-- Hibiki markdown: parses agent replies into draw ops (wrapped text, code, tables, links) for the ReaImGui panel,
-- with selection and copy. Hibiki.lua loads it next to itself and calls it once.
return function(P)
local ImGui, ctx, S, C, F, FONT_SIZE, RND_STRIP, alpha = P.ImGui, P.ctx, P.S, P.C, P.F, P.FONT_SIZE, P.RND_STRIP, P.alpha
local wcache, wcache_n = {}, 0
local function tw(font, size, s)
  local fc = wcache[font]
  if not fc then fc = {}; wcache[font] = fc end
  local sc = fc[size]
  if not sc then sc = {}; fc[size] = sc end
  local w = sc[s]
  if not w then
    ImGui.PushFont(ctx, font, size)
    w = ImGui.CalcTextSize(ctx, s)
    ImGui.PopFont(ctx)
    sc[s] = w
    wcache_n = wcache_n + 1
    if wcache_n > 30000 then wcache, wcache_n = {}, 0 end
  end
  return w
end

local function parse_inline(s)
  local runs, buf = {}, {}
  local bold = false
  local function flush()
    if #buf > 0 then runs[#runs + 1] = { text = table.concat(buf), bold = bold }; buf = {} end
  end
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local handled = false
    if c == '`' then
      local j = s:find('`', i + 1, true)
      if j then flush(); runs[#runs + 1] = { text = s:sub(i + 1, j - 1), code = true }; i = j + 1; handled = true end
    elseif (c == '*' or c == '_') and s:sub(i + 1, i + 1) == c then
      flush(); bold = not bold; i = i + 2; handled = true
    elseif c == '[' then
      local t, u, e = s:match('^%[([^%]]+)%]%(([^%)%s]+)%)()', i)
      if t then flush(); runs[#runs + 1] = { text = t, link = u }; i = e; handled = true end
    elseif c == '*' then
      local j = s:find('*', i + 1, true)
      if j and j > i + 1 and not s:sub(i + 1, i + 1):match('%s') then
        flush(); runs[#runs + 1] = { text = s:sub(i + 1, j - 1), italic = true, bold = bold }; i = j + 1; handled = true
      end
    end
    if not handled then buf[#buf + 1] = c; i = i + 1 end
  end
  flush()
  return runs
end

local function tokens(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    if b == 10 then
      out[#out + 1] = '\n'; i = i + 1
    elseif b < 0x80 then
      local tok = s:match('^[^ \n\128-\255]+ *', i) or s:match('^ +', i)
      out[#out + 1] = tok; i = i + #tok
    else
      local len = b >= 0xF0 and 4 or b >= 0xE0 and 3 or b >= 0xC0 and 2 or 1
      out[#out + 1] = s:sub(i, i + len - 1); i = i + len
    end
  end
  return out
end

-- ops: {'t', x, y, font, size, col, text} | {'r', x1, y1, x2, y2, col, rounding} | {'l', x1, y1, x2, y2, col, thick}
local function layout_inline(ops, runs, x0, y, maxw, size, base_col, mono)
  local lh = math.floor(size * 1.5 + 0.5)
  local dy = math.floor((lh - size) / 2)
  local x, has = x0, false
  local nl = true -- the first op of a block, and the first after a hard newline, starts a source line
  local function put(op)
    if op[1] == 't' and nl then op.nl, nl = true, false end
    ops[#ops + 1] = op
  end
  for _, r in ipairs(runs) do
    local font = (mono or r.code) and F.mono or (r.bold and F.bold or F.reg)
    local col = r.link and C.accent or (r.italic and C.muted) or base_col
    for _, tok in ipairs(tokens(r.text)) do
      if tok == '\n' then
        x, y, has, nl = x0, y + lh, false, true
      else
        local f
        if font == F.mono then f = tok:byte(1) >= 0x80 and F.reg or F.mono
        elseif tok:byte(1) >= 0xE2 then f = font
        else f = font == F.bold and F.ui_bold or F.ui end
        local w = tw(f, size, tok)
        if x + w > x0 + maxw and has then
          x, y, has = x0, y + lh, false
          if not mono then tok = tok:gsub('^ +', ''); w = tw(f, size, tok) end
        end
        if tok ~= '' then
          if w > maxw then
            for ch in tok:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
              local cw = tw(f, size, ch)
              if x + cw > x0 + maxw and has then x, y = x0, y + lh end
              put({ 't', x, y + dy, f, size, col, ch })
              x, has = x + cw, true
            end
          else
            if r.code and not mono then ops[#ops + 1] = { 'r', x, y + 1, x + w, y + lh - 1, C.codebg, 2 } end
            put({ 't', x, y + dy, f, size, col, tok })
            if r.link then ops[#ops + 1] = { 'l', x, y + dy + size + 1, x + w, y + dy + size + 1, alpha(C.accent, 0x88), 1 } end
            x, has = x + w, true
          end
        end
      end
    end
  end
  return y + lh
end

local function parse_md(text)
  local blocks, lines = {}, {}
  for l in (text .. '\n'):gmatch('(.-)\r?\n') do lines[#lines + 1] = l end
  local function cells(row)
    row = row:gsub('^%s*|', ''):gsub('|%s*$', '')
    local c = {}
    for cell in (row .. '|'):gmatch('(.-)|') do c[#c + 1] = parse_inline((cell:gsub('^%s+', ''):gsub('%s+$', ''))) end
    return c
  end
  local i = 1
  while i <= #lines do
    local l = lines[i]
    if l:match('^%s*```') then
      local buf = {}
      i = i + 1
      while i <= #lines and not lines[i]:match('^%s*```%s*$') do buf[#buf + 1] = lines[i]; i = i + 1 end
      blocks[#blocks + 1] = { t = 'code', text = table.concat(buf, '\n') }
      i = i + 1
    elseif l:match('^%s*$') then
      blocks[#blocks + 1] = { t = 'blank' }; i = i + 1
    elseif l:match('^#+%s') then
      local h, rest = l:match('^(#+)%s+(.*)$')
      blocks[#blocks + 1] = { t = 'h', level = #h, runs = parse_inline(rest) }; i = i + 1
    elseif l:match('^%s*[-*_][-*_ ]*$') and select(2, l:gsub('[-*_]', '')) >= 3 then
      blocks[#blocks + 1] = { t = 'hr' }; i = i + 1
    elseif l:match('^%s*|') and lines[i + 1] and lines[i + 1]:match('^%s*|?%s*:?%-%-') then
      local head = cells(l)
      i = i + 2
      local rows = {}
      while i <= #lines and lines[i]:match('^%s*|') do rows[#rows + 1] = cells(lines[i]); i = i + 1 end
      blocks[#blocks + 1] = { t = 'table', head = head, rows = rows }
    elseif l:match('^%s*>') then
      blocks[#blocks + 1] = { t = 'quote', runs = parse_inline((l:gsub('^%s*>%s?', ''))) }; i = i + 1
    elseif l:match('^%s*[-*+]%s') then
      local ind, rest = l:match('^(%s*)[-*+]%s+(.*)$')
      blocks[#blocks + 1] = { t = 'li', level = #ind // 2, bullet = '•', runs = parse_inline(rest) }; i = i + 1
    elseif l:match('^%s*%d+[.)]%s') then
      local ind, num, rest = l:match('^(%s*)(%d+)[.)]%s+(.*)$')
      blocks[#blocks + 1] = { t = 'li', level = #ind // 2, bullet = num .. '.', runs = parse_inline(rest) }; i = i + 1
    else
      blocks[#blocks + 1] = { t = 'p', runs = parse_inline(l) }; i = i + 1
    end
  end
  return blocks
end

local function layout_table(ops, b, y, maxw, size)
  local ncol = #b.head
  for _, r in ipairs(b.rows) do ncol = math.max(ncol, #r) end
  local pad = 6
  local function natural(runs, bold)
    local w = 0
    for _, r in ipairs(runs) do
      local f = r.code and F.mono or ((bold or r.bold) and F.bold or F.reg)
      w = w + tw(f, size, (r.text:gsub('\n', ' ')))
    end
    return w
  end
  local nat = {}
  for c = 1, ncol do nat[c] = 24 end
  for c, cell in ipairs(b.head) do nat[c] = math.max(nat[c], natural(cell, true) + 2 * pad) end
  for _, row in ipairs(b.rows) do
    for c, cell in ipairs(row) do if c <= ncol then nat[c] = math.max(nat[c], natural(cell) + 2 * pad) end end
  end
  local total = 0
  for c = 1, ncol do total = total + nat[c] end
  local widths, sum = {}, 0
  for c = 1, ncol do
    widths[c] = total <= maxw and nat[c] or math.max(36, math.floor(nat[c] * maxw / total))
    sum = sum + widths[c]
  end
  local function row(cells, yy, header)
    local sub, h, x = {}, 0, 0
    for c = 1, ncol do
      local runs = cells[c] or {}
      if header then for _, r in ipairs(runs) do r.bold = true end end
      local yb = layout_inline(sub, runs, x + pad, yy + 3, widths[c] - 2 * pad, size, C.body)
      h = math.max(h, yb - yy + 3)
      x = x + widths[c]
    end
    if header then ops[#ops + 1] = { 'r', 0, yy, sum, yy + h, C.panel, 0 } end
    for _, o in ipairs(sub) do ops[#ops + 1] = o end
    ops[#ops + 1] = { 'l', 0, yy + h, sum, yy + h, C.rule, 1 }
    return yy + h
  end
  local y0 = y
  ops[#ops + 1] = { 'l', 0, y, sum, y, C.rule, 1 }
  y = row(b.head, y, true)
  for _, r in ipairs(b.rows) do y = row(r, y, false) end
  local x = 0
  for c = 0, ncol do
    ops[#ops + 1] = { 'l', x, y0, x, y, C.rule, 1 }
    if c < ncol then x = x + widths[c + 1] end
  end
  return y + 6
end

local function layout_md(text, maxw, size, y0)
  local ops, y = {}, y0 or 0
  local lh = math.floor(size * 1.5 + 0.5)
  for _, b in ipairs(parse_md(text)) do
    if b.t == 'blank' then
      y = y + math.floor(lh * 0.45)
    elseif b.t == 'p' then
      y = layout_inline(ops, b.runs, 0, y, maxw, size, C.body)
    elseif b.t == 'h' then
      local hs = b.level == 1 and size + 5 or b.level == 2 and size + 3 or size + 1
      if y > 0 then y = y + math.floor(lh * 0.4) end
      for _, r in ipairs(b.runs) do if not r.code then r.bold = true end end
      y = layout_inline(ops, b.runs, 0, y, maxw, hs, C.text)
      if b.level <= 2 then ops[#ops + 1] = { 'l', 0, y + 1, maxw, y + 1, C.rule, 1 }; y = y + 5 end
    elseif b.t == 'li' then
      local ind = 2 + b.level * 16
      local bw = math.max(tw(F.reg, size, b.bullet) + 6, 14)
      ops[#ops + 1] = { 't', ind, y + math.floor((lh - size) / 2), F.reg, size, C.muted, b.bullet, nl = true }
      y = layout_inline(ops, b.runs, ind + bw, y, maxw - ind - bw, size, C.body)
    elseif b.t == 'quote' then
      local y0 = y
      y = layout_inline(ops, b.runs, 12, y, maxw - 12, size, C.muted)
      ops[#ops + 1] = { 'r', 0, y0 + 2, 3, y - 2, alpha(C.accent, 0x99), 1 }
    elseif b.t == 'hr' then
      y = y + 6; ops[#ops + 1] = { 'l', 0, y, maxw, y, C.rule, 1 }; y = y + 7
    elseif b.t == 'code' then
      local pad, y0, sub = 8, y, {}
      y = layout_inline(sub, { { text = b.text } }, pad, y + pad, maxw - 2 * pad, size - 1, C.text, true)
      ops[#ops + 1] = { 'r', 0, y0, maxw, y + pad, C.code, 6 }
      for _, o in ipairs(sub) do ops[#ops + 1] = o end
      y = y + pad + 6
    elseif b.t == 'table' then
      y = layout_table(ops, b, y, maxw, size)
    end
  end
  return ops, y
end

-- Text selection. Messages are drawn from laid-out ops, so ImGui's own selection doesn't apply: hit-test the
-- text ops, keep {op index, byte offset} for both ends, highlight, and copy with Cmd+C.
local function op_line(o)
  local lh = math.floor(o[5] * 1.5 + 0.5)
  local top = o[3] - math.floor((lh - o[5]) / 2)
  return top, top + lh
end
local function op_stops(o) -- {byte offset, x} at every character boundary, cached on the op
  if not o.stops then
    local st, x = { { 0, o[2] } }, o[2]
    for pos, ch in o[7]:gmatch('()([%z\1-\127\194-\244][\128-\191]*)') do
      x = x + tw(o[4], o[5], ch)
      st[#st + 1] = { pos + #ch - 1, x }
    end
    o.stops = st
  end
  return o.stops
end
local function stop_x(o, off)
  for _, st in ipairs(op_stops(o)) do if st[1] >= off then return st[2] end end
  return o[2]
end
local function hit(ops, lx, ly)
  local best, bd
  for i, o in ipairs(ops) do
    if o[1] == 't' then
      local top, bot = op_line(o)
      local st = op_stops(o)
      local right = st[#st][2]
      local dv = ly < top and top - ly or (ly > bot and ly - bot or 0)
      local dh = lx < o[2] and o[2] - lx or (lx > right and lx - right or 0)
      local d = dv * 10000 + dh
      if not bd or d < bd then best, bd = i, d end
    end
  end
  if not best then return nil end
  local off, dx = 0, math.huge
  for _, st in ipairs(op_stops(ops[best])) do
    if math.abs(st[2] - lx) < dx then off, dx = st[1], math.abs(st[2] - lx) end
  end
  return { i = best, off = off }
end
local function sel_range(sel)
  local a, b = sel.a, sel.b
  if b.i < a.i or (b.i == a.i and b.off < a.off) then a, b = b, a end
  return a, b
end
local function selected_text(sel)
  local a, b = sel_range(sel)
  local out, prev = {}, nil
  for i = a.i, b.i do
    local o = sel.L.ops[i]
    if o[1] == 't' then
      local piece = o[7]:sub((i == a.i and a.off or 0) + 1, i == b.i and b.off or #o[7])
      if prev then
        if o[3] > prev[3] + 1 then
          if o.nl then out[#out + 1] = '\n' end -- a wrapped line continues the same source line
        elseif o[2] > op_stops(prev)[#op_stops(prev)][2] + 2 and not (out[#out] or ''):match(' $') then
          out[#out + 1] = ' '
        end
      end
      out[#out + 1] = piece
      prev = o
    end
  end
  return table.concat(out)
end

local function draw_ops(L, w)
  local ops, h = L.ops, L.h
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local _, wy = ImGui.GetWindowPos(ctx)
  local _, wh = ImGui.GetWindowSize(ctx)
  if y0 + h >= wy and y0 <= wy + wh then
    local dl = ImGui.GetWindowDrawList(ctx)
    local top, bot = wy - y0 - 40, wy + wh - y0
    local sel = S.sel and S.sel.L == L and S.sel
    local sa, sb
    if sel then sa, sb = sel_range(sel) end
    for i, o in ipairs(ops) do
      if sel and o[1] == 't' and i >= sa.i and i <= sb.i and o[3] > top and o[3] < bot then
        local x1 = i == sa.i and stop_x(o, sa.off) or o[2]
        local x2 = i == sb.i and stop_x(o, sb.off) or op_stops(o)[#op_stops(o)][2]
        if x2 > x1 then
          local lt, lb = op_line(o)
          ImGui.DrawList_AddRectFilled(dl, x0 + x1, y0 + lt, x0 + x2, y0 + lb, C.selection)
        end
      end
    end
    S.n_ops = (S.n_ops or 0) + #ops
    for _, o in ipairs(ops) do
      local k = o[1]
      if k == 't' then
        if o[3] > top and o[3] < bot then ImGui.DrawList_AddTextEx(dl, o[4], o[5], x0 + o[2], y0 + o[3], o[6], o[7]) end
      elseif o[5] > top and o[3] < bot then
        if k == 'r' then ImGui.DrawList_AddRectFilled(dl, x0 + o[2], y0 + o[3], x0 + o[4], y0 + o[5], o[6], o[7])
        else ImGui.DrawList_AddLine(dl, x0 + o[2], y0 + o[3], x0 + o[4], y0 + o[5], o[6], o[7]) end
      end
    end
  end
  ImGui.Dummy(ctx, w, math.max(1, h))
  local hovered = ImGui.IsItemHovered(ctx)
  if hovered then ImGui.SetMouseCursor(ctx, ImGui.MouseCursor_TextInput) end
  local mx, my = ImGui.GetMousePos(ctx)
  if hovered and ImGui.IsMouseClicked(ctx, 0) then
    S.sel_clicked = true
    local p = hit(ops, mx - x0, my - y0)
    if p and ImGui.IsMouseDoubleClicked(ctx, 0) then -- whole word (one op)
      S.sel = { L = L, a = { i = p.i, off = 0 }, b = { i = p.i, off = #ops[p.i][7] } }
    else
      S.sel = p and { L = L, a = p, b = p, drag = true } or nil
    end
  elseif S.sel and S.sel.L == L and S.sel.drag then
    if ImGui.IsMouseDown(ctx, 0) then
      S.sel.b = hit(ops, mx - x0, my - y0) or S.sel.b
    else
      S.sel.drag = false
    end
  end
end

-- Incremental layout for a growing (streamed) reply. Blocks never span a complete blank line outside a ``` fence,
-- so the text splits there into a prefix whose ops are kept and a tail that is laid out again, starting at the
-- prefix's height. md_cut returns the last such split (the \n before that blank line) after byte `from`.
local md_layout
do
local function md_cut(text, from)
  local fence, best, p = false, nil, from + 1
  while true do
    local e = text:find('\n', p, true)
    if not e then break end -- the last line may still grow: never split on it
    local line = text:sub(p, e - 1)
    if fence then
      if line:match('^%s*```%s*$') then fence = false end
    elseif line:match('^%s*```') then fence = true
    elseif p - 1 > from and line:match('^%s*$') then best = p - 1 end
    p = e + 1
  end
  return best
end
function md_layout(old, text, w)
  local cut, pre_ops, pre_h, pre = 0, {}, 0, nil
  if old and old.w == w and old.pal == P.pal_ver() and old.cut > 0 and text:sub(1, old.cut) == old.pre then
    cut, pre_ops, pre_h, pre = old.cut, old.pre_ops, old.pre_h, old.pre
  end
  local nc = md_cut(text, cut)
  if nc then
    local more, h = layout_md(text:sub(cut + 1, nc - 1), w, FONT_SIZE, pre_h)
    table.move(more, 1, #more, #pre_ops + 1, pre_ops)
    cut, pre_h, pre = nc, h, text:sub(1, nc)
  end
  local ops = table.move(pre_ops, 1, #pre_ops, 1, {})
  local tail, h = layout_md(cut > 0 and text:sub(cut + 1) or text, w, FONT_SIZE, pre_h)
  table.move(tail, 1, #tail, #ops + 1, ops)
  return { w = w, text = text, pal = P.pal_ver(), ops = ops, h = h, cut = cut, pre = pre, pre_ops = pre_ops, pre_h = pre_h }
end
end

local function md(holder, text)
  local w = math.floor(ImGui.GetContentRegionAvail(ctx))
  local L = holder._md
  if not L or L.w ~= w or L.text ~= text or L.pal ~= P.pal_ver() then
    S.n_lay = (S.n_lay or 0) + 1
    L = md_layout(L, text, w)
    holder._md = L
  end
  draw_ops(L, w)
  if ImGui.IsItemClicked(ctx, 1) then ImGui.SetClipboardText(ctx, text) end
end

local function bubble(holder, text)
  local w = math.floor(ImGui.GetContentRegionAvail(ctx))
  local L = holder._bubble
  if not L or L.w ~= w or L.text ~= text or L.pal ~= P.pal_ver() then
    local pad, sub = 8, {}
    local y = layout_inline(sub, { { text = text } }, pad, pad, w - 2 * pad, FONT_SIZE, C.field_text)
    local ops = { { 'r', 0, 0, w, y + pad, C.user, RND_STRIP } }
    for _, o in ipairs(sub) do ops[#ops + 1] = o end
    L = { w = w, text = text, pal = P.pal_ver(), ops = ops, h = y + pad }
    holder._bubble = L
  end
  draw_ops(L, w)
  if ImGui.IsItemClicked(ctx, 1) then ImGui.SetClipboardText(ctx, text) end
end

return { bubble = bubble, md = md, md_layout = md_layout, layout_md = layout_md, selected_text = selected_text }
end
