# Changelog

All notable changes to devcontainer-kit are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/) (0.x: a breaking change bumps the minor version
and the interface number).

## [Unreleased]

### Changed

- Contributor tooling (not shipped): the repository vendors DeepWorkPlan **v7.0.1** and the AI
  Diff Reviewer **v3.3.0** (local review with `.review/extension.md`), adds the `dwp-*` command
  delegators, agent personas and catalogs under `.agents/`, and tracks the addon registry
  `.dwp/config.json`.

## [0.1.4] — 2026-10-09

Interface stays **1**. Editor pin only.

### Changed

- Base images install deepworkplan-vim **v0.4.1** (was v0.3.1), verified against commit
  `13db97c9691a864dadebf649fb656a55e6273f91`, matching the ecosystem's editor pin.

## [0.1.3] — 2026-10-09

Interface stays **1**. Repository standard and a doctor fix; no behaviour change for
`dck.toml`, the template or the images.

### Added

- Public-repository standard: `CONTRIBUTING.md`, `SECURITY.md` (policy), `CODE_OF_CONDUCT.md`
  (Contributor Covenant 2.1), `CLAUDE.md` → `AGENTS.md`, issue and pull-request templates,
  `CODEOWNERS`, Dependabot for GitHub Actions.
- `scripts/check-public-hygiene.sh` + `.public-hygiene-allow`: fails CI on personal paths,
  private names and secret patterns in tracked files (never printing the match).
- Release workflow: an annotated tag publishes the GitHub release with this CHANGELOG's
  notes and `SHA256SUMS` (`scripts/release-sums.sh`, `scripts/release-notes.sh`).

### Fixed

- `dck doctor` no longer reports a stuck Docker engine (`docker info` exiting 0 with its
  error on stdout) as an answering daemon.

## [0.1.2] — 2026-10-09

Interface stays **1**. Use it instead of 0.1.1 when you enable the agents layer.

### Fixed

- Agents layer: `ak install <cli>` for npm-distributed CLIs (codex, pi, cline …)
  failed for the dev user because Node's global prefix is root's. The layer now sets
  the dev user's npm prefix to `~/.local` (`~/.npmrc`, already on the login PATH).
  Verified in real python-3.13 and node-24 images with coding-agents-kit v0.1.1.
- `dck doctor` no longer reports the Docker daemon as answering when `docker info`
  exits 0 with empty fields.

## [0.1.1] — 2026-10-09

Security release; **use it instead of 0.1.0**. Interface stays **1** (additive).

### Security

- `dck ssh` and Herdr machines connect (and forward your SSH agent) only to
  127.0.0.1; a repository-chosen `bind` can no longer redirect the agent. The SSH
  include accepts only `HostName 127.0.0.1`.
- `up`/`start`/`build`/`rebuild` refuse a repository configuration that reaches the
  host (`initializeCommand`, `privileged`, `cap_add`, host namespaces, devices, the
  Docker socket, bind mounts or compose files outside the repository) unless you pass
  `--trust` / `DCK_TRUST=1`.
- `dck init` backups are created with `O_EXCL|O_NOFOLLOW` (never through a planted link).
- The compose overlay quotes values and escapes `$` (no YAML injection, no host
  variable interpolation into the container).
- `.env` handling acts only on regular files inside the repository; symlinked
  `.env`/compose/devcontainer files are ignored or refused; a compose project not
  named after the repository is announced.
- The entrypoint keeps the Herdr config owned by the dev user and writes its temp
  file with `O_EXCL|O_NOFOLLOW`; the images workflow passes the tag through `env`.

### Changed

- The agents layer pins coding-agents-kit **v0.1.1** (its v0.1.0 had a symlink-escape
  issue; ecosystem contract amendment A2).

### Fixed

- A dck key whose `.pub` was deleted is repaired with `ssh-keygen -y`.

## [0.1.0] — 2026-10-09

Superseded by 0.1.1 (security fixes).

First public release. **Interface 1** (`dck doctor --json` → `"interface": 1`).

### Added

- `dck` / `devcontainer-kit` launcher: `init`, `setup`, `up`, `down`, `stop`, `start`,
  `restart`, `ps`, `logs`, `shell`, `exec`, `build`, `rebuild`, `config`, `ports`,
  `ssh`, `doctor`, `herdr add|status|repair|remove`, `--skill`, `--version`.
  `devcontainer up/exec` when `@devcontainers/cli` is installed, compose otherwise;
  never `--remove-orphans`; refuses the directory-name default compose project.
- Dev Container template rendered by `dck init`: managed blocks, owned
  `devcontainer.json` keys and in-place `dck.toml` edits; diff + consent + backup
  for any change to an existing file; base image pinned by digest.
- `.devcontainer/dck.toml` and the host profile `~/.config/dck/profile.toml`, with
  JSON Schemas (`docs/schema/`).
- Base images `ghcr.io/dailybothq/devcontainer-kit-base:{python-3.13,node-24,debian}-v0.1.0`
  (amd64 + arm64): gh, Herdr, Neovim + deepworkplan-vim, hardened sshd without baked
  host keys, user `dev` (uid 1000) — no coding-agent CLI. One pin file with SHA-256
  checksums; nightly rebuilds as `<flavour>-nightly`.
- Entrypoint library: `dck_persist`, `dck_env_profile`, `dck_sshd`,
  `dck_authorize_keys`, `dck_herdr_config`, `dck_repo_hook`, `dck_layer_persist`,
  `dck_start`.
- Opt-in layers: `agents` (coding-agents-kit `v0.1.0`, one volume per CLI home),
  `dailybot`, `editor`.
- Herdr machines through a provenance-guarded `~/.ssh/config.d/dck` include with
  agent forwarding and per-alias host keys.
- `dck doctor --json` (schema `dck-doctor-v1`): runtime, repo, layers, ssh, herdr, drift.
- Agent skill `dck` (`skills/dck/SKILL.md`).
- `install.sh` (idempotent, `--no-rc`, `--uninstall`), test suite with unit scopes
  and a real-Docker integration scope, CI on Ubuntu and macOS.

[Unreleased]: https://github.com/DailybotHQ/devcontainer-kit/compare/v0.1.4...HEAD
[0.1.4]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.4
[0.1.3]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.3
[0.1.2]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.2
[0.1.1]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.1
[0.1.0]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.0
