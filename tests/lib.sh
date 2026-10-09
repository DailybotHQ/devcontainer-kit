# shellcheck shell=bash
#
# tests/lib.sh — assertion helpers and the per-test sandbox.
#
# Sourced by tests/run.sh inside each test's subshell; never run directly.
# Result lines go to file descriptor 3 (opened by the runner). Everything the
# code under test prints goes to the test's log, which the runner shows only
# when the test fails (or with -v).

# --------------------------------------------------------------------------
# Sandbox
# --------------------------------------------------------------------------

# A fresh, private HOME per test function. Nothing a test does can reach the
# real home directory: HOME, every XDG base directory and git's global and
# system configuration are pointed into the sandbox or disabled.
dck_test_enter_sandbox() {
  SANDBOX="$(mktemp -d "$DCK_TEST_RUN_DIR/sbx.$1.$2.XXXXXX")" || exit 70
  SANDBOX="$(cd -P "$SANDBOX" && pwd)"
  export SANDBOX
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME"
  export XDG_CONFIG_HOME="$HOME/.config"
  export XDG_DATA_HOME="$HOME/.local/share"
  export XDG_STATE_HOME="$HOME/.local/state"
  export XDG_CACHE_HOME="$HOME/.cache"
  export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME="dck test" GIT_AUTHOR_EMAIL="dck-test@example.invalid"
  export GIT_COMMITTER_NAME="dck test" GIT_COMMITTER_EMAIL="dck-test@example.invalid"
  : > "$GIT_CONFIG_GLOBAL"
  # Nothing from the developer's own dck setup leaks into a test.
  local v
  for v in $(env | sed -n 's/^\(DCK_[A-Z0-9_]*\)=.*/\1/p'); do
    case "$v" in DCK_TEST_*|DCK_REPO) ;; *) unset "$v" ;; esac
  done
  unset SSH_AUTH_SOCK COMPOSE_PROJECT_NAME COMPOSE_FILE DOCKER_HOST HERDR_ENV
  export DCK_FAKE_LOG="$SANDBOX/fake.log"
  : > "$DCK_FAKE_LOG"
  export DCK_FAKE_STATE="$SANDBOX/fake-state"
  mkdir -p "$DCK_FAKE_STATE"
  cd "$SANDBOX" || exit 70
}

# Put the fake docker/devcontainer/herdr/ssh executables first on PATH. Each
# fake appends its argv to $DCK_FAKE_LOG and answers from $DCK_FAKE_STATE.
use_fakes() {
  export PATH="$TESTS_DIR/fakes/bin:$PATH"
}

# Copy a fixture tree into the sandbox and print its path.
fixture() {
  local name="$1" dest="${2:-$SANDBOX/$1}"
  mkdir -p "$dest"
  cp -R "$TESTS_DIR/fixtures/$name/." "$dest/"
  printf '%s\n' "$dest"
}

# --------------------------------------------------------------------------
# Result lines
# --------------------------------------------------------------------------

pass() { printf 'ok - %s\n' "$1" >&3; }

fail() {
  printf 'not ok - %s\n' "$1" >&3
  if [ $# -ge 2 ] && [ -n "$2" ]; then
    printf '%s\n' "$2" | sed 's/^/#     /' >&3
  fi
  return 0
}

unavailable() { printf 'unavailable - %s (%s)\n' "$1" "$2" >&3; }

# --------------------------------------------------------------------------
# Assertions
# --------------------------------------------------------------------------

assert_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected: [$2]
actual:   [$1]"; fi
}

assert_ne() {
  if [ "$1" != "$2" ]; then pass "$3"; else fail "$3" "both were: [$1]"; fi
}

assert_contains() {
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3" "missing: [$2]
in: $(printf '%s' "$1" | head -c 2000)" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3" "unexpected: [$2]" ;;
    *) pass "$3" ;;
  esac
}

assert_match() {
  if printf '%s\n' "$1" | grep -Eq -- "$2"; then pass "$3"; else fail "$3" "no line matches /$2/ in:
$(printf '%s' "$1" | head -c 2000)"; fi
}

assert_no_match() {
  if printf '%s\n' "$1" | grep -Eq -- "$2"; then fail "$3" "a line matches /$2/:
$(printf '%s\n' "$1" | grep -E -- "$2" | head -5)"; else pass "$3"; fi
}

assert_file() { if [ -f "$1" ]; then pass "$2"; else fail "$2" "not a file: $1"; fi; }
assert_dir() { if [ -d "$1" ]; then pass "$2"; else fail "$2" "not a directory: $1"; fi; }
assert_symlink() { if [ -L "$1" ]; then pass "$2"; else fail "$2" "not a symlink: $1"; fi; }
assert_absent() { if [ ! -e "$1" ] && [ ! -L "$1" ]; then pass "$2"; else fail "$2" "exists: $1"; fi; }

# Octal permission bits of a path (GNU and BSD stat disagree on flags).
file_mode() {
  if stat --version >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi
}

assert_mode() {
  local m
  m="$(file_mode "$1" 2>/dev/null || echo missing)"
  assert_eq "$m" "$2" "$3"
}

# run_cmd cmd args... — runs the command, never aborting the test.
# Sets RUN_RC, RUN_OUT (stdout) and RUN_ERR (stderr).
run_cmd() {
  local o="$SANDBOX/.run.out" e="$SANDBOX/.run.err"
  "$@" >"$o" 2>"$e"
  RUN_RC=$?
  RUN_OUT="$(cat "$o")"
  RUN_ERR="$(cat "$e")"
  # Echoed to the log so a failing test shows what the command said.
  printf '$ %s\n[rc=%s]\n%s\n%s\n' "$*" "$RUN_RC" "$RUN_OUT" "$RUN_ERR"
  return 0
}

# assert_rc <expected> <description> — checks the last run_cmd's status.
assert_rc() {
  if [ "$RUN_RC" = "$1" ]; then pass "$2"; else fail "$2" "expected exit $1, got $RUN_RC
stdout: $(printf '%s' "$RUN_OUT" | head -c 1500)
stderr: $(printf '%s' "$RUN_ERR" | head -c 1500)"; fi
}

# Lines the fakes logged, e.g. fake_calls docker
fake_calls() {
  if [ $# -eq 0 ]; then cat "$DCK_FAKE_LOG"; else grep "^$1 " "$DCK_FAKE_LOG" || true; fi
}

# --------------------------------------------------------------------------
# Docker availability (integration scopes)
# --------------------------------------------------------------------------

# Prints "available" or the reason it is not. Computed once per run.
docker_status() {
  local cache="$DCK_TEST_RUN_DIR/docker_status"
  if [ ! -f "$cache" ]; then
    if [ "${DCK_TEST_DOCKER:-}" = "0" ]; then
      echo "disabled by DCK_TEST_DOCKER=0" > "$cache"
    elif ! command -v docker >/dev/null 2>&1; then
      echo "docker CLI not found" > "$cache"
    elif python3 - <<'PY' >/dev/null 2>&1
import subprocess, sys
try:
    r = subprocess.run(["docker", "info", "--format", "{{.ServerVersion}}"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
except Exception:
    sys.exit(1)
sys.exit(r.returncode)
PY
    then
      echo "available" > "$cache"
    else
      echo "docker daemon not answering" > "$cache"
    fi
  fi
  cat "$cache"
}

# require_docker <description> — returns 1 (after an "unavailable" line) when
# no daemon answers, so a test can do: require_docker "x" || return 0
require_docker() {
  local s
  s="$(docker_status)"
  if [ "$s" = "available" ]; then return 0; fi
  unavailable "$1" "$s"
  return 1
}
