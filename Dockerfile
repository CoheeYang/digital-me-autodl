# digital-me GPU 服务自包含镜像（共绩算力 / 任意 docker 环境可跑）：
# PyTorch 2.7.1+cu128（官方镜像自带）+ ComfyUI + FlashHead/breeze 两节点 + 全部权重（≈32GB）——
# 从本镜像起容器即完整可用，不依赖实例持久盘与首启下载。
# 构建耗时长（权重 ~20GB 走 hf-mirror）；改代码/依赖重构建时权重层命中缓存不重下。
# 基础镜像前缀可注入：国内本地构建用镜像源（默认 docker.1ms.run），CI/海外直连用 docker.io
ARG DOCKER_REGISTRY_PREFIX=docker.1ms.run
FROM ${DOCKER_REGISTRY_PREFIX}/pytorch/pytorch:2.7.1-cuda12.8-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    HF_ENDPOINT=https://hf-mirror.com \
    COMFYUI_DIR=/root/ComfyUI \
    PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple

# ---------- 系统依赖（阿里云源加速）----------
RUN sed -i 's|archive.ubuntu.com|mirrors.aliyun.com|g; s|security.ubuntu.com|mirrors.aliyun.com|g' /etc/apt/sources.list && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends git ffmpeg nginx curl openssl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# ---------- ComfyUI + 自定义节点（torch 已随基础镜像就位）----------
RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI /root/ComfyUI && \
    git clone --depth 1 https://github.com/HM-RunningHub/ComfyUI_RH_FlashHead /root/ComfyUI/custom_nodes/ComfyUI_RH_FlashHead && \
    git clone --depth 1 https://github.com/Saganaki22/ComfyUI-Breeze-TTS-2 /root/ComfyUI/custom_nodes/ComfyUI-Breeze-TTS-2 && \
    python -m pip install --no-cache-dir -r /root/ComfyUI/custom_nodes/ComfyUI_RH_FlashHead/requirements.txt && \
    python -m pip install --no-cache-dir -r /root/ComfyUI/custom_nodes/ComfyUI-Breeze-TTS-2/requirements.txt && \
    python -m pip install --no-cache-dir "huggingface_hub[cli]"

# ---------- 权重（FlashHead 14.3G + wav2vec 0.4G + breeze int8-hybrid ≈5G，hf-mirror）----------
ARG BREEZE_WEIGHTS="Breeze-TTS-2-int8-hybrid.safetensors"
RUN huggingface-cli download Soul-AILab/SoulX-FlashHead-1_3B \
      --local-dir /root/ComfyUI/models/Soul-AILab/SoulX-FlashHead-1_3B && \
    huggingface-cli download facebook/wav2vec2-base-960h \
      --local-dir /root/ComfyUI/models/wav2vec/facebook/wav2vec2-base-960h && \
    huggingface-cli download drbaph/Breeze-TTS-2-comfyui \
      --local-dir /root/ComfyUI/models/breezetts2/drbaph_Breeze-TTS-2-comfyui \
      --include "config.json" "generation_config.json" "tokenizer.json" "tokenizer_config.json" \
                "special_tokens_map.json" "audio_tokenizer/*" "${BREEZE_WEIGHTS}"

# ---------- 应用脚本与入口 ----------
COPY bootstrap.sh docker-entrypoint.sh nginx-comfyui.conf /root/
COPY smoke/ /root/smoke/
RUN chmod +x /root/bootstrap.sh /root/docker-entrypoint.sh /root/smoke/smoke.sh && \
    # 权重就位后关闭节点运行期下载（离线确定性：缺文件直接报错而非静默拉网）
    echo "weights baked at build time" > /root/ComfyUI/models/.weights-baked

EXPOSE 6006
ENTRYPOINT ["bash", "/root/docker-entrypoint.sh"]
