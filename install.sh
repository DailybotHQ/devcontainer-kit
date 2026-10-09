#!/usr/bin/env bash
#
# install.sh — install devcontainer-kit (dck) for the current user.
#
#   git clone --branch <tag> https://github.com/DailybotHQ/devcontainer-kit
#   ./devcontainer-kit/install.sh [--no-rc] [--uninstall]
#
# Copies the kit into ${DCK_INSTALL_DIR:-~/.local/share/dck} (a previous
# install is replaced atomically, so running it again is safe) and adds one
# guarded block to ~/.bashrc and/or ~/.zshrc that puts its bin/ on PATH.
#
#   --no-rc       leave shell rc files alone (scripted installs, CI)
#   --uninstall   remove the install and the rc block (~/.config/dck is kept)
#
# Nothing is downloaded and nothing runs with elevated privileges.
set -euo pipefail

SRC="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${DCK_INSTALL_DIR:-$HOME/.local/share/dck}"
BEGIN="# >>> devcontainer-kit (dck) >>>"
END="# <<< devcontainer-kit (dck) <<<"
RC=1
UNINSTALL=0

for arg in "$@"; do
  case "$arg" in
    --no-rc) RC=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option '$arg'" >&2; exit 2 ;;
  esac
done

case "$DEST" in
  ""|/|"$HOME"|"$HOME/") echo "install.sh: refusing to install into '$DEST'" >&2; exit 5 ;;
esac

rc_files() {
  local f found=0
  for f in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$f" ] && { printf '%s\n' "$f"; found=1; }
  done
  if [ "$found" = 0 ]; then
    case "$(basename "${SHELL:-bash}")" in
      zsh) printf '%s\n' "$HOME/.zshrc" ;;
      *) printf '%s\n' "$HOME/.bashrc" ;;
    esac
  fi
}

remove_block() {
  local f="$1" tmp
  [ -f "$f" ] || return 0
  grep -qxF "$BEGIN" "$f" || return 0
  tmp="$(mktemp "$f.dck.XXXXXX")"
  awk -v b="$BEGIN" -v e="$END" '$0 == b {skip=1; next} $0 == e {skip=0; next} !skip {print}' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

add_block() {
  local f="$1"
  [ -f "$f" ] || : > "$f"
  grep -qxF "$BEGIN" "$f" && remove_block "$f"
  {
    printf '\n%s\n' "$BEGIN"
    # shellcheck disable=SC2016  # written literally; expanded by the shell at startup
    printf 'case ":$PATH:" in *":%s/bin:"*) ;; *) export PATH="%s/bin:$PATH" ;; esac\n' "$DEST" "$DEST"
    printf '%s\n' "$END"
  } >> "$f"
}

if [ "$UNINSTALL" = 1 ]; then
  if [ -f "$DEST/VERSION" ] && [ -x "$DEST/bin/dck" ]; then
    rm -rf "$DEST"
    echo "removed $DEST"
  elif [ -e "$DEST" ]; then
    echo "install.sh: $DEST does not look like a dck install; left alone" >&2
    exit 5
  fi
  while IFS= read -r f; do remove_block "$f"; done < <(rc_files)
  echo "removed the PATH block from your shell rc files (~/.config/dck is kept)"
  exit 0
fi

[ -f "$SRC/VERSION" ] && [ -x "$SRC/bin/dck" ] || { echo "install.sh: run it from a devcontainer-kit checkout" >&2; exit 2; }
if [ -e "$DEST" ] && ! { [ -f "$DEST/VERSION" ] && [ -x "$DEST/bin/dck" ]; }; then
  echo "install.sh: $DEST exists and is not a dck install; refusing to replace it" >&2
  exit 5
fi

version="$(cat "$SRC/VERSION")"
mkdir -p "$(dirname "$DEST")"
stage="$(mktemp -d "$DEST.new.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
for p in bin lib src docs/schema skills; do
  [ -e "$SRC/$p" ] || continue
  mkdir -p "$stage/$(dirname "$p")"
  cp -R "$SRC/$p" "$stage/$p"
done
mkdir -p "$stage/images"
cp "$SRC/images/versions.env" "$stage/images/versions.env"
for f in VERSION LICENSE CREDITS.md README.md; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$stage/$f"
done
find "$stage" -name '__pycache__' -type d -prune -exec rm -rf {} +
chmod -R go-w "$stage"

if [ -e "$DEST" ]; then
  old="$DEST.old.$$"
  mv "$DEST" "$old"
  mv "$stage" "$DEST"
  rm -rf "$old"
else
  mv "$stage" "$DEST"
fi
trap - EXIT
echo "installed devcontainer-kit $version into $DEST"

if [ "$RC" = 1 ]; then
  while IFS= read -r f; do
    add_block "$f"
    echo "added $DEST/bin to PATH in $f"
  done < <(rc_files)
  echo "open a new shell (or: export PATH=\"$DEST/bin:\$PATH\"), then: dck --version"
else
  echo "PATH not changed (--no-rc): run $DEST/bin/dck, or add $DEST/bin to PATH"
fi

py_ok=0
for c in ${DCK_PYTHON:-} python3 python3.13 python3.12 python3.11; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    py_ok=1; break
  fi
done
[ "$py_ok" = 1 ] || echo "warning: dck needs python3 >= 3.11 (tomllib); none found on PATH" >&2
command -v docker >/dev/null 2>&1 || echo "note: docker is not on PATH; the container verbs need it" >&2
exit 0
