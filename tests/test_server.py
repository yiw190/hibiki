#!/usr/bin/env python3
"""Offline MCP + fake-bridge tests. No REAPER required."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SERVER = os.path.join(ROOT, "reaper_mcp", "server.py")
BRIDGE = os.path.join(ROOT, "reaper_mcp", "bridge.lua")

sys.path.insert(0, ROOT)


def check_invalid_utf8_response():
    """A mailbox reply with illegal UTF-8 must not look like a dead bridge."""
    from reaper_mcp import server

    bridge_dir = tempfile.mkdtemp(prefix="reaper_utf8_")
    prev = os.environ.get("REAPER_MCP_IPC_DIR")
    os.environ["REAPER_MCP_IPC_DIR"] = bridge_dir
    try:
        b = server.Bridge()
        with open(b.heart, "w", encoding="utf-8") as f:
            f.write("1")

        def writer():
            deadline = time.time() + 3
            while time.time() < deadline:
                if os.path.exists(b.req):
                    with open(b.req, encoding="utf-8") as f:
                        payload = json.load(f)
                    try:
                        os.remove(b.req)
                    except OSError:
                        pass
                    rid = payload.get("id", "")
                    raw = (
                        '{"id":"%s","ok":true,"ret":{"project":"波","tracks":[{"name":"Qq'
                        % rid
                    ).encode("utf-8") + bytes([0xD4]) + b'z"}]}}'
                    with open(b.resp, "wb") as f:
                        f.write(raw)
                    return
                time.sleep(0.01)

        t = threading.Thread(target=writer, daemon=True)
        t.start()
        ret = b.call("get_project_summary", timeout=3)
        t.join(timeout=1)
        assert ret["project"] == "波", ret
        assert ret["tracks"][0]["name"].startswith("Qq"), ret
        return True
    finally:
        if prev is None:
            os.environ.pop("REAPER_MCP_IPC_DIR", None)
        else:
            os.environ["REAPER_MCP_IPC_DIR"] = prev


def check_batch_timeout():
    """A batch containing a render must inherit the render budget."""
    from reaper_mcp import server

    calls, timeout = server._normalize_batch([
        {"func": "track", "action": "add", "name": "Pad"},
    ])
    assert calls == [{"func": "add_track", "args": ["Pad", None]}], calls
    assert timeout is None, timeout

    calls, timeout = server._normalize_batch([
        {"func": "track", "action": "add", "name": "Pad"},
        {"func": "render", "arguments": {"path": "/tmp/x.wav"}},
    ])
    assert timeout == server.RENDER_TIMEOUT, timeout

    calls, timeout = server._normalize_batch([{"func": "render_project", "args": ["/tmp/x.wav"]}])
    assert timeout == server.RENDER_TIMEOUT, timeout

    calls, timeout = server._normalize_batch([
        {"func": "midi", "action": "cc", "track_index": 0, "item_index": 0,
         "ccs": [{"start_beats": 0, "program": 0}]},
        {"func": "item", "action": "import", "path": "/tmp/a.mid", "track_index": 0},
        {"func": "project", "action": "save", "path": "/tmp/song.RPP"},
    ])
    assert calls[0]["func"] == "add_midi_cc", calls[0]
    assert calls[1]["func"] == "import_media", calls[1]
    assert calls[1]["args"][0] == "/tmp/a.mid", calls[1]
    assert calls[1]["args"][1]["as_new_track"] is False, calls[1]
    assert calls[2] == {"func": "save_project", "args": ["/tmp/song.RPP"]}, calls[2]
    return True


class _Recorder:
    """Stands in for Bridge: records what a tool builder would send to the bridge."""

    def __init__(self):
        self.sent = []

    def call(self, func, args=None, code=None, timeout=None, lua_timeout=None):
        self.sent.append({"func": func, "args": args, "code": code, "timeout": timeout, "lua_timeout": lua_timeout})
        return None


def _build(name, arguments):
    from reaper_mcp import server
    rec = _Recorder()
    server.TOOL_INDEX[name]["_builder"](rec, arguments)
    return rec.sent[-1]


def check_tool_params():
    """Optional params added from the 2026-10-22 tool-call audit reach the bridge; old calls are unchanged."""
    from reaper_mcp import server
    names = {t["name"] for t in server.TOOLS}
    assert names == {"status", "transport", "track", "midi", "fx", "send", "item", "envelope", "project",
                     "render", "action", "reaper_call", "run_lua", "batch"}, names  # frozen set
    c = _build("fx", {"action": "set", "track_index": 0, "fx_index": 1, "param": "Ratio", "formatted": "4"})
    assert c["func"] == "set_fx_param" and c["args"] == [0, 1, "Ratio", None, "4"], c
    c = _build("fx", {"action": "set", "track_index": 0, "fx_index": 1, "param": 2, "value": 0.5})
    assert c["args"] == [0, 1, 2, 0.5, None], c
    c = _build("send", {"action": "add", "track_index": 3, "dest_index": 5, "dst_channel": 2, "mode": "pre_fader"})
    assert c["args"] == [3, 5, {"dst_channel": 2, "mode": "pre_fader"}], c
    c = _build("send", {"action": "add", "track_index": 3, "dest_index": 5})
    assert c["args"] == [3, 5, None], c
    c = _build("send", {"action": "update", "track_index": 3, "send_index": 0, "src_channel": 0, "volume_db": -3})
    assert c["args"] == [3, 0, {"volume_db": -3, "src_channel": 0}], c
    c = _build("envelope", {"action": "set", "track_index": 1, "name": "Trim Volume",
                            "points": [{"beats": 0, "value": -3}], "unit": "db"})
    assert c["args"] == [1, "Trim Volume", [{"beats": 0, "value": -3}], "db", None], c
    c = _build("envelope", {"action": "get", "track_index": 1, "name": "Volume"})
    assert c["args"] == [1, "Volume", None, None], c
    c = _build("envelope", {"action": "set", "track_index": 1, "name": "Volume", "start_beats": 8, "end_beats": 16,
                            "points": [{"beats": 8, "value": 1}]})
    assert c["args"][4] == {"start_beats": 8, "end_beats": 16}, c
    c = _build("render", {"path": "/tmp/r", "pattern": "a", "solo_indices": [2], "mute_indices": [4],
                          "allow_solo": True, "media_online": False, "measure": False})
    opts = c["args"][1]
    assert opts["solo_indices"] == [2] and opts["mute_indices"] == [4] and opts["allow_solo"] is True
    assert opts["media_online"] is False and opts["measure"] is False and c["timeout"] == server.RENDER_TIMEOUT, c
    c = _build("run_lua", {"code": "return 1"})
    assert c["code"] == "return 1" and c["lua_timeout"] == 10 and c["timeout"] == 10 + server.RUN_LUA_GRACE, c
    c = _build("run_lua", {"code": "return 1", "timeout": 120})
    assert c["lua_timeout"] == 120.0 and c["timeout"] == 120 + server.RUN_LUA_GRACE, c
    c = _build("run_lua", {"code": "return 1", "timeout": 99999})
    assert c["lua_timeout"] == server.RUN_LUA_MAX_TIMEOUT, c
    # 2026-10-24 review: arrange verbs, ranges, selection, formats
    c = _build("item", {"action": "update", "track_index": 0, "item_index": 1, "fade_in_sec": 0.1,
                        "fade_out_shape": "s_curve", "left_edge_beats": 4, "dest_track_index": 2, "active_take": 1})
    assert c["func"] == "update_item" and c["args"][2] == {"fade_in_sec": 0.1, "fade_out_shape": "s_curve",
                                                           "left_edge_beats": 4, "dest_track_index": 2,
                                                           "active_take": 1}, c
    c = _build("item", {"action": "split", "track_index": 0, "item_index": 1, "at_beats": [8, 4]})
    assert c["func"] == "split_item" and c["args"] == [0, 1, [8, 4]], c
    c = _build("item", {"action": "delete", "track_index": 0, "item_index": 3})
    assert c["func"] == "delete_items" and c["args"] == [0, [3]], c
    c = _build("item", {"action": "duplicate", "track_index": 0, "item_index": 3, "position_beats": 32})
    assert c["func"] == "duplicate_item" and c["args"] == [0, 3, {"position_beats": 32}], c
    c = _build("transport", {"action": "goto", "marker": "Chorus"})
    assert c["args"] == ["goto", {"marker": "Chorus"}], c
    c = _build("transport", {"action": "play"})
    assert c["args"] == ["play", None], c
    c = _build("midi", {"action": "get_cc", "track_index": 0, "item_index": 0})
    assert c["func"] == "get_midi_cc", c
    c = _build("fx", {"action": "params", "track_index": 0, "fx_index": 0, "filter": "attack"})
    assert c["args"] == [0, 0, "attack"], c
    c = _build("render", {"format": "wav", "bit_depth": 16})
    assert c["args"][1]["format"] == "wav" and c["args"][1]["bit_depth"] == 16, c
    c = _build("batch", {"calls": [{"func": "run_lua", "code": "return 1", "timeout": 30}], "stop_on_error": True})
    assert c["args"][1] == {"stop_on_error": True} and c["args"][0][0]["timeout"] == 30, c
    assert c["timeout"] == 30 + server.RUN_LUA_GRACE, c
    schema = server.TOOL_INDEX["run_lua"]["inputSchema"]
    assert schema["properties"]["timeout"]["maximum"] == server.RUN_LUA_MAX_TIMEOUT
    return True


def check_timeout_hints():
    """A request REAPER is still running says 'do not resend' instead of inviting a duplicate."""
    from reaper_mcp import server
    d = tempfile.mkdtemp(prefix="reaper_ipc_busy_")
    prev = os.environ.get("REAPER_MCP_IPC_DIR")
    os.environ["REAPER_MCP_IPC_DIR"] = d
    try:
        b = server.Bridge()
        open(b.heart, "w").close()
        open(b.busy, "w").close()
        try:
            b.call("ping", timeout=0.2)
        except server.BridgeError as e:
            msg = str(e)
        else:
            return False
        return "Do not resend" in msg and "status" in msg
    finally:
        if prev is None:
            os.environ.pop("REAPER_MCP_IPC_DIR", None)
        else:
            os.environ["REAPER_MCP_IPC_DIR"] = prev

FAKE_CHILD = r"""
import json, sys, time
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get("method") == "hang":
        time.sleep(60)
    if msg.get("id") is None:
        continue
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": "stray", "result": {}}) + "\n")
    sys.stdout.write("not json\n")
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"echo": msg.get("method")}}) + "\n")
    sys.stdout.flush()
"""


def check_http_front(env):
    """The HTTP front's stdio client: matches replies by id, times out and restarts, answers tools/list unlocked."""
    from reaper_mcp import http_server

    results = {}
    fake = http_server.StdioClient([sys.executable, "-c", FAKE_CHILD])
    r = fake.rpc({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "status"}})
    results["stray lines dropped, reply matched by id"] = r == {"jsonrpc": "2.0", "id": 7, "result": {"echo": "tools/call"}}
    first = fake.proc
    t0 = time.monotonic()
    try:
        fake.rpc({"jsonrpc": "2.0", "id": 8, "method": "hang"}, timeout=1.0)
        results["hung child times out"] = False
    except TimeoutError:
        results["hung child times out"] = time.monotonic() - t0 < 5
    results["hung child killed"] = first.poll() is not None
    r = fake.rpc({"jsonrpc": "2.0", "id": 9, "method": "x"})
    results["next call restarts the child"] = r["id"] == 9 and fake.proc is not first

    def hang():
        try:
            fake.rpc({"jsonrpc": "2.0", "id": 10, "method": "hang"}, timeout=3.0)
        except TimeoutError:
            pass
    hold = threading.Thread(target=hang, daemon=True)
    hold.start()
    time.sleep(0.3)
    t0 = time.monotonic()
    tl = fake.rpc({"jsonrpc": "2.0", "id": 11, "method": "tools/list"})
    init = fake.rpc({"jsonrpc": "2.0", "id": 12, "method": "initialize", "params": {}})
    results["tools/list + initialize answered while a call holds the lock"] = (
        time.monotonic() - t0 < 1 and len(tl["result"]["tools"]) >= 8 and tl["id"] == 11
        and init["result"]["serverInfo"]["name"] == "reaper-mcp")
    results["notifications answered locally"] = fake.rpc({"jsonrpc": "2.0", "method": "notifications/initialized"}) is None
    hold.join()
    fake._kill()

    old_env = dict(os.environ)
    os.environ.update(env)
    try:
        real = http_server.StdioClient()
        real.rpc({"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "status", "arguments": {}}})
        real.rpc({"jsonrpc": "2.0", "method": "ping"})
        r = real.rpc({"jsonrpc": "2.0", "id": "a1", "method": "tools/call", "params": {"name": "status", "arguments": {}}})
        results["id-less calls then an id'd call: the right reply"] = r.get("id") == "a1" and "Drums" in r["result"]["content"][0]["text"]
        r = real.rpc({"jsonrpc": "2.0", "id": "n1", "method": "notifications/cancelled"}, timeout=5)
        results["notification carrying an id is answered, not hung"] = r == {"jsonrpc": "2.0", "id": "n1", "result": {}}
        real._kill()
    finally:
        os.environ.clear()
        os.environ.update(old_env)

    import subprocess as sp
    short = sp.run([sys.executable, os.path.join(ROOT, "reaper_mcp", "http_server.py")], capture_output=True, text=True,
                   env=dict(os.environ, REAPER_MCP_BEARER="short", REAPER_MCP_PORT="0"), timeout=30)
    results["short bearer refused at startup"] = short.returncode != 0 and "at least 32" in short.stderr
    return results


def fake_bridge(bridge_dir, stop):
    req = os.path.join(bridge_dir, "request.json")
    resp = os.path.join(bridge_dir, "response.json")
    heart = os.path.join(bridge_dir, "heartbeat")
    busy = os.path.join(bridge_dir, "busy")
    while not stop.is_set():
        with open(heart, "w", encoding="utf-8") as f:
            f.write(str(time.time()))
        if os.path.exists(req):
            try:
                with open(req, encoding="utf-8") as f:
                    payload = json.load(f)
                os.remove(req)
            except (OSError, ValueError):
                time.sleep(0.005)
                continue
            func = payload.get("func")
            if func == "run_lua" and (payload.get("code") or "") == "slow":
                with open(busy, "w", encoding="utf-8") as f:
                    f.write("1")
                time.sleep(0.6)
                try:
                    os.remove(busy)
                except OSError:
                    pass
            if func == "get_project_summary":
                detail = bool((payload.get("args") or [False])[0])
                ret = {"project": "(unsaved)", "tempo_bpm": 120.0,
                       "track_count": 1,
                       "tracks": [{"index": 0, "name": "Drums"}]}
                if detail:
                    ret["time_sig"] = {"numerator": 4, "denominator": 4}
                    ret["length_beats"] = 32.0
                    ret["cursor_beats"] = 0.0
                    ret["markers"] = []
                    ret["tracks"][0]["has_midi"] = True
                    ret["tracks"][0]["has_audio"] = False
            elif func == "add_track":
                ret = {"index": payload["args"][1] or 0,
                       "name": payload["args"][0] or ""}
            elif func == "run_lua":
                ret = 1
            elif func == "batch":
                calls = payload["args"][0]
                ret = [{"echo": c.get("func"), "args": c.get("args")}
                       for c in calls]
            elif func == "CountTracks":
                ret = 3
            else:
                ret = {"echo": func, "args": payload.get("args")}
            out = {"id": payload.get("id"), "ok": True, "ret": ret}
            tmp = resp + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(out, f)
            os.replace(tmp, resp)
        time.sleep(0.005)


def check_brain():
    """The rules composer: defaults parse, off, override, missing files, the cap; the server's fallback."""
    from reaper_mcp import brain, server
    ok = {}
    d = tempfile.mkdtemp(prefix="hibiki_brain_")
    dfile = os.path.join(d, "defaults.md")
    with open(dfile, "w", encoding="utf-8") as f:
        f.write("# Title\n<!-- - [hidden] not a rule -->\n- [alpha] First rule\n  continues here.\n"
                "- [beta] Second rule.\n\nfree text\n  not a continuation\n- [gamma] Third.\n")
    ok["defaults parse"] = brain.defaults(path=dfile) == [("alpha", "First rule continues here."),
                                                     ("beta", "Second rule."), ("gamma", "Third.")]
    shipped = brain.ids(path=brain.package_defaults_path())
    ok["shipped defaults have ids"] = len(shipped) >= 8 and {"single-dls", "rack-audible", "render-new-name"} <= set(shipped)
    ok["shipped defaults stay short"] = len(open(brain.package_defaults_path(), encoding="utf-8").read().splitlines()) <= 60
    udir = os.path.join(d, "user")
    ok["no rules.md: defaults only"] = brain.compose(udir, dfile) == (
        "## Hibiki conventions\n- [alpha] First rule continues here.\n- [beta] Second rule.\n- [gamma] Third.")
    ok["no files at all: empty"] = brain.compose(udir, os.path.join(d, "missing.md")) == ""
    brain.ensure(udir)
    ok["template alone adds no rules"] = "Your rules" not in brain.compose(udir, dfile)
    with open(brain.rules_path(udir), "a", encoding="utf-8") as f:
        f.write("- off: beta\noff: nope\n- [gamma] My own third.\n- [delta] not a default, kept\n- Example rule.\n")
    text = brain.compose(udir, dfile)
    e = brain.effective(udir, dfile)
    ok["off drops a default"] = "Second rule" not in text and e["off"] == ["beta"]
    ok["[id] overrides a default in place"] = "- [gamma] My own third." in text and "Third." not in text \
        and text.index("[alpha]") < text.index("[gamma]") < text.index("## Your rules")
    ok["your rules without off/override lines"] = text.endswith(
        "## Your rules\n- [delta] not a default, kept\n- Example rule.") and e["count"] == 2 and e["unknown"] == ["nope"]
    ok["header comment not sent"] = "off: <id>" not in text and "Rules for agents" not in text
    with open(brain.rules_path(udir), "a", encoding="utf-8") as f:
        f.write("".join("- Example rule number %d with some padding text.\n" % i for i in range(400)))
    capped = brain.compose(udir, dfile, limit=1000)
    ok["cap"] = len(capped) <= 1000 and capped.endswith("characters)") and "[alpha]" in capped
    ok["default cap"] = len(brain.compose(udir, dfile)) <= brain.BRAIN_MAX
    try:
        brain.add("off: nope", udir, dfile)
        ok["off: unknown id refused"] = False
    except ValueError:
        ok["off: unknown id refused"] = True
    ok["set_off on/off"] = brain.set_off("alpha", True, udir, dfile) and brain.set_off("alpha", True, udir, dfile) is False \
        and brain.effective(udir, dfile)["off"] == ["alpha", "beta"] and brain.set_off("alpha", False, udir, dfile) \
        and brain.effective(udir, dfile)["off"] == ["beta"]
    ok.update(check_brain_seed_upgrade(brain, d))
    real = brain.compose
    brain.compose = lambda *a, **k: 1 / 0
    try:
        ok["server falls back to the base text"] = server.instructions() == server.INSTRUCTIONS
    finally:
        brain.compose = real
    return ok


def check_brain_seed_upgrade(brain, tmp):
    """The user's copy of defaults.md: seeded, read by compose, merged per id on upgrade, reset."""
    ok = {}
    pkg = os.path.join(tmp, "pkg.md")

    def ship(text):
        with open(pkg, "w", encoding="utf-8") as f:
            f.write(text)

    u = os.path.join(tmp, "seeded")
    ship("# Shipped\n- [one] One v1.\n- [two] Two v1\n  wrapped.\n- [three] Three v1.\n")
    r = brain.upgrade(u, pkg)
    copy = brain.defaults_file(u)
    ok["seed on first setup"] = r["seeded"] and open(copy, encoding="utf-8").read() == open(pkg, encoding="utf-8").read() \
        and os.path.exists(brain.state_path(u))
    with open(copy, "w", encoding="utf-8") as f:  # the user edits: one untouched, two reworded, three deleted, own line
        f.write("# Shipped\n- [one] One v1.\n- [two] My wording of two.\nmy own note line\n")
    ok["compose reads the user copy"] = brain.compose(u).startswith(
        "## Hibiki conventions\n- [one] One v1.\n- [two] My wording of two.") and "Three" not in brain.compose(u)
    ship("# Shipped v2\n- [one] One v2\n  wrapped.\n- [two] Two v2.\n- [three] Three v2.\n- [four] Four v2.\n")
    r = brain.upgrade(u, pkg)
    text = open(copy, encoding="utf-8").read()
    ok["upgrade: unmodified default gets the new text"] = r["updated"] == ["one"] and "- [one] One v2\n  wrapped.\n" in text
    ok["upgrade: modified default kept"] = r["kept"] == ["two"] and "My wording of two." in text and "Two v2" not in text
    ok["upgrade: deleted default not re-added"] = "three" not in text
    ok["upgrade: new id appended, own lines untouched"] = r["added"] == ["four"] and text == (
        "# Shipped\n- [one] One v2\n  wrapped.\n- [two] My wording of two.\nmy own note line\n- [four] Four v2.\n")
    r = brain.upgrade(u, pkg)
    ok["upgrade twice: nothing changes"] = r["updated"] == r["added"] == [] and open(copy, encoding="utf-8").read() == text
    brain.reset(["two"], u, pkg)
    text = open(copy, encoding="utf-8").read()
    ok["reset <id>: shipped text back in place"] = "- [two] Two v2.\nmy own note line" in text
    try:
        brain.reset(["nope"], u, pkg)
        ok["reset: unknown id refused"] = False
    except ValueError:
        ok["reset: unknown id refused"] = True
    brain.reset(None, u, pkg)
    ok["reset --all: deleted ids back too"] = [i for i, _ in brain.defaults(u)] == ["one", "two", "four", "three"] \
        and "my own note line" in open(copy, encoding="utf-8").read()
    os.remove(copy)
    ok["missing user copy is seeded again"] = brain.ids(u) == brain.ids(path=brain.package_defaults_path()) \
        and os.path.exists(copy)
    return ok


def rpc(proc, msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    if msg.get("id") is None:
        return None
    return json.loads(proc.stdout.readline())


def main():
    bridge_dir = tempfile.mkdtemp(prefix="reaper_ipc_")
    stop = threading.Event()
    threading.Thread(target=fake_bridge, args=(bridge_dir, stop), daemon=True).start()

    brain_dir = tempfile.mkdtemp(prefix="hibiki_brain_")
    os.environ["HIBIKI_BRAIN"] = brain_dir  # in-process calls (the HTTP front answers initialize itself) stay out of ~
    env = dict(
        os.environ,
        HIBIKI_BRAIN=brain_dir,
        REAPER_MCP_IPC_DIR=bridge_dir,
        REAPER_MCP_TIMEOUT="5",
        REAPER_MCP_HEARTBEAT_STALE="0.2",
    )
    proc = subprocess.Popen(
        [sys.executable, SERVER],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr,
        text=True, env=env, encoding="utf-8",
    )
    failures = []

    def check(label, cond):
        print(("  PASS" if cond else "  FAIL"), label)
        if not cond:
            failures.append(label)

    try:
        src = open(BRIDGE, encoding="utf-8").read()
        check("beats are project QN",
              "TimeMap2_QNToTime(0, b" in src
              and "TimeMap2_beatsToTime(0, b, 0)" not in src)
        check("heartbeat file", "heartbeat" in src)
        check("busy file while dispatch blocked", "busy" in src)
        check("MIDI undo uses OnStateChange_Item",
              "Undo_OnStateChange_Item" in src)
        check("APPDATA mailbox", "reaper-mcp" in src and "APPDATA" in src)
        from reaper_mcp import __version__
        check("bridge VERSION matches the package", 'local VERSION = "%s"' % __version__ in src)
        pyproject = open(os.path.join(ROOT, "pyproject.toml"), encoding="utf-8").read()
        check("pyproject version matches the package", 'version = "%s"' % __version__ in pyproject)
        check("batch inherits the render timeout", check_batch_timeout())
        check("audit params reach the bridge; tool set stays frozen", check_tool_params())
        check("busy timeout says do not resend", check_timeout_hints())
        check("lua json encoder handles mixed utf-8",
              "utf8_len" in src and "is_cont" in src)
        check("python reads mailbox as utf-8 replace", check_invalid_utf8_response())

        r = rpc(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})
        check("initialize", r["result"]["serverInfo"]["name"] == "reaper-mcp")
        check("instructions present", "beats" in r["result"].get("instructions", ""))
        check("instructions ask for detail on new projects",
              "detail=true" in r["result"].get("instructions", ""))
        text = r["result"].get("instructions", "")
        check("instructions carry the shipped conventions", "## Hibiki conventions" in text and "[single-dls]" in text
              and "## Your rules" not in text)
        with open(os.path.join(brain_dir, "rules.md"), "w", encoding="utf-8") as f:
            f.write("- Example rule for the test.\n- off: rack-audible\n")
        text = rpc(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}})["result"]["instructions"]
        check("an edited rules.md reaches the next initialize, no restart",
              "## Your rules\n- Example rule for the test." in text and "[rack-audible]" not in text and "beats" in text)
        rpc(proc, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        for label, ok in check_brain().items():
            check("brain: " + label, ok)

        r = rpc(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
        names = {t["name"] for t in r["result"]["tools"]}
        check("small tool surface", 8 <= len(names) <= 16)
        check("core tools", {"status", "track", "midi", "fx", "batch", "run_lua",
                             "reaper_call"} <= names)
        check("mix primitives", {"send", "item", "envelope"} <= names)
        check("no 100-tool dump", "setup_sidechain_compression" not in names)
        print("       tools:", sorted(names), "count=", len(names))

        status_schema = next(t["inputSchema"] for t in r["result"]["tools"]
                             if t["name"] == "status")
        check("status schema has detail",
              "detail" in status_schema.get("properties", {}))

        r = rpc(proc, {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                       "params": {"name": "status", "arguments": {}}})
        body = json.loads(r["result"]["content"][0]["text"])
        check("status via fake bridge", body["tracks"][0]["name"] == "Drums")
        check("light status has no time_sig", "time_sig" not in body)

        r = rpc(proc, {"jsonrpc": "2.0", "id": 31, "method": "tools/call",
                       "params": {"name": "status", "arguments": {"detail": True}}})
        body = json.loads(r["result"]["content"][0]["text"])
        check("detailed status has time_sig",
              body.get("time_sig") == {"numerator": 4, "denominator": 4})
        check("detailed status has markers", "markers" in body)
        check("detailed status does not guess chords", "chords" not in body
              and "chord" not in body)

        r = rpc(proc, {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                       "params": {"name": "track",
                                  "arguments": {"action": "add", "name": "Bass"}}})
        body = json.loads(r["result"]["content"][0]["text"])
        check("grouped track add", body["name"] == "Bass")

        r = rpc(proc, {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
                       "params": {"name": "reaper_call",
                                  "arguments": {"func": "CountTracks", "args": [0]}}})
        check("reaper_call", json.loads(r["result"]["content"][0]["text"]) == 3)

        r = rpc(proc, {"jsonrpc": "2.0", "id": 6, "method": "tools/call",
                       "params": {"name": "batch", "arguments": {
                           "calls": [
                               {"func": "track", "action": "add", "name": "Pad"},
                               {"func": "run_lua", "code": "return 1"},
                           ]}}})
        body = json.loads(r["result"]["content"][0]["text"])
        check("batch expands grouped tools",
              body[0]["echo"] == "add_track")
        check("batch keeps run_lua", body[1]["echo"] == "run_lua")

        r = rpc(proc, {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
                       "params": {"name": "run_lua", "arguments": {"code": "slow"}}})
        check("busy bridge is not stale", not r["result"].get("isError"))

        r = rpc(proc, {"jsonrpc": "2.0", "id": 8, "method": "tools/call",
                       "params": {"name": "status", "arguments": {}}})
        check("status after slow request", "Drums" in r["result"]["content"][0]["text"])

        r = rpc(proc, {"jsonrpc": "2.0", "id": 9, "method": "tools/call",
                       "params": {"name": "nope", "arguments": {}}})
        check("unknown tool errors", "error" in r)

        r = rpc(proc, {"jsonrpc": "2.0", "id": 10, "method": "tools/call",
                       "params": {"name": "track", "arguments": {"action": "delete"}}})
        check("missing argument is named", r["result"].get("isError")
              and r["result"]["content"][0]["text"] == "missing argument: index")

        r = rpc(proc, {"jsonrpc": "2.0", "id": 11, "method": "tools/call",
                       "params": {"name": "batch", "arguments": {"calls": [
                           {"func": "track", "arguments": {"action": "delete"}},
                           {"func": "run_lua", "code": "return 1"}]}}})
        body = json.loads(r["result"]["content"][0]["text"])  # the fake bridge echoes funcs, it doesn't run Lua
        check("batch: a bad slot doesn't abort the rest", not r["result"].get("isError")
              and len(body) == 2 and body[0]["echo"] == "run_lua")

        rpc(proc, {"jsonrpc": "2.0", "method": "ping"})
        rpc(proc, {"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "status", "arguments": {}}})
        r = rpc(proc, {"jsonrpc": "2.0", "id": 13, "method": "ping"})
        check("stdio: id-less messages get no reply line", r.get("id") == 13 and r.get("result") == {})
        for label, ok in check_http_front(env).items():
            check("http front: " + label, ok)

        proc.stdin.write("[1, 2]\n")
        proc.stdin.flush()
        bad = json.loads(proc.stdout.readline())
        r = rpc(proc, {"jsonrpc": "2.0", "id": 12, "method": "ping"})
        check("non-object input answered, server alive", bad["error"]["code"] == -32600 and r.get("result") == {})
    finally:
        stop.set()
        proc.kill()

    if failures:
        print("FAILED", failures)
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main()
