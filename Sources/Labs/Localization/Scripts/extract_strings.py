#!/usr/bin/env python3
"""Extract SparkV's user-visible string literals into a catalog.

Usage:
    python3 -I extract_strings.py <Sources dir> [<Sources dir> ...] <out catalog.json>

The file is tokenized (comments, string literals with nested interpolations,
identifiers, brackets), so calls that span several lines, quotes inside
`\\( ... )` interpolations and literals in both arms of `?:` / `??` are all
seen.

What counts as user-visible:
  * direct  - every literal in the first, unlabelled argument of a SwiftUI
              view or modifier that SwiftUI looks up as a LocalizedStringKey
              by itself: Text, Button, Label, Toggle, Picker, Section,
              TextField, SecureField, Menu, LabeledContent, Stepper,
              DisclosureGroup, GroupBox, Link, LocalizedStringKey,
              .help, .accessibilityLabel/Hint/Value, .navigationTitle,
              .alert, .confirmationDialog, and String(localized:). Literals
              nested inside another call in that argument
              (`Text(String(format: "..."))`) are not keys and are skipped.
              `Text(verbatim:)` and other labelled first arguments are skipped.
              Also `"...".sparkVLocalized`, SparkV's lookup for String values.
  * arg     - literals passed to the labelled arguments SparkV's own rows,
              cards and tiles take as String (title:, detail:, subtitle:, ...).
              These are translated once the component reads them through
              `sparkVLocalized` (see INTEGRATION.md). Arguments of logging
              calls (AppLog, Logger, print) are skipped.

Interpolations become format specifiers the way SwiftUI builds the key of
an interpolated LocalizedStringKey: `\\(x, specifier: "%.1f")` keeps its
specifier, an expression that is clearly an integer becomes %lld, anything
else %@. A wrong guess only means that string falls back to English.
"""
import json
import os
import re
import sys

DIRECT_VIEWS = set((
    "Text Button Label Toggle Picker Section TextField SecureField Menu "
    "LabeledContent Stepper DisclosureGroup GroupBox Link LocalizedStringKey"
).split())
DIRECT_MODIFIERS = set((
    "help accessibilityLabel accessibilityHint accessibilityValue "
    "navigationTitle alert confirmationDialog"
).split())
ARG_LABELS = set((
    "title detail subtitle help label caption placeholder message hint note "
    "headline summary prompt emptyTitle emptyDetail"
).split())
LOG_CALLEES = {"AppLog", "Logger", "log", "logger", "print", "debugPrint", "NSLog", "os_log", "assert",
               "precondition", "fatalError", "assertionFailure", "preconditionFailure"}

INT_NAMES = (
    r"count|n|i|index|idx|minutes|seconds|hours|days|total|number|remaining|percent|"
    r"level|step|attempt|page|pages|rows|capacity|due|unfiled|waiting|running|severe|"
    r"mine|saved|used|more|moreMeetings|extraCount|secondsLeft|batteryCutoff"
)
INT_HINT = re.compile(
    r"(\.count$|Count$|Index$|Minutes$|Seconds$|Hours$|Days$|Number$|Percent$|Limit$|"
    r"(?:^|\.)max[A-Z]\w*$|(?:^|\.)(?:" + INT_NAMES + r")$|^Int\(|^max\(0, Int\(|"
    r"\.(?:totalSteps|csvRows|todaySessions|longBreakEvery|rainThreshold|maxPages|maxDepth|"
    r"rows|capacity|itemCount|healedCount)$|calendar\.component\()"
)
INT_ARITH = re.compile(r"^\(?[\w.?]+(?:\s*\?\?\s*0\))?\s*[-+]\s*(?:\d+|[\w.]+)$")
INT32_HINT = re.compile(r"(^errno$|terminationStatus$)")


# ---------------------------------------------------------------- tokenizer

def _skip_literal(src, i):
    """src[i] == '"' starts a single-line literal. Return index after it.
    `\\( ... )` interpolations are skipped as balanced code, so a quote inside
    one does not end the literal."""
    n = len(src)
    j = i + 1
    while j < n:
        c = src[j]
        if c == "\\" and j + 1 < n:
            if src[j + 1] == "(":
                j = _skip_code(src, j + 2)
                continue
            j += 2
            continue
        if c == '"':
            return j + 1
        if c == "\n":
            return j  # unterminated; give up on this line
        j += 1
    return n


def _skip_code(src, j):
    """Skip balanced code after an interpolation's '(' up to its ')'."""
    n, depth = len(src), 1
    while j < n and depth:
        c = src[j]
        if c == '"':
            j = _skip_literal(src, j)
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        j += 1
    return j


def tokenize(src):
    """Yield (kind, text) with kind in str/ident/punct. Comments, multi-line
    and raw literals are dropped."""
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        if src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if src.startswith('"""', i):
            j = src.find('"""', i + 3)
            i = n if j < 0 else j + 3
            yield ("other", "")
            continue
        if c == "#" and i + 1 < n and src[i + 1] in '#"':
            m = re.match(r'(#+)"', src[i:])
            if m:
                close = '"' + m.group(1)
                j = src.find(close, i + len(m.group(0)))
                i = n if j < 0 else j + len(close)
                yield ("other", "")
                continue
        if c == '"':
            j = _skip_literal(src, i)
            body = src[i + 1 : j - 1] if j <= n and src[j - 1 : j] == '"' else src[i + 1 : j]
            yield ("str", body)
            i = j
            continue
        if c.isalpha() or c == "_" or c == "@" or c == "$":
            m = re.match(r"[@$]?[A-Za-z_][A-Za-z0-9_]*", src[i:])
            if m:
                yield ("ident", m.group(0))
                i += len(m.group(0))
                continue
        if c.isdigit():
            m = re.match(r"[0-9][0-9_.a-fA-Fx]*", src[i:])
            yield ("other", m.group(0))
            i += len(m.group(0))
            continue
        for op in ("==", "!=", "<=", ">=", "??", "->", "&&", "||", "..."):
            if src.startswith(op, i):
                yield ("punct", op)
                i += len(op)
                break
        else:
            yield ("punct", c)
            i += 1


# ---------------------------------------------------------------- keys

def split_interpolations(body):
    """Yield ('text', s) and ('expr', s) parts of a Swift literal body."""
    i, n, buf = 0, len(body), []
    while i < n:
        c = body[i]
        if c == "\\" and i + 1 < n and body[i + 1] == "(":
            if buf:
                yield ("text", "".join(buf))
                buf = []
            j = _skip_code(body, i + 2)
            yield ("expr", body[i + 2 : j - 1])
            i = j
            continue
        if c == "\\" and i + 1 < n:
            buf.append(body[i : i + 2])
            i += 2
            continue
        buf.append(c)
        i += 1
    if buf:
        yield ("text", "".join(buf))


def specifier_for(expr):
    m = re.search(r'specifier:\s*"([^"]+)"', expr)
    if m:
        return m.group(1)
    if "format:" in expr:
        return "%@"
    e = expr.strip()
    if INT32_HINT.search(e):
        return "%d"
    if INT_HINT.search(e):
        return "%lld"
    if INT_ARITH.match(e) and re.search(r"(count|index|number|offset|row|id|max\w*|i)\b", e, re.I):
        return "%lld"
    return "%@"


def key_for(body):
    """Return (key, has_interpolation) for a literal body."""
    parts = list(split_interpolations(body))
    if not any(kind == "expr" for kind, _ in parts):
        return body, False
    out = []
    for kind, s in parts:
        out.append(s.replace("%", "%%") if kind == "text" else specifier_for(s))
    return "".join(out), True


def is_user_text(key):
    stripped = re.sub(r'%(?:lld|ld|d|@|\.?\d*f|lf|%)', "", key)
    letters = re.findall(r'[^\W\d_]', stripped)
    if len(letters) < 2:
        return False
    if re.fullmatch(r'[a-z0-9_.\-]+', key) and "." in key:  # symbol / bundle ids
        return False
    if re.fullmatch(r'[a-z]+(?:[A-Z][a-z0-9]*)+', key):  # camelCase identifiers
        return False
    if key.startswith(("http://", "https://", "x-apple", "/", "com.", "~/")):
        return False
    if re.fullmatch(r'[a-z0-9]+(?:\.[a-z0-9]+)+(?:\.fill)?', key):
        return False
    return True


# ---------------------------------------------------------------- scanner

OPEN = {"(": ")", "[": "]", "{": "}"}


def argument_literals(toks, start, stop_on_equals=False):
    """Literals of the expression starting at toks[start], up to a ',' or a
    closing bracket at depth 0. Only literals not nested inside another call,
    array or closure are returned (grouping parentheses are transparent)."""
    out, stack, k = [], [], start
    while k < len(toks):
        kind, text = toks[k]
        if kind == "punct" and text in OPEN:
            prev = toks[k - 1] if k > 0 else ("punct", "")
            is_call = text != "(" or prev[0] in ("ident", "str") or prev[1] in (")", "]", "?", "!", ">")
            stack.append(is_call)
        elif kind == "punct" and text in (")", "]", "}"):
            if not stack:
                break
            stack.pop()
        elif kind == "punct" and text == "," and not stack:
            break
        elif stop_on_equals and kind == "punct" and text == "=" and not stack:
            return []
        elif kind == "str" and not any(stack):
            out.append(text)
        k += 1
    return out


def callee_before(toks, k):
    """Dotted name ending just before toks[k] == '(' (e.g. 'AppLog.log')."""
    parts, j = [], k - 1
    while j >= 0 and toks[j][0] == "ident":
        parts.append(toks[j][1])
        if j - 1 >= 0 and toks[j - 1] == ("punct", "."):
            j -= 2
            continue
        break
    return list(reversed(parts))


def literals_in(src):
    """Yield (kind, literal body, token index) for every user-visible literal."""
    toks = list(tokenize(src))
    # Calls whose arguments are log text, tracked by their '(' token index.
    call_stack = []
    for k, (kind, text) in enumerate(toks):
        if kind == "punct" and text in OPEN:
            name = callee_before(toks, k) if text == "(" else []
            call_stack.append(bool(name) and (name[0] in LOG_CALLEES or name[-1] in LOG_CALLEES))
        elif kind == "punct" and text in (")", "]", "}"):
            if call_stack:
                call_stack.pop()
        if kind != "punct" or text != "(" or k == 0:
            continue
        prev = toks[k - 1]
        if prev[0] != "ident":
            continue
        before = toks[k - 2] if k >= 2 else ("punct", "")
        dotted = before == ("punct", ".")
        name = prev[1]
        first = toks[k + 1] if k + 1 < len(toks) else ("punct", ")")
        labelled = first[0] == "ident" and k + 2 < len(toks) and toks[k + 2] == ("punct", ":")
        direct = False
        if not dotted and name in DIRECT_VIEWS and not labelled:
            direct = True
        elif dotted and name in DIRECT_MODIFIERS and not labelled:
            direct = True
        if direct:
            for body in argument_literals(toks, k + 1):
                yield ("direct", body, k)
        if not dotted and name == "String" and labelled and first[1] == "localized":
            for body in argument_literals(toks, k + 3):
                yield ("direct", body, k)
    # "Literal".sparkVLocalized (SparkV's own lookup for String values).
    for k in range(len(toks) - 2):
        if toks[k][0] == "str" and toks[k + 1] == ("punct", ".") and toks[k + 2] == ("ident", "sparkVLocalized"):
            yield ("direct", toks[k][1], k)
    # Labelled component arguments: `title: "..."` inside a call.
    stack = []
    for k, (kind, text) in enumerate(toks):
        if kind == "punct" and text in OPEN:
            name = callee_before(toks, k) if text == "(" else []
            stack.append((text, bool(name) and (name[0] in LOG_CALLEES or name[-1] in LOG_CALLEES)))
            continue
        if kind == "punct" and text in (")", "]", "}"):
            if stack:
                stack.pop()
            continue
        if kind != "ident" or text not in ARG_LABELS:
            continue
        if not stack or stack[-1][0] != "(" or any(is_log for _, is_log in stack):
            continue
        if k + 1 >= len(toks) or toks[k + 1] != ("punct", ":"):
            continue
        prev = toks[k - 1]
        if prev not in (("punct", "("), ("punct", ",")):
            continue
        for body in argument_literals(toks, k + 2, stop_on_equals=True):
            yield ("arg", body, k)


def scan(sources):
    catalog = {}
    for src_dir in sources:
        for root, dirs, files in os.walk(src_dir):
            dirs.sort()
            for name in sorted(files):
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(root, name)
                rel = os.path.relpath(path, src_dir)
                with open(path, encoding="utf-8") as fh:
                    src = fh.read()
                for kind, body, _ in literals_in(src):
                    key, interp = key_for(body)
                    if not is_user_text(key):
                        continue
                    entry = catalog.setdefault(key, {"kind": kind, "files": [], "interpolated": interp})
                    if kind == "direct":
                        entry["kind"] = "direct"
                    if len(entry["files"]) < 3 and rel not in entry["files"]:
                        entry["files"].append(rel)
    return catalog


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    sources, out = sys.argv[1:-1], sys.argv[-1]
    catalog = scan(sources)
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(dict(sorted(catalog.items())), fh, ensure_ascii=False, indent=1)
    direct = sum(1 for v in catalog.values() if v["kind"] == "direct")
    print(f"{len(catalog)} strings ({direct} direct, {len(catalog) - direct} component args)")


if __name__ == "__main__":
    main()
