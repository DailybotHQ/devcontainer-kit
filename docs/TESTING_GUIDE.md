# Testing guide — devcontainer-kit

## Full validation commands

```bash
bash tests/run.sh
```

## Scoped commands

`bash tests/run.sh <scope>` runs one area. Scopes and the source-to-test
mapping are filled in by the first plan as the harness is built.

## Posture

Unit-first; tests run in a sandbox `HOME`, without network and without
installing anything; integration scopes that need Docker or Herdr are marked
and report "unavailable" honestly instead of passing.
