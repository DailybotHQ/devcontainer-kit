# The container as a Herdr machine

[Herdr](https://herdr.dev) can show several machines in one window: your host
and any SSH machine. dck registers a repository's container as one, so its
panes, agents and workspaces live next to the host's.

```toml
# .devcontainer/dck.toml
ssh_port = 22040      # the container's sshd, published on 127.0.0.1 only
[herdr]
machine = true        # register on `dck up`
label = "{repo}"      # the sidebar label ({repo} {service} {project} {user})
```

```bash
dck up              # starts the container, then registers it (when machine = true)
dck herdr status    # include, registration, sshd, remote server
dck herdr repair    # fixes a client stuck on "reconnecting"
dck herdr remove    # unregisters it and drops its SSH alias
```

## Identity: the SSH alias

The machine **is** its SSH alias, `<alias_prefix><repo-slug>` (`dck-myrepo`
by default; the prefix comes from the host profile, [config.md](config.md)).
dck defines it in a generated include, `~/.ssh/config.d/dck`:

```
# dck-provenance: v1
# >>> dck:dck-myrepo >>>
Host dck-myrepo
  HostName 127.0.0.1
  Port 22040
  User dev
  IdentityFile "~/.config/dck/ssh/id_ed25519"
  IdentitiesOnly yes
  ForwardAgent yes
  StrictHostKeyChecking accept-new
  HostKeyAlias dck-myrepo
  UserKnownHostsFile "~/.config/dck/ssh/known_hosts"
  ServerAliveInterval 30
# <<< dck:dck-myrepo <<<
```

and adds `Include config.d/dck` once at the top of `~/.ssh/config` (OpenSSH
applies an `Include` before the first `Host` to every host). Herdr includes
your SSH config, so `herdr machine add --label <label> dck-myrepo` reaches the
container through it.

- **Agent forwarding, never key copies.** The dedicated dck key
  (`~/.config/dck/ssh/id_ed25519`) only proves *you* to the container's sshd;
  its public half is the only thing sent to the container. Your own keys stay
  in your agent on the host and are used from inside through forwarding
  (verified: `ssh-add -l` inside lists the host key; no file in the container
  contains it).
- **No `known_hosts` growth.** Host keys go to `~/.config/dck/ssh/known_hosts`,
  keyed by alias (`HostKeyAlias`), so a port later reused by another
  repository never collides and `~/.ssh/known_hosts` is untouched.
- **The host key is pinned from the container itself.** `dck herdr add` (and `dck up`
  with Herdr on, and `dck ssh`) reads the key's public half through `docker exec` and
  pins it under the alias. It lives on the `state` volume and survives rebuilds; after
  that volume is removed, the new key is re-pinned with a note. A key dck cannot read
  (an image older than v0.3.1) falls back to `accept-new`: a changed key is refused,
  and the error names the fix,
  `ssh-keygen -R dck-myrepo -f ~/.config/dck/ssh/known_hosts`.
- **The include is dck's alone.** It starts with a provenance header; dck
  refuses to write a `config.d/dck` that lacks it, or one that is a symlink.
  One block per repository; `dck herdr remove` drops only its own.

## What each verb does

**`add`** — requires a running container and `ssh_port`. Creates the dck key if
needed, writes the include block, authorizes the public key inside the
container (`dck_authorize_keys --add` through the entrypoint library — repairs
a container started by an editor plugin, which does not pass
`DCK_AUTHORIZED_KEYS`), **waits** up to `DCK_HERDR_WAIT` seconds (default 30)
for `ssh <alias> true` to succeed, then registers the machine. Idempotent: an
existing registration is kept, renamed if the label changed and re-enabled if
it was disabled. Finally it checks whether the remote Herdr server answers
(`ssh <alias> herdr status server`); a server that has not started yet is
reported, not an error — Herdr starts it when it connects.

**`status`** — the include block, the registration (id, label,
enabled/disabled), whether sshd answers through the alias, whether the remote
server answers, and the repair hint when the machine is registered and
reachable but its server is silent.

**`repair`** — re-asserts the include and the key, waits for sshd, then
`herdr machine disable <id>` and `herdr machine enable <id>`: the known fix for
a client stuck on "reconnecting". An unregistered machine is added instead.

**`remove`** — `herdr machine remove <id>` (the container's own Herdr
sessions keep running) and the include block.

`dck up` runs `add` after starting the container when `machine = true` and
`herdr` is installed on the host; without Herdr it says so and carries on.

## What dck never does

- edit Herdr's own files (`~/.config/herdr`, `~/.local/state/herdr`, its
  endpoint catalogs) — it only calls the `herdr` CLI;
- copy a private key into a container unless you opt in with `[ssh] copy_keys`
  (host profile; [SECURITY.md](SECURITY.md#host-ssh-keys-ssh-copy_keys)), or authorize
  "every `~/.ssh/*.pub`";
- add a listener or an `authorized_keys` entry on your host **unless you ask
  for it**: the dck host listener (below) is opt-in — `dck setup` asks once,
  `dck host listener enable|disable` turns it on and off.

## Inside the container

The base images ship Herdr (pinned, `/usr/local/bin/herdr`, on the PATH of the
non-login SSH session the Herdr client uses) and a seeded config with login
shells, `new_cwd = <workspace>` and `allow_nested = true`, kept current by the
entrypoint's `dck_herdr_config` ([entrypoint.md](entrypoint.md)).

## Agents inside talking to agents outside (`dck herdr mesh`)

An agent in the container can list and ask Herdr agents on the host and in
other dck containers, and get the reply back, through
[herdr-peers](https://github.com/DailybotHQ/herdr-peers). The image installs
it from its tag's source, verifying every file against that release's
`SHA256SUMS`, which is itself pinned by sha256 in `versions.env`. Herdr's
own skill, matching the pinned binary, is installed next to it. At every
start the entrypoint links both skills into each agent's skill directory
(`~/.agents/skills`, `~/.claude/skills`, and the others that exist).

**Reply route for every pane.** After registering the container (and on every mesh),
dck writes the container's id in this host's Herdr catalog into it, and its login profile
exports it as `HERDR_PEERS_SELF`: asks from Codex panes, which cannot discover that id
themselves, then get their reply routed. `dck doctor` shows both ids (`herdr self`) and
flags a mismatch; a removed machine clears it.

`dck up` runs `dck herdr mesh` after `dck herdr add` (unless `[herdr] mesh =
false`) — and so do `dck rebuild`, `dck start` and `dck restart`, so a container built
from scratch (its volumes removed) knows the host and its peers without a manual
`dck herdr mesh` — and you can run it again at any time. The mesh works with Docker
Desktop: on a Linux host the peers' sshd ports are published on 127.0.0.1,
which a container cannot reach through `host-gateway`, so `dck herdr mesh`
says so and skips. It widens trust between your containers — read
[SECURITY.md](SECURITY.md) first for untrusted repositories.

```bash
dck herdr mesh      # make the other dck containers, the host ([host] machine) and the host's other loopback machines reachable from inside
dck agents          # herdr-peers list: the live agents on every machine
dck ask dck-other:w1:p2 "Which test covers the parser?"   # herdr-peers ask, with the reply grant
```

- **What is pushed.** Only public data goes into the container, through
  `docker exec`:
  - every other registered container's alias, port and user (from
    `~/.ssh/config.d/dck`);
  - its pinned host key (from dck's `known_hosts`);
  - its Herdr label.

  - with `[mesh] external = true` (the default), every **other** machine in
    your host Herdr whose SSH alias resolves (`ssh -G`) to a loopback address
    on a port in 22000-22999 — for example containers another kit manages —
    with its label, its enabled/disabled state and the ed25519 key **your**
    `~/.ssh/known_hosts` already pins (no pinned key: skipped, with a note).

  Inside, `dck_mesh_apply` writes `~/.ssh/config.d/dck-peers`
  (`HostName host.docker.internal`, `ForwardAgent no`, strict host keys) —
  including a block for the container itself, so herdr-peers can find its own
  machine — and the pinned `known_hosts.dck-peers`.
- **The host's Herdr catalog is mirrored, ids included.** A herdr-peers ask
  carries its reply address as `<machine id>:<pane>`, where the id is the
  asker's id **in its own Herdr catalog**. If each container minted its own ids
  (`herdr machine add`), a reply from inside could never name the machine that
  asked. So the mesh pushes the host's catalog entries (id, label, target,
  session, enabled) for every machine the container can reach — every dck
  container including itself, the host's other loopback machines with a pinned
  key, and the host's own entry — and `dck_mesh_apply` writes them as Herdr's
  saved machines (`~/.local/state/herdr/client/endpoints.json`, atomically, the
  previous file kept once as `endpoints.json.dck-bak`). Every id then means the
  same machine on the host and in every container. Herdr's saved machines live
  on the `state` volume, so they survive `rebuild`.
- **The host's own entry.** The host peer is the host's catalog entry whose
  alias resolves (`ssh -G`) to the listener (`127.0.0.1:<[host] port>`). When
  there is none, `dck host listener enable` and `dck herdr mesh` register one
  once: `dck-host` in `~/.ssh/config.d/dck` (127.0.0.1, your user, the dck key,
  the listener's pinned host key) and `herdr machine add --label <[host]
  label> dck-host`, so asks from the host carry an id the containers know.
  `dck doctor` reports the catalog and whether the host's own entry exists.
- **Every running container learns about the others.** After updating its own
  container, `dck herdr mesh` re-applies the mesh to every other running dck
  container over its alias (`ForwardAgent no`), so a container started earlier
  sees one started later. A repository whose `dck.toml` sets `[herdr] mesh =
  false` keeps it off: `dck up` records the choice in its state volume and
  refreshes from other repositories are ignored there.
- **The host as a peer** (`[host]` in your profile, see
  [config.md](config.md)). The host is reachable inside as `dck-host`
  (`host.docker.internal:<port>`, your user, pinned by the listener's ed25519
  host key). Three ways to give it a listener:
  - `listener = "dck"` (default): **`dck host listener enable`** (macOS) runs a
    user-level sshd on `127.0.0.1:22033` with its own host key, authorizing
    **only the dck key**, kept alive by a launchd agent
    (`~/Library/LaunchAgents/com.dailybothq.dck.host-listener.plist`, files in
    `~/.config/dck/host-listener/`). `dck setup` offers it once on a terminal
    and records your answer (`[host] machine`). `dck host listener status`
    shows it; `disable` removes it.
  - `listener = "external"` with `port` and `host_key`: a loopback listener
    you already run (for example one another kit set up); dck writes nothing on
    the host.
  - `listener = "remote-login"`: the system sshd on port 22, with your key in
    your own `authorized_keys`.
- **Containers another kit manages reaching dck containers.** They usually log
  in with your own keys, which dck containers do not accept by default: list
  their public files in `[ssh] authorized_extra` (host profile) and run
  `dck up`.
- **herdr-peers on the host.** `dck setup` installs a verified copy (the
  images' pin) in `~/.local/share/dck-host/herdr-peers/<tag>` when Herdr is on
  the host; `dck agents` and `dck ask` use it (`dck host peers install|status`).
- **The agent in Herdr panes.** Herdr points a pane's `SSH_AUTH_SOCK` at its forwarded-agent
  link, which dangles when the client that attached forwarded no agent. Since v0.2.8 the login
  profile falls back to the host agent dck mounts and the entrypoint repoints a dangling link, so
  mesh hops and `herdr-peers reply` keep working.
- **Credentials.** No private key enters the container (unless `[ssh] copy_keys`). Hops out of it
  authenticate with keys held by the host's ssh-agent, reached through
  agent forwarding (Herdr and `dck ssh` sessions) or the mounted agent
  socket (exec sessions). `dck herdr mesh` loads the dck key into that
  agent (never into the macOS Keychain) and says so; `ssh-add -d
  ~/.config/dck/ssh/id_ed25519` takes it out.
- **When the container's Herdr server is not running yet**, the Herdr
  machines are registered on the next `dck herdr mesh`. The ssh side is
  always written.

## The standard sidebar inside (`dck herdr layout`)

When the host Herdr attaches a container, the container opens with the
standard sidebar:

| Workspace | Content |
| --- | --- |
| **Home** | one shell (pane `home`), focused at the end |
| **Editor** | one shell (pane `editor`) |
| **Development** | tab `Development`, split `server` \| `tests` |
| **Agents** | tabs `Agent 1` … `Agent 4` |

Every pane is a plain shell in the workspace directory. The layout starts no
program: agents are started by you, or through `ak`.

```bash
dck herdr layout           # with a TTY: ask whether to reset (default keep); without one: keep
dck herdr layout --keep    # create only what is missing
dck herdr layout --reset   # close App, Editor, Development, Agents (and the legacy "Home", "Home (~)") and recreate them
bash dev.sh herdr-layout   # the same, from the repository
```

- **`dck up` runs it with `--keep`** right after `dck herdr add` (as do `dck rebuild`,
  `dck start` and `dck restart`).
  `[herdr] layout = "none"` in dck.toml turns that off.
- **`--keep` never rearranges your work:**
  - Development is split only when it has exactly one pane, so a layout
    you arranged by hand stays as it is;
  - a tab whose presence cannot be read is skipped, never duplicated.
- **`--reset` touches only the four standard workspaces** (and the legacy
  "Home (~)"). It aborts, recreating nothing, when one of them cannot be
  closed.
- **It runs inside the container,** as the container user, against the
  container's own Herdr server (`dck-herdr-layout`, installed by the
  template).
