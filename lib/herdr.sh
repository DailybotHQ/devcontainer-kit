# shellcheck shell=bash
#
# lib/herdr.sh — the container as a Herdr machine.
#
#   dck herdr add       SSH include + authorized key + wait for sshd, then
#                       `herdr machine add --label <label> <alias>` (idempotent)
#   dck herdr status    include, registration, sshd and the remote server
#   dck herdr repair    re-assert the include and the key, then disable/enable
#                       the machine (the fix for a client stuck "reconnecting")
#   dck herdr remove    `herdr machine remove` and drop the include block
#   dck herdr mesh      push the peer list into the container: every other dck
#                       container (and the host, when the profile sets
#                       host_machine) becomes reachable from inside
#   dck herdr layout [--keep|--reset]   the standard sidebar inside the container
#                       (Home · Editor · Development · Agents); dck up runs --keep
#   dck agents          herdr-peers list: the live agents on every machine
#   dck ask <machine>:<pane>|<#> "<prompt>"   herdr-peers ask, with the reply grant
#
# The machine's identity is its SSH alias (<alias_prefix><repo-slug>), defined
# in ~/.ssh/config.d/dck with agent forwarding and the dedicated dck key. dck
# only ever talks to Herdr through its CLI; it never edits Herdr's own files.

DCK_VERBS="$DCK_VERBS herdr agents ask "

herdr_paths() {
  HERDR_INCLUDE="$HOME/.ssh/config.d/dck"
  HERDR_SSH_CONFIG="$HOME/.ssh/config"
  HERDR_KNOWN_HOSTS="$(dck_config_home)/ssh/known_hosts"
  # Always loopback: the agent is forwarded on this connection, so its address
  # never comes from the (repository-controlled) bind setting.
  HERDR_HOST="127.0.0.1"
  ssh_bind_reachable_on_loopback
  HERDR_WAIT="${DCK_HERDR_WAIT:-30}"
  case "$HERDR_WAIT" in ''|*[!0-9]*) HERDR_WAIT=30 ;; esac
}

herdr_require_config() {
  [ "$DCK_HAS_TOML" = "1" ] || die "$DCK_EXIT_CONFIG" "no .devcontainer/dck.toml — run: dck init"
  [ "${DCK_SSH_PORT:-0}" != "0" ] || die "$DCK_EXIT_CONFIG" "a Herdr machine needs sshd: set ssh_port in .devcontainer/dck.toml"
}

herdr_require_cli() {
  command -v herdr >/dev/null 2>&1 || die "$DCK_EXIT_ENV" "herdr is not installed on this host (https://herdr.dev)"
}

herdr_ensure_include() {
  local r
  (umask 077 && mkdir -p "$HOME/.ssh" "$(dirname "$HERDR_KNOWN_HOSTS")")
  r="$(dckpy sshconf upsert --file "$HERDR_INCLUDE" --alias "$DCK_ALIAS" --host "$HERDR_HOST" \
        --port "$DCK_SSH_PORT" --user "${DCK_TOML_USER:-dev}" --identity "$DCK_SSH_IDENTITY" \
        --known-hosts "$HERDR_KNOWN_HOSTS")" || exit $?
  [ "$r" = "unchanged" ] || note "ssh: $r host $DCK_ALIAS in $(pretty_path "$HERDR_INCLUDE")"
  r="$(dckpy sshconf include --config "$HERDR_SSH_CONFIG")" || exit $?
  [ "$r" = "present" ] || note "ssh: added 'Include config.d/dck' to the top of $(pretty_path "$HERDR_SSH_CONFIG")"
}

# Put the dck public key in the container's authorized_keys (repairs a
# container started without DCK_AUTHORIZED_KEYS, e.g. by an editor plugin).
herdr_authorize_key() {
  [ -f "$DCK_SSH_IDENTITY.pub" ] || return 0
  dc exec -T --user "${DC_USER:-dev}" "$DC_SERVICE" \
    bash -c '. /usr/local/lib/dck/entrypoint.sh && dck_authorize_keys --add' < "$DCK_SSH_IDENTITY.pub" >/dev/null 2>&1 \
    || warn "could not authorize the dck key inside $DC_SERVICE (is it built from a devcontainer-kit base image?)"
}

herdr_ssh_ok() {
  ssh -o BatchMode=yes -o ConnectTimeout=3 "$DCK_ALIAS" true </dev/null >/dev/null 2>&1
}

herdr_server_ok() {
  ssh -o BatchMode=yes -o ConnectTimeout=3 "$DCK_ALIAS" herdr status server </dev/null >/dev/null 2>&1
}

# wait_for <description> <function>
herdr_wait_for() {
  local i=0
  while [ "$i" -lt "$HERDR_WAIT" ]; do
    "$2" && return 0
    i=$((i + 1))
    [ "$i" -lt "$HERDR_WAIT" ] && sleep 1
  done
  "$2"
}

# Sets HERDR_ID, HERDR_LABEL_NOW, HERDR_ENABLED (empty id: not registered).
herdr_lookup() {
  HERDR_ID=""; HERDR_LABEL_NOW=""; HERDR_ENABLED=""
  local line
  line="$(herdr machine list --json 2>/dev/null | dckpy herdr find --target "$DCK_ALIAS" 2>/dev/null || true)"
  [ -n "$line" ] || return 0
  HERDR_ID="$(printf '%s' "$line" | cut -f1)"
  HERDR_LABEL_NOW="$(printf '%s' "$line" | cut -f2)"
  HERDR_ENABLED="$(printf '%s' "$line" | cut -f3)"
}

herdr_prepare() {
  herdr_require_config
  herdr_require_cli
  require_docker
  herdr_paths
  container_running || die "$DC_SERVICE is not running — run: dck up"
  dck_identity_ensure
  herdr_ensure_include
  herdr_authorize_key
  note "herdr: waiting for sshd on $HERDR_HOST:$DCK_SSH_PORT (up to ${HERDR_WAIT}s)"
  herdr_wait_for "sshd" herdr_ssh_ok || die "sshd in $DC_SERVICE does not answer on $HERDR_HOST:$DCK_SSH_PORT — run: dck logs, dck herdr status"
}

# herdr_agent_key — mesh hops out of a container authenticate with the dck key
# held by the HOST's ssh-agent (the Docker Desktop socket mounted in each
# container): make sure it is loaded. The private key never leaves the host.
# Only the mesh calls this; it is never stored in the macOS Keychain.
herdr_agent_key() {
  [ -f "$DCK_SSH_IDENTITY" ] || return 0
  if ! command -v ssh-add >/dev/null 2>&1 || [ -z "${SSH_AUTH_SOCK:-}" ]; then
    warn "no ssh-agent on this host: agents inside containers cannot reach other machines (start one, then: dck herdr mesh)"
    return 0
  fi
  local fp
  fp="$(ssh-keygen -lf "$DCK_SSH_IDENTITY.pub" 2>/dev/null | cut -d' ' -f2)"
  if [ -n "$fp" ] && ssh-add -l 2>/dev/null | grep -qF "$fp"; then return 0; fi
  ssh-add "$DCK_SSH_IDENTITY" >/dev/null 2>&1 || { warn "could not add the dck key to the ssh-agent"; return 0; }
  note "ssh-agent: loaded the dck key for the mesh (every dck container with the agent socket can now log in to the others; ssh-add -d removes it — see docs/SECURITY.md)"
}

# herdr_mesh — push the peer list (public data only) into this container, where
# dck_mesh_apply writes the ssh config, the pinned host keys and the Herdr machines.
herdr_mesh() {
  herdr_require_config
  require_docker
  herdr_paths
  container_running || die "$DC_SERVICE is not running — run: dck up"
  if [ "${DCK_HOST_OS:-$(uname -s)}" = "Linux" ]; then  # DCK_HOST_OS: test hook
    # Peers publish sshd on the host's 127.0.0.1, which host-gateway does not
    # reach from a container on Linux: the mesh is Docker Desktop only.
    note "mesh: skipped on a Linux host (peer containers are reachable from inside only with Docker Desktop; see docs/herdr.md)"
    return 0
  fi
  herdr_agent_key
  local host_user="" host_key="" payload n
  if [ "${DCK_HOST_MACHINE:-0}" = "1" ]; then
    host_user="$(id -un)"
    host_key=/etc/ssh/ssh_host_ed25519_key.pub
  fi
  payload="$( { herdr machine list --json 2>/dev/null || true; } | dckpy sshconf peers --labels-stdin \
      --file "$HERDR_INCLUDE" --known-hosts "$HERDR_KNOWN_HOSTS" --exclude "$DCK_ALIAS" \
      --host-user "$host_user" --host-key "$host_key")" || exit $?
  n="$(printf '%s\n' "$payload" | grep -c '^peer ' || true)"
  printf '%s\n' "$payload" | dc exec -T --user root "$DC_SERVICE" \
    bash -c '. /usr/local/lib/dck/entrypoint.sh && dck_mesh_apply' >/dev/null 2>&1 \
    || die "could not apply the mesh inside $DC_SERVICE (rendered by devcontainer-kit v0.2+?)"
  note "mesh: $n peer(s) reachable from inside $DC_SERVICE"
}

# herdr_layout [--keep|--reset] — create the standard sidebar inside the container,
# as the container user, against the container's own Herdr server.
herdr_layout() {
  require_docker
  container_running || die "$DC_SERVICE is not running — run: dck up"
  local user="${DC_USER:-dev}"
  dc exec -T --user "$user" -e "HOME=/home/$user" -e "USER=$user" -e "LOGNAME=$user" \
    -e "DCK_LAYOUT_CWD=${DC_WORKSPACE:-/workspace}" "$DC_SERVICE" dck-herdr-layout "$@" \
    || die "the Herdr layout could not be created inside $DC_SERVICE (is the host Herdr attached? run: dck herdr status)"
}

herdr_peers_cli() {
  command -v herdr-peers >/dev/null 2>&1 && return 0
  die "$DCK_EXIT_ENV" "herdr-peers is not installed on this host. Install the skill, pinned:
  npx --yes skills add DailybotHQ/herdr-peers@${HERDR_PEERS_TAG:-v0.1.0} --skill herdr-peers -g
then put its helper on PATH (see https://github.com/DailybotHQ/herdr-peers#install)"
}

dck_cmd_agents() {
  [ $# -eq 0 ] || die "$DCK_EXIT_USAGE" "usage: dck agents"
  herdr_peers_cli
  exec herdr-peers list
}

dck_cmd_ask() {
  [ $# -ge 2 ] || die "$DCK_EXIT_USAGE" "usage: dck ask <machine>:<pane> \"<prompt>\""
  herdr_peers_cli
  local target="$1"; shift
  case "$target" in
    *:*) ;;
    *) die "$DCK_EXIT_USAGE" "ask: the target is <machine>:<pane> (the MACHINE:PANE column of: dck agents)" ;;
  esac
  exec herdr-peers ask "$target" "$*"
}

herdr_add() {
  herdr_prepare
  herdr_lookup
  if [ -n "$HERDR_ID" ]; then
    if [ "$HERDR_LABEL_NOW" != "$DCK_HERDR_LABEL" ]; then
      herdr machine rename --label "$DCK_HERDR_LABEL" "$HERDR_ID" >/dev/null || die "herdr machine rename failed"
      note "herdr: renamed machine $DCK_ALIAS to \"$DCK_HERDR_LABEL\""
    fi
    if [ "$HERDR_ENABLED" = "0" ]; then
      herdr machine enable "$HERDR_ID" >/dev/null || die "herdr machine enable failed"
      note "herdr: enabled machine $DCK_ALIAS"
    fi
    note "herdr: $DCK_ALIAS is already registered (\"$DCK_HERDR_LABEL\")"
  else
    herdr machine add --label "$DCK_HERDR_LABEL" "$DCK_ALIAS" || die "herdr machine add failed — run: dck herdr status"
    note "herdr: registered $DCK_ALIAS as \"$DCK_HERDR_LABEL\""
  fi
  if herdr_wait_for "server" herdr_server_ok; then
    note "herdr: the remote server answers"
  else
    note "herdr: the remote server is not answering yet; it starts when Herdr connects (dck herdr status)"
  fi
}

herdr_status() {
  herdr_require_config
  herdr_paths
  local include="absent" reg="no" sshs="no" srv="no"
  if dckpy sshconf has --file "$HERDR_INCLUDE" --alias "$DCK_ALIAS"; then include="present"; fi
  note "alias            $DCK_ALIAS ($HERDR_HOST:$DCK_SSH_PORT, user ${DCK_TOML_USER:-dev})"
  note "ssh include      $include ($(pretty_path "$HERDR_INCLUDE"))"
  if command -v herdr >/dev/null 2>&1; then
    herdr_lookup
    if [ -n "$HERDR_ID" ]; then
      reg="yes"
      note "registered       yes (id $HERDR_ID, label \"$HERDR_LABEL_NOW\", $([ "$HERDR_ENABLED" = 1 ] && echo enabled || echo disabled))"
    else
      note "registered       no — run: dck herdr add"
    fi
  else
    note "registered       unknown — herdr is not installed on this host"
  fi
  if [ "$include" = "present" ] && herdr_ssh_ok; then sshs="yes"; fi
  note "sshd answering   $sshs"
  if [ "$sshs" = "yes" ] && herdr_server_ok; then srv="yes"; fi
  note "server answering $srv"
  if [ "$reg" = "yes" ] && [ "$sshs" = "yes" ] && [ "$srv" = "no" ]; then
    note "hint: a client stuck on \"reconnecting\" is fixed by: dck herdr repair"
  fi
}

herdr_repair() {
  herdr_prepare
  herdr_lookup
  if [ -z "$HERDR_ID" ]; then
    note "herdr: $DCK_ALIAS is not registered; adding it"
    herdr_add
    return
  fi
  herdr machine disable "$HERDR_ID" >/dev/null || die "herdr machine disable failed"
  herdr machine enable "$HERDR_ID" >/dev/null || die "herdr machine enable failed"
  note "herdr: reconnected $DCK_ALIAS (disabled, then enabled)"
  if herdr_wait_for "server" herdr_server_ok; then note "herdr: the remote server answers"; fi
}

herdr_remove() {
  herdr_require_config
  herdr_paths
  if command -v herdr >/dev/null 2>&1; then
    herdr_lookup
    if [ -n "$HERDR_ID" ]; then
      herdr machine remove "$HERDR_ID" >/dev/null || die "herdr machine remove failed"
      note "herdr: removed machine $DCK_ALIAS (its sessions keep running in the container)"
    else
      note "herdr: $DCK_ALIAS was not registered"
    fi
  fi
  local r
  r="$(dckpy sshconf remove --file "$HERDR_INCLUDE" --alias "$DCK_ALIAS")" || exit $?
  [ "$r" = "removed" ] && note "ssh: removed host $DCK_ALIAS from $(pretty_path "$HERDR_INCLUDE")"
  return 0
}

dck_cmd_herdr() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    add|status|repair|remove|mesh) [ $# -eq 0 ] || die "$DCK_EXIT_USAGE" "herdr $sub takes no arguments" ;;
    layout)
      case "${1:-}" in ''|--keep|--reset) ;; *) die "$DCK_EXIT_USAGE" "usage: dck herdr layout [--keep|--reset]" ;; esac
      [ $# -le 1 ] || die "$DCK_EXIT_USAGE" "usage: dck herdr layout [--keep|--reset]" ;;
    *) die "$DCK_EXIT_USAGE" "usage: dck herdr add|status|repair|remove|mesh|layout" ;;
  esac
  load_context
  "herdr_$sub" "$@"
}

# Called by `dck up` when dck.toml sets [herdr] machine = true.
dck_herdr_after_up() {
  if ! command -v herdr >/dev/null 2>&1; then
    note "herdr: not installed on this host; skipping machine registration"
    return 0
  fi
  ( herdr_add ) || return 0
  if [ "${DCK_HERDR_MESH:-1}" = "1" ]; then
    ( herdr_mesh ) || true
  fi
  if [ "${DCK_HERDR_LAYOUT:-standard}" = "standard" ]; then
    ( herdr_layout --keep ) || warn "herdr: the standard layout was not created (run: dck herdr layout)"
  fi
}
