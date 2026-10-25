#!/usr/bin/env python3
"""hibiki setup / doctor / connect / uninstall against a fake HOME, a fake Gamut and no launchd."""

from __future__ import annotations

import json
import os
import plistlib
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STARTUP = (ROOT / "reaper" / "__startup.lua").read_text()
OLD_BEARER = "old-bearer-0123456789abcdefghijklmnopqrstu"


class FakeGamut(BaseHTTPRequestHandler):
    servers: list = []
    assigned: dict = {}  # agent slug -> [mcp ids]

    def log_message(self, *a):
        pass

    def _reply(self, body):
        raw = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")

    def do_GET(self):
        if self.path == "/api/agents":
            return self._reply([{"slug": "ag1", "name": "Music"}, {"slug": "ag2", "name": "Other"}])
        if self.path.endswith("/remote-mcps") and self.path.startswith("/api/agents/"):
            slug = self.path.split("/")[3]
            ids = FakeGamut.assigned.get(slug, [])
            return self._reply({"mcps": [s for s in self.servers if s["id"] in ids]})
        self._reply({"servers": self.servers})

    def do_POST(self):
        b = self._body()
        if self.path.startswith("/api/agents/"):
            slug = self.path.split("/")[3]
            FakeGamut.assigned.setdefault(slug, []).extend(i for i in b["mcpIds"] if i not in FakeGamut.assigned.get(slug, []))
            return self._reply({"success": True})
        self.servers.append(dict(b, id="s%d" % len(self.servers)))
        self._reply({})

    def do_PATCH(self):
        b = self._body()
        sid = self.path.rsplit("/", 1)[-1]
        for s in self.servers:
            if s["id"] == sid:
                s.update(b)
        self._reply({})

    def do_DELETE(self):
        sid = self.path.rsplit("/", 1)[-1]
        FakeGamut.servers = [s for s in self.servers if s["id"] != sid]
        self._reply({})


def shim(res):
    """ReaImGui's imgui.lua shim, so setup doesn't download it (tests stay offline)."""
    f = res / "Scripts/ReaTeam Extensions/API/imgui.lua"
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text("-- shim")


def run(home, *args, gamut=""):
    env = dict(os.environ, HOME=str(home), HIBIKI_NO_SERVICES="1", GAMUT_URL=gamut or "http://127.0.0.1:9",
               USERPROFILE=str(home), APPDATA=str(home / "AppData/Roaming"), LOCALAPPDATA=str(home / "AppData/Local"),
               HIBIKI_SYSTEM_APPLICATIONS=str(home / "no-system-apps"),  # this Mac's own REAPER must not count
               PATH="/usr/bin:/bin")
    env.pop("REAPER_RESOURCE_PATH", None)
    env.pop("HIBIKI_BRAIN", None)
    r = subprocess.run([sys.executable, "-m", "reaper_mcp", *args], cwd=str(ROOT), env=env,
                       capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout + r.stderr


def main():
    failures = []

    def check(label, cond, detail=""):
        print(("  PASS " if cond else "  FAIL ") + label + ("" if cond else "  " + detail[-800:]))
        if not cond:
            failures.append(label)

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), FakeGamut)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    gamut = "http://127.0.0.1:%d" % httpd.server_address[1]

    home = Path(tempfile.mkdtemp(prefix="grs_home_"))
    res = home / "Library/Application Support/REAPER"
    scripts = res / "Scripts"
    la = home / "Library/LaunchAgents"
    for d in (scripts, res / "UserPlugins", la, home / ".config/reaper-mcp", home / ".config/agent-gateway",
              home / "Library/Application Support/Claude", home / ".cursor", home / "Applications/REAPER.app"):
        d.mkdir(parents=True)
    # a Mac set up by hand before the suite: hook copied verbatim, bearer in env, old LaunchAgents, user's own hook
    (scripts / "__startup.lua").write_text("-- my own thing\nreaper.ShowConsoleMsg('hi')\n\n" + STARTUP)
    (res / "UserPlugins/reaper_imgui-arm64.dylib").write_bytes(b"x")
    shim(res)
    (home / ".config/reaper-mcp/env").write_text("REAPER_MCP_BEARER=%s\nREAPER_MCP_PORT=8787\n" % OLD_BEARER)
    for old in ("com.yitian.reaper-mcp", "com.yitian.reaper-watchdog", "com.yitian.cloudflared-reaper"):
        with open(la / (old + ".plist"), "wb") as f:
            plistlib.dump({"Label": old, "ProgramArguments": ["/usr/bin/true"]}, f)
    (home / ".config/agent-gateway/config.json").write_text(json.dumps({
        "acp": [{"slug": "codex", "command": ["x"]}],
        "mcpServers": [{"name": "reaper", "command": "/usr/bin/python3", "args": ["/old/python/server.py"]},
                       {"name": "other", "command": "y"}]}))
    FakeGamut.servers = [{"id": "s0", "name": "reaper-mcp", "url": "http://localhost:8787/mcp",
                          "authType": "bearer", "accessToken": OLD_BEARER}]

    rc, out = run(home, "setup", gamut=gamut)
    check("setup exits 0", rc == 0, out)
    bridge = (scripts / "reaper_mcp_bridge.lua").read_text()
    check("bridge installed", bridge == (ROOT / "reaper_mcp/bridge.lua").read_text())
    check("panel installed", (scripts / "Hibiki/Hibiki.lua").exists() and (scripts / "Hibiki/studio.lua").exists())
    check("meter JSFX installed under Effects/Hibiki",
          (scripts.parent / "Effects/Hibiki/Hibiki_Meter.jsfx").read_text() == (ROOT / "panel/Hibiki_Meter.jsfx").read_text())
    cli = home / ".local/bin/hibiki"
    check("source checkout: ~/.local/bin/hibiki launcher for the panel's Recover",
          cli.exists() and os.access(cli, os.X_OK) and str(ROOT / "reaper_mcp/cli.py") in cli.read_text(), out)
    check("ReaImGui already present: no download", "already installed" in out and "shim: installed" not in out, out)
    hook = (scripts / "__startup.lua").read_text()
    check("startup: hand-copied hook adopted into the managed block, not duplicated",
          hook.count("reaper_mcp_bridge.lua") == 1 and "-- >>> hibiki" in hook, hook)
    check("startup: user's own lines kept", hook.startswith("-- my own thing\nreaper.ShowConsoleMsg('hi')\n"), hook)
    check("startup backup written", (scripts / "__startup.lua.bak").exists())
    tok = home / ".config/reaper-mcp/token"
    check("token reuses the bearer clients already hold", tok.read_text().strip() == OLD_BEARER)
    check("token is 0600", tok.stat().st_mode & 0o777 == 0o600)
    check("legacy MCP + watchdog LaunchAgents removed",
          not (la / "com.yitian.reaper-mcp.plist").exists() and not (la / "com.yitian.reaper-watchdog.plist").exists())
    check("cloudflared LaunchAgent untouched", (la / "com.yitian.cloudflared-reaper.plist").exists())
    mcp = plistlib.loads((la / "com.hibiki.reaper-mcp.plist").read_bytes())
    check("MCP LaunchAgent runs reaper_mcp/http_server.py with this python",
          mcp["ProgramArguments"] == [sys.executable, str(ROOT / "reaper_mcp/http_server.py")], str(mcp))
    check("no secret in the MCP plist", OLD_BEARER not in (la / "com.hibiki.reaper-mcp.plist").read_text())
    check("a python outside Hibiki.app: no bundle association", "AssociatedBundleIdentifiers" not in mcp, str(mcp))
    check("gateway LaunchAgent written", (la / "com.hibiki.agent-gateway.plist").exists())
    check("watchdog kept on (it was on before)", (la / "com.hibiki.reaper-watchdog.plist").exists())
    gw = json.loads((home / ".config/agent-gateway/config.json").read_text())
    check("gateway config: reaper entry repointed, others kept",
          gw["mcpServers"][0]["args"] == [str(ROOT / "reaper_mcp/server.py")]
          and [s["name"] for s in gw["mcpServers"]] == ["reaper", "other"] and gw["acp"][0]["slug"] == "codex", str(gw))
    check("Gamut: existing registration updated, not duplicated",
          len(FakeGamut.servers) == 1 and FakeGamut.servers[0]["accessToken"] == OLD_BEARER, str(FakeGamut.servers))
    cd = json.loads((home / "Library/Application Support/Claude/claude_desktop_config.json").read_text())
    check("Claude Desktop registered (stdio)", cd["mcpServers"]["reaper"]["args"] == [str(ROOT / "reaper_mcp/server.py")])
    check("Cursor registered", "reaper" in json.loads((home / ".cursor/mcp.json").read_text())["mcpServers"])

    seeded = home / ".config/hibiki/brain/defaults.md"
    check("setup seeds the user's defaults.md from the package", seeded.exists()
          and seeded.read_text() == (ROOT / "brain/defaults.md").read_text() and "agent rules:" in out, out)
    rc, out2 = run(home, "setup", gamut=gamut)
    check("second setup: agent rules up to date", "agent rules: up to date" in out2, out2)
    hook2 = (scripts / "__startup.lua").read_text()
    check("second setup: idempotent", rc == 0 and hook2 == hook and "bridge: up to date" in out2
          and "startup hook: up to date" in out2 and len(FakeGamut.servers) == 1, out2)

    (scripts / "reaper_mcp_bridge.lua").write_text('local VERSION = "0.0.1"\n')
    rc, out = run(home, "doctor", "--json", gamut=gamut)
    rows = {r["check"]: r for r in json.loads(out[out.index("["):])} if "[" in out else {}
    check("doctor flags an outdated bridge", rc == 1 and rows.get("bridge script", {}).get("level") == "FAIL", out)
    check("doctor sees the Gamut registration", rows.get("Gamut", {}).get("level") == "ok", out)

    mhome = Path(tempfile.mkdtemp(prefix="grs_mcp_only_"))
    mres = mhome / "Library/Application Support/REAPER"
    for d in (mres / "Scripts", mhome / ".cursor", mhome / "Applications/REAPER.app"):
        d.mkdir(parents=True)
    FakeGamut.servers, before = [], list(FakeGamut.servers)
    rc, out = run(mhome, "setup", "--mcp-only", gamut=gamut)
    mhook = (mres / "Scripts/__startup.lua").read_text() if (mres / "Scripts/__startup.lua").exists() else ""
    check("setup --mcp-only: bridge + startup hook + Cursor, nothing else",
          rc == 0 and (mres / "Scripts/reaper_mcp_bridge.lua").exists() and "reaper_mcp_bridge.lua" in mhook
          and "reaper" in json.loads((mhome / ".cursor/mcp.json").read_text())["mcpServers"]
          and not (mres / "Scripts/Hibiki").exists() and not (mhome / "Library/LaunchAgents").exists()
          and not (mhome / ".config/reaper-mcp/token").exists() and not (mhome / ".config/agent-gateway").exists()
          and not FakeGamut.servers, out)
    FakeGamut.servers = before
    rc, out = run(mhome, "doctor", "--mcp-only", "--json", gamut=gamut)
    mrows = {r["check"]: r["level"] for r in json.loads(out[out.index("["):])} if "[" in out else {}
    check("doctor --mcp-only: passes without panel, token or services",
          rc == 0 and mrows.get("startup hook") == "ok" and "token" not in mrows and "MCP http" not in mrows, out)

    rc, out = run(home, "connect", "gamut", "--agent", "Music", gamut=gamut)
    check("connect gamut --agent: REAPER assigned to that agent only",
          rc == 0 and FakeGamut.assigned.get("ag1") == [FakeGamut.servers[0]["id"]] and "ag2" not in FakeGamut.assigned
          and "Music: enabled" in out, out)
    rc, out = run(home, "connect", "gamut", "--all-agents", gamut=gamut)
    check("connect gamut --all-agents: idempotent for the first, enables the rest",
          "Music: already enabled" in out and "Other: enabled" in out and FakeGamut.assigned["ag1"] == [FakeGamut.servers[0]["id"]], out)

    rc, out = run(home, "connect", "cursor", "--remove")
    check("connect --remove", rc == 0 and "reaper" not in json.loads((home / ".cursor/mcp.json").read_text())["mcpServers"], out)

    rc, out = run(home, "uninstall", gamut=gamut)
    hook3 = (scripts / "__startup.lua").read_text()
    check("uninstall: services, scripts, managed hook gone; user lines stay",
          rc == 0 and not list(la.glob("com.hibiki.*")) and not (scripts / "reaper_mcp_bridge.lua").exists()
          and not (scripts / "Hibiki").exists() and not (scripts.parent / "Effects/Hibiki").exists()
          and "reaper_mcp_bridge" not in hook3 and "my own thing" in hook3, out)
    check("uninstall: Gamut registration removed", FakeGamut.servers == [], str(FakeGamut.servers))
    check("uninstall keeps the token without --purge", tok.exists())

    # onboarding order: no REAPER yet -> setup refuses and touches nothing
    bare = Path(tempfile.mkdtemp(prefix="grs_noreaper_"))
    rc, out = run(bare, "setup", "--no-connect")
    check("no REAPER: setup refuses with the download link",
          rc != 0 and "reaper.fm" in out and not (bare / "Library").exists(), out)

    fresh = Path(tempfile.mkdtemp(prefix="grs_fresh_"))
    (fresh / "Library/Application Support/REAPER/UserPlugins").mkdir(parents=True)
    (fresh / "Applications/REAPER64.app").mkdir(parents=True)
    (fresh / "Library/Application Support/REAPER/UserPlugins/reaper_imgui-x86_64.dylib").write_bytes(b"x")
    shim(fresh / "Library/Application Support/REAPER")
    rc, out = run(fresh, "setup", "--no-connect")
    t = (fresh / ".config/reaper-mcp/token").read_text().strip()
    check("fresh Mac: new random token, hook created", rc == 0 and len(t) >= 40
          and "-- >>> hibiki" in (fresh / "Library/Application Support/REAPER/Scripts/__startup.lua").read_text(), out)
    (fresh / ".config/reaper-mcp/token").write_text("short\n")
    rc, out = run(fresh, "setup", "--no-connect")
    t2 = (fresh / ".config/reaper-mcp/token").read_text().strip()
    check("a bearer under 32 characters is replaced", rc == 0 and len(t2) >= 40 and t2 != "short", out)
    check("fresh Mac: watchdog stays off", not (fresh / "Library/LaunchAgents/com.hibiki.reaper-watchdog.plist").exists())

    # the Mac before the Hibiki rename: the suite's own LaunchAgents under its old name, the hand-copied v0.3 hook
    # (it launches Scripts/GamutChat/GamutChat.lua), the old panel folder
    old = Path(tempfile.mkdtemp(prefix="grs_renamed_"))
    ores = old / "Library/Application Support/REAPER"
    ola = old / "Library/LaunchAgents"
    for d in (ores / "Scripts/GamutChat", ores / "UserPlugins", ola, old / "Applications/REAPER.app"):
        d.mkdir(parents=True)
    (ores / "UserPlugins/reaper_imgui-arm64.dylib").write_bytes(b"x")
    shim(ores)
    (ores / "Scripts/GamutChat/GamutChat.lua").write_text("-- old panel")
    sys.path.insert(0, str(ROOT))
    from reaper_mcp import suite
    (ores / "Scripts/__startup.lua").write_text(suite.LEGACY_HOOKS[0] + "\n")
    for lab in ("com.gamut-reaper-suite.reaper-mcp", "com.gamut-reaper-suite.agent-gateway",
                "com.gamut-reaper-suite.reaper-watchdog"):
        with open(ola / (lab + ".plist"), "wb") as f:
            plistlib.dump({"Label": lab, "ProgramArguments": ["/usr/bin/true"]}, f)
    rc, out = run(old, "setup", "--no-connect")
    hook = (ores / "Scripts/__startup.lua").read_text()
    check("rename: old suite LaunchAgents replaced by com.hibiki.*",
          rc == 0 and not list(ola.glob("com.gamut-reaper-suite.*"))
          and {p_.name for p_ in ola.glob("com.hibiki.*")} == {"com.hibiki.reaper-mcp.plist", "com.hibiki.agent-gateway.plist",
                                                              "com.hibiki.reaper-watchdog.plist"}, out)
    check("rename: hand-copied hook swapped for the managed one",
          "GamutChat" not in hook and hook.count("reaper_mcp_bridge.lua") == 1 and "-- >>> hibiki" in hook
          and "\"Hibiki.lua\"" in hook, hook)
    check("rename: old panel folder gone, new one installed",
          not (ores / "Scripts/GamutChat").exists() and (ores / "Scripts/Hibiki/Hibiki.lua").exists(), out)

    import re
    check("ACP agents: every npm package pinned to an exact version",
          all(re.match(r"^\d+\.\d+\.\d+$", a.get("version", "")) for a in suite.ACP_AGENTS.values()), str(suite.ACP_AGENTS))
    calls = []
    real_run, real_node, real_write = suite.subprocess.run, suite.ensure_node, suite.write_json
    suite.subprocess.run = lambda cmd, **kw: calls.append(cmd)
    suite.ensure_node = lambda p_: Path("/nonexistent/node/bin")
    suite.write_json = lambda *a, **kw: None
    try:
        suite.agents_add(suite.Paths(), ["codex", "minimax"], restart=False)
    finally:
        suite.subprocess.run, suite.ensure_node, suite.write_json = real_run, real_node, real_write
    check("ACP agents: npm installs the pinned spec, scripts off unless the package needs them",
          len(calls) == 2 and calls[0][-1] == "@agentclientprotocol/codex-acp@2.2.2" and "--ignore-scripts" in calls[0]
          and calls[1][-1].startswith("@minimax-ai/code@") and "--ignore-scripts" not in calls[1], str(calls))

    check_rules(check)
    check_recover(check, suite)
    check_stop_start(check, suite)
    check_update(check, suite)
    check_use(check, suite)
    check_app_bundle(check, suite)

    httpd.shutdown()
    if failures:
        print("FAILED", failures)
        sys.exit(1)
    print("all passed")


def check_rules(check):
    """hibiki rules / --path / edit / off / on against a fake HOME (edit opens nothing under HIBIKI_NO_SERVICES)."""
    home = Path(tempfile.mkdtemp(prefix="hb_rules_"))
    rules = home / ".config/hibiki/brain/rules.md"
    rc, out = run(home, "rules")
    check("rules: defaults printed with no rules.md", rc == 0 and out.startswith("## Hibiki conventions")
          and "[single-dls]" in out and "## Your rules" not in out, out)
    rc, out = run(home, "rules", "--path")
    check("rules --path", rc == 0 and out.strip() == str(rules), out)
    copy = rules.parent / "defaults.md"
    check("rules: the first read seeds defaults.md", copy.exists())
    rc, out = run(home, "rules", "edit")
    text = rules.read_text() if rules.exists() else ""
    check("rules edit: both files, rules.md from the template", rc == 0 and "created from the template" in out
          and str(copy) in out and "off: <id>" in text and "defaults.md" in text, out + text)
    rc, out = run(home, "rules", "edit", "mine")
    check("rules edit mine: only rules.md", rc == 0 and out.strip() == str(rules), out)
    shipped = copy.read_text()
    copy.write_text(shipped.replace("- [ears-files] Files named", "- [ears-files] Example rewording. Files named"))
    rc, out = run(home, "rules")
    check("rules: a rewritten default is what agents get", "[ears-files] Example rewording." in out, out)
    rc, out = run(home, "rules", "reset", "ears-files")
    check("rules reset <id>", rc == 0 and copy.read_text() == shipped, out)
    rc, out = run(home, "rules", "reset", "no-such-rule")
    check("rules reset: unknown id refused", rc == 1 and "no shipped rule" in out, out)
    copy.write_text("- [ears-files] only this one, the rest deleted\n")
    rc, out = run(home, "rules", "reset", "--all")
    check("rules reset --all", rc == 0 and [ln for ln in copy.read_text().splitlines() if ln.startswith("- [")][-1]
          .startswith("- [restore-point]") and "[ears-files] Files named" in copy.read_text(), out)
    rc, out = run(home, "rules", "off", "no-such-rule")
    check("rules off: unknown id refused", rc == 1 and "no default rule" in out, out)
    rc, out = run(home, "rules", "off", "rack-audible")
    rc2, shown = run(home, "rules")
    check("rules off <id>", rc == 0 and "- off: rack-audible" in rules.read_text() and "[rack-audible]" not in shown
          and "## Your rules" not in shown, out + shown)
    with open(rules, "a", encoding="utf-8") as f:
        f.write("- Example rule for the test.\n")
    rc, out = run(home, "rules", "on", "rack-audible")
    rc2, shown = run(home, "rules")
    check("rules on <id>; your rules follow the conventions", rc == 0 and "off:" not in rules.read_text().split("-->")[-1]
          and "[rack-audible]" in shown and shown.rstrip().endswith("## Your rules\n- Example rule for the test."),
          out + shown)
    rc, out = run(home, "rules", "--json")
    info = json.loads(out) if rc == 0 else {}
    check("rules --json", info.get("count") == 1 and info.get("off") == [] and len(info.get("defaults", [])) >= 8, out)


def check_recover(check, suite):
    """`hibiki recover --json` with launchctl, ps, pkill and the HTTP checks faked."""
    import contextlib
    import io
    home = Path(tempfile.mkdtemp(prefix="grs_recover_"))
    res = home / "Library/Application Support/REAPER"
    (res / "Scripts").mkdir(parents=True)
    (home / "Library/LaunchAgents").mkdir(parents=True)
    for label in (suite.MCP_LABEL, suite.GW_LABEL):
        (home / "Library/LaunchAgents" / (label + ".plist")).write_bytes(b"x")
    ipc = home / "ipc"
    ipc.mkdir()
    (ipc / "heartbeat").write_text("1")
    os.utime(ipc / "heartbeat", (1, 1))
    calls, killed = [], []
    restarted = {"done": False}
    gw_pid = {suite.MCP_LABEL: "100", suite.GW_LABEL: "200"}

    class R:
        def __init__(self, out="", rc=0):
            self.stdout, self.returncode = out, rc

    def fake_run(cmd, **kw):
        calls.append(list(cmd))
        if cmd[:2] == ["launchctl", "print"]:
            label = cmd[2].split("/")[-1]
            pid = gw_pid[label] if not restarted["done"] else str(int(gw_pid[label]) + 1000)
            return R("state = running\n\tpid = %s\n" % pid)
        if cmd[:3] == ["launchctl", "kickstart", "-k"]:
            if cmd[3].endswith(suite.GW_LABEL):
                restarted["done"] = True
            return R()
        if cmd[0] == "ps":
            if not restarted["done"]:
                return R(" 100 1\n 101 100\n 200 1\n 201 200\n 202 201\n")
            return R(" 1100 1\n 1101 1100\n 1200 1\n 201 1\n 202 201\n")
        if cmd[0] == "pgrep":
            return R("555\n" if "HibikiPanel" in cmd[-1] else "")
        return R()

    saved = {k: getattr(suite, k) for k in ("no_launchd", "domain", "wait_http", "kill_pids", "WINDOWS", "loaded")}
    real_run = suite.subprocess.run
    env_saved = {k: os.environ.get(k) for k in ("HOME", "REAPER_MCP_IPC_DIR")}
    os.environ["HOME"], os.environ["REAPER_MCP_IPC_DIR"] = str(home), str(ipc)
    suite.no_launchd, suite.domain, suite.WINDOWS = (lambda: False), (lambda: "gui/501"), False
    suite.loaded = lambda label: True
    suite.wait_http = lambda url, seconds=10: True
    suite.kill_pids = lambda pids: killed.extend(pids) or len(pids)
    suite.subprocess.run = fake_run
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            rc = suite.main(["recover", "--json"])
    finally:
        suite.subprocess.run = real_run
        for k, v in saved.items():
            setattr(suite, k, v)
        for k, v in env_saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    try:
        r = json.loads(out.getvalue())
    except ValueError:
        r = {}
    steps = {x["name"]: x for x in r.get("steps", [])}
    check("recover --json: stdout is one JSON object with ok + steps", r.get("ok") is True and rc == 0
          and all(set(x) == {"name", "ok", "detail"} for x in r.get("steps", [])), out.getvalue())
    check("recover: kickstart -k for the MCP and the gateway",
          ["launchctl", "kickstart", "-k", "gui/501/" + suite.MCP_LABEL] in calls
          and ["launchctl", "kickstart", "-k", "gui/501/" + suite.GW_LABEL] in calls, str(calls))
    check("recover: the old gateway's orphaned agents are killed, the new ones kept",
          sorted(killed) == [201, 202], str(killed))
    check("recover: panel stream curls killed for both user agents",
          ["pkill", "-f", "curl -s -N -A HibikiPanel"] in calls and ["pgrep", "-f", "curl -s -N -A GamutChatPanel"] in calls
          and steps.get("panel streams", {}).get("detail") == "killed 1 panel stream", str(steps))
    check("recover: missing bridge / panel / token restored",
          (res / "Scripts/reaper_mcp_bridge.lua").exists() and (res / "Scripts/Hibiki/Hibiki.lua").exists()
          and (home / ".config/reaper-mcp/token").exists() and "bridge script" in steps.get("files", {}).get("detail", ""))
    check("recover: stale bridge reported, REAPER left alone",
          steps.get("REAPER bridge", {}).get("ok") is False and "stale" in steps["REAPER bridge"]["detail"]
          and not any("REAPER" in " ".join(c) and ("kill" in c[0]) for c in calls))
    check("recover: MCP + gateway up -> ok", steps.get("MCP http", {}).get("ok") and steps.get("agent gateway", {}).get("ok"))


def check_stop_start(check, suite):
    """`hibiki stop` / `start` with launchctl faked: services off and disabled across logins, then restored."""
    import contextlib
    import io
    home = Path(tempfile.mkdtemp(prefix="grs_stop_"))
    la = home / "Library/LaunchAgents"
    la.mkdir(parents=True)
    for label in (suite.MCP_LABEL, suite.GW_LABEL, suite.WD_LABEL):
        (la / (label + ".plist")).write_bytes(b"x")
    calls = []
    state = {suite.MCP_LABEL: True, suite.GW_LABEL: True, suite.WD_LABEL: False}

    def fake_launchctl(*args):
        calls.append(list(args))
        label = args[-1].split("/")[-1].replace(".plist", "")
        if args[0] == "bootout":
            state[label] = False
        if args[0] == "bootstrap":
            state[label] = True
        return 0

    saved = {k: getattr(suite, k) for k in ("no_launchd", "domain", "wait_http", "WINDOWS", "loaded", "launchctl",
                                             "service_pid", "kill_pids")}
    env_saved = os.environ.get("HOME")
    os.environ["HOME"] = str(home)
    suite.no_launchd, suite.domain, suite.WINDOWS = (lambda: False), (lambda: "gui/501"), False
    suite.launchctl = fake_launchctl
    suite.loaded = lambda label: state.get(label, False)
    suite.service_pid = lambda label: 0
    suite.kill_pids = lambda pids: 0
    suite.wait_http = lambda url, seconds=10: all(state[x] for x in (suite.MCP_LABEL, suite.GW_LABEL))
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            rc1 = suite.main(["stop"])
            marker = json.loads((home / ".config/reaper-mcp/stopped.json").read_text())
            after_stop = dict(state)
            with contextlib.redirect_stdout(io.StringIO()) as rec:
                rc_rec = suite.main(["recover", "--json"])
            calls_stop = list(calls)
            rc2 = suite.main(["start"])
    finally:
        for k, v in saved.items():
            setattr(suite, k, v)
        os.environ["HOME"] = env_saved
    check("stop: every installed service booted out and disabled for later logins",
          rc1 == 0 and not any(after_stop.values())
          and all(["disable", "gui/501/" + x] in calls_stop for x in (suite.MCP_LABEL, suite.GW_LABEL, suite.WD_LABEL)),
          str(calls_stop))
    check("stop: remembers what was running (watchdog was off)",
          sorted(marker.get("running", [])) == sorted([suite.MCP_LABEL, suite.GW_LABEL]), str(marker))
    r = json.loads(rec.getvalue() or "{}")
    check("recover after stop: refuses and points at `hibiki start`, restarts nothing",
          rc_rec == 1 and r.get("ok") is False and "hibiki start" in r["steps"][0]["detail"]
          and not any(c[0] in ("kickstart", "bootstrap") for c in calls_stop), rec.getvalue())
    check("start: enables and bootstraps only what was running, clears the marker",
          rc2 == 0 and state[suite.MCP_LABEL] and state[suite.GW_LABEL] and not state[suite.WD_LABEL]
          and ["enable", "gui/501/" + suite.MCP_LABEL] in calls
          and not (home / ".config/reaper-mcp/stopped.json").exists(), str(calls[len(calls_stop):]))


def check_update(check, suite):
    """`hibiki update` with the GitHub API, downloads and the installer launch faked (nothing leaves the machine)."""
    import contextlib
    import hashlib
    import io
    order = ["0.5.0", "0.5.1-dev.1", "0.5.1-dev.4", "0.5.1-rc.1", "0.5.1", "0.5.2-dev.1", "0.10.0"]
    keys = [suite.version_key(v) for v in order]
    check("update: version order 0.5.0 < 0.5.1-dev.1 < 0.5.1-dev.4 < 0.5.1-rc.1 < 0.5.1 < 0.5.2-dev.1 < 0.10.0",
          keys == sorted(keys) and len(set(keys)) == len(keys) and suite.version_key("v0.5.1") == suite.version_key("0.5.1")
          and suite.version_key("0.5.1-dev.10") > suite.version_key("0.5.1-dev.9"), str(keys))

    from reaper_mcp import cli
    check("cli: `hibiki update` (and stop / start) reach the suite", {"update", "stop", "start"} <= cli.SUITE)
    dl = "https://github.com/yiw190/hibiki/releases/download/"
    pkg_body = b"fake pkg bytes"
    exe_body = b"fake exe bytes"

    def rel(tag, pre, assets=None):
        v = tag[1:]
        return {"tag_name": tag, "prerelease": pre, "draft": False, "html_url": "https://github.com/yiw190/hibiki/releases/tag/" + tag,
                "published_at": "2026-10-23T08:00:00Z", "body": "notes " * 200,
                "assets": assets if assets is not None else [
                    {"name": n, "browser_download_url": dl + tag + "/" + n}
                    for n in ("Hibiki-%s.pkg" % v, "Hibiki-%s.pkg.sha256" % v, "Hibiki-%s-setup.exe" % v,
                              "Hibiki-%s-setup.exe.sha256" % v)]}

    releases = [rel("v0.5.1-dev.5", True), rel("v0.5.0", False), rel("v0.5.0-rc.1", True),
                {"tag_name": "v9.9.9", "prerelease": False, "draft": True}, {"tag_name": "nightly", "prerelease": True}]
    state = {"releases": releases, "files": {}, "fetched": [], "headers": []}

    def set_files(tag, pkg_sha=None):
        v = tag[1:]
        state["files"] = {
            dl + tag + "/Hibiki-%s.pkg" % v: pkg_body,
            dl + tag + "/Hibiki-%s.pkg.sha256" % v: (
                "%s  Hibiki-%s.pkg\n" % (pkg_sha or hashlib.sha256(pkg_body).hexdigest(), v)).encode(),
            dl + tag + "/Hibiki-%s-setup.exe" % v: exe_body,
            dl + tag + "/Hibiki-%s-setup.exe.sha256" % v: (
                "%s  Hibiki-%s-setup.exe\n" % (hashlib.sha256(exe_body).hexdigest(), v)).encode()}

    class Resp(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            self.close()

    def fake_urlopen(req, timeout=None):
        url = req.full_url if hasattr(req, "full_url") else req
        state["fetched"].append((url, timeout))
        state["headers"].append(dict(req.header_items()) if hasattr(req, "header_items") else {})
        if url == suite.RELEASES_API:
            return Resp(json.dumps(state["releases"]).encode())
        if url in state["files"]:
            return Resp(state["files"][url])
        raise suite.urllib.error.URLError("unexpected url " + url)

    launched = []

    class FakePopen:
        def __init__(self, cmd, **kw):
            launched.append((list(cmd), kw))

    home = Path(tempfile.mkdtemp(prefix="grs_update_"))
    saved = {k: getattr(suite, k) for k in ("__version__", "host_os", "packaged", "WINDOWS")}
    saved_urlopen, saved_popen = suite.urllib.request.urlopen, suite.subprocess.Popen
    env_saved = {k: os.environ.get(k) for k in ("HOME", "LOCALAPPDATA")}
    os.environ["HOME"], os.environ["LOCALAPPDATA"] = str(home), str(home / "AppData/Local")
    suite.urllib.request.urlopen, suite.subprocess.Popen = fake_urlopen, FakePopen

    def run(*argv, version="0.5.1-dev.4", os_name="macos", pkg=True):
        suite.__version__ = version
        suite.host_os = lambda: os_name
        suite.WINDOWS = os_name == "windows"
        suite.packaged = (lambda: pkg) if pkg is not None else saved["packaged"]
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = suite.main(["update", *argv])
        text = out.getvalue()
        try:
            return rc, json.loads(text), text
        except ValueError:
            return rc, {}, text

    try:
        rc, j, _ = run("--json")
        check("update --json: shape", set(j) == {"current", "latest", "tag", "url", "published", "update_available",
                                                 "channel", "notes"} and rc == 0, str(j))
        check("update: a dev build defaults to the dev channel and sees the newest pre-release",
              j.get("channel") == "dev" and j.get("latest") == "0.5.1-dev.5" and j.get("tag") == "v0.5.1-dev.5"
              and j.get("update_available") is True and j.get("published", "").startswith("2026-10-23")
              and j.get("url", "").endswith("/v0.5.1-dev.5") and len(j.get("notes", "")) == 600, str(j))
        check("update: GitHub API asked with a User-Agent and a 10 s timeout",
              state["fetched"][0] == (suite.RELEASES_API, 10)
              and any(k.lower() == "user-agent" for k in state["headers"][0]), str(state["fetched"][:1]))
        rc, j, _ = run("--json", version="0.5.0")
        check("update: a release build defaults to stable (pre-releases and drafts ignored)",
              j.get("channel") == "stable" and j.get("latest") == "0.5.0" and j.get("update_available") is False, str(j))
        rc, j, _ = run("--json", "--channel", "dev", version="0.5.0")
        check("update --channel dev on a release build: newest pre-release", j.get("latest") == "0.5.1-dev.5", str(j))
        state["releases"] = [rel("v0.5.1-rc.1", True), rel("v0.5.1", False)] + releases
        rc, j, _ = run("--json", "--channel", "dev")
        check("update: the final release outranks its rc and dev builds", j.get("latest") == "0.5.1", str(j))
        state["releases"] = releases
        rc, _, text = run()
        check("update (text): current, latest, tag, date, url, availability",
              rc == 0 and "0.5.1-dev.4" in text and "v0.5.1-dev.5" in text and "2026-10-23" in text
              and "releases/tag/v0.5.1-dev.5" in text and "update available: yes" in text, text)

        launched.clear()
        rc, j, _ = run("--install", "--json", pkg=None)
        check("update --install from a source checkout: refused, nothing downloaded or launched",
              rc == 1 and j.get("error") == "running from a source checkout; install the package instead" and not launched, str(j))

        set_files("v0.5.1-dev.5")
        state["fetched"].clear()
        rc, j, _ = run("--install", "--json")
        pkg = home / "Library/Caches/Hibiki/updates/Hibiki-0.5.1-dev.5.pkg"
        check("update --install (macOS): pkg + .sha256 downloaded into a 0700 cache, verified, `open`ed (not run)",
              rc == 0 and pkg.read_bytes() == pkg_body and (pkg.parent.stat().st_mode & 0o777) == 0o700
              and launched and launched[-1][0] == ["open", str(pkg)] and j.get("launched") == ["open", str(pkg)]
              and j.get("installer") == str(pkg) and "Installer" in j.get("message", "")
              and not any("sudo" in str(c) for c in launched), str(j))

        launched.clear()
        rc, j, _ = run("--install", "--json", os_name="windows")
        exe = home / "AppData/Local/Hibiki/updates/Hibiki-0.5.1-dev.5-setup.exe"
        check("update --install (Windows): setup.exe verified and started interactively (no /SILENT)",
              rc == 0 and exe.read_bytes() == exe_body and launched and launched[-1][0] == [str(exe)]
              and not any("SILENT" in a.upper() for a in launched[-1][0][1:]), str(j) + str(launched))

        launched.clear()
        set_files("v0.5.1-dev.5", pkg_sha="0" * 64)
        rc, j, _ = run("--install", "--json")
        check("update --install: sha256 mismatch refused, file deleted, nothing launched",
              rc == 1 and "sha256" in j.get("error", "") and not launched
              and not (home / "Library/Caches/Hibiki/updates/Hibiki-0.5.1-dev.5.pkg").exists(), str(j))

        launched.clear()
        state["fetched"].clear()
        bad = rel("v0.5.1-dev.5", True, assets=[
            {"name": "Hibiki-0.5.1-dev.5.pkg", "browser_download_url": "https://evil.example/Hibiki-0.5.1-dev.5.pkg"},
            {"name": "Hibiki-0.5.1-dev.5.pkg.sha256", "browser_download_url": dl + "v0.5.1-dev.5/Hibiki-0.5.1-dev.5.pkg.sha256"}])
        state["releases"] = [bad]
        rc, j, _ = run("--install", "--json")
        check("update --install: a download URL outside github.com/yiw190/hibiki/releases/download/ is refused",
              rc == 1 and "evil.example" in j.get("error", "") and not launched
              and not any("evil" in u for u, _ in state["fetched"]), str(j))
        check("update: URL allow-list", all(not suite.release_url_ok(u) for u in (
            "http://github.com/yiw190/hibiki/releases/download/v1/x.pkg",
            "https://github.com.evil.io/yiw190/hibiki/releases/download/v1/x.pkg",
            "https://github.com/yiw190/other/releases/download/v1/x.pkg",
            "https://github.com/yiw190/hibiki/releases/download/../../other/x.pkg",
            "https://github.com/yiw190/hibiki/releases/download/v1/x.pkg?x=1"))
            and suite.release_url_ok(dl + "v1/Hibiki-1.pkg"))

        launched.clear()
        state["releases"] = releases
        rc, j, _ = run("--install", "--json", version="0.5.1-dev.5")
        check("update --install when up to date: says so, downloads and launches nothing",
              rc == 0 and j.get("update_available") is False and "up to date" in j.get("message", "") and not launched,
              str(j))
        set_files("v0.5.1-dev.5")
        rc, j, _ = run("--install", "--force", "--json", version="0.5.1-dev.5")
        check("update --install --force: reinstalls the same version", rc == 0 and launched, str(j))

        suite.urllib.request.urlopen = lambda req, timeout=None: (_ for _ in ()).throw(
            suite.urllib.error.URLError("offline"))
        rc, j, _ = run("--json")
        check("update offline: JSON error, exit 1", rc == 1 and "offline" in j.get("error", ""), str(j))
    finally:
        for k, v in saved.items():
            setattr(suite, k, v)
        suite.urllib.request.urlopen, suite.subprocess.Popen = saved_urlopen, saved_popen
        for k, v in env_saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def check_app_bundle(check, suite):
    """The package's Hibiki.app: pkg_python prefers it, LaunchAgents on it name the bundle, the watchdog starts as it."""
    import contextlib
    import io
    home = Path(tempfile.mkdtemp(prefix="hb_app_"))
    pkg = home / "pkg"
    (pkg / "python/bin").mkdir(parents=True)
    (pkg / "python/bin/python3").write_text("")
    saved = suite.PKG_ROOT, suite.no_launchd, suite.WINDOWS
    suite.PKG_ROOT, suite.no_launchd, suite.WINDOWS = pkg, (lambda: True), False
    try:
        check("app: a package without Hibiki.app keeps bin/python3", suite.pkg_python() == pkg / "python/bin/python3")
        exe = pkg / "python/Hibiki.app/Contents/MacOS/Hibiki"
        exe.parent.mkdir(parents=True)
        exe.write_text("")
        check("app: pkg_python prefers Hibiki.app", suite.pkg_python() == exe, str(suite.pkg_python()))

        p = suite.Paths()
        p.la, p.logs = home / "LaunchAgents", home / "logs"
        with contextlib.redirect_stdout(io.StringIO()):
            suite.start_agent(p, "com.hibiki.test", [str(exe), "x.py"])
            suite.start_agent(p, "com.hibiki.test2", ["/usr/bin/python3", "x.py"])
        a = plistlib.loads((p.la / "com.hibiki.test.plist").read_bytes())
        b = plistlib.loads((p.la / "com.hibiki.test2.plist").read_bytes())
        check("app: a job on Hibiki.app names its bundle, a bare python doesn't",
              a.get("AssociatedBundleIdentifiers") == [suite.APP_ID] and "AssociatedBundleIdentifiers" not in b, str(a))

        check("app: watchdog outside the app runs bash directly",
              suite.watchdog_args("/usr/bin/python3", "/w.sh") == ["/bin/bash", "/w.sh"])
        script = home / "w.sh"
        script.write_text('echo "bash $BASH_VERSION"\n')
        args = suite.watchdog_args(str(exe), str(script))
        r = subprocess.run([sys.executable] + args[1:], capture_output=True, text=True, timeout=20)
        check("app: watchdog starts as Hibiki and execs bash on the script",
              args[0] == str(exe) and args[-1] == str(script) and r.stdout.startswith("bash "), r.stdout + r.stderr)
    finally:
        suite.PKG_ROOT, suite.no_launchd, suite.WINDOWS = saved


def check_use(check, suite):
    """`hibiki use dev|release|status` and the forwarding in cli.main, with a fake package and no real setup."""
    import contextlib
    import io
    from reaper_mcp import cli
    home = Path(tempfile.mkdtemp(prefix="hb_use_"))
    pkg = home / "pkg"
    (pkg / "python/bin").mkdir(parents=True)
    (pkg / "python/bin/python3").write_text("")
    (pkg / "app/reaper_mcp").mkdir(parents=True)
    (pkg / "app/reaper_mcp/cli.py").write_text("")
    (pkg / "VERSION").write_text("0.5.0\n")
    co = home / "reaper-mcp"
    for rel in suite.CHECKOUT_FILES + ("reaper_mcp/__init__.py",):
        (co / rel).parent.mkdir(parents=True, exist_ok=True)
        (co / rel).write_text('__version__ = "9.9.9-dev.1"\n' if rel.endswith("__init__.py") else "")
    shim_ = home / ".local/bin/hibiki"
    shim_.parent.mkdir(parents=True)
    shim_.write_text('#!/bin/sh\nexec /usr/bin/python3 -s -E /x/reaper_mcp/cli.py "$@"\n')
    mode = home / ".config/reaper-mcp/mode.json"
    calls, execs = [], []

    class Done(Exception):
        pass

    def fake_run(cmd, **kw):
        calls.append((list(cmd), kw))
        if cmd[0] == "git":
            out = "abc1234\n" if "rev-parse" in cmd else " M panel/Hibiki.lua\n"
            return subprocess.CompletedProcess(cmd, 0, out, "")
        return subprocess.CompletedProcess(cmd, 0, "", "")

    def fake_execv(py, args):
        execs.append((py, list(args), os.environ.get("HIBIKI_FORWARDED")))
        raise Done()

    saved = {k: getattr(suite, k) for k in ("PKG_ROOT", "ROOT")}
    saved_run, saved_execv = suite.subprocess.run, os.execv
    env_keys = ("HOME", "HIBIKI_FORWARDED", "HIBIKI_USE_RELEASE", "HIBIKI_NO_SHIM")
    env_saved = {k: os.environ.get(k) for k in env_keys}
    for k in env_keys[1:]:
        os.environ.pop(k, None)
    os.environ["HOME"] = str(home)
    suite.PKG_ROOT, suite.subprocess.run, os.execv = pkg, fake_run, fake_execv

    def call(fn, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                rc = fn(list(argv))
            except Done:
                rc = "exec"
        return rc, out.getvalue() + err.getvalue()

    try:
        rc, out = call(suite.main, "use", "dev", "--path", str(home / "nope"))
        check("use dev: a folder that isn't a checkout is refused, mode unchanged", rc == 2 and not mode.exists(), out)

        rc, out = call(suite.main, "use", "dev", "--path", str(co))
        m = json.loads(mode.read_text()) if mode.exists() else {}
        setup = [c for c in calls if c[0][0] != "git"]
        check("use dev: mode.json records the checkout, the package python and the commit",
              rc == 0 and m.get("mode") == "dev" and m.get("path") == str(co.resolve()) and m.get("commit") == "abc1234"
              and m.get("dirty") is True and m.get("python") == str(pkg / "python/bin/python3") and m.get("at"), out)
        check("use dev: runs the checkout's setup with the package python, forwarded and without a shim",
              len(setup) == 1 and setup[0][0] == [str(pkg / "python/bin/python3"), "-s", "-E",
                                                  str(co.resolve() / "reaper_mcp/cli.py"), "setup"]
              and setup[0][1]["env"].get("HIBIKI_FORWARDED") == "1" and setup[0][1]["env"].get("HIBIKI_NO_SHIM") == "1",
              str(setup))
        check("use dev: old ~/.local/bin/hibiki shim removed", not shim_.exists(), out)
        check("use dev: summary names the commit and says REAPER needs a restart",
              "abc1234 +dirty" in out and "restart REAPER" in out, out)

        rc, out = call(suite.main, "use", "--json")
        st = json.loads(out) if out.startswith("{") else {}
        check("use --json: dev, path, commit, version, python",
              rc == 0 and st.get("mode") == "dev" and st.get("commit") == "abc1234" and st.get("version") == "9.9.9-dev.1"
              and st.get("python") == str(pkg / "python/bin/python3") and st.get("missing") is False, out)

        suite.ROOT = pkg / "app"
        rc, out = call(cli.main, "doctor", "--json")
        check("forward: the package's `hibiki doctor` execs the checkout's cli.py with the recorded python",
              rc == "exec" and execs == [(str(pkg / "python/bin/python3"), [str(pkg / "python/bin/python3"), "-s", "-E",
                                         str(co.resolve() / "reaper_mcp/cli.py"), "doctor", "--json"], "1")], str(execs))
        os.environ.pop("HIBIKI_FORWARDED", None)
        execs.clear()
        rc, out = call(cli.main, "use", "--json")
        check("forward: `use` always runs where it was called", rc == 0 and not execs and '"mode": "dev"' in out, out)
        os.environ["HIBIKI_FORWARDED"] = "1"
        check("forward: not again once forwarded", suite.forward(["doctor"]) is None and not execs)
        os.environ.pop("HIBIKI_FORWARDED")
        suite.ROOT = co.resolve()
        check("forward: not when already running from the checkout", suite.forward(["doctor"]) is None and not execs)
        suite.ROOT = pkg / "app"

        m["path"] = str(home / "gone")
        mode.write_text(json.dumps(m))
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            r = suite.forward(["recover"])
        check("forward: a vanished checkout warns and falls back to the installed release",
              r is None and not execs and "gone" in err.getvalue() and "use release" in err.getvalue(), err.getvalue())

        os.environ["HIBIKI_USE_RELEASE"] = "1"
        with contextlib.redirect_stderr(io.StringIO()):
            r = suite.forward(["setup"])
        check("HIBIKI_USE_RELEASE (fresh install): dev mode cleared, setup runs from the package",
              r is None and not mode.exists() and not execs)
        os.environ.pop("HIBIKI_USE_RELEASE")

        mode.write_text(json.dumps(dict(m, path=str(co.resolve()))))
        rc, out = call(suite.main, "update", "--install", "--json")
        j = json.loads(out) if out.startswith("{") else {}
        check("update --install in dev mode: refused, points at `use release`",
              rc == 1 and "dev mode" in j.get("error", "") and "hibiki use release" in j.get("error", ""), out)

        calls.clear()
        shim_.write_text('#!/bin/sh\nexec /usr/bin/python3 -s -E /x/reaper_mcp/cli.py "$@"\n')
        rc, out = call(suite.main, "use", "release")
        setup = [c for c in calls if c[0][0] != "git"]
        check("use release: mode.json gone, the package's setup runs (forwarded flag set), shim removed",
              rc == 0 and not mode.exists() and len(setup) == 1
              and setup[0][0] == [str(pkg / "python/bin/python3"), "-s", "-E", str(pkg / "app/reaper_mcp/cli.py"), "setup"]
              and setup[0][1]["env"].get("HIBIKI_FORWARDED") == "1" and "HIBIKI_NO_SHIM" not in setup[0][1]["env"]
              and not shim_.exists() and "release: 0.5.0" in out, out + str(setup))
        rc, out = call(suite.main, "use")
        check("use (status): release with the package version", rc == 0 and "mode:    release" in out and "0.5.0" in out, out)

        suite.PKG_ROOT = home / "no-pkg"
        calls.clear()
        rc, out = call(suite.main, "use", "release")
        check("use release without a package: error, nothing run",
              rc == 1 and "no installed package; install Hibiki first" in out and not calls, out)
    finally:
        for k, v in saved.items():
            setattr(suite, k, v)
        suite.subprocess.run, os.execv = saved_run, saved_execv
        for k, v in env_saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    dev_home = Path(tempfile.mkdtemp(prefix="hb_usedoc_"))
    (dev_home / ".config/reaper-mcp").mkdir(parents=True)
    rc, out = run(dev_home, "doctor", "--json")
    rows = json.loads(out[out.index("["):]) if "[" in out else []
    check("doctor: first row is the mode (release)", rows and rows[0]["check"] == "mode"
          and rows[0]["detail"].startswith("release"), out)
    (dev_home / ".config/reaper-mcp/mode.json").write_text(json.dumps(
        {"mode": "dev", "path": str(ROOT), "python": sys.executable}))
    rc, out = run(dev_home, "doctor", "--json")
    rows = json.loads(out[out.index("["):]) if "[" in out else []
    check("doctor: first row is the mode (dev <checkout> @ <commit>)", rows and rows[0]["check"] == "mode"
          and rows[0]["detail"].startswith("dev %s @ " % ROOT), out)
    (dev_home / "Applications/REAPER.app").mkdir(parents=True)
    rc, out = run(dev_home, "setup", "--no-connect", "--no-reaimgui")
    check("setup in dev mode writes no ~/.local/bin/hibiki shim", not (dev_home / ".local/bin/hibiki").exists(), out)


def main_windows():
    """The same flow on Windows paths: %APPDATA%\\REAPER, REAPER under Program Files, no LaunchAgents."""
    failures = []

    def check(label, cond, detail=""):
        print(("  PASS " if cond else "  FAIL ") + label + ("" if cond else "  " + detail[-800:]))
        if not cond:
            failures.append(label)

    httpd = ThreadingHTTPServer(("127.0.0.1", 0), FakeGamut)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    gamut = "http://127.0.0.1:%d" % httpd.server_address[1]

    bare = Path(tempfile.mkdtemp(prefix="hb_noreaper_"))
    rc, out = run(bare, "setup", "--no-connect")
    check("win: no REAPER -> setup refuses with the download link", rc != 0 and "reaper.fm" in out, out)

    home = Path(tempfile.mkdtemp(prefix="hb_win_"))
    res = home / "AppData/Roaming/REAPER"
    scripts = res / "Scripts"
    (home / "no-system-apps/REAPER (x64)").mkdir(parents=True)
    (home / "no-system-apps/REAPER (x64)/reaper.exe").write_bytes(b"MZ")
    (res / "UserPlugins").mkdir(parents=True)
    (res / "UserPlugins/reaper_imgui-x64.dll").write_bytes(b"MZ")
    shim(res)
    (home / "AppData/Roaming/Claude").mkdir(parents=True)
    (home / ".cursor").mkdir()
    FakeGamut.servers = []
    rc, out = run(home, "setup", gamut=gamut)
    check("win: setup exits 0", rc == 0, out)
    check("win: bridge in %APPDATA%\\REAPER\\Scripts", (scripts / "reaper_mcp_bridge.lua").read_text()
          == (ROOT / "reaper_mcp/bridge.lua").read_text())
    check("win: panel installed", (scripts / "Hibiki/Hibiki.lua").exists())
    check("win: ReaImGui present, nothing downloaded", "already installed" in out and "shim: installed" not in out, out)
    hook = (scripts / "__startup.lua").read_text()
    check("win: startup hook written", "-- >>> hibiki" in hook and "Hibiki.lua" in hook, hook)
    check("win: token written", (home / ".config/reaper-mcp/token").read_text().strip() != "")
    gw = json.loads((home / ".config/agent-gateway/config.json").read_text())
    check("win: gateway config points at this server.py", gw["mcpServers"][0]["args"] == [str(ROOT / "reaper_mcp/server.py")])
    check("win: Gamut registration added", len(FakeGamut.servers) == 1 and FakeGamut.servers[0]["url"].endswith("/mcp"))
    cd = json.loads((home / "AppData/Roaming/Claude/claude_desktop_config.json").read_text())
    check("win: Claude Desktop registered under %APPDATA%\\Claude", "reaper" in cd["mcpServers"])
    check("win: no LaunchAgents", not (home / "Library").exists())
    rc, out2 = run(home, "setup", gamut=gamut)
    check("win: second setup idempotent", rc == 0 and "bridge: up to date" in out2 and len(FakeGamut.servers) == 1, out2)
    rc, out = run(home, "doctor", "--json", gamut=gamut)
    rows = {r["check"]: r for r in json.loads(out[out.index("["):])} if "[" in out else {}
    check("win: doctor finds REAPER, bridge, panel, ReaImGui", all(rows.get(k, {}).get("level") == "ok"
          for k in ("REAPER", "bridge script", "chat panel", "ReaImGui", "startup hook", "token")), out)
    rc, out = run(home, "uninstall", gamut=gamut)
    check("win: uninstall removes bridge, panel, hook block, registrations",
          rc == 0 and not (scripts / "reaper_mcp_bridge.lua").exists() and not (scripts / "Hibiki").exists()
          and FakeGamut.servers == [], out)

    httpd.shutdown()
    if failures:
        print("FAILED", failures)
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main_windows() if os.name == "nt" else main()
