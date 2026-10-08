-- The overview's alarms, dwell watch and topology over real Notes records:
--   (cd tools/statechart-visualizer && ../../zig-out/bin/ouroctl test overview_test.lua)
local o = require('ouro')
local model = require('model')
local overview = require('overview')
local recording = require('recording')
local notes = require('fixtures.notes_session')

local function load(name, thresholds)
  local store = model.new(o.json.null, thresholds)
  for _, record in ipairs(assert(recording.parse(notes[name], o.json))) do model.ingest(store, record) end
  return store
end

return {
  ['normal operation raises nothing and maps the topology'] = function()
    local store = load('normal')
    assert(#store.alarms == 0, 'no alarms in a normal session')
    assert(table.concat(store.order, ',') == 'notes,notes/document.1,notes/document.2,notes/document.3')
    assert(store.actors['notes/document.2'].parent == 'notes')
    assert(table.concat(store.endpoint_order, ',') == 'quit,choose,write,notify', table.concat(store.endpoint_order, ','))
    assert(store.endpoints.notify.kind == 'task' and store.endpoints.write.kind == 'invoke')
    for _, path in ipairs(store.order) do assert(overview.severity(store, path, {}) == nil) end
    -- Three completed writes of document.1 give it a stuck limit.
    local entry = store.actors['notes/document.1']
    assert(#entry.dwells['open.io.saving.writing'] == 2, #entry.dwells['open.io.saving.writing'])
    assert(overview.limit(store, entry, 'open.io.saving.writing') == nil, 'two samples are not enough')
    assert(overview.limit(store, entry, 'open.io.idle') == nil, 'idle states are not watched')
  end,

  ['a failed write is a high alarm on its unit until acknowledged'] = function()
    local store = load('error')
    assert(#store.alarms == 1, #store.alarms)
    local a = store.alarms[1]
    assert(a.actor == 'notes/document.2' and a.severity == 'high' and a.kind == 'invoke' and a.src == 'write', a.message)
    assert(a.message:find('ENOSPC', 1, true) and a.step == #store.actors[a.actor].history.frames)
    assert(overview.severity(store, 'notes/document.2', {}) == 'high')
    assert(overview.severity(store, 'notes/document.2', {[tostring(a.id)] = true}) == nil)
    assert(overview.severity(store, 'notes/document.1', {}) == nil, 'other units stay grey')
  end,

  ['a write that outlasts its usual dwell turns amber at the deadline'] = function()
    local store = load('stuck')
    local entry = store.actors['notes/document.1']
    local limit, usual = overview.limit(store, entry, 'open.io.saving.writing')
    assert(usual == 40 and limit == 1000, 'max(min_ms, 10 x median): ' .. tostring(limit))
    assert(#store.alarms == 0 and store.deadline == store.now + 1000, 'one timer for the earliest deadline')
    assert(model.check(store, store.now + 999) == store.deadline and #store.alarms == 0)
    assert(model.check(store, store.now + 2) == nil, 'no further deadline')
    local a = store.alarms[1]
    assert(a and a.kind == 'stuck' and a.severity == 'medium' and a.state == 'open.io.saving.writing', a and a.message)
    model.check(store, store.now + 5000)
    assert(#store.alarms == 1, 'one alarm per dwell')
    -- A fixed per-chart limit needs no samples.
    local fixed = load('stuck', {default = {factor = 10, min_ms = 1000, samples = 3},
      charts = {document = {states = {['open.io.saving.writing'] = {max_ms = 300}, ['open.io.idle'] = false}}}})
    assert(overview.limit(fixed, fixed.actors['notes/document.3'], 'open.io.saving.writing') == 300)
  end,

  ['sends and children reporting back become traffic'] = function()
    local store = model.new(o.json.null)
    local graph = {format = 'ouro.machine.graph', version = 1, id = 'p', root = '', events = {},
      states = {{id = '', type = 'compound', children = {'a'}, initial = 'a'}, {id = 'a', parent = '', type = 'atomic'}},
      transitions = {}}
    model.ingest(store, {kind = 'actor', action = 'started', actor = 'p', machine = 'p', graph = graph, time_ms = 0})
    model.ingest(store, {kind = 'actor', action = 'started', actor = 'p/c', machine = 'p', parent = 'p', graph = graph, time_ms = 0})
    model.ingest(store, {kind = 'transition', actor = 'p', machine = 'p', time_ms = 5, event = {type = 'GO'}, states = {'a'},
      sent = {{kind = 'send_to', to = 'p/c', event = 'PING', accepted = true}}})
    model.ingest(store, {kind = 'transition', actor = 'p', machine = 'p', time_ms = 6, origin = 'child',
      event = {type = 'error.actor.c', error = {message = 'boom'}}, states = {'a'}})
    model.ingest(store, {kind = 'transition', actor = 'p/c', machine = 'p', time_ms = 7, rejected = true, reason = 'error',
      event = {type = 'PING'}, states = {'a'}, error = {code = 'YieldInAction', message = 'YieldInAction: sleep in an action'}})
    assert(store.traffic['p>p/c'].count == 1 and store.traffic['p>p/c'].events.PING)
    assert(store.traffic['p/c>p'].count == 1)
    assert(#store.alarms == 2 and store.alarms[1].kind == 'error' and store.alarms[2].kind == 'action', #store.alarms)
    assert(store.alarms[2].message:find('^YieldInAction'), store.alarms[2].message)
    assert(store.actors['p/c'].rejected == 1 and store.actors['p/c'].last_rejected.event == 'PING')
  end,
}
