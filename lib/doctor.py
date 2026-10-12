"""`dck doctor [--json]` — environment and repository health, interface 2.

Top-level keys (ECOSYSTEM_CONTRACT §2.3; schema docs/schema/dck-doctor-v2.json):
interface, version, runtime, repo, layers, ssh, herdr, drift — plus os,
python, profile and problems. Works anywhere: outside a repository `repo`,
`layers` and `ssh` are null. Never prints the value of an environment
variable or a file's secret content; env files are reported by path, mode
and the NAMES of the keys they set.

Every probe has a timeout and degrades to null/false with a reason instead
of failing: the doctor must answer on a machine where things are broken.
"""

import json
import os
import platform
import re
import socket
import subprocess
import sys

import config
import devc

INTERFACE = 2
TIMEOUT = 15


def run(argv, timeout=TIMEOUT):
    """(returncode, stdout) — (None, '') when the command is missing or hangs."""
    try:
        r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           stdin=subprocess.DEVNULL, timeout=timeout, text=True)
        return r.returncode, r.stdout
    except (OSError, subprocess.SubprocessError):
        return None, ""


def which(cmd):
    for d in os.environ.get("PATH", "").split(os.pathsep):
        p = os.path.join(d, cmd)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def first_version(text):
    m = re.search(r"(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.]+)?)", text or "")
    return m.group(1) if m else None


def read_env_file(path):
    out = {}
    if os.path.islink(path):
        return out
    try:
        for line in open(path).read().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def runtime_info():
    docker = {"cli": bool(which("docker")), "version": None, "daemon": False,
              "server_version": None, "reason": None}
    provider = None
    compose = {"version": None}
    if docker["cli"]:
        rc, out = run(["docker", "version", "--format", "{{.Client.Version}}"])
        docker["version"] = (out or "").strip() or None
        rc, out = run(["docker", "info", "--format", "{{.ServerVersion}}|{{.OperatingSystem}}|{{.Name}}"])
        parts = ((out or "").strip().split("|") + ["", "", ""])[:3]
        # A stuck engine can exit 0 with empty fields or its error text on
        # stdout: only a server version number proves the daemon answered.
        if rc == 0 and re.match(r"^\d+\.\d+", parts[0]):
            docker["daemon"] = True
            docker["server_version"] = parts[0] or None
            blob = (" ".join(parts[1:]) + " " + (run(["docker", "context", "show"])[1] or "")).lower()
            if "orbstack" in blob:
                provider = "orbstack"
            elif "colima" in blob:
                provider = "colima"
            elif "docker desktop" in blob or "docker-desktop" in blob or "desktop-linux" in blob:
                provider = "docker-desktop"
            elif "podman" in blob:
                provider = "podman"
            else:
                provider = "docker-engine"
        else:
            docker["reason"] = "daemon not answering" if rc is not None else "docker info timed out"
        rc, out = run(["docker", "compose", "version", "--short"])
        compose["version"] = first_version(out) if rc == 0 else None
    else:
        docker["reason"] = "docker CLI not found"
    dc = {"installed": bool(which("devcontainer")), "version": None}
    if dc["installed"]:
        dc["version"] = first_version(run(["devcontainer", "--version"])[1])
    return {"docker": docker, "provider": provider, "compose": compose, "devcontainer_cli": dc}


def port_answers(host, port, timeout=2.0):
    try:
        with socket.create_connection((host, int(port)), timeout=timeout) as s:
            s.settimeout(timeout)
            try:
                banner = s.recv(64)
            except OSError:
                banner = b""
            text = banner.decode("ascii", "replace").strip() or None
            # A TCP accept alone can be Docker's userland proxy with nothing
            # behind it yet: only an SSH banner proves sshd answers.
            return bool(text and text.startswith("SSH-")), text
    except OSError:
        return False, None


def repo_info(repo, dck_tag, profile, rt, problems, compose_files=None):
    info = {"path": repo, "devcontainer": None, "config_valid": False, "errors": [],
            "warnings": [], "flavour": None, "base_image": None, "digest_pinned": False,
            "kit_version": None, "vendored": None, "project": None,
            "service": None, "container": None, "env_files": [], "compose_files": [],
            "compose_override": bool(compose_files)}
    merged = None
    try:
        d = devc.read(repo)
        info["devcontainer"] = os.path.relpath(d["file"], repo)
        info["service"] = d["service"]
        # dck --compose-file F... (PRIMARY mode): those files, in order, instead of
        # devcontainer.json's dockerComposeFile.
        files = [os.path.abspath(f) for f in compose_files] if compose_files else list(d["compose_files"])
        info["compose_files"] = [os.path.relpath(f, repo) if f.startswith(repo + os.sep) else f for f in files]
        compose_dir = os.path.dirname(files[0])
        info["project"] = compose_project(compose_dir, d["compose_name"], toml_project(repo))
        svc_dir = os.path.join(compose_dir, d["service"] or "")
        dockerfile = os.path.join(svc_dir, "Dockerfile")
        if os.path.isfile(dockerfile) and not os.path.islink(dockerfile):
            m = re.search(r"^ARG BASE_IMAGE=(\S+)", open(dockerfile).read(), re.M)
            if m:
                info["base_image"] = m.group(1)
                info["digest_pinned"] = "@sha256:" in m.group(1)
        stamp = os.path.join(svc_dir, "dck", "VERSION")
        if os.path.isfile(stamp) and not os.path.islink(stamp):
            m = re.match(r"^devcontainer-kit (v\S+)", open(stamp).read())
            info["kit_version"] = m.group(1) if m else None
            info["vendored"] = vendored_state(os.path.join(svc_dir, "dck"))
        for root, _dirs, files in os.walk(compose_dir):
            for f in sorted(files):
                if f.startswith(".env") and f.endswith(".example"):
                    target = os.path.join(root, f[:-len(".example")])
                    if os.path.islink(target) or os.path.islink(os.path.join(root, f)):
                        problems.append("%s is a symlink; dck ignores it" % os.path.relpath(target, repo))
                        continue
                    entry = {"path": os.path.relpath(target, repo), "present": os.path.isfile(target),
                             "mode": None, "private": None, "keys_set": []}
                    if entry["present"]:
                        mode = os.stat(target).st_mode & 0o777
                        entry["mode"] = "%04o" % mode
                        entry["private"] = not (mode & 0o077)
                        entry["keys_set"] = sorted(k for k, v in read_env_file(target).items() if v)
                        if not entry["private"]:
                            problems.append("%s is readable by other accounts (dck setup narrows it)" % entry["path"])
                    else:
                        problems.append("%s is missing (dck setup creates it)" % entry["path"])
                    info["env_files"].append(entry)
    except devc.DevcError as exc:
        info["errors"].append(str(exc))
    if os.path.isfile(config.repo_config_path(repo)):
        try:
            merged, warnings = config.effective(repo, dck_tag, profile)
            info["config_valid"] = not info["errors"]
            info["warnings"] = warnings
            info["flavour"] = merged["flavour"]
            if not info["project"]:
                info["project"] = None
        except config.ConfigError as exc:
            info["errors"].extend(exc.problems)
    else:
        info["errors"].append(".devcontainer/dck.toml not found (run: dck init)")
    for e in info["errors"]:
        problems.append("repo: %s" % e)
    if info["base_image"] and not info["digest_pinned"]:
        problems.append("the Dockerfile's base image is not pinned by digest (dck init pins it)")
    if info["vendored"] == "modified":
        problems.append("docker/local/%s/dck/ differs from the devcontainer-kit files it was vendored from "
                        "(dck init restores them)" % info["service"])
    docker_ok = rt["docker"]["daemon"]
    if docker_ok and info["project"] and info["service"]:
        rc, out = run(["docker", "ps", "-a", "--filter", "label=com.docker.compose.project=%s" % info["project"],
                       "--filter", "label=com.docker.compose.service=%s" % info["service"],
                       "--format", "{{.Names}}\t{{.State}}"])
        line = (out or "").strip().splitlines()
        if line:
            name, _, state = line[0].partition("\t")
            info["container"] = {"name": name, "state": state or "unknown"}
        else:
            info["container"] = {"name": None, "state": "absent"}
    return info, merged


def vendored_state(dck_dir):
    """"current" when every vendored script equals this kit's copy, "modified"
    when one differs or is missing, None when render is unavailable."""
    try:
        import render
    except ImportError:
        return None
    for rel, content in render.vendored_files():
        path = os.path.join(dck_dir, rel)
        if os.path.islink(path) or not os.path.isfile(path) or open(path).read() != content:
            return "modified"
    return "current"


def host_peers_cli():
    """herdr-peers for `dck agents`/`dck ask`: on PATH, else dck's verified host copy."""
    p = which("herdr-peers")
    if p:
        return p
    pins = read_env_file(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "images", "versions.env"))
    tag = pins.get("HERDR_PEERS_TAG")
    if not tag:
        return None
    base = os.environ.get("XDG_DATA_HOME") or os.path.join(os.environ.get("HOME", ""), ".local", "share")
    root = os.path.join(base, "dck-host", "herdr-peers", tag)
    p = os.path.join(root, "skills", "herdr-peers", "scripts", "herdr-peers")
    ok = os.path.isfile(os.path.join(root, ".dck-verified")) and os.path.isfile(p) and os.access(p, os.X_OK)
    return p if ok else None


def catalog_info(merged, installed):
    """What `dck herdr mesh` mirrors into containers: the host's Herdr catalog
    entries they can reach (the host's own ids, needed for herdr-peers replies),
    and the host's own entry."""
    if not installed:
        return None
    rc, out = run(["herdr", "machine", "list", "--json"])
    if rc != 0:
        return None
    try:
        raw = out[min([i for i in (out.find("["), out.find("{")) if i >= 0] or [0]):]
        data = json.loads(raw)
        if isinstance(data, dict):
            data = (data.get("result") or {}).get("machines") or data.get("machines") or []
    except ValueError:
        return None
    import sshconf
    inc = os.path.join(os.environ.get("HOME", ""), ".ssh", "config.d", "dck")
    aliases = {a for a, _s, _e in sshconf._blocks(sshconf._read_owned(inc))} if os.path.exists(inc) else set()
    self_alias = None
    if merged and merged.get("host_machine"):
        me = sshconf.host_self(data, merged.get("host_port"))
        self_alias = str(me["target"]) if me else None
        if self_alias:
            aliases.add(self_alias)
    mirrored = sum(1 for m in data if isinstance(m, dict) and m.get("target") in aliases)
    return {"host_self": self_alias, "mirrored_dck": mirrored, "entries": len(data)}


def herdr_info(merged, problems):
    h = {"installed": bool(which("herdr")), "version": None, "machine": None, "alias": None,
         "include_present": None, "registered": None, "enabled": None, "server_answering": None}
    if h["installed"]:
        h["version"] = first_version(run(["herdr", "--version"])[1])
    h["peers_cli"] = host_peers_cli()
    h["host_ak"] = bool(which("ak"))
    h["catalog"] = catalog_info(merged, h["installed"])
    if merged is None:
        return h
    h["machine"] = bool(merged["herdr.machine"])
    h["alias"] = merged["alias"]
    import sshconf
    inc = os.path.join(os.environ.get("HOME", ""), ".ssh", "config.d", "dck")
    h["include_present"] = sshconf.has_alias(inc, merged["alias"])
    if h["installed"]:
        rc, out = run(["herdr", "machine", "list", "--json"])
        if rc == 0:
            raw = out[min([i for i in (out.find("["), out.find("{")) if i >= 0] or [0]):]
            try:
                data = json.loads(raw)
                if isinstance(data, dict):
                    data = (data.get("result") or {}).get("machines") or data.get("machines") or []
                found = [m for m in data if isinstance(m, dict) and m.get("target") == merged["alias"]]
                h["registered"] = bool(found)
                h["enabled"] = bool(found[0].get("enabled", True)) if found else None
                h["id"] = str(found[0].get("id") or "") or None if found else None
            except ValueError:
                pass
    c = h.get("catalog")
    if merged.get("host_machine") and c is not None and not c["host_self"]:
        problems.append("the host has no entry for itself in its Herdr catalog: replies to asks from the host "
                        "cannot be routed (dck herdr mesh registers dck-host)")
    if h["machine"] and h["registered"] is False:
        problems.append("herdr.machine is on but %s is not registered (dck herdr add)" % merged["alias"])
    return h


def drift_info(merged, h, container_name):
    pins = read_env_file(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "images", "versions.env"))
    items = []
    mine = "v" + config_version()
    if merged and merged.get("_kit_version"):
        items.append({"name": "kit", "pinned": merged["_kit_version"], "installed": mine,
                      "status": "ok" if merged["_kit_version"] == mine else "drift",
                      "note": "the devcontainer-kit the repository was rendered with vs the installed dck"})
    host_herdr = h.get("version")
    if pins.get("HERDR_VERSION"):
        items.append({"name": "herdr", "pinned": pins["HERDR_VERSION"], "installed": host_herdr,
                      "status": "unknown" if not host_herdr else ("ok" if host_herdr == pins["HERDR_VERSION"] else "drift"),
                      "note": "host client vs the version pinned in the images (they need not match)"})
    if container_name:
        rc, out = run(["docker", "exec", container_name, "cat", "/etc/dck/image.env"])
        inside = {}
        if rc != 0:
            return items  # not built from a devcontainer-kit image: nothing to compare
        if rc == 0:
            for line in out.splitlines():
                if "=" in line:
                    k, v = line.split("=", 1)
                    inside[k] = v
        for key in ("GH_VERSION", "HERDR_VERSION", "NVIM_VERSION", "DWP_VIM_TAG"):
            if key in pins:
                got = inside.get(key)
                items.append({"name": key.lower().replace("_version", "").replace("_tag", ""),
                              "pinned": pins[key], "installed": got,
                              "status": "unknown" if got is None else ("ok" if got == pins[key] else "drift"),
                              "note": "running container vs this dck's pin file"})
    return items


def config_version():
    try:
        return open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "VERSION")).read().strip()
    except OSError:
        return "0.0.0"


def host_profiles_info(merged, problems):
    """[agents] host_profiles: what is shared, by name only (never a value)."""
    import hostagents
    lines, p = hostagents.report(merged)
    for level, msg in lines:
        if level == "warn":
            problems.append(msg)
    mounts = [{"profile": "%s@%s" % (s["cli"], s["profile"][1:]), "mode": s["mode"], "reason": s["why"]}
              for s in p["shared"]]
    if p["codex"]:
        mounts.append({"profile": "codex@default", "mode": p["codex"]["mode"], "reason": p["codex"]["why"]})
    if p["env_names"]:
        mounts.append({"profile": "env", "mode": hostagents.MOUNT_MODES["env"][0],
                       "reason": hostagents.MOUNT_MODES["env"][1]})
    return {"enabled": p["enabled"], "reason": p["reason"] or None,
            "shared": hostagents.shared_clis(p), "profiles": hostagents.profile_refs(p),
            "mounts": mounts, "codex": bool(p["codex"]),
            "skipped": [{"cli": c, "reason": r} for c, r in p["skipped"]],
            "env_names": p["env_names"], "notes": [m for _lvl, m in lines]}


def ssh_keys_info(merged, container_name):
    """[ssh] copy_keys: the opt-in state and key file NAMES (never contents).
    `copied` comes from the running container's manifest, else null."""
    import sshkeys
    p = sshkeys.plan(merged)
    copied = None
    if container_name:
        rc, out = run(["docker", "exec", container_name, "cat", p["manifest"]])
        copied = sshkeys.parse_manifest(out) if rc == 0 else []
    return {"enabled": p["enabled"], "reason": p["reason"] or None,
            "host_keys": p["host_keys"], "copied": copied}


def _version_tuple(v):
    m = re.match(r"^v?(\d+)\.(\d+)", str(v))
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


def toml_project(repo):
    """[compose] project from dck.toml, or None (an invalid file says nothing here)."""
    try:
        raw = config.parse_file(config.repo_config_path(repo))
    except config.ConfigError:
        return None
    v = (raw.get("compose") or {}).get("project") if isinstance(raw.get("compose"), dict) else None
    return v if isinstance(v, str) and re.match(config.RE_COMPOSE_PROJECT, v) else None


def compose_project(compose_dir, compose_name, toml_name=None):
    """The compose project as the launcher resolves it (resolve_project):
    [compose] project in dck.toml, then COMPOSE_PROJECT_NAME in the environment,
    then in the compose directory's .env (never through a symlink), then the
    compose file's top-level name."""
    if toml_name:
        return toml_name
    if os.environ.get("COMPOSE_PROJECT_NAME"):
        return os.environ["COMPOSE_PROJECT_NAME"]
    env = os.path.join(compose_dir, ".env")
    if os.path.isfile(env) and not os.path.islink(env):
        v = read_env_file(env).get("COMPOSE_PROJECT_NAME", "").strip().strip('"')
        if v:
            return v
    return compose_name or None


def git_identity_info(container, user):
    """The container user's git identity and where it came from (names only of
    the signing setup: the format and whether commits are signed)."""
    out = {"name": None, "email": None, "signing": None, "source": None}
    for key, field in (("user.name", "name"), ("user.email", "email"), ("gpg.format", "signing")):
        rc, text = run(["docker", "exec", "-u", user, container, "git", "config", "--global", "--get", key])
        out[field] = (text or "").strip() or None if rc == 0 else None
    rc, text = run(["docker", "exec", container, "cat", "/home/%s/.dck/volumes/state/git-identity-source" % user])
    src = (text or "").strip() if rc == 0 else ""
    out["source"] = {"host": "the host's git config", "env": "DCK_GIT_* in the service .env",
                     "host+env": "the host's git config and DCK_GIT_*"}.get(src)
    return out


def compose_info(project, service, state_volume, problems):
    """The compose project's other services, and whether this service's state
    volume is per service. Several repositories sharing one project (one
    COMPOSE_PROJECT_NAME) and the default name would share one state volume:
    one sshd host key, ~/.ssh, gh auth and Herdr state for all of them."""
    vol = "%s_%s" % (project, state_volume)
    out = {"project": project, "state_volume": vol, "services": [], "shared_with": []}
    rc, text = run(["docker", "ps", "-a", "--filter", "label=com.docker.compose.project=%s" % project,
                    "--format", '{{.Label "com.docker.compose.service"}}\t{{.Mounts}}'])
    if rc != 0:
        return out
    for line in (text or "").splitlines():
        svc, _, mounts = line.partition("\t")
        svc = svc.strip()
        if not svc or svc == service:
            continue
        if svc not in out["services"]:
            out["services"].append(svc)
        if vol in [m.strip() for m in mounts.split(",")] and svc not in out["shared_with"]:
            out["shared_with"].append(svc)
    fix = ('set [compose] state_volume = "state-%s" in .devcontainer/dck.toml, then dck init '
           "and dck up --recreate" % service)
    if out["shared_with"]:
        problems.append("compose: the state volume %s is shared with %s — one sshd host key, ~/.ssh, "
                        "gh auth and Herdr state for all of them; %s"
                        % (vol, ", ".join(sorted(out["shared_with"])), fix))
    elif out["services"] and state_volume == "state":
        problems.append("compose: project %s is shared with other services (%s) and the state volume "
                        "is not per service (%s); another repository in this project would share it; %s"
                        % (project, ", ".join(sorted(out["services"])), vol, fix))
    return out


def collect(start, profile=None, compose_files=None):
    problems = []
    version = config_version()
    py_ok = sys.version_info >= (3, 11)
    rt = runtime_info()
    cv = rt["compose"]["version"]
    if cv and _version_tuple(cv) < (2, 24):
        problems.append("Docker Compose %s is older than 2.24, which dck needs for satellites "
                        "(extends with !reset/!override) and port strings; update Docker" % cv)
    if not rt["docker"]["cli"]:
        problems.append("docker is not installed")
    elif not rt["docker"]["daemon"]:
        problems.append("the docker daemon is not answering")
    try:
        prof, _ = config.load_profile(profile)
        prof_out = {"name": prof["name"], "source": prof["_source"], "valid": True}
    except config.ConfigError as exc:
        prof_out = {"name": profile or "default", "source": exc.path, "valid": False}
        problems.append("profile: %s" % "; ".join(exc.problems))
    repo = devc.find_repo(start)
    report = {
        "interface": INTERFACE,
        "version": version,
        "os": {"system": platform.system().lower(), "machine": platform.machine()},
        "python": {"version": platform.python_version(), "ok": py_ok},
        "runtime": rt,
        "profile": prof_out,
        "repo": None, "layers": None, "ssh": None, "herdr": None, "drift": [], "host_profiles": None,
        "ssh_keys": None, "compose": None, "git": None,
        "problems": problems,
    }
    merged = None
    container_running = False
    if repo:
        info, merged = repo_info(repo, "v" + version, profile, rt, problems, compose_files)
        if merged is not None:
            merged["_kit_version"] = info["kit_version"]
        report["repo"] = info
        container_running = bool(info["container"] and info["container"]["state"] == "running")
        if merged:
            report["layers"] = {"agents": merged["layers.agents"], "clis": merged["agents.clis"],
                                "dailybot": merged["layers.dailybot"], "editor": merged["layers.editor"],
                                "clis_supported": list(merged.get("clis_supported") or []),
                                # default: wire and install the onboarding choice (clis);
                                # advanced: [agents] supported, each developer chooses.
                                "clis_mode": "advanced" if merged.get("agents.supported") is not None else "default",
                                "clis_effective": list(merged.get("clis_effective") or []),
                                "clis_source": merged.get("clis_source") or "repo", "clis_image": None}
            if merged["layers.agents"] and container_running:
                # The CLIs the running image was built with (recorded by the agents layer).
                rc, out = run(["docker", "exec", info["container"]["name"], "cat", "/opt/dck/agent-clis"])
                if rc == 0 and re.match(r"^[a-z ]*$", (out or "").strip()):
                    built = (out or "").split()
                    report["layers"]["clis_image"] = built
                    if sorted(built) != sorted(report["layers"]["clis_effective"]):
                        problems.append("agent CLIs: the running image has %s installed; you request %s (%s) — "
                                        "rebuild needed: dck rebuild" % (" ".join(built) or "none",
                                                                         " ".join(report["layers"]["clis_effective"])
                                                                         or "none", report["layers"]["clis_source"]))
            ssh = {"enabled": merged["ssh_port"] != 0, "port": merged["ssh_port"] or None,
                   "bind": merged["bind"], "identity": merged["ssh_identity"],
                   "identity_present": os.path.isfile(merged["ssh_identity"]),
                   "answering": None, "banner": None}
            if merged["bind"] != "127.0.0.1":
                problems.append("bind is %s: the container's ports are reachable beyond this machine" % merged["bind"])
            if ssh["enabled"] and container_running:
                host = "127.0.0.1" if merged["bind"] == "0.0.0.0" else merged["bind"]
                ssh["answering"], ssh["banner"] = port_answers(host, merged["ssh_port"])
                if not ssh["answering"]:
                    problems.append("sshd does not answer on %s:%s" % (host, merged["ssh_port"]))
            report["ssh"] = ssh
            report["host_profiles"] = host_profiles_info(merged, problems)
            import render
            st = render.compose_status(repo, "v" + version, profile)
            report["compose_render"] = st
            if st["error"]:
                problems.append("compose: %s" % st["error"])
            elif st["stale"]:
                problems.append("compose: docker/local/docker-compose.yaml does not reflect dck.toml or its user "
                                "block; run dck init")
            if rt["docker"]["daemon"] and info["project"]:
                report["compose"] = compose_info(info["project"], merged["service"],
                                                 merged["compose.state_volume"], problems)
            report["ssh_keys"] = ssh_keys_info(
                merged, report["repo"]["container"]["name"] if container_running else None)
    if merged and container_running:
        report["git"] = git_identity_info(report["repo"]["container"]["name"], merged["user"])
    h = herdr_info(merged, problems)
    if merged and container_running and h.get("id"):
        # The id the container exports as HERDR_PEERS_SELF (herdr-peers' reply route).
        rc, out = run(["docker", "exec", report["repo"]["container"]["name"], "cat",
                       "/home/%s/.dck/volumes/state/herdr-self" % merged["user"]])
        inside = (out or "").strip() if rc == 0 else ""
        h["self_inside"] = inside if re.match(r"^[0-9a-f]{32}$", inside) else None
        if h["self_inside"] != h["id"]:
            problems.append("herdr: HERDR_PEERS_SELF inside is %s, but the host's catalog has this container as %s; "
                            "asks from Codex panes find no reply route (run: dck herdr add)"
                            % (h["self_inside"] or "unset", h["id"]))
    if h["registered"] and report["ssh"] and report["ssh"]["answering"]:
        rc, _ = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=3", h["alias"],
                     "herdr", "status", "server"], timeout=10)
        h["server_answering"] = rc == 0
    report["herdr"] = h
    name = report["repo"]["container"]["name"] if container_running else None
    report["drift"] = drift_info(merged, h, name)
    for d in report["drift"]:
        if d["status"] == "drift" and d["name"] != "herdr":
            problems.append("drift: %s pinned %s, installed %s" % (d["name"], d["pinned"], d["installed"]))
    report["ok"] = not problems
    return report


def text(report):
    yes = lambda b: "yes" if b else ("no" if b is not None else "-")  # noqa: E731
    rt = report["runtime"]
    out = ["devcontainer-kit %s (interface %d)" % (report["version"], report["interface"]),
           "python           %s%s" % (report["python"]["version"], "" if report["python"]["ok"] else " (need >= 3.11)"),
           "docker           cli %s, daemon %s%s" % (rt["docker"]["version"] or "missing",
                                                     rt["docker"]["server_version"] or "not answering",
                                                     (" (%s)" % rt["provider"]) if rt["provider"] else ""),
           "compose          %s" % (rt["compose"]["version"] or "-"),
           "devcontainer cli %s" % (rt["devcontainer_cli"]["version"] or "not installed"),
           "profile          %s (%s)" % (report["profile"]["name"], report["profile"]["source"])]
    r = report["repo"]
    if r:
        out += ["repo             %s" % r["path"],
                "  config valid   %s" % yes(r["config_valid"]),
                "  flavour        %s" % (r["flavour"] or "-"),
                "  base image     %s" % (r["base_image"] or "-"),
                "  digest         %s" % ("pinned" if r["digest_pinned"] else "not pinned"),
                "  rendered with  %s (dck/ %s)" % (r["kit_version"] or "-", r["vendored"] or "-"),
                "  compose files  %s%s" % (", ".join(r["compose_files"]) or "-",
                                           " (--compose-file)" if r["compose_override"] else ""),
                "  container      %s" % ((r["container"] or {}).get("state") or "-")]
        for e in r["env_files"]:
            out.append("  env file       %s: %s%s" % (e["path"],
                                         ("present " + e["mode"]) if e["present"] else "MISSING",
                                         ("; keys set: " + ", ".join(e["keys_set"])) if e["keys_set"] else ""))
    else:
        out.append("repo             - (no .devcontainer/ here)")
    if report["layers"]:
        l = report["layers"]  # noqa: E741
        out.append("layers           agents %s%s, dailybot %s, editor %s" % (
            yes(l["agents"]), (" (" + " ".join(l["clis"]) + ")") if l["clis"] else "", yes(l["dailybot"]), yes(l["editor"])))
        if l["agents"]:
            out.append("agent CLIs       mode %s" % (
                "advanced ([agents] supported: each developer chooses what to install)" if l["clis_mode"] == "advanced"
                else "default (the CLIs chosen at onboarding, dck.toml clis, are wired and installed)"))
            out.append("                 supported %s" % (" ".join(l["clis_supported"]) or "none"))
            out.append("                 requested %s (from %s)" % (" ".join(l["clis_effective"]) or "none",
                                                               l["clis_source"]))
            out.append("                 installed %s" % (
                "- (no running container, or an image from before v0.3.6)" if l["clis_image"] is None else
                (" ".join(l["clis_image"]) or "none") + (
                    "" if sorted(l["clis_image"]) == sorted(l["clis_effective"]) else " — rebuild needed: dck rebuild")))
    s = report["ssh"]
    if s:
        out.append("ssh              %s" % ("off" if not s["enabled"] else "%s:%s, key %s, answering %s" % (
            s["bind"], s["port"], "present" if s["identity_present"] else "missing", yes(s["answering"]))))
    g = report.get("git")
    if g:
        out.append("git identity     %s%s (from %s)" % (
            g["name"] or "unset", (" <%s>" % g["email"]) if g["email"] else "",
            g["source"] or ("nowhere: run dck up" if not g["name"] else "the image or a manual git config")))
    cr = report.get("compose_render")
    if cr and cr["overrides"]:
        out.append("user block       overrides dck's %s (x-dck-merge)" % ", ".join(cr["overrides"]))
    c = report.get("compose")
    if c:
        out.append("compose          project %s, state volume %s%s" % (
            c["project"], c["state_volume"],
            ("; other services: " + ", ".join(sorted(c["services"]))) if c["services"] else ""))
    k = report.get("ssh_keys")
    if k:
        if not k["enabled"]:
            out.append("ssh keys         %s" % k["reason"])
        elif k["copied"] is not None:
            out.append("ssh keys         copy_keys on; ssh keys copied: %s" % (", ".join(k["copied"]) or "none"))
        else:
            out.append("ssh keys         copy_keys on; copied at the next start: %s" % (", ".join(k["host_keys"]) or "none"))
    hp = report.get("host_profiles")
    if hp:
        out += ["%-17s%s" % ("host profiles", m[len("host profiles: "):]) for m in hp["notes"]]
    h = report["herdr"]
    out.append("herdr-peers      %s" % (h.get("peers_cli") or "not installed (dck host peers install)"))
    out.append("ak (host)        %s" % ("installed" if h.get("host_ak") else "not installed (coding-agents-kit)"))
    c = h.get("catalog")
    if c is not None:
        out.append("herdr catalog    %d entr%s; mirrored into containers: %d dck machine(s)%s" % (
            c["entries"], "y" if c["entries"] == 1 else "ies", c["mirrored_dck"],
            ", host self %s" % (c["host_self"] or "MISSING") if report["layers"] is not None else ""))
    out.append("herdr            %s%s" % (h["version"] or "not installed",
                                          "" if h["machine"] is None else ", machine %s, alias %s, registered %s, server %s" % (
                                              yes(h["machine"]), h["alias"], yes(h["registered"]), yes(h["server_answering"]))))
    if h.get("id"):
        out.append("herdr self       %s in the host's catalog; HERDR_PEERS_SELF inside: %s" % (
            h["id"], h.get("self_inside") or ("unset" if "self_inside" in h else "- (container not running)")))
    for d in report["drift"]:
        out.append("drift            %-10s pinned %s, installed %s (%s)" % (d["name"], d["pinned"], d["installed"] or "-", d["status"]))
    if report["problems"]:
        out.append("problems:")
        out += ["  - %s" % p for p in report["problems"]]
    else:
        out.append("no problems found")
    return "\n".join(out)


def main(args):
    as_json = "--json" in args
    strict = "--strict" in args
    profile = None
    if "--profile" in args:
        profile = args[args.index("--profile") + 1]
    start = os.getcwd()
    if "--repo" in args:
        start = args[args.index("--repo") + 1]
    files = [args[i + 1] for i, a in enumerate(args[:-1]) if a == "--compose-file"]
    report = collect(start, profile, files or None)
    print(json.dumps(report, indent=2, sort_keys=True) if as_json else text(report))
    return 1 if (strict and not report["ok"]) else 0
