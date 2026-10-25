--[[
  reaper-mcp bridge — runs inside REAPER as a deferred ReaScript.

  Python writes  <ipc>/request.json   {id, func, args|code}
  Lua writes     <ipc>/response.json  {id, ok, ret|error}
  Lua touches    <ipc>/heartbeat      every defer tick
  Lua writes     <ipc>/busy           while dispatch is running (defer cannot tick)

  Load via Actions > Load ReaScript and keep it running.
]]

local VERSION = "0.6.0-rc.2"
local DEBUG = (os.getenv and os.getenv("REAPER_MCP_DEBUG") == "1") or false

local function log(s)
  if DEBUG then reaper.ShowConsoleMsg(s .. "\n") end
end

local function ipc_dir()
  local env = os.getenv("REAPER_MCP_IPC_DIR")
  if env and env ~= "" then
    local sep = env:find("\\") and "\\" or "/"
    if env:sub(-1) ~= "/" and env:sub(-1) ~= "\\" then env = env .. sep end
    return env
  end
  local appdata = os.getenv("APPDATA")
  if appdata and appdata ~= "" then
    return appdata .. "\\reaper-mcp\\ipc\\"
  end
  local home = os.getenv("HOME") or ""
  local osname = reaper.GetOS()
  if osname:match("OSX") or osname:match("macOS") or osname:match("darwin") then
    return home .. "/Library/Application Support/reaper-mcp/ipc/"
  end
  local xdg = os.getenv("XDG_DATA_HOME")
  if xdg and xdg ~= "" then
    return xdg .. "/reaper-mcp/ipc/"
  end
  return home .. "/.local/share/reaper-mcp/ipc/"
end

local DIR = ipc_dir()
local REQ = DIR .. "request.json"
local RESP = DIR .. "response.json"
local TMP = DIR .. "response.tmp"
local HEART = DIR .. "heartbeat"
local BUSY = DIR .. "busy"
-- one id per REAPER process (non-persistent ExtState), so a bridge reloaded into the same REAPER keeps it; a
-- second REAPER gets another and leaves the mailbox alone while the first one's heartbeat is fresh
local INSTANCE = reaper.GetExtState("reaper_mcp", "instance")
if INSTANCE == "" then
  INSTANCE = ("%x%08x%04x"):format(os.time(), math.floor((reaper.time_precise() % 1) * 0xFFFFFFFF),
    math.random(0, 0xFFFF))
  reaper.SetExtState("reaper_mcp", "instance", INSTANCE, false)
end
local CLAIM = DIR .. "request." .. INSTANCE .. ".claimed"

----------------------------------------------------------------------
-- JSON
----------------------------------------------------------------------
local json = {}
do
  local esc = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
  }
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
  local function is_cont(s, i)
    local b = s:byte(i)
    return b ~= nil and b >= 0x80 and b < 0xC0
  end
  local SPECIAL = '[%c"\\\128-\255]'
  local function esc_str(s)
    local i = s:find(SPECIAL)
    if not i then return '"' .. s .. '"' end
    local parts, np, run, n = {'"'}, 1, 1, #s
    while i do
      local b = s:byte(i)
      local skip
      if b < 32 or b == 34 or b == 92 then
        skip = esc[s:sub(i, i)] or string.format('\\u%04x', b)
      elseif b >= 128 then
        local len = utf8_len(s, i)
        local ok = len ~= nil and (i + len - 1) <= n
        if ok then
          for j = i + 1, i + len - 1 do
            if not is_cont(s, j) then ok = false break end
          end
        end
        if ok then i = i + len - 1 else skip = string.format('\\u%04x', b) end
      end
      if skip then
        if i > run then np = np + 1; parts[np] = s:sub(run, i - 1) end
        np = np + 1; parts[np] = skip
        run = i + 1
      end
      i = s:find(SPECIAL, i + 1)
    end
    if run <= n then np = np + 1; parts[np] = s:sub(run, n) end
    parts[np + 1] = '"'
    return table.concat(parts)
  end
  local encode
  local function is_array(t)
    local n = 0
    for k in pairs(t) do
      if type(k) ~= "number" then return false end
      n = n + 1
    end
    return n == #t
  end
  local function forced_object(t)
    local mt = getmetatable(t)
    return mt ~= nil and mt.__jsontype == "object"
  end
  -- explicit JSON null, so arrays with nulls keep their length and positions
  json.null = setmetatable({}, { __jsontype = "null" })
  -- decoded arrays remember their length (a null element leaves a nil hole that # can't see)
  json.len = function(t)
    local mt = getmetatable(t)
    return mt and mt.__n or #t
  end
  json.userdata_hook = function(_) return nil end
  encode = function(v, seen)
    local tv = type(v)
    if v == nil then return "null"
    elseif tv == "boolean" then return tostring(v)
    elseif tv == "number" then
      if v ~= v or v == math.huge or v == -math.huge then return "null" end
      if v == math.floor(v) and math.abs(v) < 1e15 then
        return string.format("%d", v)
      end
      return string.format("%.17g", v)
    elseif tv == "string" then return esc_str(v)
    elseif tv == "userdata" then return encode(json.userdata_hook(v), seen)
    elseif tv == "table" then
      if v == json.null then return "null" end
      seen = seen or {}
      if seen[v] then return "null" end
      seen[v] = true
      local out
      if is_array(v) and not forced_object(v) then
        local parts = {}
        for i = 1, #v do parts[i] = encode(v[i], seen) end
        out = "[" .. table.concat(parts, ",") .. "]"
      else
        local parts = {}
        for k, val in pairs(v) do
          parts[#parts + 1] = esc_str(tostring(k)) .. ":" .. encode(val, seen)
        end
        out = "{" .. table.concat(parts, ",") .. "}"
      end
      seen[v] = nil
      return out
    else
      return "null"
    end
  end
  json.encode = function(v) return encode(v, nil) end
  json.object = function(t) return setmetatable(t or {}, { __jsontype = "object" }) end

  local UNESC = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f",
                  ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
  local function ws(s, j) return s:find("[^ \t\r\n]", j) or (#s + 1) end
  local function utf8_char(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then
      return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
      return string.char(
        0xE0 + math.floor(cp / 0x1000),
        0x80 + math.floor(cp / 0x40) % 0x40,
        0x80 + cp % 0x40)
    end
    return string.char(
      0xF0 + math.floor(cp / 0x40000),
      0x80 + math.floor(cp / 0x1000) % 0x40,
      0x80 + math.floor(cp / 0x40) % 0x40,
      0x80 + cp % 0x40)
  end

  local function decode(s, i)
    i = ws(s, i)
    local c = s:byte(i)
    if c == 123 then
      local obj = {}
      i = ws(s, i + 1)
      if s:byte(i) == 125 then return obj, i + 1 end
      while true do
        local key, val
        key, i = decode(s, i)
        i = ws(s, i)
        assert(s:byte(i) == 58, "expected :")
        val, i = decode(s, i + 1)
        obj[key] = val
        i = ws(s, i)
        local ch = s:byte(i)
        if ch == 44 then i = i + 1
        elseif ch == 125 then return obj, i + 1
        else error("expected , or }") end
      end
    elseif c == 91 then
      local arr, n = {}, 0
      i = ws(s, i + 1)
      if s:byte(i) == 93 then return arr, i + 1 end
      while true do
        local val
        val, i = decode(s, i)
        n = n + 1
        arr[n] = val
        i = ws(s, i)
        local ch = s:byte(i)
        if ch == 44 then i = i + 1
        elseif ch == 93 then return setmetatable(arr, { __n = n }), i + 1
        else error("expected , or ]") end
      end
    elseif c == 34 then
      local j = i + 1
      local k = s:find('["\\]', j)
      if not k then error("unterminated string") end
      if s:byte(k) == 34 then return s:sub(j, k - 1), k + 1 end
      local buf, nb = {}, 0
      while true do
        if k > j then nb = nb + 1; buf[nb] = s:sub(j, k - 1) end
        if s:byte(k) == 34 then return table.concat(buf), k + 1 end
        local e = s:sub(k + 1, k + 1)
        if e == "u" then
          local cp = tonumber(s:sub(k + 2, k + 5), 16) or 0
          -- a UTF-16 surrogate pair (\uD83C\uDFB5) is one code point: combine it, don't emit two halves
          local lo = cp >= 0xD800 and cp <= 0xDBFF and s:sub(k + 6, k + 7) == "\\u"
            and tonumber(s:sub(k + 8, k + 11), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            k = k + 6
          end
          nb = nb + 1; buf[nb] = utf8_char(cp)
          j = k + 6
        else
          if e == "" then error("unterminated string") end
          nb = nb + 1; buf[nb] = UNESC[e] or e
          j = k + 2
        end
        k = s:find('["\\]', j)
        if not k then error("unterminated string") end
      end
    elseif c and (c == 45 or (c >= 48 and c <= 57)) then
      local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
      return tonumber(num), i + #num
    elseif s:sub(i, i + 3) == "true" then return true, i + 4
    elseif s:sub(i, i + 4) == "false" then return false, i + 5
    elseif s:sub(i, i + 3) == "null" then return nil, i + 4
    else error("unexpected char at " .. i) end
  end
  json.decode = function(s)
    if not s or s == "" then return nil end
    local ok, v = pcall(function() return decode(s, 1) end)
    if ok then return v else return nil, v end
  end
end

----------------------------------------------------------------------
-- files
----------------------------------------------------------------------
local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local c = f:read("*a")
  f:close()
  return c
end

local function write_atomic(final, content, tmp)
  tmp = tmp or (final .. ".tmp")
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write(content)
  f:close()
  os.remove(final)
  if not os.rename(tmp, final) then
    local g = io.open(final, "wb")
    if g then g:write(content) g:close() end
    os.remove(tmp)
  end
  return true
end

-- Python treats a heartbeat older than REAPER_MCP_HEARTBEAT_STALE (5s) as a dead
-- bridge, so 0.5s is plenty. Rewriting it every defer tick was pure idle I/O.
local HEARTBEAT_INTERVAL = 0.5
local last_heartbeat = -math.huge
local function touch_heartbeat(force)
  local now = reaper.time_precise()
  if not force and (now - last_heartbeat) < HEARTBEAT_INTERVAL then return end
  last_heartbeat = now
  local f = io.open(HEART, "wb")
  if f then f:write(INSTANCE .. " " .. os.time()) f:close() end
end

-- another REAPER's bridge wrote the heartbeat within the last few seconds (server.py's stale limit is 5 s)
local function other_bridge_alive()
  local f = io.open(HEART, "rb")
  if not f then return false end
  local inst, t = (f:read("*a") or ""):match("^(%S+) (%d+)$")
  f:close()
  return inst ~= nil and inst ~= INSTANCE and os.time() - tonumber(t) <= 5
end

----------------------------------------------------------------------
-- handle registry (userdata round-trip)
----------------------------------------------------------------------
local handles, handle_rev, handle_seq = {}, {}, 0
local function to_handle(ud)
  local key = tostring(ud)
  if handle_rev[key] then return handle_rev[key] end
  handle_seq = handle_seq + 1
  local id = "h" .. handle_seq
  handles[id] = ud
  handle_rev[key] = id
  return id
end
json.userdata_hook = function(ud) return { __handle = to_handle(ud) } end

local function unmarshal(v)
  if type(v) == "table" then
    if v.__handle ~= nil then
      local ud = handles[v.__handle]
      if ud == nil then error("unknown handle: " .. tostring(v.__handle)) end
      return ud
    end
    for k, val in pairs(v) do v[k] = unmarshal(val) end
    return v
  end
  return v
end

----------------------------------------------------------------------
-- DSL
----------------------------------------------------------------------
local function track_at(i)
  if i == -1 then return reaper.GetMasterTrack(0) end
  local t = reaper.GetTrack(0, i)
  if not t then error("no track at index " .. tostring(i)) end
  return t
end

-- Absolute project quarter notes.
local function beats_to_time(b) return reaper.TimeMap2_QNToTime(0, b or 0) end
local function time_to_beats(t) return reaper.TimeMap2_timeToQN(0, t or 0) end

local dispatch
local DSL = {}
local RUN_LUA_TIMEOUT = 10 -- seconds, when the request names none (server.py sends its own)
local MIDI_FUNCS = {
  add_midi_notes = true, replace_midi_notes = true,
  update_midi_note = true, delete_midi_notes = true,
  add_midi_cc = true,
}

-- A batch used to pay one arrange/timeline/layout refresh per sub-call. Coalesce
-- them: while a batch is running the requests are only recorded, and one real
-- refresh of each kind happens when the outermost batch finishes.
local batch_depth = 0
local pending_arrange, pending_tracks, pending_timeline = false, false, false

local function refresh_arrange()
  if batch_depth > 0 then pending_arrange = true else reaper.UpdateArrange() end
end

local function refresh_tracks()
  if batch_depth > 0 then pending_tracks = true else reaper.TrackList_AdjustWindows(false) end
end

local function refresh_timeline()
  if batch_depth > 0 then pending_timeline = true else reaper.UpdateTimeline() end
end

local function flush_refresh()
  if batch_depth > 0 then return end
  if pending_arrange then pending_arrange = false reaper.UpdateArrange() end
  if pending_tracks then pending_tracks = false reaper.TrackList_AdjustWindows(false) end
  if pending_timeline then pending_timeline = false reaper.UpdateTimeline() end
end

local function vol_db(t)
  local vol = reaper.GetMediaTrackInfo_Value(t, "D_VOL")
  if vol <= 0 then return -150 end
  return 20 * math.log(vol) / math.log(10)
end

local function db_of(gain)
  if not gain or gain <= 0 then return -150 end
  return 20 * math.log(gain) / math.log(10)
end

-- I_SOLO can read 0 while REAPER still solos (UI solo state), so trust AnyTrackSolo when it exists.
local function any_solo()
  if reaper.AnyTrackSolo then return reaper.AnyTrackSolo(0) and true or false end
  for i = 0, reaper.CountTracks(0) - 1 do
    if reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, i), "I_SOLO") ~= 0 then return true end
  end
  return false
end

local function soloed_tracks()
  local out = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    if reaper.GetMediaTrackInfo_Value(t, "I_SOLO") ~= 0 then
      local _, name = reaper.GetTrackName(t)
      out[#out + 1] = string.format("%d %s", i, name)
    end
  end
  return out
end

-- igngroupflags 3: no group or selection ganging (flag 0 soloed every selected track along with t)
local function set_solo(t, on)
  if reaper.SetTrackUISolo then reaper.SetTrackUISolo(t, on and 1 or 0, 3) end
  reaper.SetMediaTrackInfo_Value(t, "I_SOLO", on and 2 or 0) -- 2 = solo in place
end

function DSL.ping()
  return { ret = { pong = true, version = VERSION, reaper = reaper.GetAppVersion() } }
end

local MAX_SELECTED_ITEMS = 200

function DSL.get_project_summary(detail)
  local n = reaper.CountTracks(0)
  local tracks = {}
  for i = 0, n - 1 do
    local t = reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(t)
    local rec = {
      index = i, name = name, volume_db = vol_db(t),
      mute = reaper.GetMediaTrackInfo_Value(t, "B_MUTE") == 1,
      solo = reaper.GetMediaTrackInfo_Value(t, "I_SOLO") ~= 0,
      item_count = reaper.CountTrackMediaItems(t),
      fx_count = reaper.TrackFX_GetCount(t),
    }
    if reaper.IsTrackSelected(t) then rec.selected = true end
    if detail then
      local has_midi, has_audio, midi_notes = false, false, 0
      for j = 0, rec.item_count - 1 do
        local take = reaper.GetActiveTake(reaper.GetTrackMediaItem(t, j))
        if take and reaper.TakeIsMIDI(take) then
          has_midi = true
          local _, nc = reaper.MIDI_CountEvts(take)
          midi_notes = midi_notes + (nc or 0)
        elseif take then
          has_audio = true
        end
      end
      rec.has_midi = has_midi
      rec.has_audio = has_audio
      if has_midi then rec.midi_note_count = midi_notes end
      local fd = reaper.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
      if fd ~= 0 then rec.folder_depth = fd end
    end
    tracks[#tracks + 1] = rec
  end
  local _, proj = reaper.EnumProjects(-1, "")
  local ret = {
    project = proj ~= "" and proj or "(unsaved)",
    tempo_bpm = reaper.Master_GetTempo(),
    play_state = reaper.GetPlayState(),
    cursor_seconds = reaper.GetCursorPosition(),
    track_count = n,
    tracks = tracks,
    -- a lingering solo or a muted master silently changes every render; surface both
    any_solo = any_solo(),
    master_mute = reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "B_MUTE") == 1,
  }
  if reaper.IsProjectDirty then ret.dirty = reaper.IsProjectDirty(0) ~= 0 end
  ret.cursor_beats = time_to_beats(ret.cursor_seconds)
  local ts, te = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if te > ts then ret.time_selection = { start_beats = time_to_beats(ts), end_beats = time_to_beats(te) } end
  local nsel = reaper.CountSelectedMediaItems(0)
  if nsel > 0 then
    local sel = {}
    for i = 0, math.min(nsel, MAX_SELECTED_ITEMS) - 1 do
      local it = reaper.GetSelectedMediaItem(0, i)
      sel[#sel + 1] = { track_index = math.floor(reaper.GetMediaTrackInfo_Value(reaper.GetMediaItem_Track(it), "IP_TRACKNUMBER")) - 1,
                        item_index = math.floor(reaper.GetMediaItemInfo_Value(it, "IP_ITEMNUMBER")) }
    end
    ret.selected_items = sel
    if nsel > MAX_SELECTED_ITEMS then ret.selected_items_total = nsel end
  end
  if detail then
    local num, denom = 4, 4
    if reaper.TimeMap_GetTimeSigAtTime then
      local a, b = reaper.TimeMap_GetTimeSigAtTime(0, 0)
      if type(a) == "number" and a > 0 then num = a end
      if type(b) == "number" and b > 0 then denom = b end
    end
    local length_sec = 0
    if reaper.GetProjectLength then length_sec = reaper.GetProjectLength(0) or 0 end
    ret.time_sig = { numerator = num, denominator = denom } -- at the project start; tempo_map lists the changes
    ret.length_beats = time_to_beats(length_sec)
    local nt = reaper.CountTempoTimeSigMarkers(0)
    if nt > 0 then
      local map = {}
      for i = 0, nt - 1 do
        local _, tpos, _, _, bpm, tnum, tden, linear = reaper.GetTempoTimeSigMarker(0, i)
        local m = { beats = time_to_beats(tpos), bpm = bpm }
        if tnum and tnum > 0 then m.numerator, m.denominator = tnum, tden end
        if linear then m.linear = true end
        map[#map + 1] = m
      end
      ret.tempo_map = map
    end
    local markers = {}
    local nm = 0
    if reaper.CountProjectMarkers then nm = reaper.CountProjectMarkers(0) or 0 end
    for i = 0, nm - 1 do
      local retval, isrgn, pos, rgnend, name, idx = reaper.EnumProjectMarkers(i)
      if retval and retval ~= 0 then
        local m = {
          index = idx,
          name = name or "",
          position_beats = time_to_beats(pos),
          is_region = isrgn and true or false,
        }
        if isrgn then m.end_beats = time_to_beats(rgnend) end
        markers[#markers + 1] = m
      end
    end
    ret.markers = markers
  end
  return { ret = ret }
end

function DSL.list_tracks()
  return { ret = DSL.get_project_summary().ret.tracks }
end

function DSL.add_track(name, index)
  index = index or reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(index, true)
  refresh_tracks()
  local t = reaper.GetTrack(0, index)
  if name and name ~= "" then
    reaper.GetSetMediaTrackInfo_String(t, "P_NAME", name, true)
  end
  refresh_arrange()
  return { ret = { index = index, name = name or "" } }
end

function DSL.delete_track(index)
  if index == -1 then error("cannot delete the master track") end
  reaper.DeleteTrack(track_at(index))
  refresh_arrange()
  return { ret = true }
end

function DSL.update_track(index, props)
  local t = track_at(index)
  props = props or {}
  if props.name ~= nil then
    reaper.GetSetMediaTrackInfo_String(t, "P_NAME", tostring(props.name), true)
  end
  if props.volume_db ~= nil then
    reaper.SetMediaTrackInfo_Value(t, "D_VOL", 10 ^ (props.volume_db / 20))
  end
  if props.pan ~= nil then
    reaper.SetMediaTrackInfo_Value(t, "D_PAN", props.pan)
  end
  if props.mute ~= nil then
    reaper.SetMediaTrackInfo_Value(t, "B_MUTE", props.mute and 1 or 0)
  end
  if props.solo ~= nil then
    reaper.SetMediaTrackInfo_Value(t, "I_SOLO", props.solo and 1 or 0)
  end
  refresh_arrange()
  return { ret = true }
end

function DSL.set_tempo(bpm)
  reaper.SetCurrentBPM(0, bpm, true)
  return { ret = bpm }
end

function DSL.set_time_signature(num, denom)
  reaper.SetTempoTimeSigMarker(0, -1, 0, -1, -1, reaper.Master_GetTempo(),
    num, denom, false)
  refresh_timeline()
  return { ret = { num = num, denom = denom } }
end

-- a marker or region by its number (as REAPER shows it) or its name; regions give their start
local function marker_time(m)
  local want = tostring(m):lower()
  local i = 0
  while true do
    local retval, _, pos, _, name, num = reaper.EnumProjectMarkers(i)
    if not retval or retval == 0 then break end
    if (type(m) == "number" and num == m) or (type(m) ~= "number" and (name or ""):lower() == want) then return pos end
    i = i + 1
  end
  error("no marker or region " .. (type(m) == "number" and "#" .. m or ("named " .. tostring(m))), 0)
end

function DSL.transport(action, opts)
  local cmds = {
    play = 1007, stop = 1016, pause = 1008, record = 1013,
    toggle_repeat = 1068, goto_start = 40042,
  }
  if action == "goto" then
    opts = opts or {}
    local t
    if opts.position_beats ~= nil then t = beats_to_time(opts.position_beats)
    elseif opts.marker ~= nil then t = marker_time(opts.marker)
    else error("goto needs position_beats or marker", 0) end
    reaper.SetEditCurPos(t, true, true) -- moves the view, and playback when playing
  else
    local cmd = cmds[action]
    if not cmd then error("unknown transport action: " .. tostring(action)) end
    reaper.Main_OnCommand(cmd, 0)
  end
  local state = reaper.GetPlayState()
  local pos = (state & 1) == 1 and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  return { ret = { play_state = state, position_sec = pos, position_beats = time_to_beats(pos) } }
end

function DSL.action(command_id)
  reaper.Main_OnCommand(tonumber(command_id), 0)
  return { ret = true }
end

function DSL.create_midi_item(ti, start_beats, length_beats)
  local t = track_at(ti)
  local s = beats_to_time(start_beats or 0)
  local e = beats_to_time((start_beats or 0) + (length_beats or 4))
  local item = reaper.CreateNewMIDIItemInProj(t, s, e, false)
  reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
  -- IP_ITEMNUMBER is the item's index inside its track, so this replaces a scan
  -- of every item on the track. Verify it, since the property is a fallback 0 on
  -- builds that do not know it.
  local idx = math.floor(reaper.GetMediaItemInfo_Value(item, "IP_ITEMNUMBER"))
  if not (idx >= 0 and reaper.GetTrackMediaItem(t, idx) == item) then
    idx = -1
    for i = 0, reaper.CountTrackMediaItems(t) - 1 do
      if reaper.GetTrackMediaItem(t, i) == item then idx = i break end
    end
  end
  refresh_arrange()
  return { ret = {
    item_index = idx, handle = to_handle(item),
    start_beats = start_beats or 0, length_beats = length_beats or 4,
  } }
end

local function midi_take_at(ti, ii)
  local item = reaper.GetTrackMediaItem(track_at(ti), ii)
  if not item then error("no item at index " .. tostring(ii)) end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then error("item take is not MIDI") end
  return take
end

local function validate_notes(notes)
  if not notes or #notes == 0 then error("notes array is empty") end
  if #notes > 10000 then error("refusing more than 10000 notes in one call") end
  for i, nt in ipairs(notes) do
    if type(nt) ~= "table" or type(nt.pitch) ~= "number" or type(nt.start_beats) ~= "number" then
      error("note #" .. i .. " needs numeric pitch and start_beats")
    end
  end
end

local function insert_notes(take, notes)
  local count = 0
  for _, nt in ipairs(notes) do
    local sppq = reaper.MIDI_GetPPQPosFromProjQN(take, nt.start_beats)
    local eppq = reaper.MIDI_GetPPQPosFromProjQN(take, nt.start_beats + (nt.length_beats or 1))
    reaper.MIDI_InsertNote(take, false, nt.muted == true, sppq, eppq,
      nt.channel or 0, nt.pitch, nt.velocity or 96, true)
    count = count + 1
  end
  return count
end

local function extend_item_to_notes(take, notes)
  local max_qn
  for _, nt in ipairs(notes or {}) do
    -- Same 1-beat default as insert_notes, so a note without length_beats is
    -- covered by the item extension instead of hanging past its end.
    local e = (nt.start_beats or 0) + (nt.length_beats or 1)
    if not max_qn or e > max_qn then max_qn = e end
  end
  if not max_qn then return false end
  local item = reaper.GetMediaItemTake_Item(take)
  local want_end = reaper.TimeMap2_QNToTime(0, max_qn)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  if want_end > pos + len + 1e-9 then
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", want_end - pos)
    return true
  end
  return false
end

local undo_depth = 0 -- > 0 while a request runs inside its turn's undo block (see run_request)

local function record_item_undo(take, desc)
  local item = reaper.GetMediaItemTake_Item(take)
  if undo_depth > 0 then
    -- inside the request's block: marking the item is enough for EndBlock to capture the MIDI edit
    if reaper.MarkTrackItemsDirty then reaper.MarkTrackItemsDirty(reaper.GetMediaItem_Track(item), item) end
    return
  end
  reaper.Undo_OnStateChange_Item(0, desc, item)
end

function DSL.add_midi_notes(ti, ii, notes)
  local take = midi_take_at(ti, ii)
  validate_notes(notes)
  local count = insert_notes(take, notes)
  reaper.MIDI_Sort(take)
  local extended = extend_item_to_notes(take, notes)
  record_item_undo(take, "MCP: add MIDI notes")
  refresh_arrange()
  local ret = { inserted = count }
  if extended then ret.item_extended = true end
  return { ret = ret }
end

function DSL.get_midi_notes(ti, ii)
  local take = midi_take_at(ti, ii)
  local _, noteCount = reaper.MIDI_CountEvts(take)
  local notes = {}
  for i = 0, noteCount - 1 do
    local _, sel, muted, sppq, eppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    local sqn = reaper.MIDI_GetProjQNFromPPQPos(take, sppq)
    local eqn = reaper.MIDI_GetProjQNFromPPQPos(take, eppq)
    local n = {
      pitch = pitch, velocity = vel,
      start_beats = sqn, length_beats = eqn - sqn,
    }
    if chan ~= 0 then n.channel = chan end
    if muted then n.muted = true end
    if sel then n.selected = true end
    notes[#notes + 1] = n
  end
  return { ret = notes }
end

-- CC, program change and pitch bend, in the shape `midi cc` takes (pitch_bend -8192..8191)
function DSL.get_midi_cc(ti, ii)
  local take = midi_take_at(ti, ii)
  local _, _, ccCount = reaper.MIDI_CountEvts(take)
  local out = {}
  for i = 0, (ccCount or 0) - 1 do
    local _, sel, muted, ppq, chanmsg, chan, m2, m3 = reaper.MIDI_GetCC(take, i)
    local e = { start_beats = reaper.MIDI_GetProjQNFromPPQPos(take, ppq) }
    if chanmsg == 0xB0 then e.cc, e.value = m2, m3
    elseif chanmsg == 0xC0 then e.program = m2
    elseif chanmsg == 0xE0 then e.pitch_bend = ((m3 << 7) | m2) - 8192
    else e.status, e.msg2, e.msg3 = chanmsg, m2, m3 end
    if chan ~= 0 then e.channel = chan end
    if muted then e.muted = true end
    if sel then e.selected = true end
    out[#out + 1] = e
  end
  return { ret = out }
end

function DSL.replace_midi_notes(ti, ii, notes)
  local take = midi_take_at(ti, ii)
  validate_notes(notes)
  local _, noteCount = reaper.MIDI_CountEvts(take)
  for i = noteCount - 1, 0, -1 do reaper.MIDI_DeleteNote(take, i) end
  local count = insert_notes(take, notes)
  reaper.MIDI_Sort(take)
  local extended = extend_item_to_notes(take, notes)
  record_item_undo(take, "MCP: replace MIDI notes")
  refresh_arrange()
  local ret = { inserted = count }
  if extended then ret.item_extended = true end
  return { ret = ret }
end

function DSL.update_midi_note(ti, ii, note_index, changes)
  local take = midi_take_at(ti, ii)
  local _, noteCount = reaper.MIDI_CountEvts(take)
  if type(note_index) ~= "number" or note_index < 0 or note_index >= noteCount then
    error("no note at index " .. tostring(note_index))
  end
  local _, _, muted, sppq, eppq, chan, pitch, vel = reaper.MIDI_GetNote(take, note_index)
  local ch = changes or {}
  local orig_start_qn = reaper.MIDI_GetProjQNFromPPQPos(take, sppq)
  local start_qn = ch.start_beats or orig_start_qn
  local end_qn = start_qn + (ch.length_beats or (
    reaper.MIDI_GetProjQNFromPPQPos(take, eppq) - orig_start_qn))
  local new_muted = muted
  if ch.muted ~= nil then new_muted = ch.muted and true or false end
  -- noSort here, then one explicit sort below: MIDI_SetNote used to sort as well,
  -- which sorted the whole event list twice per note.
  reaper.MIDI_SetNote(take, note_index, nil, new_muted,
    reaper.MIDI_GetPPQPosFromProjQN(take, start_qn),
    reaper.MIDI_GetPPQPosFromProjQN(take, end_qn),
    ch.channel or chan, ch.pitch or pitch, ch.velocity or vel, true)
  reaper.MIDI_Sort(take)
  record_item_undo(take, "MCP: update MIDI note")
  refresh_arrange()
  return { ret = true }
end

function DSL.delete_midi_notes(ti, ii, indices)
  local take = midi_take_at(ti, ii)
  local _, total = reaper.MIDI_CountEvts(take)
  local uniq, seen = {}, {}
  for _, i in ipairs(indices or {}) do
    if math.type(i) == "integer" and i >= 0 and i < total and not seen[i] then
      seen[i] = true
      uniq[#uniq + 1] = i
    end
  end
  indices = uniq
  table.sort(indices, function(a, b) return a > b end)
  for _, i in ipairs(indices) do reaper.MIDI_DeleteNote(take, i) end
  reaper.MIDI_Sort(take)
  record_item_undo(take, "MCP: delete MIDI notes")
  refresh_arrange()
  return { ret = { deleted = #indices } }
end

local function validate_ccs(events)
  if not events or #events == 0 then error("ccs array is empty") end
  if #events > 10000 then error("refusing more than 10000 ccs in one call") end
  for i, ev in ipairs(events) do
    if type(ev) ~= "table" or type(ev.start_beats) ~= "number" then
      error("cc #" .. i .. " needs numeric start_beats")
    end
    if ev.program == nil and ev.cc == nil then
      error("cc #" .. i .. " needs cc or program")
    end
  end
end

function DSL.add_midi_cc(ti, ii, events)
  local take = midi_take_at(ti, ii)
  validate_ccs(events)
  local count = 0
  for _, ev in ipairs(events) do
    local ppq = reaper.MIDI_GetPPQPosFromProjQN(take, ev.start_beats)
    local chan = ev.channel or 0
    if ev.program ~= nil then
      reaper.MIDI_InsertCC(take, false, false, ppq, 0xC0, chan, ev.program, 0)
    else
      reaper.MIDI_InsertCC(take, false, false, ppq, 0xB0, chan, ev.cc, ev.value or 0)
    end
    count = count + 1
  end
  reaper.MIDI_Sort(take)
  record_item_undo(take, "MCP: add MIDI CC")
  refresh_arrange()
  return { ret = { inserted = count } }
end

function DSL.add_track_fx(ti, fx_name)
  local t = track_at(ti)
  local fx = reaper.TrackFX_AddByName(t, fx_name, false, -1)
  if fx < 0 then error("could not add FX: " .. tostring(fx_name)) end
  local _, got = reaper.TrackFX_GetFXName(t, fx, "")
  return { ret = { fx_index = fx, name = got } }
end

function DSL.list_track_fx(ti)
  local t = track_at(ti)
  local out = {}
  for i = 0, reaper.TrackFX_GetCount(t) - 1 do
    local _, name = reaper.TrackFX_GetFXName(t, i, "")
    out[#out + 1] = {
      index = i, name = name,
      enabled = reaper.TrackFX_GetEnabled(t, i),
    }
  end
  return { ret = out }
end

function DSL.get_fx_params(ti, fxi, filter)
  local t = track_at(ti)
  local out = {}
  local want = type(filter) == "string" and filter ~= "" and filter:lower() or nil
  for i = 0, reaper.TrackFX_GetNumParams(t, fxi) - 1 do
    local _, pn = reaper.TrackFX_GetParamName(t, fxi, i, "")
    if want and not pn:lower():find(want, 1, true) then goto continue end
    local val, mn, mx = reaper.TrackFX_GetParam(t, fxi, i)
    local _, fmt = reaper.TrackFX_GetFormattedParamValue(t, fxi, i, "")
    out[#out + 1] = { index = i, name = pn, value = val, min = mn, max = mx, formatted = fmt }
    ::continue::
  end
  return { ret = out }
end

local function fx_param_index(t, fxi, param)
  if type(param) ~= "string" then return param end
  local n = reaper.TrackFX_GetNumParams(t, fxi)
  for i = 0, n - 1 do
    local _, pn = reaper.TrackFX_GetParamName(t, fxi, i, "")
    if pn:lower() == param:lower() then return i end
  end
  error("no param named " .. param .. " (fx params lists the " .. n .. " names)")
end

-- Display text of a normalized value, without moving the knob when the API allows it.
local function fx_format(t, fxi, pidx, v)
  if reaper.TrackFX_FormatParamValueNormalized then
    local ok, s = reaper.TrackFX_FormatParamValueNormalized(t, fxi, pidx, v, "")
    if ok and s and s ~= "" then return s end
  end
  reaper.TrackFX_SetParamNormalized(t, fxi, pidx, v)
  local _, s = reaper.TrackFX_GetFormattedParamValue(t, fxi, pidx, "")
  return s
end

-- "-12.0 dB" -> -12, "4.0:1" -> 4, "inf" / "inf:1" -> math.huge, "-inf dB" -> -math.huge
local function display_number(s)
  s = tostring(s or ""):lower()
  local sign, rest = s:match("^%s*([-+]?)%s*(.*)$")
  if rest:sub(1, 3) == "inf" then return sign == "-" and -math.huge or math.huge end
  return tonumber(s:match("[-+]?%d*%.?%d+"))
end

-- Find the normalized value whose display is `target` (a number in the display unit, or a label).
local function resolve_formatted(t, fxi, pidx, target)
  local want = type(target) == "number" and target or display_number(target)
  if type(target) == "string" then
    -- exact label first: JS enums ("3.2k", "Blown Capacitor 4") and switches
    local lt, partial = target:lower(), nil
    for k = 0, 1000 do
      local v = k / 1000
      local shown = fx_format(t, fxi, pidx, v):lower()
      if shown == lt then return v end
      if not partial and want == nil and shown:find(lt, 1, true) then partial = v end
    end
    if want == nil then
      if partial then return partial end
      error("no value of this param displays as '" .. target .. "'")
    end
  end
  local lo, hi = 0.0, 1.0
  local flo, fhi = display_number(fx_format(t, fxi, pidx, lo)), display_number(fx_format(t, fxi, pidx, hi))
  if flo == nil or fhi == nil then error("param display is not numeric; pass value (0..1) instead") end
  local rising = fhi >= flo
  local mn, mx = math.min(flo, fhi), math.max(flo, fhi)
  if want < mn - 1e-9 or want > mx + 1e-9 then
    error(("formatted %s is outside this param's range %s..%s"):format(tostring(target),
      fx_format(t, fxi, pidx, rising and 0 or 1), fx_format(t, fxi, pidx, rising and 1 or 0)))
  end
  for _ = 1, 50 do
    local mid = (lo + hi) / 2
    local f = display_number(fx_format(t, fxi, pidx, mid))
    if f == nil then break end
    if (f < want) == rising then lo = mid else hi = mid end
  end
  local dlo = math.abs((display_number(fx_format(t, fxi, pidx, lo)) or 0) - want)
  local dhi = math.abs((display_number(fx_format(t, fxi, pidx, hi)) or 0) - want)
  return dlo <= dhi and lo or hi
end

function DSL.set_fx_param(ti, fxi, param, value, formatted)
  local t = track_at(ti)
  local pidx = fx_param_index(t, fxi, param)
  local n = reaper.TrackFX_GetNumParams(t, fxi)
  if type(pidx) ~= "number" or pidx < 0 or pidx >= n then
    error(("no param %s (fx has %d params)"):format(tostring(param), n))
  end
  if formatted ~= nil then
    reaper.TrackFX_SetParamNormalized(t, fxi, pidx, resolve_formatted(t, fxi, pidx, formatted))
  elseif type(value) == "number" then
    reaper.TrackFX_SetParam(t, fxi, pidx, value)
  else
    error("fx set needs value (0..1) or formatted (display value, e.g. -12 for dB, 4 for 4:1, or a label)")
  end
  local v = reaper.TrackFX_GetParam(t, fxi, pidx)
  local _, shown = reaper.TrackFX_GetFormattedParamValue(t, fxi, pidx, "")
  return { ret = { param_index = pidx, value = v, formatted = shown } }
end

function DSL.delete_track_fx(ti, fxi)
  local t = track_at(ti)
  if not reaper.TrackFX_Delete(t, fxi) then error("could not delete FX " .. tostring(fxi)) end
  return { ret = true }
end

function DSL.set_fx_enabled(ti, fxi, enabled)
  reaper.TrackFX_SetEnabled(track_at(ti), fxi, enabled and true or false)
  return { ret = { enabled = reaper.TrackFX_GetEnabled(track_at(ti), fxi) } }
end

function DSL.move_track_fx(ti, fxi, dest_index)
  local t = track_at(ti)
  local n = reaper.TrackFX_GetCount(t)
  if fxi < 0 or fxi >= n or dest_index < 0 or dest_index >= n then
    error(("FX index out of range (track has %d FX)"):format(n))
  end
  local _, name = reaper.TrackFX_GetFXName(t, fxi, "")
  reaper.TrackFX_CopyToTrack(t, fxi, t, dest_index, true) -- returns nothing; check the result instead
  local _, moved = reaper.TrackFX_GetFXName(t, dest_index, "")
  if moved ~= name then error("could not move FX") end
  return { ret = { fx_index = dest_index } }
end

function DSL.set_fx_preset(ti, fxi, preset)
  local t = track_at(ti)
  if preset and preset ~= "" then
    if not reaper.TrackFX_SetPreset(t, fxi, preset) then
      error("could not set preset: " .. tostring(preset))
    end
  end
  local _, name = reaper.TrackFX_GetPreset(t, fxi, "")
  return { ret = { preset = name } }
end

local SEND_MODES = { post_fader = 0, pre_fx = 1, pre_fader = 3 }
local SEND_MODE_NAMES = { [0] = "post_fader", [1] = "pre_fx", [2] = "pre_fader", [3] = "pre_fader" }

function DSL.list_sends(ti)
  local t = track_at(ti)
  local out = {}
  local n = reaper.GetTrackNumSends(t, 0)
  for i = 0, n - 1 do
    local dest = reaper.GetTrackSendInfo_Value(t, 0, i, "P_DESTTRACK")
    local dest_index = -1
    if dest then
      if dest == reaper.GetMasterTrack(0) then
        dest_index = -1
      else
        dest_index = math.floor(reaper.GetMediaTrackInfo_Value(dest, "IP_TRACKNUMBER") - 1)
      end
    end
    local rec = {
      send_index = i,
      dest_index = dest_index,
      volume_db = db_of(reaper.GetTrackSendInfo_Value(t, 0, i, "D_VOL")),
      pan = reaper.GetTrackSendInfo_Value(t, 0, i, "D_PAN"),
      mute = reaper.GetTrackSendInfo_Value(t, 0, i, "B_MUTE") == 1,
      mode = SEND_MODE_NAMES[math.floor(reaper.GetTrackSendInfo_Value(t, 0, i, "I_SENDMODE"))] or "post_fader",
    }
    local src = math.floor(reaper.GetTrackSendInfo_Value(t, 0, i, "I_SRCCHAN"))
    local dst = math.floor(reaper.GetTrackSendInfo_Value(t, 0, i, "I_DSTCHAN"))
    if src ~= 0 then rec.src_channel = src end -- omitted when 0 (channels 1/2)
    if dst ~= 0 then rec.dst_channel = dst end
    out[#out + 1] = rec
  end
  return { ret = out }
end

-- volume/pan/mute plus routing: src_channel / dst_channel are the first channel of the stereo pair, 0-based
-- (dst_channel 2 = channels 3/4, the sidechain input of ReaComp & co.); mode post_fader | pre_fader | pre_fx.
local function apply_send_props(t, send_index, props)
  props = props or {}
  if props.volume_db ~= nil then
    reaper.SetTrackSendInfo_Value(t, 0, send_index, "D_VOL", 10 ^ (props.volume_db / 20))
  end
  if props.pan ~= nil then
    reaper.SetTrackSendInfo_Value(t, 0, send_index, "D_PAN", props.pan)
  end
  if props.mute ~= nil then
    reaper.SetTrackSendInfo_Value(t, 0, send_index, "B_MUTE", props.mute and 1 or 0)
  end
  if props.mode ~= nil then
    local m = SEND_MODES[props.mode]
    if not m then error("send mode must be post_fader, pre_fader or pre_fx") end
    reaper.SetTrackSendInfo_Value(t, 0, send_index, "I_SENDMODE", m)
  end
  if props.src_channel ~= nil then
    reaper.SetTrackSendInfo_Value(t, 0, send_index, "I_SRCCHAN", props.src_channel)
  end
  if props.dst_channel ~= nil then
    -- the destination needs the channels to exist, or REAPER folds the send back down
    local dest = reaper.GetTrackSendInfo_Value(t, 0, send_index, "P_DESTTRACK")
    if dest then
      local need = props.dst_channel + 2
      if need % 2 == 1 then need = need + 1 end
      if reaper.GetMediaTrackInfo_Value(dest, "I_NCHAN") < need then
        reaper.SetMediaTrackInfo_Value(dest, "I_NCHAN", need)
      end
    end
    reaper.SetTrackSendInfo_Value(t, 0, send_index, "I_DSTCHAN", props.dst_channel)
  end
end

function DSL.add_send(ti, dest_index, props)
  local src = track_at(ti)
  local dest = track_at(dest_index)
  local idx = reaper.CreateTrackSend(src, dest)
  if idx < 0 then error("could not create send") end
  apply_send_props(src, idx, props)
  return { ret = { send_index = idx, dest_index = dest_index } }
end

function DSL.delete_send(ti, send_index)
  if not reaper.RemoveTrackSend(track_at(ti), 0, send_index) then
    error("could not delete send")
  end
  return { ret = true }
end

function DSL.update_send(ti, send_index, props)
  local t = track_at(ti)
  local n = reaper.GetTrackNumSends(t, 0)
  if type(send_index) ~= "number" or send_index < 0 or send_index >= n then
    error(("no send at index %s (track has %d sends)"):format(tostring(send_index), n))
  end
  apply_send_props(t, send_index, props)
  return { ret = true }
end

-- REAPER's C_FADEINSHAPE / C_FADEOUTSHAPE numbers
local FADE_SHAPES = { "linear", "fast_start", "fast_end", "fast_start_steep", "fast_end_steep", "s_curve", "s_curve_steep" }
local FADE_SHAPE_N = {}
for i, n in ipairs(FADE_SHAPES) do FADE_SHAPE_N[n] = i - 1 end

local function fade_shape(v)
  local n = FADE_SHAPE_N[v]
  if not n then error("fade shape must be one of " .. table.concat(FADE_SHAPES, ", "), 0) end
  return n
end

local function item_at(ti, ii)
  local item = reaper.GetTrackMediaItem(track_at(ti), ii)
  if not item then error("no item at index " .. tostring(ii), 0) end
  return item
end

local function item_index(item) return math.floor(reaper.GetMediaItemInfo_Value(item, "IP_ITEMNUMBER")) end
local function item_track_index(item)
  return math.floor(reaper.GetMediaTrackInfo_Value(reaper.GetMediaItem_Track(item), "IP_TRACKNUMBER")) - 1
end

function DSL.list_items(ti)
  local t = track_at(ti)
  local out = {}
  for i = 0, reaper.CountTrackMediaItems(t) - 1 do
    local item = reaper.GetTrackMediaItem(t, i)
    local vol = reaper.GetMediaItemInfo_Value(item, "D_VOL")
    local db = (vol <= 0) and -150 or (20 * math.log(vol) / math.log(10))
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local pos_beats = time_to_beats(pos)
    local rec = {
      item_index = i,
      position_beats = pos_beats,
      length_beats = time_to_beats(pos + reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
        - pos_beats,
      gain_db = db,
      fade_in_sec = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN"),
      fade_out_sec = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN"),
      loop = reaper.GetMediaItemInfo_Value(item, "B_LOOPSRC") == 1,
      mute = reaper.GetMediaItemInfo_Value(item, "B_MUTE") == 1,
    }
    -- a shape only matters on a fade that exists (new items carry REAPER's default shape, often not linear)
    if rec.fade_in_sec > 0 then rec.fade_in_shape = FADE_SHAPES[reaper.GetMediaItemInfo_Value(item, "C_FADEINSHAPE") + 1] end
    if rec.fade_out_sec > 0 then rec.fade_out_shape = FADE_SHAPES[reaper.GetMediaItemInfo_Value(item, "C_FADEOUTSHAPE") + 1] end
    local nt = reaper.CountTakes(item)
    local take = reaper.GetActiveTake(item)
    if take then
      local _, tname = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      if tname ~= "" then rec.take = tname end
      if not reaper.TakeIsMIDI(take) then
        local src = reaper.GetMediaItemTake_Source(take)
        local file = src and reaper.GetMediaSourceFileName(src, "") or ""
        if file ~= "" then rec.source = file end
      end
    end
    if nt > 1 then
      rec.takes = nt
      rec.active_take = math.floor(reaper.GetMediaItemInfo_Value(item, "I_CURTAKE"))
    end
    out[#out + 1] = rec
  end
  return { ret = out }
end

-- every take's start offset moves with the left edge, so the content stays where it is on the timeline
local function set_left_edge(item, beats)
  local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local new = beats_to_time(beats)
  if new >= pos + len then error("left_edge_beats must stay before the item's end", 0) end
  local d = new - pos
  for k = 0, reaper.CountTakes(item) - 1 do
    local take = reaper.GetTake(item, k)
    if take then
      local rate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
      local offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
      reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", offs + d * (rate ~= 0 and rate or 1))
    end
  end
  reaper.SetMediaItemInfo_Value(item, "D_POSITION", new)
  reaper.SetMediaItemInfo_Value(item, "D_LENGTH", len - d)
end

function DSL.update_item(ti, ii, props)
  local item = item_at(ti, ii)
  props = props or {}
  if props.gain_db ~= nil then
    reaper.SetMediaItemInfo_Value(item, "D_VOL", 10 ^ (props.gain_db / 20))
  end
  if props.fade_in_sec ~= nil then
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", props.fade_in_sec)
  end
  if props.fade_out_sec ~= nil then
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", props.fade_out_sec)
  end
  if props.fade_in_shape ~= nil then
    reaper.SetMediaItemInfo_Value(item, "C_FADEINSHAPE", fade_shape(props.fade_in_shape))
  end
  if props.fade_out_shape ~= nil then
    reaper.SetMediaItemInfo_Value(item, "C_FADEOUTSHAPE", fade_shape(props.fade_out_shape))
  end
  if props.active_take ~= nil then
    local take = reaper.GetTake(item, props.active_take)
    if not take then error("no take " .. tostring(props.active_take) .. " (the item has " .. reaper.CountTakes(item) .. ")", 0) end
    reaper.SetActiveTake(take)
  end
  if props.loop ~= nil then
    reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", props.loop and 1 or 0)
  end
  if props.mute ~= nil then
    reaper.SetMediaItemInfo_Value(item, "B_MUTE", props.mute and 1 or 0)
  end
  if props.position_beats ~= nil then
    reaper.SetMediaItemPosition(item, beats_to_time(props.position_beats), false)
  end
  if props.length_beats ~= nil then
    local pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local pos_b = time_to_beats(pos)
    reaper.SetMediaItemLength(item, beats_to_time(pos_b + props.length_beats) - pos, false)
  end
  if props.left_edge_beats ~= nil then set_left_edge(item, props.left_edge_beats) end
  local ret = true
  if props.dest_track_index ~= nil then
    if not reaper.MoveMediaItemToTrack(item, track_at(props.dest_track_index)) then error("could not move the item", 0) end
    ret = { track_index = item_track_index(item), item_index = item_index(item) }
  end
  refresh_arrange()
  return { ret = ret }
end

-- split at each beat position inside the item; the pieces left to right
function DSL.split_item(ti, ii, at_beats)
  local item = item_at(ti, ii)
  if type(at_beats) ~= "table" or json.len(at_beats) == 0 then error("split needs at_beats", 0) end
  local times = {}
  for _, b in ipairs(at_beats) do times[#times + 1] = beats_to_time(b) end
  table.sort(times)
  local pieces = { item }
  for _, t in ipairs(times) do
    local last = pieces[#pieces]
    local pos = reaper.GetMediaItemInfo_Value(last, "D_POSITION")
    local len = reaper.GetMediaItemInfo_Value(last, "D_LENGTH")
    if t <= pos or t >= pos + len then error(("beat %g is not inside the item"):format(time_to_beats(t)), 0) end
    local right = reaper.SplitMediaItem(last, t)
    if not right then error(("could not split at beat %g"):format(time_to_beats(t)), 0) end
    pieces[#pieces + 1] = right
  end
  local out = {}
  for _, it in ipairs(pieces) do out[#out + 1] = item_index(it) end
  refresh_arrange()
  return { ret = { item_indices = out } }
end

function DSL.delete_items(ti, indices)
  local t = track_at(ti)
  local list = {}
  for _, i in ipairs(indices or {}) do list[#list + 1] = item_at(ti, i) end
  if #list == 0 then error("delete needs item_index or item_indices", 0) end
  for _, it in ipairs(list) do reaper.DeleteTrackMediaItem(t, it) end
  refresh_arrange()
  return { ret = { deleted = #list } }
end

-- an independent copy (new GUIDs, so a MIDI copy is not pooled with the original); default: right after the item
function DSL.duplicate_item(ti, ii, opts)
  local item = item_at(ti, ii)
  opts = opts or {}
  local dest = track_at(opts.dest_track_index or ti)
  local ok, chunk = reaper.GetItemStateChunk(item, "", false)
  if not ok then error("could not read the item", 0) end
  chunk = chunk:gsub("{%x+%-%x+%-%x+%-%x+%-%x+}", function() return reaper.genGuid("") end)
  local copy = reaper.AddMediaItemToTrack(dest)
  reaper.SetItemStateChunk(copy, chunk, false)
  local t = opts.position_beats ~= nil and beats_to_time(opts.position_beats)
    or (reaper.GetMediaItemInfo_Value(item, "D_POSITION") + reaper.GetMediaItemInfo_Value(item, "D_LENGTH"))
  reaper.SetMediaItemInfo_Value(copy, "D_POSITION", t)
  refresh_arrange()
  return { ret = { track_index = item_track_index(copy), item_index = item_index(copy) } }
end

function DSL.import_media(path, opts)
  opts = opts or {}
  local ti, start_beats, as_new_track = opts.track_index, opts.start_beats, opts.as_new_track
  if type(path) ~= "string" or path == "" then error("path required") end
  if start_beats ~= nil then
    reaper.SetEditCurPos(beats_to_time(start_beats), false, false)
  end
  if not as_new_track then
    if ti == nil then error("track_index required unless as_new_track") end
    reaper.Main_OnCommand(40297, 0)
    reaper.SetTrackSelected(track_at(ti), true)
  end
  -- REAPER keeps items sorted by position and a new track shifts later ones, so compare items, not counts
  local existing = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    for j = 0, reaper.CountTrackMediaItems(t) - 1 do existing[reaper.GetTrackMediaItem(t, j)] = true end
  end
  local ok = reaper.InsertMedia(path, as_new_track and 1 or 0)
  if ok == false then error("InsertMedia failed: " .. path) end
  local created = {}
  for i = 0, reaper.CountTracks(0) - 1 do
    local t = reaper.GetTrack(0, i)
    for j = 0, reaper.CountTrackMediaItems(t) - 1 do
      local item = reaper.GetTrackMediaItem(t, j)
      if not existing[item] then
        reaper.SetMediaItemInfo_Value(item, "B_LOOPSRC", 0)
        created[#created + 1] = { track_index = i, item_index = j }
      end
    end
  end
  refresh_tracks()
  refresh_arrange()
  return { ret = { path = path, created = created } }
end

function DSL.list_envelopes(ti)
  local t = track_at(ti)
  local out = {}
  for i = 0, reaper.CountTrackEnvelopes(t) - 1 do
    local env = reaper.GetTrackEnvelope(t, i)
    local _, name = reaper.GetEnvelopeName(env, "")
    out[#out + 1] = { index = i, name = name, n_points = reaper.CountEnvelopePoints(env) }
  end
  return { ret = out }
end

local function envelope_at(ti, name_or_index)
  local t = track_at(ti)
  if type(name_or_index) == "number" then
    local env = reaper.GetTrackEnvelope(t, name_or_index)
    if not env then error("no envelope at index " .. tostring(name_or_index)) end
    return env
  end
  local env = reaper.GetTrackEnvelopeByName(t, tostring(name_or_index))
  if not env then
    local names = {}
    for i = 0, reaper.CountTrackEnvelopes(t) - 1 do
      local _, nm = reaper.GetEnvelopeName(reaper.GetTrackEnvelope(t, i), "")
      names[#names + 1] = nm
    end
    error("no envelope named " .. tostring(name_or_index) .. " on this track (has: "
      .. (#names > 0 and table.concat(names, ", ") or "none")
      .. "). Show it first, e.g. action 40406 Volume / 40407 Pan with the track selected.", 0)
  end
  return env
end

-- Point values come back raw, and a fader-scaled volume envelope (REAPER 6+ default) stores fader positions
-- (0 dB = 716.2), so convert both ways: the tool speaks gain (Volume 1.0 = 0 dB) for every scaling mode,
-- or dB with unit="db" (Volume, Trim Volume, send volume).
local function to_unit(v, unit)
  if unit == "db" then return db_of(v) end
  return v
end

local function from_unit(v, unit)
  if unit == "db" then
    if v <= -150 then return 0 end
    return 10 ^ (v / 20)
  end
  return v
end

local function check_unit(unit)
  if unit ~= nil and unit ~= "gain" and unit ~= "db" then error("unit must be gain or db") end
end

-- optional {start_beats, end_beats}: both ends included
local function beat_range(range)
  if type(range) ~= "table" or (range.start_beats == nil and range.end_beats == nil) then return nil end
  local a, b = range.start_beats or 0, range.end_beats or math.huge
  if b < a then error("end_beats must not be before start_beats", 0) end
  return a, b
end

function DSL.get_envelope(ti, name_or_index, unit, range)
  check_unit(unit)
  local env = envelope_at(ti, name_or_index)
  local _, name = reaper.GetEnvelopeName(env, "")
  local mode = reaper.GetEnvelopeScalingMode(env)
  local ra, rb = beat_range(range)
  local pts = {}
  for i = 0, reaper.CountEnvelopePoints(env) - 1 do
    local ok, time, value, shape, tension, selected = reaper.GetEnvelopePoint(env, i)
    if ok and ra then
      local b = time_to_beats(time)
      if b < ra - 1e-9 or b > rb + 1e-9 then ok = false end
    end
    if ok then
      pts[#pts + 1] = {
        beats = time_to_beats(time),
        value = to_unit(reaper.ScaleFromEnvelopeMode(mode, value), unit),
        shape = shape,
        tension = tension,
        selected = selected,
      }
    end
  end
  local ret = { name = name, points = pts }
  if unit then ret.unit = unit end
  return { ret = ret }
end

-- Envelopes made from a chunk can come up ACT 0: the points read back fine but nothing plays.
local function ensure_active(env)
  if not (reaper.GetEnvelopeStateChunk and reaper.SetEnvelopeStateChunk) then return false end
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if not ok or not chunk then return false end
  local fixed, n = chunk:gsub("\nACT 0", "\nACT 1", 1)
  if n == 0 then return false end
  reaper.SetEnvelopeStateChunk(env, fixed, false)
  return true
end

-- with a range only the points inside it are replaced (both ends included); without one, the whole envelope
function DSL.set_envelope(ti, name_or_index, points, unit, range)
  check_unit(unit)
  local env = envelope_at(ti, name_or_index)
  local mode = reaper.GetEnvelopeScalingMode(env)
  local ra, rb = beat_range(range)
  points = points or {}
  for i, p in ipairs(points) do
    if type(p) ~= "table" or type(p.beats or p.time) ~= "number" or type(p.value) ~= "number" then
      error("point #" .. i .. " needs numeric beats and value")
    end
    if p.beats and p.beats < 0 then error("point #" .. i .. " is before the project start (beats < 0)") end
    if ra and p.beats and (p.beats < ra - 1e-9 or p.beats > rb + 1e-9) then
      error(("point #%d (beat %g) is outside start_beats..end_beats"):format(i, p.beats), 0)
    end
  end
  if ra then
    reaper.DeleteEnvelopePointRange(env, beats_to_time(ra) - 1e-9, rb == math.huge and math.huge or beats_to_time(rb) + 1e-9)
  else
    reaper.DeleteEnvelopePointRange(env, -math.huge, math.huge)
  end
  for _, p in ipairs(points) do
    reaper.InsertEnvelopePoint(env, beats_to_time(p.beats or p.time or 0),
      reaper.ScaleToEnvelopeMode(mode, from_unit(p.value or 0, unit)), p.shape or 0, p.tension or 0,
      p.selected and true or false, true)
  end
  reaper.Envelope_SortPoints(env)
  local activated = ensure_active(env)
  refresh_arrange()
  local ret = { n_points = reaper.CountEnvelopePoints(env) }
  if activated then ret.activated = true end
  return { ret = ret }
end

function DSL.set_time_selection(sb, eb)
  reaper.GetSet_LoopTimeRange(true, false, beats_to_time(sb), beats_to_time(eb), false)
  return { ret = { start_beats = sb, end_beats = eb } }
end

function DSL.add_marker(pos_beats, name, is_region, end_beats)
  local idx = reaper.AddProjectMarker2(0, is_region and true or false,
    beats_to_time(pos_beats),
    is_region and beats_to_time(end_beats or pos_beats) or 0,
    name or "", -1, 0)
  refresh_timeline()
  return { ret = { marker_index = idx } }
end

function DSL.save_project(path)
  if path and path ~= "" then
    local dir = path:match("^(.*)[/\\]")
    if dir then reaper.RecursiveCreateDirectory(dir, 0) end
    reaper.Main_SaveProjectEx(0, path, 0)
    -- checked before adopting the path: opening a file that wasn't written would drop the unsaved project
    if not reaper.file_exists(path) then error("could not write " .. path .. " (is the folder writable on the REAPER host?)") end
    local _, cur = reaper.EnumProjects(-1, "")
    if cur == "" then
      -- an untitled project adopts the path instead of leaving a stray copy
      reaper.Main_openProject("noprompt:" .. path)
      return { ret = { saved = true, path = path, copy = false } }
    end
    return { ret = { saved = true, path = path, copy = true } }
  end
  local _, proj = reaper.EnumProjects(-1, "")
  if not proj or proj == "" then
    error("unsaved project: pass path")
  end
  reaper.Main_SaveProject(0, false)
  return { ret = { saved = true, path = proj, copy = false } }
end

local function split_targets(s)
  local out = {}
  for f in tostring(s or ""):gmatch("[^;]+") do out[#out + 1] = f end
  return out
end

local function file_size(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local n = f:seek("end")
  f:close()
  return n
end

-- Length, sample peak and integrated loudness of a rendered file, measured by REAPER itself
-- (CalculateNormalization returns the gain that would bring the file to 0 on that scale).
local function measure_file(p)
  local m = {}
  if not reaper.PCM_Source_CreateFromFile then return m end
  local src = reaper.PCM_Source_CreateFromFile(p)
  if not src then return m end
  if reaper.GetMediaSourceLength then
    local len = reaper.GetMediaSourceLength(src)
    if type(len) == "number" then m.length_sec = len end
  end
  if reaper.CalculateNormalization then
    local g_peak = reaper.CalculateNormalization(src, 2, 0, 0, 0)
    local g_lufs = reaper.CalculateNormalization(src, 0, 0, 0, 0)
    -- digital silence needs "infinite" gain: report it as -150 so the near-silent check still fires
    local function level(g)
      if type(g) ~= "number" or g ~= g or g <= 0 then return nil end
      if g == math.huge or g > 1e7 then return -150 end
      return -db_of(g)
    end
    m.peak_db = level(g_peak)
    m.lufs_i = level(g_lufs)
  end
  if reaper.PCM_Source_Destroy then reaper.PCM_Source_Destroy(src) end
  return m
end

local SILENT_PEAK_DB = -60
-- REAPER sink configs (RENDER_FORMAT, base64): "evaw" + bit depth byte (32 = float), and LAME MP3 at 320 kbps CBR
local RENDER_FORMATS = {
  wav16 = "ZXZhdxAAAQ==", wav24 = "ZXZhdxgAAQ==", wav32 = "ZXZhdyAAAQ==",
  mp3 = "bDNwbUABAAABAAAAAAAAAP////8EAAAAQAEAAAAAAAA=",
}

local function render_format(opts)
  if opts.format == nil and opts.bit_depth == nil then return nil end
  local f = opts.format or "wav"
  if f == "mp3" then
    if opts.bit_depth ~= nil then error("bit_depth is for wav", 0) end
    return RENDER_FORMATS.mp3
  end
  if f ~= "wav" then error("format must be wav or mp3", 0) end
  local cfg = RENDER_FORMATS["wav" .. tostring(opts.bit_depth or 24)]
  if not cfg then error("bit_depth must be 16, 24 or 32 (float)", 0) end
  return cfg
end

function DSL.render_project(path, opts)
  opts = opts or {}
  if path and path ~= "" then
    reaper.GetSetProjectInfo_String(0, "RENDER_FILE", path, true)
  end
  local bounds = opts.bounds or "project"
  local flag = 1
  if bounds == "custom" then flag = 0
  elseif bounds == "time_selection" then flag = 2
  elseif bounds == "items" then flag = 4 -- selected media items (3 would be all project regions)
  end
  if bounds == "custom" then
    local sb, eb = opts.start_beats or 0, opts.end_beats or 0
    if eb <= sb then error(("bounds=custom needs end_beats > start_beats (got %s..%s)"):format(sb, eb)) end
  end
  reaper.GetSetProjectInfo(0, "RENDER_BOUNDSFLAG", flag, true)
  if bounds == "custom" then
    reaper.GetSetProjectInfo(0, "RENDER_STARTPOS", beats_to_time(opts.start_beats or 0), true)
    reaper.GetSetProjectInfo(0, "RENDER_ENDPOS", beats_to_time(opts.end_beats or 0), true)
  end
  if opts.sample_rate then
    reaper.GetSetProjectInfo(0, "RENDER_SRATE", opts.sample_rate, true)
  end
  if opts.channels then
    reaper.GetSetProjectInfo(0, "RENDER_CHANNELS", opts.channels, true)
  end
  -- 0 = master mix only; 2 = stems of the selected tracks. (1 rendered master + every selected track's stem,
  -- which is why renders used to need "deselect all tracks first"; 8 is the render matrix.)
  local settings = 0
  if opts.stems then
    settings = 2
    if opts.track_indices then
      reaper.Main_OnCommand(40297, 0)
      for _, i in ipairs(opts.track_indices) do
        local tr = track_at(i)
        reaper.SetTrackSelected(tr, true)
      end
    end
  end
  reaper.GetSetProjectInfo(0, "RENDER_SETTINGS", settings, true)
  if opts.pattern and opts.pattern ~= "" then
    reaper.GetSetProjectInfo_String(0, "RENDER_PATTERN", opts.pattern, true)
  end
  -- a format asked for this render only: the project's own render format comes back afterwards
  local fmt, fmt_before = render_format(opts), nil
  if fmt then
    fmt_before = select(2, reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", "", false))
    reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", fmt, true)
  end

  -- Temporary solo / mute for this render only (null tests, stage renders); restored afterwards.
  local snapshot
  local solo_list, mute_list = opts.solo_indices, opts.mute_indices
  if (solo_list and #solo_list > 0) or (mute_list and #mute_list > 0) then
    snapshot = {}
    for i = 0, reaper.CountTracks(0) - 1 do
      local t = reaper.GetTrack(0, i)
      snapshot[#snapshot + 1] = { t = t, solo = reaper.GetMediaTrackInfo_Value(t, "I_SOLO"),
                                  mute = reaper.GetMediaTrackInfo_Value(t, "B_MUTE") }
    end
    if solo_list and #solo_list > 0 then
      for _, s in ipairs(snapshot) do set_solo(s.t, false) end
      for _, i in ipairs(solo_list) do set_solo(track_at(i), true) end
    end
    for _, i in ipairs(mute_list or {}) do reaper.SetMediaTrackInfo_Value(track_at(i), "B_MUTE", 1) end
  end
  local function restore()
    if fmt_before then reaper.GetSetProjectInfo_String(0, "RENDER_FORMAT", fmt_before, true); fmt_before = nil end
    if not snapshot then return end
    for _, s in ipairs(snapshot) do
      if reaper.SetTrackUISolo then reaper.SetTrackUISolo(s.t, s.solo ~= 0 and 1 or 0, 3) end
      reaper.SetMediaTrackInfo_Value(s.t, "I_SOLO", s.solo)
      reaper.SetMediaTrackInfo_Value(s.t, "B_MUTE", s.mute)
    end
    snapshot = nil
  end

  local ok, res = pcall(function()
    local warnings = {}
    -- A lingering solo turns a "full mix" bounce into a few parts at -30..-40 dB.
    if not opts.stems and not (solo_list and #solo_list > 0) and not opts.allow_solo and any_solo() then
      local who = soloed_tracks()
      error("tracks are soloed (" .. (#who > 0 and table.concat(who, ", ") or "UI solo") .. "): the render "
        .. "would hold only those. Clear solo (track update solo=false), or pass solo_indices for a "
        .. "deliberate solo render, or allow_solo=true.", 0)
    end
    if reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), "B_MUTE") == 1 then
      warnings[#warnings + 1] = "master track is muted"
    end
    -- Audio goes offline while REAPER is in the background (pref offlineinact); a render then drops it.
    if opts.media_online ~= false then reaper.Main_OnCommand(40101, 0) end

    local targets = {}
    local _, tl = reaper.GetSetProjectInfo_String(0, "RENDER_TARGETS", "", false)
    targets = split_targets(tl)
    -- An existing target makes REAPER ask "overwrite?" in a modal, which hangs the bridge.
    local clash = {}
    for _, f in ipairs(targets) do
      if reaper.file_exists(f) then clash[#clash + 1] = f end
    end
    if #clash > 0 then
      error("refusing to render over existing file(s): " .. table.concat(clash, "; ")
        .. " (REAPER's overwrite prompt would block the bridge). Use a new pattern or delete them.", 0)
    end
    if opts.stems and opts.track_indices and #targets > 0 and #targets ~= #opts.track_indices then
      warnings[#warnings + 1] = ("stems: REAPER planned %d file(s) for %d track(s)"):format(#targets, #opts.track_indices)
    end

    reaper.Main_OnCommand(42230, 0)

    local files = {}
    for _, f in ipairs(targets) do
      local rec = { path = f }
      local size = file_size(f)
      if not size then
        rec.missing = true
        warnings[#warnings + 1] = "not written: " .. f
      else
        rec.bytes = size
        if opts.measure ~= false then
          for k, v in pairs(measure_file(f)) do rec[k] = v end
          if rec.peak_db and rec.peak_db < SILENT_PEAK_DB then
            warnings[#warnings + 1] = ("near-silent: %s peaks at %.1f dBFS"):format(f, rec.peak_db)
          end
        end
        if opts.stems and f:match("[/\\][^/\\]*Master[^/\\]*$") then
          warnings[#warnings + 1] = "stems=true but REAPER rendered the master mix: " .. f
        end
      end
      files[#files + 1] = rec
    end
    local ret = { rendered_to = path or "(project render path)", bounds = bounds,
                  stems = opts.stems and true or false, files = files }
    if #warnings > 0 then ret.warnings = warnings end
    return ret
  end)
  restore()
  if not ok then error(res, 0) end
  return { ret = res }
end

function DSL.create_bus(name, source_indices)
  local bus_index = reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(bus_index, true)
  local bus = reaper.GetTrack(0, bus_index)
  reaper.GetSetMediaTrackInfo_String(bus, "P_NAME", name or "Bus", true)
  reaper.SetMediaTrackInfo_Value(bus, "I_FOLDERCOMPACT", 0)
  for _, i in ipairs(source_indices or {}) do
    local src = track_at(i)
    reaper.CreateTrackSend(src, bus)
    -- a submix: the source reaches its parent only through the bus; a direct send as well would play it twice
    reaper.SetMediaTrackInfo_Value(src, "B_MAINSEND", 0)
  end
  refresh_tracks()
  refresh_arrange()
  return { ret = { index = bus_index, name = name or "Bus" } }
end

function DSL.batch(calls, opts)
  local results = {}
  local stop = type(opts) == "table" and opts.stop_on_error
  batch_depth = batch_depth + 1
  local ok, err = pcall(function()
    local failed = false
    for i = 1, json.len(calls or {}) do
      if failed then
        results[i] = { skipped = true }
      else
        local cok, r = pcall(dispatch, calls[i])
        if not cok then
          results[i] = { error = tostring(r) }
        elseif r and r.ok == false then
          results[i] = { error = r.error or "error" }
        else
          results[i] = r and r.ret
        end
        if results[i] == nil then results[i] = json.null end
        failed = stop and type(results[i]) == "table" and results[i].error ~= nil
      end
    end
  end)
  batch_depth = batch_depth - 1
  -- Always release the refresh lock, even when the batch blew up halfway.
  flush_refresh()
  if not ok then error(err) end
  return { ret = results }
end

----------------------------------------------------------------------
-- Turn receipts. Each request that can change the project runs in one undo block labelled
-- "Hibiki <turn>: <what>", and what it changed goes into ExtState Hibiki/receipts (JSON, newest turn last),
-- so the panel can list a turn's changes and undo exactly that turn. The turn id comes from the panel
-- (ExtState Hibiki/turn while it waits for a reply); without one, calls less than 2 min apart share an id.
----------------------------------------------------------------------
local READ_ONLY = {
  ping = true, get_project_summary = true, list_tracks = true, get_midi_notes = true, get_midi_cc = true,
  list_track_fx = true,
  get_fx_params = true, list_sends = true, list_items = true, list_envelopes = true, get_envelope = true,
  save_project = true, render_project = true, transport = true, set_time_selection = true, batch = true,
}
-- reaper_call of a getter changes nothing; GetSet* can set, so it counts as a change
local function api_reads(func)
  if func:match("^GetSet") then return false end
  return func:match("^Get") or func:match("^Count") or func:match("^Enum") or func:match("^Is")
    or func:match("^Has") or func:match("^TimeMap") or func:match("^TrackFX_Get") or func:match("^TakeFX_Get")
    or func:match("^MIDI_Get") or func:match("^MIDI_Count") or func:match("^Master_Get") or func:match("^format_")
    or func:match("^parse_") or func:match("^Undo_Can") or func:match("^Envelope_Evaluate")
    or func == "time_precise" or func == "file_exists" or func == "CalculateNormalization" or func == "ShowConsoleMsg"
end

local function receipt_wanted(func)
  if DSL[func] then return not READ_ONLY[func] end
  return type(reaper[func]) == "function" and not api_reads(func)
end

local function tname(i)
  if i == -1 then return "master" end
  local t = type(i) == "number" and reaper.GetTrack(0, i)
  if not t then return "#" .. tostring(type(i) == "number" and i + 1 or i) end
  local _, name = reaper.GetTrackName(t)
  return ("#%d %s"):format(i + 1, name)
end

local function fxname(ti, fxi)
  local t = type(ti) == "number" and (ti == -1 and reaper.GetMasterTrack(0) or reaper.GetTrack(0, ti))
  if not t or type(fxi) ~= "number" then return "FX " .. tostring(fxi) end
  local ok, name = reaper.TrackFX_GetFXName(t, fxi, "")
  return ok and name ~= "" and name or ("FX " .. (fxi + 1))
end

local function short(v, n)
  local s = type(v) == "table" and json.encode(v) or tostring(v)
  n = n or 60
  if #s > n then s = s:sub(1, n - 1) .. "…" end
  return s
end

local function props_text(p)
  if type(p) ~= "table" then return "" end
  local out = {}
  local function add(k, f)
    if p[k] ~= nil then out[#out + 1] = f(p[k]) end
  end
  add("name", function(v) return "name → " .. short(v, 30) end)
  add("volume_db", function(v) return ("volume %.1f dB"):format(v) end)
  add("gain_db", function(v) return ("gain %.1f dB"):format(v) end)
  add("pan", function(v) return ("pan %.2f"):format(v) end)
  add("mute", function(v) return v and "mute" or "unmute" end)
  add("solo", function(v) return v and "solo" or "unsolo" end)
  add("mode", function(v) return tostring(v) end)
  add("position_beats", function(v) return ("move to beat %g"):format(v) end)
  add("length_beats", function(v) return ("length %g beats"):format(v) end)
  add("fade_in", function(v) return ("fade in %gs"):format(v) end)
  add("fade_out", function(v) return ("fade out %gs"):format(v) end)
  add("loop", function(v) return v and "loop on" or "loop off" end)
  add("src_channel", function(v) return "src ch " .. v end)
  add("dst_channel", function(v) return "dst ch " .. v end)
  return table.concat(out, ", ")
end

local function count_of(list) return type(list) == "table" and json.len(list) or 0 end

local DESCRIBE = {
  add_track = function(a) return ("add track %s"):format(short(a[1] or "", 30)) end,
  delete_track = function(a) return "delete track " .. tname(a[1]) end,
  update_track = function(a) return tname(a[1]) .. ": " .. props_text(a[2]) end,
  set_tempo = function(a) return ("tempo %g BPM"):format(a[1] or 0) end,
  set_time_signature = function(a) return ("time signature %s/%s"):format(a[1], a[2]) end,
  action = function(a)
    local id = tonumber(a[1]) or 0
    local ok, text = pcall(function() return reaper.kbd_getTextFromCmd and reaper.kbd_getTextFromCmd(id, 0) end)
    return "action " .. tostring(a[1]) .. ((ok and text and text ~= "") and (" " .. text) or "")
  end,
  create_midi_item = function(a) return ("%s: new MIDI item at beat %g"):format(tname(a[1]), a[2] or 0) end,
  add_midi_notes = function(a) return ("%s item %s: add %d notes"):format(tname(a[1]), a[2], count_of(a[3])) end,
  replace_midi_notes = function(a) return ("%s item %s: replace notes (%d)"):format(tname(a[1]), a[2], count_of(a[3])) end,
  update_midi_note = function(a) return ("%s item %s: edit note %s"):format(tname(a[1]), a[2], a[3]) end,
  delete_midi_notes = function(a) return ("%s item %s: delete %d notes"):format(tname(a[1]), a[2], count_of(a[3])) end,
  add_midi_cc = function(a) return ("%s item %s: add %d CC"):format(tname(a[1]), a[2], count_of(a[3])) end,
  add_track_fx = function(a) return ("%s: add %s"):format(tname(a[1]), short(a[2], 40)) end,
  delete_track_fx = function(a) return ("%s: remove %s"):format(tname(a[1]), fxname(a[1], a[2])) end,
  set_fx_enabled = function(a) return ("%s: %s %s"):format(tname(a[1]), a[3] and "enable" or "bypass", fxname(a[1], a[2])) end,
  move_track_fx = function(a) return ("%s: move %s to slot %s"):format(tname(a[1]), fxname(a[1], a[2]), (a[3] or 0) + 1) end,
  set_fx_preset = function(a) return ("%s: %s preset %s"):format(tname(a[1]), fxname(a[1], a[2]), short(a[3], 30)) end,
  set_fx_param = function(a)
    local v = a[5] ~= nil and a[5] or a[4]
    return ("%s: %s %s = %s"):format(tname(a[1]), fxname(a[1], a[2]), short(a[3], 24), short(v, 16))
  end,
  add_send = function(a)
    local p = props_text(a[3])
    return ("send %s → %s%s"):format(tname(a[1]), tname(a[2]), p ~= "" and (" (" .. p .. ")") or "")
  end,
  delete_send = function(a) return ("%s: delete send %s"):format(tname(a[1]), a[2]) end,
  update_send = function(a) return ("%s send %s: %s"):format(tname(a[1]), a[2], props_text(a[3])) end,
  update_item = function(a) return ("%s item %s: %s"):format(tname(a[1]), a[2], props_text(a[3])) end,
  split_item = function(a) return ("%s item %s: split at %d point%s"):format(tname(a[1]), a[2], count_of(a[3]),
    count_of(a[3]) == 1 and "" or "s") end,
  delete_items = function(a) return ("%s: delete %d item%s"):format(tname(a[1]), count_of(a[2]), count_of(a[2]) == 1 and "" or "s") end,
  duplicate_item = function(a) return ("%s item %s: duplicate"):format(tname(a[1]), a[2]) end,
  import_media = function(a)
    local o = type(a[2]) == "table" and a[2] or {}
    return ("import %s%s"):format(short(tostring(a[1] or ""):match("[^/\\]+$") or a[1], 40),
      o.as_new_track and " (new track)" or (o.track_index and (" to " .. tname(o.track_index)) or ""))
  end,
  set_envelope = function(a) return ("%s: %s envelope, %d points"):format(tname(a[1]), short(a[2], 20), count_of(a[3])) end,
  add_marker = function(a) return ("%s %s at beat %g"):format(a[3] and "region" or "marker", short(a[2] or "", 30), a[1] or 0) end,
  create_bus = function(a) return ("bus %s from %d tracks"):format(short(a[1] or "Bus", 30), count_of(a[2])) end,
}

local function describe(func, args)
  local f = DESCRIBE[func]
  if f then
    local ok, s = pcall(f, args or {})
    if ok and s then return s end
  end
  local parts = {}
  for i = 1, math.min(json.len(args or {}), 4) do parts[i] = short(args[i], 24) end
  return func .. "(" .. table.concat(parts, ", ") .. ")"
end

local MAX_TURNS, MAX_LINES = 30, 60
local receipts = {}       -- { id, at, n, lines = {}, failed }
local staged = {}         -- changes of the request that is running
local auto_turn, auto_at = nil, -math.huge

local function note_change(what, ok)
  staged[#staged + 1] = { what = what, ok = ok ~= false }
end

local function current_turn()
  local t = reaper.GetExtState("Hibiki", "turn")
  if t ~= "" and t:match("^[%w._-]+$") and #t <= 40 then return t end
  local now = reaper.time_precise()
  if not auto_turn or now - auto_at > 120 then auto_turn = "mcp-" .. os.time() end
  auto_at = now
  return auto_turn
end

local function commit_receipt(turn)
  local _, proj = reaper.EnumProjects(-1, "")
  local r = receipts[#receipts]
  -- undo history is per project tab, so a reply that touched two projects gets one receipt per project
  if not r or r.id ~= turn or r.proj ~= proj then
    r = { id = turn, proj = proj, at = os.time(), n = 0, points = 0, lines = {} }
    receipts[#receipts + 1] = r
    if #receipts > MAX_TURNS then table.remove(receipts, 1) end
  end
  r.points = r.points + 1 -- undo points this turn left (one per request), so a revert can tell it got them all
  for _, c in ipairs(staged) do
    r.n = r.n + 1
    if not c.ok then r.failed = true end
    if #r.lines < MAX_LINES then r.lines[#r.lines + 1] = c.ok and c.what or (c.what .. " (failed)") end
  end
  r.at = os.time()
  reaper.SetExtState("Hibiki", "receipts", json.encode(receipts), false)
  reaper.SetExtState("Hibiki", "receipts_seq", tostring(os.time()) .. "." .. r.n .. "." .. #receipts, false)
end

-- What a run_lua or a raw API call changed, read off the project before and after it (tracks and FX by GUID):
-- the receipt lists real changes ("#11 Pizz: add Pizz level -3 dB") instead of the script's first line
local SNAP_MAX_TRACKS = 400
local function snapshot()
  local n = reaper.CountTracks(0)
  if n > SNAP_MAX_TRACKS or not reaper.GetTrackGUID then return nil end
  local snap = { tempo = reaper.Master_GetTempo(), tracks = {}, order = {} }
  for i = -1, n - 1 do
    local tr = i == -1 and reaper.GetMasterTrack(0) or reaper.GetTrack(0, i)
    local _, name = reaper.GetTrackName(tr)
    local free = reaper.GetMediaTrackInfo_Value(tr, "I_FREEMODE")
    local t = { i = i, name = name, vol = reaper.GetMediaTrackInfo_Value(tr, "D_VOL"),
      pan = reaper.GetMediaTrackInfo_Value(tr, "D_PAN"), mute = reaper.GetMediaTrackInfo_Value(tr, "B_MUTE"),
      items = reaper.CountTrackMediaItems(tr), sends = reaper.GetTrackNumSends(tr, 0),
      lanes = free == 2 and reaper.GetMediaTrackInfo_Value(tr, "I_NUMFIXEDLANES") or 0, fx = {}, fxo = {} }
    for k = 0, reaper.TrackFX_GetCount(tr) - 1 do
      local g = reaper.TrackFX_GetFXGUID(tr, k) or ("#" .. k)
      local _, fn = reaper.TrackFX_GetFXName(tr, k, "")
      t.fx[g] = { name = fn, on = reaper.TrackFX_GetEnabled(tr, k), off = reaper.TrackFX_GetOffline(tr, k) }
      t.fxo[#t.fxo + 1] = g
    end
    local g = i == -1 and "master" or reaper.GetTrackGUID(tr)
    snap.tracks[g] = t
    snap.order[#snap.order + 1] = g
  end
  return snap
end

local function snap_diff(a, b)
  local out = {}
  local function add(line) if #out < MAX_LINES then out[#out + 1] = line end end
  local function label(t) return t.i == -1 and "master" or ("#%d %s"):format(t.i + 1, t.name) end
  if math.abs(a.tempo - b.tempo) > 1e-6 then add(("tempo %g → %g BPM"):format(a.tempo, b.tempo)) end
  for _, g in ipairs(a.order) do
    if not b.tracks[g] then add("delete track " .. label(a.tracks[g])) end
  end
  for _, g in ipairs(b.order) do
    local x, y = a.tracks[g], b.tracks[g]
    if not x then add("add track " .. label(y))
    else
      local L = label(y)
      if x.name ~= y.name then add(("%s: renamed from %s"):format(L, x.name)) end
      if math.abs(db_of(x.vol) - db_of(y.vol)) > 0.05 then add(("%s: volume %.1f → %.1f dB"):format(L, db_of(x.vol), db_of(y.vol))) end
      if math.abs(x.pan - y.pan) > 0.005 then add(("%s: pan %.2f → %.2f"):format(L, x.pan, y.pan)) end
      if x.mute ~= y.mute then add(L .. (y.mute == 1 and ": mute" or ": unmute")) end
      for _, fg in ipairs(x.fxo) do
        if not y.fx[fg] then add(("%s: remove %s"):format(L, x.fx[fg].name)) end
      end
      for _, fg in ipairs(y.fxo) do
        local o, f = x.fx[fg], y.fx[fg]
        if not o then add(("%s: add %s%s"):format(L, f.name, f.on and "" or " (bypassed)"))
        else
          if o.name ~= f.name then add(("%s: %s renamed %s"):format(L, o.name, f.name)) end
          if o.on ~= f.on then add(("%s: %s %s"):format(L, f.on and "enable" or "bypass", f.name)) end
          if o.off ~= f.off then add(("%s: %s %s"):format(L, f.off and "offline" or "online", f.name)) end
        end
      end
      if x.items ~= y.items then
        local d = y.items - x.items
        add(("%s: %s%d item%s"):format(L, d > 0 and "+" or "-", math.abs(d), math.abs(d) == 1 and "" or "s"))
      end
      if x.lanes ~= y.lanes then add(y.lanes > 0 and ("%s: %d fixed lanes"):format(L, y.lanes) or (L .. ": back to one lane")) end
      if x.sends ~= y.sends then
        local d = y.sends - x.sends
        add(("%s: %s%d send%s"):format(L, d > 0 and "+" or "-", math.abs(d), math.abs(d) == 1 and "" or "s"))
      end
    end
  end
  return out
end

-- "-- set up the Pizz sound rack" on a script's first line is its title on the receipt
local function script_title(code)
  local line = tostring(code or ""):match("^%s*([^\n]*)") or ""
  local t = line:match("^%-%-+%s*(.-)%s*$")
  if t and t ~= "" then return short(t, 70) end
end

local function first_line(code)
  local line = tostring(code or ""):match("^%s*([^\n]*)") or ""
  return short(line, 50)
end

----------------------------------------------------------------------
-- Dispatch
----------------------------------------------------------------------
local function tidy_err(msg)
  msg = tostring(msg or "")
  msg = msg:gsub('%[string "mcp_run_lua"%]:', "lua:")
  msg = msg:gsub("^bridge error: ", "")
  return msg
end

-- "lua:12: attempt to index a nil value" -> append the offending source line so the fix is obvious.
local function with_line(msg, code)
  local n = tonumber(msg:match("^lua:(%d+):"))
  if not n or type(code) ~= "string" then return msg end
  local i = 0
  for raw in (code .. "\n"):gmatch("([^\n]*)\n") do
    i = i + 1
    if i == n then
      local line = raw:gsub("^%s+", "")
      if #line > 160 then line = line:sub(1, 157) .. "..." end
      return msg .. "  [line " .. n .. ": " .. line .. "]"
    end
  end
  return msg
end

dispatch = function(req)
  local func = req.func
  if func == "run_lua" then
    local chunk, cerr = load(req.code, "mcp_run_lua", "t",
      setmetatable({ reaper = reaper, json = json, to_handle = to_handle,
                     handles = handles }, { __index = _G }))
    if not chunk then return { ok = false, error = with_line(tidy_err(cerr), req.code) } end
    -- past its timeout the snippet is stopped at the next Lua instruction; a call blocked inside REAPER or a
    -- host command (ExecProcess, a render, a modal dialog) can't be interrupted and is stopped when it returns
    local limit = tonumber(req.timeout) or RUN_LUA_TIMEOUT
    local hook = debug and debug.sethook
    if hook then
      local deadline = reaper.time_precise() + limit
      hook(function()
        if reaper.time_precise() > deadline then
          hook()
          error(("run_lua stopped: still running after %g s (its timeout); what it did before that stays done"):format(limit), 0)
        end
      end, "", 10000)
    end
    local ok, ret = pcall(chunk)
    if hook then hook() end
    if not ok then return { ok = false, error = with_line(tidy_err(ret), req.code) } end
    return { ok = true, ret = ret }
  end

  local args = req.args or {}
  local nargs = json.len(args)
  for i = 1, nargs do args[i] = unmarshal(args[i]) end

  if DSL[func] then
    -- described before the call: a deleted track has no name afterwards
    local what = receipt_wanted(func) and describe(func, args)
    local ok, res = pcall(DSL[func], table.unpack(args, 1, nargs))
    if what then note_change(what, ok, ok and res and res.ret) end
    if not ok then error(res, 0) end
    res = res or {}
    if res.ok == nil then res.ok = true end
    return res
  end

  local fn = reaper[func]
  if type(fn) == "function" then
    local packed = table.pack(pcall(fn, table.unpack(args, 1, nargs)))
    if receipt_wanted(func) then note_change(describe(func, args), packed[1]) end
    if not packed[1] then
      return { ok = false, error = "error calling " .. func .. ": " .. tostring(packed[2]) }
    end
    local rets = {}
    for i = 2, packed.n do rets[i - 1] = packed[i] == nil and json.null or packed[i] end
    if #rets <= 1 then return { ok = true, ret = rets[1] }
    else return { ok = true, ret = rets } end
  end

  return { ok = false, error = "unknown function: " .. tostring(func) }
end

local function batch_writes(req)
  for _, c in ipairs(type(req.args) == "table" and type(req.args[1]) == "table" and req.args[1] or {}) do
    if type(c) == "table" and (c.func == "run_lua" or c.func == "render_project" or receipt_wanted(tostring(c.func))) then
      return true
    end
  end
  return false
end

-- A reply works on the project tab that was in front when it first changed something. If the user brings another
-- tab to the front meanwhile, writes (and renders) are refused instead of landing there. A panel reply stays
-- refused until it ends; without the panel (calls < 2 min apart share a turn) the first refusal re-pins to the new
-- tab, so the agent hears about the switch once and can go on there if that's what the user wants.
local pin = nil -- { turn, proj, path }
local function project_name(path) return (path ~= "" and path:match("[^/\\]+$")) or "an unsaved project" end
local function guard_project(turn)
  local proj, path = reaper.EnumProjects(-1, "")
  if not pin or pin.turn ~= turn then pin = { turn = turn, proj = proj, path = path }; return end
  if pin.proj == proj then return end
  local was = pin.path
  if not turn:match("^mcp%-") then
    error(("refused: this reply started on %s, but %s is now the active project tab. Nothing was changed. "
      .. "Ask the user to switch back to %s, or to send a new message for this tab."):format(
      project_name(was), project_name(path), project_name(was)), 0)
  end
  pin = { turn = turn, proj = proj, path = path }
  error(("refused once: earlier calls changed %s, but %s is now the active project tab. Nothing was changed. "
    .. "If the user meant to switch, repeat the call; it will go to %s."):format(
    project_name(was), project_name(path), project_name(path)), 0)
end

-- one undo block per request that can change something; its changes go on the turn's receipt. An empty block
-- leaves no undo point, which is how a read-only run_lua stays off the receipt
local function run_request(req)
  local func = req.func
  if func == "render_project" then guard_project(current_turn()) end
  if func ~= "run_lua" and not receipt_wanted(func) and func ~= "batch" then return dispatch(req) end
  local turn = current_turn()
  if func ~= "batch" or batch_writes(req) then guard_project(turn) end
  staged = {}
  -- code we can't describe from its arguments (run_lua, raw API calls, a batch holding one): diff the project
  local opaque = func == "run_lua" or not DSL[func]
  if func == "batch" then
    for _, c in ipairs(type(req.args) == "table" and type(req.args[1]) == "table" and req.args[1] or {}) do
      if type(c) == "table" and (c.func == "run_lua" or not DSL[c.func]) then opaque = true end
    end
  end
  -- never lets a receipt detail cost the call: a failing snapshot just means the generic line
  local before = opaque and select(2, pcall(snapshot)) or nil
  if type(before) ~= "table" then before = nil end
  reaper.Undo_BeginBlock2(0)
  undo_depth = undo_depth + 1
  local ok, resp = pcall(dispatch, req)
  undo_depth = undo_depth - 1
  local fine = ok and not (type(resp) == "table" and resp.ok == false)
  if opaque then
    local after = before and select(2, pcall(snapshot))
    local okd, lines = false, nil
    if type(after) == "table" then okd, lines = pcall(snap_diff, before, after) end
    if not okd or type(lines) ~= "table" then lines = {} end
    local title = func == "run_lua" and script_title(req.code)
    if title or #lines > 0 then
      staged = {}
      if title then note_change(title, fine) end
      for _, l in ipairs(lines) do note_change(l, fine) end
    elseif func == "run_lua" then
      note_change("script: " .. first_line(req.code), fine)
    end
  end
  local first = staged[1] and staged[1].what or func
  local label = "Hibiki " .. turn .. ": " .. short(first, 70) .. (#staged > 1 and (" +" .. (#staged - 1)) or "")
  -- EndBlock ticks the state-change counter even when it makes no undo point, so a new point is told apart by
  -- the top of the undo list changing; the label is made to differ from the top it would replace
  local top = reaper.Undo_CanUndo2(0)
  while label == top do label = label .. "·" end
  reaper.Undo_EndBlock2(0, label, -1)
  if reaper.Undo_CanUndo2(0) ~= top then
    if #staged == 0 then note_change(func) end
    commit_receipt(turn)
  end
  staged = {}
  if not ok then error(resp, 0) end
  return resp
end

----------------------------------------------------------------------
-- Main loop
----------------------------------------------------------------------
reaper.RecursiveCreateDirectory(DIR, 0)
local serving = false
local function start_serving()
  serving = true
  os.remove(REQ)
  os.remove(RESP)
  os.remove(TMP)
  os.remove(BUSY)
  touch_heartbeat(true)
  log("reaper-mcp bridge " .. VERSION .. " ready\n  " .. DIR) -- no console window on every launch; `hibiki doctor` / ping report the version
end
if other_bridge_alive() then
  reaper.ShowConsoleMsg("reaper-mcp bridge: another REAPER is already serving the MCP; this one waits until it quits.\n")
else
  start_serving()
end

local function handle_mailbox()
  -- claim the request by renaming it: only one bridge can win, so a request never runs twice
  local raw = os.rename(REQ, CLAIM) and read_file(CLAIM)
  if raw then
    os.remove(CLAIM)
    local bf = io.open(BUSY, "wb")
    if bf then bf:write("1") bf:close() end
    touch_heartbeat(true)
    if DEBUG then log("REQ: " .. raw) end
    local req, derr = json.decode(raw)
    local resp
    if not req then
      resp = { ok = false, error = "bad request json: " .. tostring(derr) }
    else
      local ok, r = pcall(run_request, req)
      if ok then resp = r
      else resp = { ok = false, error = tidy_err(r) } end
      resp.id = req.id
    end
    local out = json.encode(resp)
    if DEBUG then log("RESP: " .. out) end
    write_atomic(RESP, out, TMP)
    os.remove(BUSY)
    touch_heartbeat(true)
  end
end

local tick_error_shown = false
local next_check = 0
local function tick()
  if not serving then
    local now = reaper.time_precise()
    if now >= next_check then
      next_check = now + 1
      if not other_bridge_alive() then start_serving() end
    end
    reaper.defer(tick)
    return
  end
  touch_heartbeat()
  local ok, err = pcall(handle_mailbox)
  if not ok then
    os.remove(BUSY)
    if not tick_error_shown then -- once, not every 30 ms
      tick_error_shown = true
      reaper.ShowConsoleMsg("reaper-mcp bridge: " .. tostring(err) .. "\n")
    end
  end
  reaper.defer(tick)
end

reaper.defer(tick)
