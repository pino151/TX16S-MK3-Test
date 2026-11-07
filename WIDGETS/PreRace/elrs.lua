-- ELRS panel: packet rate, TX power and telemetry ratio, read from the TX
-- module with crsf.lua and turned into short display strings, plus the ELRS
-- settings menu's state (elrsmenu.lua draws it): change the settings, write
-- them to the module and read them back. Works without a quad connected.

local M = {}

local gsub, match = string.gsub, string.match

-- Status levels, as in telem.lua.
local NONE, OK, WARN, BAD = 0, 1, 2, 3

-- Parameter names (ELRS 3.x and 4.x). "RF Band" only exists on ELRS 4.x
-- with an LR1121 (the MK3's internal module). The VTX Administrator ones are
-- used by vtx.lua; ELRS 4.x calls "Band" "Band/Enable".
local WANTED = { "RF Band", "Packet Rate", "Telem Ratio", "Max Power", "Dynamic",
  "Band", "Channel", "Pwr Lvl", "Send VTx" }
local ALIASES = { ["Band/Enable"] = "Band" }
-- A scan stops once these are in. "RF Band" comes before "Packet Rate", so
-- if it exists it has been seen by then.
local REQUIRED = { "Packet Rate", "Telem Ratio", "Max Power", "Dynamic",
  "Band", "Channel", "Pwr Lvl", "Send VTx" }

-- What the menu can change, in menu (and write) order. All are text
-- selections: the value written is the option's index. Packet rate, power
-- and telemetry ratio are stored per model in the ELRS module.
local SETTINGS = {
  { name = "RF Band", label = "RF BAND" },
  { name = "Packet Rate", label = "RATE" },
  { name = "Max Power", label = "POWER" },
  { name = "Dynamic", label = "DYNAMIC" },
  { name = "Telem Ratio", label = "TELEM" },
}
-- The panel cell that shows each setting's result after APPLY.
local CELL = { ["RF Band"] = "rate", ["Packet Rate"] = "rate", ["Max Power"] = "power",
  ["Dynamic"] = "power", ["Telem Ratio"] = "tlm" }

local SETTLE = 30        -- ticks after the writes before reading them back
local TIMEOUT = 500      -- ticks an APPLY may take before it counts as failed
local SHOW_RESULT = 500  -- ticks the green/red result stays on

local function cell()
  return { main = "--", sub = "", level = NONE }
end

-- `crsf` is the crsf.lua module.
function M.new(crsf)
  local e = {
    crsf = crsf,
    link = crsf.new(WANTED, REQUIRED, ALIASES),
    version = -1,
    rate = cell(),
    power = cell(),
    tlm = cell(),
    ui = "main",     -- main or menu
    state = "idle",  -- idle, writing, settling, verifying or done
    rows = {},
  }
  e.list = { e.rate, e.power, e.tlm }  -- panel order
  return e
end

local function set(c, main, sub, level)
  c.main, c.sub, c.level = main, sub, level or NONE
end

-- The selected option's text, or nil.
local function text(f)
  return f and f.text ~= "" and f.text or nil
end

-- "100Hz Full(-112dBm)" -> "100Hz" + "Full"; "200 Full Low Band" (ELRS 3.x
-- LR1121) -> "200Hz" + "Full 900M". On ELRS 4.x the RF Band is added: "2.4G".
local function formatRate(c, rate, band)
  local t = text(rate)
  t = t and gsub(gsub(t, "%(.-%)", ""), "Low Band", "900M")
  local main, rest = match(t or "", "^%s*(%S+)%s*(.-)%s*$")
  if not main then
    set(c, "--", "")
    return
  end
  if match(main, "^%d+$") then
    main = main .. "Hz"
  end
  local b = text(band)  -- "915MHz", "2.4GHz", "X-Band"
  if b then
    b = gsub(b, "Hz$", "")
    rest = rest == "" and b or (rest .. " " .. b)
  end
  set(c, main, rest)
end

-- "250" + "mW", or "1W"/"2W" from 1000 mW up so every value fits one font.
-- The detail shows dynamic power ("Dyn" or the AUX switch) when it's on.
local function formatPower(c, power, dynamic)
  local t = text(power)
  if not t then
    set(c, "--", "")
    return
  end
  local dyn = text(dynamic)
  dyn = (dyn and dyn ~= "Off") and dyn or ""
  local unit = power.unit or ""
  local mw = tonumber(t)
  if mw then
    set(c, mw >= 1000 and ((mw / 1000) .. "W") or (t .. unit), dyn)
  else
    -- EU LR1121 builds list two powers, e.g. "25/250": the unit goes beside the label.
    set(c, t, dyn == "" and unit or (unit .. " " .. dyn))
  end
end

-- "Std" + "1:64". Telemetry off is a warning: the QUAD strip needs it.
local function formatTlm(c, tlm)
  local t = text(tlm)
  if not t then
    set(c, "--", "")
    return
  end
  set(c, t, match(tlm.unit or "", "%((.-)%)") or "", t == "Off" and WARN or NONE)
end

local MESSAGES = {
  nomodule = { "NO MODULE", WARN },
  noreply = { "NO REPLY", WARN },
  notelrs = { "NOT ELRS", WARN },
  reading = { "READING", NONE },
}

-- Menu --------------------------------------------------------------------

-- An option as the menu shows it: "100Hz Full(-112dBm)" -> "100Hz Full  -112dBm".
local function optionText(row, i)
  local t = gsub(gsub(row.field.options[i + 1] or "?", "%(", "  "), "%)", "")
  if row.name == "Max Power" then
    t = t .. (row.field.unit or "")
  end
  return t
end

-- Each row's text, whether it differs from the module's value, and whether
-- it can be changed: a new RF band makes ELRS pick the packet rate itself.
local function describeRows(e)
  local bandChanged = false
  for i = 1, #e.rows do
    local row = e.rows[i]
    row.changed = row.sel ~= row.field.value
    row.disabled = row.name == "Packet Rate" and bandChanged
    if row.disabled then
      row.sel = row.field.value
      row.changed, row.text = false, "set by RF band"
    else
      row.text = optionText(row, row.sel)
    end
    bandChanged = bandChanged or (row.name == "RF Band" and row.changed)
  end
end

-- Open the menu on the module's current values. False if there are none.
function M.open(e)
  local f, rows = e.link.fields, {}
  for i = 1, #SETTINGS do
    local s = SETTINGS[i]
    local field = f[s.name]
    if field and field.options and field.value then
      rows[#rows + 1] = { name = s.name, label = s.label, field = field, sel = field.value }
    end
  end
  if #rows == 0 then
    return false
  end
  e.rows = rows
  describeRows(e)
  e.ui = "menu"
  return true
end

function M.close(e)
  e.ui = "main"
end

-- The next (dir 1) or previous (dir -1) option, skipping the empty entries
-- ELRS uses for values the hardware doesn't support, wrapping round.
local function step(row, dir)
  local options = row.field.options
  local n, i = #options, row.sel
  for _ = 1, n do
    i = (i + dir) % n
    if options[i + 1] ~= "" then
      row.sel = i
      return
    end
  end
end

-- Mark each changed setting's panel cell green if the module now holds the
-- new value, red if not. `checked` = false: none got through.
local function finish(e, now, checked)
  local result, fields = {}, e.link.fields
  for i = 1, #e.changes do
    local row = e.changes[i]
    local f = fields[row.name]
    local ok = checked and f and f.value == row.sel
    local name = CELL[row.name]
    if result[name] ~= BAD then
      result[name] = ok and OK or BAD
    end
  end
  e.result, e.state, e.resultUntil = result, "done", now + SHOW_RESULT
end

-- Write the changed settings, in menu order.
local function apply(e)
  local link, crsf, now = e.link, e.crsf, getTime()
  local changes, names, ok = {}, {}, true
  for i = 1, #e.rows do
    local row = e.rows[i]
    if row.changed then
      changes[#changes + 1] = row
      names[#names + 1] = row.name
      ok = crsf.write(link, row.name, row.sel) and ok
      if row.name == "RF Band" then
        names[#names + 1] = "Packet Rate"  -- ELRS picks a new one
      end
    end
  end
  e.ui = "main"
  if #changes == 0 then
    return
  end
  e.changes, e.readNames, e.deadline = changes, names, now + TIMEOUT
  if ok then
    e.state = "writing"
  else
    crsf.clearWrites(link)
    finish(e, now, false)
  end
end

-- A tap in the menu: "prev"/"next" with the row's index, "cancel" or "ok".
function M.choose(e, kind, i)
  local row = e.rows[i]
  if (kind == "prev" or kind == "next") and row and not row.disabled then
    step(row, kind == "next" and 1 or -1)
    describeRows(e)
  elseif kind == "cancel" then
    e.ui = "main"
  elseif kind == "ok" then
    apply(e)
  end
end

-- After APPLY: writes go out, the module settles, then they're read back.
local function stepApply(e, now)
  local st, link, crsf = e.state, e.link, e.crsf
  if (st == "writing" or st == "settling" or st == "verifying") and now >= e.deadline then
    crsf.clearWrites(link)
    finish(e, now, false)
  elseif st == "writing" and not crsf.writing(link) then
    e.state, e.readAt = "settling", now + SETTLE
  elseif st == "settling" and now >= e.readAt then
    if crsf.read(link, e.readNames) then
      e.state = "verifying"
    end
  elseif st == "verifying" and not crsf.busy(link) then
    finish(e, now, true)
  elseif st == "done" and now >= e.resultUntil then
    e.state, e.result = "idle", nil
  end
end

-- Call from refresh() and background(). allowReread = false while armed.
function M.update(e, allowReread)
  local link = e.link
  e.crsf.update(link, allowReread)
  stepApply(e, getTime())

  local f = link.fields
  if not (f["Packet Rate"] or f["Telem Ratio"] or f["Max Power"]) then
    -- Nothing to show yet: say why.
    local m = MESSAGES[link.status] or MESSAGES.reading
    if e.message ~= m[1] then
      e.message, e.messageLevel = m[1], m[2]
      e.messageList = { m[1] }
    end
    return
  end
  e.message = nil
  if link.version ~= e.version or e.state ~= e.shown then
    e.version, e.shown = link.version, e.state
    formatRate(e.rate, f["Packet Rate"], f["RF Band"])
    formatPower(e.power, f["Max Power"], f["Dynamic"])
    formatTlm(e.tlm, f["Telem Ratio"])
    local result = e.state == "done" and e.result
    if result then
      for name, level in pairs(result) do
        e[name].level = level
      end
    end
  end
end

-- Read everything again (ENTER, or a tap with nothing to show).
function M.refresh(e)
  e.crsf.restart(e.link)
end

return M
