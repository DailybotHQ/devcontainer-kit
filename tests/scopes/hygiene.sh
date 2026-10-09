# shellcheck shell=bash
# Scope: hygiene — scripts/check-public-hygiene.sh (public repository standard A3, S3).
# Every violating string is assembled at run time, so this file itself stays clean.

HY="$DCK_REPO/scripts/check-public-hygiene.sh"

# A throwaway git repository holding one file with the given content.
hy_repo() {
  local dir="$SANDBOX/r"
  mkdir -p "$dir"
  git -C "$dir" init -q 2>/dev/null
  mkdir -p "$(dirname "$dir/${2:-file.txt}")"
  printf '%s\n' "$1" > "$dir/${2:-file.txt}"
  git -C "$dir" add -A
}
hy() { run_cmd bash -c 'cd "$1" && bash "$2" "${@:3}"' _ "$SANDBOX/r" "$HY" "$@"; }

# rule_case <rule> <description> <content>
rule_case() {
  rm -rf "$SANDBOX/r"
  hy_repo "$3"
  hy
  if [ "$RUN_RC" = 1 ] && printf '%s\n' "$RUN_OUT" | grep -q "\[$1\]"; then
    pass "flags $2 [$1]"
  else
    fail "flags $2 [$1]" "rc=$RUN_RC out=$RUN_OUT err=$RUN_ERR"
  fi
}

test_each_rule_is_enforced() {
  local org="Daily""Bot-Inc" b="dailybot"
  rule_case personal-path "a macOS home path" "see /Users/""alice/projects/x"
  rule_case personal-path "a Linux home path" "cd /home/""bob/src"
  rule_case private-org "the private organisation" "github.com/$org/repo"
  rule_case private-repo "a private repository name" "clone $b-core next to it"
  rule_case private-repo "another private repository" "the discord-""gateway service"
  rule_case internal-tool "an internal tool" "run d""bdev up"
  rule_case internal-tool "an internal mesh name" "Include config.d/$b-peers"
  rule_case internal-tool "a mesh stamp" "[$b-mesh] protocol=1"
  rule_case email "a personal company address" "write to jane.doe@$b.com"
  rule_case secret-aws "an AWS key id" "key: AKI""AABCDEFGHIJKLMNOP"
  rule_case secret-github "a GitHub token" "gh""p_$(printf 'a%.0s' $(seq 1 36))"
  rule_case secret-openai "an OpenAI key" "sk-""$(printf 'b%.0s' $(seq 1 40))"
  rule_case secret-anthropic "an Anthropic key" "sk-""ant-$(printf 'c%.0s' $(seq 1 30))"
  rule_case secret-slack "a Slack token" "xo""xb-1234567890-abcdef"
  rule_case secret-google "a Google API key" "AI""za$(printf 'd%.0s' $(seq 1 35))"
  rule_case private-key "a private key header" "-----BEGIN OPENSSH PRIVATE ""KEY-----"
  rule_case quoted-secret "a quoted secret assignment" "API_TOKEN = \"$(printf 'e%.0s' $(seq 1 20))\""
}

test_findings_never_echo_the_secret() {
  local tok="gh""p_SECRETVALUE$(printf 'z%.0s' $(seq 1 30))"
  hy_repo "token=$tok"
  hy
  assert_rc 1 "a finding exits 1"
  assert_not_contains "$RUN_OUT$RUN_ERR" "SECRETVALUE" "the matched text is never printed"
  assert_match "$RUN_OUT" '^file\.txt:1: \[secret-github\]' "a finding names file, line and rule"
}

test_legitimate_forms_pass() {
  hy_repo "volumes:
  - state:/home/dev/.dck/volumes/state
  - x:/home/builder/.cache
DCK_AUTHORIZED_KEYS: \"\${DCK_AUTHORIZED_KEYS:-}\"
Report: security@dailybot.com, support@dailybot.com, conduct@dailybot.com
token: \${{ secrets.GITHUB_TOKEN }}
see /home/<name>/ for a placeholder"
  hy
  assert_rc 0 "container users, placeholders, allowed addresses and \${} references pass"
  assert_contains "$RUN_OUT" "no finding" "the clean result says so"
}

test_mixed_line_still_flagged() {
  hy_repo "paths /home/dev/x and /home/""carol/y"
  hy
  assert_rc 1 "an allowed path does not hide a personal one on the same line"
}

test_allow_list() {
  local fake="AKI""AFAKETEST00000000"
  hy_repo "aws_key = $fake" "tests/fixture-fake.txt"
  hy
  assert_rc 1 "an unlisted fixture is flagged"
  printf 'tests/fixture-*.txt secret-aws fake key used by a test (contains FAKE/TEST)\n' > "$SANDBOX/r/.public-hygiene-allow"
  hy
  assert_rc 0 "a listed fixture is allowed for its rule"
  printf 'tests/fixture-*.txt private-key wrong rule\n' > "$SANDBOX/r/.public-hygiene-allow"
  hy
  assert_rc 1 "an entry for another rule does not allow it"
}

test_scope_of_files() {
  hy_repo "clean"
  mkdir -p "$SANDBOX/r/.agents/skills/vendor"
  printf '%s\n' "/Users/""vendor/path" > "$SANDBOX/r/.agents/skills/vendor/x.md"
  printf '%s\n' "/Users/""untracked/path" > "$SANDBOX/r/untracked.txt"
  git -C "$SANDBOX/r" add .agents
  hy
  assert_rc 0 "vendored .agents/skills/ copies and untracked files are not checked"
  hy untracked.txt
  assert_rc 1 "explicit file arguments are checked"
  printf 'bin\000/Users/''zed\n' > "$SANDBOX/r/blob.bin"; git -C "$SANDBOX/r" add blob.bin
  hy blob.bin
  assert_rc 0 "binary files are skipped"
}

test_this_repository_is_clean() {
  run_cmd bash "$HY"
  assert_rc 0 "every tracked file of this repository passes"
  run_cmd bash "$HY" "$HY" "$DCK_REPO/.public-hygiene-allow"
  assert_rc 0 "the script and its allow-list do not match their own rules"
}

test_wired_into_ci() {
  assert_contains "$(cat "$DCK_REPO/.github/workflows/ci.yml")" "bash scripts/check-public-hygiene.sh" "CI runs the hygiene check"
  if command -v shellcheck >/dev/null 2>&1; then
    run_cmd shellcheck -S warning "$HY"
    assert_rc 0 "the script passes shellcheck"
  else
    unavailable "the script passes shellcheck" "shellcheck not installed"
  fi
}
