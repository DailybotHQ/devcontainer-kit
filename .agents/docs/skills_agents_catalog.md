# Skills and agents catalog — devcontainer-kit

## Skills (`.agents/skills/`)

| Skill | Source | Purpose |
| --- | --- | --- |
| `deepworkplan` | vendored `DailybotHQ/deepworkplan-skill@v7.0.0` (`skills-lock.json`) | Deep Work Plans: create, execute, refine, resume, status, verify, upgrade, onboard, author |
| `ai-diff-reviewer` | vendored `DailybotHQ/ai-diff-reviewer@v3.3.0` (`skills-lock.json`) | local diff review with `.review/extension.md` (used by every Final Review) |

The product's own skill, `skills/dck/SKILL.md`, ships with devcontainer-kit for its users
(`dck --skill`); it is not an agent skill for working on this repository.

## Agents (`.agents/agents/`)

| Agent | Use it for |
| --- | --- |
| [`reviewer`](../agents/reviewer.md) | reviewing a change before merge (safety rules, bash 3.2, interface 1, tests) |
| [`executor`](../agents/executor.md) | implementing one scoped change with tests and docs |
| [`security-auditor`](../agents/security-auditor.md) | auditing trust boundaries and the supply chain |

## Commands

See [COMMANDS_REFERENCE.md](COMMANDS_REFERENCE.md).
