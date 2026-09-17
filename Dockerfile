# digital-me AutoDL 服务镜像（可选路线 B；权重不进镜像——首次启动由 breeze 节点
# download_if_missing 自动经 hf-mirror 下载，或手动跑仓库 install.sh 第 4 步预下载）。
# 构建产物 ≈ 12GB（PyTorch cu128 + ComfyUI + 两节点依赖）。
FROM nvidia/cuda:12.8.1-cudnn9-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    HF_ENDPOINT=https://hf-mirror.com \
    COMFYUI_DIR=/root/ComfyUI

RUN apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends python3 python3-pip git ffmpeg nginx curl openssl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir torch==2.7.1 torchaudio==2.7.1 --index-url https://download.pytorch.org/whl/cu128

RUN git clone --depth 1 https://github.com/comfyanonymous/ComfyUI /root/ComfyUI && \
    git clone --depth 1 https://github.com/HM-RunningHub/ComfyUI_RH_FlashHead /root/ComfyUI/custom_nodes/ComfyUI_RH_FlashHead && \
    git clone --depth 1 https://github.com/Saganaki22/ComfyUI-Breeze-TTS-2 /root/ComfyUI/custom_nodes/ComfyUI-Breeze-TTS-2 && \
    pip3 install --no-cache-dir -r /root/ComfyUI/custom_nodes/ComfyUI_RH_FlashHead/requirements.txt && \
    pip3 install --no-cache-dir -r /root/ComfyUI/custom_nodes/ComfyUI-Breeze-TTS-2/requirements.txt && \
    pip3 install --no-cache-dir "huggingface_hub[cli]"

COPY bootstrap.sh docker-entrypoint.sh nginx-comfyui.conf /root/
COPY smoke/ /root/smoke/
RUN chmod +x /root/bootstrap.sh /root/docker-entrypoint.sh /root/smoke/smoke.sh

EXPOSE 6006
ENTRYPOINT ["bash", "/root/docker-entrypoint.sh"]
