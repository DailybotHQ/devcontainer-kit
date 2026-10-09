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
                ("DCK_HERDR_LABEL", merged["herdr.label"]),
                ("DCK_NETWORK", merged["network"]),
                ("DCK_FLAVOUR", merged["flavour"]),
                ("DCK_IMAGE_TAG", merged["image_tag"]),
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
        if m.get("type") == "bind":
            binds.append("      - %s:%s%s" % (json.dumps(source), target, suffix))
        elif m.get("type") == "volume":
            # Already-qualified sources (<project>_x) are external by name, so
            # compose does not prefix them twice into a second, empty volume.
            if source not in decls:
                order.append(source)
                decls[source] = source if source.startswith(project + "_") else None
            vols.append("      - %s:%s%s" % (source, target, suffix))
    lines = ["# Generated by dck from %s — do not edit." % os.path.relpath(info["file"], repo),
             "# Reproduces the devcontainer mounts/containerEnv that plain compose omits.",
             "services:", "  %s:" % info["service"]]
    if env:
        lines.append("    environment:")
        for k, v in env.items():
            lines.append("      %s: %s" % (k, json.dumps(str(v))))
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
