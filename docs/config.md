# Configuration — `dck.toml` and the host profile (interface 2)

dck reads two TOML files. Both are validated by `lib/config.py` (python3 3.11+
standard library, `tomllib`); the JSON Schemas in [`schema/`](schema/) describe
the same rules and are checked against the validator by the test suite.

| File | Scope | Schema |
| --- | --- | --- |
| `.devcontainer/dck.toml` | one repository, committed | [`dck-config-v2.json`](schema/dck-config-v2.json) |
| `~/.config/dck/profile.toml` | one host, never committed | [`dck-profile-v2.json`](schema/dck-profile-v2.json) |

Validate either by hand:

```bash
dck config                                   # effective config of the current repo
python3 -I lib/dckpy.py config validate .devcontainer/dck.toml
python3 -I lib/dckpy.py config validate --kind profile ~/.config/dck/profile.toml
```

Every problem is reported in one run, each line naming the file and key. An
invalid file exits **3**. Unknown keys are **warnings**, not errors, so a
config written for a newer dck within interface 2 still loads. A version-1 file (dck
v0.1.x) is read with warnings; `dck init` migrates it — the `interface` line becomes `2`
and `image_tag` (meaningful only with the shared base image) is removed, shown as a diff
like every other change.

## `.devcontainer/dck.toml`

```toml
interface = 2
service = "app"                # compose service the tools attach to
user = "dev"                   # remoteUser
workspace = "/app"             # workspaceFolder: every Herdr workspace and pane opens here
flavour = "node-24"            # python-3.13 | node-24 | debian (official image, digest-pinned)
# base_image = "node:22.20.0-trixie-slim@sha256:<64 hex>"   # optional override, digest required
ssh_agent = true               # share the host's SSH agent (git over SSH); keys never enter
ssh_host_config = true         # your git aliases from ~/.ssh/config inside, public keys only
ssh_port = 22040               # loopback-only host port for Herdr; 0 = no sshd
ports = { web = 4321 }         # named loopback ports
[layers]
agents = false                 # true → runs the coding-agents-kit installer
dailybot = false               # true only when the dailybot addon asks for it
editor = true                  # nvim + deepworkplan-vim as the default editor
[agents]
clis = []                      # kinds for `ak install` when layers.agents is true
[herdr]
machine = true                 # register as a Herdr machine on `dck up`
label = "{repo}"
layout = "standard"            # the sidebar dck up creates inside: standard | none
mesh = true                    # dck up runs `dck herdr mesh` (Docker Desktop only; docs/SECURITY.md)
[compose]
state_volume = "state"         # this service's state volume; one per repository in a shared project
# project = "acme-platform"    # the compose project name (default <prefix><repo-slug>)
# networks = ["acme-net"]      # existing external networks
# volumes = ["local_pgvector"] # other services' compose-managed volumes, exact names
# [build]
# context = "../.."            # build from the repository root
# dockerfile = "docker/local/vue/Dockerfile"   # a Dockerfile shared by several services
```

The user block (keys dck does not render, and `x-dck-merge` for keys it does), the
other services' volumes and networks, port strings and satellites:
[shared-stack.md](shared-stack.md).

| Key | Type | Default | Rule |
| --- | --- | --- | --- |
| `interface` | integer | **required** | `2`; `1` is read for migration only (warning; `dck init` rewrites it); another value is refused |
| `service` | string | **required** | compose service name, `^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$` |
| `user` | string | `dev` | `^[a-z_][a-z0-9_-]{0,31}$`; the base images create `dev` with uid 1000 |
| `workspace` | string | `/app` | absolute path of safe characters; the app path: the repository mount, and where every Herdr workspace and new pane opens (`new_cwd`) |
| `flavour` | string | **required** | `python-3.13`, `node-24` or `debian` |
| `base_image` | string | the flavour's pin in `versions.env` | an official image pinned by digest: `name[:tag]@sha256:<64 hex>`, no registry host |
| `image_tag` | string | — | interface 1 only; ignored since v0.2.0 (warning), removed by `dck init` |
| `ssh_host_config` | boolean | `true` | with `ssh_agent`: `dck up` and `dck rebuild` copy the concrete `Host` aliases of your `~/.ssh/config` (and its `Include` files) **for git hosting services** (GitHub, GitLab, Bitbucket, Azure DevOps, Codeberg, sourcehut) into the container — `HostName`, `Port`, `User`, the **public** half of each `IdentityFile` and the host keys you already trust. Only aliases whose key your agent holds are copied; on a terminal, dck offers to `ssh-add` a missing one (`--apple-use-keychain` on macOS). Skipped: wildcard patterns, `Match` blocks, `ProxyCommand`/`ProxyJump` hosts, loopback hosts, dck's own aliases. Inside, these aliases are included first, so they win over the container's own `~/.ssh/config` entries of the same name. Other hosts: `[ssh] host_extra` in your host profile |
| `ssh_agent` | boolean | `true` | mount the host's SSH agent socket (Docker Desktop's, or `$SSH_AUTH_SOCK` on Linux) as `SSH_AUTH_SOCK` for exec sessions (`dev.sh shell`, editor terminals). On a Linux host OpenSSH's agent serves only its own uid, so this works when your uid is 1000 (the container user's); otherwise use `dck ssh` / Herdr sessions, which forward the agent. `dck up` and `dck rebuild` choose the socket by Docker provider: Docker Desktop and OrbStack share the host agent; a native Linux engine mounts `$SSH_AUTH_SOCK`; colima, podman and others get none (exec sessions have no agent; `dck ssh` and Herdr sessions forward it). When an editor opens the container itself, set `DCK_HOST_SSH_AUTH_SOCK` in its environment on those hosts (a missing path fails the start rather than being created) or set `ssh_agent = false` |
| `ssh_port` | integer or string | `0` | `0` (no sshd) or 1024–65535; published on `bind` only. Also a string: the host port as a compose expression (`"${API_SSH_PORT:-22540}"`, rendered `"127.0.0.1:${API_SSH_PORT:-22540}:22"`); dck resolves it for `dck ssh`, Herdr and the doctor from the environment, then `docker/local/.env`, then the default |
| `bind` | string | `127.0.0.1` | IPv4 address every published port binds to. Changing it exposes the container's ports beyond this machine — see [SECURITY.md](SECURITY.md). `dck ssh` and Herdr still connect only to 127.0.0.1 and refuse a `bind` that is neither loopback nor `0.0.0.0` |
| `ports` | table | `{}` | `name = port` (integer or string); names `^[a-z][a-z0-9_-]{0,31}$`; ports unique and different from `ssh_port`. A value may also be a compose port string, `"HOST:CONTAINER"` with either side a number or `${VAR:-default}` (`"${DJANGO_RUNSERVER_HOST_PORT:-8000}:8000"`, `"5001:3000"`), rendered verbatim after `<bind>:` unless it names a host IP ([shared-stack.md](shared-stack.md#port-strings)) |
| `layers.agents` | boolean | `false` | see [layers.md](layers.md) |
| `layers.dailybot` | boolean | `false` | see [layers.md](layers.md) |
| `layers.editor` | boolean | `true` | see [layers.md](layers.md) |
| `agents.clis` | array | `[]` | kinds from `claude codex cursor opencode pi cline grok`, no duplicates; a warning when set while `layers.agents` is false. Also the CLIs whose host accounts `agents.host_profiles` (host profile) shares |
| `herdr.machine` | boolean | `false` | requires a non-zero `ssh_port` |
| `herdr.label` | string | `{repo}` | 1–64 chars; placeholders `{repo}` `{service}` `{project}` `{user}` |
| `herdr.layout` | string | `standard` | `standard` (App · Editor · Development · Agents, created by `dck up`) or `none` ([herdr.md](herdr.md)) |
| `compose.project` | string | unset | `^[a-z0-9][a-z0-9_-]{0,62}$`: the rendered compose project name (`name:`) instead of `<compose_project_prefix><repo-slug>`; it wins over `COMPOSE_PROJECT_NAME` in the environment or `docker/local/.env` (dck passes `-p`); only `dck --project` overrides it |
| `compose.networks` | array of strings | `[]` | existing external networks; with the host profile's `network` and the networks `x-dck-merge` names, declared once in the single top-level `networks:` (`external: true`) and joined by the service |
| `compose.volumes` | array of strings | `[]` | extra compose-managed volumes declared with their exact names (the data volumes of the file's other services: `<project>_<name>` keeps reattaching); or the `user:volumes` sub-block ([shared-stack.md](shared-stack.md#the-other-services-volumes-and-networks)) |
| `build.context` | string | unset (`./<service>`) | the build context, relative to the compose file's directory (`"../.."` = the repository root); the `dockerfile` and dck's `COPY` paths follow it |
| `build.dockerfile` | string | unset | a Dockerfile shared by several services, relative to the repository (`docker/local/vue/Dockerfile`); dck's blocks and its `dck/` directory go next to it |
| `agents.node_first` | boolean | `false` | put the agents' own Node (`/opt/dck/node`, installed when the image's `node` is older than the pinned major) first on PATH — `ENV PATH` in the Dockerfile and the login profile — for a repository whose own tooling needs that Node (Node 24). Off: the image's `node` stays first. Needs `layers.agents` |
| `agents.presets` | array | unset (both) | ak alias presets: subset of `classic` (`claudex`, `codexx`, …) and `providers` (`claude-glm`, …). Unset keeps both (the behaviour before v0.3.3); `[]` turns them off; new renders write `presets = []` |
| `compose.state_volume` | string | `state` | `^[a-z0-9][a-z0-9_.-]{0,62}$`, not an agents-layer volume name (`agentkit`, `claude`, `codex`, …). The named volume of this service's state — sshd host key, `~/.ssh` (`authorized_keys`, `known_hosts`, copied keys), gh auth, Herdr client state and config, shell history — mounted at `~/.dck/volumes/state` (only the compose volume's name changes). Compose prefixes it with the project name, so repositories that share one compose project (one `COMPOSE_PROJECT_NAME`) and keep the default would share **one** state volume: give each its own, e.g. `state-<service>` (`dck init --state-volume NAME`). The default keeps the volume existing installs already have; changing it starts the service with a fresh state volume (re-pinned host key, new gh login) and leaves the old one in place. `dck doctor` flags a shared project whose state volume is not per service |
| `herdr.mesh` | boolean | `true` | `dck up` runs `dck herdr mesh`: agents inside reach the other dck containers (and the host, with `host_machine`). Docker Desktop only; widens trust between containers ([SECURITY.md](SECURITY.md)) |

## Host profile

`~/.config/dck/profile.toml` is optional: when it is absent every default
applies. `--profile <name>` (or `DCK_PROFILE=<name>`) selects
`~/.config/dck/profiles/<name>.toml` instead, which must exist. The config
directory is `$DCK_CONFIG_HOME`, else `$XDG_CONFIG_HOME/dck`, else
`~/.config/dck`.

```toml
interface = 2
name = "acme"
compose_project_prefix = "acme-"   # compose project = <prefix><repo-slug>
network = "acme-dev"               # shared external network ("" = none)
alias_prefix = "acme-"             # SSH alias = <alias_prefix><repo-slug>
host_machine = false               # alias of [host] machine (profiles written before v0.2.3)
[labels]
machine = "{project} · {repo}"     # Herdr label when the repo sets none
[ssh]
identity = "~/.config/dck/ssh/id_ed25519"   # dedicated key dck authorizes in containers
host_extra = []                    # aliases or host names beyond git services to copy inside (opt-in)
authorized_extra = []              # extra PUBLIC key files authorized in every container (opt-in)
copy_keys = false                  # true → bind the whole ~/.ssh read-only and copy its id_* (private keys too) inside (opt-in)
[host]
machine = true                     # the host as a mesh peer (dck-host); see docs/herdr.md
listener = "dck"                   # dck | external | remote-login
port = 0                           # 0 = the listener's default (dck 22033, remote-login 22)
host_key = ""                      # the listener's public ed25519 host key ("" = its default)
label = "host"                     # the host's Herdr label inside containers
[mesh]
external = true                    # also push the host's other loopback Herdr machines
[agents]
host_profiles = false              # true → containers use the host's agent accounts (opt-in)
host_profile_names = []            # only these host profiles ("claude@work1"); [] = all of the repo's CLIs
host_env_keys = []                 # exact names copied besides the shared profiles' Claude tokens
default_profile = {}               # e.g. { claude = "@work3" }: a bare `ak claude` inside uses it
```

| Key | Type | Default | Rule |
| --- | --- | --- | --- |
| `interface` | integer | `2` | `2`; `1` is still read (the profile has the same shape in both) |
| `name` | string | `default` | `^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$` |
| `compose_project_prefix` | string | `""` | empty or `^[a-z0-9][a-z0-9_-]{0,31}$`; include your own separator |
| `network` | string | `""` | docker network name, empty for none |
| `alias_prefix` | string | `dck-` | `^[a-z0-9][a-z0-9._-]{0,31}$` |
| `host_machine` | boolean | `false` | alias of `host.machine`, kept for profiles written before v0.2.3; `host.machine` wins when both are set |
| `host.machine` | boolean | unset (→ `host_machine`) | the mesh pushes the host as `dck-host`, so agents inside reach agents on the host. `dck setup` offers it once on a terminal and records the answer here |
| `host.listener` | string | `dck` | `dck`: dck's own loopback listener (`dck host listener enable`, macOS); `external`: one you already run (set `port` and `host_key`; dck writes nothing on the host); `remote-login`: the system sshd on port 22 with your key in your own `authorized_keys` ([SECURITY.md](SECURITY.md)) |
| `host.port` | integer | `0` | `0` (the listener's default: `dck` 22033, `remote-login` 22) or 1024-65535; required for `external` |
| `host.host_key` | string | `""` | path of the listener's **public** ed25519 host key, pinned inside; empty = the listener's default; required for `external` |
| `host.label` | string | `host` | the host's Herdr machine label inside containers |
| `mesh.external` | boolean | `true` | the mesh also pushes the host's other Herdr machines on loopback ports 22000-22999 (for example containers another kit manages), with their enabled state and the ed25519 key your `known_hosts` already pins |
| `labels.machine` | string | `{repo}` | same placeholders as `herdr.label` |
| `ssh.identity` | string | `~/.config/dck/ssh/id_ed25519` | `~` expands to `$HOME` |
| `ssh.host_extra` | array of strings | `[]` | aliases or host names beyond the git hosting services whose `~/.ssh/config` blocks `ssh_host_config` also copies into containers. Host-side only — a repository's `dck.toml` cannot set it. Every container with the agent socket can then reach those hosts as you |
| `ssh.copy_keys` | boolean | `false` | `dck up` binds the host's **whole** `~/.ssh` read-only at `~/.ssh_host` — while it is on, every file there (not only `id_*`: `config`, `known_hosts`, other keys) is readable by processes in the container (a runtime compose overlay, never written into the repository; uses the compose backend) and every container start copies its `id_*` keys into the container's `~/.ssh` on the state volume: private keys 0600, `.pub` 0644, refreshed when they change on the host, removed when they are removed there. For tools that only offer key files, such as `gh auth login`. Never touches dck's `config`, `config.d/`, `authorized_keys` or `known_hosts.dck-host`. **Your private keys then rest in the volume, readable by code in the container** ([SECURITY.md](SECURITY.md#host-ssh-keys-ssh-copy_keys)). `dck setup` asks once and records the answer. Off: `copy_keys = false`, then `dck up --recreate` (the copies are removed at the next start); full wipe: `dck down` and remove the `<project>_state` volume. Host-side only — a repository's `dck.toml` cannot set it |
| `agents.host_profiles` | boolean | `false` | `dck up` shares the host's agent accounts with containers whose repository turns `layers.agents` on: each host ak profile (`$AGENTKIT_PROFILES_DIR/<cli>/<name>`, default root `~/.local/share/agentkit/profiles`) of the CLIs in that repository's `agents.clis` — claude, codex, pi, cline, grok, opencode; never cursor, whose profiles hold absolute host symlinks — the host's Codex home (`$CODEX_HOME` or `~/.codex`) when `codex@default` is shared, and an env file read-only. Read-write only where the CLI writes (each reason in SECURITY.md). Through a runtime compose overlay, never written into the repository; uses the compose backend. Host-side only — a repository's `dck.toml` cannot set it. See [layers.md](layers.md#host-accounts) and [SECURITY.md](SECURITY.md#host-accounts-agents-host_profiles) |
| `agents.default_profile` | table | `{}` | the account a bare `ak <cli>` uses inside: `{ claude = "@work3", codex = "@work2" }` (cli one of claude codex pi cline grok opencode), exported as `AGENTKIT_DEFAULT_PROFILE_<CLI>` (coding-agents-kit v0.5.2+) when that profile is shared by `host_profiles`; the answer to a macOS `@default` Claude login, which lives in the keychain and cannot reach a container. `dck doctor` shows the mapping and flags one it cannot apply. Host-side only |
| `agents.host_profile_names` | array of strings | `[]` | only these host profiles are shared and get their Claude token: `"<cli>@<name>"` (`cli` one of claude codex pi cline grok opencode; `@default` is the CLI's own home, for Codex `~/.codex`, for Claude the default token); at most 64. Empty: every profile of the repository's CLIs, and their own homes |
| `agents.host_env_keys` | array of strings | `[]` | exact variable names (`^[A-Z_][A-Z0-9_]*$`, no prefix or wildcard; at most 64) copied from the host's ak env file into the container's, besides the Claude token of each shared Claude profile. `[]` copies nothing else; with `host_profiles` off nothing is copied. Values never appear in compose files, logs or `dck doctor` |
| `ssh.authorized_extra` | array of strings | `[]` | public key files (paths ending in `.pub`, at most 16) added to the dck block of every container's `authorized_keys` at `dck up`, for clients that log in with your own keys (for example containers another kit manages). Host-side only; each listed key can open a shell in your containers |

## Precedence

- The repo file decides everything about the container; the profile decides
  host-side naming (project prefix, network, SSH alias, label format, key).
- `herdr.label` in the repo wins over `labels.machine` in the profile.
- Credentials are the host's decision: `agents.host_profiles`, `agents.host_env_keys`
  and `ssh.copy_keys` are read from the profile only; in a repository's `dck.toml` they are ignored with a
  warning. The repository still decides *which* CLIs exist (`agents.clis`), so only
  their accounts are shared.
- The repo **slug** is the directory name lower-cased with every character
  outside `[a-z0-9_-]` replaced by `-` (`My Repo` → `my-repo`).

## Output for scripts

`dckpy.py config show --repo DIR [--profile NAME] [--format env|json]` prints
the merged view. The `env` form is `DCK_<KEY>=<value>` lines (booleans `1`/`0`,
lists space-separated, port maps `name=port` pairs) meant to be read line by
line, never `eval`ed; validation guarantees single-line values.
