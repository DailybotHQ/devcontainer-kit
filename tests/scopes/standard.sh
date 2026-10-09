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
  for p in ".dwp/" "tmp/" ".env" ".env.*" "!.env.example" ".DS_Store" "Thumbs.db"; do
    assert_match "$g" "^$(printf '%s' "$p" | sed 's/[.*]/\\&/g')$" ".gitignore has $p"
  done
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
