-- A layer-shell application launcher written as a statechart.
--   ouroctl run examples/launcher/ouro.json        first launch opens it
--   ouroctl activate dev.ourokit.launcher          bind to a key; toggles
-- charts.lua holds the behavior, view.lua the UI, model.lua search.
local ouro = require("ouro")
local model = require("model")

-- Start a prepared command as a transient systemd user service, the way
-- desktop shells do. Lua has no process spawning; `prepare_launch` only
-- builds argv. `env` resolves a bare command on the user manager's PATH.
local function escape(id)
  return (id:gsub("%.desktop$", ""):gsub("[^%w_.:]", function(ch) return string.format("\\x%02x", ch:byte()) end))
end

local function start_unit(entry, launch)
  local variant = ouro.dbus.variant
  local argv = { "env", "--" }
  for _, arg in ipairs(launch.argv) do argv[#argv + 1] = arg end
  local properties = {
    { "Description", variant("s", model.text(entry.name) or entry.id) },
    { "ExecStart", variant("a(sasb)", { { "/usr/bin/env", argv, false } }) },
    { "Type", variant("s", "exec") },
    { "CollectMode", variant("s", "inactive-or-failed") },
  }
  if model.text(launch.cwd) then properties[#properties + 1] = { "WorkingDirectory", variant("s", launch.cwd) } end
  local connection, failure = ouro.dbus.connect("session")
  if not connection then error(failure, 0) end
  local bus <close> = connection
  -- Bus unique names are never reused while the bus lives, and the sandbox
  -- has no math.random.
  local name = string.format("app-ourokit-%s-%s.service", escape(entry.id), bus:unique_name():gsub("%W", ""))
  local reply, err = bus:call {
    destination = "org.freedesktop.systemd1", path = "/org/freedesktop/systemd1",
    interface = "org.freedesktop.systemd1.Manager", member = "StartTransientUnit",
    signature = "ssa(sv)a(sa(sv))", args = { name, "fail", properties, {} }, timeout_ms = 5000,
  }
  if not reply then error(err, 0) end
  return true
end

local charts = require("charts")(ouro, model, {
  scan = function() return ouro.xdg.applications.list() end,
  launch = function(entry)
    local options = entry.terminal and { terminal_argv = { "xdg-terminal-exec" } } or nil
    return start_unit(entry, ouro.xdg.applications.prepare_launch(entry, options))
  end,
})

local view = require("view")(ouro, model, charts.results)

-- Created at load, started by `run`. Activation is delivered before `run` on
-- the first launch; until the actor has started those events are dropped,
-- and `run` opens.
local launcher = charts.launcher:actor()
local function send(type)
  if launcher:started() then launcher:send(type) end
end

local function state(snapshot)
  return { open = ouro.machine.matches(snapshot, "open"), error = snapshot.context.error }
end
local output_schema = {
  type = "object", additionalProperties = false, required = { "open" },
  properties = { open = { type = "boolean" }, error = { type = "string" } },
}
local function action(event, description)
  return { event = event, description = description, output = state, output_schema = output_schema }
end
local mcp = ouro.machine.actions(launcher, {
  Toggle = action("TOGGLE", "Show the launcher if hidden, hide it if open."),
  Open = action("OPEN", "Show the launcher."),
  Close = action("CLOSE", "Hide the launcher."),
  State = { description = "Whether the launcher is open, and the last error.", output = state, output_schema = output_schema },
}, {
  before = function(actor)
    if not actor:started() then return ouro.action_error("NotRunning", {}) end
  end,
})

local actions = { toggle = "TOGGLE", open = "OPEN", close = "CLOSE" }

return ouro.app {
  id = "dev.ourokit.launcher", single_instance = true,
  -- Bind a key in the compositor to `ouroctl activate dev.ourokit.launcher`
  -- (or the same `ouroctl run`, which forwards to the running instance).
  activate = function() send("TOGGLE") end,
  activate_action = function(name)
    if not actions[name] then
      return nil, { name = "org.freedesktop.DBus.Error.NotSupported", message = "unknown action " .. tostring(name) }
    end
    send(actions[name])
  end,
  actions = mcp,
  run = function()
    launcher:start()
    launcher:send("OPEN")
    return { windows = view.windows(launcher) }
  end,
}
