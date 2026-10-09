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
        return usage("config needs a command: validate | show | rules")
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
                            ("--image-tag", "image_tag", str), ("--ssh-port", "ssh_port", int)):
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
    for on, off, key in (("--agents", "--no-agents", "agents"), ("--editor", "--no-editor", "editor"),
                         ("--herdr", "--no-herdr", "herdr_machine")):
        if flag(args, on):
            opts[key] = True
        if flag(args, off):
            opts[key] = False
    opts["dry_run"] = flag(args, "--dry-run")
    opts["yes"] = flag(args, "--yes") or flag(args, "-y")
    opts["no_digest"] = flag(args, "--no-digest") or os.environ.get("DCK_NO_DIGEST") == "1"
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
            if not (repo and project and out):
                return usage("devc overlay --repo DIR --project NAME --out FILE")
            print("written" if devc.write_overlay(repo, project, out) else "none")
            return EXIT_OK
        if sub == "env-examples":
            for p in devc.env_examples(opt(args, "--dir"), opt(args, "--repo")):
                print(p)
            return EXIT_OK
        if sub == "preflight":
            found = devc.preflight(opt(args, "--repo"))
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
        return usage("sshconf needs a command: upsert | remove | has | include")
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


def cmd_doctor(args):
    import doctor
    return doctor.main(args)


GROUPS = {"doctor": cmd_doctor, "config": cmd_config, "init": cmd_init, "devc": cmd_devc, "sshconf": cmd_sshconf, "herdr": cmd_herdr}


def main(argv):
    if not argv or argv[0] not in GROUPS:
        return usage("dckpy: expected one of: %s" % ", ".join(sorted(GROUPS)))
    return GROUPS[argv[0]](list(argv[1:]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
