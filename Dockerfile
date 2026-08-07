# oblaQ Pipeline Image — Nerfstudio layer on top of the COLMAP base
#
# Starts FROM the already-built, already-pushed oblaq-colmap-base image
# instead of recompiling COLMAP every time. This should rebuild in roughly
# the time it takes to install the pip requirements - minutes, not the
# 30-40+ minute COLMAP compile - since Docker Hub pulls the base layers
# rather than rebuilding them.
 
FROM dakord/oblaq-colmap-base:latest
 
ENV DEBIAN_FRONTEND=noninteractive
 
# Python 3.11 via deadsnakes - Ubuntu 22.04 ships 3.10 by default, but the
# pinned oblaq_requirements.txt was generated under 3.11 on the original pod
# (some pinned packages, e.g. av==18.0.0, require 3.11+).
# build-essential + python3.11-dev: the base COLMAP image deliberately has no
# compiler (COLMAP itself was already compiled in an earlier stage), but a
# few pinned Python packages (fpsample, pyliblzfse) have no prebuilt wheel
# for this platform and need to compile a small C extension during install.
# openssh-server: NOT included in the base image or by default - RunPod's own
# stock templates bundle SSH access automatically, a custom image needs it
# added explicitly, confirmed missing when "Connection refused" occurred on
# first deploy test.
RUN apt-get update && apt-get install -y software-properties-common build-essential openssh-server && \
    add-apt-repository ppa:deadsnakes/ppa -y && \
    apt-get update && \
    apt-get install -y python3.11 python3.11-venv python3.11-distutils python3.11-dev && \
    rm -rf /var/lib/apt/lists/*
 
WORKDIR /root
RUN python3.11 -m venv /root/nerfstudio-env
COPY oblaq_requirements.txt /root/oblaq_requirements.txt
RUN /root/nerfstudio-env/bin/pip install --upgrade pip && \
    /root/nerfstudio-env/bin/pip install -r /root/oblaq_requirements.txt --extra-index-url https://download.pytorch.org/whl/cu128
 
RUN echo "source /root/nerfstudio-env/bin/activate" >> /root/.bashrc
 
# COLMAP PATH fix: installed to /opt/colmap-install/bin by the base image
# but not in the default PATH — add it permanently so 'colmap' works without
# manual export every session.
RUN echo 'export PATH="/opt/colmap-install/bin:$PATH"' >> /root/.bashrc
 
# ffmpeg: required by ns-process-data for image/video handling.
# Not included in the base image, confirmed missing during first real pipeline run.
RUN apt-get update && apt-get install -y ffmpeg && rm -rf /var/lib/apt/lists/*
 
# Nerfstudio camera model 17 patch: Nerfstudio's pinned COLMAP parser doesn't
# include model ID 17 (EQUIRECTANGULAR), causing a KeyError if COLMAP was run
# with --ImageReader.camera_model EQUIRECTANGULAR. Adding it for robustness
# even though the current pipeline uses SIMPLE_RADIAL (the default).
RUN sed -i 's/CameraModel(model_id=10, model_name="THIN_PRISM_FISHEYE", num_params=12),/CameraModel(model_id=10, model_name="THIN_PRISM_FISHEYE", num_params=12),\n    CameraModel(model_id=17, model_name="EQUIRECTANGULAR", num_params=2),/' \
    /root/nerfstudio-env/lib/python3.11/site-packages/nerfstudio/data/utils/colmap_parsing_utils.py
 
# Nerfstudio internal COLMAP flag-rename patch: ns-process-data calls COLMAP
# internally using OLD flag names (--SiftExtraction.use_gpu / --SiftMatching.use_gpu)
# that don't exist in COLMAP 4.x (renamed to --FeatureExtraction.use_gpu /
# --FeatureMatching.use_gpu). Without this, ns-process-data fails immediately
# but LOOKS like a silent stall (0% CPU, no visible error) - cost ~1 hour of
# confused debugging before the real cause was found. Different file from the
# camera model patch above.
RUN sed -i 's/--SiftExtraction.use_gpu/--FeatureExtraction.use_gpu/' \
    /root/nerfstudio-env/lib/python3.11/site-packages/nerfstudio/process_data/colmap_utils.py && \
    sed -i 's/--SiftMatching.use_gpu/--FeatureMatching.use_gpu/' \
    /root/nerfstudio-env/lib/python3.11/site-packages/nerfstudio/process_data/colmap_utils.py
 
# nvcc for gsplat: gsplat (Nerfstudio's Gaussian Splatting rasterizer)
# JIT-compiles its CUDA kernel on first use. The base image's final stage is
# CUDA runtime-only (no compiler) - without this, ns-train crashes with
# AttributeError: 'NoneType' object has no attribute 'CameraModelType'.
# Note: the cuda-toolkit-12-4 metapackage does NOT actually install nvcc -
# confirmed missing after installing it. These two specific packages are needed.
RUN apt-get update && apt-get install -y cuda-nvcc-12-4 cuda-compiler-12-4 sqlite3 && \
    rm -rf /var/lib/apt/lists/*
ENV PATH="/usr/local/cuda-12.4/bin:${PATH}"
 
# gsplat CUDA compilation default: even with nvcc present, default parallel
# compilation can get OOM-killed on specific files (exit code 137) despite
# plenty of system RAM - a per-process memory spike issue during ninja's
# default job count, not genuine RAM exhaustion. Confirmed fix: limit to 2.
ENV MAX_JOBS=2
 
# gsplat AOT (ahead-of-time) precompilation: gsplat supports building its
# CUDA extension during pip install instead of waiting for JIT compilation
# on first ns-train run. Doing this at IMAGE BUILD time (not on a live,
# billing pod) eliminates: the ~5-10 min first-run wait, the OOM risk
# happening mid-client-job, and needing nvcc present in the final runtime
# image at all (though we keep it above for JIT fallback safety anyway).
#
# TORCH_CUDA_ARCH_LIST must be set explicitly - without it, building in
# GitHub Actions (which has NO GPU present) can silently target the wrong
# architecture or fail. 8.6=Ampere (A100/A40/3090), 8.9=Ada Lovelace
# (RTX 4090/4000 Ada) - matches the same architectures targeted for COLMAP.
ENV TORCH_CUDA_ARCH_LIST="8.6;8.9"
RUN /root/nerfstudio-env/bin/pip uninstall gsplat -y && \
    /root/nerfstudio-env/bin/pip install --no-binary gsplat --no-build-isolation gsplat==1.4.0 2>&1 | tee /tmp/gsplat_build_log.txt && \
    /root/nerfstudio-env/bin/python3 -c "from gsplat.cuda._backend import _C; assert _C is not None, 'gsplat CUDA extension failed to build'" || \
    (echo "BUILD FAILED: gsplat CUDA extension did not build correctly. Check /tmp/gsplat_build_log.txt" && exit 1)
 
# prepare_nerfstudio_masks.py: converts COLMAP-convention masks
# (frame_0001.jpg.png) to Nerfstudio-convention (frame_0001.png in a masks/
# subfolder). Was missing from the image, had to be rewritten from scratch
# and manually uploaded during a live session - baking it in now.
COPY prepare_nerfstudio_masks.py /root/prepare_nerfstudio_masks.py
 
# --- SSH setup ---
# RunPod injects the pod's authorized public key via a $PUBLIC_KEY environment
# variable at container start (same convention their own stock templates
# rely on) - this needs to be written into authorized_keys ourselves, since
# a custom image doesn't get that handled automatically. Host keys also need
# generating fresh (sshd refuses to start without them). This all has to
# happen at container START (not build time), since $PUBLIC_KEY is only set
# when the pod actually launches - hence a startup script as the image's
# entrypoint, rather than doing this as a RUN step during the build.
RUN mkdir -p /var/run/sshd && \
    mkdir -p /root/.ssh && chmod 700 /root/.ssh && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
 
COPY start.sh /root/start.sh
RUN chmod +x /root/start.sh
 
WORKDIR /root
ENTRYPOINT ["/root/start.sh"]
 
