-- Screen layout, computed from the zone size so the same code works at
-- 800x480 (MK3), 480x272 (MK2) and other zone sizes. It only measures text
-- with lcd.sizeText and never draws.

local M = {}

local floor, max, min = math.floor, math.max, math.min

-- Fonts from largest to smallest. XXLSIZE and DBLSIZE are bold.
local FONTS = { XXLSIZE, DBLSIZE, MIDSIZE, BOLD, SMLSIZE }
-- Output names get one smaller step, for long names on small screens.
local NAME_FONTS = { XXLSIZE, DBLSIZE, MIDSIZE, BOLD, SMLSIZE, TINSIZE or SMLSIZE }

local AUX_ROWS = 6  -- two columns of 5, then one channel centred below

local function fits(text, font, maxW, maxH)
  local w, h = lcd.sizeText(text, font)
  return w <= maxW and h <= maxH
end

-- Index in `fonts` of the largest font in which `text` fits in maxW x maxH.
local function fitIndex(fonts, text, maxW, maxH)
  for i = 1, #fonts do
    if fits(text, fonts[i], maxW, maxH) then
      return i
    end
  end
  return #fonts
end

-- The largest font in which `text` fits in maxW x maxH.
function M.fit(text, maxW, maxH)
  return FONTS[fitIndex(FONTS, text, maxW, maxH)]
end

-- A framed panel split into columns. Each column has a small label at the
-- top (with room for a detail right-aligned on the same line) and one
-- value centred in the space below. `cols` is a list of
-- { label, sample text that sets the value font, relative width }.
-- `inset` keeps the content clear of the panel's left edge (at least pad).
-- `sameFont` gives every column the font of the tightest one.
local function panel(x, y, w, h, pad, labelH, cols, inset, sameFont)
  local p = { x = x, y = y, w = w, h = h, cols = {} }
  inset = max(pad, inset or 0)
  local total = 0
  for i = 1, #cols do
    total = total + cols[i][3]
  end
  local valueH = h - labelH - 2 * pad
  local cx = x + inset
  local smallest = 1
  for i = 1, #cols do
    local spec = cols[i]
    local cw = floor((w - inset - pad) * spec[3] / total)
    local fi = fitIndex(FONTS, spec[2], cw - pad, valueH)
    smallest = max(smallest, fi)
    p.cols[i] = {
      x = cx,
      right = cx + cw - pad,
      labelY = y + pad,
      label = spec[1],
      labelW = lcd.sizeText(spec[1], SMLSIZE),
      font = FONTS[fi],
      cx = cx + floor(cw / 2),
      cy = y + pad + labelH + floor(valueH / 2),
    }
    cx = cx + cw
  end
  if sameFont then
    for i = 1, #p.cols do
      p.cols[i].font = FONTS[smallest]
    end
  end
  return p
end

-- A square gimbal box of size s, with a row of axis values underneath.
local function gimbal(x, y, s, pad, labelH)
  local r = floor(s / 2) - 1
  local dot = max(3, floor(s / 24))
  return {
    x = x,
    y = y,
    s = s,
    cx = x + floor(s / 2),
    cy = y + floor(s / 2),
    r = r,
    dot = dot,
    travel = r - dot - 1,  -- full deflection puts the dot just inside the ring
    textY = y + s + pad + floor(labelH / 2),
  }
end

-- Aux cells: the first 10 channels in two columns of 5, the 11th centred
-- below. Designed for 11 channels.
local function auxGrid(x, y, w, h, pad, count)
  local rowH = floor(h / AUX_ROWS)
  local colW = floor((w - pad) / 2)
  local g = {
    rowH = rowH,
    colW = colW,
    nameW = floor(colW * 0.45),
    gap = pad,
    barH = max(6, floor(rowH * 0.5)),
    nameFont = SMLSIZE,
    cells = {},
  }
  for i = 1, count do
    local cx, row
    if i <= 10 then
      row = (i - 1) % 5
      cx = x + floor((i - 1) / 5) * (colW + pad)
    else
      row = 5
      cx = x + floor((w - colW) / 2)
    end
    g.cells[i] = { x = cx, y = y + row * rowH }
  end
  return g
end

-- `atOrigin`: the zone starts at the screen's top-left corner, as in App
-- mode, where EdgeTX's menu button sits over that corner (45 px square at
-- 480x272, 62 px at 800x480). The layout keeps that corner clear.
function M.compute(w, h, auxCount, atOrigin)
  local L = { w = w, h = h, atOrigin = atOrigin }
  if w < 300 or h < 170 then
    L.tooSmall = true
    return L
  end

  local pad = max(2, floor(h / 80))
  L.pad = pad
  local _, labelH = lcd.sizeText("A", SMLSIZE)
  local innerW = w - 2 * pad
  local topH = floor(h * 0.28)
  local stripH = floor(h * 0.19)
  local corner = atOrigin and (max(45, floor(h * 0.13)) + pad) or 0

  -- Top band: VIDEO on the left, ELRS on the right.
  local videoW = floor(innerW * 0.36)
  L.video = panel(pad, pad, videoW, topH, pad, labelH, {
    { "VIDEO", "R8", 62 },
    { "PWR", "8", 38 },
  }, corner - pad)
  -- Power from 1000mW is shown as "1W"/"2W", so "500mW" is the widest.
  local elrsX, elrsW = 2 * pad + videoW, innerW - videoW - pad
  L.elrs = panel(elrsX, pad, elrsW, topH, pad, labelH, {
    { "RATE", "DK500", 1 },
    { "TX PWR", "500mW", 1 },
    { "TLM", "1:128", 1 },
  }, pad, true)
  L.elrsIdle = panel(elrsX, pad, elrsW, topH, pad, labelH, {
    { "ELRS", "NO MODULE", 1 },
  })

  -- Bottom strip: QUAD status, as four cells once linked, else "NO LINK".
  local stripY = h - pad - stripH
  L.strip = panel(pad, stripY, innerW, stripH, pad, labelH, {
    { "LINK", "100%", 1 },
    { "PACK", "4.20V", 1 },
    { "FC", "NO ARM", 1 },
    { "VTX", "R8", 1 },
  }, pad, true)
  L.stripIdle = panel(pad, stripY, innerW, stripH, pad, labelH, {
    { "QUAD", "NO LINK", 1 },
  })

  -- Middle band: left gimbal, aux grid, right gimbal, laid out like the
  -- radio itself.
  local midY = 2 * pad + topH
  local midH = h - topH - stripH - 4 * pad
  local s = min(midH - pad - labelH, floor(w * 0.23))
  local gy = midY + floor((midH - (s + pad + labelH)) / 2)
  L.left = gimbal(pad, gy, s, pad, labelH)
  L.right = gimbal(w - pad - s, gy, s, pad, labelH)
  local auxX = 2 * pad + s
  L.aux = auxGrid(auxX, midY, w - 2 * auxX, midH, pad, auxCount)
  return L
end

-- One font for all output names: the largest in which every name fits.
function M.fitNames(L, list)
  if L.tooSmall then
    return
  end
  local a = L.aux
  for f = 1, #NAME_FONTS do
    local font = NAME_FONTS[f]
    local ok = true
    for i = 1, #list do
      if not fits(list[i].name, font, a.nameW, a.rowH) then
        ok = false
        break
      end
    end
    if ok or f == #NAME_FONTS then
      a.nameFont = font
      return
    end
  end
end

return M
