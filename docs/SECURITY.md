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
| the container → your host | **no** | the container reaches the host only through what you publish (loopback ports) and what you forward (your SSH agent, for the session you open) |
| other machines on your network → the container | **no** | nothing listens beyond 127.0.0.1 unless `bind` says so |
| the network → the image build | **no** | every base-image download is pinned and checksum-verified; the opt-in layers pin coding-agents-kit by tag and resolve the Dailybot CLI's dependencies with uv (see Supply chain) |

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
  build time by its own installer (`--strict` checks they are present, not
  their content) from **each plugin's default branch**: deepworkplan-vim pins
  none of them and this repository cannot, so two builds of the same pins may
  differ and a compromised plugin branch on build day would land in the
  published image (the trade-off of an editor that starts ready, open for
  the owner to accept or reverse;
  pinning belongs upstream, as a per-plugin commit or a lockfile checked here); Debian's `nodejs`/`npm` in `python-3.13` and `debian` come
  from the distribution's signed archive; coding-agents-kit is
  pinned by tag (its installer then installs each CLI through the vendor's
  channel); the Dailybot CLI's dependencies are resolved by uv at build time.

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

## Coding agents

The base images contain no coding-agent CLI. The opt-in agents layer installs
coding-agents-kit, which is **pass-through by default**: no permission-bypass
flag is injected by dck, the template or the layer. Autonomy is the kit's
explicit opt-in (`ak <kind> --auto` or `AGENTKIT_PERMISSIONS=auto`). Choosing it
inside a container is reasonable when the container is your sandbox — and it
remains your decision.

## Reporting

Report a vulnerability privately through GitHub's "Report a vulnerability"
(Security tab of DailybotHQ/devcontainer-kit). Please do not open a public
issue for it.
