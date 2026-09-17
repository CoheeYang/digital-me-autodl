#!/usr/bin/env bash
# 容器入口：配置 Basic 认证与 nginx 站点，再走通用 bootstrap。
# 凭据：部署时给 PROXY_USER / PROXY_PASS 环境变量即用指定值（共绩等平台在控制台注入）；
# 未给则首启生成随机密码并落盘 /root/.dh-serve-credentials（docker logs 可见）。
set -euo pipefail

PROXY_USER="${PROXY_USER:-dhsvc}"

if [ ! -f /etc/nginx/.dhhtpasswd ]; then
  PROXY_PASS="${PROXY_PASS:-$(openssl rand -hex 12)}"
  printf '%s:%s\n' "$PROXY_USER" "$(openssl passwd -apr1 "$PROXY_PASS")" > /etc/nginx/.dhhtpasswd
  chmod 640 /etc/nginx/.dhhtpasswd
  cat > /root/.dh-serve-credentials <<EOF
# digital-me 服务凭据（nginx Basic，应用侧 DH_PROXY_USER / DH_PROXY_PASS）
DH_PROXY_USER=$PROXY_USER
DH_PROXY_PASS=$PROXY_PASS
EOF
  chmod 600 /root/.dh-serve-credentials
  echo "[entrypoint] Basic 凭据已生成（PROXY_USER=${PROXY_USER}，密码见 /root/.dh-serve-credentials 或启动日志）"
  echo "[entrypoint] DH_PROXY_USER=$PROXY_USER DH_PROXY_PASS=$PROXY_PASS"
fi

if [ ! -f /etc/nginx/conf.d/digitalme-serve.conf ]; then
  cp /root/nginx-comfyui.conf /etc/nginx/conf.d/digitalme-serve.conf
fi

exec bash /root/bootstrap.sh
