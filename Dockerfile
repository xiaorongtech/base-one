FROM alpine:3.20

ARG XRAY_VERSION=26.4.17

RUN apk add --no-cache \
      ca-certificates \
      curl \
      gettext \
      nginx \
      unzip \
    && addgroup -S xray \
    && adduser -S -D -H -h /var/empty -s /sbin/nologin -G xray xray \
    && mkdir -p /tmp/xray /usr/local/bin /etc/xray /etc/nginx/templates /usr/share/nginx/html /var/lib/nginx/tmp \
    && ARCH="$(apk --print-arch)" \
    && case "$ARCH" in \
         x86_64) XRAY_ARCH="64" ;; \
         aarch64) XRAY_ARCH="arm64-v8a" ;; \
         armv7) XRAY_ARCH="arm32-v7a" ;; \
         *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;; \
       esac \
    && curl -fsSL -o /tmp/xray/xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip" \
    && unzip -q /tmp/xray/xray.zip -d /tmp/xray \
    && install -m 0755 /tmp/xray/xray /usr/local/bin/xray \
    && rm -rf /tmp/xray \
    && chown -R nginx:nginx /usr/share/nginx/html /var/lib/nginx /var/log/nginx \
    && chmod 1777 /run \
    && mkdir -p /run/app/nginx \
    && chmod 1777 /run/app /run/app/nginx

COPY config/nginx.conf.template /etc/nginx/templates/nginx.conf.template
COPY config/xray.json.template /etc/xray/xray.json.template
COPY public/ /usr/share/nginx/html/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

# 运行时配置渲染到 /run/app（任意用户可写），监听 8080 以兼容非 root 运行
EXPOSE 8080/tcp

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/ >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/entrypoint.sh"]
