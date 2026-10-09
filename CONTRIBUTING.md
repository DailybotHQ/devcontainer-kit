# Contributing to devcontainer-kit

Thanks for helping. This project is small on purpose: bash 3.2+ and the python3 standard
library on the host, pinned and checksum-verified tools in the images, and a test suite
that every change keeps green.

## Development setup

You need bash, python3 ≥ 3.11, git, [shellcheck](https://www.shellcheck.net/), and — for
the integration scope — Docker with Compose v2. Nothing is installed to work on the
repository: run the tools from the checkout.

```bash
git clone https://github.com/DailybotHQ/devcontainer-kit
cd devcontainer-kit
bin/dck --version
```

## The gate

Every pull request must pass, locally and in CI:

```bash
bash tests/run.sh                                   # all scopes (docker last; "unavailable" without a daemon)
bash scripts/check-public-hygiene.sh                # no private names, personal paths or secrets
shellcheck -S warning bin/* lib/*.sh scripts/*.sh tests/run.sh install.sh
```

Run one area with `bash tests/run.sh <scope>`; the scopes and the source-to-test map are
in [docs/TESTING_GUIDE.md](docs/TESTING_GUIDE.md). Tests run in a sandbox `HOME`: never
point them at your real home.

## Commits and pull requests

- [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`,
  `test:`, `ci:`, `chore:` … with an optional scope, e.g. `fix(launcher): …`.
- One topic per pull request; fill in the template (summary, linked issue, test evidence,
  checklist). `main` is protected: CI must pass and a maintainer reviews before merge.
- Update the docs that describe what you changed (`docs/`, `README.md`, `CHANGELOG.md`
  under **Unreleased**).
- A DCO sign-off is **not** required.

## Ground rules

- English for code, comments and docs.
- Never commit a secret, a real token, a private hostname or personal data; the hygiene
  check enforces the common cases. Fixtures that need secret-shaped strings must be
  obviously fake and listed in `.public-hygiene-allow` with a reason.
- Pin every external tool by version and checksum in `images/versions.env`; never pipe a
  download into a shell; never add a permission-bypass flag by default.
- Security issues: see [SECURITY.md](SECURITY.md) — report privately, not in an issue.

AI coding agents working on this repository start at [AGENTS.md](AGENTS.md).

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
