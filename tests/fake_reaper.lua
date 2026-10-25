--[[
  Minimal fake ReaScript API so reaper_mcp/bridge.lua can be driven headlessly.

  Written in Lua, not driven from Python, because ReaScript relies on multiple
  return values and lupa does not unpack Python tuples into those.

  Globals exposed for the harness: calls, ticks, tracks, now, ppq, pump().
]]

local PPQ = 960.0
ppq = PPQ
calls = {}
ticks = {}
now = 1000.0
tracks = {}
master = { name = "Master", master = true }

local function hit(k) calls[k] = (calls[k] or 0) + 1 end

local function track(i)
  if i == -1 then return master end
  local t = tracks[i + 1]
  if not t then error("no track at index " .. tostring(i)) end
  return t
end

local function item_at(t, i)
  local it = t.items[i + 1]
  if not it then error("no item at index " .. tostring(i)) end
  return it
end

function pump(n, dt)
  for _ = 1, (n or 1) do
    now = now + (dt or (1 / 60))
    local fn = ticks[#ticks]
    if not fn then break end
    fn()
  end
end

function new_track(name)
  return { name = name or "", items = {}, sends = {}, envelopes = {} }
end

function new_item(pos, len)
  return { position = pos, length = len, notes = {}, ccs = {}, loop = true }
end

reaper = {}

reaper.GetOS = function() return "OSX64" end
reaper.GetAppVersion = function() return "7.99/fake" end
-- clock_step > 0: every read moves the clock on (a loop that runs for "seconds" inside one request)
clock_step = 0
reaper.time_precise = function() now = now + clock_step return now end
reaper.ShowConsoleMsg = function() hit("ShowConsoleMsg") end
reaper.RecursiveCreateDirectory = function() hit("RecursiveCreateDirectory") end
reaper.defer = function(f) hit("defer") ticks[#ticks + 1] = f end

-- project
reaper.CountTracks = function() return #tracks end
reaper.GetTrack = function(_, i) return track(i) end
reaper.GetMasterTrack = function() return master end
reaper.GetTrackName = function(t) return true, t.name end
reaper.GetMediaTrackInfo_Value = function(t, key)
  hit("GetMediaTrackInfo_Value")
  if key == "D_VOL" then return t.vol or 1.0 end
  if key == "B_MUTE" then return t.mute and 1 or 0 end
  if key == "I_SOLO" then return t.solo and 1 or 0 end
  if key == "IP_TRACKNUMBER" then
    for i, x in ipairs(tracks) do if x == t then return i end end
    return 0
  end
  if key == "B_MAINSEND" then return t.mainsend == false and 0 or 1 end
  if key == "I_NCHAN" then return t.nchan or 2 end
  return 0.0
end
reaper.SetMediaTrackInfo_Value = function(t, key, v)
  hit("SetMediaTrackInfo_Value")
  fake_changed = true
  if key == "D_VOL" then t.vol = v end
  if key == "B_MUTE" then t.mute = (v == 1) end
  if key == "I_SOLO" then t.solo = (v ~= 0) end
  if key == "B_MAINSEND" then t.mainsend = (v ~= 0) end
  if key == "I_NCHAN" then t.nchan = v end
end
reaper.GetSetMediaTrackInfo_String = function(t, key, v)
  if key == "P_NAME" then t.name = v end
  return true, t.name
end
reaper.InsertTrackAtIndex = function(i) fake_changed = true table.insert(tracks, i + 1, new_track()) end
reaper.DeleteTrack = function(t)
  for i, x in ipairs(tracks) do
    if x == t then table.remove(tracks, i) return end
  end
end
reaper.TrackList_AdjustWindows = function() hit("TrackList_AdjustWindows") end
reaper.UpdateArrange = function() hit("UpdateArrange") end
reaper.UpdateTimeline = function() hit("UpdateTimeline") end
reaper.Main_GetTempo = function() return 120.0 end
reaper.Master_GetTempo = function() return 120.0 end
reaper.GetPlayState = function() return 0 end
reaper.GetCursorPosition = function() return 0.0 end
local project_path = ""
reaper.EnumProjects = function() return 0, project_path end
reaper.Main_openProject = function(name)
  hit("Main_openProject")
  project_path = name:gsub("^noprompt:", "")
end
reaper.TimeMap2_QNToTime = function(_, qn) return qn * 0.5 end
reaper.TimeMap2_timeToQN = function(_, t) return t / 0.5 end
reaper.TimeMap_GetTimeSigAtTime = function() return 4, 4, 120.0 end
reaper.GetProjectLength = function()
  local max = 0
  for _, t in ipairs(tracks) do
    for _, it in ipairs(t.items) do
      local e = (it.position or 0) + (it.length or 0)
      if e > max then max = e end
    end
  end
  return max
end
markers = markers or {}
reaper.CountProjectMarkers = function() return #markers end
reaper.EnumProjectMarkers = function(i)
  local m = markers[i + 1]
  if not m then return false, false, 0, 0, "", 0 end
  return true, m.isrgn or false, m.pos or 0, m.rgnend or 0, m.name or "", m.idx or i
end

-- undo
reaper.Undo_BeginBlock = function() hit("Undo_BeginBlock") end
reaper.Undo_EndBlock = function() hit("Undo_EndBlock") end
-- like REAPER: an EndBlock that saw no change leaves no undo point, but ticks the state counter all the same
undo_labels, state_changes, fake_changed = {}, 0, false
reaper.Undo_BeginBlock2 = function() hit("Undo_BeginBlock2") fake_changed = false end
reaper.Undo_EndBlock2 = function(_, label)
  hit("Undo_EndBlock2")
  state_changes = state_changes + 1
  if fake_changed then undo_labels[#undo_labels + 1] = label end
end
reaper.Undo_CanUndo2 = function() return undo_labels[#undo_labels] end
reaper.GetProjectStateChangeCount = function() return state_changes end
reaper.MarkTrackItemsDirty = function() hit("MarkTrackItemsDirty") end
reaper.GetMediaItem_Track = function(it) return it.track end
ext_state = {}
reaper.GetExtState = function(sec, key) return ext_state[sec .. "/" .. key] or "" end
reaper.SetExtState = function(sec, key, v) ext_state[sec .. "/" .. key] = v end
reaper.Undo_OnStateChange_Item = function() hit("Undo_OnStateChange_Item") end

-- items
reaper.CountTrackMediaItems = function(t) return #(t.items or {}) end
reaper.GetTrackMediaItem = function(t, i)
  hit("GetTrackMediaItem")
  return t.items[i + 1]
end
reaper.GetMediaItemInfo_Value = function(it, key)
  hit("item." .. tostring(key))
  if key == "D_POSITION" then return it.position end
  if key == "D_LENGTH" then return it.length end
  if key == "D_VOL" then return it.vol or 1.0 end
  if key == "D_FADEINLEN" or key == "D_FADEOUTLEN" then return 0.0 end
  if key == "B_LOOPSRC" then return it.loop and 1 or 0 end
  if key == "B_MUTE" then return it.mute and 1 or 0 end
  if key == "IP_ITEMNUMBER" then
    for _, t in ipairs(tracks) do
      for i, x in ipairs(t.items) do if x == it then return i - 1 end end
    end
    return 0
  end
  return 0.0
end
reaper.SetMediaItemInfo_Value = function(it, key, v)
  hit("SetMediaItemInfo_Value")
  if key == "B_LOOPSRC" then it.loop = (v == 1) end
  if key == "D_LENGTH" then it.length = v end
  if key == "D_POSITION" then it.position = v end
end
reaper.SetMediaItemLength = function(it, v) it.length = v end
reaper.CreateNewMIDIItemInProj = function(t, s, e)
  local it = new_item(s, e - s)
  t.items[#t.items + 1] = it
  return it
end
reaper.GetActiveTake = function(it) return it end
reaper.TakeIsMIDI = function() return true end
reaper.GetMediaItemTake_Item = function(take) return take end

-- MIDI
reaper.MIDI_CountEvts = function(take) return #take.notes, #take.notes, 0, 0 end
reaper.MIDI_GetNote = function(take, i)
  local n = take.notes[i + 1]
  return true, n.sel, n.muted, n.sppq, n.eppq, n.chan, n.pitch, n.vel
end
reaper.MIDI_SetNote = function(take, i, sel, muted, sppq, eppq, chan, pitch, vel, no_sort)
  hit("MIDI_SetNote")
  hit(no_sort and "MIDI_SetNote.noSort" or "MIDI_SetNote.sorted")
  local n = take.notes[i + 1]
  if sel ~= nil then n.sel = sel end
  n.muted, n.sppq, n.eppq = muted, sppq, eppq
  n.chan, n.pitch, n.vel = chan, pitch, vel
end
reaper.MIDI_InsertNote = function(take, sel, muted, sppq, eppq, chan, pitch, vel)
  hit("MIDI_InsertNote")
  fake_changed = true
  take.notes[#take.notes + 1] = { sel = sel, muted = muted, sppq = sppq,
    eppq = eppq, chan = chan, pitch = pitch, vel = vel }
end
reaper.MIDI_DeleteNote = function(take, i)
  hit("MIDI_DeleteNote")
  table.remove(take.notes, i + 1)
end
reaper.MIDI_Sort = function(take)
  hit("MIDI_Sort")
  table.sort(take.notes, function(a, b) return a.sppq < b.sppq end)
end
reaper.MIDI_GetPPQPosFromProjQN = function(_, qn) return qn * PPQ end
reaper.MIDI_GetProjQNFromPPQPos = function(_, ppq) return ppq / PPQ end
reaper.MIDI_InsertCC = function(take, sel, muted, ppq, chanmsg, chan, msg2, msg3)
  hit("MIDI_InsertCC")
  fake_changed = true
  take.ccs = take.ccs or {}
  take.ccs[#take.ccs + 1] = {
    sel = sel, muted = muted, ppq = ppq, chanmsg = chanmsg,
    chan = chan, msg2 = msg2, msg3 = msg3,
  }
end
reaper.SetEditCurPos = function(pos)
  hit("SetEditCurPos")
  cursor = pos
end
reaper.SetTrackSelected = function(t, sel)
  t.selected = sel and true or false
end
-- render settings and a fake 42230 that writes the planned files
proj_info, proj_str = {}, {}
fake_gain = 2.0          -- CalculateNormalization result: 2.0 = peak/LUFS at -6 dB
renders = {}             -- solo/mute state seen by each 42230
reaper.GetSetProjectInfo = function(_, key, v, set)
  if set then proj_info[key] = v end
  return proj_info[key] or 0
end
local function render_targets()
  local dir = proj_str.RENDER_FILE or "/tmp"
  local pat = proj_str.RENDER_PATTERN or "untitled"
  local out = {}
  if proj_info.RENDER_SETTINGS == 2 then
    for _, t in ipairs(tracks) do
      if t.selected then out[#out + 1] = dir .. "/" .. pat:gsub("%$track", t.name) .. ".wav" end
    end
  else
    out[1] = dir .. "/" .. pat:gsub("%$track", "Master") .. ".wav"
  end
  return out
end
reaper.GetSetProjectInfo_String = function(_, key, v, set)
  if key == "RENDER_TARGETS" then return true, table.concat(render_targets(), ";") end
  if set then proj_str[key] = v end
  return true, proj_str[key] or ""
end
reaper.AnyTrackSolo = function()
  for _, t in ipairs(tracks) do if t.solo then return true end end
  return ui_solo == true
end
-- like REAPER: a selected track gangs every selected track unless igngroupflags has &2
reaper.SetTrackUISolo = function(t, solo, flags)
  hit("SetTrackUISolo")
  if t.selected and ((flags or 0) & 2) == 0 then
    for _, x in ipairs(tracks) do if x.selected then x.solo = solo ~= 0 end end
  end
  t.solo = solo ~= 0
end
reaper.IsProjectDirty = function() return project_dirty or 0 end
reaper.PCM_Source_CreateFromFile = function(p) return { path = p } end
reaper.GetMediaSourceLength = function() return 2.0 end
reaper.CalculateNormalization = function() return fake_gain end
reaper.PCM_Source_Destroy = function() hit("PCM_Source_Destroy") end

reaper.Main_OnCommand = function(id)
  hit("Main_OnCommand")
  hit("cmd." .. tostring(id))
  if id == 40297 then
    for _, t in ipairs(tracks) do t.selected = false end
  end
  if id == 42230 then
    local state = {}
    for i, t in ipairs(tracks) do state[i] = { solo = t.solo or false, mute = t.mute or false } end
    renders[#renders + 1] = state
    for _, f in ipairs(render_targets()) do
      local h = io.open(f, "wb")
      if h then h:write("RIFFfake") h:close() end
    end
  end
end
-- like REAPER: the item goes in at the edit cursor, items stay sorted by position, a new track goes after the
-- selected one
reaper.InsertMedia = function(path, mode)
  hit("InsertMedia")
  local sel
  for i, x in ipairs(tracks) do
    if x.selected then sel = i break end
  end
  local it = new_item(cursor or 0, 4)
  if mode == 1 then
    local t = new_track("imported")
    t.items[1] = it
    table.insert(tracks, (sel or #tracks) + 1, t)
  else
    local t = tracks[sel or #tracks]
    local at = #t.items + 1
    for i, x in ipairs(t.items) do
      if x.position > it.position then at = i break end
    end
    table.insert(t.items, at, it)
  end
  return true
end
reaper.Main_SaveProject = function(_, force)
  hit("Main_SaveProject")
  saved = { force = force }
end
local written = {}
reaper.Main_SaveProjectEx = function(_, path, flags)
  hit("Main_SaveProjectEx")
  if path:find("^/readonly/") then return end
  saved = { path = path, flags = flags }
  written[path] = true
end
reaper.file_exists = function(path)
  if written[path] then return true end
  local h = io.open(path, "rb")
  if h then h:close() return true end
  return false
end

-- sends / envelopes / fx
reaper.GetTrackNumSends = function(t) return #(t.sends or {}) end
reaper.GetTrackSendInfo_Value = function(t, _, i, key)
  local s = t.sends[i + 1]
  if key == "D_VOL" then return s.vol or 1.0 end
  if key == "D_PAN" then return s.pan or 0.0 end
  if key == "B_MUTE" then return s.mute and 1 or 0 end
  if key == "P_DESTTRACK" then return s.dest end
  return s[key] or 0
end
reaper.SetTrackSendInfo_Value = function(t, _, i, key, v)
  local s = t.sends[i + 1]
  if key == "D_VOL" then s.vol = v
  elseif key == "D_PAN" then s.pan = v
  elseif key == "B_MUTE" then s.mute = (v == 1)
  else s[key] = v end
  return true
end
reaper.GetEnvelopeStateChunk = function(env) return true, env.chunk or "<VOLENV2\nACT 1 -1\n>" end
reaper.SetEnvelopeStateChunk = function(env, chunk) env.chunk = chunk return true end
reaper.CountTrackEnvelopes = function(t) return #t.envelopes end
reaper.GetTrackEnvelope = function(t, i) return t.envelopes[i + 1] end
reaper.GetEnvelopeName = function(env) return true, (env and env.name) or "Volume" end
reaper.CountEnvelopePoints = function(env) return #env.points end
reaper.GetEnvelopePoint = function(env, i)
  local p = env.points[i + 1]
  return true, p[1], p[2], 0, 0, false
end
reaper.GetTrackEnvelopeByName = function(t, name)
  for _, e in ipairs(t.envelopes) do if e.name == name then return e end end
end
reaper.DeleteEnvelopePointRange = function(env, t0, t1)
  for i = #env.points, 1, -1 do
    if env.points[i][1] >= t0 and env.points[i][1] < t1 then table.remove(env.points, i) end
  end
end
reaper.InsertEnvelopePoint = function(env, time, value)
  env.points[#env.points + 1] = { time, value }
  return true
end
reaper.Envelope_SortPoints = function(env) table.sort(env.points, function(a, b) return a[1] < b[1] end) end
-- fader scaling as REAPER computes it (schwa, forum.cockos.com t=241604): a gain of 1.0 sits at 716.2 of 1000
local FADER, FADER_I = 1.9905358527674863, 0.25118864315095801
reaper.GetEnvelopeScalingMode = function(env) return env.scaling or 0 end
reaper.ScaleToEnvelopeMode = function(mode, v)
  if mode ~= 1 then return v end
  local b = (-FADER + math.sqrt(FADER * FADER + 4 * FADER * v)) * FADER_I
  return b ^ (1 / 3) * 1000
end
reaper.ScaleFromEnvelopeMode = function(mode, y)
  if mode ~= 1 then return y end
  y = (y * 0.001) ^ 3
  return (y + y * y) * FADER
end
reaper.CreateTrackSend = function(src, dest)
  src.sends[#src.sends + 1] = { dest = dest }
  return #src.sends - 1
end
-- FX: one fake compressor per track that has t.fx = true. Param 0 Threshold (-60..0 dB), 1 Ratio (1:1..inf, like
-- ReaComp's), 2 Mode (enum labels).
local MODES = { "Off", "Blown Capacitor 4", "4" }
local function fx_display(p, v)
  if p == 0 then return string.format("%.1f", -60 + 60 * v) end
  if p == 1 then
    if v >= 1 then return "inf" end
    return string.format("%.1f:1", 1 / (1 - v))
  end
  return MODES[math.min(3, math.floor(v * 3) + 1)]
end
reaper.TrackFX_GetCount = function(t) return t.fx and 1 or 0 end
reaper.TrackFX_GetNumParams = function(t) return t.fx and 3 or 0 end
reaper.TrackFX_GetParamName = function(_, _, p) return true, ({ "Threshold", "Ratio", "Mode" })[p + 1] end
reaper.TrackFX_FormatParamValueNormalized = function(_, _, p, v) hit("FormatParamValueNormalized") return true, fx_display(p, v) end
reaper.TrackFX_SetParamNormalized = function(t, _, p, v)
  t.fxp = t.fxp or {}
  t.fxp[p] = v
  return true
end
reaper.TrackFX_SetParam = reaper.TrackFX_SetParamNormalized
reaper.TrackFX_GetParam = function(t, _, p) return (t.fxp or {})[p] or 0, 0, 1 end
reaper.TrackFX_GetFormattedParamValue = function(t, _, p) return true, fx_display(p, (t.fxp or {})[p] or 0) end

-- Count heartbeat writes without touching the real API.
local real_open = io.open
io.open = function(p, mode)
  if mode == "wb" and p:match("heartbeat$") then hit("heartbeat_writes") end
  return real_open(p, mode)
end

-- GUIDs for the receipt's before/after project diff
local guid_n = 0
reaper.GetTrackGUID = function(t)
  if not t.guid then guid_n = guid_n + 1; t.guid = ("{T%04d}"):format(guid_n) end
  return t.guid
end
reaper.TrackFX_GetFXGUID = function(t, i) return t.fx and ("{FX-" .. reaper.GetTrackGUID(t) .. "}") or nil end
reaper.TrackFX_GetFXName = function(t, i) return true, "ReaComp" end
reaper.TrackFX_GetEnabled = function(t) return not t.fx_bypassed end
reaper.TrackFX_GetOffline = function() return false end

-- ---------------------------------------------------------------- 2026-10-24: arrange verbs, selection, tempo map
local function track_of(it)
  for _, t in ipairs(tracks) do
    for i, x in ipairs(t.items) do if x == it then return t, i end end
  end
end
local function sort_items(t) table.sort(t.items, function(a, b) return a.position < b.position end) end
reaper.GetMediaItem_Track = function(it) return it.track or track_of(it) end
reaper.IsTrackSelected = function(t) return t.selected == true end
time_sel = { 0, 0 }
reaper.GetSet_LoopTimeRange2 = function(_, set, _, s, e)
  if set then time_sel = { s, e } end
  return time_sel[1], time_sel[2]
end
reaper.CountSelectedMediaItems = function()
  local n = 0
  for _, t in ipairs(tracks) do for _, it in ipairs(t.items) do if it.selected then n = n + 1 end end end
  return n
end
reaper.GetSelectedMediaItem = function(_, k)
  local n = 0
  for _, t in ipairs(tracks) do
    for _, it in ipairs(t.items) do
      if it.selected then
        if n == k then return it end
        n = n + 1
      end
    end
  end
end
tempo_markers = {}
reaper.CountTempoTimeSigMarkers = function() return #tempo_markers end
reaper.GetTempoTimeSigMarker = function(_, i)
  local m = tempo_markers[i + 1]
  return true, m.time, 0, 0, m.bpm, m.num or 0, m.den or 0, m.linear or false
end
play_pos = 0
reaper.GetPlayPosition = function() return play_pos end
reaper.GetCursorPosition = function() return cursor or 0.0 end
active_proj = 0
reaper.EnumProjects = function() return active_proj, project_path end

-- item properties beyond the basics live in it.info
local base_get, base_set = reaper.GetMediaItemInfo_Value, reaper.SetMediaItemInfo_Value
reaper.GetMediaItemInfo_Value = function(it, key)
  if key == "D_FADEINLEN" or key == "D_FADEOUTLEN" or key == "C_FADEINSHAPE" or key == "C_FADEOUTSHAPE"
      or key == "I_CURTAKE" then
    hit("item." .. key)
    if key == "I_CURTAKE" then return it.curtake or 0 end
    return (it.info or {})[key] or 0
  end
  return base_get(it, key)
end
reaper.SetMediaItemInfo_Value = function(it, key, v)
  it.info = it.info or {}
  it.info[key] = v
  return base_set(it, key, v)
end
-- takes: the item is its own first take (as before); it.takes = { take2, ... } adds more
reaper.CountTakes = function(it) return 1 + #(it.takes or {}) end
reaper.GetTake = function(it, i) if i == 0 then return it end return (it.takes or {})[i] end
reaper.GetActiveTake = function(it) if (it.curtake or 0) == 0 then return it end return it.takes[it.curtake] end
reaper.SetActiveTake = function(take)
  for _, t in ipairs(tracks) do
    for _, it in ipairs(t.items) do
      if it == take then it.curtake = 0 end
      for k, x in ipairs(it.takes or {}) do if x == take then it.curtake = k end end
    end
  end
end
reaper.TakeIsMIDI = function(take) return not take.audio end
reaper.GetSetMediaItemTakeInfo_String = function(take, key, v, set)
  if key == "P_NAME" then if set then take.take_name = v end return true, take.take_name or "" end
  return false, ""
end
reaper.GetMediaItemTake_Source = function(take) return take.audio and { file = take.audio } or nil end
reaper.GetMediaSourceFileName = function(src) return src.file end
reaper.GetMediaItemTakeInfo_Value = function(take, key)
  if key == "D_PLAYRATE" then return take.rate or 1 end
  if key == "D_STARTOFFS" then return take.offs or 0 end
  return 0
end
reaper.SetMediaItemTakeInfo_Value = function(take, key, v)
  if key == "D_STARTOFFS" then take.offs = v end
  return true
end
reaper.SplitMediaItem = function(it, t)
  if t <= it.position or t >= it.position + it.length then return nil end
  local tr = track_of(it)
  local right = new_item(t, it.position + it.length - t)
  right.offs = (it.offs or 0) + (t - it.position)
  it.length = t - it.position
  tr.items[#tr.items + 1] = right
  sort_items(tr)
  fake_changed = true
  return right
end
reaper.DeleteTrackMediaItem = function(t, it)
  for i, x in ipairs(t.items) do if x == it then table.remove(t.items, i) fake_changed = true return true end end
  return false
end
reaper.MoveMediaItemToTrack = function(it, dest)
  local src, i = track_of(it)
  table.remove(src.items, i)
  dest.items[#dest.items + 1] = it
  sort_items(dest)
  fake_changed = true
  return true
end
local chunk_src, guid_seq = {}, 0
reaper.genGuid = function() guid_seq = guid_seq + 1 return ("{%08X-0000-0000-0000-000000000000}"):format(guid_seq) end
reaper.GetItemStateChunk = function(it)
  chunk_src[#chunk_src + 1] = it
  return true, ("<ITEM\nSRC %d\nIGUID {AAAAAAAA-0000-0000-0000-000000000001}\n>"):format(#chunk_src)
end
reaper.AddMediaItemToTrack = function(t)
  local it = new_item(0, 0)
  t.items[#t.items + 1] = it
  fake_changed = true
  return it
end
reaper.SetItemStateChunk = function(it, chunk)
  local src = chunk_src[tonumber(chunk:match("SRC (%d+)"))]
  it.length, it.notes, it.chunk = src.length, src.notes, chunk
  return true
end
reaper.MIDI_CountEvts = function(take) return #take.notes, #take.notes, #(take.ccs or {}), 0 end
reaper.MIDI_GetCC = function(take, i)
  local c = take.ccs[i + 1]
  return true, c.sel or false, c.muted or false, c.ppq, c.chanmsg, c.chan, c.msg2, c.msg3
end
-- markers for goto: { pos, name, idx }
reaper.EnumProjectMarkers = function(i)
  local m = markers[i + 1]
  if not m then return 0, false, 0, 0, "", 0 end
  return i + 1, m.isrgn or false, m.pos or 0, m.rgnend or 0, m.name or "", m.idx or i
end
