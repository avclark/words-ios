#!/usr/bin/env python3
"""Guard for the verify-script harness: NO shell-interpolated Python, ever.

History: two harness failures came from shell variables interpolated into
Python source ("import json,sys try:" from a mangled newline; braces eaten
by bash 3.2's nested-quote parsing inside $(python3 -c "...")). A previous
validator ast-parsed the sources AS WRITTEN — but interpolated sources
reach Python AS DELIVERED, after bash's version-specific quoting has run
over them, so static parsing can never prove them safe. This checker
therefore enforces the structural rule that replaces validation-by-
simulation:

  RULE: Python source in these scripts must be a LITERAL — a single-quoted
  -c string or a quote-delimited heredoc. Data crosses into Python only
  via environment variables, argv, or stdin. Interpolation into source is
  banned outright, not linted for correctness.

Because every allowed source is a literal, what this file parses is
byte-for-byte what python3 will receive, so ast.parse() here is exact.

Checks, per verify*.sh:
  1. BAN  python3 -c "..." / py "..."   (double-quoted source — bash
     interpolates into code). The py() helper definition itself is exempt.
  2. BAN  python3 ... << EOF            (unquoted heredoc delimiter —
     bash interpolates into the body). <<'EOF' is required.
  3. PARSE every single-quoted -c source and every quoted-heredoc body
     with ast.parse — a literal that doesn't parse is a plain bug.

Run it after ANY edit to a verify script, before running the script.
Exit 0 = clean; exit 1 = violations listed on stdout.
"""

import ast
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
FAILED = False


def violation(path, line, message):
    global FAILED
    FAILED = True
    print(f"VIOLATION {path.name}:{line}: {message}")


def check_banned(path, lines):
    for i, line in enumerate(lines, 1):
        # py() helper definition passes through "$1" — that's the one
        # place a double quote is correct (the argument it receives is
        # itself a literal, enforced at every call site below).
        if re.search(r'^\s*py\(\)', line):
            continue
        if re.search(r'python3\s+-c\s+"', line) or re.search(r'\bpy\s+"', line):
            violation(path, i, 'python source in DOUBLE quotes — bash interpolates '
                               'into code; use a single-quoted source and pass data '
                               'via env/argv/stdin')
        m = re.search(r'python3\b[^#]*<<-?\s*([^\s)]+)', line)
        if m:
            delim = m.group(1)
            if not (delim.startswith("'") or delim.startswith('"')):
                violation(path, i, f'unquoted heredoc delimiter {delim} — bash '
                                   f"interpolates into the body; use <<'{delim}'")


def iter_static_sources(path, text, lines):
    """Yield (line_number, source) for every literal python source."""
    # Single-quoted -c sources (shell single-quoted strings cannot contain
    # single quotes, so "up to the next quote" is exact).
    for m in re.finditer(r"(?:python3\s+-c|\bpy)\s+'([^']*)'", text):
        line = text[:m.start()].count("\n") + 1
        yield line, m.group(1)
    # Quote-delimited heredocs feeding python3.
    i = 0
    while i < len(lines):
        m = re.search(r"python3\b[^#]*<<-?\s*'([^']+)'", lines[i])
        if not m:
            i += 1
            continue
        delim, start = m.group(1), i + 1
        body = []
        j = start
        while j < len(lines) and lines[j].strip() != delim:
            body.append(lines[j])
            j += 1
        if j >= len(lines):
            violation(path, i + 1, f"heredoc '{delim}' never closed")
            return
        yield start + 1, "\n".join(body)
        i = j + 1


def main():
    scripts = sorted(HERE.glob("verify*.sh"))
    if not scripts:
        print("no verify*.sh found next to the checker", file=sys.stderr)
        return 1
    total = 0
    for path in scripts:
        text = path.read_text()
        lines = text.split("\n")
        check_banned(path, lines)
        for line, src in iter_static_sources(path, text, lines):
            if not src.strip():
                continue
            total += 1
            try:
                ast.parse(src)
            except SyntaxError as e:
                violation(path, line, f"literal python does not parse: {e}")
    if FAILED:
        return 1
    print(f"OK: {len(scripts)} scripts, {total} literal python blocks, "
          f"all parse; no interpolated python anywhere")
    return 0


if __name__ == "__main__":
    sys.exit(main())
