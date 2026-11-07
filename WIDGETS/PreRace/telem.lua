-- Quad telemetry for the QUAD strip: link, pack and flight controller.
-- Turns CRSF sensor values into short display strings and a status level
-- per cell, and only rebuilds a string when its value changes.

local M = {}

local ceil, max = math.ceil, math.max
local format = string.format

-- Status levels, used by draw.lua to pick a colour.
M.NONE, M.OK, M.WARN, M.BAD = 0, 1, 2, 3
local NONE, OK, WARN, BAD = M.NONE, M.OK, M.WARN, M.BAD

local UPDATE_EVERY = 10   -- ticks (10 ms each) between telemetry reads
local LOOKUP_EVERY = 200  -- ticks between retries for sensors not found yet

-- Pre-race thresholds. The pack check is "is this a charged pack?", so a
-- storage-charged or part-used pack shows yellow.
local LQ_OK, LQ_WARN = 80, 50           -- RQly, %
local CELL_OK, CELL_WARN = 4.00, 3.75   -- volts per cell
local CELL_MAX = 4.40   -- highest a cell can read (HV LiPo 4.35 V plus sensor error)
local NO_PACK = 2.5     -- below this the FC is powered from USB, not a pack

-- Sensor names as EdgeTX creates them for CRSF (radio/src/telemetry/sensor_names.h).
local SENSORS = { "RQly", "1RSS", "2RSS", "ANT", "RxBt", "FM" }

-- Betaflight appends one of these to the flight mode while disarmed;
-- no suffix means armed (Betaflight src/main/telemetry/crsf.c).
local DISARMED = {
  ["*"] = { "READY", OK },    -- ready to arm
  ["!"] = { "NO ARM", WARN }, -- arming is blocked
  ["?"] = { "NO GPS", WARN }, -- GPS rescue not ready
}

local function cell()
  return { main = "--", sub = "", level = NONE }
end

function M.new()
  local t = {
    ids = {},
    nextUpdate = 0,
    nextLookup = 0,
    linked = false,
    armed = false,
    cells = 0,  -- detected cell count, kept while the link stays up
    link = cell(),
    pack = cell(),
    fc = cell(),
    vtx = cell(),  -- filled in by build step 5 (MSP read-back)
  }
  t.list = { t.link, t.pack, t.fc, t.vtx }  -- strip order
  return t
end

-- Sensors only exist once telemetry has been received, so retry until found.
local function lookup(t, now)
  if now < t.nextLookup then
    return
  end
  t.nextLookup = now + LOOKUP_EVERY
  for i = 1, #SENSORS do
    local name = SENSORS[i]
    if not t.ids[name] then
      local info = getFieldInfo(name)
      if info then
        t.ids[name] = info.id
      end
    end
  end
end

-- The sensor's value, or nil if it's missing or hasn't updated recently.
local function read(t, name)
  local id = t.ids[name]
  if not id then
    return nil
  end
  local value, current = getSourceValue(id)
  if current then
    return value
  end
  return nil
end

local function set(c, main, sub, level)
  c.main, c.sub, c.level = main, sub, level
end

local function updateLink(t)
  local lq = read(t, "RQly")
  -- EdgeTX reports ELRS's active antenna as 1 or 2.
  local rssi = read(t, read(t, "ANT") == 2 and "2RSS" or "1RSS")
  if not rssi or rssi == 0 then
    rssi = read(t, "1RSS")
  end
  local c = t.link
  if lq == c.lq and rssi == c.rssi then
    return
  end
  c.lq, c.rssi = lq, rssi
  local sub = (rssi and rssi ~= 0) and format("%ddBm", rssi) or ""
  if not lq then
    set(c, "--", sub, NONE)
  elseif lq >= LQ_OK then
    set(c, format("%d%%", lq), sub, OK)
  elseif lq >= LQ_WARN then
    set(c, format("%d%%", lq), sub, WARN)
  else
    set(c, format("%d%%", lq), sub, BAD)
  end
end

-- cellsOption 1+ forces the cell count; otherwise it's worked out from the
-- voltage. The count only grows while linked, so a sagging pack keeps its
-- count; it's worked out again for the next connection.
local function updatePack(t, cellsOption)
  local v = read(t, "RxBt")
  if v and v >= NO_PACK then
    if cellsOption and cellsOption >= 1 then
      t.cells = cellsOption
    else
      t.cells = max(t.cells, ceil(v / CELL_MAX))
    end
  end
  local c = t.pack
  if v == c.v and t.cells == c.cells then
    return
  end
  c.v, c.cells = v, t.cells
  if not v then
    set(c, "--", "", NONE)
  elseif v < NO_PACK then
    set(c, "--", "NO PACK", WARN)
  else
    local perCell = v / t.cells
    local level = (perCell >= CELL_OK and OK) or (perCell >= CELL_WARN and WARN) or BAD
    set(c, format("%.2fV", perCell), format("%dS %.1fV", t.cells, v), level)
  end
end

local function updateFc(t)
  local fm = read(t, "FM")
  local c = t.fc
  if fm == c.fm then
    return
  end
  c.fm = fm
  t.armed = false
  if type(fm) ~= "string" or fm == "" then
    set(c, "--", "", NONE)
  elseif fm == "!FS!" then
    set(c, "!FS!", "FAILSAFE", BAD)
  else
    local status = DISARMED[string.sub(fm, -1)]
    if status then
      set(c, status[1], string.sub(fm, 1, -2), status[2])
    else
      set(c, "ARMED", fm, BAD)  -- armed while walking out is the thing to catch
      t.armed = true
    end
  end
end

-- Call from refresh() and background(); reads at most every UPDATE_EVERY.
function M.update(t, cellsOption)
  local now = getTime()
  if now < t.nextUpdate then
    return
  end
  t.nextUpdate = now + UPDATE_EVERY

  local linked = getRSSI() > 0
  if linked ~= t.linked then
    t.linked = linked
    t.cells = 0         -- a new connection may mean a new pack
    t.nextLookup = now  -- look for sensors as soon as telemetry starts
  end
  if not linked then
    t.armed = false
    return
  end
  lookup(t, now)
  updateLink(t)
  updatePack(t, cellsOption)
  updateFc(t)
end

return M
