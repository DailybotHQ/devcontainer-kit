# Opt-in layers

The base images are agent-free ([images.md](images.md)). Everything else is a
**layer**, switched on per repository in `.devcontainer/dck.toml` and applied
by `dck init` to the repository's own Dockerfile and compose file. Each layer
is off unless the file says otherwise (the editor is the one layer on by
default).

```toml
[layers]
agents = false     # coding-agents-kit (ak) + the CLIs in [agents].clis
dailybot = false   # the Dailybot CLI — only when the dailybot addon asks for it
editor = true      # nvim + deepworkplan-vim as the default editor

[agents]
clis = []          # claude codex cursor opencode pi cline grok
```

After changing the file, run `dck init` (it shows the diff and asks), then
`dck rebuild`.

## agents

Installs [coding-agents-kit](https://github.com/DailybotHQ/coding-agents-kit)
at the tag pinned in `images/versions.env` (`AGENTKIT_TAG`, **v0.1.1**) into the
dev user's home, following the kit's install contract:
`git clone --branch <tag> … && ./install.sh`, then `ak install <kind>…` for the
kinds in `agents.clis`, each through its vendor's official channel.

What `dck init` renders when `agents = true`:

```dockerfile
# >>> dck:layers >>>
ARG DCK_AGENT_CLIS="claude codex"
RUN DCK_USER=dev dck-layer agents ${DCK_AGENT_CLIS}
# <<< dck:layers <<<
```

```yaml
    volumes:
      - agentkit:/home/dev/.dck/volumes/agentkit
      - claude:/home/dev/.dck/volumes/claude
      - codex:/home/dev/.dck/volumes/codex
    environment:
      DCK_AGENTS: "claude codex"
      AGENTKIT_PROFILES_DIR: /home/dev/.dck/volumes/agentkit/profiles
```

- **npm globals go to `~/.local`.** The layer writes `prefix=~/.local` to the dev
  user's `~/.npmrc` (Node's own prefix is root's), so `ak install` of npm-based
  CLIs (codex, pi, cline …) works at build time and later inside the container;
  `~/.local/bin` is on the login PATH.
- **Node** is added where the flavour lacks a current one (`python-3.13` and
  `debian` carry only Debian's older `nodejs`, installed for the editor's
  plugins): the official nodejs.org tarball at `NODE_VERSION`, checked against
  its pinned SHA-256 before extraction into `/usr/local`, ahead of `/usr/bin`
  on PATH. It is installed when `node` is missing or its major is older than
  the pinned one. `node-24` already has it.
- **One named volume per CLI home**, per compose project. At start the
  entrypoint (`dck_layer_persist`, [entrypoint.md](entrypoint.md)) links each
  kind's home onto its volume:

  | Kind | Persisted |
  | --- | --- |
  | claude | `~/.claude`, `~/.claude.json` |
  | codex | `~/.codex` |
  | cursor | `~/.cursor`, `~/.config/cursor` |
  | opencode | `~/.config/opencode`, `~/.local/share/opencode` |
  | pi | `~/.pi` |
  | cline | `~/.cline` |
  | grok | `~/.grok` |

  `~/.config/agentkit` (ak's env file, mode 600) is on the `agentkit` volume
  and `AGENTKIT_PROFILES_DIR` points ak's profiles there, so logins survive
  rebuilds. A volume copy always wins over a rebuilt image's copy; to start a
  CLI from scratch, remove its volume (`docker volume rm <project>_<kind>`).
- **Autonomy by default, with an opt-out.** coding-agents-kit (v0.3.0+)
  launches every CLI in autonomy; the container is the sandbox (Codex's
  bubblewrap sandbox cannot create user namespaces inside a container, for
  example). The layer itself spells no autonomy flag. To have agents ask,
  set `AGENTKIT_PERMISSIONS=ask` in `docker/local/<service>/.env` or
  uncomment it in compose; `ak <kind> --ask` opts out for one launch.
- **The wrapper names.** The layer turns on ak's `classic` preset (`claudex`,
  `codexx`, `cursorx`, `opencodex`, `pix`, `clinex`, `grokx`) and `providers`
  preset (`claude-glm`, `codex-glm`, `codex-azure`, `codex-xai`, …), loaded by
  every bash the dev user starts.

## dailybot

Only when the `dailybot` addon asks for it. Renders
`RUN DCK_USER=<user> dck-layer dailybot`: the Dailybot CLI wheel
(`DAILYBOT_CLI_VERSION`) is downloaded from PyPI, checked against its pinned
SHA-256, and installed as an isolated `uv` tool on `/usr/local/bin` (uv is the
image's own on `python-3.13`, otherwise a pinned, checksum-verified standalone
binary). The wheel's dependencies are resolved by uv at build time. The CLI's
config (`~/.config/dailybot`) is kept on the `state` volume.

## editor

On by default: `EDITOR`, `VISUAL` and `GIT_EDITOR` are `nvim` with the
deepworkplan-vim configuration. With `editor = false` the Dockerfile sets them
to `nano` and compose passes `DCK_EDITOR=0`. The base image still contains
nvim; the layer decides the default, not the presence.

## How the layers are packaged

The installers are scripts in `lib/layers/` (`common.sh`, `agents.sh`,
`dailybot.sh`), baked into every base image at `/usr/local/lib/dck/layers/`
with the dispatcher `/usr/local/bin/dck-layer`. They run only during the
**repository's** image build. Every download goes through one verified
`fetch`; nothing is piped into a shell.

## Status in v0.1.x

The `agents` layer is verified end to end with coding-agents-kit `v0.1.1`
(`ak` interface 1, permissions `ask`; `ak install codex` in real python-3.13 and
node-24 images; the `docker` test scope installs the kit on every CI run). Each
vendor CLI's own behaviour belongs to the ecosystem field test. The `dailybot`
and `editor` layers are verified end to end.
