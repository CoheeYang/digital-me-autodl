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

## 镜像审查与验收流程（发版必读）

1.0.0 的教训：镜像构建成功 ≠ 镜像能跑（漏装依赖直到起容器才炸）。发新版必须过三道关卡：

### 第一道：一键机器验收（push 前的硬关卡）

```bash
smoke/verify-image.sh harborpush.suanleme.cn/coheey/digitalme-serve:1.0.1
# 三关全绿才 docker push；任何一关红，看输出里的日志尾巴定位
```

| 关卡 | 抓什么 bug |
|---|---|
| ① 启动冒烟（容器起 + `/system_stats` 200） | 依赖缺失、入口脚本坏、端口不通（1.0.0 那类） |
| ② 节点契约（`/object_info` 断言） | 节点没装上/被改名；下拉值漂移（如 `int8 hybrid (recommended)`）；输入形状变更（reference_audio 成对契约）；权重目录缺失 |
| ③ 工作流校验（提交 smoke 工作流拿 prompt_id） | 接线/类型不合法、参数被拒（拿到 prompt_id = ComfyUI 校验通过；GPU 宿主继续真出片，CPU 宿主执行失败属预期） |

无 GPU 宿主自动降级 CPU 验证模式（--cpu + triton 导入补丁，只影响 triton 后端注册，不影响依赖/节点判定）。

### 第二道：人工 diff 审查（版本间对比，5 分钟）

```bash
# Dockerfile 变更审查：只许预期内的改动出现
git diff v1.0.0..HEAD -- Dockerfile
# 依赖快照对比：新增包应能对应到「有意升级的 requirements」，出现不相干的新包要追查
docker run --rm --entrypoint python <旧镜像> -m pip freeze | sort > /tmp/freeze-old.txt
docker run --rm --entrypoint python <新镜像> -m pip freeze | sort > /tmp/freeze-new.txt
diff /tmp/freeze-old.txt /tmp/freeze-new.txt
# 节点版本对比（git rev 变化必须是有意的）
docker run --rm --entrypoint sh <镜像> -c 'cd /root/ComfyUI && git rev-parse --short HEAD && for d in custom_nodes/*; do echo "$d $(git -C $d rev-parse --short HEAD)"; done'
```

### 第三道：共绩真机验收（切 SUANLI_IMAGE 前的最终关）

本地过了 ≠ GPU 环境能跑。共绩拉起新版部署后跑 `smoke/smoke.sh` 出真 mp4，通过后才改主仓库 `SUANLI_IMAGE` 指向新版。

### 版本纪律

- 版本号第三位递增（1.0.0 → 1.0.1）；**旧 tag 不删不覆盖**（回滚=改回 SUANLI_IMAGE 指旧 tag）
- 升级 breeze/FlashHead 节点（git rev 变化）时，第二道 diff 审查必做——上游接口变更正是②③关要抓的

## 已知问题

- **1.0.0 镜像漏装 ComfyUI 自身 requirements**（起容器即 `ModuleNotFoundError: sqlalchemy/torchsde`）：Dockerfile 只装了自定义节点依赖。修复：Dockerfile 增加 ComfyUI requirements 安装（排除 torch，基础镜像已带）后重打 **1.0.1**。**本地 `docker run` + `/system_stats` 200 通过前不要 push**。
- 无 GPU 宿主（笔记本）跑本镜像看 GUI：需补丁 comfy_kitchen 的 triton 无条件导入（try/except）+ `main.py --cpu`；GPU 环境不受影响（详见 digital-me 主仓库 docs/12 §6.2）。
- 大镜像（30GB+）构建对宿主盘空间要求 ≥ 镜像体积×1.5；Docker Desktop 数据盘必须不在满盘上（VHDX 无法扩展 = I/O error = 守护进程段错误）。

## 本地查看工作流 GUI（无 GPU 也可以）

```bash
docker run -d --name dm-serve-gui -p 127.0.0.1:6006:6006 \
  -e PROXY_USER=dhsvc -e PROXY_PASS=<自定密码> \
  --entrypoint bash <镜像> -c "
  chmod 644 /etc/nginx/.dhhtpasswd 2>/dev/null;
  python -m pip install -q torchsde sqlalchemy alembic av;   # 1.0.0 缺依赖的补装（1.0.1 起不需要）
  cd /root/ComfyUI && sed -i 's/^from .backends import triton as _triton_backend/try:\n    from .backends import triton as _triton_backend\nexcept Exception:\n    pass/' /opt/conda/lib/python3.11/site-packages/comfy_kitchen/__init__.py;
  nginx; exec python main.py --cpu --listen 127.0.0.1 --port 8188"
# 浏览器开 http://127.0.0.1:6006（Basic: dhsvc/<密码>），拖入 smoke/smoke_design.json
```

共绩部署起来后同样有完整 GUI：部署 accessUrl 浏览器打开 + Basic 凭据即可（GPU 环境，可真实执行）。

## License

本仓库脚本与配置为 MIT；所拉取的第三方节点与模型权重遵循各自许可（FlashHead 见其仓库；**Breeze-TTS-2 权重为 research/non-commercial，商用需 BreezeBlue 授权**）。
