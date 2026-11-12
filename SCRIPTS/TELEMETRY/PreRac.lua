-- Pre-race check screen for 128x64 radios (RadioMaster TX12 and Pocket).
-- The black-and-white sibling of WIDGETS/PreRace: see WIDGET_SPEC.md.
-- Set it up in Model > Display as a Script screen, then press TELE on the
-- main view. Scroll picks VIDEO or ELRS (marked by the bar under it), ENTER
-- opens its menu. Hold RTN to leave.
-- The code lives in /SCRIPTS/PRERACE/ and is loaded in pieces to save memory.

local DIR = "/SCRIPTS/PRERACE/"

local L, V     -- link.lua and view.lua, loaded in init
local s, S     -- their states
local P, page  -- menu.lua and the open menu, only while one is open
local focus = 0
local lastRun = 0

local function load(name)
  return assert(loadScript(DIR .. name .. ".lua"))()
end

local function init()
  L, V = load("link"), load("view")
  s, S = L.new(), V.new()
end

-- Called all the time, also while another screen shows. Nothing is asked of
-- the module then, except to finish a send that was started.
local function background()
  local now = getTime()
  if s and #s.w > 0 and now - lastRun > 20 then
    L.update(s, now, false, false)
  end
end

local function run(event)
  local now = getTime()
  lastRun = now
  L.update(s, now, S.linked, S.armed)
  if page then
    if not P.event(page, event, s, L) then
      P.draw(page, s, L, V)
      return 0
    end
    P, page = nil, nil
    collectgarbage()
  elseif event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_PREV then
    focus = 1 - focus
  elseif event == EVT_VIRTUAL_ENTER then
    P = load("menu")
    page = P.open(focus == 0 and "vtx" or "elrs", s, L)
    if page then
      P.draw(page, s, L, V)
      return 0
    end
    P = nil
  end
  V.draw(S, s, L, focus)
  return 0
end

return { init = init, background = background, run = run }
