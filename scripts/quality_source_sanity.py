#!/usr/bin/env python3
"""Safe syntax baseline over tracked source files; never execute inspected code.

Intentionally small: Python AST, JSON parser, and .NET project XML. This is NOT
a compilation, test suite, live application, or release acceptance.
"""
from __future__ import annotations

import ast
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
IGNORED = {".git", ".tools", "node_modules", "venv", ".venv", ".tox",
           "__pycache__", "bin", "obj", "build", "dist", "publish", "vendor",
           "fixtures", "testdata", "test-data", "decompiled", "extracted"}
VALID_SUFFIXES = {".py", ".json", ".csproj"}
MAX_FILE_BYTES = 6 * 1024 * 1024


def inspect(root: Path):
    git = subprocess.run(["git", "-C", str(root), "ls-files", "-z"],
                         capture_output=True, check=False)
    if git.returncode:
        raise RuntimeError("Unable to enumerate tracked source files")
    checked = {"python": 0, "json": 0, "csproj": 0}
    errors = []
    omitted = 0
    for rel in git.stdout.split(b"\0"):
        if not rel:
            continue
        name = rel.decode("utf-8", errors="surrogateescape")
        path = Path(name)
        if set(path.parts) & IGNORED or path.suffix.lower() not in VALID_SUFFIXES:
            continue
        full = root / path
        try:
            if not full.is_file() or full.stat().st_size > MAX_FILE_BYTES:
                omitted += 1
                continue
            data = full.read_text(encoding="utf-8-sig")
            suffix = path.suffix.lower()
            if suffix == ".py":
                ast.parse(data, filename=name)
                checked["python"] += 1
            elif suffix == ".json":
                json.loads(data)
                checked["json"] += 1
            elif suffix == ".csproj":
                ET.fromstring(data)
                checked["csproj"] += 1
        except (SyntaxError, json.JSONDecodeError, ET.ParseError, UnicodeError, OSError) as exc:
            errors.append(f"{name}: {type(exc).__name__}: {str(exc)[:180]}")
    return checked, omitted, errors


def main():
    try:
        counts, omitted, errors = inspect(ROOT)
    except RuntimeError as exc:
        print("SOURCE_SANITY_ERROR=" + str(exc), file=sys.stderr)
        return 2
    print("TRACKED_PYTHON=" + str(counts["python"]))
    print("TRACKED_JSON=" + str(counts["json"]))
    print("TRACKED_CSPROJ=" + str(counts["csproj"]))
    print("OMITTED=" + str(omitted))
    for error in errors[:25]:
        print("INVALID " + error, file=sys.stderr)
    if errors:
        print("SOURCE_SANITY_FAIL=" + str(len(errors)))
        return 1
    if not sum(counts.values()):
        print("SOURCE_SANITY_NOT_CONFIGURED")
        return 2
    print("SOURCE_SANITY_PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
