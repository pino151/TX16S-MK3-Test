-- Pre-race screen for 128x64 radios: the ELRS TX module and the quad's FC.
-- Reads the ELRS settings over the CRSF parameter protocol (as the ELRS Lua
-- does), writes changes, and asks the FC for its VTX setting over MSP.
-- Kept small for the TX12's memory: only the fields the screen shows, and
-- option lists stay as the module's own ";" separated strings.
-- Must run on Lua 5.2 (EdgeTX up to 2.10) and 5.3 (2.11 and later).

local M = {}

local push, pop = crossfireTelemetryPush, crossfireTelemetryPop
local char, floor = string.char, math.floor

-- Field names in ELRS 3.x and 4.x ("Band/Enable" is 4.x's name for "Band").
local WANT = { ["RF Band"] = 1, ["Packet Rate"] = 1, ["Telem Ratio"] = 1, ["Max Power"] = 1,
  Dynamic = 1, Band = 1, ["Band/Enable"] = 1, Channel = 1, ["Pwr Lvl"] = 1, ["Send VTx"] = 1 }
local NEED = 8  -- all of them but "RF Band", which only ELRS 4.x has

local function str(b, i)
  local s = ""
  while b[i] and b[i] ~= 0 do
    s = s .. char(b[i])
    i = i + 1
  end
  return s, i + 1, b[i] == 0
end

local function restart(s)
  s.ph, s.pings, s.t, s.cur, s.msg = "ping", 0, 0, nil, "READING"
end

function M.new()
  local s = { f = {}, w = {}, seq = 0, mspT = 0, ver = 0 }
  restart(s)
  return s
end

local function startRead(s, q, scan)
  s.q, s.qi, s.scan, s.cur, s.rep, s.n, s.ph = q, 1, scan, nil, 0, 0, "read"
end

local function finish(s, now)
  s.cur = nil
  if s.rep == 0 and #s.q > 0 then
    s.f = {}  -- no answer at all: the module is gone
    s.ver = s.ver + 1
    restart(s)
    return
  end
  s.ph, s.msg, s.q, s.t = "idle", nil, nil, now + 3000
end

local function nextField(s, now)
  s.cur = nil
  s.qi = s.qi + 1
  if s.scan and s.n >= NEED then
    finish(s, now)
  end
end

local function onInfo(s, d)
  if s.ph ~= "ping" or d[2] ~= 0xEE then
    return
  end
  local _, i = str(d, 3)
  -- The serial number spells "ELRS" on ExpressLRS modules.
  if d[i] ~= 0x45 or d[i + 1] ~= 0x4C or d[i + 2] ~= 0x52 or d[i + 3] ~= 0x53 then
    s.msg, s.ph = "NOT ELRS", "stop"
    return
  end
  local q = {}
  for id = 1, d[i + 12] or 0 do
    q[id] = id
  end
  startRead(s, q, true)
end

local function onEntry(s, d, now)
  local c = s.cur
  if s.ph ~= "read" or not c or d[2] ~= 0xEE or d[3] ~= c.id then
    return
  end
  local rem = d[4]
  if c.ex and rem ~= c.ex then
    return  -- a late reply to an earlier request
  end
  s.rep = s.rep + 1
  local b = c.b
  for i = 5, #d do
    b[#b + 1] = d[i]
  end
  if s.scan and not c.nm then
    local name, _, complete = str(b, 3)
    if complete then
      c.nm = true
      if not WANT[name] then
        nextField(s, now)
        return
      end
    end
  end
  if rem > 0 then
    c.ch, c.ex, c.n, c.dl = c.ch + 1, rem - 1, 0, nil
    return
  end
  local typ = b[2] % 128
  local name, i = str(b, 3)
  if name == "Band/Enable" then
    name = "Band"
  end
  if WANT[name] then
    local f = { id = c.id }
    if typ == 9 then  -- text selection: options, value, min, max, default, unit
      f.o, i = str(b, i)
      f.v = b[i]
      f.u = str(b, i + 4)
    elseif typ == 0 then  -- uint8: value, min, max
      f.v, f.lo, f.hi = b[i], b[i + 1], b[i + 2]
    end
    if s.scan and name ~= "RF Band" then
      s.n = s.n + 1  -- the scan stops once it has the ones it needs
    end
    s.f[name] = f
    s.ver = s.ver + 1
  end
  nextField(s, now)
end

local function onMsp(s, d, now)
  local st = d[3]
  -- A first (and only) chunk of the reply to MSP_VTX_CONFIG, without error.
  if d[2] == 0xC8 and st and st < 128 and floor(st / 16) % 2 == 1 and d[5] == 88 and d[10] then
    s.fc = { typ = d[6], band = d[7], ch = d[8], pw = d[9], pit = d[10] }
    s.mspT = now + 1000
  end
end

local function ping(s, now)
  if now < s.t then
    return
  end
  local sent = push(0x28, { 0x00, 0xEA })
  if sent == nil then
    s.msg, s.pings, s.t = "NO MODULE", 0, now + 200
  elseif sent then
    s.pings = s.pings + 1
    if s.pings > 6 then
      s.msg, s.t = "NO REPLY", now + 200
    else
      s.msg, s.t = "READING", now + 50
    end
  end
end

local function request(s, now)
  local c = s.cur
  if not c then
    local id = s.q[s.qi]
    if not id then
      finish(s, now)
      return
    end
    c = { id = id, ch = 0, n = 0, b = {} }
    s.cur = c
  elseif c.dl then
    if now < c.dl then
      return
    end
    c.n = c.n + 1
    if c.n >= 3 then
      nextField(s, now)
      return
    end
  end
  if push(0x2C, { 0xEE, 0xEA, c.id, c.ch }) then
    c.dl = now + 50
  else
    c.dl = nil
  end
end

-- Read the known fields again (after a write, a tool, or every 30 s).
function M.reread(s)
  local q = {}
  for _, f in pairs(s.f) do
    q[#q + 1] = f.id
  end
  if #q == 0 then
    restart(s)
  else
    startRead(s, q, false)
  end
end

-- Queue a write. They go out one per update, then everything is re-read.
function M.write(s, name, value)
  local f = s.f[name]
  if not f then
    return false
  end
  s.w[#s.w + 1] = { f.id, value }
  s.cur = nil
  return true
end

function M.busy(s)
  return s.ph ~= "idle" or #s.w > 0
end

-- Option number i (from 0) of a selection field, or its current one.
function M.opt(f, i)
  if not f or not f.o then
    return nil
  end
  local n = 0
  i = i or f.v
  for item in string.gmatch(f.o .. ";", "([^;]*);") do
    if n == i then
      return item
    end
    n = n + 1
  end
end

-- Call often. `linked`: telemetry is coming in; `armed`: nothing is asked.
function M.update(s, now, linked, armed)
  if s.last and now - s.last > 100 and s.ph == "idle" then
    s.t = 0  -- we were paused (a tool ran): the settings may have changed
  end
  s.last = now
  for _ = 1, 6 do
    local cmd, d = pop()
    if not cmd then
      break
    end
    if cmd == 0x29 then
      onInfo(s, d)
    elseif cmd == 0x2B then
      onEntry(s, d, now)
    elseif cmd == 0x7B then
      onMsp(s, d, now)
    end
  end
  if not linked then
    s.fc, s.mspT = nil, now + 100
  end
  local w = s.w
  if s.ph == "ping" then
    ping(s, now)
  elseif s.ph == "stop" then
    return
  elseif #w > 0 then
    if push(0x2D, { 0xEE, 0xEA, w[1][1], w[1][2] }) then
      table.remove(w, 1)
      if #w == 0 then
        s.ph, s.q, s.cur, s.t = "idle", nil, nil, now + 30  -- let it settle, then re-read
        s.mspT = now + 250
      end
    end
  elseif s.ph == "read" then
    request(s, now)
  elseif armed then
    return
  elseif now >= s.t then
    M.reread(s)
  elseif linked and now >= s.mspT then
    if push(0x7A, { 0xC8, 0xEA, 0x30 + s.seq, 0, 88 }) then
      s.seq = (s.seq + 1) % 16
      s.mspT = now + (s.fc and 1000 or 200)
    end
  end
end

return M
