# shellcheck shell=bash
# Scope: config — lib/config.py (dck.toml + host profile) and its JSON Schemas.

PYCFG=(python3 -I "$DCK_REPO/lib/dckpy.py" config)
CFIX="$TESTS_DIR/fixtures/config"

# invalid_case <description> <expected stderr fragment> <toml body>
invalid_case() {
  printf '%s\n' "$3" > "$SANDBOX/case.toml"
  run_cmd "${PYCFG[@]}" validate "$SANDBOX/case.toml"
  if [ "$RUN_RC" = 3 ]; then
    assert_contains "$RUN_ERR" "$2" "rejects: $1"
  else
    fail "rejects: $1" "expected exit 3, got $RUN_RC: $RUN_ERR"
  fi
}

# A repo directory with .devcontainer/dck.toml holding the given body.
make_repo() {
  local dir="$SANDBOX/${2:-myrepo}"
  mkdir -p "$dir/.devcontainer"
  printf '%s\n' "$1" > "$dir/.devcontainer/dck.toml"
  printf '%s\n' "$dir"
}

test_valid_configs() {
  run_cmd "${PYCFG[@]}" validate "$CFIX/valid-full.toml"
  assert_rc 0 "the contract's full example validates"
  run_cmd "${PYCFG[@]}" validate "$CFIX/valid-minimal.toml"
  assert_rc 0 "a minimal config (interface, service, flavour) validates"
  assert_eq "$RUN_ERR" "" "a clean config prints no warning"
  run_cmd "${PYCFG[@]}" validate --kind profile "$CFIX/profile-full.toml"
  assert_rc 0 "a full host profile validates"
}

test_invalid_configs() {
  local base='interface = 1
service = "app"
flavour = "node-24"'
  invalid_case "a missing service" "service: required key is missing" 'interface = 1
flavour = "debian"'
  invalid_case "a missing flavour" "flavour: required key is missing" 'interface = 1
service = "app"'
  invalid_case "a missing interface" "interface: required key is missing" 'service = "app"
flavour = "debian"'
  invalid_case "an unknown interface major" "interface 2 is not supported by this dck (supports 1)" 'interface = 2
service = "app"
flavour = "debian"'
  invalid_case "an unknown flavour" "flavour: invalid value 'alpine'" 'interface = 1
service = "app"
flavour = "alpine"'
  invalid_case "a service name with a space" "service: invalid value" 'interface = 1
service = "my app"
flavour = "debian"'
  invalid_case "a relative workspace" "workspace: invalid value" "$base
workspace = \"workspace\""
  invalid_case "a root user name with shell metacharacters" "user: invalid value" "$base
user = \"dev;rm\""
  invalid_case "a non-semver image tag" "image_tag: invalid value" "$base
image_tag = \"latest\""
  invalid_case "a privileged ssh port" "ssh_port: expected 0 (no sshd) or a port in 1024-65535" "$base
ssh_port = 22"
  invalid_case "an ssh port given as a string" "ssh_port: expected an integer, got string" "$base
ssh_port = \"22040\""
  invalid_case "a port out of range" "ports: web: expected a port number in 1-65535" "$base
ports = { web = 70000 }"
  invalid_case "a duplicated port" "port 4321 is already used by web" "$base
ports = { web = 4321, docs = 4321 }"
  invalid_case "a port equal to ssh_port" "ports.web: port 22040 is already the ssh_port" "$base
ssh_port = 22040
ports = { web = 22040 }"
  invalid_case "a non-loopback bind that is not an address" "bind: invalid value" "$base
bind = \"localhost\""
  invalid_case "a layer flag that is a string" "layers.agents: expected a boolean" "$base
[layers]
agents = \"yes\""
  invalid_case "an unknown agent kind" "agents.clis: unknown kind 'gemini'" "$base
[agents]
clis = [\"gemini\"]"
  invalid_case "a duplicated agent kind" "agents.clis: duplicate entries" "$base
[agents]
clis = [\"claude\", \"claude\"]"
  invalid_case "a Herdr machine without sshd" "herdr.machine: a Herdr machine needs sshd" "$base
[herdr]
machine = true"
  invalid_case "an unknown label placeholder" "herdr.label: unknown placeholder {host}" "$base
ssh_port = 22040
[herdr]
label = \"{host}\""
  invalid_case "layers given as a value instead of a table" "layers: expected a table" "$base
layers = true"
  invalid_case "invalid TOML" "invalid TOML" 'interface = 1
service = "app'
}

test_every_problem_reported_at_once() {
  printf '%s\n' 'interface = 1
flavour = "alpine"
ssh_port = 80' > "$SANDBOX/multi.toml"
  run_cmd "${PYCFG[@]}" validate "$SANDBOX/multi.toml"
  assert_rc 3 "an invalid config exits 3"
  assert_contains "$RUN_ERR" "service: required key is missing" "first problem reported"
  assert_contains "$RUN_ERR" "flavour: invalid value" "second problem reported"
  assert_contains "$RUN_ERR" "ssh_port: expected 0" "third problem reported"
  assert_contains "$RUN_ERR" "$SANDBOX/multi.toml" "problems name the file"
}

test_unknown_keys_warn_but_pass() {
  printf '%s\n' 'interface = 1
service = "app"
flavour = "debian"
future_key = 1
[layers]
gpu = true' > "$SANDBOX/fwd.toml"
  run_cmd "${PYCFG[@]}" validate "$SANDBOX/fwd.toml"
  assert_rc 0 "unknown keys do not fail validation (forward compatibility)"
  assert_contains "$RUN_ERR" "unknown key future_key ignored" "an unknown top-level key is warned about"
  assert_contains "$RUN_ERR" "unknown key layers.gpu ignored" "an unknown table key is warned about"
}

test_defaults_and_merge() {
  local repo
  repo="$(make_repo 'interface = 1
service = "app"
flavour = "python-3.13"' "My Repo")"
  run_cmd "${PYCFG[@]}" show --repo "$repo" --format json
  assert_rc 0 "show works without any host profile"
  local j="$RUN_OUT"
  get() { printf '%s' "$j" | python3 -c "import json,sys; v=json.load(sys.stdin)[sys.argv[1]]; print(json.dumps(v))" "$1"; }
  assert_eq "$(get user)" '"dev"' "user defaults to dev"
  assert_eq "$(get workspace)" '"/workspace"' "workspace defaults to /workspace"
  assert_eq "$(get ssh_port)" '0' "ssh_port defaults to 0 (no sshd)"
  assert_eq "$(get bind)" '"127.0.0.1"' "bind defaults to loopback"
  assert_eq "$(get layers.agents)" 'false' "the agents layer is off by default"
  assert_eq "$(get layers.editor)" 'true' "the editor layer is on by default"
  assert_eq "$(get image_tag)" "\"v$(cat "$DCK_REPO/VERSION")\"" "image_tag defaults to this dck's tag"
  assert_eq "$(get repo_slug)" '"my-repo"' "the repo slug is lower-case and safe"
  assert_eq "$(get alias)" '"dck-my-repo"' "the ssh alias uses the default prefix"
  assert_eq "$(get herdr.label)" '"My Repo"' "the default label is the repo name"
  assert_eq "$(get profile_source)" '"defaults"' "an absent default profile means defaults"
  assert_eq "$(get ssh_identity)" "\"$HOME/.config/dck/ssh/id_ed25519\"" "the default identity is a dedicated dck key"
}

test_env_output_is_line_safe() {
  local repo
  repo="$(make_repo "$(cat "$CFIX/valid-full.toml")")"
  run_cmd "${PYCFG[@]}" show --repo "$repo"
  assert_rc 0 "env output works"
  assert_match "$RUN_OUT" '^DCK_SERVICE=app$' "service exported as DCK_SERVICE"
  assert_match "$RUN_OUT" '^DCK_LAYERS_AGENTS=1$' "booleans are 1/0"
  assert_match "$RUN_OUT" '^DCK_AGENTS_CLIS=claude codex$' "lists are space separated"
  assert_match "$RUN_OUT" '^DCK_PORTS=api=8000 web=4321$' "port maps are name=port pairs"
  assert_no_match "$RUN_OUT" '^[^A-Z]' "every line is KEY=VALUE"
}

test_profile_selection_and_precedence() {
  local repo
  mkdir -p "$XDG_CONFIG_HOME/dck/profiles"
  cp "$CFIX/profile-full.toml" "$XDG_CONFIG_HOME/dck/profiles/acme.toml"
  printf 'alias_prefix = "home-"\n' > "$XDG_CONFIG_HOME/dck/profile.toml"
  repo="$(make_repo 'interface = 1
service = "app"
flavour = "node-24"
ssh_port = 22050' web)"
  run_cmd "${PYCFG[@]}" show --repo "$repo" --format json
  assert_contains "$RUN_OUT" '"alias": "home-web"' "profile.toml is the default profile"
  run_cmd "${PYCFG[@]}" show --repo "$repo" --profile acme --format json
  assert_rc 0 "--profile selects profiles/<name>.toml"
  assert_contains "$RUN_OUT" '"alias": "acme-web"' "the named profile's alias prefix applies"
  assert_contains "$RUN_OUT" '"herdr.label": "acme-web · web"' "the profile label format expands {project} and {repo}"
  assert_contains "$RUN_OUT" '"network": "acme-dev"' "the profile network is carried"
  assert_contains "$RUN_OUT" "\"ssh_identity\": \"$HOME/.config/dck/ssh/acme_ed25519\"" "~ in the identity expands to HOME"
  printf '%s\n' 'interface = 1
service = "app"
flavour = "node-24"
ssh_port = 22050
[herdr]
label = "{repo} ({service})"' > "$repo/.devcontainer/dck.toml"
  run_cmd "${PYCFG[@]}" show --repo "$repo" --profile acme --format json
  assert_contains "$RUN_OUT" '"herdr.label": "web (app)"' "an explicit repo label wins over the profile format"
  run_cmd "${PYCFG[@]}" show --repo "$repo" --profile nope
  assert_rc 3 "a missing named profile is a configuration error"
  assert_contains "$RUN_ERR" "profile 'nope' not found" "the error names the missing profile"
  run_cmd "${PYCFG[@]}" show --repo "$repo" --profile "../etc"
  assert_rc 3 "a profile name cannot escape the profiles directory"
}

test_config_home_resolution() {
  local repo alt="$SANDBOX/alt"
  repo="$(make_repo "$(cat "$CFIX/valid-minimal.toml")")"
  mkdir -p "$alt"
  printf 'alias_prefix = "alt-"\n' > "$alt/profile.toml"
  run_cmd env DCK_CONFIG_HOME="$alt" "${PYCFG[@]}" show --repo "$repo" --format json
  assert_contains "$RUN_OUT" '"alias": "alt-myrepo"' "DCK_CONFIG_HOME overrides the config directory"
  mkdir -p "$SANDBOX/xdg/dck"
  printf 'alias_prefix = "xdg-"\n' > "$SANDBOX/xdg/dck/profile.toml"
  run_cmd env XDG_CONFIG_HOME="$SANDBOX/xdg" "${PYCFG[@]}" show --repo "$repo" --format json
  assert_contains "$RUN_OUT" '"alias": "xdg-myrepo"' "XDG_CONFIG_HOME is honoured"
}

test_invalid_profile() {
  local repo
  repo="$(make_repo "$(cat "$CFIX/valid-minimal.toml")")"
  mkdir -p "$XDG_CONFIG_HOME/dck"
  printf 'alias_prefix = "Bad Prefix"\nhost_machine = "no"\n' > "$XDG_CONFIG_HOME/dck/profile.toml"
  run_cmd "${PYCFG[@]}" show --repo "$repo"
  assert_rc 3 "an invalid profile is a configuration error"
  assert_contains "$RUN_ERR" "alias_prefix: invalid value" "a bad alias prefix is reported"
  assert_contains "$RUN_ERR" "host_machine: expected a boolean" "a wrong-typed profile value is reported"
}

test_missing_repo_config() {
  mkdir -p "$SANDBOX/empty"
  run_cmd "${PYCFG[@]}" show --repo "$SANDBOX/empty"
  assert_rc 3 "a repo without dck.toml is a configuration error"
  assert_contains "$RUN_ERR" "dck.toml: file not found" "the error names the missing file"
}

test_schema_matches_rules() {
  run_cmd python3 - "$DCK_REPO" <<'PY'
import json, os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "lib"))
import config as c
problems = []
for kind, rules, fname in (("repo", c.REPO_RULES, "dck-config-v1.json"),
                           ("profile", c.PROFILE_RULES, "dck-profile-v1.json")):
    schema = json.load(open(os.path.join(root, "docs", "schema", fname)))
    props = schema["properties"]
    flat = {}
    for k, v in props.items():
        if v.get("type") == "object" and "properties" in v and k != "ports":
            for sk, sv in v["properties"].items():
                flat["%s.%s" % (k, sk)] = sv
        else:
            flat[k] = v
    if set(flat) != set(rules):
        problems.append("%s: schema keys %s != rule keys %s" % (kind, sorted(set(flat) ^ set(rules)), ""))
    for key, (typ, default, cons) in rules.items():
        s = flat.get(key, {})
        if default is c.REQUIRED:
            if key not in schema.get("required", []):
                problems.append("%s.%s required in code, not in schema" % (kind, key))
        elif default is not None and s.get("default", default) != default:
            problems.append("%s.%s default %r != schema %r" % (kind, key, default, s.get("default")))
        if cons and cons[0] == "pattern":
            pat = s.get("pattern") or (s.get("propertyNames") or {}).get("pattern")
            if pat != cons[1]:
                problems.append("%s.%s pattern differs" % (kind, key))
        if cons and cons[0] == "enum":
            enum = s.get("enum") or (s.get("items") or {}).get("enum")
            if list(enum or []) != list(cons[1]):
                problems.append("%s.%s enum differs" % (kind, key))
print("\n".join(problems))
sys.exit(1 if problems else 0)
PY
  assert_rc 0 "docs/schema JSON Schemas match the validator's rules"
}

test_schema_files_are_valid_json() {
  local f
  for f in "$DCK_REPO"/docs/schema/dck-config-v1.json "$DCK_REPO"/docs/schema/dck-profile-v1.json; do
    run_cmd python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["$schema"].endswith("2020-12/schema")' "$f"
    assert_rc 0 "$(basename "$f") is a draft 2020-12 JSON Schema"
  done
}
