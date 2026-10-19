#!/usr/bin/env python3
"""Validate cybersyn/changelog.txt and print version blocks.

  changelog.py check   [--file F] [--version V] [--top]
  changelog.py section VERSION [--file F] [--markdown]

`check` enforces the rules Factorio applies when it parses the file
(https://lua-api.factorio.com/latest/auxiliary/changelog-format.html), because
the game rejects the whole changelog on the first violation and the in-game
changelog view then shows nothing. Run it with `python3 -I`.
"""
import argparse
import os
import re
import sys

SEPARATOR = "-" * 99
VERSION_RE = re.compile(r"^Version: (\d+)\.(\d+)\.(\d+)$")
CATEGORY_RE = re.compile(r"^  [^ ].*:$")
ENTRY_RE = re.compile(r"^    - \S")
CONTINUATION_RE = re.compile(r"^      \S")

DEFAULT_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "cybersyn", "changelog.txt")


def read_lines(path):
    with open(path, encoding="utf-8", newline="") as f:
        text = f.read()
    if text.startswith("﻿"):
        text = text[1:]
    return text.replace("\r\n", "\n").split("\n")


def parse_blocks(lines):
    """Return [(version, start_index, end_index)] where indices cover the block including its separator."""
    starts = [i for i, line in enumerate(lines) if line == SEPARATOR]
    blocks = []
    for n, start in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        m = VERSION_RE.match(lines[start + 1]) if start + 1 < len(lines) else None
        blocks.append((".".join(m.groups()) if m else None, start, end))
    return blocks


def check(lines, version=None, top=False):
    errors = []

    def err(i, msg):
        errors.append(f"line {i + 1}: {msg}")

    for i, line in enumerate(lines):
        if "\t" in line:
            err(i, "tab character")
        if line != line.rstrip(" "):
            err(i, "trailing space")
        if line.startswith("-") and line != SEPARATOR and set(line) == {"-"}:
            err(i, f"separator has {len(line)} dashes, expected 99")

    if not lines or lines[0] != SEPARATOR:
        err(0, "file must start with a 99-dash separator")

    blocks = parse_blocks(lines)
    seen = set()
    for ver, start, end in blocks:
        if ver is None:
            err(start + 1, "separator must be followed directly by 'Version: a.b.c'")
            continue
        if ver == "0.0.0":
            err(start + 1, "version 0.0.0 is invalid")
        if ver in seen:
            err(start + 1, f"version {ver} appears twice")
        seen.add(ver)
        body_start = start + 2
        if body_start < end and lines[body_start].startswith("Date:"):
            body_start += 1
        category = None
        entries = set()
        last_was_entry = False
        for i in range(body_start, end):
            line = lines[i]
            if line == "":
                last_was_entry = False
                continue
            if CATEGORY_RE.match(line):
                category = line.strip()
                entries = set()
                last_was_entry = False
            elif ENTRY_RE.match(line):
                if category is None:
                    err(i, "entry before any category line")
                if line in entries:
                    err(i, f"duplicate entry in {category}")
                entries.add(line)
                last_was_entry = True
            elif CONTINUATION_RE.match(line):
                if not last_was_entry:
                    err(i, "continuation line without an entry above it")
            else:
                err(i, "expected '  Category:', '    - entry' or a 6-space continuation")

    if version is not None:
        if version not in seen:
            errors.append(f"no 'Version: {version}' block")
        elif top and blocks and blocks[0][0] != version:
            errors.append(f"the first block is {blocks[0][0]}, expected {version} on top")
    return errors


def section(lines, version):
    for ver, start, end in parse_blocks(lines):
        if ver == version:
            body = lines[start + 1:end]
            while body and body[-1] == "":
                body.pop()
            return "\n".join(body)
    return None


def to_markdown(block):
    """GitHub renders 4-space indented lines as code, so rewrite the block as Markdown lists."""
    out = []
    for line in block.split("\n")[1:]:
        if line.startswith("Date:"):
            out.append(f"_Released {line[5:].strip()}_")
        elif CATEGORY_RE.match(line):
            out += ["", f"### {line.strip()[:-1]}"]
        elif ENTRY_RE.match(line):
            out.append(f"- {line[6:]}")
        elif CONTINUATION_RE.match(line) and out:
            out[-1] += " " + line.strip()
    return "\n".join(out).strip()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--file", default=DEFAULT_FILE)
    c.add_argument("--version")
    c.add_argument("--top", action="store_true", help="also require --version to be the first block")
    s = sub.add_parser("section")
    s.add_argument("version")
    s.add_argument("--file", default=DEFAULT_FILE)
    s.add_argument("--markdown", action="store_true", help="GitHub release-notes form")
    args = ap.parse_args()

    lines = read_lines(args.file)
    if args.cmd == "check":
        errors = check(lines, args.version, args.top)
        for e in errors:
            print(f"{args.file}: {e}", file=sys.stderr)
        if errors:
            return 1
        print(f"{args.file}: OK")
        return 0
    text = section(lines, args.version)
    if text is None:
        print(f"{args.file}: no 'Version: {args.version}' block", file=sys.stderr)
        return 1
    print(to_markdown(text) if args.markdown else text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
