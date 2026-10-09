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
#
# The machine's identity is its SSH alias (<alias_prefix><repo-slug>), defined
# in ~/.ssh/config.d/dck with agent forwarding and the dedicated dck key. dck
# only ever talks to Herdr through its CLI; it never edits Herdr's own files.

DCK_VERBS="$DCK_VERBS herdr "

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
  [ $# -eq 0 ] || die "$DCK_EXIT_USAGE" "herdr $sub takes no arguments"
  case "$sub" in
    add|status|repair|remove) ;;
    *) die "$DCK_EXIT_USAGE" "usage: dck herdr add|status|repair|remove" ;;
  esac
  load_context
  "herdr_$sub"
}

# Called by `dck up` when dck.toml sets [herdr] machine = true.
dck_herdr_after_up() {
  if ! command -v herdr >/dev/null 2>&1; then
    note "herdr: not installed on this host; skipping machine registration"
    return 0
  fi
  ( herdr_add )
}
