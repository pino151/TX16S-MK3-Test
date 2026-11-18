-- The widget's own background image (the BgImage option): a PNG, JPG or BMP
-- from the SD card's /IMAGES folder. It's scaled to cover the zone without
-- stretching (an image of another shape is cropped evenly at the edges).
-- That's done once per image and zone size, and only the fitted copy is
-- kept: EdgeTX allows Lua bitmaps 2 MB in all, and an 800x480 one takes
-- 768 KB. An image exactly the zone's size needs no copy and draws fastest.

local M = {}

local floor, ceil, max = math.floor, math.ceil, math.max

M.FOLDER = "/IMAGES"

-- `name` is the option's value: a file name in /IMAGES, or "" for none.
function M.new(name)
  return { name = name or "" }
end

-- Bitmap.open() and Bitmap.resize() don't fail outright: they return an
-- empty bitmap (0x0) when the file isn't an image or memory ran out.
local function size(bmp)
  if not bmp then
    return 0, 0
  end
  return Bitmap.getSize(bmp)
end

local function fit(b, w, h)
  b.w, b.h, b.failed = w, h, false
  if b.bmp then
    b.bmp = nil
    collectgarbage()  -- free the old copy before loading again
  end
  if b.name == "" then
    return
  end
  local img = Bitmap.open(M.FOLDER .. "/" .. b.name)
  local iw, ih = size(img)
  if iw == 0 or ih == 0 then
    b.failed = true
    return
  end
  if iw == w and ih == h then
    b.bmp, b.x, b.y = img, 0, 0
    return
  end
  local scale = max(w / iw, h / ih)
  local nw, nh = ceil(iw * scale), ceil(ih * scale)
  local bmp = Bitmap.resize(img, nw, nh)
  img = nil
  collectgarbage()  -- drop the full-size image now
  if size(bmp) == 0 then
    b.failed = true  -- the full-size image used up the memory Lua bitmaps may have
    return
  end
  b.bmp, b.x, b.y = bmp, floor((w - nw) / 2), floor((h - nh) / 2)
end

-- Draws the image over a w x h zone, fitting it first if needed. Returns
-- true if it drew one (the screen then needs no background of its own).
function M.draw(b, w, h)
  if b.w ~= w or b.h ~= h then
    fit(b, w, h)
  end
  if b.bmp then
    lcd.drawBitmap(b.bmp, b.x, b.y)
    return true
  end
  return false
end

return M
