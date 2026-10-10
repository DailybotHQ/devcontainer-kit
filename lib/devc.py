"""Read a repository's devcontainer.json for the launcher, and write the
compose overlay that reproduces its `mounts` / `containerEnv`.

Ported from the deepworkplan-website dev.sh launcher (the most complete of
the hand-copied launchers): devcontainer.json is the single source of truth.
`runServices` decides what starts; `remoteUser` and `workspaceFolder` decide
how the main service is entered. dck.toml, when present, adds the host-side
settings (ssh port, Herdr machine, alias).
"""

import json
import os
import re

import config
import jsonc

_SAFE_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


class DevcError(Exception):
    pass


def find_repo(start):
    """The nearest ancestor of `start` holding .devcontainer/devcontainer.json
    (or .devcontainer/dck.toml)."""
    d = os.path.abspath(start)
    while True:
        dc = os.path.join(d, ".devcontainer")
        if os.path.isfile(os.path.join(dc, "devcontainer.json")) or os.path.isfile(os.path.join(dc, "dck.toml")):
            return d
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def devcontainer_path(repo):
    return os.path.join(repo, ".devcontainer", "devcontainer.json")


def read(repo):
    path = devcontainer_path(repo)
    if os.path.islink(path):
        raise DevcError("refusing a symlinked %s" % path)
    if not os.path.isfile(path):
        raise DevcError("no .devcontainer/devcontainer.json in %s — run: dck init" % repo)
    try:
        data = jsonc.load(path)
    except (ValueError, OSError) as exc:
        raise DevcError("cannot parse %s: %s" % (path, exc))
    if not isinstance(data, dict):
        raise DevcError("%s is not a JSON object" % path)
    cf = data.get("dockerComposeFile")
    if isinstance(cf, str):
        cf = [cf]
    cf = [c for c in (cf or []) if isinstance(c, str)]
    if not cf:
        raise DevcError("%s declares no dockerComposeFile (dck drives compose-based dev containers)" % path)
    base = os.path.dirname(path)
    files = [os.path.normpath(os.path.join(base, c)) for c in cf]
    for f in files:
        if os.path.islink(f):
            raise DevcError("refusing a symlinked compose file: %s" % f)
        if not os.path.isfile(f):
            raise DevcError("compose file not found: %s" % f)
    service = data.get("service") or ""
    if not isinstance(service, str) or not service:
        raise DevcError("%s declares no service" % path)
    # runServices is what the editor plugin starts. Without it, only the main
    # service — never "every service in the compose file".
    run = data.get("runServices") or [service]
    if not isinstance(run, list) or not all(isinstance(s, str) and s for s in run):
        raise DevcError("%s: runServices must be a list of service names" % path)
    project = None
    m = re.search(r"^name:\s*['\"]?([A-Za-z0-9_.-]+)['\"]?\s*(#.*)?$", open(files[0]).read(), re.M)
    if m:
        project = m.group(1)
    return {
        "file": path,
        "compose_files": files,
        "service": service,
        "run_services": run,
        "user": data.get("remoteUser") or "",
        "workspace": data.get("workspaceFolder") or "",
        "shutdown": data.get("shutdownAction") or "",
        "mounts": data.get("mounts") or [],
        "container_env": data.get("containerEnv") or {},
        "compose_name": project or "",
    }


def env_lines(repo, dck_tag, profile=None):
    """KEY=VALUE lines for bash (never eval'd). Values are single-line by
    construction (validated config; paths without newlines are refused)."""
    info = read(repo)
    out = [("DC_REPO", repo), ("DC_FILE", info["file"])]
    out += [("DC_COMPOSE_FILE", f) for f in info["compose_files"]]
    out += [("DC_SERVICE", info["service"]), ("DC_RUNSERVICES", " ".join(info["run_services"])),
            ("DC_USER", info["user"]), ("DC_WORKSPACE", info["workspace"]),
            ("DC_SHUTDOWN", info["shutdown"]), ("DC_MOUNTS", str(len(info["mounts"]))),
            ("DC_ENVS", str(len(info["container_env"]))), ("DC_COMPOSE_NAME", info["compose_name"])]
    if os.path.isfile(config.repo_config_path(repo)):
        merged, warnings = config.effective(repo, dck_tag, profile)
        out += [("DCK_HAS_TOML", "1"),
                ("DCK_SSH_PORT", str(merged["ssh_port"])),
                ("DCK_BIND", merged["bind"]),
                ("DCK_ALIAS", merged["alias"]),
                ("DCK_SSH_IDENTITY", merged["ssh_identity"]),
                ("DCK_HERDR_MACHINE", "1" if merged["herdr.machine"] else "0"),
                ("DCK_HOST_MACHINE", "1" if merged.get("host_machine") else "0"),
                ("DCK_HERDR_LAYOUT", merged["herdr.layout"]),
                ("DCK_HERDR_MESH", "1" if merged["herdr.mesh"] else "0"),
                ("DCK_SSH_AGENT", "1" if merged["ssh_agent"] else "0"),
                ("DCK_SSH_HOST_CONFIG", "1" if merged["ssh_host_config"] else "0"),
                ("DCK_SSH_HOST_EXTRA", " ".join(merged["ssh_host_extra"])),
                ("DCK_HERDR_LABEL", merged["herdr.label"]),
                ("DCK_NETWORK", merged["network"]),
                ("DCK_FLAVOUR", merged["flavour"]),
                ("DCK_PORTS", " ".join("%s=%s" % kv for kv in sorted(merged["ports"].items()))),
                ("DCK_TOML_USER", merged["user"])]
    else:
        warnings = []
        prof, warnings = config.load_profile(profile)
        out += [("DCK_HAS_TOML", "0"), ("DCK_SSH_IDENTITY", config.expand_home(prof["ssh.identity"], os.environ))]
    for k, v in out:
        if "\n" in v or "\r" in v:
            raise DevcError("refusing a multi-line value for %s" % k)
    return out, warnings


def _parse_mount(m):
    if isinstance(m, dict):
        return dict(m)
    if not isinstance(m, str):
        return {}
    return dict(p.split("=", 1) for p in m.split(",") if "=" in p)


def write_overlay(repo, project, out_path):
    """Compose overlay with devcontainer.json's mounts and containerEnv for the
    main service. The editor plugin injects these through its own generated
    overlay; plain compose would silently omit them. Returns False when there
    is nothing to reproduce (and writes nothing)."""
    info = read(repo)
    mounts, env = info["mounts"], info["container_env"]
    if not mounts and not env:
        return False
    binds, vols, decls, order = [], [], {}, []
    for raw in mounts:
        m = _parse_mount(raw)
        source, target = m.get("source"), m.get("target")
        if not source or not target:
            continue
        suffix = ":ro" if str(m.get("readonly", "")).lower() in ("true", "1") else ""
        if any(ord(c) < 32 for c in str(source) + str(target)) or not str(target).startswith("/"):
            raise DevcError("mounts: invalid source/target %r -> %r" % (source, target))
        if m.get("type") == "bind":
            binds.append("      - %s" % json.dumps(("%s:%s%s" % (source, target, suffix)).replace("$", "$$")))
        elif m.get("type") == "volume":
            if not re.match(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$", str(source)):
                raise DevcError("mounts: invalid volume name %r" % source)
            # Already-qualified sources (<project>_x) are external by name, so
            # compose does not prefix them twice into a second, empty volume.
            if source not in decls:
                order.append(source)
                decls[source] = source if source.startswith(project + "_") else None
            vols.append("      - %s" % json.dumps("%s:%s%s" % (source, target, suffix)))
    lines = ["# Generated by dck from %s — do not edit." % os.path.relpath(info["file"], repo),
             "# Reproduces the devcontainer mounts/containerEnv that plain compose omits.",
             "services:", "  %s:" % info["service"]]
    if env:
        lines.append("    environment:")
        for k, v in env.items():
            if not _SAFE_KEY.match(str(k)):
                raise DevcError("containerEnv: invalid variable name %r" % k)
            # $$ keeps compose from interpolating host variables into the value.
            lines.append("      %s: %s" % (k, json.dumps(str(v).replace("$", "$$"))))
    if binds or vols:
        lines.append("    volumes:")
        lines.extend(binds + vols)
    if order:
        lines.append("volumes:")
        for short in order:
            if decls[short] is None:
                lines.append("  %s: {}" % short)
            else:
                lines += ["  %s:" % short, "    external: true", "    name: %s" % decls[short]]
    tmp = "%s.tmp-%d" % (out_path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    os.replace(tmp, out_path)
    return True


RISKY_COMPOSE = (
    (r"^\s*privileged:\s*(true|yes|on)\b", "privileged: true"),
    (r"^\s*cap_add:", "cap_add"),
    (r"docker\.sock", "the Docker socket"),
    (r"^\s*(network_mode|pid|ipc|userns_mode|uts):\s*['\"]?host", "a host namespace"),
    (r"^\s*security_opt:", "security_opt"),
    (r"^\s*devices:", "host devices"),
)


# The one host path a dck-rendered compose file binds: the host's SSH agent
# socket, chosen by dck itself (export_host_ssh_agent always exports the
# variable, so a repository's .env cannot redirect it; preflight flags one that tries).
AGENT_SOCK_SOURCE = "${DCK_HOST_SSH_AUTH_SOCK:-/run/host-services/ssh-auth.sock}"


def _host_paths(text):
    """Host-side sources of bind mounts (short and long syntax), best effort."""
    out = []
    for m in re.finditer(r"^\s*-\s*['\"]?([^'\":\s][^:'\"]*):/[^\s'\"]*", text, re.M):
        out.append(m.group(1))
    for m in re.finditer(r"^\s*source:\s*['\"]?([^'\"\s]+)", text, re.M):
        out.append(m.group(1))
    return [p for p in out if p.startswith(("/", ".", "~", "$"))]


def preflight(repo):
    """Features of the repository's own configuration that act on the HOST
    when dck starts it (devcontainer.json / compose). dck-rendered setups have
    none; anything listed needs the user's explicit --trust."""
    root = os.path.realpath(repo)
    info = read(repo)
    data = jsonc.load(info["file"])
    found = []
    # The agent socket bind is dck's own only while dck.toml asks for it.
    agent_ok = False
    if os.path.isfile(config.repo_config_path(repo)):
        try:
            agent_ok = bool(config.effective(repo, None, None)[0]["ssh_agent"])
        except Exception:  # an invalid dck.toml fails later, with its own message
            agent_ok = False
    for key in ("initializeCommand",):
        if data.get(key):
            found.append("%s (runs on the host with the devcontainer CLI)" % key)
    for raw in info["mounts"]:
        m = _parse_mount(raw)
        if m.get("type") != "bind":
            continue
        src = str(m.get("source", ""))
        p = os.path.realpath(os.path.join(repo, src)) if not src.startswith(("~", "$")) else src
        if p.startswith(("~", "$")) or (p != root and not p.startswith(root + os.sep)):
            found.append("devcontainer.json mounts: a host path outside the repository (%s)" % src)
    for f in info["compose_files"]:
        real = os.path.realpath(f)
        rel = os.path.relpath(f, repo)
        if real != root and not real.startswith(root + os.sep):
            found.append("%s: the compose file is outside the repository" % rel)
            continue
        text = open(f).read()
        for pattern, label in RISKY_COMPOSE:
            if re.search(pattern, text, re.M):
                found.append("%s: %s" % (rel, label))
        base = os.path.dirname(real)
        env_file = os.path.join(base, ".env")
        if os.path.isfile(env_file) and not os.path.islink(env_file):
            with open(env_file, errors="replace") as fh:
                if any(re.match(r"^\s*(export\s+)?DCK_HOST_SSH_AUTH_SOCK\s*[=:]", ln) for ln in fh):
                    found.append("%s: sets DCK_HOST_SSH_AUTH_SOCK (the host path mounted as the SSH agent)"
                                 % os.path.relpath(env_file, repo))
        for src in _host_paths(text):
            if src == AGENT_SOCK_SOURCE and agent_ok:
                continue
            if src.startswith(("~", "$")):
                found.append("%s: mounts a host path (%s)" % (rel, src))
                continue
            p = os.path.realpath(os.path.join(base, src))
            if p != root and not p.startswith(root + os.sep):
                found.append("%s: mounts a host path outside the repository (%s)" % (rel, src))
    return found


def env_examples(compose_dir, repo):
    """The .env*.example files under compose_dir that dck may act on: regular
    files (no symlink anywhere on the way), inside the repository, names
    without control characters."""
    root = os.path.realpath(repo)
    out = []
    for dirpath, dirnames, files in os.walk(compose_dir, followlinks=False):
        dirnames[:] = sorted(d for d in dirnames if not os.path.islink(os.path.join(dirpath, d)))
        for name in sorted(files):
            if not (name.startswith(".env") and name.endswith(".example")):
                continue
            path = os.path.join(dirpath, name)
            if any(ord(c) < 32 for c in path) or os.path.islink(path):
                continue
            real = os.path.realpath(path)
            if not real.startswith(root + os.sep):
                continue
            out.append(path)
    return out


def external_networks(compose_file):
    """Names of external networks declared in a compose file (simple parser,
    good for the files dck renders and the usual hand-written ones)."""
    txt = open(compose_file).read()
    m = re.search(r"^networks:\s*$", txt, re.M)
    if not m:
        return []
    body = txt[m.end():]
    end = re.search(r"^\S", body, re.M)
    body = body[:end.start()] if end else body
    if "external" not in body:
        return []
    return re.findall(r"^\s*name:\s*([A-Za-z0-9_.-]+)\s*$", body, re.M)
