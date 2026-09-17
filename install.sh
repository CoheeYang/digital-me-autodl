#!/usr/bin/env bash
# digital-me AutoDL 服务镜像一键安装（公开仓库路线，README 路线 A）。
# 在一台全新 AutoDL 实例（基础镜像：PyTorch 2.7.x + CUDA 12.8，Ubuntu）上执行一次：
#   git clone https://github.com/CoheeYang/digital-me-autodl.git && cd digital-me-autodl
#   bash install.sh
# 产出：ComfyUI(8188) + FlashHead 数字人 + Breeze TTS 2 语音，nginx 6006 反代 + Basic 认证。
# 幂等：重复执行安全（已存在的克隆/文件跳过）。
set -euo pipefail

COMFYUI_DIR="${COMFYUI_DIR:-/root/ComfyUI}"
BREEZE_MODEL_LABEL="${BREEZE_MODEL_LABEL:-int8 hybrid (recommended)}"
PROXY_USER="${PROXY_USER:-dhsvc}"
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# AutoDL 内置学术加速（克隆 GitHub 用；结束时关闭）
if [ -f /etc/network_turbo ]; then
  # shellcheck disable=SC1091
  source /etc/network_turbo
  trap 'unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true' EXIT
fi

log() { echo "[install] $*"; }

# ---------- 1. 系统依赖 ----------
log "系统依赖（ffmpeg / nginx）"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ffmpeg nginx curl >/dev/null

# ---------- 2. ComfyUI ----------
if [ ! -d "$COMFYUI_DIR/.git" ]; then
  log "克隆 ComfyUI → $COMFYUI_DIR"
  git clone --depth 1 https://github.com/comfyanonymous/ComfyUI "$COMFYUI_DIR"
else
  log "ComfyUI 已存在，跳过"
fi

# ---------- 3. 自定义节点 ----------
install_node() {
  local url="$1" dir="$2"
  if [ ! -d "$COMFYUI_DIR/custom_nodes/$dir/.git" ]; then
    log "克隆节点 $dir"
    git clone --depth 1 "$url" "$COMFYUI_DIR/custom_nodes/$dir"
  else
    log "节点 $dir 已存在，跳过"
  fi
  if [ -f "$COMFYUI_DIR/custom_nodes/$dir/requirements.txt" ]; then
    log "安装 $dir 依赖"
    python -m pip install -q -r "$COMFYUI_DIR/custom_nodes/$dir/requirements.txt"
  fi
}
install_node https://github.com/HM-RunningHub/ComfyUI_RH_FlashHead ComfyUI_RH_FlashHead
install_node https://github.com/Saganaki22/ComfyUI-Breeze-TTS-2 ComfyUI-Breeze-TTS-2
python -m pip install -q "huggingface_hub[cli]"

# ---------- 4. 权重下载（走 hf-mirror，大陆实例必须）----------
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
MODELS="$COMFYUI_DIR/models"

log "下载 SoulX-FlashHead-1_3B（≈14.3GB）"
huggingface-cli download Soul-AILab/SoulX-FlashHead-1_3B \
  --local-dir "$MODELS/Soul-AILab/SoulX-FlashHead-1_3B"

log "下载 wav2vec2-base-960h（≈360MB）"
huggingface-cli download facebook/wav2vec2-base-960h \
  --local-dir "$MODELS/wav2vec/facebook/wav2vec2-base-960h"

log "下载 Breeze-TTS-2（$BREEZE_MODEL_LABEL）"
case "$BREEZE_MODEL_LABEL" in
  "int8 hybrid (recommended)") BREEZE_WEIGHTS="Breeze-TTS-2-int8-hybrid.safetensors" ;;
  "bf16 (best quality)")       BREEZE_WEIGHTS="Breeze-TTS-2-bf16.safetensors" ;;
  "int8 (smallest, slower)")   BREEZE_WEIGHTS="Breeze-TTS-2-int8-convrot.safetensors" ;;
  "int8 text encoder only")    BREEZE_WEIGHTS="Breeze-TTS-2-int8-text-encoder.safetensors" ;;
  *) echo "未知 BREEZE_MODEL_LABEL：$BREEZE_MODEL_LABEL" >&2; exit 1 ;;
esac
huggingface-cli download drbaph/Breeze-TTS-2-comfyui \
  --local-dir "$MODELS/breezetts2/drbaph_Breeze-TTS-2-comfyui" \
  --include "config.json" "generation_config.json" "tokenizer.json" "tokenizer_config.json" \
            "special_tokens_map.json" "audio_tokenizer/*" "$BREEZE_WEIGHTS"

# ---------- 5. nginx：6006 反代 8188 + Basic 认证 ----------
log "配置 nginx（6006 → 127.0.0.1:8188，Basic 认证）"
PROXY_PASS="$(openssl rand -hex 12)"
printf '%s:%s\n' "$PROXY_USER" "$(openssl passwd -apr1 "$PROXY_PASS")" > /etc/nginx/.dhhtpasswd
chmod 640 /etc/nginx/.dhhtpasswd
cp "$THIS_DIR/nginx-comfyui.conf" /etc/nginx/conf.d/digitalme-serve.conf
nginx -t 2>/dev/null || { echo "nginx 配置校验失败" >&2; exit 1; }
service nginx reload 2>/dev/null || service nginx start

cat > /root/.dh-serve-credentials <<EOF
# digital-me AutoDL 服务凭据（nginx Basic，对应应用侧 DH_PROXY_USER / DH_PROXY_PASS）
DH_PROXY_USER=$PROXY_USER
DH_PROXY_PASS=$PROXY_PASS
EOF
chmod 600 /root/.dh-serve-credentials

log "完成。凭据已写入 /root/.dh-serve-credentials："
echo "  DH_PROXY_USER=$PROXY_USER"
echo "  DH_PROXY_PASS=$PROXY_PASS"
log "下一步：bash $THIS_DIR/smoke/smoke.sh <6006公网域名> $PROXY_USER <密码> 做端到端冒烟"
log "冒烟通过后：AutoDL 控制台关机并存镜像；实例启动命令设为 bash $THIS_DIR/bootstrap.sh"
