#!/usr/bin/env python3
"""reaper-mcp — stdio MCP server. Zero third-party deps.

Talks to the Lua bridge (reaper_mcp/bridge.lua, installed in REAPER as reaper_mcp_bridge.lua) over a JSON mailbox. Prefer a handful of grouped
tools plus batch / run_lua instead of dumping the whole ReaScript API.
"""

from __future__ import annotations

import json
import os
import sys
import time
import uuid

if sys.platform == "win32":
    import msvcrt
else:
    import fcntl

if not __package__:  # run by path (python3 .../reaper_mcp/server.py): make the package importable
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "reaper-mcp"
from reaper_mcp import __version__ as SERVER_VERSION  # noqa: E402
HEARTBEAT_STALE = float(os.environ.get("REAPER_MCP_HEARTBEAT_STALE", "5"))
POLL = float(os.environ.get("REAPER_MCP_POLL", "0.015"))
# A fast bridge answers inside the first few milliseconds, so poll tightly at
# first and fall back to POLL for the wait (and for lock contention).
FAST_POLL = 0.002
FAST_POLL_WINDOW = 0.25
RENDER_TIMEOUT = float(os.environ.get("REAPER_MCP_RENDER_TIMEOUT", "300"))
RUN_LUA_MAX_TIMEOUT = 600
RUN_LUA_DEFAULT_TIMEOUT = 10
RUN_LUA_GRACE = 5  # the bridge stops a snippet at its timeout; wait a little longer for that answer


def _run_lua_timeout(a):
    t = a.get("timeout")
    if t is None:
        return float(RUN_LUA_DEFAULT_TIMEOUT)
    return max(1.0, min(float(t), RUN_LUA_MAX_TIMEOUT))

INSTRUCTIONS = (
    "Drive REAPER. Time is beats (quarter notes), track/item indices are 0-based. "
    "Call status first. On a new or unknown project, call status with detail=true "
    "before editing (arrangement facts only; do not infer chords). "
    "Prefer batch for multi-step edits. "
    "Do not ExecProcess long commands in run_lua; it blocks the bridge. "
    "Use run_lua or reaper_call only for APIs not covered by the grouped tools."
)


def instructions() -> str:
    """INSTRUCTIONS plus the rules for agents (Hibiki's conventions and the user's rules.md), read at each
    initialize so an edited rules.md reaches the next session without a restart. Any trouble: the base text."""
    try:
        from reaper_mcp import brain
        rules = brain.compose()
    except Exception:  # noqa: BLE001 - instructions must never break initialize
        return INSTRUCTIONS
    return INSTRUCTIONS + ("\n\n" + rules if rules else "")


def default_ipc_dir() -> str:
    env = os.environ.get("REAPER_MCP_IPC_DIR")
    if env:
        return env
    if os.environ.get("APPDATA"):
        return os.path.join(os.environ["APPDATA"], "reaper-mcp", "ipc")
    if sys.platform == "darwin":
        return os.path.expanduser("~/Library/Application Support/reaper-mcp/ipc")
    xdg = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    return os.path.join(xdg, "reaper-mcp", "ipc")


def _is_wsl() -> bool:
    if sys.platform != "linux":
        return False
    if os.environ.get("WSL_DISTRO_NAME") or os.environ.get("WSL_INTEROP"):
        return True
    try:
        with open("/proc/version", encoding="utf-8") as f:
            return "microsoft" in f.read().lower()
    except OSError:
        return False


class BridgeError(Exception):
    pass


def _poll_wait(started: float) -> float:
    return FAST_POLL if (time.monotonic() - started) < FAST_POLL_WINDOW else POLL


class Bridge:
    def __init__(self) -> None:
        self.dir = default_ipc_dir()
        self.req = os.path.join(self.dir, "request.json")
        self.resp = os.path.join(self.dir, "response.json")
        self.heart = os.path.join(self.dir, "heartbeat")
        self.busy = os.path.join(self.dir, "busy")
        self.mutex = os.path.join(self.dir, "ipc.mutex")
        self.timeout = float(os.environ.get("REAPER_MCP_TIMEOUT", "10"))
        os.makedirs(self.dir, mode=0o700, exist_ok=True)  # the mailbox accepts run_lua: keep it private

    def _heartbeat_ok(self) -> bool:
        try:
            return (time.time() - os.path.getmtime(self.heart)) < HEARTBEAT_STALE
        except OSError:
            return False

    def _busy(self) -> bool:
        return os.path.exists(self.busy)

    def _refuse(self) -> None:
        if _is_wsl():
            raise BridgeError(
                "REAPER bridge not seen. This Python is inside WSL; REAPER is a "
                "native Windows app and they do not share this IPC directory "
                f"({self.dir}). Run the MCP server with Windows Python, or set "
                "REAPER_MCP_IPC_DIR to a path both sides can see (e.g. /mnt/c/...)."
            )
        raise BridgeError(
            "REAPER bridge not running or heartbeat stale. In REAPER: Actions > "
            "reaper_mcp_bridge.lua > Run (install it with `reaper-mcp --install-bridge`)."
        )

    def _lock(self, timeout: float):
        os.makedirs(self.dir, exist_ok=True)
        fd = open(self.mutex, "a+b")
        deadline = time.monotonic() + timeout
        try:
            while True:
                try:
                    if sys.platform == "win32":
                        fd.seek(0, os.SEEK_END)
                        if fd.tell() == 0:
                            fd.write(b"\0")
                            fd.flush()
                        fd.seek(0)
                        msvcrt.locking(fd.fileno(), msvcrt.LK_NBLCK, 1)
                    else:
                        fcntl.flock(fd.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        fd.close()
                        raise BridgeError(
                            "Timed out waiting for another reaper-mcp client to finish."
                        )
                    time.sleep(POLL)
            return fd
        except Exception:
            fd.close()
            raise

    def _unlock(self, fd) -> None:
        try:
            if sys.platform == "win32":
                fd.seek(0)
                msvcrt.locking(fd.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(fd.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        fd.close()

    def call(self, func: str, args=None, code: str | None = None, timeout: float | None = None,
             lua_timeout: float | None = None):
        wait = timeout if timeout is not None else self.timeout
        fd = self._lock(wait)
        try:
            deadline = time.monotonic() + wait
            while True:
                if self._heartbeat_ok() and not self._busy():
                    break
                if time.monotonic() >= deadline:
                    if self._busy():
                        raise BridgeError(
                            "Timed out waiting for REAPER to finish the previous request "
                            "(a long run_lua / render is still running). Do not resend it; "
                            "call status again in a few seconds."
                        )
                    self._refuse()
                time.sleep(POLL)
            rid = uuid.uuid4().hex[:12]
            payload = {"id": rid, "func": func}
            if code is not None:
                payload["code"] = code
                if lua_timeout is not None:
                    payload["timeout"] = lua_timeout
            else:
                payload["args"] = args or []
            try:
                os.remove(self.resp)
            except OSError:
                pass
            tmp = self.req + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False)  # raw UTF-8: no surrogate-pair escapes for emoji
            os.replace(tmp, self.req)

            started = time.monotonic()
            while time.monotonic() < deadline:
                if os.path.exists(self.resp):
                    try:
                        with open(self.resp, "rb") as f:
                            data = json.loads(f.read().decode("utf-8", "replace"))
                    except (OSError, ValueError):
                        time.sleep(_poll_wait(started))
                        continue
                    if data.get("id") not in (rid, None):
                        time.sleep(_poll_wait(started))
                        continue
                    try:
                        os.remove(self.resp)
                    except OSError:
                        pass
                    if not data.get("ok", False):
                        raise BridgeError(data.get("error", "unknown bridge error"))
                    return data.get("ret")
                time.sleep(_poll_wait(started))
            # Not picked up: withdraw it, or REAPER would run it later on its own (a retry would run it twice).
            withdrawn = False
            try:
                with open(self.req, "r", encoding="utf-8") as f:
                    if json.load(f).get("id") == rid:
                        os.remove(self.req)
                        withdrawn = True
            except (OSError, ValueError):
                pass
            if withdrawn:
                raise BridgeError("REAPER did not pick up the request in time (a modal dialog open?). "
                                  "It was withdrawn and will not run.")
            raise BridgeError("Timed out waiting for REAPER to finish the request; it may still complete (a call "
                              "blocked inside REAPER, e.g. ExecProcess or a dialog, can't be stopped). "
                              "Do not resend it: call status until REAPER is free. For slow work pass a "
                              "longer timeout (run_lua timeout=...), or start host commands in the "
                              "background (io.popen('cmd > log 2>&1 &')) and poll the log.")
        finally:
            self._unlock(fd)


TOOLS = []


def tool(name, description, schema, builder):
    TOOLS.append({
        "name": name,
        "description": description,
        "inputSchema": schema,
        "_builder": builder,
    })


def obj(props, required=None):
    return {
        "type": "object",
        "properties": props,
        "required": required or [],
        "additionalProperties": False,
    }


def _props(a, keys):
    return {k: a[k] for k in keys if k in a}


SEND_PROPS = ("volume_db", "pan", "mute", "mode", "src_channel", "dst_channel")

NOTE = {
    "type": "object",
    "properties": {
        "pitch": {"type": "integer", "minimum": 0, "maximum": 127},
        "start_beats": {"type": "number"},
        "length_beats": {"type": "number"},
        "velocity": {"type": "integer", "minimum": 1, "maximum": 127},
        "channel": {"type": "integer", "minimum": 0, "maximum": 15},
        "muted": {"type": "boolean"},
    },
    "required": ["pitch", "start_beats"],
}

CC = {
    "type": "object",
    "properties": {
        "start_beats": {"type": "number"},
        "channel": {"type": "integer", "minimum": 0, "maximum": 15},
        "cc": {"type": "integer", "minimum": 0, "maximum": 127},
        "value": {"type": "integer", "minimum": 0, "maximum": 127},
        "program": {"type": "integer", "minimum": 0, "maximum": 127},
    },
    "required": ["start_beats"],
}


tool(
    "status",
    "Check the Lua bridge and return project tempo, play state, cursor_beats, tracks (selected=true on selected "
    "ones), time_selection {start_beats, end_beats} when there is one, selected_items [{track_index, item_index}], "
    "any_solo, master_mute and dirty (unsaved changes). Call first; clear a lingering solo before rendering. "
    "detail=true adds arrangement facts (time signature at the start, tempo_map of tempo/meter changes, length in "
    "beats, markers, MIDI vs audio per track) without guessing chords.",
    obj({"detail": {"type": "boolean"}}),
    lambda b, a: b.call("get_project_summary", [bool(a.get("detail"))]),
)

tool(
    "transport",
    "Playback control. action: play, stop, pause, record, toggle_repeat, goto_start, goto (edit cursor to "
    "position_beats, or to a marker/region by number or name; moves playback too when playing). "
    "Returns play_state, position_sec and position_beats.",
    obj({"action": {"type": "string",
                    "enum": ["play", "stop", "pause", "record",
                             "toggle_repeat", "goto_start", "goto"]},
         "position_beats": {"type": "number", "minimum": 0},
         "marker": {"type": ["string", "integer"]}},
        ["action"]),
    lambda b, a: b.call("transport", [a["action"], _props(a, ("position_beats", "marker")) or None]),
)

tool(
    "track",
    "Track operations. action: list | add | delete | update | bus. "
    "update uses name, volume_db, pan (-1..1), mute, solo. "
    "bus creates a submix named `name` and routes source_indices through it (their direct send to the "
    "master/parent is turned off).",
    obj({
        "action": {"type": "string", "enum": ["list", "add", "delete", "update", "bus"]},
        "index": {"type": "integer", "minimum": -1},
        "name": {"type": "string"},
        "volume_db": {"type": "number"},
        "pan": {"type": "number", "minimum": -1, "maximum": 1},
        "mute": {"type": "boolean"},
        "solo": {"type": "boolean"},
        "source_indices": {"type": "array", "items": {"type": "integer", "minimum": 0}},
    }, ["action"]),
    lambda b, a: {
        "list": lambda: b.call("list_tracks"),
        "add": lambda: b.call("add_track", [a.get("name"), a.get("index")]),
        "delete": lambda: b.call("delete_track", [a["index"]]),
        "update": lambda: b.call("update_track", [a["index"], _props(
            a, ("name", "volume_db", "pan", "mute", "solo"))]),
        "bus": lambda: b.call("create_bus", [a.get("name"), a.get("source_indices") or []]),
    }[a["action"]](),
)

tool(
    "midi",
    "MIDI on a track item. Times are absolute project beats. "
    "action: create_item | add | get | replace | update | delete | cc | get_cc. "
    "replace rewrites the whole take in one undo step; add only appends. "
    "cc inserts CC (`cc`+`value`) or program change (`program`) via ccs[]; get_cc reads CC, program and "
    "pitch_bend back in that shape. "
    "get omits index (use array offset), channel if 0, muted/selected if false.",
    obj({
        "action": {"type": "string",
                   "enum": ["create_item", "add", "get", "replace", "update", "delete", "cc", "get_cc"]},
        "track_index": {"type": "integer", "minimum": 0},
        "item_index": {"type": "integer", "minimum": 0},
        "start_beats": {"type": "number", "minimum": 0},
        "length_beats": {"type": "number", "minimum": 0},
        "notes": {"type": "array", "items": NOTE},
        "ccs": {"type": "array", "items": CC},
        "note_index": {"type": "integer", "minimum": 0},
        "note_indices": {"type": "array", "items": {"type": "integer", "minimum": 0}},
        "pitch": {"type": "integer", "minimum": 0, "maximum": 127},
        "velocity": {"type": "integer", "minimum": 1, "maximum": 127},
        "channel": {"type": "integer", "minimum": 0, "maximum": 15},
        "muted": {"type": "boolean"},
    }, ["action", "track_index"]),
    lambda b, a: {
        "create_item": lambda: b.call("create_midi_item", [
            a["track_index"], a.get("start_beats", 0), a.get("length_beats", 4)]),
        "add": lambda: b.call("add_midi_notes",
                              [a["track_index"], a["item_index"], a["notes"]]),
        "get": lambda: b.call("get_midi_notes", [a["track_index"], a["item_index"]]),
        "replace": lambda: b.call("replace_midi_notes",
                                  [a["track_index"], a["item_index"], a["notes"]]),
        "update": lambda: b.call("update_midi_note", [
            a["track_index"], a["item_index"], a["note_index"],
            _props(a, ("pitch", "start_beats", "length_beats",
                       "velocity", "channel", "muted"))]),
        "delete": lambda: b.call("delete_midi_notes",
                                 [a["track_index"], a["item_index"], a["note_indices"]]),
        "cc": lambda: b.call("add_midi_cc",
                             [a["track_index"], a["item_index"], a.get("ccs") or []]),
        "get_cc": lambda: b.call("get_midi_cc", [a["track_index"], a["item_index"]]),
    }[a["action"]](),
)

tool(
    "fx",
    "Track FX. action: list | add | params | set | delete | bypass | move | preset. "
    "params takes filter (case-insensitive part of the parameter name) to list only matching ones. "
    "track_index -1 is the master. set takes value 0..1 (REAPER normalized) or formatted: the value as the "
    "plugin displays it (number in its unit, e.g. -18 for dB, 4 for 4:1, 120 for ms; or a label like "
    "\"3.2k\"), resolved by searching the display text. set returns the formatted value actually set.",
    obj({
        "action": {"type": "string",
                   "enum": ["list", "add", "params", "set", "delete", "bypass", "move", "preset"]},
        "track_index": {"type": "integer", "minimum": -1},
        "fx_index": {"type": "integer", "minimum": 0},
        "fx_name": {"type": "string"},
        "param": {"type": ["string", "integer"]},
        "value": {"type": "number"},
        "formatted": {"type": ["string", "number"]},
        "enabled": {"type": "boolean"},
        "dest_index": {"type": "integer", "minimum": 0},
        "preset": {"type": "string"},
        "filter": {"type": "string"},
    }, ["action", "track_index"]),
    lambda b, a: {
        "list": lambda: b.call("list_track_fx", [a["track_index"]]),
        "add": lambda: b.call("add_track_fx", [a["track_index"], a["fx_name"]]),
        "params": lambda: b.call("get_fx_params", [a["track_index"], a["fx_index"], a.get("filter")]),
        "set": lambda: b.call("set_fx_param",
                              [a["track_index"], a["fx_index"], a["param"], a.get("value"),
                               a.get("formatted")]),
        "delete": lambda: b.call("delete_track_fx", [a["track_index"], a["fx_index"]]),
        "bypass": lambda: b.call("set_fx_enabled",
                                 [a["track_index"], a["fx_index"], a.get("enabled", False)]),
        "move": lambda: b.call("move_track_fx",
                               [a["track_index"], a["fx_index"], a["dest_index"]]),
        "preset": lambda: b.call("set_fx_preset",
                                 [a["track_index"], a["fx_index"], a.get("preset", "")]),
    }[a["action"]](),
)

tool(
    "send",
    "Track sends. action: list | add | delete | update. "
    "track_index is the source (-1 master). dest_index is the destination track. "
    "add/update take volume_db, pan, mute, mode (post_fader | pre_fader | pre_fx) and channel routing: "
    "src_channel / dst_channel = first channel of the stereo pair, 0-based (dst_channel 2 = channels 3/4, a "
    "compressor's sidechain input; the destination's channel count is raised to fit).",
    obj({
        "action": {"type": "string", "enum": ["list", "add", "delete", "update"]},
        "track_index": {"type": "integer", "minimum": -1},
        "send_index": {"type": "integer", "minimum": 0},
        "dest_index": {"type": "integer", "minimum": -1},
        "volume_db": {"type": "number"},
        "pan": {"type": "number", "minimum": -1, "maximum": 1},
        "mute": {"type": "boolean"},
        "mode": {"type": "string", "enum": ["post_fader", "pre_fader", "pre_fx"]},
        "src_channel": {"type": "integer", "minimum": 0, "maximum": 62},
        "dst_channel": {"type": "integer", "minimum": 0, "maximum": 62},
    }, ["action", "track_index"]),
    lambda b, a: {
        "list": lambda: b.call("list_sends", [a["track_index"]]),
        "add": lambda: b.call("add_send", [a["track_index"], a["dest_index"],
                                           _props(a, SEND_PROPS) or None]),
        "delete": lambda: b.call("delete_send", [a["track_index"], a["send_index"]]),
        "update": lambda: b.call("update_send", [a["track_index"], a["send_index"],
                                                 _props(a, SEND_PROPS)]),
    }[a["action"]](),
)

FADE_SHAPES = ["linear", "fast_start", "fast_end", "fast_start_steep", "fast_end_steep", "s_curve", "s_curve_steep"]
ITEM_PROPS = ("gain_db", "fade_in_sec", "fade_out_sec", "fade_in_shape", "fade_out_shape", "loop", "mute",
              "position_beats", "length_beats", "left_edge_beats", "dest_track_index", "active_take")

tool(
    "item",
    "Media items on a track. action: list | update | import | split | delete | duplicate. "
    "Times are beats except fade_in_sec / fade_out_sec (seconds, REAPER native). "
    "update: gain_db, fades and fade_*_shape, loop, mute, position_beats (move), length_beats (trim the end), "
    "left_edge_beats (trim or extend the start; the content stays in place), dest_track_index (move to another "
    "track; returns the new indices), active_take. list shows take name, source file and take count. "
    "split cuts at at_beats (inside the item) and returns the pieces' item_indices. delete takes item_index or "
    "item_indices. duplicate copies the item (unpooled) to position_beats (default: right after it), optionally "
    "on dest_track_index. import uses a path already on the REAPER host; as_new_track=true makes new tracks. "
    "Item indices follow position, so re-list after edits that move items.",
    obj({
        "action": {"type": "string", "enum": ["list", "update", "import", "split", "delete", "duplicate"]},
        "track_index": {"type": "integer", "minimum": 0},
        "item_index": {"type": "integer", "minimum": 0},
        "item_indices": {"type": "array", "items": {"type": "integer", "minimum": 0}},
        "gain_db": {"type": "number"},
        "fade_in_sec": {"type": "number", "minimum": 0},
        "fade_out_sec": {"type": "number", "minimum": 0},
        "fade_in_shape": {"type": "string", "enum": FADE_SHAPES},
        "fade_out_shape": {"type": "string", "enum": FADE_SHAPES},
        "loop": {"type": "boolean"},
        "mute": {"type": "boolean"},
        "position_beats": {"type": "number", "minimum": 0},
        "length_beats": {"type": "number", "minimum": 0},
        "left_edge_beats": {"type": "number", "minimum": 0},
        "dest_track_index": {"type": "integer", "minimum": 0},
        "active_take": {"type": "integer", "minimum": 0},
        "at_beats": {"type": "array", "items": {"type": "number", "minimum": 0}},
        "start_beats": {"type": "number", "minimum": 0},
        "path": {"type": "string"},
        "as_new_track": {"type": "boolean"},
    }, ["action"]),
    lambda b, a: {
        "list": lambda: b.call("list_items", [a["track_index"]]),
        "update": lambda: b.call("update_item", [a["track_index"], a["item_index"], _props(a, ITEM_PROPS)]),
        "split": lambda: b.call("split_item", [a["track_index"], a["item_index"], a["at_beats"]]),
        "delete": lambda: b.call("delete_items", [a["track_index"], a.get("item_indices")
                                                  or [a["item_index"]]]),
        "duplicate": lambda: b.call("duplicate_item", [a["track_index"], a["item_index"],
                                                       _props(a, ("position_beats", "dest_track_index")) or None]),
        "import": lambda: b.call("import_media", [a.get("path"), {
            "track_index": a.get("track_index"),
            "start_beats": a.get("start_beats"),
            "as_new_track": a.get("as_new_track", False),
        }]),
    }[a["action"]](),
)

tool(
    "envelope",
    "Track envelopes. action: list | get | set. "
    "name is REAPER envelope name (Volume, Pan, Mute, ...). "
    "set replaces all points, or with start_beats / end_beats only the points in that range (ends included; "
    "every new point must lie inside it); get with a range returns only those points. value is the envelope's value; Volume is linear gain (1.0 = 0 dB, "
    "0.5 = -6 dB), also on fader-scaled envelopes. unit=db reads/writes volume-type envelopes "
    "(Volume, Trim Volume, send Volume) in dB. set re-activates an envelope left inactive (ACT 0).",
    obj({
        "action": {"type": "string", "enum": ["list", "get", "set"]},
        "track_index": {"type": "integer", "minimum": -1},
        "name": {"type": "string"},
        "envelope_index": {"type": "integer", "minimum": 0},
        "unit": {"type": "string", "enum": ["gain", "db"]},
        "start_beats": {"type": "number", "minimum": 0},
        "end_beats": {"type": "number", "minimum": 0},
        "points": {"type": "array", "items": {
            "type": "object",
            "properties": {
                "beats": {"type": "number"},
                "value": {"type": "number"},
                "shape": {"type": "integer"},
                "tension": {"type": "number"},
                "selected": {"type": "boolean"},
            },
            "required": ["beats", "value"],
        }},
    }, ["action", "track_index"]),
    lambda b, a: {
        "list": lambda: b.call("list_envelopes", [a["track_index"]]),
        "get": lambda: b.call("get_envelope",
                              [a["track_index"], a.get("name", a.get("envelope_index", 0)),
                               a.get("unit"), _props(a, ("start_beats", "end_beats")) or None]),
        "set": lambda: b.call("set_envelope",
                              [a["track_index"], a.get("name", a.get("envelope_index", 0)),
                               a.get("points") or [], a.get("unit"),
                               _props(a, ("start_beats", "end_beats")) or None]),
    }[a["action"]](),
)

tool(
    "project",
    "Project-level edits. action: tempo | time_signature | time_selection | marker | save. "
    "save with path creates missing folders and writes a copy (no dialog); an untitled project adopts that path. save without path needs an already-named project.",
    obj({
        "action": {"type": "string",
                   "enum": ["tempo", "time_signature", "time_selection", "marker", "save"]},
        "bpm": {"type": "number", "minimum": 1},
        "numerator": {"type": "integer", "minimum": 1},
        "denominator": {"type": "integer", "minimum": 1},
        "start_beats": {"type": "number", "minimum": 0},
        "end_beats": {"type": "number", "minimum": 0},
        "position_beats": {"type": "number", "minimum": 0},
        "name": {"type": "string"},
        "is_region": {"type": "boolean"},
        "region_end_beats": {"type": "number", "minimum": 0},
        "path": {"type": "string"},
    }, ["action"]),
    lambda b, a: {
        "tempo": lambda: b.call("set_tempo", [a["bpm"]]),
        "time_signature": lambda: b.call("set_time_signature",
                                         [a["numerator"], a["denominator"]]),
        "time_selection": lambda: b.call("set_time_selection",
                                         [a["start_beats"], a["end_beats"]]),
        "marker": lambda: b.call("add_marker", [
            a["position_beats"], a.get("name", ""), a.get("is_region", False),
            a.get("region_end_beats")]),
        "save": lambda: b.call("save_project", [a.get("path")]),
    }[a["action"]](),
)

tool(
    "render",
    "Render. No undo. Long timeout. "
    "bounds: project | time_selection | custom | items. "
    "Default: the master mix. stems=true renders the selected tracks as stems instead (pass track_indices to "
    "select them). path is the output folder; the file name comes from pattern. "
    "Sets all media online (action 40101) first unless media_online=false. Refuses when a target file "
    "already exists (REAPER's overwrite prompt would hang the bridge) and when tracks are soloed (pass "
    "allow_solo=true, or solo_indices / mute_indices to solo/mute tracks for this render only; they are "
    "restored afterwards). Returns files [{path, bytes, length_sec, peak_db, lufs_i}] and warnings "
    "(near-silent, missing file, master muted); measure=false skips the loudness scan. "
    "format wav (bit_depth 16 | 24 | 32 = float) or mp3 (320 kbps) sets the file type for this render only; "
    "without it the project's render format is used.",
    obj({
        "path": {"type": "string"},
        "bounds": {"type": "string",
                   "enum": ["project", "time_selection", "custom", "items"]},
        "start_beats": {"type": "number", "minimum": 0},
        "end_beats": {"type": "number", "minimum": 0},
        "stems": {"type": "boolean"},
        "track_indices": {"type": "array", "items": {"type": "integer", "minimum": 0}},
        "sample_rate": {"type": "integer", "minimum": 1},
        "channels": {"type": "integer", "minimum": 1},
        "pattern": {"type": "string"},
        "solo_indices": {"type": "array", "items": {"type": "integer", "minimum": 0}},
        "mute_indices": {"type": "array", "items": {"type": "integer", "minimum": 0}},
        "allow_solo": {"type": "boolean"},
        "media_online": {"type": "boolean"},
        "measure": {"type": "boolean"},
        "format": {"type": "string", "enum": ["wav", "mp3"]},
        "bit_depth": {"type": "integer", "enum": [16, 24, 32]},
    }),
    lambda b, a: b.call("render_project", [a.get("path"), {
        "bounds": a.get("bounds") or "project",
        "start_beats": a.get("start_beats"),
        "end_beats": a.get("end_beats"),
        "stems": a.get("stems"),
        "track_indices": a.get("track_indices"),
        "sample_rate": a.get("sample_rate"),
        "channels": a.get("channels"),
        "pattern": a.get("pattern"),
        "solo_indices": a.get("solo_indices"),
        "mute_indices": a.get("mute_indices"),
        "allow_solo": a.get("allow_solo"),
        "media_online": a.get("media_online"),
        "measure": a.get("measure"),
        "format": a.get("format"),
        "bit_depth": a.get("bit_depth"),
    }], timeout=RENDER_TIMEOUT),
)

tool(
    "action",
    "Run a REAPER Main_OnCommand by numeric command id.",
    obj({"command_id": {"type": "integer"}}, ["command_id"]),
    lambda b, a: b.call("action", [a["command_id"]]),
)

tool(
    "reaper_call",
    "Call any ReaScript function by name. Pointers come back as {\"__handle\":\"hN\"} "
    "and can be passed back in. Example: func=CountTracks args=[0].",
    obj({"func": {"type": "string"}, "args": {"type": "array"}}, ["func"]),
    lambda b, a: b.call(a["func"], a.get("args", [])),
)

tool(
    "run_lua",
    "Run a Lua snippet inside REAPER (`reaper` in scope). Use return to send a value. "
    "Best for multi-step work that would otherwise be many round-trips. Errors carry the failing line. "
    "timeout (seconds, default 10, max 600): a snippet still running Lua after it is stopped with an error "
    "(what it did until then stays done); a call blocked inside REAPER (ExecProcess, a render, a dialog) can't "
    "be stopped. REAPER is frozen while it runs, so start long host commands in the background "
    "(io.popen('cmd > log 2>&1 &')) and poll instead.",
    obj({"code": {"type": "string"},
         "timeout": {"type": "number", "minimum": 1, "maximum": RUN_LUA_MAX_TIMEOUT}}, ["code"]),
    lambda b, a: b.call("run_lua", code=a["code"], timeout=_run_lua_timeout(a) + RUN_LUA_GRACE,
                        lua_timeout=_run_lua_timeout(a)),
)

tool(
    "batch",
    "Many operations in one IPC hop and one undo point. Each call is {func, args} or {func: 'run_lua', code, "
    "timeout} or {func, arguments} for a grouped tool name (track/midi/fx/...). "
    "Each slot is the inner result, or {error}. There is no rollback: by default one failure does not abort the "
    "rest; stop_on_error=true skips the slots after the first failure ({skipped: true}). "
    "Handles from earlier calls work later.",
    obj({"calls": {"type": "array", "items": obj({
        "func": {"type": "string"},
        "args": {"type": "array"},
        "arguments": {"type": "object"},
        "code": {"type": "string"},
        "timeout": {"type": "number", "minimum": 1, "maximum": RUN_LUA_MAX_TIMEOUT},
        "action": {"type": "string"}},
        ["func"])},
         "stop_on_error": {"type": "boolean"}},
        ["calls"]),
    lambda b, a: _build_batch(b, a),
)


def _build_batch(bridge, a):
    calls, timeout = _normalize_batch(a["calls"])
    args = [calls, {"stop_on_error": True}] if a.get("stop_on_error") else [calls]
    return bridge.call("batch", args, timeout=timeout)


def _expand_grouped(func, arguments):
    """Turn a grouped MCP tool invocation into a DSL/bridge call.

    Returns (call, timeout); a batch of renders needs the render budget, not the
    ordinary bridge timeout.
    """
    spec = TOOL_INDEX.get(func)
    if spec is None or func in ("batch", "reaper_call", "run_lua"):
        return None, None
    capture = _BatchCapture()
    return spec["_builder"](capture, arguments), capture.timeout


class _BatchCapture:
    def __init__(self) -> None:
        self.timeout = None

    def call(self, func, args=None, code=None, timeout=None, lua_timeout=None):
        if timeout is not None:
            self.timeout = (self.timeout or 0.0) + timeout
        call = {"func": func}
        if code is not None:
            call["code"] = code
        else:
            call["args"] = args or []
        return call


def _normalize_batch(calls):
    out = []
    timeout = None
    for original in calls:
        call = dict(original)
        func = call.get("func")
        arguments = call.get("arguments")
        if arguments is None and "action" in call:
            arguments = {k: v for k, v in call.items() if k != "func"}
        expanded = None
        call_timeout = None
        if isinstance(arguments, dict):
            try:
                expanded, call_timeout = _expand_grouped(func, arguments)
            except KeyError as e:  # one bad slot reports its own error; the rest still run
                expanded = {"func": "run_lua", "code": "error(%s, 0)" % json.dumps("missing argument: %s" % e.args[0])}
        if expanded is not None:
            out.append(expanded)
        else:
            out.append(call)
            if func == "render_project":
                call_timeout = RENDER_TIMEOUT
            elif func == "run_lua":
                lt = _run_lua_timeout(call)
                call["timeout"] = lt
                call_timeout = lt + RUN_LUA_GRACE
        if call_timeout:
            timeout = (timeout or 0.0) + call_timeout
    return out, timeout


TOOL_INDEX = {t["name"]: t for t in TOOLS}


def make_result(rid, result):
    return {"jsonrpc": "2.0", "id": rid, "result": result}


def make_error(rid, code, message):
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def handle_request(bridge, msg):
    method = msg.get("method")
    rid = msg.get("id")
    params = msg.get("params") or {}

    if method == "initialize":
        return make_result(rid, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": instructions(),
        })
    if method == "ping":
        return make_result(rid, {})
    if method in ("notifications/initialized", "notifications/cancelled"):
        return None if rid is None else make_result(rid, {})
    if method == "tools/list":
        return make_result(rid, {
            "tools": [{"name": t["name"], "description": t["description"],
                       "inputSchema": t["inputSchema"]} for t in TOOLS],
        })
    if method == "resources/list":
        return make_result(rid, {"resources": []})
    if method == "prompts/list":
        return make_result(rid, {"prompts": []})
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        spec = TOOL_INDEX.get(name)
        if not spec:
            return make_error(rid, -32602, f"unknown tool: {name}")
        try:
            ret = spec["_builder"](bridge, args)
            text = json.dumps(ret, ensure_ascii=False, separators=(",", ":")) \
                if not isinstance(ret, str) else ret
            return make_result(rid, {
                "content": [{"type": "text", "text": text}],
            })
        except Exception as e:  # noqa: BLE001 - BridgeError and builder errors alike go back as tool errors
            text = "missing argument: %s" % e.args[0] if isinstance(e, KeyError) else str(e)
            return make_result(rid, {
                "content": [{"type": "text", "text": text}],
                "isError": True,
            })
    if rid is None:
        return None
    return make_error(rid, -32601, f"method not found: {method}")


def main():
    for stream in (sys.stdin, sys.stdout):
        try:
            stream.reconfigure(encoding="utf-8", newline="\n")
        except (AttributeError, ValueError):
            pass
    bridge = Bridge()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if not isinstance(msg, dict):
            response = make_error(None, -32600, "expected a single JSON-RPC request object")
        else:
            try:
                response = handle_request(bridge, msg)
            except Exception as e:  # noqa: BLE001
                response = make_error(msg.get("id"), -32603, f"internal error: {e}")
            if msg.get("id") is None:
                response = None
        if response is not None:
            sys.stdout.write(json.dumps(response, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
