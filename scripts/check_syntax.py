#!/usr/bin/env python3
"""Syntax gate for the parts no test imports: every .lua compiles under Lua 5.4 (REAPER's version) and calls no
top-level local function above its declaration (that call hits a nil global at runtime), every .jsfx has no
exponent literal (EEL2 can't parse one and REAPER drops the section silently), every .sh parses and is committed
executable.
Needs `pip install lupa`."""
import re
import subprocess
import sys
from pathlib import Path

import lupa.lua54 as lua54

ROOT = Path(__file__).resolve().parents[1]
SKIP = {".git", ".venv", "node_modules"}


def files(ext):
    return sorted(p for p in ROOT.rglob("*" + ext) if not SKIP & set(p.relative_to(ROOT).parts))


rt = lua54.LuaRuntime()
compile_lua = rt.eval("function(src, name) local f, e = load(src, '=' .. name) return f and '' or e end")


def use_before_declare(src):
    lines = src.splitlines()
    decl = {}
    for i, line in enumerate(lines):
        m = re.match(r"^local function (\w+)", line) or re.match(r"^local (\w+)\s*=\s*function", line)
        if m:
            decl.setdefault(m.group(1), i)
        m = re.match(r"^local ([\w, ]+)$", line)  # forward declaration
        if m:
            for n in m.group(1).split(","):
                decl.setdefault(n.strip(), i)
    out = []
    for i, line in enumerate(lines):
        code = line.split("--")[0]
        for name, d in decl.items():
            if i < d and re.search(r"(?<![\w.:])" + name + r"\s*\(", code):
                out.append("%s() called on line %d, declared on line %d" % (name, i + 1, d + 1))
    return "; ".join(out)


bad = 0
for p in files(".lua"):
    src = p.read_text()
    err = compile_lua(src, str(p.relative_to(ROOT))) or use_before_declare(src)
    print(("  ok   " if not err else "  FAIL ") + str(p.relative_to(ROOT)) + ("" if not err else "  " + err))
    bad += bool(err)
# JSFX (EEL2): REAPER silently skips a section that fails to compile; 1e-20 literals did that to the meter
for p in files(".jsfx"):
    errs = []
    for n, line in enumerate(p.read_text().splitlines(), 1):
        code = line.split("//")[0]
        if code.startswith(("desc:", "options:", "in_pin:", "out_pin:", "slider", "import ", "filename:", "tags:")):
            continue
        if re.search(r"(?<![\w.])\d+(\.\d*)?[eE][-+]?\d", code):
            errs.append("line %d: exponent literal (EEL2 has none; write 10 ^ (-n))" % n)
    print(("  ok   " if not errs else "  FAIL ") + str(p.relative_to(ROOT)) + ("" if not errs else "  " + "; ".join(errs)))
    bad += bool(errs)
for p in files(".sh") + sorted((ROOT / "packaging/macos/scripts").glob("*")):
    r = subprocess.run(["bash", "-n", str(p)], capture_output=True, text=True)
    print(("  ok   " if r.returncode == 0 else "  FAIL ") + str(p.relative_to(ROOT)) + ("" if r.returncode == 0 else "  " + r.stderr.strip()))
    bad += r.returncode != 0
# git keeps the exec bit; an edit that rewrites a file can drop it (build_pkg.sh lost it and the release build
# failed with "Permission denied"), so every shell script must be committed as 100755
staged = subprocess.run(["git", "ls-files", "-s"], cwd=ROOT, capture_output=True, text=True).stdout.splitlines()
for line in staged:
    meta, path = line.split("\t", 1)
    if path.endswith(".sh") or path.startswith("packaging/macos/scripts/"):
        ok = meta.split()[0] == "100755"
        print(("  ok   " if ok else "  FAIL ") + path + ("" if ok else "  not executable in git (git update-index --chmod=+x)"))
        bad += not ok
print("all passed" if not bad else "%d failed" % bad)
sys.exit(1 if bad else 0)
