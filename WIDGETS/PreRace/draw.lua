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

-- Fixed high-contrast colours rather than the theme's, for use in sunlight:
-- sky blue for bars, the stick dot and selections, amber for warnings.
-- `levels` are indexed by the status levels in telem.lua (NONE, OK, WARN,
-- BAD), plus 4 for a value that's on its way (vtx.lua's PENDING).
function M.palette(light)
  if light then
    local amber = lcd.RGB(200, 115, 0)
    return {
      bg = WHITE,
      panel = lcd.RGB(236, 236, 236),
      line = lcd.RGB(140, 140, 140),
      label = lcd.RGB(70, 70, 70),
      fg = BLACK,
      accent = lcd.RGB(0, 105, 200),
      barBg = lcd.RGB(205, 205, 205),
      noLink = amber,
      levels = { [0] = BLACK, lcd.RGB(0, 140, 60), amber, lcd.RGB(200, 0, 0),
        lcd.RGB(110, 110, 110) },
    }
  end
  local amber = lcd.RGB(255, 165, 0)
  return {
    bg = BLACK,
    panel = lcd.RGB(22, 22, 22),
    line = lcd.RGB(95, 95, 95),
    label = lcd.RGB(175, 175, 175),
    fg = WHITE,
    accent = lcd.RGB(40, 170, 235),
    barBg = lcd.RGB(60, 60, 60),
    noLink = amber,
    levels = { [0] = WHITE, lcd.RGB(40, 210, 90), amber, lcd.RGB(255, 70, 70),
      lcd.RGB(150, 150, 150) },
  }
end

local QUAD_IDLE = { "NO LINK" }

local LIMIT = 1024  -- output value at +/-100%

local function clamp(v)
  if v > LIMIT then
    return LIMIT
  elseif v < -LIMIT then
    return -LIMIT
  end
  return v
end

local function frame(p, c)
  fillRect(p.x, p.y, p.w, p.h, c.panel)
  drawRect(p.x, p.y, p.w, p.h, c.line)
end

local function panel(p, values, c, valueColor)
  frame(p, c)
  for i = 1, #p.cols do
    local col = p.cols[i]
    drawText(col.x, col.labelY, col.label, SMLSIZE + c.label)
    drawText(col.cx, col.cy, values[i], col.font + CENTER + VCENTER + valueColor)
  end
end

-- Width of a cell's detail text, measured only when the text changes.
local function subWidth(cell)
  if cell.sub ~= cell.measured then
    cell.measured, cell.subW = cell.sub, lcd.sizeText(cell.sub, SMLSIZE)
  end
  return cell.subW
end

-- A panel of cells, each { main, sub, level }: the main value coloured by
-- its status level and a detail right of the label, left out if there's no
-- room for it.
local function cells(p, list, c, pad)
  frame(p, c)
  local top, bottom, n = p.y + pad, p.y + p.h - pad - 1, #p.cols
  for i = 1, n do
    local col, cell = p.cols[i], list[i]
    -- Keep text a pad away from the separators between cells.
    local left, right = col.x, col.right
    if i > 1 then
      local x = col.x - floor(pad / 2)
      drawLine(x, top, x, bottom, SOLID, c.line)
      left = left + pad
    end
    if i < n then
      right = right - pad
    end
    drawText(left, col.labelY, col.label, SMLSIZE + c.label)
    if left + col.labelW + pad + subWidth(cell) <= right then
      drawText(right, col.labelY, cell.sub, SMLSIZE + RIGHT + c.fg)
    end
    drawText(col.cx, col.cy, cell.main, col.font + CENTER + VCENTER + c.levels[cell.level])
  end
end

-- QUAD strip: "NO LINK", or cells for link, pack and FC.
local function quadStrip(L, wgt, c)
  if wgt.telem.linked then
    cells(L.strip, wgt.stripCells, c, L.pad)
  else
    panel(L.stripIdle, QUAD_IDLE, c, c.noLink)
  end
end

-- ELRS panel: why there's nothing to show, or rate, power and telemetry.
local function elrsPanel(L, e, c)
  if e.message then
    panel(L.elrsIdle, e.messageList, c, c.levels[e.messageLevel])
  else
    cells(L.elrs, e.list, c, L.pad)
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
  -- The stick position is the dot. Gimbal travel is square, so a corner
  -- deflection sits outside the ring.
  local px = cx + floor(readAxis(ax) * g.travel / LIMIT)
  local py = cy - floor(readAxis(ay) * g.travel / LIMIT)
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
  fillRect(mid - 1, by - 2, 2, a.barH + 4, c.label)  -- centre mark
end

function M.screen(wgt)
  local L, c = wgt.lay, wgt.colors
  fillRect(0, 0, L.w, L.h, c.bg)
  if L.tooSmall then
    local x, y = floor(L.w / 2), floor(L.h / 2)
    local _, lineH = lcd.sizeText("A", SMLSIZE)
    drawText(x, y - lineH, "Pre-race:", SMLSIZE + CENTER + c.fg)
    drawText(x, y, "full screen only", SMLSIZE + CENTER + c.fg)
    return
  end

  cells(L.video, wgt.vtx.list, c, L.pad)
  elrsPanel(L, wgt.elrs, c)
  quadStrip(L, wgt, c)

  local s = wgt.sticks
  gimbal(L.left, s.left.x, s.left.y, c)
  gimbal(L.right, s.right.x, s.right.y, c)

  local a, aux = L.aux, wgt.aux
  for i = 1, #aux do
    auxCell(a.cells[i], aux[i], a, c)
  end
end

return M
