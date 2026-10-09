# shellcheck shell=bash
#
# lib/entrypoint.sh — the devcontainer-kit entrypoint library.
#
# Baked into every base image at /usr/local/lib/dck/entrypoint.sh and sourced
# by /usr/local/bin/dck-entrypoint, which runs `dck_start` as root when the
# container starts and then execs the container command. A repository's own
# entrypoint may source it and call the functions it wants instead.
#
# One implementation of what used to be copied, with drift, into every
# repository's entrypoint:
#
#   dck_persist <name> <target> [dir|file]   named-volume symlink: seed on first
#                                            run, preserve on rebuild
#   dck_env_profile                          the container's environment for ssh
#                                            sessions (0600, O_EXCL, never logged)
#   dck_sshd                                 host keys generated at runtime into a
#                                            volume, public keys only
#   dck_authorize_keys [--add]               the dck block of authorized_keys
#   dck_herdr_config                         Herdr config defaults, in place
#   dck_repo_hook                            docker/local/dev-setup-hook.sh, if present
#   dck_start                                the standard sequence of the above
#
# Inputs (environment; the compose file rendered by `dck init` sets them):
#   DCK_USER (dev)  DCK_HOME (that user's home)  DCK_WORKSPACE (/workspace)
#   DCK_SSH (1|0)   DCK_AUTHORIZED_KEYS          DCK_AGENTS ("claude codex ...")
#   DCK_PERSIST_ROOT ($DCK_HOME/.dck/volumes)    DCK_REPO_HOOK
# For tests: DCK_ROOT prefixes every system path (/etc, /run) and
# DCK_SSHD_BIN replaces /usr/sbin/sshd.
#
# Values of environment variables are never printed: only names and counts.
# bash 3.2 compatible.

dck_log() { printf 'dck-entrypoint: %s\n' "$*" >&2; }

_dck_is_root() { [ "$(id -u)" = "0" ]; }

# Resolve the user, home and roots once per call (cheap, keeps functions usable
# on their own).
_dck_env() {
  DCK_USER="${DCK_USER:-dev}"
  if [ -z "${DCK_HOME:-}" ]; then
    DCK_HOME="$(getent passwd "$DCK_USER" 2>/dev/null | cut -d: -f6)"
    [ -n "$DCK_HOME" ] || DCK_HOME="/home/$DCK_USER"
  fi
  DCK_WORKSPACE="${DCK_WORKSPACE:-/workspace}"
  DCK_PERSIST_ROOT="${DCK_PERSIST_ROOT:-$DCK_HOME/.dck/volumes}"
  DCK_ROOT="${DCK_ROOT:-}"
  DCK_SSHD_BIN="${DCK_SSHD_BIN:-/usr/sbin/sshd}"
}

# chown to the dev user — only meaningful (and only attempted) as root.
_dck_chown() {
  _dck_is_root || return 0
  chown "$@" 2>/dev/null || true
}

_dck_group() { id -gn "$DCK_USER" 2>/dev/null || echo "$DCK_USER"; }

# --------------------------------------------------------------------------
# dck_persist <name> <target> [dir|file]
# --------------------------------------------------------------------------
# Keeps <target> (a path under the user's home) on the named volume mounted at
# $DCK_PERSIST_ROOT/<name>, through a symlink:
#   * first run (volume copy missing or empty): the image's copy seeds it;
#   * later runs and rebuilds: the volume copy wins, the image's is discarded;
#   * idempotent: a target already linked to its volume copy is left alone.
# The kind defaults to what the target is, or dir when it does not exist.

_dck_persist_key() {
  # .config/gh -> config_gh ; .claude.json -> claude.json
  local rel="$1"
  rel="${rel#.}"
  printf '%s' "$rel" | tr '/' '_'
}

dck_persist() {
  _dck_env
  local name="${1:-}" target="${2:-}" kind="${3:-}"
  case "$name" in
    ''|*[!a-z0-9_-]*) dck_log "persist: invalid volume name '$name'"; return 1 ;;
  esac
  case "$target" in
    "$DCK_HOME"/?*) ;;
    *) dck_log "persist: refusing '$target' (must be under $DCK_HOME)"; return 1 ;;
  esac
  case "$target" in
    */../*|*/..|*/./*|*//*) dck_log "persist: refusing '$target' (not a normalised path)"; return 1 ;;
  esac
  case "$target/" in
    "$DCK_PERSIST_ROOT"/*|"$DCK_HOME/.dck/") dck_log "persist: refusing '$target' (inside the volume root)"; return 1 ;;
  esac
  local vol="$DCK_PERSIST_ROOT/$name"
  local rel="${target#"$DCK_HOME"/}"
  local store
  store="$vol/$(_dck_persist_key "$rel")"
  if [ -z "$kind" ]; then
    if [ -f "$target" ] && [ ! -L "$target" ]; then kind="file"; else kind="dir"; fi
  fi
  case "$kind" in dir|file) ;; *) dck_log "persist: kind must be dir or file"; return 1 ;; esac
  mkdir -p "$vol" || return 1

  if [ -L "$target" ]; then
    if [ "$(readlink "$target")" = "$store" ]; then
      if [ "$kind" = dir ]; then mkdir -p "$store"; elif [ ! -e "$store" ]; then : > "$store"; fi
      _dck_chown -h "$DCK_USER:$(_dck_group)" "$target"
      return 0
    fi
    rm -f "$target"
  fi

  if [ -e "$target" ]; then
    local empty=0
    if [ ! -e "$store" ]; then
      empty=1
    elif [ "$kind" = dir ] && [ -d "$store" ] && [ -z "$(ls -A "$store" 2>/dev/null)" ]; then
      empty=1
    elif [ "$kind" = file ] && [ -f "$store" ] && [ ! -s "$store" ]; then
      empty=1
    fi
    if [ "$empty" = 1 ]; then
      rm -rf "$store"
      cp -a "$target" "$store" || { dck_log "persist: could not seed $store"; return 1; }
      dck_log "persist: seeded $name/${store##*/} from the image"
    else
      dck_log "persist: kept $name/${store##*/} from the volume"
    fi
    rm -rf "$target"
  fi

  if [ "$kind" = dir ]; then mkdir -p "$store"; elif [ ! -e "$store" ]; then : > "$store"; fi
  mkdir -p "$(dirname "$target")"
  ln -s "$store" "$target"
  _dck_chown "$DCK_USER:$(_dck_group)" "$vol"
  _dck_chown -R "$DCK_USER:$(_dck_group)" "$store"
  _dck_chown -h "$DCK_USER:$(_dck_group)" "$target"
}

# --------------------------------------------------------------------------
# dck_env_profile
# --------------------------------------------------------------------------
# sshd starts every session with a clean environment, so nothing compose
# passed in (env_file, environment) reaches an ssh/Herdr session. This writes
# the container's environment to $DCK_HOME/.dck/env.sh, which the login
# profile (/etc/profile.d/00-dck.sh) sources. The file holds whatever secrets
# compose was given, for the one user meant to have them: it is created 0600
# with O_EXCL|O_NOFOLLOW (no world-readable window, never written through a
# planted symlink) and atomically renamed into place. Values are never
# printed; only the number of variables is logged.

dck_env_profile() {
  _dck_env
  local out="$DCK_HOME/.dck/env.sh" count
  mkdir -p "$DCK_HOME/.dck"
  count="$(python3 - "$out" <<'PY'
import os, shlex, sys
out = sys.argv[1]
SKIP = {"PATH", "HOME", "HOSTNAME", "PWD", "OLDPWD", "SHLVL", "SHELL", "USER",
        "LOGNAME", "TERM", "_", "DCK_AUTHORIZED_KEYS", "SSH_AUTH_SOCK",
        "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY", "MAIL"}
lines = ["# Generated at container start by dck_env_profile from the container's",
         "# environment. Do not edit: rewritten on every start. Mode 0600.", ""]
n = 0
for k, v in sorted(os.environ.items()):
    if k in SKIP or not k or k[0].isdigit() or not k.replace("_", "").isalnum():
        continue
    lines.append("export %s=%s" % (k, shlex.quote(v)))
    n += 1
tmp = "%s.tmp-%d" % (out, os.getpid())
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write("\n".join(lines) + "\n")
os.replace(tmp, out)
print(n)
PY
)" || { dck_log "env profile: could not write $out"; return 1; }
  _dck_chown "$DCK_USER:$(_dck_group)" "$DCK_HOME/.dck" "$out"
  dck_log "env profile: $count variable(s) available to ssh sessions (names only are ever logged)"
}

# --------------------------------------------------------------------------
# dck_authorize_keys [--add]
# --------------------------------------------------------------------------
# Maintains the block between "# >>> dck >>>" and "# <<< dck <<<" in
# ~/.ssh/authorized_keys; lines outside it are the user's and are kept.
#   (no flag)  the block becomes the keys in $DCK_AUTHORIZED_KEYS, when set
#              (an empty variable leaves the block as it is)
#   --add      adds the public key(s) read from stdin to the block
# Only well-formed public keys are accepted; anything else is refused.

_dck_valid_pubkeys() {
  LC_ALL=C grep -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [ -~]*)?$' || true
}

dck_authorize_keys() {
  _dck_env
  local mode="${1:-env}" keys ak="$DCK_HOME/.ssh/authorized_keys"
  if [ "$mode" = "--add" ]; then
    keys="$(_dck_valid_pubkeys)"
  else
    [ -n "${DCK_AUTHORIZED_KEYS:-}" ] || return 0
    keys="$(printf '%s\n' "$DCK_AUTHORIZED_KEYS" | _dck_valid_pubkeys)"
  fi
  if [ -z "$keys" ]; then
    dck_log "authorized keys: no valid public key given; nothing changed"
    [ "$mode" = "--add" ] && return 1
    return 0
  fi
  mkdir -p "$DCK_HOME/.ssh"
  chmod 0700 "$DCK_HOME/.ssh"
  [ -e "$ak" ] || : > "$ak"
  python3 - "$ak" "$mode" "$keys" <<'PY'
import os, sys
path, mode, keys = sys.argv[1], sys.argv[2], sys.argv[3].splitlines()
BEGIN, END = "# >>> dck >>>", "# <<< dck <<<"
lines = open(path).read().splitlines()
outside, block, state = [], [], 0
for ln in lines:
    if ln == BEGIN and state == 0:
        state = 1
    elif ln == END and state == 1:
        state = 2
    elif state == 1:
        block.append(ln)
    else:
        outside.append(ln)
if mode == "--add":
    for k in keys:
        if k not in block:
            block.append(k)
else:
    block = keys
new = outside + [BEGIN] + block + [END]
tmp = "%s.tmp-%d" % (path, os.getpid())
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, "w") as fh:
    fh.write("\n".join(new) + "\n")
os.replace(tmp, path)
PY
  _dck_chown "$DCK_USER:$(_dck_group)" "$DCK_HOME/.ssh" "$ak"
  dck_log "authorized keys: $(printf '%s\n' "$keys" | wc -l | tr -d ' ') key(s) in the dck block"
}

# --------------------------------------------------------------------------
# dck_sshd
# --------------------------------------------------------------------------
# Starts sshd for Herdr and `dck ssh` when DCK_SSH=1. The host key is
# generated once into the persistent state volume (never baked into the image,
# never regenerated on recreate, so clients' pinned keys stay valid). The
# image's drop-in already forbids passwords and root; this adds the runtime
# part: the HostKey and `AllowUsers <user>`. The host publishes the port on
# 127.0.0.1 only.

dck_sshd() {
  _dck_env
  if [ "${DCK_SSH:-0}" != "1" ]; then
    dck_log "sshd: disabled (ssh_port = 0)"
    return 0
  fi
  if [ ! -x "$DCK_SSHD_BIN" ]; then
    dck_log "sshd: $DCK_SSHD_BIN not found; Herdr and dck ssh are unavailable"
    return 1
  fi
  local keydir="${DCK_SSH_HOST_KEY_DIR:-$DCK_PERSIST_ROOT/state/ssh_host_keys}"
  local key="$keydir/ssh_host_ed25519_key"
  local conf="$DCK_ROOT/etc/ssh/sshd_config.d/20-dck-runtime.conf"
  mkdir -p "$keydir" "$DCK_ROOT/run/sshd" "$(dirname "$conf")"
  chmod 0700 "$keydir"
  if [ ! -f "$key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "dck-host-key" -f "$key" || { dck_log "sshd: could not generate a host key"; return 1; }
    dck_log "sshd: generated a persistent host key ($(ssh-keygen -lf "$key.pub" | cut -d' ' -f2))"
  fi
  if _dck_is_root; then chown -R root:root "$keydir" 2>/dev/null || true; fi
  chmod 0600 "$key"
  chmod 0644 "$key.pub"
  {
    echo "# Written by dck_sshd at container start."
    echo "HostKey $key"
    echo "AllowUsers $DCK_USER"
  } > "$conf"
  chmod 0644 "$conf"
  dck_authorize_keys || true
  local err
  if ! err="$("$DCK_SSHD_BIN" -t 2>&1)"; then
    dck_log "sshd: configuration invalid, not started: $err"
    return 1
  fi
  "$DCK_SSHD_BIN" || { dck_log "sshd: failed to start"; return 1; }
  dck_log "sshd: listening on container port 22 (public keys only)"
}

# --------------------------------------------------------------------------
# dck_herdr_config
# --------------------------------------------------------------------------
# Herdr reads ~/.config/herdr/config.toml. Keeps the keys the container needs
# present without overwriting a developer's own values:
#   onboarding = false; [terminal] default_shell = "/bin/bash",
#   shell_mode = "login" (also repairing a "non_login" value: a non-login
#   shell never reads /etc/profile.d, so tools vanish from PATH),
#   new_cwd = <workspace>; [experimental] allow_nested = true (always: the
#   container's Herdr runs inside the host's).
# Duplicate tables (invalid TOML that makes Herdr ignore the whole file) are
# merged. A file that needs no change is not rewritten.

dck_herdr_config() {
  _dck_env
  local cfg="$DCK_HOME/.config/herdr/config.toml"
  mkdir -p "$(dirname "$cfg")"
  [ -e "$cfg" ] || : > "$cfg"
  python3 - "$cfg" "$DCK_WORKSPACE" <<'PY' || { dck_log "herdr config: could not update $cfg"; return 1; }
import os, re, sys
path, workspace = sys.argv[1], sys.argv[2]
text = open(path).read()
HEADER = re.compile(r"^\s*\[([^\[\]]+)\]\s*(#.*)?$")
KEY = re.compile(r"^\s*([A-Za-z0-9_-]+)\s*=")
order, tables = [""], {"": []}
cur = ""
for ln in text.splitlines():
    m = HEADER.match(ln)
    if m:
        cur = m.group(1).strip()
        if cur not in tables:
            tables[cur] = []
            order.append(cur)
        continue
    tables[cur].append(ln)

def keys(t):
    return {KEY.match(l).group(1): i for i, l in enumerate(tables.get(t, [])) if KEY.match(l)}

def ensure(t, k, v, force=False, repair=None):
    if t not in tables:
        tables[t] = []
        order.append(t)
    ks = keys(t)
    line = "%s = %s" % (k, v)
    if k not in ks:
        body = tables[t]
        while body and not body[-1].strip():
            body.pop()
        body.append(line)
    elif force or (repair and tables[t][ks[k]].split("=", 1)[1].strip() == repair):
        tables[t][ks[k]] = line

ensure("", "onboarding", "false")
ensure("terminal", "default_shell", '"/bin/bash"')
ensure("terminal", "shell_mode", '"login"', repair='"non_login"')
ensure("terminal", "new_cwd", '"%s"' % workspace)
ensure("experimental", "allow_nested", "true", force=True)

out = []
for t in order:
    body = tables[t]
    while body and not body[-1].strip():
        body.pop()
    if t:
        if out:
            out.append("")
        out.append("[%s]" % t)
    out.extend(body)
new = "\n".join(out).lstrip("\n") + "\n"
if new != text:
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        fh.write(new)
    os.replace(tmp, path)
    sys.stderr.write("dck-entrypoint: herdr config: updated\n")
PY
  _dck_chown -R "$DCK_USER:$(_dck_group)" "$(dirname "$cfg")"
}

# --------------------------------------------------------------------------
# dck_repo_hook
# --------------------------------------------------------------------------
# Runs the repository's docker/local/dev-setup-hook.sh (if present) as the
# dev user, from the workspace. A failing hook is reported, never fatal: the
# container still starts so the developer can fix it from inside.

dck_repo_hook() {
  _dck_env
  local hook="${DCK_REPO_HOOK:-$DCK_WORKSPACE/docker/local/dev-setup-hook.sh}" rc=0
  [ -f "$hook" ] || return 0
  dck_log "repo hook: running ${hook#"$DCK_WORKSPACE"/} as $DCK_USER"
  if _dck_is_root && [ "$DCK_USER" != "root" ]; then
    if command -v runuser >/dev/null 2>&1; then
      (cd "$DCK_WORKSPACE" 2>/dev/null || cd /; runuser -u "$DCK_USER" -- env HOME="$DCK_HOME" bash "$hook") || rc=$?
    else
      (cd "$DCK_WORKSPACE" 2>/dev/null || cd /; su -s /bin/bash "$DCK_USER" -c "HOME='$DCK_HOME' bash '$hook'") || rc=$?
    fi
  else
    (cd "$DCK_WORKSPACE" 2>/dev/null || cd /; bash "$hook") || rc=$?
  fi
  [ "$rc" = 0 ] || dck_log "repo hook: exited $rc (the container keeps running)"
  return 0
}

# --------------------------------------------------------------------------
# dck_start — the standard sequence (what /usr/local/bin/dck-entrypoint runs)
# --------------------------------------------------------------------------

dck_start() {
  _dck_env
  dck_log "starting for user $DCK_USER (workspace $DCK_WORKSPACE)"
  # Per-project state volume: ssh (authorized_keys, known_hosts), gh auth,
  # Herdr config, shell history.
  dck_persist state "$DCK_HOME/.ssh" dir || true
  _dck_chown "$DCK_USER:$(_dck_group)" "$DCK_PERSIST_ROOT/state/ssh"
  chmod 0700 "$DCK_PERSIST_ROOT/state/ssh" 2>/dev/null || true
  dck_persist state "$DCK_HOME/.config/gh" dir || true
  dck_persist state "$DCK_HOME/.config/herdr" dir || true
  dck_persist state "$DCK_HOME/.bash_history" file || true
  if declare -F dck_layer_persist >/dev/null 2>&1; then
    dck_layer_persist || true
  fi
  dck_herdr_config || true
  dck_env_profile || true
  dck_sshd || true
  dck_repo_hook
  dck_log "ready"
}
