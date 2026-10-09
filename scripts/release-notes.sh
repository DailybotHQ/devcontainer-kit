#!/usr/bin/env bash
#
# scripts/release-notes.sh — the CHANGELOG section of one version, for release notes.
#
#   bash scripts/release-notes.sh <version>     e.g. 0.1.3 (no leading v)
#
# Prints the body of "## [<version>] — <date>" up to the next "## [" heading.
# Exit 1 when the CHANGELOG has no such section (a release without notes is refused).
set -euo pipefail
v="${1:-}"
[ -n "$v" ] || { echo "usage: release-notes.sh <version>" >&2; exit 2; }
f="${CHANGELOG:-CHANGELOG.md}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
awk -v v="$v" '
  index($0, "## [" v "]") == 1 { on = 1; found = 1; next }
  on && /^## \[/ { exit }
  on && /^\[[^]]+\]: / { exit }
  on { print }
  END { if (!found) exit 1 }
' "$f" | sed -e '/./,$!d' > "$tmp" || { echo "release-notes: no section for $v in $f" >&2; exit 1; }
[ -s "$tmp" ] || { echo "release-notes: empty section for $v" >&2; exit 1; }
cat "$tmp"
