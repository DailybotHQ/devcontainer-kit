# Testing guide — devcontainer-kit

## Full validation commands

```bash
bash tests/run.sh                                   # every scope, docker last
bash scripts/check-public-hygiene.sh                # public-repository hygiene (no private names, no secrets)
shellcheck -S warning bin/* lib/*.sh scripts/*.sh tests/run.sh install.sh
```

Both run in CI (`.github/workflows/ci.yml`): Ubuntu runs every scope including
`docker`; macOS runs the unit scopes under the system `/bin/bash` 3.2 with
`DCK_TEST_DOCKER=0`, so the docker scope reports `unavailable`.

## Scoped commands

`bash tests/run.sh <scope>...` runs only the named scopes. Other options:

| Option | Effect |
| --- | --- |
| `--list` | print the scopes and exit |
| `-k <text>` | only test functions whose name contains `<text>` |
| `-v` | print each test's captured output, not only for failures |

## Source-to-scope map

Pick the scope that covers the files you touched; widen to the full run when a
change touches shared code (`lib/common.sh`, `lib/dckpy.py`, `bin/dck`).

| Scope | Covers | Needs Docker |
| --- | --- | --- |
| `harness` | `tests/run.sh`, `tests/lib.sh` | no |
| `config` | `lib/config.py`, `docs/schema/dck-config-v2.json` | no |
| `template` | `src/template/`, `lib/render.py`, `dck init` | no |
| `images` | `images/`, `.github/workflows/images.yml` (static checks) | no |
| `entrypoint` | `lib/entrypoint.sh` (sandbox root, fake `sshd`) | no |
| `launcher` | `bin/dck`, `bin/devcontainer-kit`, `lib/*.sh`, `install.sh` (fake `docker`/`devcontainer`) | no |
| `layers` | the agents/editor/dailybot layers in the template and entrypoint | no |
| `herdr` | `lib/herdr.sh`, `lib/sshconf.py` (fake `herdr`/`ssh`/`docker`, sandbox `~/.ssh`) | no |
| `doctor` | `lib/doctor.py`, `lib/doctor.sh`, `docs/schema/dck-doctor-v2.json` (validated by `tests/py/minischema.py`), `skills/dck/` | no |
| `security` | static posture checks over `src/template/`, `images/`, `lib/` | no |
| `hygiene` | `scripts/check-public-hygiene.sh`, `.public-hygiene-allow` (every A3 rule, allow-list, secrets never echoed, this repo clean) | no |
| `standard` | the public repository standard: README order/badges/footer, LICENSE, CHANGELOG (Keep a Changelog), CONTRIBUTING, SECURITY, CODE_OF_CONDUCT, CLAUDE.md, .gitignore, `.github/` community files, CI; the release workflow with `scripts/release-sums.sh` and `scripts/release-notes.sh` | no |
| `docker` | integration on rendered fixtures (no base image): a node repository with the agents layer — `dev.sh up`, `shell`, sshd on loopback only, `ssh` with agent forwarding (throwaway key, sandbox agent), the host agent in exec sessions, `herdr mesh`, herdr-peers and the layout script inside, git identity, GitHub host keys, `ak` in autonomy with both presets, DeepWorkPlan Vim at its pin, persistence across `dev.sh rebuild`, live `doctor --json` against the schema, `down` — and a python repository (runtime, uv, editor, herdr-peers); the same `up`/`shell` through the real `devcontainer` CLI. Builds hold `DCK_BUILD_LOCK` when set. Cleans up its containers, volumes and images | **yes** |

## How a test is written

A scope is `tests/scopes/<scope>.sh`; every function named `test_*` is one
test and runs in its own subshell with a **fresh sandbox `HOME`**. The helpers
live in `tests/lib.sh`:

- `run_cmd <cmd...>` then `assert_rc <code> <desc>`; output in `$RUN_OUT` / `$RUN_ERR`
- `assert_eq`, `assert_ne`, `assert_contains`, `assert_not_contains`,
  `assert_match`, `assert_no_match`, `assert_file`, `assert_dir`,
  `assert_symlink`, `assert_absent`, `assert_mode`
- `use_fakes` puts `tests/fakes/bin` (fake `docker`, `devcontainer`, `herdr`,
  `ssh`, `ssh-keyscan`) first on `PATH`; each fake logs its argv to
  `$DCK_FAKE_LOG` (read with `fake_calls <tool>`) and answers from files in
  `$DCK_FAKE_STATE`
- `fixture <name>` copies `tests/fixtures/<name>/` into the sandbox
- `require_docker <desc> || return 0` emits an `unavailable` line when no
  daemon answers

Result lines go to file descriptor 3, never stdout, so output of the code under
test can never be counted as a result. A test that crashes, or makes no
assertion, is a failure.

## Posture

- **Sandbox, never the real home.** `HOME`, every XDG base directory and git's
  global/system config point into a per-test temporary directory; `DCK_*`
  variables from the caller are cleared. Nothing is installed anywhere.
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
