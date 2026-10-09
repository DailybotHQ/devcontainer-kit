# Security policy

## Supported versions

| Version | Supported |
| --- | --- |
| `v0.1.6` (latest), `v0.1.5` | yes |
| `v0.1.4` | no — upgrade (no code security fix since; newer editor pin) |
| `v0.1.3` | no — upgrade (no code security fix since; newer editor pin) |
| `v0.1.2` | no — upgrade (no code security fix since; newer editor pin and doctor fix) |
| `v0.1.1` | no — upgrade (the agents layer cannot install npm-based CLIs) |
| `v0.1.0` | no — upgrade (security fixes in `v0.1.1`) |

Fixes land on `main` and ship in the next patch release; while the project is at 0.x,
the latest release and the one before it receive security fixes.

## Reporting a vulnerability

Please report privately — **never in a public issue, discussion or pull request**:

- GitHub: **Security → Report a vulnerability** on
  [DailybotHQ/devcontainer-kit](https://github.com/DailybotHQ/devcontainer-kit/security/advisories/new)
  (private vulnerability reporting), or
- e-mail: **security@dailybot.com**.

Include the version (`dck --version`), the host OS and Docker runtime (`dck doctor --json`
helps — it never prints secret values), and the steps to reproduce.

## What to expect

| Step | Target |
| --- | --- |
| Acknowledgement | within 3 business days |
| First assessment (severity, affected versions) | within 7 business days |
| Fix or mitigation for high/critical issues | within 30 days, coordinated with you |
| Public advisory | when a fixed release is available, crediting you unless you prefer otherwise |

## Scope

The threat model, trust boundaries and the defaults this project enforces (loopback-only
ports, SSH agent forwarding instead of key copies, runtime host keys, pinned and
checksum-verified images, `--trust` for host-reaching repository configuration) are
documented in [docs/SECURITY.md](docs/SECURITY.md).
