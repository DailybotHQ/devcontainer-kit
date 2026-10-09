# devcontainer-kit base image — flavour node-24.
# Project runtime: Node 24 + corepack (pnpm). python3 + python3-venv from apt
# (the tooling; venv for the editor's plugins).
# Agent-free by design: no coding-agent CLI and no agent tooling (docs/images.md).
# Build from the repository root:
#   docker build -f images/node-24/Dockerfile -t dck-base:node-24 .
# Pins live in images/versions.env (the FROM defaults below must match it).

ARG BASE_NODE=node:24.21.0-trixie-slim@sha256:173f125896c3b47ddf056734c7ea789d04595a6a08769a8f78e0df642781fb66
FROM ${BASE_NODE}
ARG DCK_VERSION=0.0.0-dev
LABEL org.opencontainers.image.source="https://github.com/DailybotHQ/devcontainer-kit" \
      org.opencontainers.image.description="devcontainer-kit base image (node-24): agent-free dev container" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${DCK_VERSION}" \
      io.github.dailybothq.dck.flavour="node-24"
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY images/versions.env images/common/ /tmp/dck-build/
RUN /tmp/dck-build/install.sh node-24 python3 python3-venv
ENV PNPM_HOME=/usr/local/share/pnpm
RUN corepack enable \
    && mkdir -p "${PNPM_HOME}/bin" \
    && chown -R dev:dev "${PNPM_HOME}" \
    && node --version

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
    DCK_IMAGE_FLAVOUR=node-24 \
    DCK_IMAGE_VERSION=${DCK_VERSION}
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/dck-entrypoint"]
CMD ["sleep", "infinity"]
