#!/usr/bin/env bash
# 合并工作流端到端冒烟（无需声音样本：VoiceDesign 音色描述兜底路径）。
# 用法：smoke.sh <公网baseUrl> <proxyUser> <proxyPass>
#   例：smoke.sh https://u123-456.bjb2.seetacloud.com:8443 dhsvc xxxx
# 验证链路：上传头像 → 提交 breeze⊕FlashHead 合并工作流 → 轮询 → 下载 mp4。
set -euo pipefail

BASE="${1:?用法: smoke.sh <公网baseUrl> <proxyUser> <proxyPass>}"
USER="${2:?缺少 proxyUser}"
PASS="${3:?缺少 proxyPass}"
AUTH=(-u "$USER:$PASS")
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

echo "[smoke] 1/5 生成测试头像（Pillow 灰底图）"
python - "$OUT_DIR/avatar.png" <<'EOF'
import sys
from PIL import Image, ImageDraw
img = Image.new("RGB", (512, 512), (60, 70, 90))
d = ImageDraw.Draw(img)
d.ellipse((156, 96, 356, 296), fill=(210, 190, 160))   # 头
d.rectangle((186, 296, 326, 470), fill=(70, 110, 150))  # 身
img.save(sys.argv[1])
EOF

echo "[smoke] 2/5 上传头像（/upload/image，字段名必须是 image）"
UPLOADED="$(curl -s "${AUTH[@]}" -F "image=@$OUT_DIR/avatar.png;type=image/png" "$BASE/upload/image" | python -c 'import json,sys; print(json.load(sys.stdin)["name"])')"
echo "      上传返回：$UPLOADED"

echo "[smoke] 3/5 注入文件名并提交合并工作流"
python - "$HERE/smoke_design.json" "$UPLOADED" "$OUT_DIR/prompt.json" <<'EOF'
import json, sys
wf = json.load(open(sys.argv[1]))
wf["4"]["inputs"]["image"] = sys.argv[2]
json.dump({"client_id": "smoke-test", "prompt": wf}, open(sys.argv[3], "w"))
EOF
PROMPT_ID="$(curl -s "${AUTH[@]}" -H "Content-Type: application/json" --data @"$OUT_DIR/prompt.json" "$BASE/prompt" | python -c 'import json,sys; print(json.load(sys.stdin)["prompt_id"])')"
echo "      prompt_id：$PROMPT_ID"

echo "[smoke] 4/5 轮询（首次装载 breeze + FlashHead 权重较慢，最长 20 分钟）"
for i in $(seq 1 120); do
  DONE="$(curl -s "${AUTH[@]}" "$BASE/history/$PROMPT_ID" | python -c '
import json, sys
h = json.load(sys.stdin)
e = h.get(sys.argv[1], {})
s = e.get("status", {})
if s.get("status_str") and s["status_str"] != "success":
    print("ERROR:" + s["status_str"]); raise SystemExit
print("YES" if s.get("completed") else "NO")
' "$PROMPT_ID" || echo "ERROR:poll")"
  case "$DONE" in
    YES) echo "      完成"; break ;;
    NO) sleep 10 ;;
    *) echo "$DONE" >&2; exit 1 ;;
  esac
  if [ "$i" -eq 120 ]; then echo "[smoke] 20 分钟超时" >&2; exit 1; fi
done

echo "[smoke] 5/5 下载产物 mp4"
FILES_JSON="$(curl -s "${AUTH[@]}" "$BASE/history/$PROMPT_ID" | python -c '
import json, sys
e = json.load(sys.stdin)[sys.argv[1]]
outs = []
for node in (e.get("outputs") or {}).values():
    for img in node.get("images", []):
        if img.get("filename", "").lower().endswith((".mp4", ".webm", ".mov")):
            outs.append((img["filename"], img.get("subfolder", ""), img.get("type", "output")))
print(json.dumps(outs[0])
' "$PROMPT_ID")"
read -r FNAME FSUB FTYPE < <(echo "$FILES_JSON" | python -c 'import json,sys; print(*json.load(sys.stdin))')
curl -s "${AUTH[@]}" -G "$BASE/view" --data-urlencode "filename=$FNAME" --data-urlencode "subfolder=$FSUB" --data-urlencode "type=$FTYPE" -o smoke_output.mp4
echo "      已保存 smoke_output.mp4（$(du -h smoke_output.mp4 | cut -f1)）"
echo "[smoke] ✅ 合并工作流链路验证通过"
