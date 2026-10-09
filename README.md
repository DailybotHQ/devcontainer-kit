# devcontainer-kit

A standard, agent-ready development container for any repository, built on the
[Dev Containers](https://containers.dev) spec:

- **a template** (`devcontainer.json` + compose + `docker/local/`) that `dck init`
  renders into a repository — and reconciles later, never clobbering your edits;
- **`dck`**, a launcher that runs it from a plain terminal (`setup`, `up`, `shell`,
  `rebuild`, `ssh`, `doctor`, …), with or without VS Code / Cursor;
- **base images** in `python-3.13`, `node-24` and `debian` flavours that ship
  **without** coding agents — agents are an opt-in layer;
- **an entrypoint library** (persistent volumes, SSH, environment for SSH sessions)
  instead of a hand-copied entrypoint per repository;
- **Herdr machines**: each container can join [Herdr](https://herdr.dev) over a
  loopback sshd with SSH agent forwarding.

> Part of the [DeepWorkPlan](https://deepworkplan.com) ecosystem, and fully usable
> without it.

## Why

Teams end up copying the same `dev.sh`, entrypoint and Dockerfile into every
repository, and the copies drift: different function names for the same thing,
unpinned installers, ports open on every interface, private keys copied into
containers. devcontainer-kit is that setup done once, as a tool, with safe
defaults and tests.

## Install

Requires bash 3.2+ and python3 ≥ 3.11 on a Linux or macOS host; Docker (Desktop,
OrbStack, colima or Engine) with Compose v2 for the container verbs.

```bash
git clone --branch v0.1.0 https://github.com/DailybotHQ/devcontainer-kit
./devcontainer-kit/install.sh          # --no-rc for scripted installs, --uninstall to remove
dck --version
```

`install.sh` copies the kit to `~/.local/share/dck` and adds one guarded PATH
block to `~/.bashrc` / `~/.zshrc`. Nothing is downloaded and nothing runs as root.
Verify a release with its `SHA256SUMS` asset.

## Quickstart

```bash
cd your-repo
dck init --port web=4321   # renders .devcontainer/ + docker/local/ (shows a plan; asks before changing files)
dck setup                  # .env files from their examples (0600), networks, the dck SSH key
dck up                     # start the container (and register it in Herdr, if dck.toml says so)
dck shell                  # a login shell as the dev user in /workspace
dck ssh                    # or SSH in, with your agent forwarded
dck doctor                 # what is wrong, if anything (--json for tools and agents)
```

Configuration lives in `.devcontainer/dck.toml`:

```toml
interface = 1
service = "app"
flavour = "node-24"        # python-3.13 | node-24 | debian
ssh_port = 22040           # loopback-only; 0 = no sshd
ports = { web = 4321 }     # published on 127.0.0.1
[layers]
agents = false             # coding-agents-kit + the CLIs in [agents].clis
editor = true              # nvim + deepworkplan-vim
[herdr]
machine = true             # register as a Herdr machine on `dck up`
```

The same layout opens in VS Code / Cursor ("Reopen in Container") and with the
`devcontainer` CLI; `dck` uses that CLI when it is installed.

## Security model

- Every published port binds **127.0.0.1** unless `dck.toml` sets `bind`.
- **Agent forwarding, never key copies**: containers trust one dedicated dck key;
  your own keys stay in your agent on the host.
- SSH host keys are generated at runtime into a per-project volume, never baked
  into images; sshd accepts public keys only, no root, no passwords.
- The template adds no `cap_add`, no `privileged`, no Docker socket, no mount of
  your home or `~/.ssh`.
- `.env` files are created 0600 and their values are never printed; `dck doctor`
  reports variable names only.
- Base images, tools and the editor are pinned by version **and** checksum in one
  file; nothing is piped into a shell. Coding-agent CLIs are never in a base image
  and no permission-bypass flag is ever enabled by default.

Details and the threat model: [docs/SECURITY.md](docs/SECURITY.md).

## Documentation

| Topic | |
| --- | --- |
| The launcher, verbs, exit codes | [docs/launcher.md](docs/launcher.md) |
| `dck init` and the template | [docs/init.md](docs/init.md) |
| `dck.toml` and the host profile | [docs/config.md](docs/config.md) |
| Base images and pins | [docs/images.md](docs/images.md) |
| Opt-in layers (agents, dailybot, editor) | [docs/layers.md](docs/layers.md) |
| Entrypoint library | [docs/entrypoint.md](docs/entrypoint.md) |
| Herdr machines | [docs/herdr.md](docs/herdr.md) |
| `dck doctor --json` | [docs/doctor.md](docs/doctor.md) |
| Security | [docs/SECURITY.md](docs/SECURITY.md) |
| Tests | [docs/TESTING_GUIDE.md](docs/TESTING_GUIDE.md) |
| Agent skill | [skills/dck/SKILL.md](skills/dck/SKILL.md) (`dck --skill`) |

## Images

`ghcr.io/dailybothq/devcontainer-kit-base:<flavour>-v0.1.0` for linux/amd64 and
linux/arm64 — see [docs/images.md](docs/images.md). `dck init` pins the digest in
your compose file.

## License

MIT — see [LICENSE](LICENSE). Credits in [CREDITS.md](CREDITS.md). The base images
include [deepworkplan-vim](https://github.com/DailybotHQ/deepworkplan-vim)
(GPL-3.0) as a separate program; devcontainer-kit's own code stays MIT.
