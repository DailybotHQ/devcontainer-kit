# Opt-in layers

The base images are agent-free ([images.md](images.md)). Everything else is a
**layer**, switched on per repository in `.devcontainer/dck.toml` and applied
by `dck init` to the repository's own Dockerfile and compose file. Each layer
is off unless the file says otherwise (the editor is the one layer on by
default).

```toml
[layers]
agents = false     # coding-agents-kit (ak) + the CLIs chosen at onboarding
dailybot = false   # the Dailybot CLI — only when the dailybot addon asks for it
editor = true      # nvim + deepworkplan-vim as the default editor

[agents]
clis = ["claude", "codex"]   # wired and installed for everyone
# supported = "all"          # advanced: wire every CLI, each developer chooses
```

By default the CLIs in `clis` are both **wired** (home volumes, host-profile sharing) and
**installed**; a developer may only install fewer. The **advanced** opt-in,
`supported = "all"` (or a list), wires every supported CLI, installed or not, and each
developer chooses what their image installs — `DCK_AGENT_CLIS` or `INSTALL_<CLI>_CLI=true`
(environment or `docker/local/.env`), or `[agents] clis` / `clis_extra` in the host
profile, defaulting to `clis` ([config.md](config.md#each-developers-coding-agent-clis)).

After changing the file, run `dck init` (it shows the diff and asks), then
`dck rebuild`.

## agents

Installs [coding-agents-kit](https://github.com/DailybotHQ/coding-agents-kit)
at the tag pinned in `images/versions.env` (`AGENTKIT_TAG`, **v1.0.0**) into the
dev user's home, following the kit's install contract: the release tarball, verified
against the pinned `AGENTKIT_SHA256` before it is unpacked, then `install.sh --no-rc`, then `ak install <kind>…` for the
requested kinds (`DCK_AGENT_CLIS` plus each `INSTALL_<CLI>_CLI=true`; commas or spaces),
each through its vendor's official channel. A kind outside `DCK_AGENT_SUPPORTED` (the
wired CLIs: `clis`, or `supported` in the advanced mode) stops the build (exit 2) with the
list. The installed list is recorded in
`/opt/dck/agent-clis`; `dck up` and `dck doctor` compare it with the requested one and
say **rebuild needed: dck rebuild** when they differ.

What `dck init` renders when `agents = true` with `clis = ["claude", "codex"]` and
`presets = []` (the default mode; the advanced mode renders the same for every CLI in
`supported`; comment lines left out). A `dck.toml` without a `presets` key renders the
same `RUN` without `DCK_AGENT_PRESETS`, which keeps both presets:

```dockerfile
# >>> dck:layers >>>
ARG DCK_AGENT_CLIS="claude codex"
ARG INSTALL_CLAUDE_CLI=false
ARG INSTALL_CODEX_CLI=false
RUN DCK_USER=dev DCK_AGENT_SUPPORTED="claude codex" DCK_AGENT_PRESETS="" dck-layer agents ${DCK_AGENT_CLIS}
# <<< dck:layers <<<
```

```yaml
    build:
      args:
        DCK_AGENT_CLIS: "${DCK_AGENT_CLIS:-claude codex}"
        INSTALL_CLAUDE_CLI: "${INSTALL_CLAUDE_CLI:-false}"
        INSTALL_CODEX_CLI: "${INSTALL_CODEX_CLI:-false}"
    volumes:
      - agentkit:/home/dev/.dck/volumes/agentkit
      - claude:/home/dev/.dck/volumes/claude
      - codex:/home/dev/.dck/volumes/codex
      # advanced mode: one per supported CLI, installed or not (an unused one stays empty)
    environment:
      DCK_AGENTS: "claude codex"
      AGENTKIT_PROFILES_DIR: /home/dev/.dck/volumes/agentkit/profiles
```

- **Codex skips its startup update check and the daemon's auto-start** inside containers
  (`check_for_update_on_startup = false` and `[features] daemon_auto_start = false` in
  the container's own Codex configs, written by the entrypoint; never in the host's Codex
  home or a host-shared profile): dck pins every CLI version, and a plain `codex` that
  Herdr restores runs in-process. Codex's hook trust screen is left to the developer.
- **The kit's agent skills.** `agentkit`, `agentkit-setup` and `agentkit-orchestrate`
  come from the same verified release tarball into the image's shared skills directory
  (`/usr/local/share/dck/skills`); at every start the entrypoint links them, with the
  herdr-peers and Herdr skills, into each agent's skills directory (`~/.agents/skills`,
  `~/.claude/skills`, and the others that exist). Agent homes live on volumes, so a skill
  installed there by hand is lost on a recreate; these are not.
- **npm globals go to `~/.local`.** The layer writes `prefix=~/.local` to the dev
  user's `~/.npmrc` (Node's own prefix is root's), so `ak install` of npm-based
  CLIs (codex, pi, cline …) works at build time and later inside the container;
  `~/.local/bin` is on the login PATH.
- **The agents' own Node.** When the image's `node` is missing or older than the
  pinned major (Debian's `nodejs` on `python-3.13` and `debian`, or a repository that
  runs an older Node in production), the official nodejs.org tarball at
  `NODE_VERSION`, checked against its pinned SHA-256, is extracted into its **own
  prefix**, `/opt/dck/node` — never over `/usr/local`. The repository's `node` stays
  the shell's `node` and npm trees are never mixed: `ak install` runs with the
  agents' Node first on PATH, and every npm-installed agent CLI whose entry point is
  a node script gets a launcher in `~/.local/bin` that runs it on that Node.
  `node-24` (or any image with a current Node) needs none of this. A repository whose
  own tooling needs that Node too sets `[agents] node_first = true`: `/opt/dck/node/bin`
  then comes first on PATH for every process and login shell.
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
  | antigravity | `~/.gemini` (the Antigravity CLI `agy`: its state, and inside a container its Google login, which `agy` keeps in `~/.gemini/antigravity-cli/antigravity-oauth-token` when no OS keyring is reachable) |

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
- **The wrapper names, opt-in.** `[agents] presets` chooses ak's alias presets
  (`DCK_AGENT_PRESETS`): `classic` (`claudex`, `codexx`, `cursorx`, `opencodex`,
  `pix`, `clinex`, `grokx`) and `providers` (`claude-glm`, `codex-glm`,
  `codex-azure`, `codex-xai`, …), loaded by every bash the dev user starts. New
  renders write `presets = []` (none); a `dck.toml` without the key keeps both, as
  before v0.3.3.

## Host accounts

Containers can use the agent accounts you already have on the host, like git already
works through the host's SSH agent: no login inside. Opt in once, in your **host
profile** (`~/.config/dck/profile.toml`; a repository cannot ask for it):

```toml
[agents]
host_profiles = true
host_profile_names = []   # optional: only these, e.g. ["claude@work1", "codex@default"]
host_env_keys = []        # optional: exact names to copy besides the Claude tokens
```

Then `dck up` (or `dck up --recreate` for a running container) adds a runtime compose
overlay — written next to dck's other overlay under `$TMPDIR/dck-<uid>/`, never into
the repository — that binds:

| Host | Container | Mode |
| --- | --- | --- |
| each ak profile `$AGENTKIT_PROFILES_DIR/<cli>/<name>` (default root `~/.local/share/agentkit/profiles`) of the wired CLIs (`clis`, or `[agents] supported` in the advanced mode, installed or not; only profiles that exist on the host) — claude, codex, pi, cline, grok, opencode — or only those in `host_profile_names` | `~/.dck/host/agentkit/profiles/<cli>/<name>`; `AGENTKIT_PROFILES_DIR` points there | read-write: the CLI writes its state there |
| `$CODEX_HOME` or `~/.codex` (the Codex `@default` login), when codex is wired and `codex@default` shared | `~/.dck/host/codex`; `~/.codex` links to it | read-write: token refresh in `auth.json` |
| the directory `~/.config/dck/agents/<project>/` (0700) holding the env file `env`, generated (0600) on the host | `~/.dck/host/agentkit/hostenv/`; `AGENTKIT_ENV` points at `hostenv/env` | read-only |

The directory is bound, not the file: every `dck up` rewrites the env file atomically,
and a running container sees the new file at once (a single-file bind would keep the old
one until the container is recreated).

Each read-write mount and its reason is listed in
[SECURITY.md](SECURITY.md#host-accounts-agents-host_profiles) and by `dck doctor`.

- **Only the CLIs the repository wires**, and only file-portable profiles: cursor
  (and antigravity) profiles hold absolute host symlinks and are skipped. The whole
  `AGENTKIT_HOME` is never mounted (it would shadow the ak the image pins), nor a whole
  CLI directory: profiles are bound one by one.
- **The CLIs not shared keep their profiles on the volume.** With the option on,
  `AGENTKIT_PROFILES_DIR` is `~/.dck/host/agentkit/profiles`, so a profile created inside
  for a CLI the host does not share (antigravity, cursor, or a CLI with no host profile)
  would land in the container layer. At every start the entrypoint links
  `~/.dck/host/agentkit/profiles/<cli>` to that CLI's directory on the `agentkit` volume
  (created 0700) — the directory ak uses with the option off, so both modes see the same
  profiles. `ak antigravity @g1`, its login inside, then `dck rebuild` (or `dck up
  --recreate`): the login is still there. A shared CLI's directory holds the host's mounts
  and is never linked — create a new profile of a shared CLI on the host. **Upgrading:** a
  container started from an image of v0.3.5 or earlier keeps such profiles in its layer;
  `dck up --recreate` and `dck rebuild` first run this version's step inside the old
  container, which moves each profile the volume lacks onto it (reported as `agents: …`).
  For a name the volume already has, the volume's copy is kept and the layer's is set
  aside on the volume as `~/.dck/volumes/agentkit/profiles/.<cli>.dck-pre-volume-<UTC>`,
  logged by path only. An entry on another device (a bind mount) is never moved; a link
  there that points outside the volume, or a volume directory that is a symlink, is
  refused and left as is. A container recreated by other means (the editor, plain
  `docker compose`) skips that step: run `dck up --recreate` once instead.
- **Claude:** a profile logged in through the macOS keychain cannot reach a container.
  Give each such account a long-lived token — `claude setup-token`, then store it in
  ak's env file (`~/.config/agentkit/env`, mode 600; `ak env import <file>` copies
  `KEY=value` lines from a file) as `CLAUDE_CODE_OAUTH_TOKEN` (`@default`) or
  `CLAUDE_CODE_OAUTH_TOKEN_<SUFFIX>` (`@name`: the name upper-cased, every character
  outside `A-Z0-9_` replaced by `_`; `@team-b` → `CLAUDE_CODE_OAUTH_TOKEN_TEAM_B`).
- **The env file has no implicit secret:** the token of each Claude profile actually
  shared (`CLAUDE_CODE_OAUTH_TOKEN` when `claude@default` is), and the exact names in
  `host_env_keys` — nothing else. `host_env_keys = []` copies only those tokens; with
  `host_profiles` off nothing is copied. Values are never printed: the overlay,
  `dck up` and `dck doctor` state the names. The doctor also reports each shared
  profile with its mount mode and reason, and the Claude profiles that still need a
  token (from the host's `ak profiles --json`, schema `profiles-v1`,
  coding-agents-kit v0.5.0+).
- **Codex:** `auth.json` is shared read-write; keep one active writer per account
  (see [SECURITY.md](SECURITY.md#host-accounts-agents-host_profiles)).
- **A default account inside:** `[agents] default_profile = { claude = "@work3" }` (host
  profile) exports `AGENTKIT_DEFAULT_PROFILE_<CLI>` into the container when that profile
  is shared, so a bare `ak claude` uses it; the login profile also exports
  `CLAUDE_CONFIG_DIR` / `CODEX_HOME` as that profile's home (unless already set), so a
  plain `claude --resume` or `codex resume` that Herdr restores without ak uses it too.
  The macOS `@default` Claude login lives in the keychain and cannot be a default inside;
  `dck doctor` shows the mapping and flags one it cannot apply.
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
entrypoint does this at every start, for the wired CLIs (`DCK_AGENTS`):

- **Folder trust for the app path** (`workspace`, `/app` by default): Claude's "trust
  this folder" and Codex's "Trust this folder?" are pre-answered — in the container's
  own CLI homes **and** in shared host profiles (an entry for `/app` is inert on the host).
- **Claude's bypass-permissions acknowledgement** (and its onboarding): written **only**
  in the container's own CLI homes — the container is the sandbox you chose for autonomy —
  **never** in a shared host profile, which also drives your Claude on the host, where a
  human acknowledges it once per profile.
- With `AGENTKIT_PERMISSIONS=ask` (the opt-out, in `docker/local/<service>/.env` or in
  ak's env file) neither is written.

No agent ever keys through Claude's bypass-permissions acknowledgement. A leftover one
(a shared host profile whose acknowledgement was never given) is escalated to you: accept
it once per profile on the host (`ak claude @<name>`, accept, exit) and later launches
never stop. Folder trust is the only screen an agent may key through, and only on a pane
it launched itself when `--trust-cwd` was unavailable: `herdr pane read <pane> --source
visible` to see the screen, then `herdr pane send-keys <pane> <key>…` to move from the
preselected "No, exit" to "Yes" before Enter. Any other new screen (a CLI version that
asks something new) is escalated too.

## dailybot

Only when the `dailybot` addon asks for it. Renders
`RUN DCK_USER=<user> dck-layer dailybot`: the Dailybot CLI wheel
(`DAILYBOT_CLI_VERSION`) is downloaded from PyPI, checked against its pinned
SHA-256, and installed as an isolated `uv` tool on `/usr/local/bin` (uv is the
image's own on `python-3.13`, otherwise a pinned, checksum-verified standalone
binary). The wheel's dependencies are resolved by uv at build time. The CLI's
config (`~/.config/dailybot`) is kept on the `state` volume.

## editor

On by default: the rendered Dockerfile installs deepworkplan-vim in its own layer
(`dck/editor.sh`) and `EDITOR`, `VISUAL` and `GIT_EDITOR` are `nvim` with that
configuration. With `editor = false` that layer is not rendered, the Dockerfile sets
the three to `nano` and compose passes `DCK_EDITOR=0`. The pinned Neovim binary is
still installed (by `install.sh`); only deepworkplan-vim and the default change.

## How the layers are packaged

The installers are scripts in `lib/layers/` (`common.sh`, `agents.sh`,
`dailybot.sh`). `dck init` vendors them into `docker/local/<service>/dck/layers/`
and the rendered Dockerfile copies them to `/usr/local/lib/dck/layers/` with the
dispatcher `/usr/local/bin/dck-layer` (the published base images carry the same
paths). They run only during the **repository's** image build and read their pins
from the image's `/etc/dck/versions.env`. Every download goes through one verified
`fetch`; nothing is piped into a shell.

## Status in v1.0

The `agents` layer is verified end to end with coding-agents-kit `v1.0.0`
(installed from its sha256-verified release tarball; `ak` interface 1, permissions
`auto` by default; the `docker` test scope builds a rendered node fixture on every CI
run: `--clis codex --supported all`, the host profile's `clis_extra = ["pi"]`, so
`ak install codex pi`, with the `classic` and `providers` presets turned on). Each
vendor CLI's own behaviour belongs to the ecosystem field test. The `dailybot`
and `editor` layers are verified end to end.
