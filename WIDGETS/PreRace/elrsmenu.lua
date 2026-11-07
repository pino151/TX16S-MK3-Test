-- The ELRS settings menu, drawn over the whole widget in fullscreen: one row
-- per setting with < and > to step through its options, then CANCEL and
-- APPLY. elrs.lua holds the state and does the writing.

local M = {}

local floor, max = math.floor, math.max
local drawText = lcd.drawText
local fillRect = lcd.drawFilledRectangle

local TITLE = "ELRS SETTINGS"
local SAMPLE = "100Hz Full  -112dBm"  -- one of the longest values, to size the font

-- `fit(text, maxW, maxH)` returns the largest font that fits (layout.fit).
-- `rows` are elrs.lua's menu rows (4 or 5 of them).
function M.layout(w, h, fit, rows)
  local n = #rows
  local pad = max(2, floor(h / 80))
  local labelW = lcd.sizeText("DYNAMIC", SMLSIZE) + 2 * pad
  local titleH = floor(h * 0.14)
  local rowH = floor((h - titleH - (n + 3) * pad) / (n + 1))
  local btnW = floor(rowH * 1.4)
  local P = {
    w = w,
    h = h,
    n = n,
    title = { x = floor(w / 2), y = pad + floor(titleH / 2) },
    rows = {},
  }
  local y = 2 * pad + titleH
  local left, right = pad + labelW, w - pad - btnW
  for i = 1, n do
    P.rows[i] = {
      labelX = pad,
      cy = y + floor(rowH / 2),
      prev = { x = left, y = y, w = btnW, h = rowH },
      next = { x = right, y = y, w = btnW, h = rowH },
      valueX = floor((left + btnW + right) / 2),
    }
    y = y + rowH + pad
  end
  local half = floor((w - 3 * pad) / 2)
  P.cancel = { x = pad, y = y, w = half, h = rowH }
  P.ok = { x = 2 * pad + half, y = y, w = half, h = rowH }

  P.valueFont = fit(SAMPLE, right - left - btnW - 2 * pad, rowH - pad)
  P.arrowFont = fit("<", btnW - pad, rowH - pad)
  P.actionFont = fit("CANCEL", half - 2 * pad, rowH - pad)
  P.titleFont = fit(TITLE, w - 2 * pad, titleH)
  return P
end

-- `e` is the elrs.lua state; `button` is picker.lua's button drawer.
-- A changed value shows in the accent colour until APPLY.
function M.draw(P, e, c, button)
  fillRect(0, 0, P.w, P.h, c.bg)
  drawText(P.title.x, P.title.y, TITLE, P.titleFont + CENTER + VCENTER + c.fg)
  for i = 1, #e.rows do
    local row, R = e.rows[i], P.rows[i]
    drawText(R.labelX, R.cy, row.label, SMLSIZE + VCENTER + c.label)
    button(R.prev, "<", P.arrowFont, false, c, row.disabled)
    button(R.next, ">", P.arrowFont, false, c, row.disabled)
    local color = (row.disabled and c.line) or (row.changed and c.accent) or c.fg
    drawText(R.valueX, R.cy, row.text, P.valueFont + CENTER + VCENTER + color)
  end
  button(P.cancel, "CANCEL", P.actionFont, false, c)
  button(P.ok, "APPLY", P.actionFont, true, c)
end

local function inside(r, x, y)
  return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- What a tap at (x, y) hit: "cancel", "ok", or "prev"/"next" and the row's
-- index. Nothing if it missed.
function M.hit(P, x, y)
  if inside(P.cancel, x, y) then
    return "cancel"
  elseif inside(P.ok, x, y) then
    return "ok"
  end
  for i = 1, P.n do
    local R = P.rows[i]
    if inside(R.prev, x, y) then
      return "prev", i
    elseif inside(R.next, x, y) then
      return "next", i
    end
  end
end

return M
