#!/usr/bin/env bash
#
# scripts/release-sums.sh — SHA256SUMS of the files a release ships.
#
#   bash scripts/release-sums.sh <tag> [output]     (default output: SHA256SUMS)
#
# "Shipped" = what install.sh installs plus the install script and the top-level
# documents: bin/ lib/ src/ skills/ docs/schema/ images/versions.env install.sh
# VERSION LICENSE CREDITS.md README.md CHANGELOG.md — read from the TAG (git), never
# from the working tree, so the sums describe exactly what `git clone --branch <tag>`
# gives. Verify a clone with: shasum -a 256 -c SHA256SUMS (or sha256sum -c).
set -euo pipefail

tag="${1:-}"
out="${2:-SHA256SUMS}"
[ -n "$tag" ] || { echo "usage: release-sums.sh <tag> [output]" >&2; exit 2; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null || { echo "release-sums: no tag $tag" >&2; exit 2; }

if command -v sha256sum >/dev/null 2>&1; then sum() { sha256sum | cut -d' ' -f1; }
else sum() { shasum -a 256 | cut -d' ' -f1; }; fi

tmp="$(mktemp)"
git ls-tree -r --name-only "$tag" \
  | grep -E '^(bin/|lib/|src/|skills/|docs/schema/|images/versions\.env$|install\.sh$|VERSION$|LICENSE$|CREDITS\.md$|README\.md$|CHANGELOG\.md$)' \
  | LC_ALL=C sort \
  | while IFS= read -r f; do
      printf '%s  %s\n' "$(git show "$tag:$f" | sum)" "$f"
    done > "$tmp"
[ -s "$tmp" ] || { rm -f "$tmp"; echo "release-sums: $tag ships no file" >&2; exit 1; }
mv "$tmp" "$out"
echo "release-sums: $(wc -l < "$out" | tr -d ' ') file(s) -> $out"
