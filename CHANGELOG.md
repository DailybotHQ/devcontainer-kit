# Changelog

All notable changes to devcontainer-kit are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/) (0.x: a breaking change bumps the minor version
and the interface number).

## [Unreleased]

**Interface 2.** A repository's container is self-contained: no shared base image.

### Changed — breaking

- **The template renders a repository's own container.** `docker/local/<service>/Dockerfile`
  starts FROM the flavour's official image pinned by digest (node 24, python 3.13 or
  debian; `base_image` in dck.toml overrides it with another digest pin) and copies the
  build steps vendored into `docker/local/<service>/dck/` (byte copies of the kit's files,
  stamped with its version). Compose passes no base image; nothing depends on
  `ghcr.io/dailybothq/devcontainer-kit-base`, whose publishing stays optional.
- **dck.toml schema v2.** A v1 file is migrated by `dck init` (interface line, `image_tag`
  removed). New keys: `base_image`, `ssh_agent`, `herdr.layout`. `--image-tag` is gone;
  `--no-digest` is accepted and ignored.
- **doctor schema v2.** `repo.kit_version` and `repo.vendored` replace `image_tag` and
  `digest_match`; drift compares the kit a repository was rendered with.
- **Agents in autonomy by default.** The agents layer installs coding-agents-kit
  **v0.3.0** from its release tarball verified against a pinned sha256 (no git clone),
  the CLIs through `ak install` (pinned and verified by ak), and turns on the `classic`
  (`claudex`, …) and `providers` (`claude-glm`, `codex-glm`, …) presets. ak launches
  agents in autonomy by default — the container is the sandbox; the template spells no
  autonomy flag and documents the `AGENTKIT_PERMISSIONS=ask` opt-out.

### Added

- **`dev.sh`**, rendered at the repository root: `bash dev.sh up` (setup on the first
  run), `shell`, `rebuild`, `herdr`, `herdr-layout`, `agents`, `ask`, … over `dck`. A
  repository's own `dev.sh` without dck markers is kept.
- **Git over SSH through the host's agent**: the Docker Desktop socket (or
  `$SSH_AUTH_SOCK` on Linux) as `SSH_AUTH_SOCK`; the git identity from `DCK_GIT_*`, which
  `dck setup` fills from the host's git config; GitHub's published host keys pinned.
  No key file, no host `~/.ssh` or `~/.gitconfig` mount.
- **Herdr both ways**: herdr-peers (verified against its release `SHA256SUMS`) and Herdr's
  skill in every image, linked into each agent's skills; `dck herdr mesh` (run by
  `dck up`) makes the other dck containers — and the host, with `host_machine` — reachable
  from inside with no private key in the container; `dck agents` / `dck ask`.
- **The standard Herdr sidebar** inside every container — Home · Editor · Development
  (server | tests) · Agents (Agent 1..4) — via `dck herdr layout [--keep|--reset]`, run
  by `dck up` with `--keep`; `[herdr] layout = "none"` turns it off.
- **The `dck-dockerfile` skill** (`dck --skill dck-dockerfile`): detect or ask the
  runtime, ports and agents, render, validate with a real build, report.
- Non-login shells (docker exec, editor terminals) get the user tool PATH (`ak`, `nvim`).
- README: the **acceptance checklist** a repository verifies after `bash dev.sh up`.

## [0.1.6] — 2026-10-09

Interface stays **1**. Editor plugins pinned to commits (deepworkplan-vim v0.5.1).

### Changed

- Base images install deepworkplan-vim **v0.5.1** (commit
  `04dcbcbdb9760082915f3c17ac28a910983e7b0e`, installer SHA-256 `b0c531f6…`). The release
  pins every plugin and pckr to a commit in `pckr/lockfile.lua`, and `--strict` now fails the
  build when a plugin is away from its pin, so two builds of the same pins install the same
  plugin code. The "plugins come from each default branch" known limit is closed
  (`docs/SECURITY.md`).

## [0.1.5] — 2026-10-09

Interface stays **1**. Editor install through deepworkplan-vim's official installer.

### Changed

- Base images install deepworkplan-vim **v0.5.0** (commit
  `3b9c79a52f50ee7d3fd103e31c1a307bad661e59`) through its official installer instead of a
  hand-written clone: the versioned release asset (the file vim.deepworkplan.com serves) is
  checked against a pinned SHA-256 (`DWP_VIM_INSTALLER_SHA256`) and run as `dev` with
  `--version 0.5.0 --skip-packages --strict`, in its own image layer (`images/common/editor.sh`).
  Plugins are now installed at build time — `nvim` starts ready — instead of on first launch.
  The image keeps its own system-wide, SHA-256-pinned Neovim (the installer's `--nvim` is not used).
- Every flavour adds `tar`, `gzip`, `lua5.4` and `fontconfig`; `node-24` and `debian` add
  `python3-venv`; `python-3.13` and `debian` add Debian's `nodejs`/`npm` (for the editor's
  plugins only).
- The agents layer installs the pinned Node when `node` is missing **or older than the pinned
  major**, so Debian's `nodejs` never stands in for it.
- Image sizes grow with the baked-in plugins and their runtime dependencies (arm64, uncompressed):
  `node-24` 840 → 956 MB, `python-3.13` 732 → 1074 MB, `debian` 689 → 999 MB (most of the last
  two is Debian's `nodejs`/`npm`).
- The baked-in plugins are **not pinned** by this repository (deepworkplan-vim lists them without
  commits); `docs/SECURITY.md` records it as a known limit.
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

[Unreleased]: https://github.com/DailybotHQ/devcontainer-kit/compare/v0.1.6...HEAD
[0.1.6]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.6
[0.1.5]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.5
[0.1.4]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.4
[0.1.3]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.3
[0.1.2]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.2
[0.1.1]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.1
[0.1.0]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.0
