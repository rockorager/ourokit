-- contract.lua over the statechart-gaps shapes: named and function delays
-- (timers keyed by event, durations from ms), opaque handles in context,
-- and sent entries to invokes and by system id.
--   (cd tools/statechart-visualizer && ../../zig-out/bin/ouroctl test contract_test.lua)
local o = require('ouro')
local model = require('model')
local view = require('diagram.view')

local null = o.json.null
local graph = {format = 'ouro.machine.graph', version = 1, id = 'net', root = '', events = {{type = 'GO', fields = {}}},
  states = {
    {id = '', type = 'compound', children = {'idle', 'waiting', 'polling'}, initial = 'idle', after = {}, invoke = {}},
    {id = 'idle', parent = '', type = 'atomic', after = {}, invoke = {}},
    {id = 'waiting', parent = '', type = 'atomic', invoke = {},
      after = {{delay = 'slow', event = 'after.slow.waiting', ms = 2000}, {delay = 'jitter', event = 'after.jitter.waiting', ms = null}}},
    {id = 'polling', parent = '', type = 'atomic', after = {{delay = 250, event = 'after.250.polling'}},
      invoke = {{id = 'conn', src = 'socket'}}},
  },
  transitions = {
    {index = 1, source = 'idle', event = 'GO', kind = 'event', targets = {'waiting'}},
    {index = 2, source = 'waiting', event = 'after.slow.waiting', kind = 'after', targets = {'polling'}},
    {index = 3, source = 'waiting', event = 'after.jitter.waiting', kind = 'after', targets = {'idle'}},
    {index = 4, source = 'polling', event = 'after.250.polling', kind = 'after', targets = {'idle'}},
  }}

local function store()
  local s = model.new(null)
  model.ingest(s, {kind = 'actor', action = 'started', actor = 'net', machine = 'net', graph = graph, time_ms = 0})
  model.ingest(s, {kind = 'actor', action = 'started', actor = 'peer', machine = 'net', graph = graph, time_ms = 0})
  return s
end

return {
  ['named and function delays: labels, durations from ms, timers keyed by event'] = function()
    local s = store()
    local g = s.actors.net.graph
    local slow, jitter, fixed = g.transition_by_id[2], g.transition_by_id[3], g.transition_by_id[4]
    assert(slow.label == 'after slow' and slow.after == 2000 and slow.after_event == 'after.slow.waiting', slow.label)
    assert(jitter.label == 'after jitter' and jitter.after == nil, 'a function delay has no static duration')
    assert(fixed.label == 'after 250ms' and fixed.after == 250)
    model.ingest(s, {kind = 'transition', actor = 'net', machine = 'net', time_ms = 10, event = {type = 'GO'},
      states = {'waiting'}, entered = {'waiting'}, exited = {'idle'},
      timers = {{action = 'started', state = 'waiting', delay = 'slow', ms = 2000, event = 'after.slow.waiting', token = 3, time_ms = 10},
        {action = 'started', state = 'waiting', delay = 'jitter', ms = 730, event = 'after.jitter.waiting', token = 3, time_ms = 10}}})
    local frame = s.actors.net.history.frames[1]
    local a, b = frame.timers['after.slow.waiting'], frame.timers['after.jitter.waiting']
    assert(a and a.delay == 2000 and a.name == 'slow' and b and b.delay == 730 and b.name == 'jitter')
    -- A fired entry has no delay for a named delay; the event still finds it.
    model.ingest(s, {kind = 'transition', actor = 'net', machine = 'net', time_ms = 740, origin = 'timer',
      event = {type = 'after.jitter.waiting', state = 'waiting', token = 3}, states = {'idle'}, entered = {'idle'}, exited = {'waiting'},
      timers = {{action = 'fired', state = 'waiting', event = 'after.jitter.waiting', token = 3},
        {action = 'cancelled', state = 'waiting', delay = 'slow', event = 'after.slow.waiting', token = 3}}})
    frame = s.actors.net.history.frames[2]
    assert(next(frame.timers) == nil and frame.fired and frame.fired['after.jitter.waiting'], 'fired and cancelled timers leave')
    assert(s.actors.net.dwells.waiting[1] == 730)
  end,

  ['opaque handles render as their type'] = function()
    assert(view.value_text({['$h'] = 'socket'}, null) == '‹socket›')
    assert(view.value_text({['$h'] = 'userdata'}, null) == '‹userdata›')
    assert(view.value_text({port = 8080}, null) == '{"port":8080}', 'ordinary tables stay JSON')
  end,

  ['sends to invokes and by system id'] = function()
    local s = store()
    model.ingest(s, {kind = 'transition', actor = 'net', machine = 'net', time_ms = 5, event = {type = 'GO'}, states = {'polling'},
      sent = {{kind = 'send_to', invoke = true, to = 'net/conn', event = 'PING', accepted = true},
        {kind = 'send_to', system = 'peer', to = 'peer', event = 'HELLO', accepted = true},
        {kind = 'send_to', system = 'later', to = 'later', event = 'HELLO', accepted = false, reason = 'not_started'}}})
    assert(s.endpoints.socket.received == 1, 'an invoke mailbox send counts at its endpoint')
    assert(s.traffic['net>peer'] and s.traffic['net>peer'].count == 1, 'a system-id send links the actors')
    assert(s.traffic['net>net/conn'] == nil and s.traffic['net>later'] == nil, 'no links to non-actors')
  end,
}
