#!/usr/bin/env python3
"""Headless tests for panel/Hibiki.lua: the real panel code with fake reaper/ImGui APIs.

curl never runs: the panel's shell calls are recorded, and the test answers a request by writing the .out/.done
files the panel polls, or appends SSE text to the stream file, the same way the background curl would.

    uv run --with lupa python panel/test_panel.py
    uv run --with lupa python panel/test_panel.py --bench   # per-frame cost, HEAD vs working copy
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile
from pathlib import Path

PANEL = Path(__file__).resolve().parent / "Hibiki.lua"
GATEWAY = "http://127.0.0.1:47892"
GAMUT = "http://127.0.0.1:47891"

FAKES = r"""
EXT_STATE, CMDS, UI, RET = {}, {}, {}, {}
RECORD = true
OS_NAME = OS_NAME or 'macOS-arm64'
NOW = 1000.0
HIBIKI_TEST = {
  sh = function(cmd)
    CMDS[#CMDS + 1] = cmd
    if cmd:find('curl -s -N', 1, true) then return '4242\n' end
    return ''
  end,
}
local function nop() end
reaper = setmetatable({
  ImGui_GetBuiltinPath = function() return '/nonexistent' end,
  GetExtState = function(sec, key) return EXT_STATE[sec .. '/' .. key] or '' end,
  SetExtState = function(sec, key, v) EXT_STATE[sec .. '/' .. key] = v end,
  DeleteExtState = function(sec, key) EXT_STATE[sec .. '/' .. key] = nil end,
  time_precise = function() return NOW end,
  get_action_context = function() return false, '', 0, 0 end,
  GetResourcePath = function() return '/nonexistent' end,
  GetOS = function() return OS_NAME end,
  GetLastColorThemeFile = function() return '' end,
  EnumProjects = function() return 0, '' end,
  GetProjectName = function() return 'Song.RPP' end,
  GetPlayState = function() return 0 end,
  GetCursorPosition = function() return 0.0 end,
  Master_GetTempo = function() return 120.0 end,
  TimeMap_GetTimeSigAtTime = function() return 4, 4, 120.0 end,
  TimeMap2_timeToBeats = function() return 0, 0, 4, 0, 4 end,
  TimeMap2_timeToQN = function() return 0 end,
  GetSet_LoopTimeRange = function() return 0, 0 end,
  GetSet_LoopTimeRange2 = function() return 0, 0 end,
  CountTracks = function() return 0 end,
  CountSelectedTracks = function() return 0 end,
  CountSelectedMediaItems = function() return 0 end,
  MIDIEditor_GetActive = function() return nil end,
  GetFocusedFX2 = function() return 0, 0, 0, 0 end,
  GetFocusedFX = function() return 0, 0, 0, 0 end,
  GetLastTouchedTrack = function() return nil end,
  GetLastMarkerAndCurRegion = function() return -1, -1 end,
}, { __index = function(_, k) return nop end })

local flag = 1
ImGui = setmetatable({}, { __index = function(t, k)
  local v
  if k:find('_') and not k:find('^DrawList_') and not k:find('^Function_') then
    v = flag; flag = flag * 2 -- an enum value; distinct bits so OR-ed flags stay readable
  else
    v = function(...)
      if RECORD then UI[#UI + 1] = { name = k, args = table.pack(...) } end
      local r = RET[k]
      if r then return r(...) end
    end
  end
  rawset(t, k, v)
  return v
end })
package.preload.imgui = function() return function() return ImGui end end
-- fonts are distinct objects; text is 7 px per character
RET.CreateFont = function(name, flags) return { font = name, flags = flags } end
RET.CalcTextSize = function(_, s) return 7 * (utf8.len(s) or #s), 14 end
RET.GetFontSize = function() return 14 end

-- a log child 400 px wide: items advance the cursor by their height + 6 px item spacing, like ImGui
function LAYOUT(width, height)
  local L = { y = 0, scroll = 0, w = width or 400, h = height or 600 }
  local function adv(h) L.y = L.y + h + 6 end
  RET.GetCursorPosY = function() return L.y end
  RET.GetCursorScreenPos = function() return 0, L.y - L.scroll end
  RET.GetContentRegionAvail = function() return L.w, L.h end
  RET.GetScrollY = function() return L.scroll end
  RET.GetWindowHeight = function() return L.h end
  RET.GetWindowPos = function() return 0, 0 end
  RET.GetWindowSize = function() return L.w, L.h end
  RET.GetTextLineHeight = function() return 14 end
  RET.GetMousePos = function() return -1, -1 end
  RET.GetStyleVar = function() return 8, 6 end
  RET.Dummy = function(_, w, h) adv(h) end
  RET.InvisibleButton = function(_, id, w, h) adv(h) end
  RET.Spacing = function() adv(0) end
  RET.Text = function() adv(14) end
  RET.TextColored = RET.Text
  RET.TextDisabled = RET.Text
  return L
end

function OPS_EQUAL(a, b)
  if #a ~= #b then return false, 'op count ' .. #a .. ' vs ' .. #b end
  for i = 1, #a do
    local x, y = a[i], b[i]
    for k = 1, 7 do if x[k] ~= y[k] then return false, ('op %d field %d: %s vs %s'):format(i, k, tostring(x[k]), tostring(y[k])) end end
    if (x.nl or false) ~= (y.nl or false) then return false, 'op ' .. i .. ' nl' end
  end
  return true, ''
end
"""

failures: list[str] = []
OS_NAME = "macOS-arm64"  # main() runs every test once per OS


def check(label, cond, extra=""):
    print(("  PASS " if cond else "  FAIL ") + label + ("" if cond else "  " + str(extra)))
    if not cond:
        failures.append(label)


# one quoted shell argument: '...' on macOS, "..." in the Windows cmd.exe lines
QA = r"""['"]([^'"]+)['"]"""


class Request:
    def __init__(self, cmd):
        self.cmd = cmd
        self.stream = re.search(r"curl(\.exe['\"])? -s -N", cmd) is not None
        self.url = re.findall(r"""['"](https?://[^'"]+)['"]""", cmd)[0]
        m = re.search(r"-X (\w+)", cmd)
        self.method = m.group(1) if m else ("GET" if self.stream else "POST")
        m = re.search(r"-o " + QA, cmd)
        self.base = m.group(1)[:-4] if m else None
        m = re.search(r"--data-binary @" + QA, cmd)
        self.body = json.loads(Path(m.group(1)).read_text(encoding="utf-8")) if m else None
        m = re.search(r"-H @" + QA, cmd)
        self.auth = Path(m.group(1)).read_text(encoding="utf-8") if m else None

    def __repr__(self):
        return "%s %s" % (self.method, self.url)


class Panel:
    """One fresh panel run. ext: saved ExtState (Hibiki/<key>); token: the gateway token file's content."""

    def __init__(self, ext=None, token=None, env=None, src=None):
        import lupa

        self.tmp = Path(tempfile.mkdtemp())
        for k in ("TMPDIR", "TEMP", "TMP", "HOME", "USERPROFILE"):
            os.environ[k] = str(self.tmp)
        for k, v in (env or {}).items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        (self.tmp / "hibiki").mkdir()
        if token is not None:
            (self.tmp / ".config/agent-gateway").mkdir(parents=True)
            (self.tmp / ".config/agent-gateway/token").write_text(token + "\n")
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().OS_NAME = OS_NAME
        self.lua.execute(FAKES)
        self.lua.globals().HIBIKI_TEST.dir = str(PANEL.parent) + os.sep  # loads panel/studio.lua next to it
        self.lua.globals().MKDIR = lambda d: os.makedirs(d, exist_ok=True)  # mkdir -p doesn't exist on a Windows host
        state = self.lua.globals().EXT_STATE
        for k, v in {"ctx_level": "0", **(ext or {})}.items():
            state["Hibiki/" + k] = v
        self.m = self.lua.execute(src or PANEL.read_text(encoding="utf-8"))
        self.S = self.m.S
        self.seen = 0

    def requests(self):
        """Commands issued since the last call, parsed."""
        cmds = self.lua.globals().CMDS
        out = []
        while self.seen < len(cmds):
            self.seen += 1
            cmd = cmds[self.seen]
            if "/usr/bin/curl" in cmd or "curl.exe" in cmd:
                out.append(Request(cmd))
        return out

    def reply(self, req, code, body=""):
        Path(req.base + ".out").write_text(body if isinstance(body, str) else json.dumps(body))
        Path(req.base + ".done").write_text(str(code))
        self.m.poll_http()

    def sse(self, *events):
        with open(self.S.stream.file, "a") as f:
            for e in events:
                f.write("event: message\ndata: " + json.dumps(e) + "\n\n")
        self.m.poll_stream()

    def boot(self, agents=None):
        """Answer the startup agent list from the gateway; returns the requests that followed."""
        (req,) = self.requests()
        self.reply(req, 200, agents or [{"slug": "acp-fake", "name": "Fake", "backend": "acp"}])
        return self.requests()

    def type_and_send(self, text):
        self.S.input = text
        self.m.send()
        return self.requests()

    def lua_list(self, t):
        return [t[i] for i in range(1, len(t) + 1)]


def find(reqs, method, suffix):
    return [r for r in reqs if r.method == method and r.url.endswith(suffix)]


SESSION = {"agent": "acp-fake", "agent_name": "Fake", "session_acp-fake": "s1"}


def test_json():
    p = Panel()
    d = p.m.decode('{"a":[1,2.5e3,-3],"s":"\\ud83c\\udfb5 \\n\\"x\\"","t":true,"f":false,"o":{}}')
    check("json: numbers, nested arrays and objects",
          d.a[1] == 1 and d.a[2] == 2500 and d.a[3] == -3 and d.t is True and d.f is False)
    check("json: surrogate pair, newline and quote escapes", d.s == '\U0001f3b5 \n"x"', d.s)
    check("json: bad input is nil, not an error", p.m.decode('{"a":') is None and p.m.decode("") is None)
    s = 'tab\there "q" back\\slash \x01 ctrl 中'
    check("json: jstr round-trips control characters and UTF-8", p.m.decode(p.m.jstr(s)) == s)


def test_gateway_token():
    p = Panel(token="tok-123")
    (req,) = p.requests()
    check("token: gateway request carries the header file", req.url.startswith(GATEWAY)
          and req.auth == "Authorization: Bearer tok-123\n", req.auth)
    check("token: never on the command line", "tok-123" not in req.cmd)
    p.reply(req, 0)
    (fallback,) = p.requests()
    check("token: not sent to Gamut's own API", fallback.url.startswith(GAMUT) and fallback.auth is None)


def test_boot_with_hosts_down():
    p = Panel(SESSION)
    (req,) = p.requests()
    p.reply(req, 0)
    (req,) = p.requests()
    p.reply(req, 0)
    check("boot down: error shown, no stream yet", p.S.agents_err is not None and not p.requests())
    p.m.load_agents()
    reqs = p.boot()
    check("boot down: next successful load reopens the saved session",
          any(r.stream and r.url.endswith("/sessions/s1/stream") for r in reqs)
          and find(reqs, "GET", "/sessions/s1/messages"), reqs)


def test_connect_after_turn_ended():
    p = Panel(SESSION)
    p.boot()
    p.requests()
    p.sse({"type": "connected", "isActive": False})  # the turn finished while the stream was reconnecting
    msgs = find(p.requests(), "GET", "/sessions/s1/messages")
    check("idle connect: transcript reloaded", msgs)
    if msgs:
        p.reply(msgs[0], 200, [{"type": "user", "content": {"text": "hi"}},
                               {"type": "assistant", "content": {"text": "the reply"}, "toolCalls": []}])
    check("idle connect: the finished reply appears", len(p.S.msgs) == 2 and p.S.msgs[2].text == "the reply"
          and not p.S.active)
    p.sse({"type": "session_error", "apiErrorCode": "acp_error", "errorPresentation": {"message": "Fake: quota"}})
    check("idle connect: a replayed error is shown with its code", p.S.err == "Fake: quota (acp_error)", p.S.err)


def test_connect_mid_turn_uses_replay():
    p = Panel(SESSION)
    p.boot()
    p.sse({"type": "connected", "isActive": True}, {"type": "stream_delta", "text": "so far"})
    check("mid-turn connect: live view rebuilt from the replay, no reload",
          p.S.live[1].text == "so far" and p.S.active and not find(p.requests(), "GET", "/messages"))


def test_session_error_code_and_resume():
    p = Panel(SESSION)
    p.boot()
    p.sse({"type": "connected", "isActive": False})
    p.requests()
    sent = find(p.type_and_send("louder kick"), "POST", "/sessions/s1/messages")
    p.reply(sent[0], 200, {"ok": True})
    ext = p.lua.globals().EXT_STATE
    turn = ext["Hibiki/turn"]
    p.sse({"type": "stream_delta", "text": "working on it"},
          {"type": "session_error", "error": "Connection lost", "apiErrorCode": None,
           "terminalReason": "connection_lost", "isActive": False})
    p.requests()
    check("session_error: message and code shown", p.S.err == "Connection lost (connection_lost)", p.S.err)
    check("session_error: the reply's studio turn stays open", turn and ext["Hibiki/turn"] == turn, ext["Hibiki/turn"])
    p.sse({"type": "stream_delta", "text": " again"})
    check("session_error then more output: the turn runs on, the error becomes a note in the reply",
          p.S.active and p.S.err is None and ext["Hibiki/turn"] == turn
          and any("connection_lost" in (b.text or "") and "resumed" in b.text for b in p.lua_list(p.S.live)),
          [b.text for b in p.lua_list(p.S.live)])
    p.sse({"type": "session_idle"})
    check("session_idle after a resume closes the turn", ext["Hibiki/turn"] == "" and not p.S.active)

    p.sse({"type": "session_error", "apiErrorCode": "rate_limited", "errorPresentation": {"message": "Slow down"}})
    check("presentation message + api code", p.S.err == "Slow down (rate_limited)", p.S.err)
    p.sse({"type": "session_error", "apiErrorStatus": 529})
    check("bare status still says something", p.S.err == "HTTP 529", p.S.err)

    sent = find(p.type_and_send("again"), "POST", "/sessions/s1/messages")
    p.reply(sent[0], 200, {"ok": True})
    p.sse({"type": "session_error", "error": "Died"})
    check("errored turn kept open", ext["Hibiki/turn"] != "")
    p.lua.globals().NOW = p.lua.globals().NOW + 200
    p.m.frame()
    check("errored turn that never resumes is closed after the wait", ext["Hibiki/turn"] == "" and p.S.err == "Died")


def test_follow_up_mid_reply():
    p = Panel(SESSION)
    p.boot()
    p.sse({"type": "connected", "isActive": True}, {"type": "stream_delta", "text": "part one"})
    p.requests()
    reqs = p.type_and_send("second question")
    sent = find(reqs, "POST", "/sessions/s1/messages")
    check("follow-up: posted to the running session", sent and sent[0].body["content"] == "second question", reqs)
    check("follow-up: reply in progress kept, message queued below it",
          p.S.live[1].text == "part one" and len(p.S.queued) == 1 and p.S.queued[1].text == "second question")
    p.reply(sent[0], 200, {"ok": True})
    p.sse({"type": "stream_delta", "text": ", done"}, {"type": "session_active"})
    roles = [(m.role, m.text) for m in p.lua_list(p.S.msgs)]
    check("follow-up: next turn settles the reply above the question",
          roles[-2:] == [("assistant", "part one, done"), ("user", "second question")] and len(p.S.live) == 0
          and len(p.S.queued) == 0, roles)


def test_failed_send_hands_text_back():
    p = Panel(SESSION)
    p.boot()
    p.sse({"type": "connected", "isActive": False})
    p.requests()
    reqs = p.type_and_send("hello there")
    check("failed send: input cleared while sending", p.S.input == "")
    p.reply(find(reqs, "POST", "/sessions/s1/messages")[0], 500, {"error": "boom"})
    texts = [m.text for m in p.lua_list(p.S.msgs)]
    check("failed send: text back in the input, bubble removed, error shown",
          p.S.input == "hello there" and "hello there" not in texts and p.S.err == "send failed (500)"
          and not p.S.active, (p.S.input, texts, p.S.err))


def test_new_chat_login_hands_text_back():
    p = Panel({"agent": "acp-fake", "agent_name": "Fake"})
    p.boot()
    reqs = p.type_and_send("first message")
    create = find(reqs, "POST", "/api/agents/acp-fake/sessions")
    p.reply(create[0], 401, {"error": "auth_required"})
    check("login needed: text back in the input", p.S.input == "first message" and "login" in p.S.err, p.S.err)


def test_title_skips_context_block():
    p = Panel({"agent": "acp-fake", "agent_name": "Fake", "ctx_level": "1"})
    p.boot()
    reqs = p.type_and_send("make the drums louder")
    body = find(reqs, "POST", "/api/agents/acp-fake/sessions")[0].body
    check("title: message carries the REAPER context, title is the typed text",
          body["message"].startswith("[REAPER context") and body["title"] == "make the drums louder", body)


def test_script_card_shows_script():
    p = Panel(SESSION)
    p.boot()
    q = p.lua.table_from({"id": "r1", "kind": "script_run",
                          "payload": p.lua.table_from({"script": "curl x | sh", "explanation": "Check version"})})
    p.m.greq_card(q, "Fake")
    ui = p.lua.globals().UI
    tree = [ui[i] for i in range(1, len(ui) + 1) if ui[i].name == "TreeNode"]
    check("script card: script node opens by default",
          tree and tree[0].args[3] == p.lua.globals().ImGui.TreeNodeFlags_DefaultOpen, tree)


def test_one_click_install():
    p = Panel()
    p.boot([{"slug": "g1", "name": "Music", "backend": "gamut"}])
    p.requests()
    onb = p.m.ONB
    onb.install("kimi")
    (req,) = p.requests()
    check("install: POST /api/hibiki/install to the gateway", req.method == "POST" and req.url == GATEWAY + "/api/hibiki/install"
          and req.body == {"agent": "kimi"}, req)
    p.reply(req, 202, {"state": "installing"})
    (lst,) = p.requests()
    p.reply(lst, 200, [{"key": "kimi", "slug": "acp-kimi", "name": "Kimi", "description": "d", "installed": False,
                        "state": "installing", "error": ""}])
    check("install: progress tracked", onb.installing == "kimi")
    onb.load_installable()
    (lst,) = p.requests()
    p.reply(lst, 200, [{"key": "kimi", "slug": "acp-kimi", "name": "Kimi", "description": "d", "installed": True,
                        "state": "done", "error": ""}])
    (agents,) = p.requests()
    check("install done: agent list reloaded", agents.url == GATEWAY + "/api/agents")
    p.reply(agents, 200, [{"slug": "g1", "name": "Music", "backend": "gamut"}, {"slug": "acp-kimi", "name": "Kimi", "backend": "acp"}])
    onb.tick()
    check("install done: Kimi selected and settings opened for the login", p.S.agent == "acp-kimi" and p.S.cfgwin is True)
    urls = [r.url for r in p.requests()]
    check("install done: the new agent is started with ?probe=<slug> (probe=1 is only a cheap check)",
          GATEWAY + "/api/agents/acp-kimi/status?probe=acp-kimi" in urls
          and not any(u.endswith("/status?probe=1") for u in urls), urls)


def test_enable_reaper_in_gamut():
    p = Panel({"agent": "g1", "agent_name": "Music"})
    p.boot([{"slug": "g1", "name": "Music", "backend": "gamut"}])
    p.requests()
    onb = p.m.ONB
    check("reaper: unknown at first", onb.reaper_enabled("g1") is None)
    (req,) = [r for r in p.requests() if "gamut-reaper" in r.url]
    check("reaper: asks the gateway", req.method == "GET" and req.url.endswith("/api/hibiki/gamut-reaper?agent=g1"))
    p.reply(req, 200, {"registered": True, "enabled": False})
    check("reaper: disabled read back", onb.reaper_enabled("g1") is False)
    onb.enable_reaper("g1")
    (post,) = [r for r in p.requests() if r.method == "POST"]
    check("reaper: enable posts the agent", post.url.endswith("/api/hibiki/gamut-reaper") and post.body == {"agent": "g1"})
    p.reply(post, 200, {"status": "enabled"})
    (again,) = p.requests()
    p.reply(again, 200, {"registered": True, "enabled": True})
    check("reaper: enabled afterwards", onb.reaper_enabled("g1") is True)


def test_windows_commands():
    """Windows only: background work goes through cmd.exe / PowerShell lines that cmd can parse."""
    if not OS_NAME.startswith("Win"):
        return
    p = Panel(SESSION, token="tok")
    p.boot()
    cmds = [c for c in p.lua_list(p.lua.globals().CMDS)]
    curl = [c for c in cmds if "curl.exe" in c]
    check("win: every curl runs inside cmd.exe /D /S /C with balanced quotes",
          curl and all(re.match(r'^"[^"]+cmd\.exe" /D /S /C ".*"$', c) and c.count('"') % 2 == 0 for c in curl), curl[:2])
    check("win: requests finish with move .code -> .done, no POSIX tools",
          any("& move /Y" in c and ".done" in c for c in curl) and not any("/usr/bin" in c or "mv " in c for c in cmds))
    check("win: the stream marks its end with type NUL > .dead",
          any(" -s -N -A HibikiPanel" in c and "& type NUL >" in c for c in curl))
    kill = [c for c in cmds if "powershell.exe" in c]
    import base64
    script = base64.b64decode(kill[-1].split("-EncodedCommand ")[1]).decode("utf-16-le") if kill else ""
    check("win: the stream kill is an encoded PowerShell script that spares streams started after it",
          "Stop-Process" in script and "-match 'HibikiPanel/" in script and "-gt 0" in script, script)
    check("win: every stream start has its own user agent",
          any(re.search(r" -s -N -A HibikiPanel/\d+\.1 ", c) for c in curl), curl)
    check("win: no write-out % on the cmd line (format read from a file)", not any("%{" in c for c in curl))


MD_TEXTS = [
    "# Title\n\nFirst paragraph with **bold**, *italic* and `code`.\n\nSecond one\nwith a hard break.\n\n## Sub\n\n- a\n- b\n  - nested\n1. one\n2. two\n\n> quote\n\n---\n\ntail",
    "Intro\n\n```lua\nlocal x = 1\n\nlocal y = 2\n\n\nprint(x)\n```\n\nafter the fence\n\n```\nunclosed\n\nstill code\n",
    "| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n\n| c |\n|:-|\n| x |\n\ntext\n\n# Heading after a blank\n\nend",
    "\n\nleading blanks\n\n\n\n### h3\n\n中文段落，没有空格也要按字换行。中文段落，没有空格也要按字换行。\n\n[link](http://x.y) words",
    "Windows\r\nline ends\r\n\r\n- item\r\n\r\n```\r\ncode\r\n\r\n```\r\n\r\nlast",
    "```\nfence at the start\n\n```\n|not a table\n\n| h |\n|--|\n| r |\n",
]


def test_md_incremental_matches_full():
    p = Panel()
    m, lua = p.m, p.lua
    eq = lua.globals().OPS_EQUAL
    bad = []
    for t_i, text in enumerate(MD_TEXTS):
        for width in (300, 120):
            L = None
            steps = sorted(set(list(range(1, len(text) + 1, 3)) + [len(text)]))
            for n in steps:
                t = text[:n]
                L = m.md_layout(L, t, width)
                ops, h = m.layout_md(t, width, 14)
                ok, why = eq(L.ops, ops)
                if not ok or L.h != h:
                    bad.append((t_i, width, n, why, L.h, h))
                    break
            fresh = m.md_layout(None, text, width)  # one-shot (completed message) path
            ok, why = eq(fresh.ops, m.layout_md(text, width, 14)[0])
            if not ok:
                bad.append((t_i, width, "fresh", why))
    check("H1: incremental layout = full layout at every streamed length (fences, tables, lists, CRLF)", not bad, bad[:3])
    L = None
    big = "".join("Paragraph %d with some words in it.\n\n" % i for i in range(400))
    for n in (len(big) // 2, len(big)):
        L = m.md_layout(L, big[:n], 300)
    check("H1: a long reply keeps its prefix (only the tail is laid out again)", L.cut > len(big) - 80, L.cut)


def _chat(p, n):
    msgs = []
    for i in range(n):
        msgs.append({"type": "user", "id": "u%d" % i, "content": {"text": "question %d" % i}})
        msgs.append({"type": "assistant", "id": "a%d" % i, "content": {"text": "answer %d\n\nwith **two** paragraphs" % i},
                     "toolCalls": [{"name": "mcp__reaper__status"}, {"name": "Bash"}] if i % 2 else []})
    return msgs


def test_offscreen_messages_are_dummies():
    p = Panel(SESSION)
    p.boot()
    p.sse({"type": "connected", "isActive": False})
    (req,) = find(p.requests(), "GET", "/sessions/s1/messages")
    p.reply(req, 200, _chat(p, 60))
    p.S.win_from = 1  # the whole transcript in the window, as after scrolling up to the first message
    g, ui = p.lua.globals(), p.lua.globals().UI
    lay = g.LAYOUT(400, 600)
    p.m.draw_log()
    total = lay.y
    lay.y, lay.scroll = 0, total / 2
    g.UI = p.lua.table()
    p.m.draw_log()
    calls = [g.UI[i] for i in range(1, len(g.UI) + 1)]
    texts = [c for c in calls if c.name == "DrawList_AddTextEx"]
    ys = [c.args[5] for c in texts]
    check("H2: content height unchanged when off-screen messages are skipped", lay.y == total, (lay.y, total))
    check("H2: only messages near the visible window draw text",
          texts and all(-260 <= y <= 600 + 260 for y in ys), (len(texts), min(ys or [0]), max(ys or [0])))
    dummies = [c for c in calls if c.name == "Dummy"]
    check("H2: off-screen messages emit a Dummy and nothing else",
          len(dummies) > 100 and len(calls) < 6 * len(dummies) + 400, (len(dummies), len(calls)))
    lay.w, lay.y = 300, 0  # width change: every height is measured again
    p.m.draw_log()
    widths = {(m._h.w if m._h else None) for m in p.lua_list(p.S.msgs)}
    check("H2: a width change re-measures every message", widths == {300}, widths)
    h300 = lay.y
    lay.y = 0
    p.m.draw_log()
    check("H2: and then culls again with the new heights", lay.y == h300, (lay.y, h300))


WIN = 60


def _loaded(n_rounds, msgs=None, src=None):
    p = Panel(SESSION, src=src)
    p.boot()
    p.sse({"type": "connected", "isActive": False})
    (req,) = find(p.requests(), "GET", "/sessions/s1/messages")
    p.reply(req, 200, msgs if msgs is not None else _chat(p, n_rounds))
    return p


def _frame(p, lay, scroll=None):
    """One log frame: returns (calls, texts {text: screen y}); applies the frame's last SetScrollY afterwards, the way
    ImGui does on the next Begin."""
    g = p.lua.globals()
    lay.y = 0
    if scroll is not None:
        lay.scroll = scroll
    g.UI = p.lua.table()
    p.m.draw_log()
    calls = [g.UI[i] for i in range(1, len(g.UI) + 1)]
    texts = {}
    for c in calls:
        if c.name == "DrawList_AddTextEx" and 0 <= c.args[5] <= lay.h:
            texts.setdefault(c.args[7], c.args[5])
    sets = [c.args[2] for c in calls if c.name == "SetScrollY"]
    p.S.sy_last = sets[-1] if sets else lay.scroll
    lay.scroll = p.S.sy_last
    return calls, texts


def _bottom(p, lay):
    _frame(p, lay)
    _frame(p, lay, max(0, lay.y - lay.h))
    return _frame(p, lay, max(0, lay.y - lay.h))


def test_window_cost_is_constant():
    counts = {}
    for rounds in (50, 1500):
        p = _loaded(rounds)
        p.S.follow = True
        lay = p.lua.globals().LAYOUT(400, 600)
        calls, _ = _bottom(p, lay)
        counts[rounds * 2] = len(calls)
        walked = sum(1 for m in p.lua_list(p.S.msgs) if m._h)
        if rounds == 1500:
            check("W1: 3000 messages: only the last %d are laid out" % WIN, walked <= WIN + 2, walked)
            check("W1: window starts %d from the end" % WIN, p.S.win_from == 3000 - WIN + 1, p.S.win_from)
    check("W1: a frame costs the same ImGui calls for 3000 messages as for 100 (O(window), not O(total))",
          counts[3000] <= counts[100] + 10, counts)


def test_window_grows_at_top_and_keeps_position():
    p = _loaded(1500)
    lay = p.lua.globals().LAYOUT(400, 600)
    p.S.follow = True
    _bottom(p, lay)
    p.S.follow = False
    _, before = _frame(p, lay, 0)
    p.S.sy_last = 0
    start = p.S.win_from
    calls, during = _frame(p, lay, 0)
    check("W2: reaching the top grows the window by %d" % WIN, p.S.win_from == start - WIN, (start, p.S.win_from))
    check("W2: the top of the window shows text", len(before) >= 5, before)
    check("W2: the growing frame looks the same (older messages laid out out of sight)", during == before,
          (sorted(before.items())[:3], sorted(during.items())[:3]))
    check("W2: the scroll moves down by the inserted height", lay.scroll > 600, lay.scroll)
    _, after = _frame(p, lay)
    check("W2: next frame the same text sits at the same screen y", after == before,
          (sorted(before.items())[:3], sorted(after.items())[:3]))
    _, again = _frame(p, lay)
    check("W2: and stays there (no growth away from the top)", again == before and p.S.win_from == start - WIN)
    check("W2: the hint line is drawn while older messages exist",
          any(c.name == "TextDisabled" and c.args[2] == "Load earlier messages" for c in calls))


def test_window_click_hint_and_first_message():
    p = _loaded(40)  # 80 messages: one growth reaches the first message and the hint goes away
    lay = p.lua.globals().LAYOUT(400, 600)
    p.S.follow = False
    g = p.lua.globals()
    _frame(p, lay, 300)
    _, before = _frame(p, lay, 300)
    g.RET.IsItemClicked = p.lua.eval("function() return true end")
    _frame(p, lay)
    g.RET.IsItemClicked = None
    check("W3: clicking the hint loads the rest", p.S.win_from == 1, p.S.win_from)
    calls, after = _frame(p, lay)
    check("W3: no hint once the first message is in", not any(c.name == "TextDisabled" and c.args[2] == "Load earlier messages"
                                                              for c in calls))
    check("W3: text on screen", len(before) >= 5, before)
    check("W3: the view stays put even though the hint line went away", after == before,
          (sorted(before.items())[:2], sorted(after.items())[:2]))


def test_window_shrinks_when_following():
    p = _loaded(1500)
    lay = p.lua.globals().LAYOUT(400, 600)
    p.S.follow = True
    _bottom(p, lay)
    p.S.follow = False
    for _ in range(4):
        p.S.sy_last = 0
        _frame(p, lay, 0)
    grown = 3001 - p.S.win_from
    check("W4: scrolled up past %d messages" % (3 * WIN), grown > 3 * WIN, grown)
    p.S.follow = False
    _bottom(p, lay)
    check("W4: at the bottom but not following: the window is left alone", 3001 - p.S.win_from == grown)
    p.S.follow = True
    _, before = _frame(p, lay, max(0, lay.y - lay.h))
    _, after = _frame(p, lay)
    check("W4: following again cuts back to the last %d" % WIN, p.S.win_from == 3000 - WIN + 1, p.S.win_from)
    check("W4: the bottom shows text", len(before) >= 5, before)
    check("W4: the cut keeps the bottom in place", after == before and lay.scroll <= lay.y - lay.h + 1,
          (sorted(before.items())[:2], sorted(after.items())[:2], lay.scroll, lay.y))


def test_window_new_messages():
    p = _loaded(200)
    lay = p.lua.globals().LAYOUT(400, 600)
    p.S.follow = True
    _bottom(p, lay)
    lua = p.lua
    msgs = p.S.msgs
    for k in range(4):
        msgs[len(msgs) + 1] = lua.table_from({"role": "user", "text": "new %d" % k})
    _frame(p, lay)
    check("W5: following: the window start advances with new messages", p.S.win_from == len(msgs) - WIN + 1,
          (p.S.win_from, len(msgs)))
    p.S.follow = False
    start = p.S.win_from
    _, before = _frame(p, lay, 200)
    for k in range(4):
        msgs[len(msgs) + 1] = lua.table_from({"role": "user", "text": "more %d" % k})
    _, after = _frame(p, lay, 200)
    check("W5: reading scrolled up: new messages don't move the window or the view",
          p.S.win_from == start and after == before, (start, p.S.win_from))


def test_window_resets_on_session_switch():
    p = _loaded(1500)
    lay = p.lua.globals().LAYOUT(400, 600)
    p.S.win_from = 7
    p.lua.globals().EXT_STATE["Hibiki/demo_new"] = "1"
    p.m.demo_tick(p.lua.globals().NOW)
    check("W6: new chat / session switch drops the window", p.S.win_from is None, p.S.win_from)
    p.S.sid = "s1"
    p.m.refresh_messages(True)
    (req,) = find(p.requests(), "GET", "/sessions/s1/messages")
    p.reply(req, 200, _chat(p, 1500))
    _frame(p, lay)
    check("W6: a fresh load shows the last %d" % WIN, p.S.win_from == 3000 - WIN + 1, p.S.win_from)


def test_window_tool_run_boundary():
    msgs = []
    for i in range(100):
        msgs.append({"type": "user", "id": "u%d" % i, "content": {"text": "q %d" % i}})
        msgs.append({"type": "assistant", "id": "a%d" % i, "content": {"text": "a %d" % i}})
    run = [{"type": "assistant", "id": "t%d" % i, "content": {"text": ""}, "toolCalls": [{"name": "Bash"}]}
           for i in range(30)]
    msgs = msgs[:150] + run + msgs[150:]  # the run covers 151..180; n = 230, so n - 59 = 171 falls inside it
    p = _loaded(0, msgs)
    lay = p.lua.globals().LAYOUT(400, 600)
    p.S.follow = True
    _bottom(p, lay)
    check("W7: the window starts at the first message of a tool-only run, not inside it", p.S.win_from == 151,
          p.S.win_from)
    first = p.S.msgs[151]
    check("W7: the whole run is one lane held by its first message", first._hl and first._hl.key == 30,
          first._hl and first._hl.key)
    check("W7: no lane cache on messages inside the run",
          all(not p.S.msgs[i]._hl for i in range(152, 181)))


def bench():
    """Per-frame Lua time and ImGui call count, HEAD panel vs this one (mock ImGui; Lua cost includes the mocks)."""
    import subprocess
    import time
    old = subprocess.run(["git", "show", "HEAD:panel/Hibiki.lua"], cwd=PANEL.parent.parent, capture_output=True,
                         text=True).stdout
    print("%-8s %6s %16s %16s" % ("version", "msgs", "lua ms/frame", "ImGui calls"))
    for label, src in (("before", old), ("after", None)):
        for rounds in (50, 500, 1500):
            p = _loaded(rounds, src=src)
            p.S.follow = True
            lay = p.lua.globals().LAYOUT(400, 600)
            calls, _ = _bottom(p, lay)
            g = p.lua.globals()
            g.RECORD = False
            frames = 60
            t = time.perf_counter()
            for _ in range(frames):
                lay.y = 0
                p.m.draw_log()
            ms = (time.perf_counter() - t) / frames * 1000
            print("%-8s %6d %16.3f %16d" % (label, rounds * 2, ms, len(calls)))


def test_truncate_binary_search():
    p = Panel()
    tr = p.m.truncate
    check("truncate: fits unchanged", tr("short", 100) == "short")
    out = tr("abcdefghijklmnopqrstuvwxyz", 70)  # 7 px per char: 9 chars + "…" = 70
    check("truncate: longest prefix + ellipsis that fits", out == "abcdefghi…", out)
    out = tr("中文标题很长很长", 30)
    check("truncate: cuts on UTF-8 character boundaries", out == "中文标…", out)


def test_sse_backlog_crlf():
    p = Panel(SESSION)
    p.boot()
    p.sse({"type": "connected", "isActive": True})
    events = "".join("event: message\r\ndata: " + json.dumps({"type": "stream_delta", "text": "%d," % i}) + "\r\n\r\n"
                     for i in range(1000))
    cut = events.index("\r\n\r\n", len(events) // 3) + 1  # the chunk ends between \r and \n
    with open(p.S.stream.file, "ab") as f:
        f.write(events[:cut].encode())
    p.m.poll_stream()
    with open(p.S.stream.file, "ab") as f:
        f.write(events[cut:].encode())
    first = p.S.live[1].text.count(",") if len(p.S.live) else 0
    for _ in range(10):
        p.m.poll_stream()
    want = "".join("%d," % i for i in range(1000))
    check("M4: at most 400 events per frame", 0 < first <= 400, first)
    check("M4: a 1000-event CRLF backlog split mid-\\r\\n parses completely and in order",
          len(p.S.live) == 1 and p.S.live[1].text == want, p.S.live[1].text[-40:] if len(p.S.live) else None)


def test_incremental_transcript():
    p = Panel(SESSION)
    p.boot()
    p.sse({"type": "connected", "isActive": False})
    (req,) = find(p.requests(), "GET", "/sessions/s1/messages")
    check("M5: reconnect fetches the full transcript", "?" not in req.url, req.url)
    p.reply(req, 200, _chat(p, 2))
    first = p.S.msgs[1]
    first.marker = "kept"
    p.type_and_send("third question")
    p.sse({"type": "session_idle"})
    (req,) = find(p.requests(), "GET", "/messages?after=u1")
    check("M5: turn end asks only for messages after the one before the last reply", req is not None)
    p.reply(req, 200, {"after": "u1", "messages": [
        {"type": "assistant", "id": "a1", "content": {"text": "answer 1 (final)"}},
        {"type": "user", "id": "u2", "content": {"text": "third question"}},
        {"type": "assistant", "id": "a2", "content": {"text": "third answer"}}]})
    texts = [m.text for m in p.lua_list(p.S.msgs)]
    check("M5: merge keeps earlier messages (and their caches) and replaces the tail",
          texts == ["question 0", "answer 0\n\nwith **two** paragraphs", "question 1", "answer 1 (final)",
                    "third question", "third answer"] and p.S.msgs[1].marker == "kept", texts)
    p.sse({"type": "session_idle"})
    (req,) = find(p.requests(), "GET", "/messages?after=u2")
    p.reply(req, 200, _chat(p, 1))  # Gamut's own API: plain array = the whole transcript
    texts = [m.text for m in p.lua_list(p.S.msgs)]
    check("M5: an array answer replaces everything", len(texts) == 2 and p.S.msgs[1].marker is None, texts)
    p.sse({"type": "session_idle"})
    (req,) = find(p.requests(), "GET", "/messages?after=u0")
    p.reply(req, 200, {"full": True, "messages": _chat(p, 3)})
    check("M5: {full: true} replaces everything", len(p.S.msgs) == 6)
    p.sse({"type": "session_idle"})
    (req,) = find(p.requests(), "GET", "/messages?after=u2")
    p.S.msgs = p.lua.table()  # the anchor vanished locally (session switch race): fall back to a full fetch
    p.reply(req, 200, {"after": "u2", "messages": []})
    check("M5: unknown local anchor refetches in full", find(p.requests(), "GET", "/sessions/s1/messages"))


def test_private_dir():
    home = tempfile.mkdtemp()
    if OS_NAME.startswith("Win"):
        p = Panel(env={"TEMP": None, "TMP": None, "LOCALAPPDATA": home})
        check("#4 win: no TEMP -> %LOCALAPPDATA%\\Hibiki", p.m.DIR == home + "\\Hibiki\\", p.m.DIR)
        check("#4 win: q() closes % out of the quotes and refuses a double quote",
              p.m.q("a%PATH%b") == '"a"%"PATH"%"b"' and p.lua.eval("pcall")(p.m.q, 'x"y')[0] is False)
        return
    for tmp in (None, "/tmp", "/tmp/"):
        p = Panel(env={"TMPDIR": tmp})
        check("#4: TMPDIR=%r -> ~/Library/Caches/Hibiki, never /tmp" % tmp,
              p.m.DIR == str(p.tmp) + "/Library/Caches/Hibiki/", p.m.DIR)
    cmds = p.lua_list(p.lua.globals().CMDS)
    check("#4: the dir is created mode 700", any("mkdir -p -m 700" in c and "chmod 700" in c for c in cmds), cmds[:2])
    p = Panel(token="secret")
    cmds = p.lua_list(p.lua.globals().CMDS)
    i = next((n for n, c in enumerate(cmds) if "umask 077" in c and "chmod 600" in c and "gateway-auth" in c), None)
    j = next((n for n, c in enumerate(cmds) if "/usr/bin/curl" in c), None)
    check("#4: the auth header file is made 600 before the token is written", i is not None and j is not None and i < j)


def test_ids_validated():
    p = Panel({"agent": "acp-fake", "agent_name": "Fake", "session_acp-fake": "../../etc"})
    check("#9: a bad saved session id is dropped", p.S.sid == "")
    p.boot([{"slug": "ok-1", "name": "A", "backend": "acp"}, {"slug": "x;rm -rf ~", "name": "B", "backend": "acp"},
            {"slug": "..", "name": "C", "backend": "acp"}])
    check("#9: agents with unsafe slugs are ignored", [a.slug for a in p.lua_list(p.S.agents)] == ["ok-1"])
    p.S.agent, p.S.sid = "a b", "s1"  # set behind the validation: the URL still gets an encoded segment
    p.m.refresh_messages(True)
    cmds = [r.cmd.replace('"%"', "%") for r in p.requests()]
    check("#9: an unsafe slug never reaches a URL raw", cmds and all("a b" not in c for c in cmds)
          and any("/api/agents/a%20b/sessions/s1/messages" in c for c in cmds), cmds)


def _recover_job(p):
    cmds = p.lua_list(p.lua.globals().CMDS)
    job = [c for c in cmds if "recover --json" in c]
    out = re.search(r"""> ['"]([^'"]+recover[^'"]+)\.out['"]""", job[-1]).group(1) if job else None
    return job, out


def test_demo_typing():
    p = Panel(SESSION)
    p.boot()
    p.requests()
    text = "Make the pizz brighter, 中文 ok."
    p.lua.globals().EXT_STATE["Hibiki/demo_type"] = text
    t, partial, sent = 100.0, [], []
    for _ in range(400):
        p.m.demo_tick(t)
        partial.append(p.S.input)
        sent += [r for r in p.requests() if r.method == "POST" and "/messages" in r.url]
        if sent:
            break
        t += 0.05
    typed = [x for x in partial if x]
    check("demo: types the text gradually (valid UTF-8 prefixes) and then sends it once",
          len(set(typed)) > 10 and all(text.startswith(x) for x in typed) and len(sent) == 1
          and "Hibiki/demo_type" not in dict(p.lua.globals().EXT_STATE), (len(set(typed)), len(sent)))


def test_title_follows_gamut_rename():
    p = Panel({"agent": "ag1", "agent_name": "Music", "session_ag1": "s1", "title_ag1": "Make the pizz brighter"})
    p.boot([{"slug": "ag1", "name": "Music"}])
    p.requests()
    p.sse({"type": "session_updated"})
    p.m.frame()
    lists = [r for r in p.requests() if r.method == "GET" and r.url.endswith("/sessions")]
    if lists:
        p.reply(lists[-1], 200, [{"id": "s1", "name": "Brighter pizz in the kick sidechain"}, {"id": "s2", "name": "Other"}])
    check("title: Gamut's session_updated refetches the list and the header takes the new name (and persists it)",
          len(lists) == 1 and p.S.title == "Brighter pizz in the kick sidechain"
          and dict(p.lua.globals().EXT_STATE).get("Hibiki/title_ag1") == "Brighter pizz in the kick sidechain",
          (len(lists), p.S.title))


def test_recover():
    for case in ("ok", "bad", "missing"):
        p = Panel(SESSION)
        p.boot()
        p.sse({"type": "connected", "isActive": True}, {"type": "stream_delta", "text": "stuck"})
        p.requests()
        p.lua.execute("HIBIKI_TEST.sh('noop')")
        p.m.REC.start()
        job, base = _recover_job(p)
        reqs = p.requests()
        check("recover(%s): interrupts the running turn and starts the CLI in the background" % case,
              job and find(reqs, "POST", "/sessions/s1/interrupt") and p.m.REC.running is True
              and (job[-1].endswith("&") or "cmd.exe" in job[-1]), job)
        if not base:
            continue
        if case == "ok":
            body, code = json.dumps({"ok": True, "steps": [{"name": "gateway", "ok": True, "detail": "restarted"},
                                                          {"name": "bridge", "ok": False, "detail": "REAPER not running"}]}), 0
        elif case == "bad":
            body, code = "Traceback: boom", 1
        else:
            body, code = "", 127
        Path(base + ".out").write_text(body)
        Path(base + ".done").write_text(str(code))
        p.m.poll_http()
        lines = [l.text for l in p.lua_list(p.m.REC.lines)] if p.m.REC.lines else []
        if case == "ok":
            check("recover(ok): one line per step", lines == ["✓ gateway — restarted", "✗ bridge — REAPER not running"], lines)
        else:
            check("recover(%s): says to run hibiki recover in Terminal" % case,
                  len(lines) == 1 and "hibiki recover" in lines[0] and "Terminal" in lines[0], lines)
        check("recover(%s): not running any more" % case, p.m.REC.running is False)
        reqs = p.requests()
        (agents,) = [r for r in reqs if r.url.endswith("/api/agents")]
        p.reply(agents, 200, [{"slug": "acp-fake", "name": "Fake", "backend": "acp"}])
        reqs = p.requests()
        check("recover(%s): hosts re-resolved, chat reloaded in full and the stream restarted" % case,
              any(r.stream and r.url.endswith("/sessions/s1/stream") for r in reqs)
              and find(reqs, "GET", "/sessions/s1/messages"), reqs)


def _update_jobs(p):
    return [c for c in p.lua_list(p.lua.globals().CMDS) if " update --" in c]


def _finish_update(p, cmd, body, code=0):
    base = re.search(r"""> ['"]([^'"]+update[^'"]+)\.out['"]""", cmd).group(1)
    Path(base + ".out").write_text(body if isinstance(body, str) else json.dumps(body))
    Path(base + ".done").write_text(str(code))
    p.m.poll_http()


def _settings(p, click=None):
    """Draw one frame with the settings window open; click: the id of a light/LED button to press."""
    g = p.lua.globals()
    g.LAYOUT(400, 600)
    p.lua.execute("UI = {}; RET.Begin = function(_, name) if name:find('hibiki_cfg', 1, true) then return true, true end end; "
                  "RET.GetCursorPosX = function() return 0 end; RET.GetFrameHeight = function() return 20 end; "
                  "RET.GetItemRectMin = function() return 0, 0 end; RET.GetItemRectMax = function() return 0, 0 end")
    if click:
        p.lua.execute("RET.InvisibleButton = function(_, id, w, h) return id == %r end" % click)
    p.S.cfgwin = True
    try:
        p.m.frame()
    finally:
        p.lua.execute("RET.Begin, RET.InvisibleButton, RET.GetCursorPosX, RET.GetFrameHeight = nil, nil, nil, nil; "
                      "RET.GetItemRectMin, RET.GetItemRectMax = nil, nil")
        g.LAYOUT(400, 600)
    texts = []
    ui = p.lua.globals().UI
    for i in range(1, len(ui) + 1):
        e = ui[i]
        if e.name in ("Text", "TextColored", "TextDisabled"):
            args = [e.args[k] for k in range(1, e.args.n + 1)]
            texts.append(str(args[-1]))
    return texts


UPDATE_OK = {"current": "0.5.1-dev.4", "latest": "0.5.1-dev.4", "tag": "v0.5.1-dev.4", "url": "https://x",
             "published": "2026-10-20T10:00:00Z", "update_available": False, "channel": "dev", "notes": ""}
UPDATE_NEW = dict(UPDATE_OK, latest="0.5.1-dev.5", tag="v0.5.1-dev.5", published="2026-10-23T10:00:00Z",
                  update_available=True)


def test_update_check():
    import time
    for case in ("up-to-date", "available", "error", "missing"):
        p = Panel(dict(SESSION, upd_at=str(int(time.time()))))
        p.boot()
        texts = _settings(p, "##lb_updcheck")
        jobs = _update_jobs(p)
        check("update(%s): Check for updates starts `hibiki update --check --json` in the background" % case,
              len(jobs) == 1 and " update --check --json" in jobs[0] and p.m.UPD.running == "check"
              and (jobs[0].endswith("&") or "cmd.exe" in jobs[0]) and "--install" not in jobs[0], jobs)
        if not jobs:
            continue
        if case == "up-to-date":
            _finish_update(p, jobs[0], UPDATE_OK)
        elif case == "available":
            _finish_update(p, jobs[0], UPDATE_NEW)
        elif case == "error":
            _finish_update(p, jobs[0], {"current": "0.5.1-dev.4", "error": "<urlopen error offline>"}, 1)
        else:
            _finish_update(p, jobs[0], "", 127)
        texts = _settings(p)
        ext = dict(p.lua.globals().EXT_STATE)
        check("update(%s): no longer running" % case, p.m.UPD.running is None)
        if case == "up-to-date":
            check("update(up-to-date): 'Version 0.5.1-dev.4' + 'Up to date'; check time saved",
                  "Version 0.5.1-dev.4" in texts and "Up to date" in texts and ext.get("Hibiki/upd_at", "") != "", texts)
        elif case == "available":
            check("update(available): '0.5.1-dev.5 available (Oct 23)' with an Install button",
                  "0.5.1-dev.5 available (Oct 23)" in texts and p.m.UPD.available is True, texts)
        elif case == "error":
            check("update(error): the CLI's error is shown", "<urlopen error offline>" in texts and p.m.UPD.err, texts)
        else:
            check("update(missing): says the hibiki command was not found",
                  any("not found" in t for t in texts), texts)


def test_update_install():
    import time
    p = Panel(dict(SESSION, upd_at=str(int(time.time())), upd_current="0.5.1-dev.4", upd_latest="0.5.1-dev.5",
                   upd_available="1", upd_published="2026-10-23T10:00:00Z"))
    p.boot()
    texts = _settings(p)
    check("install: cached result shows the available version", "0.5.1-dev.5 available (Oct 23)" in texts
          and not _update_jobs(p), texts)
    _settings(p, "##lb_updinstall")
    jobs = _update_jobs(p)
    check("install: Install runs `hibiki update --install --json` in the background",
          len(jobs) == 1 and " update --install --json" in jobs[0] and p.m.UPD.running == "install", jobs)
    if not jobs:
        return
    texts = _settings(p)
    check("install: shows Downloading…", "Downloading…" in texts, texts)
    _finish_update(p, jobs[0], dict(UPDATE_NEW, installer="/tmp/x.pkg", launched=["open", "/tmp/x.pkg"],
                                     message="installer opened"))
    texts = _settings(p)
    check("install: tells the user to finish the installer and restart REAPER",
          any(t.startswith("Installer opened") and "restart REAPER" in t for t in texts), texts)
    p2 = Panel(dict(SESSION, upd_at=str(int(time.time())), upd_current="0.5.1-dev.4", upd_latest="0.5.1-dev.5",
                    upd_available="1"))
    p2.boot()
    _settings(p2, "##lb_updinstall")
    _finish_update(p2, _update_jobs(p2)[0], {"current": "0.5.1-dev.4", "error": "sha256 mismatch; nothing was installed"}, 1)
    texts = _settings(p2)
    check("install: the CLI's refusal is shown", "sha256 mismatch; nothing was installed" in texts, texts)


def test_update_auto_check():
    import time
    p = Panel(dict(SESSION, upd_at=str(int(time.time()) - 25 * 3600), upd_current="0.5.1-dev.4"))
    p.boot()
    p.S.cfgwin_was = False
    _settings(p)
    jobs = _update_jobs(p)
    check("auto: opening settings with a check older than 24 h checks once, never installs",
          len(jobs) == 1 and "--check" in jobs[0] and "--install" not in jobs[0], jobs)
    _settings(p)
    check("auto: not again while the window stays open", len(_update_jobs(p)) == 1)
    p = Panel(dict(SESSION, upd_at=str(int(time.time()) - 3600)))
    p.boot()
    p.S.cfgwin_was = False
    _settings(p)
    check("auto: a check under 24 h old is not repeated", not _update_jobs(p), _update_jobs(p))
    _settings(p, "##cb_upddev")
    jobs = _update_jobs(p)
    ext = dict(p.lua.globals().EXT_STATE)
    check("release candidates checkbox: persisted and re-checks with --channel dev",
          ext.get("Hibiki/upd_dev") == "1" and len(jobs) == 1 and "--channel dev" in jobs[0], (ext.get("Hibiki/upd_dev"), jobs))


# ---------------------------------------------------------------- studio.lua

STUDIO_FAKES = r"""
UNDO, REDO = {}, {}
reaper.Undo_CanUndo2 = function() return UNDO[#UNDO] end
reaper.Undo_CanRedo2 = function() return REDO[#REDO] end
reaper.Undo_DoUndo2 = function() REDO[#REDO + 1] = table.remove(UNDO) end
reaper.Undo_DoRedo2 = function() UNDO[#UNDO + 1] = table.remove(REDO) end
-- 120 BPM 4/4: 2 s per bar
reaper.TimeMap2_timeToBeats = function(_, t) local qn = t * 2; return qn % 4, math.floor(qn / 4), 4, qn, 4 end
GMEM = {}
reaper.gmem_read = function(i) return GMEM[i] or 0 end
function METER_FRAMES(from, n, t0, fn)
  GMEM[0], GMEM[2], GMEM[3] = 1, 1200, 16
  for k = 0, n - 1 do
    local i = from + k
    local o = 8 + (i % 1200) * 16
    local f = fn(k)
    GMEM[o] = t0 + k * 0.1
    GMEM[o + 2], GMEM[o + 3], GMEM[o + 4], GMEM[o + 5] = f.m, f.s, f.tp, f.tp - 0.3
    GMEM[o + 6], GMEM[o + 7] = f.corr or 0.8, -12
    for b = 0, 7 do GMEM[o + 8 + b] = -20 - b * 2 end
  end
  GMEM[1] = from + n
end
TRACKS = {}
reaper.CountTracks = function() return #TRACKS end
reaper.GetTrack = function(_, i) return TRACKS[i + 1] end
reaper.GetMasterTrack = function() return MASTER end
MASTER = { name = 'MASTER', ext = {}, mute = 0 }
reaper.GetTrackName = function(t) return true, t.name end
reaper.GetSetMediaTrackInfo_String = function(t, key, v, set)
  if not t then return false, '' end
  local k = key:gsub('^P_EXT:', '')
  if set then t.ext[k] = v end
  return t.ext[k] ~= nil, t.ext[k] or ''
end
reaper.GetMediaTrackInfo_Value = function(t, key) if key == 'B_MUTE' then return t.mute end return 0 end
reaper.SetMediaTrackInfo_Value = function(t, key, v) if key == 'B_MUTE' then t.mute = v end end
LAYOUT(400, 600)
RET.GetFrameHeight = function() return 24 end
RET.GetFrameHeightWithSpacing = function() return 30 end
RET.GetItemRectMin = function() return 0, 0 end
"""


def studio_panel(ext=None):
    p = Panel(dict(SESSION, **(ext or {})))
    p.lua.execute(STUDIO_FAKES)
    p.boot()
    p.requests()
    return p


def test_studio_loads():
    p = Panel(SESSION)
    check("studio: loaded next to the panel, no load error", p.m.studio is not None
          and p.lua.globals().EXT_STATE["Hibiki/error"] is None, p.lua.globals().EXT_STATE["Hibiki/error"])


def test_receipts_turn_and_title():
    p = studio_panel()
    st = p.lua.globals().EXT_STATE
    p.type_and_send("give the pizz another sound")
    turn = st["Hibiki/turn"]
    check("receipts: a sent message tags the bridge's changes with this reply's id", bool(turn) and "." in turn, turn)
    st["Hibiki/receipts"] = json.dumps([{"id": turn, "at": 1, "n": 2, "points": 1, "proj": "",
                                         "lines": ["#11 Pizz: add ReaEQ", "script: local x = 1"]}])
    st["Hibiki/receipts_seq"] = "1"
    p.sse({"type": "stream_delta", "text": "好的。\n\n## 结论\n**Pizz 换成 Celesta，做了 3 个版本。** 细节如下"},
          {"type": "session_idle"})
    p.requests()
    check("receipts: the reply's end clears the turn id", st["Hibiki/turn"] == "")
    check("version history: the reply is titled with its first real sentence (no 'OK', no heading)",
          p.m.studio._R.summary[turn] == "Pizz 换成 Celesta，做了 3 个版本", p.m.studio._R.summary[turn])


def test_meter_context():
    p = studio_panel({"ctx_level": "1"})
    p.lua.execute("METER_FRAMES(0, 0, 0, function() end)")
    p.m.studio.tick(2000)
    # 8 s of playback from bar 3 (t = 4 s): loud at bar 5, an inter-sample peak at bar 6
    p.lua.execute("""METER_FRAMES(0, 80, 4.0, function(k)
      local t = 4 + k * 0.1
      return { m = (t >= 8 and t < 10) and -7 or -10, s = (t >= 8 and t < 10) and -7.5 or -10.5,
               tp = (t >= 10.5 and t < 10.6) and 0.4 or -2, corr = (t >= 6 and t < 6.1) and -0.2 or 0.8 }
    end)""")
    p.m.studio.tick(2001)
    reqs = p.type_and_send("too loud?")
    (post,) = find(reqs, "POST", "/sessions/s1/messages")
    body = post.body["content"]
    line = [l for l in body.split("\n") if l.startswith("meter (")]
    check("meter: the last playback is summarised in the context", len(line) == 1 and "bars 3.1-6.4" in line[0]
          and "LUFS-S max -7.5 @ 5.1" in line[0] and "true peak max 0.4 dBTP @ 6.2" in line[0]
          and "correlation min -0.20 @ 4.1" in line[0], line)
    check("meter: integrated loudness is gated over the playback", "LUFS-I -9." in line[0], line)
    check("meter: band and per-bar lines", "meter bands (mid" in body and "meter per bar (max LUFS-M / max dBTP): 3 -10.0/-2.0 · 4"
          in body, body[-600:])


def test_rack_switch_and_context():
    p = studio_panel({"ctx_level": "1"})
    p.lua.execute("""
      RACK_CMDS = {}
      reaper.Main_OnCommand = function(id) RACK_CMDS[#RACK_CMDS + 1] = id end
      TRACKS = { { name = 'Bass A', ext = { hibiki_var = 'Bass/1' }, mute = 0 },
                 { name = 'Bass B', ext = { hibiki_var = 'Bass/2' }, mute = 1 },
                 { name = 'Keys', ext = {}, mute = 0 } }""")
    p.m.studio.tick(5000)
    groups = p.lua_list(p.m.studio._RK.groups)
    check("rack: tagged sibling tracks form one group, active = the unmuted one",
          len(groups) == 1 and groups[0].name == "Bass" and groups[0].active == 1)
    p.lua.execute("RET.InvisibleButton = function(_, id) return id == '##led_rk1_2' end")
    p.m.studio.rack_row()
    t = p.lua.globals().TRACKS
    check("rack: clicking 2 plays Bass B and mutes Bass A", t[1].mute == 1 and t[2].mute == 0 and t[3].mute == 0)
    check("rack: a click while stopped starts playback (a listen, not just a switch)", 1007 in p.lua_list(p.lua.globals().RACK_CMDS))
    p.lua.execute("RET.InvisibleButton = nil")
    reqs = p.type_and_send("which bass?")
    body = find(reqs, "POST", "/sessions/s1/messages")[0].body["content"]
    check("rack: the context says which variant is playing", 'audition rack "Bass": 2 variants, playing #2 (#2 Bass B)' in body, body[-400:])


def test_rack_keep():
    p = studio_panel()
    p.lua.execute("""
      TRACKS = { { name = 'Bass A', ext = { hibiki_var = 'Bass/1' }, mute = 1 },
                 { name = 'Bass B', ext = { hibiki_var = 'Bass/2' }, mute = 0 },
                 { name = 'Keys', ext = {}, mute = 0 } }
      reaper.DeleteTrack = function(t) for i, x in ipairs(TRACKS) do if x == t then table.remove(TRACKS, i) end end end
      RET.InvisibleButton = function(_, id) return id == '##chip_rkkeep1' end""")
    p.m.studio.tick(5000)
    p.m.studio.rack_row()
    p.lua.execute("RET.InvisibleButton = nil")
    t = p.lua_list(p.lua.globals().TRACKS)
    check("rack: Keep 2 deletes the other variant and clears the tag, in the panel",
          [x.name for x in t] == ["Bass B", "Keys"] and (t[0].ext.hibiki_var or "") == "" and t[0].mute == 0)
    p.m.studio.tick(5002)
    check("rack: the row is gone after Keep", len(p.lua_list(p.m.studio._RK.groups)) == 0)


def test_rack_lanes():
    p = studio_panel()
    p.lua.execute("""
      LANE_ITEMS = {}
      TRACKS = { { name = 'Pizz', ext = { hibiki_lanes = 'Pizz level' }, mute = 0, freemode = 2, lanes = 3,
                   plays = { [0] = 1, [1] = 0, [2] = 0 }, names = { [0] = '+0 dB', [1] = '-3 dB', [2] = '+3 dB' } } }
      for k = 0, 2 do LANE_ITEMS[#LANE_ITEMS + 1] = { lane = k } end
      local get, set, gets = reaper.GetMediaTrackInfo_Value, reaper.SetMediaTrackInfo_Value, reaper.GetSetMediaTrackInfo_String
      reaper.GetMediaTrackInfo_Value = function(t, k)
        if k == 'I_FREEMODE' then return t.freemode or 0 end
        if k == 'I_NUMFIXEDLANES' then return t.lanes or 1 end
        local l = k:match('^C_LANEPLAYS:(%d+)$')
        if l then return t.plays[tonumber(l)] end
        return get(t, k)
      end
      reaper.SetMediaTrackInfo_Value = function(t, k, v)
        if k == 'I_FREEMODE' then t.freemode = v; return end
        local l = k:match('^C_LANEPLAYS:(%d+)$')
        if l then t.plays[tonumber(l)] = v; return end
        return set(t, k, v)
      end
      reaper.GetSetMediaTrackInfo_String = function(t, k, v, s)
        local l = k:match('^P_LANENAME:(%d+)$')
        if l then return true, t.names[tonumber(l)] end
        return gets(t, k, v, s)
      end
      reaper.CountTrackMediaItems = function() return #LANE_ITEMS end
      reaper.GetTrackMediaItem = function(_, j) return LANE_ITEMS[j + 1] end
      reaper.GetMediaItemInfo_Value = function(it, k) if k == 'I_FIXEDLANE' then return it.lane end return 0 end
      reaper.DeleteTrackMediaItem = function(_, it) for i, x in ipairs(LANE_ITEMS) do if x == it then table.remove(LANE_ITEMS, i) end end end
    """)
    p.m.studio.tick(6000)
    g = p.lua_list(p.m.studio._RK.groups)
    check("rack lanes: a tagged fixed-lane track is a group, the playing lane is active",
          len(g) == 1 and g[0].name == "Pizz level" and g[0].count == 3 and g[0].active == 1)
    p.lua.execute("RET.InvisibleButton = function(_, id) return id == '##led_rk1_2' end")
    p.m.studio.rack_row()
    t = p.lua.globals().TRACKS[1]
    check("rack lanes: 2 plays lane 2 alone", t.plays[0] == 0 and t.plays[1] == 1 and t.plays[2] == 0)
    p.lua.execute("RET.InvisibleButton = function(_, id) return id == '##chip_rkkeep1' end")
    p.m.studio.rack_row()
    p.lua.execute("RET.InvisibleButton = nil")
    items = p.lua_list(p.lua.globals().LANE_ITEMS)
    check("rack lanes: Keep 2 keeps lane 2's items, one lane again, tag cleared",
          [x.lane for x in items] == [1] and t.freemode == 0 and (t.ext.hibiki_lanes or "") == "")


def test_remember_command():
    p = studio_panel()
    reqs = p.type_and_send("/remember example rule three")
    brain = find(reqs, "POST", "/api/hibiki/brain")
    check("remember: goes to the gateway's rules, not to the chat", len(brain) == 1
          and brain[0].body == {"add": "example rule three"}
          and not find(reqs, "POST", "/sessions/s1/messages") and p.S.input == "")
    p.reply(brain[0], 200, {"added": True, "count": 3, "path": "/x/rules.md"})
    check("remember: confirms in the hint line", "(3)" in (p.m.studio.hint() or ""), p.m.studio.hint())
    reqs = p.type_and_send("/remember off: no-such-rule")
    brain = find(reqs, "POST", "/api/hibiki/brain")
    p.reply(brain[0], 400, {"error": "no default rule 'no-such-rule'"})
    check("remember: the gateway's refusal is shown", "no default rule" in (p.m.studio.hint() or ""), p.m.studio.hint())
    t = p.lua.table_from
    line = p.m.studio.rules_line
    check("rules line: defaults, off and yours", line(t({"count": 3, "defaults": 10, "off": t(["a"])}))
          == "10 defaults (1 off) \u00b7 3 yours", line(t({"count": 3, "defaults": 10, "off": t(["a"])})))
    check("rules line: none off", line(t({"count": 0, "defaults": 10, "off": t([])})) == "10 defaults \u00b7 0 yours")
    check("rules line: an older gateway (count only)", line(t({"count": 2})) == "2 yours")
    p.requests()
    p.m.studio.rules_edit()
    ens = find(p.requests(), "POST", "/api/hibiki/brain")
    check("rules Edit: asks the gateway to create the files", len(ens) == 1 and ens[0].body == {"ensure": True})
    p.reply(ens[0], 200, {"path": "/x/brain/rules.md", "defaults_path": "/x/brain/defaults.md", "count": 0})
    cmds = p.lua_list(p.lua.globals().CMDS)
    opened = [c for c in cmds if "notepad" in c or "open -t" in c]
    check("rules Edit: opens defaults.md and rules.md",
          (len(opened) == 2 and "defaults.md" in opened[0] and "rules.md" in opened[1]) if OS_NAME == "Win64"
          else (len(opened) == 1 and "defaults.md" in opened[0] and "rules.md" in opened[0]), opened)


def test_ears_render_and_attach():
    p = studio_panel({"ctx_level": "1"})
    p.lua.execute(r"""
      PROJ, PROJS = { RENDER_SETTINGS = 1, RENDER_BOUNDSFLAG = 1 }, { RENDER_FILE = '/my/renders', RENDER_PATTERN = 'mix', RENDER_FORMAT = 'b2dnZw==' }
      reaper.GetSet_LoopTimeRange2 = function() return 10.0, 14.0 end
      reaper.format_timestr_pos = function(t) return ('%.2f'):format(t) end
      reaper.GetSetProjectInfo = function(_, k, v, set) if set then PROJ[k] = v end return PROJ[k] or 0 end
      reaper.GetSetProjectInfo_String = function(_, k, v, set)
        if k == 'RENDER_TARGETS' then return true, PROJS.RENDER_FILE .. '/' .. PROJS.RENDER_PATTERN .. '.wav' end
        if set then PROJS[k] = v end
        return true, PROJS[k] or ''
      end
      SEEN = {}
      reaper.Main_OnCommand = function(id)
        SEEN[#SEEN + 1] = id
        if id == 42230 then
          SEEN.during = { PROJ.RENDER_STARTPOS, PROJ.RENDER_ENDPOS, PROJ.RENDER_SETTINGS, PROJS.RENDER_FORMAT }
          local f = io.open(PROJS.RENDER_FILE .. '/' .. PROJS.RENDER_PATTERN .. '.wav', 'wb'); f:write('RIFF'); f:close()
        end
      end
      reaper.RecursiveCreateDirectory = function(d) MKDIR(d) end
      reaper.PCM_Source_CreateFromFile = function() return {} end
      reaper.CalculateNormalization = function(_, mode) return ({ [0] = 2.5, [3] = 1.1, [5] = 2.0 })[mode] end
    """)
    if OS_NAME.startswith("Win"):
        return  # the render/measure path is the same; the CLI line differs (covered by the recover test)
    p.lua.execute("RET.InvisibleButton = function(_, id) return id == '##chip_ears' end")
    p.m.studio.ears_chip()
    p.lua.execute("RET.InvisibleButton = nil")
    g = p.lua.globals()
    seen = p.lua_list(g.SEEN)
    check("ears: media online, then one render of the selection as the master mix in WAV",
          seen == [40101, 42230] and g.SEEN.during[1] == 10.0 and g.SEEN.during[2] == 14.0
          and g.SEEN.during[3] == 0 and g.SEEN.during[4] == "ZXZhdxgAAQ==", seen)
    check("ears: the project's render settings come back", g.PROJ.RENDER_SETTINGS == 1 and g.PROJS.RENDER_FILE == "/my/renders"
          and g.PROJS.RENDER_PATTERN == "mix" and g.PROJS.RENDER_FORMAT == "b2dnZw==")
    cmds = [c for c in p.lua_list(g.CMDS) if " ears " in c]
    check("ears: `hibiki ears` runs in the background with REAPER's loudness numbers",
          len(cmds) == 1 and "--lufs-i -7.96" in cmds[0] and "--tp -0.83" in cmds[0] and "--label 'bars 6.1-8.1'" in cmds[0], cmds)
    base = re.search(r"""> '([^']+ears[^']+)\.out'""", cmds[0]).group(1)
    wav = re.search(r"ears '([^']+\.wav)'", cmds[0]).group(1)
    png, md = wav[:-4] + ".png", wav[:-4] + ".md"
    Path(png).write_bytes(b"png")
    Path(md).write_text("# Ears")
    Path(base + ".out").write_text(json.dumps({"ok": True, "png": png, "md": md, "tilt_db_per_octave": -1.2,
                                               "peaks_over_tilt": [{"band": "3.15k", "db": 4.1}]}))
    Path(base + ".done").write_text("0")
    p.m.poll_http()
    files = p.lua_list(p.S.files)
    names = [f.name for f in files]
    check("ears: picture, summary and audio attached as one group", len(names) == 3 and names[0].endswith(".png")
          and names[2].endswith(".wav") and len({f.group for f in files}) == 1 and files[0].group == "Ears bars 6.1-8.1", names)
    body = p.m.context(True)[0]
    check("ears: the next message's context carries the numbers once",
          "ears: bars 6.1-8.1 (time selection, 4.0 s)" in body and "LUFS-I -8.0" in body and "3.15k +4.1" in body
          and "ears: bars" not in p.m.context(True)[0], body[-500:])



def test_saved_versions():
    if OS_NAME.startswith("Win"):
        return  # the paths use \\ there, which this host's filesystem can't take; the logic is the same
    p = studio_panel()
    st = p.lua.globals().EXT_STATE
    proj_dir = p.tmp / "Song"
    proj_dir.mkdir()
    proj = str(proj_dir / "Song.RPP")
    p.lua.globals().PROJ_PATH = proj
    p.lua.execute(r"""
      reaper.EnumProjects = function() return 0, PROJ_PATH end
      SAVED, OPENED, CHANGES = {}, {}, 5
      reaper.GetProjectStateChangeCount = function() return CHANGES end
      reaper.IsProjectDirty = function() return 1 end
      reaper.Main_SaveProjectEx = function(_, path) SAVED[#SAVED + 1] = path; local f = io.open(path, 'wb'); f:write('<REAPER_PROJECT\n>'); f:close() end
      reaper.Main_openProject = function(path) OPENED[#OPENED + 1] = path end
      reaper.RecursiveCreateDirectory = function(d) MKDIR(d) end
    """)
    p.type_and_send("thin the pad")
    turn = st["Hibiki/turn"]
    st["Hibiki/receipts"] = json.dumps([{"id": turn, "proj": proj, "at": 1, "n": 2, "points": 1,
                                         "lines": ["#3 Pad: volume -3.0 dB", "#3 Pad: add ReaEQ"]}])
    st["Hibiki/receipts_seq"] = "s1"
    p.m.studio.tick(3000)
    check("saved versions: nothing while the reply runs", len(p.lua_list(p.lua.globals().SAVED)) == 0)
    p.sse({"type": "stream_delta", "text": "Pad 降了 3 dB，加了 ReaEQ 切低频。"}, {"type": "session_idle"})
    p.requests()
    p.m.studio.tick(3001)
    saved = p.lua_list(p.lua.globals().SAVED)
    hist = proj_dir / ".hibiki/history/Song"
    check("saved versions: one copy of the project in .hibiki/history after the reply",
          len(saved) == 1 and os.path.normpath(saved[0]).startswith(os.path.normpath(str(hist))) and saved[0].endswith(".RPP"), saved)
    e = json.loads((hist / "index.jsonl").read_text(encoding="utf-8").splitlines()[0])
    check("saved versions: titled with the reply's first sentence, the change list kept for the tooltip",
          e["what"] == "Pad 降了 3 dB，加了 ReaEQ 切低频" and e["lines"] == ["#3 Pad: volume -3.0 dB", "#3 Pad: add ReaEQ"], e)
    cmds = [c for c in p.lua_list(p.lua.globals().CMDS) if "gzip -9" in c]
    check("saved versions: compressed and pruned to the newest 200 in the background",
          len(cmds) == 1 and "tail -n +201" in cmds[0] and cmds[0].rstrip().endswith("&"), cmds)
    p.m.studio.tick(3002)
    check("saved versions: once per reply", len(p.lua_list(p.lua.globals().SAVED)) == 1)
    rows = p.lua_list(p.m.studio._rows())
    check("version history: one row per saved version", len(rows) == 1 and rows[0].what == "Pad 降了 3 dB，加了 ReaEQ 切低频")
    import time
    time.sleep(1.1)  # versions are one a second
    p.lua.execute("CHANGES = 9")  # the user edited since: going somewhere saves Current first
    p.m.studio._SV.go(rows[0].e)
    saved = p.lua_list(p.lua.globals().SAVED)
    opened = p.lua_list(p.lua.globals().OPENED)
    check("Go to: Current is saved as a version first, then the version is written over the project and reopened",
          len(saved) == 3 and os.path.normpath(saved[1]).startswith(os.path.normpath(str(hist))) and saved[2] == proj
          and len(opened) == 2 and opened[1] == "noprompt:" + proj, (saved, opened))
    rows = p.lua_list(p.m.studio._rows())
    check("Go to: the saved Current is the newest row", rows[0].what.startswith("Before going to"), [r.what for r in rows])


def test_cli_in_dev_mode():
    if OS_NAME.startswith("Win"):
        return  # Windows has no dev mode yet; its CLI line is covered by the recover test
    p = Panel(SESSION)
    p.boot()
    cfg = p.tmp / ".config/reaper-mcp"
    cfg.mkdir(parents=True)
    checkout = p.tmp / "clone"
    (checkout / "reaper_mcp").mkdir(parents=True)
    (checkout / "reaper_mcp/cli.py").write_text("")
    py = p.tmp / "py3"
    py.write_text("")
    (cfg / "mode.json").write_text(json.dumps({"mode": "dev", "path": str(checkout), "python": str(py)}))
    p.m.REC.cli("update", "update --check --json", lambda *a: None)
    cmds = [c for c in p.lua_list(p.lua.globals().CMDS) if "update --check --json" in c]
    check("dev mode: the panel runs the checkout's CLI with the recorded Python, not /usr/local/bin/hibiki",
          len(cmds) == 1 and ("'%s' -s -E '" % py) in cmds[0] and "reaper_mcp/cli.py' update" in cmds[0]
          and "/usr/local/bin/hibiki" not in cmds[0], cmds)
    (cfg / "mode.json").write_text(json.dumps({"mode": "dev", "path": str(p.tmp / "gone"), "python": str(py)}))
    p.m.REC.cli("update", "update --check --json", lambda *a: None)
    cmds = [c for c in p.lua_list(p.lua.globals().CMDS) if "update --check --json" in c]
    check("dev mode with a missing checkout: back to the installed CLI", "/usr/local/bin/hibiki" in cmds[-1], cmds[-1])

def main():
    global OS_NAME
    try:
        import lupa  # noqa: F401
    except ImportError:
        raise SystemExit("needs lupa: uv run --with lupa python panel/test_panel.py")
    if "--bench" in sys.argv:
        bench()
        return
    for OS_NAME in ("macOS-arm64", "Win64"):
        print("== " + OS_NAME)
        for name, fn in list(globals().items()):
            if name.startswith("test_"):
                print(name)
                try:
                    fn()
                except Exception as e:  # noqa: BLE001 - report and keep going
                    print("  FAIL %s raised %r" % (name, e))
                    failures.append(OS_NAME + ":" + name)
    if failures:
        print("FAILED", failures)
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main()
