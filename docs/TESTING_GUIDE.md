# Testing guide — devcontainer-kit

## Full validation commands

```bash
bash tests/run.sh                                   # every scope (15), docker last
bash scripts/check-public-hygiene.sh                # public-repository hygiene (no private names, no secrets)
shellcheck -S warning bin/* lib/*.sh scripts/*.sh tests/run.sh install.sh
```

All three run in CI (`.github/workflows/ci.yml`): Ubuntu runs every scope including
`docker`; macOS runs the unit scopes under the system `/bin/bash` 3.2 with
`DCK_TEST_DOCKER=0`, so the docker scope reports `unavailable`.

## Scoped commands

`bash tests/run.sh <scope>...` runs only the named scopes. Other options:

| Option | Effect |
| --- | --- |
| `--list` | print the scopes, in run order, and exit |
| `-k <text>` | only test functions whose name contains `<text>` |
| `-v` | print each test's captured output, not only for failures |
| `-h` | print the runner's usage |

The canonical order is `harness config template images entrypoint launcher layers
agents sshkeys herdr doctor security hygiene standard docker` (`ORDER` in
`tests/run.sh`); a scope file not listed there runs after them, alphabetically.

## Source-to-scope map

Pick the scope that covers the files you touched; widen to the full run when a
change touches shared code (`lib/common.sh`, `lib/dckpy.py`, `bin/dck`).

| Scope | Covers | Needs Docker |
| --- | --- | --- |
| `harness` | `tests/run.sh`, `tests/lib.sh` | no |
| `config` | `lib/config.py` (dck.toml, the host profile and its `[host]`/`[mesh]`/`[ssh]` keys, each developer's coding-agent CLIs and the advanced mode), `docs/schema/dck-config-v2.json`, `docs/schema/dck-profile-v2.json` | no |
| `template` | `src/template/`, `lib/render.py`, `dck init` (reconcile, markers, the user block and `x-dck-merge`, port strings, state volume, `--no-dev-sh`, the advanced CLI mode), the rendered `dev.sh` (its docker-only fallback, preflight and `install-dck`) | no |
| `images` | `images/`, `.github/workflows/images.yml` (static checks), and that the repository's own `docker/local/app/dck/` equals its sources and `VERSION` | no |
| `entrypoint` | `lib/entrypoint.sh` (sandbox root, fake `sshd`): persistence, `env.sh`, authorized keys, sshd host keys, the Herdr config and catalog, the mesh, git identity, `HERDR_PEERS_SELF` | no |
| `launcher` | `bin/dck`, `bin/devcontainer-kit`, `lib/launcher.sh`, `lib/common.sh`, `lib/hostlistener.sh` (`dck host listener`), `lib/devc.py`, `lib/jsonc.py`, `install.sh` (fake `docker`/`devcontainer`/`launchctl`) | no |
| `layers` | the agents/editor/dailybot layers in the template and entrypoint | no |
| `agents` | `[agents] host_profiles`: `lib/hostagents.py`, the runtime overlay and env file (`lib/launcher.sh`), the doctor's report, the entrypoint's host Codex home, `dck_agent_trust`, non-shared profiles on the `agentkit` volume, `default_profile`, `dck_codex_config`; each developer's CLIs (`lib/agentclis.py` and the build arg) (fake `docker`, a fake host `ak profiles --json`) | no |
| `sshkeys` | `[ssh] copy_keys`: `lib/sshkeys.py`, the runtime overlay and `dck setup`'s offer (`lib/launcher.sh`), `config copy-keys` (`lib/config.py`), the entrypoint's `dck_ssh_copy_keys` (modes, refresh, never-overwrite, off removes the copies), the doctor's `ssh_keys` report (fake `docker`, throwaway keys) | no |
| `herdr` | `lib/herdr.sh` (`dck herdr add\|status\|repair\|remove\|mesh\|layout`, `dck agents`, `dck ask`), `lib/sshconf.py`, `lib/peers_host.sh` (`dck host peers`), satellites (`--service`, `--seed-state-from`) and PRIMARY mode (`--compose-file`), the post-start steps of `rebuild`/`start`/`restart`, a stale image rebuilt by `up` (fake `herdr`/`ssh`/`docker`/`curl`, sandbox `~/.ssh`) | no |
| `doctor` | `lib/doctor.py`, `lib/doctor.sh`, `docs/schema/dck-doctor-v2.json` (validated by `tests/py/minischema.py`), `skills/dck/` | no |
| `security` | the posture of `docs/SECURITY.md` over `src/template/`, `images/`, `lib/`: loopback binds, `--trust` (also for `--compose-file`), symlink refusals, `python3 -I`, the overlay's quoting, the host listener, `[ssh] authorized_extra` | no |
| `hygiene` | `scripts/check-public-hygiene.sh`, `.public-hygiene-allow` (every A3 rule, allow-list, secrets never echoed, this repo clean) | no |
| `standard` | the public repository standard: README order/badges/footer, LICENSE, CHANGELOG (Keep a Changelog), CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, CLAUDE.md, .gitignore, `.github/` community files, CI; the release workflow with `scripts/release-sums.sh` and `scripts/release-notes.sh` | no |
| `docker` | integration on rendered fixtures (no base image): a node repository with the agents layer — `dev.sh up`, `shell`, sshd on loopback only, `ssh` with agent forwarding (throwaway key, sandbox agent), the host agent in exec sessions, `herdr mesh`, herdr-peers and the layout script inside, git identity, GitHub host keys, `ak` in autonomy with both presets, DeepWorkPlan Vim at its pin, host accounts' env file rewritten by a second `dck up` and seen inside without a recreate, persistence across `dev.sh rebuild`, a removed `state` volume re-pinned by `dck ssh`, live `doctor --json` against the schema, PRIMARY mode (`--compose-file` A B `up --recreate`), `down`; a fresh rebuild that joins the mesh and copies keys (`[ssh] copy_keys`) — and a python repository (runtime, uv, editor, herdr-peers at its pin); the same `up`/`shell` through the real `devcontainer` CLI; a shared-stack fixture shaped like a product API (env_files, port expressions, an external network, a user block, a satellite with `extends` + `!reset`/`!override`: `docker compose config -q` and a real `up`); a pre-existing data volume of another service reattaching after `dck init` + `up`; a workspace under a renamed user's home; a workspace satellite (`--service`, `--seed-state-from`). Builds hold `DCK_BUILD_LOCK` when set. Cleans up its containers, volumes and images | **yes** |

## How a test is written

A scope is `tests/scopes/<scope>.sh`; every function named `test_*` is one
test and runs in its own subshell with a **fresh sandbox `HOME`**. The helpers
live in `tests/lib.sh`:

- `run_cmd <cmd...>` then `assert_rc <code> <desc>`; output in `$RUN_OUT` / `$RUN_ERR`
- `assert_eq`, `assert_ne`, `assert_contains`, `assert_not_contains`,
  `assert_match`, `assert_no_match`, `assert_file`, `assert_dir`,
  `assert_not_file`, `assert_symlink`, `assert_absent`, `assert_mode`; `pass`,
  `fail`, `unavailable` write a result line directly
- `use_fakes` puts `tests/fakes/bin` (fake `docker`, `devcontainer`, `herdr`,
  `ssh`, `curl`, `launchctl`) first on `PATH`; each fake logs its argv to
  `$DCK_FAKE_LOG` (read with `fake_calls <tool>`) and answers from files in
  `$DCK_FAKE_STATE`; `tests/fakes/sbin/sshd` stands in for sshd in the
  `entrypoint` scope, and `tests/fakes/layout/herdr` is a stateful Herdr for the
  layout tests
- `fixture <name>` copies `tests/fixtures/<name>/` into the sandbox
- `require_docker <desc> || return 0` emits an `unavailable` line when no
  daemon answers

Result lines go to file descriptor 3, never stdout, so output of the code under
test can never be counted as a result. A test that crashes, or makes no
assertion, is a failure.

## Posture

- **Sandbox, never the real home.** `HOME`, every XDG base directory and git's
  global/system config point into a per-test temporary directory; `DCK_*`
  variables from the caller are cleared, and so are `AGENTKIT_*`, `HERDR_*`,
  `CLAUDE_*`, `CODEX_*`, the vendors' `*_API_KEY`/`*_TOKEN`/`*_SECRET` variables,
  `SSH_AUTH_SOCK`, `COMPOSE_PROJECT_NAME`, `COMPOSE_FILE` and `DOCKER_HOST`.
  Nothing is installed anywhere.
- **PATH-hermetic.** The runner hides the developer's own ecosystem tools — `ak`,
  `agentkit`, `herdr`, `herdr-peers`, `herdr-groups`, `dck`, `devcontainer-kit`, the
  agent CLIs, `dailybot` (`DCK_TEST_HIDDEN` in
  `tests/run.sh`): each `PATH` directory holding one is replaced by a mirror of its
  other executables, so docker, the devcontainer CLI, python3 and git still resolve.
  A test that needs one of them uses a fake.
- **No network** in the unit scopes. The `docker` scope pulls base images and
  release assets because building an image does. It runs with the sandbox
  `HOME` (docker reads an empty `$HOME/.docker`) and `DCK_SSH_CONFIG=/dev/null`,
  so the developer's `~/.ssh` is never read or written; its ssh-agent socket
  lives at `/tmp/dck-it-<pid>.sock` (Unix socket paths are length-limited) and
  is removed by the test.
- **Honest unavailability.** Without a Docker daemon (or with
  `DCK_TEST_DOCKER=0`) docker-dependent tests print
  `unavailable - <test> (<reason>)`; they never pass silently. The probe asks
  the real docker (never the fakes) and requires a server version number: a
  stuck engine that exits 0 printing its error counts as not answering.
- The summary is always the last line:
  `summary: scopes: N, passed: P, failed: F, unavailable: U`. Exit status is
  0 only when `failed` is 0; 2 on a usage error (unknown scope or flag).
