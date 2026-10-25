#!/usr/bin/env python3
"""Build Hibiki-<version>-setup.exe: the suite + a bundled Python under %LOCALAPPDATA%\\Programs\\Hibiki, an Inno Setup
installer that checks for REAPER first and runs `hibiki setup` for the user.

    python packaging/windows/build_exe.py [out_dir]          (default dist/)

Staging works anywhere (handy to inspect the payload); compiling bytecode and the installer needs Windows with
Inno Setup 6 (ISCC.exe on PATH, or ISCC=<path>).
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
SUITE = ["reaper_mcp", "brain", "gateway", "panel", "reaper", "LICENSE", "README.md"]
# nothing in the suite uses these; ~30 MB less
PRUNE = ["tcl", "include", "libs", "Scripts", "Lib/test", "Lib/idlelib", "Lib/turtledemo", "Lib/tkinter",
         "Lib/ensurepip", "Lib/lib2to3", "Lib/site-packages/pip"]


# electron/rcedit: sets the icon and version strings of the Hibiki*.exe copies
RCEDIT = ("https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe",
          "3e7801db1a5edbec91b49a24a094aad776cb4515488ea5a4ca2289c400eade2a")


def lock() -> dict:
    return dict(re.findall(r"^(\w+)=(\S+)", (HERE.parent / "python.lock").read_text(), re.M))


def version() -> str:
    return re.search(r'^__version__ = "([^"]+)"', (REPO / "reaper_mcp/__init__.py").read_text(), re.M).group(1)


def numeric(v: str) -> str:
    """VersionInfoVersion wants a.b.c.d: 0.5.0-rc.1 -> 0.5.0.0."""
    parts = re.match(r"(\d+)\.(\d+)\.(\d+)", v).groups()
    return ".".join(parts) + ".0"


def download(url: str, sha256: str) -> Path:
    cache = Path(os.environ.get("PY_CACHE") or Path.home() / ".cache/hibiki")
    cache.mkdir(parents=True, exist_ok=True)
    f = cache / url.rsplit("/", 1)[1]
    if not f.exists():
        with urllib.request.urlopen(url, timeout=300) as r:
            f.with_name(f.name + ".part").write_bytes(r.read())
        os.replace(f.with_name(f.name + ".part"), f)
    got = hashlib.sha256(f.read_bytes()).hexdigest()
    if got != sha256:
        f.unlink()
        raise SystemExit("sha256 mismatch for %s: %s" % (f.name, got))
    return f


def fetch_python(stage: Path) -> None:
    L = lock()
    name = "cpython-%s+%s-x86_64-pc-windows-msvc-install_only_stripped.tar.gz" % (L["PY"], L["TAG"])
    tgz = download("https://github.com/astral-sh/python-build-standalone/releases/download/%s/%s" % (L["TAG"], name),
                   L["SHA_win_x64"])
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(tgz) as t:
            if hasattr(tarfile, "data_filter"):
                t.extractall(tmp, filter="data")
            else:
                t.extractall(tmp)
        shutil.move(str(Path(tmp) / "python"), str(stage / "python"))
    for rel in PRUNE:
        shutil.rmtree(stage / "python" / rel, ignore_errors=True)
    for dll in (stage / "python/DLLs").glob("*"):
        if dll.name.lower().startswith(("_tkinter", "tcl", "tk")):
            dll.unlink()


def make_ico(out: Path) -> None:
    """A .ico whose entries are the PNG icons as they are (Windows reads PNG entries since Vista)."""
    pngs = [(s, (REPO / ("icons/hibiki-%d.png" % s)).read_bytes()) for s in (16, 32, 64, 128, 256)]
    head = struct.pack("<HHH", 0, 1, len(pngs))
    offset, entries = 6 + 16 * len(pngs), b""
    for size, data in pngs:
        entries += struct.pack("<BBBBHHII", size % 256, size % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    out.write_bytes(head + entries + b"".join(d for _, d in pngs))


def brand(stage: Path) -> None:
    """Hibiki.exe (from pythonw.exe: the supervisor, no console) and HibikiConsole.exe (from python.exe: services and
    the CLI). Task Manager and Startup apps show an exe's icon and FileDescription, so they say Hibiki, not Python."""
    py, v = stage / "python", version()
    ico = stage.parent / "hibiki.ico"
    make_ico(ico)
    rcedit = download(*RCEDIT)
    for src, dst in (("pythonw.exe", "Hibiki.exe"), ("python.exe", "HibikiConsole.exe")):
        shutil.copy2(py / src, py / dst)
        args = [str(rcedit), str(py / dst), "--set-icon", str(ico), "--set-file-version", numeric(v),
                "--set-product-version", v]
        for k, val in (("FileDescription", "Hibiki"), ("ProductName", "Hibiki"), ("CompanyName", "yiw190"),
                       ("InternalName", dst[:-4]), ("OriginalFilename", dst)):
            args += ["--set-version-string", k, val]
        subprocess.run(args, check=True)
    ico.unlink()


def stage_suite(stage: Path) -> None:
    app = stage / "app"
    for rel in SUITE:
        src = REPO / rel
        if src.is_dir():
            shutil.copytree(src, app / rel, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "test_*.py", "fake_*"))
        else:
            app.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, app / rel)
    (stage / "bin").mkdir()
    # %~dp0 = this file's folder; -s -E: ignore the user's site-packages and PYTHON* variables
    (stage / "bin/hibiki.cmd").write_text(
        '@echo off\r\n"%~dp0..\\python\\HibikiConsole.exe" -s -E "%~dp0..\\app\\reaper_mcp\\cli.py" %*\r\n')
    (stage / "VERSION").write_text(version() + "\n")


def main() -> int:
    out = Path(sys.argv[1] if len(sys.argv) > 1 else REPO / "dist").resolve()
    out.mkdir(parents=True, exist_ok=True)
    stage = out / "stage-win"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir()
    v = version()
    print("hibiki %s, python %s (%s)" % (v, lock()["PY"], lock()["TAG"]))
    fetch_python(stage)
    stage_suite(stage)
    if os.name != "nt":
        print("staged in %s (bytecode and installer need Windows)" % stage)
        return 0
    brand(stage)
    # the install folder is per user but treat it as read-only: ship the bytecode
    subprocess.run([str(stage / "python/HibikiConsole.exe"), "-m", "compileall", "-q", str(stage / "app")], check=True)
    iscc = os.environ.get("ISCC") or shutil.which("ISCC") or r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
    subprocess.run([iscc, "/Q", "/DAppVersion=" + v, "/DNumVersion=" + numeric(v), "/DStage=" + str(stage),
                    "/DOutDir=" + str(out), str(HERE / "hibiki.iss")], check=True)
    exe = out / ("Hibiki-%s-setup.exe" % v)
    digest = hashlib.sha256(exe.read_bytes()).hexdigest()
    exe.with_name(exe.name + ".sha256").write_text("%s  %s\n" % (digest, exe.name))
    shutil.rmtree(stage, ignore_errors=True)
    print(exe)
    return 0


if __name__ == "__main__":
    sys.exit(main())
