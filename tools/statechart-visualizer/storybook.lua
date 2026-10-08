-- Headless frames of the statechart inspector over real inspection records:
-- fixture charts on machine.manual_scheduler(), a recorded stopwatch session
-- (ouroctl replay --records) and the visualizer's own chart.
--   zig-out/bin/ouroctl storybook snapshot tools/statechart-visualizer/storybook.lua --output out
-- Each story renders view.Screen over an unstarted visualizer actor restored
-- from a snapshot, so selection, cursor and editor are chart state as in the
-- app; pulses are pinned because snapshots cannot advance animations.
local o = require('ouro')
local machine = o.machine
local model = require('model')
local charts = require('charts')
local view = require('diagram.view')
local scenario = require('scenario')
local recording = require('recording')

local W, H = 1600, 1000

local stub = {}
for _, name in ipairs({'observe', 'follow', 'poll', 'load', 'inject', 'watch'}) do stub[name] = function() end end

-- One store per source, filled during catalog evaluation (actors write
-- signals, which story builds may not).
local function fixture_store(name)
  local store = model.new(o.json.null)
  local run = scenario.run(require('fixtures.' .. name))
  for _, record in ipairs(run.lifecycle) do if record.action == 'started' then model.ingest(store, record) end end
  for _, record in ipairs(run.records) do model.ingest(store, record) end
  return store
end

local stores = {document = fixture_store('document'), connection = fixture_store('connection')}

-- The real Notes charts (examples/documents): three notes, then a failed
-- write, or a write that never finishes (checked 2.5 s later).
local notes = require('fixtures.notes_session')
for _, name in ipairs({'normal', 'error', 'stuck'}) do
  local store = model.new(o.json.null)
  for _, record in ipairs(assert(recording.parse(notes[name], o.json))) do model.ingest(store, record) end
  stores['notes_' .. name] = store
end
model.check(stores.notes_stuck, stores.notes_stuck.now + 2500)

stores.stopwatch = model.new(o.json.null)
for _, record in ipairs(assert(recording.parse(require('fixtures.stopwatch_recording'), o.json))) do
  model.ingest(stores.stopwatch, record)
end

-- The visualizer inspecting itself: its own chart driven through a session
-- on the manual scheduler, recorded like any other actor.
stores.self = model.new(o.json.null)
do
  local clock = machine.manual_scheduler()
  local services = {}
  for k, v in pairs(stub) do services[k] = v end
  services.follow = function(_, send) send({type = 'ATTACHED'}) end
  services.inject = function(input) return input.event.type .. ' accepted → clock, clock.running' end
  local viz = charts(services):actor {id = 'visualizer', scheduler = clock, input = {mode = 'socket', address = 'unix:/run/ourokit/dev/self'}}
  viz:observe(function(record) model.ingest(stores.self, record) end)
  model.ingest(stores.self, {kind = 'actor', action = 'started', actor = 'visualizer', machine = 'visualizer',
    graph = viz.chart:graph(), time_ms = 0})
  viz:start()
  local function at(t) clock.advance(t - clock.now) end
  at(30); scenario.run_one(clock)
  at(60); viz:send {type = 'RECORDS', revision = 1, actors = {'stopwatch'}, counts = {stopwatch = 3}, after = 3, seed = 1}
  at(900); viz:send {type = 'SCRUB', value = 2}
  at(1400); viz:send {type = 'STEP', delta = 1}
  at(2000); viz:send {type = 'LIVE'}
  at(2600); viz:send {type = 'INJECT', name = 'START'}
  at(2700); scenario.run_one(clock)
  at(3200); viz:send {type = 'EDIT_PAYLOAD', name = 'MAX_LAPS', fields = {value = 'integer'}}
  at(3600); viz:send {type = 'FIELD', name = 'value', value = '3'}
end

local function counts(store)
  local out = {}
  for path, entry in pairs(store.actors) do out[path] = #entry.history.frames end
  return out
end

-- An unstarted visualizer actor restored to `states` with `context`.
local function viz_for(store, selected, cursor, opts)
  local states = {'connection', 'view', 'editor', 'screen', 'watch', 'watch.idle', opts.screen or 'screen.unit'}
  for _, id in ipairs(opts.states or {'connection.connected', 'connection.connected.live', 'view.scrubbing', 'editor.closed'}) do
    states[#states + 1] = id
  end
  local context = {mode = opts.mode or 'socket', address = opts.address or 'unix:/run/user/1000/ourokit/dev/7f3a…',
    path = opts.path or false, revision = 1, actors = store.order, counts = counts(store), after = 0, seed = 1,
    selected = selected, cursor = cursor or false, message = opts.message or false, editor = opts.editor or false,
    gaps = 0, acked = opts.acked or {}, wait = false, alarm = opts.alarm or false}
  return charts(stub):actor {id = 'visualizer', snapshot = {machine = 'visualizer', status = 'active', states = states, context = context}}
end

local function find(store, actor, event)
  for i, frame in ipairs(store.actors[actor].history.frames) do
    if frame.record.event and frame.record.event.type == event then return i end
  end
end

local function story(id, name, store_name, actor, cursor, opts)
  opts = opts or {}
  local store = stores[store_name]
  if type(cursor) == 'string' then cursor = find(store, actor, cursor) end
  local viz = viz_for(store, actor, cursor, opts)
  local frames = actor and store.actors[actor].history.frames
  local now = frames and frames[cursor or #frames].time + (opts.elapsed or 0)
  return o.story {id = id, name = name, viewport = {width = W, height = H}, snapshot_scale = 1,
    color_scheme = opts.scheme or 'light', padding = 0, content = function()
      return view.Screen {viz = viz, store = store, motion = opts.pulse or 0.999, now = now, timeline_width = W - 24,
        overview_now = opts.overview_now}
    end}
end

-- The first alarm of a store, for drill-down stories.
local function first_alarm(store_name) return stores[store_name].alarms[1] end
local overview_states = {'connection.connected', 'connection.connected.live', 'view.following', 'editor.closed'}
local alarm = first_alarm('notes_error')

local recorded = {mode = 'file', path = 'stopwatch.records.jsonl', states = {'connection.loaded', 'view.scrubbing', 'editor.closed'}}

return o.storybook {title = 'Statechart inspector', stories = {
  story('overview/notes', 'Overview: Notes with three documents, normal operation (all grey)', 'notes_normal', nil, nil,
    {screen = 'screen.overview', states = overview_states}),
  story('overview/invoke-error', 'Overview: a failed write (red unit and alarm)', 'notes_error', nil, nil,
    {screen = 'screen.overview', states = overview_states}),
  story('overview/stuck', 'Overview: a write stuck for 2.5 s (amber)', 'notes_stuck', nil, nil,
    {screen = 'screen.overview', states = overview_states, overview_now = stores.notes_stuck.now}),
  story('overview/drill-down', 'Drill-down: the alarm opens its unit at the failing step', 'notes_error', alarm.actor, alarm.step,
    {alarm = alarm.id, pulse = 0.6}),
  story('overview/record', 'Level 4: the record behind the alarm', 'notes_error', alarm.actor, alarm.step,
    {alarm = alarm.id, screen = 'screen.record'}),
  story('overview/back', 'Back up: alarm acknowledged, the unit is grey again', 'notes_error', alarm.actor, nil,
    {screen = 'screen.overview', states = overview_states, acked = {[tostring(alarm.id)] = true}}),
  story('overview/dark', 'Overview: failed write, dark theme', 'notes_error', nil, nil,
    {screen = 'screen.overview', states = overview_states, scheme = 'dark'}),
  story('stopwatch/start', 'Stopwatch: START taken (recorded session)', 'stopwatch', 'stopwatch', 'START', {pulse = 0.55, mode = recorded.mode, path = recorded.path, states = recorded.states}),
  story('stopwatch/lap', 'Stopwatch: LAP while running', 'stopwatch', 'stopwatch', 'LAP', {pulse = 0.5, elapsed = 40, mode = recorded.mode, path = recorded.path, states = recorded.states}),
  story('stopwatch/lap-dark', 'Stopwatch: LAP, dark theme', 'stopwatch', 'stopwatch', 'LAP', {pulse = 0.5, elapsed = 40, scheme = 'dark', mode = recorded.mode, path = recorded.path, states = recorded.states}),
  story('document/both-regions', 'Document: SAVE taken by both parallel regions', 'document', 'document', 11, {pulse = 0.6, elapsed = 3100}),
  story('document/rejected', 'Document: rejected DISCARD', 'document', 'document', 6, {pulse = 0.999}),
  story('document/invoke-error', 'Document: write invoke failed', 'document', 'document', 9, {pulse = 0.7, scheme = 'dark'}),
  story('document/final', 'Document: DISCARD into the final state', 'document', 'document', 13, {pulse = 0.85}),
  story('connection/retry', 'Connection: retry backoff timer', 'connection', 'connection', 4, {pulse = 0.6, elapsed = 900}),
  story('editor/payload', 'Payload editor for an event with fields', 'stopwatch', 'stopwatch', 'LAP',
    {pulse = 0.999, states = {'connection.connected', 'connection.connected.live', 'view.following', 'editor.open'},
     editor = {name = 'MAX_LAPS', fields = {value = 'integer'}, drafts = {value = '3'}}, message = 'START accepted → clock, clock.running, settings, settings.closed'}),
  story('self/visualizer', 'The visualizer inspecting its own chart', 'self', 'visualizer', nil, {pulse = 0.6, address = 'unix:… (self)'}),
}}
