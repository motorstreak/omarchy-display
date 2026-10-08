-- Display plugin: remembers each monitor's scale.
--
-- Loaded from the end of ~/.config/hypr/monitors.lua (the plugin adds the
-- line), so the saved rules come after Omarchy's catch-all rule and win over
-- it. Omarchy's toggles (laptop display off, mirroring) load later still, so
-- they keep winning over these.
--
-- Monitors are matched by description (make, model, serial), so a scale
-- follows the monitor to another port or dock. Every scale change is saved,
-- whatever made it: this panel, Omarchy's Super+/ keys, or hyprctl.

local state_dir = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/omarchy-display"
local state_file = state_dir .. "/monitors"

-- description -> { mode, scale, transform }, kept in file order.
local saved, order = {}, {}

local function read_state()
  local f = io.open(state_file)
  if not f then return end
  for line in f:lines() do
    local desc, mode, scale, transform = line:match("^(.-)\t(.-)\t(.-)\t(.-)$")
    if desc and desc ~= "" and tonumber(scale) then
      if not saved[desc] then table.insert(order, desc) end
      saved[desc] = { mode = mode, scale = tonumber(scale), transform = tonumber(transform) or 0 }
    end
  end
  f:close()
end

local function serialize()
  local lines = {}
  for _, desc in ipairs(order) do
    local s = saved[desc]
    table.insert(lines, string.format("%s\t%s\t%.7g\t%d", desc, s.mode, s.scale, s.transform))
  end
  return table.concat(lines, "\n") .. "\n"
end

local function write_state()
  local content = serialize()
  local f = io.open(state_file)
  local current = f and f:read("a")
  if f then f:close() end
  if current == content then return end
  os.execute("mkdir -p '" .. state_dir .. "'")
  f = io.open(state_file, "w")
  if not f then return end
  f:write(content)
  f:close()
end

local function mode_of(m)
  return string.format("%dx%d@%.2f", m.width, m.height, m.refresh_rate)
end

-- Arrangement: each monitor's side of the anchor (the laptop panel when it's
-- on, otherwise the first monitor without a side): "left", "right", "above" or
-- "below", or an exact place dragged in the panel, "@dx,dy" (its top left
-- corner from the anchor's, in layout pixels), by description, in
-- ~/.local/state/omarchy-display/arrangement.
-- None means right, after any others. Positions are worked out from the saved
-- sizes and scales: left/right line up the bottoms (a laptop sits lower than a
-- monitor beside it), above/below the centres; then shifted so the layout
-- starts at 0,0.
local arrangement_file = state_dir .. "/arrangement"
local sides = {}

local function read_arrangement()
  local f = io.open(arrangement_file)
  if not f then return end
  for line in f:lines() do
    local desc, side = line:match("^(.-)\t(%a+)$")
    if desc and desc ~= "" and (side == "left" or side == "right" or side == "above" or side == "below") then
      sides[desc] = side
    else
      local d, dx, dy = line:match("^(.-)\t@(%-?%d+),(%-?%d+)$")
      if d and d ~= "" then sides[d] = { tonumber(dx), tonumber(dy) } end
    end
  end
  f:close()
end

local function write_arrangement()
  local lines = {}
  for desc, side in pairs(sides) do
    if type(side) == "table" then
      table.insert(lines, string.format("%s\t@%d,%d", desc, side[1], side[2]))
    else
      table.insert(lines, desc .. "\t" .. side)
    end
  end
  table.sort(lines)
  os.execute("mkdir -p '" .. state_dir .. "'")
  local f = io.open(arrangement_file, "w")
  if not f then return end
  f:write(table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
  f:close()
end

local function internal(m)
  return m.name and (m.name:match("^eDP%-") or m.name:match("^LVDS%-") or m.name:match("^DSI%-")) ~= nil
end

-- A monitor's size in layout pixels at its saved mode, scale and rotation.
local function logical(desc)
  local s = saved[desc]
  local w, h = s.mode:match("^(%d+)x(%d+)")
  w, h = tonumber(w), tonumber(h)
  if not w or not h or not s.scale or s.scale <= 0 then return nil end
  w, h = w / s.scale, h / s.scale
  if (s.transform or 0) % 2 == 1 then w, h = h, w end
  return w, h
end

-- Positions ("XxY") for the monitors on now, by description.
local function layout()
  local on = {}
  for _, m in ipairs(hl.get_monitors()) do
    if m.description and saved[m.description] and not m.disabled and not m.mirror_of
        and (m.width or 0) > 0 and (m.height or 0) > 0 and logical(m.description) then
      table.insert(on, m)
    end
  end
  -- A lone monitor is fine wherever it is: left alone (moving the laptop panel
  -- just as another monitor is unplugged reconfigures it mid-hotplug).
  if #on < 2 then return {} end
  table.sort(on, function(a, b) return a.name < b.name end)
  local anchor = nil
  for _, m in ipairs(on) do if internal(m) then anchor = m end end
  if not anchor then
    for _, m in ipairs(on) do if not sides[m.description] then anchor = anchor or m end end
  end
  anchor = anchor or on[1]

  local aw, ah = logical(anchor.description)
  local pos = { [anchor.description] = { 0, 0 } }
  local left, right, top, bottom = 0, aw, 0, ah
  -- Dragged places first; sides then go beyond everything placed.
  for _, m in ipairs(on) do
    local side = sides[m.description]
    if m ~= anchor and type(side) == "table" then
      local w, h = logical(m.description)
      pos[m.description] = { side[1], side[2] }
      left, right = math.min(left, side[1]), math.max(right, side[1] + w)
      top, bottom = math.min(top, side[2]), math.max(bottom, side[2] + h)
    end
  end
  for _, m in ipairs(on) do
    if m ~= anchor and type(sides[m.description]) ~= "table" then
      local w, h = logical(m.description)
      local side = sides[m.description] or "right"
      if side == "left" then
        pos[m.description] = { left - w, ah - h }
        left = left - w
      elseif side == "above" then
        pos[m.description] = { (aw - w) / 2, top - h }
        top = top - h
      elseif side == "below" then
        pos[m.description] = { (aw - w) / 2, bottom }
        bottom = bottom + h
      else
        pos[m.description] = { right, ah - h }
        right = right + w
      end
    end
  end
  local minx, miny = 0, 0
  for _, p in pairs(pos) do
    minx = math.min(minx, p[1])
    miny = math.min(miny, p[2])
  end
  local result = {}
  for desc, p in pairs(pos) do
    result[desc] = string.format("%dx%d", math.floor(p[1] - minx + 0.5), math.floor(p[2] - miny + 0.5))
  end
  return result
end

local function rule_for(desc, position)
  local s = saved[desc]
  hl.monitor({ output = "desc:" .. desc, mode = s.mode, position = position or "auto", scale = s.scale,
    transform = s.transform })
end

-- Puts the monitors on now where the arrangement says, those not there yet.
-- Something else moving them back (Omarchy's lid script places the laptop
-- panel "auto") is corrected, but only a few times in a row, in case Hyprland
-- won't take a position.
local corrections, last_correction = 0, 0
local function apply_layout()
  local positions = layout()
  local changed = false
  for _, m in ipairs(hl.get_monitors()) do
    local p = positions[m.description or ""]
    if p and p ~= string.format("%dx%d", m.x or 0, m.y or 0) then
      rule_for(m.description, p)
      changed = true
    end
  end
  return changed
end

-- `wait` ms: 2 s after monitors come and go (they blink off and on as the lid
-- closes or the system wakes; let Hyprland finish), less for a scale change.
local function apply_layout_soon(wait)
  hl.timer(function()
    local now = os.time()
    if now - last_correction > 5 then corrections = 0 end
    if corrections >= 3 then return end
    if apply_layout() then
      corrections = corrections + 1
      last_correction = now
    end
  end, { timeout = wait or 2000, type = "oneshot" })
end

local function usable(m)
  return m.description and m.description ~= "" and not m.disabled and not m.mirror_of
    and (m.width or 0) > 0 and (m.height or 0) > 0
end

-- Omarchy's lid script (omarchy-hyprland-monitor-clamshell) turns the laptop
-- panel back on at the scale in monitors.lua's `omarchy_monitor_scale`, and
-- corrects the panel to it whenever they differ, so a scale picked here was
-- lost on opening the lid. So the laptop panel's scale is kept there too, the
-- way Omarchy's own scale keys do it (GDK_SCALE: the nearest whole number).
local monitors_lua = os.getenv("HOME") .. "/.config/hypr/monitors.lua"

local function keep_omarchy_scale(scale)
  local f = io.open(monitors_lua)
  if not f then return end
  -- (A newline in front, so the first line can match too.)
  local content = "\n" .. f:read("a")
  f:close()
  local value = string.format("%.7g", scale)
  local updated, n = content:gsub("\nlocal omarchy_monitor_scale = [^\n]*", "\nlocal omarchy_monitor_scale = " .. value, 1)
  if n == 0 then return end
  updated = updated:gsub("\nlocal omarchy_gdk_scale = [^\n]*",
    "\nlocal omarchy_gdk_scale = " .. string.format("%d", math.floor(scale + 0.5)), 1)
  if updated == content then return end
  f = io.open(monitors_lua, "w")
  if not f then return end
  f:write(updated:sub(2))
  f:close()
end

-- Saves the monitors as they are now (sizes; positions follow the arrangement).
local function record()
  for _, m in ipairs(hl.get_monitors()) do
    if usable(m) then
      if not saved[m.description] then table.insert(order, m.description) end
      saved[m.description] = { mode = mode_of(m), scale = m.scale, transform = m.transform or 0 }
      if internal(m) then keep_omarchy_scale(m.scale) end
    end
  end
  write_state()
end

read_state()
read_arrangement()
do
  local positions = layout()
  for _, desc in ipairs(order) do rule_for(desc, positions[desc]) end
end

-- Monitors seen for the first time keep the scale they have now.
local seeded = false
for _, m in ipairs(hl.get_monitors()) do
  if usable(m) and not saved[m.description] then
    table.insert(order, m.description)
    saved[m.description] = { mode = mode_of(m), scale = m.scale, transform = m.transform or 0 }
    rule_for(m.description)
    seeded = true
  end
end
if seeded then write_state() end

hl.on("monitor.layout_changed", function() record(); apply_layout_soon(2000) end)
hl.on("monitor.added", function() record(); apply_layout_soon(2000) end)
hl.on("monitor.removed", function() apply_layout_soon(2000) end)

display_scaling = {
  -- Sets a monitor's mode (by connector name), e.g. "3840x2160@59.94": the
  -- refresh rate; its scale, rotation and place stay.
  set_mode = function(name, mode)
    if type(mode) ~= "string" or not mode:match("^%d+x%d+@[%d.]+$") then return end
    for _, m in ipairs(hl.get_monitors()) do
      if m.name == name and usable(m) then
        if not saved[m.description] then table.insert(order, m.description) end
        saved[m.description] = { mode = mode, scale = m.scale, transform = m.transform or 0 }
        -- Saved as asked (record() would read the monitor before the mode applies).
        write_state()
        rule_for(m.description, layout()[m.description])
        return
      end
    end
  end,
  -- Puts a monitor (by connector name) on a side of the anchor: "left",
  -- "right", "above", "below", or "auto" (right, after the others).
  -- Exact places dragged in the panel: { { name, dx, dy }, ... }, each from the
  -- anchor's top left corner in layout pixels.
  place = function(list)
    for _, item in ipairs(list or {}) do
      for _, m in ipairs(hl.get_monitors()) do
        if m.name == item[1] and m.description and m.description ~= ""
            and tonumber(item[2]) and tonumber(item[3]) then
          sides[m.description] = { math.floor(item[2] + 0.5), math.floor(item[3] + 0.5) }
        end
      end
    end
    write_arrangement()
    corrections = 0
    apply_layout()
  end,

  arrange = function(name, side)
    for _, m in ipairs(hl.get_monitors()) do
      if m.name == name and m.description and m.description ~= "" then
        sides[m.description] = (side == "left" or side == "right" or side == "above" or side == "below") and side or nil
        write_arrangement()
        corrections = 0
        apply_layout()
        return
      end
    end
  end,
  -- Sets a monitor's scale by connector name, keeping its mode and rotation.
  set = function(name, scale)
    for _, m in ipairs(hl.get_monitors()) do
      if m.name == name and usable(m) then
        if not saved[m.description] then table.insert(order, m.description) end
        saved[m.description] = { mode = mode_of(m), scale = scale, transform = m.transform or 0 }
        rule_for(m.description, layout()[m.description])
        record()
        -- A new size moves the monitors around it.
        apply_layout_soon(200)
        return
      end
    end
  end,
}

-- Text rendering (bin/display-text): darken glyph stems the way macOS does,
-- for every app started from here on, at the strength the panel last set.
local properties = io.open(state_dir .. "/freetype-properties")
if properties then
  local value = properties:read("l")
  properties:close()
  if value and value ~= "" then hl.env("FREETYPE_PROPERTIES", value) end
end

-- Super+Ctrl+D opens this panel instead of Omarchy's Display panel.
hl.unbind("SUPER + CTRL + D")
o.bind("SUPER + CTRL + D", "Display", "omarchy-shell shell toggle io.github.motorstreak.display")
