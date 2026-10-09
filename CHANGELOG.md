# Changelog

All notable changes to devcontainer-kit. Versions follow [SemVer](https://semver.org)
(0.x: a breaking change bumps the minor version and the interface number).

## [0.1.0] — 2026-10-09

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

[0.1.0]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.0
