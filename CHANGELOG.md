# Changelog

All notable changes to devcontainer-kit are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/) (0.x: a breaking change bumps the minor version
and the interface number).

## [Unreleased]

### Added

- **`HERDR_PEERS_SELF` inside containers.** Asks from a Codex pane failed with "no reply
  route" until `HERDR_PEERS_SELF` named the container's machine id in the host's Herdr
  catalog. `dck up`, `dck herdr add` (after every registration) and `dck herdr mesh` now
  record that id on the state volume (new entrypoint function `dck_herdr_self`) and the
  login profile exports it; `dck herdr remove` clears it. `dck doctor` shows both ids
  (`herdr self`; `herdr.id` / `herdr.self_inside` in `--json`) and flags a mismatch.
- **Shared compose stacks** ([docs/shared-stack.md](docs/shared-stack.md)), all additive:
  a repository that sets none of these renders byte-identically to v0.3.2.
  - **The user block**: `# >>> user:<svc> >>>` … `# <<< user:<svc> <<<` inside the dck
    service, kept verbatim. Plain keys for what dck does not render (`depends_on`,
    `healthcheck`, …); `x-dck-merge:` for keys it does, merged at `dck init` (lists
    appended, maps merged with the user's entry winning, scalars and replace-only keys
    such as `command` and `entrypoint` replaced in any YAML form). A plain key dck also
    renders is refused with the fix.
  - **Top-level `user:volumes` / `user:networks` sub-blocks** and `[compose] volumes`, so
    the file's other services (a database, workers) declare their data volumes and
    networks with their exact names and existing volumes keep reattaching; a name
    declared twice is refused.
  - **Port strings**: `ssh_port` and `ports` accept compose expressions
    (`"${DJANGO_RUNSERVER_HOST_PORT:-8000}:8000"`, `"5001:3000"`), loopback-prefixed
    unless they name a host IP; the launcher resolves `${VAR:-default}` (environment,
    then `docker/local/.env`) for `dck ssh`, Herdr and the doctor.
  - `[build] context` (build from the repository root; dck's `COPY` paths follow it) and
    `[build] dockerfile` (a Dockerfile shared by several services, where dck's blocks and
    its `dck/` directory go).
  - `[compose] project` and `[compose] networks` (one top-level `networks:`, external).
  - `[agents] presets`: the ak alias presets (`classic`, `providers`). Unset keeps both,
    as before; new renders write `presets = []` (off).
- `dck doctor`: Docker Compose >= 2.24 (satellites with `extends` + `!reset`), a compose
  file that does not reflect `dck.toml` or its user block (`dck up` and `dck rebuild`
  warn too), and what the user block overrides (`compose_render` in `--json`).

### Changed

- **Markers are all-or-nothing.** A compose file or Dockerfile with some of dck's markers
  but not all, or with unbalanced markers, is refused with the fix instead of being
  replaced or appended to (a block appended at the end could land inside another
  mapping). A file without any dck marker is still proposed as a whole-file replacement.

## [0.3.2] — 2026-10-11

Interface stays **2**.

### Added

- **The host's SSH keys inside containers, opt-in** (`[ssh] copy_keys = true` in the host
  profile; off by default, a repository's `dck.toml` cannot set it). Tools that only offer
  key files, such as `gh auth login`, ignored the forwarded agent and asked to generate a
  new key. With it on, `dck up` binds the host's `~/.ssh` read-only at `~/.ssh_host`
  through a runtime compose overlay (`$TMPDIR/dck-<uid>/<project>-sshkeys.yml`), and every
  container start copies its `id_*` keys into the container's `~/.ssh` on the state
  volume (private 0600, `.pub` 0644, refreshed when they change on the host, removed when
  removed there). dck's own `config`, `config.d/`, `authorized_keys` and
  `known_hosts.dck-host` are never touched, a key the container made itself is kept, and
  the agent forwarding is unchanged. Turning it off removes the copies at the next start.
  While it is on, the whole host `~/.ssh` is readable inside (read-only), not only the
  `id_*` keys, and private keys rest in the state volume: the trade-off and the wipe are
  in `docs/SECURITY.md`. New entrypoint function `dck_ssh_copy_keys`.
- `dck setup` asks once, on a terminal, whether to copy the host's SSH keys (default no)
  and records the answer in the profile's `[ssh]` table.
- `dck doctor` reports the opt-in and the key file names (`ssh keys copied: …`, names
  only); `doctor --json` gains an optional `ssh_keys` object (`enabled`, `reason`,
  `host_keys`, `copied`).
- The agents layer installs coding-agents-kit's three skills (`agentkit`,
  `agentkit-setup`, `agentkit-orchestrate`) from the same verified release tarball into
  the image's shared skills directory; the entrypoint links them into every agent's
  skills directory at each start, so a recreate no longer loses them.

- The repository dogfoods its own container (`.devcontainer/`, `docker/local/`,
  `dev.sh`): python-3.13 with every coding-agents-kit CLI, Herdr, herdr-peers and
  shellcheck, registered as a Herdr machine; the unit gate runs inside.

### Fixed

- **`[compose] state_volume`** in `dck.toml` (and `dck init --state-volume NAME`): the
  name of the service's state volume (sshd host key, `~/.ssh`, gh auth, Herdr client
  state, history). It was hardcoded as `state`, so repositories sharing one compose
  project (one `COMPOSE_PROJECT_NAME`) all mounted one `<project>_state` volume. The
  default stays `state`, so no existing install loses its volume; only the compose
  volume's name changes, the mount point (`~/.dck/volumes/state`) does not. The agents
  layer's volumes stay shared by name.
- `dck doctor` flags a compose project shared with other services whose state volume is
  not per service (or another service mounting the same state volume), with the fix;
  `doctor --json` gains an optional `compose` object. The doctor now resolves the compose
  project like the launcher and compose (`COMPOSE_PROJECT_NAME` from the environment or
  the compose directory's `.env` before the file's `name:`).
- `dck doctor` says when Claude's default account will not be logged in inside (its
  host login is the macOS keychain, never shared, and `CLAUDE_CODE_OAUTH_TOKEN` is not in
  ak's env file), with both fixes, instead of a bare "not copied" line.
- A container built from scratch reaches the host and its peers at once: `dck rebuild`,
  `dck start` and `dck restart` now run the same post-start steps as `dck up` — the Herdr
  machine is registered (re-added when it was removed, its host key re-pinned), the mesh
  and the host-catalog mirror are pushed, and the layout is created. A rebuild after the
  volumes were removed left an empty Herdr catalog inside until `dck herdr mesh` ran by
  hand.

### Changed

- **Pins:** coding-agents-kit **v0.5.1** (`AGENTKIT_TAG`; tag commit `48c38f8`, tarball
  sha256 `62cde0e8…`, `SHA256SUMS` sha256 `400e8fd6…`).
- Agent tooling: the vendored `deepworkplan` skill moves to v7.6.1 (`skills-lock.json`,
  AGENTS.md provenance), through the pack's own addon planner; the AI Diff Reviewer
  stays at v3.3.9, the pack's pin.

## [0.3.1] — 2026-10-11

Interface stays **2**.

### Fixed

- Host accounts keep working across `dck up`: the env file of `[agents] host_profiles`
  is now bound through its per-project directory (`~/.config/dck/agents/<project>/env`,
  in the container `~/.dck/host/agentkit/hostenv/env`), not as a single file. Every
  `dck up` rewrites it atomically, and a single-file bind kept showing the old inode,
  so tokens went stale or unset in a running container until `--recreate`. The v0.3.0
  file `~/.config/dck/agents/<project>.env` is removed on the next `dck up`.
- A removed `state` volume no longer breaks `dck ssh` and `dck herdr add` (and `dck up`
  with Herdr on) behind a bare "sshd does not answer": the host key is pinned from the
  container itself through `docker exec` (new entrypoint helper `dck_host_key_pub`), and
  a changed key is re-pinned with a note. When the key cannot be read (an older image),
  a mismatch is named with the exact `ssh-keygen -R <alias> -f …` fix.

### Changed

- **Pins:** herdr-peers **v0.2.2** (`HERDR_PEERS_TAG`, verified by the sha256 of its
  `SHA256SUMS`): Codex lanes pass `--pane`, and `list` shows full machine ids.
- Agent tooling: the vendored `deepworkplan` skill moves to v7.6.0 and the AI Diff
  Reviewer skill to v3.3.9 (`skills-lock.json`, `.dwp/config.json`, AGENTS.md
  provenance), through the pack's own addon planner.
- Docs: no agent keys through Claude's bypass-permissions acknowledgement. A leftover one
  is escalated to the developer, who accepts it once per profile; folder trust is the only
  screen an agent may key through, and only on a pane it launched itself when
  `--trust-cwd` was unavailable (`docs/layers.md`, the `dck` skill, `docs/SECURITY.md`).

## [0.3.0] — 2026-10-11

Interface stays **2**: every new key is optional and off by default.

### Added

- **Containers can use the host's agent accounts** (`[agents] host_profiles = true`, host
  profile only — a repository's `dck.toml` cannot turn it on). `dck up` adds a runtime
  compose overlay, never written into the repository, that binds the host's
  coding-agents-kit profiles of the CLIs the repository installs (`[agents] clis`;
  claude, codex, pi, cline, grok, opencode — never cursor, whose profiles hold absolute
  host symlinks), one bind per profile, with `AGENTKIT_PROFILES_DIR` pointing at them;
  `[agents] host_profile_names` limits them to the profiles listed (`"claude@work1"`).
  Also the host's Codex home (`codex@default`) when codex is installed, and a generated
  env file (0600, under `~/.config/dck/agents/`) read-only with `AGENTKIT_ENV` pointing
  at it. Mounts are read-write only where the CLI writes, each reason documented and
  shown by the doctor. The env file has no implicit secret: only the Claude token of
  each shared Claude profile and the exact names in `[agents] host_env_keys`; with the
  option off nothing is copied. Values never appear in compose files, logs or the
  doctor; the names do.
- `dck doctor` reports the shared profiles with their mount mode and reason, the env
  file's names and, from the host's
  `ak profiles --json` (`profiles-v1`, coding-agents-kit v0.5.0+), the Claude profiles
  that log in through the macOS keychain without a token variable (with the fix:
  `claude setup-token`, then store it in ak's env file as `CLAUDE_CODE_OAUTH_TOKEN_<SUFFIX>`).
  `doctor --json` gains an optional `host_profiles` object (`profiles`, `mounts`, …).
- **Unattended agent launches.** With autonomy on, the entrypoint marks the app path as
  trusted for Claude and Codex at each start — in the container's own CLI homes and in
  shared host profiles — and writes Claude's bypass-permissions acknowledgement only in
  the container's own homes, never in a shared host profile. `AGENTKIT_PERMISSIONS=ask`
  writes neither. The Herdr fallback for a screen that still appears is documented.

### Changed

- **The agents layer installs coding-agents-kit v0.5.0** (`AGENTKIT_TAG`, verified by
  `AGENTKIT_SHA256`): accounts and quota (`ak usage`, `ak pick`), the per-profile Claude
  token (`CLAUDE_CODE_OAUTH_TOKEN_<SUFFIX>`) and `ak profiles --json` (`profiles-v1`),
  which `host_profiles` and `dck doctor` build on.
- **Pins:** herdr-peers **v0.2.1** (`HERDR_PEERS_TAG`, verified by the sha256 of its
  release `SHA256SUMS`) inside the images and for `dck host peers install`, and
  deepworkplan-vim **v0.7.0** (`DWP_VIM_TAG`, its tag commit and installer sha256) as
  the editor.
- With `host_profiles` on, `dck up` uses the compose backend (the overlay is a compose
  file the devcontainer CLI never reads).
- The test suite is PATH-hermetic: the developer's own `ak`, `herdr`, `herdr-peers`,
  `dck` and agent CLIs are hidden from every test, and `AGENTKIT_*`, `HERDR_*`,
  `CLAUDE_*`, `CODEX_*` and credential-shaped variables are cleared in the sandbox.

### Security

- Credential sharing is opt-in and documented in `docs/SECURITY.md`: Codex `auth.json`
  is shared read-write, so keep one active writer per account.

Upgrade: install v0.3.0, then (optionally) set `[agents] host_profiles = true` in your
host profile and `dck up --recreate`.

## [0.2.11] — 2026-10-11

### Fixed

- The layout also closes the workspace Herdr's server opens before it when that workspace is
  named after the app path ("app" for `/app`): once v0.2.9 pointed `new_cwd` there, Herdr
  stopped naming it "~". Still only when it holds one pane and no agent.

## [0.2.10] — 2026-10-11

### Changed

- **The agents layer installs coding-agents-kit v0.4.0** (`AGENTKIT_TAG`, verified by
  `AGENTKIT_SHA256`): `ak usage` shows the quota and usage of every account and profile,
  and `ak setup` probes, verifies and repairs the kit, inside the container as on the host.

### Fixed

- The agents layer runs the `ak` it just installed, not whichever `ak` is first on `PATH`
  (an older copy in an image, or the host's during the tests).

Upgrade with `dck init` and `bash dev.sh rebuild`.

## [0.2.9] — 2026-10-11

### Changed

- **The Herdr layout is App · Editor · Development · Agents.** The first workspace is now
  App (an existing Home is renamed on `--keep`), and the `~` workspace Herdr's server opens
  in the home directory before the layout runs is closed while it still holds one idle pane.
- **Every workspace and pane opens in the app path.** Herdr's `new_cwd` follows `dck.toml`
  `workspace` (the image's seeded `/workspace` is repaired), so panes opened later with
  Herdr's "new" start there too; `dck init` now defaults `workspace` to `/app`.

Upgrade with `dck init`, `bash dev.sh rebuild` and `bash dev.sh up` (or
`dck herdr layout --keep`).

## [0.2.8] — 2026-10-11

### Fixed

- Agents in Herdr panes have an SSH agent even when the Herdr client that attached
  forwarded none. Herdr then points `SSH_AUTH_SOCK` at a dangling link, so mesh hops,
  `herdr-peers reply` and git over SSH failed with `Permission denied (publickey)`. The
  login profile falls back to the host agent dck mounts, and the entrypoint repoints the
  dangling Herdr link at it. Upgrade with `dck init` and `bash dev.sh rebuild`.

## [0.2.7] — 2026-10-11

### Fixed

- A persisted JSON file that does not exist yet (or was left empty by an earlier version)
  starts as `{}` instead of an empty file: an empty `~/.claude.json` made Claude Code report
  its configuration as corrupt and stop on the first run in every new container. Upgrade with
  `dck init` and `bash dev.sh rebuild`; empty files already on a volume are repaired at start.

## [0.2.6] — 2026-10-11

Upgrade with `dck init` (re-renders the vendored entrypoint), `bash dev.sh rebuild`, then
`dck herdr mesh` (or `dck up`).

### Fixed

- **herdr-peers replies across machines.** An ask carries its reply address as
  `<machine id>:<pane>`, the id the asker has in its own Herdr catalog; containers minted new
  ids with `herdr machine add`, so a reply could not name the machine that asked. The mesh
  now pushes the host's catalog entries (id, label, target, session, enabled) for every
  machine the container can reach — every dck container including itself, the host's other
  loopback machines with a pinned key and the host's own entry — and the container's Herdr
  catalog becomes that copy (atomically, the previous file kept as `.dck-bak`). The ssh side
  gains a block for the container itself.
- **The host's own entry.** The host peer is the host's catalog entry that resolves to the
  listener; when none exists, `dck host listener enable` and `dck herdr mesh` register
  `dck-host` once (Host block with the dck key and the listener's pinned host key, then
  `herdr machine add`).

### Added

- `dck doctor` reports the host's Herdr catalog (entries, dck machines mirrored, the host's own
  entry) and flags a missing host self entry when the host is a peer.

## [0.2.5] — 2026-10-11

### Fixed

- `install.sh` is executable in the repository, so the documented `./devcontainer-kit/install.sh`
  works (it was mode 644 since v0.1 and failed with "permission denied"); the rendered `dev.sh`
  runs it through `bash` in `install-dck` regardless of the mode.

## [0.2.4] — 2026-10-11

Security patch for v0.2.3 (findings of its security review). Upgrade with `dck init`
(re-renders `dev.sh` and the vendored entrypoint), `bash dev.sh rebuild`, and — if you
enabled it — `dck host listener enable` again to rewrite the listener's configuration.

### Security

- **`dev.sh` without dck** runs a preflight mirroring dck's (`up`, `build`, `rebuild` refuse
  configuration that reaches the host unless `DCK_TRUST=1`), passes dck's compose project
  name (`-p`), and creates `.env` files only from regular, non-symlinked examples, never
  through a symlink or over an existing file.
- **`install-dck`** validates the rendered tag, checks `SHA256SUMS` against a digest
  embedded at render time when known (recorded by a verified `install-dck`), and requires
  `install.sh`, `bin/dck` and every `lib/` file to be covered by the sums.
- **Host listener**: the dck key is authorized with `no-agent-forwarding,no-X11-forwarding,
  no-user-rc`; `sshd_config` adds `AllowAgentForwarding no`, `PermitUserRC no`,
  `PermitUserEnvironment no`, `PermitOpen none`, `GatewayPorts no` and keeps only
  `AllowStreamLocalForwarding local`; paths are quoted in `sshd_config` and XML-escaped in
  the launchd plist. The setup prompt (still `[Y/n]`) states that code in any running dck
  container can then open a shell on the Mac, and how to undo it.
- **Mesh**: a repository with `[herdr] mesh = false` ignores refreshes pushed by other
  repositories (marker on its state volume); labels pushed for every peer are sanitized
  and never start with `-`; aliases must start with a letter or digit and `ssh` gets `--`
  before them. `docs/SECURITY.md` states that host-catalog peers expose the host's loopback
  container inventory to dck containers.
- **`[ssh] authorized_extra`** paths never glob (validator and launcher).
- **Test hooks** are honoured only with `DCK_TEST=1`.
- **Host herdr-peers** counts as installed only with a completion marker written after the
  full verified copy; a partial tree is replaced.

## [0.2.3] — 2026-10-11

Agent mesh out of the box: agents in a dck container reach and answer agents on the host,
in the other dck containers and in the host's other loopback containers, and the reverse,
surviving `rebuild`. Interface stays 2; every new profile key is optional. Upgrade with
`dck init` (re-renders `dev.sh` and the vendored scripts), then `bash dev.sh rebuild`.

### Added

- **The host listener** (`dck host listener enable|disable|status`, macOS): a user-level
  sshd on 127.0.0.1 (default port 22033, its own ed25519 host key) that authorizes only the
  dck key, kept alive by a launchd agent. `dck setup` offers it once on a terminal and
  records the answer in the profile. Opt-in and documented as a trust boundary in
  `docs/SECURITY.md`.
- **`[host]` profile table**: `machine`, `listener = "dck" | "external" | "remote-login"`,
  `port`, `host_key`, `label`. `external` reuses a listener you already run (dck writes
  nothing on the host); `host_machine` stays as the alias of `[host] machine`.
- **Host-catalog peers** (`[mesh] external`, default on): the mesh also pushes the host's
  other Herdr machines on loopback ports 22000-22999 — for example containers another kit
  manages — pinned by the ed25519 key your `known_hosts` holds (unknown keys are skipped)
  and with their enabled/disabled state mirrored inside.
- **Refresh-all**: `dck herdr mesh` (and so `dck up`) re-applies the mesh to every other
  running dck container, so containers started earlier learn about later ones.
- **`[ssh] authorized_extra`**: public key files authorized in every container's dck block,
  for clients that log in with your own keys. Host profile only.
- **Host herdr-peers** (`dck host peers install|status`): installed by `dck setup` at the
  images' pin, verified like the images do; `dck agents` and `dck ask` use it.
  `dck doctor` reports it and coding-agents-kit (`ak`) on the host.
- **`dev.sh` without dck**: the rendered `dev.sh` runs the container verbs on plain
  `docker compose` when dck is absent, and `bash dev.sh install-dck` installs dck from the
  rendered tag, verified against that release's `SHA256SUMS`.

### Changed

- Herdr's saved machines (`~/.local/state/herdr/client`) live on the `state` volume, so
  machines registered inside a container survive `rebuild`.
- DeepWorkPlan Vim pinned to **v0.6.0** (tag, commit and installer SHA-256 from its release).

### Fixed

- Documentation audit: the host-profile docs name interface 2, `dck help` and the doctor
  docstring say interface 2, the agents layer docs name coding-agents-kit v0.3.0 installed
  from its verified tarball, and the launcher and image docs list `herdr mesh|layout`,
  `doctor --strict` and the herdr-peers checksum pin.
- The layers test counts `git clone` calls only, so an environment git shim no longer fails it.

## [0.2.2] — 2026-10-10

### Added

- **Your git SSH aliases inside the container** (`ssh_host_config`, default `true`). `dck up`
  and `dck rebuild` copy the concrete `Host` blocks of the host's `~/.ssh/config` (and its
  `Include` files) for git hosting services into the container — `HostName`, `Port`,
  `User`, the **public** half of each `IdentityFile`, and the host keys you already trust —
  so `git` with a remote such as `git@github.com-work:org/repo` uses the same key inside as
  on the host, through the host's agent. Only aliases whose key the agent holds are copied;
  on a terminal dck offers to `ssh-add` a missing one (`--apple-use-keychain` on macOS).
  Other hosts are opt-in, in the host profile only (`[ssh] host_extra`). No private key, no `ProxyCommand`/`ProxyJump`,
  no `Match` block and no loopback host ever reaches the container.

### Fixed

- Files the entrypoint writes into `~/.ssh` (the mesh, the aliases) belong to the container
  user again: `~/.ssh` is a symlink into the state volume and `chown -R` did not follow it.

## [0.2.1] — 2026-10-09

Fixes from the v0.2.0 local review. Upgrade with `dck init` (re-renders the compose agent
socket block and the vendored scripts) then `bash dev.sh rebuild`.

### Security

- **The mesh never forwards the agent.** Peers inside a container get `ForwardAgent no`;
  each container already reaches the host agent through its own socket.
- **The trust path between containers is documented and switchable.** `docs/SECURITY.md`
  now lists the agent socket (container → host) and the mesh (container → other dck
  containers) as trust boundaries. New `[herdr] mesh` (default `true`) turns the mesh off;
  the dck key is loaded into the agent only by the mesh, never into the macOS Keychain.
- **The agent socket bind never creates a host path** (`create_host_path: false`). dck
  always sets `DCK_HOST_SSH_AUTH_SOCK` itself, by Docker provider: Docker Desktop and
  OrbStack share the host agent, a native Linux engine mounts `$SSH_AUTH_SOCK`, other
  providers (colima, podman) get `/dev/null` with a note. A repository compose `.env` that
  sets it, or the bind with `ssh_agent = false`, needs `--trust`.
- On a Linux host the entrypoint no longer changes the host agent socket's group and mode.
- herdr-peers: every installed file must be listed in the release `SHA256SUMS`; symlinks
  are refused.

### Fixed

- `dck herdr mesh` pushes the peers' host keys: they are read under the `HostKeyAlias`
  dck pins with (plain or hashed), not only as `[127.0.0.1]:<port>`.
- `dck rebuild` exports the host agent socket on Linux like `dck up`.
- Commit signing is copied into the container only when it can work there (SSH signing; a
  `.pub` path becomes a `key::` literal), and the entrypoint skips signing settings that
  cannot work inside (a `.env` written by v0.2.0). openpgp signing no longer breaks every
  commit.
- The skill directories are created as the container user; v0.2.0's root-owned
  `~/.agents` / `~/.claude` are given back at the next start.
- The agents-layer opt-out lives in the service `.env` (the commented compose line was
  invalid YAML when uncommented).
- The mesh is skipped on a Linux host, where peers' loopback ports are unreachable from a
  container, instead of reporting them reachable.
- Host users with a dot (`jane.doe`) are accepted on both sides of the mesh.
- `host_machine` is documented as what it does since v0.2.0.

## [0.2.0] — 2026-10-09

**Interface 2.** A repository's container is self-contained: no shared base image.

### Changed — breaking

- **The template renders a repository's own container.** `docker/local/<service>/Dockerfile`
  starts FROM the flavour's official image pinned by digest (node 24, python 3.13 or
  debian; `base_image` in dck.toml overrides it with another digest pin) and copies the
  build steps vendored into `docker/local/<service>/dck/` (byte copies of the kit's files,
  stamped with its version). Compose passes no base image; nothing depends on
  `ghcr.io/dailybothq/devcontainer-kit-base`, whose publishing stays optional.
- **dck.toml schema v2.** A v1 file is migrated by `dck init` (interface line, `image_tag`
  removed). New keys: `base_image`, `ssh_agent`, `herdr.layout`. `--image-tag` is gone;
  `--no-digest` is accepted and ignored.
- **doctor schema v2.** `repo.kit_version` and `repo.vendored` replace `image_tag` and
  `digest_match`; drift compares the kit a repository was rendered with.
- **Agents in autonomy by default.** The agents layer installs coding-agents-kit
  **v0.3.0** from its release tarball verified against a pinned sha256 (no git clone),
  the CLIs through `ak install` (pinned and verified by ak), and turns on the `classic`
  (`claudex`, …) and `providers` (`claude-glm`, `codex-glm`, …) presets. ak launches
  agents in autonomy by default — the container is the sandbox; the template spells no
  autonomy flag and documents the `AGENTKIT_PERMISSIONS=ask` opt-out.

### Added

- **`dev.sh`**, rendered at the repository root: `bash dev.sh up` (setup on the first
  run), `shell`, `rebuild`, `herdr`, `herdr-layout`, `agents`, `ask`, … over `dck`. A
  repository's own `dev.sh` without dck markers is kept.
- **Git over SSH through the host's agent**: the Docker Desktop socket (or
  `$SSH_AUTH_SOCK` on Linux) as `SSH_AUTH_SOCK`; the git identity from `DCK_GIT_*`, which
  `dck setup` fills from the host's git config; GitHub's published host keys pinned.
  No key file, no host `~/.ssh` or `~/.gitconfig` mount.
- **Herdr both ways**: herdr-peers (verified against its release `SHA256SUMS`) and Herdr's
  skill in every image, linked into each agent's skills; `dck herdr mesh` (run by
  `dck up`) makes the other dck containers — and the host, with `host_machine` — reachable
  from inside with no private key in the container; `dck agents` / `dck ask`.
- **The standard Herdr sidebar** inside every container — Home · Editor · Development
  (server | tests) · Agents (Agent 1..4) — via `dck herdr layout [--keep|--reset]`, run
  by `dck up` with `--keep`; `[herdr] layout = "none"` turns it off.
- **The `dck-dockerfile` skill** (`dck --skill dck-dockerfile`): detect or ask the
  runtime, ports and agents, render, validate with a real build, report.
- Non-login shells (docker exec, editor terminals) get the user tool PATH (`ak`, `nvim`).
- README: the **acceptance checklist** a repository verifies after `bash dev.sh up`.

## [0.1.6] — 2026-10-09

Interface stays **1**. Editor plugins pinned to commits (deepworkplan-vim v0.5.1).

### Changed

- Base images install deepworkplan-vim **v0.5.1** (commit
  `04dcbcbdb9760082915f3c17ac28a910983e7b0e`, installer SHA-256 `b0c531f6…`). The release
  pins every plugin and pckr to a commit in `pckr/lockfile.lua`, and `--strict` now fails the
  build when a plugin is away from its pin, so two builds of the same pins install the same
  plugin code. The "plugins come from each default branch" known limit is closed
  (`docs/SECURITY.md`).

## [0.1.5] — 2026-10-09

Interface stays **1**. Editor install through deepworkplan-vim's official installer.

### Changed

- Base images install deepworkplan-vim **v0.5.0** (commit
  `3b9c79a52f50ee7d3fd103e31c1a307bad661e59`) through its official installer instead of a
  hand-written clone: the versioned release asset (the file vim.deepworkplan.com serves) is
  checked against a pinned SHA-256 (`DWP_VIM_INSTALLER_SHA256`) and run as `dev` with
  `--version 0.5.0 --skip-packages --strict`, in its own image layer (`images/common/editor.sh`).
  Plugins are now installed at build time — `nvim` starts ready — instead of on first launch.
  The image keeps its own system-wide, SHA-256-pinned Neovim (the installer's `--nvim` is not used).
- Every flavour adds `tar`, `gzip`, `lua5.4` and `fontconfig`; `node-24` and `debian` add
  `python3-venv`; `python-3.13` and `debian` add Debian's `nodejs`/`npm` (for the editor's
  plugins only).
- The agents layer installs the pinned Node when `node` is missing **or older than the pinned
  major**, so Debian's `nodejs` never stands in for it.
- Image sizes grow with the baked-in plugins and their runtime dependencies (arm64, uncompressed):
  `node-24` 840 → 956 MB, `python-3.13` 732 → 1074 MB, `debian` 689 → 999 MB (most of the last
  two is Debian's `nodejs`/`npm`).
- The baked-in plugins are **not pinned** by this repository (deepworkplan-vim lists them without
  commits); `docs/SECURITY.md` records it as a known limit.
- Contributor tooling (not shipped): the repository vendors DeepWorkPlan **v7.0.1** and the AI
  Diff Reviewer **v3.3.0** (local review with `.review/extension.md`), adds the `dwp-*` command
  delegators, agent personas and catalogs under `.agents/`, and tracks the addon registry
  `.dwp/config.json`.

## [0.1.4] — 2026-10-09

Interface stays **1**. Editor pin only.

### Changed

- Base images install deepworkplan-vim **v0.4.1** (was v0.3.1), verified against commit
  `13db97c9691a864dadebf649fb656a55e6273f91`, matching the ecosystem's editor pin.

## [0.1.3] — 2026-10-09

Interface stays **1**. Repository standard and a doctor fix; no behaviour change for
`dck.toml`, the template or the images.

### Added

- Public-repository standard: `CONTRIBUTING.md`, `SECURITY.md` (policy), `CODE_OF_CONDUCT.md`
  (Contributor Covenant 2.1), `CLAUDE.md` → `AGENTS.md`, issue and pull-request templates,
  `CODEOWNERS`, Dependabot for GitHub Actions.
- `scripts/check-public-hygiene.sh` + `.public-hygiene-allow`: fails CI on personal paths,
  private names and secret patterns in tracked files (never printing the match).
- Release workflow: an annotated tag publishes the GitHub release with this CHANGELOG's
  notes and `SHA256SUMS` (`scripts/release-sums.sh`, `scripts/release-notes.sh`).

### Fixed

- `dck doctor` no longer reports a stuck Docker engine (`docker info` exiting 0 with its
  error on stdout) as an answering daemon.

## [0.1.2] — 2026-10-09

Interface stays **1**. Use it instead of 0.1.1 when you enable the agents layer.

### Fixed

- Agents layer: `ak install <cli>` for npm-distributed CLIs (codex, pi, cline …)
  failed for the dev user because Node's global prefix is root's. The layer now sets
  the dev user's npm prefix to `~/.local` (`~/.npmrc`, already on the login PATH).
  Verified in real python-3.13 and node-24 images with coding-agents-kit v0.1.1.
- `dck doctor` no longer reports the Docker daemon as answering when `docker info`
  exits 0 with empty fields.

## [0.1.1] — 2026-10-09

Security release; **use it instead of 0.1.0**. Interface stays **1** (additive).

### Security

- `dck ssh` and Herdr machines connect (and forward your SSH agent) only to
  127.0.0.1; a repository-chosen `bind` can no longer redirect the agent. The SSH
  include accepts only `HostName 127.0.0.1`.
- `up`/`start`/`build`/`rebuild` refuse a repository configuration that reaches the
  host (`initializeCommand`, `privileged`, `cap_add`, host namespaces, devices, the
  Docker socket, bind mounts or compose files outside the repository) unless you pass
  `--trust` / `DCK_TRUST=1`.
- `dck init` backups are created with `O_EXCL|O_NOFOLLOW` (never through a planted link).
- The compose overlay quotes values and escapes `$` (no YAML injection, no host
  variable interpolation into the container).
- `.env` handling acts only on regular files inside the repository; symlinked
  `.env`/compose/devcontainer files are ignored or refused; a compose project not
  named after the repository is announced.
- The entrypoint keeps the Herdr config owned by the dev user and writes its temp
  file with `O_EXCL|O_NOFOLLOW`; the images workflow passes the tag through `env`.

### Changed

- The agents layer pins coding-agents-kit **v0.1.1** (its v0.1.0 had a symlink-escape
  issue; ecosystem contract amendment A2).

### Fixed

- A dck key whose `.pub` was deleted is repaired with `ssh-keygen -y`.

## [0.1.0] — 2026-10-09

Superseded by 0.1.1 (security fixes).

First public release. **Interface 1** (`dck doctor --json` → `"interface": 1`).

### Added

- `dck` / `devcontainer-kit` launcher: `init`, `setup`, `up`, `down`, `stop`, `start`,
  `restart`, `ps`, `logs`, `shell`, `exec`, `build`, `rebuild`, `config`, `ports`,
  `ssh`, `doctor`, `herdr add|status|repair|remove`, `--skill`, `--version`.
  `devcontainer up/exec` when `@devcontainers/cli` is installed, compose otherwise;
  never `--remove-orphans`; refuses the directory-name default compose project.
- Dev Container template rendered by `dck init`: managed blocks, owned
  `devcontainer.json` keys and in-place `dck.toml` edits; diff + consent + backup
  for any change to an existing file; base image pinned by digest.
- `.devcontainer/dck.toml` and the host profile `~/.config/dck/profile.toml`, with
  JSON Schemas (`docs/schema/`).
- Base images `ghcr.io/dailybothq/devcontainer-kit-base:{python-3.13,node-24,debian}-v0.1.0`
  (amd64 + arm64): gh, Herdr, Neovim + deepworkplan-vim, hardened sshd without baked
  host keys, user `dev` (uid 1000) — no coding-agent CLI. One pin file with SHA-256
  checksums; nightly rebuilds as `<flavour>-nightly`.
- Entrypoint library: `dck_persist`, `dck_env_profile`, `dck_sshd`,
  `dck_authorize_keys`, `dck_herdr_config`, `dck_repo_hook`, `dck_layer_persist`,
  `dck_start`.
- Opt-in layers: `agents` (coding-agents-kit `v0.1.0`, one volume per CLI home),
  `dailybot`, `editor`.
- Herdr machines through a provenance-guarded `~/.ssh/config.d/dck` include with
  agent forwarding and per-alias host keys.
- `dck doctor --json` (schema `dck-doctor-v1`): runtime, repo, layers, ssh, herdr, drift.
- Agent skill `dck` (`skills/dck/SKILL.md`).
- `install.sh` (idempotent, `--no-rc`, `--uninstall`), test suite with unit scopes
  and a real-Docker integration scope, CI on Ubuntu and macOS.

[Unreleased]: https://github.com/DailybotHQ/devcontainer-kit/compare/v0.3.2...HEAD
[0.3.2]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.3.2
[0.3.1]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.3.1
[0.3.0]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.3.0
[0.2.11]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.11
[0.2.10]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.10
[0.2.9]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.9
[0.2.8]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.8
[0.2.7]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.7
[0.2.6]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.6
[0.2.5]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.5
[0.2.4]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.4
[0.2.3]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.3
[0.2.2]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.2
[0.2.1]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.1
[0.2.0]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.2.0
[0.1.6]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.6
[0.1.5]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.5
[0.1.4]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.4
[0.1.3]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.3
[0.1.2]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.2
[0.1.1]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.1
[0.1.0]: https://github.com/DailybotHQ/devcontainer-kit/releases/tag/v0.1.0
