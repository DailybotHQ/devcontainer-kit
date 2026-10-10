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
workspace = "/workspace"       # workspaceFolder
flavour = "node-24"            # python-3.13 | node-24 | debian (official image, digest-pinned)
# base_image = "node:22.20.0-trixie-slim@sha256:<64 hex>"   # optional override, digest required
ssh_agent = true               # share the host's SSH agent (git over SSH); keys never enter
ssh_host_config = true         # your ~/.ssh/config aliases inside, public keys only
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
```

| Key | Type | Default | Rule |
| --- | --- | --- | --- |
| `interface` | integer | **required** | `2`; `1` is read for migration only (warning; `dck init` rewrites it); another value is refused |
| `service` | string | **required** | compose service name, `^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$` |
| `user` | string | `dev` | `^[a-z_][a-z0-9_-]{0,31}$`; the base images create `dev` with uid 1000 |
| `workspace` | string | `/workspace` | absolute path of safe characters |
| `flavour` | string | **required** | `python-3.13`, `node-24` or `debian` |
| `base_image` | string | the flavour's pin in `versions.env` | an official image pinned by digest: `name[:tag]@sha256:<64 hex>`, no registry host |
| `image_tag` | string | — | interface 1 only; ignored since v0.2.0 (warning), removed by `dck init` |
| `ssh_host_config` | boolean | `true` | with `ssh_agent`: `dck up` and `dck rebuild` copy the concrete `Host` aliases of your `~/.ssh/config` (and its `Include` files) into the container — `HostName`, `Port`, `User`, the **public** half of each `IdentityFile` and the host keys you already trust — and load any missing private key into your agent (`ssh-add`, `--apple-use-keychain` on macOS). Skipped: wildcard patterns, `Match` blocks, `ProxyCommand`/`ProxyJump` hosts, loopback hosts, dck's own aliases |
| `ssh_agent` | boolean | `true` | mount the host's SSH agent socket (Docker Desktop's, or `$SSH_AUTH_SOCK` on Linux) as `SSH_AUTH_SOCK` for exec sessions (`dev.sh shell`, editor terminals). On a Linux host OpenSSH's agent serves only its own uid, so this works when your uid is 1000 (the container user's); otherwise use `dck ssh` / Herdr sessions, which forward the agent. `dck up` and `dck rebuild` choose the socket by Docker provider: Docker Desktop and OrbStack share the host agent; a native Linux engine mounts `$SSH_AUTH_SOCK`; colima, podman and others get none (exec sessions have no agent; `dck ssh` and Herdr sessions forward it). When an editor opens the container itself, set `DCK_HOST_SSH_AUTH_SOCK` in its environment on those hosts (a missing path fails the start rather than being created) or set `ssh_agent = false` |
| `ssh_port` | integer | `0` | `0` (no sshd) or 1024–65535; published on `bind` only |
| `bind` | string | `127.0.0.1` | IPv4 address every published port binds to. Changing it exposes the container's ports beyond this machine — see [SECURITY.md](SECURITY.md). `dck ssh` and Herdr still connect only to 127.0.0.1 and refuse a `bind` that is neither loopback nor `0.0.0.0` |
| `ports` | table | `{}` | `name = port`; names `^[a-z][a-z0-9_-]{0,31}$`; ports unique and different from `ssh_port` |
| `layers.agents` | boolean | `false` | see [layers.md](layers.md) |
| `layers.dailybot` | boolean | `false` | see [layers.md](layers.md) |
| `layers.editor` | boolean | `true` | see [layers.md](layers.md) |
| `agents.clis` | array | `[]` | kinds from `claude codex cursor opencode pi cline grok`, no duplicates; a warning when set while `layers.agents` is false |
| `herdr.machine` | boolean | `false` | requires a non-zero `ssh_port` |
| `herdr.label` | string | `{repo}` | 1–64 chars; placeholders `{repo}` `{service}` `{project}` `{user}` |
| `herdr.layout` | string | `standard` | `standard` (Home · Editor · Development · Agents, created by `dck up`) or `none` ([herdr.md](herdr.md)) |
| `herdr.mesh` | boolean | `true` | `dck up` runs `dck herdr mesh`: agents inside reach the other dck containers (and the host, with `host_machine`). Docker Desktop only; widens trust between containers ([SECURITY.md](SECURITY.md)) |

## Host profile

`~/.config/dck/profile.toml` is optional: when it is absent every default
applies. `--profile <name>` (or `DCK_PROFILE=<name>`) selects
`~/.config/dck/profiles/<name>.toml` instead, which must exist. The config
directory is `$DCK_CONFIG_HOME`, else `$XDG_CONFIG_HOME/dck`, else
`~/.config/dck`.

```toml
interface = 1
name = "acme"
compose_project_prefix = "acme-"   # compose project = <prefix><repo-slug>
network = "acme-dev"               # shared external network ("" = none)
alias_prefix = "acme-"             # SSH alias = <alias_prefix><repo-slug>
host_machine = false               # the host as a mesh peer (dck-host); see docs/herdr.md
[labels]
machine = "{project} · {repo}"     # Herdr label when the repo sets none
[ssh]
identity = "~/.config/dck/ssh/id_ed25519"   # dedicated key dck authorizes in containers
```

| Key | Type | Default | Rule |
| --- | --- | --- | --- |
| `interface` | integer | `1` | must be `1` |
| `name` | string | `default` | `^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$` |
| `compose_project_prefix` | string | `""` | empty or `^[a-z0-9][a-z0-9_-]{0,31}$`; include your own separator |
| `network` | string | `""` | docker network name, empty for none |
| `alias_prefix` | string | `dck-` | `^[a-z0-9][a-z0-9._-]{0,31}$` |
| `host_machine` | boolean | `false` | the mesh also pushes the host as `dck-host` (your user, port 22): agents inside can reach it when Remote Login is on and your key is in your `authorized_keys`. dck configures nothing on the host itself ([SECURITY.md](SECURITY.md)) |
| `labels.machine` | string | `{repo}` | same placeholders as `herdr.label` |
| `ssh.identity` | string | `~/.config/dck/ssh/id_ed25519` | `~` expands to `$HOME` |

## Precedence

- The repo file decides everything about the container; the profile decides
  host-side naming (project prefix, network, SSH alias, label format, key).
- `herdr.label` in the repo wins over `labels.machine` in the profile.
- The repo **slug** is the directory name lower-cased with every character
  outside `[a-z0-9_-]` replaced by `-` (`My Repo` → `my-repo`).

## Output for scripts

`dckpy.py config show --repo DIR [--profile NAME] [--format env|json]` prints
the merged view. The `env` form is `DCK_<KEY>=<value>` lines (booleans `1`/`0`,
lists space-separated, port maps `name=port` pairs) meant to be read line by
line, never `eval`ed; validation guarantees single-line values.
