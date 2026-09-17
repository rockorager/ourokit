local ouro = require('ouro')
local bus = assert(ouro.dbus.connect('session'))
local client = assert(ouro.dbus.connect('session'))
local interface = 'dev.ourokit.Service'
local path = '/test'
local finished, started, canceled_after = {}, false, false
local definition = { path=path, interface=interface, signals={Changed='us'}, methods={
  Echo = {input='su', output='s', handler=function(request)
    local text, delay = table.unpack(request.args)
    assert(request.sender:sub(1,1) == ':' and request.path == path)
    ouro.sleep(delay)
    finished[#finished+1] = text
    return {text .. '!'}
  end},
  Fail = {input='', output='', handler=function() error('private failure') end},
  Reject = {input='', output='', handler=function()
    return nil, {name='dev.ourokit.Rejected', message='not allowed'}
  end},
  Bad = {input='', output='u', handler=function() return {-1} end},
  Empty = {input='', output='', handler=function() return {} end},
  Nested = {input='a{sv}', output='a{sv}', handler=function(r) return r.args end},
  Wait = {input='', output='', handler=function()
    started = true
    ouro.sleep(10000)
    canceled_after = true
    return {}
  end},
}}
local export = assert(bus:export(definition))
-- The declaration is a snapshot, not a mutable dispatch table.
definition.methods.Echo.handler = function() error('mutated') end
local duplicate, dup = bus:export(definition)
assert(duplicate == nil and dup.name == 'AlreadyExported')
local invalid, invalid_error = bus:own_name(interface, 'extra')
assert(invalid == nil and invalid_error.name == 'InvalidArguments')
invalid, invalid_error = bus:emit(17)
assert(invalid == nil and invalid_error.name == 'InvalidSignal')
local name = assert(bus:own_name(interface))
local conflict, conflict_error = client:own_name(interface)
assert(conflict == nil and conflict_error.name == 'NameUnavailable')
local function call(member, signature, args, override)
  return client:call {destination=interface, path=path, interface=override or interface,
    member=member, signature=signature or '', args=args or {}, timeout_ms=2000}
end
local completed = 0
ouro.spawn(function()
  local reply = assert(call('Echo', 'su', {'slow', 40}))
  assert(reply.signature == 's' and reply.args[1] == 'slow!')
  completed = completed + 1
end)
local fast = assert(call('Echo', 'su', {'fast', 0}))
assert(fast.args[1] == 'fast!' and finished[1] == 'fast')
while completed < 1 do ouro.sleep(1) end
assert(finished[2] == 'slow')
for _, case in ipairs({
  {'Fail', '', {}, 'org.freedesktop.DBus.Error.Failed'},
  {'Reject', '', {}, 'dev.ourokit.Rejected'},
  {'Bad', '', {}, 'org.freedesktop.DBus.Error.Failed'},
  {'Missing', '', {}, 'org.freedesktop.DBus.Error.UnknownMethod'},
  {'Echo', 's', {'wrong'}, 'org.freedesktop.DBus.Error.InvalidArgs'},
}) do
  local reply, err = call(case[1], case[2], case[3])
  assert(reply == nil and err.kind == 'remote' and err.name == case[4])
  if case[1] == 'Reject' then assert(err.message == 'not allowed') end
end
assert(assert(call('Empty')).signature == '')
local nested = assert(call('Nested', 'a{sv}', {{{'urgency', ouro.dbus.variant('y', 2)}}}))
assert(nested.args[1][1][1] == 'urgency' and nested.args[1][1][2].value == 2)
local xml = assert(call('Introspect', '', {}, 'org.freedesktop.DBus.Introspectable')).args[1]
assert(xml:find('<interface name="dev.ourokit.Service">', 1, true))
assert(xml:find('<method name="Echo"><arg type="s" direction="in"/><arg type="u" direction="in"/><arg type="s" direction="out"/></method>', 1, true))
assert(xml:find('<signal name="Changed">', 1, true))
local signals = assert(client:subscribe {sender=interface, path=path, interface=interface, member='Changed'})
assert(bus:emit {path=path, interface=interface, member='Changed', signature='us', args={73,'updated'}})
local signal = assert(signals:next())
assert(signal.signature == 'us' and signal.args[1] == 73 and signal.args[2] == 'updated')
local canceled = false
ouro.spawn(function()
  local reply, err = call('Wait')
  assert(reply == nil and err.name == 'org.freedesktop.DBus.Error.Failed')
  canceled = true
end)
while not started do ouro.sleep(1) end
export:close()
while not canceled do ouro.sleep(1) end
assert(not canceled_after)
local missing, err = call('Empty')
assert(missing == nil and err.name == 'org.freedesktop.DBus.Error.UnknownObject')
name:close()
-- A round trip on the owner ensures the queued ReleaseName was processed.
assert(bus:call {destination='org.freedesktop.DBus', path='/org/freedesktop/DBus',
  interface='org.freedesktop.DBus', member='ListNames', signature='', args={}})
local acquired = assert(client:own_name(interface))
acquired:close()
signals:close()
client:close()
bus:close()
service_done = true
