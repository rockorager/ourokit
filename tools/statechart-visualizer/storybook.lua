-- Headless frames of the statechart plant, driven by fixture records.
--   zig-out/bin/ouroctl storybook snapshot tools/statechart-visualizer/storybook.lua --output out
local o = require('ouro')
local contract = require('contract')
local history = require('history')
local layout = require('plant.layout')
local view = require('plant.view')
local scenario = require('scenario')
local fixtures = {document=require('fixtures.document'), connection=require('fixtures.connection')}
local recording = require('recording')

local W, H = 1600, 1000

-- Recorded during catalog evaluation: actors write their snapshot signal,
-- which is not allowed inside a story's build callback.
local runs = {}
for name, fixture in pairs(fixtures) do runs[name] = scenario.run(fixture) end

-- A real session: examples/stopwatch recorded under --dev, replayed with
-- `ouroctl replay ... --records` (fixtures/stopwatch_recording.lua).
runs.recording = {records = {}, lifecycle = {}}
for _, record in ipairs(assert(recording.parse(require('fixtures.stopwatch_recording'), o.json))) do
  if record.kind == 'actor' and record.action == 'started' and record.actor == 'stopwatch' and not runs.recording.graph then
    runs.recording.graph, runs.recording.lifecycle[1] = record.graph, record
  elseif record.kind == 'transition' and record.actor == 'stopwatch' then
    runs.recording.records[#runs.recording.records + 1] = record
  end
end

local function load(name)
  local run = runs[name]
  local graph = contract.graph(run.graph)
  local hist = history.new(graph)
  local t0 = run.lifecycle[1] and run.lifecycle[1].time_ms
  for _, raw in ipairs(run.records) do history.append(hist, contract.record(raw, t0)) end
  return graph, hist
end

-- One frame: history position, machine clock and pinned motion phases.
local function frame(name, cursor, opts)
  return function()
    local graph, hist = load(name)
    local plant = layout.layout(graph)
    if cursor == 'lap' then
      for i, candidate in ipairs(hist.frames) do
        if candidate.record.event and candidate.record.event.type == 'LAP' then cursor = i; break end
      end
    end
    local f = hist.frames[cursor]
    return view.screen {
      history=hist, plant=plant, cursor=opts.head and nil or cursor,
      now=f.time + (opts.elapsed or 0), motion={pulse=opts.pulse, spin=opts.spin or 0.15},
      source=opts.source or 'ouro.machine · manual scheduler · fixtures/' .. name .. '.lua', status=opts.status,
      timeline_width=W - 24,
    }
  end
end

local function story(id, name, fixture, cursor, opts)
  return o.story {id=id, name=name, viewport={width=W, height=H}, snapshot_scale=1,
    color_scheme='dark', padding=0, content=frame(fixture, cursor, opts or {})}
end

return o.storybook {title='Statechart plant', stories={
  story('plant/initial', 'Initial configuration', 'document', 1, {pulse=0.7, status='LIVE'}),
  story('plant/edit-pulse', 'EDIT pulse leaving the manifold', 'document', 2, {pulse=0.3}),
  story('plant/saving', 'Writing: pump running, timeout gauge counting', 'document', 4, {pulse=0.8, elapsed=1900, spin=0.3}),
  story('plant/microsteps', 'SAVE then always → writing in one macrostep', 'document', 8, {pulse=0.8, elapsed=400}),
  story('plant/rejected', 'Rejected DISCARD flashes at the inlet', 'document', 6, {pulse=0.35}),
  story('plant/invoke-error', 'Write throws: pump red, error tag', 'document', 9, {pulse=0.7}),
  story('plant/both-regions', 'SAVE taken by both parallel regions', 'document', 11, {pulse=0.6, elapsed=3100}),
  story('plant/timeout', 'Timeout fired, write pump cancelled', 'document', 12, {pulse=0.6}),
  story('plant/final', 'DISCARD into the final state', 'document', 13, {pulse=0.9}),
  story('plant/connection', 'Connection machine with retry backoff', 'connection', 4, {pulse=0.6, elapsed=900}),
  story('recording/stopwatch-start', 'Recorded stopwatch session: first step', 'recording', 1,
    {pulse=0.7, status='RECORDING', source='recording · examples/stopwatch (ouroctl replay --records)'}),
  story('recording/stopwatch-scrubbed', 'Recorded stopwatch session scrubbed to a lap', 'recording', 'lap',
    {pulse=0.5, elapsed=40, status='RECORDING', source='recording · examples/stopwatch (ouroctl replay --records)'}),
}}
