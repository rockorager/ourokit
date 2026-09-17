local ouro = require("ouro")

-- Headless notification service example. Replace the stdout write with your UI.
-- Run on a private bus so it does not conflict with your desktop's daemon:
-- dbus-run-session -- zig-out/bin/ouroctl run examples/dbus_notifications.lua
local connection, failure = ouro.dbus.connect("session")
assert(connection, failure and failure.message)
local bus <close> = connection
local interface = "org.freedesktop.Notifications"
local path = "/org/freedesktop/Notifications"
local notifications, next_id = {}, 1

local function close(id, reason)
  notifications[id] = nil
  assert(bus:emit {
    path = path, interface = interface, member = "NotificationClosed",
    signature = "uu", args = {id, reason},
  })
end

local exported, export_error = bus:export {
  path = path,
  interface = interface,
  signals = { NotificationClosed = "uu" },
  methods = {
    GetCapabilities = {
      input = "", output = "as",
      handler = function() return {{"body"}} end,
    },
    GetServerInformation = {
      input = "", output = "ssss",
      handler = function() return {"ourokit example", "ourokit", "0.1", "1.3"} end,
    },
    Notify = {
      input = "susssasa{sv}i", output = "u",
      handler = function(request)
        local app, replaces, icon, summary, body, actions, hints, timeout = table.unpack(request.args)
        if timeout < -1 then
          return nil, {name="org.freedesktop.DBus.Error.InvalidArgs", message="Invalid expiration timeout"}
        end
        local id = replaces
        if id == 0 or not notifications[id] then
          if next_id > 4294967295 then
            return nil, {name="org.freedesktop.DBus.Error.LimitsExceeded", message="Notification IDs exhausted"}
          end
          id, next_id = next_id, next_id + 1
        end
        local notification = {summary=summary, body=body}
        notifications[id] = notification
        local delay = timeout == -1 and 5000 or timeout
        if delay > 0 then
          ouro.spawn(function()
            ouro.sleep(delay)
            -- Replacements invalidate the previous expiration task.
            if notifications[id] == notification then close(id, 1) end
          end)
        end
        ouro.stdout.write(string.format("[%d] %s: %s\n%s\n", id, app, summary, body))
        return {id}
      end,
    },
    CloseNotification = {
      input = "u", output = "",
      handler = function(request)
        local id = request.args[1]
        if not notifications[id] then
          return nil, {name="org.freedesktop.DBus.Error.InvalidArgs", message="Unknown notification"}
        end
        close(id, 3)
        return {}
      end,
    },
  },
}
assert(exported, export_error and export_error.message)
local service <close> = exported
local owned, name_error = bus:own_name(interface)
assert(owned, name_error and name_error.message)
local name <close> = owned
ouro.stdout.write("Notification service ready\n")
while true do ouro.sleep(60000) end
