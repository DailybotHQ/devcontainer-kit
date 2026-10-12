# Entrypoint library

`lib/entrypoint.sh` is baked into every base image at
`/usr/local/lib/dck/entrypoint.sh`. The image's entrypoint,
`/usr/local/bin/dck-entrypoint`, sources it, runs **`dck_start`** as root and
then `exec`s the container command (`sleep infinity` by default). One
implementation replaces the per-repository entrypoints that used to drift
apart (four different names for the same persistence block).

A failing step is logged and never stops the container from starting, so the
developer can always get in and fix it.

## Inputs

Set by the compose file `dck init` renders ([init.md](init.md)):

| Variable | Default | Meaning |
| --- | --- | --- |
| `DCK_USER` | `dev` | the user whose home is managed |
| `DCK_HOME` | that user's home | |
| `DCK_WORKSPACE` | `/app` (dck.toml `workspace`) | the repository mount; Herdr opens every workspace and new pane here |
| `DCK_SSH` | `0` | `1` starts sshd (`ssh_port` ≠ 0 in `dck.toml`) |
| `DCK_AUTHORIZED_KEYS` | empty | public key(s) to authorize; `dck up` passes the dedicated dck key |
| `DCK_PERSIST_ROOT` | `$DCK_HOME/.dck/volumes` | where named volumes are mounted, one directory per volume |
| `DCK_REPO_HOOK` | `$DCK_WORKSPACE/docker/local/dev-setup-hook.sh` | the repository hook |
| `DCK_HOST_PROFILES` | empty | the CLIs whose ak profiles are the host's (`[agents] host_profiles`, set by `dck up`'s runtime overlay) |
| `DCK_HOST_CODEX` | empty | the mounted host Codex home (`$DCK_HOME/.dck/host/codex`); `~/.codex` links to it. Ignored outside `$DCK_HOME/.dck/host/` |
| `DCK_SSH_COPY_KEYS` | `0` | `1` copies the host's `~/.ssh/id_*` keys from `~/.ssh_host` (`[ssh] copy_keys`, set with that read-only bind by `dck up`'s runtime overlay); see `dck_ssh_copy_keys` |
| `AGENTKIT_PERMISSIONS` | empty | `ask` turns autonomy off: `dck_agent_trust` then writes nothing |

## Functions

### `dck_persist <name> <target> [dir|file]`

Keeps `<target>` (a path under the user's home) on the named volume mounted at
`$DCK_PERSIST_ROOT/<name>`, through a symlink. The volume copy is named after
the target's path relative to the home, without the leading dot, `/` → `_`
(`~/.config/gh` → `<volume>/config_gh`, `~/.claude.json` → `<volume>/claude.json`).

- **Seed on first run:** when the volume copy is missing or empty, the image's
  copy at the target is moved onto the volume.
- **Preserve on rebuild:** when the volume copy has content, it wins; the
  image's copy is discarded.
- **Idempotent:** a target already linked to its volume copy is left alone,
  silently.
- A symlink pointing elsewhere is replaced (its target is not touched).
- Refused: targets outside the home, the home itself, non-normalised paths
  (`..`), targets inside the volume root, invalid volume names.

### `dck_env_profile`

sshd starts every session with a clean environment, so nothing compose passed
in (`env_file`, `environment`) would reach an `ssh` or Herdr session. This
writes the container's environment to `~/.dck/env.sh`, which the login profile
`/etc/profile.d/00-dck.sh` sources. The file holds whatever secrets compose was
given, for the one user meant to have them:

- created **0600** with `O_CREAT|O_EXCL|O_NOFOLLOW` (no world-readable window,
  never written through a planted symlink), then atomically renamed;
- shell-managed names (`PATH`, `HOME`, `SHELL`, `USER`, …) and
  `DCK_AUTHORIZED_KEYS` are left out;
- values are never printed: only the number of variables is logged.

### `dck_sshd`

When `DCK_SSH=1`: generates an **ed25519 host key once** into
`$DCK_PERSIST_ROOT/state/ssh_host_keys` (0700, root) — never baked into the
image and never regenerated on recreate, so clients' pinned host keys stay
valid — writes `/etc/ssh/sshd_config.d/20-dck-runtime.conf` (`HostKey`,
`AllowUsers <user>`), authorizes `DCK_AUTHORIZED_KEYS`, validates with
`sshd -t` and starts sshd. The image's drop-in already forbids passwords and
root login ([images.md](images.md)); the host publishes the port on
`127.0.0.1` only.

### `dck_host_key_pub`

Prints the persistent host key's public half (nothing before sshd generated
it). `dck ssh` and `dck herdr add` run it as root through `docker exec` and pin
the key under the repository's alias, so a host key that changed because the
`state` volume was removed is re-pinned from the container itself, never
learned from the network.

### `dck_authorize_keys [--add]`

Maintains the block between `# >>> dck >>>` and `# <<< dck <<<` in
`~/.ssh/authorized_keys` (0600); lines outside it are yours. Without a flag
the block becomes the keys in `DCK_AUTHORIZED_KEYS` (an empty variable leaves
it alone — e.g. a container started by an editor plugin); `--add` adds the
key(s) read from stdin (`dck herdr add` uses it to repair access). Only
well-formed OpenSSH public keys are accepted.

### `dck_herdr_config`

Keeps `~/.config/herdr/config.toml` usable inside the container without
overwriting your values: `onboarding = false`; `[terminal]` `default_shell`,
`shell_mode = "login"` (also repairing `"non_login"`, which hides
`/etc/profile.d` PATH entries from panes) and `new_cwd = <workspace>` when
missing; `[experimental] allow_nested = true` always (the container's Herdr
runs inside the host's). Duplicate tables — invalid TOML that makes Herdr
ignore the whole file — are merged. An unchanged file is not rewritten.

### `dck_repo_hook`

Runs `docker/local/dev-setup-hook.sh` from the workspace, as the dev user,
when the file exists. A non-zero exit is reported and the container keeps
running. Put project-specific start-up here instead of forking the
entrypoint.

### `dck_agent_trust`

Unattended agent launches ([layers.md](layers.md#unattended-agent-launches)): with
autonomy on, the workspace is marked trusted for the CLIs in `DCK_AGENTS` — Claude's
`projects[<workspace>].hasTrustDialogAccepted` and Codex's
`[projects."<workspace>"] trust_level = "trusted"` in the container's own homes and in
the shared host profiles; Claude's bypass-permissions acknowledgement and onboarding
only in the container's own homes (`~/.claude.json`, `~/.claude/settings.json`, and
profiles on the container's volume), never in a profile listed by `DCK_HOST_PROFILES`.
Idempotent; an invalid file is left alone; only the number of files changed is logged.

### `dck_ssh_copy_keys`

`[ssh] copy_keys` (host profile, opt-in; [SECURITY.md](SECURITY.md#host-ssh-keys-ssh-copy_keys)).
With `DCK_SSH_COPY_KEYS=1`, copies every regular `id_*` file of `~/.ssh_host` (the
host's `~/.ssh`, mounted read-only) into `~/.ssh` on the state volume: private keys
0600, `.pub` 0644, `~/.ssh` 0700. Runs at every start: a key changed on the host is
refreshed, one removed from the host is removed. Only `id_*` names are written, so
dck's `config`, `config.d/`, `authorized_keys` and `known_hosts.dck-host` are never
touched; a key the container made itself under the same name is kept, and symlinks are
not followed. The copied names go to `~/.ssh/.dck-copied-keys`; without
`DCK_SSH_COPY_KEYS=1` the next start removes exactly those files. Names only are
logged (`ssh keys copied: …`), never a key's contents.

### `dck_herdr_self <id|->`

Records this container's machine id in the **host's** Herdr catalog (32 hex characters)
on the state volume (`~/.dck/volumes/state/herdr-self`, 0644, public data); the login
profile exports it as `HERDR_PEERS_SELF`, herdr-peers' reply route — a Codex pane cannot
discover it by itself, so asks from one failed with "no reply route". `dck up`,
`dck herdr add` (after every registration: a re-added machine has a new id) and
`dck herdr mesh` push it through `docker exec`; `dck herdr remove` clears it (`-`).
A malformed id is refused; a value already set in the environment wins.

### `dck_start`

The standard sequence:

1. persist `~/.ssh`, `~/.config/gh`, `~/.config/herdr`, Herdr's saved
   machines (`~/.local/state/herdr/client`) and `~/.bash_history` on
   the per-project `state` volume (and the agents layer's homes, see
   [layers.md](layers.md));
2. git identity, SSH agent access, `dck_ssh_copy_keys`, skills links (herdr-peers,
   Herdr and, with the agents layer, coding-agents-kit's skills) and `dck_agent_trust`;
3. `dck_herdr_config`;
4. `dck_env_profile`;
5. `dck_sshd`;
6. `dck_repo_hook`.

## Using it from your own entrypoint

```bash
#!/usr/bin/env bash
. /usr/local/lib/dck/entrypoint.sh
dck_start
dck_persist state "$HOME/.cache/my-tool"   # extra persisted path
exec "$@"
```

## Testing

The `entrypoint` scope runs every function unprivileged against a sandbox
root (`DCK_ROOT` prefixes `/etc` and `/run`; `DCK_SSHD_BIN` is a fake), under
the system bash too. The `docker` scope runs the real thing as root in a built
image, including a public-key SSH login.
