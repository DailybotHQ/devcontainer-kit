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
- **A changed host key is refused** (`accept-new`). The container's host key
  lives on its `state` volume and survives rebuilds; if you delete that volume
  on purpose, forget the old key with
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
- copy a private key into a container, or authorize "every `~/.ssh/*.pub`";
- add a listener or an `authorized_keys` entry on your host (`host_machine`
  only tells the mesh about your host's own sshd, when you run one).

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

`dck up` runs `dck herdr mesh` after `dck herdr add` (unless `[herdr] mesh =
false`), and you can run it again at any time. The mesh works with Docker
Desktop: on a Linux host the peers' sshd ports are published on 127.0.0.1,
which a container cannot reach through `host-gateway`, so `dck herdr mesh`
says so and skips. It widens trust between your containers — read
[SECURITY.md](SECURITY.md) first for untrusted repositories.

```bash
dck herdr mesh      # make every other dck container (and the host, with host_machine) reachable from inside
dck agents          # herdr-peers list: the live agents on every machine
dck ask dck-other:w1:p2 "Which test covers the parser?"   # herdr-peers ask, with the reply grant
```

- **What is pushed.** Only public data goes into the container, through
  `docker exec`:
  - every other registered container's alias, port and user (from
    `~/.ssh/config.d/dck`);
  - its pinned host key (from dck's `known_hosts`);
  - its Herdr label.

  Inside, `dck_mesh_apply` writes `~/.ssh/config.d/dck-peers`
  (`HostName host.docker.internal`, `ForwardAgent no`, strict host keys),
  the pinned `known_hosts.dck-peers` and a Herdr machine per peer.
- **The host as a peer.** Set `host_machine = true` in your host profile.
  The host is then reachable as `dck-host` (`host.docker.internal:22`, your
  user, the host's ed25519 host key). This needs Remote Login (sshd) on the
  host, and your key in its `authorized_keys`.
- **Credentials.** No private key enters the container. Hops out of it
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
dck herdr layout --reset   # close Home, Editor, Development, Agents (and the legacy "Home (~)") and recreate them
bash dev.sh herdr-layout   # the same, from the repository
```

- **`dck up` runs it with `--keep`** right after `dck herdr add`.
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
