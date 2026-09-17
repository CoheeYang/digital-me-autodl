#!/usr/bin/env bash
# 容器入口（路线 B）：首启生成 Basic 凭据与 nginx 配置，再走通用 bootstrap。
set -euo pipefail

PROXY_USER="${PROXY_USER:-dhsvc}"

if [ ! -f /etc/nginx/.dhhtpasswd ]; then
  PROXY_PASS="$(openssl rand -hex 12)"
  printf '%s:%s\n' "$PROXY_USER" "$(openssl passwd -apr1 "$PROXY_PASS")" > /etc/nginx/.dhhtpasswd
  chmod 640 /etc/nginx/.dhhtpasswd
  cat > /root/.dh-serve-credentials <<EOF
# digital-me 服务凭据（nginx Basic，应用侧 DH_PROXY_USER / DH_PROXY_PASS）
DH_PROXY_USER=$PROXY_USER
DH_PROXY_PASS=$PROXY_PASS
EOF
  chmod 600 /root/.dh-serve-credentials
  echo "[entrypoint] 凭据已生成：/root/.dh-serve-credentials"
fi

if [ ! -f /etc/nginx/conf.d/digitalme-serve.conf ]; then
  cp /root/nginx-comfyui.conf /etc/nginx/conf.d/digitalme-serve.conf
fi

exec bash /root/bootstrap.sh
