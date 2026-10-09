"""`dck doctor [--json]` — environment and repository health, interface 1.

Top-level keys (ECOSYSTEM_CONTRACT §2.3; schema docs/schema/dck-doctor-v1.json):
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

INTERFACE = 1
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
        if rc == 0 and out.strip():
            docker["daemon"] = True
            parts = (out.strip().split("|") + ["", "", ""])[:3]
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
            return True, banner.decode("ascii", "replace").strip() or None
    except OSError:
        return False, None


def repo_info(repo, dck_tag, profile, rt, problems):
    info = {"path": repo, "devcontainer": None, "config_valid": False, "errors": [],
            "warnings": [], "flavour": None, "image_tag": None, "base_image": None,
            "digest_pinned": False, "digest_match": None, "project": None,
            "service": None, "container": None, "env_files": []}
    merged = None
    try:
        d = devc.read(repo)
        info["devcontainer"] = os.path.relpath(d["file"], repo)
        info["service"] = d["service"]
        info["project"] = d["compose_name"] or None
        compose_text = open(d["compose_files"][0]).read()
        m = re.search(r'BASE_IMAGE:\s*"([^"]+)"', compose_text)
        if m:
            info["base_image"] = m.group(1)
            info["digest_pinned"] = "@sha256:" in m.group(1)
        compose_dir = os.path.dirname(d["compose_files"][0])
        for root, _dirs, files in os.walk(compose_dir):
            for f in sorted(files):
                if f.startswith(".env") and f.endswith(".example"):
                    target = os.path.join(root, f[:-len(".example")])
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
            info["image_tag"] = merged["image_tag"]
            if not info["project"]:
                info["project"] = None
        except config.ConfigError as exc:
            info["errors"].extend(exc.problems)
    else:
        info["errors"].append(".devcontainer/dck.toml not found (run: dck init)")
    for e in info["errors"]:
        problems.append("repo: %s" % e)
    if info["base_image"] and not info["digest_pinned"]:
        problems.append("the base image is pinned by tag only (re-run dck init when the registry is reachable)")
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
    if docker_ok and info["digest_pinned"]:
        ref, _, digest = info["base_image"].partition("@")
        rc, out = run(["docker", "image", "inspect", "--format", "{{json .RepoDigests}}", info["base_image"]])
        if rc == 0:
            try:
                info["digest_match"] = any(x.endswith(digest) for x in json.loads(out or "[]"))
            except ValueError:
                info["digest_match"] = None
        else:
            info["digest_match"] = None  # not pulled yet: nothing to compare
        if info["digest_match"] is False:
            problems.append("the local base image does not match the digest pinned in compose (dck rebuild --no-cache pulls it)")
    return info, merged


def herdr_info(merged, problems):
    h = {"installed": bool(which("herdr")), "version": None, "machine": None, "alias": None,
         "include_present": None, "registered": None, "enabled": None, "server_answering": None}
    if h["installed"]:
        h["version"] = first_version(run(["herdr", "--version"])[1])
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
            except ValueError:
                pass
    if h["machine"] and h["registered"] is False:
        problems.append("herdr.machine is on but %s is not registered (dck herdr add)" % merged["alias"])
    return h


def drift_info(merged, h, container_name):
    pins = read_env_file(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "images", "versions.env"))
    items = []
    mine = "v" + config_version()
    if merged:
        items.append({"name": "image_tag", "pinned": merged["image_tag"], "installed": mine,
                      "status": "ok" if merged["image_tag"] == mine else "drift",
                      "note": "repository image tag vs the installed dck"})
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


def collect(start, profile=None):
    problems = []
    version = config_version()
    py_ok = sys.version_info >= (3, 11)
    rt = runtime_info()
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
        "repo": None, "layers": None, "ssh": None, "herdr": None, "drift": [],
        "problems": problems,
    }
    merged = None
    container_running = False
    if repo:
        info, merged = repo_info(repo, "v" + version, profile, rt, problems)
        report["repo"] = info
        container_running = bool(info["container"] and info["container"]["state"] == "running")
        if merged:
            report["layers"] = {"agents": merged["layers.agents"], "clis": merged["agents.clis"],
                                "dailybot": merged["layers.dailybot"], "editor": merged["layers.editor"]}
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
    h = herdr_info(merged, problems)
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
                "  flavour        %s, image %s" % (r["flavour"] or "-", r["image_tag"] or "-"),
                "  base image     %s" % (r["base_image"] or "-"),
                "  digest         %s%s" % ("pinned" if r["digest_pinned"] else "tag only",
                                           "" if r["digest_match"] is None else (", matches local image" if r["digest_match"] else ", DIFFERS from the local image")),
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
    s = report["ssh"]
    if s:
        out.append("ssh              %s" % ("off" if not s["enabled"] else "%s:%s, key %s, answering %s" % (
            s["bind"], s["port"], "present" if s["identity_present"] else "missing", yes(s["answering"]))))
    h = report["herdr"]
    out.append("herdr            %s%s" % (h["version"] or "not installed",
                                          "" if h["machine"] is None else ", machine %s, alias %s, registered %s, server %s" % (
                                              yes(h["machine"]), h["alias"], yes(h["registered"]), yes(h["server_answering"]))))
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
    report = collect(start, profile)
    print(json.dumps(report, indent=2, sort_keys=True) if as_json else text(report))
    return 1 if (strict and not report["ok"]) else 0
