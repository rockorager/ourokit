-- The inspected data: per-actor graph, history frames and diagram layout.
-- It is append-only, can grow to thousands of frames and is rebuilt from the
-- inspected app at any time, so it lives here rather than in chart context.
-- The visualizer chart holds everything about the session instead (source,
-- connection, selection, cursor, editor) and a `revision` that every ingest
-- batch bumps, so views rebuild from chart state alone.
local contract = require('contract')
local history = require('history')
local layout = require('diagram.layout')
local overview = require('overview')
local default_thresholds = require('thresholds')

local M = {}

function M.new(null, thresholds)
  contract.null = null
  return {actors = {}, order = {}, plants = {}, null = null, thresholds = thresholds or default_thresholds,
    alarms = {}, alarm_keys = {}, endpoints = {}, endpoint_order = {}, traffic = {}, traffic_order = {}, inbox = {}}
end

local function shape(g) return g.id .. ':' .. #g.states .. ':' .. #g.transitions end

-- Diagrams are laid out once per chart shape and shared by its actors.
function M.plant(store, entry)
  local key = shape(entry.graph)
  store.plants[key] = store.plants[key] or layout.layout(entry.graph)
  return store.plants[key]
end

local function started(store, record, time)
  local path = record.actor
  local graph = contract.graph(record.graph)
  local existing = store.actors[path]
  -- A reseed (attach, reload, idle reattach) of the same chart keeps history.
  if record.seeded and existing and shape(existing.graph) == shape(graph) then
    existing.stopped = false
    return
  end
  if not existing then store.order[#store.order + 1] = path end
  -- t0 is on the scheduler clock when records carry time_ms, else receive time.
  local parent = record.parent
  local entry = {path = path, machine = record.machine, graph = graph, history = history.new(graph),
    parent = parent ~= store.null and parent or nil, null = store.null,
    t0 = record.time_ms ~= store.null and record.time_ms or nil, received0 = time}
  overview.new_entry(entry)
  store.actors[path] = entry
  overview.declare(store, entry)
end

-- Ingests one §10 record (`time` is the receive time, for clockless feeds).
function M.ingest(store, record, time)
  if record.kind == 'actor' then
    if record.action == 'started' then started(store, record, time)
    elseif record.action == 'stopped' and store.actors[record.actor] then store.actors[record.actor].stopped = true end
  elseif record.kind == 'transition' then
    local entry = store.actors[record.actor]
    if not entry then return end
    entry.stopped = record.status == 'stopped'
    local frames = entry.history.frames
    if record.time_ms and record.time_ms ~= store.null then entry.t0 = entry.t0 or record.time_ms end
    entry.received0 = entry.received0 or time
    local fallback = time and (time - entry.received0) or (frames[#frames] and frames[#frames].time or 0)
    local frame = history.append(entry.history, contract.record(record, entry.t0, fallback))
    overview.observe(store, entry, record, frame)
    store.deadline = overview.check(store, store.now)
  end
end

-- Stuck-state check at `now` on the inspected app's clock (no record
-- needed); returns the next deadline.
function M.check(store, now)
  store.now = math.max(store.now or now, now)
  store.deadline = overview.check(store, store.now)
  return store.deadline
end

-- Services only stage what they receive; the visualizer chart's `ingest`
-- action drains the inbox (design §6: this store is a cache written from
-- chart actions only). `now` also runs the stuck-state check.
function M.stage(store, record, time)
  store.inbox[#store.inbox + 1] = {record = record, time = time}
end

function M.drain(store, now)
  local inbox = store.inbox
  store.inbox = {}
  for _, item in ipairs(inbox) do M.ingest(store, item.record, item.time) end
  if now then M.check(store, now) end
end

-- Frame counts per actor, for the chart's cursor arithmetic.
function M.counts(store)
  local counts = {}
  for path, entry in pairs(store.actors) do counts[path] = #entry.history.frames end
  return counts
end

return M
