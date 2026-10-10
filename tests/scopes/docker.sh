# shellcheck shell=bash
# Scope: docker — integration against a real Docker daemon (reported
# "unavailable" without one). Renders fixture repositories with `dck init` (the
# v2 template: no shared base image) and proves the acceptance checklist on
# real containers: a node fixture with the agents layer end to end (dev.sh up,
# shell, ssh with agent forwarding, the host agent in exec sessions, Herdr
# mesh and layout script, git identity, persistence across rebuild, doctor,
# down) and a python fixture (runtime, editor, herdr-peers). Everything it
# creates is removed by the test itself.
#
# Runs with the sandbox HOME (docker then reads $HOME/.docker, empty), the
# compose backend, and DCK_SSH_CONFIG=/dev/null so the developer's own
# ~/.ssh/config is never read. Image builds hold DCK_BUILD_LOCK when set.

DCK="$DCK_REPO/bin/dck"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }

it_cleanup() {
  [ -n "${IT_REPO:-}" ] && (cd "$IT_REPO" && "$DCK" down >/dev/null 2>&1)
  if [ -n "${IT_PROJECT:-}" ]; then
    docker ps -aq --filter "label=com.docker.compose.project=$IT_PROJECT" | xargs -r docker rm -f >/dev/null 2>&1
    docker volume ls -q --filter "label=com.docker.compose.project=$IT_PROJECT" | xargs -r docker volume rm >/dev/null 2>&1
    docker image rm "${IT_PROJECT}-app" >/dev/null 2>&1
    # dck down keeps the project network (shared projects); a test project is
    # unique per run, so its network must go too or runs exhaust Docker's pools.
    docker network rm "${IT_PROJECT}_default" >/dev/null 2>&1
  fi
  if [ -n "${IT_AGENT_PID:-}" ]; then kill "$IT_AGENT_PID" 2>/dev/null; fi
  if [ -n "${IT_SOCK:-}" ]; then rm -f "$IT_SOCK"; fi
  return 0
}

wait_port() {
  local i=0
  while [ "$i" -lt 60 ]; do
    # The banner, not the TCP accept: on Linux the userland proxy accepts
    # before sshd in the container listens.
    python3 -c 'import socket,sys; s=socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2); s.settimeout(2); sys.exit(0 if s.recv(4).startswith(b"SSH-") else 1)' "$1" 2>/dev/null && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

# new_fixture <prefix> — a fresh, uniquely named project; sets IT_PROJECT/IT_REPO.
new_fixture() {
  IT_PROJECT="$1$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  IT_REPO="$SANDBOX/$IT_PROJECT"
  mkdir -p "$IT_REPO"; git -C "$IT_REPO" init -q
}

with_lock() {  # with_lock <command...> — one image build at a time on a shared machine
  local lock="${DCK_BUILD_LOCK:-}"
  if [ -z "$lock" ]; then "$@"; return $?; fi
  until mkdir "$lock" 2>/dev/null; do sleep 15; done
  "$@"; local rc=$?
  rmdir "$lock" 2>/dev/null
  return "$rc"
}

d() { run_cmd bash -c 'cd "$1" && shift && "$@"' _ "$IT_REPO" "$DCK" "$@"; }
dev() { run_cmd bash -c 'cd "$1" && PATH="$2:$PATH" bash dev.sh "${@:3}"' _ "$IT_REPO" "$DCK_REPO/bin" "$@"; }

test_node_fixture_end_to_end() {
  require_docker "a rendered node repository: dev.sh up, agents, ssh, herdr, persistence, doctor" || return 0
  export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_SSH_CONFIG=/dev/null
  new_fixture dckit
  trap it_cleanup EXIT
  local port; port="$(free_port)"
  echo '{"name":"fixture","engines":{"node":">=24"}}' > "$IT_REPO/package.json"
  run_cmd "$DCK" init --repo "$IT_REPO" --ssh-port "$port" --no-herdr --agents --clis "codex pi" --yes
  assert_rc 0 "dck init renders the node fixture with the agents layer"
  # 1. Layout
  local f
  for f in .devcontainer/devcontainer.json .devcontainer/dck.toml docker/local/docker-compose.yaml docker/local/app/Dockerfile docker/local/app/dck/VERSION dev.sh; do
    assert_file "$IT_REPO/$f" "layout: $f is rendered"
  done
  assert_not_contains "$(cat "$IT_REPO/docker/local/app/Dockerfile" "$IT_REPO/docker/local/docker-compose.yaml")" "devcontainer-kit-base" "layout: no shared base image is referenced"
  printf 'IT_MARKER=from-env-file\nDCK_GIT_NAME=Fixture Dev\nDCK_GIT_EMAIL=fixture@example.invalid\n' >> "$IT_REPO/docker/local/app/.env.example"

  # The host agent: a throwaway key in a sandbox agent. dck up maps it into exec
  # sessions on Linux (DCK_HOST_SSH_AUTH_SOCK); ssh sessions get it forwarded.
  IT_SOCK="/tmp/dck-it-$$.sock"
  eval "$(ssh-agent -a "$IT_SOCK" -s)" >/dev/null
  IT_AGENT_PID="$SSH_AGENT_PID"
  ssh-keygen -q -t ed25519 -N '' -C dck-it-agent-key -f "$SANDBOX/agentkey"
  ssh-add -q "$SANDBOX/agentkey" 2>/dev/null

  # 2. dev.sh up is the entry point (setup on the first run, then build and start).
  with_lock dev up
  assert_rc 0 "dev.sh up builds and starts the container"
  if wait_port "$port"; then pass "sshd answers on the published loopback port"; else fail "sshd answers on the published loopback port"; fi
  run_cmd docker port "${IT_PROJECT}-app-1" 22
  assert_eq "$RUN_OUT" "127.0.0.1:$port" "sshd is published on 127.0.0.1 only"
  dev shell -c 'printf "%s|%s|%s" "$(whoami)" "$(pwd)" "$(test -f package.json && echo repo-mounted)"'
  assert_eq "$RUN_OUT" "dev|/workspace|repo-mounted" "dev.sh shell runs as the dev user in the mounted workspace"

  # 3 + 4. Herdr: sshd with agent forwarding, the mesh and the layout script.
  d ssh 'ssh-add -l; grep -rl dck-it-agent-key /home /root /tmp /etc 2>/dev/null | wc -l | tr -d " "; echo "$IT_MARKER"'
  assert_rc 0 "dck ssh logs in with the dedicated key"
  assert_contains "$RUN_OUT" "dck-it-agent-key (ED25519)" "the host's agent is forwarded into ssh sessions"
  assert_match "$RUN_OUT" '^0$' "no file in the container contains the forwarded key"
  assert_contains "$RUN_OUT" "from-env-file" "ssh sessions see the container environment (env profile)"
  # The apply path is the same on Linux (where dck skips the mesh: peers are unreachable there).
  DCK_HOST_OS=Darwin d herdr mesh
  assert_rc 0 "dck herdr mesh applies the peer list inside"
  dev shell -c 'test -f ~/.ssh/config.d/dck-peers && head -1 ~/.ssh/config; herdr-peers --help >/dev/null && echo peers-ok; command -v dck-herdr-layout; ls ~/.agents/skills; echo "owner:$(stat -c %U ~/.agents)"'
  assert_contains "$RUN_OUT" "Include config.d/dck-peers" "the peers ssh config is included"
  assert_contains "$RUN_OUT" "peers-ok" "herdr-peers runs inside"
  assert_contains "$RUN_OUT" "/usr/local/bin/dck-herdr-layout" "the layout script is installed"
  assert_contains "$RUN_OUT" "herdr-peers" "the herdr-peers skill is linked for the agents"
  assert_contains "$RUN_OUT" "owner:dev" "~/.agents belongs to the container user"

  # 5. Git over SSH through the host agent in exec sessions (Linux: the sandbox
  #    agent; Docker Desktop: the host's own agent socket), and GitHub's keys.
  dev shell -c 'ssh-add -l >/dev/null 2>&1; echo "agent-rc=$?"; ssh-keygen -F github.com -f /etc/ssh/ssh_known_hosts >/dev/null && echo gh-known; git config --global user.name'
  assert_no_match "$RUN_OUT" 'agent-rc=2' "exec sessions reach the host's SSH agent (no key inside)"
  if [ "$(uname -s)" = "Linux" ]; then
    # OpenSSH's ssh-agent refuses a client of another uid (getpeereid), so on a
    # Linux host the shared socket serves the container user (uid 1000) only
    # when the host user is uid 1000 too; ssh sessions use forwarding instead.
    if [ "$(id -u)" = "1000" ]; then
      dev shell -c 'ssh-add -l'
      assert_contains "$RUN_OUT" "dck-it-agent-key (ED25519)" "on Linux, exec sessions see the host agent's key"
    else
      unavailable "on Linux, exec sessions see the host agent's key" "host uid $(id -u) != container uid 1000: ssh-agent refuses other uids"
    fi
  fi
  dev shell -c 'ssh-keygen -F github.com -f /etc/ssh/ssh_known_hosts >/dev/null && echo gh-known; git config --global user.name'
  assert_contains "$RUN_OUT" "gh-known" "GitHub's host keys are pinned"
  assert_contains "$RUN_OUT" "Fixture Dev" "the git identity comes from DCK_GIT_* (no host file)"

  # 6 + 7. Every coding agent through agentkit, in autonomy, with the presets.
  local tag; tag="$(sed -n 's/^AGENTKIT_TAG=//p' "$DCK_REPO/images/versions.env")"
  dev shell -c 'ak --version; ak doctor --json | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[\"interface\"], d[\"permissions\"], d[\"aliases\"][\"classic\"], d[\"aliases\"][\"providers\"])"; command -v codex pi; bash -ic "type -t claudex; type -t codex-glm" 2>/dev/null'
  assert_contains "$RUN_OUT" "agentkit ${tag#v}" "the installed kit is the pinned $tag"
  assert_contains "$RUN_OUT" "1 auto True True" "ak runs in autonomy by default with the classic and providers presets"
  assert_match "$RUN_OUT" '/codex$' "codex is installed through ak"
  assert_match "$RUN_OUT" '/pi$' "pi is installed through ak"
  assert_contains "$RUN_OUT" "function" "the wrapper names are shell functions"
  assert_contains "$(cat "$IT_REPO/docker/local/docker-compose.yaml")" "set AGENTKIT_PERMISSIONS=ask in ./app/.env" "the opt-out is documented in compose"

  # 9. The editor: DeepWorkPlan Vim at its pinned tag, plugins built.
  local dtag; dtag="$(sed -n 's/^DWP_VIM_TAG=//p' "$DCK_REPO/images/versions.env")"
  dev shell -c 'git -C ~/.config/nvim describe --tags; timeout 120 nvim --headless +qa && echo nvim-ok'
  assert_contains "$RUN_OUT" "$dtag" "nvim is DeepWorkPlan Vim $dtag"
  assert_contains "$RUN_OUT" "nvim-ok" "nvim starts headless with the baked-in plugins"

  # 8. Persistence across rebuild: the state and agent volumes survive.
  dev shell -c 'mkdir -p ~/.config/gh ~/.codex && echo kept > ~/.config/gh/it-marker && echo kept > ~/.codex/it-marker && echo kept > ~/.config/agentkit/it-marker'
  with_lock dev rebuild
  assert_rc 0 "dev.sh rebuild recreates the container"
  wait_port "$port" || fail "sshd answers again after a rebuild"
  dev shell -c 'cat ~/.config/gh/it-marker ~/.codex/it-marker ~/.config/agentkit/it-marker; git config --global user.name'
  assert_eq "$RUN_OUT" "kept
kept
kept
Fixture Dev" "gh, a CLI home, agentkit and the git identity survive a rebuild"
  d ssh true
  assert_rc 0 "after a rebuild the same host key is accepted (strict checking)"

  d doctor --json
  local ok
  ok="$(printf '%s' "$RUN_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["interface"], d["repo"]["container"]["state"], d["ssh"]["answering"], d["repo"]["vendored"], sorted({x["status"] for x in d["drift"] if x["name"] in ("gh","nvim","dwp_vim","kit")}))')"
  assert_eq "$ok" "2 running True current ['ok']" "doctor sees the running container, sshd, current vendored scripts and no drift"
  printf '%s' "$RUN_OUT" | python3 "$TESTS_DIR/py/minischema.py" "$DCK_REPO/docs/schema/dck-doctor-v2.json" >/dev/null
  assert_rc 0 "the live doctor report matches the schema"

  dev down
  assert_rc 0 "dev.sh down succeeds"
  run_cmd docker ps -a --filter "label=com.docker.compose.project=$IT_PROJECT" --format '{{.Names}}'
  assert_eq "$RUN_OUT" "" "dev.sh down removed the container"
  run_cmd docker volume inspect "${IT_PROJECT}_state" --format '{{.Name}}'
  assert_eq "$RUN_OUT" "${IT_PROJECT}_state" "dev.sh down kept the per-project state volume"
}

test_python_fixture() {
  require_docker "a rendered python repository builds with its runtime, editor and herdr-peers" || return 0
  export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_SSH_CONFIG=/dev/null
  new_fixture dckpy
  trap it_cleanup EXIT
  printf '[project]\nname = "fixture"\nversion = "0.0.0"\n' > "$IT_REPO/pyproject.toml"
  run_cmd "$DCK" init --repo "$IT_REPO" --ssh-port 0 --no-herdr --yes
  assert_rc 0 "dck init renders the python fixture"
  assert_contains "$(cat "$IT_REPO/.devcontainer/dck.toml")" 'flavour = "python-3.13"' "the runtime is detected from pyproject.toml"
  with_lock dev up
  assert_rc 0 "dev.sh up builds and starts the python fixture"
  local dtag; dtag="$(sed -n 's/^DWP_VIM_TAG=//p' "$DCK_REPO/images/versions.env")"
  dev shell -c 'python3 --version; uv --version >/dev/null && echo uv-ok; git -C ~/.config/nvim describe --tags; herdr-peers --help >/dev/null && echo peers-ok; command -v ak || echo no-ak'
  assert_match "$RUN_OUT" '^Python 3\.13' "the python runtime is the flavour's"
  assert_contains "$RUN_OUT" "uv-ok" "uv is installed"
  assert_contains "$RUN_OUT" "$dtag" "nvim is DeepWorkPlan Vim $dtag"
  assert_contains "$RUN_OUT" "peers-ok" "herdr-peers runs inside"
  assert_contains "$RUN_OUT" "no-ak" "without the agents layer, no coding-agent kit is installed"
  dev down
  assert_rc 0 "dev.sh down succeeds"
}

test_devcontainer_cli_backend() {
  require_docker "up and shell through the devcontainer CLI" || return 0
  if ! command -v devcontainer >/dev/null 2>&1; then
    unavailable "up and shell through the devcontainer CLI" "@devcontainers/cli not installed"
    return 0
  fi
  export DCK_BACKEND=devcontainer DCK_NONINTERACTIVE=1 DCK_SSH_CONFIG=/dev/null
  new_fixture dckdc
  trap it_cleanup EXIT
  "$DCK" init --repo "$IT_REPO" --flavour debian --ssh-port 0 --no-herdr --yes >/dev/null 2>&1
  with_lock run_cmd bash -c 'cd "$1" && "$2" up' _ "$IT_REPO" "$DCK"
  assert_rc 0 "dck up through the devcontainer CLI starts the container"
  run_cmd bash -c 'cd "$1" && "$2" shell -c "whoami; pwd"' _ "$IT_REPO" "$DCK"
  assert_eq "$RUN_OUT" "dev
/workspace" "dck shell through devcontainer exec runs as remoteUser in workspaceFolder"
  run_cmd docker ps --filter "label=com.docker.compose.project=$IT_PROJECT" --format '{{.Names}}'
  assert_eq "$RUN_OUT" "${IT_PROJECT}-app-1" "the devcontainer CLI used the compose project dck init named"
}

test_zz_nothing_left_behind() {
  # Runs last in the scope: every container, volume and network a test created is gone.
  require_docker "the docker scope leaves no container, volume or network behind" || return 0
  local left
  left="$( { docker ps -a --format '{{.Names}}'; docker volume ls --format '{{.Name}}'; docker network ls --format '{{.Name}}'; } | grep -E '^(dckit|dckpy|dckdc)[0-9a-f]{8}' || true)"
  assert_eq "$left" "" "the docker scope leaves no container, volume or network behind"
}
