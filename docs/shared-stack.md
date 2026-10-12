# Several repositories, one compose project

dck renders one service per repository. Some products run as one compose project
spread over several repositories — an API, a web app, workers and a database that
share one `COMPOSE_PROJECT_NAME`, one network and some volumes. This page covers the
`dck.toml` keys and the compose conventions (since v0.3.3) that make that work without
hand-editing what dck renders.

Everything here is additive: a repository that sets none of these keys renders exactly
as before.

## When this applies

- Several repositories each run `dck init` and render their own service, but the
  services must live in **one** compose project (they reach each other by service
  name, share named volumes, or one `docker compose ps` shows the whole product).
- The stack already exists as hand-written compose files (often run as root, with
  YAML anchors for workers) and you are moving it to dck.

A single repository with a single service needs none of this.

## Naming the project: `[compose] project`

```toml
[compose]
project = "acme-platform"     # the rendered top-level `name:`
```

By default `dck init` writes `name: <compose_project_prefix><repo-slug>`, which gives
every repository its own project. Set `project` to the same value in every repository
of the stack so they render the same `name:`. The launcher resolves the project as
before — `COMPOSE_PROJECT_NAME` in the environment, then in `docker/local/.env`, then
the compose file's `name:` ([launcher.md](launcher.md)) — so an existing
`COMPOSE_PROJECT_NAME` still wins.

## One state volume per service: `[compose] state_volume`

Each dck service keeps its state in a named volume (v0.3.2): the sshd host key,
`~/.ssh` (`authorized_keys`, `known_hosts`, copied keys), gh auth, Herdr client state
and config, and shell history. Compose prefixes volume names with the project name, so
repositories that share one project and keep the default `state` would share **one**
state volume — one host key for several machines, one `known_hosts`, one gh login.

```toml
[compose]
project = "acme-platform"
state_volume = "state-api"    # one per service: state-web, state-worker, ...
```

- `dck init --state-volume NAME` writes the key.
- `dck doctor` flags a shared project whose state volume is not per service
  ([doctor.md](doctor.md), `compose.shared_with`).
- Changing it starts the service with a **fresh** state volume (a re-pinned host key,
  a new gh login) and leaves the old volume in place; remove it by hand when you no
  longer need it.

## External networks: `[compose] networks`

```toml
[compose]
networks = ["acme-net"]       # networks that already exist; dck never creates them
```

Three sources can name an external network:

| Source | Where |
| --- | --- |
| `[compose] networks` | the repository's `dck.toml` |
| `network` | your host profile ([config.md](config.md#host-profile)) |
| `x-dck-merge.networks` | the user block (below) |

All of them end up in **one** top-level `networks:` mapping, each declared once with
`external: true`. dck never writes two `networks:` keys. Create the network once on
the host (`docker network create acme-net`) before the first `dck up`.

## Port strings

`ssh_port` and each `[ports]` entry accept an integer (as before) or a string holding a
compose port expression:

```toml
ssh_port = "${API_SSH_PORT:-22540}"            # host port only; the container port is 22

[ports]
web    = 4321                                  # integer: same port on both sides
django = "${DJANGO_RUNSERVER_HOST_PORT:-8000}:8000"
node   = "5001:3000"
public = "0.0.0.0:9000:9000"
```

| Entry | Rendered |
| --- | --- |
| `ssh_port = "${API_SSH_PORT:-22540}"` | `"127.0.0.1:${API_SSH_PORT:-22540}:22"` |
| `web = 4321` | `"127.0.0.1:4321:4321"` |
| `django = "${DJANGO_RUNSERVER_HOST_PORT:-8000}:8000"` | `"127.0.0.1:${DJANGO_RUNSERVER_HOST_PORT:-8000}:8000"` |
| `node = "5001:3000"` | `"127.0.0.1:5001:3000"` |
| `public = "0.0.0.0:9000:9000"` | `"0.0.0.0:9000:9000"` (verbatim) |

A string is rendered verbatim and prefixed with `<bind>:` (`127.0.0.1` by default)
unless it already starts with a host IP (`1.2.3.4:` or `[...]:`). Naming a host IP
other than loopback exposes that port beyond this machine — the same decision as a
non-loopback `bind` ([SECURITY.md](SECURITY.md#network-exposure-loopback-only)).

Compose substitutes `${VAR:-default}` itself. For the host port `dck ssh`, Herdr and
`dck doctor` connect to, the launcher resolves the expression the same way: the
variable from the environment, then from the compose directory's `.env`
(`docker/local/.env`), then the default.

## Build context: `[build] context`

```toml
[build]
context = "../.."     # relative to the compose file's directory (docker/local/)
```

The default context is `./<service>` (`docker/local/<service>/`). With
`context = "../.."` the context is the repository root, and the `dockerfile` path is
computed relative to it, so the project layer of the Dockerfile can
`COPY requirements/ ...` from the root.

## The user block

Most stacks need compose keys dck does not render (`depends_on`, `healthcheck`, a
`command`) or extra entries in keys it does (`env_file`, `environment`, `volumes`,
`networks`). They go in a **user block** inside the dck service mapping of
`docker/local/docker-compose.yaml`, which dck never rewrites:

```yaml
services:
  # >>> dck:service >>>
  api:
    build: ...
    # ... dck-rendered keys ...
    # >>> user:api >>>
    depends_on:                       # dck does not render it: a plain key
      - postgres
    healthcheck:
      test: ["CMD", "true"]
    x-dck-merge:                      # dck renders these: merged into its keys
      env_file:
        - path: ./django/.env
          required: false
        - ./postgres/.env
      environment:
        DOCKER_DEV_ENV: "1"
      volumes:
        - logins:/home/dev/.logins
        - ../../..:/workspaces:ro      # sibling checkouts, read-only
        - sqlite_volume:/app/src/databases
      networks:
        - acme-net
      extra_hosts:
        - "metadata.local:127.0.0.1"
      command: ["python", "manage.py", "runserver", "0.0.0.0:8000"]
    # <<< user:api <<<
  # <<< dck:service <<<
```

**Placement.** The markers are `# >>> user:<service> >>>` and
`# <<< user:<service> <<<`, at service-key indentation (four spaces), inside the
service mapping, right before `# <<< dck:service <<<`. You add the block; `dck init`
never inserts one, so a file without it renders exactly as before.

**Plain keys or `x-dck-merge`.**

| Key | Goes | Effect |
| --- | --- | --- |
| a key dck does not render (`depends_on`, `healthcheck`, `stop_grace_period`, ...) | plain, directly in the block | compose reads it as is |
| a key dck renders (`env_file`, `environment`, `volumes`, `networks`, `command`, ...) | under `x-dck-merge:` | merged into dck's value at `dck init` |

A plain key that dck also renders is an error, with the fix "move it under
x-dck-merge".

**Merge rules** for `x-dck-merge`:

| Value | Rule | Examples |
| --- | --- | --- |
| list | your items are appended after dck's | `volumes`, `env_file`, `ports`, `networks`, `extra_hosts`, `depends_on`, `cap_add` |
| map | merged; your entry wins on the same key | `environment`, `labels` |
| scalar | yours replaces dck's; `dck doctor` reports the override | `command`, `working_dir`, `init`, `user` |

Named volumes in `x-dck-merge.volumes` that are not dck's own (`logins`,
`sqlite_volume` above) are declared once in the single top-level `volumes:`
(compose-managed, `{}`). Networks named there join the single top-level `networks:`
(`external: true`).

**After editing the block, run `dck init`.** The merge happens at render time;
`dck doctor` and `dck up` warn when the rendered file does not reflect the block.

**Markers are all-or-nothing.** A compose file with some dck markers but not all, or a
user block without its end marker, is an error naming the missing marker and the fix.
dck never appends a block at the end of the file.

## Satellites: `extends` instead of anchors

Workers and other services built from the same image are user-owned services outside
the dck markers. Hand-written stacks often defined them with a YAML anchor
(`<<: *api`). An anchor copies **everything**, including dck's published ports and the
sshd wiring, so two containers fought over one host port. Use `extends` with
`!reset`:

```yaml
services:
  # >>> dck:service >>>
  api:
    ...
  # <<< dck:service <<<
  api-worker:
    extends: api
    command: ["celery", "worker"]
    ports: !reset []
    depends_on: !reset []
```

Place satellites after `# <<< dck:service <<<`, still inside `services:`. `extends`
with `!reset` needs **Docker Compose 2.24** or newer; `dck doctor` checks the version
and names the minimum.

## Moving a root-run stack to the `dev` user

dck containers run as `dev` (uid 1000). Named volumes created by an older container
that ran as root keep root ownership, so the new container cannot write to them. Fix
each affected path once, from `docker/local/`:

```bash
docker compose run --rm --user root api chown -R 1000:1000 /app/src/databases
dck up --recreate
```

Repeat the `chown` for every volume path the old container wrote to (one per
service and path).

## Alias presets: `[agents] presets`

```toml
[agents]
clis = ["claude", "codex"]
presets = []          # subset of ["classic", "providers"]
```

`presets` selects the coding-agents-kit (`ak`) alias presets. With the key **absent**,
both `classic` and `providers` apply, as before; new renders write `presets = []`
(no presets). See [layers.md](layers.md).

## Security notes

The user block is the repository's own compose content. dck merges it into the
rendered file, and `dck up`'s preflight reviews the result like any other repository
compose content ([SECURITY.md](SECURITY.md)):

- **Host-reaching keys need `--trust`.** Bind mounts of host paths outside the
  repository (the `../../..:/workspaces:ro` mount above is one), `privileged`,
  `cap_add`, host namespaces, devices or the Docker socket make `up`, `start`, `build`
  and `rebuild` refuse (exit 5) until you pass `--trust` (or `DCK_TRUST=1`) after
  reading what they list.
- **Prefer read-only mounts** for shared sources (`:ro`): the container then reads
  sibling checkouts without being able to change them.
- **`env_file` contents reach the container and its SSH sessions.** Every variable
  compose passes in is written to the dev user's `~/.dck/env.sh` (0600) so `ssh` and
  Herdr sessions see it ([entrypoint.md](entrypoint.md#dck_env_profile)). List only
  files whose secrets that container should hold.
- **Extra networks widen reachability.** Every container on a shared network can
  reach the others' ports, including sshd on port 22 (public-key login for `dev`
  only).
- **Ports with a host IP** (`"0.0.0.0:9000:9000"`) are published beyond loopback; keep
  the default prefix unless the port must be reachable from other machines.
