# devcontainer-kit

A standard, agent-ready development container for any repository — rendered from one
template into the repository itself, run with `bash dev.sh up` or opened by your editor.

[![CI](https://github.com/DailybotHQ/devcontainer-kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/DailybotHQ/devcontainer-kit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/DailybotHQ/devcontainer-kit?sort=semver)](https://github.com/DailybotHQ/devcontainer-kit/releases/latest)
[![License: MIT](https://img.shields.io/github/license/DailybotHQ/devcontainer-kit)](LICENSE)

## What it is

For teams and agents that work in containers. Teams end up copying the same `dev.sh`,
entrypoint and Dockerfile into every repository, and the copies drift: different function
names for the same thing, unpinned installers, ports open on every interface, private
keys copied into containers. devcontainer-kit is that setup done once, as a tool, with
safe defaults and tests. Built on the [Dev Containers](https://containers.dev) spec:

- **a template** that `dck init` renders into each repository — and reconciles later,
  never clobbering your edits: `.devcontainer/devcontainer.json`,
  `docker/local/<service>/Dockerfile` (FROM the runtime's official image pinned by
  digest — node, python or debian — with every download verified),
  `docker/local/docker-compose.yaml` and `dev.sh`. No shared base image is involved;
- **`dck`**, the launcher behind `dev.sh` (`up`, `shell`, `rebuild`, `ssh`, `doctor`, …),
  with or without VS Code / Cursor and the `devcontainer` CLI;
- **inside every container**: DeepWorkPlan Vim, Herdr and herdr-peers, gh, git over SSH
  through the host's agent (no key copied in), and — opt-in — every coding agent through
  coding-agents-kit (`ak`): in autonomy by default, started unattended, and — when your
  host profile opts in — on your host's own accounts with no login inside;
- **Herdr, both ways**: the host Herdr attaches the container as a machine with the
  standard sidebar (App · Editor · Development · Agents); agents inside ask and answer
  agents on the host, in the other dck containers and in the host's other loopback
  containers;
- **the `dck-dockerfile` skill**: an agent creates or regenerates a repository's
  container on request and proves it with a real build;
- **an entrypoint library** (persistent volumes, SSH, environment for SSH sessions, git
  identity, agent trust) instead of a hand-copied entrypoint per repository.

## Install

Requires bash 3.2+ and python3 ≥ 3.11 on a Linux or macOS host; Docker (Desktop, OrbStack,
colima or Engine) with Compose v2 for the container verbs.

```bash
git clone --branch v0.3.3 https://github.com/DailybotHQ/devcontainer-kit
( cd devcontainer-kit && curl -fsSLO https://github.com/DailybotHQ/devcontainer-kit/releases/download/v0.3.3/SHA256SUMS \
    && shasum -a 256 -c SHA256SUMS )   # optional: verify the checkout against the release
./devcontainer-kit/install.sh          # --no-rc for scripted installs, --uninstall to remove
dck --version                          # devcontainer-kit 0.3.3
```

`install.sh` copies the kit to `~/.local/share/dck` and adds one guarded PATH block to
`~/.bashrc` / `~/.zshrc`. Nothing is downloaded and nothing runs as root.

## Quickstart

```bash
cd your-repo
dck init --port web=4321   # renders the layout (shows a plan; asks before changing files)
bash dev.sh up             # first run: .env files, the dck SSH key; then build and start
bash dev.sh shell          # a login shell as the dev user in /app
bash dev.sh doctor         # what is wrong, if anything (dck doctor --json for tools and agents)
```

Or ask your agent: `dck --skill dck-dockerfile` is the skill that detects the runtime and
ports, renders the container and validates it with a real build.

Configuration lives in `.devcontainer/dck.toml` (interface 2, committed with the
repository):

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
layout = "standard"        # App · Editor · Development · Agents ("none" to skip)
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
   `bash dev.sh agents`. The host is a peer once you accept the listener `dck setup`
   offers (or `dck host listener enable`); `dck setup` also installs a verified
   herdr-peers for the host, so `dck agents` / `dck ask` work there too.
5. **Git over SSH, no key inside** — `bash dev.sh shell -c 'ssh-add -l && git config user.name'`
   shows your agent's keys and your identity; `ssh -T git@github.com` greets you, and your
   `~/.ssh/config` aliases (`git@github.com-work:…`) work the same inside.
6. **Every coding agent** — `bash dev.sh shell -c 'ak doctor'` lists the CLIs from
   `[agents].clis`, and `claudex` / `codex-glm` are shell functions.
7. **Autonomy by default, opt-out documented** — `ak doctor --json` → `"permissions":
   "auto"`; `AGENTKIT_PERMISSIONS=ask` in `docker/local/<service>/.env` makes agents ask.
8. **Persistence** — after `bash dev.sh rebuild`, the CLIs' logins, `gh auth status`, the
   Herdr config, agentkit's keys and your git identity are still there.
9. **Editor** — `bash dev.sh shell -c 'git -C ~/.config/nvim describe --tags'` prints the
   pinned DeepWorkPlan Vim tag and `nvim` starts ready.
10. **The standard sidebar** — the attached machine opens with App · Editor ·
    Development (server | tests) · Agents (Agent 1..4): `bash dev.sh herdr-layout --keep`
    recreates what is missing.

## Core usage

| Command | What it does |
| --- | --- |
| `dck init [--agents --clis "claude codex"]` | renders or reconciles the layout; every change is a diff you accept |
| `bash dev.sh up` / `dck up [--recreate]` | `.env` files and the dck key, then build and start; registers the Herdr machine and runs the mesh |
| `bash dev.sh shell [-c CMD]` | a login shell (or one command) as the dev user in the app path |
| `dck rebuild` | rebuild the images and recreate the containers; named volumes (logins, history) survive |
| `dck agents` / `dck ask <machine>:<pane> "<prompt>"` | the live agents on every Herdr machine; ask one of them and get its reply (herdr-peers) |
| `dck doctor [--json]` | environment and repository health, names of secrets only |

### The host's agent accounts inside the container

New in v0.3.0. Opt in once, in your **host profile** (`~/.config/dck/profile.toml` — a
repository's `dck.toml` cannot ask for it):

```toml
[agents]
host_profiles = true
host_profile_names = []   # optional: only these profiles, e.g. ["claude@work1"]
host_env_keys = []        # optional: exact env names to share besides Claude's tokens
```

`dck up --recreate` then binds into the container, one by one, the host's
coding-agents-kit profiles of the CLIs the repository installs (claude, codex, pi, cline,
grok, opencode — never cursor; `host_profile_names = ["claude@work1"]` narrows them), the
host's `~/.codex` when codex is installed, and a generated env file read-only. The env
file holds no implicit secret: only the long-lived token of each shared Claude profile
(`CLAUDE_CODE_OAUTH_TOKEN_<PROFILE>`, and `CLAUDE_CODE_OAUTH_TOKEN` for Claude's own home)
plus the exact names you list. Mounts are read-write only where the CLI writes. Everything
goes through a runtime compose overlay that is never written into the repository.
`dck doctor` shows what is shared, by name, with each mount's mode and reason:

```text
layers           agents yes (claude codex), dailybot no, editor yes
host profiles    shared: claude@work1, codex@default
host profiles    claude@work1 rw — Claude rewrites its profile state (.claude.json, settings, sessions, history) on every run
host profiles    codex@default (the host's Codex home) rw — Codex refreshes its login in auth.json and writes sessions and history
host profiles    env file (ro) names: CLAUDE_CODE_OAUTH_TOKEN_WORK1
```

A Claude profile that logs in through the macOS keychain cannot reach a container; the
doctor names it and the variable to store its `claude setup-token` token under. With
autonomy on, agents in the container start unattended: the app path is pre-trusted for
Claude and Codex, and Claude's bypass-permissions acknowledgement is written only in the
container's own homes, never in your shared host profiles. Details:
[docs/layers.md](docs/layers.md#host-accounts).

### The full-stack path

From a bare host to agents on several accounts coordinating across the host and the
container:

1. **Host tools.** Install [coding-agents-kit](https://github.com/DailybotHQ/coding-agents-kit)
   (`ak`), [Herdr](https://herdr.dev) and devcontainer-kit; `dck setup` installs a
   verified herdr-peers for the host and offers the loopback listener that makes the host
   a peer of the containers.
2. **Accounts.** One ak profile per account (`ak profiles add claude @work1`); for Claude,
   `claude setup-token` per account and the token in ak's env file
   (`~/.config/agentkit/env`) as `CLAUDE_CODE_OAUTH_TOKEN_WORK1`.
3. **Host profile.** `[agents] host_profiles = true` in `~/.config/dck/profile.toml`.
4. **Repository.** `dck init --agents --clis "claude codex"` with `[herdr] machine = true`,
   then `bash dev.sh up`: the container joins Herdr with the standard sidebar and the mesh.
5. **Agents.** Inside, `ak claude @work1` starts with no login and no first-run screen;
   `herdr-peers list` shows the agents everywhere; on the host, `dck agents` and
   `dck ask` reach the ones inside.
6. **Plans.** With the [DeepWorkPlan](https://deepworkplan.com) skill in the repository,
   a lead agent splits a plan into lanes and hands each one to an agent on its own pane
   and account.

## How it fits with DeepWorkPlan

DeepWorkPlan's `devcontainer` addon is a thin integrator of this kit, pinned by tag: it
detects the kit with `dck doctor --json`, offers it, and renders a repository's container
through the `dck-dockerfile` skill. The addon is optional; the kit works on its own. The
page for it is [deepworkplan.com/kit/devcontainer](https://deepworkplan.com/kit/devcontainer).
Inside the container, the other ecosystem tools meet: `ak` runs the agents, Herdr and
herdr-peers connect them across machines, DeepWorkPlan Vim is the editor.

## Part of the DeepWorkPlan ecosystem

[DeepWorkPlan](https://deepworkplan.com) turns any repository into an AI-first,
agent-pilotable codebase. These projects ship together; every addon is optional.

| Repository | Role | Purpose |
| --- | --- | --- |
| [deepworkplan-skill](https://github.com/DailybotHQ/deepworkplan-skill) | Pack | The methodology, specification and kit as an installable agent skill |
| [coding-agents-kit](https://github.com/DailybotHQ/coding-agents-kit) | Addon: agentkit | One command for every coding agent: accounts, quota, `ak pick`, headless runs |
| [devcontainer-kit](https://github.com/DailybotHQ/devcontainer-kit) (this repository) | Addon: devcontainer | A reproducible dev container per repository, wired to Herdr and the host's accounts |
| [herdr-peers](https://github.com/DailybotHQ/herdr-peers) | Addon: Herdr | Ask an agent in another Herdr pane, on any machine, and get one authorized reply |
| [deepworkplan-vim](https://github.com/DailybotHQ/deepworkplan-vim) | Addon: DeepWorkPlan Vim | The terminal editor for plans: plan browser, lanes view, Markdown viewer |
| [ai-diff-reviewer](https://github.com/DailybotHQ/ai-diff-reviewer) | Required local review | Reviews a change set locally and in CI; every Final Review runs it |
| [agent-skill](https://github.com/DailybotHQ/agent-skill) | Addon: Dailybot | The Dailybot agent skill: progress reports, check-ins, chat and more |
| [deepworkplan.com](https://deepworkplan.com) ([source](https://github.com/DailybotHQ/deepworkplan-website)) | Site and hub | The methodology, specification, kit catalog and `/init.md`; coordinates the ecosystem |

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
| Several repositories in one compose project | [docs/shared-stack.md](docs/shared-stack.md) |
| `dck doctor --json` | [docs/doctor.md](docs/doctor.md) |
| Threat model and defaults | [docs/SECURITY.md](docs/SECURITY.md) |
| Tests | [docs/TESTING_GUIDE.md](docs/TESTING_GUIDE.md) |
| Agent skills | [skills/dck/SKILL.md](skills/dck/SKILL.md) (`dck --skill`), [skills/dck-dockerfile/SKILL.md](skills/dck-dockerfile/SKILL.md) (`dck --skill dck-dockerfile`) |
| Changes | [CHANGELOG.md](CHANGELOG.md) |

## Security

Loopback-only ports; the host's SSH agent (forwarded or the Docker Desktop socket),
never key copies or a mounted `~/.ssh`; host keys generated at runtime, never baked;
coding agents in autonomy by default inside the container — the sandbox — with an
`AGENTKIT_PERMISSIONS=ask` opt-out; the host's agent accounts shared only when your host
profile opts in, never at a repository's request; no `cap_add`/`privileged`/Docker socket in the template; `.env`
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
