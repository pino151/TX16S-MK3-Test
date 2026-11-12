-- Pre-race screen for 128x64 radios: the VTX and ELRS menus. Loaded when one
-- is opened and dropped again when it closes, to keep memory free.
-- Scroll moves between the rows, ENTER edits a row (scroll then changes its
-- value, ENTER again keeps it and jumps to the button), RTN cancels the edit
-- or closes the menu. Nothing is sent until SEND or APPLY.

local M = {}

local text, fill = lcd.drawText, lcd.drawFilledRectangle
local gsub = string.gsub

-- `kind` is "vtx" or "elrs", `s` the link state, `L` the link module.
-- Returns the menu, or nil while the module's settings aren't known.
function M.open(kind, s, L)
  local f, rows = s.f, {}
  local function add(label, name, lo)
    local fl = f[name]
    if fl and fl.v then
      local hi = fl.hi
      if fl.o then  -- a selection: its last option
        hi = -1
        for _ in string.gmatch(fl.o .. ";", "([^;]*);") do
          hi = hi + 1
        end
      end
      rows[#rows + 1] = { label = label, name = name, f = fl, v = fl.v, was = fl.v,
        lo = lo or fl.lo or 0, hi = hi }
    end
  end
  local p = { kind = kind, rows = rows, pos = 1, edit = false }
  if kind == "vtx" then
    add("Band", "Band", 1)  -- 0 is "off": not offered, as on the colour widget
    add("Chan", "Channel")
    add("Power", "Pwr Lvl")
    if #rows < 3 or not f["Send VTx"] then
      return nil
    end
    if rows[1].v < 1 then
      rows[1].v = 5  -- VTX Admin was off: start on R
    end
    p.pos, p.edit = 2, true  -- the channel is what changes most
    rows[2].old = rows[2].v
  else
    add("Band", "RF Band")
    add("Rate", "Packet Rate")
    add("Power", "Max Power")
    add("Dynamic", "Dynamic")
    add("Telem", "Telem Ratio")
    if #rows == 0 then
      return nil
    end
  end
  return p
end

-- The row a changed RF band rules out: the rates belong to the old band.
local function disabled(p, row)
  return row.name == "Packet Rate" and p.rows[1].name == "RF Band" and p.rows[1].v ~= p.rows[1].was
end

local function label(row, L, V)
  local f, v = row.f, row.v
  if not f.o then
    return v
  end
  local t = L.opt(f, v) or "?"
  if row.name == "Pwr Lvl" then
    return v > 0 and (t .. "  " .. V.POWER[v]) or "-  keep"
  elseif row.name == "Max Power" then
    return t .. (f.u or "")
  end
  return gsub(t, "%(.-%)", "")
end

-- Step to the next value, skipping the empty options ELRS 4.x leaves for
-- the rates of the other RF band.
local function step(row, d, L)
  local v = row.v
  for _ = row.lo, row.hi do
    v = v + d
    if v > row.hi then
      v = row.lo
    elseif v < row.lo then
      v = row.hi
    end
    if not row.f.o or L.opt(row.f, v) ~= "" then
      row.v = v
      return
    end
  end
end

local function apply(p, s, L)
  local rows = p.rows
  if p.kind == "vtx" then
    for i = 1, 3 do
      L.write(s, rows[i].name, rows[i].v)
    end
    L.write(s, "Send VTx", 1)  -- 1 = pressed
  else
    for i = 1, #rows do
      if rows[i].v ~= rows[i].was and not disabled(p, rows[i]) then
        L.write(s, rows[i].name, rows[i].v)
      end
    end
  end
end

-- Returns true when the menu is finished with (sent, applied or cancelled).
function M.event(p, event, s, L)
  local rows = p.rows
  local row = rows[p.pos]
  if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_PREV then
    local d = event == EVT_VIRTUAL_NEXT and 1 or -1
    if p.edit then
      step(row, d, L)
    else
      p.pos = (p.pos - 1 + d) % (#rows + 1) + 1
    end
  elseif event == EVT_VIRTUAL_ENTER then
    if not row then
      apply(p, s, L)
      return true
    elseif p.edit then
      p.edit, p.pos = false, #rows + 1
    elseif not disabled(p, row) then
      p.edit, row.old = true, row.v
    end
  elseif event == EVT_VIRTUAL_EXIT then
    if not p.edit then
      return true
    end
    p.edit, row.v = false, row.old
  end
  return false
end

function M.draw(p, s, L, V)
  local rows, vtx = p.rows, p.kind == "vtx"
  lcd.clear()
  if vtx then
    local band, ch = rows[1].v, rows[2].v
    text(1, 1, "VTX  " .. (L.opt(rows[1].f, band) or "?") .. ch .. "  " .. (V.freq(band, ch) or "?")
      .. "MHz", 0)
  else
    text(1, 1, "ELRS SETTINGS", 0)
  end
  fill(0, 0, 128, 9)  -- inverts the title line
  local y = 11
  for i = 1, #rows do
    local row = rows[i]
    text(1, y + 1, row.label, SMLSIZE)
    if disabled(p, row) then
      text(40, y + 1, "set by band", SMLSIZE)
    else
      local flags = i == p.pos and (p.edit and INVERS + BLINK or INVERS) or 0
      text(40, y, label(row, L, V), flags)
      if row.v ~= row.was and not vtx then
        text(128, y + 1, "*", SMLSIZE + RIGHT)  -- changed, not applied yet
      end
    end
    y = y + 9
  end
  text(64, y, vtx and "[ SEND ]" or "[ APPLY ]", CENTER + (p.pos > #rows and INVERS or 0))
  if y < 47 then
    text(1, 57, "RTN: cancel", SMLSIZE)
  end
end

return M
