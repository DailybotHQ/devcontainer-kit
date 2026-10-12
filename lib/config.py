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
HOST_LISTENERS = ("dck", "external", "remote-login")

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
# A compose port string (v0.3.3): a host part and an optional container part,
# each a number or a ${VAR} / ${VAR:-default} expression, optionally after a host IP.
_PORT_ATOM = r"(\d{1,5}|\$\{[A-Za-z_][A-Za-z0-9_]*(:?-\d{1,5})?\})"
RE_PORT_SPEC = r"^((\d{1,3}(\.\d{1,3}){3}|\[[0-9A-Fa-f:]+\]):)?%s(:%s)?(/(tcp|udp))?$" % (_PORT_ATOM, _PORT_ATOM)
RE_COMPOSE_PROJECT = r"^[a-z0-9][a-z0-9_-]{0,62}$"
RE_BUILD_CONTEXT = r"^(\.|\.\.|\./[A-Za-z0-9._/-]*|\.\./[A-Za-z0-9._/-]*|[A-Za-z0-9._-][A-Za-z0-9._/-]*)$"
RE_NETWORK_NAME = r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$"
AK_PRESETS = ("classic", "providers")
RE_DEFAULT_PROFILE = r"^@?[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
DEFAULT_PROFILE_CLIS = ("claude", "codex", "pi", "cline", "grok", "opencode")
# A compose volume key (compose prefixes it with the project name).
RE_VOLUME = r"^[a-z0-9][a-z0-9_.-]{0,62}$"
# The agents layer's volume names: a state volume must not take one of them.
AGENT_VOLUME_NAMES = ("agentkit", "claude", "codex", "cursor", "opencode", "pi", "cline", "grok")
# An environment variable name (exact: no prefix or wildcard, no implicit secret).
RE_ENV_NAME = r"^[A-Z_][A-Z0-9_]{0,127}$"
# A host ak profile: <cli>@<name>, the CLIs whose profiles are file-portable.
RE_PROFILE_REF = r"^(claude|codex|pi|cline|grok|opencode)@[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"

# key path -> (type, default, constraint). "required" defaults are REQUIRED.
REQUIRED = object()
REPO_RULES = {
    "interface": ("int", REQUIRED, ("interface", INTERFACES)),
    "service": ("str", REQUIRED, ("pattern", RE_SERVICE)),
    "user": ("str", "dev", ("pattern", RE_USER)),
    "workspace": ("str", "/app", ("pattern", RE_WORKSPACE)),
    "flavour": ("str", REQUIRED, ("enum", FLAVOURS)),
    "image_tag": ("str", None, ("pattern", RE_TAG)),  # interface 1 only; ignored since v0.2.0
    "base_image": ("str", None, ("pattern", RE_IMAGE_PIN)),  # None -> the flavour's pinned image
    "ssh_port": ("port_or_spec", 0, ("port_or_zero", None)),
    "bind": ("str", "127.0.0.1", ("pattern", RE_IPV4)),
    "ports": ("port_map", {}, ("pattern", RE_PORT_NAME)),
    # v0.3.3, all optional and additive (absent: v0.3.2's render).
    "build.context": ("str", None, ("pattern", RE_BUILD_CONTEXT)),
    # A Dockerfile shared by several services, relative to the repository root;
    # dck's managed blocks and its dck/ directory go next to it.
    "build.dockerfile": ("str", None, ("pattern", r"^(?!.*(^|/)\.\.(/|$))[A-Za-z0-9._-][A-Za-z0-9._/-]*Dockerfile[A-Za-z0-9._-]*$")),
    "compose.project": ("str", None, ("pattern", RE_COMPOSE_PROJECT)),
    "compose.networks": ("host_list", [], ("pattern", RE_NETWORK_NAME)),
    # Extra compose-managed volumes declared with their exact names (other
    # services' data volumes keep reattaching: <project>_<name>).
    "compose.volumes": ("volume_list", [], ("pattern", RE_VOLUME)),
    "agents.presets": ("preset_list", None, ("enum", AK_PRESETS)),
    # The agents' own Node (/opt/dck/node) first on PATH, for a repository whose
    # own tooling needs that Node too. Off: the image's node stays first.
    "agents.node_first": ("bool", False, None),
    "layers.agents": ("bool", False, None),
    "layers.dailybot": ("bool", False, None),
    "layers.editor": ("bool", True, None),
    "agents.clis": ("kind_list", [], ("enum", AGENT_KINDS)),
    # The CLIs the image is WIRED for (v0.3.6): their home volumes, host-profile
    # sharing and default_profile, installed or not. Unset (the default): clis —
    # wire and install what onboarding chose. "all" or a list (advanced): each
    # developer chooses what to install within it (DCK_AGENT_CLIS,
    # INSTALL_<CLI>_CLI, the host profile), defaulting to clis.
    "agents.supported": ("kinds_or_all", None, ("enum", AGENT_KINDS)),
    "herdr.machine": ("bool", False, None),
    "ssh_agent": ("bool", True, None),
    "ssh_host_config": ("bool", True, None),
    # false: `dck init` neither creates nor touches dev.sh (a repository with its own).
    "dev_sh": ("bool", True, None),
    "herdr.layout": ("str", "standard", ("enum", ("standard", "none"))),
    "herdr.mesh": ("bool", True, None),
    "herdr.label": ("label", "{repo}", ("placeholders", LABEL_PLACEHOLDERS)),
    # The named volume of this service's state (sshd host key, ~/.ssh, gh auth,
    # Herdr client state, history). "state" keeps every existing install's volume;
    # repositories sharing one compose project each need their own name.
    "compose.state_volume": ("str", "state", ("pattern", RE_VOLUME)),
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
    # Hosts beyond the git services whose ~/.ssh/config aliases dck copies into
    # containers. A host preference, never a repository's: a cloned repository
    # must not be able to ask for your server aliases.
    "ssh.host_extra": ("host_list", [], ("pattern", r"^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$")),
    # Extra PUBLIC keys authorized in every container's dck block (for example
    # the keys non-dck containers log in with). Host profile only.
    "ssh.authorized_extra": ("pubkey_list", [], None),
    # Copy the host's ~/.ssh/id_* keys (private ones too) into every container's
    # ~/.ssh at each start, for tools that only offer key files (gh auth login).
    # Private keys at rest in the state volume: off by default, host profile only.
    "ssh.copy_keys": ("bool", False, None),
    # The host as a mesh peer (docs/herdr.md). [host] machine wins over the
    # older top-level host_machine, which stays as its alias.
    "host.machine": ("bool", None, None),
    "host.listener": ("str", "dck", ("enum", HOST_LISTENERS)),
    "host.port": ("int", 0, ("port_or_zero", None)),
    "host.host_key": ("path", "", None),
    "host.label": ("label", "host", ("placeholders", LABEL_PLACEHOLDERS)),
    # The mesh also pushes the host's other loopback Herdr machines.
    "mesh.external": ("bool", True, None),
    # The host's agent accounts inside containers (docs/config.md): the ak
    # profiles of the CLIs a repository installs, the host's Codex home and an
    # env file of explicitly named variables. Host profile only — a repository cannot ask for
    # your credentials.
    "agents.host_profiles": ("bool", False, None),
    "agents.host_env_keys": ("env_name_list", [], ("pattern", RE_ENV_NAME)),
    "agents.host_profile_names": ("profile_ref_list", [], ("pattern", RE_PROFILE_REF)),
    # The account a bare `ak <cli>` uses inside: { claude = "@work3" }, exported as
    # AGENTKIT_DEFAULT_PROFILE_<CLI> (coding-agents-kit v0.5.2+). Host profile only.
    "agents.default_profile": ("default_profile_map", {}, ("pattern", RE_DEFAULT_PROFILE)),
    # The coding-agent CLIs YOU want in every repository's image (v0.3.6): clis
    # replaces the repository's [agents] clis, clis_extra adds to it (or to your
    # clis). Exported as DCK_AGENT_CLIS by dck up / rebuild; the environment wins.
    "agents.clis": ("kind_list", None, ("enum", AGENT_KINDS)),
    "agents.clis_extra": ("kind_list", [], ("enum", AGENT_KINDS)),
}
TABLES = {"repo": ("layers", "agents", "herdr", "ssh", "compose", "build"), "profile": ("labels", "ssh", "host", "mesh", "agents")}
# Keys only the host profile may set; in a repository's dck.toml they are ignored.
HOST_ONLY_REPO_KEYS = ("agents.host_profiles", "agents.host_env_keys", "agents.host_profile_names",
                       "agents.default_profile", "agents.clis_extra",
                       "ssh.copy_keys")

# Where each listener kind listens and which public host key pins it.
LISTENER_DEFAULT_PORT = {"dck": 22033, "remote-login": 22, "external": 0}
LISTENER_DEFAULT_KEY = {"dck": "~/.config/dck/host-listener/ssh_host_ed25519_key.pub",
                        "remote-login": "/etc/ssh/ssh_host_ed25519_key.pub", "external": ""}


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
    elif kind == "port_or_spec":
        if isinstance(value, str):
            if not re.match(r"^%s$" % _PORT_ATOM, value) or value == "0":
                return bad("invalid ssh_port %r (a number, or the host port as a compose expression such as "
                           "\"${SSH_PORT:-22540}\"; the container port is always 22)" % value)
            return None
        if isinstance(value, bool) or not isinstance(value, int):
            return bad("expected an integer or a compose port expression, got %s" % _type_name(value))
        if not (value == 0 or 1024 <= value <= 65535):
            return bad("expected 0 (no sshd) or a port in 1024-65535, got %s" % value)
    elif kind == "volume_list":
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            return bad("expected an array of volume names, got %s" % _type_name(value))
        for item in value:
            if not re.match(carg, item):
                bad("invalid volume name %r (must match %s)" % (item, carg))
        if len(set(value)) != len(value):
            bad("duplicate entries")
        if len(value) > 64:
            bad("at most 64 volumes")
    elif kind == "default_profile_map":
        if not isinstance(value, dict):
            return bad("expected a table of cli = \"@profile\", got %s" % _type_name(value))
        for cli, prof in value.items():
            if cli not in DEFAULT_PROFILE_CLIS:
                bad("unknown cli %r (one of: %s)" % (cli, ", ".join(DEFAULT_PROFILE_CLIS)))
            elif not isinstance(prof, str) or not re.match(carg, prof):
                bad("%s: invalid profile %r (\"@<name>\", e.g. \"@work3\")" % (cli, prof))
    elif kind == "preset_list":
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            return bad("expected an array of preset names, got %s" % _type_name(value))
        for item in value:
            if item not in carg:
                bad("unknown preset %r (one of: %s)" % (item, ", ".join(carg)))
        if len(set(value)) != len(value):
            bad("duplicate entries")
    elif kind == "port_map":
        if not isinstance(value, dict):
            return bad("expected a table of name = port, got %s" % _type_name(value))
        seen = {}
        for name, port in value.items():
            if not re.match(carg, name):
                bad("invalid port name %r (must match %s)" % (name, carg))
            elif isinstance(port, str):
                if not re.match(RE_PORT_SPEC, port):
                    bad("%s: invalid port string %r (\"HOST:CONTAINER\", each a number or ${VAR:-default}, "
                        "optionally after a host IP: \"${WEB_PORT:-8000}:8000\", \"5001:3000\")" % (name, port))
                elif not re.search(r":%s(/(tcp|udp))?$" % _PORT_ATOM, port) and not re.match(r"^\d{1,5}$", port):
                    bad("%s: a port string needs its container port (\"HOST:CONTAINER\"), got %r" % (name, port))
                elif port in seen:
                    bad("%s: port %s is already used by %s" % (name, port, seen[port]))
                else:
                    seen[port] = name
            elif isinstance(port, bool) or not isinstance(port, int) or not 1 <= port <= 65535:
                bad("%s: expected a port number in 1-65535 or a port string, got %r" % (name, port))
            elif port in seen:
                bad("%s: port %s is already used by %s" % (name, port, seen[port]))
            else:
                seen[port] = name
    elif kind == "host_list":
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            return bad("expected an array of host names, got %s" % _type_name(value))
        for item in value:
            if not re.match(carg, item):
                bad("invalid host %r (must match %s)" % (item, carg))
        if len(value) > 64:
            bad("at most 64 hosts")
    elif kind == "pubkey_list":
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            return bad("expected an array of public key file paths, got %s" % _type_name(value))
        for item in value:
            if not item.endswith(".pub") or re.search(r"[\s\x00*?\[\]{}]", item) or "/../" in item or item.startswith("../"):
                bad("invalid public key file %r (a path ending in .pub, no whitespace, glob characters or ..)" % item)
        if len(value) > 16:
            bad("at most 16 keys")
    elif kind == "env_name_list":
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            return bad("expected an array of variable names, got %s" % _type_name(value))
        for item in value:
            if not re.match(carg, item):
                bad("invalid variable name %r (an exact name: upper-case letters, digits and _)" % item)
        if len(value) > 64:
            bad("at most 64 names")
    elif kind == "profile_ref_list":
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            return bad("expected an array of \"cli@name\" strings, got %s" % _type_name(value))
        for item in value:
            if not re.match(carg, item):
                bad("invalid profile %r (\"<cli>@<name>\", cli one of claude codex pi cline grok opencode)" % item)
        if len(value) > 64:
            bad("at most 64 profiles")
    elif kind == "kinds_or_all":
        if value != "all" and not isinstance(value, list):
            return bad("expected \"all\" or an array of strings, got %s" % _type_name(value))
        if isinstance(value, list):
            _check(key, value, ("kind_list", rule[1], rule[2]), problems)
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
        if kind == "repo" and key in HOST_ONLY_REPO_KEYS:
            warnings.append("%s: %s is a host-profile setting (~/.config/dck/profile.toml); "
                            "a repository cannot set it — ignored" % (path, key))
        elif key not in rules:
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
        if effective["agents.node_first"] and not effective["layers.agents"]:
            warnings.append("%s: agents.node_first is set but layers.agents is false; there is no agents' "
                            "Node to put first" % path)
        unsupported = [c for c in effective["agents.clis"]
                       if c not in supported_kinds(effective["agents.supported"], effective["agents.clis"])]
        if unsupported:
            problems.append("agents.clis: %s not in agents.supported (%s)" % (
                ", ".join(unsupported), ", ".join(supported_kinds(effective["agents.supported"])) or "none"))
        if effective["agents.clis"] and not effective["layers.agents"]:
            warnings.append("%s: agents.clis is set but layers.agents is false; no CLI will be installed" % path)
        ssh = effective["ssh_port"]
        for name, port in effective["ports"].items():
            if ssh and isinstance(ssh, int) and port == ssh:
                problems.append("ports.%s: port %s is already the ssh_port" % (name, port))
        if effective["compose.state_volume"] in AGENT_VOLUME_NAMES:
            problems.append("compose.state_volume: %r is an agents-layer volume; choose another name "
                            "(for example \"state-%s\")" % (effective["compose.state_volume"], effective["service"]))
        if effective["herdr.machine"] and not ssh:
            problems.append("herdr.machine: a Herdr machine needs sshd; set ssh_port to a port in 1024-65535")
        if effective["interface"] == 1:
            warnings.append("%s: interface 1 is read for migration only; `dck init` rewrites it as "
                            "interface 2" % path)
        if effective["image_tag"] is not None:
            warnings.append("%s: image_tag is ignored since devcontainer-kit v0.2.0 (no shared base "
                            "image); `dck init` removes it" % path)
    if kind == "profile" and not problems and effective["host.listener"] == "external":
        if not effective["host.port"]:
            problems.append("host.port: listener = \"external\" needs the port of your existing listener")
        if not effective["host.host_key"]:
            problems.append("host.host_key: listener = \"external\" needs the path of its public host key")
    if problems:
        raise ConfigError(path, problems)
    return effective, warnings


def host_settings(prof, env=None):
    """The resolved host-peer settings of a validated profile."""
    env = os.environ if env is None else env
    listener = prof["host.listener"]
    machine = prof["host.machine"] if prof["host.machine"] is not None else prof["host_machine"]
    return {
        "host_machine": bool(machine),
        "host_listener": listener,
        "host_port": prof["host.port"] or LISTENER_DEFAULT_PORT[listener],
        "host_key": expand_home(prof["host.host_key"] or LISTENER_DEFAULT_KEY[listener], env),
        "host_label": prof["host.label"],
        "host_configured": prof["host.machine"] is not None or "host_machine_set" in prof,
        "mesh_external": prof["mesh.external"],
        "ssh_authorized_extra": [expand_home(p, env) for p in prof["ssh.authorized_extra"]],
    }


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
    raw = parse_file(path)
    effective, warnings = validate(raw, "profile", path)
    effective["_source"] = path
    if "host_machine" in raw:
        effective["host_machine_set"] = True
    return effective, warnings


def profile_copy_keys(name=None, env=None):
    """[ssh] copy_keys as the profile spells it: "true", "false" or "unset"."""
    path, _ = profile_path(name, env)
    if not os.path.exists(path):
        return "unset"
    raw = parse_file(path)
    effective, _ = validate(raw, "profile", path)
    if "copy_keys" not in (raw.get("ssh") or {}):
        return "unset"
    return "true" if effective["ssh.copy_keys"] else "false"


def record_copy_keys(value, name=None, env=None):
    """Write `copy_keys = <value>` into the profile's [ssh] table (appending the
    table when there is none). Never changes a value already set. The new text
    is parsed and validated before it replaces the file."""
    path, _ = profile_path(name, env)
    if profile_copy_keys(name, env) != "unset":
        return False
    text = ""
    if os.path.exists(path):
        if os.path.islink(path):
            raise ConfigError(path, ["refusing a symlinked profile"])
        with open(path) as fh:
            text = fh.read()
    line = "copy_keys = %s  # added by dck setup; see docs/config.md\n" % ("true" if value else "false")
    lines = text.splitlines(True)
    for i, ln in enumerate(lines):
        if re.match(r"^\s*\[ssh\]\s*(#.*)?$", ln):
            if not ln.endswith("\n"):
                lines[i] = ln + "\n"
            lines.insert(i + 1, line)
            break
    else:
        if text and not text.endswith("\n"):
            lines.append("\n")
        lines.append(("\n" if text.strip() else "") + "[ssh]\n" + line)
    new = "".join(lines)
    if tomllib is None:
        raise ConfigError(path, ["python 3.11+ is required to write TOML"])
    try:
        validate(tomllib.loads(new), "profile", path)
    except tomllib.TOMLDecodeError as exc:
        raise ConfigError(path, ["could not record copy_keys: %s" % exc])
    d = os.path.dirname(path)
    old = os.umask(0o077)
    try:
        os.makedirs(d, 0o700, exist_ok=True)
        tmp = "%s.tmp-%d" % (path, os.getpid())
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as fh:
            fh.write(new)
        os.replace(tmp, path)
    finally:
        os.umask(old)
    return True


def resolve_port(spec, dotenv=None, env=None):
    """The host port a compose port expression stands for: an integer as is;
    "${VAR:-default}" / "${VAR}" from the environment, then the compose
    directory's .env, then the default; a "HOST:CONTAINER" string's host part.
    0 when it cannot be resolved (no default, variable unset)."""
    env = os.environ if env is None else env
    if isinstance(spec, int):
        return spec
    s = str(spec or "")
    s = re.sub(r"^(\d{1,3}(\.\d{1,3}){3}|\[[0-9A-Fa-f:]+\]):", "", s)  # a leading host IP
    m = re.match(r"^\$\{([A-Za-z_][A-Za-z0-9_]*)(:?-(\d{1,5}))?\}", s)
    if m:
        name, default = m.group(1), m.group(3)
        value = env.get(name) or (dotenv or {}).get(name) or default or ""
        return int(value) if re.match(r"^\d{1,5}$", str(value)) else 0
    m = re.match(r"^(\d{1,5})", s)
    return int(m.group(1)) if m else 0


def read_dotenv(path):
    """KEY=VALUE pairs of a compose .env (quotes stripped); {} when missing or a link."""
    out = {}
    if not os.path.isfile(path) or os.path.islink(path):
        return out
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    out[k.strip().replace("export ", "", 1).strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return out


def parse_clis(text, where):
    """A DCK_AGENT_CLIS value ("grok opencode" or "grok,opencode") as a list of
    known kinds; ConfigError naming the kinds when one is unknown."""
    names = [n for n in str(text).replace(",", " ").split() if n]
    bad = [n for n in names if n not in AGENT_KINDS]
    if bad:
        raise ConfigError(where, ["unknown coding-agent CLI%s %s (one of: %s)" % (
            "s" if len(bad) > 1 else "", ", ".join(repr(b) for b in bad), ", ".join(AGENT_KINDS))])
    out = []
    for n in names:
        if n not in out:
            out.append(n)
    return out


def supported_kinds(value, clis=()):
    """[agents] supported as a list of kinds, in ak's order: "all" is every kind ak
    knows; unset (None) is the default mode, the repository's clis."""
    if value is None:
        value = list(clis)
    return list(AGENT_KINDS) if value == "all" else [k for k in AGENT_KINDS if k in value]


def install_var(kind):
    return "INSTALL_%s_CLI" % kind.upper()


def effective_clis(repo_clis, supported, prof, env=None, dotenv=None, dotenv_path="docker/local/.env"):
    """The CLIs this developer's image installs, and where the list comes from.
    The list: DCK_AGENT_CLIS in the environment, then in the compose directory's
    .env, then the host profile ([agents] clis replaces, clis_extra adds), then
    dck.toml's clis. Added to it: every kind whose INSTALL_<CLI>_CLI is exactly
    "true" (the environment, then .env). An empty DCK_AGENT_CLIS counts as unset
    (compose's ${VAR:-default} does too). Every kind must be supported."""
    env = os.environ if env is None else env
    dotenv = dotenv or {}
    if (env.get("DCK_AGENT_CLIS") or "").strip():
        out, sources = parse_clis(env["DCK_AGENT_CLIS"], "DCK_AGENT_CLIS (environment)"), ["env"]
    elif (dotenv.get("DCK_AGENT_CLIS") or "").strip():
        out, sources = parse_clis(dotenv["DCK_AGENT_CLIS"], "DCK_AGENT_CLIS (%s)" % dotenv_path), ["env (%s)" % dotenv_path]
    else:
        out, sources = list(repo_clis), ["repo"]
        if prof.get("agents.clis") is not None:
            out, sources = list(prof["agents.clis"]), ["profile"]
        extra = [c for c in prof.get("agents.clis_extra") or [] if c not in out]
        if extra:
            out += extra
            if sources != ["profile"]:
                sources.append("profile")
    from_env, from_dotenv = [], []
    for kind in AGENT_KINDS:
        name = install_var(kind)
        value = env[name] if name in env else dotenv.get(name)
        if value == "true":
            (from_env if name in env else from_dotenv).append(kind)
            if kind not in out:
                out.append(kind)
    if from_env:
        sources.append("INSTALL_* (env)")
    if from_dotenv:
        sources.append("INSTALL_* (%s)" % dotenv_path)
    allowed = supported_kinds(supported, repo_clis)
    bad = [c for c in out if c not in allowed]
    if bad:
        if supported is None:
            hint = ("this repository wires only the CLIs chosen at onboarding (dck.toml [agents] clis); to let each "
                    "developer choose, set [agents] supported = \"all\" in dck.toml (advanced mode, docs/config.md)")
        else:
            hint = "add %s to dck.toml's [agents] supported, or do not request %s" % (
                "it" if len(bad) == 1 else "them", "it" if len(bad) == 1 else "them")
        raise ConfigError(" + ".join(sources), ["%s not in [agents] supported (%s): %s" % (
            ", ".join(bad), ", ".join(allowed) or "none", hint)])
    return out, " + ".join(sources)


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
        "ssh_identity": expand_home(prof["ssh.identity"], env),
        "ssh_host_extra": list(prof["ssh.host_extra"]),
        "host_profiles": bool(prof["agents.host_profiles"]),
        "host_env_keys": list(prof["agents.host_env_keys"]),
        "host_profile_names": list(prof["agents.host_profile_names"]),
        "default_profile": dict((k, "@" + v.lstrip("@")) for k, v in prof["agents.default_profile"].items()),
        "ssh_copy_keys": bool(prof["ssh.copy_keys"]),
    })
    merged.update(host_settings(prof, env))
    # Port strings (v0.3.3) resolve to the host port dck dials (dck ssh, Herdr, doctor).
    dotenv = read_dotenv(os.path.join(repo, "docker", "local", ".env"))
    merged["ssh_port_spec"] = cfg["ssh_port"]
    merged["ssh_port"] = resolve_port(cfg["ssh_port"], dotenv, env)
    # The CLIs this developer's image gets (v0.3.6); agents.clis stays the repository's.
    if cfg["layers.agents"]:
        merged["clis_effective"], merged["clis_source"] = effective_clis(
            cfg["agents.clis"], cfg["agents.supported"], prof, env, dotenv)
        merged["clis_supported"] = supported_kinds(cfg["agents.supported"], cfg["agents.clis"])
    else:
        merged["clis_effective"], merged["clis_source"], merged["clis_supported"] = [], "repo", []
    merged["herdr.label"] = expand_label(label_fmt, {
        "repo": repo_name, "service": cfg["service"], "user": cfg["user"],
        "project": prof["compose_project_prefix"] + rslug})
    return merged, warn_repo + warn_prof
