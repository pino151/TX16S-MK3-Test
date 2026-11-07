-- Pre-race check dashboard. See WIDGET_SPEC.md in the repo.
-- Build steps 1-3: layout, live sticks and aux bars with output names, the
-- QUAD telemetry strip, and ELRS settings read from the TX module.

local DIR = "/WIDGETS/PreRace/"

-- The modules hold no per-widget state, so every instance shares one copy.
-- They are loaded on the first create() so the widget costs almost nothing
-- unless it is actually placed on a screen.
local mods

local function loadModules()
  if not mods then
    mods = {}
    for _, name in ipairs({ "chans", "layout", "draw", "telem", "crsf", "elrs" }) do
      mods[name] = assert(loadScript(DIR .. name .. ".lua"))()
    end
  end
  return mods
end

local options = {
  { "Light", BOOL, 0 },             -- 1 = light background, for strong sun
  { "StickMode", VALUE, 0, 0, 4 },  -- 0 = use the radio's stick mode
  { "Cells", VALUE, 0, 0, 14 },     -- 0 = work out the quad's cell count
}

local function applyOptions(wgt, opts)
  wgt.options = opts
  wgt.colors = mods.draw.palette(opts.Light == 1)
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
  }
  applyOptions(wgt, opts)
  return wgt
end

local function update(wgt, opts)
  applyOptions(wgt, opts)
end

-- Telemetry and the ELRS reader keep running whether or not the widget is
-- visible. The ELRS settings aren't re-read periodically while armed.
local function updateData(wgt)
  mods.telem.update(wgt.telem, wgt.options.Cells)
  mods.elrs.update(wgt.elrs, not wgt.telem.armed)
end

-- Only called while the widget is hidden, e.g. while the user is in the
-- menus, where they may rename outputs. Re-read the names when we're back.
local function background(wgt)
  wgt.namesStale = true
  updateData(wgt)
end

local function inside(r, x, y)
  return r and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h
end

-- Events only arrive in fullscreen (long-press the widget to get there).
-- A tap on the ELRS panel, or ENTER, reads the ELRS settings again.
local function onEvent(wgt, event, touchState)
  if touchState then
    if event == EVT_TOUCH_TAP and inside(wgt.lay.elrs, touchState.x, touchState.y) then
      mods.elrs.refresh(wgt.elrs)
    end
  elseif event == EVT_VIRTUAL_ENTER then
    mods.elrs.refresh(wgt.elrs)
  end
end

local function refresh(wgt, event, touchState)
  local m = mods
  updateData(wgt)
  if event and event ~= 0 then
    onEvent(wgt, event, touchState)
  end
  local zone = wgt.zone
  local lay = wgt.lay
  -- EdgeTX updates the zone table in place when the widget is resized.
  local atOrigin = (zone.xabs or 0) == 0 and (zone.yabs or 0) == 0
  if not lay or lay.w ~= zone.w or lay.h ~= zone.h or lay.atOrigin ~= atOrigin then
    lay = m.layout.compute(zone.w, zone.h, #wgt.aux, atOrigin)
    wgt.lay = lay
    wgt.namesStale = true  -- name fonts depend on the layout
  end
  if wgt.namesStale then
    m.chans.readNames(wgt.aux)
    m.layout.fitNames(lay, wgt.aux)
    wgt.namesStale = false
  end
  m.draw.screen(wgt)
end

return {
  name = "Pre-race",
  options = options,
  create = create,
  update = update,
  refresh = refresh,
  background = background,
}
