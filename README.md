# digital-me-autodl — 数字人课程服务的 AutoDL GPU 镜像

[digital-me](https://github.com/CoheeYang/digital-me)（AI 录播课数字人生成平台）的 GPU 服务端环境：**一个 AutoDL 实例跑通「文字 → 数字人讲课视频」全管线**。

```
口播稿文本 + 声音样本(可选) + 头像图片
        │  一次 ComfyUI 提交（合并工作流）
        ▼
┌──────────────────────── ComfyUI (127.0.0.1:8188) ────────────────────────┐
│  BreezeTTS2VoiceClone(text, ref_audio, ref_text) ──AUDIO──► FlashHead    │
│  （无样本时 BreezeTTS2VoiceDesign：文字描述音色）      Sampler + Loader   │
│                                                            │             │
│  LoadImage(头像) ──────────────────────────────────────────┘ ► SaveVideo  │
└──────────────────────────────────────────────────────────────────────────┘
        │  nginx 6006 反代 + Basic 认证（AutoDL 自动映射公网域名）
        ▼
  chunk 对口型视频 mp4
```

- **语音**：[Breeze TTS 2](https://huggingface.co/BreezeBlue/Breeze-TTS-2)（breez-tts2，3B，中英双语，零样本声音克隆）——⚠️ 权重为 research/non-commercial 许可，自托管商用需自行取得 BreezeBlue 授权
- **数字人**：[ComfyUI_RH_FlashHead](https://github.com/HM-RunningHub/ComfyUI_RH_FlashHead)（SoulX-FlashHead-1_3B，lite/pro 两档）
- 显存：breeze int8-hybrid ≈5.5GiB + FlashHead，**24G 卡（4090/4090D）单实例够用**；ComfyUI 队列天然串行，无需自管并发

---

## 路线 A（推荐）：AutoDL 基础镜像 + 一键脚本

1. **开实例**：AutoDL 控制台 → 容器实例 Pro，地区随意（如北京B），GPU 选 4090D ×1；镜像选 **PyTorch 2.7.x + CUDA 12.8** 系基础镜像（Ubuntu 20.04/22.04 均可）。
2. **扩容系统盘 +50GB**（创建页勾选，或创建后在「更多→配置调整」）：FlashHead 权重 14.3G + wav2vec 0.4G + breeze 5G + 环境 ~10G，默认 30G 盘装不下。
3. **SSH 进实例**执行：
   ```bash
   git clone https://github.com/CoheeYang/digital-me-autodl.git
   cd digital-me-autodl
   bash install.sh          # ≈20-40 分钟（大头是权重下载，走 hf-mirror）
   ```
   结束时会打印 nginx Basic 凭据（也存于 `/root/.dh-serve-credentials`）。
4. **冒烟**（实例的 6006 公网域名在控制台「SSH远程连接」旁可见）：
   ```bash
   bash smoke/smoke.sh https://u<uid>-<inst>.<region>.seetacloud.com:8443 <user> <pass>
   ```
   跑通会在当前目录留下 `smoke_output.mp4`（首次提交含权重装载，最长 ~20 分钟）。
5. **固化**：控制台关机 → 「更多→保存镜像」（如 `digitalme-serve-v2`）；之后开实例选该私有镜像，**自定义启动命令**填：
   ```bash
   bash /root/digital-me-autodl/bootstrap.sh
   ```

## 路线 B：Docker 镜像（可选）

本仓库带 [Dockerfile](Dockerfile)（权重不进镜像，首启自动下载）。打 tag（如 `v1`）触发 [GitHub Actions](.github/workflows/docker.yml) 构建并推到 `ghcr.io/<owner>/digital-me-autodl`；AutoDL 创建实例时「镜像市场→Docker 镜像」填镜像地址即可（若只认 Docker Hub，在仓库 Secrets 配置 Docker Hub 账号后启用 workflow 里注释掉的第二段登录）。

---

## 合并工作流契约（给接 API 的人）

冒烟用的 [smoke/smoke_design.json](smoke/smoke_design.json) 就是完整示例。关键点（全部经两节点源码核实）：

| 节点 | class_type | 关键输入 |
|---|---|---|
| 模型装载 | `BreezeTTS2LoadModel` | `model` 必须精确等于下拉标签（默认档 `"int8 hybrid (recommended)"`）；`decode_mode: "eager"`（cuda_graphs 会常驻显存）；`download_if_missing: true` |
| 声音克隆 | `BreezeTTS2VoiceClone` | `breeze_model`←装载节点；`text`=口播稿；`reference_audio`←`LoadAudio` 输出（**AUDIO 类型**）；`reference_text`=样本的**精确转写**（≠口播稿）；`cfg_scale: 1.0`（>1 且无 instruction 会 500）；`seed` 正值可复现（**0=随机**） |
| 音色描述 | `BreezeTTS2VoiceDesign` | 无 reference_audio/ref_text，改传 `instruction`（如「沉稳清晰的中文讲师」）；`cfg_scale: 4.0` |
| 数字人 | `RunningHub SoulX-FlashHead Sampler` | `ref_audio` 接 breeze 的 **AUDIO 输出直连**（采样率随 AUDIO dict 自描述，无需重采样）；`avatar_image`←`LoadImage`；`model_type: lite\|pro`；832×672 |
| 保存 | `SaveVideo` | `filename_prefix: "video/…"`；产物从 `/history` 的 `outputs[node]["images"]` 取（注意是 images 不是 videos） |

HTTP 契约（应用侧 `ComfyUiClient` 已实现，换环境直连同样适用）：

- 上传：`POST /upload/image`，multipart **字段名必须叫 `image`**（音频也是，服务端硬编码）
- 提交：`POST /prompt`，body `{client_id, prompt: <上述工作流 JSON>}` → `{prompt_id}`
- 轮询：`GET /history/{prompt_id}`，`status.completed` 且 `status_str==="success"` 即成
- 下载：`GET /view?filename=…&subfolder=…&type=output`，**下完即取走**（输出目录会被周期清理）
- 探活：`GET /system_stats` 返回 200
- 所有请求带 `Authorization: Basic <DH_PROXY_USER>:<DH_PROXY_PASS>`

## 应用侧（digital-me）对接

实例跑起来后，在应用平台注入：

```bash
DH_COMFYUI_BASE_URL=https://u<uid>-<inst>.<region>.seetacloud.com:8443
DH_PROXY_USER=<install.sh 打印的用户>
DH_PROXY_PASS=<install.sh 打印的密码>
DH_SERVE_INSTANCE_UUID=<AutoDL 实例 uuid>   # 空闲自动关机守卫用
AUTODL_TOKEN=<AutoDL API token>
```

## 坑位备忘

- **glibc**：Ubuntu 20.04（glibc 2.31）装不上 flash_attn 的 wheel —— 两节点的 `attention` 保持 `auto`，自动回落 sdpa，质量无损。
- **HF 下载**：大陆实例必须 `HF_ENDPOINT=https://hf-mirror.com`（install.sh 已内置）；克隆 GitHub 慢时 AutoDL 自带 `source /etc/network_turbo` 学术加速。
- **6006 端口**：AutoDL 只把 6006 自动映射为公网域名，nginx 监听 6006、ComfyUI 只听 127.0.0.1，别改端口结构。
- **首次提交慢**：breeze + FlashHead 权重装载约 1-3 分钟属正常；冷启动后单 chunk（~90s 口播）合成 lite 档分钟级。
- **种子**：breeze 的 `seed=0` 是「随机」不是固定值——要可复现必须给正整数。

## License

本仓库脚本与配置为 MIT；所拉取的第三方节点与模型权重遵循各自许可（FlashHead 见其仓库；**Breeze-TTS-2 权重为 research/non-commercial，商用需 BreezeBlue 授权**）。
