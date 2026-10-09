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
- add a host-as-machine listener on your host (the host profile's
  `host_machine` key is reserved and reported only in v0.1).

## Inside the container

The base images ship Herdr (pinned, `/usr/local/bin/herdr`, on the PATH of the
non-login SSH session the Herdr client uses) and a seeded config with login
shells, `new_cwd = <workspace>` and `allow_nested = true`, kept current by the
entrypoint's `dck_herdr_config` ([entrypoint.md](entrypoint.md)).
