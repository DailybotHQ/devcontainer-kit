#!/usr/bin/env bash
#
# tests/run.sh — the devcontainer-kit test runner.
#
#   bash tests/run.sh                 every scope (unit scopes, then docker)
#   bash tests/run.sh <scope>...      only the named scopes
#   bash tests/run.sh --list          list the scopes and exit
#   bash tests/run.sh -k <pattern>    only test functions whose name matches
#   bash tests/run.sh -v              print each test's captured output
#
# A scope is tests/scopes/<scope>.sh. Every function named test_* in it runs
# in its own subshell with a fresh sandbox HOME (see tests/lib.sh). Results
# are written by the assertion helpers to file descriptor 3, never stdout, so
# output from the code under test can never be mistaken for a result line.
#
# Result lines: "ok - ...", "not ok - ...", "unavailable - ... (reason)".
# The LAST line is always the summary:
#   summary: scopes: N, passed: P, failed: F, unavailable: U
# Exit status: 0 when failed is 0, 1 otherwise, 2 on a usage error.
#
# Requires bash 3.2+ (the macOS system bash) and python3.

set -uo pipefail

_self="${BASH_SOURCE[0]}"
while [ -L "$_self" ]; do
  _dir="$(cd -P "$(dirname "$_self")" && pwd)"
  _self="$(readlink "$_self")"
  case "$_self" in /*) ;; *) _self="$_dir/$_self" ;; esac
done
TESTS_DIR="$(cd -P "$(dirname "$_self")" && pwd)"
DCK_REPO="$(cd -P "$TESTS_DIR/.." && pwd)"
SCOPES_DIR="${DCK_TEST_SCOPES_DIR:-$TESTS_DIR/scopes}"

# The canonical order. Scopes not listed here run after these, alphabetically.
# docker is last: it is the only integration scope and the slowest.
ORDER="harness config template images entrypoint launcher layers herdr doctor security hygiene standard docker"

usage_error() {
  printf 'tests/run.sh: %s\n' "$1" >&2
  printf 'summary: error: %s\n' "$1"
  exit 2
}

all_scopes() {
  local s f seen=" "
  for s in $ORDER; do
    if [ -f "$SCOPES_DIR/$s.sh" ]; then
      printf '%s\n' "$s"
      seen="$seen$s "
    fi
  done
  for f in "$SCOPES_DIR"/*.sh; do
    [ -f "$f" ] || continue
    s="$(basename "$f" .sh)"
    case "$seen" in *" $s "*) continue ;; esac
    printf '%s\n' "$s"
  done
}

VERBOSE=0
FILTER=""
REQUESTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --list) all_scopes; exit 0 ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -k) [ $# -ge 2 ] || usage_error "-k needs a pattern"; FILTER="$2"; shift 2 ;;
    -h|--help) sed -n '3,20p' "$TESTS_DIR/run.sh" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) usage_error "unknown flag '$1'" ;;
    *) REQUESTED+=("$1"); shift ;;
  esac
done

SCOPES=()
if [ "${#REQUESTED[@]}" -eq 0 ]; then
  while IFS= read -r s; do SCOPES+=("$s"); done < <(all_scopes)
else
  for s in "${REQUESTED[@]}"; do
    case "$s" in *[!a-z0-9_-]*|'') usage_error "invalid scope name '$s'" ;; esac
    [ -f "$SCOPES_DIR/$s.sh" ] || usage_error "unknown scope '$s' (see: bash tests/run.sh --list)"
    SCOPES+=("$s")
  done
fi
[ "${#SCOPES[@]}" -gt 0 ] || usage_error "no scopes found under $SCOPES_DIR"

# Per-run scratch: the docker-status cache and per-test result/log files.
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dck-run.XXXXXX")" || usage_error "cannot create a temporary directory"
trap 'rm -rf "$RUN_DIR"' EXIT

export DCK_REPO TESTS_DIR
export DCK_TEST_RUN_DIR="$RUN_DIR"
# The home the runner was started with, recorded only so the harness scope can
# prove the sandbox is somewhere else. Nothing ever writes through it.
export DCK_TEST_OUTER_HOME="${HOME:-}"

PASSED=0
FAILED=0
UNAVAILABLE=0

test_functions() {
  # Definition order, not alphabetical: a scope reads top to bottom.
  sed -n 's/^\(test_[A-Za-z0-9_]*\)[[:space:]]*()[[:space:]]*{.*$/\1/p' "$1"
}

count_results() {
  local line
  while IFS= read -r line; do
    case "$line" in
      "ok"|"ok "*) PASSED=$((PASSED + 1)) ;;
      "not ok"*) FAILED=$((FAILED + 1)) ;;
      "unavailable"*) UNAVAILABLE=$((UNAVAILABLE + 1)) ;;
    esac
  done < "$1"
}

run_test() {
  local scope="$1" fn="$2" file="$3"
  local results="$RUN_DIR/$scope.$fn.results" log="$RUN_DIR/$scope.$fn.log" rc
  : > "$results"
  (
    # shellcheck source=tests/lib.sh
    . "$TESTS_DIR/lib.sh"
    dck_test_enter_sandbox "$scope" "$fn"
    # shellcheck disable=SC1090
    . "$file"
    "$fn"
  ) 3>"$results" >"$log" 2>&1 </dev/null
  rc=$?
  # Result lines only: anything else on fd 3 is ignored, not counted.
  grep -E '^(ok|not ok|unavailable)( |$)' "$results" > "$results.clean" || true
  if [ "$rc" -ne 0 ] && ! grep -q '^not ok' "$results.clean"; then
    printf 'not ok - %s/%s exited %s without a failed assertion\n' "$scope" "$fn" "$rc" >> "$results.clean"
  fi
  if [ "$rc" -eq 0 ] && [ ! -s "$results.clean" ]; then
    printf 'not ok - %s/%s made no assertion\n' "$scope" "$fn" >> "$results.clean"
  fi
  cat "$results.clean"
  count_results "$results.clean"
  if [ "$VERBOSE" -eq 1 ] || grep -q '^not ok' "$results.clean"; then
    if [ -s "$log" ]; then
      printf '#   --- output of %s/%s (last 40 lines)\n' "$scope" "$fn"
      tail -n 40 "$log" | sed 's/^/#   /'
    fi
  fi
}

for scope in "${SCOPES[@]}"; do
  file="$SCOPES_DIR/$scope.sh"
  printf '# scope: %s\n' "$scope"
  fns="$(test_functions "$file")"
  if [ -z "$fns" ]; then
    printf 'not ok - scope %s defines no test_* function\n' "$scope"
    FAILED=$((FAILED + 1))
    continue
  fi
  for fn in $fns; do
    if [ -n "$FILTER" ]; then
      case "$fn" in *"$FILTER"*) ;; *) continue ;; esac
    fi
    run_test "$scope" "$fn" "$file"
  done
done

printf 'summary: scopes: %s, passed: %s, failed: %s, unavailable: %s\n' \
  "${#SCOPES[@]}" "$PASSED" "$FAILED" "$UNAVAILABLE"
[ "$FAILED" -eq 0 ]
