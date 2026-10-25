"""hibiki: per-user install, health check, client registration and removal on macOS.

Everything runs from ROOT, the folder that holds reaper_mcp/, brain/, gateway/, panel/, reaper/ and scripts/ — the .pkg
payload or a git clone — with the Python that runs this module, so LaunchAgents point at whichever of the two ran
`setup`. Stdlib only (3.9+).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from reaper_mcp import __version__

ROOT = Path(__file__).resolve().parents[1]
PKG_ID = "io.github.yiw190.hibiki"
PKG_ROOT = Path("/Library/Application Support/Hibiki")
LABEL = "com.hibiki."
MCP_LABEL, GW_LABEL, WD_LABEL = LABEL + "reaper-mcp", LABEL + "agent-gateway", LABEL + "reaper-watchdog"
# LaunchAgents from before: hand-made ones, then the suite's own under its old name (gamut-reaper-suite, renamed
# Hibiki 2026-10-21); same jobs, replaced on setup
LEGACY_LABELS = {"com.yitian.reaper-mcp": MCP_LABEL, "com.yitian.reaper-watchdog": WD_LABEL,
                 "com.gamut-reaper-suite.reaper-mcp": MCP_LABEL, "com.gamut-reaper-suite.agent-gateway": GW_LABEL,
                 "com.gamut-reaper-suite.reaper-watchdog": WD_LABEL}
GW_PORT = 47892
TUNNEL_LABEL = LABEL + "cloudflared"  # scripts/macos-host-bootstrap.sh

WINDOWS = sys.platform == "win32"
IMGUI_VERSION = "0.10.0.5"
IMGUI_SHA256 = {  # by release file name
    "reaper_imgui-arm64.dylib": "1f90cf004c0bbada45358609c943f601b2cb0e625ecf7739ae5df8708ab705ae",
    "reaper_imgui-x86_64.dylib": "2209fec3eae03f22fe94b9d2681b04e21f41c7d4587cb0d69e4eb72e39a64e65",
    "reaper_imgui-x64.dll": "800b216e0937bf5bb6b08ba2767b7b974a746b3fc3b54943b4d3011da0a68f2a",
}
# `require 'imgui'` loads this shim from ImGui_GetBuiltinPath() (Scripts/ReaTeam Extensions/API). It isn't a release
# asset: ReaPack fetches it from the source tree, so without ReaPack the panel can't start unless setup installs it.
IMGUI_SHIM_URL = "https://raw.githubusercontent.com/cfillion/reaimgui/v%s/shims/imgui.lua" % IMGUI_VERSION
IMGUI_SHIM_SHA256 = "b73dac959d973e2d8fb47ea73588e84f81d4a3c7fb962c327d08427c2454b093"
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"  # Windows: the supervisor starts at logon from here
RUN_VALUE = "Hibiki"
STARTUP_BEGIN = "-- >>> hibiki (managed by hibiki setup; edits inside are overwritten)"
STARTUP_END = "-- <<< hibiki"
LEGACY_STARTUP = (("-- >>> gamut-reaper-suite", "-- <<< gamut-reaper-suite"),)  # (begin prefix, end prefix)
# hand-copied hooks shipped before the managed block existed; setup swaps an exact copy for the managed block
LEGACY_HOOKS = ("""-- reaper-mcp: start the MCP bridge automatically every time REAPER launches (installed 2026-10-18).
local path = reaper.GetResourcePath() .. "/Scripts/reaper_mcp_bridge.lua"
local id = reaper.NamedCommandLookup("_RS70b9b9e08b3a1b47bef354e4c40290516371e9f9")
if id == 0 then id = reaper.AddRemoveReaScript(true, 0, path, true) end
if id ~= 0 then reaper.Main_OnCommand(id, 0) end

-- Gamut Chat panel: open on launch (2026-10-18). Toggle check so a second run never closes it.
do
  local gpath = reaper.GetResourcePath() .. "/Scripts/GamutChat/GamutChat.lua"
  local gid = reaper.NamedCommandLookup("_RS24f59c095963d6e7a1cf187e50fff047f87d7381")
  if gid == 0 then gid = reaper.AddRemoveReaScript(true, 0, gpath, true) end
  if gid ~= 0 and reaper.GetToggleCommandState(gid) ~= 1 then reaper.Main_OnCommand(gid, 0) end
end""",)
LEGACY_PANEL_DIRS = ("GamutChat",)
PANEL_FILES = ("Hibiki.lua", "context.lua", "markdown.lua", "studio.lua")  # Scripts/Hibiki/: the panel loads its parts next to itself
METER_JSFX = "Hibiki_Meter.jsfx"  # Effects/Hibiki/: the panel puts it on the master's monitoring FX

# exact versions; bump deliberately. Only minimax runs install scripts: better-sqlite3 fetches its native
# binding and @vscode/ripgrep fetches rg. kimi's postinstall only renames a legacy shim and node-pty ships
# darwin/win32 prebuilds; grok's launcher unpacks its binary on first run.
ACP_AGENTS = {
    "codex": {"package": "@agentclientprotocol/codex-acp", "version": "2.2.2", "bin": "codex-acp", "args": [],
              "name": "Codex", "description": "OpenAI Codex CLI over ACP"},
    "claude": {"package": "@agentclientprotocol/claude-agent-acp", "version": "0.94.0", "bin": "claude-agent-acp", "args": [],
               "name": "Claude Code", "description": "Claude Code (Claude Agent SDK) over ACP; uses the local claude login",
               "path_extra": ["~/.local/bin"]},
    "kimi": {"package": "@moonshot-ai/kimi-code", "version": "2.3.0", "bin": "kimi", "args": ["acp"],
             "name": "Kimi", "description": "Kimi Code CLI over ACP; uses the Kimi Code subscription login",
             "loginVariants": [
                 {"id": "global", "name": "Log in with kimi.ai", "description": "International account (kimi.ai)",
                  "args": ["--region", "global"]},
                 {"id": "cn", "name": "Log in with kimi.com", "description": "Mainland China account (kimi.com)",
                  "args": ["--region", "mainland-cn"]}]},
    # declares no ACP auth method; its login is `mcode acp login [--region global]`
    "minimax": {"package": "@minimax-ai/code", "version": "0.6.12", "bin": "mcode", "args": ["acp"],
                "allow_scripts": "@minimax-ai/code,better-sqlite3,@vscode/ripgrep",
                "name": "MiniMax", "description": "MiniMax Code CLI over ACP; uses your MiniMax account",
                "terminalLogin": {"id": "login", "name": "Log in", "args": ["login"]},
                "loginVariants": [
                    {"id": "global", "name": "Log in (global)", "description": "Global account (minimax.io)",
                     "args": ["--region", "global"]},
                    {"id": "cn", "name": "Log in (China)", "description": "Mainland China account (minimaxi.com)",
                     "args": []}]},
    # signs in through the browser itself (ACP auth method grok.com); needs SuperGrok / X Premium+ or XAI_API_KEY
    "grok": {"package": "@xai-official/grok", "version": "1.0.67", "bin": "grok",
             "args": ["--no-auto-update", "agent", "stdio"], "name": "Grok",
             "description": "xAI's Grok Build over ACP; SuperGrok or X Premium+ (beta)"},
    # Google login opens the browser itself; the API-key, Vertex and gateway methods need keys the panel can't set
    "gemini": {"package": "@google/gemini-cli", "version": "0.65.0", "bin": "gemini", "args": ["--acp"],
               "name": "Gemini", "description": "Gemini CLI over ACP; uses your Google AI Pro / Ultra login",
               "authMethods": ["oauth-personal"]},
    # ACP auth method copilot-login runs `copilot login` (device code) in a terminal
    "copilot": {"package": "@github/copilot", "version": "1.0.103", "bin": "copilot",
                "args": ["--acp", "--no-auto-update"], "name": "Copilot",
                "description": "GitHub Copilot CLI over ACP; uses your Copilot Pro / Pro+ subscription"},
}


class Paths:
    def __init__(self, resource_path: str | None = None) -> None:
        self.home = Path.home()
        if WINDOWS:
            appdata = Path(os.environ.get("APPDATA") or self.home / "AppData/Roaming")
            self.local = Path(os.environ.get("LOCALAPPDATA") or self.home / "AppData/Local")
            default_res = appdata / "REAPER"
            self.logs = self.local / "Hibiki/logs"
            default_ipc = appdata / "reaper-mcp/ipc"  # what server.py and bridge.lua use when APPDATA is set
            self.claude_desktop = appdata / "Claude"
        else:
            self.local = self.home / "Library/Application Support"
            default_res = self.home / "Library/Application Support/REAPER"
            self.logs = self.home / "Library/Logs"
            default_ipc = self.home / "Library/Application Support/reaper-mcp/ipc"
            self.claude_desktop = self.home / "Library/Application Support/Claude"
        self.resource = Path(resource_path or os.environ.get("REAPER_RESOURCE_PATH") or default_res)
        self.scripts = self.resource / "Scripts"
        self.effects = self.resource / "Effects"
        self.cfg = self.home / ".config/reaper-mcp"
        self.token = self.cfg / "token"
        self.gw_cfg = self.home / ".config/agent-gateway/config.json"
        self.la = self.home / "Library/LaunchAgents"
        self.ipc = Path(os.environ.get("REAPER_MCP_IPC_DIR") or default_ipc)
        self.node = self.home / ".local/node"
        self.imgui_shim = self.scripts / "ReaTeam Extensions/API/imgui.lua"

    def plist(self, label: str) -> Path:
        return self.la / (label + ".plist")


REAPER_DOWNLOAD = "https://www.reaper.fm/download.php"


def reaper_app(p: Paths) -> Path | None:
    """macOS: REAPER.app (REAPER64.app in older releases) in /Applications or ~/Applications.
    Windows: reaper.exe under Program Files (or %LOCALAPPDATA%\\Programs), else where the registry says."""
    override = os.environ.get("HIBIKI_SYSTEM_APPLICATIONS")  # tests point it elsewhere
    if WINDOWS:
        roots = [override] if override else [os.environ.get(k) for k in ("ProgramW6432", "ProgramFiles",
                                                                         "ProgramFiles(x86)")] + [str(p.local / "Programs")]
        for r in filter(None, roots):
            for d in ("REAPER (x64)", "REAPER", "REAPER (ARM64)"):
                if (Path(r) / d / "reaper.exe").exists():
                    return Path(r) / d / "reaper.exe"
        if override:
            return None
        import winreg
        for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
            for view in (winreg.KEY_WOW64_64KEY, winreg.KEY_WOW64_32KEY):
                try:
                    with winreg.OpenKey(hive, r"SOFTWARE\REAPER", 0, winreg.KEY_READ | view) as k:
                        exe = Path(winreg.QueryValueEx(k, "")[0]) / "reaper.exe"
                except OSError:
                    continue
                if exe.exists():
                    return exe
        return None
    system = Path(override or "/Applications")
    for base in (system, p.home / "Applications"):
        for name in ("REAPER.app", "REAPER64.app"):
            if (base / name).exists():
                return base / name
    return None


def say(msg: str) -> None:
    if sys.stdout:  # None under pythonw (the Windows supervisor)
        print(msg, flush=True)


def no_services() -> bool:
    """Tests: write files only; no launchd, no Windows Run key, no background processes."""
    return bool(os.environ.get("HIBIKI_NO_SERVICES"))


def no_launchd() -> bool:
    return no_services() or sys.platform != "darwin"


def port() -> int:
    return int(os.environ.get("REAPER_MCP_PORT", "8787"))


def gamut_url() -> str:
    return os.environ.get("GAMUT_URL", "http://127.0.0.1:47891").rstrip("/")


def mcp_url() -> str:
    return "http://localhost:%d/mcp" % port()


def stdio_entry() -> dict:
    return {"command": sys.executable, "args": [str(ROOT / "reaper_mcp" / "server.py")]}


def need(path: Path) -> Path:
    if not path.exists():
        raise SystemExit("%s is missing: setup needs the whole suite (the .pkg or a git clone), not just the wheel" % path)
    return path


# ---------- launchd ----------

def launchctl(*args: str) -> int:
    if no_launchd():
        return 0
    return subprocess.run(["launchctl", *args], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode


def domain() -> str:
    return "gui/%d" % os.getuid()


def loaded(label: str) -> bool:
    if no_launchd():
        return False
    return launchctl("print", "%s/%s" % (domain(), label)) == 0


def stop_agent(p: Paths, label: str, delete: bool = False) -> bool:
    plist = p.plist(label)
    existed = plist.exists()
    if launchctl("bootout", "%s/%s" % (domain(), label)) == 0:
        deadline = time.time() + 15  # bootout returns before a job that shuts down gracefully is gone
        while loaded(label) and time.time() < deadline:
            time.sleep(0.2)
    if delete and existed:
        plist.unlink()
    return existed


def start_agent(p: Paths, label: str, args: list, env: dict | None = None, **extra) -> None:
    p.la.mkdir(parents=True, exist_ok=True)
    p.logs.mkdir(parents=True, exist_ok=True)
    log = str(p.logs / (label.split(".")[-1] + ".log"))
    body = {"Label": label, "ProgramArguments": args, "RunAtLoad": True,
            "StandardOutPath": log, "StandardErrorPath": log}
    if env:
        body["EnvironmentVariables"] = env
    body.update(extra)
    stop_agent(p, label)
    with open(p.plist(label), "wb") as f:
        plistlib.dump(body, f)
    bootstrap(p, label, log)


def bootstrap(p: Paths, label: str, log: str) -> bool:
    launchctl("enable", "%s/%s" % (domain(), label))  # undo `hibiki stop`, which disables the label across logins
    for attempt in range(5):
        if launchctl("bootstrap", domain(), str(p.plist(label))) == 0:
            return True
        time.sleep(1 + attempt)
    say("  launchctl bootstrap %s failed; see %s" % (label, log))
    return False


def wait_http(url: str, seconds: float = 10) -> bool:
    deadline = time.time() + seconds
    while True:
        try:
            with urllib.request.urlopen(url, timeout=2):
                return True
        except (OSError, urllib.error.URLError):
            if time.time() > deadline:
                return False
            time.sleep(0.5)


# ---------- REAPER side ----------

def copy_if_changed(src: Path, dst: Path) -> str:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and dst.read_bytes() == src.read_bytes():
        return "up to date"
    if dst.exists():
        shutil.copy2(dst, dst.with_name(dst.name + ".bak"))
    tmp = dst.with_name(dst.name + ".part")
    shutil.copy2(src, tmp)
    os.replace(tmp, dst)
    return "installed"


def install_bridge(p: Paths) -> None:
    say("  bridge: " + copy_if_changed(need(ROOT / "reaper_mcp/bridge.lua"), p.scripts / "reaper_mcp_bridge.lua"))


def install_panel(p: Paths) -> None:
    for name in PANEL_FILES:
        say("  panel %s: " % name + copy_if_changed(need(ROOT / "panel" / name), p.scripts / "Hibiki" / name))
    say("  meter: " + copy_if_changed(need(ROOT / "panel" / METER_JSFX), p.effects / "Hibiki" / METER_JSFX))
    for old in LEGACY_PANEL_DIRS:
        if (p.scripts / old).exists():
            shutil.rmtree(p.scripts / old, ignore_errors=True)
            say("  removed the old panel folder Scripts/%s" % old)


def imgui_installed(p: Paths) -> bool:
    return any((p.resource / "UserPlugins").glob("reaper_imgui-*")) and p.imgui_shim.exists()


def fetch_checked(url: str, sha256: str, dst: Path) -> None:
    with urllib.request.urlopen(url, timeout=60) as r:
        data = r.read()
    if hashlib.sha256(data).hexdigest() != sha256:
        raise SystemExit("download from %s failed its sha256 check" % url)
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.with_name(dst.name + ".part").write_bytes(data)
    os.replace(dst.with_name(dst.name + ".part"), dst)


def install_imgui(p: Paths) -> None:
    if any((p.resource / "UserPlugins").glob("reaper_imgui-*")):
        say("  ReaImGui: already installed")
    else:
        if WINDOWS:
            if platform.machine().lower() in ("arm64", "aarch64"):
                raise SystemExit("Windows on ARM: install ReaImGui with ReaPack, then run setup again")
            name = "reaper_imgui-x64.dll"
        else:
            name = "reaper_imgui-%s.dylib" % ("arm64" if platform.machine() == "arm64" else "x86_64")
        fetch_checked("https://github.com/cfillion/reaimgui/releases/download/v%s/%s" % (IMGUI_VERSION, name),
                      IMGUI_SHA256[name], p.resource / "UserPlugins" / name)
        say("  ReaImGui %s: installed" % IMGUI_VERSION)
    if not p.imgui_shim.exists():
        fetch_checked(IMGUI_SHIM_URL, IMGUI_SHIM_SHA256, p.imgui_shim)
        say("  ReaImGui Lua shim: installed (%s)" % p.imgui_shim)


def strip_managed(text: str) -> str:
    out, end = [], None
    for line in text.splitlines(keepends=True):
        if end is None:
            if line.startswith(STARTUP_BEGIN):
                end = STARTUP_END
            for b, e in LEGACY_STARTUP:
                if line.startswith(b):
                    end = e
        if end is None:
            out.append(line)
        elif line.startswith(end):
            end = None
    text = "".join(out)
    for old in LEGACY_HOOKS:
        text = text.replace(old, "")
    return text


def install_cli_shim(p: Paths) -> None:
    """Source checkouts get a ~/.local/bin/hibiki launcher (the pkg links /usr/local/bin/hibiki); the panel's Recover runs it."""
    if WINDOWS or PKG_ROOT in ROOT.parents or ROOT == PKG_ROOT:
        return
    if os.environ.get("HIBIKI_NO_SHIM") or read_mode(p).get("mode") == "dev":
        return
    shim = p.home / ".local/bin/hibiki"
    body = '#!/bin/sh\nexec %s -s -E %s "$@"\n' % (shlex.quote(sys.executable), shlex.quote(str(ROOT / "reaper_mcp/cli.py")))
    if shim.exists() and not shim.is_symlink() and shim.read_text() == body:
        return
    if shim.is_symlink():
        shim.unlink()
    shim.parent.mkdir(parents=True, exist_ok=True)
    shim.write_text(body)
    os.chmod(shim, 0o755)
    say("  cli: %s" % shim)


def install_startup(p: Paths) -> None:
    hook = need(ROOT / "reaper/__startup.lua").read_text()
    path = p.scripts / "__startup.lua"
    old = path.read_text() if path.exists() else ""
    rest = strip_managed(old)
    if hook.strip() and hook.strip() in rest:  # a hand-copied hook from before setup existed: adopt it
        rest = rest.replace(hook.strip(), "", 1)
    rest = re.sub(r"\n{3,}", "\n\n", rest).strip("\n")
    if "reaper_mcp_bridge.lua" in rest:
        # another hook already starts the bridge; a second start would make REAPER ask to stop the running script
        say("  startup hook: %s already starts the bridge; left as is" % path)
        return
    new = (rest + "\n\n" if rest else "") + STARTUP_BEGIN + "\n" + hook.rstrip("\n") + "\n" + STARTUP_END + "\n"
    if new == old:
        say("  startup hook: up to date")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if old:
        path.with_name("__startup.lua.bak").write_text(old)
    path.write_text(new)
    say("  startup hook: installed")


def remove_startup(p: Paths) -> None:
    path = p.scripts / "__startup.lua"
    if not path.exists():
        return
    rest = strip_managed(path.read_text()).strip("\n")
    if rest:
        path.write_text(rest + "\n")
    else:
        path.unlink()


# ---------- token, MCP, gateway ----------

MIN_TOKEN = 32


def ensure_token(p: Paths) -> str:
    p.cfg.mkdir(parents=True, exist_ok=True)
    os.chmod(p.cfg, 0o700)
    if p.token.exists():
        token = p.token.read_text().strip()
        if len(token) >= MIN_TOKEN:
            os.chmod(p.token, 0o600)
            return token
        if token:
            say("  the MCP bearer is shorter than %d characters; replacing it (clients get the new one)" % MIN_TOKEN)
    token = ""
    env = p.cfg / "env"  # written by scripts/macos-host-bootstrap.sh; clients already hold this bearer
    if env.exists():
        m = re.search(r"^REAPER_MCP_BEARER=(\S+)", env.read_text(), re.M)
        token = m.group(1) if m and len(m.group(1)) >= MIN_TOKEN else ""
    token = token or secrets.token_urlsafe(32)
    fd = os.open(str(p.token), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token + "\n")
    return token


def migrate_legacy(p: Paths) -> set:
    """Stop hand-made LaunchAgents that the suite replaces; returns the suite labels they stood for."""
    found = set()
    for old, new in LEGACY_LABELS.items():
        if stop_agent(p, old, delete=True):
            say("  replaced LaunchAgent %s with %s" % (old, new))
            found.add(new)
    return found


def start_mcp(p: Paths) -> bool:
    start_agent(p, MCP_LABEL, [sys.executable, str(ROOT / "reaper_mcp/http_server.py")],
                {"REAPER_MCP_PORT": str(port())}, KeepAlive=True, WorkingDirectory=str(ROOT))
    if no_launchd():
        return True
    ok = wait_http("http://127.0.0.1:%d/healthz" % port())
    say("  MCP on 127.0.0.1:%d: %s" % (port(), "up" if ok else "NOT answering, see %s" % (p.logs / "reaper-mcp.log")))
    return ok


def load_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write_json(path: Path, data: dict, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".part")
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def gateway_config(p: Paths) -> None:
    cfg = load_json(p.gw_cfg) or {"acp": []}
    servers = [s for s in cfg.get("mcpServers", []) if s.get("name") != "reaper"]
    cfg["mcpServers"] = [dict(name="reaper", **stdio_entry())] + servers
    write_json(p.gw_cfg, cfg)


def start_gateway(p: Paths) -> None:
    start_agent(p, GW_LABEL, [sys.executable, str(need(ROOT / "gateway/agent_gateway.py"))],
                KeepAlive=True, WorkingDirectory=str(ROOT))
    if no_launchd():
        return
    ok = wait_http("http://127.0.0.1:%d/health" % GW_PORT)
    say("  agent gateway on 127.0.0.1:%d: %s" % (GW_PORT, "up" if ok else "NOT answering, see %s" % (p.logs / "agent-gateway.log")))


def watchdog_on(p: Paths) -> None:
    script = need(ROOT / "scripts/reaper-watchdog.sh")
    start_agent(p, WD_LABEL, ["/bin/bash", str(script)], StartInterval=30, ProcessType="Background")
    say("  watchdog: on (relaunches REAPER after a crash, restarts a hung one while the Mac is idle)")


def watchdog_off(p: Paths) -> None:
    stop_agent(p, WD_LABEL, delete=True)
    say("  watchdog: off")


# ---------- Windows services ----------
# One supervisor (`hibiki run`, under pythonw: no console) keeps the MCP HTTP front and the gateway running and
# restarts them when they exit; HKCU ...\CurrentVersion\Run starts it at logon. No admin rights, no Task Scheduler.

def win_python(gui: bool = False) -> str:
    exe = Path(sys.executable)
    cand = exe.with_name("pythonw.exe" if gui else "python.exe")
    return str(cand) if cand.exists() else str(exe)


def supervisor_cmd() -> list:
    return [win_python(gui=True), "-s", "-E", str(ROOT / "reaper_mcp/cli.py"), "run", "--port", str(port())]


def win_pid_file(p: Paths) -> Path:
    return p.logs / "supervisor.pid"


def win_supervisor_pid(p: Paths) -> int:
    """PID of the running supervisor, or 0."""
    try:
        pid = int(win_pid_file(p).read_text().strip())
    except (OSError, ValueError):
        return 0
    out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/FO", "CSV", "/NH"],
                         capture_output=True, text=True).stdout.lower()
    return pid if "python" in out else 0  # a reused PID belongs to someone else


def win_autostart() -> str:
    import winreg
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
            return winreg.QueryValueEx(k, RUN_VALUE)[0]
    except OSError:
        return ""


def win_services_stop(p: Paths, forget: bool = False) -> bool:
    if no_services():
        return False
    pid = win_supervisor_pid(p)
    if pid:
        subprocess.run(["taskkill", "/PID", str(pid), "/T", "/F"], capture_output=True)
    try:
        win_pid_file(p).unlink()
    except OSError:
        pass
    if forget and win_autostart():
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
            winreg.DeleteValue(k, RUN_VALUE)
    return bool(pid)


def win_services_start(p: Paths, wait: bool = True) -> bool:
    p.logs.mkdir(parents=True, exist_ok=True)
    if no_services():
        return True
    import winreg
    cmd = supervisor_cmd()
    with winreg.CreateKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
        winreg.SetValueEx(k, RUN_VALUE, 0, winreg.REG_SZ, subprocess.list2cmdline(cmd))
    win_services_stop(p)
    flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
    io = dict(stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, cwd=str(ROOT), close_fds=True)
    try:  # out of the installer's (or a CI step's) job object, so it outlives the process that ran setup
        subprocess.Popen(cmd, creationflags=flags | subprocess.CREATE_BREAKAWAY_FROM_JOB, **io)
    except OSError:
        subprocess.Popen(cmd, creationflags=flags, **io)
    if not wait:
        return True
    ok = wait_http("http://127.0.0.1:%d/healthz" % port(), 20)
    say("  MCP on 127.0.0.1:%d: %s" % (port(), "up" if ok else "NOT answering, see %s" % (p.logs / "reaper-mcp.log")))
    gw = wait_http("http://127.0.0.1:%d/health" % GW_PORT, 10)
    say("  agent gateway on 127.0.0.1:%d: %s" % (GW_PORT, "up" if gw else "NOT answering, see %s"
                                                % (p.logs / "agent-gateway.log")))
    say("  autostart: on (HKCU Run '%s')" % RUN_VALUE)
    return ok


def cmd_run(a) -> int:
    """The Windows supervisor: start both services, restart whichever exits. Runs under pythonw, so no prints."""
    p = Paths()
    p.logs.mkdir(parents=True, exist_ok=True)
    try:
        return supervise(p, a.port)
    except BaseException:  # pythonw has no stderr: leave the reason where doctor's hint points
        import traceback
        with open(p.logs / "supervisor.log", "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + traceback.format_exc())
        raise


def supervise(p: Paths, port_: int) -> int:
    win_pid_file(p).write_text(str(os.getpid()))
    py = win_python() if WINDOWS else sys.executable
    env = dict(os.environ, REAPER_MCP_PORT=str(port_))
    jobs = {"reaper-mcp": [py, str(ROOT / "reaper_mcp/http_server.py")],
            "agent-gateway": [py, str(ROOT / "gateway/agent_gateway.py")]}
    flags = subprocess.CREATE_NO_WINDOW if WINDOWS else 0
    procs: dict = {}
    while True:
        for name, argv in jobs.items():
            pr = procs.get(name)
            if pr is None or pr.poll() is not None:
                with open(p.logs / (name + ".log"), "ab") as log:
                    if pr is not None:
                        log.write(b"--- exited with %d, restarting\n" % pr.returncode)
                        log.flush()
                    procs[name] = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                                   cwd=str(ROOT), env=env, creationflags=flags)
        time.sleep(2)


# ---------- MCP clients ----------

def gamut_call(method: str, path: str, body: dict | None = None) -> dict:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(gamut_url() + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else {}


def connect_gamut(p: Paths, remove: bool = False) -> str:
    try:
        servers = gamut_call("GET", "/api/remote-mcps").get("servers", [])
        old = next((s for s in servers if s.get("url") == mcp_url()), None)
        if remove:
            if old:
                gamut_call("DELETE", "/api/remote-mcps/" + old["id"])
                return "removed"
            return "not registered"
        auth = {"authType": "bearer", "accessToken": ensure_token(p)}
        if old:
            gamut_call("PATCH", "/api/remote-mcps/" + old["id"], auth)
            return "updated '%s'" % old.get("name")
        gamut_call("POST", "/api/remote-mcps", dict(auth, name="REAPER", url=mcp_url()))
        return "added 'REAPER'"
    except urllib.error.HTTPError as e:
        return "Gamut refused (%s): %s" % (e.code, e.read(300).decode(errors="replace"))
    except (OSError, ValueError):
        return "Gamut isn't running at %s; run `hibiki connect gamut` once it is" % gamut_url()


# Gamut assigns remote MCPs per agent: registering REAPER isn't enough, each agent that should drive REAPER needs it
def gamut_reaper_id() -> str:
    """Gamut's id for this MCP (matched by URL), or ''."""
    servers = gamut_call("GET", "/api/remote-mcps").get("servers", [])
    return next((s.get("id", "") for s in servers if s.get("url") == mcp_url()), "")


def gamut_agents() -> list:
    agents = gamut_call("GET", "/api/agents")
    agents = agents.get("agents", []) if isinstance(agents, dict) else agents
    return [{"slug": a["slug"], "name": a.get("name") or a["slug"]} for a in agents if isinstance(a, dict) and a.get("slug")]


def gamut_reaper_enabled(slug: str) -> bool:
    mcps = gamut_call("GET", "/api/agents/%s/remote-mcps" % urllib.parse.quote(slug)).get("mcps", [])
    return any(m.get("url") == mcp_url() for m in mcps)


def gamut_enable(p: Paths, slug: str) -> str:
    """Register the MCP in Gamut if needed, then assign it to one agent. Returns a one-line status."""
    mcp_id = gamut_reaper_id()
    if not mcp_id:
        connect_gamut(p)
        mcp_id = gamut_reaper_id()
    if not mcp_id:
        return "Gamut didn't take the REAPER MCP registration"
    if gamut_reaper_enabled(slug):
        return "already enabled"
    gamut_call("POST", "/api/agents/%s/remote-mcps" % urllib.parse.quote(slug), {"mcpIds": [mcp_id]})
    return "enabled"


def pick_gamut_agents(p: Paths, a) -> None:
    """`connect gamut`: enable REAPER for --agent / --all-agents, or ask on a terminal."""
    try:
        agents = gamut_agents()
    except (OSError, ValueError):
        return
    chosen = agents if a.all_agents else [x for x in agents if x["slug"] in (a.agent or [])
                                         or x["name"] in (a.agent or [])]
    if not chosen and not a.agent and sys.stdin and sys.stdin.isatty() and agents:
        say("Gamut assigns MCPs per agent. Enable REAPER for:")
        for i, x in enumerate(agents, 1):
            say("  %d. %s%s" % (i, x["name"], "  (already)" if gamut_reaper_enabled(x["slug"]) else ""))
        ans = input("numbers, comma-separated; 'a' = all; Enter = none: ").strip().lower()
        if ans == "a":
            chosen = agents
        else:
            idx = [int(t) for t in re.findall(r"\d+", ans)]
            chosen = [agents[i - 1] for i in idx if 0 < i <= len(agents)]
    for x in chosen:
        say("  %s: %s" % (x["name"], gamut_enable(p, x["slug"])))
    if not chosen:
        say("  REAPER isn't enabled for any agent yet: `hibiki connect gamut --agent <name>`, "
            "or the Hibiki panel's Agent settings")


def json_client(path: Path, key: str, remove: bool) -> str:
    cfg = load_json(path) if path.exists() else {}
    servers = cfg.setdefault(key, {})
    if remove:
        if servers.pop("reaper", None) is None:
            return "not registered"
        write_json(path, cfg)
        return "removed"
    if servers.get("reaper") == stdio_entry():
        return "up to date"
    servers["reaper"] = stdio_entry()
    write_json(path, cfg)
    return "registered in %s" % path


def claude_bin(p: Paths) -> str | None:
    return shutil.which("claude") or next((str(c) for c in [p.home / ".local/bin/claude"] if c.exists()), None)


def connect_claude_code(p: Paths, remove: bool = False) -> str:
    claude = claude_bin(p)
    if not claude:
        return "claude CLI not found"
    subprocess.run([claude, "mcp", "remove", "--scope", "user", "reaper"], capture_output=True)
    if remove:
        return "removed"
    e = stdio_entry()
    r = subprocess.run([claude, "mcp", "add", "--scope", "user", "reaper", "--", e["command"], *e["args"]],
                       capture_output=True, text=True)
    return "registered (user scope)" if r.returncode == 0 else "claude mcp add failed: " + (r.stderr or r.stdout).strip()


CLIENTS = {
    "gamut": (lambda p: True, connect_gamut),
    "claude-desktop": (lambda p: p.claude_desktop.is_dir(),
                       lambda p, remove=False: json_client(
                           p.claude_desktop / "claude_desktop_config.json", "mcpServers", remove)),
    "cursor": (lambda p: (p.home / ".cursor").is_dir(),
               lambda p, remove=False: json_client(p.home / ".cursor/mcp.json", "mcpServers", remove)),
    "claude-code": (lambda p: claude_bin(p) is not None, connect_claude_code),
}


def connect_detected(p: Paths, remove: bool = False) -> None:
    for name, (present, fn) in CLIENTS.items():
        if present(p):
            say("  %s: %s" % (name, fn(p, remove=remove)))


# ---------- ACP agents for the gateway ----------

def ensure_node(p: Paths) -> Path:
    """Node in ~/.local/node; returns the directory holding node and npm (bin/ on macOS, the root on Windows)."""
    bin_dir = p.node if WINDOWS else p.node / "bin"
    if (bin_dir / ("node.exe" if WINDOWS else "node")).exists():
        return bin_dir
    with urllib.request.urlopen("https://nodejs.org/dist/index.json", timeout=30) as r:
        version = next(rel["version"] for rel in json.load(r) if rel["lts"])
    arch = "arm64" if platform.machine().lower() in ("arm64", "aarch64") else "x64"
    name = "node-%s-%s-%s" % (version, "win" if WINDOWS else "darwin", arch)
    ext = ".zip" if WINDOWS else ".tar.gz"
    base = "https://nodejs.org/dist/%s/" % version
    with urllib.request.urlopen(base + "SHASUMS256.txt", timeout=30) as r:
        sums = dict(reversed(line.split()) for line in r.read().decode().splitlines() if line.strip())
    say("  installing Node %s into %s" % (version, p.node))
    with urllib.request.urlopen(base + name + ext, timeout=300) as r:
        data = r.read()
    if hashlib.sha256(data).hexdigest() != sums.get(name + ext):
        raise SystemExit("Node download failed its sha256 check")
    with tempfile.TemporaryDirectory() as tmp:
        arc = Path(tmp) / ("node" + ext)
        arc.write_bytes(data)
        if WINDOWS:
            import zipfile
            with zipfile.ZipFile(arc) as z:
                z.extractall(tmp)
        else:
            with tarfile.open(arc) as t:
                if hasattr(tarfile, "data_filter"):
                    t.extractall(tmp, filter="data")
                else:
                    t.extractall(tmp)
        if p.node.exists():
            shutil.rmtree(p.node)
        p.node.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(Path(tmp) / name), str(p.node))
    return bin_dir


def agents_add(p: Paths, slugs: list, restart: bool = True) -> None:
    unknown = [s for s in slugs if s not in ACP_AGENTS]
    if unknown:
        raise SystemExit("unknown agent(s) %s; choose from %s" % (", ".join(unknown), ", ".join(ACP_AGENTS)))
    bin_dir = ensure_node(p)
    env = dict(os.environ, PATH=os.pathsep.join([str(bin_dir), os.environ.get("PATH", "/usr/bin:/bin")]))
    system_dirs = ([os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32"),
                    os.environ.get("SystemRoot", r"C:\Windows")] if WINDOWS else ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    cfg = load_json(p.gw_cfg) or {"acp": [], "mcpServers": [dict(name="reaper", **stdio_entry())]}
    for slug in slugs:
        a = ACP_AGENTS[slug]
        # Windows: --prefix pins the global shims to the node folder (npm's default there is %APPDATA%/npm)
        cmd = [str(bin_dir / ("npm.cmd" if WINDOWS else "npm")), "install", "-g", "--no-fund", "--no-audit"]
        if WINDOWS:
            cmd.append("--prefix=" + str(p.node))
        if a.get("allow_scripts"):
            cmd.append("--allow-scripts=" + a["allow_scripts"])
        else:
            cmd.append("--ignore-scripts")
        spec = "%s@%s" % (a["package"], a["version"])
        say("  npm install %s" % spec)
        subprocess.run(cmd + [spec], env=env, check=True)
        path = os.pathsep.join([str(bin_dir)] + [str(Path(x).expanduser()) for x in a.get("path_extra", [])]
                               + system_dirs)
        entry = {"slug": slug, "name": a["name"], "description": a["description"],
                 "command": [str(bin_dir / (a["bin"] + (".cmd" if WINDOWS else "")))] + a["args"], "env": {"PATH": path},
                 "cwd": "~/Documents/REAPER Media"}
        for k in ("loginVariants", "terminalLogin", "authMethods"):
            if a.get(k):
                entry[k] = a[k]
        cfg["acp"] = [x for x in cfg.get("acp", []) if x.get("slug") != slug] + [entry]
    write_json(p.gw_cfg, cfg)
    if not restart:  # the gateway itself installing (panel button): it loads the new agents in place
        pass
    elif WINDOWS:
        if win_supervisor_pid(p):
            win_services_start(p)  # restarts the gateway with the new agents
    elif loaded(GW_LABEL):
        launchctl("kickstart", "-k", "%s/%s" % (domain(), GW_LABEL))
    say("  added %s; they show up in the panel's agent picker" % ", ".join(slugs))


# ---------- dev mode: `hibiki use dev|release` ----------

CHECKOUT_FILES = ("reaper_mcp/cli.py", "reaper_mcp/bridge.lua", "reaper_mcp/ears.py", "panel/Hibiki.lua", "panel/context.lua",
                  "panel/markdown.lua", "panel/studio.lua",
                  "panel/Hibiki_Meter.jsfx", "gateway/agent_gateway.py")


def mode_file(p: Paths) -> Path:
    return p.cfg / "mode.json"


def read_mode(p: Paths) -> dict:
    return load_json(mode_file(p))


def clear_mode(p: Paths) -> bool:
    try:
        mode_file(p).unlink()
        return True
    except OSError:
        return False


def pkg_root() -> Path:
    if WINDOWS:
        return Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData/Local") / "Programs/Hibiki"
    return PKG_ROOT


def pkg_python() -> Path:
    return pkg_root() / ("python/python.exe" if WINDOWS else "python/bin/python3")


def pkg_cli() -> Path:
    return pkg_root() / "app/reaper_mcp/cli.py"


def pkg_version() -> str:
    try:
        return (pkg_root() / "VERSION").read_text().strip()
    except OSError:
        return ""


def git_state(path: Path) -> tuple:
    def git(*args: str) -> str:
        r = subprocess.run(["git", "-C", str(path), *args], capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            raise OSError(r.stderr.strip())
        return r.stdout or ""
    try:
        return git("rev-parse", "--short", "HEAD").strip(), bool(git("status", "--porcelain").strip())
    except (OSError, subprocess.SubprocessError, AttributeError):
        return "", False


def remove_cli_shim(p: Paths) -> bool:
    shim = p.home / ".local/bin/hibiki"
    try:
        body = shim.read_text() if shim.is_file() and not shim.is_symlink() else ""
    except OSError:
        return False
    if WINDOWS or not body.startswith("#!/bin/sh\nexec ") or "reaper_mcp/cli.py" not in body:
        return False
    shim.unlink()
    say("  removed %s (the installed `hibiki` follows the mode now)" % shim)
    return True


def mode_info(p: Paths) -> dict:
    m = read_mode(p)
    if m.get("mode") == "dev" and m.get("path"):
        path = Path(m["path"])
        ok = all((path / f).is_file() for f in CHECKOUT_FILES)
        commit, dirty = git_state(path) if ok else (m.get("commit", ""), bool(m.get("dirty")))
        return {"mode": "dev", "path": str(path), "commit": commit or m.get("commit") or "", "dirty": dirty,
                "python": m.get("python") or "", "at": m.get("at") or "", "missing": not ok,
                "version": checkout_version(path) if ok else ""}
    have = pkg_cli().is_file()
    return {"mode": "release", "path": str(pkg_root()) if have else None, "version": pkg_version() if have else None,
            "python": str(pkg_python()) if have else None, "installed": have}


def checkout_version(path: Path) -> str:
    try:
        m = re.search(r'__version__\s*=\s*"([^"]+)"', (path / "reaper_mcp/__init__.py").read_text())
    except OSError:
        return ""
    return m.group(1) if m else ""


def mode_line(info: dict) -> str:
    if info["mode"] == "dev":
        return "dev %s @ %s%s%s" % (info["path"], info["commit"] or "?", " +dirty" if info["dirty"] else "",
                                    " (MISSING)" if info["missing"] else "")
    if not info.get("installed"):
        return "release (no installed package; running %s from %s)" % (__version__, ROOT)
    return "release %s" % info["version"]


def forward(argv: list):
    """Called by cli.main before anything else. Returns None to run here, else an exit code (Windows); on macOS a
    forward replaces this process."""
    p = Paths()
    if os.environ.get("HIBIKI_USE_RELEASE"):
        if clear_mode(p):
            print("hibiki: dev mode off (fresh install)", file=sys.stderr)
        return None
    if os.environ.get("HIBIKI_FORWARDED") or (argv[:1] == ["use"]):
        return None
    m = read_mode(p)
    if m.get("mode") != "dev" or not m.get("path"):
        return None
    path = Path(m["path"])
    try:
        if path.resolve() == ROOT:
            return None
    except OSError:
        pass
    cli = path / "reaper_mcp/cli.py"
    py = m.get("python") or sys.executable
    if not cli.is_file() or not Path(py).exists():
        print("hibiki: dev mode points at %s (python %s), which is gone; running the installed release instead. "
              "`hibiki use release` makes that permanent." % (path, py), file=sys.stderr)
        return None
    os.environ["HIBIKI_FORWARDED"] = "1"
    args = [py, "-s", "-E", str(cli), *argv]
    if WINDOWS:
        return subprocess.call(args)
    sys.stdout.flush()
    sys.stderr.flush()
    os.execv(py, args)
    return None


def run_setup(py: str, cli: Path, a, extra_env: dict) -> int:
    cmd = [py, "-s", "-E", str(cli), "setup"]
    if getattr(a, "resource_path", None):
        cmd += ["--resource-path", a.resource_path]
    env = dict(os.environ, HIBIKI_FORWARDED="1", **extra_env)
    env.pop("HIBIKI_USE_RELEASE", None)
    say("$ " + " ".join(shlex.quote(c) for c in cmd))
    return subprocess.run(cmd, env=env).returncode


def cmd_use(a) -> int:
    p = Paths(getattr(a, "resource_path", None))
    target = a.target or "status"
    if target == "dev":
        return use_dev(p, a)
    if target == "release":
        return use_release(p, a)
    info = mode_info(p)
    if a.json:
        print(json.dumps(info))
        return 0
    say("mode:    " + info["mode"])
    if info["mode"] == "dev":
        say("path:    %s%s" % (info["path"], "  (MISSING: the installed release runs instead)" if info["missing"] else ""))
        say("commit:  %s%s" % (info["commit"] or "?", " +dirty" if info["dirty"] else ""))
        say("version: %s" % (info["version"] or "?"))
        say("since:   %s" % (info["at"] or "?"))
    else:
        say("path:    %s" % (info["path"] or "no installed package; running %s" % ROOT))
        say("version: %s" % (info["version"] or __version__))
    say("python:  %s" % (info["python"] or sys.executable))
    return 0


def use_dev(p: Paths, a) -> int:
    path = Path(a.path or Path.home() / "reaper-mcp").expanduser().resolve()
    missing = [f for f in CHECKOUT_FILES if not (path / f).is_file()]
    if missing:
        say("error: %s is not a Hibiki checkout (missing %s)" % (path, ", ".join(missing)))
        return 2
    if pkg_root().exists() and path == pkg_root().resolve() / "app":
        say("error: %s is the installed package; use `hibiki use release`" % path)
        return 2
    py = str(pkg_python()) if pkg_python().exists() else sys.executable
    commit, dirty = git_state(path)
    write_json(mode_file(p), {"mode": "dev", "path": str(path), "python": py, "commit": commit, "dirty": dirty,
                              "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")})
    remove_cli_shim(p)
    say("dev mode: %s @ %s%s (python %s)" % (path, commit or "?", " +dirty" if dirty else "", py))
    rc = run_setup(py, path / "reaper_mcp/cli.py", a, {"HIBIKI_NO_SHIM": "1"})
    say("")
    if rc != 0:
        say("setup from the checkout failed (exit %d); still in dev mode. `hibiki use release` goes back." % rc)
        return rc
    say("dev: %s @ %s%s" % (path, commit or "?", " +dirty" if dirty else ""))
    say("The MCP and the gateway now run from the checkout, and every `hibiki` command (the panel's Recover and "
        "update too) runs its code.")
    say("REAPER still has the old bridge and panel loaded: restart REAPER to load the checkout's copies "
        "(`hibiki recover` does not reload them).")
    return 0


def use_release(p: Paths, a) -> int:
    py, cli = pkg_python(), pkg_cli()
    if not (py.exists() and cli.is_file()):
        say("error: no installed package; install Hibiki first (%s)" % pkg_root())
        return 1
    was = read_mode(p)
    clear_mode(p)
    remove_cli_shim(p)
    if was.get("mode") == "dev":
        say("dev mode off (was %s)" % was.get("path"))
    rc = run_setup(str(py), cli, a, {})
    say("")
    if rc != 0:
        say("setup from the installed package failed (exit %d)" % rc)
        return rc
    say("release: %s at %s" % (pkg_version() or "?", pkg_root()))
    say("Restart REAPER to load the installed bridge and panel.")
    return 0


# ---------- commands ----------

def cmd_setup(a) -> int:
    if sys.platform not in ("darwin", "win32") and not no_services():
        raise SystemExit("setup is for macOS and Windows; elsewhere use `reaper-mcp install-bridge` and a stdio MCP config")
    p = Paths(a.resource_path)
    if not reaper_app(p):  # onboarding order: REAPER first, then Hibiki (the installers check the same up front)
        raise SystemExit("REAPER isn't installed. Download it from %s, %s, then run `hibiki setup` again."
                         % (REAPER_DOWNLOAD, "run its installer" if WINDOWS else "drag it to Applications"))
    say("hibiki %s from %s (python %s)" % (__version__, ROOT, sys.executable))
    say("REAPER")
    install_bridge(p)
    install_brain()
    if a.mcp_only:
        return setup_mcp_only(p, a)
    install_panel(p)
    if not a.no_reaimgui:
        install_imgui(p)
    install_startup(p)
    install_cli_shim(p)
    say("Services")
    ensure_token(p)
    stopped_file(p).unlink(missing_ok=True)  # setup turns everything on again, like `hibiki start`
    if WINDOWS:
        gateway_config(p)
        ok = win_services_start(p)
    else:
        legacy = migrate_legacy(p)
        ok = start_mcp(p)
        gateway_config(p)
        start_gateway(p)
        if WD_LABEL in legacy or p.plist(WD_LABEL).exists():
            watchdog_on(p)
    if not a.no_connect:
        say("MCP clients")
        connect_detected(p)
    say("")
    say("Done. Restart REAPER: the bridge and the Hibiki panel start with it. Check with `hibiki doctor`.")
    return 0 if ok else 1


def setup_mcp_only(p: Paths, a) -> int:
    """Bridge + startup hook + stdio clients: no panel, no ReaImGui, no background services. Gamut needs the
    HTTP service, so it's left out."""
    install_startup(p)  # without the panel installed, the hook only starts the bridge
    install_cli_shim(p)
    if not a.no_connect:
        say("MCP clients")
        for name, (present, fn) in CLIENTS.items():
            if name != "gamut" and present(p):
                say("  %s: %s" % (name, fn(p)))
    say("")
    say("Done. Restart REAPER: the bridge starts with it. Check with `hibiki doctor --mcp-only`.")
    return 0


def bridge_version(path: Path) -> str:
    m = re.search(r'^local VERSION = "([^"]+)"', path.read_text(), re.M) if path.exists() else None
    return m.group(1) if m else ""


def cmd_doctor(a) -> int:
    p = Paths(a.resource_path)
    rows = []

    def row(level: str, name: str, detail: str) -> None:
        rows.append({"level": level, "check": name, "detail": detail})

    info = mode_info(p)
    row("warn" if info["mode"] == "dev" and (info["dirty"] or info["missing"]) else "ok", "mode", mode_line(info)
        + (" - `hibiki use release`" if info["mode"] == "dev" and info["missing"] else ""))
    row("ok", "suite", "%s at %s, python %s" % (__version__, ROOT, sys.executable))
    app = reaper_app(p)
    row("ok" if app else "FAIL", "REAPER", str(app) if app else "not installed - get it from " + REAPER_DOWNLOAD)
    row("ok" if p.resource.is_dir() else "FAIL", "resource path", str(p.resource))
    bv = bridge_version(p.scripts / "reaper_mcp_bridge.lua")
    row("ok" if bv == __version__ else "FAIL", "bridge script",
        "%s (suite %s)" % (bv or "missing", __version__) + ("" if bv == __version__ else " - run setup"))
    if a.mcp_only:
        return doctor_mcp_only(p, a, rows, row)
    pairs = [(p.scripts / "Hibiki" / n, ROOT / "panel" / n) for n in PANEL_FILES] + \
        [(p.effects / "Hibiki" / METER_JSFX, ROOT / "panel" / METER_JSFX)]
    off = [str(dst) for dst, src in pairs if not (dst.exists() and src.exists() and dst.read_bytes() == src.read_bytes())]
    row("warn" if off else "ok", "chat panel", "%s%s" % (p.scripts / "Hibiki",
        "" if not off else " (missing or differs from this suite: %s) - run setup" % ", ".join(off)))
    row("ok" if imgui_installed(p) else "warn", "ReaImGui", "installed" if imgui_installed(p)
        else "missing (binary or %s): the panel needs it - run setup" % p.imgui_shim)
    row_startup(p, row)
    stopped = is_stopped(p)
    if stopped:
        row("warn", "services", "stopped with `hibiki stop` (%s) - `hibiki start` turns them back on"
            % load_json(stopped_file(p)).get("at", "?"))
    if not p.token.exists():
        row("FAIL", "token", "%s missing" % p.token)
    elif WINDOWS:  # NTFS ACLs, not mode bits: the token sits in the user's profile
        row("ok", "token", str(p.token))
    else:
        mode = p.token.stat().st_mode & 0o777
        row("ok" if mode == 0o600 else "warn", "token", "%s mode %o" % (p.token, mode))
    if WINDOWS:
        auto = win_autostart()
        row("ok" if str(ROOT) in auto else ("warn" if stopped and not auto else "FAIL"), "autostart", "HKCU Run \"%s\"" % RUN_VALUE if str(ROOT) in auto
            else ("points at another install - run setup" if auto else "missing - run setup"))
        pid = win_supervisor_pid(p)
        row("ok" if pid else ("warn" if stopped else "FAIL"), "supervisor", "pid %d" % pid if pid else
            "not running - see %s, then run setup" % (p.logs / "supervisor.log"))
        row("ok", "watchdog", "macOS only")
    else:
        for label in (MCP_LABEL, GW_LABEL, WD_LABEL):
            if label == WD_LABEL and not p.plist(label).exists():
                row("ok", label, "off (optional)")
                continue
            if stopped and not loaded(label):
                row("warn", label, "stopped (`hibiki start` turns it back on)")
                continue
            row("ok" if loaded(label) else "FAIL", label, "loaded" if loaded(label) else "not loaded")
        for old in LEGACY_LABELS:
            if p.plist(old).exists():
                row("warn", old, "old LaunchAgent still installed - run setup")
    up = wait_http("http://127.0.0.1:%d/healthz" % port(), 0)
    row("ok" if up else ("warn" if stopped else "FAIL"), "MCP http", "127.0.0.1:%d %s" % (
        port(), "answers" if up else ("stopped" if stopped else "no answer")))
    gw = wait_http("http://127.0.0.1:%d/health" % GW_PORT, 0)
    row("ok" if gw else "warn", "agent gateway", "127.0.0.1:%d %s" % (GW_PORT, "answers" if gw else "no answer"))
    row_heartbeat(p, row)
    try:
        servers = gamut_call("GET", "/api/remote-mcps").get("servers", [])
        reg = next((s for s in servers if s.get("url") == mcp_url()), None)
        row("ok" if reg else "warn", "Gamut", "registered as '%s'" % reg.get("name") if reg else
            "running, MCP not registered - `hibiki connect gamut`")
    except (OSError, ValueError):
        row("warn", "Gamut", "not running at %s" % gamut_url())
    return print_rows(rows, a.json)


def doctor_mcp_only(p: Paths, a, rows: list, row) -> int:
    row_startup(p, row)
    row_heartbeat(p, row)
    return print_rows(rows, a.json)


def row_startup(p: Paths, row) -> None:
    startup = p.scripts / "__startup.lua"
    hooked = startup.exists() and "reaper_mcp_bridge.lua" in startup.read_text()
    row("ok" if hooked else "FAIL", "startup hook", str(startup) if hooked else "REAPER won't start the bridge on launch")


def row_heartbeat(p: Paths, row) -> None:
    hb = p.ipc / "heartbeat"
    age = time.time() - hb.stat().st_mtime if hb.exists() else None
    row("ok" if age is not None and age < 5 else "warn", "bridge heartbeat",
        "%.1fs old" % age if age is not None else "never seen: start REAPER")


def print_rows(rows: list, as_json: bool) -> int:
    if as_json:
        print(json.dumps(rows, indent=2))
    else:
        for r in rows:
            print("%-5s %-38s %s" % (r["level"], r["check"], r["detail"]))
    return 1 if any(r["level"] == "FAIL" for r in rows) else 0


def cmd_connect(a) -> int:
    p = Paths()
    names = list(CLIENTS) if a.client == "all" else [a.client]
    for name in names:
        present, fn = CLIENTS[name]
        if a.client == "all" and not present(p):
            continue
        say("%s: %s" % (name, fn(p, remove=a.remove)))
        if name == "gamut" and not a.remove:
            pick_gamut_agents(p, a)
    return 0


def cmd_watchdog(a) -> int:
    if WINDOWS:
        raise SystemExit("the watchdog is macOS only for now")
    p = Paths()
    watchdog_on(p) if a.state == "on" else watchdog_off(p)
    return 0


def cmd_agents(a) -> int:
    agents_add(Paths(), a.agents)
    return 0


def cmd_uninstall(a) -> int:
    p = Paths(a.resource_path)
    if WINDOWS:
        win_services_stop(p, forget=True)
        say("stopped the services and removed the autostart entry")
    else:
        for label in (MCP_LABEL, GW_LABEL, WD_LABEL, *LEGACY_LABELS):
            if stop_agent(p, label, delete=True):
                say("removed LaunchAgent " + label)
    remove_startup(p)
    if clear_mode(p):
        say("dev mode off")
    for f in (p.scripts / "reaper_mcp_bridge.lua", p.scripts / "reaper_mcp_bridge.lua.bak",
              p.scripts / "reaper_mcp_bridge.lua.new"):
        if f.exists():
            f.unlink()
    for d in ("Hibiki",) + LEGACY_PANEL_DIRS:
        shutil.rmtree(p.scripts / d, ignore_errors=True)
    shutil.rmtree(p.effects / "Hibiki", ignore_errors=True)
    say("removed the bridge, the panel and the startup hook (ReaImGui stays: other scripts use it)")
    connect_detected(p, remove=True)
    if a.purge:
        for d in (p.cfg, p.gw_cfg.parent):
            shutil.rmtree(d, ignore_errors=True)
        say("removed %s and %s" % (p.cfg, p.gw_cfg.parent))
    if WINDOWS:
        if packaged():
            say("App files: remove Hibiki in Settings -> Apps (its uninstaller runs this command too)")
    elif packaged():
        say("App files: sudo rm -rf '%s' /usr/local/bin/hibiki && sudo pkgutil --forget %s"
            % (PKG_ROOT, PKG_ID))
    return 0


# ---------- recover ----------

PANEL_STREAM_AGENTS = ("HibikiPanel", "GamutChatPanel")  # the panel's SSE curl user agent, now and before the rename
RECOVER_WAIT = 10.0


def service_pid(label: str) -> int:
    """PID launchd reports for a loaded job, or 0."""
    try:
        out = subprocess.run(["launchctl", "print", "%s/%s" % (domain(), label)], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return 0
    m = re.search(r"^\s*pid = (\d+)", out, re.M)
    return int(m.group(1)) if m else 0


def ps_table() -> dict:
    """pid -> parent pid for every process."""
    try:
        out = subprocess.run(["ps", "-A", "-o", "pid=", "-o", "ppid="], capture_output=True, text=True,
                             timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return {}
    table = {}
    for line in out.splitlines():
        f = line.split()
        if len(f) == 2 and f[0].isdigit() and f[1].isdigit():
            table[int(f[0])] = int(f[1])
    return table


def child_pids(pid: int, table: dict | None = None) -> list:
    """Every process below `pid` (the gateway's ACP agents and their MCP servers)."""
    kids: dict = {}
    for c, parent in (ps_table() if table is None else table).items():
        kids.setdefault(parent, []).append(c)
    found, todo = [], [pid]
    while todo:
        for c in kids.get(todo.pop(), []):
            if c not in found:
                found.append(c)
                todo.append(c)
    return found


def kill_pids(pids: list) -> int:
    import signal
    n = 0
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
            n += 1
        except OSError:
            pass
    return n


def restart_services(p: Paths) -> tuple:
    if WINDOWS:
        win_services_start(p, wait=False)  # taskkill /T on the supervisor takes the gateway's agents with it
        return True, "restarted the supervisor (MCP + gateway)"
    if no_launchd():
        return True, "no launchd here; nothing to restart"
    jobs = {MCP_LABEL: [sys.executable, str(ROOT / "reaper_mcp/http_server.py")],
            GW_LABEL: [sys.executable, str(ROOT / "gateway/agent_gateway.py")]}
    old, notes, ok = [], [], True
    for label, args in jobs.items():
        pid = service_pid(label)
        if pid:
            old += child_pids(pid)
        if p.plist(label).exists() and loaded(label):
            try:
                rc = subprocess.run(["launchctl", "kickstart", "-k", "%s/%s" % (domain(), label)],
                                    capture_output=True, timeout=10).returncode
            except (OSError, subprocess.SubprocessError):
                rc = -1
            notes.append("%s %s" % (label.split(".")[-1], "restarted" if rc == 0 else "restart failed (%s)" % rc))
            ok = ok and rc == 0
        else:
            env = {"REAPER_MCP_PORT": str(port())} if label == MCP_LABEL else None
            start_agent(p, label, args, env, KeepAlive=True, WorkingDirectory=str(ROOT))
            notes.append("%s started" % label.split(".")[-1])
    time.sleep(0.5)
    table = ps_table()
    current = set()
    for label in jobs:
        pid = service_pid(label)
        if pid:
            current.update([pid] + child_pids(pid, table))
    killed = kill_pids([pid for pid in old if pid in table and pid not in current])
    if killed:
        notes.append("stopped %d leftover agent/MCP process%s" % (killed, "" if killed == 1 else "es"))
    return ok, ", ".join(notes)


def kill_panel_streams() -> tuple:
    if WINDOWS:
        filt = " -or ".join("$_.CommandLine -like '*-A %s*'" % ua for ua in PANEL_STREAM_AGENTS)
        ps = ("$p = Get-CimInstance Win32_Process -Filter \"Name='curl.exe'\" | Where-Object { %s }; "
              "$p | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; "
              "@($p).Count" % filt)
        try:
            out = subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command", ps], capture_output=True,
                                 text=True, timeout=10).stdout.strip()
        except (OSError, subprocess.SubprocessError) as e:
            return False, "could not list curl processes: %s" % e
        n = int(out) if out.isdigit() else 0
    else:
        n = 0
        for ua in PANEL_STREAM_AGENTS:
            pattern = "curl -s -N -A %s" % ua
            try:
                found = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True, timeout=5).stdout.split()
                if found:
                    subprocess.run(["pkill", "-f", pattern], capture_output=True, timeout=5)
            except (OSError, subprocess.SubprocessError):
                found = []
            n += len(found)
    return True, "killed %d panel stream%s" % (n, "" if n == 1 else "s") if n else "none running"


def repair_files(p: Paths) -> tuple:
    fixed = []
    if not (p.scripts / "reaper_mcp_bridge.lua").exists():
        install_bridge(p)
        fixed.append("bridge script")
    if not all((p.scripts / "Hibiki" / n).exists() for n in PANEL_FILES) or not (p.effects / "Hibiki" / METER_JSFX).exists():
        install_panel(p)
        fixed.append("panel")
    if not p.token.exists() or len(p.token.read_text().strip()) < MIN_TOKEN:
        ensure_token(p)
        fixed.append("token")
    return True, "restored " + ", ".join(fixed) if fixed else "all present"


# ---------- stop / start ----------

def stopped_file(p: Paths) -> Path:
    return p.cfg / "stopped.json"


def is_stopped(p: Paths) -> bool:
    return stopped_file(p).exists()


def stop_labels(p: Paths) -> list:
    return [label for label in (MCP_LABEL, GW_LABEL, WD_LABEL, TUNNEL_LABEL) if p.plist(label).exists()]


def cmd_stop(a) -> int:
    """Turn the background services off and keep them off across logins, until `hibiki start` (or setup)."""
    p = Paths()
    p.cfg.mkdir(parents=True, exist_ok=True)
    if WINDOWS:
        was = win_services_stop(p, forget=True)
        write_json(stopped_file(p), {"at": time.strftime("%Y-%m-%d %H:%M:%S"), "windows": True}, 0o600)
        say("stopped: MCP and agent gateway%s; autostart at logon off" % ("" if was else " (were not running)"))
    else:
        labels = stop_labels(p)
        running = [label for label in labels if loaded(label)]
        old = []
        for label in running:
            pid = service_pid(label)
            if pid:
                old += child_pids(pid)
        for label in labels:
            stop_agent(p, label)
            launchctl("disable", "%s/%s" % (domain(), label))
        table = ps_table() if old else {}
        killed = kill_pids([pid for pid in old if pid in table])
        prev = load_json(stopped_file(p)).get("running", []) if is_stopped(p) else []
        write_json(stopped_file(p), {"at": time.strftime("%Y-%m-%d %H:%M:%S"),
                                     "running": running or prev}, 0o600)
        names = ", ".join(label.split(".")[-1] for label in labels) or "nothing installed"
        say("stopped: %s%s" % (names, "; %d leftover agent process%s ended" % (killed, "" if killed == 1 else "es")
                                if killed else ""))
        say("They stay off after login. REAPER keeps running; its bridge just has nobody to talk to.")
    say("Turn them back on with `hibiki start`.")
    return 0


def cmd_start(a) -> int:
    p = Paths()
    marker = load_json(stopped_file(p)) if is_stopped(p) else {}
    if WINDOWS:
        ok = win_services_start(p)
        stopped_file(p).unlink(missing_ok=True)
        return 0 if ok else 1
    labels = stop_labels(p)
    want = [label for label in marker.get("running", []) if label in labels] or \
        [label for label in labels if label != TUNNEL_LABEL or not marker]
    for label in (MCP_LABEL, GW_LABEL):
        if label not in labels:
            say("%s is not installed - run `hibiki setup`" % label)
    for label in labels:
        launchctl("enable", "%s/%s" % (domain(), label))
    for label in want:
        if not loaded(label):
            bootstrap(p, label, str(p.logs / (label.split(".")[-1] + ".log")))
    stopped_file(p).unlink(missing_ok=True)
    if no_launchd():
        return 0
    mcp = wait_http("http://127.0.0.1:%d/healthz" % port())
    gw = wait_http("http://127.0.0.1:%d/health" % GW_PORT)
    say("MCP on 127.0.0.1:%d: %s" % (port(), "up" if mcp else "NOT answering, see %s" % (p.logs / "reaper-mcp.log")))
    say("agent gateway on 127.0.0.1:%d: %s" % (GW_PORT, "up" if gw else "NOT answering, see %s"
                                              % (p.logs / "agent-gateway.log")))
    if WD_LABEL in want:
        say("watchdog: on")
    if TUNNEL_LABEL in want:
        say("tunnel: on")
    return 0 if mcp else 1


def cmd_recover(a) -> int:
    """The panel's Recover button: restart the services, drop stuck streams, report what answers. Never kills REAPER."""
    import contextlib
    import io
    p = Paths(getattr(a, "resource_path", None))
    steps = []

    def step(name: str, fn) -> None:
        try:
            ok, detail = fn()
        except BaseException as e:  # noqa: BLE001 - one failed step must not hide the others
            ok, detail = False, str(e) or repr(e)
        steps.append({"name": name, "ok": bool(ok), "detail": detail})

    def wait_services() -> tuple:
        deadline = time.time() + RECOVER_WAIT
        mcp = gw = False
        while True:
            mcp = mcp or wait_http("http://127.0.0.1:%d/healthz" % port(), 0)
            gw = gw or wait_http("http://127.0.0.1:%d/health" % GW_PORT, 0)
            if (mcp and gw) or time.time() > deadline:
                break
            time.sleep(0.5)
        steps.append({"name": "MCP http", "ok": mcp, "detail": "127.0.0.1:%d %s" % (port(), "answers" if mcp else
                      "no answer - see %s" % (p.logs / "reaper-mcp.log"))})
        return gw, "127.0.0.1:%d %s" % (GW_PORT, "answers" if gw else "no answer - see %s" % (p.logs / "agent-gateway.log"))

    def bridge() -> tuple:
        hb = p.ipc / "heartbeat"
        if not hb.exists():
            return False, "bridge never seen: start REAPER"
        age = time.time() - hb.stat().st_mtime
        if age < 5:
            return True, "bridge alive (heartbeat %.1fs old)" % age
        return False, ("bridge stale (heartbeat %.0fs old): REAPER busy or hung; the watchdog restarts a hung REAPER"
                       % age)

    if is_stopped(p):
        detail = "stopped with `hibiki stop` - run `hibiki start` to turn them back on"
        if a.json:
            print(json.dumps({"ok": False, "steps": [{"name": "services", "ok": False, "detail": detail}]}))
        else:
            print("FAIL %-17s %s" % ("services", detail))
        return 1
    sink = sys.stderr if (a.json and sys.stderr) else (io.StringIO() if a.json else sys.stdout)
    with contextlib.redirect_stdout(sink):
        step("files", lambda: repair_files(p))
        step("restart services", lambda: restart_services(p))
        step("panel streams", kill_panel_streams)
        step("agent gateway", wait_services)
        step("REAPER bridge", bridge)
    up = {s["name"]: s["ok"] for s in steps}
    ok = up.get("MCP http", False) and up.get("agent gateway", False)
    if a.json:
        print(json.dumps({"ok": ok, "steps": steps}))
    else:
        for s_ in steps:
            print("%-4s %-17s %s" % ("ok" if s_["ok"] else "FAIL", s_["name"], s_["detail"]))
        print("recovered" if ok else "not recovered: see the FAIL lines")
    return 0 if ok else 1


# ---------- update ----------

RELEASES_API = "https://api.github.com/repos/yiw190/hibiki/releases?per_page=50"
RELEASE_DOWNLOAD = "https://github.com/yiw190/hibiki/releases/download/"
UPDATE_TIMEOUT = 10
DOWNLOAD_TIMEOUT = 60
VERSION_RE = re.compile(r"^v?(\d+(?:\.\d+){0,3})(?:[-.]?(dev|a|alpha|b|beta|c|pre|rc)[.-]?(\d*))?$", re.I)
STAGES = {"dev": 0, "a": 1, "alpha": 1, "b": 2, "beta": 2, "c": 3, "pre": 3, "rc": 3}
FINAL = 9


class UpdateError(Exception):
    pass


def version_key(v: str) -> tuple:
    """0.5.0 < 0.5.1-dev.1 < 0.5.1-dev.4 < 0.5.1-rc.1 < 0.5.1 (dev < alpha < beta < rc < final)."""
    m = VERSION_RE.match(v.strip())
    if not m:
        raise ValueError("not a version: %r" % v)
    nums = tuple(int(x) for x in m.group(1).split("."))
    stage = STAGES[m.group(2).lower()] if m.group(2) else FINAL
    return nums + (0,) * (4 - len(nums)) + (stage, int(m.group(3) or 0))


def default_channel() -> str:
    return "dev" if "-" in __version__ else "stable"


def host_os() -> str:
    return "windows" if WINDOWS else ("macos" if sys.platform == "darwin" else sys.platform)


def packaged() -> bool:
    """True when ROOT is the .pkg payload (macOS) or the setup.exe install (Windows), not a git clone."""
    if WINDOWS:
        return "Programs" in ROOT.parts and "Hibiki" in ROOT.parts
    return PKG_ROOT in ROOT.parents or ROOT == PKG_ROOT


def gh_open(url: str, timeout: float):
    req = urllib.request.Request(url, headers={"User-Agent": "hibiki/%s" % __version__,
                                               "Accept": "application/vnd.github+json"})
    return urllib.request.urlopen(req, timeout=timeout)


def fetch_releases() -> list:
    with gh_open(RELEASES_API, UPDATE_TIMEOUT) as r:
        data = json.loads(r.read().decode("utf-8"))
    if not isinstance(data, list):
        raise UpdateError("GitHub answered without a release list: %s" % str(data)[:200])
    return data


def pick_release(releases: list, channel: str) -> dict | None:
    best = None
    for r in releases:
        if not isinstance(r, dict) or r.get("draft"):
            continue
        try:
            key = version_key(str(r.get("tag_name") or ""))
        except ValueError:
            continue
        if channel == "stable" and (r.get("prerelease") or key[4] != FINAL):
            continue
        if best is None or key > best[0]:
            best = (key, r)
    return best[1] if best else None


def release_url_ok(url: str) -> bool:
    u = urllib.parse.urlparse(url)
    return (url.startswith(RELEASE_DOWNLOAD) and u.scheme == "https" and u.netloc == "github.com"
            and not u.query and not u.fragment and ".." not in u.path and "\\" not in url)


def updates_dir() -> Path:
    if host_os() == "windows":
        d = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData/Local") / "Hibiki/updates"
    else:
        d = Path.home() / "Library/Caches/Hibiki/updates"
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def installer_name(version: str) -> str:
    if host_os() == "macos":
        return "Hibiki-%s.pkg" % version
    if host_os() == "windows":
        return "Hibiki-%s-setup.exe" % version
    raise UpdateError("no Hibiki installer for %s; update the source checkout with git" % host_os())


def asset_url(release: dict, name: str) -> str:
    for asset in release.get("assets") or []:
        if isinstance(asset, dict) and asset.get("name") == name:
            url = str(asset.get("browser_download_url") or "")
            if not release_url_ok(url):
                raise UpdateError("refusing %s: %s is not a Hibiki release download" % (name, url))
            return url
    raise UpdateError("release %s has no %s" % (release.get("tag_name"), name))


def download(url: str, dst: Path) -> str:
    if not release_url_ok(url):
        raise UpdateError("refusing to download %s: not a Hibiki release download" % url)
    part = dst.with_name(dst.name + ".part")
    h = hashlib.sha256()
    with gh_open(url, DOWNLOAD_TIMEOUT) as r, open(part, "wb") as f:
        while True:
            chunk = r.read(1 << 16)
            if not chunk:
                break
            h.update(chunk)
            f.write(chunk)
    os.replace(part, dst)
    return h.hexdigest()


def expected_sha(text: str, name: str) -> str:
    parts = text.split()
    if not parts or not re.match(r"^[0-9a-fA-F]{64}$", parts[0]):
        raise UpdateError("%s.sha256 is not a sha256 file" % name)
    if len(parts) > 1 and parts[1].lstrip("*") != name:
        raise UpdateError("%s.sha256 is for %s" % (name, parts[1]))
    return parts[0].lower()


def launch_installer(path: Path) -> list:
    """Opens the installer for the user; never silent, never sudo (macOS Installer asks for the admin password)."""
    cmd = ["open", str(path)] if host_os() == "macos" else [str(path)]
    kw = {"stdin": subprocess.DEVNULL, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL, "close_fds": True}
    if host_os() == "windows":
        kw["creationflags"] = getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    else:
        kw["start_new_session"] = True
    subprocess.Popen(cmd, **kw)
    return cmd


def install_release(release: dict, version: str) -> dict:
    name = installer_name(version)
    url, sha_url = asset_url(release, name), asset_url(release, name + ".sha256")
    d = updates_dir()
    with gh_open(sha_url, UPDATE_TIMEOUT) as r:
        want = expected_sha(r.read(64 * 1024).decode("utf-8", "replace"), name)
    dst = d / name
    got = download(url, dst)
    if got != want:
        dst.unlink()
        raise UpdateError("%s failed its sha256 check (got %s, expected %s); nothing was installed" % (name, got, want))
    return {"installer": str(dst), "sha256": got, "launched": launch_installer(dst)}


def cmd_update(a) -> int:
    channel = a.channel or default_channel()
    out = {"current": __version__, "channel": channel, "latest": None, "tag": None, "url": None, "published": None,
           "update_available": False, "notes": ""}
    try:
        if a.install and read_mode(Paths()).get("mode") == "dev":
            raise UpdateError("in dev mode (%s); run `hibiki use release` first" % read_mode(Paths()).get("path"))
        if a.install and not packaged():
            raise UpdateError("running from a source checkout; install the package instead")
        rel = pick_release(fetch_releases(), channel)
        if rel:
            tag = str(rel.get("tag_name"))
            latest = tag[1:] if tag[:1] in ("v", "V") else tag
            out.update(latest=latest, tag=tag, url=rel.get("html_url"), published=rel.get("published_at"),
                       update_available=version_key(latest) > version_key(__version__),
                       notes=str(rel.get("body") or "")[:600])
        if a.install:
            if not rel:
                raise UpdateError("no release on the %s channel" % channel)
            if not out["update_available"] and not a.force:
                out.update(launched=None, message="already up to date (%s)" % __version__)
            else:
                out.update(install_release(rel, out["latest"]))
                out["message"] = ("installer opened: finish it in the Installer window, then restart REAPER"
                                  if host_os() == "macos" else "installer opened: finish it, then restart REAPER")
    except (UpdateError, OSError, ValueError) as e:
        out["error"] = str(e) or repr(e)
    if a.json:
        print(json.dumps(out))
        return 1 if "error" in out else 0
    say("current: %s (channel %s)" % (__version__, channel))
    if out["latest"]:
        say("latest:  %s (%s, %s)  %s" % (out["latest"], out["tag"], str(out["published"] or "")[:10], out["url"]))
        say("update available: %s" % ("yes - run `hibiki update --install`" if out["update_available"] and not a.install
                                      else "yes" if out["update_available"] else "no, up to date"))
    elif "error" not in out:
        say("latest:  no release on the %s channel" % channel)
    if out.get("launched"):
        say("downloaded %s (sha256 ok)" % out["installer"])
        say("launched: %s" % " ".join(out["launched"]))
    if out.get("message"):
        say(out["message"])
    if "error" in out:
        say("error: %s" % out["error"])
        return 1
    return 0


def open_text_file(path: Path) -> list:
    """Open a text file in the user's editor without waiting; returns the command (none under HIBIKI_NO_SERVICES)."""
    if no_services():
        return []
    if WINDOWS:
        cmd = ["notepad", str(path)]
    elif sys.platform == "darwin":
        cmd = ["/usr/bin/open", "-t", str(path)]
    else:
        cmd = shlex.split(os.environ.get("VISUAL") or os.environ.get("EDITOR") or "xdg-open") + [str(path)]
    subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return cmd


def install_brain() -> None:
    """Seed the user's defaults.md from the package, or merge a newer package file into it (see reaper_mcp/brain)."""
    from reaper_mcp import brain
    try:
        r = brain.upgrade()
    except OSError as e:
        say("  agent rules: cannot write %s (%s)" % (brain.user_dir(), e))
        return
    if r["seeded"]:
        say("  agent rules: %s created" % brain.defaults_file())
    elif r["updated"] or r["added"]:
        say("  agent rules: %s%s%s" % ("updated " + ", ".join(r["updated"]) if r["updated"] else "",
                                       "; " if r["updated"] and r["added"] else "",
                                       "added " + ", ".join(r["added"]) if r["added"] else ""))
    else:
        say("  agent rules: up to date")
    if r["kept"]:
        say("  agent rules: kept your wording of %s (`hibiki rules reset <id>` takes the new text)" % ", ".join(r["kept"]))


def cmd_rules(a) -> int:
    """hibiki rules [edit [defaults|mine] | off <id> | on <id> | reset <id>|--all] [--path] [--json]"""
    from reaper_mcp import brain
    path = brain.rules_path()
    if a.path:
        say(str(path))
        return 0
    if a.action in ("off", "on"):
        if not a.id:
            say("usage: hibiki rules %s <id>   (ids: %s)" % (a.action, ", ".join(brain.ids())))
            return 2
        try:
            changed = brain.set_off(a.id, a.action == "off")
        except ValueError as e:
            say("error: %s" % e)
            return 1
        state = "off" if a.action == "off" else "on"
        say("%s: %s%s (%s); new agent sessions get it" % (a.id, state, "" if changed else ", already", path))
        return 0
    if a.action == "reset":
        if bool(a.id) == bool(a.all):
            say("usage: hibiki rules reset <id> | --all")
            return 2
        try:
            done = brain.reset(None if a.all else [a.id])
        except ValueError as e:
            say("error: %s" % e)
            return 1
        say("shipped text back for %s in %s" % (", ".join(done), brain.defaults_file()))
        return 0
    if a.action == "edit":
        if a.id not in (None, "defaults", "mine"):
            say("usage: hibiki rules edit [defaults | mine]")
            return 2
        made = not path.exists()
        brain.ensure()
        files = [p for k, p in (("defaults", brain.defaults_file()), ("mine", path)) if a.id in (None, k)]
        for f in files:
            open_text_file(f)
            say("%s%s" % (f, " (created from the template)" if f == path and made else ""))
        return 0
    if a.id or a.all:
        say("usage: hibiki rules [edit [defaults|mine] | off <id> | on <id> | reset <id>|--all] [--path]")
        return 2
    e = brain.effective()
    if a.json:
        print(json.dumps(dict(e, text=brain.compose())))
        return 0
    text = brain.compose()
    say(text or "(no rules: %s and %s are empty)" % (brain.defaults_file(), path))
    return 0


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="hibiki", description="REAPER MCP, Hibiki panel and agent gateway.")
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("setup", help="install or upgrade everything for this user (safe to re-run)")
    s.add_argument("--resource-path", help="REAPER resource path (default: ~/Library/Application Support/REAPER, "
                                           "%%APPDATA%%\\REAPER on Windows)")
    s.add_argument("--no-reaimgui", action="store_true", help="don't download ReaImGui")
    s.add_argument("--no-connect", action="store_true", help="don't register the MCP in Gamut / Claude / Cursor")
    s.add_argument("--mcp-only", action="store_true", help="only the MCP: bridge, startup hook and Claude / Cursor; "
                                                           "no panel, no gateway, no background services, no Gamut")
    s.set_defaults(fn=cmd_setup)
    d = sub.add_parser("doctor", help="check every piece and say what's wrong")
    d.add_argument("--resource-path")
    d.add_argument("--json", action="store_true")
    d.add_argument("--mcp-only", action="store_true", help="check only what `setup --mcp-only` installs")
    d.set_defaults(fn=cmd_doctor)
    c = sub.add_parser("connect", help="register the MCP in a client")
    c.add_argument("client", choices=["all", *CLIENTS])
    c.add_argument("--remove", action="store_true")
    c.add_argument("--agent", action="append", metavar="NAME|SLUG", help="gamut: enable REAPER for this agent")
    c.add_argument("--all-agents", action="store_true", help="gamut: enable REAPER for every agent")
    c.set_defaults(fn=cmd_connect)
    w = sub.add_parser("watchdog", help="relaunch REAPER after crashes (for an unattended Mac)")
    w.add_argument("state", choices=["on", "off"])
    w.set_defaults(fn=cmd_watchdog)
    g = sub.add_parser("agents", help="install ACP agents for the panel (needs Node; installed into ~/.local/node)")
    g.add_argument("action", choices=["add"])
    g.add_argument("agents", nargs="+", metavar="|".join(ACP_AGENTS))
    g.set_defaults(fn=cmd_agents)
    rc = sub.add_parser("recover", help="restart the MCP and gateway, drop stuck panel streams, report (REAPER untouched)")
    rc.add_argument("--resource-path")
    rc.add_argument("--json", action="store_true")
    rc.set_defaults(fn=cmd_recover)
    st = sub.add_parser("stop", help="turn the background services off (MCP, gateway, watchdog, tunnel); they stay off after login")
    st.set_defaults(fn=cmd_stop)
    sa = sub.add_parser("start", help="turn the background services back on after `hibiki stop`")
    sa.set_defaults(fn=cmd_start)
    u = sub.add_parser("uninstall", help="remove this user's install")
    u.add_argument("--resource-path")
    u.add_argument("--purge", action="store_true", help="also delete tokens, gateway config and ACP transcripts")
    u.set_defaults(fn=cmd_uninstall)
    up = sub.add_parser("update", help="check GitHub for a newer Hibiki release; --install downloads, verifies and opens "
                                       "its installer")
    up.add_argument("--check", action="store_true", help="only report (the default)")
    up.add_argument("--install", action="store_true", help="download the installer, verify its sha256 and open it")
    up.add_argument("--channel", choices=["stable", "dev"], help="dev includes pre-releases (default: dev on a "
                                                                    "pre-release build, else stable)")
    up.add_argument("--force", action="store_true", help="--install even when already up to date")
    up.add_argument("--json", action="store_true")
    up.set_defaults(fn=cmd_update)
    us = sub.add_parser("use", help="switch the whole install to a git checkout (dev) or back to the installed "
                                     "package (release); no argument or `status` shows the current mode")
    us.add_argument("target", nargs="?", choices=["dev", "release", "status"])
    us.add_argument("--path", help="dev: the checkout (default ~/reaper-mcp)")
    us.add_argument("--resource-path")
    us.add_argument("--json", action="store_true")
    us.set_defaults(fn=cmd_use)
    ru = sub.add_parser("rules", help="the rules every agent gets: your defaults.md (Hibiki's conventions, edit "
                                      "freely) + rules.md; `edit [defaults|mine]` opens them, `reset <id>|--all` "
                                      "brings shipped text back, `off <id>` / `on <id>` switch a convention")
    ru.add_argument("action", nargs="?", choices=["show", "edit", "off", "on", "reset"])
    ru.add_argument("id", nargs="?", help="a rule id (edit: defaults | mine)")
    ru.add_argument("--all", action="store_true", help="reset: every shipped rule")
    ru.add_argument("--path", action="store_true", help="print the path of your rules.md")
    ru.add_argument("--json", action="store_true")
    ru.set_defaults(fn=cmd_rules)
    r = sub.add_parser("run", help=argparse.SUPPRESS)  # the Windows supervisor (started by setup and at logon)
    r.add_argument("--port", type=int, default=port())
    r.set_defaults(fn=cmd_run)
    return ap


def main(argv: list) -> int:
    a = parser().parse_args(argv)
    if not getattr(a, "fn", None):
        parser().print_help()
        return 2
    return a.fn(a)
