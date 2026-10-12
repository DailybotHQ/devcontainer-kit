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

KIT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TEMPLATE_DIR = os.path.join(KIT_ROOT, "src", "template")

# The scripts a rendered Dockerfile COPYs, vendored into docker/local/<service>/dck/
# as byte copies of this kit's files (no shared base image carries them).
VENDORED = (
    ("versions.env", "images/versions.env"),
    ("install.sh", "images/common/install.sh"),
    ("editor.sh", "images/common/editor.sh"),
    ("peers.sh", "images/common/peers.sh"),
    ("herdr-layout.sh", "images/common/herdr-layout.sh"),
    ("sshd_config.conf", "images/common/sshd_config.conf"),
    ("github_known_hosts", "images/common/github_known_hosts"),
    ("herdr-config.toml", "images/common/herdr-config.toml"),
    ("profile.sh", "images/common/profile.sh"),
    ("dck-entrypoint", "images/common/dck-entrypoint"),
    ("dck-layer", "images/common/dck-layer"),
    ("entrypoint.sh", "lib/entrypoint.sh"),
    ("layers/common.sh", "lib/layers/common.sh"),
    ("layers/agents.sh", "lib/layers/agents.sh"),
    ("layers/dailybot.sh", "lib/layers/dailybot.sh"),
)
# Per flavour: the base-image pin in versions.env and the extra apt packages
# install.sh adds (the editor's plugins need python3-venv / nodejs).
FLAVOUR_BASE = {"node-24": "BASE_NODE", "python-3.13": "BASE_PYTHON", "debian": "BASE_DEBIAN"}
FLAVOUR_APT = {"node-24": "python3 python3-venv", "python-3.13": "nodejs npm",
               "debian": "python3 python3-venv nodejs npm"}

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
# The user block (v0.3.3): `# >>> user:<service> >>>` … `# <<< user:<service> <<<`
# inside the dck service mapping. dck never rewrites it. Plain keys there are
# keys dck does not render (compose reads them as they are); `x-dck-merge:`
# holds keys dck also renders, merged into dck's at render time: lists
# appended, maps merged (the user's entry wins), scalars replaced.
# --------------------------------------------------------------------------

# Keys that compose writes as lists but that REPLACE, never append: the user's
# value wins as written (reported as an override when dck renders the key).
REPLACE_KEYS = ("command", "entrypoint", "healthcheck", "working_dir", "user", "image", "init",
                "platform", "stop_signal", "restart", "build")

# Top-level user sub-blocks: declarations for the file's other services
# (`# >>> user:volumes >>>` inside dck's volumes block, same for networks).
TOP_USER_BLOCKS = ("volumes", "networks")

USER_RE = re.compile(r"^[ \t]*# (>>>|<<<) user:([A-Za-z0-9_.-]+) (>>>|<<<)[ \t]*$")
MERGE_KEY = "x-dck-merge"


class UserBlockError(Exception):
    pass


def _indent(line):
    return len(line) - len(line.lstrip(" "))


def _blank(line):
    t = line.strip()
    return not t or t.startswith("#")


def extract_user_block(text, service):
    """The user block's lines (markers included) inside the dck service block,
    or None when there is none. A half-open, duplicated or misplaced block is
    an error naming the fix."""
    lines = text.splitlines()
    blocks = parse_blocks(text) or {}
    found, start = [], None
    for i, line in enumerate(lines):
        m = USER_RE.match(line)
        if not m or m.group(2) in TOP_USER_BLOCKS:
            continue
        if m.group(2) != service:
            raise UserBlockError("user block for %r found, but the dck service is %r; rename its markers to "
                                 "user:%s" % (m.group(2), service, service))
        if m.group(1) == ">>>":
            if start is not None or found:
                raise UserBlockError("a second user:%s block (line %d); keep exactly one" % (service, i + 1))
            start = i
        else:
            if start is None:
                raise UserBlockError("'# <<< user:%s <<<' at line %d has no opening marker "
                                     "'# >>> user:%s >>>'" % (service, i + 1, service))
            found = [start, i]
            start = None
    if start is not None:
        raise UserBlockError("'# >>> user:%s >>>' at line %d has no closing marker; add "
                             "'    # <<< user:%s <<<' after the block" % (service, start + 1, service))
    if not found:
        return None
    svc = blocks.get("service")
    if not svc or not (svc[0] < found[0] and found[1] < svc[1]):
        raise UserBlockError("the user:%s block must sit inside the dck service block, right before "
                             "'  # <<< dck:service <<<'" % service)
    return lines[found[0]:found[1] + 1]


def _children(lines, start, indent):
    """Lines after `start` that belong to it (deeper indent, or blank)."""
    out, j = [], start + 1
    while j < len(lines) and (_blank(lines[j]) or _indent(lines[j]) > indent):
        out.append(lines[j])
        j += 1
    while out and not out[-1].strip():
        out.pop()
    return out, j


def _split_flow(text):
    """The items of a one-line flow collection body, honouring quotes."""
    items, cur, quote, depth = [], "", None, 0
    for ch in text:
        if quote:
            cur += ch
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote, cur = ch, cur + ch
        elif ch in "[{":
            depth, cur = depth + 1, cur + ch
        elif ch in "]}":
            depth, cur = depth - 1, cur + ch
        elif ch == "," and depth == 0:
            items.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        items.append(cur.strip())
    return items


def _value(rest, body):
    """(kind, payload) of one key: ("list", [item chunks]), ("map", [(key, chunk)]),
    ("scalar", text) or ("block", body lines) for anything else."""
    rest = re.sub(r"\s+#.*$", "", rest).strip() if not rest.strip().startswith(("'", '"')) else rest.strip()
    if rest:
        if rest.startswith("[") and rest.endswith("]"):
            return "list", [["- " + it] for it in _split_flow(rest[1:-1])]
        if rest.startswith("{") and rest.endswith("}"):
            out = []
            for it in _split_flow(rest[1:-1]):
                k, _, v = it.partition(":")
                out.append((k.strip().strip("\"'"), ["%s: %s" % (k.strip(), v.strip())]))
            return "map", out
        return "scalar", rest
    real = [ln for ln in body if not _blank(ln)]
    if not real:
        return "scalar", "null"
    ind = _indent(real[0])
    if real[0].lstrip().startswith("- "):
        items = []
        for ln in body:
            if _blank(ln) and not items:
                continue
            if _indent(ln) == ind and ln.lstrip().startswith("- "):
                items.append([ln[ind:]])
            elif items:
                items[-1].append(ln[ind:] if len(ln) >= ind else ln.strip())
        return "list", items
    entries = []
    for ln in body:
        if _blank(ln) and not entries:
            continue
        m = re.match(r"^\s*([^\s:#][^:#]*?)\s*:(\s|$)", ln)
        if _indent(ln) == ind and m:
            entries.append((m.group(1).strip("\"'"), [ln[ind:]]))
        elif entries:
            entries[-1][1].append(ln[ind:] if len(ln) >= ind else ln.strip())
    if entries:
        return "map", entries
    return "block", body


def _keys(lines):
    """[(key, rest of its line, child lines)] of a mapping (first key's indent)."""
    real = [ln for ln in lines if not _blank(ln)]
    if not real:
        return []
    ind = _indent(real[0])
    out, i = [], 0
    while i < len(lines):
        ln = lines[i]
        m = re.match(r"^\s*([A-Za-z0-9_.-]+)\s*:(.*)$", ln)
        if not _blank(ln) and _indent(ln) == ind and m:
            body, j = _children(lines, i, ind)
            out.append((m.group(1), m.group(2), body))
            i = j
            continue
        if not _blank(ln):
            raise UserBlockError("cannot read line %r in the user block (one key per line at the block's "
                                 "indentation)" % ln.strip())
        i += 1
    return out


def parse_user_block(block):
    """{"lines", "plain": {key}, "merge": {key: (kind, payload)}, "volumes", "networks"}."""
    inner = block[1:-1]
    plain, merge = {}, {}
    for key, rest, body in _keys(inner):
        if key == MERGE_KEY:
            if rest.strip():
                raise UserBlockError("x-dck-merge must be a block mapping (keys on the lines below it)")
            for k, r, b in _keys(body):
                merge[k] = ("raw", (r, b)) if k in REPLACE_KEYS else _value(r, b)
        else:
            plain[key] = True
    volumes, networks = [], []
    kind, items = merge.get("volumes", ("list", []))
    if kind == "list":
        for chunk in items:
            first = chunk[0][2:].strip().strip("\"'")
            src = None
            if re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]*:/", first):
                src = first.split(":", 1)[0]
            else:
                text = "\n".join(chunk)
                if re.search(r"(^|\s)type:\s*volume\b", text):
                    m = re.search(r"source:\s*['\"]?([A-Za-z0-9][A-Za-z0-9_.-]*)", text)
                    src = m.group(1) if m else None
            if src and src not in volumes:
                volumes.append(src)
    kind, items = merge.get("networks", ("list", []))
    if kind == "list":
        for chunk in items:
            name = chunk[0][2:].strip().strip("\"'")
            if re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", name) and name != "default" and name not in networks:
                networks.append(name)
    elif kind == "map":
        networks += [k for k, _ in items if k != "default" and k not in networks]
    return {"lines": block, "plain": plain, "merge": merge, "volumes": volumes, "networks": networks}


def apply_user_block(rendered, service, user):
    """The rendered compose text with the user block merged into the dck service
    block and kept verbatim before its closing marker. Returns (text, overrides)."""
    if not user:
        return rendered, []
    if not user.get("lines"):
        return apply_top_user_blocks(rendered, user.get("top")), []
    lines = rendered.splitlines()
    blocks = parse_blocks(rendered)
    s, e = blocks["service"]
    head = None
    for i in range(s + 1, e):
        if re.match(r"^  %s:\s*$" % re.escape(service), lines[i]):
            head = i
            break
    if head is None:
        raise UserBlockError("the rendered service %r was not found" % service)
    body = lines[head + 1:e]
    keys = _keys(body)
    dck = {k: (r, b) for k, r, b in keys}
    clash = sorted(k for k in user["plain"] if k in dck)
    if clash:
        raise UserBlockError("the user block sets %s as plain key(s), but dck renders %s too; move %s under "
                             "x-dck-merge: (lists are appended, maps merged, scalars replaced)"
                             % (", ".join(clash), "it" if len(clash) == 1 else "them",
                                "it" if len(clash) == 1 else "them"))
    overrides, out = [], []
    order = [k for k, _, _ in keys] + [k for k in user["merge"] if k not in dck]
    for key in order:
        rest, child = dck.get(key, ("", []))
        if key not in user["merge"]:
            out.append("    %s:%s" % (key, rest))
            out.extend(child)
            continue
        ukind, upay = user["merge"][key]
        if key not in dck:
            out.extend(_emit(key, ukind, upay))
            continue
        if ukind == "raw":
            if (rest, child) != upay:
                overrides.append(key)
            out.extend(_emit(key, ukind, upay))
            continue
        dkind, dpay = _value(rest, child)
        if ukind == "list" and dkind == "list":
            have = ["\n".join(c) for c in dpay]
            items = dpay + [c for c in upay if "\n".join(c) not in have]
            out.extend(_emit(key, "list", items))
        elif ukind == "map" and dkind == "map":
            merged, seen = [], {}
            for k, c in dpay:
                seen[k] = len(merged)
                merged.append((k, c))
            for k, c in upay:
                if k in seen:
                    if merged[seen[k]][1] != c:
                        overrides.append("%s.%s" % (key, k))
                    merged[seen[k]] = (k, c)
                else:
                    merged.append((k, c))
            out.extend(_emit(key, "map", merged))
        elif ukind in ("list", "map") and dkind in ("list", "map"):
            raise UserBlockError("x-dck-merge.%s is a %s, but dck renders %s as a %s; write it as a %s"
                                 % (key, "list" if ukind == "list" else "mapping", key,
                                    "list" if dkind == "list" else "mapping", "list" if dkind == "list" else "mapping"))
        else:
            overrides.append(key)
            out.extend(_emit(key, ukind, upay))
    new = lines[:head + 1] + out + user["lines"] + lines[e:]
    text = "\n".join(new)
    text = text + "\n" if rendered.endswith("\n") else text
    return apply_top_user_blocks(text, user.get("top")), overrides


def extract_top_user_blocks(text):
    """{"volumes": lines, "networks": lines} (markers included) of the top-level
    user sub-blocks, each inside dck's block of the same name; {} for none."""
    lines = text.splitlines()
    blocks = parse_blocks(text) or {}
    out, open_at = {}, {}
    for i, line in enumerate(lines):
        m = USER_RE.match(line)
        if not m or m.group(2) not in TOP_USER_BLOCKS:
            continue
        name = m.group(2)
        if m.group(1) == ">>>":
            if name in open_at or name in out:
                raise UserBlockError("a second user:%s block (line %d); keep exactly one" % (name, i + 1))
            open_at[name] = i
        else:
            if name not in open_at:
                raise UserBlockError("'# <<< user:%s <<<' at line %d has no opening marker" % (name, i + 1))
            start = open_at.pop(name)
            dck = blocks.get(name)
            if not dck or not (dck[0] < start and i < dck[1]):
                raise UserBlockError("the user:%s block must sit inside dck's top-level %s block, right before "
                                     "'# <<< dck:%s <<<'" % (name, name, name))
            out[name] = lines[start:i + 1]
    for name, at in open_at.items():
        raise UserBlockError("'# >>> user:%s >>>' at line %d has no closing marker; add '  # <<< user:%s <<<' "
                             "after the block" % (name, at + 1, name))
    return out


def top_declared(block):
    """The names a top-level user sub-block declares (keys at its first indent)."""
    names = []
    for k, _r, _b in _keys(block[1:-1]):
        names.append(k)
    return names


def apply_top_user_blocks(rendered, top):
    """Insert each top-level user sub-block verbatim before dck's closing marker."""
    if not top:
        return rendered
    lines = rendered.splitlines()
    for name in TOP_USER_BLOCKS:
        if name not in top:
            continue
        blocks = parse_blocks("\n".join(lines))
        if name not in blocks:
            raise UserBlockError("the user:%s block has no dck %s block to live in" % (name, name))
        end = blocks[name][1]
        lines = lines[:end] + top[name] + lines[end:]
    text = "\n".join(lines)
    return text + "\n" if rendered.endswith("\n") else text


def load_user_block(repo, service):
    """The parsed user block of the repository's compose file, or None."""
    path = os.path.join(repo, "docker", "local", "docker-compose.yaml")
    if not os.path.isfile(path) or os.path.islink(path):
        return None
    text = open(path).read()
    block = extract_user_block(text, service)
    top = extract_top_user_blocks(text)
    if not block and not top:
        return None
    user = parse_user_block(block) if block else {"lines": None, "plain": {}, "merge": {}, "volumes": [],
                                                    "networks": []}
    user["top"] = top
    user["top_volumes"] = top_declared(top["volumes"]) if "volumes" in top else []
    user["top_networks"] = top_declared(top["networks"]) if "networks" in top else []
    return user


def _emit(key, kind, payload):
    if kind == "raw":
        rest, body = payload
        return ["    %s:%s" % (key, rest)] + list(body)
    if kind == "scalar":
        return ["    %s: %s" % (key, payload)]
    if kind == "block":
        return ["    %s:" % key] + payload
    out = ["    %s:" % key]
    for _k, chunk in (payload if kind == "map" else [(None, c) for c in payload]):
        out.extend("      " + ln if ln.strip() else "" for ln in chunk)
    return out


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


def kit_pins():
    """images/versions.env of this kit as a dict (KEY=VALUE lines)."""
    pins = {}
    with open(os.path.join(KIT_ROOT, "images", "versions.env")) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                pins[k.strip()] = v.strip()
    return pins


def base_image_for(values, pins):
    """The image the Dockerfile starts FROM: dck.toml base_image, else the
    flavour's official image pinned by digest in versions.env."""
    return values.get("base_image") or pins[FLAVOUR_BASE[values["flavour"]]]


def vendored_files():
    """(relative path under dck/, content) for every vendored script, plus
    the VERSION stamp."""
    out = []
    for rel, src in VENDORED:
        with open(os.path.join(KIT_ROOT, src)) as fh:
            out.append((rel, fh.read()))
    return out


def toml_drop(text, key):
    """Remove a top-level `key = ...` line from TOML text (before any table)."""
    lines = text.splitlines()
    out, in_table = [], False
    for ln in lines:
        if re.match(r"^\s*\[", ln):
            in_table = True
        if not in_table and re.match(r"^\s*%s\s*=" % re.escape(key), ln):
            continue
        out.append(ln)
    return "\n".join(out) + ("\n" if text.endswith("\n") else "")


def supported_volumes(values):
    """The kinds [agents] supported wires (home volumes, host profiles), in ak's order."""
    return config.supported_kinds(values.get("agents.supported"), values.get("agents.clis") or [])


def install_args(values):
    """The Dockerfile ARGs of the INSTALL_<CLI>_CLI convention (v0.3.6)."""
    return ["ARG %s=false" % config.install_var(k) for k in supported_volumes(values)]


def layers_block(values):
    """Dockerfile lines for the opt-in layers (see docs/layers.md)."""
    lines = []
    user = values["user"]
    presets = values.get("agents.presets")
    if values["layers.agents"] and presets is None:
        # [agents] presets unset: the v0.3.2 lines, byte for byte (both presets on).
        lines += [
            "# Agents layer (layers.agents = true): coding-agents-kit (ak) from its verified",
            "# release, the pinned Node when the flavour lacks a current one, `ak install`",
            "# (pinned, verified) and the classic + providers presets. Autonomy is ak's default.",
            "# The CLIs installed: DCK_AGENT_CLIS plus each INSTALL_<CLI>_CLI=true (compose",
            "# passes both from the developer's environment or docker/local/.env).",
            "ARG DCK_AGENT_CLIS=\"%s\"" % " ".join(values["agents.clis"]),
        ] + install_args(values) + [
            "RUN DCK_USER=%s DCK_AGENT_SUPPORTED=\"%s\" dck-layer agents ${DCK_AGENT_CLIS}"
            % (user, " ".join(supported_volumes(values))),
        ]
    elif values["layers.agents"]:
        lines += [
            "# Agents layer (layers.agents = true): coding-agents-kit (ak) from its verified",
            "# release, the pinned Node when the flavour lacks a current one, `ak install`",
            "# (pinned, verified) and the ak alias presets of [agents] presets (%s)."
            % (" + ".join(presets) or "none"),
            "# Autonomy is ak's default.",
            "# The CLIs installed: DCK_AGENT_CLIS plus each INSTALL_<CLI>_CLI=true (compose",
            "# passes both from the developer's environment or docker/local/.env).",
            "ARG DCK_AGENT_CLIS=\"%s\"" % " ".join(values["agents.clis"]),
        ] + install_args(values) + [
            "RUN DCK_USER=%s DCK_AGENT_SUPPORTED=\"%s\" DCK_AGENT_PRESETS=\"%s\" dck-layer agents ${DCK_AGENT_CLIS}"
            % (user, " ".join(supported_volumes(values)), " ".join(presets)),
        ]
    if values["layers.dailybot"]:
        lines += [
            "# Dailybot layer (layers.dailybot = true): requested by the dailybot addon.",
            "RUN DCK_USER=%s dck-layer dailybot" % user,
        ]
    if values["layers.agents"] and values.get("agents.node_first"):
        lines += [
            "# [agents] node_first = true: the agents' Node (/opt/dck/node, present when the",
            "# image's node is older than the pinned major) first on PATH for every process.",
            "ENV PATH=/opt/dck/node/bin:$PATH \\",
            "    DCK_NODE_FIRST=1",
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


def release_sums_sha256(dck_tag):
    """The sha256 of this release's SHA256SUMS when the kit knows it: install.sh
    records it (RELEASE_SUMS_SHA256: '<tag> <sha256>') when it installs from a
    verified release. Empty when unknown (a checkout, an unverified install)."""
    path = os.path.join(KIT_ROOT, "RELEASE_SUMS_SHA256")
    if os.environ.get("DCK_TEST") == "1" and os.environ.get("DCK_TEST_RELEASE_SUMS"):
        path = os.environ["DCK_TEST_RELEASE_SUMS"]  # test hook
    try:
        parts = open(path).read().split()
    except OSError:
        return ""
    if len(parts) == 2 and parts[0] == dck_tag and re.match(r"^[0-9a-f]{64}$", parts[1]):
        return parts[1]
    return ""


RE_HOST_IP = re.compile(r"^(\d{1,3}(\.\d{1,3}){3}|\[[0-9A-Fa-f:]+\]):")


def port_line(bind, spec, comment):
    """One `ports:` entry: an integer as before; a string verbatim, after the bind
    address unless it already names a host IP; a lone host port maps to itself."""
    if isinstance(spec, int):
        return '      - "%s:%d:%d"   # %s' % (bind, spec, spec, comment)
    s = spec if ":" in spec or not re.match(r"^\d+$", spec) else "%s:%s" % (spec, spec)
    if not RE_HOST_IP.match(s):
        s = "%s:%s" % (bind, s)
    return '      - "%s"   # %s' % (s, comment)


def dockerfile_path(values):
    """The service's Dockerfile, relative to the repository: [build] dockerfile
    (shared by several services), else docker/local/<service>/Dockerfile."""
    return values.get("build.dockerfile") or "docker/local/%s/Dockerfile" % values["service"]


def build_paths(values):
    """(build context, dockerfile relative to it, dck/ relative to it); the
    v0.3.2 defaults when [build] context and dockerfile are unset."""
    svc = values["service"]
    ctx = values.get("build.context")
    df = dockerfile_path(values)
    df_dir, df_name = os.path.split(df)
    if not ctx and not values.get("build.dockerfile"):
        return "./%s" % svc, "Dockerfile", "dck"
    if not ctx:
        ctx = "./" + os.path.relpath(df_dir, os.path.join("docker", "local"))
    rel = os.path.relpath(df_dir, os.path.normpath(os.path.join("docker", "local", ctx)))
    rel = "" if rel == "." else rel + "/"
    return ctx, rel + df_name, rel + "dck"


def network_names(values, network, extra=()):
    """The external networks, once each: the host profile's, [compose] networks,
    then those the user block names."""
    out = []
    for n in [network] + list(values.get("compose.networks") or []) + list(extra):
        if n and n not in out:
            out.append(n)
    return out


def context(values, repo_name, project, network, base_image, dck_tag, pins=None, user=None):
    merge = (user or {}).get("merge") or {}
    top_vols = (user or {}).get("top_volumes") or []
    top_nets = (user or {}).get("top_networks") or []
    # x-dck-merge volumes/networks the user declares in a top-level sub-block
    # are theirs to declare (an external volume, a network with options).
    user_volumes = [v for v in list(values.get("compose.volumes") or []) + ((user or {}).get("volumes") or [])
                    if v not in top_vols]
    user_networks = [n for n in (user or {}).get("networks") or [] if n not in top_nets]
    nets = network_names(values, network, user_networks)
    dck_vols = [values["compose.state_volume"]] + (["agentkit"] + supported_volumes(values)
                                                   if values["layers.agents"] else [])
    for name in top_vols:
        if name in dck_vols or name in (values.get("compose.volumes") or []):
            raise UserBlockError("volume %r is declared in the user:volumes block and by dck (%s); declare it once: "
                                 "remove it from the block%s" % (name, "dck.toml [compose] volumes"
                                                                 if name in (values.get("compose.volumes") or [])
                                                                 else "its own volume",
                                                                 " or from [compose] volumes"
                                                                 if name in (values.get("compose.volumes") or []) else ""))
    for name in top_nets:
        if name in network_names(values, network):
            raise UserBlockError("network %r is declared in the user:networks block and by dck ([compose] networks "
                                 "or the host profile's network); declare it once" % name)
    has_net_decls = bool(nets) or "networks" in ((user or {}).get("top") or {})
    bctx, bdockerfile, dck_dir = build_paths(values)
    user = values["user"]
    # (compose volume key, directory under ~/.dck/volumes): the state volume's
    # name is configurable, its mount point is not (the entrypoint reads "state").
    vols = [(values["compose.state_volume"], "state")]
    if values["layers.agents"]:
        vols.append(("agentkit", "agentkit"))
        # Every SUPPORTED CLI's home, installed or not (v0.3.6): a CLI a developer
        # installs later finds its volume; an unused one stays empty.
        vols += [(k, k) for k in supported_volumes(values)]
    bind = values["bind"]
    port_lines = []
    if values["ssh_port"]:
        if isinstance(values["ssh_port"], int):
            port_lines.append('      - "%s:%d:22"   # sshd (Herdr, `dck ssh`)' % (bind, values["ssh_port"]))
        else:
            port_lines.append('      - "%s:%s:22"   # sshd (Herdr, `dck ssh`)' % (bind, values["ssh_port"]))
    for name, port in sorted(values["ports"].items(), key=lambda kv: (isinstance(kv[1], str), str(kv[1]).zfill(5))):
        port_lines.append(port_line(bind, port, name))
    raw_label = values.get("_label_fmt", values["herdr.label"])
    return {
        "dck_tag": dck_tag,
        "dck_version": dck_tag.lstrip("v"),
        "is_node": values["flavour"] == "node-24",
        "is_python": values["flavour"] == "python-3.13",
        "editor_on": values["layers.editor"],
        "uv_image": (pins or {}).get("UV_IMAGE", ""),
        "apt_extras": FLAVOUR_APT[values["flavour"]],
        "repo_name": repo_name,
        "project": project,
        "dck_sums_sha256": release_sums_sha256(dck_tag),
        "service": values["service"],
        "user": user,
        "workspace": values["workspace"],
        "flavour": values["flavour"],
        "base_image": base_image,
        "ssh_port": toml_value(values["ssh_port"]),
        "ssh_enabled": "1" if values["ssh_port"] else "0",
        "editor_enabled": "1" if values["layers.editor"] else "0",
        "ports_inline": ", ".join("%s = %s" % (k, toml_value(v)) for k, v in sorted(values["ports"].items())),
        "has_ports": bool(port_lines),
        "port_lines": "\n".join(port_lines),
        "volume_mounts": "\n".join("      - %s:/home/%s/.dck/volumes/%s" % (v, user, d) for v, d in vols),
        "volume_decls": "\n".join("  %s: {}" % v for v in
                                   [v for v, _ in vols] + [u for u in user_volumes if u not in [v for v, _ in vols]]),
        "state_volume": values["compose.state_volume"],
        "has_network": bool(nets),
        "has_network_decls": has_net_decls,
        "network": network,
        "network_lines": "\n".join("      - %s" % n for n in nets),
        "network_decls": "\n".join("  %s:\n    external: true\n    name: %s" % (n, n) for n in nets),
        "build_context": bctx,
        "build_dockerfile": bdockerfile,
        "dck_dir": dck_dir,
        "layers_agents": toml_value(values["layers.agents"]),
        "layers_agents_on": values["layers.agents"],
        "layers_dailybot_on": values["layers.dailybot"],
        "layers_dailybot": toml_value(values["layers.dailybot"]),
        "layers_editor": toml_value(values["layers.editor"]),
        "agents_clis_toml": ", ".join(json.dumps(c) for c in values["agents.clis"]),
        "agents_clis_space": " ".join(values["agents.clis"]),
        "agents_supported_space": " ".join(supported_volumes(values)),
        "agents_supported_set": values.get("agents.supported") is not None,
        "agents_supported_toml": ('"all"' if values.get("agents.supported") == "all"
                                  else "[%s]" % ", ".join(json.dumps(c) for c in values.get("agents.supported") or [])),
        "install_arg_lines": "\n".join('        %s: "${%s:-false}"' % (config.install_var(k), config.install_var(k))
                                       for k in supported_volumes(values)),
        "install_env_lines": "\n".join("# %s=false" % config.install_var(k) for k in supported_volumes(values)),
        "agents_presets_toml": ", ".join(json.dumps(p) for p in (values.get("agents.presets") or [])),
        "herdr_machine": toml_value(values["herdr.machine"]),
        "herdr_layout": values["herdr.layout"],
        "herdr_mesh": "true" if values["herdr.mesh"] else "false",
        "ssh_agent_on": values["ssh_agent"],
        "ssh_host_config": "true" if values["ssh_host_config"] else "false",
        "dev_sh": "true" if values.get("dev_sh", True) else "false",
        "ssh_agent": toml_value(values["ssh_agent"]),
        "herdr_label_fmt": raw_label,
        "rename_user": user != "dev",
        "workspace_in_home": user != "dev" and values["workspace"].startswith("/home/%s/" % user),
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
    def __init__(self, rel, action, new=None, old=None, note="", mode=None):
        self.rel, self.action, self.new, self.old, self.note = rel, action, new, old, note
        self.mode = mode


def _read(path):
    if os.path.islink(path):
        return None  # check_paths refuses it before anything is shown or written
    try:
        with open(path) as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def check_markers(rel, old, rendered):
    """Markers are all-or-nothing: a file with some of dck's markers but not
    all of the ones it needs is refused with the fix (never a block appended at
    EOF that would land inside another mapping). Only `networks`, a top-level
    block, may be added at the end."""
    have = parse_blocks(old)
    if have is None:
        raise RefusedError("%s: dck's markers are unbalanced, duplicated or crossed; fix them (each "
                           "'# >>> dck:<name> >>>' needs its '# <<< dck:<name> <<<'), or remove every dck "
                           "marker to let dck replace the file (with a backup)" % rel)
    if not have:
        return
    need = parse_blocks(rendered) or {}
    missing = [n for n in need if n not in have and n != "networks"]
    if missing:
        raise RefusedError("%s has dck markers (%s) but not %s; add the missing block(s) back where they "
                           "belong (see a fresh `dck init` render), or remove every dck marker to let dck "
                           "replace the file (with a backup)"
                           % (rel, ", ".join(sorted(have)), ", ".join("dck:" + n for n in missing)))
    if "networks" in need and "networks" not in have and re.search(r"^networks:", old, re.M):
        raise RefusedError("%s already has a top-level 'networks:' outside dck's markers; dck must declare "
                           "the external networks in one place: move them to [compose] networks in "
                           "dck.toml (or x-dck-merge.networks) and delete that key" % rel)
    for key in ("volumes", "networks"):
        if key in have and len(re.findall(r"^%s:" % key, old, re.M)) > 1:
            raise RefusedError("%s has more than one top-level '%s:'; keep only dck's block and declare the "
                               "rest through dck.toml or x-dck-merge" % (rel, key))


def plan(repo, values, ctx, toml_overrides, toml_exists, drop=()):
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
        for key in drop:
            new = toml_drop(new, key)
        changes.append(Change(rel, "unchanged" if new == old else "update", new, old,
                              "migrated to interface 2" if drop else "values from flags"))

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
                      ("docker/service/Dockerfile.tmpl", dockerfile_path(values))):
        rendered = render_text(read_template(tmpl), ctx, tmpl)
        if tmpl.startswith("docker/docker-compose") and ctx.get("_user"):
            rendered, _ov = apply_user_block(rendered, svc, ctx["_user"])
        old = _read(os.path.join(repo, rel))
        if old is None:
            changes.append(Change(rel, "create", rendered))
            continue
        check_markers(rel, old, rendered)
        new = reconcile_blocks(old, rendered)
        if new is None:
            changes.append(Change(rel, "replace", rendered, old, "no dck markers: whole file"))
        else:
            changes.append(Change(rel, "unchanged" if new == old else "update", new, old, "managed blocks"))

    # Vendored scripts: owned by dck, byte copies of this kit's files.
    for sub, content in vendored_files() + [("VERSION", "devcontainer-kit %s\n" % ctx["dck_tag"])]:
        rel = "%s/dck/%s" % (os.path.dirname(dockerfile_path(values)), sub)
        old = _read(os.path.join(repo, rel))
        if old is None:
            changes.append(Change(rel, "create", content))
        else:
            changes.append(Change(rel, "unchanged" if old == content else "update", content, old,
                                  "vendored from devcontainer-kit %s" % ctx["dck_tag"]))

    # dev.sh: the per-repository entry point. A repository's own dev.sh (no dck
    # markers) is kept as it is; a rendered one is reconciled by its block.
    rel = "dev.sh"
    rendered = render_text(read_template("dev.sh.tmpl"), ctx, "dev.sh.tmpl")
    old = _read(os.path.join(repo, rel))
    if not values.get("dev_sh", True):
        changes.append(Change(rel, "unchanged", note="dev_sh = false in dck.toml: dev.sh is not managed"))
    elif old is None:
        changes.append(Change(rel, "create", rendered, mode=0o755))
    elif "devsh" not in (parse_blocks(old) or {}):
        changes.append(Change(rel, "unchanged", note="the repository's own dev.sh is kept (docs/launcher.md maps "
                                                     "its commands to dck)"))
    else:
        new = reconcile_blocks(old, rendered)
        changes.append(Change(rel, "unchanged" if new == old else "update", new, old, "managed block"))

    # Create-only files.
    if values["layers.agents"]:
        # The compose directory's .env.example: each developer's CLIs (v0.3.6).
        rel = "docker/local/.env.example"
        if _read(os.path.join(repo, rel)) is None:
            changes.append(Change(rel, "create", render_text(read_template("docker/env.example.tmpl"), ctx, rel)))
        else:
            changes.append(Change(rel, "unchanged", note="create-only"))
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


def check_paths(repo, changes):
    """Refuse symlinked targets and any target that resolves outside the repo.
    A repository could otherwise point docker/local/docker-compose.yaml at
    ~/.ssh/id_ed25519 (its content would be shown in a diff) or make
    docker/local a link out of the tree (dck would write there)."""
    root = os.path.realpath(repo)
    for c in changes:
        path = os.path.join(repo, c.rel)
        if os.path.islink(path):
            raise RefusedError("%s is a symlink; dck init never reads or writes through one" % c.rel)
        parent = os.path.realpath(os.path.dirname(path))
        if parent != root and not parent.startswith(root + os.sep):
            raise RefusedError("%s resolves outside the repository (%s)" % (c.rel, parent))


class RefusedError(Exception):
    pass


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
    while os.path.lexists(dest):
        n += 1
        dest = "%s.dck-bak-%s-%d" % (path, stamp, n)
    mode = os.stat(path).st_mode & 0o777
    # O_EXCL|O_NOFOLLOW: a name planted by the repository (even a dangling
    # symlink) is never written through.
    fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with open(path, "rb") as src, os.fdopen(fd, "wb") as out:
        out.write(src.read())
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
            write_atomic(path, c.new, c.mode)
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


def compose_status(repo, dck_tag, profile=None, env=None):
    """What `dck init` would do to docker/local/docker-compose.yaml, without
    writing: {"stale": bool, "overrides": [keys the user block overrides],
    "error": str or None}. Read by `dck doctor` and `dck up`."""
    env = os.environ if env is None else env
    out = {"stale": False, "overrides": [], "error": None}
    rel = "docker/local/docker-compose.yaml"
    path = os.path.join(repo, rel)
    if not os.path.isfile(path) or os.path.islink(path):
        return out
    try:
        toml_path = config.repo_config_path(repo)
        values, _ = config.validate(config.parse_file(toml_path), "repo", toml_path)
        values["_label_fmt"] = values["herdr.label"]
        prof, _ = config.load_profile(profile, env)
        project = values.get("compose.project") or prof["compose_project_prefix"] + config.slug(os.path.basename(repo))
        pins = kit_pins()
        user = load_user_block(repo, values["service"])
        ctx = context(values, os.path.basename(repo), project, prof["network"], base_image_for(values, pins),
                      dck_tag, pins, user)
        rendered = render_text(read_template("docker/docker-compose.yaml.tmpl"), ctx, "compose")
        rendered, out["overrides"] = apply_user_block(rendered, values["service"], user)
        old = open(path).read()
        if not parse_blocks(old):
            return out
        check_markers(rel, old, rendered)
        out["stale"] = reconcile_blocks(old, rendered) != old
    except (config.ConfigError, UserBlockError, RefusedError, RenderError, OSError) as exc:
        out["error"] = str(exc)
    return out


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
                ("workspace", "workspace"), ("ssh_port", "ssh_port"),
                ("agents", "layers.agents"), ("clis", "agents.clis"), ("supported", "agents.supported"), ("editor", "layers.editor"),
                ("herdr_machine", "herdr.machine"), ("ports", "ports"),
                ("state_volume", "compose.state_volume"), ("dev_sh", "dev_sh"))
    if opts.get("ports") is not None:
        merged_ports = dict(raw.get("ports") or {}) if isinstance(raw.get("ports"), dict) else {}
        merged_ports.update(opts["ports"])
        opts = dict(opts, ports=merged_ports)
    overrides = [(dotted, opts[k]) for k, dotted in flag_map if opts.get(k) is not None]

    doc = {k: (dict(v) if isinstance(v, dict) else v) for k, v in raw.items()}
    if not toml_exists:
        doc.update({"interface": config.INTERFACE, "service": "app", "flavour": detect_flavour(repo),
                    "ssh_port": default_ssh_port(rslug)})
        # New renders: no ak alias preset (dck.toml writes presets = []).
        doc.setdefault("agents", {}).setdefault("presets", [])
    for dotted, value in overrides:
        table, _, key = dotted.rpartition(".")
        if table:
            doc.setdefault(table, {})[key] = value
        else:
            doc[key] = value
    if (not toml_exists and opts.get("supported") is None and opts.get("interactive")
            and (doc.get("layers") or {}).get("agents")):
        # The default wires and installs the CLIs chosen here; the advanced mode
        # wires every CLI and lets each developer choose what to install.
        if ask("Coding-agent CLIs: dck wires and installs %s for everyone (the default).\n"
               "Advanced: wire every CLI ak knows and let each developer choose what to install "
               "(DCK_AGENT_CLIS, INSTALL_<CLI>_CLI, their host profile)? [y/N] "
               % (" ".join((doc.get("agents") or {}).get("clis") or []) or "no CLI")):
            doc.setdefault("agents", {})["supported"] = "all"
    if not toml_exists and opts.get("herdr_machine") is None:
        # Default: a Herdr machine when Herdr is installed and sshd is on.
        doc.setdefault("herdr", {})["machine"] = which("herdr") is not None and doc.get("ssh_port", 0) != 0
    try:
        values, warnings = config.validate(doc, "repo", toml_path)
    except config.ConfigError as exc:
        err.write("dck: invalid configuration\n%s\n" % exc)
        return EXIT_CONFIG
    for w in warnings:
        err.write("dck: warning: %s\n" % w)
    values["_label_fmt"] = values["herdr.label"]

    prof, pwarn = config.load_profile(opts.get("profile"), env)
    for w in pwarn:
        err.write("dck: warning: %s\n" % w)
    project = values.get("compose.project") or prof["compose_project_prefix"] + rslug

    pins = kit_pins()
    base_image = base_image_for(values, pins)
    # A version-1 dck.toml migrates to interface 2: the interface line is
    # rewritten and image_tag (meaningful only with the shared base image) goes.
    migrate = toml_exists and (values["interface"] == 1 or values["image_tag"] is not None)

    try:
        user = load_user_block(repo, values["service"])
    except UserBlockError as exc:
        err.write("dck: docker/local/docker-compose.yaml: %s\n" % exc)
        return EXIT_CONFIG
    try:
        ctx = context(values, repo_name, project, prof["network"], base_image, dck_tag, pins, user)
    except UserBlockError as exc:
        err.write("dck: docker/local/docker-compose.yaml: %s\n" % exc)
        return EXIT_CONFIG
    ctx["_user"] = user
    try:
        changes = plan(repo, values, ctx, (overrides if toml_exists else []) +
                       ([("interface", config.INTERFACE)] if migrate else []), toml_exists,
                       drop=("image_tag",) if migrate else ())
    except RenderError as exc:
        err.write("dck: template error: %s\n" % exc)
        return EXIT_FAIL
    except UserBlockError as exc:
        err.write("dck: docker/local/docker-compose.yaml: %s\n" % exc)
        return EXIT_CONFIG
    except RefusedError as exc:
        err.write("dck: refusing: %s\n" % exc)
        return EXIT_REFUSED

    try:
        check_paths(repo, changes)
    except RefusedError as exc:
        err.write("dck: refusing: %s\n" % exc)
        return EXIT_REFUSED
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
