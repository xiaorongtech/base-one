#!/bin/sh
set -eu

: "${VLESS_UUID:?VLESS_UUID is required}"
: "${WS_PATH:=/r9q2x7b6p4w8}"

case "$WS_PATH" in
  /*) ;;
  *) WS_PATH="/$WS_PATH" ;;
esac

# 平台 secret 给出的是任意长度随机串，而 VLESS 的 id 必须是合法 UUID。
# 这里做一次确定性规范化：合法 UUID 原样使用，其余值用 SHA-256 派生为 UUID v4。
# 原始 secret 始终留在平台 Vault 中，不会出现在镜像、仓库或日志里。
normalize_uuid() {
  _v="$1"
  _lower=$(printf '%s' "$_v" | tr 'A-Z' 'a-z')

  if printf '%s' "$_lower" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    printf '%s' "$_lower"
    return
  fi

  if printf '%s' "$_lower" | grep -Eq '^[0-9a-f]{32}$'; then
    printf '%s-%s-%s-%s-%s' \
      "$(printf '%s' "$_lower" | cut -c1-8)" \
      "$(printf '%s' "$_lower" | cut -c9-12)" \
      "$(printf '%s' "$_lower" | cut -c13-16)" \
      "$(printf '%s' "$_lower" | cut -c17-20)" \
      "$(printf '%s' "$_lower" | cut -c21-32)"
    return
  fi

  _h=$(printf '%s' "$_v" | sha256sum | cut -c1-32)
  _a=$(printf '%s' "$_h" | cut -c1-8)
  _b=$(printf '%s' "$_h" | cut -c9-12)
  _c=$(printf '%s' "$_h" | cut -c13-16)
  _d=$(printf '%s' "$_h" | cut -c17-20)
  _e=$(printf '%s' "$_h" | cut -c21-32)

  # version = 4
  _c="4$(printf '%s' "$_c" | cut -c2-4)"

  # variant = 10xx (8/9/a/b)
  case "$(printf '%s' "$_d" | cut -c1-1)" in
    8|9|a|b) ;;
    *) _d="a$(printf '%s' "$_d" | cut -c2-4)" ;;
  esac

  printf '%s-%s-%s-%s-%s' "$_a" "$_b" "$_c" "$_d" "$_e"
}

VLESS_UUID_EFFECTIVE=$(normalize_uuid "$VLESS_UUID")

if [ "$VLESS_UUID_EFFECTIVE" != "$VLESS_UUID" ]; then
  echo "Normalised VLESS id into UUID format (raw secret stays in the platform vault)"
fi

# 平台边缘层固定把流量转发到容器 80 端口，但容器通常以非 root 运行。
# 镜像已给 nginx 加 cap_net_bind_service。用一个空闲的特权端口 81 试探绑定能力，
# 避免与真正要用的 80 抢绑（探测进程退出与正式启动之间存在竞态）。
probe_bind() {
  _port="$1"
  _cfg=$(mktemp)
  printf 'pid /run/app/probe.pid;\nerror_log /dev/null;\nevents { worker_connections 8; }\nhttp { server { listen %s; } }\n' "$_port" > "$_cfg"
  if nginx -c "$_cfg" >/dev/null 2>&1; then
    nginx -s stop -c "$_cfg" >/dev/null 2>&1 || true
    rm -f "$_cfg"
    return 0
  fi
  rm -f "$_cfg"
  return 1
}

if probe_bind 81; then
  LISTEN_DIRECTIVES="listen 80 default_server;
    listen 8080 default_server;"
  echo "Privileged port bind works as uid=$(id -u); serving on 80 and 8080"
else
  LISTEN_DIRECTIVES="listen 8080 default_server;"
  echo "WARNING: cannot bind a privileged port as uid=$(id -u); serving on 8080 only" >&2
fi

export VLESS_UUID="$VLESS_UUID_EFFECTIVE" WS_PATH LISTEN_DIRECTIVES

# 以非 root 运行时 /etc 不可写，配置一律渲染到 /run/app（tmpfs，任意用户可写）
RUN_DIR="${RUN_DIR:-/run/app}"
CONF_DIR="$RUN_DIR/conf"
WWW_DIR="$RUN_DIR/www"
mkdir -p "$CONF_DIR" "$WWW_DIR"

echo "Rendering service configuration"
envsubst '${WS_PATH} ${LISTEN_DIRECTIVES}' < /etc/nginx/templates/nginx.conf.template > "$CONF_DIR/nginx.conf"
envsubst '${VLESS_UUID} ${WS_PATH}' < /etc/xray/xray.json.template > "$CONF_DIR/xray.json"
envsubst '${WS_PATH}' < /etc/nginx/templates/index.html.template > "$WWW_DIR/index.html"

# 供落地页/客户端读取的节点参数（不含任何本地凭据）
cat > "$WWW_DIR/node.json" <<JSON
{
  "uuid": "${VLESS_UUID}",
  "path": "${WS_PATH}",
  "port": 443,
  "tls": true,
  "host": "",
  "sni": "",
  "network": "ws",
  "remark": "Komuta Free Edge - Germany-East"
}
JSON
chmod 0644 "$WWW_DIR/node.json" "$WWW_DIR/index.html"

echo "Validating internal proxy configuration"
if ! _xout=$(/usr/local/bin/xray run -test -c "$CONF_DIR/xray.json" 2>&1); then
  printf '%s\n' "$_xout" | tail -n 5
  echo "Xray configuration test failed" >&2
  exit 23
fi

echo "Validating Nginx configuration"
nginx -t -c "$CONF_DIR/nginx.conf"

echo "Starting internal proxy"
/usr/local/bin/xray run -c "$CONF_DIR/xray.json" >/dev/null 2>&1 &
XRAY_PID="$!"

echo "Starting Nginx"
nginx -c "$CONF_DIR/nginx.conf" -g 'daemon off;' &
NGINX_PID="$!"

term_handler() {
  echo "Stopping services"
  kill "$XRAY_PID" "$NGINX_PID" 2>/dev/null || true
  wait "$XRAY_PID" "$NGINX_PID" 2>/dev/null || true
  exit 0
}

trap term_handler INT TERM

while true; do
  if ! kill -0 "$XRAY_PID" 2>/dev/null; then
    echo "Internal proxy process exited" >&2
    kill "$NGINX_PID" 2>/dev/null || true
    exit 1
  fi
  if ! kill -0 "$NGINX_PID" 2>/dev/null; then
    echo "Nginx process exited" >&2
    kill "$XRAY_PID" 2>/dev/null || true
    exit 1
  fi
  sleep 5
done
