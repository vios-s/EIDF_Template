# syntax=docker/dockerfile:1
###############################################################################
# vLLM serving image for the EIDF GPU Service  ——  GROUP TEMPLATE (eidf105)
#
# Base image already ships Python 3.12 + CUDA runtime + vLLM, so this file
# only adds (a) a few CLI conveniences and (b) a non-root user whose uid/gid
# MATCHES your EIDF account, so files written to the shared NFS get the right
# ownership. Find your values on the EIDF login VM with:  id
#
# Build (per user):
#   docker login registry.eidf.ac.uk     # SAFE username + CLI Secret
#   docker build \
#     --build-arg USERNAME=<you> \
#     --build-arg USER_ID=<uid> \
#     --build-arg GROUP_ID=<gid> \
#     -t registry.eidf.ac.uk/eidf105/vllm-eidf:latest .
#
#   docker push registry.eidf.ac.uk/eidf105/vllm-eidf:latest
#
# See build.sh (repo root) for a one-liner and README.md for the full workflow.
###############################################################################
# Pinned, like the CUDA and PyTorch_Docker bases are. vLLM makes breaking CLI
# and config changes between minor releases, so `:latest` silently moves the
# ground under a rebuild. Check for newer tags with:
#   curl -s 'https://hub.docker.com/v2/repositories/vllm/vllm-openai/tags/?page_size=25&ordering=last_updated' \
#     | jq -r '.results[].name'
# and bump this line when you actually intend to move.
FROM registry.eidf.ac.uk/docker-cache/vllm/vllm-openai:v0.26.0

LABEL maintainer="EIDF eidf105 group"
LABEL description="vLLM OpenAI-compatible server for the EIDF GPU service"

ENV DEBIAN_FRONTEND=noninteractive

# --- Minimal, useful CLI tooling (single layer) ------------------------------
# NOTE: intentionally NO conda / venv / node here. The base image installs
# vLLM into the system Python; creating another environment on top of it only
# shadows that interpreter and breaks `vllm serve`.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git git-lfs curl wget ca-certificates \
       screen tmux htop nvtop nano vim-tiny less \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir hf-xet

# --- Non-root user matching the EIDF NFS uid/gid -----------------------------
ARG USERNAME=vllm
ARG USER_ID=1000
ARG GROUP_ID=1000
RUN existing_user="$(getent passwd ${USER_ID} | cut -d: -f1)"; \
    if [ -n "$existing_user" ] && [ "$existing_user" != "${USERNAME}" ]; then \
        userdel -r "$existing_user" 2>/dev/null || userdel -f "$existing_user" 2>/dev/null || true; \
    fi \
    && if ! getent group ${GROUP_ID} >/dev/null; then \
        groupadd -g ${GROUP_ID} ${USERNAME}; \
    fi \
    && if getent passwd ${USERNAME} >/dev/null; then \
        usermod -u ${USER_ID} -g ${GROUP_ID} -d /home/${USERNAME} -m ${USERNAME}; \
    else \
        useradd -m -u ${USER_ID} -g ${GROUP_ID} -s /bin/bash ${USERNAME}; \
    fi \
    && mkdir -p /home/${USERNAME} \
    && chown -R ${USER_ID}:${GROUP_ID} /home/${USERNAME}

ENV HOME=/home/${USERNAME}

# HF / torch caches default to $HOME here; the Job overrides HF_HOME to a path
# on the mounted NFS so downloaded weights persist and are shared across runs
# instead of bloating the ephemeral container layer.
# hf-xet is the current fast-transfer backend (hf_transfer / HF_HUB_ENABLE_HF_TRANSFER
# is deprecated). HF_XET_HIGH_PERFORMANCE saturates network/CPU for downloads.
ENV HF_HOME=/home/${USERNAME}/.cache/huggingface \
    HF_XET_HIGH_PERFORMANCE=1 \
    TORCH_HOME=/home/${USERNAME}/.cache/torch

USER ${USERNAME}
WORKDIR /home/${USERNAME}

# vLLM OpenAI-compatible server default port
EXPOSE 8000

# No CMD/ENTRYPOINT override: the Kubernetes Job supplies the full
# `vllm serve ...` command so the model and flags stay configurable per run.
#
# FOOTGUN, inherited from the base image, which sets
# ENTRYPOINT ["vllm", "serve"]:
#   docker run <image> bash        # does NOT give you a shell
# It appends "bash" as an argument to `vllm serve` and dies with a completely
# unrelated-looking "RuntimeError: Failed to infer device type". To get a shell
# locally you must override the entrypoint:
#   docker run --rm -it --entrypoint /bin/bash <image>
# Kubernetes is unaffected: a pod spec's `command:` replaces ENTRYPOINT outright,
# and both Job yamls here set it explicitly.
