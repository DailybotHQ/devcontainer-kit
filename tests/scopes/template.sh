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
  assert_eq "$RUN_OUT" "app ['app'] dev /workspace none ../docker/local/docker-compose.yaml" "devcontainer.json carries the owned keys"
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
  assert_contains "$RUN_OUT" "replace   docker/local/app/Dockerfile (no dck markers: whole file)" "unbalanced markers are a whole-file proposal"
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
  assert_contains "$c" '- ${DCK_HOST_SSH_AUTH_SOCK:-/run/host-services/ssh-auth.sock}:/run/dck/ssh-agent.sock' "the host SSH agent socket is mounted (no key file)"
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
  run_cmd env PATH=/usr/bin:/bin bash "$r/dev.sh" up
  assert_rc 4 "without dck, dev.sh says how to install it"
  assert_contains "$RUN_ERR" "git clone --branch v$(cat "$DCK_REPO/VERSION") https://github.com/DailybotHQ/devcontainer-kit" "the install line is pinned"
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
  assert_contains "$(cat "$r/dev.sh")" "herdr-layout) exec dck herdr layout" "dev.sh herdr-layout maps to dck herdr layout"
}
