#!/usr/bin/env bash
#
# lib/layers/agents.sh — the agents layer: coding-agents-kit (`ak`) at its
# pinned tag, plus Node on flavours without it, then `ak install <kind>...`.
#
#   dck-layer agents [kind...]      (rendered by `dck init` when layers.agents = true)
#
# The base images never contain a coding-agent CLI; this runs only in the
# repository's own image build. It follows coding-agents-kit's documented
# install contract (`git clone --branch <tag> … && ./install.sh`, `ak install`)
# and passes no permission-bypass flag: autonomy stays opt-in through `ak`
# (`--auto` / AGENTKIT_PERMISSIONS=auto), never a default of this layer.
# shellcheck source=lib/layers/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

KINDS="claude codex cursor opencode pi cline grok"
for k in "$@"; do
  case " $KINDS " in
    *" $k "*) ;;
    *) layer_log "unknown kind '$k' (one of: $KINDS)"; exit 2 ;;
  esac
done

# 1. Node — the npm-distributed CLIs need it; python-3.13 and debian lack it.
if ! command -v node >/dev/null 2>&1; then
  arch="$(layer_arch)"
  case "$arch" in
    amd64) node_arch=x64; node_sha="$NODE_SHA256_AMD64" ;;
    arm64) node_arch=arm64; node_sha="$NODE_SHA256_ARM64" ;;
  esac
  tarball="/tmp/node-v${NODE_VERSION}.tar.xz"
  layer_fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" "$node_sha" "$tarball"
  tar -xJf "$tarball" -C "${DCK_LAYER_PREFIX:-/usr/local}" --strip-components=1 \
    --exclude CHANGELOG.md --exclude LICENSE --exclude README.md
  rm -f "$tarball"
  corepack enable >/dev/null 2>&1 || true
  layer_log "installed Node ${NODE_VERSION}"
fi

# 2. coding-agents-kit at its pinned tag, installed for the dev user.
src="$(mktemp -d /tmp/agentkit.XXXXXX)"
# The clone runs as the dev user, so the directory must be theirs.
if [ "$(id -u)" = "0" ]; then chown "$DCK_USER" "$src"; fi
as_user env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git clone --quiet --depth 1 --branch "$AGENTKIT_TAG" https://github.com/DailybotHQ/coding-agents-kit.git "$src/coding-agents-kit"
as_user bash "$src/coding-agents-kit/install.sh"
rm -rf "$src"
layer_log "installed coding-agents-kit ${AGENTKIT_TAG}"

# 3. The CLIs the repository asked for, each through its vendor's official channel.
if [ "$#" -gt 0 ]; then
  ak_bin="$(as_user bash -lc 'command -v ak || echo "$HOME/.local/share/agentkit/bin/ak"')"
  as_user "$ak_bin" install "$@"
  layer_log "ak install $*"
fi
