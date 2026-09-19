#!/usr/bin/env bash
# 镜像推送前验收关卡（防 1.0.0 式翻车：docs/12 §6.1 的教训固化）。
# 用法：smoke/verify-image.sh <完整镜像ref，如 harborpush.suanleme.cn/coheey/digitalme-serve:1.0.1>
# 三关全绿才允许 docker push：
#   ① 启动冒烟  —— 容器能起，ComfyUI /system_stats 200（抓依赖缺失类 bug）
#   ② 节点契约  —— /object_info 断言 breeze/FlashHead 节点注册且关键输入形状未变（抓节点丢失/接口变更）
#   ③ 工作流校验 —— 提交 smoke 工作流拿到 prompt_id（抓接线/类型/参数不合法；GPU 宿主会继续真出片）
# 无 GPU 宿主自动加 --cpu + comfy_kitchen triton 补丁（仅本地验证用，不改变镜像内容；
# 该补丁只影响 triton 后端注册，不影响「依赖是否装齐/节点是否可用」的判定）。
set -euo pipefail

IMG="${1:?用法: verify-image.sh <镜像ref>}"
NAME="dm-verify-$$"
PORT=$(( 20000 + RANDOM % 20000 ))
USER="verify"
PASS="$(openssl rand -hex 6)"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[verify] ① 启动容器：$IMG（端口 127.0.0.1:$PORT）"
GPU_MODE="yes"
if ! command -v nvidia-smi >/dev/null 2>&1; then
  GPU_MODE="no"
  echo "[verify]   无 GPU 宿主 → CPU 验证模式（--cpu + triton 导入补丁）"
  docker run -d --name "$NAME" -p "127.0.0.1:$PORT:6006" --entrypoint bash "$IMG" -c "
    printf '%s:%s\n' '$USER' \"\$(openssl passwd -apr1 '$PASS')\" > /etc/nginx/.dhhtpasswd; chmod 644 /etc/nginx/.dhhtpasswd
    cp /root/nginx-comfyui.conf /etc/nginx/conf.d/digitalme-serve.conf 2>/dev/null || true
    sed -i 's/^from .backends import triton as _triton_backend/try:\\n    from .backends import triton as _triton_backend\\nexcept Exception:\\n    pass/' \$(python -c 'import comfy_kitchen,os;print(os.path.join(os.path.dirname(comfy_kitchen.__file__),"__init__.py"))' 2>/dev/null || echo /opt/conda/lib/python3.11/site-packages/comfy_kitchen/__init__.py)
    nginx
    cd /root/ComfyUI && exec python main.py --cpu --listen 127.0.0.1 --port 8188" >/dev/null
else
  docker run -d --name "$NAME" -p "127.0.0.1:$PORT:6006" \
    -e PROXY_USER="$USER" -e PROXY_PASS="$PASS" "$IMG" >/dev/null
fi

auth=(-u "$USER:$PASS")
echo "[verify] ① 等待 ComfyUI 就绪（首启装载权重较慢，最长 15 分钟）"
ok=""
for i in $(seq 1 90); do
  sleep 10
  if [ "$(curl -s --max-time 5 "${auth[@]}" -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/system_stats 2>/dev/null)" = "200" ]; then ok=1; break; fi
  if ! docker ps --format '{{.Names}}' | grep -q "^$NAME$"; then
    echo "✗ 容器已退出（启动失败）："; docker logs "$NAME" 2>&1 | tail -15; exit 1
  fi
done
[ -n "$ok" ] || { echo "✗ 15 分钟未就绪"; docker exec "$NAME" tail -20 /root/comfyui.log 2>/dev/null || docker logs "$NAME" 2>&1 | tail -20; exit 1; }
echo "[verify] ① ✅ /system_stats 200（依赖完整性通过）"

echo "[verify] ② 节点契约断言（/object_info）"
curl -s --max-time 10 "${auth[@]}" "http://127.0.0.1:$PORT/object_info" -o /tmp/dm-verify-object.json
python3 - "$GPU_MODE" <<'EOF'
import json, sys
gpu = sys.argv[1]
d = json.load(open("/tmp/dm-verify-object.json"))
def need(cond, msg):
    if not cond:
        print(f"✗ {msg}"); sys.exit(1)
# 1) 关键节点注册
for node in ["BreezeTTS2LoadModel", "BreezeTTS2VoiceClone", "BreezeTTS2VoiceDesign",
             "RunningHub SoulX-FlashHead Sampler", "RunningHub SoulX-FlashHead Loader"]:
    need(node in d, f"节点未注册: {node}")
# 2) 下拉值精确匹配（07 §4.3 契约：model 必须是 REPO_CHOICES 的 key）
lm = d["BreezeTTS2LoadModel"]["input"]["required"]
need("int8 hybrid (recommended)" in lm["model"][0], "BreezeTTS2LoadModel.model 下拉值缺 int8 hybrid (recommended)（构造器会 422）")
# 3) 克隆节点输入形状（ref 成对 + AUDIO 类型直连契约）
vc = d["BreezeTTS2VoiceClone"]["input"]["required"]
need("reference_audio" in vc and "reference_text" in vc, "VoiceClone 缺 reference_audio/reference_text 输入（克隆契约变了）")
need("cfg_scale" in vc and "seed" in vc, "VoiceClone 缺 cfg_scale/seed")
sampler = d["RunningHub SoulX-FlashHead Sampler"]["input"]
need("ref_audio" in sampler.get("required", {}), "FlashHead Sampler 缺 ref_audio 输入（AUDIO 直连契约变了）")
# 4) 权重就位（离线确定性：镜像内已烘焙，download_if_missing 只是兜底）
print("✓ 节点契约全部通过（breeze 三节点 + FlashHead 两节点 + 下拉值 + 输入形状）")
EOF
docker exec "$NAME" sh -c '
  for f in /root/ComfyUI/models/Soul-AILab/SoulX-FlashHead-1_3B /root/ComfyUI/models/wav2vec/facebook/wav2vec2-base-960h /root/ComfyUI/models/breezetts2/drbaph_Breeze-TTS-2-comfyui; do
    [ -d "$f" ] && [ -n "$(ls -A "$f" 2>/dev/null)" ] || { echo "✗ 权重目录缺失或为空: $f"; exit 1; }
  done
  echo "[verify] ② ✅ 权重目录齐全"' || exit 1

echo "[verify] ③ 工作流校验（提交 smoke_design.json 拿 prompt_id）"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -c '
import base64
open("/tmp/dm-verify-avatar.png", "wb").write(base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABh6FO1AAAAABJRU5ErkJggg=="))'
UPLOADED=$(curl -s "${auth[@]}" -F "image=@/tmp/dm-verify-avatar.png;type=image/png" "http://127.0.0.1:$PORT/upload/image" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
python3 - "$HERE/smoke_design.json" "$UPLOADED" <<'EOF'
import json, sys
wf = json.load(open(sys.argv[1]))
wf["4"]["inputs"]["image"] = sys.argv[2]
json.dump({"client_id": "verify", "prompt": wf}, open("/tmp/dm-verify-prompt.json", "w"))
EOF
RESP=$(curl -s --max-time 60 "${auth[@]}" -H "Content-Type: application/json" --data @/tmp/dm-verify-prompt.json "http://127.0.0.1:$PORT/prompt")
echo "$RESP" | python3 -c '
import json, sys
r = json.load(sys.stdin)
pid = r.get("prompt_id")
if pid:
    print("[verify] ③ ✅ 工作流校验通过（prompt_id=%s；节点/输入/接线合法）" % pid)
    print("[verify]    （GPU 宿主将继续真实出片；CPU 宿主执行失败属预期，校验通过即达标）")
else:
    print("✗ 工作流被拒：", json.dumps(r.get("node_errors") or r, ensure_ascii=False)[:500]); sys.exit(1)'

echo ""
echo "════════ 三关全绿，允许推送：docker push $IMG ══════"
