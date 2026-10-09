# devcontainer-kit base image — flavour python-3.13.
# Project runtime: Python 3.13 + uv. Debian's nodejs/npm only for the editor's
# plugins; the agents layer adds the pinned Node.
# Agent-free by design: no coding-agent CLI and no agent tooling (docs/images.md).
# Build from the repository root:
#   docker build -f images/python-3.13/Dockerfile -t dck-base:python-3.13 .
# Pins live in images/versions.env (the FROM defaults below must match it).

ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.12.24@sha256:3af4716e991d6956a41e573eab705d0ee08500cd829ed30293eb8472f372c65a
ARG BASE_PYTHON=python:3.13.16-slim-trixie@sha256:bf44cdfcb76cd3b41e879bc058fc37ec5872002ccfde7fcb765e218cde0cd79c
FROM ${UV_IMAGE} AS uv
FROM ${BASE_PYTHON}
ARG DCK_VERSION=0.0.0-dev
LABEL org.opencontainers.image.source="https://github.com/DailybotHQ/devcontainer-kit" \
      org.opencontainers.image.description="devcontainer-kit base image (python-3.13): agent-free dev container" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${DCK_VERSION}" \
      io.github.dailybothq.dck.flavour="python-3.13"
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY images/versions.env images/common/ /tmp/dck-build/
RUN /tmp/dck-build/install.sh python-3.13 nodejs npm
COPY --from=uv /uv /uvx /usr/local/bin/
RUN uv --version

# The editor in its own layer: deepworkplan-vim through its official installer,
# verified and run in container mode (images/common/editor.sh, docs/images.md).
COPY images/versions.env images/common/editor.sh /tmp/dck-editor/
RUN /tmp/dck-editor/editor.sh

# Entrypoint library and the default entrypoint (docs/entrypoint.md).
COPY lib/entrypoint.sh /usr/local/lib/dck/entrypoint.sh
COPY images/common/dck-entrypoint /usr/local/bin/dck-entrypoint
# Opt-in layer installers (agents, dailybot): only scripts here, run by the
# repository's own image build when dck.toml enables them (docs/layers.md).
COPY lib/layers/ /usr/local/lib/dck/layers/
COPY images/common/dck-layer /usr/local/bin/dck-layer
RUN chmod 0644 /usr/local/lib/dck/entrypoint.sh /usr/local/lib/dck/layers/*.sh \
    && chmod 0755 /usr/local/bin/dck-entrypoint /usr/local/bin/dck-layer

ENV LANG=en_US.UTF-8 \
    EDITOR=nvim \
    VISUAL=nvim \
    GIT_EDITOR=nvim \
    DCK_IMAGE_FLAVOUR=python-3.13 \
    DCK_IMAGE_VERSION=${DCK_VERSION}
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/dck-entrypoint"]
CMD ["sleep", "infinity"]
