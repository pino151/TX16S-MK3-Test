-- VTX: the VTX Administrator settings on the ELRS module, the picker's
-- choices, sending a new band, channel and power with "Send VTx", and what
-- the flight controller actually has, read over MSP (msp.lua).
-- ELRS sends the VTX Admin setting to the FC (MSP_SET_VTX_CONFIG) on "Send
-- VTx" and again whenever a quad connects while the band isn't Off. The FC
-- maps ELRS's band number to a row of its own VTX table, so the FC's table
-- decides the letters and frequencies shown here once it has been read.

local M = {}

local format, min = string.format, math.min

-- Status levels, as in telem.lua, plus PENDING while a send is under way.
local NONE, OK, WARN, BAD, PENDING = 0, 1, 2, 3, 4

-- MSP commands (Betaflight src/main/msp/msp_protocol.h).
local MSP_VTX_CONFIG, MSP_VTXTABLE_BAND, MSP_VTXTABLE_POWERLEVEL = 88, 137, 138

-- Band letters by ELRS band number (its Band options are "Off;A;B;E;F;R;L").
local LETTER = { "A", "B", "E", "F", "R", "L" }
local ELRS_BANDS = #LETTER

-- Until the FC's table is read: Betaflight's default table
-- (src/main/drivers/vtx_table.c), which has no L band.
local FREQ = {
  { 5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725 },  -- A
  { 5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866 },  -- B
  { 5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945 },  -- E
  { 5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880 },  -- F
  { 5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917 },  -- R
}
local ORDER = { R = 1, F = 2, E = 3, B = 4, A = 5, L = 6 }  -- picker band order

M.CHANNEL_LABELS = { "1", "2", "3", "4", "5", "6", "7", "8" }
-- ELRS's "Pwr Lvl": 0 is "-" (leave the VTX's power as it is), then 1-8.
local DEFAULT_POWERS = { "-", "1", "2", "3", "4", "5", "6", "7", "8" }

local SETTLE = 30          -- ticks after "Send VTx" before reading the module back
local TIMEOUT = 500        -- ticks a send may take before it counts as failed
local SHOW_RESULT = 500    -- ticks the sent/failed colour stays on
local FIRST_CONFIG = 100   -- ticks after the link comes up before asking the FC
local CONFIG_EVERY = 1000  -- ticks between reads of the FC's setting (not while armed)
local RETRY_CONFIG = 200   -- ticks before asking again after no answer
local AFTER_SEND = 250     -- ELRS sends 3 times, 0.5 s apart, then saves

local function u16(b, i)
  return (b[i] or 0) + (b[i + 1] or 0) * 256
end

local function cell()
  return { main = "--", sub = "", level = NONE }
end

local function letter(v, band)
  local t = v.tbl
  return (t and t.complete and t.letters[band]) or LETTER[band] or "?"
end

-- MHz for a band and channel (0 if there's none).
local function freq(v, band, ch)
  local t = v.tbl
  local row = (t and t.complete and t.freqs[band]) or FREQ[band]
  return row and row[ch] or 0
end

local function powerLabel(v, p)
  return v.powerLabels[p + 1] or tostring(p)
end

-- The module's settings: band (0 = Off), channel, power (nil if unknown).
local function current(f)
  local band, ch, pwr = f.Band, f.Channel, f["Pwr Lvl"]
  if not (band and band.value and ch and ch.value) then
    return nil
  end
  return band.value, ch.value, pwr and pwr.value
end

-- The picker's heading, e.g. "R3  5732MHz  PWR 25", and which channels the
-- selected band has.
local function describe(v)
  local s = v.sel
  for c = 1, #M.CHANNEL_LABELS do
    v.chanOk[c] = freq(v, s.band, c) > 0
  end
  local mhz = freq(v, s.band, s.ch)
  v.title = format("%s%d  %sMHz  PWR %s", letter(v, s.band), s.ch, mhz > 0 and mhz or "?",
    s.pwr > 0 and powerLabel(v, s.pwr) or "-")
end

-- Keep the selection on a band and channel that exist.
local function fixSelection(v)
  local s, ok = v.sel, false
  for i = 1, #v.bands do
    ok = ok or v.bands[i] == s.band
  end
  if not ok then
    s.band = v.bands[1] or 5
  end
  describe(v)
  if not v.chanOk[s.ch] then
    for c = 1, #M.CHANNEL_LABELS do
      if v.chanOk[c] then
        s.ch = c
        break
      end
    end
  end
  if s.pwr >= #v.powerLabels then
    s.pwr = 0
  end
  describe(v)
end

-- The picker's bands and powers: from the FC's table once it's read, else
-- Betaflight's defaults. `options` goes up so the picker lays itself out again.
local function setOptions(v)
  local t = v.tbl
  local full = t and t.complete
  local bands = {}
  for b = 1, full and min(v.fc.bands, ELRS_BANDS) or #FREQ do
    local row, any = full and t.freqs[b] or FREQ[b], false
    for c = 1, #M.CHANNEL_LABELS do
      any = any or (row and (row[c] or 0) > 0)
    end
    if any then
      bands[#bands + 1] = b
    end
  end
  table.sort(bands, function(a, b)
    local oa, ob = ORDER[letter(v, a)] or 9, ORDER[letter(v, b)] or 9
    return oa < ob or (oa == ob and a < b)
  end)
  v.bands, v.bandLabels = bands, {}
  for i = 1, #bands do
    v.bandLabels[i] = letter(v, bands[i])
  end
  if full and #t.powers > 0 then
    v.powerLabels = { "-" }
    for p = 1, #t.powers do
      v.powerLabels[p + 1] = t.powers[p]
    end
  else
    v.powerLabels = DEFAULT_POWERS
  end
  v.options = v.options + 1
  fixSelection(v)
  v.changed = true
end

local function onConfig(v, b)
  local now = getTime()
  if not b or #b < 5 then
    if not v.fc then
      v.nextConfig = now + RETRY_CONFIG
    end
    return
  end
  local old = v.fc
  -- Reply bytes: Betaflight src/main/msp/msp.c, MSP_VTX_CONFIG.
  local fc = {
    type = b[1], band = b[2], ch = b[3], power = b[4], pit = b[5], freq = u16(b, 6),
    hasTable = b[12] == 1, bands = b[13] or 0, powers = b[15] or 0,
  }
  v.fc = fc
  -- A new FC, or a different table: read the table (again).
  if fc.hasTable and (not v.tbl or not old or old.bands ~= fc.bands or old.powers ~= fc.powers) then
    v.tbl = { letters = {}, freqs = {}, powers = {}, nextBand = 1, nextPower = 1 }
  end
  v.changed = true
end

local function onBand(v, b)
  local t = v.tbl
  if not t then
    return
  end
  if b and b[1] then
    local i = 3 + (b[2] or 0)  -- after band number, name length and name
    local row = {}
    for c = 1, b[i + 2] or 0 do
      row[c] = u16(b, i + 1 + 2 * c)
    end
    t.letters[b[1]], t.freqs[b[1]] = string.char(b[i] or 63), row
  end
  t.nextBand = t.nextBand + 1
end

local function onPower(v, b)
  local t = v.tbl
  if not t then
    return
  end
  if b and b[1] then
    local chars = {}
    for i = 5, 4 + (b[4] or 0) do
      if b[i] and b[i] ~= 32 then
        chars[#chars + 1] = string.char(b[i])
      end
    end
    t.powers[b[1]] = #chars > 0 and table.concat(chars) or tostring(u16(b, 2))
  end
  t.nextPower = t.nextPower + 1
end

function M.new()
  local v = {
    video = cell(),  -- VIDEO panel: band and channel, frequency
    power = cell(),  -- VIDEO panel: power level
    strip = cell(),  -- QUAD strip VTX cell: what the FC has
    state = "idle",  -- idle, writing, settling, verifying, sent or failed
    ui = "main",     -- main, picker or confirm
    sel = { band = 5, ch = 1, pwr = 0 },
    title = "",
    version = -1,
    linked = false,
    nextConfig = 0,
    chanOk = {},
    options = 0,
  }
  v.list = { v.video, v.power }
  -- MSP reply handlers, made once rather than per request.
  v.onConfig = function(b) onConfig(v, b) end
  v.onBand = function(b) onBand(v, b) end
  v.onPower = function(b) onPower(v, b) end
  setOptions(v)
  return v
end

-- Ask the FC for its VTX setting, then (once per quad) its VTX table.
local function queryFc(v, msp, m, linked, armed, now)
  if linked ~= v.linked then
    v.linked = linked
    msp.cancel(m)
    v.fc, v.tbl = nil, nil  -- a new connection may be a different quad
    v.nextConfig = now + FIRST_CONFIG
    setOptions(v)
  end
  if not linked or armed or msp.busy(m) then
    return
  end
  local t, fc = v.tbl, v.fc
  if now >= v.nextConfig then
    v.nextConfig = now + CONFIG_EVERY
    msp.request(m, MSP_VTX_CONFIG, nil, v.onConfig)
  elseif t and not t.complete then
    if t.nextBand <= min(fc.bands, ELRS_BANDS) then
      msp.request(m, MSP_VTXTABLE_BAND, { t.nextBand }, v.onBand)
    elseif t.nextPower <= min(fc.powers, #DEFAULT_POWERS - 1) then
      msp.request(m, MSP_VTXTABLE_POWERLEVEL, { t.nextPower }, v.onPower)
    else
      t.complete = true
      setOptions(v)
    end
  end
end

local function formatStrip(v, band, ch)
  local s, fc = v.strip, v.fc
  if not fc then
    -- Not read from the FC (yet): what ELRS sends when the quad connects.
    if not band then
      s.main, s.sub, s.level = "--", "", NONE
    elseif band == 0 then
      s.main, s.sub, s.level = "--", "OFF", NONE
    else
      s.main, s.sub, s.level = letter(v, band) .. ch, "SENT", NONE
    end
    return
  end
  if fc.type == 0 or fc.type == 255 then  -- Betaflight: unsupported or unknown device
    s.main, s.sub, s.level = "--", "NO VTX", WARN
    return
  end
  s.main = fc.band > 0 and (letter(v, fc.band) .. fc.ch) or tostring(fc.freq)
  s.sub = fc.pit == 1 and "PIT" or (fc.freq > 0 and tostring(fc.freq) or "")
  if fc.pit == 1 then
    s.level = WARN
  elseif not band or band == 0 then
    s.level = NONE  -- VTX Admin is off: nothing to compare with
  elseif band == fc.band and ch == fc.ch then
    s.level = OK    -- the FC has what VTX Admin sends
  else
    s.level = WARN
  end
end

local function formatCells(v, f)
  local band, ch, pwr = current(f)
  local video, power = v.video, v.power
  if not band then
    video.main, video.sub, power.main = "--", "", "--"
  elseif band == 0 then
    video.main, video.sub, power.main = "--", "OFF", "--"
  else
    local mhz = freq(v, band, ch)
    video.main, video.sub = letter(v, band) .. ch, mhz > 0 and tostring(mhz) or ""
    power.main = (pwr and pwr > 0) and powerLabel(v, pwr) or "--"
  end
  local st = v.state
  video.level = (st == "sent" and OK) or (st == "failed" and BAD)
    or (st == "idle" and NONE) or PENDING
  formatStrip(v, band, ch)
end

-- Open the picker on the module's current settings. False if the module
-- hasn't shown its VTX Administrator settings.
function M.open(v, f)
  local band, ch, pwr = current(f)
  if not band or not f["Send VTx"] then
    return false
  end
  local s = v.sel
  s.band, s.ch, s.pwr = band, (ch >= 1 and ch <= 8) and ch or 1, pwr or 0
  fixSelection(v)
  v.ui = "picker"
  return true
end

function M.close(v)
  v.ui = "main"
end

local function finish(v, ok, now)
  v.state = ok and "sent" or "failed"
  v.resultUntil = now + SHOW_RESULT
  if ok and v.linked then
    v.nextConfig = now + AFTER_SEND  -- see what the FC made of it
  end
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
    if kind == "band" and v.bands[i] then
      s.band = v.bands[i]
      fixSelection(v)
    elseif kind == "chan" and v.chanOk[i] then
      s.ch = i
    elseif kind == "power" and v.powerLabels[i] then
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

-- The send: writes go out, the module settles, then its values are read back.
local function stepSend(v, crsf, link, now)
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
end

-- Call from refresh() and background(), after the ELRS reader has run (it
-- pops the MSP replies too). `m` is this widget's msp.lua state.
function M.update(v, crsf, link, msp, m, linked, armed)
  local now = getTime()
  stepSend(v, crsf, link, now)
  queryFc(v, msp, m, linked, armed, now)
  msp.update(m)
  if link.version ~= v.version or v.state ~= v.shown or v.changed then
    v.version, v.shown, v.changed = link.version, v.state, false
    formatCells(v, link.fields)
  end
end

return M
