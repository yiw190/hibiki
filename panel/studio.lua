-- Hibiki studio: what the panel adds around the chat.
--   receipts  each reply's REAPER changes (the bridge labels its undo points "Hibiki <turn>: …" and lists them in
--             ExtState Hibiki/receipts); after a reply that changed the project a copy goes to Version history
--             (Agent settings), where Go to brings back any version
--   meter     Hibiki_Meter.jsfx on the master's monitoring FX writes 100 ms frames to gmem "Hibiki" while REAPER
--             plays; the last playback becomes a few context lines (loudness, true peak, bands, stereo, per bar)
--   rack      audition variants tagged by the agent (track P_EXT:hibiki_var = "group/n", or P_EXT:hibiki_fxvar
--             lines "group/n<TAB>{fx guid}"), switched with numbered buttons or keys 1-9
--   ears      renders the time selection / razor area, measures it (REAPER + `hibiki ears`) and attaches it
-- Hibiki.lua loads this file with dofile and calls the returned function once with its helpers.
return function(P)
local ImGui, ctx, S, C, EXT = P.ImGui, P.ctx, P.S, P.C, P.EXT
local M = {}
local function now() return reaper.time_precise() end
local function log10(x) return math.log(x, 10) end
local function bar_beat(t)
  local beats, measures = reaper.TimeMap2_timeToBeats(0, t)
  return ('%d.%d'):format((measures or 0) + 1, math.floor(beats or 0) + 1)
end
local function bar_of(t)
  local _, measures = reaper.TimeMap2_timeToBeats(0, t)
  return (measures or 0) + 1
end
local function exists(path)
  local f = io.open(path, 'rb')
  if f then f:close() end
  return f ~= nil
end
local function plural(n, word) -- 1 reply / 2 replies, 1 change / 2 changes
  return ('%d %s'):format(n, n == 1 and word or (word:match('[^aeiou]y$') and (word:sub(1, -2) .. 'ies') or (word .. 's')))
end

local note = nil -- { text, till }: a short line in the composer's hint spot
function M.note(text) note = { text = text, till = now() + 6 } end
function M.hint() return note and now() < note.till and note.text or nil end

---------------------------------------------------------------- receipts
-- The bridge labels every undo point an agent makes "Hibiki <reply id>: …" and lists each reply's changes in ExtState
-- Hibiki/receipts. Changes are kept; Agent settings > Version history lists the replies and goes back to before one.
local R = { seq = nil, list = {}, n = 0, current = nil, ended = nil, summary = {} }
local RUN_ID = ('%x'):format(math.floor(now() * 1000) % 0xFFFFF)
reaper.SetExtState(EXT, 'turn', '', false) -- a panel that died mid-reply must not tag later changes as its own

-- queued: a message sent while a reply runs; it keeps that reply's id until the reply ends
function M.turn_start(queued)
  if queued and R.current then return end
  R.n = R.n + 1
  R.current = RUN_ID .. '.' .. R.n
  reaper.SetExtState(EXT, 'turn', R.current, false)
end
-- a reply's title: its first sentence that says something (no "OK", no headings or code), markdown stripped, ≤ 60 chars
local FILLER = { ['好的'] = true, ['好'] = true, ['收到'] = true, ['明白'] = true, ['ok'] = true, ['okay'] = true,
  ['sure'] = true, ['done'] = true, ['完成'] = true, ['好了'] = true }
local function title_of(text)
  local fence = false
  for line in (tostring(text or '') .. '\n'):gmatch('([^\n]*)\n') do
    if line:match('^%s*```') then fence = not fence
    elseif not fence then
      local l = line:gsub('^%s*#+%s*', ''):gsub('^%s*[-*>]%s+', ''):gsub('^%s*%d+[.)]%s+', '')
      l = l:gsub('%*%*', ''):gsub('`', ''):gsub('%[(.-)%]%(.-%)', '%1'):gsub('^%s+', ''):gsub('%s+$', '')
      if not l:match('^|') and l ~= '' then
        -- first sentence: the earliest terminator, found as plain text (a Lua [...] class splits UTF-8 marks)
        local cut
        for _, mark in ipairs({ '。', '！', '？', '；', '!', '?', ';', '. ' }) do
          local at = l:find(mark, 1, true)
          if at and (not cut or at < cut) then cut = at end
        end
        local first = cut and l:sub(1, cut - 1) or l
        for _, mark in ipairs({ '：', '，', ':', ',', '.' }) do -- no dangling mark at the end
          if first:sub(-#mark) == mark then first = first:sub(1, -#mark - 1) end
        end
        if not FILLER[first:lower()] and (utf8.len(first) or #first) >= 4 then
          if (utf8.len(first) or #first) > 60 then first = first:sub(1, (utf8.offset(first, 60) or 61) - 1) .. '…' end
          return first
        end
      end
    end
  end
end

function M.turn_end(said)
  if R.current then
    R.ended = R.current
    R.summary[R.current] = title_of(said)
  end
  R.current = nil
  reaper.SetExtState(EXT, 'turn', '', false)
end

-- the bridge logs a run_lua it could not describe as "script: <first line of code>"
local function readable(line)
  line = tostring(line or '')
  if line:match('^script: ') then return 'Ran a script' .. (line:match(' %(failed%)$') and ' (failed)' or '') end
  return line
end

local function read_receipts()
  local seq = reaper.GetExtState(EXT, 'receipts_seq')
  if seq == R.seq then return end
  R.seq = seq
  local list = P.decode(reaper.GetExtState(EXT, 'receipts'))
  R.list = type(list) == 'table' and list or {}
end

local function prefix(id) return 'Hibiki ' .. id .. ': ' end

---------------------------------------------------------------- meter
local MT = { on = reaper.GetExtState(EXT, 'meter') ~= '0', next = nil, seg = nil, prev = nil,
  alive = nil, alive_at = -math.huge, status = '' }
local GMEM = reaper.gmem_attach ~= nil and reaper.gmem_read ~= nil
if GMEM then reaper.gmem_attach('Hibiki') end
local MON = 0x1000000 -- the master's monitoring FX chain in TrackFX_* indices
local JS_NAMES = { 'JS:Hibiki/Hibiki_Meter.jsfx', 'JS:Hibiki/Hibiki_Meter', 'Hibiki Meter' }
local BAND_NAMES = { '40', '100', '250', '600', '1.5k', '3k', '6k', '12k' }

local function meter_slot()
  local m = reaper.GetMasterTrack(0)
  for i = 0, (reaper.TrackFX_GetRecCount and reaper.TrackFX_GetRecCount(m) or 0) - 1 do
    local _, name = reaper.TrackFX_GetFXName(m, MON + i, '')
    if (name or ''):find('Hibiki Meter', 1, true) then return i end
  end
  return -1
end
function MT.ensure()
  local m = reaper.GetMasterTrack(0)
  local slot = meter_slot()
  if MT.on and slot < 0 then
    if not exists(reaper.GetResourcePath() .. '/Effects/Hibiki/Hibiki_Meter.jsfx') then
      MT.status = 'not installed'
      return
    end
    local idx = -1
    for _, nm in ipairs(JS_NAMES) do
      idx = reaper.TrackFX_AddByName(m, nm, true, 1)
      if idx >= 0 then break end
    end
    MT.status = idx >= 0 and 'idle' or 'could not load'
  elseif not MT.on and slot >= 0 then
    reaper.TrackFX_Delete(m, MON + slot)
    MT.status = 'off'
  else
    MT.status = MT.on and 'idle' or 'off'
  end
end

local RK -- the rack listens to the meter's frames
local function add_frame(fr)
  local seg = MT.seg
  -- a jump back, or forward by more than a hop, is a new playback
  if not seg or fr.pos < seg.last - 0.3 or fr.pos > seg.last + 1.5 then
    if seg and #seg.f >= 20 then MT.prev = seg end
    seg = { f = {} }
    MT.seg = seg
  end
  seg.f[#seg.f + 1] = fr
  seg.last, seg.at = fr.pos, now()
  if #seg.f > 6000 then table.remove(seg.f, 1) end -- 10 min
  RK.on_frame(fr)
end

function MT.tick()
  if not GMEM or not MT.on or reaper.gmem_read(0) ~= 1 then return end
  local alive = reaper.gmem_read(5)
  if alive ~= MT.alive then MT.alive, MT.alive_at = alive, now() end
  local total, ring, stride = reaper.gmem_read(1), reaper.gmem_read(2), reaper.gmem_read(3)
  if ring <= 0 or stride < 16 then return end
  if not MT.next or total < MT.next then MT.next = total end -- first look, or the meter restarted
  if total - MT.next > ring then MT.next = total - ring end
  local G = reaper.gmem_read
  while MT.next < total do
    local o = 8 + (MT.next % ring) * stride
    local b = {}
    for k = 0, 7 do b[k + 1] = G(o + 8 + k) end
    add_frame({ pos = G(o), m = G(o + 2), s = G(o + 3), tp = G(o + 4), sp = G(o + 5), corr = G(o + 6), sm = G(o + 7), b = b })
    MT.next = MT.next + 1
  end
end
function MT.running() return MT.on and now() - MT.alive_at < 2 end

local function energy(l) return 10 ^ ((l + 0.691) / 10) end
local function lufs(e) return -0.691 + 10 * log10(e) end

-- integrated loudness of a run of frames (each frame's LUFS-M is a 400 ms gating block, 75 % overlap: BS.1770)
local function integrated(frames)
  local sum, n = 0, 0
  for _, f in ipairs(frames) do if f.m > -70 then sum, n = sum + energy(f.m), n + 1 end end
  if n == 0 then return nil end
  local gate = lufs(sum / n) - 10
  local s2, n2 = 0, 0
  for _, f in ipairs(frames) do if f.m > -70 and f.m > gate then s2, n2 = s2 + energy(f.m), n2 + 1 end end
  return n2 > 0 and lufs(s2 / n2) or nil
end

function MT.lines(L)
  local seg = MT.seg
  if not seg or #seg.f < 20 then seg = MT.prev end
  if not seg or #seg.f < 20 then return end
  local f = seg.f
  local playing = reaper.GetPlayState() & 1 == 1 and now() - seg.at < 1
  local ago = now() - seg.at
  if not playing and ago > 900 then return end
  local li = integrated(f)
  local smax, tmax, cmin = f[1], f[1], nil
  local sm_e, sm_n, band_e, band_n = 0, 0, { 0, 0, 0, 0, 0, 0, 0, 0 }, 0
  for _, x in ipairs(f) do
    if x.s > smax.s then smax = x end
    if x.tp > tmax.tp then tmax = x end
    if x.m > -50 then
      if not cmin or x.corr < cmin.corr then cmin = x end
      sm_e, sm_n = sm_e + 10 ^ (x.sm / 10), sm_n + 1
      for k = 1, 8 do band_e[k] = band_e[k] + 10 ^ (x.b[k] / 10) end
      band_n = band_n + 1
    end
  end
  local head = ('meter (Hibiki Meter on the master, %s): bars %s-%s (%.0f s)'):format(
    playing and 'playing now' or ('last playback ' .. math.floor(ago / 60) .. ':' .. ('%02d'):format(math.floor(ago % 60)) .. ' ago'),
    bar_beat(f[1].pos), bar_beat(f[#f].pos), f[#f].pos - f[1].pos + 0.1)
  local parts = {}
  if li then parts[#parts + 1] = ('LUFS-I %.1f'):format(li) end
  parts[#parts + 1] = ('LUFS-S max %.1f @ %s'):format(smax.s, bar_beat(smax.pos))
  parts[#parts + 1] = ('true peak max %.1f dBTP @ %s'):format(tmax.tp, bar_beat(tmax.pos))
  if cmin then parts[#parts + 1] = ('correlation min %.2f @ %s'):format(cmin.corr, bar_beat(cmin.pos)) end
  if sm_n > 0 then
    local sm = 10 * log10(sm_e / sm_n)
    parts[#parts + 1] = sm < -60 and 'side below -60 dB vs mid (mono)' or ('side %.1f dB vs mid'):format(sm)
  end
  L[#L + 1] = head .. ': ' .. table.concat(parts, ' · ')
  if band_n > 0 then
    local b = {}
    for k = 1, 8 do b[k] = BAND_NAMES[k] .. ' ' .. ('%.1f'):format(10 * log10(band_e[k] / band_n)) end
    L[#L + 1] = 'meter bands (mid, dB RMS, octave-wide band-pass): ' .. table.concat(b, ' · ')
  end
  -- per bar: max LUFS-M and true peak; long playbacks are grouped so the line stays short
  local bars, order = {}, {}
  for _, x in ipairs(f) do
    local k = bar_of(x.pos)
    local e = bars[k]
    if not e then e = { m = x.m, tp = x.tp }; bars[k] = e; order[#order + 1] = k
    else
      if x.m > e.m then e.m = x.m end
      if x.tp > e.tp then e.tp = x.tp end
    end
  end
  local step = math.max(1, math.ceil(#order / 24))
  local cells = {}
  for i = 1, #order, step do
    local m, tp = -200, -200
    for j = i, math.min(#order, i + step - 1) do
      local e = bars[order[j]]
      if e.m > m then m = e.m end
      if e.tp > tp then tp = e.tp end
    end
    local name = step == 1 and tostring(order[i]) or (order[i] .. '-' .. order[math.min(#order, i + step - 1)])
    cells[#cells + 1] = ('%s %.1f/%.1f'):format(name, m, tp)
  end
  L[#L + 1] = 'meter per bar (max LUFS-M / max dBTP): ' .. table.concat(cells, ' · ')
end

---------------------------------------------------------------- rack
RK = { groups = {}, at = -math.huge, focus = nil, stats = {} }
local function track_label(i, tr)
  if i == -1 then return 'master' end
  local _, nm = reaper.GetTrackName(tr)
  return ('#%d %s'):format(i + 1, nm)
end
local function fx_by_guid(tr, guid)
  for k = 0, reaper.TrackFX_GetCount(tr) - 1 do
    if reaper.TrackFX_GetFXGUID(tr, k) == guid then return k end
  end
end
local function active_of(g)
  for _, v in ipairs(g.vars) do
    if v.lane then
      if reaper.GetMediaTrackInfo_Value(v.tr, 'C_LANEPLAYS:' .. v.lane) == 1 then return v.n end
    elseif v.fx then
      if reaper.TrackFX_GetEnabled(v.tr, v.fx) then return v.n end
    elseif reaper.GetMediaTrackInfo_Value(v.tr, 'B_MUTE') == 0 then return v.n end
  end
end
function RK.scan()
  RK.at = now()
  local by, order = {}, {}
  local function add(name, v)
    local g = by[name]
    if not g then g = { name = name, vars = {}, count = 0 }; by[name] = g; order[#order + 1] = g end
    g.vars[#g.vars + 1] = v
  end
  for i = -1, reaper.CountTracks(0) - 1 do
    local tr = i == -1 and reaper.GetMasterTrack(0) or reaper.GetTrack(0, i)
    local ok, v = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:hibiki_var', '', false)
    if ok and v ~= '' then
      local g, n = v:match('^(.-)/(%d+)$')
      if g and g ~= '' then
        local _, tn = reaper.GetTrackName(tr)
        add(g, { n = tonumber(n), tr = tr, label = track_label(i, tr), short = tn })
      end
    end
    -- fixed lanes (REAPER 7): one variant per lane of one track, the playing lane is the one you hear and see
    local okl, lg = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:hibiki_lanes', '', false)
    if okl and lg ~= '' and reaper.GetMediaTrackInfo_Value(tr, 'I_FREEMODE') == 2 then
      for k = 0, math.min(9, math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_NUMFIXEDLANES'))) - 1 do
        local _, ln = reaper.GetSetMediaTrackInfo_String(tr, 'P_LANENAME:' .. k, '', false)
        add(lg, { n = k + 1, tr = tr, lane = k, short = ln ~= '' and ln or nil,
          label = track_label(i, tr) .. ': ' .. (ln ~= '' and ln or ('lane ' .. (k + 1))) })
      end
    end
    local ok2, fv = reaper.GetSetMediaTrackInfo_String(tr, 'P_EXT:hibiki_fxvar', '', false)
    if ok2 and fv ~= '' then
      for line in fv:gmatch('[^\n]+') do
        local g, n, guid = line:match('^(.-)/(%d+)\t(%b{})')
        local fx = g and fx_by_guid(tr, guid)
        if fx then
          local _, fxn = reaper.TrackFX_GetFXName(tr, fx, '')
          -- "Pizz level -6 dB" in group "Pizz level" reads "-6 dB" next to the buttons
          local short = fxn:gsub('^%a+: ', ''):gsub(' %(.-%)$', '')
          if short:sub(1, #g + 1):lower() == (g .. ' '):lower() then short = short:sub(#g + 2) end
          add(g, { n = tonumber(n), tr = tr, fx = fx, guid = guid, label = track_label(i, tr) .. ': ' .. fxn, short = short })
        end
      end
    end
  end
  local groups = {}
  for _, g in ipairs(order) do
    local nums, distinct = {}, 0 -- two tracks tagged with the same number are one variant
    for _, v in ipairs(g.vars) do if not nums[v.n] then nums[v.n] = true; distinct = distinct + 1 end end
    g.count = distinct
    if distinct >= 2 then
      table.sort(g.vars, function(a, b) return a.n < b.n end)
      g.active = active_of(g)
      groups[#groups + 1] = g
    end
  end
  RK.groups = groups
end
function RK.switch(g, n)
  for _, v in ipairs(g.vars) do -- a track deleted since the last scan: rescan next frame instead of touching it
    if reaper.ValidatePtr2(0, v.tr, 'MediaTrack*') == false then RK.at = -math.huge; return end
  end
  reaper.PreventUIRefresh(1)
  for _, v in ipairs(g.vars) do
    local on = v.n == n
    if v.lane then
      reaper.SetMediaTrackInfo_Value(v.tr, 'C_LANEPLAYS:' .. v.lane, on and 1 or 0) -- no undo point (REAPER 7.79)
    elseif v.fx then
      -- TrackFX_SetEnabled leaves an "FX bypass toggle" undo point (on top of the reply's); the
      -- :bypass parameter switches the same thing without one (checked on REAPER 7.79), like B_MUTE
      local pb = reaper.TrackFX_GetParamFromIdent and reaper.TrackFX_GetParamFromIdent(v.tr, v.fx, ':bypass') or -1
      if pb >= 0 then reaper.TrackFX_SetParamNormalized(v.tr, v.fx, pb, on and 0 or 1)
      else reaper.TrackFX_SetEnabled(v.tr, v.fx, on) end
    else reaper.SetMediaTrackInfo_Value(v.tr, 'B_MUTE', on and 0 or 1) end
  end
  reaper.PreventUIRefresh(-1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  g.active = n
  RK.focus = g.name
  -- a click is a listen: stopped, it plays the time selection on a loop (the agent sets it to the section where the
  -- variants differ), or from the edit cursor; playing, the switch happens in place for a seamless A/B
  if reaper.GetPlayState() & 1 == 0 then
    local s0, e0 = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    if e0 > s0 then
      reaper.GetSet_LoopTimeRange2(0, true, true, s0, e0, false) -- the loop points follow the time selection
      reaper.GetSetRepeat(1)
      reaper.SetEditCurPos(s0, false, false)
    end
    reaper.Main_OnCommand(1007, 0) -- Transport: Play
  end
end
-- Keep n: the other variants go (tracks deleted / FX removed), the tags are cleared; one undo step.
-- A variant can span several tracks / FX tagged with the same number (a layered stack): all of them stay.
function RK.keep(g, n)
  for _, v in ipairs(g.vars) do
    if reaper.ValidatePtr2(0, v.tr, 'MediaTrack*') == false then RK.at = -math.huge; return end
  end
  reaper.Undo_BeginBlock2(0)
  reaper.PreventUIRefresh(1)
  local kept, fx_drop, tr_drop = {}, {}, {}
  for _, v in ipairs(g.vars) do
    if v.n == n then kept[#kept + 1] = v
    elseif v.lane then -- the lanes go together below
    elseif v.fx then fx_drop[#fx_drop + 1] = v
    else tr_drop[#tr_drop + 1] = v end
  end
  for _, k in ipairs(kept) do
    if k.lane then -- the kept lane's items stay, the track goes back to one lane
      for j = reaper.CountTrackMediaItems(k.tr) - 1, 0, -1 do
        local it = reaper.GetTrackMediaItem(k.tr, j)
        if reaper.GetMediaItemInfo_Value(it, 'I_FIXEDLANE') ~= k.lane then reaper.DeleteTrackMediaItem(k.tr, it) end
      end
      reaper.SetMediaTrackInfo_Value(k.tr, 'I_FREEMODE', 0)
      reaper.GetSetMediaTrackInfo_String(k.tr, 'P_EXT:hibiki_lanes', '', true)
    end
  end
  table.sort(fx_drop, function(a, b) return a.fx > b.fx end) -- highest index first: the others keep their place
  for _, v in ipairs(fx_drop) do reaper.TrackFX_Delete(v.tr, v.fx) end
  for _, v in ipairs(tr_drop) do reaper.DeleteTrack(v.tr) end
  for _, k in ipairs(kept) do
    if k.fx then
      local _, lines = reaper.GetSetMediaTrackInfo_String(k.tr, 'P_EXT:hibiki_fxvar', '', false)
      local rest = {}
      for line in (lines or ''):gmatch('[^\n]+') do
        if line:match('^(.-)/%d+\t') ~= g.name then rest[#rest + 1] = line end
      end
      reaper.GetSetMediaTrackInfo_String(k.tr, 'P_EXT:hibiki_fxvar', table.concat(rest, '\n'), true)
      for j = 0, reaper.TrackFX_GetCount(k.tr) - 1 do -- the kept FX by GUID: deleting others moved its index
        if reaper.TrackFX_GetFXGUID(k.tr, j) == k.guid then reaper.TrackFX_SetEnabled(k.tr, j, true) end
      end
    elseif not k.lane then
      reaper.GetSetMediaTrackInfo_String(k.tr, 'P_EXT:hibiki_var', '', true)
      reaper.SetMediaTrackInfo_Value(k.tr, 'B_MUTE', 0)
    end
  end
  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock2(0, ('Hibiki: keep %s %d'):format(g.name, n), -1)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  M.note(('Kept %s %d · Cmd+Z undoes'):format(g.name, n))
  RK.at = -math.huge
end

-- what each variant measured on the master while it was the one playing
function RK.on_frame(fr)
  if fr.m <= -60 then return end
  for _, g in ipairs(RK.groups) do
    if g.active then
      local k = g.name .. '/' .. g.active
      local st = RK.stats[k] or { e = 0, n = 0 }
      st.e, st.n = st.e + energy(fr.m), st.n + 1
      RK.stats[k] = st
    end
  end
end
local function heard(g, n)
  local st = RK.stats[g.name .. '/' .. n]
  if not st or st.n < 10 then return nil end
  return lufs(st.e / st.n), st.n / 10
end

local MAX_ROWS = 3
function M.rack_height()
  local n = math.min(#RK.groups, MAX_ROWS)
  return n > 0 and n * ImGui.GetFrameHeightWithSpacing(ctx) or 0
end
function M.rack_row()
  if #RK.groups == 0 then return end
  -- keys 1-9 switch one group: the one last touched among the rows shown, else the first
  local kg = RK.groups[1]
  for gi, x in ipairs(RK.groups) do if gi <= MAX_ROWS and x.name == RK.focus then kg = x end end
  local focused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
  local mods = ImGui.IsKeyDown(ctx, ImGui.Mod_Ctrl) or ImGui.IsKeyDown(ctx, ImGui.Mod_Super)
    or ImGui.IsKeyDown(ctx, ImGui.Mod_Shift) or ImGui.IsKeyDown(ctx, ImGui.Mod_Alt)
  -- not while a field takes typing (composer, a card's Other…/secret field), not with a modifier held (Cmd+1)
  if focused and not S.comp_active and not ImGui.IsAnyItemActive(ctx) and not mods then
    for k = 1, 9 do
      if ImGui.IsKeyPressed(ctx, ImGui.Key_1 + k - 1, false) or ImGui.IsKeyPressed(ctx, ImGui.Key_Keypad1 + k - 1, false) then
        for _, v in ipairs(kg.vars) do if v.n == k then RK.switch(kg, k); break end end
      end
    end
  end
  local names, lw = {}, 0 -- one label column: every row's buttons start at the same x
  for gi, g in ipairs(RK.groups) do
    if gi > MAX_ROWS then break end
    names[gi] = P.truncate(g.name, 110)
    lw = math.max(lw, (ImGui.CalcTextSize(ctx, names[gi])))
  end
  local dim = (C.strip_text & 0xFFFFFF00) | 0x99
  for gi, g in ipairs(RK.groups) do
    if gi > MAX_ROWS then break end
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.TextColored(ctx, (g == kg or #RK.groups == 1) and C.strip_text or dim, names[gi]) -- full strength = keys 1-9
    if ImGui.IsItemHovered(ctx) then
      P.show_tip(g.name .. ' · ' .. plural(g.count, 'variant') .. (g == kg and ' · keys 1-9' or '')
        .. (#RK.groups > MAX_ROWS and ('\n+' .. (#RK.groups - MAX_ROWS) .. ' groups not shown') or ''))
    end
    local gap, last = lw - (ImGui.CalcTextSize(ctx, names[gi])) + 8, nil
    for vi, v in ipairs(g.vars) do
      if v.n ~= last then -- one button per number (vars are sorted by n)
        last = v.n
        ImGui.SameLine(ctx, 0, gap)
        gap = 4
        if ImGui.GetContentRegionAvail(ctx) < ImGui.CalcTextSize(ctx, tostring(v.n)) + 30 + 80 then -- this button + Keep
          local rest, seen = 0, {}
          for j = vi, #g.vars do if not seen[g.vars[j].n] then seen[g.vars[j].n] = true; rest = rest + 1 end end
          ImGui.AlignTextToFramePadding(ctx)
          ImGui.TextColored(ctx, C.strip_text, '+' .. rest)
          break
        end
        if P.led_toggle('rk' .. gi .. '_' .. v.n, tostring(v.n), g.active == v.n) then RK.switch(g, v.n) end
        if ImGui.IsItemHovered(ctx) then
          local l, secs = heard(g, v.n)
          P.show_tip(v.label .. (l and ('\n%.1f LUFS avg · %.0f s heard'):format(l, secs) or ''))
        end
      end
    end
    local keep
    for _, x in ipairs(g.vars) do if x.n == g.active then keep = x; break end end
    if keep and keep.short and keep.short ~= '' then -- what is playing, so a click shows on screen, not only in the sound
      ImGui.SameLine(ctx, 0, 8)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.TextColored(ctx, C.value, P.truncate(keep.short, 140))
    end
    ImGui.SameLine(ctx, 0, 8)
    if P.chip('rkkeep' .. gi, keep and ('Keep ' .. keep.n) or 'Keep', C.muted, false, not keep) then RK.keep(g, keep.n) end
    if ImGui.IsItemHovered(ctx) then
      P.show_tip(keep and (keep.label .. '\nremoves ' .. plural(g.count - 1, 'other variant') .. ' · one undo step')
        or 'No variant playing')
    end
  end
end

---------------------------------------------------------------- ears
local E = { busy = false, n = 0, pend = {} }
local MAX_EARS = 30
local function ears_range()
  local s, e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if e > s then return s, e, 'time selection' end
  local lo, hi
  for i = 0, reaper.CountTracks(0) - 1 do
    local _, rz = reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(0, i), 'P_RAZOREDITS', '', false)
    for sa, sb in (rz or ''):gmatch('(%S+) (%S+) %b""') do
      local a, b = tonumber(sa), tonumber(sb)
      if a and b and b > a then lo, hi = math.min(lo or a, a), math.max(hi or b, b) end
    end
  end
  if lo then return lo, hi, 'razor area' end
end

local NUM_KEYS = { 'RENDER_BOUNDSFLAG', 'RENDER_STARTPOS', 'RENDER_ENDPOS', 'RENDER_SETTINGS', 'RENDER_SRATE',
  'RENDER_CHANNELS', 'RENDER_ADDTOPROJ', 'RENDER_NORMALIZE', 'RENDER_TAILFLAG' }
local STR_KEYS = { 'RENDER_FILE', 'RENDER_PATTERN', 'RENDER_FORMAT' }
local WAV24 = 'ZXZhdxgAAQ==' -- "evaw", 24 bit: REAPER's own default WAV sink config

local function render(s, e, dir, name)
  local saved = { n = {}, s = {} }
  for _, k in ipairs(NUM_KEYS) do saved.n[k] = reaper.GetSetProjectInfo(0, k, 0, false) end
  for _, k in ipairs(STR_KEYS) do saved.s[k] = select(2, reaper.GetSetProjectInfo_String(0, k, '', false)) end
  local wav
  local ok, err = pcall(function()
    reaper.GetSetProjectInfo_String(0, 'RENDER_FILE', dir, true)
    reaper.GetSetProjectInfo_String(0, 'RENDER_PATTERN', name, true)
    reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT', WAV24, true)
    local set = { RENDER_BOUNDSFLAG = 0, RENDER_STARTPOS = s, RENDER_ENDPOS = e, RENDER_SETTINGS = 0, RENDER_SRATE = 48000,
      RENDER_CHANNELS = 2, RENDER_ADDTOPROJ = 0, RENDER_NORMALIZE = 0, RENDER_TAILFLAG = 0 }
    for k, v in pairs(set) do reaper.GetSetProjectInfo(0, k, v, true) end
    local _, targets = reaper.GetSetProjectInfo_String(0, 'RENDER_TARGETS', '', false)
    wav = (targets or ''):match('[^;]+')
    if not wav then error('no render target', 0) end -- level 0: no "studio.lua:475:" prefix in the hint
    if exists(wav) then error(name .. '.wav already exists', 0) end -- REAPER's overwrite prompt would block the bridge
    reaper.Main_OnCommand(40101, 0) -- media goes offline while REAPER is in the background; a render drops it
    reaper.Main_OnCommand(42230, 0)
  end)
  for k, v in pairs(saved.n) do reaper.GetSetProjectInfo(0, k, v, true) end
  for k, v in pairs(saved.s) do reaper.GetSetProjectInfo_String(0, k, v, true) end
  if not ok then return nil, tostring(err) end
  if not exists(wav) then return nil, 'the render wrote nothing' end
  return wav
end

local function measure(wav)
  local m = {}
  if not (reaper.PCM_Source_CreateFromFile and reaper.CalculateNormalization) then return m end
  local src = reaper.PCM_Source_CreateFromFile(wav)
  if not src then return m end
  for key, mode in pairs({ lufs_i = 0, peak = 2, tp = 3, lufs_m_max = 4, lufs_s_max = 5 }) do
    local g = reaper.CalculateNormalization(src, mode, 0, 0, 0)
    if type(g) == 'number' and g > 0 and g < 1e7 then m[key] = -20 * log10(g) end
  end
  reaper.PCM_Source_Destroy(src)
  return m
end

function E.run(s, e, what)
  local cut = e - s > MAX_EARS
  if cut then e = s + MAX_EARS end
  E.n = E.n + 1
  local sep = P.WIN and '\\' or '/'
  local dir = P.DIR .. 'ears'
  reaper.RecursiveCreateDirectory(dir, 0)
  local name = ('ears-%s-%d'):format(os.date('%H%M%S'), E.n)
  local label = ('bars %s-%s'):format(bar_beat(s), bar_beat(e))
  local wav, err = render(s, e, dir, name)
  if not wav then M.note('Ears: ' .. err); return end
  local m = measure(wav)
  E.busy, E.at, E.wav, E.label = true, now(), wav, label
  local args = { 'ears', P.q(wav), '--json', '--label', P.q(label) }
  for k, flag in pairs({ lufs_i = '--lufs-i', lufs_s_max = '--lufs-s-max', lufs_m_max = '--lufs-m-max', tp = '--tp', peak = '--peak' }) do
    if m[k] then args[#args + 1] = flag .. (' %.2f'):format(m[k]) end
  end
  local function nums()
    local p = {}
    if m.lufs_i then p[#p + 1] = ('LUFS-I %.1f'):format(m.lufs_i) end
    if m.lufs_s_max then p[#p + 1] = ('LUFS-S max %.1f'):format(m.lufs_s_max) end
    if m.tp then p[#p + 1] = ('true peak %.1f dBTP'):format(m.tp) end
    return table.concat(p, ' · ')
  end
  local base = ('ears: %s (%s%s, %.1f s), rendered from the master: %s'):format(label, what,
    cut and (', first ' .. MAX_EARS .. ' s') or '', e - s, nums())
  E.base = base -- M.tick's timeout still sends REAPER's own measurements
  P.cli('ears', table.concat(args, ' '), function(code, out)
    if not E.busy or E.wav ~= wav then return end -- timed out earlier (M.tick): the WAV is already attached
    E.busy = false
    local r = P.decode(out)
    local group = 'Ears ' .. label
    if code == 0 and type(r) == 'table' and r.ok == true and type(r.png) == 'string' then
      P.add_file(r.png, group)
      P.add_file(r.md, group)
      P.add_file(wav, group)
      local peaks = {}
      for _, p in ipairs(type(r.peaks_over_tilt) == 'table' and r.peaks_over_tilt or {}) do
        peaks[#peaks + 1] = tostring(p.band) .. ' +' .. tostring(p.db)
      end
      E.pend[#E.pend + 1] = { group = group, text = base .. ('; tilt %s dB/oct; over the tilt: %s; spectrum, stereo and '
        .. 'levels in the attached .md/.png'):format(tostring(r.tilt_db_per_octave), #peaks > 0 and table.concat(peaks, ', ') or 'none') }
      M.note('Ears: ' .. label .. ' attached')
    else
      P.add_file(wav, group)
      E.pend[#E.pend + 1] = { group = group, text = base .. '; the WAV is attached (no spectrum: this Hibiki has no `hibiki ears` yet)' }
      M.note('Ears: ' .. label .. ' attached as audio')
    end
  end)
end

function M.ears_chip()
  local s, e, what = ears_range()
  local off = E.busy or not s
  local clicked = P.chip('ears', E.busy and 'Ears…' or 'Ears', C.muted, false, off)
  if ImGui.IsItemHovered(ctx) then
    P.show_tip(E.busy and ('Measuring ' .. (E.label or '') .. '…')
      or not s and 'No time selection or razor area'
      or ('%s · bars %s-%s · %.1f s · master%s'):format((what:gsub('^%l', string.upper)), bar_beat(s), bar_beat(e), e - s,
        e - s > MAX_EARS and (' · first ' .. MAX_EARS .. ' s') or ''))
  end
  if clicked then E.run(s, e, what) end
end

---------------------------------------------------------------- rules (/remember)
local BR = { info = nil, at = -math.huge }
function M.command(text)
  if text:match('^/remember%s*$') then M.note('/remember <rule>'); return true end
  local rule = text:match('^/remember%s+(.+)$')
  if not rule then return false end
  P.http_url('POST', P.gateway .. '/api/hibiki/brain', '{"add":' .. P.jstr(rule) .. '}', function(code, body)
    local r = P.decode(body)
    if code == 200 and type(r) == 'table' then
      M.note(r.added == false and 'Already in agent rules' or ('Saved to agent rules (' .. (tonumber(r.count) or 0) .. ')'))
      BR.at = -math.huge
    else
      if S.input == '' then S.input = text end -- hand the rule back, like a failed send
      M.note(code == 0 and 'Rule not saved: gateway not answering'
        or (type(r) == 'table' and type(r.error) == 'string' and ('Rule not saved: ' .. r.error))
        or ('Rule not saved: gateway answered ' .. tostring(code)))
    end
  end)
  return true
end
-- "10 defaults (1 off) · 3 yours"; a gateway without shipped defaults (before 0.6) only has the count
function M.rules_line(info)
  local yours = (tonumber(info.count) or 0) .. ' yours'
  local n = tonumber(info.defaults)
  if not n then return yours end
  local off = type(info.off) == 'table' and #info.off or 0
  return n .. ' defaults' .. (off > 0 and (' (' .. off .. ' off)') or '') .. ' · ' .. yours
end
local function brain_info()
  if now() - BR.at < 10 then return end
  BR.at = now()
  P.http_url('GET', P.gateway .. '/api/hibiki/brain', nil, function(code, body)
    local r = P.decode(body)
    BR.info = code == 200 and type(r) == 'table' and r or false
  end)
end
local function brain_edit()
  P.http_url('POST', P.gateway .. '/api/hibiki/brain', '{"ensure":true}', function(code, body)
    local r = P.decode(body)
    if code ~= 200 or type(r) ~= 'table' or type(r.path) ~= 'string' then BR.info, BR.at = false, now(); return end -- the Agent rules row says it, in the window where Edit was clicked
    local files = { r.path } -- rules.md; a gateway from 0.6 also has the user's defaults.md
    if type(r.defaults_path) == 'string' then table.insert(files, 1, r.defaults_path) end
    if P.WIN then
      for _, f in ipairs(files) do P.win_bg('start "" notepad ' .. P.q(f)) end
    else
      local qs = {}
      for _, f in ipairs(files) do qs[#qs + 1] = P.q(f) end
      P.sh('/usr/bin/open -t ' .. table.concat(qs, ' ') .. ' >/dev/null 2>&1 &')
    end
    BR.at = -math.huge
  end)
end
M.rules_edit = brain_edit

---------------------------------------------------------------- saved versions (survive a REAPER restart)
-- After a reply that changed the project, a copy of the project as it is (saved or not) goes to
-- <project folder>/.hibiki/history/<name>/<stamp>.RPP(.gz) with a line in index.jsonl. Main_SaveProjectEx to another
-- path keeps the open project's path and dirty state (checked on REAPER 7.79). No media is copied: ~40 KB a version.
local SV = { done = {}, cache = nil, cache_key = nil }
local SEP = P.WIN and '\\' or '/'
local MAX_SNAPS = 200
local function project_where()
  local _, path = reaper.EnumProjects(-1, '')
  if not path or path == '' then return nil end
  local dir, file = path:match('^(.*)[/\\]([^/\\]+)$')
  if not dir then return nil end
  local name = file:gsub('%.[Rr][Pp][Pp]$', '')
  return dir, name, dir .. SEP .. '.hibiki' .. SEP .. 'history' .. SEP .. name
end

-- one saved version: the project as it is now (saved or not), with a title and the change list for the tooltip
function SV.save(title, lines, turn)
  local dir, name, hd = project_where()
  if not dir then return nil end
  reaper.RecursiveCreateDirectory(hd, 0)
  local stamp = os.date('%Y%m%d-%H%M%S')
  local file = hd .. SEP .. stamp .. '.RPP'
  if exists(file) or exists(file .. '.gz') then return nil end -- one version a second
  reaper.Main_SaveProjectEx(0, file, 0)
  if not exists(file) then return nil end
  local L = {}
  for i, l in ipairs(lines or {}) do if i <= 12 then L[#L + 1] = P.jstr(readable(l)) end end
  local f = io.open(hd .. SEP .. 'index.jsonl', 'ab')
  if f then
    f:write('{"file":', P.jstr(stamp .. '.RPP' .. (P.WIN and '' or '.gz')), ',"at":', tostring(os.time()),
      ',"turn":', P.jstr(turn or ''), ',"n":', tostring(#(lines or {})), ',"what":', P.jstr(title or ''),
      ',"lines":[', table.concat(L, ','), ']}\n')
    f:close()
  end
  if not P.WIN then -- compress, and keep the newest MAX_SNAPS, in the background
    P.sh('( /usr/bin/gzip -9 -f ' .. P.q(file) .. '; cd ' .. P.q(hd) .. ' && /bin/ls -t | /usr/bin/grep "\\.RPP\\.gz$" | '
      .. '/usr/bin/tail -n +' .. (MAX_SNAPS + 1) .. ' | while read f; do /bin/rm -f "$f"; done ) >/dev/null 2>&1 &')
  else -- no gzip there: keep the newest MAX_SNAPS uncompressed (stamped names sort by time)
    local names, i = {}, 0
    while true do
      local f = reaper.EnumerateFiles(hd, i)
      if not f then break end
      if f:match('^%d+%-%d+%.RPP$') then names[#names + 1] = f end
      i = i + 1
    end
    table.sort(names)
    for k = 1, #names - MAX_SNAPS do os.remove(hd .. SEP .. names[k]) end
  end
  SV.cache_key = nil
  SV.saved_at = reaper.GetProjectStateChangeCount(0) -- "Current" is in the history until the project changes again
  return stamp
end

-- after a reply that changed the project: titled with the reply's first sentence
function SV.snap(r)
  SV.done[r.id] = true
  local lines = type(r.lines) == 'table' and r.lines or {}
  local title = R.summary[r.id]
  if not title then
    for _, l in ipairs(lines) do if not l:match('^script: ') then title = l; break end end
  end
  SV.save(title or 'Agent changes', lines, r.id)
end

-- newest first, only versions whose file is still there
function SV.list()
  local _, _, hd = project_where()
  if not hd then return {} end
  if SV.cache_key == hd and SV.cache then return SV.cache end
  local out = {}
  local f = io.open(hd .. SEP .. 'index.jsonl', 'rb')
  if f then
    for line in f:lines() do
      local e = P.decode(line)
      if type(e) == 'table' and type(e.file) == 'string' and e.file:match('^[%w._-]+$')
          and (exists(hd .. SEP .. e.file) or exists(hd .. SEP .. e.file:gsub('%.gz$', ''))) then
        table.insert(out, 1, e)
      end
    end
    f:close()
  end
  SV.cache, SV.cache_key = out, hd
  return out
end

-- Go to: this tab becomes that version. The current state is saved as a version first, so nothing is lost and
-- Go to can come back. The version opens from its own folder (relative media paths resolve) and is saved over the
-- project file from there, so REAPER rewrites the paths for the project folder.
function SV.go(e)
  local dir, name, hd = project_where()
  local _, path = reaper.EnumProjects(-1, '')
  if not dir then return end
  local src = hd .. SEP .. e.file
  local rpp = src:gsub('%.gz$', '')
  local unpacked = false
  if not exists(rpp) then
    if P.WIN or not exists(src) then M.note('That version is gone'); return end
    rpp = hd .. SEP .. 'goto-' .. e.file:gsub('%.gz$', '')
    P.sh('/usr/bin/gunzip -c ' .. P.q(src) .. ' > ' .. P.q(rpp))
    unpacked = true
  end
  if not exists(rpp) then M.note('Could not unpack that version'); return end
  local when = os.date('%H:%M:%S', tonumber(e.at) or os.time())
  if reaper.GetProjectStateChangeCount(0) ~= SV.saved_at or reaper.IsProjectDirty(0) ~= 0 then
    SV.save('Before going to ' .. when, {}, 'goto')
  end
  reaper.Main_openProject('noprompt:' .. rpp)
  reaper.Main_SaveProjectEx(0, path, 0)
  reaper.Main_openProject('noprompt:' .. path)
  if unpacked then os.remove(rpp) end
  SV.saved_at = reaper.GetProjectStateChangeCount(0)
  SV.cache_key = nil
  M.note('Went to the ' .. when .. ' version')
end

local function snap_tick()
  if S.active then return end
  local r = R.list[#R.list]
  if type(r) ~= 'table' or type(r.id) ~= 'string' or SV.done[r.id] then return end
  if r.proj ~= select(2, reaper.EnumProjects(-1, '')) or (tonumber(r.n) or 0) == 0 then return end
  -- a panel reply right after it ends; changes from outside the panel once they have settled for 10 s
  if r.id == R.ended or (r.id:match('^mcp%-') and os.time() - (tonumber(r.at) or 0) >= 10) then SV.snap(r) end
end
-- receipts already there when the panel starts were snapshotted by an earlier run (or predate this feature)
read_receipts()
for _, r in ipairs(R.list) do if type(r) == 'table' and type(r.id) == 'string' then SV.done[r.id] = true end end

---------------------------------------------------------------- version history rows
-- the newest 10 saved versions of this project
local function version_rows()
  local rows = {}
  for i, e in ipairs(SV.list()) do
    if i > 10 then break end
    local what = tostring(e.what or '')
    if what == '' or what:match('^script: ') or what == 'Ran a script' then what = 'Agent changes' end
    rows[#rows + 1] = { at = tonumber(e.at) or 0, what = what, lines = type(e.lines) == 'table' and e.lines or {}, e = e }
  end
  return rows
end

---------------------------------------------------------------- panel hooks
function M.tick(t)
  if reaper.GetExtState(EXT, 'open') == 'ears' then -- like open=settings / recover: another script can press Ears
    reaper.DeleteExtState(EXT, 'open', false)
    local s, e, what = ears_range()
    if E.busy then M.note('Ears: still measuring')
    elseif s then E.run(s, e, what)
    else M.note('Ears: no time selection or razor area') end
  end
  read_receipts()
  if E.busy and now() - E.at > 90 then -- `hibiki ears` never answered (or Recover dropped the job): the WAV alone
    E.busy = false
    P.add_file(E.wav, 'Ears ' .. E.label)
    if E.base then E.pend[#E.pend + 1] = { group = 'Ears ' .. E.label, text = E.base .. '; the WAV is attached (no spectrum)' } end
    M.note('Ears: ' .. E.label .. ' attached as audio')
  end
  snap_tick()
  MT.tick()
  local proj = reaper.EnumProjects(-1, '')
  if proj ~= RK.proj then -- another project tab: nothing from the last one may stay clickable
    RK.proj = proj
    RK.scan(); RK.stats, RK.focus = {}, nil
  elseif t - RK.at > 1 then RK.scan() end
end

-- the Ears summaries waiting for the next message (Hibiki.lua sends them alone when Context is off): only those whose
-- attachment chip is still there; removing the chip drops its numbers too
function M.take_ears()
  local have, out = {}, {}
  for _, f in ipairs(S.files) do if f.group then have[f.group] = true end end
  for _, x in ipairs(E.pend) do if have[x.group] then out[#out + 1] = x.text end end
  E.pend = {}
  return #out > 0 and table.concat(out, '\n') or nil
end

-- extra lines for the REAPER context block (sent with each message)
function M.context_lines(L)
  local ok = pcall(MT.lines, L)
  if not ok then L[#L + 1] = 'meter: (could not summarise the last playback)' end
  for _, g in ipairs(RK.groups) do
    local cur
    for _, v in ipairs(g.vars) do if v.n == g.active then cur = v end end
    L[#L + 1] = ('audition rack "%s": %d variants, playing %s'):format(g.name, g.count,
      cur and ('#' .. cur.n .. ' (' .. cur.label .. ')') or 'none')
  end
  local p = M.take_ears()
  if p then L[#L + 1] = p end
end

local function settings_rows(A, w, x0)
  local function row() ImGui.SetCursorScreenPos(ctx, x0, select(2, ImGui.GetCursorScreenPos(ctx))) end
  local function right_btn(id, text, off, on)
    local bw = ImGui.CalcTextSize(ctx, text) + 16
    ImGui.SameLine(ctx)
    ImGui.SetCursorScreenPos(ctx, x0 + w - bw, select(2, ImGui.GetCursorScreenPos(ctx)))
    return A.light_btn(id, text, bw, on, off)
  end
  local function right_note(text) -- dim status at the right end of the row just drawn
    local _, y1 = ImGui.GetItemRectMin(ctx)
    local _, y2 = ImGui.GetItemRectMax(ctx)
    local tw = ImGui.CalcTextSize(ctx, text)
    ImGui.DrawList_AddText(ImGui.GetWindowDrawList(ctx), x0 + w - tw, (y1 + y2 - ImGui.GetTextLineHeight(ctx)) / 2, A.dim, text)
  end
  return row, right_btn, right_note
end

-- Agent settings, right column under the context switch: what else the agent is told
function M.settings_context(A)
  brain_info()
  A.box('agentctx', A.COL, function(w, x0)
    local row, right_btn, right_note = settings_rows(A, w, x0)
    if A.checkbox('meter', 'Measure playback', MT.on, w) then
      MT.on = not MT.on
      reaper.SetExtState(EXT, 'meter', MT.on and '1' or '0', true)
      MT.ensure()
    end
    if ImGui.IsItemHovered(ctx) then P.show_tip('Hibiki_Meter.jsfx · master monitoring FX (not rendered)') end
    if MT.on then right_note(MT.running() and 'running' or MT.status) end
    row()
    ImGui.AlignTextToFramePadding(ctx)
    local info = BR.info
    ImGui.Text(ctx, info and ('Agent rules: ' .. M.rules_line(info))
      or (info == false and 'Agent rules: gateway not answering' or 'Agent rules'))
    if ImGui.IsItemHovered(ctx) and info and info.path then P.show_tip(info.path) end
    if right_btn('brainedit', 'Edit', info == false) then brain_edit() end
  end)
end

-- Agent settings, left column: what agents changed, and the way back
function M.settings_changes(A)
  A.section('Version history', A.COL)
  A.box('changes', A.COL, function(w, x0)
    local row, right_btn = settings_rows(A, w, x0)
    local _, _, hist = project_where()
    local today = os.date('%Y%m%d')
    local tcol = (ImGui.CalcTextSize(ctx, '00-00 00:00')) + 10 -- time column: 00:00:00 today, MM-DD HH:MM before
    -- Current: the project as it is now; saved into the history unless it already is
    local changed = SV.saved_at == nil or reaper.GetProjectStateChangeCount(0) ~= SV.saved_at
    -- the history is per project and this window stays open across tab switches: say whose it is
    local _, path = reaper.EnumProjects(-1, '')
    local _, pname = project_where()
    ImGui.TextColored(ctx, A.dim, P.truncate(pname or 'Untitled project', w))
    if ImGui.IsItemHovered(ctx) and path ~= '' then P.show_tip(path) end
    row()
    ImGui.AlignTextToFramePadding(ctx)
    ImGui.Text(ctx, 'Current')
    ImGui.SameLine(ctx, 0, 0)
    ImGui.SetCursorScreenPos(ctx, x0 + tcol, select(2, ImGui.GetCursorScreenPos(ctx)))
    ImGui.TextColored(ctx, A.dim, not hist and 'project not saved' or (changed and 'not in the history' or 'in the history'))
    if right_btn('savever', 'Save version', not hist or not changed or S.active) then
      if SV.save('Saved by you', {}, 'you') then M.note('Saved this version') end
    end
    for i, x in ipairs(version_rows()) do
      row()
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.TextColored(ctx, A.dim, os.date(os.date('%Y%m%d', x.at) == today and '%H:%M:%S' or '%m-%d %H:%M', x.at))
      ImGui.SameLine(ctx, 0, 0)
      ImGui.SetCursorScreenPos(ctx, x0 + tcol, select(2, ImGui.GetCursorScreenPos(ctx)))
      local bw = ImGui.CalcTextSize(ctx, 'Go to') + 16
      local cx = ImGui.GetCursorScreenPos(ctx)
      ImGui.Text(ctx, P.truncate(x.what, x0 + w - bw - 8 - cx))
      if ImGui.IsItemHovered(ctx) then
        local L = { os.date('%Y-%m-%d %H:%M:%S', x.at) .. ' · ' .. x.what }
        for _, l in ipairs(x.lines) do L[#L + 1] = readable(l) end
        P.show_tip(table.concat(L, '\n'))
      end
      if right_btn('ver' .. i, 'Go to', S.active) then SV.go(x.e) end
      if ImGui.IsItemHovered(ctx) then P.show_tip('Current is saved as a version first') end
    end
    if hist and #version_rows() == 0 then
      row()
      ImGui.TextColored(ctx, A.dim, 'No versions yet')
    end
  end)
end

function M.exit() reaper.SetExtState(EXT, 'turn', '', false) end

if MT.on then pcall(MT.ensure) end
M._R, M._MT, M._RK, M._E, M._H, M._SV, M._rows = R, MT, RK, E, H, SV, version_rows -- headless tests
return M
end
