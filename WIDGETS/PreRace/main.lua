-- Pre-race check dashboard. See WIDGET_SPEC.md in the repo.
-- A status bar with the date and the radio's battery,
-- live sticks and aux bars with output names, the QUAD telemetry strip, ELRS
-- settings read from the TX module (and a menu to change them), a VTX
-- channel picker that sends through ELRS VTX Administrator, and the FC's VTX
-- setting read back over MSP.

local DIR = "/WIDGETS/PreRace/"

-- The modules hold no per-widget state, so every instance shares one copy.
-- They are loaded on the first create() so the widget costs almost nothing
-- unless it is actually placed on a screen.
local mods
local MODULES = { "chans", "layout", "draw", "telem", "crsf", "elrs", "msp", "vtx", "picker",
  "elrsmenu", "status", "bg" }

local function loadModules()
  if not mods then
    mods = {}
    for _, name in ipairs(MODULES) do
      mods[name] = assert(loadScript(DIR .. name .. ".lua"))()
    end
  end
  return mods
end

-- EdgeTX keeps option values by position, and resets one whose type
-- changes. BgImage took over the old Freestyle slot (4), so ThemeBg (5)
-- keeps its value across the update.
local options = {
  { "Light", BOOL, 0 },             -- 1 = light background, for strong sun
  { "StickMode", VALUE, 0, 0, 4 },  -- 0 = use the radio's stick mode
  { "Cells", VALUE, 0, 0, 14 },     -- 0 = work out the quad's cell count
  { "BgImage", FILE, "", "/IMAGES" },  -- a background image from /IMAGES (bg.lua)
  { "ThemeBg", BOOL, 0 },           -- 1 = no black/white fill: the radio's own background shows
  { "BgDim", VALUE, 65, 0, 100 },   -- % of a background image the see-through backdrops hide
}

local function applyOptions(wgt, opts)
  wgt.options = opts
  wgt.colors = mods.draw.palette(opts.Light == 1)
  -- ThemeBg: the main screen draws no background and no panel fills. The
  -- VTX picker and the ELRS menu keep theirs, so their buttons stay readable.
  -- A background image does the same while it shows (refresh()).
  wgt.themeBg = opts.ThemeBg == 1
  -- BgDim in %, as EdgeTX's transparency for lcd.drawFilledRectangle: 0 is
  -- solid, 15 is see-through (none drawn). Lua 5.3: keep it an integer.
  local pct = math.max(0, math.min(100, opts.BgDim or 65))
  wgt.colors.dim = 15 - math.floor(pct * 15 / 100 + 0.5)
  local name = opts.BgImage or ""
  if not wgt.bg or wgt.bg.name ~= name then
    wgt.bg = nil
    collectgarbage()  -- free the old image before the new one loads
    wgt.bg = mods.bg.new(name)
  end
  wgt.sticks = mods.chans.stickMap(opts.StickMode)
end

local function create(zone, opts)
  local m = loadModules()
  local wgt = {
    zone = zone,
    aux = m.chans.auxList(),
    namesStale = true,
    telem = m.telem.new(),
    elrs = m.elrs.new(m.crsf),
    msp = m.msp.new(),
    vtx = m.vtx.new(),
    status = m.status.new(),
  }
  -- The ELRS reader pops every CRSF frame, so it hands MSP replies on.
  wgt.elrs.link.handlers[m.msp.MSP_RESP] = function(data)
    m.msp.handle(wgt.msp, data)
  end
  local t = wgt.telem
  wgt.stripCells = { t.link, t.pack, t.fc }  -- QUAD strip order
  applyOptions(wgt, opts)
  return wgt
end

local function update(wgt, opts)
  applyOptions(wgt, opts)
end

-- Telemetry, the ELRS reader, VTX sends and FC reads keep running whether or
-- not the widget is visible. Nothing is polled periodically while armed.
local function updateData(wgt)
  local m, t = mods, wgt.telem
  m.telem.update(t, wgt.options.Cells)
  m.elrs.update(wgt.elrs, not t.armed)
  m.vtx.update(wgt.vtx, m.crsf, wgt.elrs.link, m.msp, wgt.msp, t.linked, t.armed)
end

-- Only called while the widget is hidden, e.g. while the user is in the
-- menus, where they may rename outputs. Re-read the names when we're back.
local function background(wgt)
  wgt.namesStale = true
  updateData(wgt)
end

-- The main layout, computed again whenever the zone changes size.
local function mainLayout(wgt)
  local m, zone, lay = mods, wgt.zone, wgt.lay
  if not lay or lay.w ~= zone.w or lay.h ~= zone.h then
    lay = m.layout.compute(zone.w, zone.h, #wgt.aux)
    wgt.lay = lay
    wgt.namesStale = true  -- name fonts depend on the layout
  end
  if wgt.namesStale then
    m.chans.readNames(wgt.aux)
    m.layout.fitNames(lay, wgt.aux)
    wgt.namesStale = false
  end
  return lay
end

-- The picker's layout, made again when the zone or the choices change (the
-- FC's VTX table sets the bands and power levels).
local function pickerLayout(wgt)
  local m, zone, p, v = mods, wgt.zone, wgt.pick, wgt.vtx
  if not p or p.w ~= zone.w or p.h ~= zone.h or p.options ~= v.options then
    p = m.picker.layout(zone.w, zone.h, m.layout.fit, v, m.vtx.CHANNEL_LABELS)
    wgt.pick = p
  end
  return p
end

-- The ELRS menu's layout, made again when the zone or its rows change.
local function menuLayout(wgt)
  local m, zone, p, e = mods, wgt.zone, wgt.menu, wgt.elrs
  if not p or p.w ~= zone.w or p.h ~= zone.h or p.n ~= #e.rows then
    p = m.elrsmenu.layout(zone.w, zone.h, m.layout.fit, e.rows)
    wgt.menu = p
  end
  return p
end

local function inside(r, x, y)
  return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- Events only arrive in fullscreen (long-press the widget to get there).
-- Main screen: a tap on the VIDEO panel opens the VTX picker, a tap on the
-- ELRS panel the ELRS menu (or, with no settings to show, reads them
-- again), and ENTER reads the ELRS settings again.
-- Picker and menu: taps choose and send; EXIT closes them.
local function onEvent(wgt, event, touchState)
  local m, v, e = mods, wgt.vtx, wgt.elrs
  local tap = touchState and event == EVT_TOUCH_TAP
  if v.ui ~= "main" then
    if tap then
      local kind, i = m.picker.hit(pickerLayout(wgt), touchState.x, touchState.y)
      if kind then
        m.vtx.choose(v, kind, i, m.crsf, e.link)
      end
    elseif event == EVT_VIRTUAL_EXIT then
      m.vtx.close(v)
    end
  elseif e.ui ~= "main" then
    if tap then
      local kind, i = m.elrsmenu.hit(menuLayout(wgt), touchState.x, touchState.y)
      if kind then
        m.elrs.choose(e, kind, i)
      end
    elseif event == EVT_VIRTUAL_EXIT then
      m.elrs.close(e)
    end
  elseif tap then
    local lay, x, y = wgt.lay, touchState.x, touchState.y
    if inside(lay.video, x, y) then
      m.vtx.open(v, e.link.fields)
    elseif inside(lay.elrs, x, y) then
      if not m.elrs.open(e) then
        m.elrs.refresh(e)
      end
    end
  elseif event == EVT_VIRTUAL_ENTER then
    m.elrs.refresh(wgt.elrs)
  end
end

local function refresh(wgt, event, touchState)
  local m, v, e = mods, wgt.vtx, wgt.elrs
  updateData(wgt)
  mainLayout(wgt)
  if event == nil then
    -- Not fullscreen (any more): no taps, so close the picker and menu.
    m.vtx.close(v)
    m.elrs.close(e)
  elseif event ~= 0 then
    onEvent(wgt, event, touchState)
  end
  local c = wgt.colors
  if v.ui ~= "main" then
    c.line, c.label = c.solid.line, c.solid.label
    m.picker.draw(pickerLayout(wgt), v, m.vtx, c)
  elseif e.ui ~= "main" then
    c.line, c.label = c.solid.line, c.solid.label
    m.elrsmenu.draw(menuLayout(wgt), e, c, m.picker.button)
  else
    -- Over a background image or the radio's own background, the text sits
    -- on see-through backdrops (draw.backdrop) with brighter labels and lines.
    local lay, bg = wgt.lay, wgt.bg
    c.clear = wgt.themeBg
    if not lay.tooSmall and m.bg.draw(bg, lay.w, lay.h) then
      c.clear = true
    end
    local set = c.clear and c.seeThrough or c.solid
    c.line, c.label = set.line, set.label
    m.draw.screen(wgt)
    if lay.bar then
      m.status.update(wgt.status)
      m.status.draw(lay.bar, wgt.status, c, bg.failed and "IMAGE NOT LOADED", m.draw.backdrop)
    end
  end
end

return {
  name = "Pre-race",
  options = options,
  create = create,
  update = update,
  refresh = refresh,
  background = background,
}
