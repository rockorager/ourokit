-- Storybook frames for the launcher view. Each story drives a real chart
-- into one state with fake discovery and launching, then renders the same
-- view the app uses: the UI is a function of the snapshot.
--   ouroctl storybook snapshot examples/launcher/stories.lua --output frames
local ouro = require("ouro")
local model = require("model")
local view = require("view")(ouro, model)
local null = ouro.json.null

local function entry(id, name, icon, comment, generic)
  return { id = id .. ".desktop", path = "/usr/share/applications/" .. id .. ".desktop", name = name,
    generic_name = generic or null, comment = comment or null, icon = icon or null, exec = id,
    working_directory = null, keywords = {}, actions = {}, hidden = false, no_display = false,
    terminal = false, dbus_activatable = false, visible = true }
end
local apps = {
  entry("org.gnome.Terminal", "Terminal", "utilities-terminal", "Use the command line", "Terminal emulator"),
  entry("org.gnome.Nautilus", "Files", "system-file-manager", "Access and organize files"),
  entry("firefox", "Firefox", "web-browser", "Browse the World Wide Web", "Web Browser"),
  entry("org.gnome.Calculator", "Calculator", "accessories-calculator", "Perform arithmetic, scientific or financial calculations"),
  entry("org.gnome.Settings", "Settings", "preferences-system", "Utility to configure the desktop"),
  entry("org.gnome.TextEditor", "Text Editor", "accessories-text-editor", "Edit text files"),
  entry("yelp", "Help", "help-browser", "Get help with GNOME"),
  entry("vim", "Vim", nil, "Edit text files"),
}

-- Drive a fresh actor with `steps`; `scan`/`launch` decide how fakes behave.
local function drive(options, steps)
  local charts = require("charts")(ouro, model, {
    scan = function() if options.scan_error then error(options.scan_error, 0) end return apps end,
    launch = function() if options.launch_error then error(options.launch_error, 0) end return true end,
  })
  local clock = ouro.machine.manual_scheduler()
  local launcher = charts.launcher:start { scheduler = clock }
  launcher:send("OPEN")
  if options.scanned ~= false then clock.run_tasks() end
  for _, event in ipairs(steps or {}) do
    if event == "run" then clock.run_tasks() else launcher:send(event) end
  end
  return launcher
end

local function story(id, name, launcher)
  return ouro.story {
    id = "launcher/" .. id, name = name, viewport = { width = 900, height = 600 }, snapshot_scale = 2, padding = 0,
    -- A flat stand-in for the desktop under the translucent layer surface.
    content = function()
      return ouro.box { key = "desktop", width = "fill", height = "fill", background = "#3b4b63",
        ouro.box { key = "surface", width = "fill", height = "fill", background = "#10141c99",
          view.content(launcher) } }
    end,
  }
end

local stories = {
  story("loading", "Scanning (first open)", drive { scanned = false }),
  story("ready", "Ready, second row selected", drive({}, { { type = "MOVE", delta = 1 } })),
  story("filtered", "Filtered by “te”", drive({}, { { type = "QUERY", text = "te" }, { type = "MOVE", delta = 1 } })),
  story("launching", "Launching", drive({}, { { type = "QUERY", text = "fire" }, "ACTIVATE" })),
  story("launch-error", "Launch failed", drive({ launch_error = { name = "NoExec", message = "Vim has no Exec line" } },
    { { type = "QUERY", text = "vim" }, "ACTIVATE", "run" })),
  story("discovery-error", "Discovery failed",
    drive { scan_error = { name = "ApplicationDiscoveryUnavailable", message = "ApplicationDiscoveryUnavailable" } }),
  story("no-match", "No matches", drive({}, { { type = "QUERY", text = "zzz" } })),
}

return ouro.storybook { stories = stories }
