# `dck doctor`

```bash
dck doctor            # human report
dck doctor --json     # machine report, interface 2 (docs/schema/dck-doctor-v2.json)
dck doctor --strict   # exit 1 while `problems` is not empty (CI)
dck --compose-file F... doctor   # PRIMARY mode: report the compose files dck up was given
```

The doctor works anywhere: outside a repository it reports the host only
(`repo`, `layers`, `ssh`, `host_profiles`, `ssh_keys`, `compose` and `git` are
`null`; `herdr` still reports the host's client). Every probe has a timeout and
degrades to `null`/`false` with a reason instead of failing — a broken
machine still gets an answer. Exit status is 0 (or 1 with `--strict` and
problems), 2 on a usage error.

## The JSON report (interface 2)

Integrators (the DeepWorkPlan `devcontainer` addon, scripts, agents) read
`interface` first and treat an unknown value as "not compatible" — one warning,
never an error. Within interface 2 keys may be **added**, never removed or
retyped. Interface 2 (v0.2.0) replaced the base-image keys of interface 1 (`image_tag`,
`digest_match`) with `kit_version` and `vendored`.

| Key | Content |
| --- | --- |
| `interface` | `2` |
| `version` | the installed dck version (the `VERSION` file of the install) |
| `runtime` | `docker` {`cli`, `version`, `daemon` (true only when `docker info` returns a server version — a stuck engine that exits 0 printing its error counts as not answering), `server_version`, `reason`}, `provider` (`docker-desktop`, `orbstack`, `colima`, `podman`, `docker-engine` or null), `compose.version`, `devcontainer_cli` {`installed`, `version`} |
| `repo` | `path`, `devcontainer` (the devcontainer.json in use, repository-relative), `config_valid`, `errors`, `warnings`, `flavour`, `base_image` (the `ARG BASE_IMAGE` pin of the rendered Dockerfile), `digest_pinned`, `kit_version` (the devcontainer-kit tag in `docker/local/<service>/dck/VERSION`), `vendored` (`current` when `dck/` equals the installed kit's files, `modified` otherwise — `dck init` restores them), `project`, `service`, `container` {`name`, `state`}, `compose_files` (in order; `dck --compose-file` replaces devcontainer.json's list), `compose_override`, `env_files` [{`path`, `present`, `mode`, `private`, `keys_set`}] (one per `.env*.example` under the compose directory; a symlinked one is skipped and reported) |
| `layers` | `agents`, `clis` (dck.toml's), `dailybot`, `editor`; `clis_mode` (`default`: no `[agents] supported`, the CLIs chosen at onboarding are wired and installed; `advanced`: `[agents] supported` is set, each developer chooses), `clis_supported` (`[agents] supported`, or `clis` in the default mode), `clis_effective` (what this developer requests), `clis_source` (`env`, `env (docker/local/.env)`, `profile`, `repo`, `INSTALL_* (env)`, `INSTALL_* (docker/local/.env)`, joined by ` + `), `clis_image` (what the running image installed, from `/opt/dck/agent-clis`; null without a running container or for an image from before v0.3.6). A requested list that differs from the installed one is a problem: **rebuild needed: dck rebuild**. The text report prints `agent CLIs mode / supported / requested / installed` |
| `ssh` | `enabled`, `port`, `bind`, `identity`, `identity_present`, `answering` (true only when sshd sends its `SSH-` banner on the published port — a bare TCP accept can be Docker's userland proxy; probed only when the container runs), `banner` |
| `herdr` | `installed`, `version`, `machine` (dck.toml), `alias`, `include_present`, `registered`, `enabled`, `server_answering` (`herdr status server` over SSH, only when registered and sshd answers); `peers_cli` (the herdr-peers `dck agents`/`dck ask` use: on PATH, else dck's verified host copy, else null), `host_ak` (coding-agents-kit's `ak` is on the host's PATH), `catalog` {`host_self`, `mirrored_dck`, `entries`} (what `dck herdr mesh` mirrors into containers: the host's own catalog entry and how many dck machines the host's catalog holds; null without herdr) |
| `drift` | [{`name`, `pinned`, `installed`, `status` (`ok`/`drift`/`unknown`), `note`}]: the kit the repository was rendered with (`kit`) vs the installed dck; the host's Herdr client vs the image pin (informative: they need not match); inside a running container built from a dck image, gh/herdr/nvim/deepworkplan-vim vs `images/versions.env` |
| `ssh_keys` | null outside a configured repository; else `enabled` (`[ssh] copy_keys` on and the host has `~/.ssh`), `reason` (why it is off), `host_keys` (the `id_*` file names of the host's `~/.ssh` the entrypoint copies), `copied` (the names the running container copied, from its `~/.ssh/.dck-copied-keys`; null without a running container). Names only, never a key's contents; the text report prints `ssh keys copied: <names>` |
| `herdr.id`, `herdr.self_inside` | the container's machine id in the host's Herdr catalog, and the id the running container exports as `HERDR_PEERS_SELF` (absent without a running container). A problem when they differ: asks from Codex panes would find no reply route |
| `compose` | null outside a configured repository or without a Docker daemon; else `project` (resolved like the launcher: `[compose] project` in dck.toml, then `COMPOSE_PROJECT_NAME` in the environment, then in the compose directory's `.env`, then the compose file's `name:`), `state_volume` (`<project>_<[compose] state_volume>`), `services` (the project's other services), `shared_with` (other services mounting this service's state volume). A problem when `shared_with` is not empty, or when the project has other services and `state_volume` is the default `state` |
| `host_profiles` | null outside a configured repository; else `enabled`, `reason` (why it is off), `shared` (CLIs whose host ak profiles `dck up` binds), `profiles` (the shared profiles as `cli@name`; the Codex home is `codex@default`), `mounts` [{`profile`, `mode` (`ro`/`rw`), `reason`}] (every shared directory and the env file), `codex` (the host's Codex home is shared), `codex_versions` ({`host`, `container`, `match`} when `codex@default` is shared: each side's `codex --version` number, or null; `match` is true/false when both are known, else null — `false` is a problem), `skipped` [{`cli`, `reason`}], `env_names` (names in the container's env file — never values), `notes` (the text report's lines) |
| `compose_render` | present in a configured repository: `stale` (`dck init` would change `docker/local/docker-compose.yaml`), `overrides` (the dck keys the user block's `x-dck-merge` replaces, or whose map entries it overrides, as `key.entry`), `error`. A stale file or an error is a problem; the text report prints `user block overrides dck's …` |
| `git` | null without a running container; else the container user's `name`, `email`, `signing` (`gpg.format`, `ssh` or null) and `source` (the host's git config, `DCK_GIT_*` in the service `.env`, or both) |
| `os`, `python`, `profile` | host system/arch; python version and whether it is ≥ 3.11; the host profile in use and whether it is valid |
| `problems`, `ok` | human-readable findings; `ok` is true when there are none |

**Secrets.** `env_files[].keys_set` lists the *names* of variables that have a
value — never a value. The text report prints the same names. A `.env` readable
by other accounts is a problem (`dck setup` narrows it to 0600).

## What counts as a problem

- docker missing, or its daemon not answering; Docker Compose older than 2.24
  (satellites need `extends` with `!reset`/`!override`, and port strings);
- an invalid `devcontainer.json`, `dck.toml` or host profile, or no `dck.toml`;
- a missing, symlinked or group/other-readable `.env`;
- the rendered Dockerfile's base image (`ARG BASE_IMAGE`) pinned by tag only;
- `docker/local/<service>/dck/` differing from the installed kit's files;
- a compose file that does not reflect `dck.toml` or its user block (run `dck init`);
- a `bind` other than `127.0.0.1`;
- sshd not answering while the container runs;
- `herdr.machine = true` but the machine is not registered; `HERDR_PEERS_SELF`
  inside differing from the container's id in the host's catalog; with the host as
  a mesh peer, no entry for the host itself in its Herdr catalog;
- a compose project shared with other services while the state volume is the
  default `state`, or another service mounting this service's state volume;
- agent CLIs: the running image installed another list than the one requested
  (**rebuild needed: dck rebuild**);
- tool drift inside the container (gh, herdr, nvim, deepworkplan-vim), or a
  repository rendered with another dck tag (the host's Herdr client vs the image
  pin is informative only);
- with `[agents] host_profiles`: a `default_profile` mapping it cannot apply, a shared Claude profile that logs in through the macOS
  keychain without its token variable in the env file (run `claude setup-token`, then
  store the token in ak's env file — `~/.config/agentkit/env`, or `ak env import <file>` —
  as `CLAUDE_CODE_OAUTH_TOKEN_<SUFFIX>`, or
  `CLAUDE_CODE_OAUTH_TOKEN` for `@default`), a listed variable whose value
  could not be copied, and — when `codex@default` is shared — a host `codex --version`
  that differs from the container's (the shared `~/.codex` is read-write; a mismatched
  pair has corrupted that state DB; use a named profile inside, `ak codex @name`, or
  align the versions). Logins are read from the host's `ak profiles --json`
  (schema `profiles-v1`, coding-agents-kit v0.5.0+); without it the doctor says so.

The text report also says, as a note, when Claude's default account will not be logged
in inside: Claude's own home (`~/.claude`) is never shared — on macOS its login lives in
the keychain — so `@default` gets in only through `CLAUDE_CODE_OAUTH_TOKEN` in ak's env
file (`claude setup-token`), or through a login made once inside (`ak claude`), which the
container's `claude` volume keeps across recreates and rebuilds.

## What the doctor does not read

The doctor does not read DeepWorkPlan's `.dwp/config.json`: a DWP integrator
compares the registry's `devcontainer` version with `dck doctor --json`'s
`version` itself, so the product never depends on DWP.
