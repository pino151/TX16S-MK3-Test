-- ELRS panel: packet rate, TX power and telemetry ratio, read from the TX
-- module with crsf.lua and turned into short display strings. Works without
-- a quad connected.

local M = {}

local gsub, match = string.gsub, string.match

-- Status levels, as in telem.lua.
local NONE, WARN = 0, 2

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

-- Call from refresh() and background(). allowReread = false while armed.
function M.update(e, allowReread)
  local link = e.link
  e.crsf.update(link, allowReread)

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
  if link.version ~= e.version then
    e.version = link.version
    formatRate(e.rate, f["Packet Rate"], f["RF Band"])
    formatPower(e.power, f["Max Power"], f["Dynamic"])
    formatTlm(e.tlm, f["Telem Ratio"])
  end
end

-- Read everything again (the refresh tap).
function M.refresh(e)
  e.crsf.restart(e.link)
end

return M
