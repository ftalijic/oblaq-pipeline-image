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

# oblaQ Pipeline Image — CUDA COLMAP (pinned) + Nerfstudio (pinned)
#
# Multi-stage build: a "builder" stage compiles COLMAP from source (which
# generates a lot of intermediate object files / source tree bulk), then a
# clean final stage copies over only the finished, installed results -
# discarding the intermediate build bulk. This avoids exhausting the disk
# space available on GitHub Actions' free-tier runners (~14GB usable),
# which a single-stage build filled up before ninja install could complete.
#
# Bakes in the fully validated build from the 26 July session:
# - Ubuntu 22.04 / GCC 11.4.0 (no ABI issues, unlike the local WSL/Ubuntu 26.04 attempt)
# - COLMAP pinned to commit fff58c71 (4.2.0.dev0), CUDA-enabled, compute capability 89 (Ada Lovelace)
# - Nerfstudio environment pinned via oblaq_requirements.txt (place alongside this Dockerfile)

# ============================================================
# STAGE 1: builder — compiles COLMAP, discarded after this stage
# ============================================================
FROM nvidia/cuda:12.4.1-devel-ubuntu22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    git cmake ninja-build build-essential \
    libboost-program-options-dev libboost-graph-dev libboost-system-dev \
    libeigen3-dev libopenimageio-dev openimageio-tools libmetis-dev \
    libgoogle-glog-dev libgtest-dev libgmock-dev libsqlite3-dev libglew-dev \
    qtbase5-dev libqt5opengl5-dev libcgal-dev libceres-dev \
    libqt5svg5-dev libopencv-dev \
    wget \
    && rm -rf /var/lib/apt/lists/*

# CMake fix: apt's 3.22.1 is too old for COLMAP's bundled faiss (needs 3.24+).
RUN cd /tmp && \
    wget https://github.com/Kitware/CMake/releases/download/v3.29.0/cmake-3.29.0-linux-x86_64.tar.gz && \
    tar -xzf cmake-3.29.0-linux-x86_64.tar.gz && \
    mv cmake-3.29.0-linux-x86_64 /opt/cmake-3.29.0 && \
    rm cmake-3.29.0-linux-x86_64.tar.gz
ENV PATH="/opt/cmake-3.29.0/bin:${PATH}"

# COLMAP: pinned commit, CUDA enabled, explicit compute capability (89 = Ada
# Lovelace). Install to /opt/colmap-install instead of the default /usr/local,
# so Stage 2 can cleanly copy just that one self-contained folder.
RUN cd /root && \
    git clone https://github.com/colmap/colmap.git && \
    cd colmap && \
    git checkout fff58c71 && \
    mkdir build && cd build && \
    cmake .. -GNinja -DCUDA_ENABLED=ON -DCMAKE_CUDA_ARCHITECTURES=89 -DCMAKE_INSTALL_PREFIX=/opt/colmap-install && \
    ninja -j2 && \
    ninja install && \
    rm -rf /root/colmap  # discard source + object files now that install is done

# ============================================================
# STAGE 2: final — clean image, only the finished COLMAP install + Nerfstudio
# ============================================================
FROM nvidia/cuda:12.4.1-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive

# Runtime libraries COLMAP's compiled binary needs. Reusing the same -dev
# package names proven to work in Stage 1 (rather than guessing minimal
# runtime-only package names, which failed on libcgal13 not existing -
# CGAL is header-only in this build and needs no runtime package at all).
RUN apt-get update && apt-get install -y \
    libboost-program-options-dev libboost-graph-dev libboost-system-dev \
    libopenimageio-dev libmetis-dev \
    libgoogle-glog-dev libsqlite3-dev libglew-dev \
    qtbase5-dev libqt5opengl5-dev libqt5svg5-dev \
    libceres-dev libopencv-dev \
    python3 python3-venv python3-pip \
    tmux \
    && rm -rf /var/lib/apt/lists/*

# Copy only the finished COLMAP install from the builder stage
COPY --from=builder /opt/colmap-install /opt/colmap-install
ENV PATH="/opt/colmap-install/bin:${PATH}"

RUN colmap -h | grep -q "with CUDA" || (echo "COLMAP built WITHOUT CUDA - check base image / build args" && exit 1)

# --- Nerfstudio: pinned Python environment ---
WORKDIR /root
RUN python3 -m venv /root/nerfstudio-env
COPY oblaq_requirements.txt /root/oblaq_requirements.txt
RUN /root/nerfstudio-env/bin/pip install --upgrade pip && \
    /root/nerfstudio-env/bin/pip install -r /root/oblaq_requirements.txt

RUN echo "source /root/nerfstudio-env/bin/activate" >> /root/.bashrc

WORKDIR /root
CMD ["/bin/bash"]

