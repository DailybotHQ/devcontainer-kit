# shellcheck shell=bash
# Scope: agents — [agents] host_profiles: the host's agent accounts inside a
# container (config, the runtime overlay and its mount modes, the env file
# without implicit secrets, the doctor's report) and the entrypoint's
# unattended-launch trust.

DCK="$DCK_REPO/bin/dck"
use_fakes
export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_NO_DIGEST=1

REPO="$SANDBOX/proj"
# Fake values: they must never appear outside the generated env file.
FAKE_VALUE_A="dck-fake-value-aaaa"
FAKE_VALUE_B="dck-fake-value-bbbb"
FAKE_VALUE_C="dck-fake-value-cccc"
FAKE_VALUE_D="dck-fake-value-dddd"
FAKE_VALUE_E="dck-fake-value-eeee"
PROFILES="$HOME/.local/share/agentkit/profiles"

mk_repo() {
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  "$DCK" init --repo "$REPO" --flavour node-24 --agents --clis "${1:-claude codex cursor pi}" --no-herdr --yes >/dev/null 2>&1 \
    || { fail "fixture: dck init failed"; return 1; }
  : > "$DCK_FAKE_LOG"
}

# The host side: ak profiles claude @work1 @team-b, codex @work1, cursor @work1,
# the Codex home and an ak env file (with a token of a profile that does not exist).
mk_host() {
  mkdir -p "$PROFILES/claude/work1" "$PROFILES/claude/team-b" "$PROFILES/codex/work1" \
           "$PROFILES/cursor/work1" "$HOME/.codex" "$HOME/.config/agentkit"
  cat > "$HOME/.config/agentkit/env" <<EOF
# ak env file
CLAUDE_CODE_OAUTH_TOKEN='$FAKE_VALUE_A'
export CLAUDE_CODE_OAUTH_TOKEN_WORK1="$FAKE_VALUE_B"
CLAUDE_CODE_OAUTH_TOKEN_GONE='$FAKE_VALUE_D'
OPENAI_API_KEY=$FAKE_VALUE_C
XAI_API_KEY=\$(cat /somewhere)
BROKEN_TOKEN='it''s'
EOF
  chmod 600 "$HOME/.config/agentkit/env"
}

profile() {
  mkdir -p "$HOME/.config/dck"
  printf 'interface = 2\n[agents]\n%s\n' "$1" > "$HOME/.config/dck/profile.toml"
}

up() { run_cmd bash -c 'cd "$1" && shift && env "$@"' _ "$REPO" TMPDIR="$SANDBOX/tmp" "$DCK" up; }
overlay() { printf '%s/tmp/dck-%s/proj-agents.yml' "$SANDBOX" "$(id -u)"; }
envfile() { printf '%s/.config/dck/agents/proj/env' "$HOME"; }

# binds <overlay> — one line per bind: "<target> <ro|rw>"
binds() {
  python3 -I - "$1" <<'PY'
import sys
cur = None
out = []
for line in open(sys.argv[1]).read().splitlines():
    s = line.strip()
    if s == "- type: bind":
        if cur:
            out.append(cur)
        cur = {"ro": False}
    elif cur is not None and s.startswith("target:"):
        cur["target"] = s.split(":", 1)[1].strip().strip('"')
    elif cur is not None and s == "read_only: true":
        cur["ro"] = True
if cur:
    out.append(cur)
for b in out:
    print("%s %s" % (b["target"], "ro" if b["ro"] else "rw"))
PY
}

test_config_accepts_the_host_profile_keys() {
  local f="$SANDBOX/p.toml"
  printf 'interface = 2\n[agents]\nhost_profiles = true\nhost_env_keys = ["OPENAI_API_KEY"]\nhost_profile_names = ["claude@work1", "codex@default"]\n' > "$f"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config validate --kind profile "$f"
  assert_rc 0 "the host profile accepts host_profiles, host_env_keys and host_profile_names"
  printf 'interface = 2\n[agents]\nhost_profiles = "yes"\nhost_env_keys = ["lower", "XAI_*"]\nhost_profile_names = ["cursor@x", "claude"]\n' > "$f"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config validate --kind profile "$f"
  assert_rc 3 "invalid values are refused"
  assert_contains "$RUN_ERR" "agents.host_profiles: expected a boolean" "a non-boolean host_profiles is named"
  assert_contains "$RUN_ERR" "invalid variable name 'lower'" "a lower-case name is refused"
  assert_contains "$RUN_ERR" "invalid variable name 'XAI_*'" "no prefix or wildcard: names are exact"
  assert_contains "$RUN_ERR" "invalid profile 'cursor@x'" "a non-portable CLI cannot be listed"
  assert_contains "$RUN_ERR" "invalid profile 'claude'" "a profile is cli@name"
}

test_a_repository_cannot_turn_it_on() {
  mk_repo || return 0
  mk_host
  python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("[agents]\n", "[agents]\nhost_profiles = true\nhost_env_keys = [\"OPENAI_API_KEY\"]\nhost_profile_names = [\"claude@work1\"]\n", 1))' "$REPO/.devcontainer/dck.toml"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config show --repo "$REPO" --format json
  assert_rc 0 "the repository config still loads"
  assert_contains "$RUN_ERR" "agents.host_profiles is a host-profile setting" "host_profiles in a repository is reported as ignored"
  assert_contains "$RUN_ERR" "agents.host_profile_names is a host-profile setting" "so is host_profile_names"
  up
  assert_rc 0 "dck up succeeds"
  assert_not_file "$(overlay)" "no host-profiles overlay is written on a repository's request"
  assert_not_file "$(envfile)" "and no env file"
  assert_not_contains "$(fake_calls docker)" "-agents.yml" "compose is not given one"
}

test_off_copies_nothing_even_with_names_listed() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = false
host_env_keys = ["OPENAI_API_KEY"]'
  up
  assert_rc 0 "dck up succeeds"
  assert_not_file "$(overlay)" "no overlay while host_profiles is off"
  assert_not_file "$(envfile)" "host_env_keys copies nothing unless host_profiles is on"
  assert_not_contains "$RUN_OUT" "host profiles" "nothing about host profiles is printed"
}

test_up_shares_profiles_codex_and_env() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true
host_env_keys = ["OPENAI_API_KEY", "XAI_API_KEY"]'
  up
  assert_rc 0 "dck up succeeds with host profiles"
  local ov o
  ov="$(overlay)"
  assert_file "$ov" "the runtime overlay is written outside the repository"
  assert_mode "$ov" 600 "the overlay is private"
  assert_contains "$(fake_calls docker)" "-f $ov up -d" "compose is given the overlay"
  o="$(cat "$ov")"
  assert_contains "$o" "source: \"$PROFILES/claude/work1\"" "each profile is bound on its own"
  assert_contains "$o" 'target: "/home/dev/.dck/host/agentkit/profiles/claude/work1"' "into the container's profiles directory"
  assert_contains "$o" "source: \"$PROFILES/claude/team-b\"" "every profile of a listed CLI by default"
  assert_contains "$o" "source: \"$PROFILES/codex/work1\"" "codex profiles too"
  assert_not_contains "$o" "source: \"$PROFILES/claude\"" "never a whole CLI directory"
  assert_not_contains "$o" "profiles/cursor" "cursor profiles (absolute host symlinks) are not shared"
  assert_not_contains "$o" "share/agentkit\"" "the whole AGENTKIT_HOME is never mounted"
  assert_contains "$o" 'AGENTKIT_PROFILES_DIR: "/home/dev/.dck/host/agentkit/profiles"' "AGENTKIT_PROFILES_DIR names them"
  assert_contains "$o" 'DCK_HOST_PROFILES: "claude codex"' "the entrypoint learns which CLIs are shared"
  assert_contains "$o" "source: \"$HOME/.codex\"" "the host's Codex home is bound"
  assert_contains "$o" 'DCK_HOST_CODEX: "/home/dev/.dck/host/codex"' "and named for the entrypoint"
  assert_contains "$o" "source: \"$(dirname "$(envfile)")\"" "the env file's directory is bound, not the file"
  assert_not_contains "$o" "source: \"$(envfile)\"" "the file itself is never bound (an atomic rewrite would not reach the container)"
  assert_contains "$o" 'AGENTKIT_ENV: "/home/dev/.dck/host/agentkit/hostenv/env"' "AGENTKIT_ENV points at the file inside it"
  assert_contains "$o" "create_host_path: false" "a missing host path fails the start instead of being created"
  assert_contains "$o" "# Shared profiles: claude@team-b claude@work1 codex@work1 codex@default" "the overlay names the shared profiles"
  assert_contains "$o" "# Env file names (values only in the 0600 env file): CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_WORK1 OPENAI_API_KEY" "and the env file's names"
  assert_file "$(envfile)" "the env file is generated under the dck config directory"
  assert_mode "$(envfile)" 600 "the env file is 0600"
  assert_mode "$(dirname "$(envfile)")" 700 "its directory is 0700"
  local e
  e="$(cat "$(envfile)")"
  assert_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN='$FAKE_VALUE_A'" "the @default Claude token is copied (claude is installed)"
  assert_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN_WORK1='$FAKE_VALUE_B'" "a shared profile's token is copied"
  assert_not_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN_GONE" "a token of a profile that is not shared is never copied"
  assert_contains "$e" "OPENAI_API_KEY='$FAKE_VALUE_C'" "an explicitly listed name is copied"
  assert_not_contains "$e" "XAI_API_KEY" "shell code is never copied, even when listed"
  assert_not_contains "$e" "BROKEN_TOKEN" "an unlisted name is never copied"
  local name
  for name in "$FAKE_VALUE_A" "$FAKE_VALUE_B" "$FAKE_VALUE_C" "$FAKE_VALUE_D"; do
    assert_not_contains "$o" "$name" "no value is in the overlay"
    assert_not_contains "$RUN_OUT$RUN_ERR" "$name" "no value is printed"
    assert_not_contains "$(fake_calls)" "$name" "no value reaches docker's argv"
  done
  assert_contains "$RUN_OUT" "host profiles: shared: claude@team-b claude@work1 codex@work1 codex@default" "dck up names what it shares"
  assert_contains "$RUN_OUT" "env file names: CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_WORK1 OPENAI_API_KEY" "names only"
  assert_contains "$RUN_OUT" "ak profiles not shared for: cursor pi" "and what it skips"
  assert_eq "$(git -C "$REPO" status --porcelain | grep -c agents || true)" "0" "nothing is written into the repository"
}

test_mounts_are_read_write_only_where_the_cli_writes() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true'
  up
  local b
  b="$(binds "$(overlay)")"
  assert_contains "$b" "/home/dev/.dck/host/agentkit/hostenv ro" "the env file's directory is read-only"
  assert_no_match "$b" '/agentkit/hostenv rw$' "the env file is never read-write"
  assert_match "$b" '^/home/dev/\.dck/host/agentkit/profiles/claude/work1 rw$' "a Claude profile is read-write (its state is rewritten on every run)"
  assert_match "$b" '^/home/dev/\.dck/host/codex rw$' "the Codex home is read-write (auth.json token refresh)"
  assert_no_match "$b" '^/home/dev/\.dck/host/agentkit/profiles/[a-z]+ ' "no CLI directory is bound as a whole"
  run_cmd python3 -I - "$DCK_REPO" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import hostagents
doc = open(os.path.join(sys.argv[1], "docs", "SECURITY.md")).read()
missing = [k for k, (mode, why) in hostagents.MOUNT_MODES.items() if why not in doc]
assert set(hostagents.SHAREABLE) <= set(hostagents.MOUNT_MODES), "a shareable CLI has no mount mode"
assert hostagents.MOUNT_MODES["env"][0] == "ro"
assert not missing, missing
print("ok")
PY
  assert_eq "$RUN_OUT" "ok" "every mount mode and its reason are documented in docs/SECURITY.md"
}

test_default_names_are_only_the_shared_claude_tokens() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true'
  up
  local e
  e="$(cat "$(envfile)")"
  assert_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN_WORK1=" "the shared profile's token"
  assert_not_contains "$e" "OPENAI_API_KEY" "host_env_keys = [] copies nothing else"
  assert_not_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN_GONE" "no prefix match: only shared profiles"
  assert_contains "$RUN_OUT" "env file names: CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_WORK1" "the names are stated"
}

test_host_profile_names_limits_profiles_and_tokens() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true
host_profile_names = ["claude@work1"]'
  up
  assert_rc 0 "dck up succeeds"
  local o e
  o="$(cat "$(overlay)")"
  e="$(cat "$(envfile)")"
  assert_contains "$o" "source: \"$PROFILES/claude/work1\"" "the listed profile is bound"
  assert_not_contains "$o" "claude/team-b" "an unlisted profile is not"
  assert_not_contains "$o" "codex/work1" "nor an unlisted CLI's profiles"
  assert_not_contains "$o" "source: \"$HOME/.codex\"" "codex@default is not listed: the Codex home stays on the host"
  assert_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN_WORK1=" "the listed profile gets its token"
  assert_not_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN=" "claude@default is not listed: no default token"
  profile 'host_profiles = true
host_profile_names = ["claude@default", "codex@default"]'
  up
  o="$(cat "$(overlay)")"
  e="$(cat "$(envfile)")"
  assert_not_contains "$o" "agentkit/profiles/claude/" "only the CLIs' own homes: no ak profile is bound"
  assert_contains "$o" "source: \"$HOME/.codex\"" "codex@default shares the Codex home"
  assert_eq "$(grep -c '=' "$(envfile)")" "1" "exactly one name is copied"
  assert_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN='" "claude@default gets the default token"
}

test_turning_it_off_removes_the_overlay_and_env_file() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true'
  up
  assert_file "$(overlay)" "fixture: the overlay exists"
  profile 'host_profiles = false'
  : > "$DCK_FAKE_LOG"
  up
  assert_rc 0 "dck up succeeds"
  assert_not_file "$(overlay)" "the overlay is removed when the option is turned off"
  assert_not_file "$(envfile)" "and so is the env file"
  assert_absent "$(dirname "$(envfile)")" "and its directory"
  assert_not_contains "$(fake_calls docker)" "-agents.yml" "compose is not given it"
}

inode() { python3 -I -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$1"; }

test_second_up_keeps_the_tokens_visible_inside() {
  # A running container keeps its bind mounts: a single-file bind would pin the
  # first env file's inode, and the atomic rewrite on the next `dck up` would
  # never reach it. The directory is bound, so the new file is what it sees.
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true'
  up
  local o1 d1
  o1="$(cat "$(overlay)")"
  d1="$(inode "$(dirname "$(envfile)")")"
  sed "s/$FAKE_VALUE_B/$FAKE_VALUE_E/" "$HOME/.config/agentkit/env" > "$SANDBOX/env.new"
  cat "$SANDBOX/env.new" > "$HOME/.config/agentkit/env"
  up
  assert_rc 0 "the second dck up succeeds"
  assert_eq "$(cat "$(overlay)")" "$o1" "the overlay is unchanged, so compose keeps the running container"
  assert_eq "$(inode "$(dirname "$(envfile)")")" "$d1" "the bound directory is the same one the container holds"
  assert_contains "$(cat "$(envfile)")" "CLAUDE_CODE_OAUTH_TOKEN_WORK1='$FAKE_VALUE_E'" "the rotated token is in the file the container reads"
  assert_not_contains "$(cat "$(envfile)")" "$FAKE_VALUE_B" "the old value is gone"
  assert_mode "$(envfile)" 600 "the rewritten env file is still 0600"
}

test_the_single_file_env_of_v030_is_removed() {
  mk_repo || return 0
  mk_host
  mkdir -p "$HOME/.config/dck/agents"
  printf "OLD='%s'\n" "$FAKE_VALUE_D" > "$HOME/.config/dck/agents/proj.env"
  profile 'host_profiles = true'
  up
  assert_not_file "$HOME/.config/dck/agents/proj.env" "the v0.3.0 single-file env is removed"
  assert_file "$(envfile)" "the per-project directory holds the env file"
}

test_agents_layer_off_shares_nothing() {
  mkdir -p "$REPO"; git -C "$REPO" init -q
  "$DCK" init --repo "$REPO" --flavour node-24 --no-agents --no-herdr --yes >/dev/null 2>&1 || { fail "fixture: dck init"; return 0; }
  mk_host
  profile 'host_profiles = true'
  up
  assert_rc 0 "dck up succeeds"
  assert_not_file "$(overlay)" "without the agents layer nothing is shared"
}

test_custom_profiles_dir_and_codex_home() {
  mk_repo "claude codex" || return 0
  mkdir -p "$SANDBOX/alt/claude/x" "$SANDBOX/codexhome"
  profile 'host_profiles = true'
  run_cmd bash -c 'cd "$1" && shift && env "$@"' _ "$REPO" TMPDIR="$SANDBOX/tmp" AGENTKIT_PROFILES_DIR="$SANDBOX/alt" CODEX_HOME="$SANDBOX/codexhome" "$DCK" up
  assert_rc 0 "dck up succeeds"
  assert_contains "$(cat "$(overlay)")" "source: \"$SANDBOX/alt/claude/x\"" "AGENTKIT_PROFILES_DIR is honoured"
  assert_contains "$(cat "$(overlay)")" "source: \"$SANDBOX/codexhome\"" "CODEX_HOME is honoured"
}

test_devcontainer_backend_falls_back_to_compose() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true'
  run_cmd bash -c 'cd "$1" && shift && env "$@"' _ "$REPO" TMPDIR="$SANDBOX/tmp" DCK_BACKEND=auto "$DCK" up
  assert_rc 0 "dck up succeeds"
  assert_contains "$(fake_calls docker)" "-agents.yml up -d" "auto picks compose, which applies the overlay"
  assert_eq "$(fake_calls devcontainer)" "" "the devcontainer CLI is not used"
}

# A fake host ak answering `ak profiles --json` (profiles-v1).
fake_ak() {
  mkdir -p "$SANDBOX/akbin"
  cat > "$SANDBOX/akbin/ak" <<'EOF'
#!/bin/sh
[ "$1 $2" = "profiles --json" ] || exit 2
cat <<'J'
{"schema": "profiles-v1", "interface": 1, "profiles": [
 {"cli": "claude", "profile": "@default", "path_relative": null, "isolation": "env", "login": "token-var", "key_names_set": ["CLAUDE_CODE_OAUTH_TOKEN"]},
 {"cli": "claude", "profile": "@work1", "path_relative": "claude/work1", "isolation": "env", "login": "keychain", "key_names_set": []},
 {"cli": "claude", "profile": "@team-b", "path_relative": "claude/team-b", "isolation": "env", "login": "keychain", "key_names_set": []},
 {"cli": "codex", "profile": "@default", "path_relative": null, "isolation": "env", "login": "file", "key_names_set": []},
 {"cli": "codex", "profile": "@work1", "path_relative": "codex/work1", "isolation": "env", "login": "unknown", "key_names_set": []},
 {"cli": "cursor", "profile": "@work1", "path_relative": "cursor/work1", "isolation": "cursor-home", "login": "file", "key_names_set": []}
]}
J
EOF
  chmod +x "$SANDBOX/akbin/ak"
}

test_doctor_reports_names_modes_and_keychain_logins() {
  mk_repo || return 0
  mk_host
  fake_ak
  profile 'host_profiles = true
host_env_keys = ["OPENAI_API_KEY"]'
  run_cmd bash -c 'cd "$1" && PATH="$2:$PATH" "$3" doctor' _ "$REPO" "$SANDBOX/akbin" "$DCK"
  assert_contains "$RUN_OUT" "host profiles    shared: claude@team-b, claude@work1, codex@work1, codex@default" "the doctor names the shared profiles"
  assert_contains "$RUN_OUT" "claude@work1 rw — Claude rewrites its profile state" "each mount with its mode and reason"
  assert_contains "$RUN_OUT" "codex@default (the host's Codex home) rw — Codex refreshes its login in auth.json" "the Codex home's reason"
  assert_contains "$RUN_OUT" "env file (ro) names: CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN_WORK1, OPENAI_API_KEY" "names only, read-only"
  assert_contains "$RUN_OUT" "cursor ak profiles not shared" "and the skipped ones"
  assert_contains "$RUN_OUT" "codex @work1 (login: unknown)" "the login kind unknown is reported as is"
  assert_contains "$RUN_OUT" "codex @default (login: file)" "and file"
  assert_not_contains "$RUN_OUT" "claude @work1 logs in through the macOS keychain" "a keychain login with its token stored is fine"
  assert_contains "$RUN_OUT" "claude @team-b logs in through the macOS keychain" "a keychain-only login is flagged"
  assert_contains "$RUN_OUT" "claude setup-token" "with the fix: a long-lived token"
  assert_contains "$RUN_OUT" "CLAUDE_CODE_OAUTH_TOKEN_TEAM_B" "stored under the profile's variable (suffix upper-cased, - → _)"
  local name
  for name in "$FAKE_VALUE_A" "$FAKE_VALUE_B" "$FAKE_VALUE_C" "$FAKE_VALUE_D"; do
    assert_not_contains "$RUN_OUT$RUN_ERR" "$name" "the doctor never prints a value"
  done
  run_cmd bash -c 'cd "$1" && PATH="$2:$PATH" "$3" doctor --json' _ "$REPO" "$SANDBOX/akbin" "$DCK"
  local json="$RUN_OUT" r
  r="$(printf '%s' "$json" | python3 "$TESTS_DIR/py/minischema.py" "$DCK_REPO/docs/schema/dck-doctor-v2.json" 2>&1)"
  assert_eq "$r" "" "doctor --json with host_profiles matches its schema"
  run_cmd python3 -I -c '
import json, sys
hp = json.loads(sys.argv[1])["host_profiles"]
assert hp["enabled"] and hp["shared"] == ["claude", "codex"] and hp["codex"], hp
assert hp["profiles"] == ["claude@team-b", "claude@work1", "codex@work1", "codex@default"], hp
modes = {m["profile"]: m["mode"] for m in hp["mounts"]}
assert modes["env"] == "ro" and modes["claude@work1"] == "rw" and modes["codex@default"] == "rw", modes
assert all(m["reason"] for m in hp["mounts"]), hp
assert "OPENAI_API_KEY" in hp["env_names"], hp
print("ok")' "$json"
  assert_eq "$RUN_OUT" "ok" "doctor --json reports profiles, mounts and names"
}

test_doctor_without_profiles_json() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true'
  run_cmd bash -c 'cd "$1" && "$2" doctor' _ "$REPO" "$DCK"
  assert_contains "$RUN_OUT" "ak profiles --json" "without a host ak the doctor says logins were not checked"
}

# ---------------------------------------------------------------------------
# Entrypoint: Codex home, skills, unattended-launch trust
# ---------------------------------------------------------------------------

ep() {
  run_cmd env DCK_USER="$(id -un)" DCK_HOME="$SANDBOX/h" DCK_WORKSPACE=/app DCK_SKILLS_SRC="$SANDBOX/skills" "$@" \
    bash -c '. "$1"; shift; for f in "$@"; do "$f"; done' _ "$DCK_REPO/lib/entrypoint.sh" ${EP_FUNCS:-dck_agent_trust}
}

mk_container_home() {
  mkdir -p "$SANDBOX/h/.dck/host/codex" "$SANDBOX/h/.dck/host/agentkit/profiles/claude/work1" \
           "$SANDBOX/h/.dck/volumes/agentkit/profiles/claude/own1" "$SANDBOX/skills/herdr-peers"
  printf 'model = "m"\n' > "$SANDBOX/h/.dck/host/codex/config.toml"
  printf '{"projects": {"/elsewhere": {"x": 1}}}\n' > "$SANDBOX/h/.dck/host/agentkit/profiles/claude/work1/.claude.json"
}

test_trust_folder_everywhere_bypass_only_in_own_homes() {
  mk_container_home
  ep DCK_AGENTS="claude codex" DCK_HOST_PROFILES="claude" AGENTKIT_PROFILES_DIR="$SANDBOX/h/.dck/host/agentkit/profiles" \
     DCK_HOST_CODEX="$SANDBOX/h/.dck/host/codex"
  assert_contains "$RUN_ERR" "agent trust: workspace /app trusted" "the entrypoint logs the trust step"
  run_cmd python3 -I -c '
import json, sys
h = sys.argv[1]
own = json.load(open(h + "/.claude.json"))
assert own["projects"]["/app"]["hasTrustDialogAccepted"] is True, own
assert own["hasCompletedOnboarding"] is True and own["bypassPermissionsModeAccepted"] is True, own
assert json.load(open(h + "/.claude/settings.json"))["skipDangerousModePermissionPrompt"] is True
shared = json.load(open(h + "/.dck/host/agentkit/profiles/claude/work1/.claude.json"))
assert shared["projects"]["/app"]["hasTrustDialogAccepted"] is True, shared
assert shared["projects"]["/elsewhere"] == {"x": 1}, shared
assert "bypassPermissionsModeAccepted" not in shared and "hasCompletedOnboarding" not in shared, shared
import os
assert not os.path.exists(h + "/.dck/host/agentkit/profiles/claude/work1/settings.json")
print("ok")' "$SANDBOX/h"
  assert_eq "$RUN_OUT" "ok" "folder trust in own homes and shared profiles; bypass acknowledgement only in own homes"
  local c
  c="$(cat "$SANDBOX/h/.dck/host/codex/config.toml")"
  assert_contains "$c" 'model = "m"' "the shared Codex config keeps its content"
  assert_contains "$c" '[projects."/app"]' "Codex gets a project table for the workspace"
  assert_contains "$c" 'trust_level = "trusted"' "marked trusted"
  assert_mode "$SANDBOX/h/.claude.json" 600 "a created config file is 0600"
  local before after
  before="$(cat "$SANDBOX/h/.dck/host/codex/config.toml")"
  ep DCK_AGENTS="claude codex" DCK_HOST_PROFILES="claude" AGENTKIT_PROFILES_DIR="$SANDBOX/h/.dck/host/agentkit/profiles" \
     DCK_HOST_CODEX="$SANDBOX/h/.dck/host/codex"
  after="$(cat "$SANDBOX/h/.dck/host/codex/config.toml")"
  assert_eq "$after" "$before" "a second start changes nothing"
  assert_contains "$RUN_ERR" "(0 file(s) updated)" "and says so"
}

test_own_profiles_get_the_acknowledgement() {
  mk_container_home
  ep DCK_AGENTS="claude" AGENTKIT_PROFILES_DIR="$SANDBOX/h/.dck/volumes/agentkit/profiles"
  run_cmd python3 -I -c '
import json, sys
d = sys.argv[1]
c = json.load(open(d + "/.claude.json"))
assert c["projects"]["/app"]["hasTrustDialogAccepted"] and c["bypassPermissionsModeAccepted"], c
assert json.load(open(d + "/settings.json"))["skipDangerousModePermissionPrompt"] is True
print("ok")' "$SANDBOX/h/.dck/volumes/agentkit/profiles/claude/own1"
  assert_eq "$RUN_OUT" "ok" "a profile on the container's own volume is the container's: trust and acknowledgement"
}

test_ask_writes_nothing() {
  mk_container_home
  ep DCK_AGENTS="claude codex" AGENTKIT_PERMISSIONS=ask DCK_HOST_CODEX="$SANDBOX/h/.dck/host/codex"
  assert_contains "$RUN_ERR" "AGENTKIT_PERMISSIONS=ask" "the opt-out is logged"
  assert_absent "$SANDBOX/h/.claude.json" "no Claude config is written"
  assert_eq "$(cat "$SANDBOX/h/.dck/host/codex/config.toml")" 'model = "m"' "no Codex trust is written"
  mkdir -p "$SANDBOX/h/.config/agentkit"
  printf 'export AGENTKIT_PERMISSIONS="ask"  # agents ask\n' > "$SANDBOX/h/.config/agentkit/env"
  ep DCK_AGENTS="claude"
  assert_absent "$SANDBOX/h/.claude.json" "the opt-out in ak's env file counts too"
}

test_codex_home_is_the_host_mount() {
  mk_container_home
  mkdir -p "$SANDBOX/h/.codex"
  printf 'image\n' > "$SANDBOX/h/.codex/from-image"
  EP_FUNCS="dck_layer_persist dck_skills_link" ep DCK_AGENTS="codex" DCK_HOST_CODEX="$SANDBOX/h/.dck/host/codex" \
     DCK_PERSIST_ROOT="$SANDBOX/h/.dck/volumes"
  assert_symlink "$SANDBOX/h/.codex" "the Codex home is a link"
  assert_eq "$(readlink "$SANDBOX/h/.codex")" "$SANDBOX/h/.dck/host/codex" "to the host's Codex home"
  assert_absent "$SANDBOX/h/.dck/host/codex/skills" "no container skill link is planted in the host's Codex home"
  assert_absent "$SANDBOX/h/.dck/host/codex/from-image" "the image's copy is not copied into the host's home"
  EP_FUNCS="dck_layer_persist" ep DCK_AGENTS="codex" DCK_PERSIST_ROOT="$SANDBOX/h/.dck/volumes"
  assert_eq "$(readlink "$SANDBOX/h/.codex")" "$SANDBOX/h/.dck/volumes/codex/codex" "turned off, ~/.codex goes back to its volume"
  assert_file "$SANDBOX/h/.dck/host/codex/config.toml" "the host's files are untouched"
}

test_host_codex_outside_the_host_dir_is_ignored() {
  mk_container_home
  mkdir -p "$SANDBOX/elsewhere"
  EP_FUNCS="dck_layer_persist" ep DCK_AGENTS="codex" DCK_HOST_CODEX="$SANDBOX/elsewhere" DCK_PERSIST_ROOT="$SANDBOX/h/.dck/volumes"
  assert_eq "$(readlink "$SANDBOX/h/.codex")" "$SANDBOX/h/.dck/volumes/codex/codex" "DCK_HOST_CODEX must name the dck host mount"
}

test_python_side_never_logs_values() {
  run_cmd grep -nE 'print\(.*values\[|log.*values\[' "$DCK_REPO/lib/hostagents.py" "$DCK_REPO/lib/dckpy.py" "$DCK_REPO/lib/doctor.py"
  assert_eq "$RUN_OUT" "" "no code path prints an env file value"
}

test_doctor_explains_the_default_claude_login() {
  mk_repo "claude" || return 0
  mk_host
  fake_ak
  sed -i.orig '/^CLAUDE_CODE_OAUTH_TOKEN=/d' "$HOME/.config/agentkit/env" && rm -f "$HOME/.config/agentkit/env.orig"
  profile 'host_profiles = true'
  run_cmd bash -c 'cd "$1" && PATH="$2:$PATH" "$3" doctor' _ "$REPO" "$SANDBOX/akbin" "$DCK"
  assert_contains "$RUN_OUT" "claude @default will not be logged in inside" "the doctor says the default Claude account will not be logged in"
  assert_contains "$RUN_OUT" "claude setup-token" "with the fix: a long-lived token in ak's env file"
  assert_contains "$RUN_OUT" "log in once inside" "or a login the claude volume keeps"
  assert_not_contains "$RUN_OUT" "CLAUDE_CODE_OAUTH_TOKEN not copied" "instead of the bare not-copied line"
}

# #11: [agents] default_profile — the account a bare `ak <cli>` uses inside.
test_default_profile_is_exported_for_shared_profiles() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true
default_profile = { claude = "@work1", codex = "nope" }'
  up
  assert_rc 0 "dck up succeeds with default_profile"
  local o; o="$(cat "$(overlay)")"
  assert_contains "$o" 'AGENTKIT_DEFAULT_PROFILE_CLAUDE: "@work1"' "a shared profile becomes the CLI's default inside"
  assert_not_contains "$o" "AGENTKIT_DEFAULT_PROFILE_CODEX" "a profile that is not shared is not exported"
  fake_ak
  run_cmd bash -c 'cd "$1" && PATH="$2:$PATH" "$3" doctor' _ "$REPO" "$SANDBOX/akbin" "$DCK"
  assert_contains "$RUN_OUT" "default profile inside (AGENTKIT_DEFAULT_PROFILE_<CLI>, ak v0.5.2+): claude @work1" "the doctor shows the mapping"
  assert_contains "$RUN_OUT" "a plain claude/codex inside (a pane Herdr restores without ak) uses it: CLAUDE_CONFIG_DIR=/home/dev/.dck/host/agentkit/profiles/claude/work1" "and the config home a restored plain claude uses"
  assert_contains "$RUN_OUT" "default_profile codex = @nope not applied — codex @nope is not shared" "and flags one it cannot apply"
  printf 'interface = 2\n[agents]\ndefault_profile = { cursor = "@x" }\n' > "$SANDBOX/p.toml"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config validate --kind profile "$SANDBOX/p.toml"
  assert_rc 3 "a CLI without portable profiles is refused"
  python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("[agents]\n", "[agents]\ndefault_profile = { claude = \"@work1\" }\n", 1))' "$REPO/.devcontainer/dck.toml"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config show --repo "$REPO" --format json
  assert_contains "$RUN_ERR" "agents.default_profile is a host-profile setting" "a repository cannot set it"
}

# v0.3.4: Codex never checks for an update at startup inside a container — only
# in the container's own configs; the host's Codex home and host-shared profiles
# are never written; hooks are never pre-trusted.
test_codex_update_check_off_only_in_own_configs() {
  mk_container_home
  local own="$SANDBOX/h/.dck/volumes/codex/codex" p="$SANDBOX/h/.dck/volumes/agentkit/profiles/codex"
  mkdir -p "$own" "$p/own1" "$p/mine"
  ln -sfn "$own" "$SANDBOX/h/.codex"
  printf '[projects."/app"]\ntrust_level = "trusted"\n' > "$own/config.toml"
  printf 'check_for_update_on_startup = true\n' > "$p/mine/config.toml"
  local host_before; host_before="$(cat "$SANDBOX/h/.dck/host/codex/config.toml")"
  EP_FUNCS=dck_codex_config ep DCK_AGENTS="codex" AGENTKIT_PROFILES_DIR="$SANDBOX/h/.dck/volumes/agentkit/profiles"
  assert_rc 0 "dck_codex_config runs"
  assert_eq "$(head -1 "$own/config.toml")" "check_for_update_on_startup = false" "the container's ~/.codex skips the update check (a top-level key, before any table)"
  assert_contains "$(cat "$own/config.toml")" '[projects."/app"]' "the rest of the config is kept"
  assert_eq "$(head -1 "$p/own1/config.toml")" "check_for_update_on_startup = false" "an ak codex profile on the container's volume too"
  assert_contains "$(cat "$own/config.toml")" "[features]
daemon_auto_start = false" "a plain restored codex starts no app-server daemon"
  assert_contains "$(cat "$p/mine/config.toml")" "check_for_update_on_startup = true" "a value the developer set is kept"
  assert_not_contains "$(cat "$p/mine/config.toml")" "check_for_update_on_startup = false" "never doubled"
  assert_contains "$RUN_ERR" "codex: startup update check and daemon auto-start off in 3 config(s)" "and logged"
  printf '[features]\ndaemon_auto_start = true\n' > "$p/mine/config.toml"
  EP_FUNCS=dck_codex_config ep DCK_AGENTS="codex" AGENTKIT_PROFILES_DIR="$SANDBOX/h/.dck/volumes/agentkit/profiles"
  assert_contains "$(cat "$p/mine/config.toml")" "daemon_auto_start = true" "a daemon_auto_start the developer set is kept"
  assert_eq "$(grep -c daemon_auto_start "$p/mine/config.toml")" "1" "and not doubled"
  EP_FUNCS=dck_codex_config ep DCK_AGENTS="codex" AGENTKIT_PROFILES_DIR="$SANDBOX/h/.dck/volumes/agentkit/profiles"
  assert_not_contains "$RUN_ERR" "update check off" "a second start changes nothing"
  assert_eq "$(grep -c check_for_update_on_startup "$own/config.toml")" "1" "the key is written once"
  # The host's Codex home and host-shared profiles: never written.
  mkdir -p "$SANDBOX/h/.dck/host/agentkit/profiles/codex/work1"
  printf 'model = "w"\n' > "$SANDBOX/h/.dck/host/agentkit/profiles/codex/work1/config.toml"
  ln -sfn "$SANDBOX/h/.dck/host/codex" "$SANDBOX/h/.codex"
  EP_FUNCS=dck_codex_config ep DCK_AGENTS="codex" DCK_HOST_CODEX="$SANDBOX/h/.dck/host/codex" DCK_HOST_PROFILES="codex" \
     AGENTKIT_PROFILES_DIR="$SANDBOX/h/.dck/host/agentkit/profiles"
  assert_eq "$(cat "$SANDBOX/h/.dck/host/codex/config.toml")" "$host_before" "the host's Codex home is never written"
  assert_eq "$(cat "$SANDBOX/h/.dck/host/agentkit/profiles/codex/work1/config.toml")" 'model = "w"' "nor a host-shared codex profile"
  assert_not_contains "$(cat "$own/config.toml" "$p/own1/config.toml")" "hooks" "hooks are never pre-trusted"
  EP_FUNCS=dck_codex_config ep DCK_AGENTS="claude" AGENTKIT_PROFILES_DIR="$SANDBOX/h/.dck/volumes/agentkit/profiles"
  assert_not_contains "$RUN_ERR" "codex:" "without codex, nothing"
  assert_contains "$(sed -n '/^dck_start() {/,/^}/p' "$DCK_REPO/lib/entrypoint.sh")" "dck_codex_config || true" "dck_start runs it at every start"
}

# v0.3.4 (A): a pane Herdr restores runs a plain `claude --resume` without ak; with
# [agents] default_profile, the login profile points it at that profile's home.
test_login_profile_points_plain_clis_at_the_default_profile() {
  local prof="$SANDBOX/profiles"
  mkdir -p "$prof/claude/work3" "$prof/codex/work2" "$SANDBOX/lh"
  run_cmd env HOME="$SANDBOX/lh" AGENTKIT_PROFILES_DIR="$prof" AGENTKIT_DEFAULT_PROFILE_CLAUDE="@work3" AGENTKIT_DEFAULT_PROFILE_CODEX="@work2" \
    sh -c '. "$1"; printf "%s|%s" "${CLAUDE_CONFIG_DIR:-unset}" "${CODEX_HOME:-unset}"' _ "$DCK_REPO/images/common/profile.sh"
  assert_eq "$RUN_OUT" "$prof/claude/work3|$prof/codex/work2" "CLAUDE_CONFIG_DIR and CODEX_HOME name the default profiles"
  run_cmd env HOME="$SANDBOX/lh" AGENTKIT_PROFILES_DIR="$prof" AGENTKIT_DEFAULT_PROFILE_CLAUDE="@work3" CLAUDE_CONFIG_DIR=/elsewhere \
    sh -c '. "$1"; printf "%s" "$CLAUDE_CONFIG_DIR"' _ "$DCK_REPO/images/common/profile.sh"
  assert_eq "$RUN_OUT" "/elsewhere" "a value already set wins (ak sets its own)"
  run_cmd env HOME="$SANDBOX/lh" AGENTKIT_PROFILES_DIR="$prof" AGENTKIT_DEFAULT_PROFILE_CLAUDE="@missing" \
    sh -c '. "$1"; printf "%s" "${CLAUDE_CONFIG_DIR:-unset}"' _ "$DCK_REPO/images/common/profile.sh"
  assert_eq "$RUN_OUT" "unset" "a profile directory that does not exist is not named"
  run_cmd env HOME="$SANDBOX/lh" AGENTKIT_PROFILES_DIR="$prof" AGENTKIT_DEFAULT_PROFILE_CLAUDE="../../etc" \
    sh -c '. "$1"; printf "%s" "${CLAUDE_CONFIG_DIR:-unset}"' _ "$DCK_REPO/images/common/profile.sh"
  assert_eq "$RUN_OUT" "unset" "a malformed name is refused"
  run_cmd env HOME="$SANDBOX/lh" sh -c '. "$1"; printf "%s" "${CLAUDE_CONFIG_DIR:-unset}"' _ "$DCK_REPO/images/common/profile.sh"
  assert_eq "$RUN_OUT" "unset" "without default_profile, nothing changes"
}
