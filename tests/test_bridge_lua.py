#!/usr/bin/env python3
"""Headless tests for reaper_mcp/bridge.lua, driven through the real mailbox.

Loads the bridge into a Lua interpreter with a fake ReaScript API
(tests/fake_reaper.lua), then sends requests exactly like server.py does.

Needs lupa; skips cleanly when it is absent so a bare CI job still passes.

    uv run --with lupa python tests/test_bridge_lua.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "reaper_mcp" / "bridge.lua"
FAKE = Path(__file__).resolve().parent / "fake_reaper.lua"

PPQ = 960.0

# Shims for older Lua runtimes lupa may load; the bridge targets REAPER's Lua 5.4.
COMPAT = """
if not table.pack then
  table.pack = function(...) return {n = select('#', ...), ...} end
end
if not table.unpack then table.unpack = unpack end
local _load = load
load = function(chunk, name, mode, env)
  local f, err = _load(chunk, name)
  if not f then return f, err end
  if env and setfenv then setfenv(f, env) end
  return f
end
"""

REFERENCE_ESC = r"""
local esc = {['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
local function utf8_len(s, i)
  local b = s:byte(i)
  if not b then return nil end
  if b < 0x80 then return 1 end
  if b < 0xC2 then return nil end
  if b < 0xE0 then return 2 end
  if b < 0xF0 then return 3 end
  if b < 0xF5 then return 4 end
  return nil
end
local function is_cont(s, i) local b = s:byte(i) return b ~= nil and b >= 0x80 and b < 0xC0 end
return function(s)
  local parts = {'"'}
  local i, n = 1, #s
  while i <= n do
    local b = s:byte(i)
    if b < 32 or b == 34 or b == 92 then
      parts[#parts + 1] = esc[s:sub(i, i)] or string.format('\\u%04x', b)
      i = i + 1
    elseif b < 128 then
      parts[#parts + 1] = s:sub(i, i)
      i = i + 1
    else
      local len = utf8_len(s, i)
      local ok = len ~= nil and (i + len - 1) <= n
      if ok then for j = i + 1, i + len - 1 do if not is_cont(s, j) then ok = false break end end end
      if ok then parts[#parts + 1] = s:sub(i, i + len - 1); i = i + len
      else parts[#parts + 1] = string.format('\\u%04x', b); i = i + 1 end
    end
  end
  parts[#parts + 1] = '"'
  return table.concat(parts)
end
"""


def json_checks(lupa, check) -> None:
    """bridge.lua's JSON codec on its own: fast paths must not change what goes over the mailbox."""
    import random
    src = BRIDGE.read_text(encoding="utf-8")
    block = src[src.index("local json = {}"):src.index("-" * 70 + "\n-- files")]
    lua = lupa.LuaRuntime(encoding=None)
    lua.execute(COMPAT)
    js = lua.execute(block + "\nreturn json")
    ref = lua.execute(REFERENCE_ESC)
    enc = js.encode

    def dec(raw: bytes):
        return lua.eval("function(j, s) return j.decode(s) end")(js, raw)

    cases = {
        "ascii": b"Piano 1", "cjk": "鼓 钢琴 Lead".encode(), "emoji": "\U0001F3B5 Lead".encode(),
        "escapes": b'a"b\\c\n\t\r\x08\x0c/', "controls": b"\x00\x01\x1f\x7f",
        "invalid utf-8": b"ok\xff\xc3(\xe4\xb8", "lone continuation": b"\x80\xbfx", "overlong lead": b"\xc0\xaf",
        "empty": b"",
    }
    for name, raw in cases.items():
        out = enc(raw)
        check("json encode %s: same bytes as the reference encoder" % name, out == ref(raw), (raw, out, ref(raw)))
    check("json encode cjk passes through unescaped", enc("鼓".encode()) == '"鼓"'.encode())
    check("json encode invalid utf-8 -> \\u00XX per bad byte",
          enc(b"ok\xff\xc3(") == b'"ok\\u00ff\\u00c3("', enc(b"ok\xff\xc3("))
    check("json encode controls", enc(b"\x01\n\x1f") == b'"\\u0001\\n\\u001f"', enc(b"\x01\n\x1f"))
    rng = random.Random(7)
    alphabet = [bytes([b]) for b in range(256)] + ["é".encode(), "鼓".encode(), "\U0001F3B5".encode()] * 20
    mismatch = None
    for _ in range(3000):
        raw = b"".join(rng.choice(alphabet) for _ in range(rng.randint(0, 24)))
        if enc(raw) != ref(raw):
            mismatch = raw
            break
    check("json encode: 3000 random byte strings match the reference encoder", mismatch is None, repr(mismatch))

    for name, value in {"cjk": "鼓 钢琴", "escapes": 'q"b\\s\n\t\r\x08\x0c/', "controls": "\x01\x1f",
                        "emoji": "\U0001F3B5x", "bmp": "é€"}.items():
        for ascii_only in (True, False):
            wire = json.dumps(value, ensure_ascii=ascii_only).encode()
            got = dec(wire)
            check("json decode %s (ensure_ascii=%s)" % (name, ascii_only), got == value.encode(), (wire, got))
            check("json round trip %s (ensure_ascii=%s)" % (name, ascii_only), dec(enc(dec(wire))) == value.encode())
    doc = {"notes": [{"pitch": 60 + i, "start_beats": i * 0.5, "name": "鼓 %d \"x\"" % i, "muted": i % 2 == 0}
                     for i in range(50)], "track": "Piano", "empty": [], "nested": {"a": [1, -2.5, 3e2]}}
    wire = json.dumps(doc, ensure_ascii=False).encode()
    back = json.loads(enc(dec(wire)).decode())
    check("json round trip: notes document", back == dict(doc, nested={"a": [1, -2.5, 300]}), back)
    bad = lua.eval("function(j, s) return select(2, j.decode(s)) end")
    check("json decode: unterminated string is an error", bad(js, b'"abc') is not None
          and bad(js, b'"ab\\') is not None and bad(js, b'"\\u00e9') is not None)


def main() -> None:
    try:
        import lupa
    except ImportError:
        print("SKIP  install lupa: uv run --with lupa python tests/test_bridge_lua.py")
        return

    ipc_dir = tempfile.mkdtemp(prefix="reaper_lua_")
    os.environ["REAPER_MCP_IPC_DIR"] = ipc_dir
    req = os.path.join(ipc_dir, "request.json")
    resp = os.path.join(ipc_dir, "response.json")

    lua = lupa.LuaRuntime()
    lua.execute(COMPAT)
    lua.execute(FAKE.read_text(encoding="utf-8"))
    lua.execute(BRIDGE.read_text(encoding="utf-8"))

    g = lua.globals()
    failures = []

    def count(name) -> int:
        v = g.calls[name]
        return 0 if v is None else int(v)

    def clear():
        lua.execute("calls = {}")

    def rpc(func, args=None, code=None):
        payload = {"id": "t", "func": func}
        if code is not None:
            payload["code"] = code
        else:
            payload["args"] = args or []
        with open(req, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        g.pump(1)
        for _ in range(300):
            if os.path.exists(resp):
                break
            g.pump(1)
        with open(resp, encoding="utf-8") as f:
            return json.loads(f.read())

    def check(label, cond, extra=""):
        print(("  PASS" if cond else "  FAIL"), label, "" if cond else extra)
        if not cond:
            failures.append(label)

    def seeded_track(index=0):
        """A track with one MIDI item holding one muted note."""
        lua.execute(f"""
            if not tracks[{index + 1}] then
              tracks[{index + 1}] = new_track("T{index}")
            end
            tracks[{index + 1}].items[1] = new_item(0.0, 2.0)
            tracks[{index + 1}].items[1].notes = {{
              {{sel = false, muted = true, sppq = 0.0, eppq = {PPQ},
                chan = 0, pitch = 60, vel = 96}},
            }}
        """)
        return g.tracks

    # --- baseline ----------------------------------------------------
    check("bridge loaded", rpc("ping").get("ok") is True)
    r = rpc("add_track", ["Solo", 0])
    check("add_track", r.get("ok") and r["ret"]["index"] == 0, r)
    check("one refresh per single call",
          count("UpdateArrange") == 1 and count("TrackList_AdjustWindows") == 1,
          f"arrange={count('UpdateArrange')} tracks={count('TrackList_AdjustWindows')}")

    # --- batch coalesces refresh ------------------------------------
    clear()
    r = rpc("batch", [[
        {"func": "add_track", "args": ["A", 1]},
        {"func": "add_track", "args": ["B", 2]},
        {"func": "update_track", "args": [0, {"volume_db": -3}]},
        {"func": "update_track", "args": [1, {"mute": True}]},
    ]])
    check("batch ok", r.get("ok"), r)
    check("batch refreshes arrange once",
          count("UpdateArrange") == 1, f"arrange={count('UpdateArrange')}")
    check("batch refreshes track layout once",
          count("TrackList_AdjustWindows") == 1, f"tracks={count('TrackList_AdjustWindows')}")

    # --- refresh state is released after the batch -------------------
    clear()
    r = rpc("update_track", [0, {"volume_db": -1}])
    check("refresh works after a batch",
          r.get("ok") and count("UpdateArrange") == 1, f"arrange={count('UpdateArrange')}")

    # --- MIDI note update -------------------------------------------
    seeded_track(0)
    clear()
    r = rpc("update_midi_note", [0, 0, 0, {"pitch": 62}])
    check("update_midi_note ok", r.get("ok"), r)
    check("update_midi_note sorts once", count("MIDI_Sort") == 1, f"sort={count('MIDI_Sort')}")
    check("update_midi_note asks the API not to sort",
          count("MIDI_SetNote.noSort") == 1 and count("MIDI_SetNote.sorted") == 0,
          f"noSort={count('MIDI_SetNote.noSort')} sorted={count('MIDI_SetNote.sorted')}")

    # lupa's LuaTable shadows Lua fields named like dict methods (items, keys),
    # so index with [] rather than attribute access.
    def note0():
        return g.tracks[1]["items"][1]["notes"][1]

    r = rpc("update_midi_note", [0, 0, 0, {"muted": False}])
    n = note0()
    check("update_midi_note can unmute", r.get("ok") and n["muted"] is False, dict(n))

    r = rpc("update_midi_note", [0, 0, 0, {"start_beats": 2.0}])
    n = note0()
    moved = abs(float(n["sppq"]) - 2.0 * PPQ) < 1e-6
    kept = abs(float(n["eppq"]) - float(n["sppq"]) - PPQ) < 1e-6
    check("moved note keeps its length", r.get("ok") and moved and kept, dict(n))

    # --- item index without a scan -----------------------------------
    clear()
    before = count("GetTrackMediaItem")
    r = rpc("create_midi_item", [0, 0.0, 4.0])
    check("create_midi_item index correct",
          r["ret"]["item_index"] == len(g.tracks[1]["items"]) - 1, r)
    check("create_midi_item does not scan items",
          count("GetTrackMediaItem") - before <= 1,
          f"lookups={count('GetTrackMediaItem') - before}")

    # --- list_items property reads -----------------------------------
    clear()
    n_items = len(g.tracks[1]["items"])
    r = rpc("list_items", [0])
    reads = sum(count(f"item.{k}") for k in ("D_POSITION", "D_LENGTH", "D_VOL"))
    check("list_items reads 3 properties per item",
          r.get("ok") and reads == 3 * n_items, f"reads={reads} items={n_items}")

    # --- read-only ops leave no undo point --------------------------------
    clear()
    n_labels = len(list(g.undo_labels.values()))
    r = rpc("batch", [[
        {"func": "list_items", "args": [0]},
        {"func": "list_sends", "args": [0]},
        {"func": "list_envelopes", "args": [0]},
        {"func": "list_tracks", "args": []},
        {"func": "get_envelope", "args": [0, 0]},
    ]])
    check("read-only batch runs", r.get("ok"), r)
    check("read-only batch leaves no undo point", len(list(g.undo_labels.values())) == n_labels,
          list(g.undo_labels.values()))

    # --- mutating ops: one labelled undo point per request, and a receipt per turn ------------
    clear()
    g.ext_state["Hibiki/turn"] = "k1.3"
    rpc("update_track", [0, {"volume_db": -2}])
    labels = list(g.undo_labels.values())
    check("mutating op gets one undo block", count("Undo_BeginBlock2") == 1 and count("Undo_EndBlock2") == 1)
    check("undo point carries the turn id and what changed",
          labels and labels[-1].startswith("Hibiki k1.3: #1 ") and "volume -2.0 dB" in labels[-1], labels)
    rec = json.loads(g.ext_state["Hibiki/receipts"])
    check("receipt for the turn, with its project", rec[-1]["id"] == "k1.3" and rec[-1]["n"] == 1
          and "proj" in rec[-1]
          and "volume -2.0 dB" in rec[-1]["lines"][0], rec)
    r = rpc("batch", [[
        {"func": "update_track", "args": [0, {"mute": True}]},
        {"func": "list_tracks", "args": []},
        {"func": "add_track", "args": ["Pad", 1]},
    ]])
    labels = list(g.undo_labels.values())
    rec = json.loads(g.ext_state["Hibiki/receipts"])
    check("a batch is one undo point (+N more)", r.get("ok") and labels[-1].startswith("Hibiki k1.3: ")
          and labels[-1].endswith("+1") and count("Undo_BeginBlock2") == 2, labels)
    check("batch changes join the same turn's receipt", rec[-1]["id"] == "k1.3" and rec[-1]["n"] == 3
          and rec[-1]["points"] == 2
          and rec[-1]["lines"][1].endswith("mute") and rec[-1]["lines"][2] == "add track Pad", rec)
    n_labels = len(labels)
    r = rpc("run_lua", code="return reaper.CountTracks(0)")
    check("read-only run_lua: no undo point, no receipt line", r.get("ok") and len(list(g.undo_labels.values())) == n_labels
          and json.loads(g.ext_state["Hibiki/receipts"])[-1]["n"] == 3)
    r = rpc("run_lua", code="reaper.InsertTrackAtIndex(0, true)\nreturn 1")
    rec = json.loads(g.ext_state["Hibiki/receipts"])
    check("changing run_lua: the receipt names the new track instead of the code",
          rec[-1]["n"] == 4 and rec[-1]["lines"][3].startswith("add track #1"), rec)
    r = rpc("run_lua", code="-- set up a quieter pad\nlocal t = reaper.GetTrack(0, 0)\n"
            "reaper.SetMediaTrackInfo_Value(t, 'D_VOL', 0.5)\nt.fx = true\nreturn 1")
    rec = json.loads(g.ext_state["Hibiki/receipts"])
    lines = rec[-1]["lines"]
    check("run_lua: the receipt says what changed (title from the first comment, then a before/after diff)",
          lines[-3] == "set up a quieter pad" and lines[-2].endswith("volume 0.0 → -6.0 dB")
          and lines[-1].endswith(": add ReaComp"), lines)
    rpc("run_lua", code="-- same title\nreaper.InsertTrackAtIndex(0, true)\nreturn 1")
    r = rpc("run_lua", code="-- same title\nreaper.InsertTrackAtIndex(0, true)\nreturn 1")  # same label as the top
    labels = list(g.undo_labels.values())
    check("a repeated label still counts as a new undo point", labels[-1] == labels[-2] + "·"
          and json.loads(g.ext_state["Hibiki/receipts"])[-1]["points"] == 6, labels[-2:])
    for _ in range(3):
        rpc("delete_track", [0])
    g.ext_state["Hibiki/turn"] = "k1.4"
    rpc("update_track", [0, {"pan": 0.5}])
    rec = json.loads(g.ext_state["Hibiki/receipts"])
    check("a new turn id starts a new receipt", [x["id"] for x in rec][-2:] == ["k1.3", "k1.4"], rec)
    g.ext_state["Hibiki/turn"] = ""
    rpc("update_track", [0, {"pan": 0}])
    rec = json.loads(g.ext_state["Hibiki/receipts"])
    check("no turn id: calls get an automatic mcp-<time> turn", rec[-1]["id"].startswith("mcp-"), rec)

    # --- midi CC / program change --------------------------------------
    seeded_track(0)
    clear()
    r = rpc("add_midi_cc", [0, 0, [
        {"start_beats": 0, "program": 33, "channel": 1},
        {"start_beats": 0, "cc": 64, "value": 127, "channel": 0},
    ]])
    take_ccs = g.tracks[1]["items"][1]["ccs"]
    pc, cc64 = take_ccs[1], take_ccs[2]
    check("add_midi_cc ok", r.get("ok") and r["ret"]["inserted"] == 2, r)
    check("program change is 0xC0", int(pc["chanmsg"]) == 0xC0 and int(pc["msg2"]) == 33, dict(pc))
    check("cc 64 value 127", int(cc64["chanmsg"]) == 0xB0 and int(cc64["msg2"]) == 64 and int(cc64["msg3"]) == 127, dict(cc64))
    check("add_midi_cc sorts once", count("MIDI_Sort") == 1, f"sort={count('MIDI_Sort')}")
    check("MIDI edit inside the request's undo block marks the item instead of a separate undo point",
          count("MarkTrackItemsDirty") == 1 and count("Undo_OnStateChange_Item") == 0)

    # --- compact payloads ----------------------------------------------
    seeded_track(0)
    r = rpc("get_midi_notes", [0, 0])
    n0 = r["ret"][0]
    check("get omits index", "index" not in n0, n0)
    check("get omits channel 0", "channel" not in n0, n0)
    check("get omits selected false", "selected" not in n0, n0)
    check("get keeps muted true", n0.get("muted") is True, n0)

    r = rpc("get_project_summary")
    check("status has no ipc", r.get("ok") and "ipc" not in r["ret"], r)
    check("light status has no time_sig", "time_sig" not in r["ret"], r)

    seeded_track(0)
    lua.execute('markers = {{isrgn = false, pos = 0.0, name = "Intro", idx = 1}}')
    r = rpc("get_project_summary", [True])
    det = r.get("ret") or {}
    tr0 = (det.get("tracks") or [{}])[0]
    check("detailed status ok", r.get("ok"), r)
    check("detailed time_sig 4/4",
          (det.get("time_sig") or {}).get("numerator") == 4
          and (det.get("time_sig") or {}).get("denominator") == 4, det)
    check("detailed length_beats from project length",
          abs(float(det.get("length_beats") or 0) - 4.0) < 1e-6, det)
    check("detailed cursor_beats", "cursor_beats" in det, det)
    check("detailed markers",
          det.get("markers") and det["markers"][0].get("name") == "Intro", det)
    check("detailed track is midi", tr0.get("has_midi") is True
          and tr0.get("has_audio") is False, tr0)
    check("detailed midi_note_count", tr0.get("midi_note_count") == 1, tr0)
    check("detailed status does not guess chords",
          "chords" not in det and "chord" not in det, det)
    lua.execute("markers = {}")

    r = rpc("batch", [[{"func": "ping"}]])
    inner = r["ret"][0]
    check("batch unwraps ret", isinstance(inner, dict) and inner.get("pong") is True, inner)
    check("batch has no ok/ret shell", "ret" not in inner and "ok" not in inner, inner)

    r = rpc("run_lua", code="this is not lua !!!")
    err = r.get("error") or ""
    check("error has no bridge prefix", r.get("ok") is False and "bridge error" not in err, err)
    check("error strips chunk name", "mcp_run_lua" not in err, err)

    # --- import media ---------------------------------------------------
    clear()
    n_before = len(g.tracks)
    r = rpc("import_media", ["/tmp/x.mid", {"start_beats": 0, "as_new_track": True}])
    check("import_media new track", r.get("ok") and len(g.tracks) == n_before + 1, r)
    new_it = g.tracks[len(g.tracks)]["items"][1]
    check("import_media clears loop source", new_it["loop"] is False, dict(new_it))

    lua.execute("""
        tracks[1].selected = false
        tracks[2] = tracks[2] or new_track("T1")
        tracks[2].items = { new_item(0.0, 1.0), new_item(8.0, 1.0) }
    """)
    r = rpc("import_media", ["/tmp/y.wav", {"start_beats": 8, "track_index": 1}])
    items = g.tracks[2]["items"]
    check("import_media reports the item it created, between existing ones",
          r.get("ok") and r["ret"]["created"] == [{"track_index": 1, "item_index": 1}], r)
    check("import_media leaves existing items alone", items[3]["loop"] is True and items[2]["loop"] is False,
          [dict(items[i]) for i in (1, 2, 3)])
    n_before = len(g.tracks)
    r = rpc("import_media", ["/tmp/z.wav", {"as_new_track": True}])
    created = r.get("ret", {}).get("created")
    check("import_media new track mid-list: only the new item",
          r.get("ok") and len(created) == 1 and g.tracks[created[0]["track_index"] + 1]["name"] == "imported"
          and len(g.tracks) == n_before + 1, r)

    r = rpc("import_media", ["", {"track_index": 0}])
    check("import_media rejects empty path", r.get("ok") is False, r)

    # --- save project ---------------------------------------------------
    clear()
    r = rpc("save_project", [None])
    check("save_project unsaved needs path", r.get("ok") is False, r)
    r = rpc("save_project", ["/tmp/new dir/song.RPP"])
    check("save_project untitled adopts the path", r.get("ok") and r["ret"]["copy"] is False
          and count("Main_openProject") == 1, r)
    check("save_project creates the folder", count("RecursiveCreateDirectory") == 1)
    r = rpc("save_project", ["/tmp/song_v2.RPP"])
    check("save_project named project writes a copy", r.get("ok") and r["ret"]["copy"] is True
          and count("Main_openProject") == 1, r)
    check("save_project uses SaveProjectEx", count("Main_SaveProjectEx") == 2)
    r = rpc("save_project", [None])
    check("save_project named project saves in place", r.get("ok") and r["ret"]["path"] == "/tmp/new dir/song.RPP"
          and count("Main_SaveProject") == 1, r)
    check("save_project skips undo block", count("Undo_BeginBlock2") == 0)
    r = rpc("save_project", ["/readonly/song.RPP"])
    check("save_project reports a failed write", r.get("ok") is False and "could not write" in (r.get("error") or ""), r)

    # --- idle heartbeat throttle --------------------------------------
    clear()
    g.pump(60)  # one second of idle ticks
    writes = count("heartbeat_writes")
    check("idle heartbeat writes throttled", 1 <= writes <= 3, f"writes={writes}")

    # --- JSON regressions (null args, emoji, nil batch slots) ----------
    n_tracks = len(g.tracks)
    r = rpc("add_track", [None, 0])
    check("null name keeps the index in place", r.get("ok") and r["ret"]["index"] == 0
          and len(g.tracks) == n_tracks + 1 and r["ret"].get("name") != "0", r)
    r = rpc("add_track", ["\U0001F3B5 Lead", 0])  # json.dump escapes it as a surrogate pair
    names = [t["name"] for t in rpc("list_tracks")["ret"]]
    check("emoji survives the mailbox", "\U0001F3B5 Lead" in names, names[:3])
    r = rpc("batch", [[{"func": "run_lua", "code": "return nil"}, {"func": "ping"}]])
    r2 = rpc("batch", [[{"func": "run_lua", "code": 'error("missing argument: index", 0)'}, {"func": "ping"}]])
    check("batch error slot carries the message", r2.get("ok") and r2["ret"][0] == {"error": "missing argument: index"}
          and r2["ret"][1]["pong"] is True, r2)
    check("batch keeps nil slots as null", r.get("ok") and isinstance(r["ret"], list) and len(r["ret"]) == 2
          and r["ret"][0] is None, r)

    # --- delete_midi_notes ignores repeats and out-of-range indices --
    item = rpc("create_midi_item", [0, 0.0, 4.0])["ret"]["item_index"]
    rpc("add_midi_notes", [0, item, [{"pitch": 60, "start_beats": 0, "length_beats": 1},
                                     {"pitch": 62, "start_beats": 1, "length_beats": 1}]])
    r = rpc("delete_midi_notes", [0, item, [0, 0, 99]])
    left = rpc("get_midi_notes", [0, item])["ret"]
    check("delete [0,0,99] removes one note", r.get("ok") and r["ret"]["deleted"] == 1 and len(left) == 1, r)

    # --- volume envelopes speak gain, whatever their scaling ----------
    lua.execute("""
        tracks[#tracks + 1] = new_track("Vox")
        tracks[#tracks].envelopes = { { name = "Volume", scaling = 1, points = {} } }
        tracks[#tracks + 1] = new_track("Amp")
        tracks[#tracks].envelopes = { { name = "Volume", points = {} } }
    """)
    vox, amp = len(g.tracks) - 2, len(g.tracks) - 1
    r = rpc("set_envelope", [vox, "Volume", [{"beats": 0, "value": 1.0}, {"beats": 4, "value": 0.5}]])
    raw = [float(g.tracks[vox + 1]["envelopes"][1]["points"][i][2]) for i in (1, 2)]
    want = [float(g.reaper.ScaleToEnvelopeMode(1, v)) for v in (1.0, 0.5)]
    check("set_envelope on a fader-scaled envelope stores fader positions (0 dB = 716.2)",
          r.get("ok") and all(abs(a - b) < 1e-6 for a, b in zip(raw, want)) and abs(raw[0] - 716.2178) < 1e-3, (raw, want))
    lua.execute("""tracks[%d].envelopes[1].points = {
        { 0.0, reaper.ScaleToEnvelopeMode(1, 1.0) }, { 2.0, reaper.ScaleToEnvelopeMode(1, 0.5) } }""" % (vox + 1))
    r = rpc("get_envelope", [vox, "Volume"])
    vals = [p["value"] for p in r.get("ret", {}).get("points", [])]
    check("get_envelope on a fader-scaled envelope returns gain (points drawn at 0 dB and -6 dB)", r.get("ok") and len(vals) == 2
          and abs(vals[0] - 1.0) < 1e-9 and abs(vals[1] - 0.5) < 1e-9, r)
    rpc("set_envelope", [amp, "Volume", [{"beats": 0, "value": 0.5}]])
    check("set_envelope on an amplitude envelope stores the gain as is",
          float(g.tracks[amp + 1]["envelopes"][1]["points"][1][2]) == 0.5)

    # --- a bus is a submix: sources reach the master through it only -
    n_before = len(g.tracks)
    r = rpc("create_bus", ["Drum Bus", [vox, amp]])
    bus = g.tracks[n_before + 1]
    srcs = [g.tracks[vox + 1], g.tracks[amp + 1]]
    check("create_bus sends each source to the new bus", r.get("ok") and r["ret"]["index"] == n_before
          and all(len(s["sends"]) == 1 and s["sends"][1]["dest"]["name"] == "Drum Bus" for s in srcs), r)
    check("create_bus turns off the sources' direct master send",
          all(int(g.reaper.GetMediaTrackInfo_Value(s, "B_MAINSEND")) == 0 for s in srcs)
          and int(g.reaper.GetMediaTrackInfo_Value(bus, "B_MAINSEND")) == 1)

    # --- render: preflight, overwrite guard, temporary solo, measured outputs ----
    out_dir = tempfile.mkdtemp()
    lua.execute("""
        for _, t in ipairs(tracks) do t.solo = false t.mute = false end
        renders = {}
        fake_gain = 2.0
    """)
    clear()
    r = rpc("render_project", [out_dir, {"bounds": "project", "pattern": "mix1"}])
    ret = r.get("ret") or {}
    f0 = (ret.get("files") or [{}])[0]
    check("render sets media online (40101) before rendering", r.get("ok") and count("cmd.40101") == 1
          and count("cmd.42230") == 1, r)
    check("render reports the file it wrote, with size, length, peak and LUFS",
          f0.get("path") == out_dir + "/mix1.wav" and f0.get("bytes", 0) > 0 and f0.get("length_sec") == 2.0
          and abs(f0.get("peak_db", 0) + 6.0206) < 1e-3 and abs(f0.get("lufs_i", 0) + 6.0206) < 1e-3, f0)
    check("clean render has no warnings", "warnings" not in ret, ret)

    clear()
    r = rpc("render_project", [out_dir, {"bounds": "project", "pattern": "mix1"}])
    check("render refuses an existing target instead of hitting the overwrite prompt",
          r.get("ok") is False and "existing file" in (r.get("error") or "") and count("cmd.42230") == 0, r)

    lua.execute("tracks[1].solo = true")
    clear()
    r = rpc("render_project", [out_dir, {"bounds": "project", "pattern": "mix2"}])
    check("render refuses while a track is soloed and names it",
          r.get("ok") is False and "soloed" in (r.get("error") or "") and count("cmd.42230") == 0, r)
    r = rpc("render_project", [out_dir, {"bounds": "project", "pattern": "mix2", "allow_solo": True}])
    check("allow_solo=true renders anyway", r.get("ok"), r)
    lua.execute("tracks[1].solo = false")

    n_tr = len(g.tracks)
    lua.execute("tracks[2].mute = true")
    lua.execute("for _, t in ipairs(tracks) do t.selected = true end")  # selection ganging must not spread the solo
    r = rpc("render_project", [out_dir, {"bounds": "project", "pattern": "solo_render",
                                         "solo_indices": [0], "mute_indices": [2]}])
    seen = g.renders[len(g.renders)]
    check("solo_indices / mute_indices apply during the render",
          r.get("ok") and seen[1]["solo"] is True and all(seen[i]["solo"] is False for i in range(2, n_tr + 1))
          and seen[3]["mute"] is True, r)
    check("solo / mute are restored after the render",
          all(not g.tracks[i]["solo"] for i in range(1, n_tr + 1)) and g.tracks[2]["mute"] is True
          and not g.tracks[3]["mute"], [(g.tracks[i]["solo"], g.tracks[i]["mute"]) for i in range(1, n_tr + 1)])
    lua.execute("tracks[2].mute = false")
    lua.execute("for _, t in ipairs(tracks) do t.selected = false end")

    lua.execute("fake_gain = 10000")
    r = rpc("render_project", [out_dir, {"bounds": "project", "pattern": "quiet"}])
    check("near-silent render is flagged", r.get("ok") and any("near-silent" in w for w in r["ret"].get("warnings", [])), r)
    lua.execute("fake_gain = math.huge")
    r = rpc("render_project", [out_dir, {"bounds": "project", "pattern": "silent"}])
    f0 = (r.get("ret", {}).get("files") or [{}])[0]
    check("digitally silent render reads -150 dB and is flagged", r.get("ok") and f0.get("peak_db") == -150
          and any("near-silent" in w for w in r["ret"].get("warnings", [])), r)
    lua.execute("fake_gain = 2.0")

    r = rpc("render_project", [out_dir, {"bounds": "custom", "start_beats": 8, "end_beats": 8}])
    check("custom bounds need end > start", r.get("ok") is False and "end_beats" in (r.get("error") or ""), r)

    clear()
    r = rpc("render_project", [out_dir, {"bounds": "project", "pattern": "noon", "media_online": False, "measure": False}])
    f0 = (r.get("ret", {}).get("files") or [{}])[0]
    check("media_online=false skips 40101; measure=false skips the scan",
          r.get("ok") and count("cmd.40101") == 0 and "peak_db" not in f0 and f0.get("bytes", 0) > 0, r)

    lua.execute('tracks[1].name = "Kick"')
    r = rpc("render_project", [out_dir, {"bounds": "project", "pattern": "stem_$track", "stems": True,
                                         "track_indices": [0]}])
    files = [f["path"] for f in r.get("ret", {}).get("files", [])]
    check("stems render reports the per-track file", r.get("ok") and files == [out_dir + "/stem_Kick.wav"], r)

    r = rpc("get_project_summary")
    st = r.get("ret") or {}
    check("status reports any_solo, master_mute and dirty",
          st.get("any_solo") is False and st.get("master_mute") is False and st.get("dirty") is False, st)
    lua.execute("ui_solo = true")
    check("status any_solo sees a UI solo that I_SOLO hides", rpc("get_project_summary")["ret"]["any_solo"] is True)
    lua.execute("ui_solo = false")

    # --- fx set by displayed value -----------------------------------
    lua.execute("tracks[1].fx = true tracks[1].fxp = {}")
    r = rpc("set_fx_param", [0, 0, "Threshold", None, -18])
    check("fx set formatted=-18 lands on -18.0 dB", r.get("ok") and r["ret"]["formatted"] == "-18.0", r)
    r = rpc("set_fx_param", [0, 0, "Ratio", None, 4])
    check("fx set formatted ratio 4 lands on 4.0:1, not inf/99", r.get("ok") and r["ret"]["formatted"] == "4.0:1", r)
    r = rpc("set_fx_param", [0, 0, 1, None, "inf"])
    check("fx set formatted 'inf' reaches the top of the range", r.get("ok") and r["ret"]["formatted"] == "inf", r)
    r = rpc("set_fx_param", [0, 0, "Mode", None, "4"])
    check("fx set formatted enum label matches exactly ('4', not 'Blown Capacitor 4')",
          r.get("ok") and r["ret"]["formatted"] == "4", r)
    r = rpc("set_fx_param", [0, 0, "Threshold", None, 12])
    check("fx set formatted out of range is an error with the range",
          r.get("ok") is False and "outside" in (r.get("error") or ""), r)
    r = rpc("set_fx_param", [0, 0, "Threshold", 0.5])
    check("fx set value still works and returns formatted", r.get("ok") and r["ret"]["formatted"] == "-30.0", r)
    r = rpc("set_fx_param", [0, 0, "Threshold"])
    check("fx set without value or formatted is a clear error", r.get("ok") is False and "formatted" in (r.get("error") or ""), r)

    # --- sends: sidechain routing ---------------------------------------
    lua.execute("""
        tracks[#tracks + 1] = new_track("KickSrc")
        tracks[#tracks + 1] = new_track("Bass")
    """)
    ks, bs = len(g.tracks) - 2, len(g.tracks) - 1
    r = rpc("add_send", [ks, bs, {"dst_channel": 2, "mode": "pre_fader", "volume_db": -6}])
    snd = g.tracks[ks + 1]["sends"][1]
    check("add_send routes to channels 3/4 and widens the destination to 4 channels",
          r.get("ok") and int(snd["I_DSTCHAN"]) == 2 and int(g.tracks[bs + 1]["nchan"]) == 4
          and int(snd["I_SENDMODE"]) == 3 and abs(float(snd["vol"]) - 10 ** (-6 / 20)) < 1e-9, r)
    r = rpc("list_sends", [ks])
    s0 = (r.get("ret") or [{}])[0]
    check("list_sends shows dst_channel and mode", s0.get("dst_channel") == 2 and s0.get("mode") == "pre_fader"
          and "src_channel" not in s0, s0)
    r = rpc("update_send", [ks, 5, {"mute": True}])
    check("update_send on a missing send is an error", r.get("ok") is False and "no send" in (r.get("error") or ""), r)
    r = rpc("add_send", [ks, bs, {"mode": "sideways"}])
    check("bad send mode is an error", r.get("ok") is False, r)

    # --- envelopes in dB, inactive envelopes come back on ---------------
    lua.execute("""
        tracks[#tracks + 1] = new_track("Trimmed")
        tracks[#tracks].envelopes = { { name = "Trim Volume", scaling = 1, points = {},
                                        chunk = "<VOLENV3\\nACT 0 -1\\nVIS 1 1 1\\n>" } }
    """)
    tv = len(g.tracks) - 1
    r = rpc("set_envelope", [tv, "Trim Volume", [{"beats": 0, "value": 0}, {"beats": 4, "value": -6}], "db"])
    env = g.tracks[tv + 1]["envelopes"][1]
    check("set_envelope unit=db re-activates an ACT 0 envelope",
          r.get("ok") and r["ret"].get("activated") is True and "ACT 1" in env["chunk"], r)
    r = rpc("get_envelope", [tv, "Trim Volume", "db"])
    vals = [p["value"] for p in r.get("ret", {}).get("points", [])]
    check("get_envelope unit=db round-trips dB", r.get("ok") and len(vals) == 2 and abs(vals[0]) < 1e-9
          and abs(vals[1] + 6) < 1e-9, r)
    r = rpc("set_envelope", [tv, "Trim Volume", [{"beats": 0}]])
    check("set_envelope rejects a point without value", r.get("ok") is False and "point #1" in (r.get("error") or ""), r)
    r = rpc("get_envelope", [tv, "Volume"])
    check("missing envelope error lists what the track has", r.get("ok") is False and "Trim Volume" in (r.get("error") or ""), r)

    # --- run_lua errors point at the line ---------------------------------
    r = rpc("run_lua", code="local a = 1\nlocal t = nil\nreturn t.x")
    check("run_lua runtime error quotes the failing line",
          r.get("ok") is False and "[line 3: return t.x]" in (r.get("error") or ""), r)

    # --- 2026-10-24: arrange verbs, ranges, selection, guards ----------------
    g.ext_state["Hibiki/turn"] = "arr.1"
    lua.execute("""
      tracks = { new_track("A"), new_track("B") }
      tracks[1].items[1] = new_item(0.0, 4.0)      -- beats 0..8 (fake tempo: 1 beat = 0.5 s)
      tracks[1].items[1].ccs = { { ppq = 960, chanmsg = 0xB0, chan = 1, msg2 = 64, msg3 = 127 },
                                 { ppq = 0, chanmsg = 0xE0, chan = 0, msg2 = 0, msg3 = 64 } }
      tracks[2].selected = true
      tracks[1].items[1].selected = true
      time_sel = { 1.0, 3.0 }
      tempo_markers = { { time = 0, bpm = 120, num = 4, den = 4 }, { time = 8, bpm = 90, num = 3, den = 4 } }
    """)
    r = rpc("get_project_summary", [False])["ret"]
    check("status: time selection in beats", r.get("time_selection") == {"start_beats": 2.0, "end_beats": 6.0}, r)
    check("status: selected tracks and items", r["tracks"][1].get("selected") is True
          and "selected" not in r["tracks"][0] and r.get("selected_items") == [{"track_index": 0, "item_index": 0}], r)
    r = rpc("get_project_summary", [True])["ret"]
    check("status detail: tempo_map lists the meter change", len(r.get("tempo_map", [])) == 2
          and r["tempo_map"][1] == {"beats": 16.0, "bpm": 90, "numerator": 3, "denominator": 4}, r.get("tempo_map"))

    r = rpc("split_item", [0, 0, [6, 2]])
    items = g.tracks[1]["items"]
    check("split: sorted cuts give three pieces left to right",
          r.get("ok") and r["ret"]["item_indices"] == [0, 1, 2] and len(items) == 3
          and abs(items[3]["position"] - 3.0) < 1e-9 and abs(items[2]["length"] - 2.0) < 1e-9, r)
    r = rpc("split_item", [0, 0, [50]])
    check("split: a beat outside the item is refused", r.get("ok") is False and "not inside" in r["error"], r)
    r = rpc("update_item", [0, 1, {"left_edge_beats": 3, "fade_in_sec": 0.2, "fade_out_shape": "s_curve"}])
    it = g.tracks[1]["items"][2]
    check("update: left edge moves the start, content stays (offset grows)",
          r.get("ok") and abs(it["position"] - 1.5) < 1e-9 and abs(it["length"] - 1.5) < 1e-9
          and abs(it["offs"] - 1.5) < 1e-9, dict(it))
    check("update: fade seconds and shape", it["info"]["D_FADEINLEN"] == 0.2 and it["info"]["C_FADEOUTSHAPE"] == 5)
    r = rpc("update_item", [0, 1, {"fade_in_shape": "wobbly"}])
    check("update: unknown fade shape lists the names", r.get("ok") is False and "s_curve" in r["error"], r)
    r = rpc("list_items", [0])["ret"]
    check("list: fade_in_sec / shape named", r[1]["fade_in_sec"] == 0.2 and r[1]["fade_out_shape"] == "s_curve", r[1])
    r = rpc("duplicate_item", [0, 0, {"position_beats": 20}])
    check("duplicate: copy lands at the beat with new GUIDs",
          r.get("ok") and r["ret"] == {"track_index": 0, "item_index": 3}
          and abs(g.tracks[1]["items"][4]["position"] - 10.0) < 1e-9
          and "AAAAAAAA" not in g.tracks[1]["items"][4]["chunk"], r)
    r = rpc("update_item", [0, 3, {"dest_track_index": 1}])
    check("update: dest_track_index moves it and returns the new place",
          r.get("ok") and r["ret"] == {"track_index": 1, "item_index": 0} and len(g.tracks[2]["items"]) == 1, r)
    r = rpc("delete_items", [0, [0, 2]])
    check("delete: several at once", r.get("ok") and r["ret"]["deleted"] == 2 and len(g.tracks[1]["items"]) == 1, r)
    lua.execute("tracks[1].items[1].takes = { { audio = '/Users/me/take2.wav', take_name = 'Take 2' } }")
    r = rpc("update_item", [0, 0, {"active_take": 1}])
    lst = rpc("list_items", [0])["ret"][0]
    check("takes: switch the active take; list shows its name, source and count",
          r.get("ok") and lst.get("take") == "Take 2" and lst.get("source") == "/Users/me/take2.wav"
          and lst.get("takes") == 2 and lst.get("active_take") == 1, lst)
    r = rpc("update_item", [0, 0, {"active_take": 5}])
    check("takes: a missing take is refused", r.get("ok") is False and "no take 5" in r["error"], r)

    lua.execute("""tracks[1].items[1].curtake = 0
      tracks[1].items[1].ccs = { { ppq = 960, chanmsg = 0xB0, chan = 1, msg2 = 64, msg3 = 127 },
                                 { ppq = 0, chanmsg = 0xE0, chan = 0, msg2 = 0, msg3 = 64 } }""")
    r = rpc("get_midi_cc", [0, 0])
    check("midi get_cc: CC and pitch bend in the cc tool's shape",
          r.get("ok") and {"start_beats": 1.0, "cc": 64, "value": 127, "channel": 1} in r["ret"]
          and {"start_beats": 0.0, "pitch_bend": 0} in r["ret"], r)

    # fake envelope points are in seconds: beats 0, 4, 8, 12
    lua.execute("""tracks[1].envelopes = { { name = 'Volume', points = { {0, 1}, {2, 1}, {4, 1}, {6, 1} } } }""")
    r = rpc("set_envelope", [0, "Volume", [{"beats": 4, "value": 0.5}, {"beats": 6, "value": 0.25}], None,
                             {"start_beats": 4, "end_beats": 8}])
    pts = [list(x.values()) for x in g.tracks[1]["envelopes"][1]["points"].values()]
    check("envelope set with a range replaces only the points inside it (ends included)",
          r.get("ok") and [round(x[0], 6) for x in pts] == [0, 2, 3, 6] and pts[1][1] == 0.5, pts)
    r = rpc("set_envelope", [0, "Volume", [{"beats": 1, "value": 1}], None, {"start_beats": 4, "end_beats": 8}])
    check("envelope set refuses a point outside the range", r.get("ok") is False and "outside" in r["error"], r)
    r = rpc("get_envelope", [0, "Volume", None, {"start_beats": 2, "end_beats": 6}])
    check("envelope get with a range", r.get("ok") and [x["beats"] for x in r["ret"]["points"]] == [4, 6], r)

    lua.execute("tracks[1].fx = true tracks[1].fxp = {}")
    r = rpc("get_fx_params", [0, 0, "rat"])
    check("fx params filter", r.get("ok") and [x["name"] for x in r["ret"]] == ["Ratio"], r)

    lua.execute("markers = { { pos = 12.0, name = 'Chorus', idx = 3 } } cursor = 0")
    r = rpc("transport", ["goto", {"marker": "chorus"}])
    check("transport goto a marker by name", r.get("ok") and r["ret"]["position_beats"] == 24.0
          and r["ret"]["position_sec"] == 12.0, r)
    r = rpc("transport", ["goto", {"marker": 3}])
    check("transport goto a marker by number", r.get("ok") and r["ret"]["position_beats"] == 24.0, r)
    r = rpc("transport", ["goto", {"position_beats": 8}])
    check("transport goto a beat", r.get("ok") and r["ret"]["position_beats"] == 8.0, r)
    r = rpc("transport", ["goto", {"marker": "Bridge"}])
    check("transport goto a missing marker", r.get("ok") is False and "Bridge" in r["error"], r)

    r = rpc("batch", [[{"func": "update_track", "args": [0, {"name": "x"}]},
                       {"func": "update_track", "args": [9, {"name": "y"}]},
                       {"func": "update_track", "args": [1, {"name": "z"}]}], {"stop_on_error": True}])
    check("batch stop_on_error skips what follows the failure",
          r.get("ok") and "error" in r["ret"][1] and r["ret"][2] == {"skipped": True} and g.tracks[2]["name"] == "B", r)

    lua.execute("clock_step = 0.05")
    r = rpc("run_lua", code="local n = 0 while true do n = n + 1 end")
    lua.execute("clock_step = 0")
    check("run_lua: a runaway loop is stopped at its timeout", r.get("ok") is False
          and "still running after 10 s" in (r.get("error") or ""), r)
    r = rpc("run_lua", code="return 7")
    check("run_lua works again after a stopped snippet", r.get("ok") and r["ret"] == 7, r)

    lua.execute("proj_str.RENDER_FORMAT = 'ZmxhYwAAAAA='")
    r = rpc("render_project", ["/tmp", {"bounds": "project", "pattern": "fmt_test_%d" % os.getpid(), "format": "wav",
                                        "bit_depth": 16, "measure": False}])
    check("render format for this render only, then the project's comes back",
          r.get("ok") and g.proj_str["RENDER_FORMAT"] == "ZmxhYwAAAAA=", r)
    r = rpc("render_project", ["/tmp", {"format": "wav", "bit_depth": 20}])
    check("render: a bad bit depth is refused", r.get("ok") is False and "bit_depth" in r["error"], r)

    # a reply is pinned to the project tab it started on
    g.ext_state["Hibiki/turn"] = "pin.1"
    check("guard: first write pins the tab", rpc("update_track", [0, {"name": "p1"}]).get("ok"))
    lua.execute("active_proj = 1")
    r = rpc("update_track", [0, {"name": "p2"}])
    check("guard: a panel reply can't write after the user switched tabs",
          r.get("ok") is False and "refused" in r["error"] and g.tracks[1]["name"] == "p1", r)
    check("guard: reads still work", rpc("get_project_summary", [False]).get("ok"))
    check("guard: still refused later in the same reply", rpc("update_track", [0, {"name": "p3"}]).get("ok") is False)
    g.ext_state["Hibiki/turn"] = "pin.2"
    check("guard: the next reply works on the new tab", rpc("update_track", [0, {"name": "p4"}]).get("ok"))
    g.ext_state["Hibiki/turn"] = ""
    rpc("update_track", [0, {"name": "m1"}])
    lua.execute("active_proj = 0")
    r1 = rpc("update_track", [0, {"name": "m2"}])
    r2 = rpc("update_track", [0, {"name": "m3"}])
    check("guard: without the panel the switch is refused once, then followed",
          r1.get("ok") is False and "refused once" in r1["error"] and r2.get("ok"), (r1, r2))

    # a second REAPER's bridge: the request is claimed by rename, so only one bridge runs it
    if os.path.exists(resp):
        os.remove(resp)
    with open(req, "w", encoding="utf-8") as f:
        json.dump({"id": "c1", "func": "ping", "args": []}, f)
    os.rename(req, os.path.join(ipc_dir, "request.other.claimed"))
    g.pump(3)
    check("mailbox: a request another bridge claimed is not run here", not os.path.exists(resp))
    os.remove(os.path.join(ipc_dir, "request.other.claimed"))
    # a second REAPER (its own Lua state, so another instance id) waits while this one's heartbeat is fresh
    g.pump(1)  # fresh heartbeat
    lua2 = lupa.LuaRuntime()
    lua2.execute(COMPAT)
    lua2.execute(FAKE.read_text(encoding="utf-8"))
    lua2.execute("now = 2345.678")  # another process: another clock reading at startup
    lua2.execute(BRIDGE.read_text(encoding="utf-8"))
    with open(req, "w", encoding="utf-8") as f:
        json.dump({"id": "w1", "func": "ping", "args": []}, f)
    lua2.globals().pump(5)
    check("second REAPER: leaves the mailbox alone while the first one is alive", os.path.exists(req))
    g.pump(1)
    check("first REAPER: still serves", os.path.exists(resp) and json.load(open(resp))["id"] == "w1")
    with open(os.path.join(ipc_dir, "heartbeat"), "w") as f:
        f.write("gone 0")
    lua2.globals().pump(90)  # past its one-second recheck; taking over clears the old mailbox files
    if os.path.exists(resp):
        os.remove(resp)
    with open(req, "w", encoding="utf-8") as f:
        json.dump({"id": "w2", "func": "ping", "args": []}, f)
    lua2.globals().pump(2)
    check("second REAPER: takes over once the first one's heartbeat is stale",
          os.path.exists(resp) and json.load(open(resp))["id"] == "w2")
    g.pump(1)  # the first bridge is still running in this test: put its heartbeat back
    heart = open(os.path.join(ipc_dir, "heartbeat")).read()
    check("heartbeat names this REAPER", len(heart.split()) == 2 and heart.split()[1].isdigit(), heart)

    json_checks(lupa, check)

    # --- the bridge is still responsive -------------------------------
    r = rpc("ping")
    check("bridge still responsive", r.get("ok") and r["ret"]["pong"] is True, r)

    if failures:
        print("FAILED", failures)
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main()
