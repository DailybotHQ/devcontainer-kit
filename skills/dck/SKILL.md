---
name: dck
description: Operate a repository's development container with devcontainer-kit (dck) — render the Dev Container template (dck init), start/enter/rebuild it from a terminal (dck setup|up|shell|exec|rebuild|down), SSH in with agent forwarding, register it as a Herdr machine (dck herdr add|status|repair), and diagnose it (dck doctor --json). Use only when the user mentions dck or devcontainer-kit, a dev container / devcontainer / .devcontainer/ or docker/local/ setup they want created or operated, or a container they want as a Herdr machine. Do not use for building or deploying production images, for Kubernetes, or merely because a repository contains a Dockerfile.
license: MIT
metadata:
  version: 0.1.3
  interface: 1
  homepage: https://github.com/DailybotHQ/devcontainer-kit
---

# dck — devcontainer-kit

`dck` (long name `devcontainer-kit`) gives any repository a standard,
agent-ready development container built on the Dev Containers spec and runs it
from a plain terminal. It works without VS Code, without DeepWorkPlan and
without Herdr; each of those only adds to it.

## Check before acting

```bash
dck --version                  # is it installed?
dck doctor --json              # interface, runtime, repo, layers, ssh, herdr, drift
```

Read `interface` first: this skill speaks interface **1**. If `dck` is missing,
tell the user and show the pinned install line — do not install it without
being asked:

```bash
git clone --branch v0.1.3 https://github.com/DailybotHQ/devcontainer-kit
./devcontainer-kit/install.sh
```

## Tasks

| The user wants… | Run |
| --- | --- |
| a dev container for this repo | `dck init --dry-run`, show the plan, then `dck init` (add `--yes` only after the user agreed to the diffs) |
| to start it | `dck setup && dck up` |
| a shell / one command inside | `dck shell` · `dck shell -c "<cmd>"` · `dck exec <service> <cmd…>` |
| it rebuilt after Dockerfile changes | `dck rebuild` (`--no-cache` for a clean build) |
| it stopped / removed | `dck stop` · `dck down` (named volumes are kept) |
| to see what dck resolved | `dck config`, `dck ports`, `dck ps`, `dck logs --no-follow` |
| SSH into it | `dck ssh [cmd…]` |
| it in Herdr | set `[herdr] machine = true` and `ssh_port` in `.devcontainer/dck.toml`, then `dck up` (or `dck herdr add`); `dck herdr status`; a client stuck on "reconnecting" → `dck herdr repair` |
| coding-agent CLIs inside | set `[layers] agents = true` and `[agents] clis = [...]` in `dck.toml`, `dck init` (shows the diff), `dck rebuild` |
| to know what is wrong | `dck doctor` (human) or `dck doctor --json` (parse `problems`) |

Configuration lives in `.devcontainer/dck.toml` (per repo, committed) and
`~/.config/dck/profile.toml` (per host). Edit `dck.toml`, then re-run
`dck init` — it reconciles the generated files and shows diffs.

Exit codes: 0 ok, 1 failed, 2 usage, 3 configuration, 4 environment
(docker/python missing), 5 refused by a safety rule. On 5, read the message:
it names the rule (e.g. clobbering a file, the directory-default compose
project, a configuration that reaches the host) — do not work around it, ask
the user. Never add `--trust` / `DCK_TRUST=1` yourself: it means the user has
read the repository's container configuration and accepts what it does on the
host.

## Rules for agents

- `dck init` changes existing files only with consent. Run `--dry-run` first,
  show the user the diffs, and pass `--yes` only once they agree. Backups are
  kept as `<file>.dck-bak-<timestamp>`.
- Never print, log or paste the contents of `docker/local/**/.env` or any
  value of a `*_API_KEY` / `*_TOKEN` variable. `dck doctor` reports variable
  names only — use it instead of `cat`.
- Never add `cap_add`, `privileged`, the Docker socket, `0.0.0.0` binds or a
  host `~/.ssh` mount to the generated files; if a user asks for one, explain
  the exposure (see the project's `docs/SECURITY.md`) and let them make that
  edit as their own decision.
- Coding agents inside the container run through coding-agents-kit (`ak`),
  which is permission pass-through by default. Never enable an autonomy or
  bypass mode on the user's behalf.
- Prefer `dck shell -c` / `dck exec` over raw `docker compose`: dck applies the
  right project, user, workspace and overlay, and never `--remove-orphans`.

## Trust boundary (write scope)

What running this skill's commands may write, and nothing else:

| Path | Written by | When |
| --- | --- | --- |
| the repository: `.devcontainer/`, `docker/local/`, `.gitignore` (dck block) | `dck init` | creation, or reconciliation after consent |
| `docker/local/**/.env` (created 0600 from `.env.example`, never overwritten) | `dck setup`, `dck up` | when missing |
| `~/.config/dck/` (dedicated SSH key, dck known_hosts, profiles) | `dck setup`, `dck up`, `dck ssh` | first use |
| `~/.ssh/config.d/dck` (provenance-guarded) and one `Include config.d/dck` line at the top of `~/.ssh/config` | `dck herdr add/repair/remove` | only for Herdr machines |
| Herdr's saved machines | the `herdr` CLI, called by `dck herdr …` | only for Herdr machines |
| Docker objects of this repository's compose project (containers, images, per-project volumes, declared external networks) | `dck up/build/rebuild/down/setup` | on those verbs |
| `$TMPDIR/dck-<uid>/` (0700, compose overlay) | compose backend | on up/build |
| `~/.local/share/dck/` and one PATH block in `~/.bashrc`/`~/.zshrc` | `install.sh` | only when the user installs |

dck never edits Herdr's own files, never copies a private key into a
container, never writes outside the paths above, and never sends anything to
a network service other than the Docker registry, GitHub/PyPI/nodejs.org
downloads pinned in the image build, and the container's own sshd on
loopback.
