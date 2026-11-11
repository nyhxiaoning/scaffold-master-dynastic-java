#!/usr/bin/env bash
# scaffold-admin 后端一键启动脚本
#
# 用法(在项目根目录):
#   scripts/start-backend.sh           jar 缺失时自动打包,前台启动(Ctrl-C 停止)
#   scripts/start-backend.sh --build   启动前强制重新打包
#   scripts/start-backend.sh --bg      后台启动,日志写入 logs/scaffold-admin.log
#   scripts/start-backend.sh --help    显示帮助
#
# 执行步骤:检查运行依赖 → 加载本机配置 → 校验 JWT 密钥 → 预检 MySQL/Redis
#           → 检查端口占用 → 打包(按需) → 启动 → 等待启动结果(--bg)。
# 任一严格前置(命令依赖 / 密钥 ≥32 字节 / MySQL / Redis / 空闲端口)不满足时,
# 报错会同时输出「当前环境」:实际检测值、该值来自哪里(环境变量/.env.local/默认值)、
# 以及本机可核查的线索(如 docker ps 检测到的容器映射端口)。
#
# JWT 等环境变量读取顺序:当前 shell 已导出的变量 → 根目录 .env.local → 默认值。
# 密钥持久保存在 .env.local(.gitignore 已忽略,不会入库),重启后已登录 token 持续有效。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/scaffold-system"
JAR_PATH="$BACKEND_DIR/scaffold-admin/target/scaffold-admin-0.1.0-SNAPSHOT.jar"
ENV_FILE="$ROOT_DIR/.env.local"
LOG_FILE="$ROOT_DIR/logs/scaffold-admin.log"
LOG_PREV="$LOG_FILE.prev"
HTTP_PORT=8080

# 启动前快照 shell 中已设置的环境变量,保证显式环境变量优先于 .env.local
PRESET_VARS="JWT_SECRET DB_HOST DB_PORT DB_NAME DB_USERNAME DB_PASSWORD DB_TIMEZONE REDIS_HOST REDIS_PORT REDIS_PASSWORD"

usage() {
  sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

# ---- 输出辅助 ----
STEP=0
TOTAL=0
start_step() { STEP=$((STEP + 1)); printf '\n[%d/%d] %s\n' "$STEP" "$TOTAL" "$1"; }
ok()   { printf '  ✔ %s\n' "$1"; }
warn() { printf '  ⚠ %s\n' "$1"; }
# die <错误描述> [处理建议] —— 两个参数都会附带「当前环境」实况
die()  {
  printf '  ✖ 错误:%s\n' "$1" >&2
  [[ $# -ge 2 ]] && printf '  处理建议:%s\n' "$2" >&2
  env_snapshot
  exit 1
}
# 报错时输出当前环境实况:变量取值来源 / 本机服务 / 进程
env_snapshot() {
  {
    echo "  ---------- 当前环境 ----------"
    echo "  系统:      $(uname -s) $(uname -r) $(sw_vers -productVersion 2>/dev/null || true)"
    echo "  项目根:    $ROOT_DIR"
    echo "  shell预设: ${PRESET_SET:-无}"
    local n v src
    for n in JWT_SECRET DB_HOST DB_PORT DB_NAME DB_USERNAME DB_TIMEZONE REDIS_HOST REDIS_PORT REDIS_PASSWORD; do
      eval "v=\"\${$n:-}\""
      case "$n" in
        JWT_SECRET) v="${v:+${v:0:8}***(${#v}字符)}"; [[ -z "$v" ]] && v="(未设置)"; src="${SRC_JWT_SECRET:-未设置}" ;;
        *) eval "src=\"\${SRC_${n}:-未设置}\""
           if [[ "$n" == *PASSWORD* ]]; then v="${v:+***已设置}"; [[ -z "$v" ]] && v="(空)"; fi ;;
      esac
      printf '  %-11s%-30s来源:%s\n' "$n:" "${v:-"(未设置)"}" "$src"
    done
    if command -v lsof >/dev/null 2>&1 && lsof -iTCP:"$HTTP_PORT" -sTCP:LISTEN -n -P 2>/dev/null | grep -q LISTEN; then
      echo "  端口 $HTTP_PORT: 被占用 -> $(lsof -iTCP:$HTTP_PORT -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR==2{print $1" PID="$2}')"
    else
      echo "  端口 $HTTP_PORT: 空闲"
    fi
    if command -v docker >/dev/null 2>&1; then
      local containers
      containers="$(docker ps --format '{{.Names}}({{.Image}}) {{.Ports}}' 2>/dev/null | grep -iE 'mysql|redis' | head -4 || true)"
      if [[ -n "$containers" ]]; then
        echo "  Docker 在跑的相关容器:"
        while IFS= read -r l; do echo "    $l"; done <<< "$containers"
      else
        echo "  Docker: 未检测到在运行的 mysql/redis 容器"
      fi
    else
      echo "  Docker: 命令不可用,无法检查容器"
    fi
    echo "  日志:      $LOG_FILE"
    echo "  --------------------------------"
  } >&2
}
# 变量来源登记:env(shell预设)/ file(.env.local)/ default(配置文件默认值)
set_src() { eval "SRC_$1=\"\$2\""; }
# 判断该变量是否来自 shell 预设:查启动时的快照 PRESET_*,不查实时值
preset_flag() { eval "[[ -n \"\${PRESET_$1:-}\" ]]"; }

# 枚举本机 docker 中所有 redis 实例:名称、宿主端口、requirepass(自动读取容器启动参数)
# 输出形如:候选 redis:容器 xxx 端口 6379 密码 123456 → 在 .env.local 写 REDIS_PORT=6379 / REDIS_PASSWORD=123456
redis_candidates() {
  command -v docker >/dev/null 2>&1 || { echo "  (docker 不可用,无法枚举 redis 实例)"; return 0; }
  local names n ports pass host_ports line any=0
  names="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i redis || true)"
  [[ -z "$names" ]] && { echo "  (未检测到运行中的 redis 容器)"; return 0; }
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    any=1
    ports="$(docker port "$n" 6379/tcp 2>/dev/null || true)"; [[ -z "$ports" ]] && ports="$(docker port "$n" 2>/dev/null | head -2 || true)"
    pass="$(docker inspect "$n" --format '{{json .Config.Cmd}}' 2>/dev/null | sed -n 's/.*"--requirepass","\([^"]*\)".*/\1/p')"; [[ -z "$pass" ]] && pass="(未设置密码)"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      host_port="${line##*:}"
      echo "  · 容器 $n  端口 $host_port  密码 $pass  →  .env.local 写 REDIS_PORT=$host_port / REDIS_PASSWORD=$pass"
    done <<< "$ports"
  done <<< "$names"
  [[ $any -eq 0 ]] && echo "  (未检测到运行中的 redis 容器)"
  return 0
}

# ---- 参数解析 ----
BUILD=0
BG=0
for arg in "$@"; do
  case "$arg" in
    --build) BUILD=1 ;;
    --bg) BG=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数:$arg" "支持 --build / --bg / --help,详见 scripts/start-backend.sh --help" ;;
  esac
done
TOTAL=$((6 + BUILD + BG))   # 依赖→配置→密钥→服务预检→端口→启动 [→打包] [→等待结果]

# ---- 步骤 1:运行依赖(严格:缺一不可) ----
start_step "检查运行依赖(严格:java / lsof / nc,--build 另需 mvn)"
missing=""
for cmd in java lsof nc; do
  command -v "$cmd" >/dev/null 2>&1 || missing="$missing $cmd"
done
if [[ -n "$missing" ]]; then
  die "缺少必需命令:$missing" "macOS:brew install openjdk;并确认 PATH 含 /usr/bin(lsof/nc 系统自带,缺失说明 PATH 异常)"
fi
ok "java: $(java -version 2>&1 | head -1)"
if (( BUILD )); then
  command -v mvn >/dev/null 2>&1 || die "缺少 mvn(--build 为严格前置)" "安装:brew install maven;或去掉 --build 用已有 jar"
  ok "mvn: $(mvn -v 2>/dev/null | head -1)"
fi
PRESET_SET="$(for name in $PRESET_VARS; do eval "v=\"\${$name:-}\""; [[ -n "$v" ]] && printf '%s ' "$name"; true; done)"
[[ -z "$PRESET_SET" ]] && PRESET_SET="无"
true

# ---- 步骤 2:加载本机配置 .env.local,登记来源 ----
start_step "加载本机配置 $ENV_FILE(shell 显式变量 > 本文件 > 默认值)"
for name in $PRESET_VARS; do
  eval "PRESET_${name}=\"\${${name}:-}\""
  set_src "$name" "$([[ -n "${!name:-}" ]] && echo "shell 环境变量" || echo "未设置")"
done
if [[ -f "$ENV_FILE" ]]; then
  line_no=0; loaded=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"; val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    [[ -z "$key" ]] && continue
    if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      warn ".env.local 第 ${line_no} 行变量名非法(已跳过):${key}"
      continue
    fi
    if [[ "$val" == \"*\" ]]; then val="${val#\"}"; val="${val%\"}"; fi
    if [[ "$val" == \'*\' ]]; then val="${val#\'}"; val="${val%\'}"; fi
    eval "existing=\"\${${key}:-}\""
    if [[ -z "$existing" ]]; then
      export "${key}=${val}"
      [[ -n "$(for n in $PRESET_VARS; do [[ "$n" == "$key" ]] && echo 1; done)" ]] && set_src "$key" ".env.local"
      loaded=$((loaded + 1))
    fi
  done < "$ENV_FILE"
  ok "已读入 $loaded 项(shell 中已设置的同名变量保持优先)"
else
  ok "不存在 .env.local,全部取 shell 环境变量与默认值"
fi
for name in $PRESET_VARS; do
  eval "preset=\"\${PRESET_${name}:-}\""
  [[ -n "$preset" ]] && export "${name}=${preset}"
done

# ---- 步骤 3:JWT 密钥(严格:≥32 字节) ----
start_step "校验 JWT 密钥(严格:UTF-8 编码 ≥32 字节且非空白)"
if [[ -z "${JWT_SECRET:-}" || -z "${JWT_SECRET//[[:space:]]/}" ]]; then
  command -v openssl >/dev/null 2>&1 || die "缺 openssl,无法生成密钥" "先装 openssl,或手动 export JWT_SECRET=\"\$(openssl rand -hex 32)\""
  JWT_SECRET="$(openssl rand -hex 32)"
  export JWT_SECRET
  if [[ -f "$ENV_FILE" ]]; then printf '\nJWT_SECRET=%s\n' "$JWT_SECRET" >> "$ENV_FILE"
  else printf 'JWT_SECRET=%s\n' "$JWT_SECRET" > "$ENV_FILE"; chmod 600 "$ENV_FILE"; fi
  set_src JWT_SECRET ".env.local(本次自动生成)"
  ok "未检测到密钥,已生成 64 字节并写入 $(basename "$ENV_FILE")(权限 600,git 忽略,不入库)"
else
  set_src JWT_SECRET "$(preset_flag JWT_SECRET && echo "shell 环境变量" || echo ".env.local")"
  ok "已就绪,来源:${SRC_JWT_SECRET}"
fi
export JWT_SECRET
SECRET_BYTES="$(printf '%s' "$JWT_SECRET" | wc -c | tr -d '[:space:]')"
if (( SECRET_BYTES < 32 )); then
  die "JWT_SECRET 仅 ${SECRET_BYTES} 字节,不满足严格前置(≥32)" \
      "删除 $(basename "$ENV_FILE") 中的 JWT_SECRET 行让脚本重新生成,或执行 export JWT_SECRET=\"\$(openssl rand -hex 32)\""
fi
ok "长度 ${SECRET_BYTES} 字节,校验通过"

# ---- 步骤 4:依赖服务预检(严格:MySQL、Redis 必须可达且认证通过) ----
start_step "预检依赖服务(严格:MySQL TCP 可达;Redis TCP 可达且认证通过)"
DB_HOST="${DB_HOST:-localhost}"; DB_PORT="${DB_PORT:-33060}"
REDIS_HOST="${REDIS_HOST:-localhost}"; REDIS_PORT="${REDIS_PORT:-6379}"
for n in DB_HOST DB_PORT REDIS_HOST REDIS_PORT; do
  preset_flag "$n" && set_src "$n" "shell 环境变量" || { grep -qE "^${n}=" "$ENV_FILE" 2>/dev/null && set_src "$n" ".env.local" || set_src "$n" "默认值(application-dev.yml)"; }
done
printf '  连接目标:MySQL %s:%s | Redis %s:%s\n' "$DB_HOST" "$DB_PORT" "$REDIS_HOST" "$REDIS_PORT"

if nc -z -w 2 "$DB_HOST" "$DB_PORT" >/dev/null 2>&1; then
  ok "MySQL 可达: ${DB_HOST}:${DB_PORT}"
else
  die "MySQL 不可连接:${DB_HOST}:${DB_PORT}(TCP 拒绝或超时)" \
      "先起库(上方「当前环境」已列出 docker 容器与其映射端口,端口不一致时在 .env.local 写 DB_PORT=<映射端口>)"
fi

if nc -z -w 2 "$REDIS_HOST" "$REDIS_PORT" >/dev/null 2>&1; then
  ok "Redis TCP 可达: ${REDIS_HOST}:${REDIS_PORT}"
  if command -v redis-cli >/dev/null 2>&1; then
    if [[ -n "${REDIS_PASSWORD:-}" ]]; then
      pong="$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASSWORD" ping 2>&1 || true)"
    else
      pong="$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping 2>&1 || true)"
    fi
    pong="$(printf '%s' "$pong" | tail -1)"
    if [[ "$pong" == "PONG" ]]; then
      ok "Redis 认证通过(PONG)"
    elif [[ "$pong" == NOAUTH* || "$pong" == WRONGPASS* || "$pong" == *"invalid password"* || "$pong" == *NOAUTH* || "$pong" == *WRONGPASS* ]]; then
      die "Redis 认证失败(返回:${pong});服务器设置了 requirepass,当前 REDIS_PASSWORD 不对" \
"候选(本机在跑的 redis 实例,端口/密码自动读取自容器启动参数,选对的组合写回 .env.local):
$(redis_candidates)"
    else
      die "redis-cli 认证测试异常(返回:${pong})" \
"核对 REDIS_PORT/REDIS_PASSWORD;.env.local 当前为 ${REDIS_HOST}:${REDIS_PORT} / REDIS_PASSWORD=$(printf '%s' "${REDIS_PASSWORD:-未设置}" | sed 's/./*/g')
候选实例:
$(redis_candidates)"
    fi
  else
    warn "redis-cli 未安装,仅验证了 TCP 可达;若运行时报 RedisConnectionFailureException,补装 redis-cli 后重跑"
  fi
else
  die "Redis 不可连接:${REDIS_HOST}:${REDIS_PORT}(TCP 拒绝或超时)" \
"若实际端口不同,按下方候选改 .env.local 的 REDIS_PORT / REDIS_PASSWORD:
$(redis_candidates)"
fi

# ---- 步骤 5:端口占用(严格:8080 必须空闲) ----
start_step "检查端口 $HTTP_PORT(严格:必须空闲)"
if lsof -iTCP:"$HTTP_PORT" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
  lsof -iTCP:"$HTTP_PORT" -sTCP:LISTEN -n -P >&2 || true
  die "端口 $HTTP_PORT 已被占用" \
      "停掉占用进程:kill \$(lsof -t -iTCP:$HTTP_PORT -sTCP:LISTEN);若是旧后端实例,停掉后重跑本脚本"
fi
ok "端口空闲"

# ---- 步骤 6:打包(--build 强制;否则仅 jar 缺失时) ----
if (( BUILD )) || [[ ! -f "$JAR_PATH" ]]; then
  start_step "打包 scaffold-admin(mvn -pl scaffold-admin -am package -DskipTests)"
  command -v mvn >/dev/null 2>&1 || die "缺少 mvn(打包为严格前置)" "安装:brew install maven"
  if ! (cd "$BACKEND_DIR" && mvn -pl scaffold-admin -am package -DskipTests -q); then
    die "Maven 打包失败(上方为 Maven 输出)" "常见原因:依赖下载失败(网络/镜像配置)、Java 版本 < 17、源码编译错误"
  fi
  [[ -f "$JAR_PATH" ]] || die "打包结束但 jar 不存在:$JAR_PATH" "检查上方 Maven 输出的 artifactId 与版本号是否一致"
  ok "打包完成:$(basename "$JAR_PATH") ($(du -h "$JAR_PATH" | cut -f1))"
fi

# ---- 步骤 7:启动 ----
start_step "启动后端"
if [[ -f "$LOG_FILE" ]]; then
  mv -f "$LOG_FILE" "$LOG_PREV"
  ok "旧日志备份为 $(basename "$LOG_PREV")"
fi
mkdir -p "$(dirname "$LOG_FILE")"
printf '  参数: DB=%s:%s(%s) REDIS=%s:%s(%s) JWT=%s…%d字节(%s)\n' \
  "$DB_HOST" "$DB_PORT" "${SRC_DB_PORT:-?}" "$REDIS_HOST" "$REDIS_PORT" "${SRC_REDIS_PORT:-?}" \
  "${JWT_SECRET:0:8}" "$SECRET_BYTES" "${SRC_JWT_SECRET:-?}"
if (( BG )); then
  nohup java -jar "$JAR_PATH" > "$LOG_FILE" 2>&1 &
  APP_PID=$!
  ok "进程已拉起:PID=$APP_PID"
else
  ok "前台模式:日志同时输出到终端与 $(basename "$LOG_FILE")(Ctrl-C 停止)"
fi

# ---- 步骤 8(仅 --bg):等待并报告启动结果 ----
if (( BG )); then
  start_step "等待启动结果(最长 90 秒;失败会输出日志报错与疑似根因)"
  elapsed=0; started=0
  while (( elapsed < 90 )); do
    grep -q "Started ScaffoldAdminApplication" "$LOG_FILE" 2>/dev/null && { started=1; break; }
    grep -qE "Application run failed|APPLICATION FAILED TO START" "$LOG_FILE" 2>/dev/null && break
    kill -0 "$APP_PID" 2>/dev/null || break
    sleep 1; elapsed=$((elapsed + 1))
  done
  if (( started )); then
    ok "启动成功,用时 ${elapsed}s——$(grep 'Started ScaffoldAdminApplication' "$LOG_FILE" | tail -1 | sed 's/.*Started/Started/')"
    printf '\n  ✔ 全部 %d 步通过。\n' "$TOTAL"
    printf '    地址: http://localhost:%s/api    日志: %s\n' "$HTTP_PORT" "$LOG_FILE"
    printf '    停止: kill %s\n' "$APP_PID"
    exit 0
  fi
  warn "启动失败——日志末尾 40 行:"
  echo "  ---------- $LOG_FILE ----------" >&2
  tail -40 "$LOG_FILE" >&2 2>/dev/null || echo "  (日志为空,进程可能未产出输出)" >&2
  echo "  --------------------------------" >&2
  cause="$(grep -m1 -E 'Caused by:|BeanCreationException|IllegalArgumentException|IllegalStateException|APPLICATION FAILED TO START|Application run failed|Password authentication failed|Communications link failure' "$LOG_FILE" 2>/dev/null || true)"
  [[ -n "$cause" ]] && printf '  疑似根因:%s\n' "$cause" >&2
  if kill -0 "$APP_PID" 2>/dev/null; then
    warn "进程 PID=$APP_PID 仍在,执行清理性停止"
    kill "$APP_PID" 2>/dev/null || true
  fi
  die "启动失败" "按「疑似根因」处理(数据库/Redis 认证失败则修 .env.local 中的账号密码;端口冲突见上方当前环境)"
fi

printf '\n  ✔ 全部 %d 步通过。\n' "$TOTAL"
printf '    地址: http://localhost:%s/api    日志: %s\n' "$HTTP_PORT" "$LOG_FILE"
printf '    停止: Ctrl-C(前台模式)\n'