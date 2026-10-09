"""A tiny JSON Schema (draft 2020-12 subset) validator for the test suite:
type (incl. lists), const, enum, required, properties, items, pattern.
Standard library only. Usage: python3 minischema.py <schema.json> < doc.json
Prints one line per violation; exits 1 when there is any."""
import json
import re
import sys

TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}


def is_type(v, t):
    if t == "integer":
        return isinstance(v, int) and not isinstance(v, bool)
    if t == "number":
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    return isinstance(v, TYPES[t])


def check(v, s, path, errs):
    if "const" in s and v != s["const"]:
        errs.append("%s: expected const %r, got %r" % (path, s["const"], v))
    if "enum" in s and v not in s["enum"]:
        errs.append("%s: %r not in %r" % (path, v, s["enum"]))
    if "type" in s:
        ts = s["type"] if isinstance(s["type"], list) else [s["type"]]
        if not any(is_type(v, t) for t in ts):
            errs.append("%s: %r is not of type %s" % (path, v, ts))
            return
    if isinstance(v, str) and "pattern" in s and not re.search(s["pattern"], v):
        errs.append("%s: %r does not match %s" % (path, v, s["pattern"]))
    if isinstance(v, dict):
        for k in s.get("required", []):
            if k not in v:
                errs.append("%s: missing required key %r" % (path, k))
        for k, sub in s.get("properties", {}).items():
            if k in v:
                check(v[k], sub, "%s.%s" % (path, k), errs)
    if isinstance(v, list) and "items" in s:
        for i, item in enumerate(v):
            check(item, s["items"], "%s[%d]" % (path, i), errs)


if __name__ == "__main__":
    schema = json.load(open(sys.argv[1]))
    doc = json.load(sys.stdin)
    errors = []
    check(doc, schema, "$", errors)
    print("\n".join(errors))
    sys.exit(1 if errors else 0)
