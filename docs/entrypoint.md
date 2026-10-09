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
| `DCK_WORKSPACE` | `/workspace` | the repository mount |
| `DCK_SSH` | `0` | `1` starts sshd (`ssh_port` ≠ 0 in `dck.toml`) |
| `DCK_AUTHORIZED_KEYS` | empty | public key(s) to authorize; `dck up` passes the dedicated dck key |
| `DCK_PERSIST_ROOT` | `$DCK_HOME/.dck/volumes` | where named volumes are mounted, one directory per volume |
| `DCK_REPO_HOOK` | `$DCK_WORKSPACE/docker/local/dev-setup-hook.sh` | the repository hook |

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

### `dck_start`

The standard sequence:

1. persist `~/.ssh`, `~/.config/gh`, `~/.config/herdr`, `~/.bash_history` on
   the per-project `state` volume (and the agents layer's homes, see
   [layers.md](layers.md));
2. `dck_herdr_config`;
3. `dck_env_profile`;
4. `dck_sshd`;
5. `dck_repo_hook`.

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
