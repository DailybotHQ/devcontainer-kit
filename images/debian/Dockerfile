# devcontainer-kit base image — flavour debian.
# No project runtime. python3 from apt for the tooling.
# Agent-free by design: no coding-agent CLI and no agent tooling (docs/images.md).
# Build from the repository root:
#   docker build -f images/debian/Dockerfile -t dck-base:debian .
# Pins live in images/versions.env (the FROM defaults below must match it).

ARG BASE_DEBIAN=debian:trixie-20261005-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f
FROM ${BASE_DEBIAN}
ARG DCK_VERSION=0.0.0-dev
LABEL org.opencontainers.image.source="https://github.com/DailybotHQ/devcontainer-kit" \
      org.opencontainers.image.description="devcontainer-kit base image (debian): agent-free dev container" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${DCK_VERSION}" \
      io.github.dailybothq.dck.flavour="debian"
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY images/versions.env images/common/ /tmp/dck-build/
RUN /tmp/dck-build/install.sh debian python3

# Entrypoint library and the default entrypoint (docs/entrypoint.md).
COPY lib/entrypoint.sh /usr/local/lib/dck/entrypoint.sh
COPY images/common/dck-entrypoint /usr/local/bin/dck-entrypoint
RUN chmod 0644 /usr/local/lib/dck/entrypoint.sh && chmod 0755 /usr/local/bin/dck-entrypoint

ENV LANG=en_US.UTF-8 \
    EDITOR=nvim \
    VISUAL=nvim \
    GIT_EDITOR=nvim \
    DCK_IMAGE_FLAVOUR=debian \
    DCK_IMAGE_VERSION=${DCK_VERSION}
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/dck-entrypoint"]
CMD ["sleep", "infinity"]
