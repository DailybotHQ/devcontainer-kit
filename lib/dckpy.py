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


GROUPS = {"config": cmd_config}


def main(argv):
    if not argv or argv[0] not in GROUPS:
        return usage("dckpy: expected one of: %s" % ", ".join(sorted(GROUPS)))
    return GROUPS[argv[0]](list(argv[1:]))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
