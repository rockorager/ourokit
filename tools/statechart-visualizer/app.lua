-- Statechart plant: a live P&ID-style view of ouro.machine actors.
--
--   ouroctl run tools/statechart-visualizer/app.lua
--       In-process demo: runs the fixture charts and observes them with
--       ouro.machine.inspect.
--   ouroctl run tools/statechart-visualizer/app.lua -- unix:$SOCKET
--       Attaches to a `--dev` instance's development socket and polls
--       runtime.statecharts (see README.md).
local o = require('ouro')
local contract = require('contract')
local history = require('history')
local layout = require('plant.layout')
local view = require('plant.view')
local scenario = require('scenario')
local fixtures = {require('fixtures.document'), require('fixtures.connection')}

contract.null = o.json.null

local W, H = 1600, 1000
local actors, order, plants = {}, {}, {}
local revision = o.signal(0)
local selected = o.signal(nil)
local cursor = o.signal(nil)
local source = o.signal('in-process demo · ouro.machine.inspect')
local status = o.signal('starting')
local address

local function bump() revision:set(revision() + 1) end

-- Plants are laid out once per chart shape and shared by its actors.
local function plant_for(entry)
  local g = entry.graph
  local key = g.id .. ':' .. #g.states .. ':' .. #g.transitions
  plants[key] = plants[key] or layout.layout(g)
  return plants[key]
end

local function on_started(record, time)
  local path = record.actor
  if not actors[path] then order[#order + 1] = path end
  local graph = contract.graph(record.graph)
  actors[path] = {path = path, machine = record.machine, graph = graph, history = history.new(graph), t0 = time}
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
    entry.t0 = entry.t0 or time
    local frames = entry.history.frames
    local t = time and entry.t0 and (time - entry.t0) or (frames[#frames] and frames[#frames].time or 0)
    history.append(entry.history, contract.record(record, t))
  end
end

-- In-process: every actor in this VM. Lua has no millisecond clock, so
-- records are stamped with ouro.time() seconds refined by a 50 ms ticker
-- (which lags under load, hence the resync every second).
local function demo()
  local start = o.time()
  local second, sub = start, 0
  o.spawn(function()
    while true do
      o.sleep(50)
      local s = o.time()
      if s ~= second then second, sub = s, 0 else sub = math.min(sub + 50, 950) end
    end
  end)
  o.machine.inspect(function(record)
    if record.kind == 'transition' and record.status == 'active' then
      for _, actor in ipairs(o.machine.actors()) do
        if actor.path == record.actor then record.accepted = actor:accepted() end
      end
    end
    ingest(record, (second - start) * 1000 + sub)
    bump()
  end)
  for _, fixture in ipairs(fixtures) do o.spawn(function() scenario.live(fixture) end) end
  status:set('LIVE')
end

-- Development endpoint: runtime.statecharts with a sequence cursor. Records
-- arrive as JSON text because ouro.mcp replies are capped at 4096 values.
local function attach()
  source:set('attached · ' .. address)
  local after, seeded, LIMIT = 0, false, 256
  while true do
    local ok, reply = pcall(o.mcp.call, address, 'runtime.statecharts',
      {after = after, limit = LIMIT, text = true, actors = not seeded})
    if not ok or reply.error or reply.result.isError then
      status:set('DISCONNECTED')
      after, seeded = 0, false
      o.sleep(1000)
    else
      local out = reply.result.structuredContent
      if not seeded then
        -- Late attach: actors whose start the ring already evicted.
        for _, actor in ipairs(out.actors or {}) do
          if actor.started ~= o.json.null then ingest(o.json.decode(actor.started), nil) end
          if actor.latest ~= o.json.null then ingest(o.json.decode(actor.latest), nil) end
        end
        seeded = true
      end
      for _, entry in ipairs(out.records) do ingest(o.json.decode(entry.record), entry.time_ms) end
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

local function content()
  revision()
  local path = selected()
  local entry = path and actors[path]
  if not entry then
    return o.box {key = 'empty', width = 'fill', height = 'fill', alignment = 'center', background = '#161b21',
      o.text {key = 't', text = address and ('Waiting for statechart records from ' .. address) or 'Waiting for actors…',
        foreground = '#7d8a97'}}
  end
  local n = #entry.history.frames
  local at = cursor()
  local tabs = {}
  for i, p in ipairs(order) do
    tabs[i] = {label = p .. (actors[p].stopped and ' ■' or ''), selected = p == path,
      on_press = function() selected:set(p); cursor:set(nil) end}
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
    if uri then address = uri:find('^unix:') and uri or ('unix:' .. uri:gsub('^file://', '')) end
  end,
  run = function()
    if address then o.spawn(attach) else demo() end
    return {windows = {o.window {id = 'main', title = 'Statechart plant', width = W, height = H,
      padding = 0, background = '#0d1115', content = content}}}
  end,
}
