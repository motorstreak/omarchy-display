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

local function rule_for(desc)
  local s = saved[desc]
  hl.monitor({ output = "desc:" .. desc, mode = s.mode, position = "auto", scale = s.scale, transform = s.transform })
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

local function internal(m)
  return m.name and (m.name:match("^eDP%-") or m.name:match("^LVDS%-") or m.name:match("^DSI%-")) ~= nil
end

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

-- Saves the monitors as they are now.
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
for _, desc in ipairs(order) do rule_for(desc) end

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

hl.on("monitor.layout_changed", record)
hl.on("monitor.added", record)

display_scaling = {
  -- Sets a monitor's scale by connector name, keeping its mode and rotation.
  set = function(name, scale)
    for _, m in ipairs(hl.get_monitors()) do
      if m.name == name and usable(m) then
        if not saved[m.description] then table.insert(order, m.description) end
        saved[m.description] = { mode = mode_of(m), scale = scale, transform = m.transform or 0 }
        rule_for(m.description)
        record()
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
o.bind("SUPER + CTRL + D", "Display", "omarchy-shell shell toggle display")
