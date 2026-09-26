-- org.freedesktop.Application (Desktop Entry Specification, section 8).
-- This task and all handlers use the normal scoped D-Bus adapter. It has no MCP
-- dependency, and development instances never acquire or call a public name.
local ouro, declaration, state, options = ...
local interface = 'org.freedesktop.Application'
local path = '/' .. declaration.id:gsub('%.', '/'):gsub('-', '_')
local function platform_data(entries)
  local result = {}
  for _, entry in ipairs(entries) do
    local key, variant = entry[1], entry[2]
    if key == 'activation-token' or key == 'desktop-startup-id' then
      if variant.signature ~= 's' then
        return nil, {name='org.freedesktop.DBus.Error.InvalidArgs', message='Expected string platform data'}
      end
      result[key] = variant.value
    else
      result[key] = variant
    end
  end
  return result
end
local function deliver(member, args)
  local data, failure = platform_data(args[#args])
  if not data then return nil, failure end
  local hook
  if member == 'Activate' then hook = declaration.activate
  elseif member == 'Open' then hook = declaration.open
  else hook = declaration.activate_action end
  if not hook and member ~= 'Activate' then
    return nil, {name='org.freedesktop.DBus.Error.NotSupported', message='Application does not handle this operation'}
  end
  if hook then
    local result, err
    if member == 'Activate' then result, err = hook(data)
    elseif member == 'Open' then result, err = hook(args[1], data)
    else result, err = hook(args[1], args[2], data) end
    if err then return nil, err end
  end
  state.requested = true
  state.token = data['activation-token']
  return {}
end
local data = {}
if options.token then data[#data+1] = {'activation-token', ouro.dbus.variant('s', options.token)} end
if options.startup_id then data[#data+1] = {'desktop-startup-id', ouro.dbus.variant('s', options.startup_id)} end
local member, signature, args = 'Activate', 'a{sv}', {data}
if options.dbus_activated and (options.development or not declaration.single_instance) then
  error('DBus activation requires single_instance outside development')
end
if options.action then
  member, signature, args = 'ActivateAction', 'sava{sv}', {options.action, {}, data}
elseif #options.uris > 0 then
  member, signature, args = 'Open', 'asa{sv}', {options.uris, data}
end
if options.client or (declaration.single_instance and not options.development) then
  local bus, failure = ouro.dbus.connect('session')
  if not bus then error(failure.name) end
  state.bus = bus
  if not options.client then
    state.export = assert(bus:export {path=path, interface=interface, methods={
      Activate={input='a{sv}', output='', handler=function(r) return deliver('Activate', r.args) end},
      Open={input='asa{sv}', output='', handler=function(r) return deliver('Open', r.args) end},
      ActivateAction={input='sava{sv}', output='', handler=function(r) return deliver('ActivateAction', r.args) end},
    }})
    state.name, failure = bus:own_name(declaration.id)
    if not state.name and failure.name ~= 'NameUnavailable' then error(failure.name) end
  end
  if not state.name then
    if state.export then state.export:close(); state.export = nil end
    local reply, err = bus:call {destination=declaration.id, path=path, interface=interface,
      member=member, signature=signature, args=args, timeout_ms=5000}
    if not reply then error(err.name .. ': ' .. err.message) end
    state.forwarded = true
    bus:close()
    return true
  end
end
if not options.dbus_activated then
  local result, failure = deliver(member, args)
  if not result then error(failure.name .. ': ' .. failure.message) end
end
return true
