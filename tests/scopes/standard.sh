# shellcheck shell=bash
# Scope: standard — the ecosystem public repository standard (A3): S1 files and the
# S4 release workflow. Structure is asserted; wording stays the repository's own.

R="$DCK_REPO"
VERSION="$(cat "$R/VERSION")"

test_readme_sections_in_order() {
  local got
  got="$(sed -n 's/^## //p' "$R/README.md" | tr '\n' '|')"
  assert_eq "$got" "What it is|Install|Quickstart|Documentation|Security|Contributing|License|" "README sections follow the standard order"
  assert_eq "$(head -1 "$R/README.md")" "# devcontainer-kit" "README starts with the title"
  assert_match "$(sed -n 3p "$R/README.md")" '^A standard, agent-ready development container' "the title is followed by the one-line value"
  assert_contains "$(cat "$R/README.md")" "actions/workflows/ci.yml/badge.svg" "README has the CI badge"
  assert_contains "$(cat "$R/README.md")" "img.shields.io/github/v/release/DailybotHQ/devcontainer-kit" "README has the release badge"
  assert_contains "$(cat "$R/README.md")" "img.shields.io/github/license/DailybotHQ/devcontainer-kit" "README has the license badge"
  assert_contains "$(cat "$R/README.md")" "git clone --branch v$VERSION https://github.com/DailybotHQ/devcontainer-kit" "README installs from the pinned current tag"
  assert_contains "$(sed -n '/^## Security/,/^## /p' "$R/README.md")" "[SECURITY.md](SECURITY.md)" "README Security links SECURITY.md"
  assert_eq "$(tail -1 "$R/README.md")" "Part of the [DeepWorkPlan](https://deepworkplan.com) ecosystem — works on its own." "README ends with the ecosystem footer"
}

test_license_and_credits() {
  assert_eq "$(head -1 "$R/LICENSE")" "MIT License" "LICENSE is MIT (GitHub detects the SPDX id from it)"
  assert_contains "$(cat "$R/LICENSE")" "Copyright (c) 2026 DailybotHQ contributors" "LICENSE names DailybotHQ contributors"
  assert_file "$R/CREDITS.md" "CREDITS.md names the original author"
}

test_changelog_keep_a_changelog() {
  local c t v
  c="$(cat "$R/CHANGELOG.md")"
  assert_contains "$c" "[Keep a Changelog](https://keepachangelog.com/en/1.1.0/)" "the CHANGELOG declares Keep a Changelog"
  assert_match "$c" '^## \[Unreleased\]$' "the CHANGELOG has an Unreleased section"
  for t in $(git -C "$R" tag -l 'v[0-9]*'); do
    v="${t#v}"
    assert_match "$c" "^## \[$v\] — [0-9]{4}-[0-9]{2}-[0-9]{2}$" "the CHANGELOG has a dated section for $t"
    assert_match "$c" "^\[$v\]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/$t$" "the CHANGELOG links $t"
  done
  assert_no_match "$c" '^### (Removed|Added|Changed|Fixed|Security|Deprecated)[^ ]' "section headings are the Keep a Changelog types"
}

test_contributing() {
  local c; c="$(cat "$R/CONTRIBUTING.md")"
  assert_contains "$c" "bash tests/run.sh" "CONTRIBUTING gives the test gate"
  assert_contains "$c" "bash scripts/check-public-hygiene.sh" "CONTRIBUTING gives the hygiene gate"
  assert_contains "$c" "Conventional Commits" "CONTRIBUTING sets the commit convention"
  assert_contains "$c" "DCO sign-off is **not** required" "CONTRIBUTING states DCO is not required"
  assert_contains "$c" "[AGENTS.md](AGENTS.md)" "CONTRIBUTING links AGENTS.md"
  assert_contains "$c" "pull request" "CONTRIBUTING describes the PR flow"
}

test_security_policy() {
  local s; s="$(cat "$R/SECURITY.md")"
  assert_match "$s" '^## Supported versions$' "SECURITY.md has a supported versions table"
  assert_contains "$s" "security/advisories/new" "SECURITY.md points to private vulnerability reporting"
  assert_contains "$s" "security@dailybot.com" "SECURITY.md gives the security address"
  assert_contains "$s" "never in a public issue" "SECURITY.md forbids public issues for vulnerabilities"
  assert_match "$s" 'Acknowledgement \| within [0-9]+ business days' "SECURITY.md states response targets"
  assert_contains "$s" "[docs/SECURITY.md](docs/SECURITY.md)" "SECURITY.md links the threat model"
}

test_code_of_conduct() {
  local c; c="$(cat "$R/CODE_OF_CONDUCT.md")"
  assert_contains "$c" "# Contributor Covenant Code of Conduct" "the Code of Conduct is the Contributor Covenant"
  assert_contains "$c" "version 2.1" "it is version 2.1"
  assert_contains "$c" "enforcement at security@dailybot.com" "it names the reporting contact"
  assert_not_contains "$c" "[INSERT" "no placeholder is left"
}

test_agents_entry_point() {
  assert_symlink "$R/CLAUDE.md" "CLAUDE.md is a symlink"
  assert_eq "$(readlink "$R/CLAUDE.md")" "AGENTS.md" "CLAUDE.md points to AGENTS.md"
  local a; a="$(cat "$R/AGENTS.md")"
  for s in "## Purpose" "## Layout" "## Validation" "## Rules"; do
    assert_contains "$a" "$s" "AGENTS.md has $s"
  done
  assert_contains "$a" "bash scripts/check-public-hygiene.sh" "AGENTS.md lists the hygiene gate"
}

test_gitignore() {
  local g; g="$(cat "$R/.gitignore")"
  local p
  for p in "tmp/" ".env" ".env.*" "!.env.example" ".DS_Store" "Thumbs.db"; do
    assert_match "$g" "^$(printf '%s' "$p" | sed 's/[.*]/\\&/g')$" ".gitignore has $p"
  done
  # DeepWorkPlan v7 (spec/CONFIG.md): plans stay ignored, the addon registry is tracked.
  run_cmd git -C "$R" check-ignore -q .dwp/plans/PLAN_000_example/README.md
  assert_rc 0 ".dwp/ plans are ignored"
  run_cmd git -C "$R" check-ignore -q .dwp/config.json
  assert_rc 1 "the .dwp/config.json addon registry is tracked"
}

test_github_community_files() {
  local d="$R/.github"
  assert_file "$d/ISSUE_TEMPLATE/bug_report.yml" "a bug report form exists"
  assert_file "$d/ISSUE_TEMPLATE/feature_request.yml" "a feature request form exists"
  assert_contains "$(cat "$d/ISSUE_TEMPLATE/config.yml")" "blank_issues_enabled: false" "blank issues are off"
  assert_contains "$(cat "$d/ISSUE_TEMPLATE/config.yml")" "security/advisories/new" "security reports are routed privately"
  assert_contains "$(cat "$d/ISSUE_TEMPLATE/bug_report.yml")" "Security problems go to SECURITY.md" "the bug form routes security away"
  local f
  for f in bug_report feature_request config; do
    run_cmd python3 - "$d/ISSUE_TEMPLATE/$f.yml" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
assert "\t" not in text, "tabs in YAML"
assert re.search(r"^(name|blank_issues_enabled):", text, re.M), "top-level key missing"
PY
    assert_rc 0 "$f.yml is plain, tab-free YAML with its top-level key"
  done
  local p; p="$(cat "$d/PULL_REQUEST_TEMPLATE.md")"
  for s in "## Summary" "## Linked issue" "## Test evidence" "## Checklist"; do
    assert_contains "$p" "$s" "the PR template has $s"
  done
  assert_contains "$p" "No secrets, tokens, personal paths or private context" "the PR checklist covers secrets and private context"
  assert_match "$(cat "$d/CODEOWNERS")" '^\* @xergioalex$' "CODEOWNERS assigns every file"
  assert_contains "$(cat "$d/dependabot.yml")" "package-ecosystem: github-actions" "Dependabot watches GitHub Actions"
  assert_contains "$(cat "$d/dependabot.yml")" "interval: weekly" "weekly"
}

test_ci_workflow() {
  local c; c="$(cat "$R/.github/workflows/ci.yml")"
  assert_contains "$c" "pull_request:" "CI runs on pull requests"
  assert_contains "$c" "branches: [main]" "CI runs on pushes to main"
  assert_contains "$c" "bash tests/run.sh" "CI runs the full test gate"
  assert_contains "$c" "bash scripts/check-public-hygiene.sh" "CI runs the hygiene check"
  assert_contains "$c" "shellcheck -S warning" "CI lints"
}

test_no_placeholders() {
  local f
  for f in README.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md CHANGELOG.md AGENTS.md; do
    assert_no_match "$(cat "$R/$f")" '\[(TODO|TBD|FIXME)|\[INSERT|lorem ipsum' "$f has no placeholder"
  done
}

# ---- S4: release workflow -------------------------------------------------------------

rel_repo() {
  local d="$SANDBOX/rel"
  mkdir -p "$d/bin" "$d/lib" "$d/tests" "$d/images"
  git -C "$d" init -q
  echo "0.9.0" > "$d/VERSION"; echo "#!/bin/sh" > "$d/bin/dck"; echo "x" > "$d/lib/a.py"
  echo "MIT License" > "$d/LICENSE"; echo "K=V" > "$d/images/versions.env"; echo "t" > "$d/tests/t.sh"
  printf '# Changelog\n\n## [Unreleased]\n\n## [0.9.0] — 2026-01-02\n\n### Added\n\n- first\n\n## [0.8.0] — 2026-01-01\n\n- older\n\n[0.9.0]: https://example.invalid\n' > "$d/CHANGELOG.md"
  git -C "$d" add -A && git -C "$d" commit -qm init && git -C "$d" tag -a v0.9.0 -m v0.9.0
  echo "changed after the tag" > "$d/lib/a.py"
  printf '%s\n' "$d"
}

test_release_sums() {
  local d; d="$(rel_repo)"
  run_cmd bash -c 'cd "$1" && bash "$2" v0.9.0 SHA256SUMS' _ "$d" "$R/scripts/release-sums.sh"
  assert_rc 0 "release-sums succeeds on a tag"
  assert_eq "$(cut -d' ' -f3 "$d/SHA256SUMS" | tr '\n' ' ')" "CHANGELOG.md LICENSE VERSION bin/dck images/versions.env lib/a.py " "it lists exactly the shipped files (tests/ excluded)"
  run_cmd bash -c 'cd "$1" && git stash -q && shasum -a 256 -c SHA256SUMS' _ "$d"
  assert_rc 0 "the sums verify against the tagged content (not the working tree)"
  run_cmd bash -c 'cd "$1" && bash "$2" v9.9.9' _ "$d" "$R/scripts/release-sums.sh"
  assert_rc 2 "an unknown tag is refused"
}

test_release_notes() {
  local d; d="$(rel_repo)"
  run_cmd bash -c 'cd "$1" && bash "$2" 0.9.0' _ "$d" "$R/scripts/release-notes.sh"
  assert_eq "$RUN_OUT" "### Added

- first" "the notes are exactly that version's section"
  run_cmd bash -c 'cd "$1" && bash "$2" 0.8.0' _ "$d" "$R/scripts/release-notes.sh"
  assert_eq "$RUN_OUT" "- older" "the last section stops at the link references"
  run_cmd bash -c 'cd "$1" && bash "$2" 1.0.0' _ "$d" "$R/scripts/release-notes.sh"
  assert_rc 1 "a version without a section is refused"
  run_cmd env CHANGELOG="$R/CHANGELOG.md" bash "$R/scripts/release-notes.sh" "$VERSION"
  assert_rc 0 "this repository's CHANGELOG has notes for the current version"
}

test_release_workflow() {
  local w; w="$(cat "$R/.github/workflows/release.yml")"
  assert_contains "$w" 'tags: ["v*.*.*"]' "releases are triggered by version tags"
  assert_contains "$w" '[ "$(git cat-file -t "refs/tags/${TAG}")" = "tag" ]' "only annotated tags are released"
  assert_contains "$w" '[ "v$(git show "${TAG}:VERSION")" = "${TAG}" ]' "the tag must match VERSION"
  assert_contains "$w" 'bash scripts/release-sums.sh "${TAG}" SHA256SUMS' "SHA256SUMS is attached"
  assert_contains "$w" 'bash scripts/release-notes.sh "${TAG#v}"' "notes come from the CHANGELOG"
  assert_contains "$w" '*-*) pre="--prerelease"' "pre-release tags are flagged"
  assert_contains "$w" "bash scripts/check-public-hygiene.sh" "the hygiene check runs before publishing"
  assert_eq "$(grep -c 'contents: write' "$R/.github/workflows/release.yml")" "1" "only the release job can write"
  assert_no_match "$(grep -E 'uses:' "$R/.github/workflows/release.yml")" '@(v[0-9]|main)' "actions are pinned by SHA"
  assert_no_match "$(sed -n '/run: |/,$p' "$R/.github/workflows/release.yml" | grep -v '^ *TAG:\|^ *GH_TOKEN:')" '\$\{\{' "no expression is expanded inside a run: script"
}
