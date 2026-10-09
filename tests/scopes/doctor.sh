# shellcheck shell=bash
# Scope: doctor — `dck doctor [--json]` (schema-checked) and the dck skill.

DCK="$DCK_REPO/bin/dck"
SCHEMA="$DCK_REPO/docs/schema/dck-doctor-v1.json"
VERSION="$(cat "$DCK_REPO/VERSION")"
use_fakes
export DCK_BACKEND=compose DCK_NONINTERACTIVE=1 DCK_NO_DIGEST=1

REPO="$SANDBOX/proj"
mk_repo() {
  mkdir -p "$REPO"; git -C "$REPO" init -q
  "$DCK" init --repo "$REPO" --flavour node-24 --ssh-port 22040 --port web=4321 --herdr "$@" --yes >/dev/null 2>&1 || fail "fixture: init"
}
doc() { run_cmd bash -c 'cd "$1" && shift && "$@"' _ "${1:-$REPO}" "$DCK" doctor --json; }
outside() { mkdir -p "$SANDBOX/nowhere"; doc "$SANDBOX/nowhere"; }
# jq-less field access: j <python expression over d>
j() { printf '%s' "$RUN_OUT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps($1))"; }
valid() {
  local r
  r="$(printf '%s' "$RUN_OUT" | python3 "$TESTS_DIR/py/minischema.py" "$SCHEMA" 2>&1)"
  if [ $? -eq 0 ]; then pass "$1"; else fail "$1" "$r"; fi
}

test_outside_a_repository() {
  outside
  assert_rc 0 "doctor works outside a repository"
  valid "the report matches dck-doctor-v1"
  assert_eq "$(j 'd["interface"]')" "1" "interface is 1"
  assert_eq "$(j 'd["version"]')" "\"$VERSION\"" "version is the installed dck's"
  assert_eq "$(j '[d["repo"], d["layers"], d["ssh"]]')" "[null, null, null]" "repo, layers and ssh are null outside a repository"
  assert_eq "$(j 'd["runtime"]["docker"]["daemon"]')" "true" "the (fake) daemon is reported"
  assert_eq "$(j 'd["runtime"]["compose"]["version"]')" '"2.99.0-fake"' "the compose version is reported"
  assert_eq "$(j 'd["herdr"]["installed"]')" "true" "the (fake) herdr is detected"
}

test_inside_a_repository() {
  mk_repo
  doc
  valid "the in-repo report matches dck-doctor-v1"
  assert_eq "$(j 'd["repo"]["config_valid"]')" "true" "the config is valid"
  assert_eq "$(j 'd["repo"]["flavour"]')" '"node-24"' "the flavour is reported"
  assert_eq "$(j 'd["repo"]["image_tag"]')" "\"v$VERSION\"" "the image tag is reported"
  assert_eq "$(j 'd["repo"]["project"]')" '"proj"' "the compose project is reported"
  assert_eq "$(j 'd["layers"]')" '{"agents": false, "clis": [], "dailybot": false, "editor": true}' "the layers are reported"
  assert_eq "$(j '[d["ssh"]["enabled"], d["ssh"]["port"], d["ssh"]["bind"]]')" '[true, 22040, "127.0.0.1"]' "ssh port and bind are reported"
  assert_eq "$(j 'd["repo"]["digest_pinned"]')" "false" "a tag-only pin is reported"
  assert_contains "$(j 'd["problems"]')" "pinned by tag only" "and listed as a problem"
  assert_contains "$(j 'd["problems"]')" "docker/local/app/.env is missing" "a missing .env is a problem"
  assert_eq "$(j 'd["ok"]')" "false" "ok is false while problems remain"
}

test_env_files_names_only() {
  mk_repo
  run_cmd bash -c 'cd "$1" && "$2" setup' _ "$REPO" "$DCK"
  local fake="placeholder-$$-value"
  printf 'SERVICE_API_KEY=%s\nEMPTY_TOKEN=\n' "$fake" >> "$REPO/docker/local/app/.env"
  doc
  assert_eq "$(j '[e["keys_set"] for e in d["repo"]["env_files"]]')" '[["SERVICE_API_KEY"]]' "only names of variables with a value are reported"
  assert_eq "$(j 'd["repo"]["env_files"][0]["mode"]')" '"0600"' "the file mode is reported"
  assert_not_contains "$RUN_OUT" "$fake" "no value appears in the JSON"
  run_cmd bash -c 'cd "$1" && "$2" doctor' _ "$REPO" "$DCK"
  assert_not_contains "$RUN_OUT" "$fake" "no value appears in the text report"
  chmod 644 "$REPO/docker/local/app/.env"
  doc
  assert_contains "$(j 'd["problems"]')" "readable by other accounts" "a readable .env is a problem"
}

test_docker_missing_or_down() {
  local bin="$SANDBOX/nodocker" f t
  mkdir -p "$bin"
  for f in "$TESTS_DIR"/fakes/bin/*; do [ "$(basename "$f")" = docker ] || ln -s "$f" "$bin/"; done
  for t in bash sh env python3 sed grep cat dirname basename readlink pwd tr id uname cut head tail sort awk mkdir; do
    command -v "$t" >/dev/null 2>&1 && [ ! -e "$bin/$t" ] && ln -s "$(command -v "$t")" "$bin/$t"
  done
  mkdir -p "$SANDBOX/nowhere"
  run_cmd env PATH="$bin" bash -c 'cd "$1" && "$2" doctor --json' _ "$SANDBOX/nowhere" "$DCK"
  assert_rc 0 "doctor answers without docker"
  valid "the no-docker report matches the schema"
  assert_eq "$(j '[d["runtime"]["docker"]["cli"], d["runtime"]["docker"]["reason"]]')" '[false, "docker CLI not found"]' "a missing docker CLI is reported"
  touch "$DCK_FAKE_STATE/daemon_down"
  outside
  assert_eq "$(j '[d["runtime"]["docker"]["daemon"], d["runtime"]["docker"]["reason"]]')" '[false, "daemon not answering"]' "a daemon that does not answer is reported"
  assert_contains "$(j 'd["problems"]')" "the docker daemon is not answering" "and listed as a problem"
}

test_provider_detection() {
  echo "29.0.0|OrbStack|orbstack" > "$DCK_FAKE_STATE/info_out"
  outside
  assert_eq "$(j 'd["runtime"]["provider"]')" '"orbstack"' "OrbStack is recognised"
  echo "29.0.0|Ubuntu 24.04 (colima)|colima" > "$DCK_FAKE_STATE/info_out"
  outside
  assert_eq "$(j 'd["runtime"]["provider"]')" '"colima"' "colima is recognised"
  echo "29.0.0|Docker Desktop|docker-desktop" > "$DCK_FAKE_STATE/info_out"
  outside
  assert_eq "$(j 'd["runtime"]["provider"]')" '"docker-desktop"' "Docker Desktop is recognised"
}

test_digest_match() {
  printf 'sha256:%064d\n' 5 > "$DCK_FAKE_STATE/digest"
  mkdir -p "$REPO"; git -C "$REPO" init -q
  run_cmd env DCK_NO_DIGEST=0 "$DCK" init --repo "$REPO" --flavour debian --ssh-port 22040 --no-herdr --yes
  doc
  assert_eq "$(j 'd["repo"]["digest_pinned"]')" "true" "a digest pin is reported"
  assert_eq "$(j 'd["repo"]["digest_match"]')" "null" "an image not pulled yet cannot be compared"
  printf '["ghcr.io/dailybothq/devcontainer-kit-base@sha256:%064d"]\n' 5 > "$DCK_FAKE_STATE/image_inspect_out"
  doc
  assert_eq "$(j 'd["repo"]["digest_match"]')" "true" "a matching local image is reported"
  printf '["ghcr.io/dailybothq/devcontainer-kit-base@sha256:%064d"]\n' 6 > "$DCK_FAKE_STATE/image_inspect_out"
  doc
  assert_eq "$(j 'd["repo"]["digest_match"]')" "false" "a different local image is reported"
  assert_contains "$(j 'd["problems"]')" "does not match the digest pinned in compose" "and listed as a problem"
}

test_container_ssh_and_drift() {
  mk_repo
  printf 'proj-app-1\trunning\n' > "$DCK_FAKE_STATE/ps"
  printf 'GH_VERSION=0.0.1\nHERDR_VERSION=%s\nNVIM_VERSION=%s\nDWP_VIM_TAG=%s\n' \
    "$(sed -n 's/^HERDR_VERSION=//p' "$DCK_REPO/images/versions.env")" \
    "$(sed -n 's/^NVIM_VERSION=//p' "$DCK_REPO/images/versions.env")" \
    "$(sed -n 's/^DWP_VIM_TAG=//p' "$DCK_REPO/images/versions.env")" > "$DCK_FAKE_STATE/container_image_env"
  doc
  assert_eq "$(j 'd["repo"]["container"]')" '{"name": "proj-app-1", "state": "running"}' "the container state is reported"
  assert_eq "$(j 'd["ssh"]["answering"]')" "false" "sshd is probed on loopback (nothing listens in the test)"
  assert_contains "$(j 'd["problems"]')" "sshd does not answer on 127.0.0.1:22040" "a silent sshd is a problem"
  assert_eq "$(j '[x["status"] for x in d["drift"] if x["name"] == "gh"]')" '["drift"]' "a tool version different from the pin is drift"
  assert_eq "$(j '[x["status"] for x in d["drift"] if x["name"] == "nvim"]')" '["ok"]' "a matching tool version is ok"
  assert_contains "$(j 'd["problems"]')" "drift: gh pinned" "tool drift is a problem"
  sed -i.orig "s/^image_tag = .*/image_tag = \"v0.0.9\"/" "$REPO/.devcontainer/dck.toml" && rm -f "$REPO/.devcontainer/dck.toml.orig"
  doc
  assert_eq "$(j '[x["status"] for x in d["drift"] if x["name"] == "image_tag"]')" '["drift"]' "a repository pinned to another dck tag shows drift"
}

test_herdr_section() {
  mk_repo
  doc
  assert_eq "$(j '[d["herdr"]["machine"], d["herdr"]["alias"], d["herdr"]["registered"]]')" '[true, "dck-proj", false]' "an unregistered machine is reported"
  assert_contains "$(j 'd["problems"]')" "dck-proj is not registered" "and listed as a problem"
  printf '[{"id":"abc","label":"proj","target":"dck-proj","enabled":true}]' > "$DCK_FAKE_STATE/herdr_machines"
  doc
  assert_eq "$(j '[d["herdr"]["registered"], d["herdr"]["enabled"]]')" '[true, true]' "a registered machine is reported"
}

test_strict_text_and_flags() {
  outside
  run_cmd bash -c 'cd "$1" && "$2" doctor' _ "$SANDBOX/nowhere" "$DCK"
  assert_contains "$RUN_OUT" "devcontainer-kit $VERSION (interface 1)" "the text report starts with version and interface"
  mk_repo
  run_cmd bash -c 'cd "$1" && "$2" doctor --strict' _ "$REPO" "$DCK"
  assert_rc 1 "--strict exits 1 while problems remain"
  run_cmd bash -c 'cd "$1" && "$2" doctor --bogus' _ "$REPO" "$DCK"
  assert_rc 2 "an unknown doctor flag is a usage error"
  mkdir -p "$XDG_CONFIG_HOME/dck"; printf 'alias_prefix = "Bad"\n' > "$XDG_CONFIG_HOME/dck/profile.toml"
  outside
  assert_rc 0 "an invalid profile does not stop the doctor"
  assert_eq "$(j 'd["profile"]["valid"]')" "false" "the invalid profile is reported"
  valid "the report still matches the schema"
}

test_non_loopback_bind_is_flagged() {
  mk_repo
  sed -i.orig 's/^ssh_port = 22040$/ssh_port = 22040\nbind = "0.0.0.0"/' "$REPO/.devcontainer/dck.toml" && rm -f "$REPO/.devcontainer/dck.toml.orig"
  doc
  assert_contains "$(j 'd["problems"]')" "bind is 0.0.0.0" "a non-loopback bind is a problem"
}

SKILL="$DCK_REPO/skills/dck/SKILL.md"

test_skill_frontmatter() {
  run_cmd python3 - "$SKILL" "$VERSION" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
assert m, "no frontmatter"
fm = m.group(1)
def field(k):
    mm = re.search(r"^%s:\s*(.+)$" % k, fm, re.M)
    return mm.group(1).strip() if mm else None
errors = []
if field("name") != "dck": errors.append("name must be dck")
desc = field("description") or ""
if not (50 <= len(desc) <= 1024): errors.append("description length %d" % len(desc))
if "Use only when" not in desc or "Do not use" not in desc: errors.append("description lacks strict triggers")
if not re.search(r"^  interface: 1$", fm, re.M): errors.append("metadata.interface must be 1")
if not re.search(r"^  version: %s$" % re.escape(sys.argv[2]), fm, re.M): errors.append("metadata.version must equal VERSION")
if field("license") != "MIT": errors.append("license must be MIT")
print("\n".join(errors)); sys.exit(1 if errors else 0)
PY
  assert_rc 0 "the skill frontmatter is valid (name, strict description, interface 1, version, license)"
}

test_skill_rules() {
  local s; s="$(cat "$SKILL")"
  assert_match "$s" '^## Trust boundary \(write scope\)$' "the skill has a Trust boundary (write scope) section"
  assert_no_match "$s" '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba|z)?sh' "no fetch-piped-to-shell line (E005)"
  assert_no_match "$s" '--dangerously|--yolo|--always-approve|AGENTKIT_PERMISSIONS=auto' "no permission-bypass flag (E006)"
  assert_contains "$s" "git clone --branch v$VERSION https://github.com/DailybotHQ/devcontainer-kit" "the install line is pinned to this version (W012)"
  assert_no_match "$s" '@main|--branch main|:latest' "no floating reference"
  local v
  for v in init setup up shell exec rebuild down doctor ssh "herdr add" "herdr repair"; do
    assert_contains "$s" "dck $v" "the skill teaches 'dck $v'"
  done
}

test_skill_printed_by_dck() {
  run_cmd "$DCK" --skill
  assert_rc 0 "dck --skill succeeds"
  assert_eq "$RUN_OUT" "$(cat "$SKILL")" "dck --skill prints the bundled SKILL.md"
  run_cmd bash "$DCK_REPO/install.sh" --no-rc
  run_cmd "$HOME/.local/share/dck/bin/dck" --skill
  assert_eq "$RUN_OUT" "$(cat "$SKILL")" "an installed dck prints the same skill"
  run_cmd "$HOME/.local/share/dck/bin/dck" doctor --json
  valid "an installed dck's doctor matches the schema"
}

test_empty_docker_info_is_not_a_daemon() {
  echo "||" > "$DCK_FAKE_STATE/info_out"
  outside
  assert_eq "$(j 'd["runtime"]["docker"]["daemon"]')" "false" "docker info with empty fields does not count as a daemon"
}
