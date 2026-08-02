# oblaQ Pipeline Image — CUDA COLMAP (pinned) + Nerfstudio (pinned)
#
# Bakes in the fully validated build from the 26 July session:
# - Ubuntu 22.04 / GCC 11.4.0 (no ABI issues, unlike the local WSL/Ubuntu 26.04 attempt)
# - COLMAP pinned to commit fff58c71 (4.2.0.dev0), CUDA-enabled, compute capability 89 (Ada Lovelace)
# - Nerfstudio environment pinned via oblaq_requirements.txt (place alongside this Dockerfile)
#
# Build once, push to a registry, deploy on RunPod as a custom image instead of
# rebuilding from scratch on every pod. See oblaQ_Pipeline_Log.md for the
# reasoning behind each pinned choice / worked-around pitfall below.

FROM nvidia/cuda:12.4.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# --- System dependencies (full list validated 26 July, includes undocumented ones) ---
RUN apt-get update && apt-get install -y \
    git cmake ninja-build build-essential \
    libboost-program-options-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libopenimageio-dev openimageio-tools libmetis-dev \
    libgoogle-glog-dev libgtest-dev libgmock-dev libsqlite3-dev libglew-dev \
    qtbase5-dev libqt5opengl5-dev libcgal-dev libceres-dev \
    libqt5svg5-dev libopencv-dev \
    python3 python3-venv python3-pip \
    wget \
    && rm -rf /var/lib/apt/lists/*

# --- CMake fix: apt's 3.22.1 is too old for COLMAP's bundled faiss (needs 3.24+).
#     pip install --upgrade cmake produced a broken CMAKE_ROOT wrapper in testing -
#     use the official prebuilt binary instead. ---
RUN cd /tmp && \
    wget https://github.com/Kitware/CMake/releases/download/v3.29.0/cmake-3.29.0-linux-x86_64.tar.gz && \
    tar -xzf cmake-3.29.0-linux-x86_64.tar.gz && \
    mv cmake-3.29.0-linux-x86_64 /opt/cmake-3.29.0 && \
    rm cmake-3.29.0-linux-x86_64.tar.gz
ENV PATH="/opt/cmake-3.29.0/bin:${PATH}"

# --- COLMAP: pinned commit, CUDA enabled, explicit compute capability.
#     -DCMAKE_CUDA_ARCHITECTURES=native fails in containerized environments
#     ("nvcc fatal: Unsupported gpu architecture 'compute_'") even with a real
#     GPU present at runtime - use the explicit number instead. 89 = Ada
#     Lovelace (RTX 2000 Ada, RTX 4000 Ada, RTX 40-series consumer cards).
#     Update this if targeting a different GPU generation. ---
RUN cd /root && \
    git clone https://github.com/colmap/colmap.git && \
    cd colmap && \
    git checkout fff58c71 && \
    mkdir build && cd build && \
    cmake .. -GNinja -DCUDA_ENABLED=ON -DCMAKE_CUDA_ARCHITECTURES=89 && \
    ninja -j2 && \
    ninja install

# Verify the build actually has CUDA enabled - fail the image build loudly if not,
# rather than silently shipping a CPU-only binary.
RUN colmap -h | grep -q "with CUDA" || (echo "COLMAP built WITHOUT CUDA - check base image / build args" && exit 1)

# --- Nerfstudio: pinned Python environment ---
# Place oblaq_requirements.txt in the same folder as this Dockerfile before building.
WORKDIR /root
RUN python3 -m venv /root/nerfstudio-env
COPY oblaq_requirements.txt /root/oblaq_requirements.txt
RUN /root/nerfstudio-env/bin/pip install --upgrade pip && \
    /root/nerfstudio-env/bin/pip install -r /root/oblaq_requirements.txt

# Activate the venv automatically in interactive shells
RUN echo "source /root/nerfstudio-env/bin/activate" >> /root/.bashrc

# --- tmux, for protecting long-running work from SSH disconnects ---
RUN apt-get update && apt-get install -y tmux && rm -rf /var/lib/apt/lists/*

WORKDIR /root
CMD ["/bin/bash"]
