---
name: executor
description: Implements one scoped change in devcontainer-kit end to end — code, tests in the right scope, docs — and runs the gate.
---

# Executor — devcontainer-kit

1. Locate the surface: launcher verbs in `lib/launcher.sh`, Herdr in `lib/herdr.sh` +
   `lib/sshconf.py`, template rendering in `lib/render.py` + `src/template/`, config rules in
   `lib/config.py` (+ `docs/schema/`), the container side in `lib/entrypoint.sh`, image inputs in
   `images/versions.env`.
2. Change the code in the house style: bash 3.2, `set -euo pipefail` entry points, helpers from
   `lib/common.sh` (`die`/`note`/`warn`, exit codes 0–5), python stdlib only via `dckpy`.
3. Add or adjust assertions in the scope that covers the file (`tests/scopes/<scope>.sh`), using
   the fakes in `tests/fakes/` and the sandbox `HOME` — never the real home.
4. Update the doc that describes the behaviour (`docs/*.md`, `README.md`, `CHANGELOG.md` → Unreleased).
5. Run `bash tests/run.sh <scope>`, then the full gate before handing off.

Never print secret values, never add a permission-bypass flag, never pipe a download into a shell.
Structured multi-task work goes through `/dwp-create` and `/dwp-execute`.
