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
