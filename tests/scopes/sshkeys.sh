# shellcheck shell=bash
# Scope: sshkeys — [ssh] copy_keys: the host's ~/.ssh/id_* keys inside a
# container (config, the runtime overlay, the entrypoint's copy with its modes,
# refresh, never-overwrite and off-removes rules, and the doctor's report).
# Keys are throwaway ones generated in the sandbox; their contents must never
# appear in any output.

DCK="$DCK_REPO/bin/dck"
LIB="$DCK_REPO/lib/entrypoint.sh"
use_fakes
export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_NO_DIGEST=1

REPO="$SANDBOX/proj"

mk_repo() {
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  "$DCK" init --repo "$REPO" --flavour node-24 --no-herdr --yes >/dev/null 2>&1 \
    || { fail "fixture: dck init failed"; return 1; }
  : > "$DCK_FAKE_LOG"
}

# mk_keys <dir> — throwaway ed25519 and rsa keys plus files that must never be copied.
mk_keys() {
  mkdir -p "$1"
  chmod 700 "$1"
  ssh-keygen -q -t ed25519 -N '' -C "dck-test" -f "$1/id_ed25519" || fail "fixture: ssh-keygen ed25519"
  ssh-keygen -q -t rsa -b 2048 -N '' -C "dck-test" -f "$1/id_rsa" || fail "fixture: ssh-keygen rsa"
  printf 'Host example\n  User host-config\n' > "$1/config"
  printf 'host-known\n' > "$1/known_hosts"
  printf 'ssh-ed25519 AAAA host-authorized\n' > "$1/authorized_keys"
  ln -s "$1/id_ed25519" "$1/id_linked"
}

profile() {
  mkdir -p "$HOME/.config/dck"
  printf 'interface = 2\n[ssh]\n%s\n' "$1" > "$HOME/.config/dck/profile.toml"
}

up() { run_cmd bash -c 'cd "$1" && shift && env "$@"' _ "$REPO" TMPDIR="$SANDBOX/tmp" "$DCK" up; }
overlay() { printf '%s/tmp/dck-%s/proj-sshkeys.yml' "$SANDBOX" "$(id -u)"; }

# The private key's base64 body: a line no output may ever contain.
secret_line() { sed -n 2p "$1"; }

# --- config ----------------------------------------------------------------

test_config_accepts_copy_keys_in_the_host_profile() {
  local f="$SANDBOX/p.toml"
  printf 'interface = 2\n[ssh]\ncopy_keys = true\n' > "$f"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config validate --kind profile "$f"
  assert_rc 0 "the host profile accepts [ssh] copy_keys"
  printf 'interface = 2\n[ssh]\ncopy_keys = "yes"\n' > "$f"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config validate --kind profile "$f"
  assert_rc 3 "a non-boolean is refused"
  assert_contains "$RUN_ERR" "ssh.copy_keys: expected a boolean" "and named"
  run_cmd python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import config; print(config.validate({}, "profile")[0]["ssh.copy_keys"])' "$DCK_REPO/lib"
  assert_eq "$RUN_OUT" "False" "off by default"
}

test_a_repository_cannot_turn_it_on() {
  mk_repo || return 0
  mk_keys "$HOME/.ssh"
  printf '\n[ssh]\ncopy_keys = true\n' >> "$REPO/.devcontainer/dck.toml"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config show --repo "$REPO" --format json
  assert_rc 0 "the repository config still loads"
  assert_contains "$RUN_ERR" "ssh.copy_keys is a host-profile setting" "copy_keys in a repository is reported as ignored"
  up
  assert_rc 0 "dck up succeeds"
  assert_not_file "$(overlay)" "no ssh-keys overlay on a repository's request"
  assert_not_contains "$(fake_calls docker)" "-sshkeys.yml" "compose is not given one"
}

# --- the runtime overlay ---------------------------------------------------

test_off_writes_nothing() {
  mk_repo || return 0
  mk_keys "$HOME/.ssh"
  up
  assert_rc 0 "dck up succeeds"
  assert_not_file "$(overlay)" "no overlay while copy_keys is off (the default)"
  assert_not_contains "$RUN_OUT$RUN_ERR" "ssh keys" "nothing about ssh keys is printed"
}

test_up_binds_the_host_ssh_read_only() {
  mk_repo || return 0
  mk_keys "$HOME/.ssh"
  profile 'copy_keys = true'
  up
  assert_rc 0 "dck up succeeds with copy_keys"
  local ov o
  ov="$(overlay)"
  assert_file "$ov" "the runtime overlay is written outside the repository"
  assert_mode "$ov" 600 "the overlay is private"
  assert_contains "$(fake_calls docker)" "-f $ov up -d" "compose is given the overlay"
  o="$(cat "$ov")"
  assert_contains "$o" "source: \"$(cd -P "$HOME/.ssh" && pwd)\"" "the host's ~/.ssh is the source"
  assert_contains "$o" 'target: "/home/dev/.ssh_host"' "bound at ~/.ssh_host"
  assert_contains "$o" "read_only: true" "read-only"
  assert_contains "$o" "create_host_path: false" "never created on the host"
  assert_contains "$o" 'DCK_SSH_COPY_KEYS: "1"' "the entrypoint is told to copy"
  assert_contains "$RUN_OUT$RUN_ERR" "copied at start: id_ed25519 id_ed25519.pub id_rsa id_rsa.pub" "dck up names the keys"
  assert_not_contains "$RUN_OUT$RUN_ERR" "id_linked" "a symlinked key is not offered"
  assert_not_contains "$RUN_OUT$RUN_ERR$o" "$(secret_line "$HOME/.ssh/id_ed25519")" "no key content is printed or written"
  assert_eq "$(git -C "$REPO" status --porcelain --ignored | grep -c sshkeys || true)" "0" "nothing is written into the repository"
  # Off again: the overlay is removed and compose no longer gets it.
  profile 'copy_keys = false'
  : > "$DCK_FAKE_LOG"
  up
  assert_rc 0 "dck up succeeds after turning it off"
  assert_not_file "$ov" "turning copy_keys off removes the overlay"
  assert_not_contains "$(fake_calls docker)" "-sshkeys.yml" "and compose is not given it"
}

test_on_without_a_host_ssh_dir() {
  mk_repo || return 0
  profile 'copy_keys = true'
  up
  assert_rc 0 "dck up succeeds without ~/.ssh on the host"
  assert_not_file "$(overlay)" "nothing to bind: no overlay"
  assert_contains "$RUN_OUT$RUN_ERR" "copy_keys is on, but the host has no" "and it says why"
  assert_not_contains "$RUN_OUT$RUN_ERR" "bound read-only" "and never claims a bind"
}

test_config_verb_reports_the_opt_in() {
  mk_repo || return 0
  run_cmd bash -c 'cd "$1" && "$2" config' _ "$REPO" "$DCK"
  assert_contains "$RUN_OUT$RUN_ERR" "ssh keys copy    off" "dck config reports it off"
  profile 'copy_keys = true'
  run_cmd bash -c 'cd "$1" && "$2" config' _ "$REPO" "$DCK"
  assert_contains "$RUN_OUT$RUN_ERR" "ssh keys copy    on" "and on"
}

# --- the entrypoint --------------------------------------------------------

# ep [VAR=value...] — dck_ssh_copy_keys against a sandbox home.
CH="$SANDBOX/h"
ep() {
  run_cmd env DCK_USER="$(id -un)" DCK_HOME="$CH" DCK_WORKSPACE=/app "$@" \
    bash -c '. "$1"; dck_ssh_copy_keys' _ "$LIB"
}

mk_container() {
  mk_keys "$CH/.ssh_host"
  mkdir -p "$CH/.ssh/config.d"
  printf 'dck config\n' > "$CH/.ssh/config"
  printf 'dck fragment\n' > "$CH/.ssh/config.d/dck-host"
  printf 'dck authorized\n' > "$CH/.ssh/authorized_keys"
  printf 'dck known\n' > "$CH/.ssh/known_hosts.dck-host"
}

test_copy_keys_copies_with_modes() {
  mk_container
  chmod 0755 "$CH/.ssh"
  ep DCK_SSH_COPY_KEYS=1
  assert_rc 0 "the copy succeeds"
  local k
  for k in id_ed25519 id_rsa; do
    assert_eq "$(cmp -s "$CH/.ssh_host/$k" "$CH/.ssh/$k" && echo same)" "same" "$k is copied"
    assert_mode "$CH/.ssh/$k" 600 "$k is 0600"
    assert_eq "$(cmp -s "$CH/.ssh_host/$k.pub" "$CH/.ssh/$k.pub" && echo same)" "same" "$k.pub is copied"
    assert_mode "$CH/.ssh/$k.pub" 644 "$k.pub is 0644"
  done
  assert_mode "$CH/.ssh" 700 "the container's .ssh is 0700"
  assert_eq "$(cat "$CH/.ssh/.dck-copied-keys")" "id_ed25519
id_ed25519.pub
id_rsa
id_rsa.pub" "the manifest lists the copied names"
  assert_mode "$CH/.ssh/.dck-copied-keys" 600 "the manifest is 0600"
  assert_contains "$RUN_ERR" "ssh keys copied: id_ed25519 id_ed25519.pub id_rsa id_rsa.pub" "the names are logged"
  assert_not_contains "$RUN_OUT$RUN_ERR" "$(secret_line "$CH/.ssh_host/id_ed25519")" "never a key's contents"
  assert_absent "$CH/.ssh/id_linked" "a symlinked key on the host is not followed"
  ssh-keygen -y -f "$CH/.ssh/id_ed25519" > "$SANDBOX/derived.pub" 2>/dev/null
  assert_eq "$(cut -d' ' -f1-2 "$SANDBOX/derived.pub")" "$(cut -d' ' -f1-2 "$CH/.ssh_host/id_ed25519.pub")" "the copied private key loads without an agent"
}

test_copy_keys_never_touches_dck_files() {
  mk_container
  ep DCK_SSH_COPY_KEYS=1
  assert_eq "$(cat "$CH/.ssh/config")" "dck config" "dck's config is never overwritten"
  assert_eq "$(cat "$CH/.ssh/config.d/dck-host")" "dck fragment" "nor config.d/"
  assert_eq "$(cat "$CH/.ssh/authorized_keys")" "dck authorized" "nor authorized_keys"
  assert_eq "$(cat "$CH/.ssh/known_hosts.dck-host")" "dck known" "nor known_hosts.dck-host"
  assert_absent "$CH/.ssh/known_hosts" "the host's known_hosts is not copied"
  assert_eq "$(cat "$CH/.ssh_host/config")" "Host example
  User host-config" "the host's files are untouched"
}

test_copy_keys_refreshes_and_follows_the_host() {
  mk_container
  ep DCK_SSH_COPY_KEYS=1
  rm -f "$CH/.ssh_host/id_ed25519" "$CH/.ssh_host/id_ed25519.pub"
  ssh-keygen -q -t ed25519 -N '' -C "dck-test-2" -f "$CH/.ssh_host/id_ed25519"
  rm -f "$CH/.ssh_host/id_rsa" "$CH/.ssh_host/id_rsa.pub"
  ep DCK_SSH_COPY_KEYS=1
  assert_rc 0 "a second start succeeds"
  assert_eq "$(cmp -s "$CH/.ssh_host/id_ed25519" "$CH/.ssh/id_ed25519" && echo same)" "same" "a key changed on the host is refreshed"
  assert_contains "$(cat "$CH/.ssh/id_ed25519.pub")" "dck-test-2" "with its .pub"
  assert_mode "$CH/.ssh/id_ed25519" 600 "still 0600"
  assert_absent "$CH/.ssh/id_rsa" "a key removed from the host is removed"
  assert_absent "$CH/.ssh/id_rsa.pub" "with its .pub"
  assert_eq "$(cat "$CH/.ssh/.dck-copied-keys")" "id_ed25519
id_ed25519.pub" "the manifest follows"
  local left; left="$(find "$CH/.ssh" -maxdepth 1 -name '.dck-key.*' | wc -l | tr -d ' ')"
  assert_eq "$left" "0" "no temporary file is left behind"
}

test_copy_keys_keeps_the_containers_own_key() {
  mk_container
  ssh-keygen -q -t ed25519 -N '' -C "made-inside" -f "$CH/.ssh/id_ed25519"
  ep DCK_SSH_COPY_KEYS=1
  assert_contains "$(cat "$CH/.ssh/id_ed25519.pub")" "made-inside" "a key the container made is never overwritten"
  assert_contains "$RUN_ERR" "kept the container's own: id_ed25519 id_ed25519.pub" "and that is logged"
  assert_eq "$(cmp -s "$CH/.ssh_host/id_rsa" "$CH/.ssh/id_rsa" && echo same)" "same" "the other keys are still copied"
  assert_not_contains "$(cat "$CH/.ssh/.dck-copied-keys")" "id_ed25519" "a kept key is not in the manifest"
  ln -s /etc/passwd "$CH/.ssh/id_planted" 2>/dev/null
  printf 'x\n' > "$CH/.ssh_host/id_planted"
  ep DCK_SSH_COPY_KEYS=1
  assert_symlink "$CH/.ssh/id_planted" "a symlink in the container's ~/.ssh is never written through"
}

test_off_copies_nothing_and_removes_what_was_copied() {
  mk_container
  ep
  assert_rc 0 "off is a no-op"
  assert_absent "$CH/.ssh/id_ed25519" "off copies nothing"
  assert_absent "$CH/.ssh/.dck-copied-keys" "and writes no manifest"
  assert_eq "$RUN_ERR" "" "and says nothing"
  ep DCK_SSH_COPY_KEYS=1
  printf 'mine\n' > "$CH/.ssh/id_mine"
  ep DCK_SSH_COPY_KEYS=0
  assert_absent "$CH/.ssh/id_ed25519" "turning it off removes the copied keys at the next start"
  assert_absent "$CH/.ssh/id_rsa.pub" "every one of them"
  assert_absent "$CH/.ssh/.dck-copied-keys" "and the manifest"
  assert_eq "$(cat "$CH/.ssh/id_mine")" "mine" "a key dck did not copy is kept"
  assert_eq "$(cat "$CH/.ssh/config")" "dck config" "dck's own files are kept"
  assert_contains "$RUN_ERR" "copy_keys is off; removed 4 copied key file(s)" "the removal is logged"
}

test_on_without_the_mount() {
  mkdir -p "$CH/.ssh"
  ep DCK_SSH_COPY_KEYS=1
  assert_rc 0 "a missing mount never fails the start"
  assert_contains "$RUN_ERR" "is not mounted" "and is reported"
}

test_dck_start_runs_the_copy() {
  assert_contains "$(sed -n '/^dck_start() {/,/^}/p' "$LIB")" "dck_ssh_copy_keys || true" "dck_start copies the keys, never failing the start"
  local start persist copy
  start="$(sed -n '/^dck_start() {/,/^}/p' "$LIB")"
  persist="$(printf '%s\n' "$start" | grep -n 'dck_persist state "$DCK_HOME/.ssh"' | cut -d: -f1)"
  copy="$(printf '%s\n' "$start" | grep -n 'dck_ssh_copy_keys' | cut -d: -f1)"
  assert_eq "$([ "$persist" -lt "$copy" ] && echo after)" "after" "after ~/.ssh is on the state volume"
}

# --- the doctor ------------------------------------------------------------

test_doctor_reports_state_and_names() {
  mk_repo || return 0
  mk_keys "$HOME/.ssh"
  run_cmd bash -c 'cd "$1" && "$2" doctor' _ "$REPO" "$DCK"
  assert_contains "$RUN_OUT" "ssh keys         off ([ssh] copy_keys in the host profile)" "the doctor reports the opt-in off"
  profile 'copy_keys = true'
  run_cmd bash -c 'cd "$1" && "$2" doctor' _ "$REPO" "$DCK"
  assert_contains "$RUN_OUT" "ssh keys         copy_keys on; copied at the next start: id_ed25519, id_ed25519.pub, id_rsa, id_rsa.pub" "without a container: what the next start copies"
  printf 'proj-app-1\trunning\n' > "$DCK_FAKE_STATE/ps"
  printf 'id_ed25519\nid_ed25519.pub\n../evil\n' > "$DCK_FAKE_STATE/container_ssh_manifest"
  run_cmd bash -c 'cd "$1" && "$2" doctor' _ "$REPO" "$DCK"
  assert_contains "$RUN_OUT" "ssh keys         copy_keys on; ssh keys copied: id_ed25519, id_ed25519.pub" "with a running container: the names it copied"
  assert_not_contains "$RUN_OUT" "evil" "a name that is not a key name is dropped"
  assert_not_contains "$RUN_OUT$RUN_ERR" "$(secret_line "$HOME/.ssh/id_ed25519")" "the doctor never prints a key"
  run_cmd bash -c 'cd "$1" && "$2" doctor --json' _ "$REPO" "$DCK"
  local json="$RUN_OUT" r
  r="$(printf '%s' "$json" | python3 "$TESTS_DIR/py/minischema.py" "$DCK_REPO/docs/schema/dck-doctor-v2.json" 2>&1)"
  assert_eq "$r" "" "doctor --json with ssh_keys matches its schema"
  run_cmd python3 -I -c '
import json, sys
k = json.loads(sys.argv[1])["ssh_keys"]
assert k["enabled"] and k["copied"] == ["id_ed25519", "id_ed25519.pub"], k
assert k["host_keys"] == ["id_ed25519", "id_ed25519.pub", "id_rsa", "id_rsa.pub"], k
print("ok")' "$json"
  assert_eq "$RUN_OUT" "ok" "doctor --json reports the state and the names"
}

# --- dck setup offers it ---------------------------------------------------

setup_with() { run_cmd bash -c 'cd "$1" && shift && env "$@"' _ "$REPO" "$@" "$DCK" setup; }

test_setup_offers_and_records_yes() {
  mk_repo || return 0
  mk_keys "$HOME/.ssh"
  mkdir -p "$HOME/.config/dck"
  printf 'interface = 2\n\n[ssh]\nhost_extra = ["box"]\n\n[mesh]\nexternal = true\n' > "$HOME/.config/dck/profile.toml"
  setup_with DCK_COPY_KEYS_ANSWER=y
  assert_rc 0 "setup succeeds"
  assert_contains "$RUN_OUT$RUN_ERR" "recorded [ssh] copy_keys = true" "a yes is recorded"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config validate --kind profile "$HOME/.config/dck/profile.toml"
  assert_rc 0 "the profile stays valid (copy_keys joins the existing [ssh] table)"
  assert_eq "$(grep -c '^\[ssh\]' "$HOME/.config/dck/profile.toml")" "1" "no second [ssh] table"
  assert_contains "$(cat "$HOME/.config/dck/profile.toml")" 'host_extra = ["box"]' "the existing settings are kept"
  assert_eq "$(python3 -I "$DCK_REPO/lib/dckpy.py" config copy-keys)" "true" "copy_keys reads back true"
  : > "$DCK_FAKE_LOG"
  setup_with DCK_COPY_KEYS_ANSWER=n
  assert_not_contains "$RUN_OUT$RUN_ERR" "copy_keys" "a recorded answer is never asked again or changed"
  assert_eq "$(python3 -I "$DCK_REPO/lib/dckpy.py" config copy-keys)" "true" "still true"
}

test_setup_records_no_and_the_default_stays_off() {
  mk_repo || return 0
  mk_keys "$HOME/.ssh"
  setup_with DCK_COPY_KEYS_ANSWER=n
  assert_rc 0 "setup succeeds"
  assert_contains "$RUN_OUT$RUN_ERR" "recorded [ssh] copy_keys = false" "a no is recorded"
  assert_contains "$(cat "$HOME/.config/dck/profile.toml")" "[ssh]" "in a new [ssh] table"
  assert_eq "$(python3 -I "$DCK_REPO/lib/dckpy.py" config copy-keys)" "false" "copy_keys reads back false"
  rm -f "$HOME/.config/dck/profile.toml"
  setup_with
  assert_contains "$RUN_OUT$RUN_ERR" "[ssh] copy_keys = true in your host profile" "non-interactive setup only points at the setting"
  assert_absent "$HOME/.config/dck/profile.toml" "and records nothing (off by default)"
}

test_setup_does_not_offer_without_keys() {
  mk_repo || return 0
  setup_with DCK_COPY_KEYS_ANSWER=y
  assert_not_contains "$RUN_OUT$RUN_ERR" "copy_keys" "no id_* key on the host: nothing to offer"
}
