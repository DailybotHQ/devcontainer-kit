# shellcheck shell=bash
# Scope: herdr — `dck herdr add|status|repair|remove` and the SSH include,
# against a fake herdr/ssh/docker and a sandbox ~/.ssh.

DCK="$DCK_REPO/bin/dck"
use_fakes
export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_NO_DIGEST=1 DCK_HERDR_WAIT=1

REPO="$SANDBOX/proj"
INC="$HOME/.ssh/config.d/dck"
mk_repo() {
  local name="${1:-proj}" port="${2:-22040}"
  mkdir -p "$SANDBOX/$name"
  git -C "$SANDBOX/$name" init -q
  "$DCK" init --repo "$SANDBOX/$name" --flavour debian --ssh-port "$port" --herdr --yes >/dev/null 2>&1 || fail "fixture: init $name"
  echo "$name-app-1" > "$DCK_FAKE_STATE/ps"
  : > "$DCK_FAKE_LOG"
}
d() { run_cmd bash -c 'cd "$1" && shift && "$@"' _ "${DREPO:-$REPO}" "$DCK" "$@"; }
machines() { cat "$DCK_FAKE_STATE/herdr_machines" 2>/dev/null || echo "[]"; }

test_add_registers_the_alias() {
  mk_repo
  d herdr add
  assert_rc 0 "herdr add succeeds"
  assert_contains "$(fake_calls herdr)" "herdr machine add --label proj dck-proj" "the machine is registered under its SSH alias"
  assert_contains "$(machines)" '"target": "dck-proj"' "Herdr now knows the machine"
  assert_contains "$(fake_calls ssh)" "ssh -o BatchMode=yes -o ConnectTimeout=3 dck-proj true" "dck waits for sshd through the alias"
  assert_contains "$RUN_OUT" "registered dck-proj as \"proj\"" "the registration is reported"
  assert_contains "$RUN_OUT" "the remote server answers" "the remote server is checked"
}

test_include_file() {
  mk_repo
  d herdr add
  local c; c="$(cat "$INC")"
  assert_contains "$c" "# dck-provenance: v1" "the include carries its provenance header"
  assert_contains "$c" "Host dck-proj" "the alias is defined"
  assert_contains "$c" "  HostName 127.0.0.1" "it connects to loopback"
  assert_contains "$c" "  Port 22040" "on the configured port"
  assert_contains "$c" "  User dev" "as the dev user"
  assert_contains "$c" "  IdentityFile \"$HOME/.config/dck/ssh/id_ed25519\"" "with the dedicated dck key"
  assert_contains "$c" "  IdentitiesOnly yes" "offering no other key"
  assert_contains "$c" "  ForwardAgent yes" "forwarding the agent (keys are never copied)"
  assert_contains "$c" "  StrictHostKeyChecking accept-new" "refusing a changed host key"
  assert_contains "$c" "  HostKeyAlias dck-proj" "keyed by alias, so a reused port never collides"
  assert_contains "$c" "  UserKnownHostsFile \"$HOME/.config/dck/ssh/known_hosts\"" "keeping host keys out of ~/.ssh/known_hosts"
  assert_mode "$INC" 600 "the include is 0600"
  assert_absent "$HOME/.ssh/known_hosts" "~/.ssh/known_hosts does not grow"
  assert_eq "$(head -2 "$HOME/.ssh/config" | tail -1)" "Include config.d/dck" "~/.ssh/config includes it at the top"
}

test_include_keeps_user_config() {
  mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
  printf 'Host github.com\n  User git\n' > "$HOME/.ssh/config"; chmod 600 "$HOME/.ssh/config"
  mk_repo
  d herdr add
  d herdr add
  assert_eq "$(grep -c '^Include config.d/dck$' "$HOME/.ssh/config")" "1" "the Include line is added once"
  assert_contains "$(cat "$HOME/.ssh/config")" "Host github.com
  User git" "the user's own hosts are kept"
  assert_mode "$HOME/.ssh/config" 600 "~/.ssh/config keeps its mode"
}

test_include_refuses_foreign_file() {
  mkdir -p "$HOME/.ssh/config.d"
  printf 'Host mine\n  HostName example.com\n' > "$INC"
  mk_repo
  d herdr add
  assert_rc 5 "a config.d/dck file without dck's header is refused"
  assert_eq "$(cat "$INC")" "Host mine
  HostName example.com" "the foreign file is untouched"
  assert_not_contains "$(fake_calls herdr)" "machine add" "nothing is registered after the refusal"
  rm -f "$INC"; ln -s "$SANDBOX/elsewhere" "$INC"
  d herdr add
  assert_rc 5 "a symlinked include is refused"
}

test_add_authorizes_only_the_public_key() {
  mk_repo
  d herdr add
  assert_contains "$(fake_calls docker)" "exec -T --user dev app bash -c . /usr/local/lib/dck/entrypoint.sh && dck_authorize_keys --add" "the key is authorized through the entrypoint library"
  assert_eq "$(cat "$DCK_FAKE_STATE/exec_stdin")" "$(cat "$HOME/.config/dck/ssh/id_ed25519.pub")" "exactly the public key is sent"
  assert_not_contains "$(cat "$DCK_FAKE_STATE/exec_stdin")" "PRIVATE KEY" "no private key ever leaves the host"
}

test_add_is_idempotent_and_follows_the_label() {
  mk_repo
  d herdr add
  : > "$DCK_FAKE_LOG"
  d herdr add
  assert_rc 0 "a second add succeeds"
  assert_not_contains "$(fake_calls herdr)" "machine add" "a registered machine is not added twice"
  assert_contains "$RUN_OUT" "already registered" "it says so"
  sed -i.orig 's/^label = "{repo}"$/label = "Project {repo}"/' "$REPO/.devcontainer/dck.toml" && rm -f "$REPO/.devcontainer/dck.toml.orig"
  d herdr add
  assert_match "$(fake_calls herdr)" 'machine rename --label Project proj [0-9a-f]{32}' "a changed label renames the machine"
  python3 - "$DCK_FAKE_STATE/herdr_machines" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p)); m[0]["enabled"] = False; json.dump(m, open(p, "w"))
PY
  d herdr add
  assert_match "$(fake_calls herdr)" 'machine enable [0-9a-f]{32}' "a disabled machine is enabled again"
}

test_waits_for_sshd() {
  mk_repo
  echo 255 > "$DCK_FAKE_STATE/ssh_rc"
  d herdr add
  assert_rc 1 "add fails when sshd never answers"
  assert_contains "$RUN_ERR" "does not answer on 127.0.0.1:22040" "the failure names the port"
  assert_not_contains "$(fake_calls herdr)" "machine add" "nothing is registered before sshd answers"
}

test_status() {
  mk_repo
  d herdr status
  assert_rc 0 "status succeeds"
  assert_contains "$RUN_OUT" "registered       no — run: dck herdr add" "an unregistered machine is reported"
  assert_contains "$RUN_OUT" "ssh include      absent" "a missing include is reported"
  d herdr add
  d herdr status
  assert_match "$RUN_OUT" 'registered       yes \(id [0-9a-f]{32}, label "proj", enabled\)' "registration, label and state are shown"
  assert_contains "$RUN_OUT" "sshd answering   yes" "sshd is probed"
  assert_contains "$RUN_OUT" "server answering yes" "the remote server is probed"
  echo 1 > "$DCK_FAKE_STATE/ssh_server_rc"
  d herdr status
  assert_contains "$RUN_OUT" "server answering no" "a silent server is reported"
  assert_contains "$RUN_OUT" "dck herdr repair" "and the repair is suggested"
}

test_repair_disables_then_enables() {
  mk_repo
  d herdr add
  : > "$DCK_FAKE_LOG"
  d herdr repair
  assert_rc 0 "repair succeeds"
  assert_match "$(fake_calls herdr | grep -E 'disable|enable' | tr '\n' '|')" '^herdr machine disable [0-9a-f]{32}\|herdr machine enable [0-9a-f]{32}\|$' "repair disables, then enables the machine"
  assert_contains "$(fake_calls docker)" "dck_authorize_keys --add" "repair re-asserts the key"
  rm -f "$DCK_FAKE_STATE/herdr_machines"
  d herdr repair
  assert_contains "$(fake_calls herdr)" "machine add --label proj dck-proj" "repairing an unregistered machine adds it"
}

test_remove_keeps_other_repositories() {
  mk_repo proj 22040
  DREPO="$SANDBOX/proj" d herdr add
  mk_repo other 22041
  DREPO="$SANDBOX/other" d herdr add
  assert_contains "$(cat "$INC")" "Host dck-other" "a second repository gets its own block"
  DREPO="$SANDBOX/proj" d herdr remove
  assert_rc 0 "remove succeeds"
  assert_match "$(fake_calls herdr)" 'machine remove [0-9a-f]{32}' "the machine is removed from Herdr"
  assert_not_contains "$(cat "$INC")" "Host dck-proj" "its include block is removed"
  assert_contains "$(cat "$INC")" "Host dck-other" "other repositories' blocks are kept"
  assert_not_contains "$(machines)" '"target": "dck-proj"' "Herdr no longer lists it"
  assert_contains "$(machines)" '"target": "dck-other"' "the other machine stays"
}

test_never_touches_herdr_files() {
  mk_repo
  d herdr add
  d herdr repair
  d herdr remove
  assert_absent "$HOME/.config/herdr" "dck writes nothing under ~/.config/herdr"
  assert_absent "$HOME/.local/state/herdr" "dck writes nothing under ~/.local/state/herdr"
  assert_no_match "$(cat "$DCK_REPO/lib/herdr.sh" "$DCK_REPO/lib/sshconf.py")" 'endpoints\.json|\.local/state/herdr' "the code never references Herdr's private state"
}

test_preconditions() {
  mk_repo
  : > "$DCK_FAKE_STATE/ps"
  d herdr add
  assert_rc 1 "add refuses a stopped container"
  assert_contains "$RUN_ERR" "is not running — run: dck up" "and says what to do"
  echo "proj-app-1" > "$DCK_FAKE_STATE/ps"
  sed -i.orig -e 's/^ssh_port = 22040$/ssh_port = 0/' -e 's/^machine = true$/machine = false/' "$REPO/.devcontainer/dck.toml" && rm -f "$REPO/.devcontainer/dck.toml.orig"
  d herdr add
  assert_rc 3 "a repository without sshd cannot be a machine"
  d herdr nope
  assert_rc 2 "an unknown herdr subcommand is a usage error"
}

test_without_herdr_installed() {
  mk_repo
  local bin="$SANDBOX/noherdr" f
  mkdir -p "$bin"
  for f in "$TESTS_DIR"/fakes/bin/*; do [ "$(basename "$f")" = herdr ] || ln -s "$f" "$bin/"; done
  local p="$bin:${PATH#"$TESTS_DIR/fakes/bin:"}"
  # Drop any real herdr from the PATH too.
  p="$(printf '%s' "$p" | tr ':' '\n' | while IFS= read -r dir; do [ -x "$dir/herdr" ] || printf '%s:' "$dir"; done)"
  run_cmd env PATH="${p%:}" bash -c 'cd "$1" && "$2" herdr add' _ "$REPO" "$DCK"
  assert_rc 4 "herdr add without herdr is an environment error"
  run_cmd env PATH="${p%:}" bash -c 'cd "$1" && "$2" up' _ "$REPO" "$DCK"
  assert_rc 0 "up still succeeds without herdr"
  assert_contains "$RUN_OUT" "herdr: not installed on this host; skipping machine registration" "up says why it skipped registration"
}

test_up_registers_when_configured() {
  mk_repo
  d up
  assert_rc 0 "up succeeds"
  local log; log="$(fake_calls | grep -nE 'compose .* up -d|machine add' | cut -d: -f1 | tr '\n' ' ')"
  assert_contains "$(fake_calls herdr)" "machine add --label proj dck-proj" "up registers the machine when dck.toml asks"
  assert_match "$log" '^[0-9]+ [0-9]+ $' "registration happens after the container is up"
}

test_herdr_json_shapes() {
  run_cmd bash -c 'printf "%s" "$1" | python3 -I "$2" herdr find --target dck-a' _ '[{"id":"1","label":"A","target":"dck-a","enabled":false}]' "$DCK_REPO/lib/dckpy.py"
  assert_eq "$RUN_OUT" "1	A	0" "a plain list is read"
  run_cmd bash -c 'printf "%s" "$1" | python3 -I "$2" herdr find --target dck-a' _ 'noise {"result":{"machines":[{"id":"2","label":"B","target":"dck-a"}]}}' "$DCK_REPO/lib/dckpy.py"
  assert_eq "$RUN_OUT" "2	B	1" "a wrapped result with leading noise is read"
  run_cmd bash -c 'printf "[]" | python3 -I "$1" herdr find --target dck-a' _ "$DCK_REPO/lib/dckpy.py"
  assert_rc 1 "no match exits 1"
}

test_mesh_pushes_the_peers() {
  mk_repo other 22041
  DREPO="$SANDBOX/other" d herdr add
  mk_repo proj 22040
  d herdr add
  mkdir -p "$HOME/.config/dck/ssh"
  printf '[127.0.0.1]:22041 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPeerHostKeyFakeOnlyForTests000000000000\n' >> "$HOME/.config/dck/ssh/known_hosts"
  : > "$DCK_FAKE_STATE/exec_stdin"
  d herdr mesh
  assert_rc 0 "herdr mesh succeeds"
  local s; s="$(cat "$DCK_FAKE_STATE/exec_stdin")"
  assert_contains "$s" "peer dck-other 22041 dev other" "the other container is a peer, with its Herdr label"
  assert_not_contains "$s" "peer dck-proj " "the container itself is not its own peer"
  assert_contains "$s" "hostkey 22041 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPeerHostKeyFakeOnlyForTests000000000000" "the peer's pinned host key is pushed"
  assert_no_match "$s" 'PRIVATE KEY|id_ed25519' "no private key material or key path is pushed"
  assert_contains "$(fake_calls docker)" "exec -T --user root app bash -c . /usr/local/lib/dck/entrypoint.sh && dck_mesh_apply" "the payload is applied inside the container"
  assert_contains "$RUN_OUT" "mesh: 1 peer(s) reachable from inside app" "the peer count is reported"
}

test_agents_and_ask() {
  mk_repo
  run_cmd bash -c 'cd "$1" && PATH=/usr/bin:/bin "$2" agents' _ "$REPO" "$DCK"
  assert_ne "$RUN_RC" "0" "without herdr-peers, dck agents fails"
  assert_contains "$RUN_ERR" "herdr-peers is not installed on this host" "and says how to install it, pinned"
  mkdir -p "$SANDBOX/peersbin"
  printf '#!/bin/sh\nprintf "herdr-peers %%s\\n" "$*" >> "%s"\n' "$DCK_FAKE_LOG" > "$SANDBOX/peersbin/herdr-peers"
  chmod +x "$SANDBOX/peersbin/herdr-peers"
  run_cmd bash -c 'cd "$1" && PATH="$3:$PATH" "$2" agents' _ "$REPO" "$DCK" "$SANDBOX/peersbin"
  assert_rc 0 "dck agents runs herdr-peers"
  assert_contains "$(fake_calls herdr-peers)" "herdr-peers list" "dck agents is herdr-peers list"
  run_cmd bash -c 'cd "$1" && PATH="$3:$PATH" "$2" ask dck-other:w1:p2 "which test covers the parser?"' _ "$REPO" "$DCK" "$SANDBOX/peersbin"
  assert_rc 0 "dck ask runs herdr-peers"
  assert_contains "$(fake_calls herdr-peers)" "herdr-peers ask dck-other:w1:p2 which test covers the parser?" "dck ask is herdr-peers ask, with the prompt as one argument"
  run_cmd bash -c 'cd "$1" && PATH="$3:$PATH" "$2" ask justaname "hi"' _ "$REPO" "$DCK" "$SANDBOX/peersbin"
  assert_rc 2 "a target without machine:pane is a usage error"
}
