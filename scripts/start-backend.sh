#!/usr/bin/env bash
# scaffold-admin 后端一键启动脚本
#
# 用法(在项目根目录):
#   scripts/start-backend.sh           jar 缺失时自动打包,前台启动(Ctrl-C 停止)
#   scripts/start-backend.sh --build   启动前强制重新打包
#   scripts/start-backend.sh --bg      后台启动,日志写入 logs/scaffold-admin.log
#
# JWT 密钥读取顺序:当前 shell 已导出的 JWT_SECRET → 根目录 .env.local → 自动生成并写入 .env.local。
# 密钥持久保存在 .env.local(.gitignore 已忽略,不会入库),重启后已登录 token 持续有效。
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/scaffold-system"
JAR_PATH="$BACKEND_DIR/scaffold-admin/target/scaffold-admin-0.1.0-SNAPSHOT.jar"
ENV_FILE="$ROOT_DIR/.env.local"
LOG_FILE="$ROOT_DIR/logs/scaffold-admin.log"
PORT=8080

# 启动前快照 shell 中已设置的环境变量,保证显式环境变量优先于 .env.local
PRESET_VARS="JWT_SECRET DB_HOST DB_PORT DB_NAME DB_USERNAME DB_PASSWORD DB_TIMEZONE REDIS_HOST REDIS_PORT REDIS_PASSWORD"

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

BUILD=0
BG=0
for arg in "$@"; do
  case "$arg" in
    --build) BUILD=1 ;;
    --bg) BG=1 ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $arg(支持 --build / --bg / --help)" >&2
      exit 1
      ;;
  esac
done

# 1. 记录 shell 中已导出的变量
for name in $PRESET_VARS; do
  eval "PRESET_${name}=\"\${${name}:-}\""
done

# 2. 载入 .env.local(仅补充 shell 中未设置的变量;KEY=VALUE 支持首尾双引号)
if [[ -f "$ENV_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" == \#* || "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "$key" | tr -d '[:space:]')"
    [[ -z "$key" ]] && continue
    # 仅接受合法的环境变量名,避免 eval 执行任意内容
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ "$val" == \"*\" ]]; then val="${val#\"}"; val="${val%\"}"; fi
    if [[ "$val" == \'*\' ]]; then val="${val#\'}"; val="${val%\'}"; fi
    eval "existing=\"\${${key}:-}\""
    if [[ -z "$existing" ]]; then
      export "${key}=${val}"
    fi
  done < "$ENV_FILE"
fi

# 3. 还原 shell 中显式设置的变量(优先级最高)
for name in $PRESET_VARS; do
  eval "preset=\"\${PRESET_${name}:-}\""
  if [[ -n "$preset" ]]; then
    export "${name}=${preset}"
  fi
done

# 4. 密钥缺失时自动生成并持久化到 .env.local
if [[ -z "${JWT_SECRET:-}" || -z "${JWT_SECRET//[[:space:]]/}" ]]; then
  JWT_SECRET="$(openssl rand -hex 32)"
  export JWT_SECRET
  if [[ -f "$ENV_FILE" ]]; then
    printf '\nJWT_SECRET=%s\n' "$JWT_SECRET" >> "$ENV_FILE"
  else
    printf 'JWT_SECRET=%s\n' "$JWT_SECRET" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
  fi
  echo "已生成本机 JWT 密钥并写入 $ENV_FILE(.gitignore 已忽略,不会入库)"
fi
export JWT_SECRET
SECRET_BYTES="$(printf '%s' "$JWT_SECRET" | wc -c | tr -d '[:space:]')"
if (( SECRET_BYTES < 32 )); then
  echo "错误:JWT_SECRET 仅 ${SECRET_BYTES} 字节,至少需要 32 字节" >&2
  exit 1
fi

# 5. 端口占用检查
if lsof -iTCP:"$PORT" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
  echo "错误:端口 $PORT 已被占用,可能已有后端实例在运行:" >&2
  lsof -iTCP:"$PORT" -sTCP:LISTEN -n -P >&2 || true
  echo "先停止占用进程(如 lsof -iTCP:$PORT -sTCP:LISTEN 查 PID 后 kill)再重试。" >&2
  exit 1
fi

# 6. 打包(--build 强制;否则仅在 jar 缺失时)
if (( BUILD )) || [[ ! -f "$JAR_PATH" ]]; then
  echo "打包 scaffold-admin(mvn -pl scaffold-admin -am package -DskipTests)..."
  (cd "$BACKEND_DIR" && mvn -pl scaffold-admin -am package -DskipTests -q)
fi

# 7. 启动
if (( BG )); then
  mkdir -p "$(dirname "$LOG_FILE")"
  nohup java -jar "$JAR_PATH" > "$LOG_FILE" 2>&1 &
  echo "已后台启动:PID=$!"
  echo "  日志: $LOG_FILE(tail -f 查看)"
  echo "  地址: http://localhost:$PORT/api"
else
  echo "前台启动中(Ctrl-C 停止服务)..."
  exec java -jar "$JAR_PATH"
fi