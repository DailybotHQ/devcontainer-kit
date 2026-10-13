# `dck init` — the Dev Container template

`dck init` writes a standard Dev Containers layout into a repository (the git
top-level of the current directory, or `--repo DIR`), or reconciles an existing one. The result works three ways: with `dck up` from a
terminal, with VS Code / Cursor "Reopen in Container", and with the
`devcontainer` CLI.

```bash
cd my-repo
dck init --port web=4321          # writes the layout, prints the plan
dck setup && dck up && dck shell  # see launcher.md
```

## What it renders

| File | Ownership |
| --- | --- |
| `.devcontainer/dck.toml` | **yours** — the source of truth ([config.md](config.md)). Created once; afterwards only the values you pass as flags are edited, in place, comments kept (and an interface-1 file is migrated: `interface = 2`, `image_tag` removed) |
| `.devcontainer/devcontainer.json` | dck owns six keys: `dockerComposeFile`, `service`, `runServices` (its first entry), `remoteUser`, `workspaceFolder`, `shutdownAction: "none"`, and removes the keys that select another container source (`image`, `build`, `dockerFile`, `context`). Every other key (customizations, features, forwardPorts, …) is yours |
| `docker/local/docker-compose.yaml` | dck owns the marked blocks `project`, `service`, `volumes`, `networks`; add backing services and anything else outside them. Inside the service, the `user:<service>` block is yours and kept verbatim, as are the top-level `user:volumes` / `user:networks` sub-blocks ([shared-stack.md](shared-stack.md)) |
| `docker/local/<service>/Dockerfile` (or `[build] dockerfile`) | dck owns the `base` and `layers` blocks; add project layers below them |
| `docker/local/<service>/.env.example` | created once, then yours |
| `docker/local/.env.example` | with the agents layer: created once, then yours; explains the repository's CLI mode and each developer's options (`DCK_AGENT_CLIS`, `INSTALL_<CLI>_CLI`, [config.md](config.md#each-developers-coding-agent-clis)) |
| `docker/local/<service>/dck/` | dck owns it: the build scripts the Dockerfile copies (`versions.env`, `install.sh`, `peers.sh`, `editor.sh`, `herdr-layout.sh`, the entrypoint and the `layers/` installers, …), vendored as byte copies of the kit's files, and `VERSION` (the kit they came from) |
| `dev.sh` | created when missing (executable); dck owns its `devsh` block. A repository's own `dev.sh` without dck markers is never touched; `dev_sh = false` (`--no-dev-sh`) and dck neither creates nor touches it |
| `.gitignore` | dck owns the `gitignore` block: `docker/local/**/.env`, `docker/local/**/.env.*`, `!docker/local/**/.env.example`, `*.dck-bak-*` |

A managed block is delimited by marker comments:

```
# >>> dck:service >>>
  ...reconciled by dck init...
# <<< dck:service <<<
```

The rendered service:

- builds from its own Dockerfile, which starts `FROM ${BASE_IMAGE}`: the
  flavour's official image (`node`, `python` or `debian`) pinned by digest in
  `dck/versions.env`, or `base_image` from `dck.toml`. No shared base image is
  involved ([images.md](images.md));
- with the agents layer, passes the build args `DCK_AGENT_CLIS:
  "${DCK_AGENT_CLIS:-<clis>}"` and one `INSTALL_<CLI>_CLI` per wired CLI, so plain
  compose reads `docker/local/.env` too;
- mounts the repository at `workspace` and the service's state volume
  (`[compose] state_volume`, default `state`; compose prefixes it with the project)
  at `/home/<user>/.dck/volumes/state`, plus `agentkit` and one per wired CLI with the
  agents layer ([layers.md](layers.md)), and, with `ssh_agent`, the host's SSH agent
  socket (`${DCK_HOST_SSH_AUTH_SOCK:-/run/host-services/ssh-auth.sock}`, never created
  when missing);
- publishes `ssh_port` → 22 and every named port on `bind` (default
  `127.0.0.1`) only;
- reads `docker/local/<service>/.env` (optional; `dck setup` creates it 0600
  from the example) and passes `DCK_USER`, `DCK_WORKSPACE`, `DCK_SSH`,
  `DCK_EDITOR` and `DCK_AUTHORIZED_KEYS` (plus `SSH_AUTH_SOCK`, `DCK_AGENTS`,
  `AGENTKIT_PROFILES_DIR` and `DCK_DAILYBOT` when their option is on) to the image's
  entrypoint ([entrypoint.md](entrypoint.md)); `host.docker.internal` resolves to
  the host;
- names its compose project (`name:`: `[compose] project`, else
  `<compose_project_prefix><repo-slug>`), so no tool ever falls back to the
  directory-name default; the host profile's `network` and `[compose] networks`
  are joined as external networks.

## Reconcile, never clobber

1. dck computes every file's new content and prints a plan: `create`,
   `unchanged`, `update` (managed parts changed), `replace` (the file has no
   usable dck markers or is not parseable — the whole file would change) or
   `append` (the `.gitignore` guard).
2. Every `update`/`replace` is shown as a unified diff.
3. Changing an existing file needs consent: `--yes`, or answering `y` at the
   per-file prompt on a terminal. Without consent **nothing** is written and
   `dck init` exits **5**; a file declined at the prompt is kept (the others are
   written) and the exit is still 5. The `.gitignore` guard append is the one change
   made without consent: it modifies no existing line and keeps `.env`
   secrets out of git.
4. Each file changed is first copied to `<file>.dck-bak-<UTC timestamp>`
   (same mode), then replaced atomically.
5. A second run with nothing to change writes nothing and makes no backup.

Markers are all-or-nothing: a compose file or Dockerfile whose dck markers are
unbalanced, duplicated or crossed, or that has some of dck's blocks but not all, is
refused (exit 5) with the fix, never edited in place. A file without any dck marker
is proposed as a whole-file `replace`.

## Flags

See `dck help init`: `--flavour`, `--service`, `--user`, `--workspace`,
`--ssh-port`, `--state-volume`, `--port NAME=N` (repeatable; a port string goes in
`dck.toml`), `--agents`/`--no-agents`, `--clis "claude codex"`,
`--supported all|"claude codex"`, `--editor`/`--no-editor`, `--herdr`/`--no-herdr`,
`--dev-sh`/`--no-dev-sh`, `--dry-run`, `--yes`/`-y`, `--repo DIR`. Values given as
flags override `dck.toml` and are written into it. On a repository without
`dck.toml`, defaults are: flavour detected (`package.json` → `node-24`;
`pyproject.toml`, `requirements.txt`, `setup.py`, `Pipfile` → `python-3.13`;
otherwise `debian`), service `app`, user `dev`, workspace `/app`, an SSH port
derived from the repository name (22100–22999), `[agents] presets = []`, and
`herdr.machine = true` only when sshd is on and `herdr` is on the host's `PATH`. On
a terminal, a new `dck.toml` with the agents layer and no `--supported` asks once
whether to use the advanced CLI mode ([config.md](config.md#each-developers-coding-agent-clis)).

`--dry-run` prints the plan and diffs and writes nothing.

## Base image

There is no registry lookup: the Dockerfile's `ARG BASE_IMAGE` is the flavour's
official image as pinned, tag and digest, in the kit's `images/versions.env`
(vendored as `dck/versions.env`), or `base_image` from `dck.toml`, which must carry
a digest too. Upgrading dck and re-running `dck init` moves the pin; `dck doctor`
flags a Dockerfile whose base image is not digest-pinned. `--no-digest` is still
accepted, for compatibility, and does nothing.

## Safety

- `dck init` refuses `$HOME` and `/` as the repository, symlinked target files,
  and any target that resolves outside the repository (exit 5).
- The rendered template never mounts the host's `~/.ssh`, the Docker socket
  or `~/.gitconfig`, adds no `cap_add` and no `privileged`; see
  [SECURITY.md](SECURITY.md).
- `dck init` validates with `docker compose config` and
  `devcontainer read-configuration` in the test suite (`template` scope).
