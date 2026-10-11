# Security — devcontainer-kit

devcontainer-kit writes a container setup into repositories, runs a root
entrypoint, builds images from the network and wires SSH between your host and
your containers. This document states what it defends, how, and what it
deliberately does not. Every default below is asserted by the `security` test
scope (plus the `images`, `entrypoint`, `launcher` and `herdr` scopes).

## Threat model

**Assets.** Your host account (home directory, SSH keys, shell rc files), the
secrets you put in `docker/local/**/.env`, the integrity of the tools installed
in your images, and your Herdr machines.

**Trust boundaries.**

| From → to | Trusted? | Consequence |
| --- | --- | --- |
| you → dck on your host | yes | dck acts with your permissions, inside the write scope below |
| the repository's files → dck | **no** — you may run dck on a repository you just cloned | dck parses them (JSONC, TOML, compose); never writes or reads secrets through a symlink they plant; never imports a module from them; never forwards your agent to an address they choose |
| the repository's container configuration → your Docker daemon | **only after review** | `up`/`start`/`build`/`rebuild` hand the repository's compose file and `devcontainer.json` to Docker (and the devcontainer CLI). Anything in them that reaches the host — `initializeCommand`, `privileged`, `cap_add`, host namespaces, devices, the Docker socket, bind mounts outside the repository, a compose file outside it — is refused until you pass `--trust` (or `DCK_TRUST=1`). dck-rendered setups contain none of these. Treat `--trust` like "trust this folder" in an editor |
| the repository → its own container | yes, by design | the container exists to run the repository's code; its hook and its Dockerfile run there, with the dev user's sudo |
| the container → your host | **no** | the container reaches the host through what you publish (loopback ports) and through your SSH agent: forwarded on the sessions you open, and — with `ssh_agent = true`, the default — its socket mounted for the container's lifetime. Code in the container can *use* the agent's keys (sign, never read them) while it runs: for git that is the point; for sensitive keys use `ssh-add -c` (confirm each use) or set `ssh_agent = false`. With the host as a mesh peer (`[host] machine = true`) that also means a shell on the host — see the next row |
| a dck container → your host's shell | **only with the host listener (opt-in)** | `dck host listener enable` (or a yes to the one question `dck setup` asks) runs a user-level sshd on **127.0.0.1** only (default port 22033, its own ed25519 host key, `AllowUsers` you, no passwords, no PAM, no root, no TCP forwarding (`PermitOpen none`), no agent forwarding, no `~/.ssh/rc`, only the local stream forward Herdr's client uses) that authorizes **only the dck key** (`no-agent-forwarding,no-X11-forwarding,no-user-rc`), kept alive by a launchd agent. While it runs, any process that can use the dck key through your agent — code in any running dck container with the agent socket — can open a shell on your host as you. That is what lets agents inside answer agents on the host. Turn it off with `dck host listener disable` (removes the launchd agent and its files), `[host] machine = false`, `ssh_agent = false` per repository, or `ssh-add -d ~/.config/dck/ssh/id_ed25519`. With `listener = "external"` dck reuses a listener you already run and writes nothing on the host; with `"remote-login"` it relies on the system sshd and your own `authorized_keys` |
| one dck container → another dck container | **only through the mesh** | `[herdr] mesh = true` (the default; Docker Desktop only) loads the dck key into your agent so agents inside can ask agents in the other containers. Every container with the agent socket can then log in to every other dck container (they all authorize the dck key) and read what it holds (`.env`, logins). Only run untrusted repositories with `mesh = false` and `ssh_agent = false`, and remove the key from the agent (`ssh-add -d ~/.config/dck/ssh/id_ed25519`). The mesh never forwards the agent further (`ForwardAgent no`) |
| a dck container → your agent accounts | **only with `[agents] host_profiles` (opt-in, host profile)** | off by default, and only your host profile can turn it on — a repository's `dck.toml` cannot. When on, `dck up` binds into the container the host's ak profiles of the CLIs the repository installs (read-write), the host's Codex home (read-write) and an allow-listed env file (read-only). Code in the container can then act as you on those accounts and read those credentials while it runs. See [Host accounts](#host-accounts-agents-host_profiles) |
| other machines on your network → the container | **no** | nothing listens beyond 127.0.0.1 unless `bind` says so |
| the network → the image build | **no** | every base-image download is pinned and checksum-verified; the opt-in layers install coding-agents-kit from its sha256-verified release tarball and resolve the Dailybot CLI's dependencies with uv (see Supply chain) |

**Out of scope.** A malicious repository *inside its own container* (it owns
that container by design), a compromised Docker daemon or kernel, a host
account already compromised, and supply-chain compromise of the upstream
projects whose releases we pin (we pin, we do not audit them).

## Defaults and how they are enforced

### Network exposure: loopback only

Every port the template publishes binds `127.0.0.1` (`"127.0.0.1:<port>:<port>"`,
sshd as `"127.0.0.1:<ssh_port>:22"`). Only an explicit `bind = "<address>"` in
`dck.toml` widens it, and `dck doctor` then lists it as a problem. Whatever
`bind` says, `dck ssh` and Herdr machines connect **only to 127.0.0.1**: your
agent is forwarded on that connection, so its destination never comes from
repository-controlled configuration (a `bind` that is neither loopback nor
`0.0.0.0` makes them refuse, exit 5). Inside the
container sshd listens on the container network: other containers on the same
compose network can reach port 22, where only public-key login for the dev
user is accepted.

### No privilege escalation from the template

The template never adds `cap_add`, `privileged`, the Docker socket,
`security_opt`, host namespaces, or mounts of your home, `~/.ssh` or
`~/.gitconfig`. If a repository needs one of these, that is the repository's
own edit, outside dck's managed blocks, and its own decision.

### SSH: agent forwarding, never key copies

- dck creates a **dedicated** key, `~/.config/dck/ssh/id_ed25519` (0600, in a
  0700 directory). Only its public half is sent to containers (the
  `DCK_AUTHORIZED_KEYS` variable, or stdin of `dck_authorize_keys --add`).
- Your own keys never enter a container: `dck ssh` and the Herdr include use
  **agent forwarding** for the session you open (`ForwardAgent yes`,
  `IdentitiesOnly yes`). Verified in a real container: the forwarded key is
  usable inside and no file inside contains it. While a session is open, code
  in the container can *use* your agent (not read keys) — prefer an agent that
  confirms each use (`ssh-add -c`) for sensitive keys.
- No "authorize every `~/.ssh/*.pub`": the container trusts exactly the dck key.
- **The agent socket.** With `ssh_agent = true` the template binds the host
  agent's socket (Docker Desktop's `/run/host-services/ssh-auth.sock`, or
  `$SSH_AUTH_SOCK` on Linux, exported by `dck up` and `dck rebuild`) at
  `/run/dck/ssh-agent.sock`, never a key file, never `~/.ssh`. The bind never
  creates a missing host path (`create_host_path: false`); with no agent on a
  Linux host, `/dev/null` is mounted instead. dck always sets
  `DCK_HOST_SSH_AUTH_SOCK` itself, and `--trust` is required when a
  repository's compose `.env` tries to set it. The entrypoint gives the dev
  user access only to Docker Desktop's root-owned socket; a Linux host's own
  socket is left as it is.
- **Your SSH aliases.** With `ssh_host_config = true` (the default), `dck up` copies the
  concrete `Host` blocks of your `~/.ssh/config` **for git hosting services** into the
  container with only the **public** half of each key and the host keys you already
  trust, so `git` with an alias such as `github.com-work` picks the same key through your
  agent. No private key, no `ProxyCommand`/`ProxyJump`, no `Match` block and no loopback
  host is copied, and an alias is copied only when your agent already holds its key (on
  a terminal dck asks before running `ssh-add`; never without one, never the whole
  Keychain). Other hosts need `[ssh] host_extra` in your host profile (never a repository's
  `dck.toml`), because any process in any container with the agent socket can use the
  agent's keys. Turn it off with
  `ssh_host_config = false`.
- **The mesh.** `dck herdr mesh` loads the dck key into your agent (never into
  the macOS Keychain) and pushes only public data into the container: peer
  aliases, ports, users, labels and pinned host keys. Peers are reached with
  strict host keys and `ForwardAgent no`. With `[mesh] external = true` (the
  default) it also pushes the host's other Herdr machines on loopback ports
  22000-22999, pinned by the ed25519 key **your** `known_hosts` already holds
  (a peer with no known key is skipped, never trusted on first use inside).
  Those host-catalog peers tell every dck container the **inventory of your
  host's loopback containers** (aliases, ports, users, labels, public host
  keys); turn it off with `[mesh] external = false`. Since v0.2.6 the mesh also
  copies the matching entries of your host's Herdr catalog — machine ids,
  labels, aliases, sessions, enabled state — into each container's Herdr
  (replies need identical ids); only entries the container can reach are
  copied, never another host's. A repository whose
  `dck.toml` sets `[herdr] mesh = false` is recorded as such in its state
  volume at `dck up`, and refreshes pushed by another repository's
  `dck herdr mesh` are ignored there.
  `[ssh] authorized_extra` (host profile only) adds the public keys you list to
  every container's dck block, so clients that log in with your own keys (for
  example containers another kit manages) can reach dck containers. See the
  trust boundaries above for what it opens.
- **Host keys** are generated at runtime into the per-project `state` volume
  (ed25519, 0600, directory 0700 root), never baked into an image (the build
  deletes the package's keys and generates none), so one image never ships one
  private key to everyone, and a rebuild keeps the identity clients pinned.
- `StrictHostKeyChecking accept-new`: a new container is trusted on first use,
  a changed key is refused. Host keys are recorded in dck's own known_hosts,
  keyed by alias; `~/.ssh/known_hosts` never grows.
- The container's sshd: public key only, no root, no passwords, no
  keyboard-interactive, `PermitUserEnvironment no`, `AllowUsers <dev user>`,
  local forwarding only, `GatewayPorts no`, no X11, no tunnels.

### Secrets

- `.env` files are created from their examples at **0600** (never overwritten,
  never written through a symlink); `dck setup` narrows an existing readable
  one to 0600 and says so. The template's `.gitignore` block keeps them out of
  git.
- No value of an environment variable is ever printed or logged by dck or the
  entrypoint. `dck doctor` reports the *names* of variables that are set.
- The entrypoint's `~/.dck/env.sh` (the container's environment for SSH
  sessions) is created 0600 with `O_EXCL|O_NOFOLLOW` and renamed atomically:
  no world-readable window, no write through a planted symlink.
- Nothing secret is embedded in an image: the base images contain no
  credential, and the layers install software only.

### Host accounts (`[agents] host_profiles`)

Credential sharing is **opt-in** and host-side only. With
`[agents] host_profiles = true` in `~/.config/dck/profile.toml`, `dck up` adds a
second runtime compose overlay (`$TMPDIR/dck-<uid>/<project>-agents.yml`, 0600 in a
0700 directory you own — never written into the repository) that binds:

- `$AGENTKIT_PROFILES_DIR/<cli>` (default `~/.local/share/agentkit/profiles/<cli>`)
  for each CLI in the repository's `[agents] clis` with file-portable profiles —
  claude, codex, pi, cline, grok, opencode — read-write, and points
  `AGENTKIT_PROFILES_DIR` at them. cursor (and antigravity) profiles are never shared:
  they hold absolute host symlinks into your home. The whole `AGENTKIT_HOME` is never
  mounted: it also holds the host's ak program and would shadow the image's pinned ak;
- the host's Codex home (`$CODEX_HOME`, else `~/.codex`, the Codex `@default` login),
  read-write, when codex is installed;
- an env file generated on the host, `~/.config/dck/agents/<project>.env` (0600 in a
  0700 directory), read-only, with `AGENTKIT_ENV` pointing at it. It holds **only**
  `CLAUDE_CODE_OAUTH_TOKEN`, `CLAUDE_CODE_OAUTH_TOKEN_*` and the names listed in
  `[agents] host_env_keys`, copied from the host's ak env file (and dck's
  environment) as plain single-line values; shell code, quotes and multi-line values
  are skipped by name. This file is the one place dck writes a credential value, on
  your host, for your user only; turning the option off removes it.

Values never appear in a compose file, in docker's argv, in dck's output or in
`dck doctor` (names only). Every mount uses `create_host_path: false`: a missing host
path fails the start instead of being created.

**Read-write sharing races.** The Codex `auth.json` (and a CLI's session files) are
shared read-write: Codex refreshes its token in place, so keep **one active writer
per account** — the same account used at once on the host and in a container, or in
two containers, can lose a refresh and log one of them out. Prefer a dedicated ak
profile per place that runs agents in parallel. Claude's long-lived token
(`claude setup-token`) is inference-only and never refreshed, so sharing it has no
race; a Claude login kept in the macOS keychain cannot reach a container — `dck doctor`
names such profiles and the variable to store the token under.

**Ownership.** On Docker Desktop and OrbStack the bind mounts appear owned by the
container user. On a native Linux engine they keep the host's uid: the option works
when your uid is 1000 (the container user's), like the SSH agent socket.

### Unattended agent launches

A new agent must not stall at a first-run screen nobody is watching. With autonomy on
(the default) the entrypoint marks the workspace (the app path, `/app` by default) as
trusted at each start, for the CLIs the repository installs:

| What | Container's own CLI homes | Shared host profiles |
| --- | --- | --- |
| Folder trust for the app path (Claude `projects[<path>].hasTrustDialogAccepted`, Codex `[projects."<path>"] trust_level = "trusted"`) | yes | yes — an entry for a container path such as `/app` is inert on the host |
| Claude's bypass-permissions acknowledgement (`skipDangerousModePermissionPrompt`, `bypassPermissionsModeAccepted`) and onboarding | yes — the container is the sandbox you chose for autonomy | **never** — those profiles also drive your Claude on the host, where a human acknowledges it once per profile |

With `AGENTKIT_PERMISSIONS=ask` (in the service `.env` or in ak's env file) neither is
written. Files are changed only when a key is missing and replaced atomically; an
invalid file is left alone. The host's Codex home receives no container skill links.

### Auth volumes per project

Named volumes (`state`, one per coding-agent CLI, `agentkit`) are declared by
compose without `external`, so compose prefixes them with the project name:
logins in one repository's container are not shared with another's. Sharing is
possible only by an explicit edit outside the managed blocks.

### Supply chain

- Base images pinned by tag **and** digest; gh, Herdr, Neovim and (for the
  agents layer) Node pinned by version **and SHA-256** per architecture;
  deepworkplan-vim by tag, commit **and** installer SHA-256; uv and the
  Dailybot CLI wheel by version and SHA-256 — all in one file,
  `images/versions.env`. A `fetch()` verifies every download before use (the
  editor's installer is downloaded, verified, then run — never piped into a
  shell).
- Repositories pin the base image by digest in compose (`dck init` resolves
  it); `dck doctor` reports a tag-only pin and a local image that differs from
  the pin.
- GitHub Actions are pinned by commit SHA. Only the image workflow can write
  packages. Images are built with provenance and an SBOM.
- Known limits: the Neovim checksums were computed at pin time (the release
  publishes none); deepworkplan-vim's plugins (about 40) are installed at
  build time by its own installer, each at the commit the pinned release fixes
  in `pckr/lockfile.lua` (from v0.5.1; `--strict` fails the build when a plugin
  or pckr is away from its lock entry), so two builds of the same pins install
  the same plugin commits; those commits are fetched from each plugin's
  upstream repository and verified by commit hash, not by a separate checksum
  or signature; Debian's `nodejs`/`npm` in `python-3.13` and `debian` come
  from the distribution's signed archive; coding-agents-kit is
  pinned by tag (its installer then installs each CLI through the vendor's
  channel); the Dailybot CLI's dependencies are resolved by uv at build time.

### `dev.sh` without dck

The rendered `dev.sh` can run the container verbs on plain `docker compose`
when dck is not installed. It keeps dck's guarantees there: `up`, `build`
and `rebuild` run a preflight that refuses `privileged`, `cap_add`, the
Docker socket, host namespaces, `security_opt`, `devices`, bind mounts of
host paths outside the repository, a `.env` that redirects the agent socket
and `initializeCommand` — unless `DCK_TRUST=1`; compose gets dck's project
name (`-p`), so it never acts on another checkout; `.env` files are created
only from regular, non-symlinked examples, never through a symlink and never
over an existing file. `bash dev.sh install-dck` validates the rendered tag,
checks the release `SHA256SUMS` against the digest embedded at render time
when the rendering dck knew it (a dck installed by `install-dck` records it),
requires the installer, `bin/dck` and every `lib/` file to be covered, and
verifies the clone against it before running `install.sh --no-rc`.

### Test hooks

Variables that swap a binary or answer a prompt in tests (`DCK_HOST_SSHD`,
`DCK_LAUNCHCTL`, `DCK_LAUNCH_AGENTS_DIR`, `DCK_HOST_LISTENER_ANSWER`,
`DCK_PEERS_CURL`, `DCK_VERSIONS_ENV`, …) are honoured only when
`DCK_TEST=1`, which only the test runner sets.

### Code hygiene on the host

- Python always runs in isolated mode (`python3 -I`): a `json.py` or
  `shlex.py` in the repository can never shadow a standard-library module —
  including in the root entrypoint, whose working directory is the
  repository mount.
- `dck init` refuses symlinked targets and any target that resolves outside
  the repository; it changes existing files only after showing the diff and
  getting consent, keeping a backup created with `O_EXCL|O_NOFOLLOW` (a
  planted backup name is never written through).
- `.env` handling (`setup`, `up`, `doctor`) acts only on regular files inside
  the repository: symlinked files or directories and names with control
  characters are skipped; a symlinked `devcontainer.json` or compose file is
  refused.
- The compose overlay quotes every value and escapes `$`, so a repository
  cannot inject compose keys or pull host variables (e.g. a token) into the
  container through `containerEnv` or `mounts`.
- A compose project not named after the repository (from `COMPOSE_PROJECT_NAME`
  or `name:`) is announced on every verb, since `down`/`stop` act on that
  project's services.
- No `eval` of command output in the shell code; values from the python side
  are read line by line into an allow-listed set of variables.
- The compose overlay lives in a 0700 directory dck must own (a planted or
  symlinked directory is refused) and is written 0600.
- `dck init` refuses `$HOME` and `/`; `install.sh` refuses to replace a
  directory that is not a dck install.

## Deliberate trade-offs

| Choice | Why |
| --- | --- |
| The dev user has passwordless sudo | a development container is the developer's machine; packages and debugging need root |
| `git config --system safe.directory '*'` in the images | the repository is bind-mounted with the host's ownership; without it git refuses every repository |
| The dck SSH key has no passphrase | it is only ever authorized inside dck containers on loopback; your real keys stay in your agent |
| `host.docker.internal` resolves to the host | standard Docker behaviour, needed to reach host services; the container still only reaches what the host exposes |
| Herdr config forces `allow_nested = true` | the container's Herdr runs inside the host's |
| The repository hook runs at every start | it is the repository's own code in its own container |
| `--remove-orphans` is never passed | protecting shared projects outweighs orphan cleanup |
| `--trust` is per invocation | an explicit, reviewable decision each time a host-reaching configuration is started |
| The host listener is opt-in, asked once | a shell on your host from any dck container is a real widening; the question says so, the answer is recorded in your profile, and `dck host listener disable` undoes it |
| `[agents] host_profiles` is off by default and host-only | sharing your agent accounts with a container is a real widening; you turn it on once in your host profile, a repository can never ask for it, and only the CLIs that repository installs are shared |
| The mesh is on by default | agents inside a container asking agents in the other containers is the point of the Herdr integration; with it, every dck container can log in to the others (see the trust boundaries). Untrusted repositories: `[herdr] mesh = false`, `ssh_agent = false` |

## Coding agents

The opt-in agents layer installs coding-agents-kit from its release tarball,
verified against the pinned sha256, and the CLIs through `ak install`, which
pins and verifies each one. **Autonomy is the default:** every agent launched
through `ak` runs with its CLI's own autonomy flag, so it can run any command
the container's user can, without asking. Autonomy is meant for disposable or
sandboxed environments, and the development container is exactly that: its
only writable host path is the repository (plus, with `[agents] host_profiles`,
the shared agent profiles and Codex home), it holds no host private key (SSH
goes through the host agent) and its ports bind to loopback. Agents start
unattended: the workspace is pre-trusted (see
[Unattended agent launches](#unattended-agent-launches)). dck, the template
and the layers never spell an autonomy flag; they live only in
coding-agents-kit. To have agents ask before acting, set
`AGENTKIT_PERMISSIONS=ask` in `docker/local/<service>/.env`, or
pass `--ask` to one launch; the opt-out always wins. (The compose block that
lists the agents layer is reconciled by `dck init`, so the opt-out lives in the
service `.env`, which is yours.)

## Reporting

Report a vulnerability privately through GitHub's "Report a vulnerability"
(Security tab of DailybotHQ/devcontainer-kit). Please do not open a public
issue for it.
