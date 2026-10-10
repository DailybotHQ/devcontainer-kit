# devcontainer-kit

A standard, agent-ready development container for any repository — rendered from one
template into the repository itself, run with `bash dev.sh up` or opened by your editor.

[![CI](https://github.com/DailybotHQ/devcontainer-kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/DailybotHQ/devcontainer-kit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/DailybotHQ/devcontainer-kit?sort=semver)](https://github.com/DailybotHQ/devcontainer-kit/releases/latest)
[![License: MIT](https://img.shields.io/github/license/DailybotHQ/devcontainer-kit)](LICENSE)

## What it is

Teams end up copying the same `dev.sh`, entrypoint and Dockerfile into every repository,
and the copies drift: different function names for the same thing, unpinned installers,
ports open on every interface, private keys copied into containers. devcontainer-kit is
that setup done once, as a tool, with safe defaults and tests. Built on the
[Dev Containers](https://containers.dev) spec:

- **a template** that `dck init` renders into each repository — and reconciles later,
  never clobbering your edits: `.devcontainer/devcontainer.json`,
  `docker/local/<service>/Dockerfile` (FROM the runtime's official image pinned by
  digest — node, python or debian — with every download verified),
  `docker/local/docker-compose.yaml` and `dev.sh`. No shared base image is involved;
- **`dck`**, the launcher behind `dev.sh` (`up`, `shell`, `rebuild`, `ssh`, `doctor`, …),
  with or without VS Code / Cursor and the `devcontainer` CLI;
- **inside every container**: DeepWorkPlan Vim, Herdr and
  [herdr-peers](https://github.com/DailybotHQ/herdr-peers), gh, git over SSH through the
  host's agent (no key copied in), and — opt-in — every coding agent through
  [coding-agents-kit](https://github.com/DailybotHQ/coding-agents-kit) (`ak`, autonomy by
  default, with the familiar `claudex` / `codex-glm` names);
- **Herdr, both ways**: the host Herdr attaches the container as a machine and it opens
  with the standard sidebar (Home · Editor · Development · Agents); agents inside can ask
  agents on the host and in other containers;
- **the `dck-dockerfile` skill**: an agent creates or regenerates a repository's
  container on request and proves it with a real build;
- **an entrypoint library** (persistent volumes, SSH, environment for SSH sessions,
  git identity) instead of a hand-copied entrypoint per repository.

## Install

Requires bash 3.2+ and python3 ≥ 3.11 on a Linux or macOS host; Docker (Desktop, OrbStack,
colima or Engine) with Compose v2 for the container verbs.

```bash
git clone --branch v0.1.6 https://github.com/DailybotHQ/devcontainer-kit
./devcontainer-kit/install.sh          # --no-rc for scripted installs, --uninstall to remove
dck --version
```

`install.sh` copies the kit to `~/.local/share/dck` and adds one guarded PATH block to
`~/.bashrc` / `~/.zshrc`. Nothing is downloaded and nothing runs as root. Each release
carries `SHA256SUMS` for the shipped files.

## Quickstart

```bash
cd your-repo
dck init --port web=4321   # renders the layout (shows a plan; asks before changing files)
bash dev.sh up             # first run: .env files, the dck SSH key; then build and start
bash dev.sh shell          # a login shell as the dev user in /workspace
bash dev.sh doctor         # what is wrong, if anything (dck doctor --json for tools and agents)
```

Or ask your agent: `dck --skill dck-dockerfile` is the skill that detects the runtime and
ports, renders the container and validates it with a real build.

Configuration lives in `.devcontainer/dck.toml` (interface 2):

```toml
interface = 2
service = "app"
flavour = "node-24"        # python-3.13 | node-24 | debian (official image, pinned by digest)
ssh_agent = true           # git over SSH through the host's agent; keys never enter
ssh_port = 22040           # loopback-only; 0 = no sshd
ports = { web = 4321 }     # published on 127.0.0.1
[layers]
agents = true              # coding-agents-kit (ak) + the CLIs in [agents].clis
editor = true              # nvim + DeepWorkPlan Vim
[agents]
clis = ["claude", "codex"]
[herdr]
machine = true             # register as a Herdr machine on `dev.sh up`
layout = "standard"        # Home · Editor · Development · Agents ("none" to skip)
```

### Acceptance checklist

What every rendered container gives you. After `bash dev.sh up` in your repository,
each item is one check:

1. **Layout** — `.devcontainer/devcontainer.json`, `docker/local/<service>/Dockerfile`
   (+ `dck/`), `docker/local/docker-compose.yaml` and `dev.sh` exist, and
   `devcontainer.json` names the same service as compose: `dck doctor --json` →
   `repo.vendored` is `current`.
2. **One entry point** — `bash dev.sh up` builds, starts and (with `[herdr] machine`)
   registers the container: `bash dev.sh ps`.
3. **Herdr attaches** — the host's Herdr lists the machine and its remote server answers:
   `dck herdr status`.
4. **Agents talk across machines** — inside, `herdr-peers list` shows the agents on the
   host and the other containers, and an `herdr-peers ask` gets its reply back:
   `bash dev.sh agents`.
5. **Git over SSH, no key inside** — `bash dev.sh shell -c 'ssh-add -l && git config user.name'`
   shows your agent's keys and your identity; `ssh -T git@github.com` greets you.
6. **Every coding agent** — `bash dev.sh shell -c 'ak doctor'` lists the CLIs from
   `[agents].clis`, and `claudex` / `codex-glm` are shell functions.
7. **Autonomy by default, opt-out documented** — `ak doctor --json` → `"permissions":
   "auto"`; `AGENTKIT_PERMISSIONS=ask` in `docker/local/<service>/.env` makes agents ask.
8. **Persistence** — after `bash dev.sh rebuild`, the CLIs' logins, `gh auth status`, the
   Herdr config, agentkit's keys and your git identity are still there.
9. **Editor** — `bash dev.sh shell -c 'git -C ~/.config/nvim describe --tags'` prints the
   pinned DeepWorkPlan Vim tag and `nvim` starts ready.
10. **The standard sidebar** — the attached machine opens with Home · Editor ·
    Development (server | tests) · Agents (Agent 1..4): `bash dev.sh herdr-layout --keep`
    recreates what is missing.

## Documentation

| Topic | |
| --- | --- |
| The launcher, verbs, exit codes | [docs/launcher.md](docs/launcher.md) |
| `dck init` and the template | [docs/init.md](docs/init.md) |
| `dck.toml` and the host profile | [docs/config.md](docs/config.md) |
| Pins, and the optional published base images | [docs/images.md](docs/images.md) |
| Opt-in layers (agents, dailybot, editor) | [docs/layers.md](docs/layers.md) |
| Entrypoint library | [docs/entrypoint.md](docs/entrypoint.md) |
| Herdr machines | [docs/herdr.md](docs/herdr.md) |
| `dck doctor --json` | [docs/doctor.md](docs/doctor.md) |
| Threat model and defaults | [docs/SECURITY.md](docs/SECURITY.md) |
| Tests | [docs/TESTING_GUIDE.md](docs/TESTING_GUIDE.md) |
| Agent skills | [skills/dck/SKILL.md](skills/dck/SKILL.md) (`dck --skill`), [skills/dck-dockerfile/SKILL.md](skills/dck-dockerfile/SKILL.md) (`dck --skill dck-dockerfile`) |
| Changes | [CHANGELOG.md](CHANGELOG.md) |

## Security

Loopback-only ports; the host's SSH agent (forwarded or the Docker Desktop socket),
never key copies or a mounted `~/.ssh`; host keys generated at runtime, never baked;
coding agents in autonomy by default inside the container — the sandbox — with an
`AGENTKIT_PERMISSIONS=ask` opt-out; no `cap_add`/`privileged`/Docker socket in the template; `.env`
files 0600 and never printed; every image input pinned by version and checksum;
repository configuration that reaches the host needs `--trust`. Report vulnerabilities
privately — see [SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome — read [CONTRIBUTING.md](CONTRIBUTING.md) (setup, the test
gate, Conventional Commits, PR flow) and the [Code of Conduct](CODE_OF_CONDUCT.md).
AI coding agents start at [AGENTS.md](AGENTS.md).

## License

MIT — see [LICENSE](LICENSE). Credits in [CREDITS.md](CREDITS.md). The base images
include [deepworkplan-vim](https://github.com/DailybotHQ/deepworkplan-vim) (GPL-3.0) as a
separate program; devcontainer-kit's own code stays MIT.

---

Part of the [DeepWorkPlan](https://deepworkplan.com) ecosystem — works on its own.
