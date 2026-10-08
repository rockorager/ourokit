-- Statechart inspector: live statechart diagrams of ouro.machine actors in
-- Harel / SCXML / Stately notation.
--
--   ouroctl run tools/statechart-visualizer/app.lua
--       In-process: runs the fixture charts and observes every actor in this
--       VM (itself included) with ouro.machine.inspect.
--   ouroctl run tools/statechart-visualizer/app.lua -- unix:$SOCKET
--       Attaches to a --dev instance: subscribes to ouro://statecharts and
--       fetches runtime.statecharts on each notification (polling only when
--       the endpoint lacks the resource). Event pills send runtime.send.
--   ouroctl run tools/statechart-visualizer/app.lua --dev -- self
--       Attaches to its own development endpoint.
--   ouroctl run tools/statechart-visualizer/app.lua -- session.records.jsonl
--       Loads a replayed recording (`ouroctl replay log app --records file`).
-- It opens on the system overview (every actor, I/O and the alarm list);
-- clicking a unit drills into its statechart.
-- All session state is in the `visualizer` chart (charts.lua); the views are
-- pure functions of it and of the inspected data (model.lua).
local o = require('ouro')
local machine = o.machine
local model = require('model')
local charts = require('charts')
local view = require('diagram.view')
local scenario = require('scenario')
local recording = require('recording')
local client = require('client')
local fixtures = {require('fixtures.document'), require('fixtures.connection')}

local W, H = 1600, 1000
local LIMIT = 256
local URI = 'ouro://statecharts'
local store = model.new(o.json.null)
local revision = 0
local gaps = 0 -- ring overflows reseeded from the late-attach snapshot

-- Until the next possible stuck-state alarm, on the inspected app's clock.
local function wait()
  return store.deadline and store.now and math.max(20, store.deadline - store.now) or nil
end

-- A RECORDS event: staged data is waiting in the inbox for the chart.
local function batch(extra)
  revision = revision + 1
  local event = {type = 'RECORDS', revision = revision, gaps = gaps}
  for k, v in pairs(extra or {}) do event[k] = v end
  return event
end

-- In-process seed: the started record and current snapshot of a live actor.
local function seed(actor)
  local clock = actor._scheduler and actor._scheduler.clock
  local now = clock and clock() or nil
  model.stage(store, {kind = 'actor', action = 'started', actor = actor.path, machine = actor.chart.id,
    graph = actor.chart:graph(), seeded = true, time_ms = now})
  local snapshot = machine.plain(actor:snapshot())
  local record = {kind = 'transition', actor = actor.path, machine = actor.chart.id, origin = 'attach', seeded = true,
    event = {type = 'ouro.attach'}, time_ms = now, microsteps = {}, exited = {}, entered = {}, timers = {}, invokes = {},
    states = snapshot.states, status = snapshot.status, context = snapshot.context}
  for _, live in ipairs(actor:pending_timers()) do
    record.timers[#record.timers + 1] = {action = 'started', state = live.state, delay = live.delay, token = live.token, time_ms = live.time_ms}
  end
  for _, live in ipairs(actor:pending_invokes()) do
    record.invokes[#record.invokes + 1] = {action = 'started', state = live.state, id = live.id, src = live.src, token = live.token, time_ms = live.time_ms}
  end
  model.stage(store, record)
end

-- Feedback from our own bookkeeping events must not trigger another batch
-- when the visualizer inspects itself.
local function own(record)
  return record.machine == 'visualizer' and record.event and (record.event.type == 'RECORDS' or record.event.type == 'ATTACHED')
end

-- One fetch of runtime.statecharts until caught up (client.lua).
local function fetch(address, after, seed_seen, epoch_seen)
  local cursor = {after = after, seed = seed_seen, epoch = epoch_seen, gaps = gaps}
  local changed = client.fetch(function(arguments) return o.mcp.call(address, 'runtime.statecharts', arguments) end,
    cursor, function(record, time) model.stage(store, record, time) end, own, o.json, LIMIT)
  gaps = cursor.gaps
  return cursor.after, cursor.seed, changed, cursor.epoch
end

local services = {}

-- In-process: seed every actor of this VM, then follow its records.
function services.observe(_, send)
  for _, actor in ipairs(machine.actors()) do pcall(seed, actor) end
  machine.inspect(function(record)
    model.stage(store, record)
    if not own(record) then send(batch()) end
  end)
  send(batch())
  while true do o.sleep(3600 * 1000) end
end

-- Push: subscribe, then fetch after the acknowledgment and after every
-- notification. Raises NoPush when the endpoint lacks the resource.
function services.follow(input, send)
  local after, seed_seen, epoch = input.after or 0, nil, input.epoch
  local refused
  local function pull()
    local changed
    after, seed_seen, changed, epoch = fetch(input.address, after, seed_seen, epoch)
    if changed then send(batch({after = after, seed = seed_seen, epoch = epoch})) end
  end
  o.mcp.subscribe(input.address, URI, function(message)
    if message.method == 'notifications/subscriptions/acknowledged' then
      send({type = 'ATTACHED'})
      pull()
    elseif message.method == 'notifications/resources/updated' then
      pull()
    elseif message.error then
      refused = message.error
    end
  end)
  if refused then error('NoPush: ' .. tostring(refused.message), 0) end
  error('Detached: the subscription ended', 0)
end

-- Fallback: one fetch per polling state entry.
function services.poll(input, send)
  local after, seed_seen, changed, epoch = fetch(input.address, input.after or 0, input.seed or nil, input.epoch)
  if changed then send(batch({after = after, seed = seed_seen, epoch = epoch})) end
end

-- A replayed recording (§14 --records), all at once.
function services.load(input)
  local text, err = o.files.read(input.path, {max_bytes = 64 * 1024 * 1024})
  if not text then error('CannotRead: ' .. tostring(err and err.message or err), 0) end
  local records, problem = recording.parse(text, o.json)
  if not records then error(problem, 0) end
  for _, record in ipairs(records) do model.stage(store, record) end
  return {revision = batch().revision}
end

-- Stuck states: sleep until the earliest deadline, then check. Records
-- arriving meanwhile re-enter the watch state, cancelling this sleep, so the
-- app clock advanced by exactly `wait` when it returns.
function services.watch(input)
  local from = store.now
  o.sleep(math.ceil(input.wait))
  return {revision = batch().revision, now = from + input.wait}
end

-- For the chart's actions: drain staged data into the cache, and read it.
function services.drain(now) model.drain(store, now) end
function services.summary()
  local actors = {}
  for i, path in ipairs(store.order) do actors[i] = path end
  return {actors = actors, counts = model.counts(store), wait = wait()}
end

-- Event pills: runtime.send on an endpoint, actor:_send in-process.
function services.inject(input)
  local summary
  if input.mode == 'in_process' then
    for _, actor in ipairs(machine.actors()) do
      if actor.path == input.actor then
        local accepted, reason = actor:_send(input.event, 'dev')
        summary = {accepted = accepted == true, reason = reason, states = machine.plain(actor:snapshot()).states}
      end
    end
    if not summary then error('UnknownActor: ' .. tostring(input.actor), 0) end
  else
    local reply = o.mcp.call(input.address, 'runtime.send', {actor = input.actor, event = input.event})
    if reply.error then error(tostring(reply.error.message), 0) end
    summary = reply.result.structuredContent
    if reply.result.isError then error(summary.error and summary.error.message or 'runtime.send failed', 0) end
  end
  if summary.accepted then return input.event.type .. ' accepted → ' .. table.concat(summary.states or {}, ', ') end
  return input.event.type .. ' rejected' .. (summary.reason and (' (' .. tostring(summary.reason) .. ')') or '')
end

local chart = charts(services)
local options = {mode = 'in_process'}

return o.app {
  id = 'dev.ourokit.statechart-visualizer',
  open = function(uris)
    local uri = uris[1]
    if not uri then return end
    if uri:find('%.jsonl$') then options = {mode = 'file', path = (uri:gsub('^file://', ''))}
    elseif uri == 'self' then options = {mode = 'socket', self = true}
    else options = {mode = 'socket', address = uri:find('^unix:') and uri or ('unix:' .. uri:gsub('^file://', ''))} end
  end,
  run = function()
    -- The development endpoint exists by the time the UI runs.
    if options.self then options.address = o.development_endpoint and o.development_endpoint() or false end
    local viz = chart:start {id = 'visualizer', input = options}
    if options.mode == 'in_process' then
      for _, fixture in ipairs(fixtures) do o.spawn(function() scenario.live(fixture) end) end
    end
    return {windows = {o.window {id = 'main', title = 'Statechart inspector', width = W, height = H, padding = 0,
      content = function()
        return view.Screen {viz = viz, store = store, timeline_width = W - 24}
      end}}}
  end,
}
