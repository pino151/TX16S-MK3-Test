-- The thin status bar along the top: the date on the left, the radio's
-- battery on the right. EdgeTX hides its own top bar in App mode, so this
-- stands in for it. Lua has no way to read the speaker volume (EdgeTX
-- exposes no getter for it), so the volume isn't shown.

local M = {}

local floor, max, min = math.floor, math.max, math.min
local format = string.format
local drawText = lcd.drawText
local fillRect = lcd.drawFilledRectangle
local drawRect = lcd.drawRectangle

local BATT_EVERY = 10   -- refreshes between battery reads (about 0.5 s)
local DATE_EVERY = 200  -- refreshes between date and battery-setting reads (about 10 s)

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local MONTH_OFFSET = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }

-- Day of the week, 1 = Sunday (Sakamoto's method; getDateTime() has none).
local function weekday(y, m, d)
  if m < 3 then
    y = y - 1
  end
  return (y + floor(y / 4) - floor(y / 100) + floor(y / 400) + MONTH_OFFSET[m] + d) % 7 + 1
end

function M.new()
  return { tick = 0, volts = false, battText = "", battW = 0, fill = 0, dateText = "" }
end

-- Battery range and warning level from the radio settings (Radio Setup >
-- Battery), and the date. Both change rarely.
local function readSlow(st)
  local g = getGeneralSettings()
  st.warn, st.low, st.high = g.battWarn, g.battMin, g.battMax
  st.volts = false  -- work out the gauge again with these settings
  local t = getDateTime()
  st.dateText = format("%s %d %s %d", DAYS[weekday(t.year, t.mon, t.day)], t.day,
    MONTHS[t.mon] or "?", t.year)
end

-- Called from refresh() (it measures text), only while the bar is shown.
function M.update(st)
  if st.tick % DATE_EVERY == 0 then
    readSlow(st)
  end
  if st.tick % BATT_EVERY == 0 or not st.volts then
    local v = getValue("tx-voltage")  -- volts, to 0.1 V
    if v ~= st.volts then
      st.volts = v
      st.battText = format("%.1fV", v)
      st.battW = lcd.sizeText(st.battText, SMLSIZE)
      local span = st.high - st.low
      st.fill = span > 0 and max(0, min(1, (v - st.low) / span)) or 0
      st.warning = v <= st.warn  -- as EdgeTX's own low-battery warning
    end
  end
  st.tick = st.tick + 1
end

-- `B` is the layout's bar (layout.lua). The battery turns red at the
-- radio's warning voltage.
function M.draw(B, st, c)
  fillRect(0, 0, B.w, B.h, c.panel)
  drawText(B.x, B.cy, st.dateText, SMLSIZE + VCENTER + c.fg)
  local color = st.warning and c.levels[3] or c.fg
  drawText(B.right, B.cy, st.battText, SMLSIZE + VCENTER + RIGHT + color)
  -- Battery icon left of the voltage: body, terminal nub, charge fill.
  local bodyW, ih = B.iconW - B.nubW, B.iconH
  local ix = B.right - st.battW - B.gap - B.iconW
  local iy = B.cy - floor(ih / 2)
  drawRect(ix, iy, bodyW, ih, color)
  local nubH = max(2, floor(ih / 2))
  fillRect(ix + bodyW, iy + floor((ih - nubH) / 2), B.nubW, nubH, color)
  local fw = floor((bodyW - 4) * st.fill + 0.5)
  if fw > 0 then
    fillRect(ix + 2, iy + 2, fw, ih - 4, color)
  end
end

return M
