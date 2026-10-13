# shellcheck shell=bash
# Scope: layers — the opt-in agents/dailybot/editor layers in the template,
# the layer installers (lib/layers/) and their runtime persistence.

DCK="$DCK_REPO/bin/dck"
LFIX="$TESTS_DIR/fixtures/layers"
use_fakes
export DCK_NONINTERACTIVE=1 DCK_NO_DIGEST=1

REPO="$SANDBOX/proj"
render() {
  mkdir -p "$REPO"
  [ -d "$REPO/.git" ] || git -C "$REPO" init -q
  run_cmd "$DCK" init --repo "$REPO" --no-herdr --yes "$@"
}
compose() { cat "$REPO/docker/local/docker-compose.yaml"; }
dockerfile() { cat "$REPO/docker/local/app/Dockerfile"; }

test_off_by_default() {
  render --flavour node-24
  assert_rc 0 "init renders"
  assert_not_contains "$(sed -n '/>>> dck:layers >>>/,/<<< dck:layers <<</p' "$REPO/docker/local/app/Dockerfile")" "dck-layer" "the Dockerfile has no layer by default"
  assert_contains "$(dockerfile)" "No opt-in layer is enabled" "the layers block says so"
  assert_not_contains "$(compose)" "DCK_AGENTS" "no agents environment by default"
  assert_not_contains "$(compose)" "AGENTKIT" "no coding-agents-kit setting by default"
  assert_not_contains "$(compose)" "DCK_AGENT_CLIS" "no agent CLI build arg by default"
  assert_eq "$(sed -n '/>>> dck:volumes >>>/,/<<< dck:volumes <<</p' "$REPO/docker/local/docker-compose.yaml" | grep -c ': {}')" "1" "only the state volume is declared"
  assert_contains "$(cat "$REPO/.devcontainer/dck.toml")" "agents = false" "dck.toml records the layer off"
}

test_agents_layer_enabled() {
  # The default mode: wire and install the CLIs chosen at onboarding (clis).
  render --flavour node-24 --agents --clis "claude codex"
  assert_rc 0 "init renders with the agents layer"
  local d c
  d="$(dockerfile)"; c="$(compose)"
  assert_contains "$d" 'ARG DCK_AGENT_CLIS="claude codex"' "the requested kinds reach the build"
  assert_contains "$d" 'RUN DCK_USER=dev DCK_AGENT_SUPPORTED="claude codex" DCK_AGENT_PRESETS="" dck-layer agents ${DCK_AGENT_CLIS}' "the Dockerfile runs the agents layer installer (a new render: no ak preset), wired for the chosen CLIs"
  assert_contains "$d" 'ARG INSTALL_CODEX_CLI=false' "the INSTALL_<CLI>_CLI convention reaches the build"
  assert_not_contains "$d" 'INSTALL_GROK_CLI' "only for the wired CLIs"
  assert_contains "$c" 'DCK_AGENTS: "claude codex"' "the entrypoint wires the chosen kinds"
  assert_contains "$c" 'DCK_AGENT_CLIS: "${DCK_AGENT_CLIS:-claude codex}"' "the build arg defaults to dck.toml's list and takes DCK_AGENT_CLIS"
  assert_contains "$c" 'INSTALL_CLAUDE_CLI: "${INSTALL_CLAUDE_CLI:-false}"' "each INSTALL_<CLI>_CLI is a build arg, false by default"
  assert_eq "$(printf '%s\n' "$c" | grep -c 'args:')" "1" "one build args block"
  assert_contains "$c" "AGENTKIT_PROFILES_DIR: /home/dev/.dck/volumes/agentkit/profiles" "ak profiles live on the agentkit volume"
  local v
  for v in agentkit claude codex; do
    assert_contains "$c" "      - $v:/home/dev/.dck/volumes/$v" "volume $v is mounted"
    assert_contains "$c" "  $v: {}" "volume $v is declared (per compose project)"
  done
  assert_not_contains "$c" "  cursor: {}" "a CLI not chosen gets no volume (the default mode)"
  assert_contains "$(cat "$REPO/docker/local/.env.example")" "wires only the CLIs chosen at onboarding" "docker/local/.env.example explains the default mode"
  assert_no_match "$d$c" '--dangerously|--yolo|--always-approve|--force' "the template spells no CLI autonomy flag (they live in coding-agents-kit)"
  assert_contains "$c" "set AGENTKIT_PERMISSIONS=ask in ./app/.env" "compose documents the opt-out (through the service .env)"
  assert_no_match "$c" '^[[:space:]]*#[[:space:]]*AGENTKIT_PERMISSIONS=' "no commented line that would be invalid YAML when uncommented"
  assert_no_match "$c" '^[[:space:]]+AGENTKIT_PERMISSIONS:' "compose sets no permission posture (ak's default, autonomy)"
  local t; t="$(cat "$REPO/.devcontainer/dck.toml")"
  assert_contains "$t" "agents = true" "dck.toml records the layer on"
  assert_contains "$t" 'clis = ["claude", "codex"]' "dck.toml records the kinds"
  assert_no_match "$t" '^supported' "the default mode writes no supported key"
  assert_contains "$t" '# Advanced: supported = "all"' "and names the advanced mode"
}

test_agents_layer_advanced_mode() {
  # The advanced opt-in: wire every CLI, each developer chooses what to install.
  render --flavour node-24 --agents --clis "" --supported all
  assert_rc 0 "init --supported all renders"
  local d c v
  d="$(dockerfile)"; c="$(compose)"
  assert_contains "$d" 'DCK_AGENT_SUPPORTED="claude codex cursor opencode pi cline grok antigravity"' "the layer accepts every kind"
  assert_contains "$d" 'ARG INSTALL_GROK_CLI=false' "every INSTALL_<CLI>_CLI reaches the build"
  assert_contains "$c" 'DCK_AGENTS: "claude codex cursor opencode pi cline grok antigravity"' "the entrypoint wires every kind"
  assert_contains "$c" 'DCK_AGENT_CLIS: "${DCK_AGENT_CLIS:-}"' "nothing installed by default (clis = [])"
  assert_contains "$c" 'INSTALL_CURSOR_CLI: "${INSTALL_CURSOR_CLI:-false}"' "a developer turns one on in docker/local/.env"
  for v in claude codex cursor opencode pi cline grok antigravity; do
    assert_contains "$c" "      - $v:/home/dev/.dck/volumes/$v" "volume $v is mounted (installed or not)"
  done
  assert_contains "$(cat "$REPO/docker/local/.env.example")" "# INSTALL_OPENCODE_CLI=false" "docker/local/.env.example lists each developer's options"
  assert_contains "$(cat "$REPO/.devcontainer/dck.toml")" 'supported = "all"' "dck.toml records the advanced mode"
  render --flavour node-24 --agents --clis "claude" --supported "claude codex"
  assert_rc 0 "a supported list renders"
  c="$(compose)"
  assert_not_contains "$c" "  cursor: {}" "an unsupported kind gets no volume"
  assert_not_contains "$c" "INSTALL_CURSOR_CLI" "nor an INSTALL arg"
  assert_contains "$c" "      - codex:/home/dev/.dck/volumes/codex" "a supported CLI not installed by default is wired"
  assert_contains "$(cat "$REPO/.devcontainer/dck.toml")" 'supported = ["claude", "codex"]' "dck.toml records the list"
}

test_agents_layer_toggles_off_cleanly() {
  render --flavour node-24 --agents --clis "claude"
  printf 'RUN echo mine\n' >> "$REPO/docker/local/app/Dockerfile"
  render --no-agents --clis ""
  assert_rc 0 "turning the layer off reconciles"
  assert_not_contains "$(dockerfile)" "dck-layer agents" "the layer is removed from the Dockerfile"
  assert_contains "$(dockerfile)" "RUN echo mine" "the project's own layers are kept"
  assert_not_contains "$(compose)" "claude" "the CLI volume is removed from compose"
  assert_not_contains "$(compose)" "DCK_AGENTS" "the agents environment is removed"
}

test_agents_layer_on_python_flavour() {
  render --flavour python-3.13 --agents --clis "pi"
  assert_contains "$(dockerfile)" "dck-layer agents" "the python flavour gets the same layer (it adds Node)"
  assert_contains "$(cat "$DCK_REPO/lib/layers/agents.sh")" '[ "$node_major" -lt "${NODE_VERSION%%.*}" ]' "the installer adds Node when the flavour lacks a current one"
}

# run_layer <layer> [args] — run an installer as the current user, offline.
run_layer() {
  local layer="$1"; shift
  run_cmd env DCK_VERSIONS="$DCK_REPO/images/versions.env" DCK_USER="$(id -un)" \
    DCK_SKILLS_DIR="$SANDBOX/skills" DCK_LAYER_PREFIX="$SANDBOX/prefix" DCK_LAYER_TOOL_DIR="$SANDBOX/tools" DCK_LAYER_BIN_DIR="$SANDBOX/toolbin" \
    PATH="$LFIX/bin:$EXTRA_PATH$PATH" bash "$DCK_REPO/lib/layers/$layer.sh" "$@"
}

# agentkit_fixture — a fake coding-agents-kit release tarball and a versions.env
# whose AGENTKIT_SHA256 is that tarball's digest; the fake curl serves it.
agentkit_fixture() {
  local tag dir
  tag="$(sed -n 's/^AGENTKIT_TAG=//p' "$DCK_REPO/images/versions.env")"
  dir="$SANDBOX/akrel/coding-agents-kit-$tag"
  mkdir -p "$dir"
  cat > "$dir/install.sh" <<'SH'
#!/usr/bin/env bash
printf 'install.sh %s\n' "$*" >> "${DCK_FAKE_LOG:-/dev/null}"
mkdir -p "$HOME/.local/share/agentkit/bin"
printf '#!/usr/bin/env bash\nprintf "ak %%s npm_prefix=%%s\\n" "$*" "${NPM_CONFIG_PREFIX:-}" >> "${DCK_FAKE_LOG:-/dev/null}"\n' > "$HOME/.local/share/agentkit/bin/ak"
chmod +x "$HOME/.local/share/agentkit/bin/ak"
SH
  local skill
  for skill in agentkit agentkit-setup agentkit-orchestrate; do
    mkdir -p "$dir/skills/$skill/references"
    printf -- '---\nname: %s\n---\n' "$skill" > "$dir/skills/$skill/SKILL.md"
    printf 'ref\n' > "$dir/skills/$skill/references/r.md"
  done
  tar -czf "$SANDBOX/akrel/agentkit.tar.gz" -C "$SANDBOX/akrel" "coding-agents-kit-$tag"
  sed "s/^AGENTKIT_SHA256=.*/AGENTKIT_SHA256=$(shasum -a 256 "$SANDBOX/akrel/agentkit.tar.gz" | cut -d' ' -f1)/" \
    "$DCK_REPO/images/versions.env" > "$SANDBOX/akrel/versions.env"
}

test_agents_installer_follows_the_kit_contract() {
  EXTRA_PATH="$LFIX/nodebin:"
  agentkit_fixture
  run_cmd env DCK_VERSIONS="$SANDBOX/akrel/versions.env" DCK_USER="$(id -un)" FAKE_CURL_FILE="$SANDBOX/akrel/agentkit.tar.gz" \
    DCK_SKILLS_DIR="$SANDBOX/skills" DCK_LAYER_PREFIX="$SANDBOX/prefix" PATH="$LFIX/bin:$EXTRA_PATH$PATH" bash "$DCK_REPO/lib/layers/agents.sh" claude codex
  assert_rc 0 "the agents installer runs"
  local tag; tag="$(sed -n 's/^AGENTKIT_TAG=//p' "$DCK_REPO/images/versions.env")"
  assert_contains "$(fake_calls curl)" "https://github.com/DailybotHQ/coding-agents-kit/releases/download/$tag/coding-agents-kit-$tag.tar.gz" "coding-agents-kit comes from its pinned release tarball"
  assert_eq "$(fake_calls git | grep "^git clone " || true)" "" "nothing is cloned"
  assert_contains "$(fake_calls install.sh)" "install.sh --no-rc" "the kit's own install.sh runs without touching rc files"
  assert_contains "$(fake_calls ak)" "ak alias preset classic --on" "the classic preset is on"
  assert_contains "$(fake_calls ak)" "ak alias preset providers --on" "the providers preset is on"
  assert_contains "$(cat "$HOME/.bashrc")" '.local/share/agentkit/aliases.sh' "bash loads the presets"
  assert_contains "$(fake_calls ak)" "ak install claude codex npm_prefix=$HOME/.local" "ak installs exactly the requested kinds, npm globals into ~/.local"
  assert_eq "$(cat "$HOME/.npmrc")" "prefix=$HOME/.local" "the dev user's npm prefix is ~/.local (Node's prefix is root's)"
  local skill
  for skill in agentkit agentkit-setup agentkit-orchestrate; do
    assert_file "$SANDBOX/skills/$skill/SKILL.md" "the kit's $skill skill lands in the shared skills directory"
    assert_file "$SANDBOX/skills/$skill/references/r.md" "with its references ($skill)"
  done
  assert_contains "$RUN_ERR" "its skills agentkit, agentkit-setup, agentkit-orchestrate" "the skills are reported"
  : > "$DCK_FAKE_LOG"
  run_cmd env DCK_VERSIONS="$SANDBOX/akrel/versions.env" DCK_USER="$(id -un)" FAKE_CURL_FILE="$SANDBOX/akrel/agentkit.tar.gz" \
    DCK_SKILLS_DIR="$SANDBOX/skills" DCK_LAYER_PREFIX="$SANDBOX/prefix" PATH="$LFIX/bin:$EXTRA_PATH$PATH" bash "$DCK_REPO/lib/layers/agents.sh" claude
  assert_eq "$(cat "$SANDBOX/prefix/agent-clis")" "claude" "the image records the CLIs it installed (dck up / doctor compare it)"
  assert_eq "$(grep -c '^prefix=' "$HOME/.npmrc")" "1" "the npm prefix is written once"
  assert_eq "$(grep -c 'agentkit/aliases.sh' "$HOME/.bashrc")" "1" "the presets line is written once"
  assert_not_contains "$(fake_calls curl)" "nodejs.org" "Node is not downloaded when present"
  : > "$DCK_FAKE_LOG"
  run_cmd env DCK_VERSIONS="$SANDBOX/akrel/versions.env" DCK_USER="$(id -un)" FAKE_CURL_FILE="$SANDBOX/akrel/agentkit.tar.gz" \
    DCK_SKILLS_DIR="$SANDBOX/skills" DCK_LAYER_PREFIX="$SANDBOX/prefix" PATH="$LFIX/bin:$EXTRA_PATH$PATH" bash "$DCK_REPO/lib/layers/agents.sh" "grok,opencode" grok
  assert_rc 0 "a developer's comma list (DCK_AGENT_CLIS=\"grok,opencode\" in .env) installs"
  assert_contains "$(fake_calls ak)" "ak install grok opencode npm_prefix=" "commas separate kinds; a repeated kind is installed once"
  assert_eq "$(cat "$SANDBOX/prefix/agent-clis")" "grok opencode" "the record follows the list"
  : > "$DCK_FAKE_LOG"
  run_cmd env DCK_VERSIONS="$SANDBOX/akrel/versions.env" DCK_USER="$(id -un)" FAKE_CURL_FILE="$SANDBOX/akrel/agentkit.tar.gz" \
    DCK_SKILLS_DIR="$SANDBOX/skills" DCK_LAYER_PREFIX="$SANDBOX/prefix" PATH="$LFIX/bin:$EXTRA_PATH$PATH" \
    INSTALL_CURSOR_CLI=true INSTALL_PI_CLI=TRUE INSTALL_CLINE_CLI=1 INSTALL_CLAUDE_CLI=true bash "$DCK_REPO/lib/layers/agents.sh" claude
  assert_rc 0 "INSTALL_<CLI>_CLI build args"
  assert_contains "$(fake_calls ak)" "ak install claude cursor npm_prefix=" "only an exact \"true\" installs; a CLI also listed is installed once"
  run_cmd env DCK_VERSIONS="$SANDBOX/akrel/versions.env" DCK_USER="$(id -un)" FAKE_CURL_FILE="$SANDBOX/akrel/agentkit.tar.gz" \
    DCK_SKILLS_DIR="$SANDBOX/skills" DCK_LAYER_PREFIX="$SANDBOX/prefix" PATH="$LFIX/bin:$EXTRA_PATH$PATH" \
    DCK_AGENT_SUPPORTED="claude codex" INSTALL_GROK_CLI=true bash "$DCK_REPO/lib/layers/agents.sh" claude
  assert_rc 2 "a CLI outside [agents] supported is refused at build time"
  assert_contains "$RUN_ERR" "'grok' is not supported by this repository ([agents] supported: claude codex)" "with the supported list"
  run_layer agents gemini
  assert_rc 2 "an unknown kind is refused"
  run_layer agents claude
  assert_ne "$RUN_RC" "0" "a coding-agents-kit tarball that does not match its pin fails the build"
  assert_contains "$RUN_ERR" "checksum mismatch" "the kit tarball is verified before it is unpacked"
}

test_agents_installer_verifies_node() {
  EXTRA_PATH=""
  local p="" d f i=0
  # A PATH without any node: a directory holding node is mirrored without it
  # (dropping it would drop bash too where Debian's nodejs sits in /usr/bin).
  for d in $(printf '%s' "$PATH" | tr ':' ' '); do
    if [ -x "$d/node" ]; then
      i=$((i + 1)); mkdir -p "$SANDBOX/nonode/$i"
      for f in "$d"/*; do [ "$(basename "$f")" = node ] || ln -s "$f" "$SANDBOX/nonode/$i/" 2>/dev/null; done
      d="$SANDBOX/nonode/$i"
    fi
    p="$p$d:"
  done
  run_cmd env DCK_VERSIONS="$DCK_REPO/images/versions.env" DCK_USER="$(id -un)" DCK_LAYER_PREFIX="$SANDBOX/prefix" \
    PATH="$LFIX/bin:${p%:}" "$BASH" "$DCK_REPO/lib/layers/agents.sh" claude
  assert_ne "$RUN_RC" "0" "a Node download that does not match its pin fails the build"
  assert_contains "$RUN_ERR" "checksum mismatch" "the reason is a checksum mismatch"
  assert_contains "$(fake_calls curl)" "https://nodejs.org/dist/v$(sed -n 's/^NODE_VERSION=//p' "$DCK_REPO/images/versions.env")/" "Node comes from nodejs.org at the pinned version"
  assert_eq "$(fake_calls install.sh)" "" "nothing else runs after a failed verification"
}

test_agents_installer_replaces_an_older_node() {
  # python-3.13 and debian carry Debian's nodejs (an older major) for the editor.
  EXTRA_PATH="$LFIX/nodebin-old:"
  run_layer agents claude
  assert_ne "$RUN_RC" "0" "an older Node triggers the pinned download (the fake one fails its pin)"
  assert_contains "$(fake_calls curl)" "https://nodejs.org/dist/v$(sed -n 's/^NODE_VERSION=//p' "$DCK_REPO/images/versions.env")/" "the pinned Node is fetched when the present one is older"
  assert_contains "$RUN_ERR" "checksum mismatch" "and it is verified like any other download"
}

test_dailybot_layer() {
  render --flavour node-24 --no-agents
  sed -i.orig 's/^dailybot = false$/dailybot = true/' "$REPO/.devcontainer/dck.toml" && rm -f "$REPO/.devcontainer/dck.toml.orig"
  render
  assert_contains "$(dockerfile)" "RUN DCK_USER=dev dck-layer dailybot" "layers.dailybot adds the dailybot layer"
  assert_contains "$(compose)" 'DCK_DAILYBOT: "1"' "the entrypoint learns about it"
  EXTRA_PATH=""
  run_layer dailybot
  assert_ne "$RUN_RC" "0" "a Dailybot CLI download that does not match its pin fails"
  assert_contains "$RUN_ERR" "checksum mismatch" "the wheel is checked against its pinned hash"
}

test_editor_layer_off() {
  render --flavour debian --no-editor
  assert_contains "$(dockerfile)" "ENV EDITOR=nano VISUAL=nano GIT_EDITOR=nano" "editor off makes nano the default editor"
  assert_contains "$(compose)" 'DCK_EDITOR: "0"' "the entrypoint learns the editor is off"
  render --editor
  assert_not_contains "$(dockerfile)" "EDITOR=nano" "editor on restores nvim"
}

LIB="$DCK_REPO/lib/entrypoint.sh"
ep_env() {
  export DCK_USER=dev DCK_HOME="$SANDBOX/root/home/dev" DCK_WORKSPACE="$SANDBOX/root/workspace"
  export DCK_PERSIST_ROOT="$DCK_HOME/.dck/volumes"
  mkdir -p "$DCK_HOME" "$DCK_WORKSPACE"
}

test_runtime_persistence_per_cli() {
  ep_env
  mkdir -p "$DCK_HOME/.claude"; echo '{}' > "$DCK_HOME/.claude.json"
  run_cmd env DCK_AGENTS="claude codex bogus" bash -c '. "$1"; dck_layer_persist' _ "$LIB"
  assert_rc 0 "layer persistence runs"
  assert_eq "$(readlink "$DCK_HOME/.claude")" "$DCK_PERSIST_ROOT/claude/claude" "~/.claude lives on the claude volume"
  assert_eq "$(readlink "$DCK_HOME/.claude.json")" "$DCK_PERSIST_ROOT/claude/claude.json" "~/.claude.json lives on the claude volume"
  assert_eq "$(readlink "$DCK_HOME/.codex")" "$DCK_PERSIST_ROOT/codex/codex" "~/.codex lives on the codex volume"
  assert_eq "$(readlink "$DCK_HOME/.config/agentkit")" "$DCK_PERSIST_ROOT/agentkit/config_agentkit" "the ak config lives on the agentkit volume"
  assert_dir "$DCK_PERSIST_ROOT/agentkit/profiles" "the ak profiles directory exists on its volume"
  assert_contains "$RUN_ERR" "unknown kind 'bogus' skipped" "an unknown kind is skipped, loudly"
  run_cmd env DCK_AGENTS="" DCK_DAILYBOT=0 bash -c '. "$1"; dck_start' _ "$LIB"
  assert_eq "$(readlink "$DCK_HOME/.config/dailybot")" "$DCK_PERSIST_ROOT/state/config_dailybot" "the Dailybot CLI config lives on the state volume, with or without the dailybot layer"
}

test_runtime_nothing_without_layers() {
  ep_env
  run_cmd bash -c '. "$1"; dck_layer_persist' _ "$LIB"
  assert_rc 0 "no layer, no work"
  assert_absent "$DCK_PERSIST_ROOT/agentkit" "no agent volume is touched without the layer"
}

test_kind_lists_agree() {
  run_cmd python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import config, render; print(" ".join(config.AGENT_KINDS)); print(" ".join(render.AGENT_VOLUMES))' "$DCK_REPO/lib"
  local cfg vols sh homes
  cfg="$(printf '%s\n' "$RUN_OUT" | sed -n 1p)"; vols="$(printf '%s\n' "$RUN_OUT" | sed -n 2p)"
  sh="$(sed -n 's/^KINDS="\(.*\)"$/\1/p' "$DCK_REPO/lib/layers/agents.sh")"
  homes="$(sed -n '/^dck_agent_homes() {/,/^}/p' "$LIB" | sed -n 's/^ *\([a-z]*\)) .*/\1/p' | tr '\n' ' ' | sed 's/ $//')"
  assert_eq "$vols" "$cfg" "template volumes cover exactly the config kinds"
  assert_eq "$sh" "$cfg" "the installer accepts exactly the config kinds"
  assert_eq "$homes" "$cfg" "the entrypoint persists exactly the config kinds"
}

test_layers_are_scripts_not_clis_in_the_base() {
  local f
  for f in python-3.13 node-24 debian; do
    assert_contains "$(cat "$DCK_REPO/images/$f/Dockerfile")" "COPY lib/layers/ /usr/local/lib/dck/layers/" "$f ships the layer installers"
    assert_not_contains "$(cat "$DCK_REPO/images/$f/Dockerfile")" "dck-layer agents" "$f never runs the agents layer itself"
  done
  assert_no_match "$(cat "$DCK_REPO/lib/layers/"*.sh)" '(curl|wget)[^|]*\|[[:space:]]*(ba|z)?sh' "no layer pipes a download into a shell"
}

test_agents_installer_presets() {
  EXTRA_PATH="$LFIX/nodebin:"
  agentkit_fixture
  local run=(env DCK_VERSIONS="$SANDBOX/akrel/versions.env" DCK_USER="$(id -un)" FAKE_CURL_FILE="$SANDBOX/akrel/agentkit.tar.gz"
    DCK_SKILLS_DIR="$SANDBOX/skills" DCK_LAYER_PREFIX="$SANDBOX/prefix" PATH="$LFIX/bin:$EXTRA_PATH$PATH")
  run_cmd "${run[@]}" DCK_AGENT_PRESETS="" bash "$DCK_REPO/lib/layers/agents.sh" claude
  assert_rc 0 "the installer runs with no preset"
  assert_not_contains "$(fake_calls ak)" "alias preset" "DCK_AGENT_PRESETS=\"\" turns no preset on"
  assert_not_contains "$(cat "$HOME/.bashrc" 2>/dev/null)" "agentkit/aliases.sh" "and bash does not load the presets"
  : > "$DCK_FAKE_LOG"
  run_cmd "${run[@]}" DCK_AGENT_PRESETS="classic" bash "$DCK_REPO/lib/layers/agents.sh" claude
  assert_contains "$(fake_calls ak)" "ak alias preset classic --on" "a listed preset is turned on"
  assert_not_contains "$(fake_calls ak)" "preset providers" "only that one"
  run_cmd "${run[@]}" DCK_AGENT_PRESETS="bogus" bash "$DCK_REPO/lib/layers/agents.sh" claude
  assert_rc 2 "an unknown preset fails the build"
}

# #16: an older Node in the image (a repository's production Node, or Debian's)
# is never replaced: the pinned Node goes into the agents' own prefix, and the
# npm-installed agent CLIs are launched on it.
test_agents_get_their_own_node() {
  local tag nv arch rel ak
  tag="$(sed -n 's/^AGENTKIT_TAG=//p' "$DCK_REPO/images/versions.env")"
  nv="$(sed -n 's/^NODE_VERSION=//p' "$DCK_REPO/images/versions.env")"
  case "$(uname -m)" in arm64|aarch64) arch=arm64 ;; *) arch=x64 ;; esac
  mkdir -p "$SANDBOX/dl" "$SANDBOX/noderel/node-v$nv-linux-$arch/bin"
  printf '#!/usr/bin/env bash\necho v%s\n' "$nv" > "$SANDBOX/noderel/node-v$nv-linux-$arch/bin/node"
  chmod +x "$SANDBOX/noderel/node-v$nv-linux-$arch/bin/node"
  tar -cJf "$SANDBOX/dl/node-v$nv-linux-$arch.tar.xz" -C "$SANDBOX/noderel" "node-v$nv-linux-$arch"
  # A kit whose ak installs one npm CLI (a node-script entry point behind a symlink).
  rel="$SANDBOX/akrel/coding-agents-kit-$tag"
  mkdir -p "$rel/skills/agentkit" "$rel/skills/agentkit-setup" "$rel/skills/agentkit-orchestrate"
  for s in agentkit agentkit-setup agentkit-orchestrate; do printf -- '---\nname: %s\n---\n' "$s" > "$rel/skills/$s/SKILL.md"; done
  cat > "$rel/install.sh" <<'SH'
#!/usr/bin/env bash
mkdir -p "$HOME/.local/share/agentkit/bin"
cat > "$HOME/.local/share/agentkit/bin/ak" <<'AK'
#!/usr/bin/env bash
printf 'ak %s path=%s\n' "$*" "$PATH" >> "${DCK_FAKE_LOG:-/dev/null}"
if [ "$1" = install ]; then
  mkdir -p "$HOME/.local/lib/node_modules/fakecli/bin" "$HOME/.local/bin"
  printf '#!/usr/bin/env node\nconsole.log("fake")\n' > "$HOME/.local/lib/node_modules/fakecli/bin/cli.js"
  ln -sfn ../lib/node_modules/fakecli/bin/cli.js "$HOME/.local/bin/fakecli"
fi
AK
chmod +x "$HOME/.local/share/agentkit/bin/ak"
SH
  tar -czf "$SANDBOX/dl/coding-agents-kit-$tag.tar.gz" -C "$SANDBOX/akrel" "coding-agents-kit-$tag"
  sed -e "s/^AGENTKIT_SHA256=.*/AGENTKIT_SHA256=$(shasum -a 256 "$SANDBOX/dl/coding-agents-kit-$tag.tar.gz" | cut -d' ' -f1)/" \
      -e "s/^NODE_SHA256_AMD64=.*/NODE_SHA256_AMD64=$(shasum -a 256 "$SANDBOX/dl/node-v$nv-linux-$arch.tar.xz" | cut -d' ' -f1)/" \
      -e "s/^NODE_SHA256_ARM64=.*/NODE_SHA256_ARM64=$(shasum -a 256 "$SANDBOX/dl/node-v$nv-linux-$arch.tar.xz" | cut -d' ' -f1)/" \
      "$DCK_REPO/images/versions.env" > "$SANDBOX/versions.env"
  local old_node; old_node="$(cat "$LFIX/nodebin-old/node")"
  run_cmd env DCK_VERSIONS="$SANDBOX/versions.env" DCK_USER="$(id -un)" FAKE_CURL_DIR="$SANDBOX/dl" \
    DCK_SKILLS_DIR="$SANDBOX/skills" DCK_LAYER_PREFIX="$SANDBOX/opt" DCK_AGENT_PRESETS="" \
    PATH="$LFIX/bin:$LFIX/nodebin-old:$PATH" bash "$DCK_REPO/lib/layers/agents.sh" claude
  assert_rc 0 "the agents layer runs over an older Node"
  assert_file "$SANDBOX/opt/node/bin/node" "the pinned Node goes into the agents' own prefix"
  assert_eq "$(cat "$LFIX/nodebin-old/node")" "$old_node" "the image's node is left as it is"
  assert_contains "$RUN_ERR" "for the agents in $SANDBOX/opt/node (the image's node v20 is left as it is)" "and the log says so"
  assert_contains "$(fake_calls ak | grep '^ak install')" "path=$SANDBOX/opt/node/bin:" "ak install runs with the agents' Node first on PATH"
  assert_contains "$(head -3 "$HOME/.local/bin/fakecli")" "exec $SANDBOX/opt/node/bin/node $HOME/.local/lib/node_modules/fakecli/bin/cli.js" "an npm CLI is launched on the agents' Node"
  assert_contains "$RUN_ERR" "1 agent CLI(s) run on the agents' own Node" "counted in the log"
}
