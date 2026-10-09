# shellcheck shell=bash
# Scope: images — static checks over images/ and the images workflow.
# (The docker scope builds the node flavour when a daemon answers.)

IMG="$DCK_REPO/images"
FLAVOURS="python-3.13 node-24 debian"

pin() { sed -n "s/^$1=//p" "$IMG/versions.env"; }

test_three_flavours_exist() {
  local f
  for f in $FLAVOURS; do
    assert_file "$IMG/$f/Dockerfile" "flavour $f has a Dockerfile"
    assert_file "$IMG/$f/Dockerfile.dockerignore" "flavour $f sends a minimal build context"
  done
  run_cmd python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import config; print(" ".join(config.FLAVOURS))' "$DCK_REPO/lib"
  assert_eq "$RUN_OUT" "$FLAVOURS" "the image flavours are exactly the config flavours"
  assert_eq "$(sed -n 's/^ *flavour: \[\(.*\)\]$/\1/p' "$DCK_REPO/.github/workflows/images.yml" | tr -d ',')" "$FLAVOURS" "the workflow builds exactly those flavours"
}

test_base_images_pinned_by_digest() {
  local key f arg want got
  for key in BASE_PYTHON BASE_NODE BASE_DEBIAN UV_IMAGE; do
    assert_match "$(pin "$key")" '^[a-z0-9./-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$' "$key is pinned by tag and digest"
  done
  for f in python-3.13:BASE_PYTHON node-24:BASE_NODE debian:BASE_DEBIAN python-3.13:UV_IMAGE; do
    arg="${f#*:}"; f="${f%%:*}"
    want="$(pin "$arg")"
    got="$(sed -n "s/^ARG $arg=//p" "$IMG/$f/Dockerfile")"
    assert_eq "$got" "$want" "$f: the ARG $arg default equals versions.env"
  done
  assert_no_match "$(grep -h '^FROM' "$IMG"/*/Dockerfile)" '^FROM [^$]' "every FROM goes through a pinned ARG"
}

test_tools_pinned_with_checksums() {
  local t
  for t in GH HERDR NVIM NODE; do
    assert_match "$(pin "${t}_VERSION")" '^[0-9]+\.[0-9]+\.[0-9]+$' "$t has an exact version"
    assert_match "$(pin "${t}_SHA256_AMD64")" '^[0-9a-f]{64}$' "$t has an amd64 SHA-256"
    assert_match "$(pin "${t}_SHA256_ARM64")" '^[0-9a-f]{64}$' "$t has an arm64 SHA-256"
  done
  assert_match "$(pin DWP_VIM_TAG)" '^v[0-9]+\.[0-9]+\.[0-9]+$' "deepworkplan-vim is pinned to a release tag"
  assert_match "$(pin DWP_VIM_COMMIT)" '^[0-9a-f]{40}$' "deepworkplan-vim's tag is bound to a commit"
  assert_match "$(pin DWP_VIM_INSTALLER_SHA256)" '^[0-9a-f]{64}$' "deepworkplan-vim's installer has a SHA-256"
  assert_match "$(pin AGENTKIT_TAG)" '^v[0-9]+\.[0-9]+\.[0-9]+$' "the agents layer pins coding-agents-kit by tag"
  assert_match "$(pin DAILYBOT_CLI_WHEEL_SHA256)" '^[0-9a-f]{64}$' "the dailybot layer pins the CLI wheel hash"
}

test_every_download_is_verified() {
  local inst="$IMG/common/install.sh" n_curl n_fetch
  # The only curl is inside fetch(), which checks sha256 before returning.
  n_curl="$(grep -cE '^[[:space:]]*curl ' "$inst")"
  assert_eq "$n_curl" "1" "install.sh has exactly one curl call (inside fetch)"
  assert_contains "$(sed -n '/^fetch() {/,/^}/p' "$inst")" "sha256sum -c" "fetch verifies the checksum"
  n_fetch="$(grep -c '^fetch "https://' "$inst")"
  assert_eq "$n_fetch" "3" "gh, herdr and nvim are all fetched through fetch()"
  assert_not_contains "$(cat "$inst")" "git clone" "install.sh clones nothing (the editor has its own layer)"
}

test_editor_layer_uses_the_verified_installer() {
  local ed="$IMG/common/editor.sh" f
  assert_eq "$(grep -cE '^[[:space:]]*curl ' "$ed")" "1" "editor.sh has exactly one curl call (inside fetch)"
  assert_contains "$(sed -n '/^fetch() {/,/^}/p' "$ed")" "sha256sum -c" "editor.sh's fetch verifies the checksum"
  assert_contains "$(cat "$ed")" 'fetch "https://github.com/DailybotHQ/deepworkplan-vim/releases/download/${DWP_VIM_TAG}/install.sh"' "the installer is the versioned release asset"
  assert_contains "$(cat "$ed")" '"$DWP_VIM_INSTALLER_SHA256"' "the installer is checked against its pinned SHA-256"
  assert_contains "$(cat "$ed")" '--version "${DWP_VIM_TAG#v}" --skip-packages --strict' "container mode: pinned version, no packages, strict plugin check"
  assert_not_contains "$(grep -v '^#' "$ed")" "--nvim" "the image's own pinned Neovim is used (no --nvim)"
  assert_contains "$(cat "$ed")" 'runuser -u "$DEV_USER" -- env -i' "the installer runs as the dev user with a clean environment"
  assert_contains "$(cat "$ed")" '[ "$got" = "$DWP_VIM_COMMIT" ]' "the installed configuration is checked against its commit"
  assert_contains "$(cat "$ed")" 'exec corepack pnpm' "flavours without pnpm get a build-only pnpm for the plugin builds"
  assert_contains "$(cat "$ed")" 'PATH=/usr/local/bin:/usr/bin:/bin:/tmp/dck-editor/bin' "the build-only pnpm is reachable during the install only"
  for f in $FLAVOURS; do
    assert_contains "$(cat "$IMG/$f/Dockerfile")" "RUN /tmp/dck-editor/editor.sh" "$f installs the editor in its own layer"
  done
}

test_nothing_piped_to_a_shell() {
  assert_no_match "$(cat "$IMG"/*/Dockerfile "$IMG"/common/*)" '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z|da)?sh\b' "no fetch-piped-to-shell in images/"
  assert_no_match "$(cat "$IMG"/*/Dockerfile)" '^# *syntax=' "no unpinned Dockerfile frontend"
  assert_no_match "$(cat "$IMG"/*/Dockerfile "$IMG"/versions.env)" ':latest\b' "no :latest anywhere"
}

test_no_coding_cli_in_images() {
  local all
  all="$(cat "$IMG"/*/Dockerfile "$IMG"/common/* "$IMG"/versions.env)"
  assert_no_match "$all" 'claude\.ai/install|cursor\.com/install|opencode\.ai/install|@openai/codex|pi-coding-agent|x\.ai/cli' "no coding-agent CLI installer"
  assert_no_match "$(printf '%s' "$all" | tr 'A-Z' 'a-z')" 'cline|graphify|engram|cli\.dailybot\.com' "no Cline, Graphify, Engram or Dailybot CLI installer"
  assert_no_match "$all" 'INSTALL_[A-Z]+_CLI|ak install|pnpm add -g|npm (i|install) -g|pipx install|uv tool install' "no global CLI install in the base"
}

test_sshd_posture() {
  local d="$IMG/common/sshd_config.conf" inst="$IMG/common/install.sh"
  assert_match "$(cat "$d")" '^PasswordAuthentication no$' "sshd: no passwords"
  assert_match "$(cat "$d")" '^PermitRootLogin no$' "sshd: no root"
  assert_match "$(cat "$d")" '^PubkeyAuthentication yes$' "sshd: public keys"
  assert_match "$(cat "$d")" '^KbdInteractiveAuthentication no$' "sshd: no keyboard-interactive"
  assert_match "$(cat "$d")" '^AllowAgentForwarding yes$' "sshd: agent forwarding (keys stay on the host)"
  assert_no_match "$(cat "$d")" '^HostKey' "no host key path is baked in"
  assert_contains "$(cat "$inst")" "rm -f /etc/ssh/ssh_host_*" "host keys generated by the package are deleted"
  assert_no_match "$(cat "$IMG"/*/Dockerfile "$IMG"/common/*)" 'ssh-keygen' "no key is generated at build time"
}

test_dev_user_and_contents() {
  local inst="$IMG/common/install.sh"
  assert_contains "$(cat "$inst")" "DEV_UID=1000" "the dev user is uid 1000"
  assert_contains "$(cat "$inst")" 'NOPASSWD:ALL' "the dev user has sudo"
  local pkg
  for pkg in git sudo build-essential curl ca-certificates ripgrep fd-find openssh-server unzip tar gzip lua5.4 fontconfig; do
    assert_match "$(sed -n '/apt-get install/,/"\$@"/p' "$inst")" "(^|[[:space:]])$pkg([[:space:]]|$)" "apt installs $pkg"
  done
  assert_contains "$(cat "$IMG/node-24/Dockerfile")" "install.sh node-24 python3 python3-venv" "node-24 adds python3 and venv (tooling, editor plugins)"
  assert_contains "$(cat "$IMG/debian/Dockerfile")" "install.sh debian python3 python3-venv nodejs npm" "debian adds python3, venv and Debian's nodejs/npm"
  assert_contains "$(cat "$IMG/python-3.13/Dockerfile")" "COPY --from=uv /uv /uvx /usr/local/bin/" "python-3.13 ships uv"
  assert_contains "$(cat "$IMG/python-3.13/Dockerfile")" "install.sh python-3.13 nodejs npm" "python-3.13 adds Debian's nodejs/npm for the editor's plugins only"
  assert_contains "$(cat "$IMG/node-24/Dockerfile")" "corepack enable" "node-24 enables corepack (pnpm)"
  local f
  for f in $FLAVOURS; do
    assert_contains "$(cat "$IMG/$f/Dockerfile")" "COPY lib/entrypoint.sh /usr/local/lib/dck/entrypoint.sh" "$f bakes in the entrypoint library"
    assert_contains "$(cat "$IMG/$f/Dockerfile")" 'ENTRYPOINT ["/usr/local/bin/dck-entrypoint"]' "$f uses the dck entrypoint"
  done
}

test_install_script_is_valid_bash() {
  run_cmd bash -n "$IMG/common/install.sh"
  assert_rc 0 "install.sh parses"
  if command -v shellcheck >/dev/null 2>&1; then
    run_cmd shellcheck -S warning -x "$IMG/common/install.sh" "$IMG/common/profile.sh"
    assert_rc 0 "install.sh and profile.sh pass shellcheck"
  else
    unavailable "install.sh passes shellcheck" "shellcheck not installed"
  fi
}

test_images_workflow() {
  local w="$DCK_REPO/.github/workflows/images.yml"
  assert_no_match "$(grep -E '^\s*- uses:|^\s*uses:' "$w")" '@v[0-9]' "every action is pinned by commit SHA"
  assert_contains "$(cat "$w")" 'ghcr.io/dailybothq/devcontainer-kit-base' "images go to ghcr.io/dailybothq/devcontainer-kit-base"
  assert_contains "$(cat "$w")" '${{ matrix.flavour }}-${{ steps.tag.outputs.suffix }}' "tags are <flavour>-<tag>"
  assert_contains "$(cat "$w")" 'platforms: linux/amd64,linux/arm64' "both architectures are built"
  assert_contains "$(cat "$w")" 'cron:' "a nightly rebuild is scheduled"
  assert_contains "$(cat "$w")" 'GITHUB_STEP_SUMMARY' "digests are recorded"
  assert_eq "$(grep -c 'packages: write' "$w")" "1" "only the build job may write packages"
  assert_not_contains "$(cat "$DCK_REPO/.github/workflows/ci.yml")" "packages: write" "CI cannot write packages"
}
