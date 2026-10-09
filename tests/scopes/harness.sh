# shellcheck shell=bash
# Scope: harness — the runner and its sandbox test themselves.

FIX="$TESTS_DIR/fixtures/harness"

# Runs a nested runner over a fixture scope directory.
nested() {
  local dir="$1"; shift
  run_cmd env -u DCK_TEST_DOCKER DCK_TEST_SCOPES_DIR="$dir" bash "$TESTS_DIR/run.sh" "$@"
}

test_sandbox_home_is_private() {
  assert_ne "$HOME" "$DCK_TEST_OUTER_HOME" "HOME is not the outer home"
  assert_contains "$HOME" "$SANDBOX" "HOME lives inside the sandbox"
  assert_contains "$XDG_CONFIG_HOME" "$SANDBOX" "XDG_CONFIG_HOME lives inside the sandbox"
  assert_contains "$XDG_STATE_HOME" "$SANDBOX" "XDG_STATE_HOME lives inside the sandbox"
  assert_eq "$GIT_CONFIG_NOSYSTEM" "1" "git system config is disabled"
  assert_eq "$(pwd -P)" "$SANDBOX" "tests start in the sandbox directory"
}

test_sandbox_is_fresh_per_test() {
  # A file left by another test function would be visible here if sandboxes
  # were shared; each test gets a new directory under the run directory.
  assert_eq "$(ls -A "$HOME" | wc -l | tr -d ' ')" "0" "a new sandbox HOME starts empty"
  touch "$HOME/marker"
  assert_file "$HOME/marker" "the sandbox HOME is writable"
}

test_dck_environment_does_not_leak() {
  run_cmd env DCK_PROFILE=leaky bash -c ". '$TESTS_DIR/lib.sh'; DCK_TEST_RUN_DIR='$SANDBOX'; dck_test_enter_sandbox x y 3>/dev/null; echo \"[\${DCK_PROFILE:-}]\""
  assert_eq "$RUN_OUT" "[]" "DCK_* variables from the caller are cleared"
}

test_passing_scope_summary() {
  nested "$FIX/scopes-pass" sample
  assert_rc 0 "a passing scope exits 0"
  assert_match "$(printf '%s\n' "$RUN_OUT" | tail -1)" '^summary: scopes: 1, passed: [0-9]+, failed: 0, unavailable: [0-9]+$' "the last line is the summary"
  assert_not_contains "$RUN_OUT" "this stdout line is noise" "stdout of a test never reaches the results"
}

test_failures_are_counted() {
  nested "$FIX/scopes-fail" broken
  assert_rc 1 "a failing scope exits 1"
  assert_match "$RUN_OUT" '^not ok - deliberately unequal$' "a failed assertion is reported"
  assert_match "$RUN_OUT" '^not ok - broken/test_crash exited 3 without a failed assertion$' "a crash is a failure"
  assert_match "$RUN_OUT" '^not ok - broken/test_silent made no assertion$' "a test without assertions is a failure"
  assert_match "$RUN_OUT" '^ok - one passing line$' "passing tests still pass next to failures"
  assert_match "$(printf '%s\n' "$RUN_OUT" | tail -1)" 'passed: 1, failed: 3,' "the summary counts each outcome"
}

test_unknown_scope_is_a_usage_error() {
  nested "$FIX/scopes-pass" nope
  assert_rc 2 "an unknown scope exits 2"
  assert_not_contains "$(printf '%s\n' "$RUN_OUT" | tail -1)" "failed: 0" "a usage error never reads as a pass"
}

test_list_scopes() {
  nested "$FIX/scopes-pass" --list
  assert_eq "$RUN_OUT" "sample" "--list prints the scopes"
  run_cmd bash "$TESTS_DIR/run.sh" --list
  assert_match "$RUN_OUT" '^harness$' "the real scope list includes harness"
}

test_filter_by_name() {
  nested "$FIX/scopes-pass" -k test_one sample
  assert_match "$(printf '%s\n' "$RUN_OUT" | tail -1)" 'passed: 1, failed: 0' "-k selects matching tests only"
}

test_docker_disabled_reports_unavailable() {
  run_cmd env DCK_TEST_DOCKER=0 DCK_TEST_SCOPES_DIR="$FIX/scopes-pass" bash "$TESTS_DIR/run.sh" sample
  assert_rc 0 "docker disabled is not a failure"
  assert_match "$RUN_OUT" '^unavailable - docker-dependent check \(disabled by DCK_TEST_DOCKER=0\)$' "docker disabled is reported as unavailable"
  assert_match "$(printf '%s\n' "$RUN_OUT" | tail -1)" 'failed: 0, unavailable: 1$' "the summary counts unavailable separately"
}

test_docker_daemon_down_reports_unavailable() {
  run_cmd env -u DCK_TEST_DOCKER PATH="$FIX/fake-docker-down:$PATH" DCK_TEST_SCOPES_DIR="$FIX/scopes-pass" bash "$TESTS_DIR/run.sh" sample
  assert_rc 0 "a missing daemon is not a failure"
  assert_match "$RUN_OUT" '^unavailable - docker-dependent check \(docker daemon not answering\)$' "a daemon that does not answer is reported honestly"
  assert_not_contains "$RUN_OUT" "ok - docker answered" "nothing docker-dependent passes without a daemon"
}

test_docker_cli_missing_reports_unavailable() {
  local bin="$SANDBOX/bin" t
  mkdir -p "$bin"
  # A PATH with the tools the runner needs but no docker.
  for t in bash sh env python3 mktemp sed grep tail cat rm mkdir dirname basename readlink pwd tr wc head ls touch cp; do
    ln -s "$(command -v "$t")" "$bin/$t"
  done
  run_cmd env -u DCK_TEST_DOCKER PATH="$bin" DCK_TEST_SCOPES_DIR="$FIX/scopes-pass" "$bin/bash" "$TESTS_DIR/run.sh" sample
  assert_match "$RUN_OUT" '^unavailable - docker-dependent check \(docker CLI not found\)$' "a missing docker CLI is reported honestly"
}

test_runner_is_bash32_clean() {
  # bash 3.2 (macOS) has no associative arrays, mapfile or ${x,,}.
  local f bad=""
  for f in "$TESTS_DIR/run.sh" "$TESTS_DIR/lib.sh"; do
    if grep -nE 'declare -A|mapfile|readarray|\$\{[A-Za-z_]+(,,|\^\^)' "$f" >/dev/null; then bad="$bad $f"; fi
  done
  assert_eq "$bad" "" "runner and helpers avoid bash 4-only features"
}

test_docker_empty_info_reports_unavailable() {
  run_cmd env -u DCK_TEST_DOCKER PATH="$FIX/fake-docker-empty:$PATH" DCK_TEST_SCOPES_DIR="$FIX/scopes-pass" bash "$TESTS_DIR/run.sh" sample
  assert_match "$RUN_OUT" '^unavailable - docker-dependent check \(docker daemon not answering\)$' "docker info exiting 0 without a server version is reported as not answering"
}

test_docker_probe_ignores_the_fakes() {
  # With the fake docker first on PATH, the probe must still ask the real one.
  run_cmd env -u DCK_TEST_DOCKER PATH="$TESTS_DIR/fakes/bin:$FIX/fake-docker-empty:$PATH" bash -c '. "$1"; DCK_TEST_RUN_DIR="$2"; TESTS_DIR="$3"; PATH="$TESTS_DIR/fakes/bin:$4"; docker_status' _ "$TESTS_DIR/lib.sh" "$SANDBOX" "$TESTS_DIR" "$FIX/fake-docker-empty:$PATH"
  assert_eq "$RUN_OUT" "docker daemon not answering" "the cached docker status is never decided by the fake docker"
}
