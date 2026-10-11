# shellcheck shell=bash
#
# lib/peers_host.sh — herdr-peers for the host, so `dck agents` and `dck ask`
# work without installing it by hand.
#
#   dck host peers install   download herdr-peers at the tag the images pin
#                            (HERDR_PEERS_TAG in images/versions.env), verify
#                            its release SHA256SUMS by the pinned sha256 and every
#                            file against it, exactly like images/common/peers.sh
#   dck host peers status    where the host copy is, and its tag
#
# The copy lives in ${XDG_DATA_HOME:-~/.local/share}/dck-host/herdr-peers/<tag>
# (outside dck's own install directory, which install.sh replaces), never in an
# agent's skill directory. `dck setup` installs it when herdr is on the host.
# Nothing is piped into a shell. Test hooks: DCK_PEERS_CURL (the fetch command),
# DCK_VERSIONS_ENV (the pin file).

hostp_pins() {
  local f="${DCK_VERSIONS_ENV:-$DCK_ROOT/images/versions.env}" line  # DCK_VERSIONS_ENV: test hook
  HOSTP_TAG=""; HOSTP_SUMS=""
  [ -f "$f" ] || return 1
  while IFS= read -r line; do
    case "$line" in
      HERDR_PEERS_TAG=*) HOSTP_TAG="${line#*=}" ;;
      HERDR_PEERS_SUMS_SHA256=*) HOSTP_SUMS="${line#*=}" ;;
    esac
  done < "$f"
  case "$HOSTP_TAG" in v[0-9]*.[0-9]*.[0-9]*) ;; *) return 1 ;; esac
  case "$HOSTP_SUMS" in *[!0-9a-f]*|'') return 1 ;; esac
  [ "${#HOSTP_SUMS}" -eq 64 ]
}

hostp_dir() { printf '%s\n' "${XDG_DATA_HOME:-$HOME/.local/share}/dck-host/herdr-peers"; }

# The host copy's executable, or nothing.
dck_host_peers_bin() {
  hostp_pins || return 1
  local b
  b="$(hostp_dir)/$HOSTP_TAG/skills/herdr-peers/scripts/herdr-peers"
  [ -x "$b" ] && printf '%s\n' "$b"
}

hostp_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

hostp_fetch() {
  ${DCK_PEERS_CURL:-curl} --proto '=https' --tlsv1.2 -fsSL --retry 3 -o "$2" "$1"
}

dck_host_peers_install() {
  hostp_pins || die "$DCK_EXIT_CONFIG" "images/versions.env has no valid HERDR_PEERS_TAG / HERDR_PEERS_SUMS_SHA256"
  local dest work
  dest="$(hostp_dir)/$HOSTP_TAG"
  if [ -x "$dest/skills/herdr-peers/scripts/herdr-peers" ]; then
    note "herdr-peers $HOSTP_TAG: already installed for the host ($(pretty_path "$dest"))"
    return 0
  fi
  command -v tar >/dev/null 2>&1 || die "$DCK_EXIT_ENV" "tar is not on PATH"
  work="$(mktemp -d "${TMPDIR:-/tmp}/dck-peers.XXXXXX")" || return 1
  local rc=0
  hostp_install_into "$work" "$dest" || rc=$?
  rm -rf "$work"
  return "$rc"
}

# hostp_install_into <work dir> <destination> — download, verify, copy.
hostp_install_into() {
  local work="$1" dest="$2" src f want got listed unlisted
  hostp_fetch "https://github.com/DailybotHQ/herdr-peers/releases/download/$HOSTP_TAG/SHA256SUMS" "$work/SHA256SUMS" \
    || { warn "herdr-peers $HOSTP_TAG: could not download its SHA256SUMS"; return 1; }
  got="$(hostp_sha256 "$work/SHA256SUMS")"
  [ "$got" = "$HOSTP_SUMS" ] || { warn "herdr-peers $HOSTP_TAG: SHA256SUMS checksum mismatch; nothing installed"; return 1; }
  hostp_fetch "https://codeload.github.com/DailybotHQ/herdr-peers/tar.gz/refs/tags/$HOSTP_TAG" "$work/src.tgz" \
    || { warn "herdr-peers $HOSTP_TAG: could not download its source"; return 1; }
  src="$work/src"; mkdir "$src"
  tar -xzf "$work/src.tgz" -C "$src" --strip-components=1 || { warn "herdr-peers $HOSTP_TAG: unreadable archive"; return 1; }
  if [ -n "$(cd "$src" && find skills/herdr-peers ! -type f ! -type d 2>/dev/null)" ]; then
    warn "herdr-peers $HOSTP_TAG: the skill contains a symlink or special file; nothing installed"; return 1
  fi
  [ -d "$src/skills/herdr-peers" ] || { warn "herdr-peers $HOSTP_TAG: no skills/herdr-peers in the archive"; return 1; }
  # Every listed file matches; every installed file is listed.
  while read -r want f; do
    f="${f#\*}"; f="${f#./}"
    case "$f" in skills/herdr-peers/*) ;; *) continue ;; esac
    [ -f "$src/$f" ] || { warn "herdr-peers $HOSTP_TAG: $f is missing; nothing installed"; return 1; }
    got="$(hostp_sha256 "$src/$f")"
    [ "$got" = "$want" ] || { warn "herdr-peers $HOSTP_TAG: $f does not match its release SHA256SUMS; nothing installed"; return 1; }
  done < "$work/SHA256SUMS"
  listed="$(awk '{p=$2; sub(/^\*/, "", p); sub(/^\.\//, "", p); print p}' "$work/SHA256SUMS" | sort -u)"
  unlisted="$(cd "$src" && find skills/herdr-peers -type f | sort | comm -23 - <(printf '%s\n' "$listed"))"
  [ -z "$unlisted" ] || { warn "herdr-peers $HOSTP_TAG: files not covered by SHA256SUMS: $unlisted"; return 1; }
  mkdir -p "$dest/skills"
  rm -rf "$dest/skills/herdr-peers"
  cp -R "$src/skills/herdr-peers" "$dest/skills/herdr-peers"
  chmod -R go-w "$dest"
  note "herdr-peers $HOSTP_TAG: installed for the host, verified ($(pretty_path "$dest")); dck agents and dck ask use it"
}

dck_host_peers_status() {
  local b
  if command -v herdr-peers >/dev/null 2>&1; then
    note "herdr-peers on PATH  $(command -v herdr-peers)"
  fi
  hostp_pins || true
  if b="$(dck_host_peers_bin)"; then
    note "dck host copy        $(pretty_path "$b") (${HOSTP_TAG:-?})"
  else
    note "dck host copy        not installed — run: dck host peers install"
  fi
}
