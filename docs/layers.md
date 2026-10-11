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
at the tag pinned in `images/versions.env` (`AGENTKIT_TAG`, **v0.4.0**) into the
dev user's home, following the kit's install contract: the release tarball, verified
against the pinned `AGENTKIT_SHA256` before it is unpacked, then `install.sh --no-rc`, then `ak install <kind>…` for the
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
  set `AGENTKIT_PERMISSIONS=ask` in `docker/local/<service>/.env` (the
  compose block is reconciled by `dck init`; the `.env` is yours);
  `ak <kind> --ask` opts out for one launch.
- **The wrapper names.** The layer turns on ak's `classic` preset (`claudex`,
  `codexx`, `cursorx`, `opencodex`, `pix`, `clinex`, `grokx`) and `providers`
  preset (`claude-glm`, `codex-glm`, `codex-azure`, `codex-xai`, …), loaded by
  every bash the dev user starts.

## Host accounts

Containers can use the agent accounts you already have on the host, like git already
works through the host's SSH agent: no login inside. Opt in once, in your **host
profile** (`~/.config/dck/profile.toml`; a repository cannot ask for it):

```toml
[agents]
host_profiles = true
host_env_keys = ["OPENAI_API_KEY"]   # optional: more names for the container's env file
```

Then `dck up` (or `dck up --recreate` for a running container) adds a runtime compose
overlay — written next to dck's other overlay under `$TMPDIR/dck-<uid>/`, never into
the repository — that binds:

| Host | Container | Mode |
| --- | --- | --- |
| `$AGENTKIT_PROFILES_DIR/<cli>` (default `~/.local/share/agentkit/profiles/<cli>`) for each CLI in `[agents] clis` that has host profiles: claude, codex, pi, cline, grok, opencode | `~/.dck/host/agentkit/profiles/<cli>`; `AGENTKIT_PROFILES_DIR` points there | read-write |
| `$CODEX_HOME` or `~/.codex` (the Codex `@default` login), when codex is installed | `~/.dck/host/codex`; `~/.codex` links to it | read-write |
| `~/.config/dck/agents/<project>.env`, generated (0600) from the host's ak env file | `~/.dck/host/agentkit/env`; `AGENTKIT_ENV` points there | read-only |

- **Only the CLIs the repository installs**, and only file-portable profiles: cursor
  (and antigravity) profiles hold absolute host symlinks and are skipped. The whole
  `AGENTKIT_HOME` is never mounted (it would shadow the ak the image pins).
- **Claude:** a profile logged in through the macOS keychain cannot reach a container.
  Give each such account a long-lived token — `claude setup-token`, then store it in
  ak's env file (`~/.config/agentkit/env`, mode 600; `ak env import <file>` copies
  `KEY=value` lines from a file) as `CLAUDE_CODE_OAUTH_TOKEN` (`@default`) or `CLAUDE_CODE_OAUTH_TOKEN_<SUFFIX>`
  (`@name`: the name upper-cased, every character outside `A-Z0-9_` replaced by `_`;
  `@team-b` → `CLAUDE_CODE_OAUTH_TOKEN_TEAM_B`). Those names are always in the env file.
- **Codex:** `auth.json` is shared read-write; keep one active writer per account
  (see [SECURITY.md](SECURITY.md#host-accounts-agents-host_profiles)).
- **The env file** holds only `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN_*` and
  the names in `host_env_keys`; values are never printed. `dck up` lists the names it
  shared; `dck doctor` reports the shared CLIs, the env file's names and the Claude
  profiles that still need a token (it asks the host's `ak profiles --json`,
  schema `profiles-v1`, coding-agents-kit v0.5.0+).
- **Compose backend:** the overlay is a compose file, so with the option on `dck up`
  uses compose even when the devcontainer CLI is installed; an editor that opens the
  container itself does not apply it.
- Turning the option off (or the repository's agents layer off) removes the overlay
  and the env file at the next `dck up`; `~/.codex` goes back to its volume, whose
  contents were kept.

## Unattended agent launches

An orchestrating agent (or you) must be able to start a new agent in the container —
`ak claude`, `ak codex @work1`, a new Herdr pane — and have it work at once, with no
first-run screen waiting for a key nobody presses. With autonomy on (the default) the
entrypoint does this at every start, for the CLIs in `[agents] clis`:

- **Folder trust for the app path** (`workspace`, `/app` by default): Claude's "trust
  this folder" and Codex's "Trust this folder?" are pre-answered — in the container's
  own CLI homes **and** in shared host profiles (an entry for `/app` is inert on the host).
- **Claude's bypass-permissions acknowledgement** (and its onboarding): written **only**
  in the container's own CLI homes — the container is the sandbox you chose for autonomy —
  **never** in a shared host profile, which also drives your Claude on the host, where a
  human acknowledges it once per profile.
- With `AGENTKIT_PERMISSIONS=ask` (the opt-out, in `docker/local/<service>/.env` or in
  ak's env file) neither is written.

If a screen still appears (a CLI version that asks something new, or a host profile
whose bypass acknowledgement was never given), the orchestrator answers it through
Herdr, under your standing authorization: `herdr pane read <pane> --source visible` to see the screen,
then `herdr pane send-keys <pane> <key>…` to choose the option (for Claude's folder
question, move from the preselected "No, exit" to "Yes" before Enter). Prefer giving the
acknowledgement once on the host (`ak claude @<name>`, accept, exit) so later launches
never stop.

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

## Status in v0.3.x

The `agents` layer is verified end to end with coding-agents-kit `v0.4.0`
(installed from its sha256-verified release tarball; `ak` interface 1, permissions
`auto` by default; `ak install codex pi`, the `classic` and `providers` presets; the
`docker` test scope builds a rendered node fixture with the layer on every CI run). Each
vendor CLI's own behaviour belongs to the ecosystem field test. The `dailybot`
and `editor` layers are verified end to end.
