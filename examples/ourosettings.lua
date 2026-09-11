local ouro = require("ouro")

-- One-shot, headless query: ouroctl run examples/ourosettings.lua
local ok, result = pcall(function()
  local runtime = assert(ouro.xdg.runtime_dir, "XDG_RUNTIME_DIR is unset or empty")
  local reply = ouro.mcp.request(
    "unix:" .. runtime .. "/ouro/settings.mcp.sock",
    "resources/read",
    { uri = "ouro://settings/appearance/color_scheme" }
  )
  if reply.error then error(reply.error.message) end
  local selection = ouro.json.decode(reply.result.contents[1].text)
  return selection.exists and selection.value or "default"
end)

if not ok then
  ouro.stderr.write("ourosettings: " .. tostring(result) .. "\n")
  ouro.exit(1)
end
ouro.stdout.write(result .. "\n") -- default, light, or dark
ouro.exit(0)
