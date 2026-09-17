local ouro, export_native, next_request = ...

-- User callbacks run only in scheduler tasks, never in a socket completion.
return function(bus, definition)
  if type(definition) ~= "table" or type(definition.methods) ~= "table" then
    return nil, { kind = "local", name = "InvalidExport", message = "Expected methods table" }
  end
  if definition.signals ~= nil and type(definition.signals) ~= "table" then
    return nil, { kind = "local", name = "InvalidExport", message = "Expected signals table" }
  end
  local methods = {}
  for name, method in pairs(definition.methods) do
    if type(method) ~= "table" or type(method.handler) ~= "function" then
      return nil, { kind = "local", name = "InvalidMethod", message = "Expected method handler" }
    end
    methods[name] = { input = method.input, output = method.output, handler = method.handler }
  end
  local signals = {}
  for name, signature in pairs(definition.signals or {}) do signals[name] = signature end
  local snapshot = {
    path = definition.path, interface = definition.interface,
    methods = methods, signals = signals,
  }
  return export_native(bus, snapshot, function(stream)
    local lifetime <close> = stream
    while true do
      local message = next_request(stream)
      if not message then return end
      local request = message._request
      message._request = nil
      local spawned = pcall(ouro.spawn, function()
        local guard <close> = request
        if message._decode_error then
          request:error("org.freedesktop.DBus.Error.LimitsExceeded", "Request exceeds Lua decoding limits")
          return
        end
        local ok, result, failure = pcall(methods[message.member].handler, message)
        if not ok then
          request:error("org.freedesktop.DBus.Error.Failed", "Method handler failed")
        elseif result == nil and type(failure) == "table" then
          request:error(failure.name, failure.message)
        else
          request:reply(result)
        end
        -- The guard sends Failed if the result/error was invalid or sending failed.
      end)
      if not spawned then
        local abandoned <close> = request
        request:error("org.freedesktop.DBus.Error.LimitsExceeded", "Cannot start handler")
      end
    end
  end)
end
