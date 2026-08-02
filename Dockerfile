# oblaQ Pipeline Image — Nerfstudio layer on top of the COLMAP base
#
# Starts FROM the already-built, already-pushed oblaq-colmap-base image
# instead of recompiling COLMAP every time. This should rebuild in roughly
# the time it takes to install the pip requirements - minutes, not the
# 30-40+ minute COLMAP compile - since Docker Hub pulls the base layers
# rather than rebuilding them.
#
# IMPORTANT: update the FROM line below to your actual Docker Hub username
# once Dockerfile.colmap-base has been built and pushed successfully.

FROM dakord/oblaq-colmap-base:latest

ENV DEBIAN_FRONTEND=noninteractive

# Python 3.11 via deadsnakes - Ubuntu 22.04 ships 3.10 by default, but the
# pinned oblaq_requirements.txt was generated under 3.11 on the original pod
# (some pinned packages, e.g. av==18.0.0, require 3.11+).
RUN apt-get update && apt-get install -y software-properties-common && \
    add-apt-repository ppa:deadsnakes/ppa -y && \
    apt-get update && \
    apt-get install -y python3.11 python3.11-venv python3.11-distutils && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /root
RUN python3.11 -m venv /root/nerfstudio-env
COPY oblaq_requirements.txt /root/oblaq_requirements.txt
RUN /root/nerfstudio-env/bin/pip install --upgrade pip && \
    /root/nerfstudio-env/bin/pip install -r /root/oblaq_requirements.txt --extra-index-url https://download.pytorch.org/whl/cu128

RUN echo "source /root/nerfstudio-env/bin/activate" >> /root/.bashrc

WORKDIR /root
CMD ["/bin/bash"]
