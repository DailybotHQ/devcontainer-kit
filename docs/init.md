# `dck init` — the Dev Container template

`dck init` writes a standard Dev Containers layout into a repository, or
reconciles an existing one. The result works three ways: with `dck up` from a
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
| `.devcontainer/dck.toml` | **yours** — the source of truth ([config.md](config.md)). Created once; afterwards only the values you pass as flags are edited, in place, comments kept |
| `.devcontainer/devcontainer.json` | dck owns six keys: `dockerComposeFile`, `service`, `runServices` (its first entry), `remoteUser`, `workspaceFolder`, `shutdownAction: "none"`. Every other key (customizations, features, forwardPorts, …) is yours |
| `docker/local/docker-compose.yaml` | dck owns the marked blocks `project`, `service`, `volumes`, `networks`; add backing services and anything else outside them |
| `docker/local/<service>/Dockerfile` | dck owns the `base` and `layers` blocks; add project layers below them |
| `docker/local/<service>/.env.example` | created once, then yours |
| `.gitignore` | dck owns the `gitignore` block: `docker/local/**/.env`, `docker/local/**/.env.*`, `!docker/local/**/.env.example`, `*.dck-bak-*` |

A managed block is delimited by marker comments:

```
# >>> dck:service >>>
  ...reconciled by dck init...
# <<< dck:service <<<
```

The rendered service:

- builds `FROM ${BASE_IMAGE}`, where compose passes
  `BASE_IMAGE: "ghcr.io/dailybothq/devcontainer-kit-base:<flavour>-<tag>@sha256:<digest>"`;
- mounts the repository at `workspace` and one **per-project** named volume,
  `state`, at `/home/<user>/.dck/volumes/state` (plus one per CLI with the
  agents layer, see [layers.md](layers.md));
- publishes `ssh_port` → 22 and every named port on `bind` (default
  `127.0.0.1`) only;
- reads `docker/local/<service>/.env` (optional; `dck setup` creates it 0600
  from the example) and passes `DCK_USER`, `DCK_WORKSPACE`, `DCK_SSH`,
  `DCK_EDITOR` and `DCK_AUTHORIZED_KEYS` to the image's entrypoint
  ([entrypoint.md](entrypoint.md));
- names its compose project (`name:`), so no tool ever falls back to the
  directory-name default; the host profile's `compose_project_prefix` and
  `network` apply here.

## Reconcile, never clobber

1. dck computes every file's new content and prints a plan: `create`,
   `unchanged`, `update` (managed parts changed), `replace` (the file has no
   usable dck markers or is not parseable — the whole file would change) or
   `append` (the `.gitignore` guard).
2. Every `update`/`replace` is shown as a unified diff.
3. Changing an existing file needs consent: `--yes`, or answering `y` at the
   per-file prompt on a terminal. Without consent **nothing** is written and
   `dck init` exits **5**. The `.gitignore` guard append is the one change
   made without consent: it modifies no existing line and keeps `.env`
   secrets out of git.
4. Each file changed is first copied to `<file>.dck-bak-<UTC timestamp>`
   (same mode), then replaced atomically.
5. A second run with nothing to change writes nothing and makes no backup.

Markers that are unbalanced, nested or duplicated are never edited in place:
the file is proposed as a whole-file `replace`.

## Flags

See `dck help init`. Values given as flags override `dck.toml` and are written
into it. On a repository without `dck.toml`, defaults are: flavour detected
(`package.json` → `node-24`; `pyproject.toml`, `requirements.txt`, `setup.py`,
`Pipfile` → `python-3.13`; otherwise `debian`), service `app`, an SSH port
derived from the repository name (22100–22999), and `herdr.machine = true` only
when `herdr` is on the host's `PATH`.

`--dry-run` prints the plan and diffs and writes nothing.

## Base image digest

`dck init` resolves the digest of the base image tag with
`docker buildx imagetools inspect` and pins it in the compose file. Offline,
without docker, or before the tag's images are published, the lookup fails:
dck warns that the image is pinned **by tag only**, keeps a digest pinned by an
earlier run if there is one, and `dck doctor` reports the pin. `--no-digest`
(or `DCK_NO_DIGEST=1`) skips the lookup.

## Safety

- `dck init` refuses `$HOME` and `/` as the repository.
- The rendered template never mounts the host's `~/.ssh`, the Docker socket
  or `~/.gitconfig`, adds no `cap_add` and no `privileged`; see
  [SECURITY.md](SECURITY.md).
- `dck init` validates with `docker compose config` and
  `devcontainer read-configuration` in the test suite (`template` scope).
