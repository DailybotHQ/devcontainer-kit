"""`dck init`: render the Dev Container template into a repository.

Reconcile, never clobber:

* a missing file is created;
* a file dck generated carries named managed blocks
  (`# >>> dck:<name> >>>` ... `# <<< dck:<name> <<<`); only the inside of
  those blocks is reconciled, everything outside them is the user's;
* `.devcontainer/devcontainer.json` is reconciled by the keys dck owns
  (DEVCONTAINER_KEYS); every other key, and the file's comments when nothing
  changes, are kept;
* `.devcontainer/dck.toml` is the source of truth: created once, afterwards
  edited only for the values given as flags, line by line, comments kept;
* any change to an existing file is shown as a diff and needs consent
  (`--yes`, or a "y" at the interactive prompt), and the previous content is
  kept as `<file>.dck-bak-<UTC timestamp>`. Without consent nothing is
  written and the exit status is 5.

The only change made without consent is appending dck's `.gitignore` block
when it is absent, so a `.env` holding secrets can never be committed by
accident; no existing line is modified by that append.
"""

import difflib
import json
import os
import re
import subprocess
import sys
import time
import zlib

import config
import jsonc

TEMPLATE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "template")
BASE_IMAGE_REPO = "ghcr.io/dailybothq/devcontainer-kit-base"

DEVCONTAINER_KEYS = ("dockerComposeFile", "service", "runServices", "remoteUser",
                     "workspaceFolder", "shutdownAction")
# Keys that select a different container source and cannot coexist with compose.
DEVCONTAINER_CONFLICTS = ("image", "build", "dockerFile", "dockerfile", "context")

BLOCK_RE = re.compile(r"^[ \t]*# (>>>|<<<) dck:([a-z0-9_-]+) (>>>|<<<)[ \t]*$")
GITIGNORE_BLOCK = [
    "# >>> dck:gitignore >>>",
    "# devcontainer-kit: runtime env files hold secrets; backups from `dck init`.",
    "docker/local/**/.env",
    "docker/local/**/.env.*",
    "!docker/local/**/.env.example",
    "*.dck-bak-*",
    "# <<< dck:gitignore <<<",
]

EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_CONFIG, EXIT_ENV, EXIT_REFUSED = 0, 1, 2, 3, 4, 5


class RenderError(Exception):
    pass


# --------------------------------------------------------------------------
# Template engine: {{name}} substitution and {% if name %}/{% else %}/{% endif %}
# directive lines. Unknown names are errors, never empty strings.
# --------------------------------------------------------------------------

DIRECTIVE = re.compile(r"^\s*\{%\s*(if|else|endif)\s*([A-Za-z_][A-Za-z0-9_]*)?\s*%\}\s*$")
VAR = re.compile(r"\{\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\}")


def render_text(text, ctx, name="template"):
    out, stack = [], []
    for lineno, line in enumerate(text.splitlines(True), 1):
        m = DIRECTIVE.match(line)
        if m:
            word, var = m.group(1), m.group(2)
            if word == "if":
                if var not in ctx:
                    raise RenderError("%s:%d: unknown condition %r" % (name, lineno, var))
                stack.append([bool(ctx[var]), False])
            elif word == "else":
                if not stack or stack[-1][1]:
                    raise RenderError("%s:%d: unexpected else" % (name, lineno))
                stack[-1] = [not stack[-1][0], True]
            else:
                if not stack:
                    raise RenderError("%s:%d: unexpected endif" % (name, lineno))
                stack.pop()
            continue
        if all(active for active, _ in stack):
            def sub(vm):
                key = vm.group(1)
                if key not in ctx:
                    raise RenderError("%s:%d: unknown variable %r" % (name, lineno, key))
                return str(ctx[key])
            out.append(VAR.sub(sub, line))
    if stack:
        raise RenderError("%s: unterminated if" % name)
    return "".join(out)


def read_template(rel):
    with open(os.path.join(TEMPLATE_DIR, rel)) as fh:
        return fh.read()


# --------------------------------------------------------------------------
# Managed blocks
# --------------------------------------------------------------------------

def parse_blocks(text):
    """{name: (open_line_index, close_line_index)} or None when the markers are
    unbalanced, duplicated or crossed (a file dck cannot safely reconcile)."""
    blocks, open_name, open_at = {}, None, None
    for i, line in enumerate(text.splitlines()):
        m = BLOCK_RE.match(line)
        if not m:
            continue
        kind, name = m.group(1), m.group(2)
        if kind == ">>>":
            if open_name is not None or name in blocks:
                return None
            open_name, open_at = name, i
        else:
            if open_name != name:
                return None
            blocks[name] = (open_at, i)
            open_name = None
    if open_name is not None:
        return None
    return blocks


def reconcile_blocks(existing, rendered):
    """Replace each managed block of `existing` with the one in `rendered`.

    Blocks only in `rendered` are appended (with one blank line before them);
    blocks only in `existing` are removed. Returns the new text, or None when
    `existing` has no usable markers."""
    old_blocks = parse_blocks(existing)
    new_blocks = parse_blocks(rendered)
    if not old_blocks or new_blocks is None:
        return None
    old_lines = existing.splitlines()
    new_lines = rendered.splitlines()
    out, i = [], 0
    ordered = sorted(old_blocks.items(), key=lambda kv: kv[1][0])
    for name, (start, end) in ordered:
        out.extend(old_lines[i:start])
        if name in new_blocks:
            ns, ne = new_blocks[name]
            out.extend(new_lines[ns:ne + 1])
        else:
            # drop a now-empty separator line left before the removed block
            while out and out[-1].strip() == "":
                out.pop()
        i = end + 1
    out.extend(old_lines[i:])
    for name, (ns, ne) in sorted(new_blocks.items(), key=lambda kv: kv[1][0]):
        if name not in old_blocks:
            if out and out[-1].strip() != "":
                out.append("")
            out.extend(new_lines[ns:ne + 1])
    text = "\n".join(out)
    return text + "\n" if existing.endswith("\n") or not existing else text


# --------------------------------------------------------------------------
# dck.toml line editing (keeps comments and layout)
# --------------------------------------------------------------------------

def toml_value(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, list):
        return "[%s]" % ", ".join(json.dumps(x) for x in v)
    if isinstance(v, dict):
        return "{ %s }" % ", ".join("%s = %s" % (k, toml_value(x)) for k, x in sorted(v.items()))
    return json.dumps(v)


def toml_set(text, dotted, value):
    """Set `dotted` (`key` or `table.key`) in TOML text, preserving the rest.
    Only simple one-line `key = value` assignments are edited; a trailing
    comment on the edited line is kept."""
    table, _, key = dotted.rpartition(".")
    lines = text.splitlines()
    headers = [i for i, ln in enumerate(lines) if re.match(r"^\s*\[", ln)]
    newline = "%s = %s" % (key, toml_value(value))
    if table == "":
        start, end = 0, (headers[0] if headers else len(lines))
    else:
        own = [i for i in headers if re.match(r"^\s*\[%s\]\s*(#.*)?$" % re.escape(table), lines[i])]
        if not own:
            while lines and lines[-1].strip() == "":
                lines.pop()
            lines.extend(["", "[%s]" % table, newline])
            return "\n".join(lines) + "\n"
        start = own[0] + 1
        end = next((i for i in headers if i > own[0]), len(lines))
    for i in range(start, end):
        m = re.match(r"^(\s*)%s(\s*=\s*)(.*)$" % re.escape(key), lines[i])
        if not m:
            continue
        rest, comment = m.group(3), ""
        cm = re.search(r"\s+#.*$", rest)
        if cm and '"' not in rest[cm.start():]:
            comment = rest[cm.start():]
        lines[i] = "%s%s%s%s%s" % (m.group(1), key, m.group(2), toml_value(value), comment)
        return "\n".join(lines) + "\n"
    j = end
    while j > start and lines[j - 1].strip() == "":
        j -= 1
    lines.insert(j, newline)
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------
# Context
# --------------------------------------------------------------------------

def detect_flavour(repo):
    if os.path.exists(os.path.join(repo, "package.json")):
        return "node-24"
    for f in ("pyproject.toml", "requirements.txt", "setup.py", "Pipfile"):
        if os.path.exists(os.path.join(repo, f)):
            return "python-3.13"
    return "debian"


def default_ssh_port(slug):
    """Deterministic per repository, in 22100-22999, so two repos rarely collide."""
    return 22100 + zlib.crc32(slug.encode()) % 900


def which(cmd):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, cmd)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def resolve_digest(ref, timeout=30):
    """sha256 digest of a registry image index, or None (no docker, offline,
    not pushed yet). Never fatal: the caller falls back to the tag pin."""
    if not which("docker"):
        return None
    try:
        r = subprocess.run(["docker", "buildx", "imagetools", "inspect", ref,
                            "--format", "{{json .Manifest}}"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=timeout, text=True)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    try:
        digest = json.loads(r.stdout).get("digest", "")
    except ValueError:
        return None
    return digest if re.match(r"^sha256:[0-9a-f]{64}$", digest or "") else None


def existing_base_image(repo):
    path = os.path.join(repo, "docker", "local", "docker-compose.yaml")
    try:
        text = open(path).read()
    except OSError:
        return None
    m = re.search(r'BASE_IMAGE:\s*"([^"]+)"', text)
    return m.group(1) if m else None


def layers_block(values):
    """Dockerfile lines for the opt-in layers (see docs/layers.md)."""
    lines = []
    user = values["user"]
    if values["layers.agents"]:
        lines += [
            "# Agents layer (layers.agents = true): coding-agents-kit (ak) at its pinned",
            "# tag, Node when the flavour lacks it, then `ak install` for agents.clis.",
            "ARG DCK_AGENT_CLIS=\"%s\"" % " ".join(values["agents.clis"]),
            "RUN DCK_USER=%s dck-layer agents ${DCK_AGENT_CLIS}" % user,
        ]
    if values["layers.dailybot"]:
        lines += [
            "# Dailybot layer (layers.dailybot = true): requested by the dailybot addon.",
            "RUN DCK_USER=%s dck-layer dailybot" % user,
        ]
    if not values["layers.editor"]:
        lines += [
            "# Editor layer off (layers.editor = false): nano is the default editor.",
            "ENV EDITOR=nano VISUAL=nano GIT_EDITOR=nano",
        ]
    if not lines:
        lines = ["# No opt-in layer is enabled in dck.toml (agents, dailybot) and the editor layer is on."]
    return "\n".join(lines)


AGENT_VOLUMES = ("claude", "codex", "cursor", "opencode", "pi", "cline", "grok")


def context(values, repo_name, project, network, base_image, dck_tag):
    user = values["user"]
    vols = ["state"]
    if values["layers.agents"]:
        vols.append("agentkit")
        vols += [k for k in AGENT_VOLUMES if k in values["agents.clis"]]
    bind = values["bind"]
    port_lines = []
    if values["ssh_port"]:
        port_lines.append('      - "%s:%d:22"   # sshd (Herdr, `dck ssh`)' % (bind, values["ssh_port"]))
    for name, port in sorted(values["ports"].items(), key=lambda kv: kv[1]):
        port_lines.append('      - "%s:%d:%d"   # %s' % (bind, port, port, name))
    raw_label = values.get("_label_fmt", values["herdr.label"])
    return {
        "dck_tag": dck_tag,
        "repo_name": repo_name,
        "project": project,
        "service": values["service"],
        "user": user,
        "workspace": values["workspace"],
        "flavour": values["flavour"],
        "image_tag": values["image_tag"],
        "base_image": base_image,
        "ssh_port": values["ssh_port"],
        "ssh_enabled": "1" if values["ssh_port"] else "0",
        "editor_enabled": "1" if values["layers.editor"] else "0",
        "ports_inline": ", ".join("%s = %d" % kv for kv in sorted(values["ports"].items())),
        "has_ports": bool(port_lines),
        "port_lines": "\n".join(port_lines),
        "volume_mounts": "\n".join("      - %s:/home/%s/.dck/volumes/%s" % (v, user, v) for v in vols),
        "volume_decls": "\n".join("  %s: {}" % v for v in vols),
        "has_network": bool(network),
        "network": network,
        "layers_agents": toml_value(values["layers.agents"]),
        "layers_agents_on": values["layers.agents"],
        "layers_dailybot_on": values["layers.dailybot"],
        "layers_dailybot": toml_value(values["layers.dailybot"]),
        "layers_editor": toml_value(values["layers.editor"]),
        "agents_clis_toml": ", ".join(json.dumps(c) for c in values["agents.clis"]),
        "agents_clis_space": " ".join(values["agents.clis"]),
        "herdr_machine": toml_value(values["herdr.machine"]),
        "herdr_label_fmt": raw_label,
        "rename_user": user != "dev",
        "layers_block": layers_block(values),
    }


def render_devcontainer_new(ctx):
    return render_text(read_template("devcontainer/devcontainer.json.tmpl"), ctx, "devcontainer.json.tmpl")


def devcontainer_desired(ctx, current):
    run = list(current.get("runServices") or []) if isinstance(current.get("runServices"), list) else []
    if ctx["service"] in run:
        run.remove(ctx["service"])
    run.insert(0, ctx["service"])
    return {
        "dockerComposeFile": "../docker/local/docker-compose.yaml",
        "service": ctx["service"],
        "runServices": run,
        "remoteUser": ctx["user"],
        "workspaceFolder": ctx["workspace"],
        "shutdownAction": "none",
    }


def reconcile_devcontainer(existing_text, ctx):
    """New text, or the same text when the owned keys already agree."""
    try:
        current = jsonc.loads(existing_text)
    except ValueError:
        return None
    if not isinstance(current, dict):
        return None
    want = devcontainer_desired(ctx, current)
    same = all(current.get(k) == v for k, v in want.items()) and \
        not any(k in current for k in DEVCONTAINER_CONFLICTS)
    if same:
        return existing_text
    merged = {}
    for k, v in current.items():
        if k in DEVCONTAINER_CONFLICTS:
            continue
        merged[k] = want.get(k, v)
    for k in DEVCONTAINER_KEYS:
        merged.setdefault(k, want[k])
    header = ("// Generated by devcontainer-kit (`dck init`) from .devcontainer/dck.toml.\n"
              "// dck reconciles: %s.\n// Every other key is yours.\n" % ", ".join(DEVCONTAINER_KEYS))
    return header + json.dumps(merged, indent=2) + "\n"


# --------------------------------------------------------------------------
# Planning and applying
# --------------------------------------------------------------------------

class Change(object):
    def __init__(self, rel, action, new=None, old=None, note=""):
        self.rel, self.action, self.new, self.old, self.note = rel, action, new, old, note


def _read(path):
    try:
        with open(path) as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def plan(repo, values, ctx, toml_overrides, toml_exists):
    svc = values["service"]
    changes = []

    # dck.toml — source of truth.
    rel = ".devcontainer/dck.toml"
    old = _read(os.path.join(repo, rel))
    if old is None:
        changes.append(Change(rel, "create", render_text(read_template("devcontainer/dck.toml.tmpl"), ctx, rel)))
    else:
        new = old
        for key, value in toml_overrides:
            new = toml_set(new, key, value)
        changes.append(Change(rel, "unchanged" if new == old else "update", new, old, "values from flags"))

    # devcontainer.json — owned keys.
    rel = ".devcontainer/devcontainer.json"
    old = _read(os.path.join(repo, rel))
    if old is None:
        changes.append(Change(rel, "create", render_devcontainer_new(ctx)))
    else:
        new = reconcile_devcontainer(old, ctx)
        if new is None:
            changes.append(Change(rel, "replace", render_devcontainer_new(ctx), old, "not parseable as JSONC"))
        else:
            changes.append(Change(rel, "unchanged" if new == old else "update", new, old, "dck-owned keys"))

    # Marker-managed files.
    for tmpl, rel in (("docker/docker-compose.yaml.tmpl", "docker/local/docker-compose.yaml"),
                      ("docker/service/Dockerfile.tmpl", "docker/local/%s/Dockerfile" % svc)):
        rendered = render_text(read_template(tmpl), ctx, tmpl)
        old = _read(os.path.join(repo, rel))
        if old is None:
            changes.append(Change(rel, "create", rendered))
            continue
        new = reconcile_blocks(old, rendered)
        if new is None:
            changes.append(Change(rel, "replace", rendered, old, "no dck markers: whole file"))
        else:
            changes.append(Change(rel, "unchanged" if new == old else "update", new, old, "managed blocks"))

    # Create-only files.
    rel = "docker/local/%s/.env.example" % svc
    if _read(os.path.join(repo, rel)) is None:
        changes.append(Change(rel, "create", render_text(read_template("docker/service/env.example.tmpl"), ctx, rel)))
    else:
        changes.append(Change(rel, "unchanged", note="create-only"))

    # .gitignore block.
    rel = ".gitignore"
    old = _read(os.path.join(repo, rel))
    block = "\n".join(GITIGNORE_BLOCK) + "\n"
    if old is None:
        changes.append(Change(rel, "create", block))
    else:
        blocks = parse_blocks(old)
        if blocks and "gitignore" in blocks:
            new = reconcile_blocks(old, block)
            changes.append(Change(rel, "unchanged" if new == old else "update", new, old, "managed block"))
        else:
            sep = "" if old.endswith("\n") or not old else "\n"
            changes.append(Change(rel, "append", old + sep + ("\n" if old.strip() else "") + block, old,
                                  "secrets guard appended"))
    return changes


def unified(change):
    old = (change.old or "").splitlines(True)
    new = (change.new or "").splitlines(True)
    return "".join(difflib.unified_diff(old, new, "a/" + change.rel, "b/" + change.rel))


def write_atomic(path, text, mode=None):
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    tmp = "%s.dck-tmp-%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644 if mode is None else mode)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def backup(path):
    stamp = time.strftime("%Y%m%d%H%M%S", time.gmtime())
    dest = "%s.dck-bak-%s" % (path, stamp)
    n = 1
    while os.path.exists(dest):
        n += 1
        dest = "%s.dck-bak-%s-%d" % (path, stamp, n)
    with open(path, "rb") as src, open(dest, "wb") as out:
        out.write(src.read())
    os.chmod(dest, os.stat(path).st_mode & 0o777)
    return dest


def ask(question):
    try:
        with open("/dev/tty", "r+") as tty:
            tty.write(question)
            tty.flush()
            return tty.readline().strip().lower() in ("y", "yes")
    except OSError:
        return False


def apply(repo, changes, yes, interactive, out=sys.stdout):
    needs = [c for c in changes if c.action in ("update", "replace")]
    if needs and not yes and not interactive:
        out.write("\nrefused: %d existing file(s) differ from the template; nothing was written.\n"
                  "Review the diffs above, then re-run with --yes to apply them "
                  "(each replaced file is backed up as <file>.dck-bak-<timestamp>).\n" % len(needs))
        return EXIT_REFUSED
    declined = 0
    for c in changes:
        path = os.path.join(repo, c.rel)
        if c.action in ("unchanged",):
            continue
        if c.action in ("update", "replace") and not yes:
            if not ask("apply the change to %s? [y/N] " % c.rel):
                out.write("kept     %s (declined)\n" % c.rel)
                declined += 1
                continue
        if c.action in ("update", "replace", "append"):
            mode = os.stat(path).st_mode & 0o777
            if c.action != "append":
                out.write("backup   %s -> %s\n" % (c.rel, os.path.relpath(backup(path), repo)))
            write_atomic(path, c.new, mode)
        else:
            write_atomic(path, c.new)
        out.write("wrote    %s\n" % c.rel)
    return EXIT_REFUSED if declined else EXIT_OK


def find_repo_root(start):
    try:
        r = subprocess.run(["git", "-C", start, "rev-parse", "--show-toplevel"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.abspath(start)


def init(opts, dck_tag, env=None, out=sys.stdout, err=sys.stderr):
    """opts: dict from the CLI. Returns an exit code."""
    env = os.environ if env is None else env
    repo = os.path.realpath(opts.get("repo") or find_repo_root(os.getcwd()))
    home = os.path.realpath(env.get("HOME", "/nonexistent"))
    if repo in ("/", home):
        err.write("dck: refusing to initialise %s — run dck init inside a repository\n" % repo)
        return EXIT_REFUSED
    if not os.path.isdir(repo):
        err.write("dck: %s is not a directory\n" % repo)
        return EXIT_USAGE

    toml_path = config.repo_config_path(repo)
    toml_exists = os.path.exists(toml_path)
    raw = config.parse_file(toml_path) if toml_exists else {}
    repo_name = os.path.basename(repo)
    rslug = config.slug(repo_name)

    # Flag values → dotted keys. They override dck.toml and are written into it.
    flag_map = (("flavour", "flavour"), ("service", "service"), ("user", "user"),
                ("workspace", "workspace"), ("ssh_port", "ssh_port"), ("image_tag", "image_tag"),
                ("agents", "layers.agents"), ("clis", "agents.clis"), ("editor", "layers.editor"),
                ("herdr_machine", "herdr.machine"), ("ports", "ports"))
    if opts.get("ports") is not None:
        merged_ports = dict(raw.get("ports") or {}) if isinstance(raw.get("ports"), dict) else {}
        merged_ports.update(opts["ports"])
        opts = dict(opts, ports=merged_ports)
    overrides = [(dotted, opts[k]) for k, dotted in flag_map if opts.get(k) is not None]

    doc = {k: (dict(v) if isinstance(v, dict) else v) for k, v in raw.items()}
    if not toml_exists:
        doc.update({"interface": config.INTERFACE, "service": "app", "flavour": detect_flavour(repo),
                    "ssh_port": default_ssh_port(rslug)})
        doc["herdr"] = {"machine": which("herdr") is not None}
    for dotted, value in overrides:
        table, _, key = dotted.rpartition(".")
        if table:
            doc.setdefault(table, {})[key] = value
        else:
            doc[key] = value
    try:
        values, warnings = config.validate(doc, "repo", toml_path)
    except config.ConfigError as exc:
        err.write("dck: invalid configuration\n%s\n" % exc)
        return EXIT_CONFIG
    for w in warnings:
        err.write("dck: warning: %s\n" % w)
    if values["image_tag"] is None:
        values["image_tag"] = dck_tag
    values["_label_fmt"] = values["herdr.label"]

    prof, pwarn = config.load_profile(opts.get("profile"), env)
    for w in pwarn:
        err.write("dck: warning: %s\n" % w)
    project = prof["compose_project_prefix"] + rslug

    ref = "%s:%s-%s" % (BASE_IMAGE_REPO, values["flavour"], values["image_tag"])
    base_image = ref
    if not opts.get("no_digest"):
        digest = resolve_digest(ref)
        if digest:
            base_image = "%s@%s" % (ref, digest)
        else:
            prev = existing_base_image(repo)
            if prev and prev.startswith(ref + "@sha256:"):
                base_image = prev
            else:
                err.write("dck: warning: could not resolve the digest of %s (offline, no docker, or not "
                          "published yet); the base image is pinned by tag only — re-run `dck init` "
                          "later to pin the digest\n" % ref)

    ctx = context(values, repo_name, project, prof["network"], base_image, dck_tag)
    try:
        changes = plan(repo, values, ctx, overrides if toml_exists else [], toml_exists)
    except RenderError as exc:
        err.write("dck: template error: %s\n" % exc)
        return EXIT_FAIL

    out.write("dck init: %s (flavour %s, service %s, project %s)\n"
              % (repo, values["flavour"], values["service"], project))
    for c in changes:
        out.write("%-10s%s%s\n" % (c.action, c.rel, (" (%s)" % c.note) if c.note and c.action != "unchanged" else ""))
    for c in changes:
        if c.action in ("update", "replace", "append"):
            out.write("\n" + unified(c))
    if opts.get("dry_run"):
        out.write("\ndry run: nothing was written.\n")
        return EXIT_OK
    interactive = bool(opts.get("interactive"))
    code = apply(repo, changes, bool(opts.get("yes")), interactive, out)
    if code == EXIT_OK and any(c.action != "unchanged" for c in changes):
        out.write("\nnext: dck setup && dck up\n")
    elif code == EXIT_OK:
        out.write("\nalready in sync: nothing to do.\n")
    return code
