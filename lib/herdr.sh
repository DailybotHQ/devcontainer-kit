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
#                       (App · Editor · Development · Agents); dck up runs --keep
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

# herdr_status_running <output of `herdr status server`> — Herdr exits 0
# whether or not a server runs; only its `status: running` line means one
# answers (`status: not running` otherwise). Captured, then tested: a pipe into
# `grep -q` can fail under pipefail.
herdr_status_running() {
  case "
$1
" in *"
status: running
"*) return 0 ;; esac
  return 1
}

herdr_server_ok() {
  local out
  out="$(ssh -o BatchMode=yes -o ConnectTimeout=3 "$DCK_ALIAS" herdr status server </dev/null 2>/dev/null)" || return 1
  herdr_status_running "$out"
}

# The host's own Herdr server: when it is not running, nothing will attach the
# container (and start its server) soon, so dck up does not wait for it.
herdr_host_server_ok() {
  local out
  out="$(herdr status server </dev/null 2>/dev/null)" || return 1
  herdr_status_running "$out"
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

# herdr_push_self — tell the container its machine id in this host's Herdr
# catalog (dck_herdr_self), so the login profile exports HERDR_PEERS_SELF. Run
# after every add (a re-added machine gets a new id) and by the mesh.
herdr_push_self() {
  container_running || return 0
  herdr_lookup
  local id="${HERDR_ID:--}"
  case "$id" in -) ;; *[!0-9a-f]*) return 0 ;; esac
  if dc exec -T --user root "$DC_SERVICE" bash -c '. /usr/local/lib/dck/entrypoint.sh && type dck_herdr_self >/dev/null 2>&1 && dck_herdr_self "$1"' _ "$id" \
      </dev/null >/dev/null 2>&1; then
    [ "$id" = - ] || note "herdr: HERDR_PEERS_SELF=$id inside $DC_SERVICE (new shells and panes)"
  else
    [ "$id" = - ] || note "herdr: could not record the machine id inside $DC_SERVICE (an image older than devcontainer-kit v0.3.3?); set HERDR_PEERS_SELF=$id there by hand"
  fi
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
  ssh_pin_host_key || true
  herdr_wait_for "sshd" herdr_ssh_ok && return 0
  # sshd may have generated its key only now: pin again and retry once.
  if ssh_pin_host_key && herdr_ssh_ok; then return 0; fi
  local hint
  if hint="$(ssh_key_mismatch_hint "$DCK_ALIAS")"; then die "$hint"; fi
  die "sshd in $DC_SERVICE does not answer on $HERDR_HOST:$DCK_SSH_PORT — run: dck logs, dck herdr status"
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

# herdr_repin_peers — a peer container rebuilt outside its own `dck up` (the
# editor's "Rebuild Container", a recreated state volume) has a new sshd host
# key that the host's dck known_hosts does not have yet: the payloads pushed to
# the other containers would carry the old one, and the host's own refresh hop
# would be refused. Read each running peer's key from the container itself
# (docker exec, the container publishing that alias's port) and re-pin it.
herdr_repin_peers() {
  local line alias port name pub ktype kval rest cur tmp
  (umask 077 && mkdir -p "$(dirname "$HERDR_KNOWN_HOSTS")")
  while IFS= read -r line; do
    alias="${line%% *}"; port="${line##* }"
    [ "$alias" != "$DCK_ALIAS" ] || continue
    case "$alias" in [A-Za-z0-9]*) ;; *) continue ;; esac
    case "$port" in ''|*[!0-9]*) continue ;; esac
    name="$(docker ps --filter "publish=$port" --format '{{.Names}}' 2>/dev/null | head -n 1)"
    case "$name" in ''|*[!A-Za-z0-9_.-]*) continue ;; esac
    pub="$(docker exec -u root "$name" bash -c '. /usr/local/lib/dck/entrypoint.sh && type dck_host_key_pub >/dev/null 2>&1 && dck_host_key_pub' 2>/dev/null </dev/null | head -n 1)"
    read -r ktype kval rest <<KEY
$pub
KEY
    case "$ktype" in ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|ssh-rsa) ;; *) continue ;; esac
    case "$kval" in ''|*[!A-Za-z0-9+/=]*) continue ;; esac
    cur="$(awk -v a="$alias" '$1 == a { print $2 " " $3 }' "$HERDR_KNOWN_HOSTS" 2>/dev/null)"
    [ "$cur" = "$ktype $kval" ] && continue
    tmp="$HERDR_KNOWN_HOSTS.tmp-$$"
    { awk -v a="$alias" '$1 != a' "$HERDR_KNOWN_HOSTS" 2>/dev/null; printf '%s %s %s\n' "$alias" "$ktype" "$kval"; } > "$tmp" \
      && chmod 600 "$tmp" && mv -f "$tmp" "$HERDR_KNOWN_HOSTS" || { rm -f "$tmp"; continue; }
    if [ -n "$cur" ]; then
      note "mesh: $alias has a new host key (rebuilt); re-pinned it from the container for the host and every peer"
    else
      note "mesh: pinned the host key of $alias from the container"
    fi
  done <<ALIASES
$(dckpy sshconf aliases --file "$HERDR_INCLUDE" --ports 2>/dev/null || true)
ALIASES
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
  herdr_repin_peers
  local catalog payload n alias
  # The host must have its own entry in its Herdr catalog: asks from the host
  # carry that entry's id as their reply address.
  if [ "${DCK_HOST_MACHINE:-0}" = "1" ] && declare -F dck_host_self_register >/dev/null 2>&1; then
    dck_host_self_register || true
  fi
  catalog="$(herdr machine list --json 2>/dev/null || true)"
  payload="$(herdr_mesh_payload "$DCK_ALIAS" "$DCK_SSH_PORT" "$catalog")" || exit $?
  n="$(printf '%s\n' "$payload" | grep -c '^peer ' || true)"
  # Run in this repository, the mesh applies even with [herdr] mesh = false (an
  # explicit request); a refresh from elsewhere does not (DCK_MESH_FORCE unset).
  printf '%s\n' "$payload" | dc exec -T --user root -e DCK_MESH_FORCE=1 "$DC_SERVICE" \
    bash -c '. /usr/local/lib/dck/entrypoint.sh && dck_mesh_apply' >/dev/null 2>&1 \
    || die "could not apply the mesh inside $DC_SERVICE (rendered by devcontainer-kit v0.2+?)"
  note "mesh: $n peer(s) reachable from inside $DC_SERVICE"
  herdr_push_self
  # The containers started before this one learn about it too: re-apply the
  # mesh to every other running dck container, over its own alias.
  for alias in $(dckpy sshconf aliases --file "$HERDR_INCLUDE" 2>/dev/null || true); do
    [ "$alias" != "$DCK_ALIAS" ] || continue
    case "$alias" in [A-Za-z0-9]*) ;; *) continue ;; esac
    ssh -o BatchMode=yes -o ConnectTimeout=3 -o ForwardAgent=no -- "$alias" true </dev/null >/dev/null 2>&1 || continue
    payload="$(herdr_mesh_payload "$alias" "" "$catalog")" || continue
    if printf '%s\n' "$payload" | ssh -o BatchMode=yes -o ConnectTimeout=5 -o ForwardAgent=no -- "$alias" \
        "bash -c '. /usr/local/lib/dck/entrypoint.sh && dck_mesh_apply'" >/dev/null 2>&1; then
      note "mesh: refreshed $alias"
    else
      note "mesh: could not refresh $alias (rendered before devcontainer-kit v0.2?); run dck herdr mesh in its repository"
    fi
  done
}

# herdr_mesh_optout set|clear — the [herdr] mesh = false marker in the container.
herdr_mesh_optout() {
  container_running || return 0
  dc exec -T --user root "$DC_SERVICE" bash -c ". /usr/local/lib/dck/entrypoint.sh && dck_mesh_optout $1" \
    >/dev/null 2>&1 || true
}

# herdr_mesh_payload <alias> <its ssh port or ""> <host catalog json> — the
# public peer list for one container: the other dck containers, the host (with
# [host] machine), and the host's other loopback Herdr machines ([mesh] external).
herdr_mesh_payload() {
  local self="$1" self_port="${2:-0}" catalog="$3" host_user="" host_key="" ext=()
  if [ "${DCK_HOST_MACHINE:-0}" = "1" ]; then
    host_user="$(id -un)"
    host_key="${DCK_HOST_KEY:-}"
    [ -n "$host_key" ] && [ ! -f "$host_key" ] && warn "mesh: the host key $host_key is missing; the host is pushed unpinned and will be refused inside (dck host listener enable?)"
  fi
  [ "${DCK_MESH_EXTERNAL:-1}" = "1" ] && ext=(--external --user-known-hosts "$HOME/.ssh/known_hosts" --self-port "${self_port:-0}")
  printf '%s' "$catalog" | dckpy sshconf peers --labels-stdin \
    --file "$HERDR_INCLUDE" --known-hosts "$HERDR_KNOWN_HOSTS" --exclude "$self" \
    --host-user "$host_user" --host-key "$host_key" --host-port "${DCK_HOST_PORT:-22}" \
    --host-label "${DCK_HOST_LABEL:-host}" --catalog ${ext[@]+"${ext[@]}"}
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

# Sets HERDR_PEERS_CLI: herdr-peers on PATH, else dck's verified host copy
# (dck host peers install, run by dck setup).
herdr_peers_cli() {
  if command -v herdr-peers >/dev/null 2>&1; then HERDR_PEERS_CLI="herdr-peers"; return 0; fi
  if declare -F dck_host_peers_bin >/dev/null 2>&1 && HERDR_PEERS_CLI="$(dck_host_peers_bin)"; then return 0; fi
  die "$DCK_EXIT_ENV" "herdr-peers is not installed on this host. Install dck's verified copy:
  dck host peers install
(or the skill, pinned: npx --yes skills add DailybotHQ/herdr-peers@${HERDR_PEERS_TAG:-v0.1.0} --skill herdr-peers -g)"
}

dck_cmd_agents() {
  [ $# -eq 0 ] || die "$DCK_EXIT_USAGE" "usage: dck agents"
  herdr_peers_cli
  exec "$HERDR_PEERS_CLI" list
}

dck_cmd_ask() {
  [ $# -ge 2 ] || die "$DCK_EXIT_USAGE" "usage: dck ask <machine>:<pane> \"<prompt>\""
  herdr_peers_cli
  local target="$1"; shift
  case "$target" in
    *:*) ;;
    *) die "$DCK_EXIT_USAGE" "ask: the target is <machine>:<pane> (the MACHINE:PANE column of: dck agents)" ;;
  esac
  exec "$HERDR_PEERS_CLI" ask "$target" "$*"
}

herdr_add() {
  herdr_prepare
  herdr_lookup
  if [ -n "$HERDR_ID" ]; then
    if [ "$HERDR_LABEL_NOW" != "$DCK_HERDR_LABEL" ]; then
      # Id first: Herdr 0.9.3 rejects `rename --label <label> <id>` (the order its
      # own --help prints) with "usage: herdr machine rename <profile-id> --label <label>".
      herdr machine rename "$HERDR_ID" --label "$DCK_HERDR_LABEL" >/dev/null || die "herdr machine rename failed"
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
  herdr_push_self
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
      if command -v docker >/dev/null 2>&1; then herdr_push_self; fi
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
  # Record this repository's mesh choice in its state volume, so a refresh from
  # another repository's `dck herdr mesh` honours it (dck_mesh_apply).
  herdr_mesh_optout "$([ "${DCK_HERDR_MESH:-1}" = "1" ] && echo clear || echo set)"
  if [ "${DCK_HERDR_MESH:-1}" = "1" ]; then
    ( herdr_mesh ) || true
  fi
  if [ "${DCK_HERDR_LAYOUT:-standard}" = "standard" ]; then
    herdr_layout_after_up
  fi
}

# herdr_layout_after_up — the layout is created against the container's own
# Herdr server, which only exists once the host Herdr has attached the machine
# (its retry starts it, often 15-75 s after the container is up). Wait for it,
# bounded by DCK_HERDR_LAYOUT_WAIT seconds (default 60), and only while the
# host's Herdr runs; otherwise skip with the command to run later.
herdr_layout_after_up() {
  if ! herdr_server_ok; then
    if ! herdr_host_server_ok; then
      note "herdr: the host Herdr is not running, so the container's server has not started; open Herdr, then run: dck herdr layout"
      return 0
    fi
    local HERDR_WAIT="${DCK_HERDR_LAYOUT_WAIT:-60}"  # read by herdr_wait_for
    case "$HERDR_WAIT" in ''|*[!0-9]*) HERDR_WAIT=60 ;; esac
    note "herdr: waiting for the container's Herdr server (up to ${HERDR_WAIT}s; the host Herdr starts it when it connects)"
    if ! herdr_wait_for "server" herdr_server_ok; then
      note "herdr: the container's Herdr server is not running yet; once Herdr shows the machine connected, run: dck herdr layout"
      return 0
    fi
  fi
  ( herdr_layout --keep ) || warn "herdr: the standard layout was not created (run: dck herdr layout)"
}
