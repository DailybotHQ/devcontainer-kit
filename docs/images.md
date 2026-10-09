# Base images

`ghcr.io/dailybothq/devcontainer-kit-base:<flavour>-<tag>` — three flavours
chosen by the **project's** runtime, identical otherwise.

| Flavour | FROM (pinned tag + digest) | Project runtime | Extra |
| --- | --- | --- | --- |
| `python-3.13` | `python:3.13.16-slim-trixie` | Python 3.13 + `uv` 0.12.24 | no Node (the agents layer adds it) |
| `node-24` | `node:24.21.0-trixie-slim` | Node 24 + corepack (pnpm) | `python3` from apt, no pip/venv — the tooling needs the stdlib only |
| `debian` | `debian:trixie-20261005-slim` | none | `python3` from apt |

## Every flavour contains

- git, git-lfs, gh **2.102.0**, sudo for the dev user, build-essential,
  curl/ca-certificates, ripgrep, fd (`fd` → `fdfind`), less, nano, procps,
  xz/unzip, locales (`en_US.UTF-8`);
- openssh-server with the hardened drop-in
  `/etc/ssh/sshd_config.d/10-dck.conf` — public keys only, no root, no
  passwords, agent forwarding allowed, local forwarding only — and **no host
  keys**: the entrypoint generates them at runtime into the persistent `state`
  volume ([entrypoint.md](entrypoint.md));
- Herdr **0.9.3** at `/usr/local/bin/herdr` (on the PATH of non-login SSH
  sessions, which is how a Herdr client starts the remote server) and a seeded
  `~/.config/herdr/config.toml` (login shell, `new_cwd = /workspace`,
  `allow_nested = true`);
- Neovim **0.12.5** (`/opt/nvim-0.12.5`, `/usr/local/bin/nvim`) and the
  deepworkplan-vim configuration at tag **v0.3.1** (commit-verified) in
  `~/.config/nvim`. Only the configuration is baked in; deepworkplan-vim's own
  plugin manager fetches its plugins on the first `nvim` launch, so nothing
  unpinned ends up in the image. `EDITOR`/`VISUAL`/`GIT_EDITOR` are `nvim`
  unless the editor layer is turned off;
- the entrypoint library `/usr/local/lib/dck/entrypoint.sh` and the default
  entrypoint `/usr/local/bin/dck-entrypoint`;
- a non-root user **`dev`, uid/gid 1000**, bash login shell (on `node` images
  the stock `node` user is renamed to `dev`);
- `/etc/dck/image.env` and `/etc/dck/versions.env` — what `dck doctor` reads
  to report drift.

## No flavour contains

Coding-agent CLIs (claude, codex, cursor `agent`, opencode, pi, cline, grok),
the Dailybot CLI, Engram, Graphify, provider wrappers, or any secret. Agents
are an opt-in **layer** of the repository's own image ([layers.md](layers.md)).
The `images` test scope and the release gate fail if any of those installers
appears under `images/`.

## Pins — `images/versions.env`

One file pins every input: base images by tag **and** digest, each tool by
version **and** SHA-256 per architecture (amd64, arm64), deepworkplan-vim by
tag **and** commit. `images/common/install.sh` downloads through a single
`fetch()` that refuses a checksum mismatch; nothing is piped into a shell.
The Dockerfiles' `FROM` defaults are checked against the pin file by the test
suite. Checksum provenance:

| Tool | Source of the SHA-256 |
| --- | --- |
| gh, Herdr | GitHub release asset digests published by the vendor |
| Node (agents layer) | nodejs.org `SHASUMS256.txt` |
| Neovim | computed at pin time from the release tarballs (the v0.12.5 release publishes no checksum file) |

To bump a tool: change its version and both checksums in `versions.env`, run
`bash tests/run.sh images` and the `docker` scope, then release.

## Building

```bash
docker build -f images/node-24/Dockerfile -t dck-base:node-24 .   # from the repo root
```

The build context is the repository root; each flavour's
`Dockerfile.dockerignore` sends only `images/` and the entrypoint library.

## Releases — `.github/workflows/release.yml`

An annotated tag `vX.Y.Z` that matches `VERSION` becomes a GitHub release: notes from
that version's `CHANGELOG.md` section (`scripts/release-notes.sh`), the asset
`SHA256SUMS` over the shipped files read from the tag (`scripts/release-sums.sh`), and a
pre-release flag for tags like `v0.2.0-beta.1`. The hygiene check runs first.

## Publishing — `.github/workflows/images.yml`

- **Tag `vX.Y.Z`** → `…:<flavour>-vX.Y.Z` for `linux/amd64` and `linux/arm64`,
  with provenance and an SBOM. Templates pin these **by digest**.
- **Nightly** (03:17 UTC) and manual runs → `…:<flavour>-nightly`, picking up
  base-image security updates without moving a release tag.
- Every pushed digest is written to the run summary and uploaded as an
  artifact; `dck doctor` compares a repository's pin with what is installed.
