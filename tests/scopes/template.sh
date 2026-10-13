# shellcheck shell=bash
# Scope: template — src/template/, lib/render.py and `dck init`.

DCK="$DCK_REPO/bin/dck"

# A git repository from a fixture (or empty), with fakes on PATH.
new_repo() {
  local name="$1" from="${2:-repo-empty}"
  fixture "$from" "$SANDBOX/$name" >/dev/null
  git -C "$SANDBOX/$name" init -q
  printf '%s\n' "$SANDBOX/$name"
}

# Every test runs with the fakes first on PATH (set here, not in a subshell).
use_fakes

init_repo() { run_cmd env DCK_NONINTERACTIVE=1 "$DCK" init --repo "$@"; }

tree_digest() {
  (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s %s\n' "$(cksum < "$f" | tr -s ' ' | cut -d' ' -f1-2)" "$f"; done)
}

pyrender() {
  python3 - "$DCK_REPO/lib" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import render
exec(sys.argv[2])
PY
}

test_init_empty_repo_renders_layout() {
  local r
  r="$(new_repo app)"
  init_repo "$r" --flavour node-24 --port web=4321 --ssh-port 22040
  assert_rc 0 "dck init succeeds on an empty repository"
  assert_file "$r/.devcontainer/devcontainer.json" "devcontainer.json is rendered"
  assert_file "$r/.devcontainer/dck.toml" "dck.toml is rendered"
  assert_file "$r/docker/local/docker-compose.yaml" "the compose file is rendered"
  assert_file "$r/docker/local/app/Dockerfile" "the service Dockerfile is rendered"
  assert_file "$r/docker/local/app/.env.example" "the service .env.example is rendered"
  assert_absent "$r/docker/local/app/.env" "no .env is created by init (setup does that)"
  run_cmd python3 -I "$DCK_REPO/lib/dckpy.py" config validate "$r/.devcontainer/dck.toml"
  assert_rc 0 "the rendered dck.toml validates"
  local c
  c="$(cat "$r/docker/local/docker-compose.yaml")"
  assert_contains "$c" "name: app" "the compose file names its project (never the directory default)"
  assert_contains "$c" '"127.0.0.1:22040:22"' "sshd is published on loopback only"
  assert_contains "$c" '"127.0.0.1:4321:4321"' "named ports are published on loopback only"
  assert_not_contains "$c" "0.0.0.0" "nothing binds every interface"
  assert_not_contains "$c" "BASE_IMAGE" "compose passes no base image (no shared image)"
  assert_not_contains "$c" "devcontainer-kit-base" "nothing refers to the shared base image"
  assert_contains "$c" "- state:/home/dev/.dck/volumes/state" "the state volume is per project"
  assert_not_contains "$c" "docker.sock" "no docker socket is mounted"
  assert_not_contains "$c" ".ssh" "no host ssh directory is mounted"
  assert_match "$(cat "$r/docker/local/app/Dockerfile")" '^ARG BASE_IMAGE=node:[0-9.]+-trixie-slim@sha256:[0-9a-f]{64}$' "the Dockerfile starts from the official node image pinned by digest"
  assert_match "$(cat "$r/docker/local/app/Dockerfile")" '^FROM \$\{BASE_IMAGE\}$' "the Dockerfile builds FROM that pin"
  local rel src
  while read -r rel src; do
    if cmp -s "$DCK_REPO/$src" "$r/docker/local/app/dck/$rel"; then pass "dck/$rel is a byte copy of $src"; else fail "dck/$rel is a byte copy of $src"; fi
  done < <(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import render; [print(r, s) for r, s in render.VENDORED]' "$DCK_REPO/lib")
  assert_eq "$(cat "$r/docker/local/app/dck/VERSION")" "devcontainer-kit v$(cat "$DCK_REPO/VERSION")" "dck/VERSION stamps the kit version"
  assert_contains "$(cat "$r/docker/local/app/Dockerfile")" "# dck:managed v$(cat "$DCK_REPO/VERSION") base" "the base block carries the render stamp"
  run_cmd python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import jsonc; d=jsonc.load(sys.argv[2]); print(d["service"], d["runServices"], d["remoteUser"], d["workspaceFolder"], d["shutdownAction"], d["dockerComposeFile"])' "$DCK_REPO/lib" "$r/.devcontainer/devcontainer.json"
  assert_eq "$RUN_OUT" "app ['app'] dev /app none ../docker/local/docker-compose.yaml" "devcontainer.json carries the owned keys"
  assert_contains "$(cat "$r/.gitignore")" "docker/local/**/.env" "the .gitignore guard keeps .env files out of git"
}

test_flavour_detection() {
  local r
  r="$(new_repo n)"; echo '{}' > "$r/package.json"
  init_repo "$r"
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" 'flavour = "node-24"' "package.json selects node-24"
  r="$(new_repo p)"; : > "$r/pyproject.toml"
  init_repo "$r"
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" 'flavour = "python-3.13"' "pyproject.toml selects python-3.13"
  r="$(new_repo d)"
  init_repo "$r"
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" 'flavour = "debian"' "no marker selects debian"
  r="$(new_repo o)"; : > "$r/pyproject.toml"
  init_repo "$r" --flavour node-24
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" 'flavour = "node-24"' "--flavour wins over detection"
}

test_init_is_idempotent() {
  local r before after
  r="$(new_repo idem)"
  init_repo "$r" --ssh-port 22041
  before="$(tree_digest "$r")"
  init_repo "$r"
  assert_rc 0 "a second init exits 0"
  assert_contains "$RUN_OUT" "already in sync" "a second init reports nothing to do"
  after="$(tree_digest "$r")"
  assert_eq "$after" "$before" "a second init changes no byte"
  assert_eq "$(find "$r" -name '*.dck-bak-*' | wc -l | tr -d ' ')" "0" "no backup is made when nothing changes"
}

test_dry_run_writes_nothing() {
  local r before
  r="$(new_repo dry)"
  before="$(tree_digest "$r")"
  init_repo "$r" --dry-run
  assert_rc 0 "--dry-run exits 0"
  assert_contains "$RUN_OUT" "create    docker/local/docker-compose.yaml" "--dry-run shows the plan"
  assert_contains "$RUN_OUT" "dry run: nothing was written" "--dry-run says so"
  assert_eq "$(tree_digest "$r")" "$before" "--dry-run writes nothing"
}

test_reconcile_keeps_user_content() {
  local r
  r="$(new_repo keep)"
  init_repo "$r" --ssh-port 22042
  # The user adds a backing service, a Dockerfile layer and a dck.toml comment.
  python3 - "$r/docker/local/docker-compose.yaml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("  # <<< dck:service <<<\n", "  # <<< dck:service <<<\n  db:\n    image: postgres:17.6\n")
open(p, "w").write(s)
PY
  printf 'RUN echo project-layer\n' >> "$r/docker/local/app/Dockerfile"
  sed -i.orig 's/^ssh_port = 22042$/ssh_port = 22042   # my note/' "$r/.devcontainer/dck.toml" && rm -f "$r/.devcontainer/dck.toml.orig"
  init_repo "$r" --ssh-port 22043
  assert_rc 5 "a differing managed block is refused without consent"
  assert_contains "$(cat "$r/docker/local/docker-compose.yaml")" "22042:22" "nothing is written when consent is missing"
  assert_contains "$RUN_OUT" "-      - \"127.0.0.1:22042:22\"" "the refusal shows the diff"
  init_repo "$r" --ssh-port 22043 --yes
  assert_rc 0 "--yes applies the change"
  local c
  c="$(cat "$r/docker/local/docker-compose.yaml")"
  assert_contains "$c" '"127.0.0.1:22043:22"' "the managed block is updated"
  assert_contains "$c" "image: postgres:17.6" "a service added outside the markers is kept"
  assert_contains "$(cat "$r/docker/local/app/Dockerfile")" "RUN echo project-layer" "a project layer below the markers is kept"
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" "ssh_port = 22043   # my note" "dck.toml is edited in place, comment kept"
  assert_ne "$(find "$r" -name 'docker-compose.yaml.dck-bak-*' | head -1)" "" "the previous compose file is backed up"
  assert_contains "$(cat "$(find "$r" -name 'docker-compose.yaml.dck-bak-*' | head -1)")" "22042:22" "the backup holds the previous content"
}

test_existing_devcontainer_is_reconciled_by_keys() {
  local r j
  r="$(new_repo legacy repo-existing)"
  init_repo "$r" --service app
  assert_rc 5 "an existing hand-written setup is refused without consent"
  assert_contains "$(cat "$r/.devcontainer/devcontainer.json")" '"image": "mcr.microsoft.com' "the refused devcontainer.json is untouched"
  assert_contains "$RUN_OUT" "replace   docker/local/docker-compose.yaml (no dck markers: whole file)" "a compose file without markers is a whole-file replacement"
  assert_contains "$RUN_OUT" "update    .devcontainer/devcontainer.json (dck-owned keys)" "devcontainer.json is reconciled by keys"
  init_repo "$r" --service app --yes
  assert_rc 0 "--yes reconciles the existing setup"
  j="$(python3 -c 'import sys,json; sys.path.insert(0, sys.argv[1]); import jsonc; print(json.dumps(jsonc.load(sys.argv[2]), sort_keys=True))' "$DCK_REPO/lib" "$r/.devcontainer/devcontainer.json")"
  assert_not_contains "$j" '"image"' "a conflicting image key is removed"
  assert_contains "$j" '"customizations": {"vscode": {"extensions": ["eamodio.gitlens"]}}' "user keys are kept"
  assert_contains "$j" '"forwardPorts": [3000]' "forwardPorts is kept"
  assert_contains "$j" '"name": "Legacy app"' "the display name is kept"
  assert_contains "$j" '"remoteUser": "dev"' "an owned key is set"
  assert_ne "$(find "$r/.devcontainer" -name 'devcontainer.json.dck-bak-*' | head -1)" "" "the previous devcontainer.json is backed up"
  assert_contains "$(cat "$r/docker/local/docker-compose.yaml")" "# >>> dck:service >>>" "the replaced compose file now carries markers"
  assert_contains "$(cat "$r/.gitignore")" "node_modules/" "existing .gitignore lines are kept"
  assert_contains "$(cat "$r/.gitignore")" "# >>> dck:gitignore >>>" "the .gitignore guard is appended"
}

test_gitignore_guard_needs_no_consent() {
  local r
  r="$(new_repo gi)"
  printf 'dist/\n' > "$r/.gitignore"
  init_repo "$r"
  assert_rc 0 "appending the secrets guard alone needs no consent"
  assert_eq "$(head -1 "$r/.gitignore")" "dist/" "the existing first line is unchanged"
  run_cmd git -C "$r" check-ignore -q docker/local/app/.env
  assert_rc 0 "git ignores docker/local/app/.env"
  run_cmd git -C "$r" check-ignore -q docker/local/app/.env.example
  assert_rc 1 "git does not ignore .env.example"
}

test_corrupt_markers_mean_whole_file() {
  local r
  r="$(new_repo bad)"
  init_repo "$r"
  sed -i.orig '/<<< dck:base <<</d' "$r/docker/local/app/Dockerfile" && rm -f "$r/docker/local/app/Dockerfile.orig"
  init_repo "$r"
  assert_rc 5 "unbalanced markers are never edited in place"
  assert_contains "$RUN_ERR" "dck's markers are unbalanced, duplicated or crossed" "unbalanced markers are refused with the fix, never replaced or appended"
  assert_not_contains "$RUN_OUT" "replace   docker/local/app/Dockerfile" "no whole-file proposal for a file that has dck markers"
}

test_refuses_home_and_root() {
  run_cmd env DCK_NONINTERACTIVE=1 "$DCK" init --repo "$HOME"
  assert_rc 5 "dck init refuses \$HOME"
  run_cmd env DCK_NONINTERACTIVE=1 "$DCK" init --repo /
  assert_rc 5 "dck init refuses /"
  assert_absent "$HOME/.devcontainer" "nothing is written into \$HOME"
}

test_invalid_flags() {
  local r
  r="$(new_repo inv)"
  init_repo "$r" --flavour alpine
  assert_rc 3 "an invalid flavour is a configuration error"
  assert_absent "$r/.devcontainer/dck.toml" "nothing is written for an invalid configuration"
  init_repo "$r" --port web
  assert_rc 2 "a malformed --port is a usage error"
  init_repo "$r" --bogus
  assert_rc 2 "an unknown init flag is a usage error"
}

test_runtimes_and_migration() {
  local r f
  for f in python-3.13 debian; do
    r="$(new_repo "rt-$f")"
    init_repo "$r" --flavour "$f" --no-herdr --yes
    assert_rc 0 "init renders the $f runtime"
    case "$f" in
      python-3.13) assert_match "$(cat "$r/docker/local/app/Dockerfile")" '^ARG BASE_IMAGE=python:[0-9.]+-slim-trixie@sha256:[0-9a-f]{64}$' "python starts from the official python image by digest"
                   assert_contains "$(cat "$r/docker/local/app/Dockerfile")" "COPY --from=uv /uv /uvx /usr/local/bin/" "python gets uv" ;;
      debian) assert_match "$(cat "$r/docker/local/app/Dockerfile")" '^ARG BASE_IMAGE=debian:[a-z0-9.-]+@sha256:[0-9a-f]{64}$' "debian starts from the official debian image by digest" ;;
    esac
  done
  r="$(new_repo base-override)"
  mkdir -p "$r/.devcontainer"
  printf 'interface = 2\nservice = "app"\nflavour = "node-24"\nbase_image = "node:22.20.0-trixie-slim@sha256:%064d"\n' 1 > "$r/.devcontainer/dck.toml"
  init_repo "$r" --yes --no-herdr
  assert_match "$(cat "$r/docker/local/app/Dockerfile")" '^ARG BASE_IMAGE=node:22\.20\.0-trixie-slim@sha256:0{63}1$' "dck.toml base_image overrides the flavour's pin"
  r="$(new_repo v1)"
  mkdir -p "$r/.devcontainer"
  printf 'interface = 1\nservice = "app"\nflavour = "debian"\nimage_tag = "v0.1.6"\nssh_port = 22041\n' > "$r/.devcontainer/dck.toml"
  : > "$DCK_FAKE_LOG"
  init_repo "$r" --yes --no-herdr
  assert_rc 0 "a version-1 config migrates"
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" "interface = 2" "the interface line is rewritten"
  assert_not_contains "$(cat "$r/.devcontainer/dck.toml")" "image_tag" "image_tag is removed"
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" "ssh_port = 22041" "the rest of the file is kept"
  assert_eq "$(fake_calls docker)" "" "init makes no registry call"
}

test_profile_network_and_user_rename() {
  local r c
  r="$(new_repo net)"
  mkdir -p "$XDG_CONFIG_HOME/dck"
  printf 'compose_project_prefix = "acme-"\nnetwork = "acme-dev"\n' > "$XDG_CONFIG_HOME/dck/profile.toml"
  init_repo "$r" --user builder --no-digest
  assert_rc 0 "init with a profile network and another user"
  c="$(cat "$r/docker/local/docker-compose.yaml")"
  assert_contains "$c" "name: acme-net" "the profile prefix names the compose project"
  assert_contains "$c" "    external: true" "the profile network is declared external"
  assert_contains "$c" "      - acme-dev" "the service joins the profile network"
  assert_contains "$c" "- state:/home/builder/.dck/volumes/state" "volumes follow the configured user"
  assert_contains "$(cat "$r/docker/local/app/Dockerfile")" "usermod -l builder -d /home/builder -m dev" "a non-default user renames the base image user"
  assert_contains "$(cat "$r/.devcontainer/devcontainer.json")" '"remoteUser": "builder"' "remoteUser follows dck.toml"
}

test_rendered_compose_is_valid_for_docker_compose() {
  local r
  r="$(new_repo cv)"
  init_repo "$r" --port web=4321 --no-digest
  # The real docker CLI (not the fake) parses compose files without a daemon.
  local real
  real="$(PATH="${PATH#"$TESTS_DIR/fakes/bin:"}" command -v docker || true)"
  if [ -z "$real" ] || ! "$real" compose version >/dev/null 2>&1; then
    unavailable "docker compose config accepts the rendered file" "docker compose CLI not found"
    return 0
  fi
  run_cmd env DOCKER_HOST=unix:///nonexistent "$real" compose -f "$r/docker/local/docker-compose.yaml" config -q
  assert_rc 0 "docker compose config accepts the rendered file"
}

test_devcontainer_cli_reads_rendered_config() {
  local r real
  r="$(new_repo dcli)"
  init_repo "$r" --no-digest
  real="$(PATH="${PATH#"$TESTS_DIR/fakes/bin:"}" command -v devcontainer || true)"
  if [ -z "$real" ]; then
    unavailable "devcontainer read-configuration accepts the rendered config" "@devcontainers/cli not installed"
    return 0
  fi
  # read-configuration looks for existing containers, so it needs a daemon.
  require_docker "devcontainer read-configuration accepts the rendered config" || return 0
  run_cmd env PATH="${PATH#"$TESTS_DIR/fakes/bin:"}" "$real" read-configuration --workspace-folder "$r"
  assert_rc 0 "devcontainer read-configuration accepts the rendered config"
  assert_contains "$RUN_OUT" '"service":"app"' "the CLI reads the service"
}

test_template_engine() {
  run_cmd pyrender 'print(render.render_text("a\n{% if x %}\nyes {{v}}\n{% else %}\nno\n{% endif %}\nz\n", {"x": True, "v": 1}), end="")'
  assert_eq "$RUN_OUT" "a
yes 1
z" "if/else renders the true branch"
  run_cmd pyrender 'print(render.render_text("{% if x %}\n{% if y %}\nboth\n{% endif %}\nx\n{% endif %}\n", {"x": True, "y": False}), end="")'
  assert_eq "$RUN_OUT" "x" "nested ifs render"
  run_cmd pyrender 'render.render_text("{{nope}}\n", {})'
  assert_contains "$RUN_ERR" "unknown variable 'nope'" "an unknown variable is an error, never an empty string"
  run_cmd pyrender 'render.render_text("{% if a %}\n", {"a": 1})'
  assert_contains "$RUN_ERR" "unterminated if" "an unterminated if is an error"
}

test_toml_set_preserves_layout() {
  run_cmd pyrender 'print(render.toml_set("# c\na = 1  # keep\n\n[t]\nb = true\n", "a", 2), end="")'
  assert_eq "$RUN_OUT" "# c
a = 2  # keep

[t]
b = true" "a top-level value is replaced, its comment kept"
  run_cmd pyrender 'print(render.toml_set("a = 1\n\n[t]\nb = true\n\n[u]\nc = 1\n", "t.d", ["x"]), end="")'
  assert_eq "$RUN_OUT" 'a = 1

[t]
b = true
d = ["x"]

[u]
c = 1' "a missing key is inserted at the end of its table"
  run_cmd pyrender 'print(render.toml_set("a = 1\n", "herdr.machine", True), end="")'
  assert_eq "$RUN_OUT" "a = 1

[herdr]
machine = true" "a missing table is appended"
  run_cmd pyrender 'print(render.toml_set("[t]\nx = 1\n", "y", 2), end="")'
  assert_eq "$RUN_OUT" "y = 2
[t]
x = 1" "a missing top-level key goes before the first table"
}

test_managed_block_parser() {
  run_cmd pyrender 'print(render.parse_blocks("# >>> dck:a >>>\nx\n# <<< dck:a <<<\n"))'
  assert_eq "$RUN_OUT" "{'a': (0, 2)}" "a balanced block is found"
  run_cmd pyrender 'print(render.parse_blocks("# >>> dck:a >>>\n# >>> dck:b >>>\n# <<< dck:b <<<\n# <<< dck:a <<<\n"))'
  assert_eq "$RUN_OUT" "None" "nested blocks are rejected"
  run_cmd pyrender 'print(render.parse_blocks("# >>> dck:a >>>\n# <<< dck:a <<<\n# >>> dck:a >>>\n# <<< dck:a <<<\n"))'
  assert_eq "$RUN_OUT" "None" "duplicated blocks are rejected"
  run_cmd pyrender 'print(render.reconcile_blocks("top\n# >>> dck:a >>>\nold\n# <<< dck:a <<<\nmine\n# >>> dck:gone >>>\nx\n# <<< dck:gone <<<\n", "# >>> dck:a >>>\nnew\n# <<< dck:a <<<\n# >>> dck:b >>>\nadded\n# <<< dck:b <<<\n"), end="")'
  assert_eq "$RUN_OUT" "top
# >>> dck:a >>>
new
# <<< dck:a <<<
mine

# >>> dck:b >>>
added
# <<< dck:b <<<" "blocks are replaced, removed and added; user lines are kept"
}

test_ssh_agent_and_known_hosts() {
  local r c
  r="$(new_repo agent)"
  init_repo "$r" --no-herdr --yes
  c="$(cat "$r/docker/local/docker-compose.yaml")"
  assert_contains "$c" 'source: ${DCK_HOST_SSH_AUTH_SOCK:-/run/host-services/ssh-auth.sock}' "the host SSH agent socket is mounted (no key file)"
  assert_contains "$c" 'create_host_path: false' "a missing agent socket is never created on the host"
  assert_contains "$c" "SSH_AUTH_SOCK: /run/dck/ssh-agent.sock" "exec sessions see the agent"
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" "ssh_agent = true" "dck.toml records the agent sharing"
  assert_contains "$(cat "$r/docker/local/app/dck/github_known_hosts")" "github.com ssh-ed25519 " "GitHub's host keys are vendored"
  assert_contains "$(cat "$r/docker/local/app/.env.example")" "# DCK_GIT_EMAIL=" "the env example documents the git identity"
  assert_contains "$(cat "$r/docker/local/app/.env.example")" "# AGENTKIT_PERMISSIONS=ask" "the env example documents the opt-out"
  sed -i.orig 's/^ssh_agent = true$/ssh_agent = false/' "$r/.devcontainer/dck.toml" && rm -f "$r/.devcontainer/dck.toml.orig"
  init_repo "$r" --no-herdr --yes
  assert_not_contains "$(cat "$r/docker/local/docker-compose.yaml")" "ssh-agent.sock" "ssh_agent = false shares no agent"
}

test_devsh() {
  local r fake
  r="$(new_repo devsh)"
  init_repo "$r" --no-herdr --yes
  assert_file "$r/dev.sh" "dev.sh is rendered"
  assert_match "$(ls -l "$r/dev.sh")" '^-rwx' "dev.sh is executable"
  run_cmd bash -n "$r/dev.sh"
  assert_rc 0 "dev.sh is valid bash"
  assert_contains "$(cat "$r/dev.sh")" "# >>> dck:devsh >>>" "dev.sh has a managed block"
  fake="$SANDBOX/dckbin"; mkdir -p "$fake"
  printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "devcontainer-kit %s"; exit 0; fi\nprintf "dck %%s\\n" "$*" >> "%s"\n' "$(cat "$DCK_REPO/VERSION")" "$DCK_FAKE_LOG" > "$fake/dck"
  chmod +x "$fake/dck"
  : > "$DCK_FAKE_LOG"
  local v
  for v in down shell build rebuild logs ps doctor agents; do
    run_cmd env PATH="$fake:$PATH" bash "$r/dev.sh" "$v"
    assert_contains "$(fake_calls dck)" "dck $v" "dev.sh $v runs dck $v"
  done
  run_cmd env PATH="$fake:$PATH" bash "$r/dev.sh" up
  assert_contains "$(fake_calls dck)" "dck setup" "dev.sh up runs dck setup first"
  assert_contains "$(fake_calls dck)" "dck up" "then dck up"
  run_cmd env PATH="$fake:$PATH" bash "$r/dev.sh" herdr
  assert_contains "$(fake_calls dck)" "dck herdr add" "dev.sh herdr defaults to dck herdr add"
  run_cmd env PATH="$fake:$PATH" bash "$r/dev.sh" ask dck-x:w1:p1 "a question"
  assert_contains "$(fake_calls dck)" "dck ask dck-x:w1:p1 a question" "dev.sh ask passes the target and prompt"
  run_cmd env PATH="$fake:$PATH" bash "$r/dev.sh" nope
  assert_rc 2 "an unknown dev.sh command is a usage error"
  run_cmd env PATH=/usr/bin:/bin HOME="$SANDBOX/nodck" bash "$r/dev.sh" agents
  assert_rc 4 "without dck, a dck-only command says how to install it"
  assert_contains "$RUN_ERR" "git clone --branch v$(cat "$DCK_REPO/VERSION") https://github.com/DailybotHQ/devcontainer-kit" "the install line is pinned"
  assert_contains "$RUN_ERR" "bash dev.sh install-dck" "and names install-dck"
  r="$(new_repo devsh-own)"
  printf '#!/usr/bin/env bash\necho mine\n' > "$r/dev.sh"
  init_repo "$r" --no-herdr --yes
  assert_eq "$(cat "$r/dev.sh")" "$(printf '#!/usr/bin/env bash\necho mine')" "a repository's own dev.sh is kept"
}

test_herdr_layout_in_the_template() {
  local r
  r="$(new_repo hlayout)"
  init_repo "$r" --no-herdr --yes
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" 'layout = "standard"' "dck.toml defaults to the standard layout"
  assert_contains "$(cat "$r/docker/local/app/Dockerfile")" "COPY dck/herdr-layout.sh /usr/local/bin/dck-herdr-layout" "the image carries the layout script"
  assert_contains "$(cat "$r/dev.sh")" 'herdr-layout) exec "$dck_bin" herdr layout' "dev.sh herdr-layout maps to dck herdr layout"
}

# A PATH with the fake docker but no dck (and no default install).
nodck_path() { printf '%s:/usr/bin:/bin' "$TESTS_DIR/fakes/bin"; }

test_devsh_without_dck_uses_compose() {
  local r
  r="$(new_repo devsh-compose)"
  init_repo "$r" --service web --user node --workspace /app --no-herdr --yes
  rm -f "$r/docker/local/web/.env"
  : > "$DCK_FAKE_LOG"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" up
  assert_rc 0 "dev.sh up works with Docker alone"
  assert_contains "$(fake_calls docker)" "compose -f docker/local/docker-compose.yaml up -d web" "up starts the rendered service on plain compose"
  assert_file "$r/docker/local/web/.env" "the .env is created from its example"
  assert_mode "$r/docker/local/web/.env" 600 "under umask 077"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" shell
  assert_contains "$(fake_calls docker)" "exec -u node -w /app web bash -l" "shell enters as the rendered user and workspace"
  for v in down build logs ps; do
    run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" "$v"
    assert_rc 0 "dev.sh $v works without dck"
  done
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" rebuild
  assert_contains "$(fake_calls docker)" "up -d --force-recreate web" "rebuild recreates on plain compose"
  assert_not_contains "$(cat "$r/dev.sh")" "dev-setup-hook.sh" "the fallback never runs the start hook (the entrypoint does)"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" herdr
  assert_rc 4 "herdr needs dck"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" DCK_HOST_SSH_AUTH_SOCK= SSH_AUTH_SOCK=/tmp/agent.sock bash -c 'uname() { echo Linux; }; export -f uname; bash "$1" ps' _ "$r/dev.sh"
  assert_rc 0 "ps works"
  # The default install location is found without PATH.
  mkdir -p "$SANDBOX/inst/bin"
  printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "devcontainer-kit %s"; exit 0; fi\nprintf "dck %%s\\n" "$*" >> "%s"\n' "$(cat "$DCK_REPO/VERSION")" "$DCK_FAKE_LOG" > "$SANDBOX/inst/bin/dck"
  chmod +x "$SANDBOX/inst/bin/dck"
  run_cmd env PATH="$(nodck_path)" DCK_INSTALL_DIR="$SANDBOX/inst" bash "$r/dev.sh" agents
  assert_contains "$(fake_calls dck)" "dck agents" "dck is found in its install directory"
}

# The plain-compose fallback chooses the host SSH agent socket by Docker
# provider, as dck does, so the bind (never creating a missing host path)
# cannot fail `up` on a provider without Docker Desktop's socket.
test_devsh_without_dck_picks_the_agent_socket_by_provider() {
  local r
  r="$(new_repo devsh-agent)"
  init_repo "$r" --no-herdr --yes
  echo "29.0.0|Docker Desktop|docker-desktop" > "$DCK_FAKE_STATE/info_out"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" DCK_HOST_SSH_AUTH_SOCK= bash "$r/dev.sh" up
  assert_rc 0 "up on Docker Desktop"
  assert_eq "$(cat "$DCK_FAKE_STATE/last_agent_sock")" "" "Docker Desktop: the compose default (its shared agent socket)"
  echo "29.0.0|Ubuntu 24.04|colima" > "$DCK_FAKE_STATE/info_out"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" DCK_HOST_SSH_AUTH_SOCK= SSH_AUTH_SOCK= bash "$r/dev.sh" up
  assert_rc 0 "up on another provider"
  assert_eq "$(cat "$DCK_FAKE_STATE/last_agent_sock")" "/dev/null" "another provider: /dev/null, never a missing path"
  assert_contains "$RUN_ERR" "not shared with this Docker provider" "said once"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" DCK_HOST_SSH_AUTH_SOCK=/run/custom.sock bash "$r/dev.sh" up
  assert_eq "$(cat "$DCK_FAKE_STATE/last_agent_sock")" "/run/custom.sock" "an explicit DCK_HOST_SSH_AUTH_SOCK is kept"
  : > "$DCK_FAKE_LOG"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" DCK_HOST_SSH_AUTH_SOCK= bash "$r/dev.sh" ps
  assert_not_contains "$(fake_calls docker)" "docker info" "verbs that create no container do not probe the provider"
}

# A fake kit release for install-dck: a tree, its SHA256SUMS (served by the fake
# curl) and a git that "clones" the tree.
mk_kit() {
  local kit="$SANDBOX/kitsrc" f
  rm -rf "$kit"; mkdir -p "$kit/bin" "$kit/lib" "$SANDBOX/fk" "$DCK_FAKE_STATE/curl"
  printf '#!/usr/bin/env bash\nmkdir -p "${DCK_INSTALL_DIR:?}"; echo "installed $*" > "%s/installed"\n' "$SANDBOX" > "$kit/install.sh"; chmod +x "$kit/install.sh"
  printf 'x\n' > "$kit/VERSION"; printf 'dck\n' > "$kit/bin/dck"; printf 'lib\n' > "$kit/lib/common.sh"
  (cd "$kit" && for f in install.sh VERSION bin/dck lib/common.sh; do
     printf '%s  %s\n' "$(shasum -a 256 "$f" 2>/dev/null | cut -d' ' -f1 || sha256sum "$f" | cut -d' ' -f1)" "$f"; done) > "$DCK_FAKE_STATE/curl/SHA256SUMS"
  printf '#!/usr/bin/env bash\nif [ "$1" = clone ]; then echo "git $*" >> "%s"; cp -R "%s" "${@: -1}"; exit 0; fi\nexec /usr/bin/git "$@"\n' "$DCK_FAKE_LOG" "$kit" > "$SANDBOX/fk/git"; chmod +x "$SANDBOX/fk/git"
}
inst() { run_cmd env PATH="$SANDBOX/fk:$TESTS_DIR/fakes/bin:/usr/bin:/bin" HOME="$SANDBOX/nodck" DCK_INSTALL_DIR="$SANDBOX/inst" bash "$@"; }

test_devsh_install_dck_verifies() {
  local r
  r="$(new_repo devsh-install)"
  init_repo "$r" --no-herdr --yes
  mk_kit
  inst "$r/dev.sh" install-dck
  assert_rc 0 "install-dck installs a verified clone"
  assert_contains "$(cat "$DCK_FAKE_LOG")" "--branch v$(cat "$DCK_REPO/VERSION")" "the rendered tag is cloned"
  assert_contains "$(cat "$SANDBOX/installed")" "--no-rc" "the installer runs without touching rc files"
  assert_contains "$RUN_OUT" "python3 >= 3.11" "it mentions dck's python requirement"
  assert_match "$(cat "$SANDBOX/inst/RELEASE_SUMS_SHA256")" "^v[0-9.]+ [0-9a-f]{64}$" "the verified SHA256SUMS digest is recorded for later renders"
  rm -f "$SANDBOX/installed"
  printf 'echo tampered\n' >> "$SANDBOX/kitsrc/install.sh"
  inst "$r/dev.sh" install-dck
  assert_rc 1 "a clone that does not match SHA256SUMS is refused"
  assert_not_file "$SANDBOX/installed" "and nothing is installed"
  mk_kit
  printf 'more\n' > "$SANDBOX/kitsrc/lib/unlisted.sh"
  inst "$r/dev.sh" install-dck
  assert_rc 1 "a library file the sums do not cover is refused"
  assert_contains "$RUN_ERR" "lib/unlisted.sh is not covered" "and named"
  assert_not_file "$SANDBOX/installed" "nothing is installed"
}

test_devsh_install_dck_pins_and_validates() {
  local r sums
  r="$(new_repo devsh-pin)"
  init_repo "$r" --no-herdr --yes
  mk_kit
  sed -i.bak 's/^DCK_SUMS_SHA256=.*/DCK_SUMS_SHA256="'"$(printf '0%.0s' $(seq 1 64))"'"/' "$r/dev.sh" && rm -f "$r/dev.sh.bak"
  inst "$r/dev.sh" install-dck
  assert_rc 1 "a SHA256SUMS that differs from the pinned digest is refused"
  assert_contains "$RUN_ERR" "does not match the digest this repository pins" "and says why"
  sums="$(shasum -a 256 "$DCK_FAKE_STATE/curl/SHA256SUMS" 2>/dev/null | cut -d' ' -f1 || sha256sum "$DCK_FAKE_STATE/curl/SHA256SUMS" | cut -d' ' -f1)"
  sed -i.bak 's/^DCK_SUMS_SHA256=.*/DCK_SUMS_SHA256="'"$sums"'"/' "$r/dev.sh" && rm -f "$r/dev.sh.bak"
  inst "$r/dev.sh" install-dck
  assert_rc 0 "the pinned digest matches"
  sed -i.bak 's/^DCK_RENDERED_WITH=.*/DCK_RENDERED_WITH="main; touch pwned"/' "$r/dev.sh" && rm -f "$r/dev.sh.bak"
  inst "$r/dev.sh" install-dck
  assert_rc 2 "a rendered version that is not vX.Y.Z is refused"
  # A kit that knows its release digest embeds it at render time.
  printf 'v%s %s\n' "$(cat "$DCK_REPO/VERSION")" "$sums" > "$SANDBOX/digest"
  r="$(new_repo devsh-embed)"
  run_cmd env DCK_NONINTERACTIVE=1 DCK_TEST_RELEASE_SUMS="$SANDBOX/digest" "$DCK" init --repo "$r" --no-herdr --yes
  assert_contains "$(cat "$r/dev.sh")" "DCK_SUMS_SHA256=\"$sums\"" "the release digest is embedded when known"
}

test_devsh_fallback_preflight_and_project() {
  local r
  r="$(new_repo devsh-pre)"
  init_repo "$r" --no-herdr --yes
  : > "$DCK_FAKE_LOG"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" up
  assert_rc 0 "a dck-rendered compose file passes the preflight"
  assert_contains "$(fake_calls docker)" "compose -p devsh-pre -f docker/local/docker-compose.yaml" "plain compose uses dck's project name"
  local c="$r/docker/local/docker-compose.yaml" orig
  orig="$(cat "$c")"
  for bad in "    privileged: true" "    cap_add: [SYS_ADMIN]" "      - /var/run/docker.sock:/var/run/docker.sock" "    network_mode: host" "    pid: host" "    devices: [/dev/kvm]" "      - /etc:/host-etc" "      - ~/.ssh:/root/.ssh" "      - ../../..:/up"; do
    printf '%s\n%s\n' "$orig" "$bad" > "$c"
    run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" up
    assert_rc 5 "the fallback refuses: $bad"
  done
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" DCK_TRUST=1 bash "$r/dev.sh" up
  assert_rc 0 "DCK_TRUST=1 starts it anyway"
  printf '%s\n' "$orig" > "$c"
  printf 'DCK_HOST_SSH_AUTH_SOCK=/etc/passwd\n' > "$r/docker/local/.env"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" build
  assert_rc 5 "a .env redirecting the agent socket is refused"
}

test_devsh_fallback_env_files_are_safe() {
  local r
  r="$(new_repo devsh-env)"
  init_repo "$r" --no-herdr --yes
  rm -f "$r/docker/local/app/.env"
  printf 'SECRET=keep\n' > "$SANDBOX/outside"
  ln -s "$SANDBOX/outside" "$r/docker/local/app/.env"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" ps
  assert_eq "$(cat "$SANDBOX/outside")" "SECRET=keep" "a symlinked .env is never written through"
  rm -f "$r/docker/local/app/.env"
  mv "$r/docker/local/app/.env.example" "$SANDBOX/example"
  ln -s "$SANDBOX/example" "$r/docker/local/app/.env.example"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" ps
  assert_not_file "$r/docker/local/app/.env" "a symlinked example is never copied"
  rm -f "$r/docker/local/app/.env.example"; mv "$SANDBOX/example" "$r/docker/local/app/.env.example"
  printf 'MINE=1\n' > "$r/docker/local/app/.env"
  run_cmd env PATH="$(nodck_path)" HOME="$SANDBOX/nodck" bash "$r/dev.sh" ps
  assert_eq "$(cat "$r/docker/local/app/.env")" "MINE=1" "an existing .env is never overwritten"
}

# [compose] state_volume: the default keeps the volume every existing install has;
# a per-service name changes only the compose volume, never the mount point.
test_state_volume_default_and_per_service() {
  local r c
  r="$(new_repo sv)"
  init_repo "$r" --flavour debian --ssh-port 22050 --agents --clis "claude codex" --yes
  assert_rc 0 "dck init succeeds"
  c="$(cat "$r/docker/local/docker-compose.yaml")"
  assert_contains "$c" "      - state:/home/dev/.dck/volumes/state" "the default state volume keeps its name"
  assert_contains "$c" "  state: {}" "and its declaration"
  assert_contains "$c" "      - claude:/home/dev/.dck/volumes/claude" "the CLI volumes are unchanged"
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" 'state_volume = "state"' "dck.toml states the default"
  # An existing dck.toml without [compose] renders exactly as before.
  python3 -I -c 'import re, sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(re.sub(r"\n\[compose\][\s\S]*$", "\n", s))' "$r/.devcontainer/dck.toml"
  init_repo "$r" --dry-run
  assert_contains "$RUN_OUT" "unchanged docker/local/docker-compose.yaml" "a dck.toml without [compose] keeps today's volume"
  init_repo "$r" --state-volume state-sv --yes
  assert_rc 0 "--state-volume is accepted"
  c="$(cat "$r/docker/local/docker-compose.yaml")"
  assert_contains "$c" "      - state-sv:/home/dev/.dck/volumes/state" "the named volume mounts at the same place"
  assert_contains "$c" "  state-sv: {}" "and is declared"
  assert_not_contains "$c" "  state: {}" "the shared name is gone"
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" 'state_volume = "state-sv"' "the flag is written into dck.toml"
  init_repo "$r" --state-volume claude --yes
  assert_rc 3 "an agents-layer volume name is refused"
  assert_contains "$RUN_ERR" "compose.state_volume: 'claude' is an agents-layer volume" "and named"
  init_repo "$r" --state-volume "Bad Name" --yes
  assert_rc 3 "an invalid volume name is refused"
}

# --- v0.3.3: compose keys, the user block, markers ------------------------

# real_compose — the real docker CLI (not the fake), or "" when unavailable.
real_compose() {
  local real
  real="$(PATH="${PATH#"$TESTS_DIR/fakes/bin:"}" command -v docker || true)"
  if [ -n "$real" ] && "$real" compose version >/dev/null 2>&1; then printf '%s' "$real"; fi
}

# set_toml <repo> <python statement over s> — edit dck.toml text in place.
set_toml() {
  python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); exec(sys.argv[2]); open(p, "w").write(s)' \
    "$1/.devcontainer/dck.toml" "$2"
}

# add_user_block <repo> <block body lines (4-space indented)> — before the dck service end marker.
add_user_block() {
  python3 -I -c 'import sys; p, body = sys.argv[1], sys.argv[2]
s = open(p).read()
blk = "    # >>> user:app >>>\n" + body + "    # <<< user:app <<<\n"
s = s.replace("  # <<< dck:service <<<\n", blk + "  # <<< dck:service <<<\n", 1)
open(p, "w").write(s)' "$1/docker/local/docker-compose.yaml" "$2"
}

USER_BODY='    depends_on:
      - db
    x-dck-merge:
      env_file:
        - path: ./django/.env
          required: false
        - ./postgres/.env
      environment:
        DOCKER_DEV_ENV: "1"
        DCK_SSH: "0"
      volumes:
        - sqlite_volume:/app/src/databases
        - ../../..:/workspaces:ro
      networks:
        - shared-net
      extra_hosts: ["metadata.local:127.0.0.1"]
      command: ["python", "manage.py", "runserver", "0.0.0.0:8000"]
'

test_user_block_merges_and_stays_verbatim() {
  local r c
  r="$(new_repo ub)"
  init_repo "$r" --flavour python-3.13 --ssh-port 22060 --yes
  add_user_block "$r" "$USER_BODY"
  local before; before="$(sed -n '/# >>> user:app >>>/,/# <<< user:app <<</p' "$r/docker/local/docker-compose.yaml")"
  init_repo "$r" --yes
  assert_rc 0 "dck init reconciles a compose file with a user block"
  c="$(cat "$r/docker/local/docker-compose.yaml")"
  assert_eq "$(sed -n '/# >>> user:app >>>/,/# <<< user:app <<</p' "$r/docker/local/docker-compose.yaml")" "$before" "the user block is kept verbatim"
  assert_contains "$c" "      - path: ./django/.env
        required: false
      - ./postgres/.env" "env_file entries are appended after dck's"
  assert_contains "$c" "      - path: ./app/.env" "dck's own env_file stays"
  assert_contains "$c" '      DOCKER_DEV_ENV: "1"' "environment entries are merged"
  assert_contains "$c" '      DCK_SSH: "0"' "the user's value wins on the same environment key"
  assert_not_contains "$c" '      DCK_SSH: "1"' "dck's value for that key is replaced"
  assert_contains "$c" "      - sqlite_volume:/app/src/databases" "extra volumes are appended"
  assert_contains "$c" "      - state:/home/dev/.dck/volumes/state" "dck's volumes stay"
  assert_contains "$c" "  sqlite_volume: {}" "a named user volume is declared in dck's volumes block"
  assert_eq "$(grep -c '^volumes:' "$r/docker/local/docker-compose.yaml")" "1" "one top-level volumes:"
  assert_eq "$(grep -c '^networks:' "$r/docker/local/docker-compose.yaml")" "1" "one top-level networks:"
  assert_contains "$c" "  shared-net:
    external: true
    name: shared-net" "a network named in the block is declared external, once"
  assert_eq "$(grep -c '^      - shared-net$' "$r/docker/local/docker-compose.yaml")" "1" "and listed once on the service"
  assert_contains "$c" '      - "metadata.local:127.0.0.1"' "a flow list is appended item by item"
  assert_contains "$c" '    command: ["python", "manage.py", "runserver", "0.0.0.0:8000"]' "a scalar replaces dck's"
  assert_eq "$(grep -c "^    command:" "$r/docker/local/docker-compose.yaml")" "1" "command appears once among the service keys"
  init_repo "$r" --dry-run
  assert_contains "$RUN_OUT" "unchanged docker/local/docker-compose.yaml" "a second init is a no-op"
  local real; real="$(real_compose)"
  if [ -z "$real" ]; then
    unavailable "docker compose config accepts the merged file" "docker compose CLI not found"
  else
    mkdir -p "$r/docker/local/postgres"; : > "$r/docker/local/postgres/.env"
    python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); s = s.replace("  # <<< dck:service <<<\n", "  # <<< dck:service <<<\n  db:\n    image: busybox:1.37\n", 1); open(p, "w").write(s)' "$r/docker/local/docker-compose.yaml"
    run_cmd env DOCKER_HOST=unix:///nonexistent "$real" compose -f "$r/docker/local/docker-compose.yaml" config -q
    assert_rc 0 "docker compose config accepts the merged file"
  fi
}

test_user_block_errors_name_the_fix() {
  local r
  r="$(new_repo ue)"
  init_repo "$r" --flavour debian --ssh-port 22061 --yes
  add_user_block "$r" '    volumes:
      - x:/x
'
  init_repo "$r" --yes
  assert_rc 3 "a plain key dck also renders is refused"
  assert_contains "$RUN_ERR" "move it under x-dck-merge" "with the fix"
  git -C "$r" checkout -q -- . 2>/dev/null || true
  r="$(new_repo uh)"
  init_repo "$r" --flavour debian --ssh-port 22062 --yes
  python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); s = s.replace("  # <<< dck:service <<<\n", "    # >>> user:app >>>\n    depends_on: [db]\n  # <<< dck:service <<<\n", 1); open(p, "w").write(s)' "$r/docker/local/docker-compose.yaml"
  init_repo "$r" --yes
  assert_rc 3 "a user block without its end marker is refused"
  assert_contains "$RUN_ERR" "has no closing marker; add '    # <<< user:app <<<'" "naming the marker to add"
}

test_markers_are_all_or_nothing() {
  local r before
  r="$(new_repo mk)"
  init_repo "$r" --flavour debian --ssh-port 22063 --yes
  python3 -I -c 'import re, sys; p = sys.argv[1]; s = open(p).read(); s = re.sub(r"# >>> dck:volumes >>>\n[\s\S]*?# <<< dck:volumes <<<\n", "", s); open(p, "w").write(s)' "$r/docker/local/docker-compose.yaml"
  before="$(cat "$r/docker/local/docker-compose.yaml")"
  init_repo "$r" --yes
  assert_rc 5 "a partial marker set is refused"
  assert_contains "$RUN_ERR" "but not dck:volumes" "naming the missing block"
  assert_eq "$(cat "$r/docker/local/docker-compose.yaml")" "$before" "nothing is appended at EOF"
  r="$(new_repo mn)"
  init_repo "$r" --flavour debian --ssh-port 22064 --yes
  printf '\nnetworks:\n  mine:\n    external: true\n' >> "$r/docker/local/docker-compose.yaml"
  set_toml "$r" 's = s.replace("[compose]\n", "[compose]\nnetworks = [\"mine\"]\n", 1)'
  init_repo "$r" --yes
  assert_rc 5 "a second top-level networks: would be refused"
  assert_contains "$RUN_ERR" "already has a top-level 'networks:' outside dck's markers" "with the fix"
}

test_port_strings_and_compose_keys() {
  local r c d
  r="$(new_repo ps)"
  init_repo "$r" --flavour python-3.13 --ssh-port 22065 --yes
  set_toml "$r" 's = s.replace("ssh_port = 22065", "ssh_port = \"${PS_SSH_PORT:-22065}\"").replace("ports = {  }", "ports = { django = \"${DJANGO_RUNSERVER_HOST_PORT:-8000}:8000\", node = \"5001:3000\", pub = \"0.0.0.0:9000:9000\", web = 4321 }").replace("[compose]\n", "[compose]\nproject = \"sharedproj\"\nnetworks = [\"shared-net\", \"other-net\"]\n", 1) + "\n[build]\ncontext = \"../..\"\n"'
  init_repo "$r" --yes
  assert_rc 0 "dck init accepts port strings and the compose/build keys"
  c="$(cat "$r/docker/local/docker-compose.yaml")"
  assert_contains "$c" '      - "127.0.0.1:${PS_SSH_PORT:-22065}:22"' "an ssh_port expression is the host port, bound to loopback"
  assert_contains "$c" '      - "127.0.0.1:${DJANGO_RUNSERVER_HOST_PORT:-8000}:8000"' "a port expression is rendered verbatim after the bind address"
  assert_contains "$c" '      - "127.0.0.1:5001:3000"' "HOST:CONTAINER"
  assert_contains "$c" '      - "0.0.0.0:9000:9000"' "a string naming a host IP is verbatim"
  assert_contains "$c" '      - "127.0.0.1:4321:4321"' "an integer port as before"
  assert_contains "$c" "name: sharedproj" "[compose] project names the project"
  assert_contains "$c" "      context: ../..
      dockerfile: docker/local/app/Dockerfile" "[build] context, with the Dockerfile relative to it"
  assert_contains "$(cat "$r/docker/local/app/Dockerfile")" "COPY docker/local/app/dck/entrypoint.sh" "the Dockerfile's COPY paths follow the context"
  assert_eq "$(grep -c '^networks:' "$r/docker/local/docker-compose.yaml")" "1" "one top-level networks: for several external networks"
  assert_contains "$c" "      - default
      - shared-net
      - other-net" "the service joins each"
  run_cmd env DCK_NONINTERACTIVE=1 PS_SSH_PORT=22999 python3 -I "$DCK_REPO/lib/dckpy.py" devc read --repo "$r"
  assert_contains "$RUN_OUT" "DCK_SSH_PORT=22999" "the launcher resolves the expression from the environment"
  printf 'PS_SSH_PORT=22777\n' >> "$r/docker/local/.env"
  run_cmd env DCK_NONINTERACTIVE=1 python3 -I "$DCK_REPO/lib/dckpy.py" devc read --repo "$r"
  assert_contains "$RUN_OUT" "DCK_SSH_PORT=22777" "then from the compose directory's .env"
  local real; real="$(real_compose)"
  if [ -n "$real" ]; then
    run_cmd env DOCKER_HOST=unix:///nonexistent "$real" compose -f "$r/docker/local/docker-compose.yaml" config -q
    assert_rc 0 "docker compose config accepts port strings and several networks"
  fi
  d="$(new_repo df)"
  init_repo "$d" --flavour node-24 --service storybook --ssh-port 0 --yes
  set_toml "$d" 's += "\n[build]\ndockerfile = \"docker/local/vue/Dockerfile\"\n"'
  mkdir -p "$d/docker/local/vue"
  init_repo "$d" --yes
  assert_rc 0 "[build] dockerfile is accepted"
  assert_contains "$(cat "$d/docker/local/docker-compose.yaml")" "      context: ./vue
      dockerfile: Dockerfile" "the service builds from the shared Dockerfile"
  assert_file "$d/docker/local/vue/Dockerfile" "dck's managed blocks go into the shared Dockerfile"
  assert_file "$d/docker/local/vue/dck/entrypoint.sh" "its dck/ directory goes next to it"
}

test_agent_presets() {
  local r
  r="$(new_repo pr)"
  init_repo "$r" --flavour node-24 --agents --clis "claude" --ssh-port 0 --yes
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" "presets = []" "a new render turns the ak presets off"
  assert_contains "$(cat "$r/docker/local/app/Dockerfile")" 'RUN DCK_USER=dev DCK_AGENT_SUPPORTED="claude" DCK_AGENT_PRESETS="" dck-layer agents ${DCK_AGENT_CLIS}' "and the layer is told so (with the wired CLIs)"
  set_toml "$r" 's = s.replace("presets = []", "presets = [\"classic\"]")'
  init_repo "$r" --yes
  assert_contains "$(cat "$r/docker/local/app/Dockerfile")" 'DCK_AGENT_PRESETS="classic"' "a chosen preset is passed"
  set_toml "$r" 'import re; s = re.sub(r"\npresets = .*", "", s)'
  init_repo "$r" --yes
  assert_contains "$(cat "$r/docker/local/app/Dockerfile")" 'RUN DCK_USER=dev DCK_AGENT_SUPPORTED="claude" dck-layer agents ${DCK_AGENT_CLIS}' "no presets key passes no DCK_AGENT_PRESETS (both on)"
  set_toml "$r" 's = s.replace("[agents]\n", "[agents]\npresets = [\"bogus\"]\n", 1)'
  init_repo "$r" --yes
  assert_rc 3 "an unknown preset is refused"
}

test_up_warns_about_a_stale_compose_file() {
  local r
  r="$(new_repo st)"
  init_repo "$r" --flavour debian --ssh-port 0 --yes
  add_user_block "$r" '    x-dck-merge:
      environment:
        STALE_MARK: "1"
'
  run_cmd bash -c 'cd "$1" && DCK_BACKEND=compose "$2" up' _ "$r" "$DCK"
  assert_contains "$RUN_ERR" "does not reflect dck.toml or its user block — run: dck init" "dck up warns when the user block is not rendered yet"
  init_repo "$r" --yes
  run_cmd bash -c 'cd "$1" && DCK_BACKEND=compose "$2" up' _ "$r" "$DCK"
  assert_not_contains "$RUN_ERR" "does not reflect" "and is quiet once it is"
}

test_port_string_container_expression() {
  local r
  r="$(new_repo pe)"
  init_repo "$r" --flavour debian --ssh-port 0 --yes
  set_toml "$r" 's = s.replace("ports = {  }", "ports = { web = \"${WEB_HOST:-8000}:${WEB_PORT:-8000}\" }")'
  init_repo "$r" --yes
  assert_rc 0 "an expression on the container side is accepted"
  assert_contains "$(cat "$r/docker/local/docker-compose.yaml")" '      - "127.0.0.1:${WEB_HOST:-8000}:${WEB_PORT:-8000}"' "and rendered verbatim"
}

# #13: the file's other services declare their own volumes and networks.
test_top_level_user_blocks_and_compose_volumes() {
  local r c
  r="$(new_repo tv)"
  init_repo "$r" --flavour python-3.13 --ssh-port 0 --yes
  python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read()
s = s.replace("  # <<< dck:service <<<\n", "  # <<< dck:service <<<\n  postgres:\n    image: postgres:16-alpine\n    volumes:\n      - local_postgres14_data:/var/lib/postgresql/data\n      - local_postgres14_data_backups:/backups\n    networks:\n      - backend\n", 1)
s = s.replace("# <<< dck:volumes <<<\n", "  # >>> user:volumes >>>\n  local_postgres14_data: {}\n  local_postgres14_data_backups: {}\n  # <<< user:volumes <<<\n# <<< dck:volumes <<<\n", 1)
s = s.rstrip("\n") + "\n\n# >>> dck:networks >>>\nnetworks:\n  # >>> user:networks >>>\n  backend: {}\n  # <<< user:networks <<<\n# <<< dck:networks <<<\n"
open(p, "w").write(s)' "$r/docker/local/docker-compose.yaml"
  set_toml "$r" 's = s.replace("[compose]\n", "[compose]\nvolumes = [\"dynamodb_data\"]\n", 1)'
  local before; before="$(sed -n '/# >>> user:volumes >>>/,/# <<< user:volumes <<</p' "$r/docker/local/docker-compose.yaml")"
  init_repo "$r" --yes
  assert_rc 0 "dck init keeps the top-level user blocks"
  c="$(cat "$r/docker/local/docker-compose.yaml")"
  assert_eq "$(sed -n '/# >>> user:volumes >>>/,/# <<< user:volumes <<</p' "$r/docker/local/docker-compose.yaml")" "$before" "the user:volumes block is verbatim"
  assert_contains "$c" "  # >>> user:networks >>>
  backend: {}" "the user:networks block is kept, with no external network of dck's"
  assert_contains "$c" "  dynamodb_data: {}" "[compose] volumes declares a volume with its exact name"
  assert_contains "$c" "  state: {}" "dck's volumes are still declared"
  assert_eq "$(grep -c '^volumes:' "$r/docker/local/docker-compose.yaml")" "1" "one top-level volumes:"
  assert_eq "$(grep -c '^networks:' "$r/docker/local/docker-compose.yaml")" "1" "one top-level networks:"
  init_repo "$r" --dry-run
  assert_contains "$RUN_OUT" "unchanged docker/local/docker-compose.yaml" "idempotent"
  local real; real="$(real_compose)"
  if [ -n "$real" ]; then
    run_cmd env DOCKER_HOST=unix:///nonexistent "$real" compose -f "$r/docker/local/docker-compose.yaml" config -q
    assert_rc 0 "docker compose config accepts the other services' volumes and networks"
  fi
  # A name declared twice is refused.
  python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); s = s.replace("  local_postgres14_data: {}\n", "  local_postgres14_data: {}\n  state: {}\n", 1); open(p, "w").write(s)' "$r/docker/local/docker-compose.yaml"
  init_repo "$r" --yes
  assert_rc 3 "a volume declared in user:volumes and by dck is refused"
  assert_contains "$RUN_ERR" "volume 'state' is declared in the user:volumes block and by dck" "naming it"
}

# #15: command (and entrypoint) replace dck's in every YAML form, never append.
test_user_command_replaces_in_every_form() {
  local r c form
  for form in flow block string; do
    r="$(new_repo "cmd$form")"
    init_repo "$r" --flavour debian --ssh-port 0 --yes
    case "$form" in
      flow) add_user_block "$r" '    x-dck-merge:
      command: ["python", "manage.py", "runserver"]
' ;;
      block) add_user_block "$r" '    x-dck-merge:
      command:
        - python
        - manage.py
        - runserver
' ;;
      string) add_user_block "$r" '    x-dck-merge:
      command: python manage.py runserver
' ;;
    esac
    init_repo "$r" --yes
    assert_rc 0 "dck init accepts command as a $form"
    c="$(sed -n '/^  app:/,/# >>> user:app >>>/p' "$r/docker/local/docker-compose.yaml")"
    assert_not_contains "$c" "sleep" "command as a $form replaces dck's [sleep, infinity]"
    assert_contains "$c" "runserver" "the user's command ($form) is the service's"
    assert_eq "$(printf '%s\n' "$c" | grep -c '^    command:')" "1" "one command key ($form)"
    local real; real="$(real_compose)"
    if [ -n "$real" ]; then
      run_cmd env DOCKER_HOST=unix:///nonexistent "$real" compose -f "$r/docker/local/docker-compose.yaml" config --format json
      assert_contains "$RUN_OUT" '"runserver"' "compose sees the user's command ($form)"
      assert_not_contains "$RUN_OUT" '"infinity"' "and not dck's ($form)"
    fi
  done
}

# #19: a repository with its own dev.sh.
test_no_dev_sh() {
  local r
  r="$(new_repo nd)"
  printf '#!/usr/bin/env bash\necho "the repository'"'"'s own"\n' > "$r/dev.sh"
  local before; before="$(cat "$r/dev.sh")"
  init_repo "$r" --flavour debian --ssh-port 0 --no-dev-sh --yes
  assert_rc 0 "dck init --no-dev-sh succeeds"
  assert_eq "$(cat "$r/dev.sh")" "$before" "the repository's dev.sh is untouched"
  assert_contains "$(cat "$r/.devcontainer/dck.toml")" "dev_sh = false" "the choice is recorded in dck.toml"
  init_repo "$r" --dry-run
  assert_contains "$RUN_OUT" "unchanged dev.sh" "later inits keep it"
  local e; e="$(new_repo nd2)"
  init_repo "$e" --flavour debian --ssh-port 0 --no-dev-sh --yes
  assert_absent "$e/dev.sh" "no dev.sh is created"
}

# #22: [agents] node_first puts the agents' Node first; off by default.
test_agents_node_first() {
  local r
  r="$(new_repo nf)"
  init_repo "$r" --flavour python-3.13 --agents --clis "codex" --ssh-port 0 --yes
  assert_not_contains "$(cat "$r/docker/local/app/Dockerfile")" "/opt/dck/node/bin" "off by default: the image's node stays first"
  set_toml "$r" 's = s.replace("[agents]\n", "[agents]\nnode_first = true\n", 1)'
  init_repo "$r" --yes
  assert_rc 0 "node_first is accepted"
  assert_contains "$(cat "$r/docker/local/app/Dockerfile")" 'ENV PATH=/opt/dck/node/bin:$PATH' "the agents' Node comes first for every process"
  local d; d="$(new_repo nf2)"
  init_repo "$d" --flavour debian --no-agents --ssh-port 0 --yes
  set_toml "$d" 's = s.replace("[agents]\n", "[agents]\nnode_first = true\n", 1)'
  init_repo "$d" --yes
  assert_contains "$RUN_ERR" "agents.node_first is set but layers.agents is false" "without the agents layer it warns"
}

# v0.3.4: a preflight refusal is visible through dev.sh even with stderr discarded.
test_devsh_surfaces_a_refusal() {
  local r
  r="$(new_repo rf)"
  init_repo "$r" --flavour debian --ssh-port 0 --no-herdr --yes
  # A hand-written host mount the preflight refuses without --trust.
  python3 -I -c 'import sys; p = sys.argv[1]; s = open(p).read(); s = s.replace("  # <<< dck:service <<<\n", "  # <<< dck:service <<<\n  side:\n    image: busybox:1.37\n    volumes:\n      - /etc:/host-etc:ro\n", 1); open(p, "w").write(s)' "$r/docker/local/docker-compose.yaml"
  run_cmd bash -c 'cd "$1" && PATH="$2:$PATH" DCK_BACKEND=compose DCK_NONINTERACTIVE=1 bash dev.sh up 2>/dev/null' _ "$r" "$DCK_REPO/bin"
  assert_rc 5 "dck's refusal code is kept"
  assert_contains "$RUN_OUT" "dev.sh: dck refused to up (exit 5)" "the refusal is on stdout, visible with stderr discarded"
  assert_contains "$RUN_OUT" "DCK_TRUST=1 bash dev.sh up" "with the way through once reviewed"
}

# v0.3.5: a workspace under the renamed user's home (workspace = /home/node/app).
test_workspace_under_the_renamed_home() {
  local r d
  r="$(new_repo wh)"
  init_repo "$r" --flavour node-24 --user node --workspace /home/node/app --ssh-port 0 --yes
  assert_rc 0 "dck init renders a workspace under /home/node"
  d="$(cat "$r/docker/local/app/Dockerfile")"
  local rename workdir install
  rename="$(grep -n '^RUN usermod -l node -d /home/node -m dev' "$r/docker/local/app/Dockerfile" | cut -d: -f1)"
  install="$(grep -n '^RUN install -d -o node -g node /home/node/app$' "$r/docker/local/app/Dockerfile" | cut -d: -f1)"
  workdir="$(grep -n '^WORKDIR /home/node/app$' "$r/docker/local/app/Dockerfile" | cut -d: -f1)"
  assert_eq "$([ -n "$rename" ] && [ -n "$workdir" ] && [ "$rename" -lt "$workdir" ] && echo before)" "before" "the user is renamed (and its home moved) before WORKDIR"
  assert_eq "$([ -n "$install" ] && [ "$install" -lt "$workdir" ] && echo before)" "before" "the workspace is created as the user's, before WORKDIR"
  local p; p="$(new_repo wp)"
  init_repo "$p" --flavour debian --ssh-port 0 --yes
  assert_not_contains "$(cat "$p/docker/local/app/Dockerfile")" "usermod" "no rename, no usermod"
  assert_not_contains "$(cat "$p/docker/local/app/Dockerfile")" "install -d -o" "nor a workspace step"
}

# v0.3.6: dck init offers the advanced CLI mode (interactive, agents on, new render).
test_init_offers_the_advanced_cli_mode() {
  local r answer
  for answer in yes no; do
    r="$(new_repo "offer-$answer")"
    run_cmd python3 -I - "$DCK_REPO" "$r" "$answer" <<'PY'
import os, sys
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import render
asked = []
render.ask = lambda q: asked.append(q) or sys.argv[3] == "yes"
opts = {"repo": sys.argv[2], "flavour": "node-24", "agents": True, "clis": ["claude", "codex"], "ssh_port": 0,
        "herdr_machine": False, "yes": True, "interactive": True}
rc = render.init(opts, "v" + open(os.path.join(sys.argv[1], "VERSION")).read().strip())
print("rc=%d asked=%d" % (rc, len(asked)))
print(asked[0] if asked else "")
PY
    assert_contains "$RUN_OUT" "rc=0 asked=1" "init asks once ($answer)"
    assert_contains "$RUN_OUT" "wires and installs claude codex for everyone (the default)" "the question names the default ($answer)"
    if [ "$answer" = yes ]; then
      assert_contains "$(cat "$r/.devcontainer/dck.toml")" 'supported = "all"' "yes: the advanced mode is written"
    else
      assert_no_match "$(cat "$r/.devcontainer/dck.toml")" '^supported' "no: the default mode (no supported key)"
    fi
  done
}
