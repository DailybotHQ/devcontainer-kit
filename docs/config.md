# Configuration — `dck.toml` and the host profile (interface 1)

dck reads two TOML files. Both are validated by `lib/config.py` (python3 3.11+
standard library, `tomllib`); the JSON Schemas in [`schema/`](schema/) describe
the same rules and are checked against the validator by the test suite.

| File | Scope | Schema |
| --- | --- | --- |
| `.devcontainer/dck.toml` | one repository, committed | [`dck-config-v1.json`](schema/dck-config-v1.json) |
| `~/.config/dck/profile.toml` | one host, never committed | [`dck-profile-v1.json`](schema/dck-profile-v1.json) |

Validate either by hand:

```bash
dck config                                   # effective config of the current repo
python3 -I lib/dckpy.py config validate .devcontainer/dck.toml
python3 -I lib/dckpy.py config validate --kind profile ~/.config/dck/profile.toml
```

Every problem is reported in one run, each line naming the file and key. An
invalid file exits **3**. Unknown keys are **warnings**, not errors, so a
config written for a newer dck within interface 1 still loads.

## `.devcontainer/dck.toml`

```toml
interface = 1
service = "app"                # compose service the tools attach to
user = "dev"                   # remoteUser
workspace = "/workspace"       # workspaceFolder
flavour = "node-24"            # python-3.13 | node-24 | debian
image_tag = "v0.1.6"           # devcontainer-kit-base tag (digest pinned in compose)
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
```

| Key | Type | Default | Rule |
| --- | --- | --- | --- |
| `interface` | integer | **required** | must be `1`; another value is refused (`interface N is not supported`) |
| `service` | string | **required** | compose service name, `^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$` |
| `user` | string | `dev` | `^[a-z_][a-z0-9_-]{0,31}$`; the base images create `dev` with uid 1000 |
| `workspace` | string | `/workspace` | absolute path of safe characters |
| `flavour` | string | **required** | `python-3.13`, `node-24` or `debian` |
| `image_tag` | string | the installed dck's tag | `vX.Y.Z[-pre]` |
| `ssh_port` | integer | `0` | `0` (no sshd) or 1024–65535; published on `bind` only |
| `bind` | string | `127.0.0.1` | IPv4 address every published port binds to. Changing it exposes the container's ports beyond this machine — see [SECURITY.md](SECURITY.md). `dck ssh` and Herdr still connect only to 127.0.0.1 and refuse a `bind` that is neither loopback nor `0.0.0.0` |
| `ports` | table | `{}` | `name = port`; names `^[a-z][a-z0-9_-]{0,31}$`; ports unique and different from `ssh_port` |
| `layers.agents` | boolean | `false` | see [layers.md](layers.md) |
| `layers.dailybot` | boolean | `false` | see [layers.md](layers.md) |
| `layers.editor` | boolean | `true` | see [layers.md](layers.md) |
| `agents.clis` | array | `[]` | kinds from `claude codex cursor opencode pi cline grok`, no duplicates; a warning when set while `layers.agents` is false |
| `herdr.machine` | boolean | `false` | requires a non-zero `ssh_port` |
| `herdr.label` | string | `{repo}` | 1–64 chars; placeholders `{repo}` `{service}` `{project}` `{user}` |

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
host_machine = false               # reserved in v0.1 (reported by the doctor)
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
| `host_machine` | boolean | `false` | host-as-Herdr-machine preference; v0.1 reports it and configures nothing on the host |
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
