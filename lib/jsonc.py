"""JSONC (JSON with comments and trailing commas), as devcontainer.json allows.

Comments and trailing commas are stripped while tracking string literals, so
"https://example.com" inside a string is never mistaken for a comment.
Ported from the deepworkplan-website dev.sh launcher.
"""

import json


def _skip_ws_and_comments(s, j):
    n = len(s)
    while j < n:
        if s[j] in " \t\r\n":
            j += 1
        elif s.startswith("//", j):
            while j < n and s[j] != "\n":
                j += 1
        elif s.startswith("/*", j):
            end = s.find("*/", j + 2)
            j = n if end < 0 else end + 2
        else:
            break
    return j


def strip(s):
    out, i, n, instr = [], 0, len(s), False
    while i < n:
        c = s[i]
        if instr:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(s[i + 1])
                i += 2
                continue
            if c == '"':
                instr = False
            i += 1
            continue
        if c == '"':
            instr = True
            out.append(c)
            i += 1
        elif s.startswith("//", i):
            while i < n and s[i] != "\n":
                i += 1
        elif s.startswith("/*", i):
            end = s.find("*/", i + 2)
            i = n if end < 0 else end + 2
        elif c == ",":
            j = _skip_ws_and_comments(s, i + 1)
            if not (j < n and s[j] in "}]"):
                out.append(c)
            i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def loads(text):
    """Parse JSONC text; raises ValueError on invalid input."""
    return json.loads(strip(text))


def load(path):
    with open(path) as fh:
        return loads(fh.read())
