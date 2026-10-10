# shellcheck shell=bash
#
# lib/launcher.sh — the dck verbs.
#
# devcontainer.json is the single source of truth: `runServices` decides what
# starts, `remoteUser`/`workspaceFolder` how the main service is entered, and
# its `mounts`/`containerEnv` are reproduced for plain compose. dck.toml adds
# the host-side settings (ssh port, Herdr machine). No repository is known by
# name: everything is read from the repository dck runs in.
#
# Ported from the deepworkplan-website dev.sh launcher (env/network bootstrap,
# overlay writer, verbs), pereiratechtalks.com's `ssh [cmd]` verb and the
# hub's generic core.

# Verbs that act on a repository (they load its devcontainer.json first).
DCK_CORE_VERBS=" setup up down stop start restart ps logs shell exec build rebuild config ports ssh "
DCK_VERBS=" init help$DCK_CORE_VERBS"

# --------------------------------------------------------------------------
# Help
# --------------------------------------------------------------------------

dck_usage() {
  cat <<'EOF'
dck — devcontainer-kit: a repository's dev container from a plain terminal

usage: dck [--repo DIR] [--profile NAME] [--project NAME] [--trust] <verb> [args]

  --trust               start a repository whose own config reaches the host
                        (initializeCommand, privileged, Docker socket, host mounts)

  init [flags]          render the Dev Container template into this repository
  setup                 .env files from their examples (0600), external networks,
                        the dedicated dck SSH key
  up [--recreate] [svc...]   start runServices (detached); registers the Herdr
                        machine when dck.toml asks for it
  down [svc...]         stop and remove this repository's services (volumes kept)
  stop [svc...]         stop the containers (kept)
  start [svc...]        start stopped containers
  restart [svc...]
  ps [svc...]           containers of this repository
  logs [--no-follow] [svc...]
  shell [svc] [-c CMD]  a login shell (or one command) as remoteUser in workspaceFolder
  exec <svc> <cmd...>   run a command in a service
  build [--no-cache] [svc...]
  rebuild [--no-cache] [svc...]   build, then recreate the containers
  config                what dck resolved for this repository
  ports                 the published loopback ports
  ssh [cmd...]          ssh into the container with agent forwarding
  herdr add|status|repair|remove|mesh   the container as a Herdr machine; mesh: reach the others from inside
  herdr layout [--keep|--reset]   the standard sidebar inside: Home · Editor · Development · Agents
  agents                the live agents on every Herdr machine (herdr-peers list)
  ask <machine>:<pane> "<prompt>"   ask one of them, with the reply grant (herdr-peers ask)
  doctor [--json] [--strict]   environment and repository health (interface 1)
  --skill               print the bundled agent skill
  help [verb]           this text, or one verb's details
  --version             print the version

Exit codes: 0 ok, 1 failed, 2 usage, 3 configuration, 4 environment
(docker/python missing or not answering), 5 refused (a safety rule).
Docs: https://github.com/DailybotHQ/devcontainer-kit/tree/main/docs
EOF
}

dck_help_verb() {
  case "$1" in
    init) dck_help_init ;;
    *) dck_usage ;;
  esac
}

dck_help_init() {
  cat <<'EOF'
usage: dck init [flags]

Renders .devcontainer/{devcontainer.json,dck.toml}, docker/local/docker-compose.yaml,
docker/local/<service>/{Dockerfile,.env.example} and a .gitignore guard into the
repository (the git top-level of the current directory, or --repo DIR).

Existing files are reconciled: dck changes only what it owns (managed blocks,
owned devcontainer.json keys, values given as flags in dck.toml). Any change to an
existing file is shown as a diff and needs consent: --yes, or "y" at the prompt.
Replaced files are backed up as <file>.dck-bak-<timestamp>. Without consent nothing
is written and dck exits 5.

  --flavour python-3.13|node-24|debian   (default: detected from the repo)
  --service NAME       compose service (default app)
  --user NAME          remoteUser (default dev)
  --workspace PATH     workspaceFolder (default /workspace)
  --ssh-port N         loopback sshd port, 0 = none (default: derived from the repo name)
  --port NAME=N        a named loopback port (repeatable)
  --agents | --no-agents       the agents layer (coding-agents-kit)
  --clis "claude codex"        kinds for `ak install` when agents is on
  --editor | --no-editor       the editor layer
  --herdr | --no-herdr         register as a Herdr machine on `dck up`
  --dry-run            show the plan and the diffs, write nothing
  --yes, -y            consent to every change shown
  --repo DIR           the repository to initialise
EOF
}

# --------------------------------------------------------------------------
# Context: repository, devcontainer.json, compose project
# --------------------------------------------------------------------------

dck_config_home() {
  printf '%s\n' "${DCK_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/dck}"
}

load_context() {
  [ -n "${DC_REPO:-}" ] && return 0
  local repo line k v
  if [ -n "$DCK_REPO_ARG" ]; then
    [ -d "$DCK_REPO_ARG" ] || die "$DCK_EXIT_USAGE" "--repo: $DCK_REPO_ARG is not a directory"
    repo="$(cd -P "$DCK_REPO_ARG" && pwd)"
  else
    repo="$(dckpy devc find --start "$PWD")" || exit "$DCK_EXIT_CONFIG"
  fi
  DC_COMPOSE_FILES=()
  local args=(devc read --repo "$repo")
  [ -n "$DCK_PROFILE_NAME" ] && args+=(--profile "$DCK_PROFILE_NAME")
  local out
  out="$(dckpy "${args[@]}")" || exit "$DCK_EXIT_CONFIG"
  DCK_HAS_TOML=0; DCK_SSH_PORT=0; DCK_BIND=127.0.0.1; DCK_ALIAS=""; DCK_HERDR_MACHINE=0
  DCK_HERDR_LABEL=""; DCK_PORTS=""; DCK_SSH_IDENTITY=""; DCK_FLAVOUR=""
  export DCK_HOST_MACHINE="0"  # read by lib/herdr.sh (herdr_mesh)
  export DCK_HERDR_LAYOUT="standard"  # read by lib/herdr.sh (herdr_layout)
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      DC_COMPOSE_FILE) DC_COMPOSE_FILES+=("$v") ;;
      DC_REPO|DC_FILE|DC_SERVICE|DC_RUNSERVICES|DC_USER|DC_WORKSPACE|DC_SHUTDOWN|DC_MOUNTS|DC_ENVS|DC_COMPOSE_NAME) printf -v "$k" '%s' "$v" ;;
      DCK_HAS_TOML|DCK_SSH_PORT|DCK_BIND|DCK_ALIAS|DCK_SSH_IDENTITY|DCK_HERDR_MACHINE|DCK_HERDR_LABEL|DCK_NETWORK|DCK_FLAVOUR|DCK_HOST_MACHINE|DCK_HERDR_LAYOUT|DCK_PORTS|DCK_TOML_USER) printf -v "$k" '%s' "$v" ;;
    esac
  done <<EOF
$out
EOF
  DC_COMPOSE="${DC_COMPOSE_FILES[0]}"
  COMPOSE_DIR="$(cd -P "$(dirname "$DC_COMPOSE")" && pwd)"
  resolve_project
}

# The compose project name. Never the directory-name default: compose would
# name it after docker/local/, which is not what the editor plugin uses, and a
# second, parallel set of containers would fight the real one over ports.
resolve_project() {
  PROJECT=""; PROJECT_FROM=""
  if [ -n "$DCK_PROJECT_OVERRIDE" ]; then
    PROJECT="$DCK_PROJECT_OVERRIDE"; PROJECT_FROM="--project"
  elif [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    PROJECT="$COMPOSE_PROJECT_NAME"; PROJECT_FROM="COMPOSE_PROJECT_NAME in the environment"
  else
    local v=""
    if [ -f "$COMPOSE_DIR/.env" ] && [ ! -L "$COMPOSE_DIR/.env" ]; then
      v="$(sed -n 's/^[[:space:]]*COMPOSE_PROJECT_NAME[[:space:]]*=[[:space:]]*\(.*\)$/\1/p' "$COMPOSE_DIR/.env" | tail -1)"
      v="${v%\"}"; v="${v#\"}"
    fi
    if [ -n "$v" ]; then
      PROJECT="$v"; PROJECT_FROM="COMPOSE_PROJECT_NAME in ${COMPOSE_DIR#"$DC_REPO"/}/.env"
    elif [ -n "$DC_COMPOSE_NAME" ]; then
      PROJECT="$DC_COMPOSE_NAME"; PROJECT_FROM="name: in ${DC_COMPOSE#"$DC_REPO"/}"
    fi
  fi
  [ -n "$PROJECT" ] || die "$DCK_EXIT_REFUSED" "refusing the directory-name default compose project — add a top-level 'name:' to ${DC_COMPOSE#"$DC_REPO"/} (dck init does), set COMPOSE_PROJECT_NAME, or pass --project"
  case "$PROJECT" in
    *[!a-z0-9_-]*|[!a-z0-9]*) die "$DCK_EXIT_CONFIG" "invalid compose project name '$PROJECT' (lower-case letters, digits, - and _)" ;;
  esac
  case "$PROJECT_FROM" in
    --project) ;;
    *)
      case "$PROJECT" in
        *"$(basename "$DC_REPO" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_\n-' '-')"*) ;;
        *) warn "note: compose project '$PROJECT' (from $PROJECT_FROM) is not named after this repository; down/stop act on its services in that project" ;;
      esac
      ;;
  esac
}

# compose | devcontainer. `devcontainer up/exec` when @devcontainers/cli is
# installed (it applies features and the plugin's own overlay), compose
# otherwise. DCK_BACKEND forces one. A --project override always uses compose,
# which is the only path that takes an explicit project name.
resolve_backend() {
  case "${DCK_BACKEND:-auto}" in
    compose) BACKEND=compose ;;
    devcontainer)
      command -v devcontainer >/dev/null 2>&1 || die "$DCK_EXIT_ENV" "DCK_BACKEND=devcontainer but the devcontainer CLI is not installed"
      BACKEND=devcontainer ;;
    auto)
      if [ -z "$DCK_PROJECT_OVERRIDE" ] && command -v devcontainer >/dev/null 2>&1; then BACKEND=devcontainer; else BACKEND=compose; fi ;;
    *) die "$DCK_EXIT_USAGE" "DCK_BACKEND must be auto, compose or devcontainer" ;;
  esac
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "$DCK_EXIT_ENV" "docker is not on PATH — install Docker (Desktop, OrbStack or colima)"
}

# --------------------------------------------------------------------------
# Compose invocation and the devcontainer overlay
# --------------------------------------------------------------------------

# Pure: names the overlay without creating anything (config must not write).
overlay_path() {
  local base="${TMPDIR:-/tmp}"
  printf '%s/dck-%s/%s-overlay.yml' "${base%/}" "$(id -u)" "$PROJECT"
}

# The overlay directory is created with its mode already applied and never
# reused unless we own it: the /tmp fallback is world-writable, so another
# account could plant it (and the overlay names mounts and environment).
ensure_overlay_dir() {
  local d
  d="$(dirname "$(overlay_path)")"
  (umask 077 && mkdir -p "$d") 2>/dev/null || die "could not create $d"
  if [ -L "$d" ] || [ ! -d "$d" ] || [ ! -O "$d" ]; then
    die "$DCK_EXIT_REFUSED" "$d is not a directory you own — refusing to write the compose overlay there; remove it or set TMPDIR"
  fi
  chmod 700 "$d"
}

write_overlay() {
  if [ "$DC_MOUNTS" = "0" ] && [ "$DC_ENVS" = "0" ]; then return 0; fi
  ensure_overlay_dir
  dckpy devc overlay --repo "$DC_REPO" --project "$PROJECT" --out "$(overlay_path)" >/dev/null
}

# NOTE: --remove-orphans is never passed and must not be added. A compose
# project may be shared, or declare services beyond runServices; with the flag,
# starting the declared services would delete containers someone else uses.
dc() {
  require_docker
  local args=(-p "$PROJECT") f
  for f in "${DC_COMPOSE_FILES[@]}"; do args+=(-f "$f"); done
  if { [ "$DC_MOUNTS" != "0" ] || [ "$DC_ENVS" != "0" ]; } && [ -f "$(overlay_path)" ]; then
    args+=(-f "$(overlay_path)")
  fi
  docker compose "${args[@]}" "$@"
}

selected_services() {
  SERVICES=()
  local s
  if [ $# -gt 0 ]; then
    SERVICES=("$@")
  else
    for s in $DC_RUNSERVICES; do SERVICES+=("$s"); done
  fi
  [ "${#SERVICES[@]}" -gt 0 ] || die "$DCK_EXIT_CONFIG" "no services to act on — ${DC_FILE#"$DC_REPO"/} declares neither runServices nor service"
}

# --------------------------------------------------------------------------
# Environment files, networks, host binds, the dck SSH identity
# --------------------------------------------------------------------------

file_mode() {
  if stat --version >/dev/null 2>&1; then stat -c '%a' "$1" 2>/dev/null; else stat -f '%Lp' "$1" 2>/dev/null; fi
}

group_or_other_readable() {
  local m
  m="$(file_mode "$1")"
  [ -n "$m" ] || return 1
  [ "$(( 8#$m & 8#077 ))" -ne 0 ]
}

# Regular .env*.example files inside the repository, never through a link and
# never with a control character in the name (see lib/devc.py env_examples).
env_examples() {
  [ -d "$COMPOSE_DIR" ] || return 0
  dckpy devc env-examples --dir "$COMPOSE_DIR" --repo "$DC_REPO"
}

# .env files are created from their example at 0600, so a key pasted later is
# never readable by other accounts. Existing files are never overwritten.
ensure_env_from_examples() {
  local f target
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    target="${f%.example}"
    if [ -L "$target" ] || [ -L "$f" ]; then
      warn "${target#"$DC_REPO"/}: a symlink is involved; not created (dck never writes .env files through a link)"
      continue
    fi
    [ -f "$target" ] && continue
    (umask 077 && cat "$f" > "$target") || die "could not create $target"
    note "created ${target#"$DC_REPO"/} from ${f#"$DC_REPO"/} (0600)"
    ENV_CREATED=$((ENV_CREATED + 1))
  done <<EOF
$(env_examples)
EOF
}

# ensure_git_identity_env — copy the host's git identity (user.name, user.email
# and the signing settings, when set) into each service .env as DCK_GIT_*, only
# where the key is absent. Values are written, never printed.
ensure_git_identity_env() {
  GIT_ID_SET=0
  command -v git >/dev/null 2>&1 || return 0
  local f target pair key var value
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    target="${f%.example}"
    [ -f "$target" ] && [ ! -L "$target" ] || continue
    for pair in user.name=DCK_GIT_NAME user.email=DCK_GIT_EMAIL user.signingkey=DCK_GIT_SIGNINGKEY \
                gpg.format=DCK_GIT_GPG_FORMAT commit.gpgsign=DCK_GIT_COMMIT_GPGSIGN; do
      key="${pair%%=*}"; var="${pair#*=}"
      grep -q "^${var}=" "$target" && continue
      value="$(git config --global --get "$key" 2>/dev/null || true)"
      [ -n "$value" ] || continue
      case "$value" in *"
"*) continue ;; esac
      printf '%s=%s\n' "$var" "$value" >> "$target" || die "could not update $target"
      GIT_ID_SET=$((GIT_ID_SET + 1))
    done
  done <<EOF
$(env_examples)
EOF
  [ "$GIT_ID_SET" -eq 0 ] || note "setup: wrote $GIT_ID_SET git identity setting(s) from your git config into the service .env"
}

# warn_empty_ssh_agent — git over SSH inside the container signs with keys the
# HOST's agent holds (no key is copied in). An agent with no identity means git
# push will fail inside: say how to load the key, once, at setup.
warn_empty_ssh_agent() {
  command -v ssh-add >/dev/null 2>&1 || return 0
  local rc=0
  ssh-add -l >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) if [ "$(uname -s)" = "Darwin" ]; then
         warn "your ssh-agent holds no keys: git over SSH inside the container uses the host agent (no key is copied in). Load your git key once: ssh-add --apple-use-keychain ~/.ssh/<your key>"
       else
         warn "your ssh-agent holds no keys: git over SSH inside the container uses the host agent (no key is copied in). Load your git key: ssh-add ~/.ssh/<your key>"
       fi ;;
    *) warn "no ssh-agent is running on this host: git over SSH inside the container needs one (keys are never copied in)" ;;
  esac
}

# export_host_ssh_agent — the compose file mounts ${DCK_HOST_SSH_AUTH_SOCK} as the
# container's SSH agent. Docker Desktop's default path needs nothing; on a Linux
# host it is the user's own agent socket.
export_host_ssh_agent() {
  [ -n "${DCK_HOST_SSH_AUTH_SOCK:-}" ] && return 0
  if [ "$(uname -s)" = "Linux" ] && [ -S "${SSH_AUTH_SOCK:-}" ]; then
    export DCK_HOST_SSH_AUTH_SOCK="$SSH_AUTH_SOCK"
  fi
  return 0
}

ensure_external_networks() {
  local net f
  for f in "${DC_COMPOSE_FILES[@]}"; do
    while IFS= read -r net; do
      [ -n "$net" ] || continue
      if docker network inspect "$net" >/dev/null 2>&1; then
        [ "${1:-}" = "verbose" ] && note "network $net already present"
        continue
      fi
      docker network create "$net" >/dev/null || die "could not create docker network $net"
      note "created docker network $net"
    done <<EOF
$(dckpy devc networks --file "$f")
EOF
  done
}

# Host paths a compose file bind-mounts through ${HOME}: when one is missing,
# Docker creates a DIRECTORY there and mounts it (~/.gitconfig becomes a folder).
warn_missing_host_binds() {
  local f b
  for f in "${DC_COMPOSE_FILES[@]}"; do
    sed -n 's/^[[:space:]]*-[[:space:]]*["]*\${HOME}\(\/[^:]*\):.*$/\1/p' "$f"
  done | LC_ALL=C sort -u | while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ -e "$HOME$b" ] || warn "\$HOME$b does not exist — Docker will create a directory there and mount it"
  done
}

# ~/... for display only.
# shellcheck disable=SC2088  # a literal ~ is the point: display only
pretty_path() {
  case "$1" in
    "$HOME"/*) printf '~/%s\n' "${1#"$HOME"/}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# dck forwards your SSH agent only to 127.0.0.1. A dck.toml `bind` other than
# loopback or 0.0.0.0 means the port is not on loopback: refuse rather than
# follow a repository-chosen address with your agent.
ssh_bind_reachable_on_loopback() {
  case "$DCK_BIND" in
    127.0.0.1|0.0.0.0) return 0 ;;
    *) die "$DCK_EXIT_REFUSED" "dck.toml binds ports to $DCK_BIND; dck connects with your forwarded agent only to 127.0.0.1 — use bind = \"127.0.0.1\" (or 0.0.0.0) to ssh or register a Herdr machine" ;;
  esac
}

ssh_enabled() { [ "$DCK_HAS_TOML" = "1" ] && [ "${DCK_SSH_PORT:-0}" != "0" ]; }

# The dedicated key dck authorizes inside containers. It is generated once,
# on the host, and is never copied into a container: the container only gets
# its PUBLIC half. Your own keys reach the container through agent forwarding.
dck_identity_ensure() {
  local id="$DCK_SSH_IDENTITY"
  [ -n "$id" ] || return 0
  [ -f "$id" ] && [ -f "$id.pub" ] && return 0
  command -v ssh-keygen >/dev/null 2>&1 || die "$DCK_EXIT_ENV" "ssh-keygen is not on PATH"
  if [ -f "$id" ]; then
    (umask 022 && ssh-keygen -y -f "$id" > "$id.pub") </dev/null || die "could not derive $id.pub from $id"
    note "restored the public half of the dck SSH key"
    return 0
  fi
  (umask 077 && mkdir -p "$(dirname "$id")") || die "could not create $(dirname "$id")"
  chmod 700 "$(dirname "$id")"
  ssh-keygen -q -t ed25519 -N '' -C "dck@$(hostname 2>/dev/null || echo host)" -f "$id" </dev/null >/dev/null \
    || die "could not generate $id"
  note "created the dck SSH key $(pretty_path "$id") (authorized only inside dck containers)"
}

export_authorized_keys() {
  if ssh_enabled && [ -f "$DCK_SSH_IDENTITY.pub" ]; then
    DCK_AUTHORIZED_KEYS="$(cat "$DCK_SSH_IDENTITY.pub")"
    export DCK_AUTHORIZED_KEYS
  fi
}

# The repository's devcontainer.json and compose file run on YOUR Docker
# daemon. dck-rendered setups contain nothing that reaches the host; a hand-
# written one may (initializeCommand, privileged, the Docker socket, host
# mounts). Those need an explicit --trust (or DCK_TRUST=1) once you have read them.
preflight_check() {
  [ "${DCK_TRUST:-0}" = "1" ] && return 0
  local found
  if found="$(dckpy devc preflight --repo "$DC_REPO")"; then return 0; fi
  [ -n "$found" ] || exit "$DCK_EXIT_CONFIG"
  printf 'dck: this repository'"'"'s container configuration reaches the host:\n' >&2
  printf '%s\n' "$found" | sed 's/^/  - /' >&2
  die "$DCK_EXIT_REFUSED" "review it, then re-run with --trust (or DCK_TRUST=1) to start it anyway"
}

# Everything `up`, `start`, `build` need before compose runs.
fast_check() {
  preflight_check
  ENV_CREATED=0
  ensure_env_from_examples
  ensure_external_networks
  warn_missing_host_binds
  if ssh_enabled; then dck_identity_ensure; fi
  export_authorized_keys
}

# shellcheck disable=SC2120  # the service argument is optional (default: the main service)
container_running() {
  local s="${1:-$DC_SERVICE}" names
  # Captured, then tested: piping docker into `grep -q` under pipefail fails
  # when grep exits early and docker dies of SIGPIPE.
  names="$(docker ps --filter "label=com.docker.compose.project=$PROJECT" \
                     --filter "label=com.docker.compose.service=$s" \
                     --format '{{.Names}}' 2>/dev/null || true)"
  [ -n "$names" ]
}

# --------------------------------------------------------------------------
# Verbs
# --------------------------------------------------------------------------

cmd_setup() {
  [ $# -eq 0 ] || die "$DCK_EXIT_USAGE" "setup takes no arguments"
  local changed=0 f target
  ENV_CREATED=0
  ensure_env_from_examples
  changed=$((changed + ENV_CREATED))
  ensure_git_identity_env
  changed=$((changed + GIT_ID_SET))
  warn_empty_ssh_agent
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    target="${f%.example}"
    if [ -f "$target" ] && [ ! -L "$target" ] && group_or_other_readable "$target"; then
      # Narrowing cannot un-expose a secret already readable, but leaving it
      # open guarantees the next one is exposed too. Announced, never silent.
      chmod 600 "$target" || die "could not restrict $target to 0600"
      note "narrowed ${target#"$DC_REPO"/} to 0600 (it was readable by other accounts)"
      changed=$((changed + 1))
    fi
  done <<EOF
$(env_examples)
EOF
  if command -v docker >/dev/null 2>&1; then
    ensure_external_networks verbose
  else
    warn "docker is not on PATH — external networks not checked"
  fi
  if ssh_enabled && [ ! -f "$DCK_SSH_IDENTITY" ]; then
    dck_identity_ensure
    changed=$((changed + 1))
  fi
  warn_missing_host_binds
  if [ "$changed" -eq 0 ]; then note "setup: everything was already in place"; else note "setup: done"; fi
}

cmd_up() {
  local recreate=0 args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --recreate) recreate=1 ;;
      -*) die "$DCK_EXIT_USAGE" "up: unknown flag '$1'" ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  require_docker
  fast_check
  export_host_ssh_agent
  resolve_backend
  selected_services ${args[@]+"${args[@]}"}
  if [ "$BACKEND" = devcontainer ] && [ "${#args[@]}" -eq 0 ]; then
    note "starting ${SERVICES[*]} with the devcontainer CLI (project $PROJECT)"
    if [ "$recreate" -eq 1 ]; then
      devcontainer up --workspace-folder "$DC_REPO" --remove-existing-container
    else
      devcontainer up --workspace-folder "$DC_REPO"
    fi
  else
    write_overlay
    note "starting ${SERVICES[*]} (project $PROJECT)"
    if [ "$recreate" -eq 1 ]; then
      dc up -d --force-recreate "${SERVICES[@]}"
    else
      # --no-recreate: a second `up` is a no-op, not a replacement. A container
      # the editor plugin created carries the plugin's overlay, so a plain `up`
      # would silently recreate it. --recreate applies compose changes on purpose.
      dc up -d --no-recreate "${SERVICES[@]}"
      note "existing containers were left as they are; use --recreate to apply compose changes"
    fi
  fi
  if [ "${DCK_HERDR_MACHINE:-0}" = "1" ] && declare -F dck_herdr_after_up >/dev/null 2>&1; then
    dck_herdr_after_up || warn "the container is up, but Herdr registration did not complete — run: dck herdr status"
  fi
}

cmd_down() {
  selected_services "$@"
  # Only this repository's services. Never `compose down`, which acts on the
  # whole project and would take out anything else sharing it.
  note "stopping and removing ${SERVICES[*]} (project $PROJECT)"
  dc rm -sf "${SERVICES[@]}"
  note "named volumes were kept; list them with: docker volume ls --filter name=${PROJECT}_"
}

cmd_simple() {
  local verb="$1"; shift
  # `stop` skips the checks: refusing to STOP a stack because an env file went
  # missing would strand it with no way out but raw compose.
  if [ "$verb" != stop ]; then fast_check; write_overlay; fi
  selected_services "$@"
  dc "$verb" "${SERVICES[@]}"
}

cmd_ps() {
  selected_services "$@"
  dc ps "${SERVICES[@]}"
}

cmd_logs() {
  local follow=(-f) args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-follow) follow=() ;;
      -*) die "$DCK_EXIT_USAGE" "logs: unknown flag '$1'" ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  selected_services ${args[@]+"${args[@]}"}
  dc logs ${follow[@]+"${follow[@]}"} --tail 200 "${SERVICES[@]}"
}

# remoteUser and workspaceFolder describe the MAIN service only: a backing
# service has no such user ("unable to find user dev").
exec_opts() {
  EXEC_OPTS=()
  # Without a terminal on stdin, compose must not try to allocate one.
  [ -t 0 ] || EXEC_OPTS+=(-T)
  [ "$1" = "$DC_SERVICE" ] || return 0
  if [ -n "$DC_USER" ]; then
    # docker exec inherits PID 1's HOME=/root; a non-root shell needs these.
    EXEC_OPTS+=(--user "$DC_USER" -e "HOME=/home/$DC_USER" -e "USER=$DC_USER" -e "LOGNAME=$DC_USER")
  fi
  [ -n "$DC_WORKSPACE" ] && EXEC_OPTS+=(-w "$DC_WORKSPACE")
  return 0
}

cmd_shell() {
  local service="" cmd="" have_cmd=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -c) [ $# -ge 2 ] || die "$DCK_EXIT_USAGE" "shell -c needs a command"; cmd="$2"; have_cmd=1; shift 2 ;;
      -*) die "$DCK_EXIT_USAGE" "shell: unknown flag '$1'" ;;
      *) [ -z "$service" ] || die "$DCK_EXIT_USAGE" "shell takes one service"; service="$1"; shift ;;
    esac
  done
  service="${service:-$DC_SERVICE}"
  resolve_backend
  # A LOGIN shell: /etc/profile.d holds the PATH ordering and the env profile
  # that ssh sessions use too, so `dck shell` and Herdr panes agree.
  local sh_args=(-l)
  [ "$have_cmd" -eq 1 ] && sh_args=(-lc "$cmd")
  if [ "$BACKEND" = devcontainer ] && [ "$service" = "$DC_SERVICE" ]; then
    devcontainer exec --workspace-folder "$DC_REPO" bash "${sh_args[@]}"
    return
  fi
  exec_opts "$service"
  local shellbin=sh
  # </dev/null: the probe must not swallow this script's stdin.
  if dc exec -T "$service" sh -c 'command -v bash' </dev/null >/dev/null 2>&1; then shellbin=bash; fi
  dc exec ${EXEC_OPTS[@]+"${EXEC_OPTS[@]}"} "$service" "$shellbin" "${sh_args[@]}"
}

cmd_exec() {
  [ $# -ge 2 ] || die "$DCK_EXIT_USAGE" "exec needs a service and a command: dck exec <service> <cmd...>"
  local service="$1"; shift
  [ "${1:-}" = "--" ] && shift
  [ $# -ge 1 ] || die "$DCK_EXIT_USAGE" "exec needs a command"
  resolve_backend
  if [ "$BACKEND" = devcontainer ] && [ "$service" = "$DC_SERVICE" ]; then
    devcontainer exec --workspace-folder "$DC_REPO" "$@"
    return
  fi
  exec_opts "$service"
  dc exec ${EXEC_OPTS[@]+"${EXEC_OPTS[@]}"} "$service" "$@"
}

parse_build_flags() {
  NO_CACHE=0; BUILD_SERVICES=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-cache) NO_CACHE=1 ;;
      -*) die "$DCK_EXIT_USAGE" "unknown flag '$1'" ;;
      *) BUILD_SERVICES+=("$1") ;;
    esac
    shift
  done
}

cmd_build() {
  parse_build_flags "$@"
  fast_check
  write_overlay
  selected_services ${BUILD_SERVICES[@]+"${BUILD_SERVICES[@]}"}
  if [ "$NO_CACHE" -eq 1 ]; then
    note "building ${SERVICES[*]} (--no-cache --pull, project $PROJECT)"
    dc build --no-cache --pull "${SERVICES[@]}"
  else
    dc build "${SERVICES[@]}"
  fi
}

# The terminal equivalent of "Rebuild and Reopen in Container": rebuild the
# images and replace the containers. Named volumes are kept.
cmd_rebuild() {
  parse_build_flags "$@"
  fast_check
  resolve_backend
  selected_services ${BUILD_SERVICES[@]+"${BUILD_SERVICES[@]}"}
  if [ "$BACKEND" = devcontainer ] && [ "${#BUILD_SERVICES[@]}" -eq 0 ]; then
    note "rebuilding with the devcontainer CLI (project $PROJECT)"
    if [ "$NO_CACHE" -eq 1 ]; then
      devcontainer up --workspace-folder "$DC_REPO" --remove-existing-container --build-no-cache
    else
      dc build "${SERVICES[@]}"
      devcontainer up --workspace-folder "$DC_REPO" --remove-existing-container
    fi
  else
    write_overlay
    if [ "$NO_CACHE" -eq 1 ]; then
      note "rebuilding ${SERVICES[*]} (--no-cache --pull, project $PROJECT)"
      dc build --no-cache --pull "${SERVICES[@]}"
    else
      note "rebuilding ${SERVICES[*]} (project $PROJECT)"
      dc build "${SERVICES[@]}"
    fi
    note "recreating ${SERVICES[*]} with the new images"
    dc up -d --force-recreate "${SERVICES[@]}"
  fi
  note "rebuild done — named volumes were kept; open a new shell so PATH reloads"
}

cmd_config() {
  [ $# -eq 0 ] || die "$DCK_EXIT_USAGE" "config takes no arguments"
  local f
  resolve_backend
  note "repository       $DC_REPO"
  note "devcontainer     ${DC_FILE#"$DC_REPO"/}"
  for f in "${DC_COMPOSE_FILES[@]}"; do note "compose file     ${f#"$DC_REPO"/}"; done
  note "compose project  $PROJECT (from $PROJECT_FROM)"
  note "backend          $BACKEND"
  note "main service     ${DC_SERVICE:-<unset>}"
  note "runServices      ${DC_RUNSERVICES:-<unset>}"
  note "remoteUser       ${DC_USER:-<unset>}"
  note "workspaceFolder  ${DC_WORKSPACE:-<unset>}"
  note "shutdownAction   ${DC_SHUTDOWN:-<unset>}"
  if [ "$DC_MOUNTS" != "0" ] || [ "$DC_ENVS" != "0" ]; then
    note "overlay          $(overlay_path) ($DC_MOUNTS mount(s), $DC_ENVS containerEnv var(s); written on up/build)"
  else
    note "overlay          <none needed>"
  fi
  if [ "$DCK_HAS_TOML" = "1" ]; then
    note "dck.toml         .devcontainer/dck.toml (flavour $DCK_FLAVOUR)"
    note "ssh              $( [ "$DCK_SSH_PORT" = 0 ] && echo "off" || echo "$DCK_BIND:$DCK_SSH_PORT → 22, alias $DCK_ALIAS")"
    note "herdr machine    $( [ "$DCK_HERDR_MACHINE" = 1 ] && echo "on, label \"$DCK_HERDR_LABEL\"" || echo off)"
    note "ssh identity     $(pretty_path "$DCK_SSH_IDENTITY")"
  else
    note "dck.toml         <none> (run dck init for ssh, Herdr and ports)"
  fi
  note "profile          ${DCK_PROFILE_NAME:-default}"
}

cmd_ports() {
  [ $# -eq 0 ] || die "$DCK_EXIT_USAGE" "ports takes no arguments"
  [ "$DCK_HAS_TOML" = "1" ] || die "$DCK_EXIT_CONFIG" "no .devcontainer/dck.toml — run: dck init"
  local state="stopped" p
  if command -v docker >/dev/null 2>&1 && container_running; then state="running"; fi
  note "service $DC_SERVICE ($state), project $PROJECT"
  if [ "$DCK_SSH_PORT" != "0" ]; then
    note "  ssh    $DCK_BIND:$DCK_SSH_PORT -> 22"
  fi
  for p in $DCK_PORTS; do
    note "  $(printf '%-6s' "${p%%=*}") $DCK_BIND:${p#*=} -> ${p#*=}"
  done
  [ "$DCK_SSH_PORT" != "0" ] || [ -n "$DCK_PORTS" ] || note "  <no published ports>"
}

cmd_ssh() {
  [ "$DCK_HAS_TOML" = "1" ] || die "$DCK_EXIT_CONFIG" "no .devcontainer/dck.toml — run: dck init"
  [ "$DCK_SSH_PORT" != "0" ] || die "$DCK_EXIT_CONFIG" "ssh is off for this repository (ssh_port = 0 in dck.toml)"
  command -v ssh >/dev/null 2>&1 || die "$DCK_EXIT_ENV" "ssh is not on PATH"
  require_docker
  container_running || die "$DC_SERVICE is not running — run: dck up"
  [ -f "$DCK_SSH_IDENTITY" ] || die "$DCK_EXIT_CONFIG" "the dck SSH key $(pretty_path "$DCK_SSH_IDENTITY") is missing — run: dck setup && dck up"
  ssh_bind_reachable_on_loopback
  local host="127.0.0.1" kh
  kh="$(dck_config_home)/ssh/known_hosts"
  (umask 077 && mkdir -p "$(dirname "$kh")")
  # Agent forwarding, never key copies. accept-new: a fresh container is
  # trusted on first use, but a host key that CHANGES is refused (the key is
  # meant to survive rebuilds on the state volume). Entries are keyed by the
  # repository's alias, not host:port, so a port reused by another repository
  # never collides; dck's own known_hosts keeps ~/.ssh/known_hosts unchanged.
  # After deleting the state volume on purpose:
  #   ssh-keygen -R <alias> -f ~/.config/dck/ssh/known_hosts
  local cfg=()
  [ -n "${DCK_SSH_CONFIG:-}" ] && cfg=(-F "$DCK_SSH_CONFIG")
  ssh ${cfg[@]+"${cfg[@]}"} -p "$DCK_SSH_PORT" \
      -i "$DCK_SSH_IDENTITY" -o IdentitiesOnly=yes \
      -o ForwardAgent=yes \
      -o StrictHostKeyChecking=accept-new \
      -o HostKeyAlias="${DCK_ALIAS:-dck}" \
      -o UserKnownHostsFile="$kh" -o GlobalKnownHostsFile=/dev/null \
      "${DCK_TOML_USER:-${DC_USER:-dev}}@$host" "$@"
}

# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

dck_main() {
  DCK_PROFILE_NAME="${DCK_PROFILE:-}"
  DCK_PROJECT_OVERRIDE=""
  DCK_REPO_ARG=""
  local verb=""
  while [ $# -gt 0 ] && [ -z "$verb" ]; do
    case "$1" in
      --version|-V) note "devcontainer-kit $(dck_version)"; return 0 ;;
      --skill)
        if declare -F dck_print_skill >/dev/null 2>&1; then
          if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then dck_print_skill "$2"; else dck_print_skill; fi
          return $?
        fi
        die "$DCK_EXIT_FAIL" "--skill is not available in this build" ;;
      --profile) [ $# -ge 2 ] || die "$DCK_EXIT_USAGE" "--profile needs a name"; DCK_PROFILE_NAME="$2"; shift 2 ;;
      --trust) DCK_TRUST=1; export DCK_TRUST; shift ;;
      --project) [ $# -ge 2 ] || die "$DCK_EXIT_USAGE" "--project needs a name"; DCK_PROJECT_OVERRIDE="$2"; shift 2 ;;
      --repo) [ $# -ge 2 ] || die "$DCK_EXIT_USAGE" "--repo needs a directory"; DCK_REPO_ARG="$2"; shift 2 ;;
      -h|--help) verb="help"; shift ;;
      -*) die "$DCK_EXIT_USAGE" "unknown flag '$1' — run: dck help" ;;
      *)
        case "$DCK_VERBS" in
          *" $1 "*) verb="$1"; shift ;;
          *) die "$DCK_EXIT_USAGE" "unknown verb '$1' — run: dck help" ;;
        esac
        ;;
    esac
  done
  [ -n "$verb" ] || verb="help"
  case "$verb" in
    help) dck_help_verb "${1:-}"; return 0 ;;
    init)
      local a=()
      [ -n "$DCK_PROFILE_NAME" ] && a+=(--profile "$DCK_PROFILE_NAME")
      [ -n "$DCK_REPO_ARG" ] && a+=(--repo "$DCK_REPO_ARG")
      dckpy init ${a[@]+"${a[@]}"} "$@"
      return $?
      ;;
  esac
  case "$DCK_CORE_VERBS" in
    *" $verb "*) load_context ;;
    *) dck_dispatch_extra "$verb" "$@"; return $? ;;
  esac
  case "$verb" in
    setup)   cmd_setup "$@" ;;
    up)      cmd_up "$@" ;;
    down)    cmd_down "$@" ;;
    stop|start|restart) cmd_simple "$verb" "$@" ;;
    ps)      cmd_ps "$@" ;;
    logs)    cmd_logs "$@" ;;
    shell)   cmd_shell "$@" ;;
    exec)    cmd_exec "$@" ;;
    build)   cmd_build "$@" ;;
    rebuild) cmd_rebuild "$@" ;;
    config)  cmd_config "$@" ;;
    ports)   cmd_ports "$@" ;;
    ssh)     cmd_ssh "$@" ;;
  esac
}

# Verbs contributed by other modules (lib/herdr.sh, lib/doctor.sh) register
# themselves by appending to DCK_VERBS and defining dck_cmd_<verb>; they call
# load_context themselves when they need a repository.
dck_dispatch_extra() {
  local verb="$1"; shift
  if declare -F "dck_cmd_$verb" >/dev/null 2>&1; then
    "dck_cmd_$verb" "$@"
  else
    die "$DCK_EXIT_USAGE" "unknown verb '$verb'"
  fi
}
