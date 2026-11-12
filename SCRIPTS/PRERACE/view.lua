-- Pre-race screen for 128x64 radios: the main screen. Same layout as the
-- colour widget: status bar, ELRS left and VIDEO right, sticks and aux bars
-- in the middle, the quad's status along the bottom.
-- 128x64 only (the TX12's screen); positions are worked out for that size.
-- No colour here, so a warning shows inverted and a bad value also blinks.

local M = {}

local text, line, rect, fill = lcd.drawText, lcd.drawLine, lcd.drawRectangle, lcd.drawFilledRectangle
local floor, format, sub, match = math.floor, string.format, string.sub, string.match
-- getOutputValue() needs EdgeTX 2.8; before that the "ch5" sources work.
local out = getOutputValue or function(i) return getValue("ch" .. (i + 1)) end

local LEVEL = { [0] = 0, INVERS, INVERS + BLINK }  -- fine, warning, bad
local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local MONTH_OFFSET = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
-- Stick numbers (0 rudder, 1 elevator, 2 throttle, 3 aileron) on the gimbal
-- axes left-x, left-y, right-y, right-x, per stick mode.
local MODE_AXES = { { 0, 1, 2, 3 }, { 0, 2, 1, 3 }, { 3, 1, 2, 0 }, { 3, 2, 1, 0 } }

-- ELRS VTX Admin's bands, in its order A, B, E, F, R, L.
local FREQ = {
  { 5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725 },
  { 5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866 },
  { 5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945 },
  { 5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880 },
  { 5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917 },
  { 5362, 5399, 5436, 5473, 5510, 5547, 5584, 5621 },
}
-- What each ELRS power level does on an HDZero Race VTX (see WIDGET_SPEC.md);
-- 4 is 1W on a Freestyle VTX.
M.POWER = { "25mW", "200mW", "0mW", "1W", "25mW", "25mW", "25mW", "25mW" }

function M.freq(band, ch)
  local row = FREQ[band]
  return row and row[ch]
end

local ids = {}
local function sensor(name)
  local id = ids[name]
  if not id then
    local info = getFieldInfo(name)
    if not info then
      return 0
    end
    id = info.id
    ids[name] = id
  end
  return getValue(id)
end

-- The radio's own values: battery, date, stick mode, output names.
local function slow(S)
  local g = getGeneralSettings()
  S.warn, S.low, S.high = g.battWarn, g.battMin, g.battMax
  local t = getDateTime()
  local y, m, d = t.year, t.mon, t.day
  if m < 3 then
    y = y - 1
  end
  local wd = (y + floor(y / 4) - floor(y / 100) + floor(y / 400) + MONTH_OFFSET[m] + d) % 7 + 1
  S.date = format("%s %d %s", DAYS[wd], d, MONTHS[m])
  local a = MODE_AXES[getStickMode and getStickMode() or 2] or MODE_AXES[2]
  for i = 1, 4 do
    S.ax[i] = defaultChannel and defaultChannel(a[i]) or a[i]
  end
  for i = 1, 6 do
    local o = model.getOutput(i + 3)
    local name = o and o.name
    S.names[i] = (name and name ~= "") and name or ("CH" .. (i + 4))
  end
end

-- Telemetry from the quad, as EdgeTX's CRSF sensors.
local function sample(S)
  if S.n % 200 == 0 then
    slow(S)
  end
  local v = getValue("tx-voltage")
  S.batt, S.battF = format("%.1fV", v), v <= S.warn and LEVEL[1] or 0
  -- The icon fills over Radio Setup's battery range, 7 px wide.
  local span = S.high - S.low
  S.fill = span > 0 and floor((v - S.low) * 7 / span + 0.5) or 0
  S.fill = S.fill > 7 and 7 or (S.fill < 0 and 0 or S.fill)
  S.linked = getRSSI() > 0
  S.armed = false
  if not S.linked then
    S.cells = nil
    return
  end
  local lq = sensor("RQly")
  S.lq, S.lqF = format("%d%%", lq), LEVEL[lq < 50 and 2 or (lq < 80 and 1 or 0)]
  v = sensor("RxBt")
  if v < 2.5 then
    S.pack, S.packF = "NO PACK", LEVEL[1]  -- the FC is on USB power
  else
    -- The cell count is worked out once per connection, so sag can't lower it.
    S.cells = S.cells or (floor(v / 4.4 - 0.001) + 1)
    local cell = v / S.cells
    S.pack = format("%dS %.2fV", S.cells, cell)
    S.packF = LEVEL[cell < 3.75 and 2 or (cell < 4 and 1 or 0)]
  end
  -- Betaflight ends the flight mode with * (ready to arm), ! (arming
  -- blocked) or ? (GPS rescue not ready); with none of them it is armed.
  local fm = sensor("FM")
  if type(fm) ~= "string" or fm == "" then
    S.fc, S.fcF = "--", 0
  elseif fm == "!FS!" then
    S.fc, S.fcF = "FAILSAFE", LEVEL[2]
  else
    local last = sub(fm, -1)
    if last == "*" then
      S.fc, S.fcF = "READY", 0
    elseif last == "!" then
      S.fc, S.fcF = "NO ARM", LEVEL[1]
    elseif last == "?" then
      S.fc, S.fcF = "NO GPS", LEVEL[1]
    else
      S.fc, S.fcF, S.armed = "ARMED", LEVEL[2], true
    end
  end
end

function M.new()
  return { n = 0, ax = {}, names = {}, ver = -1 }
end

-- The ELRS texts, made again only when the module's values change.
local function elrsTexts(S, s, L)
  local f = s.f
  S.ver = s.ver
  local t = L.opt(f["Packet Rate"]) or "--"
  t = match(string.gsub(t, "%(.-%)", ""), "^%s*(%S+)") or "--"
  S.rate = match(t, "^%d+$") and (t .. "Hz") or t
  local p = f["Max Power"]
  t = L.opt(p)
  local mw = tonumber(t)
  if not t then
    S.power = "--"
  elseif mw and mw >= 1000 then
    S.power = format("%dW", floor(mw / 1000))
  else
    S.power = t .. (p.u or "")
  end
  local tlm = f["Telem Ratio"]
  t = L.opt(tlm) or "--"
  if t == "Std" then
    t = match(tlm.u or "", "%((1:%d+)%)") or t  -- the ratio "Std" works out to
  end
  S.tlm, S.tlmF = "TLM " .. t, t == "Off" and LEVEL[1] or 0
  t = L.opt(f.Dynamic)
  S.dyn = (t and t ~= "Off") and t or ""
end

local function gimbal(x, S, ix, iy)
  rect(x, 31, 17, 17)
  line(x + 8, 32, x + 8, 46, DOTTED, FORCE)
  line(x + 1, 39, x + 15, 39, DOTTED, FORCE)
  local vx, vy = out(S.ax[ix]), out(S.ax[iy])
  vx = vx > 1024 and 1024 or (vx < -1024 and -1024 or vx)
  vy = vy > 1024 and 1024 or (vy < -1024 and -1024 or vy)
  fill(x + 7 + floor(vx * 6 / 1024 + 0.5), 38 - floor(vy * 6 / 1024 + 0.5), 3, 3, FORCE)
end

-- `S` is this screen's state, `s` the link state, `L` the link module;
-- `focus` 0 marks the VIDEO panel, 1 the ELRS panel (ENTER opens it).
function M.draw(S, s, L, focus)
  if S.n % 10 == 0 then
    sample(S)
  end
  S.n = S.n + 1
  if S.ver ~= s.ver then
    elrsTexts(S, s, L)
  end
  lcd.clear()

  -- Status bar: date, radio battery.
  text(0, 0, S.date, SMLSIZE)
  text(128, 0, S.batt, SMLSIZE + RIGHT + S.battF)
  local x = lcd.getLastLeftPos() - 12
  rect(x, 1, 9, 5)
  line(x + 9, 2, x + 9, 4, SOLID, FORCE)
  if S.fill > 0 then
    fill(x + 1, 2, S.fill, 3, FORCE)
  end
  line(0, 7, 127, 7, SOLID, FORCE)

  -- ELRS: packet rate and power, telemetry ratio and dynamic power below.
  if s.msg then
    text(1, 10, "ELRS", 0)
    text(1, 18, s.msg, SMLSIZE)
  else
    text(1, 10, S.rate, 0)
    text(40, 10, S.power, 0)
    text(1, 18, S.tlm, SMLSIZE + S.tlmF)
    text(46, 18, S.dyn, SMLSIZE)
  end
  line(78, 9, 78, 24, SOLID, FORCE)

  -- VIDEO: VTX Admin's channel, large. Beside it the frequency (ticked when
  -- the FC reports the same channel, else what the FC has) and the power.
  local f, fc = s.f, s.fc
  local band, ch, pw = f.Band and f.Band.v, f.Channel and f.Channel.v, f["Pwr Lvl"]
  if band and band > 0 and ch then
    text(81, 9, (L.opt(f.Band, band) or "?") .. ch, DBLSIZE)
    if #s.w > 0 then
      text(128, 9, "SEND", SMLSIZE + RIGHT)
    elseif fc and (fc.typ == 0 or fc.typ == 255) then
      text(128, 9, "NOVTX", SMLSIZE + RIGHT + INVERS)
    elseif fc and fc.pit == 1 then
      text(128, 9, "PIT", SMLSIZE + RIGHT + INVERS)
    elseif fc and (fc.band ~= band or fc.ch ~= ch) then
      text(128, 9, "FC" .. (L.opt(f.Band, fc.band) or "?") .. fc.ch, SMLSIZE + RIGHT + INVERS)
    else
      text(128, 9, M.freq(band, ch) or "", SMLSIZE + RIGHT)
      if fc then  -- a tick: the quad is on this channel
        line(103, 12, 104, 13, SOLID, FORCE)
        line(105, 12, 106, 10, SOLID, FORCE)
      end
    end
    pw = pw and pw.v or 0
    text(128, 17, pw > 0 and M.POWER[pw] or "-", SMLSIZE + RIGHT)
  elseif band == 0 then
    -- VTX Admin is off: nothing is sent, so show what the FC is on.
    if fc and fc.band > 0 then
      text(81, 9, (L.opt(f.Band, fc.band) or "?") .. fc.ch, DBLSIZE)
    else
      text(81, 9, "--", DBLSIZE)
    end
    text(128, 9, "OFF", SMLSIZE + RIGHT)
  else
    text(81, 9, "--", DBLSIZE)
  end
  if focus == 0 then
    fill(80, 25, 48, 2, FORCE)
  else
    fill(0, 25, 78, 2, FORCE)
  end

  -- Sticks and the six aux channels (CH5-CH10) with their output names.
  gimbal(0, S, 1, 2)
  gimbal(111, S, 4, 3)
  for i = 0, 5 do
    local x0, y = 20 + floor(i / 3) * 45, 28 + (i % 3) * 8
    text(x0, y, S.names[i + 1], SMLSIZE)
    local v = out(i + 4)
    v = v > 1024 and 1024 or (v < -1024 and -1024 or v)
    local w = floor(v * 5 / 1024 + (v < 0 and -0.5 or 0.5))
    line(x0 + 32, y + 3, x0 + 42, y + 3, DOTTED, FORCE)
    line(x0 + 37, y + 1, x0 + 37, y + 5, SOLID, FORCE)
    if w > 0 then
      fill(x0 + 38, y + 2, w, 3, FORCE)
    elseif w < 0 then
      fill(x0 + 37 + w, y + 2, -w, 3, FORCE)
    end
  end

  -- The quad: link quality, pack (per cell), FC state.
  line(0, 53, 127, 53, SOLID, FORCE)
  if S.linked then
    text(1, 56, S.lq, S.lqF)
    text(54, 56, S.pack, CENTER + S.packF)
    text(128, 56, S.fc, RIGHT + S.fcF)
  else
    text(64, 56, "NO LINK", CENTER)
  end
end

return M
