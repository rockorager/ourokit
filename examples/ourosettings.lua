local ouro = require("ouro")

-- One-shot, headless query: ouroctl run examples/ourosettings.lua
local ok, result = pcall(function()
  local runtime = assert(ouro.xdg.runtime_dir, "XDG_RUNTIME_DIR is unset or empty")
  local reply = ouro.varlink.call(
    "unix:" .. runtime .. "/ouro/settings.sock",
    "dev.rockorager.ouro.Settings.Get",
    {}
  )
  if reply.error then error(reply.error) end
  return reply.parameters.settings.appearance.color_scheme
end)

if not ok then
  ouro.stderr.write("ourosettings: " .. tostring(result) .. "\n")
  ouro.exit(1)
end
ouro.stdout.write(result .. "\n") -- default, light, or dark
ouro.exit(0)
