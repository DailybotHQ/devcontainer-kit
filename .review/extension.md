# Review overrides for devcontainer-kit

devcontainer-kit is a bash 3.2 + python3-stdlib launcher (`bin/dck`, `lib/*.sh`,
`lib/*.py` run as `python3 -I lib/dckpy.py`) that writes a Dev Containers template into
other people's repositories (`lib/render.py`, `src/template/`), runs their compose
configuration (`lib/launcher.sh`, `lib/devc.py`), manages `~/.ssh/config.d/dck` and Herdr
machines (`lib/sshconf.py`, `lib/herdr.sh`), and builds agent-free base images
(`images/*/Dockerfile`, `images/common/install.sh`, `images/common/editor.sh`, pins in
`images/versions.env`).
`lib/entrypoint.sh` runs **as root** inside containers. The repository a user runs `dck`
in is untrusted input on the host; the threat model is `docs/SECURITY.md`.

## Severity overrides for this codebase

- **Always `critical`:** any host-side code path that executes or `eval`s content read
  from a user repository (devcontainer.json, dck.toml, compose files, file names), or
  calls python without `-I` (a repository's `json.py`/`shlex.py` would be imported).
  Files: `lib/launcher.sh`, `lib/common.sh` (`dckpy`), `lib/entrypoint.sh`.
- **Always `critical`:** SSH agent forwarding or `ForwardAgent yes` towards an address
  that is not `127.0.0.1`, or an `IdentityFile` other than the dedicated dck key in the
  **host-side** include dck writes (`~/.ssh/config.d/dck`).
  Files: `lib/launcher.sh` (`cmd_ssh`), `lib/herdr.sh`, `lib/sshconf.py` (`RE_HOST`).
  The container-side `config.d/dck-host` (`ssh_host_config`) points `IdentityFile` at the
  **public** halves of the developer's own git keys with no forwarding — expected; flag
  instead any private key, `ProxyCommand`/`ProxyJump`, non-git host without
  `ssh_host_extra`, or `ssh-add` without a terminal and consent.
- **Accepted by the owner (v0.2.1), do not flag:** the mesh being on by default
  (`[herdr] mesh = true` with `ssh_agent = true`), which lets a dck container log in to
  the other dck containers through the dck key in the host agent. Agents talking across
  machines is a product requirement; the path is documented in `docs/SECURITY.md` with
  its off switches. Still flag any change that widens it (agent forwarding onward, a
  non-loopback peer, keys copied in, the mesh on Linux without a reachable route).
- **Always `critical`:** a private key or a value of a `*_API_KEY`/`*_TOKEN` variable
  printed, logged, written to a world-readable file, baked into an image, or copied into a
  container. `dck doctor` must report variable NAMES only (`lib/doctor.py`).
- **Always `critical`:** a download in `images/common/install.sh`, `images/common/editor.sh`
  or `lib/layers/*.sh` that is not checked against a SHA-256 pinned in `images/versions.env`, any
  fetch-piped-to-shell, or a coding-agent CLI / Dailybot CLI / Engram / Graphify
  installed in a base image (`images/`).
- **Always `critical`:** the template (`src/template/`) gaining `cap_add`, `privileged`,
  the Docker socket, host-home or `~/.ssh` mounts, or a port not bound to `{{bind}}`
  (default `127.0.0.1`).
- **Escalate to `warning`:** writing, reading or `chmod`ing through a path that may be a
  symlink planted in the user repository (`lib/render.py` `check_paths`/`backup`,
  `.env` handling in `lib/launcher.sh`, `lib/devc.py` `env_examples`); new writes must
  use `O_EXCL|O_NOFOLLOW` or refuse links.
- **Escalate to `warning`:** a compose call that adds `--remove-orphans` or uses
  `compose down` (shared projects), or resolves the directory-name default project
  (`resolve_project` must refuse it).
- **Escalate to `warning`:** a new `up`/`build` path that skips `preflight_check`
  (host-reaching repository configuration needs `--trust`).
- **Escalate to `warning`:** bash 4-only syntax (`declare -A`, `mapfile`, `${x,,}`) in
  `bin/`, `lib/*.sh`, `install.sh`, `tests/run.sh` — macOS runs `/bin/bash` 3.2.

## Don't comment on

- Files under `.agents/skills/` — vendored, pinned copies (`skills-lock.json`); changes
  go upstream.
- The long explanatory comments in `lib/*.sh` and `images/common/install.sh`: they record
  why a safety rule exists (incidents from the hand-copied launchers); do not ask to
  shorten them.
- `print`/`note` wording in `tests/scopes/*.sh` assertions, and the deliberately
  fragmented strings in `tests/scopes/hygiene.sh` (assembled at run time so the file
  passes its own hygiene check).
- `sudo NOPASSWD` for the `dev` user and `git config --system safe.directory '*'` in the
  images: documented trade-offs in `docs/SECURITY.md`.

## Repo-specific conventions

- **Runtime dependencies:** bash + python3 standard library only; no pip packages, no
  Node in the tooling. Python 3.11+ (`tomllib`).
- **Exit codes:** 0 ok, 1 failed, 2 usage, 3 configuration, 4 environment, 5 refused by a
  safety rule (`lib/common.sh`); a new refusal uses 5 and names the rule.
- **Reconcile, never clobber:** `dck init` changes existing files only inside `# >>> dck:`
  managed blocks or owned keys, after a diff and consent, with a `.dck-bak-<ts>` backup.
- **Interface 1:** `dck doctor --json` keys and `dck.toml` keys may be added, never
  removed or retyped (`docs/schema/*.json` must match `lib/config.py` rules — the
  `config` and `doctor` scopes enforce it).
- **Pins:** every external input lives in `images/versions.env` with version AND
  checksum (base images by digest, deepworkplan-vim by tag, commit AND installer SHA-256).
- **Public repository:** no personal paths, private organisation/repository/tool names or
  secrets — `scripts/check-public-hygiene.sh` runs in CI.

## Test-strategy expectations

- A change in `lib/*.sh` or `bin/dck` needs an assertion in the matching scope of
  `tests/scopes/` (map in `docs/TESTING_GUIDE.md`), run against the fakes in
  `tests/fakes/` with a sandbox `HOME` — never the real home.
- A new safety rule needs a regression test that proves the refusal (see
  `tests/scopes/security.sh`).
- Image or entrypoint changes need the `docker` scope (real build), which must leave no
  container, volume or network behind.
