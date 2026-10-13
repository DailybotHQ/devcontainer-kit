"""Python side of dck: one entry point, called by bin/dck as

    python3 -I <lib>/dckpy.py <group> <command> [args]

`-I` (isolated mode) keeps the caller's working directory and environment
out of sys.path, so a file named json.py in the repository being worked on
can never be imported in place of the standard library. This module then
adds only its own directory, for the sibling modules.

Exit codes follow bin/dck: 0 ok, 1 failed, 2 usage, 3 configuration error,
5 refused. Output meant for bash is KEY=VALUE lines that the caller reads
with IFS, never eval.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import config  # noqa: E402

EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_CONFIG, EXIT_ENV, EXIT_REFUSED = 0, 1, 2, 3, 4, 5


def version():
    try:
        with open(os.path.join(HERE, "..", "VERSION")) as fh:
            return fh.read().strip()
    except OSError:
        return "0.0.0"


def default_tag():
    return "v" + version()


def usage(msg):
    sys.stderr.write("dck: %s\n" % msg)
    return EXIT_USAGE


def opt(args, name, default=None):
    """Pop `--name value` from args."""
    if name in args:
        i = args.index(name)
        if i + 1 >= len(args):
            raise SystemExit(usage("%s needs a value" % name))
        value = args[i + 1]
        del args[i:i + 2]
        return value
    return default


def flag(args, name):
    if name in args:
        args.remove(name)
        return True
    return False


def emit_env(mapping, prefix="DCK_"):
    for key in sorted(mapping):
        value = mapping[key]
        if isinstance(value, bool):
            value = "1" if value else "0"
        elif isinstance(value, list):
            value = " ".join(str(v) for v in value)
        elif isinstance(value, dict):
            value = " ".join("%s=%s" % kv for kv in sorted(value.items()))
        elif value is None:
            value = ""
        name = prefix + key.upper().replace(".", "_")
        print("%s=%s" % (name, value))


def warn_all(warnings):
    for w in warnings:
        sys.stderr.write("dck: warning: %s\n" % w)


def cmd_config(args):
    if not args:
        return usage("config needs a command: validate | show | host | rules")
    sub = args.pop(0)
    try:
        if sub == "validate":
            kind = opt(args, "--kind", "repo")
            if kind not in ("repo", "profile") or len(args) != 1:
                return usage("config validate [--kind repo|profile] <file>")
            effective, warnings = config.validate(config.parse_file(args[0]), kind, args[0])
            warn_all(warnings)
            print("%s: valid (%s config, interface %d)" % (args[0], kind, config.INTERFACE))
            return EXIT_OK
        if sub == "show":
            repo = opt(args, "--repo", ".")
            profile = opt(args, "--profile")
            fmt = opt(args, "--format", "env")
            merged, warnings = config.effective(repo, default_tag(), profile)
            warn_all(warnings)
            if fmt == "json":
                print(json.dumps(merged, indent=2, sort_keys=True, ensure_ascii=False))
            elif fmt == "env":
                emit_env(merged)
            else:
                return usage("--format env|json")
            return EXIT_OK
        if sub == "host":
            # The host-peer settings of the profile, as KEY=VALUE lines (no repository).
            import devc
            prof, warnings = config.load_profile(opt(args, "--profile"))
            warn_all(warnings)
            for k, v in devc.host_env(prof):
                print("%s=%s" % (k, v))
            print("DCK_SSH_IDENTITY=%s" % config.expand_home(prof["ssh.identity"], os.environ))
            return EXIT_OK
        if sub == "copy-keys":
            # [ssh] copy_keys of the host profile: prints true|false|unset; with
            # --set, records the answer only while it is unset.
            name, value = opt(args, "--profile"), opt(args, "--set")
            if value is not None:
                if value not in ("true", "false"):
                    return usage("config copy-keys [--profile NAME] [--set true|false]")
                print("recorded" if config.record_copy_keys(value == "true", name) else
                      config.profile_copy_keys(name))
                return EXIT_OK
            print(config.profile_copy_keys(name))
            return EXIT_OK
        if sub == "rules":
            out = {}
            for kind, rules in (("repo", config.REPO_RULES), ("profile", config.PROFILE_RULES)):
                out[kind] = {
                    key: {"type": r[0],
                          "required": r[1] is config.REQUIRED,
                          "default": None if r[1] is config.REQUIRED else r[1],
                          "constraint": list(r[2]) if r[2] else None}
                    for key, r in rules.items()}
            print(json.dumps(out, indent=2, sort_keys=True))
            return EXIT_OK
    except config.ConfigError as exc:
        sys.stderr.write("dck: invalid configuration\n%s\n" % exc)
        return EXIT_CONFIG
    return usage("unknown config command %r" % sub)


def cmd_init(args):
    import render
    opts = {"repo": opt(args, "--repo"), "profile": opt(args, "--profile")}
    for name, key, conv in (("--flavour", "flavour", str), ("--service", "service", str),
                            ("--user", "user", str), ("--workspace", "workspace", str),
                            ("--ssh-port", "ssh_port", int), ("--state-volume", "state_volume", str)):
        value = opt(args, name)
        if value is not None:
            try:
                opts[key] = conv(value)
            except ValueError:
                return usage("%s expects %s, got %r" % (name, "a number" if conv is int else "text", value))
    ports = {}
    while "--port" in args:
        spec = opt(args, "--port")
        name, sep, num = spec.partition("=")
        if not sep or not num.isdigit():
            return usage("--port expects name=number, got %r" % spec)
        ports[name] = int(num)
    if ports:
        opts["ports"] = ports
    clis = opt(args, "--clis")
    if clis is not None:
        opts["clis"] = [c for c in clis.replace(",", " ").split() if c]
    supported = opt(args, "--supported")
    if supported is not None:
        opts["supported"] = "all" if supported.strip() == "all" else [c for c in supported.replace(",", " ").split() if c]
    for on, off, key in (("--agents", "--no-agents", "agents"), ("--editor", "--no-editor", "editor"),
                         ("--herdr", "--no-herdr", "herdr_machine"), ("--dev-sh", "--no-dev-sh", "dev_sh")):
        if flag(args, on):
            opts[key] = True
        if flag(args, off):
            opts[key] = False
    flag(args, "--no-digest")  # accepted for compatibility: v0.2 resolves no registry digest
    opts["dry_run"] = flag(args, "--dry-run")
    opts["yes"] = flag(args, "--yes") or flag(args, "-y")
    if args:
        return usage("init: unexpected argument %r (see: dck help init)" % args[0])
    opts["interactive"] = (not opts["yes"]) and sys.stdin.isatty() and os.environ.get("DCK_NONINTERACTIVE") != "1"
    try:
        return render.init(opts, default_tag())
    except config.ConfigError as exc:
        sys.stderr.write("dck: invalid configuration\n%s\n" % exc)
        return EXIT_CONFIG


def cmd_devc(args):
    import devc
    if not args:
        return usage("devc needs a command: find | read | overlay | networks")
    sub = args.pop(0)
    try:
        if sub == "find":
            repo = devc.find_repo(opt(args, "--start", os.getcwd()))
            if not repo:
                sys.stderr.write("dck: no .devcontainer/ found here or in any parent directory — run: dck init\n")
                return EXIT_CONFIG
            print(repo)
            return EXIT_OK
        if sub == "read":
            lines, warnings = devc.env_lines(opt(args, "--repo", "."), default_tag(), opt(args, "--profile"))
            warn_all(warnings)
            for k, v in lines:
                print("%s=%s" % (k, v))
            return EXIT_OK
        if sub == "overlay":
            repo, project, out = opt(args, "--repo"), opt(args, "--project"), opt(args, "--out")
            service = opt(args, "--service")
            if not (repo and project and out):
                return usage("devc overlay --repo DIR --project NAME --out FILE [--service NAME]")
            print("written" if devc.write_overlay(repo, project, out, service) else "none")
            return EXIT_OK
        if sub == "env-examples":
            for p in devc.env_examples(opt(args, "--dir"), opt(args, "--repo")):
                print(p)
            return EXIT_OK
        if sub == "preflight":
            repo = opt(args, "--repo")
            files = []
            while "--compose-file" in args:
                files.append(opt(args, "--compose-file"))
            found = devc.preflight(repo, files)
            for f in found:
                print(f)
            return EXIT_REFUSED if found else EXIT_OK
        if sub == "networks":
            for name in devc.external_networks(opt(args, "--file")):
                print(name)
            return EXIT_OK
    except devc.DevcError as exc:
        sys.stderr.write("dck: %s\n" % exc)
        return EXIT_CONFIG
    except config.ConfigError as exc:
        sys.stderr.write("dck: invalid configuration\n%s\n" % exc)
        return EXIT_CONFIG
    return usage("unknown devc command %r" % sub)


def cmd_sshconf(args):
    import sshconf
    if not args:
        return usage("sshconf needs a command: upsert | remove | has | include | peers | host-identities")
    sub = args.pop(0)
    try:
        if sub == "upsert":
            print(sshconf.upsert(opt(args, "--file"), opt(args, "--alias"), opt(args, "--host"),
                                 opt(args, "--port"), opt(args, "--user"), opt(args, "--identity"),
                                 opt(args, "--known-hosts")))
            return EXIT_OK
        if sub == "remove":
            print(sshconf.remove(opt(args, "--file"), opt(args, "--alias")))
            return EXIT_OK
        if sub == "has":
            return EXIT_OK if sshconf.has_alias(opt(args, "--file"), opt(args, "--alias")) else EXIT_FAIL
        if sub == "include":
            print(sshconf.ensure_include(opt(args, "--config")))
            return EXIT_OK
        if sub == "host-identities":
            extra = (opt(args, "--extra") or "").split()
            sys.stdout.write(sshconf.host_identities(opt(args, "--config"), opt(args, "--home"), extra))
            return EXIT_OK
        if sub == "aliases":
            path = opt(args, "--file")
            ports = flag(args, "--ports")
            if os.path.exists(path):
                lines = sshconf._read_owned(path)
                for alias, s, e in sshconf._blocks(lines):
                    if alias == sshconf.HOST_SELF_ALIAS:  # the host, not a container
                        continue
                    if not ports:
                        print(alias)
                        continue
                    port = next((ln.split()[1] for ln in lines[s:e] if len(ln.split()) == 2
                                 and ln.split()[0].lower() == "port" and ln.split()[1].isdigit()), "")
                    if port:
                        print("%s %s" % (alias, port))
            return EXIT_OK
        if sub == "peers":
            labels = {}
            raw = sys.stdin.read() if "--labels-stdin" in args else ""
            if "--labels-stdin" in args:
                args.remove("--labels-stdin")
            start = min([i for i in (raw.find("["), raw.find("{")) if i >= 0] or [-1])
            try:
                data = json.loads(raw[start:]) if start >= 0 else []
            except ValueError:
                data = []
            if isinstance(data, dict):
                data = (data.get("result") or {}).get("machines") or data.get("machines") or []
            machines = data if isinstance(data, list) else []
            for m in machines:
                if isinstance(m, dict) and m.get("target") and m.get("label"):
                    labels[str(m["target"])] = str(m["label"])
            host_label = opt(args, "--host-label") or "host"
            path, exclude = opt(args, "--file"), opt(args, "--exclude") or ""
            host_user, host_port = opt(args, "--host-user") or "", opt(args, "--host-port") or "22"
            with_catalog = flag(args, "--catalog")
            dck_aliases = [a for a, _s, _e in sshconf._blocks(sshconf._read_owned(path))] if os.path.exists(path) else []
            # The host as a peer: its own catalog entry when it has one, so ids match.
            host_alias = sshconf.HOST_SELF_ALIAS
            if host_user:
                me = sshconf.host_self(machines, host_port)
                if me:
                    host_alias = str(me["target"])
                labels[host_alias] = labels.get(host_alias) or host_label
            external = []
            if flag(args, "--external"):
                dck_ports = sshconf.alias_ports(path) if os.path.exists(path) else []
                skip_ports = list(dck_ports) + ([host_port] if host_user else []) + [opt(args, "--self-port") or "0"]
                external, notes = sshconf.external_peers(
                    machines, skip_aliases=dck_aliases + [exclude, sshconf.HOST_SELF_ALIAS, host_alias],
                    skip_ports=skip_ports,
                    known_hosts_files=(opt(args, "--user-known-hosts") or "").split(","))
                for n in notes:
                    sys.stderr.write("dck: %s\n" % n)
            out = sshconf.peers(path, opt(args, "--known-hosts"), exclude, labels, host_user,
                                opt(args, "--host-key") or "", host_port, external, host_alias,
                                with_self=with_catalog)
            if with_catalog:
                reachable = set()
                for ln in out.splitlines():
                    parts = ln.split()
                    if len(parts) >= 2 and parts[0] in ("peer", "self"):
                        reachable.add(parts[1])
                out += "".join(l + "\n" for l in sshconf.catalog_lines(machines, reachable))
            sys.stdout.write(out)
            return EXIT_OK
        if sub == "host-self":
            # The host's own Herdr catalog entry (stdin: herdr machine list --json):
            # "<id> <target>" or nothing (exit 1).
            raw = sys.stdin.read()
            start = min([i for i in (raw.find("["), raw.find("{")) if i >= 0] or [-1])
            try:
                data = json.loads(raw[start:]) if start >= 0 else []
            except ValueError:
                data = []
            if isinstance(data, dict):
                data = (data.get("result") or {}).get("machines") or data.get("machines") or []
            me = sshconf.host_self(data if isinstance(data, list) else [], opt(args, "--port") or "0")
            if not me:
                return EXIT_FAIL
            print("%s %s" % (me.get("id", ""), me.get("target", "")))
            return EXIT_OK
    except sshconf.SshConfError as exc:
        sys.stderr.write("dck: %s\n" % exc)
        return exc.code
    except (TypeError, ValueError) as exc:
        return usage("sshconf %s: %s" % (sub, exc))
    return usage("unknown sshconf command %r" % sub)


def cmd_herdr(args):
    """`herdr machine list --json` on stdin -> the machine whose target is the alias:
    one line "id<TAB>label<TAB>enabled", or nothing (exit 1)."""
    if not args or args[0] != "find":
        return usage("herdr find --target ALIAS")
    target = opt(args[1:], "--target")
    raw = sys.stdin.read()
    start = min([i for i in (raw.find("["), raw.find("{")) if i >= 0] or [-1])
    if start < 0:
        return EXIT_FAIL
    try:
        data = json.loads(raw[start:])
    except ValueError:
        return EXIT_FAIL
    if isinstance(data, dict):
        data = (data.get("result") or {}).get("machines") or data.get("machines") or []
    for m in data if isinstance(data, list) else []:
        if isinstance(m, dict) and m.get("target") == target:
            print("%s\t%s\t%s" % (m.get("id", ""), m.get("label", ""),
                                    "1" if m.get("enabled", True) else "0"))
            return EXIT_OK
    return EXIT_FAIL


def cmd_agents(args):
    """`agents overlay --repo DIR --project NAME --out FILE [--profile NAME]`:
    the runtime overlay of [agents] host_profiles (written, or removed when off)."""
    import devc
    import hostagents
    if not args or args[0] != "overlay":
        return usage("agents overlay --repo DIR --project NAME --out FILE [--profile NAME]")
    args = args[1:]
    repo, project, out = opt(args, "--repo"), opt(args, "--project"), opt(args, "--out")
    profile = opt(args, "--profile")
    if not (repo and project and out):
        return usage("agents overlay --repo DIR --project NAME --out FILE")
    try:
        merged, _ = config.effective(repo, default_tag(), profile)
        p = hostagents.write(merged, opt(args, "--service") or devc.read(repo)["service"], project, out)
    except (hostagents.HostAgentsError, devc.DevcError, OSError) as exc:
        sys.stderr.write("dck: host profiles: %s\n" % exc)
        return EXIT_REFUSED
    except config.ConfigError as exc:
        sys.stderr.write("dck: invalid configuration\n%s\n" % exc)
        return EXIT_CONFIG
    # Names only: never a value.
    print("enabled=%s" % ("1" if p["enabled"] else "0"))
    print("shared=%s" % " ".join(hostagents.profile_refs(p)))
    print("codex=%s" % ("1" if p["codex"] else "0"))
    print("env=%s" % " ".join(p["env_names"]))
    print("skipped=%s" % " ".join(c for c, _ in p["skipped"]))
    return EXIT_OK


def cmd_clis(args):
    """`clis overlay --repo DIR --out FILE [--service NAME] [--profile NAME]`:
    the runtime overlay of this developer's coding-agent CLIs (written when the
    effective list differs from dck.toml's, removed otherwise)."""
    import agentclis
    import devc
    import hostagents
    if not args or args[0] != "overlay":
        return usage("clis overlay --repo DIR --out FILE [--service NAME] [--profile NAME]")
    args = args[1:]
    repo, out, profile = opt(args, "--repo"), opt(args, "--out"), opt(args, "--profile")
    if not (repo and out):
        return usage("clis overlay --repo DIR --out FILE")
    try:
        merged, _ = config.effective(repo, default_tag(), profile)
        p = agentclis.write(merged, opt(args, "--service") or devc.read(repo)["service"], out)
    except (hostagents.HostAgentsError, devc.DevcError, OSError) as exc:
        sys.stderr.write("dck: agent CLIs: %s\n" % exc)
        return EXIT_REFUSED
    except config.ConfigError as exc:
        sys.stderr.write("dck: invalid configuration\n%s\n" % exc)
        return EXIT_CONFIG
    print("differs=%s" % ("1" if p["differs"] else "0"))
    print("effective=%s" % " ".join(p["effective"]))
    print("source=%s" % p["source"])
    return EXIT_OK


def cmd_sshkeys(args):
    """`sshkeys overlay --repo DIR --out FILE [--profile NAME]`: the runtime
    overlay of [ssh] copy_keys (written, or removed when off)."""
    import devc
    import sshkeys
    if not args or args[0] != "overlay":
        return usage("sshkeys overlay --repo DIR --out FILE [--profile NAME]")
    args = args[1:]
    repo, out, profile = opt(args, "--repo"), opt(args, "--out"), opt(args, "--profile")
    if not (repo and out):
        return usage("sshkeys overlay --repo DIR --out FILE")
    try:
        merged, _ = config.effective(repo, default_tag(), profile)
        p = sshkeys.write(merged, opt(args, "--service") or devc.read(repo)["service"], out)
    except (sshkeys.SshKeysError, devc.DevcError, OSError) as exc:
        sys.stderr.write("dck: ssh keys: %s\n" % exc)
        return EXIT_REFUSED
    except config.ConfigError as exc:
        sys.stderr.write("dck: invalid configuration\n%s\n" % exc)
        return EXIT_CONFIG
    # File names only: never a key's contents.
    print("enabled=%s" % ("1" if p["enabled"] else "0"))
    print("keys=%s" % " ".join(p["host_keys"]))
    print("reason=%s" % p["reason"])
    return EXIT_OK


def cmd_compose(args):
    """`compose status --repo DIR [--profile NAME]`: whether `dck init` would
    change docker/local/docker-compose.yaml (stale=1), and why it cannot."""
    import render
    if not args or args[0] != "status":
        return usage("compose status --repo DIR [--profile NAME]")
    args = args[1:]
    repo, profile = opt(args, "--repo"), opt(args, "--profile")
    if not repo:
        return usage("compose status --repo DIR")
    st = render.compose_status(repo, default_tag(), profile)
    print("stale=%s" % ("1" if st["stale"] else "0"))
    print("error=%s" % (st["error"] or "").replace("\n", " "))
    return EXIT_OK


def cmd_doctor(args):
    import doctor
    return doctor.main(args)


GROUPS = {"agents": cmd_agents, "clis": cmd_clis, "sshkeys": cmd_sshkeys, "compose": cmd_compose, "doctor": cmd_doctor, "config": cmd_config, "init": cmd_init, "devc": cmd_devc, "sshconf": cmd_sshconf, "herdr": cmd_herdr}


def main(argv):
    if not argv or argv[0] not in GROUPS:
        return usage("dckpy: expected one of: %s" % ", ".join(sorted(GROUPS)))
    return GROUPS[argv[0]](list(argv[1:]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
