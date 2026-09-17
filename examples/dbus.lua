local ouro = require("ouro")

-- One-shot, headless query: ouroctl run examples/dbus.lua
local ok, result = pcall(function()
  local connection, failure = ouro.dbus.connect("session")
  assert(connection, failure and failure.message)
  local bus <close> = connection
  local reply, err = bus:call {
    destination = "org.freedesktop.DBus",
    path = "/org/freedesktop/DBus",
    interface = "org.freedesktop.DBus",
    member = "ListNames",
    signature = "",
    args = {},
  }
  assert(reply, err and err.message)
  table.sort(reply.args[1])
  return table.concat(reply.args[1], "\n")
end)

if not ok then
  ouro.stderr.write("dbus: " .. tostring(result) .. "\n")
  ouro.exit(1)
end
ouro.stdout.write(result .. "\n")
ouro.exit(0)
