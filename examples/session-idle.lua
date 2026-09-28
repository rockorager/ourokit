-- Harmless observer: no screen locking, power changes or suspend requests.
-- Run with: ouroctl run examples/session-idle.lua
local ouro = require("ouro")

return ouro.app {
  id = "dev.ourokit.session-idle",
  run = function()
    local status = ouro.signal("Waiting for five seconds of inactivity")
    ouro.spawn(function()
      local idle <close> = ouro.session.idle(5000)
      while true do
        local event = idle:next()
        if event == "idled" then
          status:set("Idle — shell policy could act here")
        elseif event == "resumed" then
          status:set("Input resumed")
        else
          status:set("Idle notifications unavailable or closed: " .. event)
          return
        end
      end
    end)
    return { windows = {
      ouro.window {
        id = "observer", title = "Native idle observer", width = 480, height = 120,
        content = function()
          return ouro.text { key = "status", text = status() }
        end,
      },
    } }
  end,
}
