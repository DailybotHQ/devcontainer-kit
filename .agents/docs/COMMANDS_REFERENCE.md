# Commands reference — devcontainer-kit

Invoke a command as `/<name>` in Claude Code, `#<name>` in agents that intercept slash syntax
(Codex, Cursor, Gemini), or in plain text ("run `<name>`") on hosts without slash commands.
Every command below is a thin delegator in `.agents/commands/` that routes to the vendored
`deepworkplan` skill — the skill is the single source of truth.

| Command | Routes to | What it does |
| --- | --- | --- |
| `dwp-create` | `.agents/skills/deepworkplan/create/` | create a Deep Work Plan (Lite first, Full when needed) |
| `dwp-execute` | `.agents/skills/deepworkplan/execute/` | execute a plan task by task through its gates |
| `dwp-refine` | `.agents/skills/deepworkplan/refine/` | change a plan's scope, split/add tasks, promote Lite → Full |
| `dwp-resume` | `.agents/skills/deepworkplan/resume/` | resume an interrupted plan at its first open task |
| `dwp-status` | `.agents/skills/deepworkplan/status/` | report a plan's status (read-only) |
| `dwp-verify` | `.agents/skills/deepworkplan/verify/` | check repository and plan conformance (read-only) |
| `dwp-upgrade` | `.agents/skills/deepworkplan/upgrade/` | check for a newer DeepWorkPlan and upgrade with consent |
| `skill-create` | `.agents/skills/deepworkplan/author/` | author or update a skill in this repository |
| `agent-create` | `.agents/skills/deepworkplan/author/` | author or update an agent persona in this repository |

The repository's own gate is not a command: `bash tests/run.sh`, `bash scripts/check-public-hygiene.sh`
and `shellcheck` (see `AGENTS.md` → Quick Commands).
