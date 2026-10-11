# shellcheck shell=bash
# Scope: agents — [agents] host_profiles: the host's agent accounts inside a
# container (config, the runtime overlay, the allow-listed env file, the
# doctor's report) and the entrypoint's unattended-launch trust.

DCK="$DCK_REPO/bin/dck"
use_fakes
export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_NO_DIGEST=1

REPO="$SANDBOX/proj"
# Fake secret values: they must never appear outside the generated env file.
SECRET_A="sk-dck-test-value-aaaa"
SECRET_B="sk-dck-test-value-bbbb"
SECRET_C="sk-dck-test-value-cccc"

mk_repo() {
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  "$DCK" init --repo "$REPO" --flavour node-24 --agents --clis "${1:-claude codex cursor pi}" --no-herdr --yes >/dev/null 2>&1 \
    || { fail "fixture: dck init failed"; return 1; }
  : > "$DCK_FAKE_LOG"
}

# The host side: ak profiles for claude, codex and cursor, the Codex home, an ak env file.
mk_host() {
  mkdir -p "$HOME/.local/share/agentkit/profiles/claude/work1" "$HOME/.local/share/agentkit/profiles/codex/work1" \
           "$HOME/.local/share/agentkit/profiles/cursor/work1" "$HOME/.codex" "$HOME/.config/agentkit"
  cat > "$HOME/.config/agentkit/env" <<EOF
# ak env file
CLAUDE_CODE_OAUTH_TOKEN='$SECRET_A'
export CLAUDE_CODE_OAUTH_TOKEN_WORK1="$SECRET_B"
OPENAI_API_KEY=$SECRET_C
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

test_config_accepts_the_host_profile_keys() {
  local f="$SANDBOX/p.toml"
  printf 'interface = 2\n[agents]\nhost_profiles = true\nhost_env_keys = ["OPENAI_API_KEY", "XAI_*"]\n' > "$f"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config validate --kind profile "$f"
  assert_rc 0 "the host profile accepts [agents] host_profiles and host_env_keys"
  printf 'interface = 2\n[agents]\nhost_profiles = "yes"\nhost_env_keys = ["lower", "A*B"]\n' > "$f"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config validate --kind profile "$f"
  assert_rc 3 "invalid values are refused"
  assert_contains "$RUN_ERR" "agents.host_profiles: expected a boolean" "a non-boolean host_profiles is named"
  assert_contains "$RUN_ERR" "invalid variable name 'lower'" "a lower-case name is refused"
  assert_contains "$RUN_ERR" "invalid variable name 'A*B'" "a * only ends a prefix"
}

test_a_repository_cannot_turn_it_on() {
  mk_repo || return 0
  mk_host
  python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("[agents]\n", "[agents]\nhost_profiles = true\nhost_env_keys = [\"OPENAI_API_KEY\"]\n", 1))' "$REPO/.devcontainer/dck.toml"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config show --repo "$REPO" --format json
  assert_rc 0 "the repository config still loads"
  assert_contains "$RUN_ERR" "agents.host_profiles is a host-profile setting" "the repository key is reported as ignored"
  up
  assert_rc 0 "dck up succeeds"
  assert_not_file "$(overlay)" "no host-profiles overlay is written on a repository's request"
  assert_not_contains "$(fake_calls docker)" "-agents.yml" "compose is not given one"
}

test_off_by_default() {
  mk_repo || return 0
  mk_host
  up
  assert_rc 0 "dck up succeeds"
  assert_not_file "$(overlay)" "no host-profiles overlay without the host profile asking"
  assert_not_contains "$RUN_OUT" "host profiles" "nothing about host profiles is printed"
}

test_up_shares_profiles_codex_and_env() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true
host_env_keys = ["OPENAI_API_KEY", "XAI_*"]'
  up
  assert_rc 0 "dck up succeeds with host profiles"
  local ov env_file
  ov="$(overlay)"
  env_file="$HOME/.config/dck/agents/proj.env"
  assert_file "$ov" "the runtime overlay is written outside the repository"
  assert_mode "$ov" 600 "the overlay is private"
  assert_contains "$(fake_calls docker)" "-f $ov up -d" "compose is given the overlay"
  local o
  o="$(cat "$ov")"
  assert_contains "$o" "source: \"$HOME/.local/share/agentkit/profiles/claude\"" "claude's host profiles are bound"
  assert_contains "$o" 'target: "/home/dev/.dck/host/agentkit/profiles/claude"' "into the container's profiles directory"
  assert_contains "$o" 'AGENTKIT_PROFILES_DIR: "/home/dev/.dck/host/agentkit/profiles"' "AGENTKIT_PROFILES_DIR names it"
  assert_contains "$o" 'DCK_HOST_PROFILES: "claude codex"' "the entrypoint learns which CLIs are shared"
  assert_not_contains "$o" "profiles/cursor" "cursor profiles (absolute host symlinks) are not shared"
  assert_not_contains "$o" "profiles/pi\"" "a CLI without host profiles is not bound"
  assert_not_contains "$o" "share/agentkit\"" "the whole AGENTKIT_HOME is never mounted"
  assert_contains "$o" "source: \"$HOME/.codex\"" "the host's Codex home is bound"
  assert_contains "$o" 'DCK_HOST_CODEX: "/home/dev/.dck/host/codex"' "and named for the entrypoint"
  assert_contains "$o" "source: \"$env_file\"" "the env file is bound"
  assert_contains "$o" 'AGENTKIT_ENV: "/home/dev/.dck/host/agentkit/env"' "AGENTKIT_ENV points at it"
  assert_contains "$o" "read_only: true" "the env file is read-only"
  assert_contains "$o" "create_host_path: false" "a missing host path fails the start instead of being created"
  assert_file "$env_file" "the env file is generated under the dck config directory"
  assert_mode "$env_file" 600 "the env file is 0600"
  assert_mode "$(dirname "$env_file")" 700 "its directory is 0700"
  local e
  e="$(cat "$env_file")"
  assert_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN='$SECRET_A'" "the default Claude token is copied"
  assert_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN_WORK1='$SECRET_B'" "a per-profile Claude token is copied"
  assert_contains "$e" "OPENAI_API_KEY='$SECRET_C'" "an allow-listed name is copied"
  assert_not_contains "$e" "XAI_API_KEY" "shell code is never copied"
  assert_not_contains "$e" "BROKEN_TOKEN" "a value that is not plain data is never copied"
  local name
  for name in "$SECRET_A" "$SECRET_B" "$SECRET_C"; do
    assert_not_contains "$o" "$name" "no value is in the overlay"
    assert_not_contains "$RUN_OUT$RUN_ERR" "$name" "no value is printed"
    assert_not_contains "$(fake_calls)" "$name" "no value reaches docker's argv"
  done
  assert_contains "$RUN_OUT" "host profiles: ak profiles shared for claude codex" "dck up names what it shares"
  assert_contains "$RUN_OUT" "env file names: CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_WORK1 OPENAI_API_KEY" "names only"
  assert_contains "$RUN_OUT" "not shared: cursor pi" "and what it skips"
  assert_eq "$(git -C "$REPO" status --porcelain | grep -c agents || true)" "0" "nothing is written into the repository"
}

test_default_allow_list_is_claude_tokens_only() {
  mk_repo || return 0
  mk_host
  profile 'host_profiles = true'
  up
  local e
  e="$(cat "$HOME/.config/dck/agents/proj.env")"
  assert_contains "$e" "CLAUDE_CODE_OAUTH_TOKEN_WORK1=" "Claude tokens are allowed by default"
  assert_not_contains "$e" "OPENAI_API_KEY" "other keys need host_env_keys"
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
  assert_not_file "$HOME/.config/dck/agents/proj.env" "and so is the env file"
  assert_not_contains "$(fake_calls docker)" "-agents.yml" "compose is not given it"
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
  assert_contains "$(cat "$(overlay)")" "source: \"$SANDBOX/alt/claude\"" "AGENTKIT_PROFILES_DIR is honoured"
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
 {"cli": "cursor", "profile": "@work1", "path_relative": "cursor/work1", "isolation": "cursor-home", "login": "file", "key_names_set": []}
]}
J
EOF
  chmod +x "$SANDBOX/akbin/ak"
}

test_doctor_reports_names_and_keychain_logins() {
  mk_repo || return 0
  mk_host
  fake_ak
  profile 'host_profiles = true
host_env_keys = ["OPENAI_API_KEY"]'
  run_cmd bash -c 'cd "$1" && PATH="$2:$PATH" "$3" doctor' _ "$REPO" "$SANDBOX/akbin" "$DCK"
  assert_contains "$RUN_OUT" "host profiles    shared for claude, codex" "the doctor names the shared CLIs"
  assert_contains "$RUN_OUT" "cursor not shared" "and the skipped ones"
  assert_contains "$RUN_OUT" "env file names: CLAUDE_CODE_OAUTH_TOKEN, CLAUDE_CODE_OAUTH_TOKEN_WORK1, OPENAI_API_KEY" "names only"
  assert_not_contains "$RUN_OUT" "claude @work1 logs in through the macOS keychain" "a keychain login with its token stored is fine"
  assert_contains "$RUN_OUT" "claude @team-b logs in through the macOS keychain" "a keychain-only login is flagged"
  assert_contains "$RUN_OUT" "claude setup-token" "with the fix: a long-lived token"
  assert_contains "$RUN_OUT" "CLAUDE_CODE_OAUTH_TOKEN_TEAM_B" "stored under the profile's variable (suffix upper-cased, - → _)"
  local name
  for name in "$SECRET_A" "$SECRET_B" "$SECRET_C"; do
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
assert "OPENAI_API_KEY" in hp["env_names"], hp
print("ok")' "$json"
  assert_eq "$RUN_OUT" "ok" "doctor --json reports host_profiles by name"
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
