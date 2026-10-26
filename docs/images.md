# Base images (optional) and pins

Since v0.2.0 a repository's container needs **no** shared base image: `dck init` renders
`docker/local/<service>/Dockerfile` FROM the runtime's official image pinned by digest
and copies the same build steps into `docker/local/<service>/dck/`, so the image is
built from the repository itself (dck.toml `base_image` replaces that `FROM`, pinned by
digest). The published
`ghcr.io/dailybothq/devcontainer-kit-base:<flavour>-<tag>` images below remain optional:
they are built from the same steps, for teams that want a prebuilt image, and nothing in
dck depends on them. The three flavours are chosen by the **project's** runtime,
identical otherwise.

| Flavour | FROM (pinned tag + digest) | Project runtime | Extra |
| --- | --- | --- | --- |
| `python-3.13` | `python:3.13.16-slim-trixie` | Python 3.13 + `uv` 0.12.24 | Debian's `nodejs`/`npm` for the editor's plugins only (the agents layer adds the pinned Node) |
| `node-24` | `node:24.21.0-trixie-slim` | Node 24 + corepack (pnpm) | `python3` + `python3-venv` from apt (the tooling needs the stdlib; venv is for the editor's plugins) |
| `debian` | `debian:trixie-20261005-slim` | none | `python3`, `python3-venv`, Debian's `nodejs`/`npm` from apt (the agents layer adds the pinned Node) |

## Every flavour contains

- git, git-lfs, gh **2.102.0**, sudo for the dev user, build-essential,
  curl/ca-certificates, ripgrep, fd (`fd` → `fdfind`), less, nano, procps,
  bash-completion, tzdata, xz/unzip/tar/gzip, lua5.4, fontconfig, locales
  (`en_US.UTF-8`) — the last few plus a Node and Python venv are what
  deepworkplan-vim's plugins need;
- the system git config `safe.directory = *` (the repository is bind-mounted with
  the host's ownership) and `init.defaultBranch = main`;
- openssh-server with the hardened drop-in
  `/etc/ssh/sshd_config.d/10-dck.conf` — public keys only, no root, no
  passwords, agent forwarding allowed, local forwarding only — and **no host
  keys**: the entrypoint generates them at runtime into the persistent `state`
  volume ([entrypoint.md](entrypoint.md)); openssh-client, with GitHub's published
  host keys in `/etc/ssh/ssh_known_hosts`, so `git` over SSH never asks to trust one;
- Herdr **0.9.3** at `/usr/local/bin/herdr` (on the PATH of non-login SSH
  sessions, which is how a Herdr client starts the remote server) and a seeded
  `~/.config/herdr/config.toml` (login shell, `new_cwd` = the app path (dck.toml `workspace`, default `/app`),
  `allow_nested = true`);
- Neovim **0.12.5** (`/opt/nvim-0.12.5`, `/usr/local/bin/nvim`, SHA-256
  pinned per architecture) and deepworkplan-vim **v1.0.1** in `~/.config/nvim`,
  installed in its own image layer (`images/common/editor.sh`) by the
  project's official installer — the one `https://vim.deepworkplan.com/install.sh`
  serves — downloaded from the versioned release asset, checked against its
  pinned SHA-256 and then run as `dev` in container mode:
  `bash install.sh --version 1.0.0 --skip-packages --strict`. `--strict` fails
  the build if the headless plugin install fails, leaves a required plugin
  missing, or leaves a plugin away from the commit deepworkplan-vim pins in
  `pckr/lockfile.lua`, so the plugins are **baked in**, pinned, and `nvim`
  starts ready. A plugin clone that loses a race with the network is the one
  transient failure: when `--strict` reports a plugin problem, `editor.sh` runs
  the installer again (a rerun updates in place and re-syncs only what is
  missing), up to 3 attempts with a growing pause, then fails the build; any
  other installer failure fails it at once. The
  configuration must resolve to the pinned commit. Plugin build steps that
  need pnpm get it on every flavour: `node-24` has it, `python-3.13` and
  `debian` get a build-only wrapper around Debian's corepack (no `pnpm` is
  left on their PATH). The plugin commits are pinned upstream, by the
  release's lockfile, not by this repository ([SECURITY.md](SECURITY.md), known limits). `--nvim` is not used: the
  installer would put a second Neovim in `~/.local/bin`, which non-login SSH
  sessions (Herdr) and `docker exec` do not have on PATH, and it resolves its
  checksum through the GitHub API at build time; the image's system-wide
  pinned Neovim covers every user. `EDITOR`/`VISUAL`/`GIT_EDITOR` are `nvim`;
  in a repository's rendered image the editor layer decides: with `[layers]
  editor = false` deepworkplan-vim is not installed and the editor is `nano`
  (Neovim itself stays, [layers.md](layers.md#editor));
- the entrypoint library `/usr/local/lib/dck/entrypoint.sh` and the default
  entrypoint `/usr/local/bin/dck-entrypoint`;
- the opt-in layer installers at `/usr/local/lib/dck/layers/` and their dispatcher
  `/usr/local/bin/dck-layer` — scripts only, run by a repository's own build
  ([layers.md](layers.md));
- the login profile `/etc/profile.d/00-dck.sh` (user tool directories on PATH, the
  container environment for SSH sessions, `HERDR_PEERS_SELF`, the SSH agent
  fallback) and a `~/.bashrc` that loads it for non-login shells too;
- a non-root user **`dev`, uid/gid 1000**, bash login shell (on `node` images
  the stock `node` user is renamed to `dev`);
- `/etc/dck/image.env` and `/etc/dck/versions.env` — what `dck doctor` reads
  to report drift.

## What a repository's rendered image adds

The Dockerfile `dck init` renders runs the same `install.sh` and `editor.sh`
(vendored into `docker/local/<service>/dck/` with a `VERSION` stamp) and adds:

- **herdr-peers v1.1.0** (`images/common/peers.sh`): fetched from its tag's source,
  every file checked against that release's `SHA256SUMS`, itself pinned by sha256;
  installed at `/usr/local/share/dck/skills/herdr-peers` with `/usr/local/bin/herdr-peers`,
  next to Herdr's own skill (`herdr --skill`, matching the pinned binary). The
  entrypoint links both into each agent's skills directory ([herdr.md](herdr.md));
- `/usr/local/bin/dck-herdr-layout`, the standard Herdr sidebar
  ([herdr.md](herdr.md#the-standard-sidebar-inside-dck-herdr-layout));
- the dck.toml user (`user` other than `dev` renames the uid-1000 user) and workspace
  (`WORKDIR`, default `/app`; the base images use `/workspace`);
- the opt-in layers ([layers.md](layers.md)), between the `dck:layers` markers.

The published base images carry neither herdr-peers nor the layout script.

## No flavour contains

Coding-agent CLIs (claude, codex, cursor `agent`, opencode, pi, cline, grok, antigravity `agy`),
the Dailybot CLI, Engram, Graphify, provider wrappers, or any secret. Agents
are an opt-in **layer** of the repository's own image ([layers.md](layers.md)).
The `images` test scope and the release gate fail if any of those installers
appears under `images/`.

## Pins — `images/versions.env`

One file pins every input: base images (and the `uv` image) by tag **and** digest,
each tool by version **and** SHA-256 per architecture (amd64, arm64),
deepworkplan-vim by tag, commit **and** installer SHA-256, and the opt-in layers'
inputs — coding-agents-kit **v1.1.0** (`AGENTKIT_TAG`, tarball `AGENTKIT_SHA256`),
Node **24.21.0** for the agents layer, the Dailybot CLI **3.27.0** wheel and uv
**0.12.24** for the dailybot layer. `images/common/install.sh` and
`images/common/editor.sh` download through a `fetch()` that refuses a checksum
mismatch; nothing is piped into a shell.
The Dockerfiles' `FROM` defaults are checked against the pin file by the test
suite. Checksum provenance:

| Tool | Source of the SHA-256 |
| --- | --- |
| gh, Herdr | GitHub release asset digests published by the vendor |
| Node (agents layer) | nodejs.org `SHASUMS256.txt` |
| herdr-peers | the SHA-256 of that release's `SHA256SUMS` (`HERDR_PEERS_SUMS_SHA256`); every installed file is then verified against it |
| Neovim | computed at pin time from the release tarballs (the v0.12.5 release publishes no checksum file) |
| deepworkplan-vim | the release's `install.sh.sha256` / `SHA256SUMS` (`DWP_VIM_INSTALLER_SHA256`), and the peeled tag commit (`DWP_VIM_COMMIT`) the installed configuration must resolve to |
| coding-agents-kit (agents layer) | the release tarball's sha256 from that release's `SHA256SUMS` (`AGENTKIT_SHA256`) |
| Dailybot CLI, uv (dailybot layer) | the PyPI wheel's SHA-256; uv's GitHub release digests |

To bump a tool: change its version and both checksums in `versions.env`, re-render
this repository's own container (`bin/dck init --repo .`: the `images` scope fails
while `docker/local/app/dck/` differs from its sources or from `VERSION`), run
`bash tests/run.sh images` and the `docker` scope, then release.

## Building

```bash
docker build -f images/node-24/Dockerfile -t dck-base:node-24 .   # from the repo root
```

The build context is the repository root; each flavour's
`Dockerfile.dockerignore` sends only `images/versions.env`, `images/common/`, the
entrypoint library and `lib/layers/`.

## Releases — `.github/workflows/release.yml`

An annotated tag `vX.Y.Z` that matches `VERSION` becomes a GitHub release: notes from
that version's `CHANGELOG.md` section (`scripts/release-notes.sh`), the asset
`SHA256SUMS` over the shipped files read from the tag (`scripts/release-sums.sh`), and a
pre-release flag for tags like `v0.2.0-beta.1`. The hygiene check runs first.

## Publishing — `.github/workflows/images.yml`

- **Tag `vX.Y.Z`** → `…:<flavour>-vX.Y.Z` for `linux/amd64` and `linux/arm64`,
  with provenance and an SBOM. A team that uses them pins one **by digest**
  (dck.toml `base_image`); `dck init` does not.
- **Nightly** (03:17 UTC) and manual runs → `…:<flavour>-nightly`, picking up
  base-image security updates without moving a release tag.
- Every pushed digest is written to the run summary and uploaded as an
  artifact; `dck doctor` compares the container's `/etc/dck/image.env` with the
  kit's pins (gh, Neovim, deepworkplan-vim, Herdr).
