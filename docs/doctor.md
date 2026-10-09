# `dck doctor`

```bash
dck doctor            # human report
dck doctor --json     # machine report, interface 1 (docs/schema/dck-doctor-v1.json)
dck doctor --strict   # exit 1 while `problems` is not empty (CI)
```

The doctor works anywhere: outside a repository it reports the host only
(`repo`, `layers` and `ssh` are `null`). Every probe has a timeout and
degrades to `null`/`false` with a reason instead of failing — a broken
machine still gets an answer. Exit status is 0 (or 1 with `--strict` and
problems), 2 on a usage error.

## The JSON report (interface 1)

Integrators (the DeepWorkPlan `devcontainer` addon, scripts, agents) read
`interface` first and treat an unknown value as "not compatible" — one warning,
never an error. Within interface 1 keys may be **added**, never removed or
retyped.

| Key | Content |
| --- | --- |
| `interface` | `1` |
| `version` | the installed dck version (`0.1.0`) |
| `runtime` | `docker` {`cli`, `version`, `daemon`, `server_version`, `reason`}, `provider` (`docker-desktop`, `orbstack`, `colima`, `podman`, `docker-engine` or null), `compose.version`, `devcontainer_cli` {`installed`, `version`} |
| `repo` | `path`, `devcontainer`, `config_valid`, `errors`, `warnings`, `flavour`, `image_tag`, `base_image` (as pinned in compose), `digest_pinned`, `digest_match` (null until the image is pulled locally), `project`, `service`, `container` {`name`, `state`}, `env_files` [{`path`, `present`, `mode`, `private`, `keys_set`}] |
| `layers` | `agents`, `clis`, `dailybot`, `editor` |
| `ssh` | `enabled`, `port`, `bind`, `identity`, `identity_present`, `answering` (a TCP connect to the published port, only when the container runs), `banner` |
| `herdr` | `installed`, `version`, `machine` (dck.toml), `alias`, `include_present`, `registered`, `enabled`, `server_answering` |
| `drift` | [{`name`, `pinned`, `installed`, `status` (`ok`/`drift`/`unknown`), `note`}]: the repository's `image_tag` vs the installed dck; the host's Herdr client vs the image pin (informative: they need not match); inside a running container built from a dck image, gh/herdr/nvim/deepworkplan-vim vs `images/versions.env` |
| `os`, `python`, `profile` | host system/arch; python version and whether it is ≥ 3.11; the host profile in use and whether it is valid |
| `problems`, `ok` | human-readable findings; `ok` is true when there are none |

**Secrets.** `env_files[].keys_set` lists the *names* of variables that have a
value — never a value. The text report prints the same names. A `.env` readable
by other accounts is a problem (`dck setup` narrows it to 0600).

## What counts as a problem

- docker missing, or its daemon not answering;
- an invalid `devcontainer.json`, `dck.toml` or host profile;
- a missing or group/other-readable `.env`;
- a base image pinned by tag only, or a local image whose digest differs from
  the pin;
- a `bind` other than `127.0.0.1`;
- sshd not answering while the container runs;
- `herdr.machine = true` but the machine is not registered;
- tool drift inside the container, or a repository pinned to another dck tag.

## Not in v0.1

The doctor does not read DeepWorkPlan's `.dwp/config.json`: a DWP integrator
compares the registry's `devcontainer` version with `dck doctor --json`'s
`version` itself, so the product never depends on DWP.
