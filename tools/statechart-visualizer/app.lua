-- Statechart plant: a live P&ID-style view of ouro.machine actors.
--
--   ouroctl run tools/statechart-visualizer/app.lua
--       In-process demo: runs the fixture charts and observes them with
--       ouro.machine.inspect.
--   ouroctl run tools/statechart-visualizer/app.lua -- unix:$SOCKET
--       Attaches to a `--dev` instance's development socket and polls
--       runtime.statecharts (see README.md).
--   ouroctl run tools/statechart-visualizer/app.lua -- session.records.jsonl
--       Loads a replayed recording (`ouroctl replay log app --records
--       file`) and opens it at its first step for scrubbing.
local o = require('ouro')
local contract = require('contract')
local history = require('history')
local layout = require('plant.layout')
local view = require('plant.view')
local scenario = require('scenario')
local recording = require('recording')
local fixtures = {require('fixtures.document'), require('fixtures.connection')}

contract.null = o.json.null

local W, H = 1600, 1000
local actors, order, plants = {}, {}, {}
local revision = o.signal(0)
local selected = o.signal(nil)
local cursor = o.signal(nil)
local source = o.signal('in-process demo · ouro.machine.inspect')
local status = o.signal('starting')
local address, records_path

local function bump() revision:set(revision() + 1) end

-- Plants are laid out once per chart shape and shared by its actors.
local function plant_for(entry)
  local g = entry.graph
  local key = g.id .. ':' .. #g.states .. ':' .. #g.transitions
  plants[key] = plants[key] or layout.layout(g)
  return plants[key]
end

local function shape(g) return g.id .. ':' .. #g.states .. ':' .. #g.transitions end

local function on_started(record, time)
  local path = record.actor
  local graph = contract.graph(record.graph)
  local existing = actors[path]
  -- A reseed (attach, reload, idle reattach) of the same chart keeps history.
  if record.seeded and existing and shape(existing.graph) == shape(graph) then
    existing.stopped = false
    return
  end
  if not existing then order[#order + 1] = path end
  -- t0 is on the scheduler clock when records carry time_ms, else receive time.
  actors[path] = {path = path, machine = record.machine, graph = graph, history = history.new(graph),
    t0 = record.time_ms ~= o.json.null and record.time_ms or nil, received0 = time}
  if not selected() then selected:set(path) end
  if selected() == path then cursor:set(nil) end
end

local function ingest(record, time)
  if record.kind == 'actor' then
    if record.action == 'started' then on_started(record, time)
    elseif record.action == 'stopped' and actors[record.actor] then actors[record.actor].stopped = true end
  elseif record.kind == 'transition' then
    local entry = actors[record.actor]
    if not entry then return end
    entry.stopped = record.status == 'stopped'
    local frames = entry.history.frames
    if record.time_ms and record.time_ms ~= o.json.null then entry.t0 = entry.t0 or record.time_ms end
    entry.received0 = entry.received0 or time
    local fallback = time and (time - entry.received0) or (frames[#frames] and frames[#frames].time or 0)
    history.append(entry.history, contract.record(record, entry.t0, fallback))
  end
end

-- In-process: every actor in this VM; records carry the scheduler clock.
local function demo()
  o.machine.inspect(function(record) ingest(record, nil); bump() end)
  for _, fixture in ipairs(fixtures) do o.spawn(function() scenario.live(fixture) end) end
  status:set('LIVE')
end

-- Development endpoint: runtime.statecharts with a sequence cursor. Records
-- arrive as JSON text because ouro.mcp replies are capped at 4096 values.
local function attach()
  source:set('attached · ' .. address)
  local after, seed, LIMIT = 0, nil, 256
  while true do
    local ok, reply = pcall(o.mcp.call, address, 'runtime.statecharts',
      {after = after, limit = LIMIT, text = true, seed = seed, actors = seed == nil})
    if not ok or reply.error or reply.result.isError then
      status:set('DISCONNECTED')
      after, seed = 0, nil
      o.sleep(1000)
    else
      local out = reply.result.structuredContent
      for _, entry in ipairs(out.records) do ingest(o.json.decode(entry.record), entry.time_ms) end
      -- The observer seeds every live actor's graph and current snapshot
      -- when it (re)attaches; apply that after the older ring records.
      if out.actors and #out.records < LIMIT then
        for _, actor in ipairs(out.actors) do
          if actor.started ~= o.json.null then ingest(o.json.decode(actor.started), out.time_ms) end
          if actor.latest ~= o.json.null then ingest(o.json.decode(actor.latest), out.time_ms) end
        end
        seed = out.seed
        bump()
      end
      after = out.next
      -- Catch up on a full page before rebuilding the UI once.
      if #out.records < LIMIT then
        if #out.records > 0 or status() ~= 'LIVE' then bump() end
        status:set(out.dropped and 'LIVE · records dropped' or 'LIVE')
        o.sleep(200)
      end
    end
  end
end

-- A replayed recording: ingest it all, then start at each actor's first step.
local function load_records()
  source:set('recording · ' .. records_path)
  local text, err = o.files.read(records_path, {max_bytes = 64 * 1024 * 1024})
  if not text then status:set('CANNOT READ ' .. tostring(err and err.message or err)); bump(); return end
  local records, problem = recording.parse(text, o.json)
  if not records then status:set(problem); bump(); return end
  for _, record in ipairs(records) do ingest(record, nil) end
  status:set('RECORDING · ' .. #records .. ' records')
  cursor:set(1)
  bump()
end

local function content()
  revision()
  local path = selected()
  local entry = path and actors[path]
  if not entry then
    return o.box {key = 'empty', width = 'fill', height = 'fill', alignment = 'center', background = '#161b21',
      o.text {key = 't', text = address and ('Waiting for statechart records from ' .. address)
        or (records_path and (records_path .. ': ' .. status())) or 'Waiting for actors…',
        foreground = '#7d8a97'}}
  end
  local n = #entry.history.frames
  local at = cursor()
  local tabs = {}
  for i, p in ipairs(order) do
    tabs[i] = {label = p .. (actors[p].stopped and ' ■' or ''), selected = p == path,
      on_press = function() selected:set(p); cursor:set(records_path and 1 or nil) end}
  end
  -- Inspected data is arbitrary: show a failure instead of losing the window.
  local ok, screen = pcall(view.screen, {
    history = entry.history, plant = plant_for(entry), cursor = at,
    title = entry.graph.id, source = source(), tabs = tabs,
    status = at and 'HISTORY' or (entry.stopped and 'STOPPED' or status()),
    timeline_width = W - 24,
    handlers = {
      following = at == nil,
      prev = function() cursor:set(math.max(1, (at or n) - 1)) end,
      next = function() local v = (at or n) + 1; cursor:set(v < n and v or nil) end,
      scrub = function(v) cursor:set(v < n and math.floor(v) or nil) end,
      live = function() cursor:set(nil) end,
    },
  })
  if ok then return screen end
  return o.box {key = 'failure', width = 'fill', height = 'fill', padding = 24, background = '#161b21',
    o.text {key = 't', text = 'Cannot draw ' .. path .. ': ' .. tostring(screen), foreground = '#ff6b62'}}
end

return o.app {
  id = 'dev.ourokit.statechart-visualizer',
  open = function(uris)
    local uri = uris[1]
    if uri and uri:find('%.jsonl$') then records_path = uri:gsub('^file://', '')
    elseif uri then address = uri:find('^unix:') and uri or ('unix:' .. uri:gsub('^file://', '')) end
  end,
  run = function()
    if records_path then o.spawn(load_records) elseif address then o.spawn(attach) else demo() end
    return {windows = {o.window {id = 'main', title = 'Statechart plant', width = W, height = H,
      padding = 0, background = '#0d1115', content = content}}}
  end,
}
