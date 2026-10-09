# `dck` — the launcher

`dck` (long name `devcontainer-kit`) starts, enters and manages a repository's
dev container from a plain terminal. It replaces the hand-copied `dev.sh`
launchers: one tool, no repository known by name, everything read from the
repository it runs in.

```
dck [--repo DIR] [--profile NAME] [--project NAME] <verb> [args]
```

`dck` finds the repository by walking up from the current directory to the
first `.devcontainer/` holding `devcontainer.json` (or `dck.toml`); `--repo`
names it explicitly. Requires bash 3.2+ (the macOS system bash works),
python3 ≥ 3.11 and, for the container verbs, Docker with Compose v2.

## Verbs

| Verb | What it does |
| --- | --- |
| `init [flags]` | render or reconcile the template ([init.md](init.md)) |
| `setup` | create each `docker/local/**/.env` from its `.env.example` at **0600** (an existing readable one is narrowed to 0600, loudly), create missing external networks, create the dedicated dck SSH key |
| `up [--recreate] [svc…]` | start `runServices`, detached. A second `up` leaves running containers alone; `--recreate` applies compose changes. Registers the Herdr machine afterwards when `dck.toml` says so ([herdr.md](herdr.md)) |
| `down [svc…]` | stop and remove this repository's services — never `compose down`; named volumes and the project network are kept (the next `up` reuses them). To retire a repository completely: `docker volume rm <project>_state …` and `docker network rm <project>_default` |
| `stop` / `start` / `restart` `[svc…]` | as compose; `stop` skips the environment checks so a stack can always be stopped |
| `ps [svc…]` | the repository's containers |
| `logs [--no-follow] [svc…]` | the last 200 lines, following by default |
| `shell [svc] [-c CMD]` | a **login** shell as `remoteUser` in `workspaceFolder` (or one command) — login, so `/etc/profile.d` gives the same PATH and environment as an SSH/Herdr session |
| `exec <svc> <cmd…>` | run a command; everything after the service is passed verbatim |
| `build [--no-cache] [svc…]` | build images (`--no-cache` also pulls) |
| `rebuild [--no-cache] [svc…]` | build, then recreate — the terminal "Rebuild Container"; volumes are kept |
| `config` | what dck resolved: files, project and where its name came from, backend, user, workspace, overlay, ssh, Herdr |
| `ports` | the published loopback ports and whether the service runs |
| `ssh [cmd…]` | SSH into the container with **agent forwarding** (see below) |
| `doctor [--json]` | environment and repository health, interface 1 ([doctor.md](doctor.md)) |
| `herdr add\|status\|repair\|remove` | the container as a Herdr machine ([herdr.md](herdr.md)) |
| `--skill`, `--version`, `help` | the bundled agent skill, the version, usage |

## Rules it follows

- **`devcontainer.json` is the source of truth.** `runServices` decides what
  starts (falling back to `service` alone, never "every service in the
  compose file"); `remoteUser`/`workspaceFolder` apply to the main service
  only — a backing service is entered as its own default user.
- **Two backends.** When the `devcontainer` CLI (`@devcontainers/cli`) is
  installed, `up`, `rebuild`, and `shell`/`exec` on the main service use
  `devcontainer up/exec`, so features and the plugin's own settings apply.
  Otherwise dck drives `docker compose` and reproduces `devcontainer.json`'s
  `mounts` and `containerEnv` in a private overlay
  (`$TMPDIR/dck-<uid>/<project>-overlay.yml`, 0600, in a 0700 directory dck
  must own — a planted or symlinked directory is refused). `DCK_BACKEND=compose|devcontainer`
  forces one; `--project` always uses compose.
- **Never `--remove-orphans`.** A compose project may be shared or declare
  on-demand services; the flag would delete containers someone else uses.
- **Never the directory-name default project.** The project name comes from
  `--project`, `COMPOSE_PROJECT_NAME` (environment, then
  `docker/local/.env`) or the compose file's top-level `name:` (which
  `dck init` writes). Otherwise dck refuses (exit 5): compose would otherwise
  build a second, parallel stack next to the editor's.
- **The repository's container configuration is reviewed before it runs.**
  `up`, `start`, `build` and `rebuild` refuse (exit 5) a configuration that
  reaches the host — `initializeCommand`, `privileged`, `cap_add`, host
  namespaces, devices, the Docker socket, bind mounts or compose files outside
  the repository — and list what they found. Re-run with `--trust` (or
  `DCK_TRUST=1`) after reading it. dck-rendered setups never trigger it.
- **Your agent only goes to loopback.** `dck ssh` (and Herdr) connect to
  `127.0.0.1` whatever `bind` says, and refuse a `bind` that is not loopback or
  `0.0.0.0`.
- **Secrets stay put.** `.env` files are created 0600 and their values are
  never printed; `doctor` reports variable *names* only.

## SSH: agent forwarding, never key copies

`dck setup` (or the first `dck up`) creates a **dedicated** key,
`~/.config/dck/ssh/id_ed25519` (0600 in a 0700 directory). Only its public
half goes to containers (through `DCK_AUTHORIZED_KEYS`, read by the
entrypoint). `dck ssh` connects to `127.0.0.1:<ssh_port>` with:

- `-i <dck key> -o IdentitiesOnly=yes` — no other key is offered;
- `-o ForwardAgent=yes` — your own keys stay on the host; git inside the
  session uses them through the agent;
- `-o StrictHostKeyChecking=accept-new` — a new container is trusted on first
  use, a *changed* host key is refused (the key survives rebuilds on the
  `state` volume);
- `-o UserKnownHostsFile=~/.config/dck/ssh/known_hosts` — your
  `~/.ssh/known_hosts` does not grow a line per container.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | success |
| 1 | an operation failed (a docker/compose command, a stopped container) |
| 2 | usage error (unknown verb/flag, missing argument) |
| 3 | configuration error (no/invalid `devcontainer.json`, `dck.toml`, profile) |
| 4 | environment missing (docker, python3 ≥ 3.11, ssh) |
| 5 | refused by a safety rule (directory-default project, clobbering, foreign overlay directory, `$HOME` as a repository) |

## Environment

| Variable | Effect |
| --- | --- |
| `DCK_BACKEND` | `auto` (default), `compose`, `devcontainer` |
| `DCK_PROFILE` | host profile name (same as `--profile`) |
| `DCK_CONFIG_HOME` | config directory (default `$XDG_CONFIG_HOME/dck` or `~/.config/dck`) |
| `DCK_PYTHON` | the python3 ≥ 3.11 to use |
| `DCK_NO_DIGEST=1` | `dck init` skips the digest lookup |
| `DCK_NONINTERACTIVE=1` | never prompt (as if stdin were not a terminal) |
| `COMPOSE_PROJECT_NAME` | project name (see above) |
| `DCK_TRUST=1` | same as `--trust` (start a configuration that reaches the host) |
| `DCK_SSH_CONFIG` | `dck ssh` passes `-F <file>` (e.g. `/dev/null` to ignore `~/.ssh/config`) |

## Install

```bash
git clone --branch v0.1.5 https://github.com/DailybotHQ/devcontainer-kit
./devcontainer-kit/install.sh            # or --no-rc for scripted installs
```

`install.sh` copies the kit to `~/.local/share/dck` (`DCK_INSTALL_DIR`
overrides), replacing a previous install atomically, and adds one guarded
block to `~/.bashrc` / `~/.zshrc` that puts its `bin/` on `PATH`. Running it
again is safe; `--uninstall` removes the install and the block (your
`~/.config/dck` is kept). It refuses to replace a directory that is not a dck
install.
