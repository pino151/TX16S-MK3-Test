-- The VTX picker and its confirmation screen, drawn over the whole widget.
-- Only reachable in fullscreen, where touch events arrive.

local M = {}

local floor, max = math.floor, math.max
local drawText = lcd.drawText
local fillRect = lcd.drawFilledRectangle
local drawRect = lcd.drawRectangle

local ROW_LABELS = { "BAND", "CHAN", "POWER" }
local ROW_KINDS = { "band", "chan", "power" }

-- Shown on the confirm screen (WIDGET_SPEC.md: the send goes to every quad).
local CONFIRM_LINES = {
  "Send this to the VTX?",
  "ELRS sends it to every quad that connects,",
  "now and later, until you change it.",
}

local function buttonRow(x, y, w, h, n, gap)
  local row = {}
  local bw = floor((w - (n - 1) * gap) / n)
  for i = 1, n do
    row[i] = { x = x + (i - 1) * (bw + gap), y = y, w = bw, h = h }
  end
  return row
end

-- `fit(text, maxW, maxH)` returns the largest font that fits (layout.fit).
-- `counts`: number of band, channel and power buttons.
function M.layout(w, h, fit, counts)
  local pad = max(2, floor(h / 80))
  local labelW = lcd.sizeText("POWER", SMLSIZE) + 2 * pad
  local titleH = floor(h * 0.2)
  local rowH = floor((h - titleH - 6 * pad) / 4)  -- band, channel, power, buttons
  local P = {
    w = w,
    h = h,
    title = { x = pad, y = pad, w = w - 2 * pad, h = titleH },
    rows = {},
    labels = {},
  }
  local y = 2 * pad + titleH
  P.textY, P.textH = y, 3 * rowH + 2 * pad  -- confirm screen text area
  for r = 1, 3 do
    P.rows[r] = buttonRow(pad + labelW, y, w - 2 * pad - labelW, rowH, counts[r], pad)
    P.labels[r] = { x = pad, y = y + floor(rowH / 2) }
    y = y + rowH + pad
  end
  local half = floor((w - 3 * pad) / 2)
  P.cancel = { x = pad, y = y, w = half, h = rowH }
  P.ok = { x = 2 * pad + half, y = y, w = half, h = rowH }

  local narrowest = P.rows[3][1].w
  P.buttonFont = fit("8", narrowest - pad, rowH - pad)
  P.actionFont = fit("CONFIRM", half - 2 * pad, rowH - pad)
  P.titleFont = fit("R8  5917MHz  PWR 8", P.title.w - 2 * pad, titleH - pad)
  local lineH = floor(P.textH / 3)
  P.lineFonts = {
    fit(CONFIRM_LINES[1], w - 2 * pad, lineH),
    fit(CONFIRM_LINES[2], w - 2 * pad, lineH),
  }
  P.lineFonts[3] = P.lineFonts[2]
  P.lineH = lineH
  return P
end

local function button(r, text, font, selected, c)
  local color = c.fg
  if selected then
    fillRect(r.x, r.y, r.w, r.h, c.accent)
    color = c.bg
  else
    fillRect(r.x, r.y, r.w, r.h, c.panel)
    drawRect(r.x, r.y, r.w, r.h, c.line)
  end
  drawText(r.x + floor(r.w / 2), r.y + floor(r.h / 2), text, font + CENTER + VCENTER + color)
end

-- `v` is the vtx.lua state, `vtx` the module (for the button labels).
function M.draw(P, v, vtx, c)
  fillRect(0, 0, P.w, P.h, c.bg)
  local t = P.title
  drawText(t.x + floor(t.w / 2), t.y + floor(t.h / 2), v.title, P.titleFont + CENTER + VCENTER + c.fg)

  if v.ui == "confirm" then
    local x = floor(P.w / 2)
    for i = 1, #CONFIRM_LINES do
      local y = P.textY + (i - 1) * P.lineH + floor(P.lineH / 2)
      drawText(x, y, CONFIRM_LINES[i], P.lineFonts[i] + CENTER + VCENTER + (i == 1 and c.fg or c.label))
    end
    button(P.cancel, "BACK", P.actionFont, false, c)
    button(P.ok, "CONFIRM", P.actionFont, true, c)
    return
  end

  local s = v.sel
  for r = 1, 3 do
    drawText(P.labels[r].x, P.labels[r].y, ROW_LABELS[r], SMLSIZE + VCENTER + c.label)
  end
  local bands, chans, powers = P.rows[1], P.rows[2], P.rows[3]
  for i = 1, #bands do
    button(bands[i], vtx.BAND_LABELS[i], P.buttonFont, vtx.BANDS[i] == s.band, c)
  end
  for i = 1, #chans do
    button(chans[i], vtx.CHANNEL_LABELS[i], P.buttonFont, i == s.ch, c)
  end
  for i = 1, #powers do
    button(powers[i], vtx.POWER_LABELS[i], P.buttonFont, i - 1 == s.pwr, c)
  end
  button(P.cancel, "CANCEL", P.actionFont, false, c)
  button(P.ok, "SEND", P.actionFont, true, c)
end

local function inside(r, x, y)
  return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- What a tap at (x, y) hit: "cancel", "ok", or "band"/"chan"/"power" and the
-- button's index. Nothing if it missed.
function M.hit(P, ui, x, y)
  if inside(P.cancel, x, y) then
    return "cancel"
  elseif inside(P.ok, x, y) then
    return "ok"
  elseif ui == "picker" then
    for r = 1, 3 do
      local row = P.rows[r]
      for i = 1, #row do
        if inside(row[i], x, y) then
          return ROW_KINDS[r], i
        end
      end
    end
  end
end

return M
