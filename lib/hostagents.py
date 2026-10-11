"""The host's agent accounts inside a container (`[agents] host_profiles`).

When the host profile turns it on, `dck up` shares with the container, through
a runtime compose overlay written outside the repository:

- the host's coding-agents-kit profiles of the CLIs the repository installs
  (`[agents] clis`), each `$AGENTKIT_PROFILES_DIR/<cli>` bound to the
  container's profiles directory, which AGENTKIT_PROFILES_DIR then names. Only
  file-portable isolations are shared; cursor (and antigravity) profiles hold
  absolute host symlinks and are skipped. The whole AGENTKIT_HOME is never
  mounted: it would shadow the ak the image pins;
- the host's Codex home (`$CODEX_HOME`, else `~/.codex`: the Codex @default
  login) when codex is installed;
- an env file generated on the host from the host's ak env file (and dck's
  own environment), holding only allow-listed names, mounted read-only with
  AGENTKIT_ENV pointing at it.

Values never leave the env file: the overlay, the logs and `dck doctor` name
variables only. Interface from coding-agents-kit v0.5.0: the Claude token per
profile is CLAUDE_CODE_OAUTH_TOKEN (@default) or CLAUDE_CODE_OAUTH_TOKEN_<SUFFIX>
(@name), and `ak profiles --json` prints schema profiles-v1.
"""

import json
import os
import re
import subprocess

import config

# Isolations whose profile directories are plain files, portable into a container.
SHAREABLE = ("claude", "codex", "pi", "cline", "grok", "opencode")
NOT_PORTABLE = {
    "cursor": "its profiles hold absolute host symlinks (a HOME of their own)",
    "antigravity": "its profiles hold absolute host symlinks (a HOME of their own)",
}
DEFAULT_ENV_KEYS = ("CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN_*")
PROFILES_SCHEMA = "profiles-v1"
_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class HostAgentsError(Exception):
    pass


def profiles_dir(env):
    return env.get("AGENTKIT_PROFILES_DIR") or os.path.join(
        env.get("HOME", ""), ".local", "share", "agentkit", "profiles")


def codex_home(env):
    return env.get("CODEX_HOME") or os.path.join(env.get("HOME", ""), ".codex")


def ak_env_path(env):
    return env.get("AGENTKIT_ENV") or os.path.join(env.get("HOME", ""), ".config", "agentkit", "env")


def env_file_path(project, env=None):
    """Where the allow-listed env file of one compose project lives on the host."""
    env = os.environ if env is None else env
    if not re.match(r"^[a-z0-9][a-z0-9_-]*$", project or ""):
        raise HostAgentsError("invalid compose project name %r" % project)
    return os.path.join(config.config_home(env), "agents", "%s.env" % project)


def allowed(name, patterns):
    for p in patterns:
        if p.endswith("*"):
            if name.startswith(p[:-1]) and len(name) > len(p) - 1:
                return True
        elif name == p:
            return True
    return False


def read_env_file(path):
    """The KEY=value subset of an ak env file (`export` allowed, values in
    quotes or bare, # comments), as coding-agents-kit reads it without a
    shell. Nothing is expanded or executed; shell code is ignored."""
    try:
        with open(path) as fh:
            lines = fh.read().splitlines()
    except OSError:
        return {}
    out = {}
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        name, sep, value = line.partition("=")
        name = name.strip()
        if not sep or not _NAME.match(name):
            continue
        value = value.strip()
        if value[:1] in ("'", '"') and value[0] in value[1:]:
            value = value[1:value.index(value[0], 1)]
        elif value[:1] in ("'", '"'):
            continue  # an unterminated quote is shell, not data
        elif " #" in value:
            value = value.split(" #", 1)[0].rstrip()
        if "$" in value or "`" in value:
            continue  # an expansion: shell code, not plain data
        out[name] = value
    return out


def _plain(value):
    return not any(c in value for c in ("'", "\n", "\r", "\x00"))


def container_home(user):
    return "/root" if user == "root" else "/home/%s" % user


def plan(merged, env=None):
    """What `dck up` would share. Pure apart from reading the host's files.
    The returned "values" entry holds secret values: never print it."""
    env = os.environ if env is None else env
    home = container_home(merged["user"])
    base = home + "/.dck/host"
    out = {"enabled": False, "reason": "", "shared": [], "skipped": [], "codex": None,
           "env_names": [], "env_skipped": [], "values": {}, "profiles_root": profiles_dir(env),
           "ak_env": ak_env_path(env), "container_profiles": base + "/agentkit/profiles",
           "container_env": base + "/agentkit/env", "container_codex": base + "/codex"}
    if not merged.get("host_profiles"):
        out["reason"] = "off ([agents] host_profiles in the host profile)"
        return out
    if not merged.get("layers.agents"):
        out["reason"] = "host_profiles is on, but this repository's layers.agents is false"
        return out
    out["enabled"] = True
    root = out["profiles_root"]
    for cli in merged.get("agents.clis") or []:
        if cli in NOT_PORTABLE:
            out["skipped"].append((cli, NOT_PORTABLE[cli]))
            continue
        if cli not in SHAREABLE:
            out["skipped"].append((cli, "not a shareable kind"))
            continue
        src = os.path.join(root, cli)
        if os.path.isdir(src):
            out["shared"].append({"cli": cli, "source": os.path.realpath(src),
                                  "target": "%s/%s" % (out["container_profiles"], cli)})
        else:
            out["skipped"].append((cli, "no host profiles in %s" % src))
    if "codex" in (merged.get("agents.clis") or []):
        ch = codex_home(env)
        if os.path.isdir(ch):
            out["codex"] = {"source": os.path.realpath(ch), "target": out["container_codex"]}
    patterns = list(DEFAULT_ENV_KEYS) + list(merged.get("host_env_keys") or [])
    values = {}
    for name, value in env.items():
        if _NAME.match(name) and allowed(name, patterns):
            values[name] = value
    values.update({k: v for k, v in read_env_file(out["ak_env"]).items() if allowed(k, patterns)})
    for name in sorted(values):
        if not values[name]:
            out["env_skipped"].append((name, "empty"))
        elif not _plain(values[name]):
            out["env_skipped"].append((name, "not a single-line value without quotes"))
        else:
            out["values"][name] = values[name]
            out["env_names"].append(name)
    return out


def _write_private(path, text):
    d = os.path.dirname(path)
    old = os.umask(0o077)
    try:
        os.makedirs(d, 0o700, exist_ok=True)
    finally:
        os.umask(old)
    if os.path.islink(d) or not os.path.isdir(d) or os.stat(d).st_uid != os.getuid():
        raise HostAgentsError("%s is not a directory you own; refusing to write there" % d)
    os.chmod(d, 0o700)
    tmp = "%s.tmp-%d" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write(text)
    os.replace(tmp, path)


def _remove(path):
    try:
        if os.path.islink(path) or os.path.isfile(path):
            os.unlink(path)
    except OSError:
        pass


def _bind(source, target, read_only):
    lines = ["      - type: bind",
             "        source: %s" % json.dumps(source.replace("$", "$$")),
             "        target: %s" % json.dumps(target)]
    if read_only:
        lines.append("        read_only: true")
    lines += ["        bind:", "          create_host_path: false"]
    return lines


def write(merged, service, project, out_path, env=None):
    """Write (or remove) the runtime overlay and the env file. Returns the plan
    without its values."""
    env = os.environ if env is None else env
    p = plan(merged, env)
    env_path = env_file_path(project, env)
    values = p.pop("values")
    if not p["enabled"] or not (p["shared"] or p["codex"] or p["env_names"]):
        _remove(out_path)
        _remove(env_path)
        return p
    if any(ord(c) < 32 for c in service) or not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", service):
        raise HostAgentsError("invalid service name %r" % service)
    for item in p["shared"] + ([p["codex"]] if p["codex"] else []):
        if any(ord(c) < 32 for c in item["source"]):
            raise HostAgentsError("refusing a host path with control characters")
    environment, volumes = [], []
    if p["shared"]:
        environment.append(("AGENTKIT_PROFILES_DIR", p["container_profiles"]))
        environment.append(("DCK_HOST_PROFILES", " ".join(s["cli"] for s in p["shared"])))
        for s in p["shared"]:
            volumes += _bind(s["source"], s["target"], False)
    if p["codex"]:
        environment.append(("DCK_HOST_CODEX", p["codex"]["target"]))
        volumes += _bind(p["codex"]["source"], p["codex"]["target"], False)
    if p["env_names"]:
        _write_private(env_path, "# Generated by dck from the host's ak env file — do not edit.\n"
                       "# Only the names allowed by [agents] host_env_keys (and Claude's tokens).\n"
                       + "".join("%s='%s'\n" % (k, values[k]) for k in p["env_names"]))
        environment.append(("AGENTKIT_ENV", p["container_env"]))
        volumes += _bind(env_path, p["container_env"], True)
    else:
        _remove(env_path)
    lines = ["# Generated by dck at runtime for [agents] host_profiles — never written into",
             "# the repository. Names host paths only; no value is in this file.",
             "services:", "  %s:" % service, "    environment:"]
    lines += ["      %s: %s" % (k, json.dumps(v)) for k, v in environment]
    lines.append("    volumes:")
    lines += volumes
    _write_private(out_path, "\n".join(lines) + "\n")
    return p


def ak_profiles(env=None, timeout=10):
    """`ak profiles --json` (profiles-v1) from the host's ak, or None."""
    env = os.environ if env is None else env
    try:
        r = subprocess.run(["ak", "profiles", "--json"], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=timeout, text=True, env=dict(env))
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    try:
        doc = json.loads(r.stdout)
    except ValueError:
        return None
    if not isinstance(doc, dict) or doc.get("schema") != PROFILES_SCHEMA or not isinstance(doc.get("profiles"), list):
        return None
    return [x for x in doc["profiles"] if isinstance(x, dict)]


def claude_token_var(profile):
    """The token variable of a Claude profile: @default or a name."""
    if not profile or profile in ("@default", "default"):
        return "CLAUDE_CODE_OAUTH_TOKEN"
    name = profile[1:] if profile.startswith("@") else profile
    return "CLAUDE_CODE_OAUTH_TOKEN_" + re.sub(r"[^A-Z0-9_]", "_", name.upper())


def report(merged, env=None, profiles=None):
    """Doctor lines: (level, message) with names only. `profiles` is the
    profiles-v1 list (None: ask the host's ak)."""
    env = os.environ if env is None else env
    p = plan(merged, env)
    p.pop("values")
    out = []
    if not p["enabled"]:
        out.append(("info", "host profiles: %s" % p["reason"]))
        return out, p
    shared = [s["cli"] for s in p["shared"]]
    out.append(("info", "host profiles: shared for %s" % (", ".join(shared) or "no CLI")))
    if p["codex"]:
        out.append(("info", "host profiles: the host's Codex home (@default) is shared read-write"))
    for cli, why in p["skipped"]:
        out.append(("info", "host profiles: %s not shared — %s" % (cli, why)))
    out.append(("info", "host profiles: env file names: %s" % (", ".join(p["env_names"]) or "none")))
    for name, why in p["env_skipped"]:
        out.append(("warn", "host profiles: %s not copied — %s" % (name, why)))
    if profiles is None:
        profiles = ak_profiles(env)
    if profiles is None:
        out.append(("info", "host profiles: the host's `ak profiles --json` (%s) is unavailable; "
                    "logins not checked" % PROFILES_SCHEMA))
        return out, p
    names = set(p["env_names"])
    for row in profiles:
        cli, prof = row.get("cli"), str(row.get("profile") or "")
        if cli not in shared and not (cli == "codex" and p["codex"]):
            continue
        label = "%s %s" % (cli, prof or "@default")
        if cli == "claude" and row.get("login") == "keychain":
            var = claude_token_var(prof)
            if var not in names:
                out.append(("warn", "host profiles: %s logs in through the macOS keychain, which a "
                            "container cannot read; run `claude setup-token` for that account, then "
                            "store it with `ak env` as %s" % (label, var)))
                continue
        out.append(("info", "host profiles: %s (login: %s)" % (label, row.get("login") or "none")))
    return out, p
