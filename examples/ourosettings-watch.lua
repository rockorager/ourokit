local ouro = require("ouro")

-- Headless subscription: ouroctl run examples/ourosettings-watch.lua
-- Writes the initial color scheme and each change; Ctrl+C stops the process.
local ok, err = pcall(function()
  local runtime = assert(ouro.xdg.runtime_dir, "XDG_RUNTIME_DIR is unset or empty")
  ouro.varlink.subscribe(
    "unix:" .. runtime .. "/ouro/settings.sock",
    "dev.rockorager.ouro.Settings.WatchPath",
    { path = "/appearance/color_scheme" },
    function(reply)
      if reply.error then error(reply.error) end
      local selection = reply.parameters
      if selection.exists then
        ouro.stdout.write(ouro.json.decode(selection.value_json) .. "\n")
      end
    end
  )
end)

if not ok then
  ouro.stderr.write("ourosettings: " .. tostring(err) .. "\n")
  ouro.exit(1)
end
ouro.exit(0)
