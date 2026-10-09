## Summary

<!-- What changes and why, in a few lines. -->

## Linked issue

<!-- Closes #… (or "none") -->

## Test evidence

<!-- Paste the summary lines, e.g.
summary: scopes: 13, passed: …, failed: 0, unavailable: …
public hygiene: … file(s) checked, no finding -->

## Checklist

- [ ] `bash tests/run.sh` passes (docker scope run, or reported unavailable with the reason)
- [ ] `bash scripts/check-public-hygiene.sh` passes
- [ ] `shellcheck -S warning bin/* lib/*.sh scripts/*.sh tests/run.sh install.sh` is clean
- [ ] Docs updated (`docs/`, `README.md`, `CHANGELOG.md` → Unreleased)
- [ ] No secrets, tokens, personal paths or private context (internal names, hostnames, people's data)
- [ ] New tools are pinned by version and checksum; no fetch-piped-to-shell; no default permission bypass
