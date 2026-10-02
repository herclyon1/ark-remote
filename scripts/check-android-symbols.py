#!/usr/bin/env python3
"""Fail when Sources/ name an SF Symbol that SkipUI cannot draw on Android.

skip-ui maps `Image(systemName:)` / `Label(systemImage:)` through the `case "…"` table in
Components/Image.swift (composeSymbolName + composeImageVector); a name outside it is drawn as a black
warning triangle (log "Unable to find system image named"). This checks every string literal after
`systemName:`, `systemImage:` and `android:` in Sources/**/*.swift against that table. Code inside
`#if !os(Android)` (or the `#else` of `#if os(Android)`) is iOS-only and skipped.

Run from the repo root after a build has fetched the checkouts:  python3 scripts/check-android-symbols.py
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLE = ROOT / ".build/checkouts/skip-ui/Sources/SkipUI/SkipUI/Components/Image.swift"

if not TABLE.exists():
    sys.exit(f"missing {TABLE.relative_to(ROOT)}: run `swift build` (or `skip export`) first")
known = set(re.findall(r'case "([^"]+)"', TABLE.read_text()))

ARG = re.compile(r'\b(?:systemName|systemImage|android):([^)]*)')
LIT = re.compile(r'"([^"\\]*)"')

bad = []
for path in sorted((ROOT / "Sources").rglob("*.swift")):
    stack = []  # per open #if: True = Android code, False = not compiled on Android
    for n, line in enumerate(path.read_text().splitlines(), 1):
        s = line.strip()
        if s.startswith("#if "):
            cond = s[4:].replace(" ", "")
            stack.append({"os(Android)": True, "!os(Android)": False}.get(cond, None))
            continue
        if s.startswith("#elseif"):
            continue  # treated as part of the open #if; no #elseif os(Android) in Sources
        if s.startswith("#else") and stack:
            if stack[-1] is not None:
                stack[-1] = not stack[-1]
            continue
        if s.startswith("#endif") and stack:
            stack.pop()
            continue
        if False in stack or s.startswith("//"):
            continue
        for m in ARG.finditer(line):
            for name in LIT.findall(m.group(1)):
                if name not in known:
                    bad.append(f"{path.relative_to(ROOT)}:{n}: \"{name}\" is not in skip-ui's symbol table")

if bad:
    print("\n".join(bad))
    sys.exit(1)
print(f"ok: every literal symbol name is drawable on Android ({len(known)} names in skip-ui's table)")
