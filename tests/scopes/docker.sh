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
  # A new render writes presets = [] (off); this fixture turns both on to test them.
  python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("presets = []", "presets = [\"classic\", \"providers\"]"))' "$IT_REPO/.devcontainer/dck.toml"
  run_cmd "$DCK" init --repo "$IT_REPO" --yes
  assert_rc 0 "dck init renders the presets the fixture asks for"
  assert_contains "$(cat "$IT_REPO/docker/local/app/Dockerfile")" 'DCK_AGENT_PRESETS="classic providers"' "and passes them to the agents layer"
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
  # The developer's own alias in the sandbox HOME's ~/.ssh/config (ssh_host_config).
  mkdir -p "$HOME/.ssh"
  printf 'Host github.com-it\n  HostName github.com\n  User git\n  IdentityFile %s\n' "$SANDBOX/agentkey" > "$HOME/.ssh/config"

  # 2. dev.sh up is the entry point (setup on the first run, then build and start).
  with_lock dev up
  assert_rc 0 "dev.sh up builds and starts the container"
  if wait_port "$port"; then pass "sshd answers on the published loopback port"; else fail "sshd answers on the published loopback port"; fi
  run_cmd docker port "${IT_PROJECT}-app-1" 22
  assert_eq "$RUN_OUT" "127.0.0.1:$port" "sshd is published on 127.0.0.1 only"
  dev shell -c 'printf "%s|%s|%s" "$(whoami)" "$(pwd)" "$(test -f package.json && echo repo-mounted)"'
  assert_eq "$RUN_OUT" "dev|/app|repo-mounted" "dev.sh shell runs as the dev user in the mounted workspace"

  # The host's SSH aliases work inside, with the public half only.
  dev shell -c 'ssh -G github.com-it | grep -E "^(hostname|user|identityfile|identitiesonly) "; ls ~/.ssh/dck-host-keys; grep -rl "PRIVATE KEY" ~/.ssh 2>/dev/null | wc -l | tr -d " "'
  assert_contains "$RUN_OUT" "hostname github.com" "a host alias from ~/.ssh/config resolves inside"
  assert_contains "$RUN_OUT" "dck-host-keys/agentkey.pub" "it selects the agent key through its public half"
  assert_match "$RUN_OUT" '^0$' "no private key file is in the container's ~/.ssh"

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
  local skill
  for skill in agentkit agentkit-setup agentkit-orchestrate; do
    assert_contains "$RUN_OUT" "$skill" "coding-agents-kit's $skill skill is linked for the agents"
  done
  assert_contains "$RUN_OUT" "owner:dev" "~/.agents belongs to the container user"

  # 5. Git over SSH through the host agent in exec sessions (Linux: the sandbox
  #    agent; Docker Desktop: the host's own agent socket), and GitHub's keys.
  dev shell -c 'ssh-add -l >/dev/null 2>&1; echo "agent-rc=$?"; ssh-keygen -F github.com -f /etc/ssh/ssh_known_hosts >/dev/null && echo gh-known; git config --global user.name'
  if [ "$(uname -s)" != "Linux" ] || [ "$(id -u)" = "1000" ]; then
    assert_no_match "$RUN_OUT" 'agent-rc=2' "exec sessions reach the host's SSH agent (no key inside)"
  else
    # dck leaves a Linux host's socket as it is (owner, mode): another uid cannot connect.
    unavailable "exec sessions reach the host's SSH agent (no key inside)" "host uid $(id -u) != container uid 1000: the host socket is not opened up"
  fi
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
  dev shell -c 'head -1 ~/.codex/config.toml; codex features list 2>/dev/null | grep "^daemon_auto_start "'
  assert_contains "$RUN_OUT" "check_for_update_on_startup = false" "Codex skips its startup update check inside (dck pins its version)"
  assert_match "$RUN_OUT" '^daemon_auto_start +[a-z ]+ +false$' "and Codex itself reads daemon_auto_start = false"
  assert_contains "$(cat "$IT_REPO/docker/local/docker-compose.yaml")" "set AGENTKIT_PERMISSIONS=ask in ./app/.env" "the opt-out is documented in compose"

  # 9. The editor: DeepWorkPlan Vim at its pinned tag, plugins built.
  local dtag; dtag="$(sed -n 's/^DWP_VIM_TAG=//p' "$DCK_REPO/images/versions.env")"
  dev shell -c 'git -C ~/.config/nvim describe --tags; timeout 120 nvim --headless +qa && echo nvim-ok'
  assert_contains "$RUN_OUT" "$dtag" "nvim is DeepWorkPlan Vim $dtag"
  assert_contains "$RUN_OUT" "nvim-ok" "nvim starts headless with the baked-in plugins"

  # Host accounts: the env file is rewritten on every `dck up`; a running
  # container must see the new file without a recreate (the directory is bound).
  mkdir -p "$HOME/.config/dck"
  printf 'interface = 2\n[agents]\nhost_profiles = true\nhost_env_keys = ["DCK_IT_HOSTENV"]\n' > "$HOME/.config/dck/profile.toml"
  export DCK_IT_HOSTENV=dck-fake-value-first
  # dck up never recreates a running container on its own: --recreate applies the overlay.
  with_lock d up --recreate
  assert_rc 0 "dck up --recreate with host accounts on"
  local cid1 cid2
  cid1="$(docker inspect -f '{{.Id}}' "${IT_PROJECT}-app-1")"
  run_cmd docker exec -u root "${IT_PROJECT}-app-1" sh -c 'cat "$AGENTKIT_ENV"'
  assert_contains "$RUN_OUT" "DCK_IT_HOSTENV='dck-fake-value-first'" "the env file is visible inside"
  export DCK_IT_HOSTENV=dck-fake-value-second
  with_lock d up
  assert_rc 0 "a second, plain dck up succeeds"
  cid2="$(docker inspect -f '{{.Id}}' "${IT_PROJECT}-app-1")"
  assert_eq "$cid2" "$cid1" "the second up keeps the running container"
  run_cmd docker exec -u root "${IT_PROJECT}-app-1" sh -c 'cat "$AGENTKIT_ENV"'
  assert_contains "$RUN_OUT" "DCK_IT_HOSTENV='dck-fake-value-second'" "the second up's value is visible inside without a recreate"
  rm -f "$HOME/.config/dck/profile.toml"; unset DCK_IT_HOSTENV

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

  # A state volume removed on purpose: a new host key, re-pinned from the container.
  docker volume rm "${IT_PROJECT}_state" >/dev/null
  with_lock dev up
  assert_rc 0 "dev.sh up after removing the state volume"
  wait_port "$port" || fail "sshd answers with its new host key"
  d ssh true
  assert_rc 0 "dck ssh logs in after the state volume was recreated"
  assert_contains "$RUN_ERR" "re-pinned" "the new host key is re-pinned from the container, with a note"
  dev down
}

# A container built from scratch — its volumes removed, then `dck rebuild` —
# reaches the host and its peers without a manual `dck herdr mesh`, and with
# [ssh] copy_keys carries the host's keys. The host's Herdr is the fake one (its
# catalog is a file); ssh reads the sandbox config through a -F wrapper, since
# OpenSSH resolves ~/.ssh from the passwd entry, not $HOME.
test_fresh_rebuild_joins_the_mesh_and_copies_keys() {
  require_docker "a fresh rebuild registers, meshes and copies the host's SSH keys" || return 0
  export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_SSH_CONFIG=/dev/null DCK_HERDR_WAIT=20 DCK_HOST_OS=Darwin
  new_fixture dckfr
  trap it_cleanup EXIT
  local bin="$SANDBOX/itbin" real_ssh port
  real_ssh="$(command -v ssh)"
  mkdir -p "$bin" "$HOME/.ssh"
  ln -s "$TESTS_DIR/fakes/bin/herdr" "$bin/herdr"
  cat > "$bin/ssh" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = -F ] && exec "$real_ssh" "\$@"; done
printf 'Include %s/.ssh/config.d/dck\n' "\$HOME" > "\$HOME/.ssh/it-config"
exec "$real_ssh" -F "\$HOME/.ssh/it-config" "\$@"
SH
  chmod +x "$bin/ssh"
  export PATH="$bin:$PATH"
  port="$(free_port)"
  run_cmd "$DCK" init --repo "$IT_REPO" --flavour debian --ssh-port "$port" --herdr --yes
  assert_rc 0 "dck init renders a Herdr machine"

  # The host's keys (throwaway), the host as a mesh peer, and one more peer.
  ssh-keygen -q -t ed25519 -N '' -C dck-it-copy -f "$HOME/.ssh/id_ed25519"
  ssh-keygen -q -t ed25519 -N '' -C dck-it-listener -f "$SANDBOX/listener"
  mkdir -p "$HOME/.config/dck/ssh"
  printf 'interface = 2\n[ssh]\ncopy_keys = true\n[host]\nmachine = true\nlistener = "external"\nport = 22032\nhost_key = "%s"\nlabel = "Mac"\n[mesh]\nexternal = false\n' \
    "$SANDBOX/listener.pub" > "$HOME/.config/dck/profile.toml"
  python3 -I "$DCK_REPO/lib/dckpy.py" sshconf upsert --file "$HOME/.ssh/config.d/dck" --alias dck-itpeer \
    --host 127.0.0.1 --port 22777 --user dev --identity "$HOME/.config/dck/ssh/id_ed25519" \
    --known-hosts "$HOME/.config/dck/ssh/known_hosts" >/dev/null
  printf 'dck-itpeer %s\n' "$(cut -d' ' -f1-2 "$SANDBOX/listener.pub")" >> "$HOME/.config/dck/ssh/known_hosts"
  herdr machine add --label "Peer" dck-itpeer >/dev/null
  # #21: the host's git identity reaches a container built from scratch (no .env key).
  git config --global user.name "Fixture Host"
  git config --global user.email "fixture-host@example.invalid"

  with_lock d up
  assert_rc 0 "the first dck up"
  d down
  docker volume ls -q --filter "label=com.docker.compose.project=$IT_PROJECT" | xargs -r docker volume rm >/dev/null 2>&1
  run_cmd docker volume ls -q --filter "label=com.docker.compose.project=$IT_PROJECT"
  assert_eq "$RUN_OUT" "" "every volume of the project is removed"
  python3 -I -c 'import json, sys; p = sys.argv[1]; m = json.load(open(p)); json.dump([x for x in m if x["target"] != sys.argv[2]], open(p, "w"))' \
    "$DCK_FAKE_STATE/herdr_machines" "dck-$IT_PROJECT"
  with_lock d rebuild
  assert_rc 0 "dck rebuild from scratch"
  assert_contains "$RUN_OUT$RUN_ERR" "herdr: registered dck-$IT_PROJECT" "rebuild re-adds the removed Herdr machine"
  assert_contains "$RUN_OUT$RUN_ERR" "mesh: 2 peer(s) reachable" "rebuild pushes the mesh"

  d shell -c 'herdr machine list 2>&1; echo ---; grep -h "^Host " ~/.ssh/config.d/dck-peers'
  assert_contains "$RUN_OUT" "Mac" "herdr machine list inside shows the host"
  assert_contains "$RUN_OUT" "Peer" "and the peer"
  assert_contains "$RUN_OUT" "Host dck-itpeer" "the peer is in the ssh config inside"
  assert_contains "$RUN_OUT" "Host dck-host" "and the host"

  # [ssh] copy_keys: the key files, their modes, and the key loads without an agent.
  d shell -c 'ls ~/.ssh; stat -c "%a %n" ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub; env -u SSH_AUTH_SOCK ssh-keygen -y -f ~/.ssh/id_ed25519; test -w ~/.ssh_host || echo host-ro'
  assert_contains "$RUN_OUT" "id_ed25519.pub" "the .pub files are listed in ~/.ssh"
  assert_contains "$RUN_OUT" "600 /home/dev/.ssh/id_ed25519" "the private key is 0600"
  assert_contains "$RUN_OUT" "644 /home/dev/.ssh/id_ed25519.pub" "the public key is 0644"
  assert_contains "$RUN_OUT" "$(cut -d' ' -f1-2 "$HOME/.ssh/id_ed25519.pub")" "the copied private key loads without the agent"
  assert_contains "$RUN_OUT" "host-ro" "the host's ~/.ssh is read-only inside"
  assert_not_contains "$RUN_OUT$RUN_ERR" "$(sed -n 2p "$HOME/.ssh/id_ed25519")" "no key content is printed"
  d doctor
  assert_contains "$RUN_OUT" "ssh keys copied: id_ed25519, id_ed25519.pub" "the doctor names the copied keys"
  assert_contains "$RUN_OUT" "git identity     Fixture Host <fixture-host@example.invalid> (from the host's git config)" "the host's git identity is inside after a fresh rebuild, and the doctor names its source"
  d shell -c 'git config --global user.email'
  assert_eq "$RUN_OUT" "fixture-host@example.invalid" "git inside uses it"
  d down
}

test_python_fixture() {
  require_docker "a rendered python repository builds with its runtime, editor and herdr-peers" || return 0
  export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_SSH_CONFIG=/dev/null
  new_fixture dckpy
  trap it_cleanup EXIT
  printf '[project]\nname = "fixture"\nversion = "0.0.0"\n' > "$IT_REPO/pyproject.toml"
  run_cmd "$DCK" init --repo "$IT_REPO" --ssh-port 0 --no-herdr --state-volume state-py --yes
  assert_rc 0 "dck init renders the python fixture (its own state volume)"
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
  run_cmd docker volume ls -q --filter "label=com.docker.compose.project=$IT_PROJECT"
  assert_contains "$RUN_OUT" "${IT_PROJECT}_state-py" "[compose] state_volume names the state volume"
  assert_no_match "$RUN_OUT" "^${IT_PROJECT}_state\$" "the shared default name is not created"
  dev shell -c 'test -L ~/.ssh && readlink ~/.ssh'
  assert_contains "$RUN_OUT" "/.dck/volumes/state/ssh" "~/.ssh still lives at the same mount point"
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
/app" "dck shell through devcontainer exec runs as remoteUser in workspaceFolder"
  run_cmd docker ps --filter "label=com.docker.compose.project=$IT_PROJECT" --format '{{.Names}}'
  assert_eq "$RUN_OUT" "${IT_PROJECT}-app-1" "the devcontainer CLI used the compose project dck init named"
}

# A product API repository moved onto dck as one service of a multi-service
# compose project (v0.3.3): [compose] project/networks/state_volume, a
# [build] context at the repository root, string port expressions, a user
# block (plain keys plus x-dck-merge) merged at `dck init`, a backing `db`
# service and an `extends` satellite outside the markers.
as_cleanup() {
  it_cleanup
  if [ -n "${IT_PROJECT:-}" ]; then docker image rm "${IT_PROJECT}-worker" >/dev/null 2>&1; fi
  if [ -n "${AS_NET:-}" ]; then docker network rm "$AS_NET" >/dev/null 2>&1; fi
  return 0
}

test_api_stack_shape() {
  require_docker "a multi-service API stack: project, networks, build context, user block, satellites" || return 0
  export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_SSH_CONFIG=/dev/null
  unset DCKAS_WEB_PORT COMPOSE_PROJECT_NAME
  new_fixture dckas
  # [compose] project differs from the repository's default name on purpose.
  IT_PROJECT="${IT_PROJECT}api"
  AS_NET="${IT_PROJECT}-net"
  trap as_cleanup EXIT
  cp -R "$TESTS_DIR/fixtures/api-stack/." "$IT_REPO/"
  local web node compose="$IT_REPO/docker/local/docker-compose.yaml"
  web="$(free_port)"; node="$(free_port)"
  run_cmd "$DCK" init --repo "$IT_REPO" --flavour python-3.13 --ssh-port 0 --no-herdr --no-agents --yes
  assert_rc 0 "dck init renders the API fixture"

  python3 -I -c '
import re, sys
path, project, net, web, node = sys.argv[1:]
text = open(path).read()
def sub(pattern, repl, text):
    new, n = re.subn(pattern, lambda m: repl, text, count=1, flags=re.M)
    if n != 1:
        sys.exit("dck.toml: no line matches %s" % pattern)
    return new
text = sub(r"^ports = .*$", "ports = { web = \"${DCKAS_WEB_PORT:-%s}:8000\", node = \"%s:3000\" }" % (web, node), text)
text = sub(r"^state_volume = .*$", "state_volume = \"state-api\"\nproject = \"%s\"\nnetworks = [\"%s\"]" % (project, net), text)
text = text.rstrip("\n") + "\n\n[build]\ncontext = \"../..\"\n"
open(path, "w").write(text)
' "$IT_REPO/.devcontainer/dck.toml" "$IT_PROJECT" "$AS_NET" "$web" "$node" || fail "dck.toml takes the stack keys"

  python3 -I -c '
import sys
path, svc, net = sys.argv[1:]
end = "  # <<< dck:service <<<\n"
text = open(path).read()
if text.count(end) != 1:
    sys.exit("compose: the dck:service end marker is not there exactly once")
block = """    # >>> user:%(svc)s >>>
    depends_on:
      - db
    x-dck-merge:
      env_file:
        - path: ./django/.env
          required: false
        - ./postgres/.env
      environment:
        DCKAS_MARKER: "from-user-block"
      volumes:
        - sqlite_volume:/app/src/databases
        - ../..:/workspaces-ro:ro
      networks:
        - %(net)s
      command: ["sleep", "infinity"]
    # <<< user:%(svc)s <<<
""" % {"svc": svc, "net": net}
satellites = """  db:
    image: busybox:1.36.1
    command: ["sleep", "infinity"]
  worker:
    extends: %(svc)s
    command: ["sleep", "infinity"]
    ports: !reset []
    depends_on: !reset []
    # A worker needs the code, not the dck service state (sshd key, ~/.ssh, gh auth).
    volumes: !override
      - ../..:/app:cached
""" % {"svc": svc}
open(path, "w").write(text.replace(end, block + end + satellites))
' "$compose" app "$AS_NET" || fail "the user block and satellites are added to the compose file"
  # The stack's own setup step: the database env file exists, the API's does not
  # (required: false keeps compose happy without it).
  cp "$IT_REPO/docker/local/postgres/.env.example" "$IT_REPO/docker/local/postgres/.env"

  run_cmd "$DCK" init --repo "$IT_REPO" --yes
  assert_rc 0 "dck init reconciles with the user block and satellites in place"
  assert_contains "$(cat "$compose")" "    # >>> user:app >>>" "the user block is kept"
  assert_contains "$(cat "$compose")" "  worker:" "the satellite is kept"

  run_cmd bash -c 'cd "$1" && docker compose -f docker/local/docker-compose.yaml config -q' _ "$IT_REPO"
  assert_rc 0 "docker compose config -q accepts the merged file"
  assert_eq "$(grep -c '^networks:' "$compose")" "1" "one top-level networks: block"
  assert_eq "$(grep -c '^volumes:' "$compose")" "1" "one top-level volumes: block"
  assert_eq "$(grep -cE '^  sqlite_volume:' "$compose")" "1" "sqlite_volume is declared once"

  run_cmd bash -c 'cd "$1" && docker compose -f docker/local/docker-compose.yaml config --format json' _ "$IT_REPO"
  assert_rc 0 "docker compose config --format json"
  local facts
  facts="$(printf '%s' "$RUN_OUT" | python3 -I -c '
import json, os, sys
repo, net = sys.argv[1:]
c = json.load(sys.stdin)
app = c["services"]["app"]
out = ["name=%s" % c.get("name")]
for k, v in sorted((c.get("networks") or {}).items()):
    out.append("network=%s external=%s" % (k, bool(v.get("external"))))
for k, v in sorted((c.get("volumes") or {}).items()):
    out.append("volume=%s name=%s" % (k, v.get("name")))
for p in app.get("ports") or []:
    out.append("port=%s:%s:%s" % (p.get("host_ip"), p.get("published"), p.get("target")))
out.extend("app_network=%s" % n for n in sorted(app.get("networks") or {}))
out.append("marker=%s" % (app.get("environment") or {}).get("DCKAS_MARKER"))
out.append("postgres_db=%s" % (app.get("environment") or {}).get("POSTGRES_DB"))
out.append("command=%s" % " ".join(app.get("command") or []))
out.append("depends_on=%s" % ",".join(sorted(app.get("depends_on") or {})))
for m in app.get("volumes") or []:
    out.append("mount=%s:%s:%s" % (m.get("source") if m.get("type") == "volume" else "bind", m.get("target"), "ro" if m.get("read_only") else "rw"))
ctx = (app.get("build") or {}).get("context") or ""
out.append("context_is_repo=%s" % (os.path.realpath(ctx) == os.path.realpath(repo)))
w = c["services"].get("worker") or {}
out.append("worker_ports=%d" % len(w.get("ports") or []))
out.append("worker_depends_on=%d" % len(w.get("depends_on") or {}))
out.append("worker_state=%s" % any(m.get("source") == "state-api" for m in w.get("volumes") or []))
print("\n".join(out))
' "$IT_REPO" "$AS_NET")"
  assert_contains "$facts" "name=$IT_PROJECT" "[compose] project names the compose project"
  assert_contains "$facts" "network=$AS_NET external=True" "the stack network is declared external"
  assert_eq "$(printf '%s\n' "$facts" | grep -c "^network=$AS_NET ")" "1" "the stack network is declared once"
  assert_contains "$facts" "app_network=$AS_NET" "the service joins the stack network"
  assert_contains "$facts" "volume=state-api name=${IT_PROJECT}_state-api" "the state volume is <project>_state-api"
  assert_not_contains "$facts" "volume=state name=" "the default state volume is not declared"
  assert_contains "$facts" "volume=sqlite_volume name=${IT_PROJECT}_sqlite_volume" "the user block's named volume is declared"
  assert_contains "$facts" "port=127.0.0.1:$web:8000" "a port expression is bound to loopback with its default interpolated"
  assert_contains "$facts" "port=127.0.0.1:$node:3000" "a host:container port string is bound to loopback"
  assert_contains "$facts" "marker=from-user-block" "x-dck-merge environment is merged into dck's"
  assert_contains "$facts" "postgres_db=fixture_local" "x-dck-merge env_file is merged (the required file)"
  assert_contains "$facts" "command=sleep infinity" "the x-dck-merge command is the service's"
  assert_contains "$facts" "depends_on=db" "a plain user-block key reaches compose"
  assert_contains "$facts" "mount=sqlite_volume:/app/src/databases:rw" "x-dck-merge volumes are appended (named)"
  assert_contains "$facts" "mount=bind:/workspaces-ro:ro" "x-dck-merge volumes are appended (read-only bind)"
  assert_contains "$facts" "mount=state-api:/home/dev/.dck/volumes/state:rw" "dck's own state mount is still there"
  assert_contains "$facts" "context_is_repo=True" "[build] context is the repository root"
  assert_contains "$facts" "worker_ports=0" "the satellite resets the ports"
  assert_contains "$facts" "worker_depends_on=0" "the satellite resets depends_on"
  assert_contains "$facts" "worker_state=False" "the satellite does not mount the dck state volume"

  docker network create "$AS_NET" >/dev/null
  with_lock d up
  assert_rc 0 "dck up builds (repository-root context) and starts the API service"
  d shell -c 'printf "marker=%s\n" "$DCKAS_MARKER"; printf "pg=%s\n" "$POSTGRES_DB"; printf "django=%s\n" "${DJANGO_DEBUG:-}"
    test -f /workspaces-ro/src/manage.py && echo ro-has-repo
    if touch /workspaces-ro/.dckas-probe 2>/dev/null; then echo ro-writable; else echo ro-readonly; fi
    awk '\''$2=="/workspaces-ro"{split($4,o,","); print "ro-opt=" o[1]} $2=="/app/src/databases"{print "db-mount"}'\'' /proc/mounts
    python3 /app/src/manage.py; whoami'
  assert_rc 0 "dck shell runs in the API service"
  assert_contains "$RUN_OUT" "marker=from-user-block" "the merged environment is seen inside"
  assert_contains "$RUN_OUT" "pg=fixture_local" "the merged env_file is seen inside"
  assert_match "$RUN_OUT" '^django=1$' "an extra env_file that dck up created from its .env.example is merged too"
  assert_contains "$RUN_OUT" "ro-has-repo" "the read-only bind shows the repository"
  assert_contains "$RUN_OUT" "ro-readonly" "the read-only bind refuses writes"
  assert_contains "$RUN_OUT" "ro-opt=ro" "the bind is mounted ro"
  assert_contains "$RUN_OUT" "db-mount" "/app/src/databases is a mount (the named volume)"
  assert_contains "$RUN_OUT" "fixture api: ok" "the fixture app runs from the workspace"
  assert_match "$RUN_OUT" '^dev$' "the API service runs as the dev user"
  run_cmd docker port "${IT_PROJECT}-app-1" 8000
  assert_eq "$RUN_OUT" "127.0.0.1:$web" "the expression port is published on loopback at its default"
  run_cmd docker port "${IT_PROJECT}-app-1" 3000
  assert_eq "$RUN_OUT" "127.0.0.1:$node" "the host:container port is published on loopback"
  run_cmd docker ps --filter "label=com.docker.compose.project=$IT_PROJECT" --filter "label=com.docker.compose.service=db" --format '{{.State}}'
  assert_eq "$RUN_OUT" "running" "depends_on started the db service"

  with_lock run_cmd bash -c 'cd "$1" && docker compose -f docker/local/docker-compose.yaml up -d worker' _ "$IT_REPO"
  assert_rc 0 "the satellite starts"
  run_cmd docker ps --filter "label=com.docker.compose.project=$IT_PROJECT" --filter "label=com.docker.compose.service=worker" --format '{{.State}}|{{.Ports}}'
  assert_eq "$RUN_OUT" "running|" "the satellite runs and publishes no port"
  run_cmd docker volume ls -q --filter "label=com.docker.compose.project=$IT_PROJECT"
  assert_match "$RUN_OUT" "^${IT_PROJECT}_state-api\$" "the state volume is <project>_state-api"
  assert_no_match "$RUN_OUT" "^${IT_PROJECT}_state\$" "the shared default state volume is not created"
  assert_match "$RUN_OUT" "^${IT_PROJECT}_sqlite_volume\$" "the user block's named volume is created"

  d doctor --json
  printf '%s' "$RUN_OUT" | python3 "$TESTS_DIR/py/minischema.py" "$DCK_REPO/docs/schema/dck-doctor-v2.json" >/dev/null
  assert_rc 0 "the live doctor report matches the schema"
  local doc
  doc="$(printf '%s' "$RUN_OUT" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
c = d.get("compose") or {}
print("state=%s" % c.get("state_volume"))
print("services=%s" % ",".join(sorted(c.get("services") or [])))
print("shared=%s" % ",".join(sorted(c.get("shared_with") or [])))
print("compose_problems=%d" % len([p for p in d.get("problems") or [] if p.startswith("compose:")]))
')"
  assert_contains "$doc" "state=${IT_PROJECT}_state-api" "doctor names the per-service state volume"
  assert_contains "$doc" "services=db,worker" "doctor sees the project's other services"
  assert_match "$doc" '^shared=$' "doctor finds the state volume shared with no other service"
  assert_contains "$doc" "compose_problems=0" "doctor reports no compose: shared-state problem"

  d down
  assert_rc 0 "dck down succeeds"
}

# #13: the other services of a shared compose file keep their data volumes. A
# pre-existing <project>_local_postgres14_data (with data in it) must be the
# volume the postgres service mounts after dck init + up, never a new one.
test_shared_stack_data_volume_reattaches() {
  require_docker "a shared stack's existing data volume reattaches after dck init + up" || return 0
  export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_SSH_CONFIG=/dev/null
  new_fixture dckdv
  trap it_cleanup EXIT
  run_cmd "$DCK" init --repo "$IT_REPO" --flavour debian --ssh-port 0 --no-herdr --no-editor --yes
  assert_rc 0 "dck init renders the fixture"
  # The data volume a previous, hand-written compose file created, with data in it.
  docker volume create --label "com.docker.compose.project=$IT_PROJECT" --label com.docker.compose.volume=local_postgres14_data \
    "${IT_PROJECT}_local_postgres14_data" >/dev/null
  docker run --rm -v "${IT_PROJECT}_local_postgres14_data:/data" busybox:1.37 sh -c 'echo kept > /data/marker' >/dev/null 2>&1
  local id_before; id_before="$(docker volume inspect -f '{{.CreatedAt}}' "${IT_PROJECT}_local_postgres14_data")"
  python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace("  # <<< dck:service <<<\n", "  # <<< dck:service <<<\n  postgres:\n    image: busybox:1.37\n    command: [\"sleep\", \"infinity\"]\n    volumes:\n      - local_postgres14_data:/var/lib/postgresql/data\n", 1)
s = s.replace("# <<< dck:volumes <<<\n", "  # >>> user:volumes >>>\n  local_postgres14_data: {}\n  # <<< user:volumes <<<\n# <<< dck:volumes <<<\n", 1)
open(p, "w").write(s)' "$IT_REPO/docker/local/docker-compose.yaml"
  run_cmd "$DCK" init --repo "$IT_REPO" --yes
  assert_rc 0 "dck init keeps the user:volumes block"
  with_lock d up
  assert_rc 0 "dck up starts the stack"
  d up postgres
  assert_rc 0 "and the database service (not in runServices)"
  d exec postgres cat /var/lib/postgresql/data/marker
  assert_eq "$RUN_OUT" "kept" "the postgres service mounts the pre-existing data volume, data intact"
  run_cmd docker volume inspect -f '{{.CreatedAt}}' "${IT_PROJECT}_local_postgres14_data"
  assert_eq "$RUN_OUT" "$id_before" "the very same volume (never recreated)"
  run_cmd docker volume ls -q --filter "label=com.docker.compose.project=$IT_PROJECT"
  assert_eq "$(printf '%s\n' "$RUN_OUT" | grep -c 'local_postgres14_data')" "1" "no second data volume was created"
  d down postgres app
}

# v0.3.5: a workspace under the renamed user's home (a product that keeps its
# node image's user and /home/node/app): the image builds and the user lands there.
test_workspace_under_the_renamed_home() {
  require_docker "a workspace under /home/node builds and runs as node" || return 0
  export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_SSH_CONFIG=/dev/null
  new_fixture dckwh
  trap it_cleanup EXIT
  echo '{"name":"fixture"}' > "$IT_REPO/package.json"
  run_cmd "$DCK" init --repo "$IT_REPO" --flavour node-24 --user node --workspace /home/node/app --ssh-port 0 --no-herdr --no-agents --no-editor --yes
  assert_rc 0 "dck init renders workspace = /home/node/app"
  with_lock d up
  assert_rc 0 "the image builds (usermod -m before WORKDIR) and the container starts"
  d shell -c 'printf "%s|%s|%s|%s|%s\n" "$(whoami)" "$(pwd)" "$HOME" "$(test -f package.json && echo repo)" "$(stat -c %U "$HOME")"'
  assert_eq "$RUN_OUT" "node|/home/node/app|/home/node|repo|node" "the user is node, in /home/node/app with the repository, and owns its home"
  d shell -c 'test -L ~/.ssh && readlink ~/.ssh'
  assert_contains "$RUN_OUT" "/home/node/.dck/volumes/state/ssh" "the state volume is mounted under the renamed home"
  d down
}

# v0.3.5: a workspace satellite through dck — a second instance of the dev
# service in its own compose project, with every host step and a seeded login.
test_workspace_satellite() {
  require_docker "a workspace satellite gets every host step and a seeded login" || return 0
  export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_SSH_CONFIG=/dev/null DCK_HERDR_WAIT=20 DCK_HOST_OS=Darwin
  new_fixture dcksat
  SAT_PROJECT="${IT_PROJECT}sat"
  trap 'it_cleanup; docker ps -aq --filter "label=com.docker.compose.project=$SAT_PROJECT" | xargs -r docker rm -f >/dev/null 2>&1; docker volume ls -q --filter "label=com.docker.compose.project=$SAT_PROJECT" | xargs -r docker volume rm >/dev/null 2>&1; docker image rm "${SAT_PROJECT}-appsatellite" >/dev/null 2>&1; docker network rm "${SAT_PROJECT}_default" >/dev/null 2>&1' EXIT
  local bin="$SANDBOX/itbin" real_ssh port sport
  real_ssh="$(command -v ssh)"
  mkdir -p "$bin" "$HOME/.ssh"
  ln -s "$TESTS_DIR/fakes/bin/herdr" "$bin/herdr"
  cat > "$bin/ssh" <<SH
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = -F ] && exec "$real_ssh" "\$@"; done
printf 'Include %s/.ssh/config.d/dck\n' "\$HOME" > "\$HOME/.ssh/it-config"
exec "$real_ssh" -F "\$HOME/.ssh/it-config" "\$@"
SH
  chmod +x "$bin/ssh"
  export PATH="$bin:$PATH"
  port="$(free_port)"; sport="$(free_port)"
  git config --global user.name "Fixture Host"
  git config --global user.email "fixture-host@example.invalid"
  run_cmd "$DCK" init --repo "$IT_REPO" --flavour debian --ssh-port "$port" --herdr --no-agents --no-editor --yes
  assert_rc 0 "dck init renders the fixture"
  with_lock d up
  assert_rc 0 "the main service is up"
  # A login on the main service's state volume, to seed the satellite from.
  d shell -c 'mkdir -p ~/.config/gh && echo "github.com: {user: fixture}" > ~/.config/gh/hosts.yml'
  # In an overlay file, extends names the file of the service it extends.
  printf 'services:\n  appsatellite:\n    extends:\n      file: docker-compose.yaml\n      service: app\n    profiles: [satellite]\n    ports: !override\n      - "127.0.0.1:%s:22"\n' "$sport" \
    > "$IT_REPO/docker/local/docker-compose.satellite.yaml"
  local sat=(--project "$SAT_PROJECT" --compose-file docker/local/docker-compose.yaml --compose-file docker/local/docker-compose.satellite.yaml --service appsatellite)
  with_lock d "${sat[@]}" up --seed-state-from "${IT_PROJECT}_state" --label "Workspace satellite"
  assert_rc 0 "dck up starts the satellite in its own project"
  assert_contains "$RUN_OUT" "seeded the gh / Dailybot login from ${IT_PROJECT}_state" "its state volume is seeded with the login"
  d "${sat[@]}" ssh 'echo sat-ssh-ok; cat ~/.config/gh/hosts.yml; git config --global user.name; echo "self=$HERDR_PEERS_SELF"'
  assert_rc 0 "sshd in the satellite accepts the dck key"
  assert_contains "$RUN_OUT" "sat-ssh-ok" "dck ssh reaches the satellite"
  assert_contains "$RUN_OUT" "github.com: {user: fixture}" "the seeded gh login is there"
  assert_contains "$RUN_OUT" "Fixture Host" "the host's git identity is set"
  assert_match "$RUN_OUT" '^self=[0-9a-f]{32}$' "HERDR_PEERS_SELF is the satellite's own machine id"
  assert_contains "$(herdr machine list --json)" "dck-${SAT_PROJECT}-appsatellite" "the satellite is a Herdr machine of its own"
  run_cmd docker port "${SAT_PROJECT}-appsatellite-1" 22
  assert_eq "$RUN_OUT" "127.0.0.1:$sport" "on its own port"
  d "${sat[@]}" down
  assert_rc 0 "dck down removes the satellite"
  run_cmd docker ps -a --filter "label=com.docker.compose.project=$SAT_PROJECT" --format '{{.Names}}'
  assert_eq "$RUN_OUT" "" "its container is gone"
  assert_not_contains "$(herdr machine list --json)" "dck-${SAT_PROJECT}-appsatellite" "and its machine"
  run_cmd docker ps --filter "label=com.docker.compose.project=$IT_PROJECT" --format '{{.Names}}'
  assert_eq "$RUN_OUT" "${IT_PROJECT}-app-1" "the main service keeps running"
  assert_contains "$(herdr machine list --json)" "dck-${IT_PROJECT}" "and stays registered"
  d down
}

test_zz_nothing_left_behind() {
  # Runs last in the scope: every container, volume and network a test created is gone.
  require_docker "the docker scope leaves no container, volume or network behind" || return 0
  local left
  left="$( { docker ps -a --format '{{.Names}}'; docker volume ls --format '{{.Name}}'; docker network ls --format '{{.Name}}'; } | grep -E '^(dckit|dckpy|dckdc|dckfr|dckas|dckdv|dckwh|dcksat)[0-9a-f]{8}' || true)"
  assert_eq "$left" "" "the docker scope leaves no container, volume or network behind"
}
