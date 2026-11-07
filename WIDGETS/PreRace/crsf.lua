-- CRSF parameter protocol, as the ExpressLRS Lua script uses it: find the TX
-- module, then read its parameters by name. Never blocks: update() handles
-- whatever replies have arrived and sends at most one request per call.
-- Message layouts: WIDGET_SPEC.md, "Q2".

local M = {}

local PING, DEVICE_INFO = 0x28, 0x29
local PARAM_ENTRY, PARAM_READ = 0x2B, 0x2C
local TX_MODULE, RADIO = 0xEE, 0xEA

-- Field types.
M.UINT8, M.TEXT_SELECTION, M.STRING, M.FOLDER, M.INFO, M.COMMAND = 0, 9, 10, 11, 12, 13

-- Status values, for the display.
M.NO_MODULE = "nomodule"  -- no CRSF module set up in the model
M.NO_REPLY = "noreply"    -- the module doesn't answer
M.NOT_ELRS = "notelrs"    -- a CRSF module, but not ExpressLRS
M.READING = "reading"
M.READY = "ready"

local PING_EVERY = 50     -- ticks (10 ms) between pings while looking for the module
local PING_SLOW = 200     -- after giving up, keep trying this often
local PINGS = 6           -- pings before giving up
local REPLY_TIMEOUT = 50  -- ticks to wait for each parameter chunk
local TRIES = 3           -- attempts per chunk before skipping the field
local RESUME_GAP = 100    -- no update() for this long means a tool ran: re-read
local REREAD_EVERY = 3000 -- ticks between re-reads of the known fields
local POPS = 8            -- replies handled per update()

-- Reads a 0-terminated string. Returns it, the index after the 0, and
-- whether the 0 was there.
local function readString(bytes, i)
  local chars = {}
  while bytes[i] and bytes[i] ~= 0 do
    chars[#chars + 1] = string.char(bytes[i])
    i = i + 1
  end
  return table.concat(chars), i + 1, bytes[i] == 0
end

-- Options are ';'-separated. Empty entries are kept: they stand for values
-- the hardware doesn't support, and the value is an index into the list.
local function split(text)
  local list = {}
  for item in string.gmatch(text .. ";", "([^;]*);") do
    list[#list + 1] = item
  end
  return list
end

-- A complete field: parent, type (bit 7 = hidden), name, then by type.
local function parseField(b)
  local typ = b[2] % 128
  local name, i = readString(b, 3)
  local f = { parent = b[1], type = typ, hidden = b[2] >= 128, name = name }
  if typ == M.TEXT_SELECTION then
    local options
    options, i = readString(b, i)
    f.options = split(options)
    f.value = b[i]
    f.unit = readString(b, i + 4)  -- skips min, max and default
    f.text = f.options[(f.value or 0) + 1] or ""
  elseif typ == M.UINT8 then
    f.value, f.min, f.max = b[i], b[i + 1], b[i + 2]
    f.unit = readString(b, i + 4)
  elseif typ == M.COMMAND then
    f.status, f.timeout = b[i], b[i + 1]
    f.info = readString(b, i + 2)
  elseif typ == M.STRING or typ == M.INFO then
    f.text = readString(b, i)
  end
  return f
end

-- `wanted`: parameter names to keep. `required`: a full scan stops once all
-- of these are in.
function M.new(wanted, required)
  local s = {
    wanted = {},
    required = required,
    fields = {},  -- name -> parsed field
    ids = {},     -- name -> field id, kept for re-reads
    version = 0,  -- goes up whenever a field is read
    status = M.READING,
  }
  for i = 1, #wanted do
    s.wanted[wanted[i]] = true
  end
  M.restart(s)
  return s
end

-- Start again from a ping and a full scan. Known values stay on show until
-- new ones arrive.
function M.restart(s)
  s.phase = "ping"
  s.pings = 0
  s.nextPing = 0
  s.cur = nil
  s.status = M.READING
end

-- Whether this read has found every required field. (Values kept from an
-- earlier read don't count, so a fresh scan reads them all again.)
local function haveRequired(s)
  for i = 1, #s.required do
    if not s.found[s.required[i]] then
      return false
    end
  end
  return true
end

local function startRead(s, queue, scanning)
  s.queue, s.qpos, s.scanning = queue, 1, scanning
  s.cur, s.replies, s.found = nil, 0, {}
  s.phase = "read"
end

local function finish(s, now)
  s.cur = nil
  if s.replies == 0 and #s.queue > 0 then
    -- Nothing answered: the module has gone. Forget it and look again.
    s.fields, s.ids = {}, {}
    s.version = s.version + 1
    M.restart(s)
    return
  end
  s.phase = "idle"
  s.status = M.READY
  s.nextReread = now + REREAD_EVERY
end

local function reread(s, now)
  local queue = {}
  for _, id in pairs(s.ids) do
    queue[#queue + 1] = id
  end
  if #queue == 0 then
    M.restart(s)
  else
    table.sort(queue)
    startRead(s, queue, false)
  end
end

local function nextField(s, now)
  s.cur = nil
  s.qpos = s.qpos + 1
  if s.scanning and haveRequired(s) then
    finish(s, now)
  end
end

local function send(cur, now)
  if crossfireTelemetryPush(PARAM_READ, { TX_MODULE, RADIO, cur.id, cur.chunk }) then
    cur.deadline = now + REPLY_TIMEOUT
  else
    cur.deadline = nil  -- not sent (output busy); try again next update
  end
end

local function ping(s, now)
  if now < s.nextPing then
    return
  end
  local sent = crossfireTelemetryPush(PING, { 0x00, RADIO })
  if sent == nil then
    s.status, s.pings = M.NO_MODULE, 0
    s.nextPing = now + PING_SLOW
  elseif sent then
    s.pings = s.pings + 1
    local givenUp = s.pings > PINGS
    s.status = givenUp and M.NO_REPLY or M.READING
    s.nextPing = now + (givenUp and PING_SLOW or PING_EVERY)
  end
end

local function request(s, now)
  local cur = s.cur
  if not cur then
    local id = s.queue[s.qpos]
    if not id then
      finish(s, now)
      return
    end
    cur = { id = id, chunk = 0, tries = 0, buf = {} }
    s.cur = cur
  elseif cur.deadline then
    if now < cur.deadline then
      return  -- still waiting for the reply
    end
    cur.tries = cur.tries + 1
    if cur.tries >= TRIES then
      nextField(s, now)  -- give up on this field
      return
    end
  end
  send(cur, now)
end

local function onDeviceInfo(s, data, now)
  -- Only the TX module; the receiver and FC answer pings too once linked.
  if s.phase ~= "ping" or data[2] ~= TX_MODULE then
    return
  end
  local name, i = readString(data, 3)
  s.deviceName = name
  -- ExpressLRS puts "ELRS" in the serial number field.
  if data[i] ~= 0x45 or data[i + 1] ~= 0x4C or data[i + 2] ~= 0x52 or data[i + 3] ~= 0x53 then
    s.status, s.phase = M.NOT_ELRS, "stopped"
    return
  end
  local queue = {}
  for id = 1, data[i + 12] or 0 do
    queue[id] = id
  end
  startRead(s, queue, true)
end

local function onParamEntry(s, data, now)
  local cur = s.cur
  if s.phase ~= "read" or not cur or data[2] ~= TX_MODULE or data[3] ~= cur.id then
    return
  end
  local remaining = data[4]
  if cur.expect and remaining ~= cur.expect then
    return  -- a late reply to an earlier request
  end
  s.replies = s.replies + 1
  local buf = cur.buf
  for i = 5, #data do
    buf[#buf + 1] = data[i]
  end

  -- While scanning, skip a field we don't want as soon as its name is in.
  if s.scanning and not cur.named then
    local name, _, complete = readString(buf, 3)
    if complete then
      cur.named = true
      if not s.wanted[name] then
        nextField(s, now)
        return
      end
    end
  end

  if remaining > 0 then
    cur.chunk, cur.expect, cur.tries, cur.deadline = cur.chunk + 1, remaining - 1, 0, nil
    return  -- request() asks for the next chunk
  end

  local f = parseField(buf)
  if s.wanted[f.name] then
    s.fields[f.name] = f
    s.ids[f.name] = cur.id
    s.found[f.name] = true
    s.version = s.version + 1
  end
  nextField(s, now)
end

-- Call from refresh() and background(). allowReread = false skips the
-- periodic re-read (e.g. while armed).
function M.update(s, allowReread)
  local now = getTime()
  if s.lastTick and now - s.lastTick > RESUME_GAP and s.phase == "idle" then
    reread(s, now)  -- a tool may have changed the settings meanwhile
  end
  s.lastTick = now

  for _ = 1, POPS do
    local command, data = crossfireTelemetryPop()
    if not command then
      break
    end
    if command == DEVICE_INFO then
      onDeviceInfo(s, data, now)
    elseif command == PARAM_ENTRY then
      onParamEntry(s, data, now)
    end
  end

  if s.phase == "ping" then
    ping(s, now)
  elseif s.phase == "read" then
    request(s, now)
  elseif s.phase == "idle" and allowReread and now >= s.nextReread then
    reread(s, now)
  end
end

return M
