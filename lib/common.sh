# shellcheck shell=bash
#
# lib/common.sh — helpers shared by bin/dck and the lib/*.sh modules.
# bash 3.2 compatible (the macOS system bash): no associative arrays, no
# mapfile, no ${var,,}.

# Exit codes (also documented in docs/launcher.md):
#   0 ok · 1 operation failed · 2 usage · 3 configuration · 4 environment
#   (docker/python/herdr missing or not answering) · 5 refused (safety)
# shellcheck disable=SC2034  # used by the other lib/*.sh modules
DCK_EXIT_FAIL=1
# shellcheck disable=SC2034
DCK_EXIT_USAGE=2
# shellcheck disable=SC2034
DCK_EXIT_CONFIG=3
DCK_EXIT_ENV=4
# shellcheck disable=SC2034
DCK_EXIT_REFUSED=5

die() {
  local code="$DCK_EXIT_FAIL"
  case "${1:-}" in [0-9]|[0-9][0-9]) code="$1"; shift ;; esac
  printf 'dck: %s\n' "$*" >&2
  exit "$code"
}
note() { printf '%s\n' "$*"; }
warn() { printf 'dck: %s\n' "$*" >&2; }

dck_version() {
  cat "$DCK_ROOT/VERSION" 2>/dev/null || echo "0.0.0"
}

# The first python3 >= 3.11 (tomllib): $DCK_PYTHON, python3, python3.13 ... 3.11.
dck_find_python() {
  local c
  for c in ${DCK_PYTHON:-} python3 python3.14 python3.13 python3.12 python3.11; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

dck_require_python() {
  [ -n "${DCK_PY:-}" ] && return 0
  DCK_PY="$(dck_find_python)" || die "$DCK_EXIT_ENV" "python3 >= 3.11 is required (tomllib); set DCK_PYTHON to one"
}

# Runs the python side in isolated mode: the repository's own files can never
# shadow a standard-library module.
dckpy() {
  dck_require_python
  "$DCK_PY" -I "$DCK_LIB/dckpy.py" "$@"
}
