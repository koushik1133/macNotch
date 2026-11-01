#!/usr/bin/env python3
"""Check SparkV's Localizable.strings against the source.

Usage (from the repo root):
    python3 -I Sources/Labs/Localization/Scripts/check_strings.py [--missing LANG]

Reports, per language: how many keys are translated, keys whose format
specifiers differ from the English key (a crash risk), and keys that no
longer appear in Sources (stale). Exit status 1 on any specifier mismatch
or on a .strings file plutil cannot read. --missing LANG prints the
untranslated user-visible strings for that language, one per line, as a
worklist for translators.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import extract_strings  # noqa: E402

SPEC = re.compile(r"%(?:(\d+)\$)?(@|lld|ld|d|lf|f|\.\d+f|llu|lu|u)")
IDENT = re.compile(r"^[A-Za-z0-9]+(\.[A-Za-z0-9_-]+)+$")


def specifiers(s):
    """Specifier types in argument order (positional ones placed by index)."""
    s = s.replace("%%", "")
    found = list(SPEC.finditer(s))
    if any(m.group(1) for m in found):
        slots = {}
        for m in found:
            slots[int(m.group(1) or 0)] = m.group(2)
        return [slots[k] for k in sorted(slots)]
    return [m.group(2) for m in found]


def compatible(key_specs, value_specs):
    """Same arguments in the same types; a translation may drop trailing %@
    arguments (English plural suffixes), which String(format:) ignores."""
    if value_specs == key_specs:
        return True
    n = len(value_specs)
    return n < len(key_specs) and key_specs[:n] == value_specs and all(t == "@" for t in key_specs[n:])


def unescape(s):
    """A Swift string literal body as the runtime string SwiftUI looks up."""
    out, i = [], 0
    simple = {"n": "\n", "t": "\t", '"': '"', "\\": "\\", "'": "'", "0": "\0", "r": "\r"}
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "u" and s[i + 2:i + 3] == "{":
                j = s.index("}", i)
                out.append(chr(int(s[i + 3:j], 16)))
                i = j + 1
                continue
            out.append(simple.get(n, c + n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def load_strings(path):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"plutil cannot read {path}: {out.stderr.strip()}")
    return json.loads(out.stdout)


def source_keys(sources):
    with tempfile.TemporaryDirectory() as tmp:
        cat = os.path.join(tmp, "catalog.json")
        subprocess.run([sys.executable, "-I", os.path.join(HERE, "extract_strings.py"), sources, cat],
                       check=True, capture_output=True)
        catalog = json.load(open(cat, encoding="utf-8"))
    keys = {}
    for raw, meta in catalog.items():
        key = unescape(raw)
        if not IDENT.match(key):
            keys[key] = meta
    return keys


def main():
    root = os.getcwd()
    res = os.path.join(root, "Resources")
    langs = sorted(d[:-6] for d in os.listdir(res) if d.endswith(".lproj"))
    src = source_keys(os.path.join(root, "Sources"))
    bad = 0
    if "--missing" in sys.argv:
        lang = sys.argv[sys.argv.index("--missing") + 1]
        table = load_strings(os.path.join(res, f"{lang}.lproj", "Localizable.strings"))
        for key in sorted(src):
            if key not in table:
                print(key)
        return 0
    for lang in langs:
        path = os.path.join(res, f"{lang}.lproj", "Localizable.strings")
        if not os.path.exists(path):
            continue
        table = load_strings(path)
        mismatched = [k for k, v in table.items() if not compatible(specifiers(k), specifiers(v))]
        stale = [k for k in table if k not in src]
        covered = sum(1 for k in src if k in table)
        print(f"{lang}: {covered}/{len(src)} source strings translated, "
              f"{len(mismatched)} specifier mismatches, {len(stale)} keys not in Sources")
        for k in mismatched[:20]:
            print(f"  MISMATCH {k!r} -> {table[k]!r}")
        bad += len(mismatched)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
