# AGENTS.md — devcontainer-kit

Entry point for AI agents working **on** this repository (`CLAUDE.md` is a symlink to this file).

## Purpose

A standard, agent-ready development container for any repository, built on the Dev Containers spec: a template (`devcontainer.json` + compose + `docker/local/`), the `dck` launcher (setup/up/shell/rebuild/doctor), images built from the repository itself in `python-3.13`, `node-24` and `debian` flavours (optional prebuilt base images from the same steps) that ship **without** coding agents (agents are an opt-in layer), and an sshd wired so each container can join [Herdr](https://herdr.dev) as a machine.

## Command / skill

devcontainer-kit (alias dck); skill dck

## Layout

| Path | What |
| --- | --- |
| `bin/dck`, `bin/devcontainer-kit` | the launcher (bash 3.2+) |
| `lib/*.sh` | launcher modules: `common`, `launcher`, `herdr`, `hostlistener` (`dck host listener`), `peers_host` (`dck host peers`), `doctor`; `entrypoint.sh` is the in-container library |
| `lib/*.py` | python side (stdlib, run as `python3 -I lib/dckpy.py`): `config`, `render` (`dck init`), `devc`, `jsonc`, `sshconf`, `doctor`, `hostagents` (`[agents] host_profiles`), `sshkeys` (`[ssh] copy_keys`), `agentclis` (each developer's coding-agent CLIs), `dckpy` (the dispatcher) |
| `lib/layers/` | opt-in layer installers baked into the images (`agents.sh`, `dailybot.sh`, shared `common.sh`) |
| `src/template/` | the Dev Container template `dck init` renders |
| `images/` | base image Dockerfiles per flavour (`python-3.13`, `node-24`, `debian`), `common/` build steps (vendored into each repository by `dck init`), `versions.env` (the single pin file) |
| `skills/dck/`, `skills/dck-dockerfile/` | the product's agent skills (`dck --skill`, `dck --skill dck-dockerfile`) |
| `docs/` | user docs, `schema/` (dck.toml, profile, doctor JSON Schemas, v1 and v2), `SECURITY.md` |
| `install.sh` | user install into `~/.local/share/dck` |
| `scripts/` | `check-public-hygiene.sh` (CI hygiene gate), `release-sums.sh` (release `SHA256SUMS`), `release-notes.sh` (release notes from `CHANGELOG.md`) |
| `assets/` | brand logos for the README header (`logo-dark.png` for dark themes, `logo-light.png` for light ones); `assets/README.md` says which is which |
| `.github/` | CI, image and release workflows; issue/PR templates; CODEOWNERS; Dependabot |
| `.agents/` | vendored `deepworkplan` skill and the `dwp-*` command delegators (`.claude`, `.cursor` → `.agents`) |
| `.devcontainer/`, `docker/local/`, `dev.sh` | the repository's own dck container (dogfood, rendered by `bin/dck init --repo .`; re-render after changing `lib/`, `images/common/` or `src/template/`) |
| `tests/` | `run.sh` (scopes), `lib.sh`, `scopes/`, `fakes/`, `fixtures/`, `py/minischema.py` |
| `.review/`, `.public-hygiene-allow` | AI Diff Reviewer overrides (`extension.md`); the hygiene check's allow-list |

## Validation

| Scope | Command |
| --- | --- |
| Full | `bash tests/run.sh` |
| Scoped | `bash tests/run.sh <scope>` |
| Public hygiene | `bash scripts/check-public-hygiene.sh` |
| Lint | `shellcheck -S warning bin/* lib/*.sh scripts/*.sh tests/run.sh install.sh` |

The test map lives in [`docs/TESTING_GUIDE.md`](docs/TESTING_GUIDE.md).

## Quick Commands

```bash
bash tests/run.sh                     # full gate (15 scopes; docker last, "unavailable" without a daemon)
bash tests/run.sh <scope>             # one area (map: docs/TESTING_GUIDE.md)
bash scripts/check-public-hygiene.sh  # no private names, personal paths or secrets
shellcheck -S warning bin/* lib/*.sh scripts/*.sh tests/run.sh install.sh
bin/dck --version && bin/dck help     # run the launcher from the checkout (no install needed)
bin/dck up && bin/dck shell           # the repository's own dev container (dogfood)
```

## Rules

1. English for code, comments and docs; conventional commits.
2. Runtime code depends on bash and the python3 standard library only.
3. Never print, log or write the value of any `*_API_KEY` / `*_TOKEN` variable; refer to variables by name. The one write is the opt-in `[agents] host_profiles` env file (0600, on the host, allow-listed names; docs/SECURITY.md).
4. Never spell a fetch-piped-to-shell install line in a skill file (marketplace rule E005); autonomy flags live only in coding-agents-kit — dck, the template and the layers never spell one, agents run in autonomy by default inside the container, and the opt-out (`AGENTKIT_PERMISSIONS=ask`) is documented wherever autonomy is configured (E006); pin every cross-repo install to a tag (W012).
5. Developing is not installing: tests run in a sandbox `HOME`; nothing is installed into the real `$HOME` while developing.
6. Pin every external tool by version (and checksum) in `images/versions.env`.
7. Never follow a symlink planted in a user repository; run python as `python3 -I`.
8. Public repository: no personal paths, private organisation/repository/tool names, internal hostnames, people's data or secrets in tracked files — `scripts/check-public-hygiene.sh` enforces it. Contribution rules: [CONTRIBUTING.md](CONTRIBUTING.md).

## Deep Work Plans

Structured work runs through the installed `deepworkplan` skill (`.agents/skills/deepworkplan/`, vendored from `DailybotHQ/deepworkplan-skill` tag `v7.8.0`, pinned with its `ref` in `skills-lock.json`). Short commands are thin delegators in `.agents/commands/` (`/dwp-create`, `/dwp-execute`, `/dwp-refine`, `/dwp-resume`, `/dwp-status`, `/dwp-verify`, `/dwp-upgrade`, `/skill-create`, `/agent-create`; `#<name>` or plain text on hosts without slash commands); `.claude` and `.cursor` are symlinks to `.agents`. Plans live in the gitignored `.dwp/`; only the addon registry `.dwp/config.json` is tracked. The registry enables two addons: the AI Diff Reviewer (`.agents/skills/ai-diff-reviewer/`, tag `v3.3.14`, overrides in `.review/extension.md`), which runs the local review in every Final Review, and the dev container (`v1.0.0`: the repository's own dck container, rendered by `bin/dck init --repo .`); the methodology itself needs no addon. The tracked `.dwp/config.json` also enables `benchmark` and `learnings` (plan records and `learnings.json` stay in the ignored plan folder).

DWP standard: 7.0.0 (onboarded 2026-10-08; upgraded 2026-10-09, 2026-10-11, 2026-10-12 and 2026-10-13; skill 7.8.0, vendored 2026-10-13)
