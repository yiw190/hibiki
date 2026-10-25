-- Hibiki context: the [REAPER context] block each message carries (project, cursor, markers, then every selection
-- kind with when it was set) and the selection pills. Hibiki.lua loads it next to itself and calls it once.
return function(P)
local function pos(t) return reaper.format_timestr_pos(t, '', 2) end
local NOTE = { 'C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B' }
local function note_name(p) return NOTE[p % 12 + 1] .. (p // 12 - 1) end
local function trnum(tr) return math.floor(reaper.GetMediaTrackInfo_Value(tr, 'IP_TRACKNUMBER')) end

local function cc_kind(chanmsg, m2, m3)
  if chanmsg == 0xB0 then return ('CC%d = %d'):format(m2, m3)
  elseif chanmsg == 0xE0 then return ('pitch bend = %d'):format(((m3 << 7) | m2) - 8192)
  elseif chanmsg == 0xC0 then return ('program %d'):format(m2)
  elseif chanmsg == 0xD0 then return ('channel pressure = %d'):format(m2)
  elseif chanmsg == 0xA0 then return ('poly aftertouch %s = %d'):format(note_name(m2), m3) end
  return ('0x%X %d %d'):format(chanmsg, m2, m3)
end

local function midi_ctx(proj, full)
  local ed = reaper.MIDIEditor_GetActive()
  if not ed then return nil end
  local take = reaper.MIDIEditor_GetTake(ed)
  if not take or not reaper.ValidatePtr2(proj, take, 'MediaItem_Take*') then return nil end
  local tr = reaper.GetMediaItemTake_Track(take)
  local _, tn = reaper.GetTrackName(tr)
  local _, total = reaper.MIDI_CountEvts(take)
  local sel, list = 0, {}
  local idx = reaper.MIDI_EnumSelNotes(take, -1)
  while idx ~= -1 do
    sel = sel + 1
    if full and #list < 64 then
      local _, _, _, sp, ep, ch, pitch, vel = reaper.MIDI_GetNote(take, idx)
      local t0 = reaper.MIDI_GetProjTimeFromPPQPos(take, sp)
      local t1 = reaper.MIDI_GetProjTimeFromPPQPos(take, ep)
      local len = reaper.TimeMap2_timeToQN(proj, t1) - reaper.TimeMap2_timeToQN(proj, t0)
      list[#list + 1] = ('  note %d: %s @ %s, %.3g qn, vel %d, ch %d'):format(idx, note_name(pitch), pos(t0), len, vel, ch + 1)
    end
    idx = reaper.MIDI_EnumSelNotes(take, idx)
  end
  local r = { track = ('#%d %s'):format(trnum(tr), tn), sel = sel, total = total, list = list }
  if full then
    local item = reaper.GetMediaItemTake_Item(take)
    r.item = pos(reaper.GetMediaItemInfo_Value(item, 'D_POSITION'))
    local _, tk = reaper.GetSetMediaItemTakeInfo_String(take, 'P_NAME', '', false)
    r.take = tk
  end
  if full then
    local _, _, nccs = reaper.MIDI_CountEvts(take)
    r.cc_total, r.cc_sel, r.cc_list = nccs, 0, {}
    local ci = reaper.MIDI_EnumSelCC(take, -1)
    while ci ~= -1 do
      r.cc_sel = r.cc_sel + 1
      if #r.cc_list < 64 then
        local _, _, _, ppq, chanmsg, chan, m2, m3 = reaper.MIDI_GetCC(take, ci)
        r.cc_list[#r.cc_list + 1] = ('  cc %d: %s @ %s, ch %d'):format(ci, cc_kind(chanmsg, m2, m3),
          pos(reaper.MIDI_GetProjTimeFromPPQPos(take, ppq)), chan + 1)
      end
      ci = reaper.MIDI_EnumSelCC(take, ci)
    end
  end
  return r
end

local function envelope_ctx(proj)
  local env = reaper.GetSelectedEnvelope(proj)
  if not env then return nil end
  local _, ename = reaper.GetEnvelopeName(env)
  local tr = reaper.Envelope_GetParentTrack(env)
  local owner = '?'
  if tr then
    local _, tn = reaper.GetTrackName(tr)
    owner = tr == reaper.GetMasterTrack(proj) and 'MASTER' or ('#%d %s'):format(trnum(tr), tn)
  end
  local n = reaper.CountEnvelopePoints(env)
  local sel, list = 0, {}
  for i = 0, n - 1 do
    local _, t, v, shape, _, selected = reaper.GetEnvelopePoint(env, i)
    if selected then
      sel = sel + 1
      if #list < 64 then
        list[#list + 1] = ('  point %d: %s @ %s, shape %d'):format(i, reaper.Envelope_FormatValue(env, v), pos(t), shape)
      end
    end
  end
  return { head = ('selected envelope: %s on %s — %d of %d points selected%s'):format(ename, owner, sel, n,
    sel > #list and (' (first ' .. #list .. ' listed)') or '') .. (sel > 0 and ':' or ''), list = list }
end

local function marker_ctx(proj, cur)
  local mk, rg = reaper.GetLastMarkerAndCurRegion(proj, cur)
  local r = {}
  if rg >= 0 then
    local _, _, p0, p1, name, num = reaper.EnumProjectMarkers3(proj, rg)
    r.region_name = name
    r.region = ('"%s" (region %d, %s–%s)'):format(name, num, pos(p0), pos(p1))
  end
  local around = {}
  if mk >= 0 then
    local _, _, p0, _, name, num = reaper.EnumProjectMarkers3(proj, mk)
    around[#around + 1] = ('last %d "%s" @ %s'):format(num, name, pos(p0))
  end
  local _, nm, nr = reaper.CountProjectMarkers(proj)
  for i = 0, (nm or 0) + (nr or 0) - 1 do
    local _, isr, p0, _, name, num = reaper.EnumProjectMarkers3(proj, i)
    if not isr and p0 > cur + 1e-9 then
      around[#around + 1] = ('next %d "%s" @ %s'):format(num, name, pos(p0))
      break
    end
  end
  if #around > 0 then r.markers = table.concat(around, ', ') end
  return r
end

---------------------------------------------------------------- what the user selected, and when
-- REAPER keeps every selection kind until the user changes it, so a track picked minutes ago still reads as
-- selected next to a time selection made a second ago; sample each kind and remember when it last changed
local SEL = { sig = {}, at = {}, t = 0 }
local SEL_KINDS = { 'razor', 'time', 'items', 'tracks', 'notes', 'env', 'fx', 'cursor' }
local SEL_LABEL = { razor = 'razor area', time = 'time selection', items = 'items', tracks = 'tracks',
  notes = 'MIDI notes', env = 'envelope', fx = 'FX window', cursor = 'edit cursor' }

local function sel_sigs(proj)
  local g = {}
  local s, e = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  g.time = e > s and (s .. ':' .. e) or ''
  local rz = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local _, v = reaper.GetSetMediaTrackInfo_String(reaper.GetTrack(proj, i), 'P_RAZOREDITS', '', false)
    if v and v ~= '' then rz[#rz + 1] = i .. '=' .. v end
  end
  g.razor = table.concat(rz, '|')
  local t = {}
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do t[#t + 1] = tostring(reaper.GetSelectedTrack(proj, i)) end
  g.tracks = table.concat(t, ',')
  local n = reaper.CountSelectedMediaItems(proj)
  local it = {}
  for i = 0, math.min(n, 64) - 1 do it[#it + 1] = tostring(reaper.GetSelectedMediaItem(proj, i)) end
  g.items = n > 0 and (n .. ':' .. table.concat(it, ',')) or ''
  local nt = {}
  local ed = reaper.MIDIEditor_GetActive()
  local take = ed and reaper.MIDIEditor_GetTake(ed)
  if take and reaper.ValidatePtr2(proj, take, 'MediaItem_Take*') then
    local idx = reaper.MIDI_EnumSelNotes(take, -1)
    while idx ~= -1 and #nt < 256 do nt[#nt + 1] = idx; idx = reaper.MIDI_EnumSelNotes(take, idx) end
    if #nt > 0 then table.insert(nt, 1, tostring(take)) end
  end
  g.notes = table.concat(nt, ',')
  local env = reaper.GetSelectedEnvelope(proj)
  g.env = env and tostring(env) or ''
  local rv, a, b, c = reaper.GetFocusedFX2()
  g.fx = (rv and rv ~= 0) and (a .. ':' .. b .. ':' .. c) or ''
  g.cursor = ('%.3f'):format(reaper.GetCursorPosition())
  return g
end

local function spos(t) return (pos(t):gsub('%.00$', '')) end


-- one pill per selection kind for the row above the input; rebuilt when a selection changes
-- tooltips carry data only: positions, lengths, names, chord markers
local function sel_pills(proj)
  local P = {}
  local function add(k, label, detail) P[#P + 1] = { k = k, label = label, detail = detail } end
  local function span(t0, t1)
    local num = reaper.TimeMap_GetTimeSigAtTime(proj, t0)
    local qn = reaper.TimeMap2_timeToQN(proj, t1) - reaper.TimeMap2_timeToQN(proj, t0)
    local bars = qn / (num or 4)
    return ('%s–%s  (%s bar%s)'):format(spos(t0), spos(t1),
      math.abs(bars - math.floor(bars + 0.5)) < 1e-6 and math.floor(bars + 0.5) or ('%.2f'):format(bars), bars == 1 and '' or 's')
  end
  local function chords(t0, t1)
    local out = {}
    local _, nm, nr = reaper.CountProjectMarkers(proj)
    for i = 0, (nm or 0) + (nr or 0) - 1 do
      local _, isr, p0, _, name, num = reaper.EnumProjectMarkers3(proj, i)
      if not isr and p0 >= t0 - 1e-9 and p0 < t1 - 1e-9 and #out < 12 then out[#out + 1] = spos(p0) .. ' ' .. name end
    end
    return #out > 0 and ('\n' .. table.concat(out, ' · ')) or ''
  end
  local function len_of(m)
    local p0 = reaper.GetMediaItemInfo_Value(m, 'D_POSITION')
    return p0, p0 + reaper.GetMediaItemInfo_Value(m, 'D_LENGTH')
  end
  local s, e = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  local rz, rt, lines = {}, {}, {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, v = reaper.GetSetMediaTrackInfo_String(tr, 'P_RAZOREDITS', '', false)
    if v and v ~= '' then
      local _, tn = reaper.GetTrackName(tr)
      rt[#rt + 1] = ('#%d %s'):format(i + 1, tn)
      for sa, sb in v:gmatch('(%S+) (%S+) "[^"]*"') do
        local a, b = tonumber(sa), tonumber(sb)
        rz.t0, rz.t1 = math.min(rz.t0 or a, a), math.max(rz.t1 or b, b)
        if #lines < 12 then lines[#lines + 1] = ('#%d %s   %s–%s'):format(i + 1, tn, spos(a), spos(b)) end
      end
    end
  end
  if #rt > 0 then
    add('razor', ('Razor  %s–%s · %s'):format(spos(rz.t0), spos(rz.t1), #rt == 1 and rt[1]:gsub('^#%d+ ', '') or (#rt .. ' tracks')),
      table.concat(lines, '\n') .. chords(rz.t0, rz.t1))
  end
  if e > s then add('time', ('Time  %s–%s'):format(spos(s), spos(e)), span(s, e) .. chords(s, e)) end
  local nt = reaper.CountSelectedTracks(proj)
  if nt > 0 then
    local names = {}
    for i = 0, math.min(nt, 12) - 1 do
      local t = reaper.GetSelectedTrack(proj, i)
      local ni_ = reaper.CountTrackMediaItems(t)
      names[#names + 1] = ('#%d %s   %d item%s%s'):format(trnum(t), select(2, reaper.GetTrackName(t)), ni_, ni_ == 1 and '' or 's',
        reaper.GetMediaTrackInfo_Value(t, 'B_MUTE') == 1 and ', muted' or '')
    end
    if nt > 12 then names[#names + 1] = ('… +%d'):format(nt - 12) end
    add('tracks', nt == 1 and ('Track  ' .. select(2, reaper.GetTrackName(reaper.GetSelectedTrack(proj, 0))))
      or ('Tracks  ' .. nt), table.concat(names, '\n'))
  end
  local ni = reaper.CountSelectedMediaItems(proj)
  if ni > 0 then
    local L = {}
    for i = 0, math.min(ni, 10) - 1 do
      local m = reaper.GetSelectedMediaItem(proj, i)
      local p0, p1 = len_of(m)
      local tk = reaper.GetActiveTake(m)
      local tkn = tk and select(2, reaper.GetSetMediaItemTakeInfo_String(tk, 'P_NAME', '', false)) or ''
      L[#L + 1] = ('%s   %s – %s%s'):format(select(2, reaper.GetTrackName(reaper.GetMediaItem_Track(m))), pos(p0), pos(p1),
        tkn ~= '' and ('   "' .. tkn .. '"') or '')
    end
    if ni > 10 then L[#L + 1] = ('… +%d'):format(ni - 10) end
    local m = reaper.GetSelectedMediaItem(proj, 0)
    local p0, p1 = len_of(m)
    local _, tn = reaper.GetTrackName(reaper.GetMediaItem_Track(m))
    add('items', ni == 1 and ('Item  %s %s–%s'):format(tn, spos(p0), spos(p1)) or ('Items  ' .. ni), table.concat(L, '\n'))
  end
  local ed = reaper.MIDIEditor_GetActive()
  local take = ed and reaper.MIDIEditor_GetTake(ed)
  if SEL.sig.notes and SEL.sig.notes ~= '' and take and reaper.ValidatePtr2(proj, take, 'MediaItem_Take*') then
    -- recounted only when the take's notes change (the hash covers selection too): a big MIDI item stays cheap
    local _, hash = reaper.MIDI_GetHash(take, true, '')
    local key = tostring(take) .. '\0' .. tostring(hash) .. '\0' .. SEL.sig.notes
    local c = SEL.note_pill
    if not c or c.key ~= key then
      local n, lo, hi, first, last = 0, 128, -1, nil, nil
      local idx = reaper.MIDI_EnumSelNotes(take, -1)
      while idx ~= -1 do
        n, first, last = n + 1, first or idx, idx
        if n <= 2000 then
          local _, _, _, _, _, _, pitch = reaper.MIDI_GetNote(take, idx)
          lo, hi = math.min(lo, pitch), math.max(hi, pitch)
        end
        idx = reaper.MIDI_EnumSelNotes(take, idx)
      end
      local t0, t1 = 0, 0
      if first then
        local _, _, _, sp = reaper.MIDI_GetNote(take, first)
        local _, _, _, _, ep = reaper.MIDI_GetNote(take, last)
        t0, t1 = reaper.MIDI_GetProjTimeFromPPQPos(take, sp), reaper.MIDI_GetProjTimeFromPPQPos(take, ep)
      end
      c = { key = key, n = n, detail = n > 0 and ('%d note%s, %s–%s\n%s – %s'):format(n, n == 1 and '' or 's',
        note_name(lo), note_name(hi), pos(t0), pos(t1)) or '' }
      SEL.note_pill = c
    end
    local _, tn = reaper.GetTrackName(reaper.GetMediaItemTake_Track(take))
    if c.n > 0 then add('notes', ('Notes  %d in %s'):format(c.n, tn), c.detail) end
  end
  local env = reaper.GetSelectedEnvelope(proj)
  if env then
    local _, en = reaper.GetEnvelopeName(env)
    local tr = reaper.Envelope_GetParentTrack(env)
    local np = reaper.CountEnvelopePoints(env)
    add('env', 'Envelope  ' .. en, ('%s on %s\n%d point%s'):format(en,
      tr and ('#%d %s'):format(trnum(tr), select(2, reaper.GetTrackName(tr))) or '?', np, np == 1 and '' or 's'))
  end
  local rv, tnum, _, fnum = reaper.GetFocusedFX2()
  if rv and rv ~= 0 and rv & 2 == 0 then
    local tr = tnum == 0 and reaper.GetMasterTrack(proj) or reaper.GetTrack(proj, tnum - 1)
    if tr then
      local _, fn = reaper.TrackFX_GetFXName(tr, fnum)
      add('fx', 'FX  ' .. (fn:gsub('^%w+i?: ', ''):gsub(' %(.-%)$', '')),
        ('%s\non %s%s'):format(fn, tnum == 0 and 'MASTER' or ('#%d %s'):format(tnum, select(2, reaper.GetTrackName(tr))),
          reaper.TrackFX_GetEnabled(tr, fnum) and '' or ' (bypassed)'))
    end
  end
  return P
end

local function sel_tick(force)
  local now = reaper.time_precise()
  if not force and now - SEL.t < 0.25 then return end
  SEL.t = now
  local proj = reaper.EnumProjects(-1)
  local g = sel_sigs(proj)
  local changed = false
  for _, k in ipairs(SEL_KINDS) do
    if SEL.sig[k] == nil then SEL.at[k] = false; changed = true -- already like this when the panel opened
    elseif SEL.sig[k] ~= g[k] then SEL.at[k] = now; changed = true end
    SEL.sig[k] = g[k]
  end
  if changed or now - (SEL.pills_at or 0) > 2 then -- names can change without the selection changing
    SEL.pills, SEL.pills_at = sel_pills(proj), now
  end
end

local function age(k)
  local t = SEL.at[k]
  if not t then return 'before panel opened' end
  local d = reaper.time_precise() - t
  if d < 60 then return ('%ds ago'):format(math.floor(d)) end
  if d < 3600 then return ('%d min ago'):format(math.floor(d / 60)) end
  return ('%d h ago'):format(math.floor(d / 3600))
end
local function set_ago(k) return ' (set ' .. age(k) .. ')' end

local function recency()
  local live = {}
  for _, k in ipairs(SEL_KINDS) do
    if SEL.sig[k] and SEL.sig[k] ~= '' and not (k == 'cursor' and SEL.at[k] == false) then live[#live + 1] = k end
  end
  if #live < 2 then return nil end
  table.sort(live, function(a, b) return (SEL.at[a] or -1) > (SEL.at[b] or -1) end)
  local out = {}
  for _, k in ipairs(live) do out[#out + 1] = SEL_LABEL[k] .. ' ' .. age(k) end
  return 'newest first: ' .. table.concat(out, ' > ')
end

-- markers, regions and notes inside a time range; tracks = nil means every track
local function range_lines(proj, t0, t1, tracks, indent)
  local L = {}
  local mk, rg, more = {}, {}, 0
  local _, nm, nr = reaper.CountProjectMarkers(proj)
  for i = 0, (nm or 0) + (nr or 0) - 1 do
    local _, isr, p0, p1, name, num = reaper.EnumProjectMarkers3(proj, i)
    if isr then
      if p0 < t1 and p1 > t0 then rg[#rg + 1] = ('"%s" %s–%s'):format(name, pos(p0), pos(p1)) end
    elseif p0 >= t0 - 1e-9 and p0 < t1 - 1e-9 then
      if #mk < 16 then mk[#mk + 1] = ('%d "%s" @ %s'):format(num, name, pos(p0)) else more = more + 1 end
    end
  end
  if more > 0 then mk[#mk + 1] = ('… +%d more'):format(more) end
  if #mk > 0 then L[#L + 1] = indent .. 'markers: ' .. table.concat(mk, ', ') end
  if #rg > 0 then L[#L + 1] = indent .. 'regions: ' .. table.concat(rg, ', ') end
  if not tracks then
    tracks = {}
    for i = 0, reaper.CountTracks(proj) - 1 do tracks[#tracks + 1] = reaper.GetTrack(proj, i) end
  end
  local parts, extra = {}, 0
  for _, tr in ipairs(tracks) do
    local notes, lo, hi, audio = 0, 128, -1, 0
    for i = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local m = reaper.GetTrackMediaItem(tr, i)
      local p0 = reaper.GetMediaItemInfo_Value(m, 'D_POSITION')
      local p1 = p0 + reaper.GetMediaItemInfo_Value(m, 'D_LENGTH')
      local take = reaper.GetActiveTake(m)
      if take and p0 < t1 and p1 > t0 and reaper.GetMediaItemInfo_Value(m, 'B_MUTE') == 0 then
        if reaper.TakeIsMIDI(take) then
          local a = reaper.MIDI_GetPPQPosFromProjTime(take, math.max(t0, p0))
          local b = reaper.MIDI_GetPPQPosFromProjTime(take, math.min(t1, p1))
          local _, nn = reaper.MIDI_CountEvts(take)
          local k0, k1 = 0, nn -- notes are sorted by start: binary search for the first one at or after a
          while k0 < k1 do
            local mid = (k0 + k1) // 2
            local _, _, _, sp = reaper.MIDI_GetNote(take, mid)
            if sp < a then k0 = mid + 1 else k1 = mid end
          end
          for k = k0, nn - 1 do
            local _, _, muted, sp, _, _, pitch = reaper.MIDI_GetNote(take, k)
            if sp >= b then break end
            if not muted and sp >= a then notes = notes + 1; lo = math.min(lo, pitch); hi = math.max(hi, pitch) end
          end
        else
          audio = audio + 1
        end
      end
    end
    if notes > 0 or audio > 0 then
      if #parts < 16 then
        local _, tn = reaper.GetTrackName(tr)
        local d = {}
        if notes > 0 then d[#d + 1] = ('%d %s %s–%s'):format(notes, notes == 1 and 'note' or 'notes', note_name(lo), note_name(hi)) end
        if audio > 0 then d[#d + 1] = 'audio' end
        local muted = reaper.GetMediaTrackInfo_Value(tr, 'B_MUTE') == 1 and ', track muted' or ''
        parts[#parts + 1] = ('#%d %s (%s%s)'):format(trnum(tr), tn, table.concat(d, ' + '), muted)
      else
        extra = extra + 1
      end
    end
  end
  if extra > 0 then parts[#parts + 1] = ('… +%d more tracks'):format(extra) end
  L[#L + 1] = indent .. 'playing here: ' .. (#parts > 0 and table.concat(parts, ', ') or 'nothing')
  return L
end

-- razor edit = a rectangle (time range × tracks), each track can hold several ranges
local function razor_ctx(proj)
  local out = {}
  for i = 0, reaper.CountTracks(proj) - 1 do
    local tr = reaper.GetTrack(proj, i)
    local _, s = reaper.GetSetMediaTrackInfo_String(tr, 'P_RAZOREDITS', '', false)
    if s and s ~= '' then
      local _, tn = reaper.GetTrackName(tr)
      for a, b, g in s:gmatch('(%S+) (%S+) "([^"]*)"') do
        out[#out + 1] = { tr = tr, t0 = tonumber(a), t1 = tonumber(b), env = g ~= '',
          label = ('#%d %s %s–%s%s'):format(i + 1, tn, pos(tonumber(a)), pos(tonumber(b)), g ~= '' and ' (envelope lane)' or '') }
      end
    end
  end
  return out
end

local function fx_ctx(proj, full)
  local rv, tnum, inum, fnum = reaper.GetFocusedFX2()
  if not rv or rv == 0 then return nil end
  local tr = tnum == 0 and reaper.GetMasterTrack(proj) or reaper.GetTrack(proj, tnum - 1)
  if not tr then return nil end
  local _, tname = reaper.GetTrackName(tr)
  local where = tnum == 0 and 'MASTER' or ('#%d %s'):format(tnum, tname)
  local name, nparams, pname, pval, enabled
  if rv & 2 ~= 0 then
    local item = reaper.GetTrackMediaItem(tr, inum)
    local take = item and reaper.GetMediaItemTake(item, fnum >> 16)
    if not take then return nil end
    local fx = fnum & 0xFFFF
    name = select(2, reaper.TakeFX_GetFXName(take, fx))
    nparams = reaper.TakeFX_GetNumParams(take, fx)
    pname = function(p) return select(2, reaper.TakeFX_GetParamName(take, fx, p)) end
    pval = function(p) return select(2, reaper.TakeFX_GetFormattedParamValue(take, fx, p)) end
    enabled = reaper.TakeFX_GetEnabled(take, fx)
    where = where .. (', item %d take FX %d'):format(inum, fx)
  else
    name = select(2, reaper.TrackFX_GetFXName(tr, fnum))
    nparams = reaper.TrackFX_GetNumParams(tr, fnum)
    pname = function(p) return select(2, reaper.TrackFX_GetParamName(tr, fnum, p)) end
    pval = function(p) return select(2, reaper.TrackFX_GetFormattedParamValue(tr, fnum, p)) end
    enabled = reaper.TrackFX_GetEnabled(tr, fnum)
    where = where .. ((fnum & 0x1000000 ~= 0) and (', input FX %d'):format(fnum & 0xFFFFFF) or (', FX %d'):format(fnum))
  end
  local r = { name = name, short = (name:gsub('^%w+i?: ', ''):gsub(' %(.-%)$', '')), where = where,
    enabled = enabled, focused = rv & 4 == 0, n = nparams, params = {} }
  if full then
    for p = 0, nparams - 1 do
      if #r.params >= 48 then break end
      local pn = pname(p)
      if pn and pn ~= '' and pn ~= 'Bypass' and pn ~= 'Wet' and pn ~= 'Delta' then
        r.params[#r.params + 1] = ('  p%d %s = %s'):format(p, pn, pval(p) or '')
      end
    end
  end
  return r
end

-- full=false: cheap chip summary; full=true: the context block
local function context(full)
  local proj = reaper.EnumProjects(-1)
  local name = reaper.GetProjectName(proj):gsub('%.[Rr][Pp][Pp]$', '')
  if name == '' then name = '(unsaved)' end
  local ps = reaper.GetPlayState()
  local state = (ps & 4 ~= 0) and 'recording' or (ps & 1 ~= 0) and 'playing' or (ps & 2 ~= 0) and 'paused' or 'stopped'
  local cur = (ps & 1 ~= 0) and reaper.GetPlayPosition() or reaper.GetCursorPosition()
  local bpm = math.floor(reaper.Master_GetTempo() * 100 + 0.5) / 100
  local num, den = reaper.TimeMap_GetTimeSigAtTime(proj, cur)
  local L = {
    ('project: %s'):format(name),
    ('tempo: %g BPM %d/%d'):format(bpm, num, den),
    ('cursor: %s (%s)'):format(pos(cur), state),
  }
  local chip = { name, ('%g BPM'):format(bpm), pos(cur) }


  if full then
    sel_tick(true)
    local rc = recency()
    if rc then L[#L + 1] = 'selection recency: ' .. rc end
  end

  local mk = marker_ctx(proj, cur)
  if mk.region then L[#L + 1] = 'region at cursor: ' .. mk.region; chip[#chip + 1] = mk.region_name end
  if mk.markers then L[#L + 1] = 'markers at cursor: ' .. mk.markers end

  local s, e = reaper.GetSet_LoopTimeRange2(proj, false, false, 0, 0, false)
  if e > s then
    chip[#chip + 1] = 'time sel'
    if full then
      L[#L + 1] = ('time selection (all tracks): %s – %s%s'):format(pos(s), pos(e), set_ago('time'))
      for _, x in ipairs(range_lines(proj, s, e, nil, '  ')) do L[#L + 1] = x end
    else
      L[#L + 1] = ('time selection: %s – %s'):format(pos(s), pos(e))
    end
  end

  local rz = razor_ctx(proj)
  if #rz > 0 then
    chip[#chip + 1] = 'razor'
    -- ranges with the same start/end on several tracks are one rectangle
    local areas, by = {}, {}
    for _, r in ipairs(rz) do
      local key = ('%.6f:%.6f'):format(r.t0, r.t1)
      local a = by[key]
      if not a then a = { t0 = r.t0, t1 = r.t1, tracks = {}, names = {} }; by[key] = a; areas[#areas + 1] = a end
      if not r.env and a.tracks[#a.tracks] ~= r.tr then a.tracks[#a.tracks + 1] = r.tr end
      local _, tn = reaper.GetTrackName(r.tr)
      local nm_ = ('#%d %s%s'):format(trnum(r.tr), tn, r.env and ' (envelope lane)' or '')
      if a.names[#a.names] ~= nm_ then a.names[#a.names + 1] = nm_ end
    end
    if full then
      for n, a in ipairs(areas) do
        if n > 8 then L[#L + 1] = ('  … +%d more razor areas'):format(#areas - 8); break end
        L[#L + 1] = ('razor area: %s – %s on %s%s'):format(pos(a.t0), pos(a.t1), table.concat(a.names, ', '), set_ago('razor'))
        if #a.tracks > 0 then
          for _, x in ipairs(range_lines(proj, a.t0, a.t1, a.tracks, '  ')) do L[#L + 1] = x end
        end
      end
    end
  end

  local tr = {}
  for i = 0, reaper.CountSelectedTracks(proj) - 1 do
    local t = reaper.GetSelectedTrack(proj, i)
    local _, tn = reaper.GetTrackName(t)
    tr[#tr + 1] = { ('#%d %s'):format(trnum(t), tn), tn }
  end
  if #tr > 0 then
    local names = {}
    for _, x in ipairs(tr) do names[#names + 1] = x[1] end
    L[#L + 1] = 'selected tracks: ' .. table.concat(names, ', ') .. (full and set_ago('tracks') or '')
    chip[#chip + 1] = #tr == 1 and tr[1][2] or (#tr .. ' tracks')
  end

  local n = reaper.CountSelectedMediaItems(proj)
  if n > 0 then
    if full then
      local it = {}
      for i = 0, math.min(n, 8) - 1 do
        local m = reaper.GetSelectedMediaItem(proj, i)
        local _, tn = reaper.GetTrackName(reaper.GetMediaItem_Track(m))
        local p0 = reaper.GetMediaItemInfo_Value(m, 'D_POSITION')
        local len = reaper.GetMediaItemInfo_Value(m, 'D_LENGTH')
        it[#it + 1] = ('%s @ %s–%s'):format(tn, pos(p0), pos(p0 + len))
      end
      if n > 8 then it[#it + 1] = ('… +%d more'):format(n - 8) end
      L[#L + 1] = 'selected items: ' .. table.concat(it, '; ') .. set_ago('items')
    end
    chip[#chip + 1] = n .. (n == 1 and ' item' or ' items')
  end

  local md = midi_ctx(proj, full)
  if md then
    if md.sel > 0 then
      chip[#chip + 1] = md.sel .. (md.sel == 1 and ' note' or ' notes')
      if full then
        L[#L + 1] = ('MIDI editor: %s, item @ %s, take "%s" — %d of %d notes selected%s%s:'):format(
          md.track, md.item, md.take, md.sel, md.total, md.sel > #md.list and (' (first ' .. #md.list .. ' listed)') or '',
          set_ago('notes'))
        for _, x in ipairs(md.list) do L[#L + 1] = x end
      end
    elseif full then
      L[#L + 1] = ('MIDI editor open: %s, item @ %s, take "%s", %d notes, none selected'):format(md.track, md.item, md.take, md.total)
    end
    if full and md.cc_sel > 0 then
      do
        L[#L + 1] = ('MIDI CC: %d of %d events selected%s:'):format(md.cc_sel, md.cc_total,
          md.cc_sel > #md.cc_list and (' (first ' .. #md.cc_list .. ' listed)') or '')
        for _, x in ipairs(md.cc_list) do L[#L + 1] = x end
      end
    end
  end

  if full then
    local ev = envelope_ctx(proj)
    if ev then
      L[#L + 1] = ev.head:gsub(':$', '') .. set_ago('env') .. (ev.head:find(':$') and ':' or '')
      for _, x in ipairs(ev.list) do L[#L + 1] = x end
    end
  end

  local fx = fx_ctx(proj, full)
  if fx then
    chip[#chip + 1] = 'FX: ' .. fx.short
    if full then
      L[#L + 1] = ('%s FX: %s on %s (%s) — %d params%s%s:'):format(fx.focused and 'focused' or 'open (last focused)',
        fx.name, fx.where, fx.enabled and 'enabled' or 'bypassed', fx.n,
        fx.n > #fx.params and (', first ' .. #fx.params .. ' shown') or '', set_ago('fx'))
      for _, x in ipairs(fx.params) do L[#L + 1] = x end
    end
  end
  local studio = P.studio()
  if full and studio then studio.context_lines(L) end
  return table.concat(L, '\n'), table.concat(chip, ' · ')
end

local chip_text
do
  local chip_cache, chip_at = '', 0
  function chip_text()
    local now = reaper.time_precise()
    if now - chip_at > 0.25 then
      chip_at = now
      local _, c = context(false)
      chip_cache = c
    end
    return chip_cache
  end
end

local CTX_OPEN = '[REAPER context — auto-attached by the Hibiki panel in REAPER; #N = REAPER track number, MCP index = N-1]'
local CTX_CLOSE = '[/REAPER context]'
-- first line of the block; CTX_OPEN itself stays fixed so older messages still fold
local CTX_NOTE = 'note: REAPER keeps every selection until it is changed, so stale ones linger; "set … ago" says what the user touched last. Read the request first, then the newest selection.'

local function split_context(text)
  local a, b = text:find(CTX_OPEN, 1, true)
  if a == 1 then
    local c, d = text:find(CTX_CLOSE, b, true)
    if c then return (text:sub(d + 1):gsub('^%s+', '')), true, text:sub(b + 1, c - 1) end
  end
  return text, false
end

return { SEL = SEL, sel_tick = sel_tick, context = context, chip_text = chip_text, split_context = split_context,
  CTX_OPEN = CTX_OPEN, CTX_CLOSE = CTX_CLOSE, CTX_NOTE = CTX_NOTE }
end
