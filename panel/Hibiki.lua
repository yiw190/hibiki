-- Hibiki: a chat panel docked inside REAPER, talking to Gamut and ACP agents through the
-- local agent gateway (127.0.0.1:47892) or the Gamut desktop API (127.0.0.1:47891). Needs ReaImGui >= 0.10.
-- agent gateway (gateway/agent_gateway.py: Gamut + ACP agents, model selectors) first, Gamut's own API as fallback
local HOSTS = { 'http://127.0.0.1:47892', 'http://127.0.0.1:47891' }
local HOST = HOSTS[1]
local EXT = 'Hibiki'
local OLD_EXT = 'GamutChat' -- the panel's name before 2026-10-21; its saved state moves over once

if not reaper.ImGui_GetBuiltinPath then
  reaper.MB('ReaImGui is not installed.', 'Hibiki', 0)
  return
end
package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
local ImGui = require 'imgui' '0.10'

---------------------------------------------------------------- utils
-- macOS runs background work through io.popen + sh; Windows through ExecProcess (no console window, no wait):
-- io.popen there flashes a console and ExecProcess returns -999 on macOS
local WIN = (reaper.GetOS() or ''):match('^Win') ~= nil
local function sh(cmd)
  local p = io.popen(cmd)
  if not p then return '' end
  local o = p:read('*a'); p:close(); return o or ''
end
local SYS = (os.getenv('SystemRoot') or 'C:\\Windows') .. '\\System32\\'
-- a cmd.exe line run in the background; /S strips the outer quotes, so inner quoted args survive as written
local function win_bg(inner)
  local line = '"' .. SYS .. 'cmd.exe" /D /S /C "' .. inner .. '"'
  if HIBIKI_TEST then return HIBIKI_TEST.sh(line) end
  reaper.ExecProcess(line, -2)
end
if HIBIKI_TEST then sh = HIBIKI_TEST.sh end -- headless tests record the curl commands instead of running them
-- one-time move of the saved state (agent, chats per agent, model picks, context switch) from OLD_EXT: key names come
-- from reaper-extstate.ini, values from REAPER's live copy when it has one (the ini lags until REAPER saves it)
if reaper.GetExtState(EXT, 'migrated') ~= '1' then
  local f = io.open(reaper.GetResourcePath() .. '/reaper-extstate.ini', 'r')
  local keys = { agent = '', agent_name = '', ctx_level = '', gamut_agent = '' }
  if f then
    local inside = false
    for line in f:lines() do
      local sec = line:match('^%[(.-)%]%s*$')
      if sec then inside = sec == OLD_EXT
      elseif inside then
        local k, v = line:match('^([^=]+)=(.*)$')
        if k then keys[k] = v end
      end
    end
    f:close()
  end
  for k, v in pairs(keys) do
    local live = reaper.GetExtState(OLD_EXT, k)
    if live ~= '' then v = live end
    if v ~= '' and k ~= 'action' and not k:find('^docked') and reaper.GetExtState(EXT, k) == '' then
      reaper.SetExtState(EXT, k, v, true)
    end
  end
  reaper.SetExtState(EXT, 'migrated', '1', true)
end

-- shell quoting: POSIX single quotes. Windows: double quotes; a " is refused (paths there never hold one) and every
-- % is closed out of the quotes ("%") so cmd's %VAR% expansion never sees a name it could expand
local function q(s)
  s = tostring(s)
  if WIN then
    if s:find('"', 1, true) then error('refused: double quote in a shell argument', 0) end
    return '"' .. s:gsub('(\\*)%%', function(bs) return bs .. bs .. '"%"' end) .. '"'
  end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- private scratch dir (curl output, the gateway auth header, resume scripts): per-user temp, else a per-user cache
-- dir; never a shared /tmp
local HOME = os.getenv('HOME') or os.getenv('USERPROFILE') or ''
local DIR
do
  local function env(k) local v = os.getenv(k); return v ~= '' and v or nil end
  if WIN then
    local base = env('TEMP') or env('TMP')
    DIR = base and (base:gsub('[\\/]?$', '\\') .. 'hibiki\\')
      or ((env('LOCALAPPDATA') or (HOME .. '\\AppData\\Local')):gsub('[\\/]?$', '\\') .. 'Hibiki\\')
  else
    local t = env('TMPDIR')
    if t and not t:match('^/tmp/*$') and not t:match('^/var/tmp/*$') and not t:match('^/private/tmp/*$') then
      DIR = t:gsub('/?$', '/') .. 'hibiki/'
    elseif (reaper.GetOS() or ''):match('^OSX') or (reaper.GetOS() or ''):match('^macOS') then
      DIR = HOME .. '/Library/Caches/Hibiki/'
    else
      DIR = (env('XDG_RUNTIME_DIR') and (env('XDG_RUNTIME_DIR'):gsub('/?$', '/') .. 'hibiki/')) or (HOME .. '/.cache/hibiki/')
    end
  end
end
local function mkdir()
  if not WIN then sh('/bin/mkdir -p -m 700 ' .. q(DIR) .. ' 2>/dev/null; /bin/chmod 700 ' .. q(DIR) .. ' 2>/dev/null') end
  reaper.RecursiveCreateDirectory(DIR, 0)
end
mkdir()
do -- stream files of earlier runs (this run removes its own by name in stream_stop)
  local i, old = 0, {}
  while true do
    local name = reaper.EnumerateFiles(DIR, i)
    if not name then break end
    if name:match('^stream%-') then old[#old + 1] = DIR .. name end
    i = i + 1
  end
  for _, f in ipairs(old) do os.remove(f) end
end
local CURL = WIN and (SYS .. 'curl.exe') or '/usr/bin/curl' -- Windows 10 1803+ ships curl.exe
local CURL_FMT = DIR .. 'code.fmt' -- Windows: the write-out format comes from a file; a literal %{..} on a cmd line
if WIN then                       -- is at the mercy of cmd's % expansion
  local f = io.open(CURL_FMT, 'wb')
  if f then f:write('%{http_code}'); f:close() end
end

local function u8(cp)
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
  elseif cp < 0x10000 then return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
  else return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)) end
end

---------------------------------------------------------------- json
local NULL = {}
local decode
do
  local esc = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
  local function skip(s, i) local _, e = s:find('^[ \n\r\t]*', i); return e + 1 end
  local function str(s, i)
    local out, j = {}, i + 1
    while true do
      local k = s:find('["\\]', j)
      if not k then error('unterminated string') end
      out[#out + 1] = s:sub(j, k - 1)
      if s:sub(k, k) == '"' then return table.concat(out), k + 1 end
      local n = s:sub(k + 1, k + 1)
      if n == 'u' then
        local cp = tonumber(s:sub(k + 2, k + 5), 16) or 63
        j = k + 6
        if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == '\\u' then
          local lo = tonumber(s:sub(j + 2, j + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00); j = j + 6
          end
        end
        out[#out + 1] = u8(cp)
      else
        out[#out + 1] = esc[n] or n; j = k + 2
      end
    end
  end
  local function val(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == '{' then
      local t = {}; i = skip(s, i + 1)
      if s:sub(i, i) == '}' then return t, i + 1 end
      while true do
        local k; k, i = str(s, skip(s, i))
        i = skip(s, skip(s, i) + 1)
        local v; v, i = val(s, i); t[k] = v
        i = skip(s, i)
        if s:sub(i, i) == '}' then return t, i + 1 end
        i = i + 1
      end
    elseif c == '[' then
      local t = {}; i = skip(s, i + 1)
      if s:sub(i, i) == ']' then return t, i + 1 end
      while true do
        local v; v, i = val(s, i); t[#t + 1] = v
        i = skip(s, i)
        if s:sub(i, i) == ']' then return t, i + 1 end
        i = i + 1
      end
    elseif c == '"' then return str(s, i)
    elseif s:sub(i, i + 3) == 'true' then return true, i + 4
    elseif s:sub(i, i + 4) == 'false' then return false, i + 5
    elseif s:sub(i, i + 3) == 'null' then return NULL, i + 4
    else
      local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
      if not num or num == '' then error('bad json at ' .. i) end
      return tonumber(num), i + #num
    end
  end
  decode = function(s)
    local ok, v = pcall(val, s or '', 1)
    if ok then return v end
  end
end
local JSON_ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function jstr(s)
  -- explicit byte ranges, not %c: MSVC's iscntrl() (REAPER on Windows) also flags some bytes >= 0x80,
  -- which split UTF-8 (Chinese) into \u00xx escapes
  return '"' .. (tostring(s):gsub('[\0-\31\127"\\]', function(c)
    return JSON_ESC[c] or string.format('\\u%04x', c:byte())
  end)) .. '"'
end

-- agent slugs, session / message / request ids go into URLs and shell lines: only [A-Za-z0-9._-], never all dots
local function idok(v)
  return type(v) == 'string' and v:match('^[A-Za-z0-9._-]+$') and not v:match('^%.+$') and v or nil
end
-- one URL path segment, percent-encoded (ids that pass idok come out unchanged)
local function seg(v)
  v = tostring(v)
  if v:match('^%.*$') then return (v:gsub('.', '%%2E')) end
  return (v:gsub('[^A-Za-z0-9._~-]', function(c) return ('%%%02X'):format(c:byte()) end))
end

---------------------------------------------------------------- http (background curl)
-- the gateway wants its token (gateway/agent_gateway.py writes it); curl reads the header from a file, not argv
local TOKEN_FILE = HOME .. '/.config/agent-gateway/token'
local AUTH_FILE, auth_token = DIR .. 'gateway-auth', nil
local function auth_args(url)
  if url:sub(1, #HOSTS[1]) ~= HOSTS[1] then return '' end
  local f = io.open(TOKEN_FILE, 'rb')
  local token = f and (f:read('*a') or ''):gsub('%s+', '') or ''
  if f then f:close() end
  if token == '' then return '' end
  if token ~= auth_token then
    -- the header is a secret: the file exists with mode 600 before the token goes in
    if not WIN then sh('umask 077; : > ' .. q(AUTH_FILE) .. '; /bin/chmod 600 ' .. q(AUTH_FILE)) end
    local h = io.open(AUTH_FILE, 'wb')
    if not h then return '' end
    h:write('Authorization: Bearer ' .. token .. '\n'); h:close()
    auth_token = token
  end
  return ' -H @' .. q(AUTH_FILE)
end
-- the run id keeps a curl left over from a closed panel from answering this run's request of the same number
local RUN = ('%x'):format(math.floor(reaper.time_precise() * 1000) % 0xFFFFFF)
local reqn, pending = 0, {}
local http_url, http_upload
do
local URL_OK = '^https?://[A-Za-z0-9.:-]+/[A-Za-z0-9._~/%%?=&-]*$' -- nothing a shell or cmd.exe would act on
local function http_line(method, url, body, cb)
  reqn = reqn + 1
  local b = DIR .. 'req' .. RUN .. '_' .. reqn
  local args = '-s -m 60 -X ' .. method .. ' -H "Content-Type: application/json"' .. auth_args(url)
  if body then
    local f = io.open(b .. '.json', 'wb')
    if not f then mkdir(); f = io.open(b .. '.json', 'wb') end
    if not f then if cb then cb(0, '') end; return end
    f:write(body); f:close()
    args = args .. ' --data-binary @' .. q(b .. '.json')
  end
  if WIN then
    win_bg(q(CURL) .. ' ' .. args .. ' -o ' .. q(b .. '.out') .. ' -w @' .. q(CURL_FMT) .. ' ' .. q(url) ..
      ' > ' .. q(b .. '.code') .. ' & move /Y ' .. q(b .. '.code') .. ' ' .. q(b .. '.done') .. ' >NUL')
  else
    sh('( /usr/bin/curl ' .. args .. ' -o ' .. q(b .. '.out') .. ' -w "%{http_code}" ' .. q(url) ..
      ' > ' .. q(b .. '.code') .. '; mv ' .. q(b .. '.code') .. ' ' .. q(b .. '.done') .. ' ) >/dev/null 2>&1 &')
  end
  pending[#pending + 1] = { b = b, cb = cb }
end
function http_url(method, url, body, cb)
  if not url:match(URL_OK) then if cb then cb(0, '') end; return end
  local ok, err = pcall(http_line, method, url, body, cb)
  if not ok and cb then cb(0, tostring(err)) end
end
-- multipart upload of a local file (curl -F), same completion files as http_url
function http_upload(url, path, cb)
  if not url:match(URL_OK) or (WIN and path:find('"', 1, true)) then if cb then cb(0, '') end; return end
  reqn = reqn + 1
  local b = DIR .. 'req' .. RUN .. '_' .. reqn
  if WIN then -- a Windows path has no quotes; curl reads file=@C:\x y.png up to the end of the argument
    win_bg(q(CURL) .. ' -s -m 300' .. auth_args(url) .. ' -F ' .. q('file=@' .. path) .. ' -o ' .. q(b .. '.out') ..
      ' -w @' .. q(CURL_FMT) .. ' ' .. q(url) .. ' > ' .. q(b .. '.code') .. ' & move /Y ' .. q(b .. '.code') .. ' ' ..
      q(b .. '.done') .. ' >NUL')
  else
    local field = 'file=@"' .. (path:gsub('\\', '\\\\'):gsub('"', '\\"')) .. '"'
    sh('( /usr/bin/curl -s -m 300' .. auth_args(url) .. ' -F ' .. q(field) .. ' -o ' .. q(b .. '.out') .. ' -w "%{http_code}" ' .. q(url) ..
      ' > ' .. q(b .. '.code') .. '; mv ' .. q(b .. '.code') .. ' ' .. q(b .. '.done') .. ' ) >/dev/null 2>&1 &')
  end
  pending[#pending + 1] = { b = b, cb = cb }
end
end

local function poll_http()
  for i = #pending, 1, -1 do
    local r = pending[i]
    local f = io.open(r.b .. '.done', 'rb')
    if f then
      local code = tonumber(f:read('*a')) or 0; f:close()
      local o = io.open(r.b .. '.out', 'rb')
      local body = o and o:read('*a') or ''
      if o then o:close() end
      os.remove(r.b .. '.done'); os.remove(r.b .. '.out'); os.remove(r.b .. '.json')
      table.remove(pending, i)
      if r.cb then r.cb(code, body) end
    end
  end
end

---------------------------------------------------------------- state
local S = {
  agent = idok(reaper.GetExtState(EXT, 'agent')) or '', agent_name = reaper.GetExtState(EXT, 'agent_name'),
  agents = {},
  sid = '', title = '',
  msgs = {}, live = {}, queued = {}, -- queued: user messages sent while a turn runs, shown after it
  active = false, waiting = false, err = nil,
  input = '', focus = true, scroll = true,
  ctx_level = math.min(tonumber(reaper.GetExtState(EXT, 'ctx_level')) or 1, 1), -- 0 off, 1 on (old 2 = detail folds into 1)
  sessions = {}, sess_at = 0,
  stream = { pid = nil, file = nil, off = 0, buf = '', check = 0 },
  cfg_opts = {}, cfg_sel = {}, perms = {}, auth = nil, acp_status = {},
  greqs = {}, greq_at = 0, gans = {}, card_h = {}, gen = 0,
  files = {}, uploading = false, -- attachments waiting to be sent: { path, name }
}
local studio -- panel/studio.lua: turn receipts, playback meter, audition rack, Ears (loaded before the first frame)
local function sval(v) return type(v) == 'string' and v or (type(v) == 'number' and tostring(v)) or nil end
local function is_acp() return S.agent:sub(1, 4) == 'acp-' end
local function via_gateway() return HOST == HOSTS[1] end
-- per-agent selector picks (model / effort / mode), stored as "id\tvalue" lines
local function cfg_load()
  S.cfg_sel = {}
  for id, v in (reaper.GetExtState(EXT, 'cfg_' .. S.agent) .. '\n'):gmatch('([^\t\n]+)\t([^\n]*)\n') do S.cfg_sel[id] = v end
end
local function cfg_save()
  local L = {}
  for id, v in pairs(S.cfg_sel) do L[#L + 1] = id .. '\t' .. v end
  reaper.SetExtState(EXT, 'cfg_' .. S.agent, table.concat(L, '\n'), true)
end
local function cfg_json()
  if not via_gateway() then return '' end
  local L = {}
  for id, v in pairs(S.cfg_sel) do L[#L + 1] = jstr(id) .. ':' .. jstr(v) end
  return ',"config":{' .. table.concat(L, ',') .. '}'
end
local function load_agent_session()
  S.sid = idok(reaper.GetExtState(EXT, 'session_' .. S.agent)) or ''
  S.title = reaper.GetExtState(EXT, 'title_' .. S.agent)
end
local function save_agent_session()
  reaper.SetExtState(EXT, 'session_' .. S.agent, S.sid, true)
  reaper.SetExtState(EXT, 'title_' .. S.agent, S.title, true)
end
if S.agent ~= '' then load_agent_session() end

local function api(path) return HOST .. '/api/agents/' .. seg(S.agent) .. path end
local function http(method, path, body, cb) http_url(method, api(path), body, cb) end
local function scroll() S.scroll = true end

-- full = the whole transcript. Otherwise only what follows the last message that is certainly final (the one
-- before the newest assistant message, which may still be updating): the gateway answers ?after=<id> with
-- {after, messages} (or {full = true, messages}); Gamut's own API ignores it and sends the whole array
local function refresh_messages(full)
  if S.sid == '' then return end
  local sid, after = S.sid, nil
  if not full then
    for i = #S.msgs, 1, -1 do
      if S.msgs[i].role == 'assistant' and S.msgs[i].id then
        for j = i - 1, 1, -1 do if S.msgs[j].id then after = idok(S.msgs[j].id); break end end
        break
      end
    end
  end
  http('GET', '/sessions/' .. seg(sid) .. '/messages' .. (after and ('?after=' .. seg(after)) or ''), nil, function(code, body)
    if code ~= 200 or sid ~= S.sid then return end
    local r = decode(body)
    if type(r) ~= 'table' then return end
    local list, keep = r, 0
    if r.messages ~= nil then
      list = type(r.messages) == 'table' and r.messages or {}
      if after and r.full ~= true and r.after == after then
        keep = nil
        for i, m in ipairs(S.msgs) do if m.id == after then keep = i end end
        if not keep then return refresh_messages(true) end
      end
    end
    local out = {}
    for _, m in ipairs(list) do
      if type(m) == 'table' then
        local role = m.type
        local text = type(m.content) == 'table' and m.content.text or (type(m.content) == 'string' and m.content) or ''
        if type(text) ~= 'string' then text = '' end
        local tools = {}
        if type(m.toolCalls) == 'table' then
          for _, tc in ipairs(m.toolCalls) do tools[#tools + 1] = type(tc) == 'table' and tc.name or nil end
        end
        if role == 'user' and text ~= '' then
          out[#out + 1] = { role = 'user', text = text, id = sval(m.id) }
        elseif role == 'assistant' and (text ~= '' or #tools > 0) then
          out[#out + 1] = { role = 'assistant', text = text, tools = tools, id = sval(m.id) }
        end
      end
    end
    local old = {}
    for i = keep + 1, #S.msgs do local m = S.msgs[i]; old[m.role .. '\0' .. m.text] = m end
    for _, m in ipairs(out) do
      local o = old[m.role .. '\0' .. m.text]
      if o then m._md, m._bubble, m._h = o._md, o._bubble, o._h end
    end
    if #S.msgs == 0 then scroll(); S.win_from = nil end
    if keep > 0 then
      local msgs = table.move(S.msgs, 1, keep, 1, {})
      S.msgs = table.move(out, 1, #out, keep + 1, msgs)
    else
      S.msgs = out
    end
    S.live, S.queued = {}, {}
  end)
end

---------------------------------------------------------------- SSE stream
-- curl carries a fixed user agent so every panel stream can be found by name, including orphans whose
-- panel died without atexit (REAPER crash / watchdog kill): they kept appending to the same file and
-- every delta showed up 2-3 times. "[c]url" keeps pkill from matching the sh -c running it.
local STREAM_UA = 'HibikiPanel'
local RUN = tostring(os.time())

-- PowerShell -EncodedCommand (UTF-16LE base64) sidesteps every layer of cmd / CreateProcess quoting
local function ps_encoded(script)
  local u = script:gsub('.', function(c) return c .. '\0' end)
  local A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  return ((u:gsub('.', function(x)
    local r, b = '', x:byte()
    for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and '1' or '0') end
    return r
  end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
    if #x < 6 then return '' end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == '1' and 2 ^ (6 - i) or 0) end
    return A:sub(c + 1, c + 1)
  end) .. ({ '', '==', '=' })[#u % 3 + 1])
end

-- every start gets its own user agent HibikiPanel/<run>.<n>; a stop kills the panel streams of other runs (orphans)
-- and this run's starts up to the current one, so a kill that lands late can never hit a stream started after it.
-- It runs in the background and the old stream files go by name: nothing on the UI thread waits for a process
local function stream_stop()
  local st = S.stream
  local max = st.starts or 0
  if WIN then
    local ps = "Get-CimInstance Win32_Process -Filter \"Name='curl.exe'\" | Where-Object { $_.CommandLine -like '*-A "
      .. STREAM_UA .. "*' -and -not ($_.CommandLine -match '" .. STREAM_UA .. "/" .. RUN .. "\\.(\\d+)' -and [int]$Matches[1] -gt "
      .. max .. ") } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
    local line = '"' .. SYS .. 'WindowsPowerShell\\v1.0\\powershell.exe" -NoProfile -NonInteractive -WindowStyle Hidden '
      .. '-EncodedCommand ' .. ps_encoded(ps)
    if HIBIKI_TEST then HIBIKI_TEST.sh(line) else reaper.ExecProcess(line, -2) end
  else
    local awk = '/[c]url -s -N -A ' .. STREAM_UA .. '/ { t = ""; if (match($0, /' .. STREAM_UA .. '\\/[0-9]+\\.[0-9]+ /)) '
      .. 't = substr($0, RSTART + ' .. (#STREAM_UA + 1) .. ', RLENGTH - ' .. (#STREAM_UA + 2) .. '); split(t, a, "."); '
      .. 'if (a[1] != run || a[2] + 0 <= max) print $1 }'
    sh('( /bin/ps -axwwo pid=,command= | /usr/bin/awk -v run=' .. RUN .. ' -v max=' .. max .. ' ' .. q(awk)
      .. ' | /usr/bin/xargs /bin/kill ) >/dev/null 2>&1 &')
  end
  for n = 1, max do
    local f = DIR .. 'stream-' .. RUN .. '-' .. n .. '.sse'
    os.remove(f); os.remove(f .. '.dead')
  end
  st.pid = nil
end

local function stream_start()
  local st = S.stream
  stream_stop()
  if S.sid == '' then return end
  st.starts = (st.starts or 0) + 1
  -- a fresh file per start: a writer that outlives its kill can't interleave into the live stream
  st.file = DIR .. 'stream-' .. RUN .. '-' .. st.starts .. '.sse'
  st.dead = st.file .. '.dead'
  local f = io.open(st.file, 'wb')
  if not f then mkdir(); f = io.open(st.file, 'wb') end
  if f then f:close() end
  st.off, st.buf, st.pos, st.cr, st.check = 0, '', 1, false, reaper.time_precise()
  -- the wrapper drops the .dead file when curl exits, so liveness is a file check, not a periodic popen (forks stall the UI)
  local url = api('/sessions/' .. seg(S.sid) .. '/stream')
  local ua = STREAM_UA .. '/' .. RUN .. '.' .. st.starts
  if WIN then
    win_bg(q(CURL) .. ' -s -N -A ' .. ua .. auth_args(url) .. ' ' .. q(url) .. ' >> ' .. q(st.file) ..
      ' & type NUL > ' .. q(st.dead))
    st.pid = 0 -- launched; Windows has no pid here (stream_stop finds the curl by its user agent)
    return
  end
  local out = sh('( /usr/bin/curl -s -N -A ' .. ua .. auth_args(url) .. ' ' .. q(url) ..
    ' >> ' .. q(st.file) .. '; : > ' .. q(st.dead) .. ' ) >/dev/null 2>&1 & echo $!')
  st.pid = tonumber(out:match('%d+'))
end

local function tool_label(name)
  if type(name) ~= 'string' then return 'tool' end
  return (name:gsub('^mcp__[%w_-]-__', ''))
end

-- Gamut's agent deep link (SuperAgent src/main/agent-deep-link.ts) focuses the app on this exact session
-- an ACP chat reopens in its own CLI (claude --resume / kimi --session; the gateway builds the line): a .command
-- file opened with Terminal needs no Automation permission, unlike scripting Terminal through osascript
local function open_in_terminal(cmd)
  if WIN then -- a .cmd file in a new console window (cmd /K keeps it open after the CLI exits)
    os.remove(DIR .. 'resume.cmd')
    local f = io.open(DIR .. 'resume.cmd', 'wb')
    if not f then return end
    f:write('@echo off\r\n', cmd, '\r\n')
    f:close()
    win_bg('start "Hibiki" ' .. q(SYS .. 'cmd.exe') .. ' /D /K ' .. q(DIR .. 'resume.cmd'))
    return
  end
  os.remove(DIR .. 'resume.command') -- a fresh file in the private dir, never one that was there before
  local f = io.open(DIR .. 'resume.command', 'w')
  if not f then return end
  f:write('#!/bin/sh\n', cmd, '\n')
  f:close()
  sh('/bin/chmod 700 ' .. q(DIR .. 'resume.command') .. ' && /usr/bin/open -a Terminal ' .. q(DIR .. 'resume.command') .. ' >/dev/null 2>&1 &')
end

local function open_in_gamut()
  if WIN then -- the deep link opens Gamut (and the chat when there is one)
    win_bg('start "" ' .. q('superagent://' .. ((idok(S.agent) and idok(S.sid)) and ('agent/' .. S.agent .. '/sessions/' .. S.sid) or '')))
    return
  end
  if idok(S.agent) and idok(S.sid) then
    sh('/usr/bin/open ' .. q('superagent://agent/' .. S.agent .. '/sessions/' .. S.sid) .. ' >/dev/null 2>&1 &')
  else
    sh('/usr/bin/open -a Gamut >/dev/null 2>&1 &')
  end
end

-- events that mean the turn is still running (after a session_error: Gamut recovered the runtime)
-- a session_error'd turn: Gamut may recover the runtime and stream on (one table: the main chunk is at Lua's
-- 200-local limit). wait: seconds it may still resume; resume: events that mean the turn is still running.
local ERR = { wait = 120, resume = { session_active = true, stream_start = true, message_start = true,
  stream_delta = true, tool_use_ready = true, permission_request = true } }

-- an errored turn that never resumed: close it so its changes still get a Version history title
function ERR.settle()
  if not S.err_turn then return end
  S.err_turn = nil
  if studio then
    local said = {}
    for _, b in ipairs(S.live) do if b.kind == 'text' then said[#said + 1] = b.text end end
    studio.turn_end(table.concat(said))
  end
end

local function on_event(d)
  local t = d.type
  if S.err_turn and ERR.resume[t] then
    S.live[#S.live + 1] = { kind = 'tool', text = '⚠ ' .. (S.err or 'error') .. ' (resumed)' }
    S.err, S.err_turn, S.active = nil, nil, true
  end
  if t == 'connected' then
    S.active = d.isActive == true
    -- the gateway replays an ACP turn in progress right after this event; start the live view from that replay
    if S.active and is_acp() then S.live = {} end
    -- a turn that ended while we weren't subscribed (late first subscribe, reconnect) only shows in the transcript
    if not S.active then refresh_messages(true) end
  elseif t == 'session_active' and #S.queued > 0 and #S.live > 0 then
    -- the gateway starts a queued message: settle the previous reply above it
    local text, tools = {}, {}
    for _, b in ipairs(S.live) do
      if b.kind == 'text' then text[#text + 1] = b.text else tools[#tools + 1] = b.text end
    end
    S.msgs[#S.msgs + 1] = { role = 'assistant', text = table.concat(text), tools = tools }
    S.msgs[#S.msgs + 1] = table.remove(S.queued, 1)
    S.live, S.active = {}, true
  elseif t == 'stream_start' or t == 'message_start' or t == 'session_active' then
    S.active = true
  elseif t == 'stream_delta' then
    if type(d.text) == 'string' then
      local last = S.live[#S.live]
      if not last or last.kind ~= 'text' then last = { kind = 'text', text = '' }; S.live[#S.live + 1] = last end
      last.text = last.text .. d.text
      S.active = true
    end
  elseif t == 'tool_use_ready' then
    S.live[#S.live + 1] = { kind = 'tool', text = tool_label(d.toolName) }
  elseif t == 'session_awaiting_input' then
    S.waiting = true
    S.greq_at = 0 -- frame() fetches the pending requests and draws them as cards
  elseif t == 'permission_request' then
    local rid = sval(d.requestId)
    if not rid then return end
    for _, p in ipairs(S.perms) do if p.id == rid then return end end
    S.perms[#S.perms + 1] = { id = rid, title = sval(d.title) or 'Run tool',
      options = type(d.options) == 'table' and d.options or {} }
    scroll()
  elseif t == 'permission_resolved' then
    for i = #S.perms, 1, -1 do if S.perms[i].id == d.requestId then table.remove(S.perms, i) end end
  elseif t == 'config_options' then
    if type(d.configOptions) == 'table' then S.cfg_opts = d.configOptions end
  elseif t == 'notice' then
    S.live[#S.live + 1] = { kind = 'tool', text = sval(d.text) or '' }
  elseif t == 'session_input_provided' then
    S.greq_at = 0
  elseif t == 'user_request_created' then
    -- Gamut ships the whole request (question / secret / review) in the event
    local q = type(d.request) == 'table' and d.request
    local scope = q and type(q.scope) == 'table' and q.scope or {}
    if q and idok(q.id) and sval(q.kind) and q.autoApproved ~= true
        and (sval(scope.sessionId) == nil or scope.sessionId == S.sid) then
      q.payload = type(q.payload) == 'table' and q.payload or {}
      for i = #S.greqs, 1, -1 do if S.greqs[i].id == q.id then table.remove(S.greqs, i) end end
      S.greqs[#S.greqs + 1] = q
      S.waiting = true
      scroll()
    end
  elseif t == 'user_request_resolved' then
    for i = #S.greqs, 1, -1 do if S.greqs[i].id == d.requestId then table.remove(S.greqs, i) end end
    if sval(d.requestId) then S.gans[sval(d.requestId)] = nil end
    if #S.greqs == 0 then S.waiting = false end
  elseif t == 'session_idle' then
    S.active, S.waiting, S.perms, S.err_turn = false, false, {}, nil
    if studio then -- the reply's own words become its title in Version history
      local said = {}
      for _, b in ipairs(S.live) do if b.kind == 'text' then said[#said + 1] = b.text end end
      studio.turn_end(table.concat(said))
    end
    refresh_messages()
    local now = reaper.time_precise()
    S.title_checks = { now + 2, now + 12 } -- Gamut names a chat in the background after its first turn
  elseif t == 'session_updated' then
    S.title_checks = { reaper.time_precise() }
  elseif t == 'session_error' then
    -- Gamut recovers a runtime that died mid-turn and the same turn streams on, so the reply stays open
    -- (studio turn, live view) until session_idle, more activity, or ERR.settle() gives up on it
    S.active, S.perms = false, {}
    if d.apiErrorCode == 'auth_required' and is_acp() then S.auth = S.auth or { methods = {} } end
    local p = d.errorPresentation
    local msg = (type(p) == 'table' and (sval(p.message) or sval(p.title))) or sval(d.error)
    local code = sval(d.apiErrorCode) or sval(d.terminalReason)
      or (tonumber(d.apiErrorStatus) and ('HTTP ' .. math.floor(d.apiErrorStatus)))
    S.err = (msg and code and not msg:find(code, 1, true)) and (msg .. ' (' .. code .. ')') or msg or code or 'error'
    S.err_turn = reaper.time_precise()
    refresh_messages()
  end
end

-- SSE: events end at a blank line. One pass with a read position over the buffer, at most 400 events a frame
-- (a long replay drains over several frames); \r\n is normalised on each new chunk only, the buffer is cut once
local function poll_stream()
  local st = S.stream
  if not st.file then return end
  local pos = st.pos or 1
  if pos == 1 then -- no backlog left from the last frame: read what curl appended
    local f = io.open(st.file, 'rb')
    if f then
      f:seek('set', st.off)
      local chunk = f:read('*a') or ''
      f:close()
      if #chunk > 0 then
        st.fails = 0
        st.off = st.off + #chunk
        if st.cr then chunk = '\r' .. chunk; st.cr = false end
        if chunk:byte(-1) == 13 then chunk = chunk:sub(1, -2); st.cr = true end -- its \n may come with the next read
        if chunk:find('\r', 1, true) then chunk = chunk:gsub('\r\n', '\n') end
        st.buf = st.buf .. chunk
      end
    end
  end
  local buf, n = st.buf, 0
  while n < 400 do
    local e = buf:find('\n\n', pos, true)
    if not e then break end
    local data
    local p = pos
    while p < e do
      local le = buf:find('\n', p, true)
      if not le or le > e then le = e end
      if buf:sub(p, p + 4) == 'data:' then
        local v = buf:sub(buf:byte(p + 5) == 32 and p + 6 or p + 5, le - 1)
        data = data and (data .. '\n' .. v) or v
      end
      p = le + 1
    end
    pos, n = e + 2, n + 1
    local d = data and decode(data)
    if type(d) == 'table' then on_event(d) end
    if st.buf ~= buf then return end -- on_event restarted the stream
  end
  if n < 400 then
    if pos > 1 then st.buf = buf:sub(pos) end
    st.pos = 1
  else
    st.pos = pos
  end
  local now = reaper.time_precise()
  -- 3 s, doubling up to 60 s while the stream keeps dying (host down, session deleted): no fork storm
  if S.sid ~= '' and now - st.check > math.min(60, 3 * 2 ^ (st.fails or 0)) then
    st.check = now
    local dead = st.dead and io.open(st.dead, 'rb')
    if dead then dead:close(); os.remove(st.dead) end
    if not st.pid or dead then
      st.fails = (st.fails or 0) + 1
      stream_start()
    end
  end
end

---------------------------------------------------------------- REAPER context
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

---------------------------------------------------------------- actions
local ime_cb -- created with the ImGui context below; send() clears the input through it
local function utf8_prefix(str, n)
  local cut = utf8.offset(str, n + 1)
  return cut and str:sub(1, cut - 1) or str
end

-- typed/files: what the user entered, handed back if the send fails
local function deliver(payload, text, typed, files)
  local bubble = { role = 'user', text = payload }
  local queued = S.active and S.sid ~= ''
  ERR.settle()
  if studio then studio.turn_start(queued) end
  if queued then
    S.queued[#S.queued + 1] = bubble -- the reply in progress stays above it
  else
    S.msgs[#S.msgs + 1] = bubble
    S.live = {}
  end
  S.err, S.input, S.focus, S.active = nil, '', true, true
  scroll()
  local gen = S.gen
  local function failed(err)
    S.err = err
    if not queued then S.active = false end -- a queued send failing doesn't end the turn that is running
    for _, list in ipairs({ S.msgs, S.queued }) do
      for i = #list, 1, -1 do if list[i] == bubble then table.remove(list, i) end end
    end
    if S.input == '' then S.input = typed or '' end
    if files and #S.files == 0 then S.files = files end
  end
  if S.sid == '' then
    S.creating = true
    local title = via_gateway() and (',"title":' .. jstr(utf8_prefix(text, 60))) or ''
    http('POST', '/sessions', '{"message":' .. jstr(payload) .. title .. cfg_json() .. '}', function(code, body)
      local r = decode(body)
      if gen ~= S.gen then return end -- the user switched agent/session meanwhile
      S.creating = false
      if code >= 200 and code < 300 and type(r) == 'table' and idok(r.id) then
        S.sid = r.id
        S.title = utf8_prefix(text, 60)
        save_agent_session()
        stream_start()
      elseif code == 401 and is_acp() then
        S.auth = S.auth or { methods = {} }
        failed((S.agent_name ~= '' and S.agent_name or S.agent) .. ' needs a login first')
      else
        failed(('create session failed (%d)'):format(code))
      end
    end)
  else
    if not S.stream.file then stream_start() end -- the boot-time restore never ran (hosts were down then)
    http('POST', '/sessions/' .. seg(S.sid) .. '/messages', '{"content":' .. jstr(payload) .. cfg_json() .. '}', function(code)
      if gen ~= S.gen then return end
      if code < 200 or code >= 300 then failed(('send failed (%d)'):format(code)) end
    end)
  end
end

local function send()
  if S.agent == '' then return end
  if S.sid == '' and S.creating then return end -- the first message is still opening the session
  local text = S.input:gsub('^%s+', ''):gsub('%s+$', '')
  if text == '' and #S.files == 0 then return end
  if S.uploading then return end
  -- a still-active InputText keeps its own buffer and hands the old text back next frame, so a quick second
  -- Enter (or key repeat) re-sent it; the composer clears ImGui's buffer next frame (S.clear_input) and exact
  -- repeats are dropped here
  S.clear_input = true
  local now = reaper.time_precise()
  if #S.files == 0 and text == S.last_sent and now - (S.last_sent_at or 0) < 2 then S.input = ''; return end
  if studio and #S.files == 0 and studio.command(text) then S.input = ''; return end
  S.last_sent, S.last_sent_at = text, now
  local payload = text
  if S.ctx_level > 0 then
    local ctx_text = context(true)
    payload = CTX_OPEN .. '\n' .. CTX_NOTE .. '\n' .. ctx_text .. '\n' .. CTX_CLOSE .. '\n\n' .. text
  elseif studio and studio.take_ears then -- Context off: an Ears summary still goes with the message its files go with
    local e = studio.take_ears()
    if e then payload = CTX_OPEN .. '\n' .. e .. '\n' .. CTX_CLOSE .. '\n\n' .. text end
  end
  if #S.files == 0 then return deliver(payload, text, text) end
  -- upload the attachments first, then send the message with Gamut's "[Attached files:]" block
  local files = S.files
  S.files, S.uploading, S.input, S.err = {}, #files, '', nil
  local gen, paths, failed = S.gen, {}, {}
  local url = api(S.sid ~= '' and ('/sessions/' .. seg(S.sid) .. '/upload-file') or '/upload-file')
  for n, f in ipairs(files) do
    http_upload(url, f.path, function(code, body)
      if gen ~= S.gen then return end
      local r = decode(body)
      if code >= 200 and code < 300 and type(r) == 'table' and sval(r.path) then paths[n] = r.path
      else failed[#failed + 1] = f.name end
      S.uploading = S.uploading - 1
      if S.uploading > 0 then return end
      S.uploading = false
      if #failed > 0 then -- hand everything back so nothing is lost
        S.err = 'Upload failed: ' .. table.concat(failed, ', ')
        S.files, S.input = files, text
        return
      end
      local lines = {}
      for m = 1, #files do lines[#lines + 1] = '- ' .. paths[m] end
      deliver(payload .. (payload ~= '' and '\n\n' or '') .. '[Attached files:]\n' .. table.concat(lines, '\n'),
        text ~= '' and text or files[1].name, text, files)
    end)
  end
end

local function stop()
  if S.sid ~= '' then http('POST', '/sessions/' .. seg(S.sid) .. '/interrupt', '{}') end
end

local function reset_view()
  stream_stop()
  S.gen = S.gen + 1 -- late callbacks from the previous view check this and drop their result
  if S.active and studio then studio.turn_end() end -- the abandoned reply's changes still get their card
  ERR.settle()
  S.msgs, S.live, S.queued, S.active, S.err, S.waiting, S.sessions, S.sess_at = {}, {}, {}, false, nil, false, {}, 0
  S.win_from = nil
  S.perms, S.greqs, S.gans, S.card_h, S.creating, S.cfg_pending = {}, {}, {}, {}, false, false
  S.last_sent, S.last_sent_at = nil, nil
  S.stream.fails = 0
  S.uploading = false
end

local function new_chat()
  reset_view()
  S.sid, S.title = '', ''
  save_agent_session()
  S.focus = true
end

local function iso_age(iso)
  local y, mo, d, h, mi, se = tostring(iso):match('(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
  if not y then return '' end
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h),
    min = tonumber(mi), sec = tonumber(se), isdst = false })
  local a = os.time(os.date('!*t')) - t
  local at = os.time() - a -- back to a local epoch: a clock time, not an age that ticks
  return os.date(os.date('%Y%m%d', at) == os.date('%Y%m%d') and '%H:%M' or '%m-%d', at)
end

local function load_sessions()
  S.sess_at = reaper.time_precise()
  local agent = S.agent
  http('GET', '/sessions', nil, function(code, body)
    if code ~= 200 or agent ~= S.agent then return end
    local list = decode(body)
    if type(list) ~= 'table' then return end
    if list.sessions then list = list.sessions end
    local out = {}
    for _, x in ipairs(list) do
      if idok(x.id) then
        out[#out + 1] = { id = x.id, name = type(x.name) == 'string' and x.name or x.id:sub(1, 8),
          age = iso_age(x.lastActivityAt), active = x.isActive == true,
          resume = type(x.resume) == 'string' and x.resume or nil }
        if x.id == S.sid and type(x.name) == 'string' and x.name ~= '' and x.name ~= S.title then
          S.title = x.name
          save_agent_session()
        end
      end
    end
    S.sessions = out
  end)
end

local load_config, load_requests
local function load_agents(try)
  try = try or 1
  local host = HOSTS[try]
  http_url('GET', host .. '/api/agents', nil, function(code, body)
    if code ~= 200 then
      if try < #HOSTS then return load_agents(try + 1) end
      S.agents_err = 'Agent gateway and Gamut not reachable (' .. code .. ')'
      return -- S.boot stays set: the next successful load reopens the saved session
    end
    local list = decode(body)
    if type(list) ~= 'table' then return end
    if list.agents then list = list.agents end
    local changed = host ~= HOST
    HOST = host
    local out = {}
    for _, a in ipairs(list) do
      if idok(a.slug) then
        out[#out + 1] = { slug = a.slug, name = type(a.name) == 'string' and a.name or a.slug,
          desc = type(a.description) == 'string' and a.description or '', acp = a.backend == 'acp',
          status = type(a.status) == 'string' and a.status or nil }
      end
    end
    S.agents, S.agents_err = out, nil
    if (changed or not S.cfg_loaded) and S.agent ~= '' then load_config() end
    if S.boot then
      S.boot = false -- the saved session is reopened once we know which host answers
      if S.sid ~= '' then stream_start(); refresh_messages(true); load_requests() end
    end
  end)
end

-- ACP agent status for the picker dots and the login card; probe = true: cheap check (binary + last login state),
-- probe = 'start': the gateway starts this agent to find out (?probe=<slug>)
local function load_acp_status(slug, probe)
  if not via_gateway() or slug:sub(1, 4) ~= 'acp-' then return end
  if slug == S.agent then S.auth_at = reaper.time_precise() end
  http_url('GET', HOST .. '/api/agents/' .. seg(slug) .. '/status' .. (probe == 'start' and ('?probe=' .. seg(slug)) or (probe and '?probe=1' or '')), nil, function(code, body)
    local r = decode(body)
    if code ~= 200 or type(r) ~= 'table' then return end
    local err = sval(r.error)
    local st = { state = sval(r.state) or '', connected = r.connected == true, err = err,
      methods = type(r.authMethods) == 'table' and r.authMethods or {} }
    S.acp_status[slug] = st
    if slug ~= S.agent then return end
    if st.connected then
      if S.auth then S.auth, S.err = nil, nil end
      if #S.cfg_opts == 0 and not S.cfg_pending then load_config() end
    elseif st.state == 'auth_required' then
      local waiting = S.auth and S.auth.waiting and err == nil
      S.auth = { methods = st.methods, err = err, waiting = waiting, terminal = S.auth and S.auth.terminal }
    elseif st.state == 'authenticating' then
      S.auth = S.auth or { methods = st.methods }
      S.auth.waiting = true
    end
  end)
end
local function load_status() if is_acp() then load_acp_status(S.agent, false) end end

function load_config()
  S.cfg_loaded = true
  S.cfg_opts = {}
  if not via_gateway() or S.agent == '' then return end
  local agent = S.agent
  S.cfg_pending = true
  http('GET', '/config', nil, function(code, body)
    if agent == S.agent then S.cfg_pending = false end
    if agent ~= S.agent then return end
    local r = decode(body)
    if code == 200 and type(r) == 'table' and type(r.configOptions) == 'table' then
      S.cfg_opts = r.configOptions
    elseif code == 401 and is_acp() then
      S.auth = S.auth or { methods = {} }
      load_status()
    end
  end)
end

local function answer_perm(p, option_id)
  for i = #S.perms, 1, -1 do if S.perms[i] == p then table.remove(S.perms, i) end end
  local opt = option_id and jstr(option_id) or 'null'
  http('POST', '/sessions/' .. seg(S.sid) .. '/permission', '{"requestId":' .. jstr(p.id) .. ',"optionId":' .. opt .. '}')
end

-- Gamut's pending user-input requests (questions, secrets, approvals) for the open session
function load_requests()
  S.greq_at = reaper.time_precise()
  if S.agent == '' or is_acp() or S.sid == '' then S.greqs = {}; return end
  local agent, sid = S.agent, S.sid
  http('GET', '/pending-requests?sessionId=' .. seg(sid), nil, function(code, body)
    if agent ~= S.agent or sid ~= S.sid or code ~= 200 then return end
    local r = decode(body)
    local list = type(r) == 'table' and r.requests
    local out = {}
    if type(list) == 'table' then
      for _, req in ipairs(list) do
        if type(req) == 'table' and idok(req.id) and sval(req.kind) and req.autoApproved ~= true then
          req.payload = type(req.payload) == 'table' and req.payload or {}
          out[#out + 1] = req
        end
      end
    end
    -- merge: events are the source of truth (user_request_resolved removes cards); this only fills in
    -- requests created before the stream connected
    for _, req in ipairs(out) do
      local known = false
      for _, old in ipairs(S.greqs) do if old.id == req.id then known = true end end
      if not known then S.greqs[#S.greqs + 1] = req end
    end
    if #S.greqs > 0 then S.waiting = true end
  end)
end

local function answer_request(req, path, body)
  req.sending, req.err = true, nil
  local gen = S.gen
  http('POST', path, body, function(code, resp)
    req.sending = false
    if gen ~= S.gen then return end
    if code >= 200 and code < 300 then
      for i = #S.greqs, 1, -1 do if S.greqs[i] == req then table.remove(S.greqs, i) end end
      S.gans[req.id] = nil
      load_requests()
    else
      local r = decode(resp)
      req.err = (type(r) == 'table' and sval(r.error)) or ('failed (' .. code .. ')')
    end
  end)
end

local function start_login(method_id, terminal)
  S.auth = S.auth or { methods = {} }
  S.auth.waiting, S.auth.err, S.auth.terminal = true, nil, terminal
  http('POST', '/auth', '{"methodId":' .. jstr(method_id) .. '}', function() load_status() end)
end

local function switch_session(id, name)
  if id == S.sid or not idok(id) then return end
  reset_view()
  S.sid, S.title = id, name or ''
  save_agent_session()
  stream_start()
  refresh_messages(true)
  load_requests()
  S.focus = true
end

local ONB = { installable = nil, inst_at = 0, reaper = {}, busy = {} } -- onboarding, filled in below
local function choose_agent(slug, name)
  if not idok(slug) then return end
  if slug:sub(1, 4) ~= 'acp-' then reaper.SetExtState(EXT, 'gamut_agent', slug, true) end
  if slug == S.agent then return end
  reset_view()
  if ONB.reaper[slug] then ONB.reaper[slug].stale = true end
  S.agent, S.agent_name = slug, name
  reaper.SetExtState(EXT, 'agent', slug, true)
  reaper.SetExtState(EXT, 'agent_name', name, true)
  load_agent_session()
  cfg_load()
  S.auth = nil
  load_config()
  if is_acp() then load_acp_status(S.agent, 'start') end
  if S.sid ~= '' then stream_start(); refresh_messages(true); load_requests() end
  S.focus = true
end

---------------------------------------------------------------- onboarding: install a CLI agent, enable REAPER in Gamut
-- one table (the main chunk is near Lua's 200-local limit); all of it goes through the gateway's /api/hibiki routes
do
  local GW_ = HOSTS[1]
  ONB.gamut_url = WIN and 'https://updates.gamutagents.com/download/win' or 'https://updates.gamutagents.com/download/mac'
  function ONB.open_url(url)
    if WIN then win_bg('start "" ' .. q(url)) else sh('/usr/bin/open ' .. q(url) .. ' >/dev/null 2>&1 &') end
  end
  -- installable = nil (not asked yet), false (gateway not answering) or the list
  function ONB.load_installable()
    ONB.inst_at = reaper.time_precise()
    http_url('GET', GW_ .. '/api/hibiki/installable', nil, function(code, body)
      local list = code == 200 and decode(body)
      if type(list) ~= 'table' then ONB.installable = false; return end
      local was = ONB.installing
      ONB.installing = nil
      for _, x in ipairs(list) do if x.state == 'installing' then ONB.installing = x.key end end
      ONB.installable = list
      for _, x in ipairs(list) do -- just finished: show it, select it, open its settings for the login
        if was and x.key == was and x.installed then ONB.just = { slug = x.slug, name = x.name }; load_agents() end
      end
    end)
  end
  function ONB.install(key)
    ONB.installing, ONB.err = key, nil
    http_url('POST', GW_ .. '/api/hibiki/install', '{"agent":' .. jstr(key) .. '}', function(code, body)
      if code ~= 202 then
        local r = decode(body)
        ONB.installing, ONB.err = nil, (type(r) == 'table' and sval(r.error)) or ('install failed (' .. code .. ')')
      end
      ONB.load_installable()
    end)
  end
  function ONB.tick()
    local now = reaper.time_precise()
    if ONB.installable == nil or now - ONB.inst_at > (ONB.installing and 2 or 30) then ONB.load_installable() end
    if ONB.just then
      for _, a in ipairs(S.agents) do
        if a.slug == ONB.just.slug then
          choose_agent(a.slug, a.name)
          S.cfgwin, ONB.just = true, nil
          load_acp_status(a.slug, 'start')
          break
        end
      end
    end
  end
  function ONB.load_reaper(slug)
    local e = ONB.reaper[slug] or {}
    ONB.reaper[slug] = e
    e.at, e.stale, e.loading = reaper.time_precise(), nil, true
    http_url('GET', GW_ .. '/api/hibiki/gamut-reaper?agent=' .. seg(slug), nil, function(code, body)
      e.loading = nil
      local r = code == 200 and decode(body)
      if type(r) == 'table' then ONB.reaper[slug] = { enabled = r.enabled == true, registered = r.registered == true,
        at = reaper.time_precise() } end
    end)
  end
  -- Gamut agents only: true / false once known, nil while unknown (or no gateway). Once enabled it is not asked
  -- again until Settings opens or the agent changes (stale); while off it is re-read every 15 s
  function ONB.reaper_enabled(slug)
    local r = ONB.reaper[slug]
    if not r or (r.stale and not r.loading) or (r.enabled ~= true and not r.loading and reaper.time_precise() - (r.at or 0) > 15) then
      ONB.load_reaper(slug)
    end
    return r and r.enabled
  end
  function ONB.enable_reaper(slug)
    ONB.busy[slug] = true
    http_url('POST', GW_ .. '/api/hibiki/gamut-reaper', '{"agent":' .. jstr(slug) .. '}', function(code, body)
      ONB.busy[slug] = nil
      local r = decode(body)
      if code ~= 200 then ONB.err = (type(r) == 'table' and sval(r.error)) or ('Gamut refused (' .. code .. ')') end
      ONB.load_reaper(slug)
    end)
  end
end

---------------------------------------------------------------- recover: the "it froze, retry" key
-- local part: interrupt, stop the stream, drop pending requests; then `hibiki recover --json` in the background
-- (result polled like a request), then hosts, the open chat and the stream come back through the boot path
local REC = { running = false }
do
  local function step_line(x)
    if type(x) ~= 'table' then return nil end
    local name = sval(x.name) or sval(x.step) or sval(x.title) or sval(x.id) or 'step'
    local ok = x.ok
    if type(ok) ~= 'boolean' then
      local st = (sval(x.status) or sval(x.state) or ''):lower()
      ok = st == 'ok' or st == 'done' or st == 'pass' or st == 'passed' or st == 'success' or st == 'skipped'
    end
    local d = sval(x.detail) or sval(x.message) or sval(x.msg) or sval(x.error) or ''
    return { ok = ok, text = (ok and '✓ ' or '✗ ') .. name .. (d ~= '' and (' — ' .. d) or '') }
  end
  local function finished(code, body)
    REC.running = false
    local r = decode(body)
    local list = type(r) == 'table' and (type(r.steps) == 'table' and r.steps or (r[1] ~= nil and r) or nil)
    local lines = {}
    for _, x in ipairs(list or {}) do lines[#lines + 1] = step_line(x) end
    if #lines == 0 and type(r) == 'table' and type(r.ok) == 'boolean' then
      lines[1] = { ok = r.ok, text = (r.ok and '✓ ' or '✗ ') .. (sval(r.message) or sval(r.error) or 'hibiki recover') }
    end
    if #lines == 0 then
      REC.lines = { { ok = true, text = 'Restarted the connection; run `hibiki recover` in Terminal for a full reset' } }
    else
      REC.lines = lines
    end
    REC.code = code
    S.boot = true -- the next answer from a host reopens the chat: full transcript + stream
    load_agents()
  end
  function REC.start()
    if REC.running then return end
    for i = #pending, 1, -1 do
      local r = pending[i]
      os.remove(r.b .. '.done'); os.remove(r.b .. '.out'); os.remove(r.b .. '.json')
      pending[i] = nil
    end
    if S.active and S.sid ~= '' then stop() end
    stream_stop()
    S.gen = S.gen + 1
    if S.active and studio then studio.turn_end() end -- the abandoned reply's changes still get their card
    ERR.settle()
    S.active, S.waiting, S.perms, S.err, S.creating, S.uploading = false, false, {}, nil, false, false
    REC.running, REC.lines, REC.at = true, nil, reaper.time_precise()
    REC.job = REC.cli('recover', 'recover --json', finished)
  end
  -- `hibiki use dev`: run the checkout's CLI with the recorded Python. An installed CLI older than dev mode (0.5.0)
  -- neither forwards nor knows the newer commands (update, ears), so the panel goes to the checkout itself
  local function dev_cli()
    local f = io.open(HOME .. '/.config/reaper-mcp/mode.json', 'rb')
    if not f then return nil end
    local m = decode(f:read('*a') or '')
    f:close()
    if type(m) ~= 'table' or m.mode ~= 'dev' or type(m.path) ~= 'string' or type(m.python) ~= 'string' then return nil end
    local cli = m.path .. '/reaper_mcp/cli.py'
    for _, path in ipairs({ cli, m.python }) do
      local g = io.open(path, 'rb')
      if not g then return nil end
      g:close()
    end
    return q(m.python) .. ' -s -E ' .. q(cli)
  end
  function REC.cli(name, args, cb)
    reqn = reqn + 1
    local b = DIR .. name .. RUN .. '_' .. reqn
    local out, code, done = q(b .. '.out'), q(b .. '.code'), q(b .. '.done')
    if WIN then
      local exe = (os.getenv('LOCALAPPDATA') or (HOME .. '\\AppData\\Local')) .. '\\Programs\\Hibiki\\bin\\hibiki.cmd'
      local ok, line = pcall(function()
        return '(if exist ' .. q(exe) .. ' (call ' .. q(exe) .. ' ' .. args .. ' > ' .. out .. ' 2>NUL && (> ' .. code
          .. ' echo 0) || (> ' .. code .. ' echo 1)) else (call hibiki ' .. args .. ' > ' .. out .. ' 2>NUL && (> ' .. code
          .. ' echo 0) || (> ' .. code .. ' echo 127))) & move /Y ' .. code .. ' ' .. done .. ' >NUL'
      end)
      if not ok then cb(127, ''); return nil end
      win_bg(line)
    elseif dev_cli() then
      sh('( ' .. dev_cli() .. ' ' .. args .. ' > ' .. out .. ' 2>/dev/null; echo $? > ' .. code .. '; /bin/mv ' .. code .. ' '
        .. done .. ' ) >/dev/null 2>&1 &')
    else
      sh('( for h in /usr/local/bin/hibiki "$HOME/.local/bin/hibiki" "$(command -v hibiki)"; do [ -n "$h" ] && [ -x "$h" ] '
        .. '&& break; h=; done; if [ -n "$h" ]; then "$h" ' .. args .. ' > ' .. out .. ' 2>/dev/null; echo $? > ' .. code
        .. '; else echo 127 > ' .. code .. '; fi; /bin/mv ' .. code .. ' ' .. done .. ' ) >/dev/null 2>&1 &')
    end
    local job = { b = b, cb = cb }
    pending[#pending + 1] = job
    return job
  end
  function REC.tick() -- a CLI that never returns must not leave the button disabled
    if not REC.running or reaper.time_precise() - REC.at < 180 then return end
    for i = #pending, 1, -1 do if pending[i] == REC.job then table.remove(pending, i) end end
    finished(124, '')
  end
end

---------------------------------------------------------------- update: `hibiki update` in the background
local UPD = {}
do
  local DAY = 24 * 3600
  local MON = { 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec' }
  local function ext(k) return reaper.GetExtState(EXT, 'upd_' .. k) end
  local function put(k, v) reaper.SetExtState(EXT, 'upd_' .. k, v or '', true) end
  local function opt(v) return v ~= '' and v or nil end
  UPD.current, UPD.latest, UPD.published = opt(ext('current')), opt(ext('latest')), opt(ext('published'))
  UPD.available, UPD.checked = ext('available') == '1', ext('at') ~= ''
  function UPD.date()
    local m, d = tostring(UPD.published or ''):match('^%d+%-(%d+)%-(%d+)')
    if not m then return nil end
    return (MON[tonumber(m)] or m) .. ' ' .. tonumber(d)
  end
  function UPD.dev()
    local v = ext('dev')
    if v ~= '' then return v == '1' end
    return (UPD.current or ''):find('-', 1, true) ~= nil
  end
  local function failed(code, r)
    if type(r) == 'table' and sval(r.error) then return sval(r.error) end
    if code == 127 then return 'hibiki command not found; reinstall Hibiki' end
    if code == 124 then return 'hibiki update did not answer' end
    return 'hibiki update failed' .. ((code or 0) ~= 0 and (' (exit ' .. code .. ')') or '')
  end
  local function take(r)
    UPD.current = sval(r.current) or UPD.current
    UPD.latest, UPD.published = sval(r.latest), sval(r.published)
    UPD.available, UPD.checked = r.update_available == true, true
    put('current', UPD.current); put('latest', UPD.latest); put('published', UPD.published)
    put('available', UPD.available and '1' or '0')
  end
  local function ok_body(r) return type(r) == 'table' and r.error == nil and sval(r.current) ~= nil end
  local function checked(code, body)
    UPD.running, UPD.job = nil, nil
    local r = decode(body)
    if not ok_body(r) then UPD.err = failed(code, r); return end
    UPD.err = nil
    take(r)
    put('at', tostring(os.time()))
  end
  local function installed(code, body)
    UPD.running, UPD.job = nil, nil
    local r = decode(body)
    if not ok_body(r) then UPD.err = failed(code, r); return end
    UPD.err = nil
    take(r)
    if type(r.launched) == 'table' then
      UPD.msg = WIN and 'Installer opened — finish it, then restart REAPER'
        or 'Installer opened — finish it in the Installer window, then restart REAPER'
      put('at', '')
    else
      UPD.msg = 'Up to date'
    end
  end
  function UPD.start(kind)
    if UPD.running then return end
    UPD.running, UPD.at, UPD.err, UPD.msg = kind, reaper.time_precise(), nil, nil
    local v = ext('dev')
    local args = 'update --' .. kind .. ' --json' .. (v == '1' and ' --channel dev' or (v == '0' and ' --channel stable' or ''))
    UPD.job = REC.cli('update', args, kind == 'install' and installed or checked)
  end
  function UPD.set_dev(on)
    put('dev', on and '1' or '0')
    put('at', '')
    if not UPD.running then UPD.start('check') end
  end
  function UPD.auto()
    if not UPD.running and os.time() - (tonumber(ext('at')) or 0) >= DAY then UPD.start('check') end
  end
  function UPD.tick()
    if not UPD.running then return end
    local live = false
    for _, j in ipairs(pending) do if j == UPD.job then live = true end end
    if live and reaper.time_precise() - UPD.at < (UPD.running == 'install' and 900 or 60) then return end
    for i = #pending, 1, -1 do if pending[i] == UPD.job then table.remove(pending, i) end end
    local fin = UPD.running == 'install' and installed or checked
    fin(124, '')
  end
end

---------------------------------------------------------------- UI setup
local ctx = ImGui.CreateContext('Hibiki') -- the panel's name (docker tab)
local function font_file(path, index)
  local f = io.open(path, 'rb')
  if not f then return nil end
  f:close()
  return ImGui.CreateFontFromFile(path, index or 0)
end
-- CJK (and everything the theme font lacks): PingFang SC, macOS's own UI face for Chinese. It lives in a
-- versioned asset folder, so it's loaded by family name; ReaImGui resolves that through the system.
-- Windows: Microsoft YaHei UI (ships with Windows, has a bold) and Consolas
local CJK = WIN and 'Microsoft YaHei UI' or 'PingFang SC'
local F = {
  reg = ImGui.CreateFont(CJK),
  bold = ImGui.CreateFont(CJK, ImGui.FontFlags_Bold),
  mono = WIN and ImGui.CreateFont('Consolas') or font_file('/System/Library/Fonts/Menlo.ttc', 0) or ImGui.CreateFont('monospace'),
}
for _, f in pairs(F) do ImGui.Attach(ctx, f) end

-- Latin text follows the REAPER theme's UI font. The .ReaperTheme stores fonts as LOGFONT hex (face name from byte
-- 28); the face used most is the theme's UI font. It usually has no CJK glyphs and ReaImGui has no glyph fallback,
-- so Chinese (and symbols like ◆ →) stay on PingFang: see font_for() and the per-token pick in layout_inline.
local load_theme_fonts -- helpers scoped: the main chunk is near Lua's 200-local limit
do
local FONT_DIRS = { (os.getenv('HOME') or '') .. '/Library/Fonts', '/Library/Fonts', '/System/Library/Fonts',
  '/System/Library/Fonts/Supplemental' }
local function theme_face(theme)
  if not theme or theme == '' then return nil end
  local txt
  if not theme:lower():match('%.reaperthemezip$') then
    local f = io.open(theme, 'rb')
    txt = f and f:read('*a') or ''
    if f then f:close() end
  elseif WIN then -- bsdtar (Windows 10+) reads zips; ExecProcess returns "<exit code>\n<stdout>"
    txt = (reaper.ExecProcess('"' .. SYS .. 'tar.exe" -xOf ' .. q(theme) .. ' "*.ReaperTheme"', 5000) or ''):gsub('^[^\n]*\n', '')
  else
    txt = sh('/usr/bin/unzip -p ' .. q(theme) .. ' "*.ReaperTheme" 2>/dev/null')
  end
  local count, best, bn = {}, nil, 0
  for hex in txt:gmatch('\n[%w_]*font[%w_]*=(%x+)') do
    local name = {}
    for i = 57, #hex - 1, 2 do
      local b = tonumber(hex:sub(i, i + 1), 16)
      if not b or b == 0 then break end
      name[#name + 1] = string.char(b)
    end
    local face = table.concat(name)
    if face ~= '' then
      count[face] = (count[face] or 0) + 1
      if count[face] > bn then best, bn = face, count[face] end
    end
  end
  return best
end
local function face_files(face)
  local key = face:gsub('%s', ''):lower()
  local reg, bold
  for _, d in ipairs(FONT_DIRS) do
    for name in sh('/bin/ls ' .. q(d) .. ' 2>/dev/null'):gmatch('[^\n]+') do
      local n = name:lower():gsub('%s', '')
      if n:sub(1, #key) == key and n:match('%.[ot]tf$') then
        local rest = n:sub(#key + 1)
        if not reg and (rest:match('^%-?regular%.') or rest:match('^%.')) then reg = d .. '/' .. name end
        if not bold and rest:match('^%-?bold%.') then bold = d .. '/' .. name end
      end
    end
  end
  return reg, bold
end
function load_theme_fonts()
  for _, f in ipairs({ F.ui, F.ui_bold }) do
    if f and f ~= F.reg and f ~= F.bold then ImGui.Detach(ctx, f) end
  end
  local face = theme_face(reaper.GetLastColorThemeFile())
  if WIN then -- font files there are named segoeui.ttf / segoeuib.ttf; ReaImGui resolves the family name instead
    F.ui = face and ImGui.CreateFont(face) or F.reg
    F.ui_bold = face and ImGui.CreateFont(face, ImGui.FontFlags_Bold) or F.bold
  else
    local reg, bold
    if face then reg, bold = face_files(face) end
    F.ui = reg and font_file(reg, 0) or F.reg
    F.ui_bold = bold and font_file(bold, 0) or F.bold
  end
  if F.ui ~= F.reg then ImGui.Attach(ctx, F.ui) end
  if F.ui_bold ~= F.bold then ImGui.Attach(ctx, F.ui_bold) end
  S.theme_font = face and (face .. (reg and '' or ' (not installed)')) or 'none'
  reaper.SetExtState(EXT, 'theme_font', S.theme_font .. ' | ' .. tostring(reg) .. ' | ' .. tostring(bold), false)
end
end
-- plain Latin (ASCII + Latin-1, e.g. "·") in the theme font; anything from U+2000 up (CJK, ◆, →) in PingFang
local function font_for(str) return str:find('[\226-\244]') and F.reg or F.ui end
-- key + char of one keystroke must land in the same frame for the IME guard below
ImGui.SetConfigVar(ctx, ImGui.ConfigVar_InputTrickleEventQueue, 0)
-- Agent settings stays a borderless ReaImGui viewport with a drawn macOS title bar: OS-decorated viewports are
-- separate top-level windows and don't follow REAPER into a full-screen Space. ReaImGui 0.10 has no
-- ViewportsNoMerge, so cfg_window opens beside the panel (a window overlapping it would merge into it)

-- ReaImGui (cocoa_inputview.mm keyDown) hands every key to the IME *and* to ImGui, so while a pinyin
-- composition is open Backspace/arrows/Esc also edit the field and Enter also sends. We infer the composition
-- (letter keys that produced no characters) and this callback undoes ImGui's side of those keys.
ime_cb = ImGui.CreateFunctionFromEEL([[
clear ? (
  InputTextCallback_DeleteChars(0, strlen(#Buf));
  CursorPos = 0; SelectionStart = 0; SelectionEnd = 0;
  strcpy(#prev, ""); prev_cursor = 0;
  clear = 0; restore = 0; strip_nl = 0;
) : restore ? (
  InputTextCallback_DeleteChars(0, strlen(#Buf));
  InputTextCallback_InsertChars(0, #prev);
  CursorPos = prev_cursor; SelectionStart = prev_cursor; SelectionEnd = prev_cursor;
  restore = 0;
) : (
  strip_nl && CursorPos > 0 && str_getchar(#Buf, CursorPos - 1) == 10 ? (
    InputTextCallback_DeleteChars(CursorPos - 1, 1);
    strcpy(#prev, #Buf); str_delsub(#prev, CursorPos - 1, 1);
    CursorPos -= 1; SelectionStart = CursorPos; SelectionEnd = CursorPos;
  ) : strcpy(#prev, #Buf);
  strip_nl = 0;
  prev_cursor = CursorPos;
);
]])
ImGui.Attach(ctx, ime_cb)
local FONT_SIZE = 14
-- tooltips wrap: the panel is docked at the screen edge, where a one-line tooltip runs off the screen
local function show_tip(text)
  if ImGui.BeginTooltip(ctx) then
    ImGui.PushTextWrapPos(ctx, FONT_SIZE * 22)
    ImGui.Text(ctx, text)
    ImGui.PopTextWrapPos(ctx)
    ImGui.EndTooltip(ctx)
  end
end

-- palette follows the active REAPER theme
local function native(name, fallback)
  local c = reaper.GetThemeColor(name, 0)
  if not c or c < 0 then return fallback end
  local r, g, b = reaper.ColorFromNative(c)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end
-- theme keys flagged "use default" (high bit set) still carry their colour in the low 24 bits
local function native_any(name, fallback)
  local c = reaper.GetThemeColor(name, 0)
  if not c or c == -1 then return fallback end
  local r, g, b = reaper.ColorFromNative(c & 0xFFFFFF)
  return (r << 24) | (g << 16) | (b << 8) | 0xFF
end
local function shade(c, d)
  local function f(v) return math.max(0, math.min(255, v + d)) end
  return (f((c >> 24) & 255) << 24) | (f((c >> 16) & 255) << 16) | (f((c >> 8) & 255) << 8) | (c & 255)
end
local function lum(c) return (((c >> 24) & 255) * 299 + ((c >> 16) & 255) * 587 + ((c >> 8) & 255) * 114) / 1000 end
local function alpha(c, a) return (c & 0xFFFFFF00) | a end

local C, COLORS, theme_file, theme_at, pal_ver = {}, {}, nil, 0, 0
local RND, RND_STRIP = 5, 8 -- corner radius: buttons/fields/lanes, and the header/composer strips
local function build_palette()
  local bg = native('col_tracklistbg', 0x3B3B3BFF)
  local dark = lum(bg) < 128
  C.bg = bg
  C.panel = native('windowtab_bg', dark and 0x424242FF or 0xF6F8FAFF)
  C.input = native('docker_bg', dark and 0x2D2D2DFF or 0xFFFFFFFF)
  C.border = native('col_main_3dsh', dark and 0x323232FF or 0xD0D7DEFF)
  C.text = native('col_tcp_text', dark and 0xF0F0F0FF or 0x1F2328FF)
  if (lum(C.text) < 128) == (not dark) then C.text = dark and 0xF0F0F0FF or 0x1F2328FF end
  C.muted = native('col_main_text2', dark and 0x8C8C8CFF or 0x6E7781FF)
  C.accent = native('col_toolbar_text_on', 0x44B3F6FF)
  C.user = native('genlist_selbg', dark and 0x3E5568FF or 0xDDF4FFFF)
  C.code = native('docker_bg', dark and 0x2D2D2DFF or 0xF6F8FAFF)
  C.codebg = alpha(C.text, 0x1C)
  C.rule = dark and 0x5A5A5AFF or 0xD0D7DEFF
  C.hover = dark and 0x4A4A4AFF or 0xEAEEF2FF
  C.danger = dark and 0xF47067FF or 0xCF222EFF
  C.ok = dark and 0x3FB950FF or 0x1A7F37FF
  C.warn = dark and 0xD29922FF or 0x9A6700FF
  C.selection = alpha(C.accent, 0x55)
  C.body = alpha(C.text, 0xE6)
  -- track-panel look, sampled from Reapertips / Default 7: grey strips on the track-list background, dark name
  -- fields, bevelled M/S-style buttons, near-black envelope lanes, light-blue values
  C.strip = dark and 0x757575FF or 0xE1E4E8FF
  C.strip_text = dark and 0x1E1E1EFF or 0x1F2328FF
  C.field = dark and 0x2E2E2EFF or 0xFFFFFFFF
  C.field_text = dark and 0xEAEAEAFF or 0x1F2328FF
  C.btn = dark and 0x4A4A4AFF or 0xF6F8FAFF
  C.btn_hover = dark and 0x575757FF or 0xEAEEF2FF
  C.btn_down = dark and 0x3A3A3AFF or 0xDDE1E5FF
  C.btn_hi = dark and 0x666666FF or 0xFFFFFFFF
  C.btn_lo = dark and 0x171717FF or 0xBFC5CCFF
  C.btn_text = dark and 0xC8C8C8FF or 0x57606AFF
  C.lane = dark and 0x212121FF or 0xF0F2F4FF
  C.lane_text = dark and 0x9C9C9CFF or 0x6E7781FF
  C.value = dark and 0x93BFF9FF or 0x0969DAFF
  C.led, C.led_off = 0x87B5F7FF, dark and 0x2B2B2BFF or 0xBFC5CCFF -- the mixer FX button's enable LED
  C.user = C.field
  -- selection pills read like selected things in the arrange view: light face (selected-item colour), dark text,
  -- marker blue for ages/outline, razor red for razor areas
  C.pill = native('col_tr1_itembgsel', 0xEBEBEBFF)
  if lum(C.pill) < 150 then C.pill = 0xE6E6E6FF end
  C.pill_old = dark and 0x9A9A9AFF or 0xD0D7DEFF
  C.pill_text = native('col_main_text', 0x242424FF)
  if lum(C.pill_text) > 110 then C.pill_text = 0x242424FF end
  C.pill_kind = 0x585858FF
  C.marker = native('marker', 0x476DBBFF)
  C.razor = native('areasel_outline', 0xA1201BFF)
  -- pop-out windows look like REAPER's own (Routing, FX): light window, darker group boxes, white fields
  C.win = native_any('col_main_bg', 0xBFBFBFFF)
  C.win_text = native('col_main_text', 0x242424FF)
  if lum(C.win) < 128 then C.win, C.win_text = 0xBFBFBFFF, 0x242424FF end
  C.win_box = shade(C.win, -0x18)
  C.win_line = shade(C.win, -0x30)
  C.win_field = 0xF5F5F5FF
  C.win_btn = 0xE6E6E6FF
  C.win_sel = 0xC4D5FBFF
  C.win_title = shade(C.win, 0x2A)
  COLORS = {
    { ImGui.Col_WindowBg, C.bg }, { ImGui.Col_ChildBg, 0x00000000 }, { ImGui.Col_PopupBg, C.panel },
    { ImGui.Col_Text, C.text }, { ImGui.Col_TextDisabled, C.muted }, { ImGui.Col_Border, C.border },
    { ImGui.Col_FrameBg, C.field }, { ImGui.Col_FrameBgHovered, C.field }, { ImGui.Col_FrameBgActive, C.field },
    { ImGui.Col_Button, C.panel }, { ImGui.Col_ButtonHovered, C.hover }, { ImGui.Col_ButtonActive, C.border },
    { ImGui.Col_Header, alpha(C.accent, 0x55) }, { ImGui.Col_HeaderHovered, alpha(C.accent, 0x33) },
    { ImGui.Col_HeaderActive, alpha(C.accent, 0x77) },
    { ImGui.Col_TitleBg, C.panel }, { ImGui.Col_TitleBgActive, C.panel }, { ImGui.Col_Separator, C.border },
    { ImGui.Col_ScrollbarBg, 0x00000000 }, { ImGui.Col_ScrollbarGrab, C.hover },
    { ImGui.Col_CheckMark, C.accent }, { ImGui.Col_InputTextCursor, C.accent },
    { ImGui.Col_TextSelectedBg, alpha(C.accent, 0x66) }, { ImGui.Col_NavCursor, C.accent },
  }
  pal_ver = pal_ver + 1
end
local function check_theme()
  local now = reaper.time_precise()
  if now - theme_at < 1 then return end
  theme_at = now
  local f = reaper.GetLastColorThemeFile()
  if f ~= theme_file then
    theme_file = f
    build_palette()
    load_theme_fonts()
    pal_ver = pal_ver + 1 -- relayout messages with the new font
  end
end
build_palette()
load_theme_fonts()

local VARS = {
  { ImGui.StyleVar_FrameRounding, RND }, { ImGui.StyleVar_ChildRounding, RND }, { ImGui.StyleVar_PopupRounding, RND_STRIP },
  { ImGui.StyleVar_WindowPadding, 10, 10 }, { ImGui.StyleVar_FramePadding, 8, 5 },
  { ImGui.StyleVar_ItemSpacing, 8, 6 }, { ImGui.StyleVar_WindowBorderSize, 0 },
}

---------------------------------------------------------------- markdown
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
  if old and old.w == w and old.pal == pal_ver and old.cut > 0 and text:sub(1, old.cut) == old.pre then
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
  return { w = w, text = text, pal = pal_ver, ops = ops, h = h, cut = cut, pre = pre, pre_ops = pre_ops, pre_h = pre_h }
end
end

local function md(holder, text)
  local w = math.floor(ImGui.GetContentRegionAvail(ctx))
  local L = holder._md
  if not L or L.w ~= w or L.text ~= text or L.pal ~= pal_ver then
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
  if not L or L.w ~= w or L.text ~= text or L.pal ~= pal_ver then
    local pad, sub = 8, {}
    local y = layout_inline(sub, { { text = text } }, pad, pad, w - 2 * pad, FONT_SIZE, C.field_text)
    local ops = { { 'r', 0, 0, w, y + pad, C.user, RND_STRIP } }
    for _, o in ipairs(sub) do ops[#ops + 1] = o end
    L = { w = w, text = text, pal = pal_ver, ops = ops, h = y + pad }
    holder._bubble = L
  end
  draw_ops(L, w)
  if ImGui.IsItemClicked(ctx, 1) then ImGui.SetClipboardText(ctx, text) end
end

---------------------------------------------------------------- UI
-- attachments waiting in the composer (one table: the main chunk is at Lua's 200-local limit)
local ATT = {}
function ATT.add(path, group) -- group: files that go and get removed together (one Ears run)
  if type(path) ~= 'string' or path == '' then return end
  local f = io.open(path, 'rb')
  if not f then return end
  f:close()
  for _, x in ipairs(S.files) do if x.path == path then return end end
  S.files[#S.files + 1] = { path = path, name = path:match('[^/\\]+$') or path, group = group }
end
function ATT.drop() -- call right after the item that should take dropped files
  if ImGui.BeginDragDropTarget(ctx) then
    local rv, count = ImGui.AcceptDragDropPayloadFiles(ctx)
    if rv then
      for i = 0, count - 1 do
        local _, fn = ImGui.GetDragDropPayloadFile(ctx, i)
        ATT.add(fn)
      end
      S.focus = true
    end
    ImGui.EndDragDropTarget(ctx)
  end
end
-- ImGui's paste only reads clipboard text. Files copied in Finder / Explorer attach (their text form is just the
-- names), and so does an image with no text beside it (a screenshot), saved as a PNG. Rich text that also carries a
-- picture stays text. First output line: files | image.
ATT.JS = [=[
ObjC.import('AppKit');
function run(argv) {
  var pb = argv[1] ? $.NSPasteboard.pasteboardWithName(argv[1]) : $.NSPasteboard.generalPasteboard; // argv[1]: tests
  var only = $.NSDictionary.dictionaryWithObjectForKey($.NSNumber.numberWithBool(true), $.NSPasteboardURLReadingFileURLsOnlyKey);
  var urls = pb.readObjectsForClassesOptions($.NSArray.arrayWithObject($.NSURL), only);
  if (!urls.isNil() && urls.count > 0) {
    var out = ['files'];
    for (var i = 0; i < urls.count; i++) out.push(urls.objectAtIndex(i).path.js);
    return out.join('\n');
  }
  var types = ObjC.deepUnwrap(pb.types) || [];
  if (types.indexOf('public.utf8-plain-text') >= 0) return '';
  var data = pb.dataForType('public.png');
  if (data.isNil()) {
    var tiff = pb.dataForType('public.tiff');
    if (tiff.isNil()) return '';
    data = $.NSBitmapImageRep.imageRepWithData(tiff).representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({}));
  }
  return data.writeToFileAtomically(argv[0], true) ? 'image\n' + argv[0] : '';
}
]=]
ATT.PS = [=[
Add-Type -AssemblyName System.Windows.Forms
$c = [Windows.Forms.Clipboard]
if ($c::ContainsFileDropList()) { 'files'; $c::GetFileDropList() }
elseif ($c::ContainsImage() -and -not $c::ContainsText()) {
  $c::GetImage().Save($args[0], [Drawing.Imaging.ImageFormat]::Png); 'image'; $args[0]
}
]=]
-- returns how many files it attached; Cmd+V on a composer that is being typed in
function ATT.paste()
  mkdir()
  local png = DIR .. 'screenshot-' .. os.date('%Y%m%d-%H%M%S') .. '.png'
  local script = DIR .. (WIN and 'clip.ps1' or 'clip.js')
  local f = io.open(script, 'wb')
  if not f then return 0 end
  f:write(WIN and ATT.PS or ATT.JS)
  f:close()
  local out
  if WIN then
    out = reaper.ExecProcess('powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File ' .. q(script) .. ' ' .. q(png), 5000)
    out = (out or ''):gsub('^%-?%d+\r?\n', '') -- ExecProcess puts the exit code on the first line
  else
    out = sh('/usr/bin/osascript -l JavaScript ' .. q(script) .. ' ' .. q(png) .. ' 2>/dev/null')
  end
  local kind, n = nil, 0
  for line in out:gmatch('[^\r\n]+') do
    if not kind then kind = line
    elseif kind == 'files' or kind == 'image' then
      local before = #S.files
      ATT.add(line)
      if #S.files > before then n = n + 1 end
    end
  end
  if n > 0 then S.focus = true end
  return n
end

-- longest prefix (whole UTF-8 characters) + "…" that fits w in the current font: binary search, cached per
-- string, width, font size and palette (fonts follow the theme)
local truncate
do
  local cache, n = {}, 0
  function truncate(str, w)
    w = math.floor(w)
    local key = str .. '\0' .. w .. '\0' .. ImGui.GetFontSize(ctx) .. '\0' .. pal_ver
    local hit = cache[key]
    if hit then return hit end
    local out = str
    if ImGui.CalcTextSize(ctx, str) > w then
      local lo, hi = 0, (utf8.len(str) or #str) - 1 -- chars kept: lo always fits (0 = just "…")
      while lo < hi do
        local mid = (lo + hi + 1) // 2
        local cut = str:sub(1, (utf8.offset(str, mid + 1) or (#str + 1)) - 1) .. '…'
        if ImGui.CalcTextSize(ctx, cut) <= w then lo = mid else hi = mid - 1 end
      end
      out = str:sub(1, (utf8.offset(str, lo + 1) or (#str + 1)) - 1) .. '…'
    end
    n = n + 1
    if n > 2000 then cache, n = {}, 0 end
    cache[key] = out
    return out
  end
end

local function push_btn(bg, hovered, active, text) -- pop with ImGui.PopStyleColor(ctx, 4)
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, bg)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, hovered)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, active)
  ImGui.PushStyleColor(ctx, ImGui.Col_Text, text)
end
-- the context a message carried: small tag with the Context button's LED, project · cursor · newest selection;
-- hover shows the whole block
local function ctx_tag(m, id)
  local c = m._ctx or ''
  if not m._ctx_sum then
    local parts = {}
    parts[#parts + 1] = c:match('\nproject: ([^\n]+)')
    parts[#parts + 1] = c:match('\ncursor: (%S+)')
    local newest = c:match('newest first: (.-)%s*[>\n]')
    if newest then
      newest = newest:gsub('%s+%d+%s*%a*%s+ago$', ''):gsub('%s+before panel opened$', '')
      parts[#parts + 1] = newest
    end
    m._ctx_sum = table.concat(parts, ' · ')
  end
  ImGui.PushFont(ctx, F.reg, FONT_SIZE - 3)
  local lh = ImGui.GetTextLineHeight(ctx)
  local title = 'REAPER context'
  local cw = m._ctx_w
  if not cw or cw.pal ~= pal_ver then
    cw = { pal = pal_ver, tw = ImGui.CalcTextSize(ctx, title),
      sw = m._ctx_sum ~= '' and (ImGui.CalcTextSize(ctx, m._ctx_sum) + 8) or 0 }
    m._ctx_w = cw
  end
  local tw, sw = cw.tw, cw.sw
  local x, y = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, '##ctxtag_' .. tostring(id), math.min(10 + tw + sw, ImGui.GetContentRegionAvail(ctx)), lh + 2)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x + 1, y + 1 + lh / 2 - 4, x + 4, y + 1 + lh / 2 + 4, C.led, 1.5)
  ImGui.DrawList_AddText(dl, x + 10, y + 1, C.lane_text, title)
  if sw > 0 then ImGui.DrawList_AddText(dl, x + 10 + tw + 8, y + 1, C.muted, m._ctx_sum) end
  ImGui.PopFont(ctx)
  if ImGui.IsItemHovered(ctx) and c ~= '' then
    local L, n = {}, 0
    for line in c:gmatch('[^\n]+') do n = n + 1; if n <= 40 then L[#L + 1] = line end end
    show_tip(table.concat(L, '\n') .. (n > 40 and ('\n… +' .. (n - 40) .. ' lines') or ''))
  end
end

-- tool calls: one small muted line under the reply (no fill, so it never reads like a message bubble); a run of
-- calls collapses into one line with per-tool counts. holder keeps the label and its widths
local function tool_lane(labels, id, holder)
  ImGui.PushFont(ctx, F.reg, FONT_SIZE - 2)
  local w = ImGui.GetContentRegionAvail(ctx)
  local c = holder and holder._lane
  if not c or c.n ~= #labels or c.w ~= w or c.pal ~= pal_ver then
    local order, cnt = {}, {}
    for _, l in ipairs(labels) do
      if not cnt[l] then cnt[l] = 0; order[#order + 1] = l end
      cnt[l] = cnt[l] + 1
    end
    local parts = {}
    for _, l in ipairs(order) do parts[#parts + 1] = cnt[l] > 1 and (l .. ' ×' .. cnt[l]) or l end
    local text = truncate(table.concat(parts, ' · '), w - 30)
    c = { n = #labels, w = w, pal = pal_ver, text = text }
    if holder then holder._lane = c end
  end
  local lh = ImGui.GetTextLineHeight(ctx)
  local x1, y1 = ImGui.GetCursorScreenPos(ctx)
  ImGui.InvisibleButton(ctx, '##lane_' .. id, w, lh + 2)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddText(dl, x1, y1 + 1, C.muted, c.text) -- plain text, flush with the reply
  ImGui.PopFont(ctx)
  if ImGui.IsItemHovered(ctx) and #labels > 1 then
    local seq = {}
    for i = 1, math.min(#labels, 60) do seq[#seq + 1] = labels[i] end
    show_tip(table.concat(seq, ' → ') .. (#labels > 60 and (' … +' .. (#labels - 60)) or ''))
  end
end

local function chevron(x2, y1, y2, col)
  local cx, cy = x2 - 11, (y1 + y2) / 2 + 1
  ImGui.DrawList_AddTriangleFilled(ImGui.GetWindowDrawList(ctx), cx - 3.5, cy - 2, cx + 3.5, cy - 2, cx, cy + 2.5, col)
end
local function dot(col, x, y) ImGui.DrawList_AddCircleFilled(ImGui.GetWindowDrawList(ctx), x, y, 3.5, col) end

-- bevelled button like the track panel's M/S: black bottom edge, light top edge, dark face
local function bevel(dl, x1, y1, x2, y2, face)
  ImGui.DrawList_AddRectFilled(dl, x1, y1, x2, y2, C.btn_lo, RND)
  ImGui.DrawList_AddRectFilled(dl, x1, y1, x2, y2 - 1, C.btn_hi, RND)
  ImGui.DrawList_AddRectFilled(dl, x1, y1 + 1, x2, y2 - 1, face, RND)
end
local function face_col()
  return ImGui.IsItemActive(ctx) and C.btn_down or (ImGui.IsItemHovered(ctx) and C.btn_hover or C.btn)
end

-- DAW button; col = C.accent marks a toggle that is on (blue label), chevron=false for toggles/plain buttons;
-- off = disabled: flat face, dimmed label, no click (BeginDisabled does not dim draw-list drawing)
local function chip(id, label, col, with_chevron, off)
  local chev = with_chevron ~= false
  local h = ImGui.GetFrameHeight(ctx) - 2 -- base font, like the pills and the header buttons
  ImGui.PushFont(ctx, font_for(label), FONT_SIZE)
  local tw = ImGui.CalcTextSize(ctx, label)
  local w = tw + 18 + (chev and 14 or 0)
  local clicked = ImGui.InvisibleButton(ctx, '##chip_' .. id, w, h)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  bevel(dl, x1, y1, x1 + w, y1 + h, off and C.btn or face_col())
  local tc = col == C.accent and C.value or (col == C.text and C.field_text or C.btn_text)
  if off then tc = alpha(tc, 0x66) end
  ImGui.DrawList_AddText(dl, x1 + 9, y1 + (h - ImGui.GetTextLineHeight(ctx)) / 2, tc, label)
  ImGui.PopFont(ctx)
  if chev then chevron(x1 + w, y1, y1 + h, off and alpha(C.btn_text, 0x66) or C.btn_text) end
  return clicked and not off
end

-- on/off button like the mixer's FX button: bevelled face, label, a small LED bar on the right (lit = on)
local function led_toggle(id, label, on)
  local h = ImGui.GetFrameHeight(ctx) - 2 -- base font, like chip()
  ImGui.PushFont(ctx, font_for(label), FONT_SIZE)
  local tw = ImGui.CalcTextSize(ctx, label)
  local w = tw + 30
  local clicked = ImGui.InvisibleButton(ctx, '##led_' .. id, w, h)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  bevel(dl, x1, y1, x1 + w, y1 + h, face_col())
  ImGui.DrawList_AddText(dl, x1 + 9, y1 + (h - ImGui.GetTextLineHeight(ctx)) / 2, C.btn_text, label)
  local lx, ly = x1 + w - 11, y1 + h / 2 - 5
  ImGui.DrawList_AddRectFilled(dl, lx, ly, lx + 4, ly + 10, on and C.led or C.led_off, 2)
  ImGui.PopFont(ctx)
  return clicked
end


-- one picker for every backend: Gamut agents and local ACP agents, each with a status dot and Connect
local function agent_state(a) -- status colour + short text for the menu
  if not a.acp then
    local st = a.status or 'unknown'
    return st == 'running' and C.ok or C.muted, st
  end
  local st = S.acp_status[a.slug]
  if not st then return C.muted, '' end
  if st.connected then return C.ok, 'ready' end
  if st.state == 'starting' or st.state == 'authenticating' then return C.warn, 'checking…' end
  if st.state == 'auth_required' then return C.warn, 'login' end
  return C.muted, st.state or ''
end

local function opt_items(o) -- ACP options may be grouped: {group, name, options = {...}}
  local out = {}
  for _, x in ipairs(type(o.options) == 'table' and o.options or {}) do
    if type(x.options) == 'table' then
      for _, y in ipairs(x.options) do out[#out + 1] = { value = sval(y.value) or '', name = sval(y.name), group = sval(x.name) } end
    else
      out[#out + 1] = { value = sval(x.value) or '', name = sval(x.name), group = sval(x.group) }
    end
  end
  return out
end

-- "Opus 5.5 · medium": what the next message runs with (explicit pick, else the agent's current value)
local function model_label()
  local model, effort
  for _, o in ipairs(S.cfg_opts) do
    if type(o) == 'table' and o.type == 'select' then
      if o.category == 'model' and not model then model = o
      elseif (o.category == 'thought_level' or o.category == 'model_config') and not effort then effort = o end
    end
  end
  local parts = {}
  for _, o in ipairs({ model or false, effort or false }) do
    if o then
      local v = S.cfg_sel[sval(o.id) or o.category] or sval(o.currentValue) or ''
      for _, it in ipairs(opt_items(o)) do if v ~= '' and it.value == v then parts[#parts + 1] = it.name or v end end
    end
  end
  return table.concat(parts, ' · ')
end

-- the agent name field in the header (agent + model in effect) is the one way into Agent settings
local function agent_picker()
  -- Gamut's agent layer stays hidden: any Gamut agent reads as "Gamut"
  local name = S.agent == '' and 'No agent' or (is_acp() and (S.agent_name ~= '' and S.agent_name or S.agent) or 'Gamut')
  local ml = S.agent ~= '' and model_label() or ''
  local h = ImGui.GetFrameHeight(ctx) - 2
  ImGui.PushFont(ctx, F.bold, FONT_SIZE)
  local nw = ImGui.CalcTextSize(ctx, name)
  ImGui.PopFont(ctx)
  local mw = ml ~= '' and (ImGui.CalcTextSize(ctx, ml) + 10) or 0
  local w = nw + mw + 20 + 14
  local clicked = ImGui.InvisibleButton(ctx, '##agentfield', w, h)
  local x1, y1 = ImGui.GetItemRectMin(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local ty = y1 + (h - ImGui.GetTextLineHeight(ctx)) / 2
  ImGui.DrawList_AddRectFilled(dl, x1, y1, x1 + w, y1 + h, ImGui.IsItemHovered(ctx) and C.btn_down or C.field, RND)
  chevron(x1 + w, y1, y1 + h, C.lane_text)
  if ImGui.IsItemHovered(ctx) then show_tip('Agent settings') end
  if clicked then
    S.cfgwin = not S.cfgwin
    S.cfgwin_pos = nil
    load_agents()
    for _, a in ipairs(S.agents) do if a.acp then load_acp_status(a.slug, true) end end
  end
  ImGui.PushFont(ctx, F.bold, FONT_SIZE)
  ImGui.DrawList_AddText(dl, x1 + 10, ty, C.field_text, name)
  ImGui.PopFont(ctx)
  if ml ~= '' then ImGui.DrawList_AddText(dl, x1 + 10 + nw + 10, ty, C.value, ml) end
end

local function history_popup()
  ImGui.SetNextWindowSizeConstraints(ctx, 260, 0, 460, 480)
  if ImGui.BeginPopup(ctx, 'histpop') then
    if reaper.time_precise() - S.sess_at > 10 then load_sessions() end
    ImGui.TextDisabled(ctx, 'Recent chats')
    local dl = ImGui.GetWindowDrawList(ctx)
    for _, x in ipairs(S.sessions) do
      local aw = ImGui.CalcTextSize(ctx, x.age)
      local label = truncate(x.name, ImGui.GetContentRegionAvail(ctx) - aw - 30)
      if ImGui.Selectable(ctx, '     ' .. label .. '##' .. x.id, x.id == S.sid) then switch_session(x.id, x.name) end
      local sx1, sy1 = ImGui.GetItemRectMin(ctx)
      local sx2, sy2 = ImGui.GetItemRectMax(ctx)
      local my = (sy1 + sy2) / 2
      ImGui.DrawList_AddRectFilled(dl, sx1 + 4, my - 5, sx1 + 8, my + 5, x.active and C.led or C.led_off, 2)
      ImGui.DrawList_AddText(dl, sx2 - aw - 4, sy1, C.muted, x.age)
    end
    if #S.sessions == 0 then ImGui.TextDisabled(ctx, 'No chats yet') end
    ImGui.EndPopup(ctx)
  end
end

local function header()
  -- a track-panel strip: grey band, dark name field on the left, button column on the right
  local dl = ImGui.GetWindowDrawList(ctx)
  local hx, hy = ImGui.GetCursorScreenPos(ctx)
  local hw = ImGui.GetContentRegionAvail(ctx)
  local fh = ImGui.GetFrameHeight(ctx) - 2
  local hh = fh + 10
  ImGui.DrawList_AddRectFilled(dl, hx - 4, hy - 4, hx + hw + 4, hy + hh - 4, C.strip, RND_STRIP)
  ImGui.SetCursorScreenPos(ctx, hx + 1, hy + 1)
  agent_picker()
  if S.agent ~= '' then
    -- the column's text buttons: Stop (while a reply runs), Chats, New
    local labels = S.active and { 'Stop', 'Chats', 'New' } or { 'Chats', 'New' }
    local right = (#labels - 1) * 3
    for _, l in ipairs(labels) do
      ImGui.PushFont(ctx, font_for(l), FONT_SIZE)
      right = right + ImGui.CalcTextSize(ctx, l) + 18 -- chip(): label + 9 px padding each side
      ImGui.PopFont(ctx)
    end
    ImGui.SameLine(ctx, 0, 8)
    local title = S.sid == '' and 'New chat' or (S.title ~= '' and S.title or 'Chat')
    local room = ImGui.GetContentRegionAvail(ctx) - right - 16
    if room > 40 then
      local tx, ty = ImGui.GetCursorScreenPos(ctx)
      local t = truncate(title, room)
      ImGui.InvisibleButton(ctx, '##title', ImGui.CalcTextSize(ctx, t), fh)
      ImGui.DrawList_AddText(dl, tx, ty + (fh - ImGui.GetTextLineHeight(ctx)) / 2, C.strip_text, t)
      if ImGui.IsItemHovered(ctx) then show_tip(title) end
      ImGui.SameLine(ctx)
    end
    local bx = hx + hw - right - 1
    -- 1 px inside the strip's top/right/bottom: two equal anti-aliased curves leave a light fringe
    ImGui.DrawList_AddRectFilled(dl, bx - 4, hy - 3, hx + hw + 3, hy + hh - 5, C.field, RND_STRIP - 1, ImGui.DrawFlags_RoundCornersRight)
    ImGui.SetCursorScreenPos(ctx, bx, hy + 1)
    if S.active then
      if chip('stop', 'Stop', C.muted, false) then stop() end
      ImGui.SameLine(ctx, 0, 3)
    end
    if chip('hist', 'Chats', C.muted, false) then
      load_sessions()
      ImGui.OpenPopup(ctx, 'histpop')
    end
    ImGui.SameLine(ctx, 0, 3)
    if chip('new', 'New', C.muted, false) then new_chat() end
    history_popup()
  end
  ImGui.SetCursorScreenPos(ctx, hx, hy + hh + 2)
  ImGui.Dummy(ctx, 0, 0)
end


-- Agent settings pops out as a real window in the style of REAPER's Routing window: small type, two columns of
-- grey group boxes with labelled rows, white fields, light buttons, LED toggles
local function cfg_window()
  local SMALL = 12
  -- other scripts (the agent via MCP) can pop the window open: SetExtState('Hibiki', 'open', 'settings')
  local want_open = reaper.GetExtState(EXT, 'open')
  if want_open == 'settings' or want_open == 'recover' then
    reaper.DeleteExtState(EXT, 'open', false)
    S.cfgwin = true
    if want_open == 'recover' then REC.start() end
  end
  if S.cfgwin and not S.cfgwin_was then -- just opened: re-read what is otherwise only polled while unknown
    local r = ONB.reaper[S.agent]
    if r then r.stale = true end
    S.agentpop_at = 0
    UPD.auto()
  end
  S.cfgwin_was = S.cfgwin
  if not S.cfgwin then return end
  local model, effort, mode
  for _, o in ipairs(S.cfg_opts) do
    if type(o) == 'table' and o.type == 'select' then
      if o.category == 'model' and not model then model = o
      elseif (o.category == 'thought_level' or o.category == 'model_config') and not effort then effort = o
      elseif o.category == 'mode' and not mode then mode = o end
    end
  end
  local function cur_of(o) local id = sval(o.id) or o.category; return id, S.cfg_sel[id] or sval(o.currentValue) or '' end
  local function pick(id, value) S.cfg_sel[id] = value; cfg_save() end
  local agent
  for _, a in ipairs(S.agents) do if a.slug == S.agent then agent = a end end
  local at = S.cfgwin_pos or (S.panel_rect and { S.panel_rect[1], S.panel_rect[2] }) -- top right, flush with the panel's left edge

  local cols = {
    { ImGui.Col_WindowBg, C.win }, { ImGui.Col_TitleBg, C.win_title }, { ImGui.Col_TitleBgActive, C.win_title },
    { ImGui.Col_Text, C.win_text }, { ImGui.Col_TextDisabled, shade(C.win_text, 0x30) },
    { ImGui.Col_Border, C.win_line }, { ImGui.Col_Separator, C.win_line },
    { ImGui.Col_FrameBg, C.win_field }, { ImGui.Col_FrameBgHovered, 0xFFFFFFFF }, { ImGui.Col_FrameBgActive, 0xFFFFFFFF },
    { ImGui.Col_PopupBg, C.win_field }, { ImGui.Col_Button, C.win_btn }, { ImGui.Col_ButtonHovered, 0xFFFFFFFF },
    { ImGui.Col_ButtonActive, C.win_sel }, { ImGui.Col_Header, C.win_sel }, { ImGui.Col_HeaderHovered, alpha(C.win_sel, 0xB0) },
    { ImGui.Col_HeaderActive, C.win_sel }, { ImGui.Col_ScrollbarGrab, C.win_line },
  }
  for _, c in ipairs(cols) do ImGui.PushStyleColor(ctx, c[1], c[2]) end
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 10, 8)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowRounding, 0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowBorderSize, 1)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 5, 2)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 5, 4)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameRounding, 3)
  ImGui.PushFont(ctx, F.reg, SMALL)
  if at then ImGui.SetNextWindowPos(ctx, at[1], at[2], ImGui.Cond_Appearing, 1, 0) end
  local name = S.agent_name ~= '' and S.agent_name or S.agent
  local visible, open = ImGui.Begin(ctx, 'Agent settings###hibiki_cfg', true,
    ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoTitleBar
    | (ImGui.WindowFlags_NoDocking or 0))
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local fh = ImGui.GetFrameHeight(ctx)
    local COL, GAP, LW = 290, 12, 60 -- column width, gutter, label column
    do -- title bar like a macOS window: traffic lights (red closes), centred bold title, drag anywhere to move
      local wx, wy = ImGui.GetWindowPos(ctx)
      local ww = ImGui.GetWindowSize(ctx)
      local th = 24
      ImGui.DrawList_AddRectFilled(dl, wx, wy, wx + ww, wy + th, C.win_title)
      ImGui.DrawList_AddLine(dl, wx, wy + th, wx + ww, wy + th, C.win_line, 1)
      local lights = { 0xFF5F57FF, 0xFEBC2EFF, 0x28C840FF }
      for i, col in ipairs(lights) do ImGui.DrawList_AddCircleFilled(dl, wx + 8 + 6 + (i - 1) * 20, wy + th / 2, 6, col) end
      ImGui.SetCursorScreenPos(ctx, wx + 8, wy + th / 2 - 6)
      if ImGui.InvisibleButton(ctx, '##cfg_close', 12, 12) then open = false end
      if ImGui.IsItemHovered(ctx) then
        local cx, cy = wx + 14, wy + th / 2
        ImGui.DrawList_AddLine(dl, cx - 2.5, cy - 2.5, cx + 2.5, cy + 2.5, 0x4D0000FF, 1.3)
        ImGui.DrawList_AddLine(dl, cx - 2.5, cy + 2.5, cx + 2.5, cy - 2.5, 0x4D0000FF, 1.3)
      end
      ImGui.PushFont(ctx, F.bold, SMALL + 1)
      local t = 'Agent settings'
      local tw = ImGui.CalcTextSize(ctx, t)
      ImGui.DrawList_AddText(dl, wx + (ww - tw) / 2, wy + (th - ImGui.GetTextLineHeight(ctx)) / 2, C.win_text, t)
      ImGui.PopFont(ctx)
      ImGui.SetCursorScreenPos(ctx, wx + 10, wy + th + 6)
    end
    S.boxh = S.boxh or {}
    local function section(title, w)
      local t = '-  ' .. title .. '  -'
      local x = ImGui.GetCursorPosX(ctx)
      ImGui.SetCursorPosX(ctx, x + (w - ImGui.CalcTextSize(ctx, t)) / 2)
      ImGui.Text(ctx, t)
    end
    -- grey group box; its height is last frame's measured content, so it sits behind the rows without a splitter
    local function box(key, w, body)
      local x, y = ImGui.GetCursorScreenPos(ctx)
      local h = S.boxh[key] or (fh + 12)
      ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, C.win_box, 1)
      ImGui.DrawList_AddRect(dl, x, y, x + w, y + h, C.win_line, 1)
      ImGui.SetCursorScreenPos(ctx, x + 5, y + 5)
      ImGui.BeginGroup(ctx)
      body(w - 10, x + 5)
      ImGui.EndGroup(ctx)
      local _, y2 = ImGui.GetItemRectMax(ctx)
      S.boxh[key] = y2 - y + 5
      ImGui.SetCursorScreenPos(ctx, x, y + S.boxh[key] + 6)
      ImGui.Dummy(ctx, w, 0)
    end
    local function label(t, x0)
      ImGui.SetCursorScreenPos(ctx, x0, select(2, ImGui.GetCursorScreenPos(ctx)))
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, t)
      ImGui.SameLine(ctx, 0, 0)
      ImGui.SetCursorScreenPos(ctx, x0 + LW, select(2, ImGui.GetCursorScreenPos(ctx)))
    end
    local function light_btn(id, text, w, on, off)
      local clicked = ImGui.InvisibleButton(ctx, '##lb_' .. id, w, fh)
      local x1, y1 = ImGui.GetItemRectMin(ctx)
      local face = off and C.win_box or (on and C.win_sel
        or (ImGui.IsItemActive(ctx) and C.win_sel or (ImGui.IsItemHovered(ctx) and 0xFFFFFFFF or C.win_btn)))
      ImGui.DrawList_AddRectFilled(dl, x1, y1, x1 + w, y1 + fh, face, 3)
      ImGui.DrawList_AddRect(dl, x1, y1, x1 + w, y1 + fh, on and C.marker or C.win_line, 3)
      local tw = ImGui.CalcTextSize(ctx, text)
      ImGui.DrawList_AddText(dl, x1 + (w - tw) / 2, y1 + (fh - ImGui.GetTextLineHeight(ctx)) / 2,
        off and shade(C.win_text, 0x60) or C.win_text, text)
      return clicked and not off
    end
    local function checkbox(id, text, on, w)
      local cx, cy = ImGui.GetCursorScreenPos(ctx)
      local hit = ImGui.InvisibleButton(ctx, '##cb_' .. id, w, fh)
      local bx, by = cx + 1, cy + (fh - 13) / 2
      ImGui.DrawList_AddRectFilled(dl, bx, by, bx + 13, by + 13, 0xFFFFFFFF, 2)
      ImGui.DrawList_AddRect(dl, bx, by, bx + 13, by + 13, C.win_line, 2)
      if on then
        ImGui.DrawList_AddLine(dl, bx + 3, by + 6.5, bx + 5.5, by + 9.5, C.win_text, 1.8)
        ImGui.DrawList_AddLine(dl, bx + 5.5, by + 9.5, bx + 10, by + 3.5, C.win_text, 1.8)
      end
      ImGui.DrawList_AddText(dl, bx + 20, cy + (fh - ImGui.GetTextLineHeight(ctx)) / 2, C.win_text, text)
      return hit
    end
    local function combo(o, key, w)
      local id, cur = cur_of(o)
      local items = opt_items(o)
      local groups, ng = {}, 0
      for _, it in ipairs(items) do
        if it.group and it.group ~= '' and not groups[it.group] then groups[it.group] = true; ng = ng + 1 end
      end
      local preview = 'Default'
      for _, it in ipairs(items) do
        if it.value == cur then preview = ((ng > 1 and it.group and it.group ~= '') and (it.group .. ' · ') or '') .. (it.name or it.value) end
      end
      ImGui.SetNextItemWidth(ctx, w)
      local bx, by = ImGui.GetCursorScreenPos(ctx) -- before BeginCombo: once open, the "last item" is in the popup
      local opened = ImGui.BeginCombo(ctx, '##cfg_' .. key, preview, ImGui.ComboFlags_HeightLarge | ImGui.ComboFlags_NoArrowButton)
      local cx, cy = bx + w - 9, by + fh / 2 -- macOS popup-button arrows
      ImGui.DrawList_AddTriangleFilled(dl, cx - 3, cy - 1.5, cx + 3, cy - 1.5, cx, cy - 5, C.win_text)
      ImGui.DrawList_AddTriangleFilled(dl, cx - 3, cy + 1.5, cx + 3, cy + 1.5, cx, cy + 5, C.win_text)
      if opened then
        local group
        for _, it in ipairs(items) do
          if ng > 1 and it.group and it.group ~= group then
            group = it.group
            if ImGui.SeparatorText then ImGui.SeparatorText(ctx, group) else ImGui.TextDisabled(ctx, group) end
          end
          local on = it.value == cur
          if ImGui.Selectable(ctx, (it.name or it.value) .. '##' .. key .. it.value, on) then pick(id, it.value) end
          if on then ImGui.SetItemDefaultFocus(ctx) end
        end
        ImGui.EndCombo(ctx)
      end
    end
    local function kv(k, v, x0, w, col)
      label(k, x0)
      ImGui.PushTextWrapPos(ctx, x0 + w - ImGui.GetWindowPos(ctx))
      if col then ImGui.TextColored(ctx, col, v) else ImGui.Text(ctx, v) end
      ImGui.PopTextWrapPos(ctx)
    end

    if reaper.time_precise() - (S.agentpop_at or 0) > 10 then -- keep local agents' login state fresh while open
      S.agentpop_at = reaper.time_precise()
      for _, a in ipairs(S.agents) do if a.acp then load_acp_status(a.slug, false) end end
    end

    if is_acp() and S.sid ~= '' and reaper.time_precise() - (S.sess_at or 0) > 10 then load_sessions() end
    -- providers: Gamut stands for the current (or last used) Gamut agent; its agent layer sits inside the box
    local want = (S.agent ~= '' and not is_acp()) and S.agent or reaper.GetExtState(EXT, 'gamut_agent')
    local gamut
    for _, a in ipairs(S.agents) do if not a.acp and (a.slug == want or not gamut) then gamut = a end end
    local provs, cur = {}, nil
    if gamut then provs[1] = { name = 'Gamut', acp = false, slug = gamut.slug, real = gamut } end
    for _, a in ipairs(S.agents) do if a.acp then provs[#provs + 1] = { name = a.name, acp = true, slug = a.slug, real = a } end end
    for _, r in ipairs(provs) do if (r.acp and r.slug == S.agent) or (not r.acp and S.agent ~= '' and not is_acp()) then cur = r end end
    ONB.tick()
    -- CLI agents the gateway can install; picking one shows its Install box instead of a provider
    local extra = {}
    for _, x in ipairs(ONB.installable or {}) do if not x.installed then extra[#extra + 1] = x end end
    local pending
    for _, x in ipairs(extra) do if x.key == S.pending_install then pending = x end end
    if pending then cur = nil end
    local function pick_provider(r)
      S.pending_install = nil
      if r ~= cur then choose_agent(r.real.slug, r.real.name); load_sessions() end
    end
    local function arrows(x2, y1, y2)
      local cx, cy = x2 - 9, (y1 + y2) / 2
      ImGui.DrawList_AddTriangleFilled(dl, cx - 3, cy - 1.5, cx + 3, cy - 1.5, cx, cy - 5, C.win_text)
      ImGui.DrawList_AddTriangleFilled(dl, cx - 3, cy + 1.5, cx + 3, cy + 1.5, cx, cy + 5, C.win_text)
    end

    -- left column (like Sends): provider drop-down, then one box with the provider's settings
    ImGui.BeginGroup(ctx)
    section('Provider', COL)
    ImGui.SetNextItemWidth(ctx, COL)
    local px, py = ImGui.GetCursorScreenPos(ctx)
    local opened = ImGui.BeginCombo(ctx, '##cfg_provider', pending and (pending.name .. ' (not installed)')
      or (cur and cur.name) or 'Choose a provider', ImGui.ComboFlags_HeightLarge | ImGui.ComboFlags_NoArrowButton)
    arrows(px + COL, py, py + fh)
    if opened then
      local pdl = ImGui.GetWindowDrawList(ctx)
      for _, r in ipairs(provs) do
        local col, state = agent_state(r.real)
        if ImGui.Selectable(ctx, r.name .. '##prov_' .. r.slug, r == cur) then pick_provider(r) end
        local _, sy1 = ImGui.GetItemRectMin(ctx)
        local sx2, sy2 = ImGui.GetItemRectMax(ctx)
        if state ~= '' then
          local tw = ImGui.CalcTextSize(ctx, state)
          ImGui.DrawList_AddCircleFilled(pdl, sx2 - tw - 10, (sy1 + sy2) / 2, 3, col)
          ImGui.DrawList_AddText(pdl, sx2 - tw - 2, sy1, shade(C.win_text, 0x40), state)
        end
        if r.acp and r.real.desc ~= '' and ImGui.IsItemHovered(ctx) then show_tip(r.real.desc) end
      end
      if #extra > 0 then ImGui.Separator(ctx) end
      for _, x in ipairs(extra) do
        if ImGui.Selectable(ctx, x.name .. '##inst_' .. x.key, x == pending) then S.pending_install = x.key end
        local _, sy1 = ImGui.GetItemRectMin(ctx)
        local sx2 = ImGui.GetItemRectMax(ctx)
        local t = ONB.installing == x.key and 'installing…' or 'install'
        ImGui.DrawList_AddText(ImGui.GetWindowDrawList(ctx), sx2 - ImGui.CalcTextSize(ctx, t) - 2, sy1, C.marker, t)
      end
      if not gamut then -- Gamut not running: a download entry, marked like the install entries above
        if ImGui.Selectable(ctx, 'Gamut (desktop app)##getgamut', false) then ONB.open_url(ONB.gamut_url) end
        if ImGui.IsItemHovered(ctx) then show_tip('Sign in with a Gamut account · own API keys optional') end
        local _, sy1 = ImGui.GetItemRectMin(ctx)
        local sx2 = ImGui.GetItemRectMax(ctx)
        ImGui.DrawList_AddText(ImGui.GetWindowDrawList(ctx), sx2 - ImGui.CalcTextSize(ctx, 'download') - 2, sy1, C.marker, 'download')
      end
      ImGui.EndCombo(ctx)
    end
    ImGui.Dummy(ctx, 0, 2)
    if pending then
      box('install', COL, function(w, x0)
        local busy = ONB.installing == pending.key
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, pending.name)
        local bt = busy and 'Installing…' or 'Install'
        local bw = ImGui.CalcTextSize(ctx, bt) + 16
        ImGui.SameLine(ctx)
        ImGui.SetCursorScreenPos(ctx, x0 + w - bw, select(2, ImGui.GetCursorScreenPos(ctx)))
        if light_btn('install', bt, bw, false, busy or ONB.installing ~= nil) then ONB.install(pending.key) end
        ImGui.SetCursorScreenPos(ctx, x0, select(2, ImGui.GetCursorScreenPos(ctx)))
        ImGui.PushTextWrapPos(ctx, x0 + w - ImGui.GetWindowPos(ctx))
        ImGui.TextDisabled(ctx, pending.description)
        ImGui.TextDisabled(ctx, busy and 'Downloading Node and the CLI into ~/.local/node (no admin rights). '
          .. 'Takes a minute or two; you log in once it is done.'
          or 'Installs Node and the CLI into ~/.local/node, no admin rights. You log in with its own account.')
        local err = (pending.error ~= '' and pending.error) or ONB.err
        if err then ImGui.TextColored(ctx, C.razor, err) end
        ImGui.PopTextWrapPos(ctx)
      end)
    elseif cur then
      box('provider', COL, function(w, x0)
        local a = cur.real
        local st = a.acp and S.acp_status[a.slug]
        local need = st and not st.connected and st.state == 'auth_required'
        local col, state = agent_state(a)
        -- header row like "Send to track 16 …  [Delete]": icon, name · state, the provider's button on the right
        local x, y = ImGui.GetCursorScreenPos(ctx)
        local resume
        for _, x_ in ipairs(S.sessions or {}) do if x_.id == S.sid then resume = x_.resume end end
        local btext = need and 'Connect' or (cur.acp and ('Open in ' .. cur.name) or 'Open in Gamut')
        local bw = ImGui.CalcTextSize(ctx, btext) + 16
        ImGui.SetCursorScreenPos(ctx, x, y)
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, cur.name)
        if state ~= '' then
          ImGui.SameLine(ctx, 0, 8)
          local dx, dy = ImGui.GetCursorScreenPos(ctx)
          ImGui.DrawList_AddCircleFilled(dl, dx + 4, dy + fh / 2, 3, col)
          ImGui.SetCursorScreenPos(ctx, dx + 12, dy)
          ImGui.TextDisabled(ctx, state)
        end
        ImGui.SameLine(ctx)
        ImGui.SetCursorScreenPos(ctx, x0 + w - bw, y)
        local off = cur.acp and not need and not resume
        if light_btn('open', btext, bw, false, off) then
          if need then S.auth = { methods = st.methods }
          elseif cur.acp then open_in_terminal(resume)
          else open_in_gamut() end
        end
        if ImGui.IsItemHovered(ctx) and cur.acp and not need then
          show_tip(resume and ('Opens this chat in Terminal:\n' .. resume)
            or (S.sid == '' and 'No chat yet' or (cur.name .. ': no CLI on this Mac')))
        end
        local function row(lbl, draw) label(lbl, x0); draw(w - LW) end
        if not cur.acp then
          row('Agent:', function(cw)
            ImGui.SetNextItemWidth(ctx, cw)
            local nm = S.agent_name ~= '' and S.agent_name or S.agent
            local gx, gy = ImGui.GetCursorScreenPos(ctx)
            local o = ImGui.BeginCombo(ctx, '##cfg_gagent', nm, ImGui.ComboFlags_HeightLarge | ImGui.ComboFlags_NoArrowButton)
            arrows(gx + cw, gy, gy + fh)
            if o then
              for _, g in ipairs(S.agents) do
                if not g.acp then
                  local on = g.slug == S.agent
                  if ImGui.Selectable(ctx, g.name .. '##ga_' .. g.slug, on) and not on then choose_agent(g.slug, g.name); load_sessions() end
                  if g.desc ~= '' and ImGui.IsItemHovered(ctx) then show_tip(g.desc) end
                  if on then ImGui.SetItemDefaultFocus(ctx) end
                end
              end
              ImGui.EndCombo(ctx)
            end
          end)
        end
        if not cur.acp and via_gateway() then -- Gamut gives MCP servers to agents one by one
          row('REAPER:', function(cw)
            local en = ONB.reaper_enabled(S.agent)
            if en then
              local x1, y1 = ImGui.GetCursorScreenPos(ctx)
              ImGui.DrawList_AddCircleFilled(dl, x1 + 4, y1 + fh / 2, 3, C.ok)
              ImGui.SetCursorScreenPos(ctx, x1 + 12, y1)
              ImGui.AlignTextToFramePadding(ctx)
              ImGui.Text(ctx, 'enabled for this agent')
            elseif en == false then
              local busy = ONB.busy[S.agent]
              if light_btn('enreaper', busy and 'Enabling…' or 'Enable for this agent', cw, false, busy) then
                ONB.enable_reaper(S.agent)
              end
            else
              ImGui.AlignTextToFramePadding(ctx)
              ImGui.TextDisabled(ctx, 'checking…')
            end
          end)
        end
        if not (model or effort or mode) then
          ImGui.SetCursorScreenPos(ctx, x0, select(2, ImGui.GetCursorScreenPos(ctx)))
          ImGui.TextDisabled(ctx, 'loading options…')
        end
        if model then row('Model:', function(cw) combo(model, 'model', cw) end) end
        if effort then row('Effort:', function(cw) combo(effort, 'effort', cw) end) end
        if mode then row('Mode:', function(cw) combo(mode, 'mode', cw) end) end
      end)
    end
    if studio then
      ImGui.Dummy(ctx, 0, 2)
      studio.settings_changes({ section = section, box = box, light_btn = light_btn, checkbox = checkbox, COL = COL,
        dim = shade(C.win_text, 0x30) })
    end
    ImGui.EndGroup(ctx)

    -- right column (like Receives): the context switch, then one box per live REAPER selection
    ImGui.SameLine(ctx, 0, GAP)
    ImGui.BeginGroup(ctx)
    section('Context', COL)
    if checkbox('ctx', 'Send REAPER context with each message', S.ctx_level > 0, COL) then
      S.ctx_level = S.ctx_level > 0 and 0 or 1
      reaper.SetExtState(EXT, 'ctx_level', tostring(S.ctx_level), true)
    end
    if studio then
      ImGui.Dummy(ctx, 0, 2)
      studio.settings_context({ box = box, light_btn = light_btn, checkbox = checkbox, COL = COL,
        dim = shade(C.win_text, 0x30) })
    end
    ImGui.Dummy(ctx, 0, 2)
    local KIND = { razor = 'Razor area', time = 'Time selection', tracks = 'Tracks', items = 'Items',
      notes = 'MIDI notes', env = 'Envelope', fx = 'FX window' }
    local P = {}
    for _, p_ in ipairs(SEL.pills or {}) do P[#P + 1] = p_ end
    table.sort(P, function(a, b) return (SEL.at[a.k] or -1) > (SEL.at[b.k] or -1) end)
    if #P == 0 then ImGui.TextDisabled(ctx, 'Nothing selected') end
    for n, p_ in ipairs(P) do
      if n > 4 then break end
      box('sel_' .. p_.k, COL, function(w, x0)
        ImGui.Text(ctx, KIND[p_.k] or p_.k)
        local lines = 0
        for ln in (p_.detail or p_.label):gmatch('[^\n]+') do
          lines = lines + 1
          if lines > 4 then break end
          ImGui.SetCursorScreenPos(ctx, x0, select(2, ImGui.GetCursorScreenPos(ctx)))
          ImGui.TextColored(ctx, shade(C.win_text, 0x30), truncate(ln, w))
        end
      end)
    end
    ImGui.Dummy(ctx, 0, 2)
    section('Hibiki', COL)
    UPD.tick()
    REC.tick()
    box('update', COL, function(w, x0)
      local function right_btn(id, text, off)
        local bw = ImGui.CalcTextSize(ctx, text) + 16
        ImGui.SameLine(ctx)
        ImGui.SetCursorScreenPos(ctx, x0 + w - bw, select(2, ImGui.GetCursorScreenPos(ctx)))
        return light_btn(id, text, bw, false, off)
      end
      local function note(col, text)
        ImGui.SetCursorScreenPos(ctx, x0, select(2, ImGui.GetCursorScreenPos(ctx)))
        ImGui.PushTextWrapPos(ctx, x0 + w - ImGui.GetWindowPos(ctx))
        ImGui.TextColored(ctx, col, text)
        ImGui.PopTextWrapPos(ctx)
      end
      local dim = shade(C.win_text, 0x30)
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, 'Version ' .. (UPD.current or '…'))
      if right_btn('updcheck', UPD.running == 'check' and 'Checking…' or 'Check for updates', UPD.running ~= nil) then
        UPD.start('check')
      end
      if UPD.running == 'install' then note(dim, 'Downloading…')
      elseif UPD.err then note(C.razor, UPD.err)
      elseif UPD.msg then note(dim, UPD.msg)
      elseif UPD.available and UPD.latest then
        local d = UPD.date()
        ImGui.SetCursorScreenPos(ctx, x0, select(2, ImGui.GetCursorScreenPos(ctx)))
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.Text(ctx, UPD.latest .. ' available' .. (d and (' (' .. d .. ')') or ''))
        if right_btn('updinstall', 'Install', UPD.running ~= nil) then UPD.start('install') end
        if ImGui.IsItemHovered(ctx) and not UPD.running then
          show_tip(UPD.latest .. ' · download .pkg · check sha256 · open it')
        end
      elseif UPD.latest then note(dim, 'Up to date')
      elseif UPD.checked and not UPD.running then note(dim, 'No release found')
      end
      ImGui.SetCursorScreenPos(ctx, x0, select(2, ImGui.GetCursorScreenPos(ctx)))
      if checkbox('upddev', 'Include release candidates', UPD.dev(), w) then UPD.set_dev(not UPD.dev()) end
      ImGui.Dummy(ctx, 0, 4)
      ImGui.SetCursorScreenPos(ctx, x0, select(2, ImGui.GetCursorScreenPos(ctx)))
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.Text(ctx, REC.running and 'Resetting the connection…' or 'Stuck or not answering?')
      local bt = REC.running and 'Recovering…' or 'Recover'
      local bw = ImGui.CalcTextSize(ctx, bt) + 16
      ImGui.SameLine(ctx)
      ImGui.SetCursorScreenPos(ctx, x0 + w - bw, select(2, ImGui.GetCursorScreenPos(ctx)))
      if light_btn('recover', bt, bw, false, REC.running) then REC.start() end
      if ImGui.IsItemHovered(ctx) and not REC.running then
        show_tip('Stop reply · reconnect · hibiki recover · reload chat')
      end
      if REC.lines then
        ImGui.SetCursorScreenPos(ctx, x0, select(2, ImGui.GetCursorScreenPos(ctx)))
        ImGui.PushTextWrapPos(ctx, x0 + w - ImGui.GetWindowPos(ctx))
        for _, l in ipairs(REC.lines) do
          ImGui.TextColored(ctx, l.ok and shade(C.win_text, 0x30) or C.razor, l.text)
        end
        ImGui.PopTextWrapPos(ctx)
      end
    end)
    ImGui.EndGroup(ctx)

    if ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) and ImGui.IsKeyPressed(ctx, ImGui.Key_Escape) then open = false end
    local x, y = ImGui.GetWindowPos(ctx)
    local w, h = ImGui.GetWindowSize(ctx)
    reaper.SetExtState(EXT, 'cfgwin', ('%d,%d %dx%d'):format(x, y, w, h), false) -- probe: where it was drawn
    ImGui.End(ctx)
  end
  ImGui.PopFont(ctx)
  ImGui.PopStyleVar(ctx, 7)
  ImGui.PopStyleColor(ctx, #cols)
  if not open then S.cfgwin = false end
end

-- row above the input: what is selected in REAPER right now, one pill per kind, newest first;
-- the newest is outlined in accent, ones older than 2 min (or from before the panel opened) are greyed
local SEL_STALE = 120
local function sel_row_visible() return S.ctx_level > 0 and SEL.pills and #SEL.pills > 0 end
local function sel_row()
  if not sel_row_visible() then return end
  local P = {}
  for _, p in ipairs(SEL.pills) do P[#P + 1] = p end
  table.sort(P, function(a, b) return (SEL.at[a.k] or -1) > (SEL.at[b.k] or -1) end)
  local now = reaper.time_precise()
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = ImGui.GetFrameHeight(ctx) - 2
  local avail = ImGui.GetContentRegionAvail(ctx)
  local used = 0
  for n, p in ipairs(P) do
    local t = SEL.at[p.k]
    local d = t and (now - t) or nil
    local kind, value = p.label:match('^(%S+)  (.*)$')
    kind, value = kind or p.label, value or ''
    ImGui.PushFont(ctx, font_for(p.label), FONT_SIZE)
    local kw = ImGui.CalcTextSize(ctx, kind)
    local vw = ImGui.CalcTextSize(ctx, value)
    local w = 8 + kw + 6 + vw + 8
    if n > 1 then
      if used + 4 + w > avail then
        ImGui.SameLine(ctx, 0, 4)
        ImGui.AlignTextToFramePadding(ctx)
        ImGui.TextColored(ctx, C.strip_text, ('+%d'):format(#P - n + 1))
        if ImGui.IsItemHovered(ctx) then
          local rest = {}
          for m = n, #P do rest[#rest + 1] = P[m].label end
          show_tip(table.concat(rest, '\n'))
        end
        ImGui.PopFont(ctx)
        break
      end
      ImGui.SameLine(ctx, 0, 4)
      used = used + 4
    end
    used = used + w
    ImGui.InvisibleButton(ctx, '##selpill_' .. p.k, w, h)
    local x1, y1 = ImGui.GetItemRectMin(ctx)
    local hovered = ImGui.IsItemHovered(ctx)
    local stale = not d or d > SEL_STALE
    local newest = n == 1 and #P > 1 and not stale
    bevel(dl, x1, y1, x1 + w, y1 + h, hovered and C.btn_hover or C.btn)
    if newest then ImGui.DrawList_AddRect(dl, x1, y1, x1 + w, y1 + h, C.value, RND, 0, 1) end
    local ty = y1 + (h - ImGui.GetTextLineHeight(ctx)) / 2
    local kc = p.k == 'razor' and 0xFF7B72FF or C.field_text
    ImGui.DrawList_AddText(dl, x1 + 8, ty, stale and alpha(kc, 0x99) or kc, kind)
    ImGui.DrawList_AddText(dl, x1 + 8 + kw + 6, ty, stale and alpha(C.value, 0x99) or C.value, value)
    ImGui.PopFont(ctx)
    if hovered then
      show_tip(p.detail or p.label)
    end
  end
end

-- on/off toggle (LED button): the REAPER context block (see context()) goes with every message while lit
local function context_chip()
  local on = S.ctx_level > 0
  if led_toggle('ctx', 'Context', on) then
    S.ctx_level = on and 0 or 1
    reaper.SetExtState(EXT, 'ctx_level', tostring(S.ctx_level), true)
  end
  if ImGui.IsItemHovered(ctx) then
    show_tip(on and ('Sent with each message:\n' .. chip_text():gsub(' · ', '\n')) or 'Off')
  end
end

-- cards above the input: things that need you (ACP tool permission, ACP login, Gamut questions/secrets/approvals)
local function card_list()
  local L = {}
  for _, p in ipairs(S.perms) do L[#L + 1] = { kind = 'perm', key = 'p' .. p.id, p = p } end
  if S.auth and is_acp() then L[#L + 1] = { kind = 'auth', key = 'auth' } end
  for _, q in ipairs(S.greqs) do L[#L + 1] = { kind = 'greq', key = 'g' .. q.id, q = q } end
  if S.waiting and #S.greqs == 0 then L[#L + 1] = { kind = 'wait', key = 'wait' } end
  if S.agent ~= '' and not is_acp() and via_gateway() and ONB.reaper_enabled(S.agent) == false then
    L[#L + 1] = { kind = 'reaper', key = 'reaper' }
  end
  return L
end
local function cards_height(L)
  local h = 0
  for _, c in ipairs(L) do h = h + (S.card_h[c.key] or 66) + 6 end
  return h
end
local function primary(label)
  push_btn(C.accent, alpha(C.accent, 0xDD), alpha(C.accent, 0xBB), 0xFFFFFFFF)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, C.accent) -- inside card(): only the secondary buttons get the grey edge
  local clicked = ImGui.Button(ctx, label)
  ImGui.PopStyleColor(ctx, 5)
  return clicked
end
local function wrapped(text, col)
  ImGui.PushTextWrapPos(ctx, 0)
  if col then ImGui.TextColored(ctx, col, text) else ImGui.Text(ctx, text) end
  ImGui.PopTextWrapPos(ctx)
end

local GAMUT_ASKS = {
  connected_account = function(p) return 'Connect your ' .. (sval(p.toolkit) or 'account') .. ' account' end,
  file = function(p) return 'Upload a file: ' .. (sval(p.description) or '') end,
  remote_mcp = function(p) return 'Connect an MCP server: ' .. (sval(p.name) or sval(p.url) or '') end,
  browser_input = function(p) return 'Do a step in the browser: ' .. (sval(p.message) or '') end,
  computer_use = function(p) return 'Control ' .. (sval(p.appName) or 'an app') .. ' on this Mac' end,
  account_reauth_required = function(p) return 'Reconnect ' .. (sval(p.toolkit) or 'an account') end,
  mcp_reauth_required = function(p) return 'Reconnect ' .. (sval(p.mcpName) or 'an MCP server') end,
}

local function question_card(q)
  local p, id = q.payload, q.id
  local st = S.gans[id] or { sel = {}, other = {} }
  S.gans[id] = st
  local qs = type(p.questions) == 'table' and p.questions or {}
  local ready = #qs > 0
  for qi, qq in ipairs(qs) do
    if type(qq) ~= 'table' then qq = {} end
    if qi > 1 then ImGui.Spacing(ctx) end
    if sval(qq.header) then ImGui.TextDisabled(ctx, qq.header) end
    wrapped(sval(qq.question) or '')
    st.sel[qi] = st.sel[qi] or {}
    for oi, o in ipairs(type(qq.options) == 'table' and qq.options or {}) do
      local label = sval(type(o) == 'table' and o.label) or ('Option ' .. oi)
      local on = st.sel[qi][label] == true
      if on then ImGui.PushStyleColor(ctx, ImGui.Col_Text, C.accent) end
      if ImGui.Selectable(ctx, label .. '##q' .. id .. '_' .. qi .. '_' .. oi, on) then
        if qq.multiSelect == true then st.sel[qi][label] = (not on) or nil else st.sel[qi] = { [label] = true } end
      end
      if on then ImGui.PopStyleColor(ctx) end
      local d = type(o) == 'table' and sval(o.description)
      if d and d ~= '' then
        ImGui.Indent(ctx, 20)
        wrapped(d, C.muted)
        ImGui.Unindent(ctx, 20)
      end
    end
    ImGui.SetNextItemWidth(ctx, -1)
    local _, v = ImGui.InputTextWithHint(ctx, '##other' .. id .. qi, 'Other…', st.other[qi] or '')
    st.other[qi] = v
    if next(st.sel[qi]) == nil and (st.other[qi] or '') == '' then ready = false end
  end
  local function answers()
    local L = {}
    for qi, qq in ipairs(qs) do
      local picked = {}
      for _, o in ipairs(type(qq.options) == 'table' and qq.options or {}) do
        local label = sval(type(o) == 'table' and o.label)
        if label and st.sel[qi][label] then picked[#picked + 1] = label end
      end
      if (st.other[qi] or '') ~= '' then picked[#picked + 1] = st.other[qi] end
      L[#L + 1] = jstr(sval(qq.question) or ('Question ' .. qi)) .. ':' .. jstr(table.concat(picked, ', '))
    end
    return '{' .. table.concat(L, ',') .. '}'
  end
  local path = '/sessions/' .. seg(S.sid) .. '/answer-question'
  if q.sending then ImGui.TextDisabled(ctx, 'Sending…')
  else
    if ready then
      if primary('Send answer##' .. id) then answer_request(q, path, '{"toolUseId":' .. jstr(id) .. ',"answers":' .. answers() .. '}') end
    else
      ImGui.BeginDisabled(ctx)
      primary('Send answer##' .. id)
      ImGui.EndDisabled(ctx)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, 'Skip##' .. id) then answer_request(q, path, '{"toolUseId":' .. jstr(id) .. ',"decline":true}') end
  end
end

local function greq_card(q, who)
  local p, id, kind = q.payload, q.id, q.kind
  local sid = S.sid
  local tid = '"toolUseId":' .. jstr(id)
  if kind == 'question' then
    question_card(q)
  elseif kind == 'secret' then
    wrapped(sval(p.reason) or (who .. ' needs a secret'))
    ImGui.TextDisabled(ctx, sval(p.secretName) or '')
    local st = S.gans[id] or { value = '' }
    S.gans[id] = st
    ImGui.SetNextItemWidth(ctx, -1)
    local _, v = ImGui.InputTextWithHint(ctx, '##secret' .. id, 'Paste the value', st.value, ImGui.InputTextFlags_Password)
    st.value = v
    if not q.sending then
      if st.value ~= '' and primary('Save##' .. id) then
        answer_request(q, '/sessions/' .. seg(sid) .. '/provide-secret',
          '{' .. tid .. ',"secretName":' .. jstr(sval(p.secretName) or '') .. ',"value":' .. jstr(st.value) .. '}')
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Decline##' .. id) then answer_request(q, '/sessions/' .. seg(sid) .. '/provide-secret', '{' .. tid .. ',"decline":true}') end
    end
  elseif kind == 'script_run' then
    wrapped(sval(p.explanation) or (who .. ' wants to run a script'))
    -- open by default: Run approves this script, not the agent's explanation of it
    if sval(p.script) and ImGui.TreeNode(ctx, 'Script (' .. (sval(p.scriptType) or 'shell') .. ')##' .. id,
        ImGui.TreeNodeFlags_DefaultOpen) then
      ImGui.PushFont(ctx, F.mono, FONT_SIZE - 1)
      wrapped(p.script, C.muted)
      ImGui.PopFont(ctx)
      ImGui.TreePop(ctx)
    end
    if not q.sending then
      if primary('Run##' .. id) then
        answer_request(q, '/sessions/' .. seg(sid) .. '/run-script',
          '{' .. tid .. ',"script":' .. jstr(sval(p.script) or '') .. ',"scriptType":' .. jstr(sval(p.scriptType) or '') .. '}')
      end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Deny##' .. id) then answer_request(q, '/sessions/' .. seg(sid) .. '/run-script', '{' .. tid .. ',"decline":true}') end
    end
  elseif kind == 'capability_review' then
    wrapped(who .. ' wants to use ' .. (sval(p.toolName) or sval(p.capability) or 'a capability'))
    if not q.sending then
      local cap = ',"capability":' .. jstr(sval(p.capability) or '')
      local path = '/sessions/' .. seg(sid) .. '/capability-review'
      if primary('Allow once##' .. id) then answer_request(q, path, '{' .. tid .. cap .. ',"scope":"once"}') end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Allow for this chat##' .. id) then answer_request(q, path, '{' .. tid .. cap .. ',"scope":"session"}') end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Deny##' .. id) then answer_request(q, path, '{' .. tid .. cap .. ',"decline":true}') end
    end
  elseif kind == 'proxy_review' or kind == 'x_agent_review' then
    local what
    local xa = type(p.xAgent) == 'table' and p.xAgent
    if xa then
      what = (sval(xa.operation) or 'contact') .. ' ' .. (sval(xa.targetAgentName) or sval(xa.targetAgentSlug) or 'another agent')
    else
      what = (sval(p.toolkit) or 'an account') .. ': ' .. (sval(p.endpointDescription) or ((sval(p.method) or '') .. ' ' .. (sval(p.targetPath) or '')))
    end
    wrapped(who .. ' wants to ' .. (xa and what or ('call ' .. what)))
    if xa and sval(xa.preview) then wrapped(xa.preview, C.muted) end
    if not q.sending then
      if primary('Allow##' .. id) then answer_request(q, '/proxy-review/' .. seg(id), '{"decision":"allow"}') end
      ImGui.SameLine(ctx)
      if ImGui.Button(ctx, 'Deny##' .. id) then answer_request(q, '/proxy-review/' .. seg(id), '{"decision":"deny"}') end
    end
  else
    local f = GAMUT_ASKS[kind]
    wrapped(f and f(p) or (who .. ' needs something from you (' .. kind .. ')'))
    if sval(p.reason) then wrapped(p.reason, C.muted) end
    if primary('Open in Gamut##' .. id) then open_in_gamut() end
  end
  if q.err then wrapped(q.err, C.danger) end
end

local CHILD_BORDERS = ImGui.ChildFlags_Borders or ImGui.ChildFlags_Border or 1
local function card(c)
  local who = S.agent_name ~= '' and S.agent_name or S.agent
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, C.panel)
  ImGui.PushStyleColor(ctx, ImGui.Col_Border, C.border)
  -- secondary buttons get a face and an edge: Col_Button is C.panel, the card's own fill
  ImGui.PushStyleColor(ctx, ImGui.Col_Button, C.btn)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonHovered, C.btn_hover)
  ImGui.PushStyleColor(ctx, ImGui.Col_ButtonActive, C.btn_down)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FrameBorderSize, 1)
  ImGui.SetNextWindowSizeConstraints(ctx, 0, 0, 100000, 340)
  local open = ImGui.BeginChild(ctx, 'card_' .. c.key, 0, 0, CHILD_BORDERS | ImGui.ChildFlags_AutoResizeY)
  if open then
    local w = ImGui.GetContentRegionAvail(ctx)
    if c.kind == 'perm' then
      wrapped(who .. ' wants to: ' .. c.p.title)
      local primed = false
      for k, o in ipairs(c.p.options) do
        if k > 1 then ImGui.SameLine(ctx) end
        local label = (sval(o.name) or sval(o.optionId) or '?') .. '##' .. c.p.id .. k
        local allow = (sval(o.kind) or ''):match('^allow')
        local clicked
        if allow and not primed then primed = true; clicked = primary(label) else clicked = ImGui.Button(ctx, label) end
        if clicked then answer_perm(c.p, sval(o.optionId)) end
      end
      if #c.p.options == 0 and ImGui.Button(ctx, 'Deny##' .. c.p.id) then answer_perm(c.p, nil) end
    elseif c.kind == 'auth' then
      if S.auth.waiting then
        wrapped('Finish the ' .. who .. ' login in ' .. (S.auth.terminal and 'the Terminal window' or 'your browser'))
      else
        wrapped(who .. ' is not connected yet')
        for k, m in ipairs(S.auth.methods) do
          if k > 1 then ImGui.SameLine(ctx) end
          local name = sval(m.name) or sval(m.id) or '?'
          local verb = name:match('^Log') or name:match('^Sign') or name:match('^Connect')
          local label = ((k == 1 and not verb) and 'Connect with ' or '') .. name .. '##auth' .. k
          local clicked = (k == 1) and primary(label) or ImGui.Button(ctx, label)
          if clicked then start_login(sval(m.id), sval(m.type) == 'terminal') end
          if sval(m.description) and ImGui.IsItemHovered(ctx) then show_tip(m.description) end
        end
        if #S.auth.methods == 0 then ImGui.TextDisabled(ctx, 'Checking…') end
      end
      if S.auth.err then wrapped(S.auth.err, C.danger) end
    elseif c.kind == 'greq' then
      greq_card(c.q, who)
    elseif c.kind == 'reaper' then
      wrapped(who .. " can't use REAPER yet")
      if primary((ONB.busy[S.agent] and 'Enabling…' or 'Enable REAPER for ' .. who) .. '##enreaper') and not ONB.busy[S.agent] then
        ONB.enable_reaper(S.agent)
      end
      if ONB.err then wrapped(ONB.err, C.danger) end
    else
      ImGui.Text(ctx, truncate(who .. ' is asking you something', w))
      if primary('Answer in Gamut') then open_in_gamut() end
    end
    ImGui.EndChild(ctx)
    local _, h = ImGui.GetItemRectSize(ctx)
    S.card_h[c.key] = h
  end
  ImGui.PopStyleVar(ctx)
  ImGui.PopStyleColor(ctx, 5)
end

local spin = { '·  ', '·· ', '···', ' ··', '  ·', '   ' }
local DOCK_FLAG = 'docked_v4' -- bumped when the context name changes: ReaImGui forgets the dock with it

-- Port of Gamut's follow engine (SuperAgent use-message-list-scroll.ts): following pins the live edge as content
-- grows; an upward wheel escapes at once; coming back within ATTACH_PX re-engages. Motion is a time-based
-- exponential chase so it is frame-rate independent at REAPER's ~33 fps defer.
local ATTACH_PX = 70
local function scroll_engine()
  local SNAP_GAP_PX, CHASE_RATE = 120, 30
  local now = reaper.time_precise()
  local dt = math.min(0.064, now - (S.sc_t or now))
  S.sc_t = now
  local cur, maxy = ImGui.GetScrollY(ctx), ImGui.GetScrollMaxY(ctx)
  if S.follow == nil then S.follow = true end
  if not S.sy_target or math.abs(cur - (S.sy_last or cur)) > 0.5 then
    S.sy_target = cur
    if S.sy_last then S.follow = maxy - cur <= ATTACH_PX end
  end
  if S.scroll then S.follow, S.trip, S.scroll = true, true, false end
  local wheel = ImGui.IsWindowHovered(ctx) and ImGui.GetMouseWheel(ctx) or 0
  if wheel ~= 0 then
    S.trip = false
    S.sy_target = math.max(0, math.min(maxy, S.sy_target - wheel * FONT_SIZE * 5))
    if wheel > 0 then S.follow = false elseif maxy - S.sy_target <= ATTACH_PX then S.follow = true end
  end
  if S.follow then
    S.sy_target = maxy
    if not S.trip and wheel == 0 and maxy - cur > SNAP_GAP_PX then cur = maxy end
  end
  local d = S.sy_target - cur
  local ny = cur
  if math.abs(d) > 0.5 then ny = cur + d * (1 - math.exp(-dt * CHASE_RATE)) end
  if math.abs(S.sy_target - ny) <= 1 then ny = S.sy_target; S.trip = false end
  if ny ~= ImGui.GetScrollY(ctx) then ImGui.SetScrollY(ctx, ny) end
  S.sy_last = ny
end

-- the conversation. Every element (sent message, reply, tool line) remembers its drawn height; one whose height is
-- known for this width and palette and lies outside the visible scroll range is replaced by a Dummy of that height,
-- so off-screen history costs two calls and the scroll range (and scroll_engine) stays exact. Only a window of the
-- newest messages (S.win_from..) is walked at all: reaching the top grows it by WIN, following the live edge cuts it
-- back to the last WIN, and each change shifts the scroll by the height it added or removed above the viewport
local draw_log
do
  local W, SP, V0, V1 = 0, 6, 0, 0
  local function skip(holder, slot, key)
    local c = holder[slot]
    local y = ImGui.GetCursorPosY(ctx)
    if c and c.w == W and c.key == key and c.pal == pal_ver and (y + c.h < V0 or y > V1) then
      ImGui.Dummy(ctx, W, math.max(0, c.h - SP))
      return true, y
    end
    return false, y
  end
  local function measured(holder, slot, key, y)
    local c = holder[slot]
    if not c then c = {}; holder[slot] = c end
    c.w, c.key, c.pal, c.h = W, key, pal_ver, ImGui.GetCursorPosY(ctx) - y
  end
  local flush, to_lane
  do
  local lane, lane_holder, lane_id = {}, nil, ''
  function flush()
    if #lane == 0 then return end
    local skipped, y = skip(lane_holder, '_hl', #lane)
    if not skipped then
      tool_lane(lane, lane_id, lane_holder)
      ImGui.Spacing(ctx)
      measured(lane_holder, '_hl', #lane, y)
    end
    for i = #lane, 1, -1 do lane[i] = nil end
  end
  function to_lane(holder, id, labels)
    if #lane == 0 then lane_id, lane_holder = id, holder end
    for _, l in ipairs(labels) do lane[#lane + 1] = l end
  end
  end
  local draw_msg
  do
  local function user_msg(m, id)
    if m._had == nil then
      m._body, m._had, m._ctx = split_context(m.text)
      local at = m._body:find('[Attached files:]', 1, true)
      if at then
        local names = {}
        for path in m._body:sub(at):gmatch('\n%- ([^\n]+)') do names[#names + 1] = path:match('[^/]+$') or path end
        m._files = table.concat(names, ', ')
        m._body = m._body:sub(1, at - 1):gsub('%s+$', '')
      end
    end
    if m._had then ctx_tag(m, id) end
    if m._body ~= '' then bubble(m, m._body) end
    if m._files then
      ImGui.PushTextWrapPos(ctx, 0)
      ImGui.TextDisabled(ctx, 'Attached: ' .. m._files)
      ImGui.PopTextWrapPos(ctx)
    end
    ImGui.Spacing(ctx)
  end
  function draw_msg(m, id)
    local tools = m.tools and #m.tools > 0
    if m.role == 'user' then
      flush()
      local skipped, y = skip(m, '_h', 0)
      if not skipped then user_msg(m, id); measured(m, '_h', 0, y) end
    elseif m.text ~= '' then
      flush()
      local skipped, y = skip(m, '_h', #m.text)
      if not skipped then
        md(m, m.text)
        if not tools then ImGui.Spacing(ctx) end
        measured(m, '_h', #m.text, y)
      end
    end
    if m.role ~= 'user' and tools then
      if not m._tl then
        m._tl = {}
        for _, n in ipairs(m.tools) do m._tl[#m._tl + 1] = tool_label(n) end
      end
      to_lane(m, id, m._tl)
    end
  end
  end
  local one, WIN = {}, 60
  local function tools_of(m) return m and m.role ~= 'user' and m.tools and #m.tools > 0 end
  -- a window never starts inside a run of tool-only replies: the whole run is one lane, held by its first message
  local function boundary(i)
    local msgs = S.msgs
    i = math.max(1, i)
    while i > 1 and msgs[i] and msgs[i].text == '' and tools_of(msgs[i]) and tools_of(msgs[i - 1]) do i = i - 1 end
    return i
  end
  local function shift(d, sy)
    if d == 0 then return end
    S.sy_last = math.max(0, (S.sy_last or sy) + d)
    S.sy_target = math.max(0, (S.sy_target or sy) + d)
    ImGui.SetScrollY(ctx, S.sy_last)
  end
  function draw_log()
    W = math.floor(ImGui.GetContentRegionAvail(ctx))
    local _, sp = ImGui.GetStyleVar(ctx, ImGui.StyleVar_ItemSpacing)
    SP = sp or 6
    local sy, wh = ImGui.GetScrollY(ctx), ImGui.GetWindowHeight(ctx)
    V0, V1 = sy - 200, sy + wh + 200
    local msgs, n = S.msgs, #S.msgs
    if not S.win_from or S.win_from > math.max(1, n) then S.win_from = boundary(n - WIN + 1) end
    local from, cut, grow = boundary(S.win_from), nil, false
    if S.follow and n - from + 1 > WIN and (n ~= S.win_n or n - from + 1 > 3 * WIN) then
      cut = boundary(n - WIN + 1)
      if cut <= from then cut = nil end
    end
    S.win_n = n
    if from > 1 then
      ImGui.TextDisabled(ctx, 'Load earlier messages')
      grow = ImGui.IsItemClicked(ctx) or (S.follow == false and (S.sy_last or sy) <= 2)
      if grow then cut = nil end
    end
    local y_first, y_cut = ImGui.GetCursorPosY(ctx), nil
    for i = from, n do
      if i == cut then flush(); y_cut = ImGui.GetCursorPosY(ctx) end
      draw_msg(msgs[i], i)
    end
    for i, b in ipairs(S.live) do
      if b.kind == 'text' then
        flush()
        local skipped, y = skip(b, '_h', #b.text)
        if not skipped then md(b, b.text); measured(b, '_h', #b.text, y) end
      else
        one[1] = b.text
        to_lane(b, 'live' .. i, one)
      end
    end
    flush()
    for i, m in ipairs(S.queued) do draw_msg(m, 'q' .. i) end
    flush()
    if S.active and not S.waiting then
      local s = spin[(math.floor(reaper.time_precise() * 6) % #spin) + 1]
      ImGui.TextColored(ctx, C.accent, 'Working ' .. s)
    end
    if S.err then ImGui.TextColored(ctx, C.danger, S.err) end
    S.win_from = from
    if y_cut then
      S.win_from = cut
      shift((from == 1 and ImGui.GetTextLineHeight(ctx) + SP or 0) - (y_cut - y_first), sy)
    elseif grow then
      -- the older messages are laid out once below everything, out of sight, so their heights are known before
      -- they move to the top next frame together with the compensating scroll
      local nf = boundary(from - WIN)
      local gap = sy + wh - ImGui.GetCursorPosY(ctx)
      if gap > 0 then ImGui.Dummy(ctx, W, gap) end
      local ya = ImGui.GetCursorPosY(ctx)
      for i = nf, from - 1 do draw_msg(msgs[i], i) end
      flush()
      local h = ImGui.GetCursorPosY(ctx) - ya
      S.win_from = nf
      shift(h - (nf == 1 and ImGui.GetTextLineHeight(ctx) + SP or 0), sy)
    end
  end
end

local perf = { n = 0, sum = 0, max = 0, gap = 0, last = reaper.time_precise(), at = reaper.time_precise() }
local function perf_tick(t0)
  local t1 = reaper.time_precise()
  local dt = t1 - t0
  perf.n, perf.sum = perf.n + 1, perf.sum + dt
  if dt > perf.max then perf.max = dt end
  if t0 - perf.last > perf.gap then perf.gap = t0 - perf.last end
  perf.last = t0
  if t1 - perf.at >= 1 then
    reaper.SetExtState(EXT, 'perf', ('fps=%.1f lua_avg_ms=%.2f lua_max_ms=%.2f max_gap_ms=%.1f'):format(
      perf.n / (t1 - perf.at), perf.sum / perf.n * 1000, perf.max * 1000, perf.gap * 1000), false)
    perf.n, perf.sum, perf.max, perf.gap, perf.at = 0, 0, 0, 0, t1
  end
end

local ime_scan
do
local IME_NAV = { 'Key_LeftArrow', 'Key_RightArrow', 'Key_UpArrow', 'Key_DownArrow', 'Key_Home', 'Key_End',
  'Key_PageUp', 'Key_PageDown', 'Key_Delete' }
local function pressed(name) return ImGui.IsKeyPressed(ctx, ImGui[name]) end
-- returns 'enter' (IME commit, don't send), 'restore' (undo ImGui's edit) or nil; tracks S.ime = typed pinyin
function ime_scan()
  if not S.comp_active then S.ime = ''; return nil end
  local chars = 0
  while ImGui.GetInputQueueCharacter(ctx, chars) do chars = chars + 1 end
  local act
  if #S.ime > 0 then
    if pressed('Key_Enter') or pressed('Key_KeypadEnter') then act = 'enter'; S.ime = ''
    elseif pressed('Key_Escape') then act = 'restore'; S.ime = ''
    elseif pressed('Key_Backspace') then act = 'restore'; S.ime = S.ime:sub(1, -2)
    else
      for _, k in ipairs(IME_NAV) do if pressed(k) then act = 'restore'; break end end
    end
    if chars > 0 then S.ime = '' end
  end
  local mods = ImGui.GetKeyMods(ctx)
  if chars == 0 and mods & (ImGui.Mod_Ctrl | ImGui.Mod_Super | ImGui.Mod_Alt) == 0 then
    for i = 0, 25 do
      if ImGui.IsKeyPressed(ctx, ImGui.Key_A + i, false) then S.ime = S.ime .. string.char(97 + i) end
    end
    if #S.ime > 0 and ImGui.IsKeyPressed(ctx, ImGui.Key_Apostrophe, false) then S.ime = S.ime .. "'" end
  end
  return act
end
end

local safe_frame
-- scripted demo for screen recordings: ExtState Hibiki/demo_agent (slug), demo_new ('1') and demo_type (text) make
-- the panel switch agent, open a new chat and type the text at a human pace, then send it
local demo_tick do
  local D
  demo_tick = function(now)
    local agent = reaper.GetExtState(EXT, 'demo_agent')
    if agent ~= '' then
      reaper.DeleteExtState(EXT, 'demo_agent', false)
      if agent ~= S.agent then choose_agent(agent, reaper.GetExtState(EXT, 'demo_agent_name')) end
    end
    if reaper.GetExtState(EXT, 'demo_new') == '1' then
      reaper.DeleteExtState(EXT, 'demo_new', false)
      new_chat()
    end
    local text = reaper.GetExtState(EXT, 'demo_type')
    if text ~= '' then
      reaper.DeleteExtState(EXT, 'demo_type', false)
      D = { text = text, n = 0, next = now + 0.6 }
      S.input = ''
    end
    if not D or now < D.next then return end
    if D.n >= #D.text then
      D = nil
      send()
      return
    end
    local n = D.n + 1
    while n < #D.text and D.text:byte(n + 1) >= 0x80 and D.text:byte(n + 1) < 0xC0 do n = n + 1 end
    D.n = n
    S.input = D.text:sub(1, n)
    local ch = D.text:sub(n, n)
    D.next = now + (ch == ' ' and 0.09 or (ch:match('[,.]') and 0.25 or 0.045 + (n * 7919 % 5) * 0.012))
    if D.n >= #D.text then D.next = now + 0.7 end
  end
end

-- per-section frame timing for diagnosis: ExtState Hibiki/profile = 1 → averages (ms) in ExtState Hibiki/prof each second
local pm do
  local on, last, acc, n, at, checked = false, 0, {}, 0, 0, 0
  pm = function(name)
    local now = reaper.time_precise()
    if name == nil then
      if now - checked > 1 then checked = now; on = reaper.GetExtState(EXT, 'profile') == '1' end
      if on then
        n = n + 1
        if now - at >= 1 and n > 0 then
          local parts = {}
          for k, v in pairs(acc) do parts[#parts + 1] = ('%s=%.2f'):format(k, v * 1000 / n) end
          table.sort(parts)
          parts[#parts + 1] = ('| md_layouts/s=%d ops/frame=%d'):format(S.n_lay or 0, (S.n_ops or 0) // n)
          S.n_lay, S.n_ops = 0, 0
          reaper.SetExtState(EXT, 'prof', table.concat(parts, ' '), false)
          acc, n, at = {}, 0, now
        end
      end
      last = now
      return
    end
    if not on then return end
    acc[name] = (acc[name] or 0) + (now - last)
    last = now
  end
end

-- studio.lua sits next to this file (Scripts/Hibiki/); without it the panel is plain chat
do
  local dir = (select(2, reaper.get_action_context()) or ''):match('^(.*[/\\])') or ''
  if HIBIKI_TEST then dir = HIBIKI_TEST.dir or dir end
  local path = dir .. 'studio.lua'
  local f = io.open(path, 'rb')
  if f then
    f:close()
    local ok, mod = pcall(dofile, path)
    if ok and type(mod) == 'function' then
      ok, mod = pcall(mod, { ImGui = ImGui, ctx = ctx, S = S, C = C, EXT = EXT, DIR = DIR, WIN = WIN, decode = decode,
        jstr = jstr, q = q, sh = sh, win_bg = win_bg, http_url = http_url, gateway = HOSTS[1], cli = REC.cli,
        add_file = ATT.add, chip = chip, led_toggle = led_toggle, primary = primary, wrapped = wrapped,
        show_tip = show_tip, truncate = truncate })
    end
    if ok and type(mod) == 'table' then studio = mod
    else reaper.SetExtState(EXT, 'error', 'studio.lua: ' .. tostring(mod):sub(1, 2000), false) end
  end
end

local function frame()
  local t0 = reaper.time_precise()
  pm()
  if S.auth and (S.auth.waiting or #S.auth.methods == 0) and t0 - (S.auth_at or 0) > 2 then load_status() end
  if S.waiting and #S.greqs == 0 and t0 - S.greq_at > 3 then load_requests() end
  check_theme()
  pm('theme')
  sel_tick()
  pm('sel')
  poll_http()
  pm('http')
  poll_stream()
  pm('sse')
  if studio then studio.tick(t0) end
  if S.err_turn and t0 - S.err_turn > ERR.wait then ERR.settle() end
  demo_tick(t0)
  if S.title_checks and S.title_checks[1] and t0 >= S.title_checks[1] then
    table.remove(S.title_checks, 1)
    if S.sid ~= '' then load_sessions() end
  end
  ImGui.PushFont(ctx, F.reg, FONT_SIZE)
  for _, c in ipairs(COLORS) do ImGui.PushStyleColor(ctx, c[1], c[2]) end
  for _, v in ipairs(VARS) do ImGui.PushStyleVar(ctx, v[1], v[2], v[3]) end
  if reaper.GetExtState(EXT, DOCK_FLAG) ~= '1' then
    ImGui.SetNextWindowDockID(ctx, -2) -- REAPER docker #2 (right side)
    reaper.SetExtState(EXT, DOCK_FLAG, '1', true)
  end
  ImGui.SetNextWindowSize(ctx, 420, 680, ImGui.Cond_FirstUseEver)
  -- the chat view sizes itself (log child + composer): no window scrollbar, no wheel nudge; onboarding still scrolls
  local wflags = ImGui.WindowFlags_NoCollapse
  -- unless last frame's cards left the log under 60 px: then the window scrolls so the input and card buttons stay reachable
  if S.agent ~= '' and S.chat_fits ~= false then wflags = wflags | ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse end
  local visible, open = ImGui.Begin(ctx, 'Hibiki', true, wflags)
  if visible then
    local px, py = ImGui.GetWindowPos(ctx)
    local pw, ph = ImGui.GetWindowSize(ctx)
    S.panel_rect = { px, py, pw, ph }
  end
  -- with the panel focused REAPER never sees the key, so Cmd+L has to close it from inside (Cmd = Mod_Ctrl on macOS)
  if visible and ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows) and
      (ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | ImGui.Key_L) or ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Super | ImGui.Key_L)) then
    open = false
  end
  pm('pre')
  if visible then
    header()
    pm('header')

    if S.agent == '' then
      -- onboarding: no agent chosen yet
      ONB.tick()
      ImGui.Dummy(ctx, 0, 24)
      ImGui.PushTextWrapPos(ctx, 0)
      ImGui.PushFont(ctx, F.bold, FONT_SIZE + 2)
      ImGui.Text(ctx, 'Connect an agent')
      ImGui.PopFont(ctx)
      ImGui.TextDisabled(ctx, 'Hibiki is the panel; the agent that does the work is yours to pick.')
      ImGui.Dummy(ctx, 0, 6)
      if #S.agents > 0 then
        ImGui.Text(ctx, #S.agents == 1 and 'One agent is ready.' or (#S.agents .. ' agents are ready.'))
        if chip('onb_open', 'Choose one', C.accent, false) then S.cfgwin = true end
        ImGui.Dummy(ctx, 0, 6)
      end
      if ONB.installable then
        local any = false
        for _, x in ipairs(ONB.installable) do
          if not x.installed then
            if any then ImGui.SameLine(ctx, 0, 4) end
            any = true
            local busy = ONB.installing == x.key
            if chip('onb_' .. x.key, busy and ('Installing ' .. x.name .. '…') or ('Install ' .. x.name), C.accent, false)
                and not ONB.installing then
              ONB.install(x.key)
            end
            if ImGui.IsItemHovered(ctx) then show_tip(x.description .. '\n~/.local/node · no admin rights · own login') end
          end
        end
        if any then ImGui.TextDisabled(ctx, 'A coding-agent CLI with its own login. One click, about a minute.') end
        if ONB.err then ImGui.TextColored(ctx, C.danger, ONB.err) end
        ImGui.Dummy(ctx, 0, 6)
      elseif ONB.installable == false then
        ImGui.TextColored(ctx, C.warn, 'Gateway not answering · hibiki doctor')
        ImGui.Dummy(ctx, 0, 6)
      end
      if chip('onb_gamut', 'Download Gamut', C.text, false) then ONB.open_url(ONB.gamut_url) end
      ImGui.TextDisabled(ctx, 'Gamut: the desktop app with agents, skills and dashboards. Sign in with a Gamut account; '
        .. 'it sets up its own containers and models. Once it runs, its agents appear here.')
      ImGui.PopTextWrapPos(ctx)
    else
      local cards = card_list()
      pm('cards')
      if S.sel and not S.sel_clicked and ImGui.IsMouseClicked(ctx, 0) then S.sel = nil end -- clicked elsewhere
      if S.sel and not S.comp_active and not S.sel.drag
          and ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | ImGui.Key_C) then
        ImGui.SetClipboardText(ctx, selected_text(S.sel))
      end
      local composer_h = 98 + cards_height(cards) + (#S.files > 0 and 30 or 0)
        + (sel_row_visible() and ImGui.GetFrameHeightWithSpacing(ctx) or 0) + (studio and studio.rack_height() or 0)
      S.chat_fits = select(2, ImGui.GetContentRegionAvail(ctx)) - composer_h >= 60
      S.sel_clicked = false
      if ImGui.BeginChild(ctx, 'log', 0, -composer_h, 0, ImGui.WindowFlags_NoScrollWithMouse) then
        scroll_engine()
        draw_log()
        ImGui.EndChild(ctx)
      end
      pm('log')
      ATT.drop() -- files dropped on the conversation attach too
      do -- the composer is a track-panel strip as well
        local _, cy = ImGui.GetCursorScreenPos(ctx)
        local wx, wy = ImGui.GetWindowPos(ctx)
        local ww, wh = ImGui.GetWindowSize(ctx)
        ImGui.DrawList_AddRectFilled(ImGui.GetWindowDrawList(ctx), wx + 6, cy - 4, wx + ww - 6, wy + wh - 6, C.strip, RND_STRIP)
      end

      for _, c in ipairs(cards) do card(c) end
      if studio then studio.rack_row() end
      do -- attachments waiting to be sent, one chip per file or per group; × removes it
        local n, seen = 0, {}
        for i, f in ipairs(S.files) do
          if not (f.group and seen[f.group]) then
            if f.group then seen[f.group] = true end
            n = n + 1
            if n > 1 then ImGui.SameLine(ctx, 0, 4) end
            local function mine(x) return x == f or (f.group ~= nil and x.group == f.group) end
            if chip('file' .. i, (f.group or f.name) .. '  ×', C.text, false) then
              for j = #S.files, 1, -1 do if mine(S.files[j]) then table.remove(S.files, j) end end
              break
            end
            if ImGui.IsItemHovered(ctx) then
              local paths = {}
              for _, x in ipairs(S.files) do if mine(x) then paths[#paths + 1] = x.path end end
              show_tip(table.concat(paths, '\n'))
            end
          end
        end
      end
      sel_row()

      if S.focus then ImGui.SetKeyboardFocusHere(ctx); S.focus = false end
      local ime = ime_scan()
      local flags = ImGui.InputTextFlags_CallbackAlways
      if ime == 'enter' then
        -- plain multiline flags: Enter becomes a newline after the committed letters, which the callback strips
        ImGui.Function_SetValue(ime_cb, 'strip_nl', 1)
      else
        flags = flags | ImGui.InputTextFlags_EnterReturnsTrue
        -- Dear ImGui has no Shift+Enter option: dropping CtrlEnterForNewLine while Shift is held makes Enter a newline
        if not ImGui.IsKeyDown(ctx, ImGui.Mod_Shift) then flags = flags | ImGui.InputTextFlags_CtrlEnterForNewLine end
        if ime == 'restore' then ImGui.Function_SetValue(ime_cb, 'restore', 1) end
      end
      -- a request to clear ImGui's own buffer only makes sense while the input is active; when it isn't, the
      -- emptied S.input is what ImGui loads on activation. Never leave the flag pending for a later frame.
      if S.clear_input and S.comp_active then ImGui.Function_SetValue(ime_cb, 'clear', 1) end
      S.clear_input = false
      -- Cmd+V with files / a screenshot on the clipboard: attach them, and undo the names ImGui pastes as text
      if S.comp_active and (ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | ImGui.Key_V)
          or ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Super | ImGui.Key_V)) and ATT.paste() > 0 then
        ImGui.Function_SetValue(ime_cb, 'restore', 1)
      end
      local before = S.input
      local entered
      entered, S.input = ImGui.InputTextMultiline(ctx, '##input', S.input, -1, 62, flags, ime_cb)
      ATT.drop()
      -- callback flags are one-frame requests: an inactive input never ran the callback, so drop them here
      ImGui.Function_SetValue(ime_cb, 'clear', 0)
      ImGui.Function_SetValue(ime_cb, 'restore', 0)
      ImGui.Function_SetValue(ime_cb, 'strip_nl', 0)
      local x1, y1 = ImGui.GetItemRectMin(ctx)
      local x2, y2 = ImGui.GetItemRectMax(ctx)
      local focused = ImGui.IsItemActive(ctx)
      if ime == 'restore' and not focused then S.input = before; S.focus = true; focused = true end -- Esc deactivated it
      S.comp_active = focused
      ImGui.DrawList_AddRect(ImGui.GetWindowDrawList(ctx), x1, y1, x2, y2,
        focused and C.value or C.btn_lo, RND, 0, 1)
      if entered then send() end
      if chip('attach', '+ File', C.muted, false) then
        local ok, fn = reaper.GetUserFileNameForRead('', 'Attach a file', '')
        if ok then ATT.add(fn) end
      end
      ImGui.SameLine(ctx, 0, 4)
      context_chip()
      if studio then ImGui.SameLine(ctx, 0, 4); studio.ears_chip() end
      local hint = (S.ime and #S.ime > 0) and ('Pinyin: ' .. S.ime) or (studio and studio.hint())
        or (S.uploading and ('Uploading ' .. S.uploading .. (S.uploading == 1 and ' file…' or ' files…')))
        or 'Enter to send'
      ImGui.PushFont(ctx, font_for(hint), FONT_SIZE) -- measure and draw in the same font
      ImGui.SameLine(ctx)
      local full_hint = hint
      hint = truncate(hint, ImGui.GetContentRegionAvail(ctx) - 4) -- a long note (a path, an error) stays inside the strip
      local hw = ImGui.CalcTextSize(ctx, hint)
      local gap = ImGui.GetContentRegionAvail(ctx) - hw
      if gap > 0 then ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + gap) end
      ImGui.AlignTextToFramePadding(ctx)
      ImGui.TextColored(ctx, (S.ime and #S.ime > 0) and C.field or C.strip_text, hint)
      ImGui.PopFont(ctx)
      if ImGui.IsItemHovered(ctx) then
        show_tip(hint ~= full_hint and full_hint or 'Enter send\nShift+Enter new line\nCmd+C copy selection\n'
          .. 'Right-click copy message\n/remember <rule> add an agent rule\nCmd+L show/hide')
      end
    end
    pm('composer')
    ImGui.End(ctx)
  end
  pm('end')
  cfg_window()
  pm('settings')
  ImGui.PopStyleVar(ctx, #VARS)
  ImGui.PopStyleColor(ctx, #COLORS)
  ImGui.PopFont(ctx)
  perf_tick(t0)
  if open then reaper.defer(safe_frame) end
end
-- a crash leaves its traceback in ExtState Hibiki/error (read it via MCP) before REAPER shows the error
safe_frame = function()
  local ok, err = xpcall(frame, debug.traceback)
  if not ok then
    reaper.SetExtState(EXT, 'error', tostring(err):sub(1, 3000), false)
    error(err, 0)
  end
end

-- remember our own action id so panel/restart_apply.sh can bind Cmd+L on any machine
do
  local _, _, _, cmd = reaper.get_action_context()
  local named = reaper.ReverseNamedCommandLookup(cmd)
  if named then reaper.SetExtState(EXT, 'action', '_' .. named, true) end
end
if reaper.set_action_options then reaper.set_action_options(1 | 4) end
reaper.atexit(function()
  stream_stop()
  if studio then studio.exit() end
  if reaper.set_action_options then reaper.set_action_options(8) end
end)
if S.agent ~= '' then cfg_load() end
S.boot = true
load_agents()
if HIBIKI_TEST then -- panel/test_panel.py drives the panel from here, without a window
  return { S = S, poll_http = poll_http, poll_stream = poll_stream, send = send, load_agents = load_agents,
    greq_card = greq_card, decode = decode, jstr = jstr, context = context, sel_tick = sel_tick, SEL = SEL,
    ONB = ONB, REC = REC, UPD = UPD, DIR = DIR, q = q, F = F, layout_md = layout_md, md_layout = md_layout,
    draw_log = draw_log, truncate = truncate, frame = frame, refresh_messages = refresh_messages,
    demo_tick = demo_tick, studio = studio, card_list = card_list, ATT = ATT }
end
reaper.defer(safe_frame)
