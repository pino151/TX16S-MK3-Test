-- MSP over CRSF, as the Betaflight TX Lua scripts use it: requests go to the
-- flight controller through the ELRS link, and replies come back as CRSF
-- frames, possibly in several chunks. One request at a time.
-- Framing: Betaflight src/main/telemetry/msp_shared.c (MSP v1, no CRC in
-- replies). Replies reach handle() through crsf.lua, which pops the queue.

local M = {}

local MSP_REQ, MSP_WRITE = 0x7A, 0x7C  -- Betaflight treats both the same
M.MSP_RESP = 0x7B
local FC, RADIO = 0xC8, 0xEA
local VERSION1, START, ERROR = 0x20, 0x10, 0x80

local TIMEOUT = 300  -- ticks (10 ms) to wait for a reply; telemetry can be slow
local TRIES = 3

function M.new()
  return { seq = 0 }
end

-- Ask the FC for `cmd`, with an optional payload (at most 4 bytes: a CRSF
-- request carries 8). `done(bytes)` gets the reply's payload, or nil if the
-- FC answered with an error or never answered. False if a request is
-- already in progress.
function M.request(s, cmd, payload, done)
  if s.cur then
    return false
  end
  s.cur = { cmd = cmd, payload = payload or {}, done = done, tries = 0 }
  return true
end

function M.busy(s)
  return s.cur ~= nil
end

function M.cancel(s)
  s.cur = nil
end

local function send(s, cur, now)
  local payload = cur.payload
  local frame = { FC, RADIO, VERSION1 + START + s.seq, #payload, cur.cmd }
  for i = 1, #payload do
    frame[#frame + 1] = payload[i]
  end
  -- Like the Betaflight Lua: requests with a payload go as MSP_WRITE.
  if crossfireTelemetryPush(#payload > 0 and MSP_WRITE or MSP_REQ, frame) then
    s.seq = (s.seq + 1) % 16
    cur.deadline, cur.rx = now + TIMEOUT, nil
  end
end

local function finish(s, cur, bytes)
  s.cur = nil
  cur.done(bytes)
end

-- An MSP reply frame: dest, origin, status, then on the first chunk size and
-- command, then payload bytes.
function M.handle(s, data)
  local cur = s.cur
  if not cur or data[2] ~= FC or not data[3] then
    return
  end
  local status = data[3]
  local seq = status % 16
  local i
  if bit32.btest(status, START) then
    if data[5] ~= cur.cmd then
      return  -- the reply to an earlier request
    end
    cur.rx = { size = data[4], bytes = {}, seq = seq, failed = bit32.btest(status, ERROR) }
    i = 6
  else
    local rx = cur.rx
    if not rx or (rx.seq + 1) % 16 ~= seq then
      cur.rx = nil  -- a chunk went missing: the timeout asks again
      return
    end
    rx.seq = seq
    i = 4
  end
  local rx = cur.rx
  local bytes = rx.bytes
  while data[i] and #bytes < rx.size do
    bytes[#bytes + 1] = data[i]
    i = i + 1
  end
  if #bytes >= rx.size then
    finish(s, cur, (not rx.failed) and bytes or nil)
  end
end

-- Call every refresh()/background(): sends the request, and asks again after
-- a timeout.
function M.update(s)
  local cur = s.cur
  if not cur then
    return
  end
  local now = getTime()
  if cur.deadline then
    if now < cur.deadline then
      return
    end
    cur.tries = cur.tries + 1
    if cur.tries >= TRIES then
      finish(s, cur, nil)
      return
    end
    cur.deadline = nil
  end
  send(s, cur, now)
end

return M
