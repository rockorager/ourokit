local ouro = require("ouro")

-- Headless subscription: ouroctl run examples/ourosettings-watch.lua
-- Writes the initial color scheme and each change; Ctrl+C stops the process.
local ok, err = pcall(function()
  local runtime = assert(ouro.xdg.runtime_dir, "XDG_RUNTIME_DIR is unset or empty")
  local address = "unix:" .. runtime .. "/ouro/settings.mcp.sock"
  local uri = "ouro://settings/appearance/color_scheme"
  ouro.mcp.subscribe(address, uri, function(notification)
      if notification.error then error(notification.error.message) end
      if not notification.method then error("subscription ended") end
      -- The acknowledgment establishes the subscription before the first read.
      -- Updates invalidate this URI; they do not contain the settings value.
      local reply = ouro.mcp.request(address, "resources/read", { uri = uri })
      if reply.error then error(reply.error.message) end
      local selection = ouro.json.decode(reply.result.contents[1].text)
      ouro.stdout.write((selection.exists and selection.value or "default") .. "\n")
    end
  )
end)

if not ok then
  ouro.stderr.write("ourosettings: " .. tostring(err) .. "\n")
  ouro.exit(1)
end
ouro.exit(0)
