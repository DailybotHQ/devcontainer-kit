# shellcheck shell=bash
# Scope: entrypoint — lib/entrypoint.sh against a sandbox filesystem root.
# Runs unprivileged: chown is skipped (only attempted as root), system paths
# are prefixed with DCK_ROOT and sshd is a fake.

LIB="$DCK_REPO/lib/entrypoint.sh"

setup_root() {
  export DCK_ROOT="$SANDBOX/root"
  export DCK_USER=dev
  export DCK_HOME="$DCK_ROOT/home/dev"
  export DCK_WORKSPACE="$DCK_ROOT/workspace"
  export DCK_PERSIST_ROOT="$DCK_HOME/.dck/volumes"
  export DCK_SSHD_BIN="$TESTS_DIR/fakes/sbin/sshd"
  mkdir -p "$DCK_HOME" "$DCK_WORKSPACE" "$DCK_PERSIST_ROOT"
}
setup_root

# ep <function> [args...] — call one library function in a fresh bash.
ep() { run_cmd bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@"; }

V="$DCK_PERSIST_ROOT"

test_persist_seeds_on_first_run() {
  mkdir -p "$DCK_HOME/.codex"; echo image > "$DCK_HOME/.codex/config"
  ep dck_persist agents "$DCK_HOME/.codex"
  assert_rc 0 "persist succeeds"
  assert_symlink "$DCK_HOME/.codex" "the target becomes a symlink"
  assert_eq "$(readlink "$DCK_HOME/.codex")" "$V/agents/codex" "it points into the named volume"
  assert_eq "$(cat "$V/agents/codex/config")" "image" "the image's copy seeds an empty volume"
  assert_contains "$RUN_ERR" "seeded agents/codex" "seeding is logged"
}

test_persist_preserves_on_rebuild() {
  mkdir -p "$V/agents/codex"; echo volume > "$V/agents/codex/config"
  # A rebuilt image ships its own (newer) copy at the target.
  mkdir -p "$DCK_HOME/.codex"; echo image > "$DCK_HOME/.codex/config"
  ep dck_persist agents "$DCK_HOME/.codex"
  assert_eq "$(cat "$DCK_HOME/.codex/config")" "volume" "the volume copy wins over the image's"
  assert_contains "$RUN_ERR" "kept agents/codex from the volume" "keeping is logged"
}

test_persist_is_idempotent() {
  ep dck_persist state "$DCK_HOME/.config/gh"
  echo token-file > "$V/state/config_gh/hosts.yml"
  local before; before="$(ls -la "$V/state/config_gh")"
  ep dck_persist state "$DCK_HOME/.config/gh"
  assert_rc 0 "a second persist succeeds"
  assert_eq "$(ls -la "$V/state/config_gh")" "$before" "a second persist changes nothing"
  assert_eq "$RUN_ERR" "" "a second persist is silent"
  assert_symlink "$DCK_HOME/.config/gh" "a missing nested target is created as a link"
}

test_persist_files() {
  echo '{"image":1}' > "$DCK_HOME/.claude.json"
  ep dck_persist agents "$DCK_HOME/.claude.json"
  assert_eq "$(readlink "$DCK_HOME/.claude.json")" "$V/agents/claude.json" "a file is persisted as a file"
  assert_file "$V/agents/claude.json" "the volume holds a regular file"
  assert_eq "$(cat "$DCK_HOME/.claude.json")" '{"image":1}' "the file is seeded"
  ep dck_persist state "$DCK_HOME/.bash_history" file
  assert_file "$V/state/bash_history" "a missing file target gets an empty file"
}

test_persist_replaces_foreign_symlink() {
  mkdir -p "$SANDBOX/elsewhere"
  ln -s "$SANDBOX/elsewhere" "$DCK_HOME/.pi"
  ep dck_persist agents "$DCK_HOME/.pi"
  assert_eq "$(readlink "$DCK_HOME/.pi")" "$V/agents/pi" "a symlink pointing elsewhere is replaced"
  assert_dir "$SANDBOX/elsewhere" "the old link's target is not deleted"
}

test_persist_refusals() {
  ep dck_persist state "/etc/passwd"
  assert_rc 1 "a target outside the home is refused"
  ep dck_persist state "$DCK_HOME/../root"
  assert_rc 1 "a path with .. is refused"
  ep dck_persist "Bad Name" "$DCK_HOME/.x"
  assert_rc 1 "an invalid volume name is refused"
  ep dck_persist state "$DCK_HOME"
  assert_rc 1 "the home directory itself is refused"
  ep dck_persist state "$V/state/x"
  assert_rc 1 "a target inside the volume root is refused"
  assert_absent "$V/state" "a refused call creates nothing"
}

test_env_profile_is_private_and_exact() {
  run_cmd env 'DCK_TEST_SECRET_API_KEY=s3cr3t value $HOME "q"'"'"'s' 'MULTI=a
b' bash -c '. "$1"; dck_env_profile' _ "$LIB"
  assert_rc 0 "the env profile is written"
  local f="$DCK_HOME/.dck/env.sh"
  assert_mode "$f" 600 "env.sh is mode 0600"
  assert_not_contains "$RUN_ERR$RUN_OUT" "s3cr3t" "no value is ever printed"
  assert_match "$RUN_ERR" 'env profile: [0-9]+ variable\(s\)' "only a count is logged"
  assert_not_contains "$(cat "$f")" "export PATH=" "PATH is left to the login shell"
  assert_not_contains "$(cat "$f")" "export HOME=" "HOME is left to the login shell"
  run_cmd env -i bash -c '. "$1"; printf "%s|%s" "$DCK_TEST_SECRET_API_KEY" "$MULTI"' _ "$f"
  assert_eq "$RUN_OUT" 's3cr3t value $HOME "q"'"'"'s|a
b' "sourcing env.sh restores values exactly (quotes, \$, newlines)"
}

test_env_profile_never_follows_a_symlink() {
  mkdir -p "$DCK_HOME/.dck"
  echo "victim" > "$SANDBOX/victim"
  ln -s "$SANDBOX/victim" "$DCK_HOME/.dck/env.sh"
  ep dck_env_profile
  assert_eq "$(cat "$SANDBOX/victim")" "victim" "a planted symlink's target is never written"
  assert_file "$DCK_HOME/.dck/env.sh" "env.sh is a regular file afterwards"
  [ -L "$DCK_HOME/.dck/env.sh" ] && fail "env.sh is still a symlink" || pass "the planted symlink is replaced"
}

KEY1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl dck@host"
KEY2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBy0yQ0ah2/+Pf3pHdgr2UNmIRm6mI2YBwUaMcR2B9Bc other@host"

test_authorized_keys_block() {
  mkdir -p "$DCK_HOME/.ssh"
  printf 'ssh-rsa AAAAB3Nza user-own-key\n' > "$DCK_HOME/.ssh/authorized_keys"
  run_cmd env DCK_AUTHORIZED_KEYS="$KEY1
not a key; rm -rf /" bash -c '. "$1"; dck_authorize_keys' _ "$LIB"
  local ak; ak="$(cat "$DCK_HOME/.ssh/authorized_keys")"
  assert_contains "$ak" "ssh-rsa AAAAB3Nza user-own-key" "keys outside the dck block are kept"
  assert_contains "$ak" "# >>> dck >>>
$KEY1
# <<< dck <<<" "the env key is in the dck block"
  assert_not_contains "$ak" "rm -rf" "a malformed line is never written"
  assert_mode "$DCK_HOME/.ssh/authorized_keys" 600 "authorized_keys is 0600"
  run_cmd bash -c '. "$1"; printf "%s\n" "$2" | dck_authorize_keys --add' _ "$LIB" "$KEY2"
  assert_rc 0 "--add accepts a key on stdin"
  run_cmd bash -c '. "$1"; printf "%s\n" "$2" | dck_authorize_keys --add' _ "$LIB" "$KEY2"
  assert_eq "$(grep -c "other@host" "$DCK_HOME/.ssh/authorized_keys")" "1" "--add never duplicates a key"
  ep dck_authorize_keys
  assert_contains "$(cat "$DCK_HOME/.ssh/authorized_keys")" "$KEY2" "an empty DCK_AUTHORIZED_KEYS leaves the block alone"
  run_cmd bash -c '. "$1"; echo "garbage" | dck_authorize_keys --add' _ "$LIB"
  assert_rc 1 "--add without a valid key fails"
}

test_authorized_keys_under_utf8_locale() {
  # Container images run with LANG=en_US.UTF-8, where [ -~] is not ASCII.
  run_cmd env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 DCK_AUTHORIZED_KEYS="$KEY1" bash -c '. "$1"; dck_authorize_keys' _ "$LIB"
  assert_contains "$(cat "$DCK_HOME/.ssh/authorized_keys" 2>/dev/null)" "$KEY1" "keys validate under a UTF-8 locale"
}

test_sshd_disabled() {
  run_cmd env DCK_SSH=0 bash -c '. "$1"; dck_sshd' _ "$LIB"
  assert_rc 0 "sshd disabled is not an error"
  assert_absent "$V/state/ssh_host_keys" "no host key is generated when sshd is off"
  assert_eq "$(fake_calls sshd)" "" "sshd is not started"
}

test_sshd_runtime_host_key() {
  run_cmd env DCK_SSH=1 DCK_AUTHORIZED_KEYS="$KEY1" bash -c '. "$1"; dck_sshd' _ "$LIB"
  assert_rc 0 "sshd starts"
  local key="$V/state/ssh_host_keys/ssh_host_ed25519_key" conf="$DCK_ROOT/etc/ssh/sshd_config.d/20-dck-runtime.conf"
  assert_file "$key" "an ed25519 host key is generated into the state volume"
  assert_mode "$key" 600 "the private host key is 0600"
  assert_mode "$V/state/ssh_host_keys" 700 "the host key directory is 0700"
  assert_contains "$(cat "$conf")" "HostKey $key" "sshd is pointed at the persistent key"
  assert_contains "$(cat "$conf")" "AllowUsers dev" "only the dev user may log in"
  assert_eq "$(fake_calls sshd | tr '\n' '|')" "sshd -t|sshd |" "the config is tested before sshd starts"
  assert_contains "$(cat "$DCK_HOME/.ssh/authorized_keys")" "$KEY1" "the host's key is authorized"
  local fp1 fp2
  fp1="$(ssh-keygen -lf "$key.pub")"
  run_cmd env DCK_SSH=1 bash -c '. "$1"; dck_sshd' _ "$LIB"
  fp2="$(ssh-keygen -lf "$key.pub")"
  assert_eq "$fp2" "$fp1" "a restart keeps the same host key"
  assert_not_contains "$RUN_ERR" "generated" "no key is regenerated on restart"
}

test_sshd_invalid_config_not_started() {
  touch "$DCK_FAKE_STATE/sshd_test_fail"
  run_cmd env DCK_SSH=1 bash -c '. "$1"; dck_sshd' _ "$LIB"
  assert_rc 1 "an invalid sshd config is reported"
  assert_contains "$RUN_ERR" "configuration invalid, not started" "the reason is logged"
  assert_absent "$DCK_FAKE_STATE/sshd_started" "sshd is not started on a bad config"
  run_cmd env DCK_SSH=1 DCK_SSHD_BIN=/nonexistent/sshd bash -c '. "$1"; dck_sshd' _ "$LIB"
  assert_rc 1 "a missing sshd binary is reported"
}

test_herdr_config_defaults() {
  ep dck_herdr_config
  local c; c="$(cat "$DCK_HOME/.config/herdr/config.toml")"
  assert_contains "$c" "onboarding = false" "onboarding is off"
  assert_contains "$c" "[terminal]" "a terminal table exists"
  assert_contains "$c" 'shell_mode = "login"' "panes are login shells"
  assert_contains "$c" "new_cwd = \"$DCK_WORKSPACE\"" "new panes open in the workspace"
  assert_contains "$c" "allow_nested = true" "nesting inside the host's Herdr is allowed"
  run_cmd python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$DCK_HOME/.config/herdr/config.toml"
  assert_rc 0 "the result is valid TOML"
  local before; before="$(cat "$DCK_HOME/.config/herdr/config.toml")"
  ep dck_herdr_config
  assert_eq "$(cat "$DCK_HOME/.config/herdr/config.toml")" "$before" "a second run changes nothing"
  assert_not_contains "$RUN_ERR" "updated" "an unchanged file is not rewritten"
}

test_herdr_config_respects_user_values() {
  mkdir -p "$DCK_HOME/.config/herdr"
  cat > "$DCK_HOME/.config/herdr/config.toml" <<'EOF'
# my settings
[terminal]
default_shell = "/usr/bin/zsh"
shell_mode = "non_login"

[ui]
mouse_capture = false

[terminal]
new_cwd = "/workspace/sub"

[experimental]
allow_nested = false
EOF
  ep dck_herdr_config
  local c; c="$(cat "$DCK_HOME/.config/herdr/config.toml")"
  assert_contains "$c" "# my settings" "comments are kept"
  assert_contains "$c" 'default_shell = "/usr/bin/zsh"' "a user's shell is kept"
  assert_contains "$c" 'new_cwd = "/workspace/sub"' "a user's new_cwd is kept"
  assert_contains "$c" 'shell_mode = "login"' "shell_mode non_login is repaired"
  assert_contains "$c" "mouse_capture = false" "unrelated settings are kept"
  assert_contains "$c" "allow_nested = true" "allow_nested is forced on"
  assert_eq "$(grep -c '^\[terminal\]' "$DCK_HOME/.config/herdr/config.toml")" "1" "duplicate tables are merged"
  run_cmd python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$DCK_HOME/.config/herdr/config.toml"
  assert_rc 0 "the repaired file is valid TOML"
}

test_repo_hook() {
  ep dck_repo_hook
  assert_rc 0 "no hook is fine"
  mkdir -p "$DCK_WORKSPACE/docker/local"
  printf 'pwd > "%s/hook-ran"\n' "$SANDBOX" > "$DCK_WORKSPACE/docker/local/dev-setup-hook.sh"
  ep dck_repo_hook
  assert_rc 0 "the hook runs"
  assert_eq "$(cat "$SANDBOX/hook-ran" 2>/dev/null)" "$(cd "$DCK_WORKSPACE" && pwd -P)" "the hook runs from the workspace"
  printf 'exit 7\n' > "$DCK_WORKSPACE/docker/local/dev-setup-hook.sh"
  ep dck_repo_hook
  assert_rc 0 "a failing hook never stops the container"
  assert_contains "$RUN_ERR" "exited 7" "a failing hook is reported"
}

test_start_sequence() {
  run_cmd env DCK_SSH=1 DCK_AUTHORIZED_KEYS="$KEY1" FOO=bar bash -c '. "$1"; dck_start' _ "$LIB"
  assert_rc 0 "dck_start completes"
  assert_eq "$(readlink "$DCK_HOME/.ssh")" "$V/state/ssh" "~/.ssh lives on the state volume"
  assert_eq "$(readlink "$DCK_HOME/.config/gh")" "$V/state/config_gh" "gh auth lives on the state volume"
  assert_eq "$(readlink "$DCK_HOME/.config/herdr")" "$V/state/config_herdr" "the Herdr config lives on the state volume"
  assert_file "$V/state/config_herdr/config.toml" "the Herdr config is seeded"
  assert_file "$DCK_HOME/.dck/env.sh" "the env profile is written"
  assert_file "$DCK_FAKE_STATE/sshd_started" "sshd is started"
  assert_contains "$(cat "$V/state/ssh/authorized_keys")" "$KEY1" "the key survives on the volume"
  assert_contains "$RUN_ERR" "ready" "the sequence reports ready"
  run_cmd env DCK_SSH=1 bash -c '. "$1"; dck_start' _ "$LIB"
  assert_rc 0 "a restart completes"
  assert_contains "$(cat "$V/state/ssh/authorized_keys")" "$KEY1" "authorized keys survive a restart without the variable"
}

test_each_function_implemented_once() {
  local fn n
  for fn in dck_persist dck_env_profile dck_sshd dck_herdr_config dck_repo_hook dck_authorize_keys dck_start; do
    n="$(grep -rhE "^$fn\(\) *\{" "$DCK_REPO/lib" "$DCK_REPO/images" "$DCK_REPO/src" 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "$n" "1" "$fn is defined exactly once"
  done
  assert_contains "$(cat "$DCK_REPO/images/common/dck-entrypoint")" ". /usr/local/lib/dck/entrypoint.sh" "the image entrypoint sources the library"
}

test_library_under_system_bash() {
  # /bin/bash is 3.2 on macOS; the library must load and run there too.
  run_cmd /bin/bash -c '. "$1"; dck_persist state "$DCK_HOME/.config/gh" && echo ok' _ "$LIB"
  assert_rc 0 "the library runs under $(/bin/bash -c 'echo $BASH_VERSION')"
  run_cmd bash -n "$LIB"
  assert_rc 0 "the library parses"
}

test_git_identity() {
  local fake="placeholder-$$-mail@example.invalid"
  run_cmd env DCK_GIT_NAME="Dev Example" DCK_GIT_EMAIL="$fake" DCK_GIT_GPG_FORMAT=ssh \
    bash -c '. "$1"; dck_git_identity' _ "$LIB"
  assert_rc 0 "the git identity is written"
  assert_eq "$(HOME="$DCK_HOME" git config --global user.name)" "Dev Example" "user.name comes from DCK_GIT_NAME"
  assert_eq "$(HOME="$DCK_HOME" git config --global user.email)" "$fake" "user.email comes from DCK_GIT_EMAIL"
  assert_eq "$(HOME="$DCK_HOME" git config --global gpg.format || true)" "" "gpg.format alone (no key:: signing key) is not written"
  assert_eq "$(HOME="$DCK_HOME" git config --global user.signingkey || true)" "" "an unset variable leaves its key alone"
  assert_not_contains "$RUN_OUT$RUN_ERR" "$fake" "values are never printed"
  assert_contains "$RUN_ERR" "2 setting(s) written" "only a count is logged"
  # SSH signing with a key:: literal is written; an openpgp key id (a v0.2.0 .env) is not.
  run_cmd env DCK_GIT_GPG_FORMAT=ssh DCK_GIT_SIGNINGKEY="key::ssh-ed25519 AAAAFake" DCK_GIT_COMMIT_GPGSIGN=true \
    bash -c '. "$1"; dck_git_identity' _ "$LIB"
  assert_eq "$(HOME="$DCK_HOME" git config --global gpg.format)" "ssh" "ssh signing settings are written"
  assert_eq "$(HOME="$DCK_HOME" git config --global commit.gpgsign)" "true" "gpgsign is written with a key:: key"
  HOME="$DCK_HOME" git config --global --unset gpg.format; HOME="$DCK_HOME" git config --global --unset commit.gpgsign; HOME="$DCK_HOME" git config --global --unset user.signingkey
  run_cmd env DCK_GIT_SIGNINGKEY=ABCDEF0123456789 DCK_GIT_COMMIT_GPGSIGN=true bash -c '. "$1"; dck_git_identity' _ "$LIB"
  assert_eq "$(HOME="$DCK_HOME" git config --global commit.gpgsign || true)" "" "openpgp signing from an old .env is skipped"
  assert_contains "$RUN_ERR" "signing settings skipped" "and the log says why"
}

test_hostssh_apply() {
  local payload
  payload="$(printf '%s\n' \
    'pub work ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIWorkKeyFakeOnlyForTests000000000000000' \
    'pub ../evil ssh-ed25519 AAAA' \
    'host github.com-work github.com 22 git work' \
    'host plain github.com 22 - work' \
    'host nopub example.org 22 git missing' \
    'host bad;alias example.org 22 git work' \
    'host local 127.0.0.1 22 git work' \
    'kh github.com 22 ssh-ed25519 AAAAGitHubFake' \
    'kh example.net 2222 ssh-ed25519 AAAAIncludedFake' \
    'something else')"
  run_cmd bash -c '. "$1"; printf "%s\n" "$2" | dck_hostssh_apply' _ "$LIB" "$payload"
  assert_rc 0 "the host aliases apply"
  local frag="$DCK_HOME/.ssh/config.d/dck-host"
  assert_contains "$(cat "$frag")" "Host github.com-work" "an alias gets a Host block"
  assert_contains "$(cat "$frag")" "IdentityFile $DCK_HOME/.ssh/dck-host-keys/work.pub" "it points at the public half"
  assert_contains "$(cat "$frag")" "IdentitiesOnly yes" "only that key is offered"
  assert_not_contains "$(cat "$frag")" "Host nopub" "an alias without its public key is refused"
  assert_not_contains "$(cat "$frag")" "bad;alias" "an unsafe alias is refused"
  assert_not_contains "$(cat "$frag")" "Host local" "a loopback host is refused"
  assert_contains "$(cat "$DCK_HOME/.ssh/dck-host-keys/work.pub")" "ssh-ed25519 AAAAC3Nza" "the public key is written"
  assert_eq "$(ls "$DCK_HOME/.ssh/dck-host-keys" | tr '\n' ' ')" "work.pub " "only valid key names are written"
  assert_contains "$(cat "$DCK_HOME/.ssh/known_hosts.dck-host")" "github.com ssh-ed25519 AAAAGitHubFake" "trusted host keys are pinned"
  assert_contains "$(cat "$DCK_HOME/.ssh/known_hosts.dck-host")" "[example.net]:2222 ssh-ed25519 AAAAIncludedFake" "with their port"
  assert_eq "$(head -1 "$DCK_HOME/.ssh/config")" "Include config.d/dck-host" "the aliases are included first"
  assert_no_match "$(cat "$frag" "$DCK_HOME/.ssh/dck-host-keys/work.pub")" 'PRIVATE KEY' "no private key material"
}

test_mesh_apply() {
  local payload
  payload="$(printf '%s\n' \
    'peer dck-other 22041 dev other label' \
    'peer dck-host 22 alice host' \
    'hostkey 22041 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPeerHostKeyFakeOnlyForTests000000000000' \
    'hostkey 22 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostHostKeyFakeOnlyForTests00000000000000' \
    'peer bad;alias 22042 dev x' \
    'peer dck-bad x dev x' \
    'peer dck-bad2 22043 Root x' \
    'hostkey 22041 ssh-dss AAAA' \
    'something else entirely')"
  run_cmd bash -c '. "$1"; printf "%s\n" "$2" | dck_mesh_apply' _ "$LIB" "$payload"
  assert_rc 0 "the mesh applies"
  local frag="$DCK_HOME/.ssh/config.d/dck-peers" known="$DCK_HOME/.ssh/known_hosts.dck-peers"
  assert_contains "$(cat "$frag")" "Host dck-other" "a valid peer gets an ssh host"
  assert_contains "$(cat "$frag")" "HostName host.docker.internal" "peers are reached through the host gateway"
  assert_contains "$(cat "$frag")" "ForwardAgent no" "the agent is never forwarded to a peer (no key inside)"
  assert_not_contains "$(cat "$frag")" "ForwardAgent yes" "no peer gets agent forwarding"
  assert_contains "$(cat "$frag")" "StrictHostKeyChecking yes" "host keys are strict"
  assert_contains "$(cat "$frag")" "Host dck-host" "the host is a peer when pushed"
  assert_not_contains "$(cat "$frag")" "bad" "invalid aliases, ports and users are refused"
  assert_contains "$(cat "$known")" "[host.docker.internal]:22041 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPeerHostKeyFakeOnlyForTests000000000000" "the peer key is pinned on its gateway port"
  assert_contains "$(cat "$known")" "host.docker.internal ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostHostKeyFakeOnlyForTests00000000000000" "the host key is pinned on port 22"
  assert_not_contains "$(cat "$known")" "ssh-dss" "an unknown key type is refused"
  assert_eq "$(head -1 "$DCK_HOME/.ssh/config")" "Include config.d/dck-peers" "the ssh config includes the peers first"
  assert_mode "$frag" 600 "the peers file is private"
  assert_contains "$RUN_ERR" "mesh: 2 peer(s) written" "the count is logged"
  run_cmd bash -c '. "$1"; printf "%s\n" "$2" | dck_mesh_apply' _ "$LIB" "$payload"
  assert_eq "$(grep -c '^Include config.d/dck-peers$' "$DCK_HOME/.ssh/config")" "1" "the include is written once"
}

test_skills_link() {
  local src="$SANDBOX/skills-src"
  mkdir -p "$src/herdr-peers" "$src/herdr" "$DCK_HOME/.claude/skills/herdr"
  echo mine > "$DCK_HOME/.claude/skills/herdr/SKILL.md"
  run_cmd env DCK_SKILLS_SRC="$src" bash -c '. "$1"; dck_skills_link' _ "$LIB"
  assert_rc 0 "skills link"
  assert_symlink "$DCK_HOME/.agents/skills/herdr-peers" "herdr-peers is linked into ~/.agents/skills"
  assert_symlink "$DCK_HOME/.claude/skills/herdr-peers" "herdr-peers is linked into ~/.claude/skills"
  assert_eq "$(cat "$DCK_HOME/.claude/skills/herdr/SKILL.md")" "mine" "a skill directory the user put there is never replaced"
}
