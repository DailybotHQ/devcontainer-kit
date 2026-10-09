# shellcheck shell=bash
# Scope: docker — integration against a real Docker daemon (reported
# "unavailable" without one). Builds the node-24 base image from images/,
# renders a fixture repository with `dck init`, then: setup, up, shell, ssh
# with agent forwarding, sshd on loopback only, host key stable across a
# recreate, doctor, down. Everything it creates is removed by the test itself.
#
# Runs with the sandbox HOME (docker then reads $HOME/.docker, empty), the
# compose backend, and DCK_SSH_CONFIG=/dev/null so the developer's own
# ~/.ssh/config is never read.

DCK="$DCK_REPO/bin/dck"
IT_IMAGE="dck-it-base:node-24"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'; }

it_cleanup() {
  [ -n "${IT_REPO:-}" ] && (cd "$IT_REPO" && "$DCK" down >/dev/null 2>&1)
  if [ -n "${IT_PROJECT:-}" ]; then
    docker volume rm "${IT_PROJECT}_state" >/dev/null 2>&1
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
  while [ "$i" -lt 30 ]; do
    # The banner, not the TCP accept: on Linux the userland proxy accepts
    # before sshd in the container listens.
    python3 -c 'import socket,sys; s=socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2); s.settimeout(2); sys.exit(0 if s.recv(4).startswith(b"SSH-") else 1)' "$1" 2>/dev/null && return 0
    i=$((i + 1)); sleep 1
  done
  return 1
}

test_build_node_flavour() {
  require_docker "build the node-24 base image" || return 0
  run_cmd docker build -q -f "$DCK_REPO/images/node-24/Dockerfile" -t "$IT_IMAGE" "$DCK_REPO"
  assert_rc 0 "the node-24 base image builds from images/"
  run_cmd docker run --rm --entrypoint bash "$IT_IMAGE" -c 'id -un 1000; command -v gh herdr nvim python3 node | wc -l; ls /etc/ssh/ssh_host_* 2>/dev/null | wc -l; for c in claude codex agent opencode pi cline grok dailybot engram graphify; do command -v "$c"; done | wc -l'
  assert_eq "$RUN_OUT" "dev
5
0
0" "the image has the dev user and its tools, no host keys and no agent CLI"
}

test_end_to_end() {
  require_docker "init, setup, up, shell, ssh, doctor, down in a real container" || return 0
  docker image inspect "$IT_IMAGE" >/dev/null 2>&1 || docker build -q -f "$DCK_REPO/images/node-24/Dockerfile" -t "$IT_IMAGE" "$DCK_REPO" >/dev/null
  export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_NO_DIGEST=1 DCK_SSH_CONFIG=/dev/null
  IT_PROJECT="dckit$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  IT_REPO="$SANDBOX/$IT_PROJECT"
  trap it_cleanup EXIT
  local port; port="$(free_port)"
  mkdir -p "$IT_REPO"; git -C "$IT_REPO" init -q; echo '{}' > "$IT_REPO/package.json"
  run_cmd "$DCK" init --repo "$IT_REPO" --ssh-port "$port" --no-herdr --yes
  assert_rc 0 "dck init renders the fixture repository"
  # Point the managed BASE_IMAGE at the image built above (not a registry ref).
  sed -i.orig "s#BASE_IMAGE: \".*\"#BASE_IMAGE: \"$IT_IMAGE\"#" "$IT_REPO/docker/local/docker-compose.yaml"
  rm -f "$IT_REPO/docker/local/docker-compose.yaml.orig"
  printf 'IT_MARKER=from-env-file\n' >> "$IT_REPO/docker/local/app/.env.example"

  d() { run_cmd bash -c 'cd "$1" && shift && "$@"' _ "$IT_REPO" "$DCK" "$@"; }
  d setup
  assert_rc 0 "dck setup succeeds"
  d up
  assert_rc 0 "dck up starts the container"
  if wait_port "$port"; then pass "sshd answers on the published loopback port"; else fail "sshd answers on the published loopback port"; fi

  d shell -c 'printf "%s|%s|%s" "$(whoami)" "$(pwd)" "$(test -f package.json && echo repo-mounted)"'
  assert_eq "$RUN_OUT" "dev|/workspace|repo-mounted" "dck shell -c runs as the dev user in the mounted workspace"

  run_cmd docker port "${IT_PROJECT}-app-1" 22
  assert_eq "$RUN_OUT" "127.0.0.1:$port" "sshd is published on 127.0.0.1 only"

  # Agent forwarding with a throwaway key; the socket path must be short.
  IT_SOCK="/tmp/dck-it-$$.sock"
  eval "$(ssh-agent -a "$IT_SOCK" -s)" >/dev/null
  IT_AGENT_PID="$SSH_AGENT_PID"
  ssh-keygen -q -t ed25519 -N '' -C dck-it-agent-key -f "$SANDBOX/agentkey"
  ssh-add -q "$SANDBOX/agentkey" 2>/dev/null
  d ssh 'ssh-add -l; grep -rl dck-it-agent-key /home /root /tmp /etc 2>/dev/null | wc -l | tr -d " "; echo "$IT_MARKER"'
  assert_rc 0 "dck ssh logs in with the dedicated key"
  assert_contains "$RUN_OUT" "dck-it-agent-key (ED25519)" "the host's agent is forwarded into the session"
  assert_match "$RUN_OUT" '^0$' "no file in the container contains the forwarded key"
  assert_contains "$RUN_OUT" "from-env-file" "ssh sessions see the container environment (env profile)"
  assert_not_contains "$RUN_ERR" "from-env-file" "dck never prints env values itself"
  d shell -c 'stat -c %U "$(readlink -f ~/.config/herdr/config.toml)"'
  assert_eq "$RUN_OUT" "dev" "the root entrypoint leaves the Herdr config owned by the dev user"

  d up --recreate
  wait_port "$port" || fail "sshd answers again after a recreate"
  d ssh true
  assert_rc 0 "after a recreate the same host key is accepted (strict checking)"

  d doctor --json
  local ok
  ok="$(printf '%s' "$RUN_OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["interface"], d["repo"]["container"]["state"], d["ssh"]["answering"], sorted({x["status"] for x in d["drift"] if x["name"] in ("gh","nvim","dwp_vim")}))')"
  assert_eq "$ok" "1 running True ['ok']" "doctor sees the running container, sshd and no tool drift"
  printf '%s' "$RUN_OUT" | python3 "$TESTS_DIR/py/minischema.py" "$DCK_REPO/docs/schema/dck-doctor-v1.json" >/dev/null
  assert_rc 0 "the live doctor report matches the schema"

  d down
  assert_rc 0 "dck down succeeds"
  run_cmd docker ps -a --filter "label=com.docker.compose.project=$IT_PROJECT" --format '{{.Names}}'
  assert_eq "$RUN_OUT" "" "dck down removed the container"
  run_cmd docker volume inspect "${IT_PROJECT}_state" --format '{{.Name}}'
  assert_eq "$RUN_OUT" "${IT_PROJECT}_state" "dck down kept the per-project state volume"
}

test_devcontainer_cli_backend() {
  require_docker "up and shell through the devcontainer CLI" || return 0
  if ! command -v devcontainer >/dev/null 2>&1; then
    unavailable "up and shell through the devcontainer CLI" "@devcontainers/cli not installed"
    return 0
  fi
  docker image inspect "$IT_IMAGE" >/dev/null 2>&1 || docker build -q -f "$DCK_REPO/images/node-24/Dockerfile" -t "$IT_IMAGE" "$DCK_REPO" >/dev/null
  export DCK_BACKEND=devcontainer DCK_NONINTERACTIVE=1 DCK_NO_DIGEST=1 DCK_SSH_CONFIG=/dev/null
  IT_PROJECT="dckdc$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  IT_REPO="$SANDBOX/$IT_PROJECT"
  trap it_cleanup EXIT
  mkdir -p "$IT_REPO"; git -C "$IT_REPO" init -q
  "$DCK" init --repo "$IT_REPO" --ssh-port 0 --no-herdr --yes >/dev/null 2>&1
  sed -i.orig "s#BASE_IMAGE: \".*\"#BASE_IMAGE: \"$IT_IMAGE\"#" "$IT_REPO/docker/local/docker-compose.yaml"
  rm -f "$IT_REPO/docker/local/docker-compose.yaml.orig"
  run_cmd bash -c 'cd "$1" && "$2" up' _ "$IT_REPO" "$DCK"
  assert_rc 0 "dck up through the devcontainer CLI starts the container"
  run_cmd bash -c 'cd "$1" && "$2" shell -c "whoami; pwd"' _ "$IT_REPO" "$DCK"
  assert_eq "$RUN_OUT" "dev
/workspace" "dck shell through devcontainer exec runs as remoteUser in workspaceFolder"
  run_cmd docker ps --filter "label=com.docker.compose.project=$IT_PROJECT" --format '{{.Names}}'
  assert_eq "$RUN_OUT" "${IT_PROJECT}-app-1" "the devcontainer CLI used the compose project dck init named"
}

test_agents_layer_installs_the_kit() {
  require_docker "the agents layer installs coding-agents-kit at its pin" || return 0
  docker image inspect "$IT_IMAGE" >/dev/null 2>&1 || docker build -q -f "$DCK_REPO/images/node-24/Dockerfile" -t "$IT_IMAGE" "$DCK_REPO" >/dev/null
  local tag; tag="$(sed -n 's/^AGENTKIT_TAG=//p' "$DCK_REPO/images/versions.env")"
  # Kit only (no CLI download): the installer, the pin, the default posture.
  run_cmd docker run --rm --entrypoint bash "$IT_IMAGE" -c 'DCK_USER=dev dck-layer agents >/dev/null 2>&1 || exit 9; runuser -u dev -- bash -lc "ak --version; ak doctor --json | python3 -c \"import json,sys; d=json.load(sys.stdin); print(d[\\\"interface\\\"], d[\\\"permissions\\\"])\"; cat ~/.npmrc"'
  assert_rc 0 "the agents layer installs coding-agents-kit in a real image"
  assert_contains "$RUN_OUT" "agentkit ${tag#v}" "the installed kit is the pinned $tag"
  assert_contains "$RUN_OUT" "1 ask" "ak reports interface 1 and pass-through permissions (no bypass)"
  assert_contains "$RUN_OUT" "prefix=/home/dev/.local" "npm globals go to the dev user's ~/.local"
}

test_zz_nothing_left_behind() {
  # Runs last in the scope: every container, volume and network a test created is gone.
  require_docker "the docker scope leaves no container, volume or network behind" || return 0
  local left
  left="$( { docker ps -a --format '{{.Names}}'; docker volume ls --format '{{.Name}}'; docker network ls --format '{{.Name}}'; } | grep -E '^(dckit|dckdc)[0-9a-f]{8}' || true)"
  assert_eq "$left" "" "the docker scope leaves no container, volume or network behind"
}
