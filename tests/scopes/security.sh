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
  assert_match "$(grep -h 'BASE_IMAGE:' "$SANDBOX/r1/docker/local/docker-compose.yaml")" 'devcontainer-kit-base:python-3\.13-v[0-9]+\.[0-9]+\.[0-9]+' "the base image is pinned to a release tag"
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
