-- Named delays and payload-dependent events in the visualizer, over real
-- records from the interpreter on a manual clock (ouroshell port gap 5).
--   (cd tools/statechart-visualizer && ../../zig-out/bin/ouroctl test delays_test.lua)
local o = require('ouro')
local machine = o.machine
local model = require('model')
local history = require('history')
local view = require('diagram.view')

-- A clock-like chart: a function delay (minute) and a constant named delay
-- (slow), plus an event whose guard reads its payload.
local chart = machine.create {
  id = 'clock', initial = 'reading', context = {second = 18, level = 0},
  events = {READ = {}, SET = {level = 'integer'}, IDLE = {}},
  delays = {minute = function(c) return (60 - c.second) * 1000 end, slow = 2000},
  guards = {
    louder = function(c, e) return e.level > c.level end,
    broken = function(c) return c.missing > 0 end, -- raises without reading the payload
  },
  states = {
    reading = {on = {READ = 'waiting', SET = {guard = 'louder', actions = machine.assign {level = function(_, e) return e.level end}},
      IDLE = {guard = 'broken'}}},
    waiting = {after = {minute = 'reading', slow = 'stale'}, on = {IDLE = 'reading'}},
    stale = {},
  },
}

local function run()
  local clock = machine.manual_scheduler()
  local store = model.new(o.json.null)
  store.actor = nil
  local actor = chart:actor {id = 'clock', scheduler = clock}
  model.ingest(store, {kind = 'actor', action = 'started', actor = 'clock', machine = 'clock', graph = chart:graph(), time_ms = 0})
  actor:observe(function(record) model.ingest(store, record) end)
  actor:start()
  store.actor = actor
  return store, actor, clock
end

local function transition(graph, event)
  for _, t in ipairs(graph.transitions) do if t.event == event then return t end end
end

return {
  ['named delays are labeled by name, with the evaluated ms only while running'] = function()
    local store, actor, clock = run()
    local graph = store.actors.clock.graph
    local minute, slow = transition(graph, 'after.minute.waiting'), transition(graph, 'after.slow.waiting')
    assert(minute.label == 'after minute', 'function delay label: ' .. minute.label)
    assert(slow.label == 'after slow', 'constant named delay label: ' .. slow.label)
    local frames = store.actors.clock.history.frames
    assert(view.after_text_of(minute, frames[#frames], frames[#frames].time) == 'after minute', 'not running: name only')
    clock.advance(100); actor:send('READ')
    local frame = frames[#frames]
    local timer = frame.timers['after.minute.waiting']
    assert(timer and timer.delay == 42000 and timer.name == 'minute', 'running: the evaluated ms from the record')
    assert(history.remaining(timer, frame.time + 1000) == 41000)
    assert(view.after_text_of(minute, frame, frame.time + 1000) == 'after minute · 41.0s')
    assert(view.after_text_of(slow, frame, frame.time + 500) == 'after slow · 1.5s')
    clock.advance(200); actor:send('IDLE') -- from waiting: unguarded
    frame = frames[#frames]
    assert(next(frame.timers) == nil and view.after_text_of(minute, frame, frame.time) == 'after minute', 'stopped: name only')
  end,

  ['payload-dependent events are available with payload, not refused'] = function()
    local store = run()
    local graph = store.actors.clock.graph
    local frames = store.actors.clock.history.frames
    local frame = frames[#frames]
    -- SET's guard reads the payload: the interpreter flags it payload = true.
    assert(view.availability(graph, frame, 'SET') == 'payload', tostring(view.availability(graph, frame, 'SET')))
    assert(view.availability(graph, frame, 'READ') == 'enabled')
    -- IDLE's guard raises without touching the payload: a real error, refused.
    assert(view.availability(graph, frame, 'IDLE') == 'refused', tostring(view.availability(graph, frame, 'IDLE')))
    -- Late attach: the snapshot record's guarded list.
    local _, guarded = store.actor:accepted()
    assert(#guarded == 1 and guarded[1] == 'SET', 'accepted() returns guarded second')
    -- The gap-2 shape: guards entries flagged payload = true, and a guarded list.
    local raw = {kind = 'transition', actor = 'clock', machine = 'clock', time_ms = 1, event = {type = 'READ'},
      states = {'reading'}, guards = {{index = 2, passed = false, payload = true}}, accepted = {'READ'}, guarded = {'SET'}}
    model.ingest(store, raw)
    frame = frames[#frames]
    assert(view.availability(graph, frame, 'SET') == 'payload' and view.availability(graph, frame, 'READ') == 'enabled')
  end,
}
