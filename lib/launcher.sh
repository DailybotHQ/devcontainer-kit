# shellcheck shell=bash
#
# lib/launcher.sh — verb dispatch for bin/dck.

DCK_VERBS=" init help "

dck_usage() {
  cat <<'EOF'
dck — devcontainer-kit launcher

usage: dck [--profile NAME] <verb> [args]

  init [flags]        render the Dev Container template into this repository
                      (reconciles, never clobbers; see `dck help init`)
  help [verb]         this text, or one verb's details
  --version           print the version
EOF
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
  --image-tag vX.Y.Z   devcontainer-kit-base tag (default: this dck's tag)
  --agents | --no-agents       the agents layer (coding-agents-kit)
  --clis "claude codex"        kinds for `ak install` when agents is on
  --editor | --no-editor       the editor layer
  --herdr | --no-herdr         register as a Herdr machine on `dck up`
  --dry-run            show the plan and the diffs, write nothing
  --yes, -y            consent to every change shown
  --no-digest          do not resolve the base image digest (tag pin only)
  --repo DIR           the repository to initialise
EOF
}

dck_main() {
  DCK_PROFILE_NAME="${DCK_PROFILE:-}"
  DCK_PROJECT_OVERRIDE=""
  local verb=""
  while [ $# -gt 0 ] && [ -z "$verb" ]; do
    case "$1" in
      --version|-V) note "devcontainer-kit $(dck_version)"; return 0 ;;
      --profile) [ $# -ge 2 ] || die "$DCK_EXIT_USAGE" "--profile needs a name"; DCK_PROFILE_NAME="$2"; shift 2 ;;
      --project) [ $# -ge 2 ] || die "$DCK_EXIT_USAGE" "--project needs a name"; DCK_PROJECT_OVERRIDE="$2"; shift 2 ;;
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
    help)
      case "${1:-}" in
        init) dck_help_init ;;
        *) dck_usage ;;
      esac
      ;;
    init)
      if [ -n "$DCK_PROFILE_NAME" ]; then
        dckpy init --profile "$DCK_PROFILE_NAME" "$@"
      else
        dckpy init "$@"
      fi
      ;;
  esac
}
