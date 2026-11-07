-- Pre-race check dashboard. See WIDGET_SPEC.md in the repo.
-- Build steps 1-2: layout, live sticks and aux bars with output names, and
-- the QUAD telemetry strip.

local DIR = "/WIDGETS/PreRace/"

-- The modules hold no per-widget state, so every instance shares one copy.
-- They are loaded on the first create() so the widget costs almost nothing
-- unless it is actually placed on a screen.
local mods

local function loadModules()
  if not mods then
    mods = {}
    for _, name in ipairs({ "chans", "layout", "draw", "telem" }) do
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
  }
  applyOptions(wgt, opts)
  return wgt
end

local function update(wgt, opts)
  applyOptions(wgt, opts)
end

-- Only called while the widget is hidden, e.g. while the user is in the
-- menus, where they may rename outputs. Re-read the names when we're back.
-- Telemetry keeps updating so a pack swap made meanwhile is still noticed.
local function background(wgt)
  wgt.namesStale = true
  mods.telem.update(wgt.telem, wgt.options.Cells)
end

local function refresh(wgt, event, touchState)
  local m = mods
  m.telem.update(wgt.telem, wgt.options.Cells)
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
