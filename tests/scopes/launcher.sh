# shellcheck shell=bash
# Scope: launcher — bin/dck verbs against fake docker/devcontainer/ssh, and install.sh.

DCK="$DCK_REPO/bin/dck"
use_fakes
export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_NO_DIGEST=1

# A repository rendered by `dck init` (ssh on 22040, a named port), git-initialised.
REPO="$SANDBOX/proj"
mk_repo() {
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  "$DCK" init --repo "$REPO" --flavour node-24 --ssh-port 22040 --port web=4321 --no-herdr --yes >/dev/null 2>&1 \
    || { fail "fixture: dck init failed"; return 1; }
  : > "$DCK_FAKE_LOG"
}

d() { run_cmd bash -c 'cd "$1" && shift && "$@"' _ "$REPO" "$DCK" "$@"; }
# denv VAR=value... <command...> — run in the repository with extra environment.
denv() { run_cmd bash -c 'cd "$1" && shift && env "$@"' _ "$REPO" "$@"; }
compose_prefix() { printf 'docker compose -p proj -f %s/docker/local/docker-compose.yaml' "$REPO"; }

test_version_and_help() {
  run_cmd "$DCK" --version
  assert_eq "$RUN_OUT" "devcontainer-kit $(cat "$DCK_REPO/VERSION")" "--version prints the version"
  run_cmd "$DCK_REPO/bin/devcontainer-kit" --version
  assert_eq "$RUN_OUT" "devcontainer-kit $(cat "$DCK_REPO/VERSION")" "devcontainer-kit is the same command"
  run_cmd "$DCK" help
  local v
  for v in init setup up down stop start restart ps logs shell exec build rebuild config ports ssh; do
    assert_match "$RUN_OUT" "^  $v( |$)" "help documents '$v'"
  done
  run_cmd "$DCK" nope
  assert_rc 2 "an unknown verb is a usage error"
  run_cmd "$DCK" --bogus
  assert_rc 2 "an unknown flag is a usage error"
}

test_outside_a_repository() {
  mkdir -p "$SANDBOX/empty"
  run_cmd bash -c 'cd "$1" && "$2" ps' _ "$SANDBOX/empty" "$DCK"
  assert_rc 3 "outside a repository is a configuration error"
  assert_contains "$RUN_ERR" "run: dck init" "the error says what to do"
}

test_finds_repo_from_subdirectory() {
  mk_repo || return 0
  mkdir -p "$REPO/src/deep"
  run_cmd bash -c 'cd "$1" && "$2" ps' _ "$REPO/src/deep" "$DCK"
  assert_rc 0 "dck works from a subdirectory"
  assert_contains "$(fake_calls docker)" "$(compose_prefix) ps app" "it acts on the enclosing repository"
}

test_setup() {
  mk_repo || return 0
  d setup
  assert_rc 0 "setup succeeds"
  assert_file "$REPO/docker/local/app/.env" "setup creates .env from .env.example"
  assert_mode "$REPO/docker/local/app/.env" 600 ".env is created 0600"
  assert_file "$HOME/.config/dck/ssh/id_ed25519" "setup creates the dedicated dck key"
  assert_mode "$HOME/.config/dck/ssh/id_ed25519" 600 "the dck private key is 0600"
  assert_mode "$HOME/.config/dck/ssh" 700 "the dck key directory is 0700"
  d setup
  assert_contains "$RUN_OUT" "setup: everything was already in place" "a second setup changes nothing"
  # The value is built at run time: no secret-shaped literal is committed.
  local fake="placeholder-$$-value"
  echo "FOO_API_KEY=$fake" >> "$REPO/docker/local/app/.env"
  chmod 644 "$REPO/docker/local/app/.env"
  d setup
  assert_contains "$RUN_OUT" "narrowed docker/local/app/.env to 0600" "a readable .env is narrowed, loudly"
  assert_mode "$REPO/docker/local/app/.env" 600 ".env is 0600 again"
  assert_not_contains "$RUN_OUT$RUN_ERR" "$fake" "no env value is ever printed"
}

test_setup_creates_external_networks() {
  mkdir -p "$XDG_CONFIG_HOME/dck"
  printf 'network = "acme-dev"\n' > "$XDG_CONFIG_HOME/dck/profile.toml"
  mk_repo || return 0
  d setup
  assert_contains "$(fake_calls docker)" "docker network create acme-dev" "a missing external network is created"
  : > "$DCK_FAKE_LOG"
  d setup
  assert_not_contains "$(fake_calls docker)" "network create" "an existing network is left alone"
}

test_up_with_compose() {
  mk_repo || return 0
  d up
  assert_rc 0 "up succeeds"
  assert_contains "$(fake_calls docker)" "$(compose_prefix) up -d --no-recreate app" "up starts exactly runServices, detached, without recreating"
  assert_not_contains "$(fake_calls docker)" "--remove-orphans" "up never passes --remove-orphans"
  assert_match "$(cat "$DCK_FAKE_STATE/last_authorized_keys")" '^ssh-ed25519 [A-Za-z0-9+/]+=* dck@' "up hands the dck public key to compose"
  assert_not_contains "$(cat "$DCK_FAKE_STATE/last_authorized_keys")" "PRIVATE" "only the public key is passed"
  assert_file "$REPO/docker/local/app/.env" "up creates a missing .env first"
  d up --recreate
  assert_contains "$(fake_calls docker)" "$(compose_prefix) up -d --force-recreate app" "--recreate forces recreation"
  d up --bogus
  assert_rc 2 "an unknown up flag is a usage error"
}

test_up_with_devcontainer_cli() {
  mk_repo || return 0
  denv DCK_BACKEND=auto "$DCK" up
  assert_contains "$(fake_calls devcontainer)" "devcontainer up --workspace-folder $REPO" "with the devcontainer CLI present, up uses it"
  assert_eq "$(fake_calls docker | grep -c ' up ' || true)" "0" "compose up is not called on that path"
  denv DCK_BACKEND=auto "$DCK" up --recreate
  assert_contains "$(fake_calls devcontainer)" "--remove-existing-container" "--recreate maps to --remove-existing-container"
  denv DCK_BACKEND=auto "$DCK" --project other up
  assert_contains "$(fake_calls docker)" "docker compose -p other" "an explicit --project always uses compose"
}

test_project_name_resolution() {
  mk_repo || return 0
  sed -i.orig '/^name: proj$/d' "$REPO/docker/local/docker-compose.yaml" && rm -f "$REPO/docker/local/docker-compose.yaml.orig"
  d ps
  assert_rc 5 "the directory-name default project is refused"
  assert_contains "$RUN_ERR" "refusing the directory-name default compose project" "the refusal explains itself"
  d --project custom ps
  assert_contains "$(fake_calls docker)" "docker compose -p custom" "--project names the project"
  denv COMPOSE_PROJECT_NAME=fromenv "$DCK" ps
  assert_contains "$(fake_calls docker)" "docker compose -p fromenv" "COMPOSE_PROJECT_NAME names the project"
  printf 'COMPOSE_PROJECT_NAME="fromfile"\n' > "$REPO/docker/local/.env"
  d ps
  assert_contains "$(fake_calls docker)" "docker compose -p fromfile" "COMPOSE_PROJECT_NAME in docker/local/.env names the project"
  d --project 'Bad Name' ps
  assert_rc 3 "an invalid project name is refused"
}

test_down_stop_start_restart() {
  mk_repo || return 0
  d down
  assert_contains "$(fake_calls docker)" "$(compose_prefix) rm -sf app" "down removes only this repository's services"
  assert_no_match "$(fake_calls docker)" ' down( |$)' "down never runs compose down"
  assert_contains "$RUN_OUT" "named volumes were kept" "down says volumes are kept"
  d stop
  assert_contains "$(fake_calls docker)" "$(compose_prefix) stop app" "stop stops runServices"
  assert_absent "$REPO/docker/local/app/.env" "stop runs no environment checks"
  d start
  assert_contains "$(fake_calls docker)" "$(compose_prefix) start app" "start starts runServices"
  d restart
  assert_contains "$(fake_calls docker)" "$(compose_prefix) restart app" "restart restarts runServices"
}

test_ps_and_logs() {
  mk_repo || return 0
  d ps
  assert_contains "$(fake_calls docker)" "$(compose_prefix) ps app" "ps lists runServices"
  d logs
  assert_contains "$(fake_calls docker)" "$(compose_prefix) logs -f --tail 200 app" "logs follows by default"
  d logs --no-follow
  assert_contains "$(fake_calls docker)" "$(compose_prefix) logs --tail 200 app" "--no-follow does not follow"
}

test_shell() {
  mk_repo || return 0
  d shell
  assert_contains "$(fake_calls docker)" "$(compose_prefix) exec -T --user dev -e HOME=/home/dev -e USER=dev -e LOGNAME=dev -w /workspace app bash -l" "shell opens a login shell as remoteUser in workspaceFolder"
  d shell -c "true"
  assert_contains "$(fake_calls docker)" "-w /workspace app bash -lc true" "shell -c runs one command in a login shell"
  denv DCK_BACKEND=auto "$DCK" shell -c "true"
  assert_contains "$(fake_calls devcontainer)" "devcontainer exec --workspace-folder $REPO bash -lc true" "with the devcontainer CLI, shell uses devcontainer exec"
  d shell -x
  assert_rc 2 "an unknown shell flag is a usage error"
}

test_exec() {
  mk_repo || return 0
  d exec app ls -la /tmp
  assert_contains "$(fake_calls docker)" "-w /workspace app ls -la /tmp" "exec passes the command verbatim, flags included"
  d exec db psql -c 'select 1'
  assert_contains "$(fake_calls docker)" "$(compose_prefix) exec -T db psql -c select 1" "a backing service is entered without remoteUser"
  d exec app
  assert_rc 2 "exec without a command is a usage error"
}

test_build_and_rebuild() {
  mk_repo || return 0
  d build
  assert_contains "$(fake_calls docker)" "$(compose_prefix) build app" "build builds runServices"
  d build --no-cache
  assert_contains "$(fake_calls docker)" "$(compose_prefix) build --no-cache --pull app" "build --no-cache also pulls"
  : > "$DCK_FAKE_LOG"
  d rebuild
  assert_eq "$(fake_calls docker | grep -E ' (build|up) ' | sed "s#$(compose_prefix) ##")" "build app
up -d --force-recreate app" "rebuild builds, then recreates"
  denv DCK_BACKEND=auto "$DCK" rebuild --no-cache
  assert_contains "$(fake_calls devcontainer)" "--remove-existing-container --build-no-cache" "rebuild --no-cache through the devcontainer CLI"
}

test_overlay_reproduces_mounts_and_env() {
  mk_repo || return 0
  python3 - "$REPO/.devcontainer/devcontainer.json" <<'PY'
import json, sys
sys.path.insert(0, __import__("os").environ["DCK_REPO"] + "/lib")
import jsonc
p = sys.argv[1]
d = jsonc.load(p)
d["mounts"] = ["source=cache,target=/home/dev/.cache,type=volume",
               "source=proj_shared,target=/shared,type=volume",
               {"source": "/opt/data", "target": "/data", "type": "bind", "readonly": True}]
d["containerEnv"] = {"APP_MODE": "dev"}
open(p, "w").write(json.dumps(d, indent=2))
PY
  local tmpd="$SANDBOX/tmp"
  mkdir -p "$tmpd"
  denv TMPDIR="$tmpd" "$DCK" up
  assert_rc 5 "a host bind mount in devcontainer.json needs --trust"
  assert_contains "$RUN_ERR" "a host path outside the repository (/opt/data)" "the preflight names it"
  denv TMPDIR="$tmpd" "$DCK" --trust up
  local ov="$tmpd/dck-$(id -u)/proj-overlay.yml"
  assert_file "$ov" "an overlay is written for mounts/containerEnv"
  assert_mode "$ov" 600 "the overlay is private"
  assert_contains "$(cat "$ov")" 'APP_MODE: "dev"' "containerEnv is reproduced"
  assert_contains "$(cat "$ov")" '- "/opt/data:/data:ro"' "a read-only bind mount is reproduced (quoted)"
  assert_contains "$(cat "$ov")" "    name: proj_shared" "an already-qualified volume is external by name"
  assert_contains "$(cat "$ov")" "  cache: {}" "a short volume is declared normally"
  assert_contains "$(fake_calls docker)" "-f $ov up -d" "compose is given the overlay"
}

test_overlay_dir_must_be_ours() {
  mk_repo || return 0
  python3 - "$REPO/.devcontainer/devcontainer.json" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["DCK_REPO"] + "/lib")
import jsonc
p = sys.argv[1]; d = jsonc.load(p); d["containerEnv"] = {"A": "1"}
open(p, "w").write(json.dumps(d))
PY
  local tmpd="$SANDBOX/tmp2"
  mkdir -p "$tmpd" "$SANDBOX/attacker"
  ln -s "$SANDBOX/attacker" "$tmpd/dck-$(id -u)"
  denv TMPDIR="$tmpd" "$DCK" up
  assert_rc 5 "a symlinked overlay directory is refused"
  assert_eq "$(ls -A "$SANDBOX/attacker")" "" "nothing is written through it"
}

test_config_and_ports() {
  mk_repo || return 0
  d config
  assert_rc 0 "config succeeds"
  assert_contains "$RUN_OUT" "compose project  proj (from name: in docker/local/docker-compose.yaml)" "config shows the project and where it came from"
  assert_contains "$RUN_OUT" "backend          compose" "config shows the backend"
  assert_contains "$RUN_OUT" "ssh              127.0.0.1:22040 → 22, alias dck-proj" "config shows ssh and the alias"
  assert_eq "$(fake_calls docker | grep -cv 'version' || true)" "0" "config runs no container command"
  d ports
  assert_contains "$RUN_OUT" "ssh    127.0.0.1:22040 -> 22" "ports lists the ssh port"
  assert_contains "$RUN_OUT" "web    127.0.0.1:4321 -> 4321" "ports lists named ports"
}

test_ssh() {
  mk_repo || return 0
  d ssh
  assert_rc 1 "ssh refuses a stopped container"
  assert_contains "$RUN_ERR" "app is not running — run: dck up" "the refusal says what to do"
  echo "proj-app-1" > "$DCK_FAKE_STATE/ps"
  d ssh
  assert_rc 3 "ssh without the dck key says how to create it"
  d setup
  d ssh uname -a
  assert_rc 0 "ssh runs"
  local call; call="$(fake_calls ssh)"
  assert_contains "$call" "-p 22040" "ssh uses the loopback port"
  assert_contains "$call" "-i $HOME/.config/dck/ssh/id_ed25519 -o IdentitiesOnly=yes" "ssh uses only the dedicated key"
  assert_contains "$call" "-o ForwardAgent=yes" "ssh forwards the agent (keys stay on the host)"
  assert_contains "$call" "-o StrictHostKeyChecking=accept-new" "a changed host key is refused"
  assert_contains "$call" "-o HostKeyAlias=dck-proj" "host keys are recorded per repository alias"
  assert_contains "$call" "-o UserKnownHostsFile=$HOME/.config/dck/ssh/known_hosts" "known hosts go to dck's own file"
  assert_contains "$call" "dev@127.0.0.1 uname -a" "the command is passed through"
  sed -i.orig 's/^ssh_port = 22040$/ssh_port = 0/' "$REPO/.devcontainer/dck.toml" && rm -f "$REPO/.devcontainer/dck.toml.orig"
  d ssh
  assert_rc 3 "ssh is refused when ssh_port is 0"
}

test_docker_missing() {
  mk_repo || return 0
  local bin="$SANDBOX/nodocker" t
  mkdir -p "$bin"
  for t in bash sh env python3 git sed grep cat dirname basename readlink pwd tr id mkdir find sort head tail awk stat chmod hostname uname ssh-keygen mktemp; do
    command -v "$t" >/dev/null 2>&1 && ln -s "$(command -v "$t")" "$bin/$t"
  done
  run_cmd env PATH="$bin" bash -c 'cd "$1" && "$2" up' _ "$REPO" "$DCK"
  assert_rc 4 "up without docker is an environment error"
  assert_contains "$RUN_ERR" "docker is not on PATH" "the error names docker"
}

test_python_isolation() {
  mk_repo || return 0
  printf 'raise SystemExit("planted json.py was imported")\n' > "$REPO/json.py"
  printf 'raise SystemExit("planted config.py was imported")\n' > "$REPO/config.py"
  d config
  assert_rc 0 "files named like stdlib or dck modules in the repo are never imported"
}

test_no_repository_names_hardcoded() {
  assert_no_match "$(cat "$DCK_REPO"/bin/* "$DCK_REPO"/lib/*.sh "$DCK_REPO"/lib/*.py)" 'dailybot|dwpwebsite|pertechtalks|xergioalex|deepworkplan-website' "no repository is known by name"
}

test_system_bash() {
  mk_repo || return 0
  run_cmd bash -c 'cd "$1" && /bin/bash "$2" ps' _ "$REPO" "$DCK"
  assert_rc 0 "dck runs under the system bash ($(/bin/bash -c 'echo $BASH_VERSION'))"
}

test_install_no_rc() {
  run_cmd bash "$DCK_REPO/install.sh" --no-rc
  assert_rc 0 "install.sh --no-rc succeeds"
  local dest="$HOME/.local/share/dck"
  assert_file "$dest/bin/dck" "dck is installed under ~/.local/share/dck"
  assert_file "$dest/lib/config.py" "the library is installed"
  assert_file "$dest/src/template/docker/docker-compose.yaml.tmpl" "the template is installed"
  assert_file "$dest/images/versions.env" "the pin file is installed (for drift checks)"
  assert_absent "$HOME/.bashrc" "--no-rc touches no rc file"
  assert_absent "$dest/tests" "tests are not installed"
  run_cmd "$dest/bin/dck" --version
  assert_eq "$RUN_OUT" "devcontainer-kit $(cat "$DCK_REPO/VERSION")" "the installed dck runs"
  mkdir -p "$SANDBOX/r" && git -C "$SANDBOX/r" init -q
  run_cmd "$dest/bin/dck" init --repo "$SANDBOX/r" --yes --no-herdr
  assert_rc 0 "the installed dck can render the template"
  run_cmd bash "$DCK_REPO/install.sh" --no-rc
  assert_rc 0 "installing again succeeds (idempotent)"
  assert_eq "$(ls "$HOME/.local/share" | grep -c '^dck')" "1" "no staging directory is left behind"
}

test_install_rc_block_and_uninstall() {
  printf '# my bashrc\n' > "$HOME/.bashrc"
  run_cmd bash "$DCK_REPO/install.sh"
  run_cmd bash "$DCK_REPO/install.sh"
  assert_eq "$(grep -c '# >>> devcontainer-kit (dck) >>>' "$HOME/.bashrc")" "1" "the rc block is added once, however often install runs"
  assert_contains "$(cat "$HOME/.bashrc")" "# my bashrc" "the rest of the rc file is kept"
  run_cmd bash -c '. "$HOME/.bashrc"; command -v dck'
  assert_eq "$RUN_OUT" "$HOME/.local/share/dck/bin/dck" "the rc block puts dck on PATH"
  run_cmd bash "$DCK_REPO/install.sh" --uninstall
  assert_rc 0 "uninstall succeeds"
  assert_absent "$HOME/.local/share/dck" "uninstall removes the install"
  assert_not_contains "$(cat "$HOME/.bashrc")" "devcontainer-kit" "uninstall removes the rc block"
  assert_contains "$(cat "$HOME/.bashrc")" "# my bashrc" "uninstall keeps the user's lines"
}

test_install_refuses_foreign_directory() {
  mkdir -p "$HOME/.local/share/dck"
  echo "mine" > "$HOME/.local/share/dck/notes.txt"
  run_cmd bash "$DCK_REPO/install.sh" --no-rc
  assert_rc 5 "install refuses to replace a directory that is not a dck install"
  assert_file "$HOME/.local/share/dck/notes.txt" "the foreign directory is untouched"
  run_cmd env DCK_INSTALL_DIR="$HOME" bash "$DCK_REPO/install.sh" --no-rc
  assert_rc 5 "install refuses HOME as the destination"
}

test_setup_writes_git_identity() {
  mk_repo || return 0
  local fake="placeholder-$$-mail@example.invalid"
  git config --global user.name "Dev Example"
  git config --global user.email "$fake"
  d setup
  assert_rc 0 "setup succeeds"
  assert_contains "$(cat "$REPO/docker/local/app/.env")" "DCK_GIT_NAME=Dev Example" "setup copies user.name into .env"
  assert_contains "$(cat "$REPO/docker/local/app/.env")" "DCK_GIT_EMAIL=$fake" "setup copies user.email into .env"
  assert_not_contains "$RUN_OUT$RUN_ERR" "$fake" "the value is never printed"
  printf 'DCK_GIT_EMAIL=kept@example.invalid\n' > "$REPO/docker/local/app/.env.tmp" && grep -v '^DCK_GIT_EMAIL=' "$REPO/docker/local/app/.env" >> "$REPO/docker/local/app/.env.tmp" && mv "$REPO/docker/local/app/.env.tmp" "$REPO/docker/local/app/.env" && chmod 600 "$REPO/docker/local/app/.env"
  d setup
  assert_eq "$(grep -c '^DCK_GIT_EMAIL=' "$REPO/docker/local/app/.env")" "1" "an existing key is never duplicated"
  assert_contains "$(cat "$REPO/docker/local/app/.env")" "DCK_GIT_EMAIL=kept@example.invalid" "an existing key is never overwritten"
  git config --global --unset user.name; git config --global --unset user.email
}

test_up_pushes_host_ssh_aliases() {
  mk_repo || return 0
  command -v ssh-agent >/dev/null 2>&1 || { pass "no ssh-agent here: host alias push untested"; return 0; }
  mkdir -p "$HOME/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C work -f "$HOME/.ssh/work"
  ssh-keygen -q -t ed25519 -N '' -C other -f "$HOME/.ssh/other"
  printf 'Host github.com-work\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/work\nHost github.com-other\n  HostName github.com\n  IdentityFile ~/.ssh/other\nHost prod\n  HostName prod.example.org\n  IdentityFile ~/.ssh/work\n' > "$HOME/.ssh/config"
  # A short socket path: macOS limits Unix socket paths to 104 bytes.
  local sock="/tmp/dck-lt-$$.sock"; rm -f "$sock"
  eval "$(ssh-agent -a "$sock" -s)" >/dev/null
  ssh-add -q "$HOME/.ssh/work" 2>/dev/null
  echo "proj-app-1" > "$DCK_FAKE_STATE/ps"
  : > "$DCK_FAKE_STATE/exec_stdin"
  DCK_NONINTERACTIVE=1 d up
  assert_rc 0 "up succeeds"
  local s; s="$(cat "$DCK_FAKE_STATE/exec_stdin")"
  assert_contains "$s" "host github.com-work github.com 22 git work" "up pushes a git alias whose key the agent holds"
  assert_not_contains "$s" "github.com-other" "an alias whose key the agent lacks is not pushed (git keeps working with the agent's keys)"
  assert_not_contains "$s" "prod" "a host that is not a git service is not pushed without ssh_host_extra"
  assert_not_contains "$s" "file " "the private key path stays on the host"
  assert_no_match "$s" 'PRIVATE KEY' "no private key content is pushed"
  assert_contains "$RUN_OUT$RUN_ERR" "lacks other" "the missing key is named, with the ssh-add command"
  assert_eq "$(ssh-add -l | grep -c other || true)" "0" "nothing is loaded into the agent without a terminal"
  # A key the agent holds with only its public half on disk (1Password, Secretive, hardware keys).
  ssh-keygen -q -t ed25519 -N '' -C vault -f "$SANDBOX/vault"
  ssh-add -q "$SANDBOX/vault" 2>/dev/null
  cp "$SANDBOX/vault.pub" "$HOME/.ssh/vault.pub"
  printf 'Host github.com-vault\n  HostName github.com\n  IdentityFile ~/.ssh/vault.pub\n' >> "$HOME/.ssh/config"
  : > "$DCK_FAKE_STATE/exec_stdin"
  DCK_NONINTERACTIVE=1 d up
  assert_contains "$(cat "$DCK_FAKE_STATE/exec_stdin")" "host github.com-vault github.com 22 - vault" "a key held by the agent with only its .pub on disk works"
  # A repository cannot widen the host list: ssh_host_extra is a host-profile key.
  printf 'ssh_host_extra = ["prod"]\n' >> "$REPO/.devcontainer/dck.toml"
  : > "$DCK_FAKE_STATE/exec_stdin"
  DCK_NONINTERACTIVE=1 d up
  assert_not_contains "$(cat "$DCK_FAKE_STATE/exec_stdin")" "prod" "ssh_host_extra in the repository's dck.toml is ignored"
  sed -i.orig '/^ssh_host_extra/d' "$REPO/.devcontainer/dck.toml" && rm -f "$REPO/.devcontainer/dck.toml.orig"
  # On a terminal, dck offers ssh-add for a missing key (and loads it on "y"). The answer
  # is typed after the prompt appears, as a person would.
  if command -v script >/dev/null 2>&1; then
    local cmd="cd '$REPO' && DCK_NONINTERACTIVE=0 '$DCK' up"
    if script -qec true /dev/null >/dev/null 2>&1; then
      { sleep 3; printf 'y\n'; sleep 2; } | script -qec "$cmd" /dev/null >"$SANDBOX/tty.out" 2>&1 || true
    else
      { sleep 3; printf 'y\n'; sleep 2; } | script -q /dev/null bash -c "$cmd" >"$SANDBOX/tty.out" 2>&1 || true
    fi
    assert_contains "$(cat "$SANDBOX/tty.out")" "Load it now" "on a terminal, dck asks before ssh-add"
    assert_eq "$(ssh-add -l | grep -c other || true)" "1" "and loads the key on yes"
    assert_contains "$(cat "$DCK_FAKE_STATE/exec_stdin")" "github.com-other" "then pushes its alias"
  else
    pass "no script(1) here: the terminal prompt is untested"
  fi
  sed -i.orig 's/^ssh_host_config = true/ssh_host_config = false/' "$REPO/.devcontainer/dck.toml" && rm -f "$REPO/.devcontainer/dck.toml.orig"
  : > "$DCK_FAKE_STATE/exec_stdin"
  d up
  assert_eq "$(cat "$DCK_FAKE_STATE/exec_stdin")" "" "ssh_host_config = false pushes nothing"
  ssh-agent -k >/dev/null 2>&1; unset SSH_AUTH_SOCK SSH_AGENT_PID; rm -f "$sock"
  rm -f "$HOME/.ssh/config" "$DCK_FAKE_STATE/ps"
}

test_setup_copies_only_working_signing() {
  mk_repo || return 0
  local env="$REPO/docker/local/app/.env"
  # openpgp signing: no gpg key exists inside, so nothing is copied.
  git config --global user.signingkey ABCDEF0123456789
  git config --global commit.gpgsign true
  d setup
  assert_rc 0 "setup succeeds with openpgp signing on the host"
  assert_no_match "$(cat "$env")" '^DCK_GIT_SIGNINGKEY=' "an openpgp key id is not copied"
  assert_no_match "$(cat "$env")" '^DCK_GIT_COMMIT_GPGSIGN=' "gpgsign is not turned on inside"
  assert_contains "$RUN_OUT$RUN_ERR" "commit signing is not copied" "setup says why"
  # ssh signing with a public-key file: sent as a key:: literal (no host path inside).
  rm -f "$env"
  mkdir -p "$HOME/.ssh"
  printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISigningKeyFakeOnlyForTests000000000000 me@host\n' > "$HOME/.ssh/signing.pub"
  git config --global gpg.format ssh
  git config --global user.signingkey "~/.ssh/signing.pub"
  d setup
  assert_contains "$(cat "$env")" "DCK_GIT_SIGNINGKEY=key::ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISigningKeyFakeOnlyForTests000000000000 me@host" "an ssh .pub path becomes a key:: literal"
  assert_contains "$(cat "$env")" "DCK_GIT_GPG_FORMAT=ssh" "gpg.format ssh is copied"
  assert_contains "$(cat "$env")" "DCK_GIT_COMMIT_GPGSIGN=true" "gpgsign is copied when it can work"
  assert_not_contains "$(cat "$env")" "$HOME" "no host path reaches the container"
  git config --global --unset user.signingkey; git config --global --unset commit.gpgsign; git config --global --unset gpg.format
}
