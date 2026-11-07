-- Channel helpers: which outputs the sticks drive, and the aux channel list.

local M = {}

-- Physical gimbal axes for each stick mode, in the order left-horizontal,
-- left-vertical, right-vertical, right-horizontal. Values are EdgeTX stick
-- numbers: 0 = rudder, 1 = elevator, 2 = throttle, 3 = aileron
-- (the same table as radio/src/input_mapping.cpp).
local MODE_AXES = {
  { 0, 1, 2, 3 },
  { 0, 2, 1, 3 },
  { 3, 1, 2, 0 },
  { 3, 2, 1, 0 },
}

-- Axis letters as FPV pilots know them, indexed by stick number + 1.
local AXIS_LETTER = { "Y", "P", "T", "R" }

local FIRST_AUX = 4  -- output index of CH5 (0 = CH1); CH1-CH4 are the sticks
local AUX_COUNT = 6  -- CH5 to CH10

-- One stick axis. `value` and `text` cache the last drawn value so the
-- label string is only rebuilt when the value changes.
local function axis(stick)
  return {
    ch = defaultChannel(stick) or stick,  -- output index, from the radio's channel order
    letter = AXIS_LETTER[stick + 1],
    value = nil,
    text = "",
  }
end

-- modeOption 1-4 forces a stick mode; anything else uses the radio's setting.
-- getStickMode() only exists from EdgeTX 2.12, so fall back to mode 2.
function M.stickMap(modeOption)
  local mode = modeOption or 0
  if mode < 1 or mode > 4 then
    mode = (getStickMode and getStickMode()) or 2
  end
  local a = MODE_AXES[mode] or MODE_AXES[2]
  return {
    mode = mode,
    left = { x = axis(a[1]), y = axis(a[2]) },
    right = { x = axis(a[4]), y = axis(a[3]) },
  }
end

function M.auxList()
  local list = {}
  for i = 1, AUX_COUNT do
    local ch = FIRST_AUX + i - 1
    list[i] = { ch = ch, name = "", num = tostring(ch + 1) }  -- num: for the mini bars
  end
  return list
end

-- Names as set on the radio's Outputs page, or "CH5" etc. when blank.
function M.readNames(list)
  for i = 1, #list do
    local item = list[i]
    local out = model.getOutput(item.ch)
    local name = out and out.name
    if not name or name == "" then
      name = "CH" .. (item.ch + 1)
    end
    item.name = name
  end
end

return M
