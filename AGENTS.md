# AGENTS.md — devcontainer-kit

Entry point for AI agents working **on** this repository.

## Purpose

A standard, agent-ready development container for any repository, built on the Dev Containers spec: a template (`devcontainer.json` + compose + `docker/local/`), the `dck` launcher (setup/up/shell/rebuild/doctor), base images in python and node flavours that ship **without** coding agents (agents are an opt-in layer), and an sshd wired so each container can join [Herdr](https://herdr.dev) as a machine.

## Command / skill

devcontainer-kit (alias dck); skill dck

## Layout (target; built by the first plan)

bin/ (dck), lib/, src/template/, images/ (Dockerfiles per flavour), skills/dck/, install.sh, tests/ (run.sh), docs/

## Validation

| Scope | Command |
| --- | --- |
| Full | `bash tests/run.sh` |
| Scoped | `bash tests/run.sh <scope>` |

The test map lives in [`docs/TESTING_GUIDE.md`](docs/TESTING_GUIDE.md).

## Rules

1. English for code, comments and docs; conventional commits.
2. Runtime code depends on bash and the python3 standard library only.
3. Never print, log or write the value of any `*_API_KEY` / `*_TOKEN` variable; refer to variables by name.
4. Never spell a fetch-piped-to-shell install line in a skill file (marketplace rule E005); never inject a permission-bypass flag by default (E006); pin every cross-repo install to a tag (W012).
5. Developing is not installing: tests run in a sandbox `HOME`; nothing is installed into the real `$HOME` while developing.
6. Pin every external tool by version.

## Deep Work Plans

Structured work runs through the installed `deepworkplan` skill (`.agents/skills/deepworkplan/`); plans live in the gitignored `.dwp/`.

DWP standard: 6.0.0 (onboarded 2026-10-08; skill 6.1.0)
