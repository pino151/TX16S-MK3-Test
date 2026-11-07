-- The VTX picker, drawn over the whole widget.
-- Only reachable in fullscreen, where touch events arrive.

local M = {}

local floor, max = math.floor, math.max
local drawText = lcd.drawText
local fillRect = lcd.drawFilledRectangle
local drawRect = lcd.drawRectangle

local ROW_LABELS = { "BAND", "CHAN", "POWER" }
local ROW_KINDS = { "band", "chan", "power" }

local function buttonRow(x, y, w, h, n, gap)
  local row = {}
  local bw = floor((w - (n - 1) * gap) / n)
  for i = 1, n do
    row[i] = { x = x + (i - 1) * (bw + gap), y = y, w = bw, h = h }
  end
  return row
end

local function longest(list)
  local text = ""
  for i = 1, #list do
    if #list[i] > #text then
      text = list[i]
    end
  end
  return text
end

-- `fit(text, maxW, maxH)` returns the largest font that fits (layout.fit).
-- `v` is the vtx.lua state: its bands and power labels set the button rows
-- (they come from the FC's VTX table once it's read).
function M.layout(w, h, fit, v, channelLabels)
  local pad = max(2, floor(h / 80))
  local labelW = lcd.sizeText("POWER", SMLSIZE) + 2 * pad
  local titleH = floor(h * 0.2)
  local rowH = floor((h - titleH - 6 * pad) / 4)  -- band, channel, power, buttons
  local P = {
    w = w,
    h = h,
    options = v.options,
    title = { x = pad, y = pad, w = w - 2 * pad, h = titleH },
    rows = {},
    labels = {},
  }
  local y = 2 * pad + titleH
  local rowLabels = { v.bandLabels, channelLabels, v.powerLabels }
  -- Power buttons with what each level means on HDZero: the number moves
  -- up and the power goes underneath in small text.
  local _, subH = lcd.sizeText("0", SMLSIZE)
  local fontH, powerH
  for r = 1, 3 do
    local row = buttonRow(pad + labelW, y, w - 2 * pad - labelW, rowH, #rowLabels[r], pad)
    P.rows[r] = row
    P.labels[r] = { x = pad, y = y + floor(rowH / 2) }
    local textH = rowH - pad
    if r == 3 and v.powerSubs then
      textH = rowH - subH - pad
      for i = 1, #row do
        local b = row[i]
        b.cy = b.y + floor((b.h - subH) / 2)
        b.subY = b.y + b.h - floor((subH + pad) / 2)
      end
    end
    y = y + rowH + pad
    -- One font for every button: the one that fits the tightest row. Power
    -- buttons with text underneath have less room, so they may get a
    -- smaller one rather than shrinking every row.
    local font = fit(longest(rowLabels[r]), (row[1] and row[1].w or rowH) - pad, textH)
    local _, fh = lcd.sizeText("8", font)
    if textH < rowH - pad then
      P.powerFont, powerH = font, fh
    elseif not fontH or fh < fontH then
      P.buttonFont, fontH = font, fh
    end
  end
  if not P.powerFont or powerH > fontH then
    P.powerFont = P.buttonFont
  end
  local half = floor((w - 3 * pad) / 2)
  P.cancel = { x = pad, y = y, w = half, h = rowH }
  P.ok = { x = 2 * pad + half, y = y, w = half, h = rowH }

  P.actionFont = fit("CANCEL", half - 2 * pad, rowH - pad)
  P.titleFont = fit("R8  5917MHz  PWR 200", P.title.w - 2 * pad, titleH - pad)
  return P
end

-- `selected` fills the button; `disabled` (a channel the FC's VTX table
-- doesn't have) draws it as an outline with dim text. `sub` is small text
-- under the main text, at the layout's r.subY (power buttons only).
local function button(r, text, font, selected, c, disabled, sub, subColor)
  local color = c.fg
  if disabled then
    drawRect(r.x, r.y, r.w, r.h, c.line)
    color = c.line
  elseif selected then
    fillRect(r.x, r.y, r.w, r.h, c.accent)
    color = c.bg
  else
    fillRect(r.x, r.y, r.w, r.h, c.panel)
    drawRect(r.x, r.y, r.w, r.h, c.line)
  end
  local x = r.x + floor(r.w / 2)
  drawText(x, r.cy or r.y + floor(r.h / 2), text, font + CENTER + VCENTER + color)
  if sub then
    drawText(x, r.subY, sub, SMLSIZE + CENTER + VCENTER + (selected and color or subColor))
  end
end

-- The small text under power button i and its colour: "keep" for "-",
-- the video-off level in amber, levels the VTX doesn't have (they fall back
-- to its minimum) dimmed.
local function powerSub(subs, i, c)
  local level = i - 1
  if level == 0 then
    return "keep", c.label
  elseif level == subs.off then
    return subs[level], c.levels[2]
  elseif level > subs.real then
    return subs[level], c.line
  end
  return subs[level], c.fg
end
M.button = button  -- elrsmenu.lua uses it too

-- `v` is the vtx.lua state, `vtx` the module (for the channel labels).
function M.draw(P, v, vtx, c)
  fillRect(0, 0, P.w, P.h, c.bg)
  local t = P.title
  drawText(t.x + floor(t.w / 2), t.y + floor(t.h / 2), v.title, P.titleFont + CENTER + VCENTER + c.fg)

  local s = v.sel
  for r = 1, 3 do
    drawText(P.labels[r].x, P.labels[r].y, ROW_LABELS[r], SMLSIZE + VCENTER + c.label)
  end
  local bands, chans, powers = P.rows[1], P.rows[2], P.rows[3]
  for i = 1, #bands do
    button(bands[i], v.bandLabels[i], P.buttonFont, v.bands[i] == s.band, c)
  end
  for i = 1, #chans do
    button(chans[i], vtx.CHANNEL_LABELS[i], P.buttonFont, i == s.ch, c, not v.chanOk[i])
  end
  local subs = v.powerSubs
  for i = 1, #powers do
    local sub, subColor
    if subs then
      sub, subColor = powerSub(subs, i, c)
    end
    button(powers[i], v.powerLabels[i], P.powerFont, i - 1 == s.pwr, c, false, sub, subColor)
  end
  button(P.cancel, "CANCEL", P.actionFont, false, c)
  button(P.ok, "SEND", P.actionFont, true, c)
end

local function inside(r, x, y)
  return x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- What a tap at (x, y) hit: "cancel", "ok", or "band"/"chan"/"power" and the
-- button's index. Nothing if it missed.
function M.hit(P, x, y)
  if inside(P.cancel, x, y) then
    return "cancel"
  elseif inside(P.ok, x, y) then
    return "ok"
  end
  for r = 1, 3 do
    local row = P.rows[r]
    for i = 1, #row do
      if inside(row[i], x, y) then
        return ROW_KINDS[r], i
      end
    end
  end
end

return M
