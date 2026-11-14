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
  "elrsmenu", "status" }

local function loadModules()
  if not mods then
    mods = {}
    for _, name in ipairs(MODULES) do
      mods[name] = assert(loadScript(DIR .. name .. ".lua"))()
    end
  end
  return mods
end

local options = {
  { "Light", BOOL, 0 },             -- 1 = light background, for strong sun
  { "StickMode", VALUE, 0, 0, 4 },  -- 0 = use the radio's stick mode
  { "Cells", VALUE, 0, 0, 14 },     -- 0 = work out the quad's cell count
  { "Freestyle", BOOL, 0 },         -- VTX picker power labels: 0 = HDZero Race/Whoop, 1 = Freestyle
  { "ThemeBg", BOOL, 0 },           -- 1 = no black/white fill: the radio's own background shows
}

local function applyOptions(wgt, opts)
  wgt.options = opts
  wgt.colors = mods.draw.palette(opts.Light == 1)
  -- The main screen then draws no background and no panel fills. The VTX
  -- picker and the ELRS menu keep theirs, so their buttons stay readable.
  wgt.colors.clear = opts.ThemeBg == 1
  wgt.sticks = mods.chans.stickMap(opts.StickMode)
  mods.vtx.setFreestyle(wgt.vtx, opts.Freestyle == 1)
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
  if v.ui ~= "main" then
    m.picker.draw(pickerLayout(wgt), v, m.vtx, wgt.colors)
  elseif e.ui ~= "main" then
    m.elrsmenu.draw(menuLayout(wgt), e, wgt.colors, m.picker.button)
  else
    local lay = wgt.lay
    m.draw.screen(wgt)
    if lay.bar then
      m.status.update(wgt.status)
      m.status.draw(lay.bar, wgt.status, wgt.colors)
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
