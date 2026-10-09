# devcontainer-kit

A standard, agent-ready development container for any repository, built on the Dev Containers spec: a template (`devcontainer.json` + compose + `docker/local/`), the `dck` launcher (setup/up/shell/rebuild/doctor), base images in python and node flavours that ship **without** coding agents (agents are an opt-in layer), and an sshd wired so each container can join [Herdr](https://herdr.dev) as a machine.

> **Status: pre-release.** Part of the [DeepWorkPlan](https://deepworkplan.com) ecosystem, and fully usable without it.

## Install

```bash
git clone --branch v0.1.0 https://github.com/DailybotHQ/devcontainer-kit && ./devcontainer-kit/install.sh   # available from v0.1.0
```

## License

MIT — see [LICENSE](LICENSE). Credits in [CREDITS.md](CREDITS.md).
