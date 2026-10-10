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
  assert_eq "$(sed -n '/>>> dck:volumes >>>/,/<<< dck:volumes <<</p' "$REPO/docker/local/docker-compose.yaml" | grep -c ': {}')" "1" "only the state volume is declared"
  assert_contains "$(cat "$REPO/.devcontainer/dck.toml")" "agents = false" "dck.toml records the layer off"
}

test_agents_layer_enabled() {
  render --flavour node-24 --agents --clis "claude codex"
  assert_rc 0 "init renders with the agents layer"
  local d c
  d="$(dockerfile)"; c="$(compose)"
  assert_contains "$d" 'ARG DCK_AGENT_CLIS="claude codex"' "the requested kinds reach the build"
  assert_contains "$d" 'RUN DCK_USER=dev dck-layer agents ${DCK_AGENT_CLIS}' "the Dockerfile runs the agents layer installer"
  assert_contains "$c" 'DCK_AGENTS: "claude codex"' "the entrypoint learns the kinds"
  assert_contains "$c" "AGENTKIT_PROFILES_DIR: /home/dev/.dck/volumes/agentkit/profiles" "ak profiles live on the agentkit volume"
  local v
  for v in agentkit claude codex; do
    assert_contains "$c" "      - $v:/home/dev/.dck/volumes/$v" "volume $v is mounted"
    assert_contains "$c" "  $v: {}" "volume $v is declared (per compose project)"
  done
  assert_not_contains "$c" "  cursor: {}" "kinds not requested get no volume"
  assert_no_match "$d$c" '--dangerously|--yolo|--always-approve|--force' "the template spells no CLI autonomy flag (they live in coding-agents-kit)"
  assert_contains "$c" "set AGENTKIT_PERMISSIONS=ask in ./app/.env" "compose documents the opt-out (through the service .env)"
  assert_no_match "$c" '^[[:space:]]*#[[:space:]]*AGENTKIT_PERMISSIONS=' "no commented line that would be invalid YAML when uncommented"
  assert_no_match "$c" '^[[:space:]]+AGENTKIT_PERMISSIONS:' "compose sets no permission posture (ak's default, autonomy)"
  local t; t="$(cat "$REPO/.devcontainer/dck.toml")"
  assert_contains "$t" "agents = true" "dck.toml records the layer on"
  assert_contains "$t" 'clis = ["claude", "codex"]' "dck.toml records the kinds"
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
    DCK_LAYER_PREFIX="$SANDBOX/prefix" DCK_LAYER_TOOL_DIR="$SANDBOX/tools" DCK_LAYER_BIN_DIR="$SANDBOX/toolbin" \
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
  tar -czf "$SANDBOX/akrel/agentkit.tar.gz" -C "$SANDBOX/akrel" "coding-agents-kit-$tag"
  sed "s/^AGENTKIT_SHA256=.*/AGENTKIT_SHA256=$(shasum -a 256 "$SANDBOX/akrel/agentkit.tar.gz" | cut -d' ' -f1)/" \
    "$DCK_REPO/images/versions.env" > "$SANDBOX/akrel/versions.env"
}

test_agents_installer_follows_the_kit_contract() {
  EXTRA_PATH="$LFIX/nodebin:"
  agentkit_fixture
  run_cmd env DCK_VERSIONS="$SANDBOX/akrel/versions.env" DCK_USER="$(id -un)" FAKE_CURL_FILE="$SANDBOX/akrel/agentkit.tar.gz" \
    DCK_LAYER_PREFIX="$SANDBOX/prefix" PATH="$LFIX/bin:$EXTRA_PATH$PATH" bash "$DCK_REPO/lib/layers/agents.sh" claude codex
  assert_rc 0 "the agents installer runs"
  local tag; tag="$(sed -n 's/^AGENTKIT_TAG=//p' "$DCK_REPO/images/versions.env")"
  assert_contains "$(fake_calls curl)" "https://github.com/DailybotHQ/coding-agents-kit/releases/download/$tag/coding-agents-kit-$tag.tar.gz" "coding-agents-kit comes from its pinned release tarball"
  assert_eq "$(fake_calls git)" "" "nothing is cloned"
  assert_contains "$(fake_calls install.sh)" "install.sh --no-rc" "the kit's own install.sh runs without touching rc files"
  assert_contains "$(fake_calls ak)" "ak alias preset classic --on" "the classic preset is on"
  assert_contains "$(fake_calls ak)" "ak alias preset providers --on" "the providers preset is on"
  assert_contains "$(cat "$HOME/.bashrc")" '.local/share/agentkit/aliases.sh' "bash loads the presets"
  assert_contains "$(fake_calls ak)" "ak install claude codex npm_prefix=$HOME/.local" "ak installs exactly the requested kinds, npm globals into ~/.local"
  assert_eq "$(cat "$HOME/.npmrc")" "prefix=$HOME/.local" "the dev user's npm prefix is ~/.local (Node's prefix is root's)"
  : > "$DCK_FAKE_LOG"
  run_cmd env DCK_VERSIONS="$SANDBOX/akrel/versions.env" DCK_USER="$(id -un)" FAKE_CURL_FILE="$SANDBOX/akrel/agentkit.tar.gz" \
    DCK_LAYER_PREFIX="$SANDBOX/prefix" PATH="$LFIX/bin:$EXTRA_PATH$PATH" bash "$DCK_REPO/lib/layers/agents.sh" claude
  assert_eq "$(grep -c '^prefix=' "$HOME/.npmrc")" "1" "the npm prefix is written once"
  assert_eq "$(grep -c 'agentkit/aliases.sh' "$HOME/.bashrc")" "1" "the presets line is written once"
  assert_not_contains "$(fake_calls curl)" "nodejs.org" "Node is not downloaded when present"
  run_layer agents gemini
  assert_rc 2 "an unknown kind is refused"
  run_layer agents claude
  assert_ne "$RUN_RC" "0" "a coding-agents-kit tarball that does not match its pin fails the build"
  assert_contains "$RUN_ERR" "checksum mismatch" "the kit tarball is verified before it is unpacked"
}

test_agents_installer_verifies_node() {
  EXTRA_PATH=""
  local p="" d
  # A PATH without any node: keep the system dirs, drop the ones holding node.
  for d in $(printf '%s' "$PATH" | tr ':' ' '); do
    [ -x "$d/node" ] && continue
    p="$p$d:"
  done
  run_cmd env DCK_VERSIONS="$DCK_REPO/images/versions.env" DCK_USER="$(id -un)" DCK_LAYER_PREFIX="$SANDBOX/prefix" \
    PATH="$LFIX/bin:${p%:}" bash "$DCK_REPO/lib/layers/agents.sh" claude
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
  run_cmd env DCK_AGENTS="" DCK_DAILYBOT=1 bash -c '. "$1"; dck_layer_persist' _ "$LIB"
  assert_eq "$(readlink "$DCK_HOME/.config/dailybot")" "$DCK_PERSIST_ROOT/state/config_dailybot" "the Dailybot CLI config lives on the state volume"
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
