#!/usr/bin/env bash
# 实例启动脚本（AutoDL「自定义启动命令」填：bash /root/digital-me-autodl/bootstrap.sh）。
# 职责：起 ComfyUI(127.0.0.1:8188) → 等就绪 → 起/刷 nginx(6006 反代+Basic)。
# 幂等：服务已在跑则直接跳过；重复执行安全。
set -euo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-/root/ComfyUI}"
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMFYUI_LOG="${COMFYUI_LOG:-/root/comfyui.log}"

log() { echo "[bootstrap] $*"; }

# ---------- ComfyUI ----------
if curl -sf -o /dev/null --max-time 3 http://127.0.0.1:8188/system_stats; then
  log "ComfyUI 已在运行"
else
  if ! pgrep -f "python.*main.py.*8188" >/dev/null 2>&1; then
    log "启动 ComfyUI（日志 $COMFYUI_LOG）"
    cd "$COMFYUI_DIR"
    nohup python main.py --listen 127.0.0.1 --port 8188 >"$COMFYUI_LOG" 2>&1 &
    echo $! > /root/comfyui.pid
  fi
  log "等待 ComfyUI 就绪（首次装载权重较慢，最长 15 分钟）"
  for i in $(seq 1 90); do
    if curl -sf -o /dev/null --max-time 3 http://127.0.0.1:8188/system_stats; then
      log "ComfyUI 就绪"
      break
    fi
    if [ "$i" -eq 90 ]; then
      echo "[bootstrap] ComfyUI 15 分钟未就绪，最近日志：" >&2
      tail -n 50 "$COMFYUI_LOG" >&2 || true
      exit 1
    fi
    sleep 10
  done
fi

# ---------- nginx（6006 反代 + Basic 认证）----------
if [ -f "$THIS_DIR/nginx-comfyui.conf" ] && [ ! -f /etc/nginx/conf.d/digitalme-serve.conf ]; then
  cp "$THIS_DIR/nginx-comfyui.conf" /etc/nginx/conf.d/digitalme-serve.conf
fi
if ! service nginx status >/dev/null 2>&1; then
  service nginx start
else
  service nginx reload || true
fi

log "服务就绪：http://127.0.0.1:6006（Basic 认证，凭据见 /root/.dh-serve-credentials）"
