# AGENTS.md — devcontainer-kit

Entry point for AI agents working **on** this repository (`CLAUDE.md` is a symlink to this file).

## Purpose

A standard, agent-ready development container for any repository, built on the Dev Containers spec: a template (`devcontainer.json` + compose + `docker/local/`), the `dck` launcher (setup/up/shell/rebuild/doctor), base images in python and node flavours that ship **without** coding agents (agents are an opt-in layer), and an sshd wired so each container can join [Herdr](https://herdr.dev) as a machine.

## Command / skill

devcontainer-kit (alias dck); skill dck

## Layout

| Path | What |
| --- | --- |
| `bin/dck`, `bin/devcontainer-kit` | the launcher (bash 3.2+) |
| `lib/*.sh` | launcher modules: `common`, `launcher`, `herdr`, `doctor`; `entrypoint.sh` is the in-container library |
| `lib/*.py` | python side (stdlib, run as `python3 -I lib/dckpy.py`): `config`, `render` (`dck init`), `devc`, `jsonc`, `sshconf`, `doctor` |
| `lib/layers/` | opt-in layer installers baked into the images (agents, dailybot) |
| `src/template/` | the Dev Container template `dck init` renders |
| `images/` | base image Dockerfiles per flavour, `common/` build steps, `versions.env` (the single pin file) |
| `skills/dck/` | the product's agent skill (`dck --skill`) |
| `docs/` | user docs, `schema/` (dck.toml, profile, doctor JSON Schemas), `SECURITY.md` |
| `install.sh` | user install into `~/.local/share/dck` |
| `scripts/` | `check-public-hygiene.sh` (CI hygiene gate), `release-sums.sh` (release `SHA256SUMS`) |
| `.github/` | CI, image and release workflows; issue/PR templates; CODEOWNERS; Dependabot |
| `tests/` | `run.sh` (scopes), `lib.sh`, `scopes/`, `fakes/`, `fixtures/`, `py/minischema.py` |

## Validation

| Scope | Command |
| --- | --- |
| Full | `bash tests/run.sh` |
| Scoped | `bash tests/run.sh <scope>` |
| Public hygiene | `bash scripts/check-public-hygiene.sh` |
| Lint | `shellcheck -S warning bin/* lib/*.sh scripts/*.sh tests/run.sh install.sh` |

The test map lives in [`docs/TESTING_GUIDE.md`](docs/TESTING_GUIDE.md).

## Rules

1. English for code, comments and docs; conventional commits.
2. Runtime code depends on bash and the python3 standard library only.
3. Never print, log or write the value of any `*_API_KEY` / `*_TOKEN` variable; refer to variables by name.
4. Never spell a fetch-piped-to-shell install line in a skill file (marketplace rule E005); never inject a permission-bypass flag by default (E006); pin every cross-repo install to a tag (W012).
5. Developing is not installing: tests run in a sandbox `HOME`; nothing is installed into the real `$HOME` while developing.
6. Pin every external tool by version (and checksum) in `images/versions.env`.
7. Never follow a symlink planted in a user repository; run python as `python3 -I`.
8. Public repository: no personal paths, private organisation/repository/tool names, internal hostnames, people's data or secrets in tracked files — `scripts/check-public-hygiene.sh` enforces it. Contribution rules: [CONTRIBUTING.md](CONTRIBUTING.md).

## Deep Work Plans

Structured work runs through the installed `deepworkplan` skill (`.agents/skills/deepworkplan/`); plans live in the gitignored `.dwp/`.

DWP standard: 6.0.0 (onboarded 2026-10-08; skill 6.1.0)
