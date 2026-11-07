-- VTX: the VTX Administrator settings on the ELRS module, the picker's
-- selection, and sending a new band, channel and power with "Send VTx".
-- ELRS then sends them to the FC over the link (MSP_SET_VTX_CONFIG), and
-- again to every quad that connects while the band isn't Off. Nothing comes
-- back from the FC; build step 5 reads its setting back over MSP.

local M = {}

local format = string.format

-- Status levels, as in telem.lua, plus PENDING while a send is under way.
local NONE, OK, BAD, PENDING = 0, 1, 3, 4

-- Band letters by ELRS band number (its Band options are "Off;A;B;E;F;R;L").
local LETTER = { "A", "B", "E", "F", "R", "L" }

-- What the picker offers. Bands are ELRS band numbers; L isn't in
-- Betaflight's default VTX table, so it isn't offered. Power 0 is ELRS's "-":
-- leave the VTX's power as it is.
M.BANDS = { 5, 4, 3, 2, 1 }
M.BAND_LABELS = { "R", "F", "E", "B", "A" }
M.CHANNEL_LABELS = { "1", "2", "3", "4", "5", "6", "7", "8" }
M.POWER_LABELS = { "-", "1", "2", "3", "4", "5", "6", "7", "8" }
M.COUNTS = { #M.BANDS, #M.CHANNEL_LABELS, #M.POWER_LABELS }

-- MHz, from Betaflight's default table (src/main/drivers/vtx_table.c), by
-- ELRS band number.
local FREQ = {
  { 5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725 },  -- A
  { 5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866 },  -- B
  { 5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945 },  -- E
  { 5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880 },  -- F
  { 5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917 },  -- R
}

local SETTLE = 30        -- ticks after "Send VTx" before reading the values back
local TIMEOUT = 500      -- ticks a send may take before it counts as failed
local SHOW_RESULT = 500  -- ticks the sent/failed colour stays on

local function cell()
  return { main = "--", sub = "", level = NONE }
end

function M.new()
  local v = {
    video = cell(),  -- VIDEO panel: band and channel, frequency
    power = cell(),  -- VIDEO panel: power level
    strip = cell(),  -- QUAD strip VTX cell
    state = "idle",  -- idle, writing, settling, verifying, sent or failed
    ui = "main",     -- main, picker or confirm
    sel = { band = 5, ch = 1, pwr = 0 },
    title = "",
    version = -1,
  }
  v.list = { v.video, v.power }
  return v
end

local function name(band, ch)
  return (LETTER[band] or "?") .. ch
end

local function freq(band, ch)
  local row = FREQ[band]
  return row and row[ch]
end

-- The module's settings: band (0 = Off), channel, power (nil if unknown).
local function current(f)
  local band, ch, pwr = f.Band, f.Channel, f["Pwr Lvl"]
  if not (band and band.value and ch and ch.value) then
    return nil
  end
  return band.value, ch.value, pwr and pwr.value
end

local function formatCells(v, f)
  local band, ch, pwr = current(f)
  local video, power, strip = v.video, v.power, v.strip
  if not band then
    video.main, video.sub = "--", ""
    power.main = "--"
    strip.main, strip.sub = "--", ""
  elseif band == 0 then
    video.main, video.sub = "--", "OFF"
    power.main = "--"
    strip.main, strip.sub = "--", "OFF"
  else
    -- The frequency in MHz, without the unit so it fits beside "VIDEO".
    local mhz = freq(band, ch)
    video.main, video.sub = name(band, ch), mhz and tostring(mhz) or ""
    power.main = (pwr and pwr > 0) and tostring(pwr) or "--"
    -- ELRS sends this when the quad connects, but nothing confirms it arrived.
    strip.main, strip.sub = name(band, ch), "SENT"
  end
  local st = v.state
  video.level = (st == "sent" and OK) or (st == "failed" and BAD)
    or (st == "idle" and NONE) or PENDING
end

-- The picker's heading, e.g. "R3  5732MHz  PWR 2".
local function describe(v)
  local s = v.sel
  v.title = format("%s  %sMHz  PWR %s", name(s.band, s.ch), freq(s.band, s.ch) or "?",
    s.pwr > 0 and s.pwr or "-")
end

-- Open the picker on the module's current settings. False if the module
-- hasn't shown its VTX Administrator settings.
function M.open(v, f)
  local band, ch, pwr = current(f)
  if not band or not f["Send VTx"] then
    return false
  end
  local s = v.sel
  s.band = freq(band, 1) and band or 5  -- Off or L: start on R
  s.ch = (ch >= 1 and ch <= 8) and ch or 1
  s.pwr = pwr or 0
  describe(v)
  v.ui = "picker"
  return true
end

function M.close(v)
  v.ui = "main"
end

local function finish(v, ok, now)
  v.state = ok and "sent" or "failed"
  v.resultUntil = now + SHOW_RESULT
end

-- Write the selection to the module and press its "Send VTx".
local function send(v, crsf, link)
  local s, f = v.sel, link.fields
  v.sending = { band = s.band, ch = s.ch, pwr = f["Pwr Lvl"] and s.pwr or nil }
  local ok = crsf.write(link, "Band", s.band) and crsf.write(link, "Channel", s.ch)
  if ok and v.sending.pwr then
    ok = crsf.write(link, "Pwr Lvl", s.pwr)
  end
  ok = ok and crsf.write(link, "Send VTx", 1)  -- 1 = clicked
  local now = getTime()
  v.ui = "main"
  v.deadline = now + TIMEOUT
  if ok then
    v.state = "writing"
  else
    crsf.clearWrites(link)
    finish(v, false, now)
  end
end

-- A tap on the picker ("band", "chan" or "power" with its index) or on its
-- buttons ("cancel", "ok"). On the confirm screen "ok" sends.
function M.choose(v, kind, i, crsf, link)
  local s = v.sel
  if v.ui == "picker" then
    if kind == "band" then
      s.band = M.BANDS[i]
    elseif kind == "chan" then
      s.ch = i
    elseif kind == "power" then
      s.pwr = i - 1
    elseif kind == "cancel" then
      v.ui = "main"
    elseif kind == "ok" then
      v.ui = "confirm"
    end
    describe(v)
  elseif v.ui == "confirm" then
    if kind == "cancel" then
      v.ui = "picker"
    elseif kind == "ok" then
      send(v, crsf, link)
    end
  end
end

-- Call from refresh() and background(), after the ELRS reader has run.
function M.update(v, crsf, link)
  local now = getTime()
  local st = v.state
  if (st == "writing" or st == "settling" or st == "verifying") and now >= v.deadline then
    crsf.clearWrites(link)
    finish(v, false, now)
  elseif st == "writing" and not crsf.writing(link) then
    v.state, v.readAt = "settling", now + SETTLE
  elseif st == "settling" and now >= v.readAt then
    if crsf.read(link, { "Band", "Channel", "Pwr Lvl" }) then
      v.state = "verifying"
    end
  elseif st == "verifying" and not crsf.busy(link) then
    -- Sent if the module now holds what we wrote.
    local band, ch, pwr = current(link.fields)
    local s = v.sending
    finish(v, band == s.band and ch == s.ch and (s.pwr == nil or pwr == s.pwr), now)
  elseif (st == "sent" or st == "failed") and now >= v.resultUntil then
    v.state = "idle"
  end
  if link.version ~= v.version or v.state ~= v.shown then
    v.version, v.shown = link.version, v.state
    formatCells(v, link.fields)
  end
end

return M
