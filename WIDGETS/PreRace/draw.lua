-- Drawing. Everything here runs inside refresh(), the only place EdgeTX
-- allows lcd drawing calls.

local M = {}

local floor = math.floor
local drawText = lcd.drawText
local fillRect = lcd.drawFilledRectangle
local drawRect = lcd.drawRectangle
local drawLine = lcd.drawLine
local drawCircle = lcd.drawCircle
local fillCircle = lcd.drawFilledCircle

-- Fixed high-contrast colours rather than the theme's, for use in sunlight.
function M.palette(light)
  if light then
    return {
      bg = WHITE,
      panel = lcd.RGB(236, 236, 236),
      line = lcd.RGB(140, 140, 140),
      label = lcd.RGB(70, 70, 70),
      fg = BLACK,
      accent = lcd.RGB(0, 90, 210),
      barBg = lcd.RGB(200, 200, 200),
      warn = lcd.RGB(200, 0, 0),
    }
  end
  return {
    bg = BLACK,
    panel = lcd.RGB(22, 22, 22),
    line = lcd.RGB(95, 95, 95),
    label = lcd.RGB(175, 175, 175),
    fg = WHITE,
    accent = YELLOW,
    barBg = lcd.RGB(60, 60, 60),
    warn = ORANGE,
  }
end

-- Placeholders until build steps 2-4 fill these panels in.
local VIDEO_VALUES = { "--", "--" }
local ELRS_VALUES = { "--", "--", "--" }
local QUAD_VALUES = { "NO LINK" }

local LIMIT = 1024  -- output value at +/-100%

local function clamp(v)
  if v > LIMIT then
    return LIMIT
  elseif v < -LIMIT then
    return -LIMIT
  end
  return v
end

local function panel(p, values, c, valueColor)
  fillRect(p.x, p.y, p.w, p.h, c.panel)
  drawRect(p.x, p.y, p.w, p.h, c.line)
  for i = 1, #p.cols do
    local col = p.cols[i]
    drawText(col.x, col.labelY, col.label, SMLSIZE + c.label)
    drawText(col.cx, col.cy, values[i], col.font + CENTER + VCENTER + valueColor)
  end
end

-- Reads one stick axis. The label string is only rebuilt when the value
-- changes, to avoid making garbage every frame.
local function readAxis(a)
  local v = getOutputValue(a.ch)
  if v ~= a.value then
    a.value = v
    a.text = string.format("%s %d", a.letter, floor(v * 100 / LIMIT + 0.5))
  end
  return clamp(v)
end

local function gimbal(g, ax, ay, c)
  local cx, cy, r = g.cx, g.cy, g.r
  drawCircle(cx, cy, r, c.line)
  drawCircle(cx, cy, r - 1, c.line)
  drawLine(cx - r, cy, cx + r, cy, DOTTED, c.line)
  drawLine(cx, cy - r, cx, cy + r, DOTTED, c.line)
  -- Gimbal travel is square, so a corner deflection sits outside the ring.
  local px = cx + floor(readAxis(ax) * g.travel / LIMIT)
  local py = cy - floor(readAxis(ay) * g.travel / LIMIT)
  drawLine(g.x, py, g.x + g.s - 1, py, SOLID, c.fg)
  drawLine(px, g.y, px, g.y + g.s - 1, SOLID, c.fg)
  fillCircle(px, py, g.dot, c.accent)
  drawText(g.x, g.textY, ax.text, SMLSIZE + VCENTER + c.fg)
  drawText(g.x + g.s, g.textY, ay.text, SMLSIZE + VCENTER + RIGHT + c.fg)
end

-- Output name, then a bar that fills from the centre towards the value.
local function auxCell(cell, item, a, c)
  drawText(cell.x, cell.y + floor(a.rowH / 2), item.name, a.nameFont + VCENTER + c.fg)
  local bx = cell.x + a.nameW + a.gap
  local bw = a.colW - a.nameW - a.gap
  local by = cell.y + floor((a.rowH - a.barH) / 2)
  local half = floor(bw / 2)
  local mid = bx + half
  fillRect(bx, by, bw, a.barH, c.barBg)
  local fw = floor(clamp(getOutputValue(item.ch)) * half / LIMIT)
  if fw > 0 then
    fillRect(mid, by, fw, a.barH, c.accent)
  elseif fw < 0 then
    fillRect(mid + fw, by, -fw, a.barH, c.accent)
  end
  fillRect(mid - 1, by - 2, 2, a.barH + 4, c.fg)  -- centre mark
end

function M.screen(wgt)
  local L, c = wgt.lay, wgt.colors
  fillRect(0, 0, L.w, L.h, c.bg)
  if L.tooSmall then
    local x, y = floor(L.w / 2), floor(L.h / 2)
    local _, lineH = lcd.sizeText("A", SMLSIZE)
    local half = floor(lineH / 2)
    drawText(x, y - half, "Pre-race:", SMLSIZE + CENTER + VCENTER + c.fg)
    drawText(x, y + half, "full screen only", SMLSIZE + CENTER + VCENTER + c.fg)
    return
  end

  panel(L.video, VIDEO_VALUES, c, c.fg)
  panel(L.elrs, ELRS_VALUES, c, c.fg)
  panel(L.strip, QUAD_VALUES, c, c.warn)

  local s = wgt.sticks
  gimbal(L.left, s.left.x, s.left.y, c)
  gimbal(L.right, s.right.x, s.right.y, c)

  local a, aux = L.aux, wgt.aux
  for i = 1, #aux do
    auxCell(a.cells[i], aux[i], a, c)
  end
end

return M
