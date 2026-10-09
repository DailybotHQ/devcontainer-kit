"""dck configuration: the per-repo `.devcontainer/dck.toml` and the host profile.

Interface 2 (see docs/config.md and docs/schema/); a version-1 file is still
read, with warnings, so `dck init` can migrate it. Python 3.11+ standard
library only (`tomllib`). Every rule lives in the RULES tables below; the
JSON Schemas under docs/schema/ are checked against them by the test suite,
so the two cannot drift apart silently.

Errors are collected, not raised one at a time: a user fixing a config sees
every problem in one run. Unknown keys are warnings (a newer dck may add
optional keys within an interface), never errors.
"""

import os
import re

try:  # pragma: no cover - exercised by the doctor on old interpreters
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    tomllib = None

INTERFACE = 2
INTERFACES = (1, 2)  # 1 is read for migration only

FLAVOURS = ("python-3.13", "node-24", "debian")
AGENT_KINDS = ("claude", "codex", "cursor", "opencode", "pi", "cline", "grok")
LABEL_PLACEHOLDERS = ("repo", "service", "project", "user")

RE_SERVICE = r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$"
RE_USER = r"^[a-z_][a-z0-9_-]{0,31}$"
RE_WORKSPACE = r"^/[A-Za-z0-9._/-]*$"
RE_TAG = r"^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$"
# An official image pinned by digest: name[:tag]@sha256:<64 hex>, no registry host.
RE_IMAGE_PIN = r"^[a-z0-9]+([._/-][a-z0-9]+)*(:[A-Za-z0-9._-]{1,128})?@sha256:[0-9a-f]{64}$"
RE_PORT_NAME = r"^[a-z][a-z0-9_-]{0,31}$"
RE_IPV4 = r"^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$"
RE_PROFILE_NAME = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"
RE_PREFIX = r"^([a-z0-9][a-z0-9_-]{0,31})?$"
RE_NETWORK = r"^([A-Za-z0-9][A-Za-z0-9_.-]{0,62})?$"
RE_ALIAS_PREFIX = r"^[a-z0-9][a-z0-9._-]{0,31}$"

# key path -> (type, default, constraint). "required" defaults are REQUIRED.
REQUIRED = object()
REPO_RULES = {
    "interface": ("int", REQUIRED, ("interface", INTERFACES)),
    "service": ("str", REQUIRED, ("pattern", RE_SERVICE)),
    "user": ("str", "dev", ("pattern", RE_USER)),
    "workspace": ("str", "/workspace", ("pattern", RE_WORKSPACE)),
    "flavour": ("str", REQUIRED, ("enum", FLAVOURS)),
    "image_tag": ("str", None, ("pattern", RE_TAG)),  # interface 1 only; ignored since v0.2.0
    "base_image": ("str", None, ("pattern", RE_IMAGE_PIN)),  # None -> the flavour's pinned image
    "ssh_port": ("int", 0, ("port_or_zero", None)),
    "bind": ("str", "127.0.0.1", ("pattern", RE_IPV4)),
    "ports": ("port_map", {}, ("pattern", RE_PORT_NAME)),
    "layers.agents": ("bool", False, None),
    "layers.dailybot": ("bool", False, None),
    "layers.editor": ("bool", True, None),
    "agents.clis": ("kind_list", [], ("enum", AGENT_KINDS)),
    "herdr.machine": ("bool", False, None),
    "ssh_agent": ("bool", True, None),
    "herdr.layout": ("str", "standard", ("enum", ("standard", "none"))),
    "herdr.label": ("label", "{repo}", ("placeholders", LABEL_PLACEHOLDERS)),
}
PROFILE_RULES = {
    "interface": ("int", INTERFACE, ("interface", INTERFACES)),
    "name": ("str", "default", ("pattern", RE_PROFILE_NAME)),
    "compose_project_prefix": ("str", "", ("pattern", RE_PREFIX)),
    "network": ("str", "", ("pattern", RE_NETWORK)),
    "alias_prefix": ("str", "dck-", ("pattern", RE_ALIAS_PREFIX)),
    "host_machine": ("bool", False, None),
    "labels.machine": ("label", "{repo}", ("placeholders", LABEL_PLACEHOLDERS)),
    "ssh.identity": ("path", "~/.config/dck/ssh/id_ed25519", None),
}
TABLES = {"repo": ("layers", "agents", "herdr"), "profile": ("labels", "ssh")}


class ConfigError(Exception):
    """Raised with every problem found, one per line."""

    def __init__(self, path, problems):
        self.path = path
        self.problems = problems
        super().__init__("\n".join("%s: %s" % (path, p) for p in problems))


def _type_name(v):
    return {bool: "boolean", int: "integer", str: "string", list: "array",
            dict: "table", float: "float"}.get(type(v), type(v).__name__)


def _check(key, value, rule, problems):
    kind, _default, constraint = rule
    ctype, carg = constraint if constraint else (None, None)

    def bad(msg):
        problems.append("%s: %s" % (key, msg))

    if kind == "bool":
        if not isinstance(value, bool):
            return bad("expected a boolean (true/false), got %s" % _type_name(value))
    elif kind == "int":
        if isinstance(value, bool) or not isinstance(value, int):
            return bad("expected an integer, got %s" % _type_name(value))
        if ctype == "const" and value != carg:
            return bad("interface %s is not supported by this dck (supports %s)" % (value, carg))
        if ctype == "interface" and value not in carg:
            return bad("interface %s is not supported by this dck (supports %s)"
                       % (value, " and ".join(str(v) for v in carg)))
        if ctype == "port_or_zero" and not (value == 0 or 1024 <= value <= 65535):
            return bad("expected 0 (no sshd) or a port in 1024-65535, got %s" % value)
    elif kind in ("str", "label", "path"):
        if not isinstance(value, str):
            return bad("expected a string, got %s" % _type_name(value))
        if "\n" in value or "\r" in value or "\x00" in value:
            return bad("must be a single line")
        if ctype == "pattern" and not re.match(carg, value):
            return bad("invalid value %r (must match %s)" % (value, carg))
        if ctype == "enum" and value not in carg:
            return bad("invalid value %r (one of: %s)" % (value, ", ".join(carg)))
        if kind == "label":
            if not value or len(value) > 64:
                return bad("must be 1-64 characters")
            for name in re.findall(r"\{([^{}]*)\}", value):
                if name not in carg:
                    return bad("unknown placeholder {%s} (known: %s)"
                               % (name, ", ".join("{%s}" % p for p in carg)))
        if kind == "path" and not value:
            return bad("must not be empty")
    elif kind == "port_map":
        if not isinstance(value, dict):
            return bad("expected a table of name = port, got %s" % _type_name(value))
        seen = {}
        for name, port in value.items():
            if not re.match(carg, name):
                bad("invalid port name %r (must match %s)" % (name, carg))
            elif isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
                bad("%s: expected a port number in 1-65535, got %r" % (name, port))
            elif port in seen:
                bad("%s: port %s is already used by %s" % (name, port, seen[port]))
            else:
                seen[port] = name
    elif kind == "kind_list":
        if not isinstance(value, list):
            return bad("expected an array of strings, got %s" % _type_name(value))
        for item in value:
            if item not in carg:
                bad("unknown kind %r (one of: %s)" % (item, ", ".join(carg)))
        if len(set(map(str, value))) != len(value):
            bad("duplicate entries")


def _flatten(data, tables, problems):
    """Map the TOML document onto dotted keys; unknown keys become warnings."""
    flat = {}
    for key, value in data.items():
        if key in tables:
            if not isinstance(value, dict):
                problems.append("%s: expected a table, got %s" % (key, _type_name(value)))
                continue
            for sub, subvalue in value.items():
                flat["%s.%s" % (key, sub)] = subvalue
        else:
            flat[key] = value
    return flat


def validate(data, kind="repo", path="dck.toml"):
    """Validate a parsed document. Returns (effective, warnings); raises ConfigError."""
    rules = REPO_RULES if kind == "repo" else PROFILE_RULES
    problems, warnings = [], []
    flat = _flatten(data, TABLES[kind], problems)
    for key in flat:
        if key not in rules:
            warnings.append("%s: unknown key %s ignored" % (path, key))
    effective = {}
    for key, rule in rules.items():
        if key in flat:
            _check(key, flat[key], rule, problems)
            effective[key] = flat[key]
        elif rule[1] is REQUIRED:
            problems.append("%s: required key is missing" % key)
        else:
            default = rule[1]
            effective[key] = list(default) if isinstance(default, list) else (
                dict(default) if isinstance(default, dict) else default)
    if kind == "repo" and not problems:
        if effective["agents.clis"] and not effective["layers.agents"]:
            warnings.append("%s: agents.clis is set but layers.agents is false; no CLI will be installed" % path)
        ssh = effective["ssh_port"]
        for name, port in effective["ports"].items():
            if ssh and port == ssh:
                problems.append("ports.%s: port %s is already the ssh_port" % (name, port))
        if effective["herdr.machine"] and not ssh:
            problems.append("herdr.machine: a Herdr machine needs sshd; set ssh_port to a port in 1024-65535")
        if effective["interface"] == 1:
            warnings.append("%s: interface 1 is read for migration only; `dck init` rewrites it as "
                            "interface 2" % path)
        if effective["image_tag"] is not None:
            warnings.append("%s: image_tag is ignored since devcontainer-kit v0.2.0 (no shared base "
                            "image); `dck init` removes it" % path)
    if problems:
        raise ConfigError(path, problems)
    return effective, warnings


def parse_file(path):
    """Read a TOML file; parse errors become ConfigError with the location."""
    if tomllib is None:
        raise ConfigError(path, ["python 3.11+ is required to read TOML (found %s)" % _pyver()])
    try:
        with open(path, "rb") as fh:
            return tomllib.load(fh)
    except FileNotFoundError:
        raise ConfigError(path, ["file not found"])
    except PermissionError:
        raise ConfigError(path, ["permission denied"])
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(path, ["invalid TOML: %s" % exc])


def _pyver():
    import sys
    return "%d.%d" % sys.version_info[:2]


def repo_config_path(repo):
    return os.path.join(repo, ".devcontainer", "dck.toml")


def load_repo(repo, default_tag):
    """Returns (effective, warnings, raw document)."""
    path = repo_config_path(repo)
    raw = parse_file(path)
    effective, warnings = validate(raw, "repo", path)
    if effective["image_tag"] is None:
        effective["image_tag"] = default_tag
    return effective, warnings, raw


def config_home(env=None):
    env = os.environ if env is None else env
    if env.get("DCK_CONFIG_HOME"):
        return env["DCK_CONFIG_HOME"]
    base = env.get("XDG_CONFIG_HOME") or os.path.join(env.get("HOME", ""), ".config")
    return os.path.join(base, "dck")


def profile_path(name=None, env=None):
    """None/"" selects profile.toml; a name selects profiles/<name>.toml."""
    home = config_home(env)
    if not name:
        return os.path.join(home, "profile.toml"), False
    if not re.match(RE_PROFILE_NAME, name):
        raise ConfigError("--profile", ["invalid profile name %r (must match %s)" % (name, RE_PROFILE_NAME)])
    return os.path.join(home, "profiles", "%s.toml" % name), True


def load_profile(name=None, env=None):
    """The default profile may be absent (defaults apply); a named one may not."""
    path, named = profile_path(name, env)
    if not os.path.exists(path):
        if named:
            raise ConfigError(path, ["profile %r not found" % name])
        effective, _ = validate({}, "profile", path)
        effective["_source"] = "defaults"
        return effective, []
    effective, warnings = validate(parse_file(path), "profile", path)
    effective["_source"] = path
    return effective, warnings


def expand_home(path, env):
    if path == "~" or path.startswith("~/"):
        return env.get("HOME", "") + path[1:]
    return path


def expand_label(fmt, values):
    return re.sub(r"\{([a-z]+)\}", lambda m: str(values.get(m.group(1), m.group(0))), fmt)


def slug(name):
    """A compose-project / ssh-alias safe slug of a repository name."""
    s = re.sub(r"[^a-z0-9_-]+", "-", name.lower()).strip("-_")
    return s[:48] or "repo"


def effective(repo, default_tag, profile_name=None, env=None):
    """The merged view the launcher acts on: repo config + host profile."""
    env = os.environ if env is None else env
    cfg, warn_repo, raw_repo = load_repo(repo, default_tag)
    prof, warn_prof = load_profile(profile_name, env)
    repo_name = os.path.basename(os.path.abspath(repo))
    label_fmt = cfg["herdr.label"] if "label" in (raw_repo.get("herdr") or {}) else prof["labels.machine"]
    rslug = slug(repo_name)
    merged = dict(cfg)
    merged.update({
        "repo": os.path.abspath(repo),
        "repo_name": repo_name,
        "repo_slug": rslug,
        "profile": prof["name"],
        "profile_source": prof["_source"],
        "compose_project_prefix": prof["compose_project_prefix"],
        "network": prof["network"],
        "alias": prof["alias_prefix"] + rslug,
        "host_machine": prof["host_machine"],
        "ssh_identity": expand_home(prof["ssh.identity"], env),
    })
    merged["herdr.label"] = expand_label(label_fmt, {
        "repo": repo_name, "service": cfg["service"], "user": cfg["user"],
        "project": prof["compose_project_prefix"] + rslug})
    return merged, warn_repo + warn_prof
