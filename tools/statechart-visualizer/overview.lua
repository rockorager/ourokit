-- The system overview's data (ISA-101 style: grey unless abnormal), folded
-- from §10 records at ingest into the model store:
--   per actor   parent, record times (event rate), rejected count and the
--               last rejection, dwell samples and entry times of leaf states
--   system      alarms (invoke and child failures, error.* and
--               surface.failed.* events, record.error, stuck states),
--               traffic between actors and I/O endpoints (invoke and task srcs)
-- Acknowledgements are chart state (`acked`), not here: this is a pure
-- function of the records, so a replayed file gives the same alarms.
local M = {}

local RATE_KEEP = 240

local function abs_time(entry, raw, frame)
  if raw.time_ms ~= nil and raw.time_ms ~= entry.null then return raw.time_ms end
  return (entry.t0 or 0) + (frame.time or 0)
end

local function message_of(err)
  if type(err) == 'table' then return tostring(err.message or err.name or err.code or 'error') end
  return tostring(err)
end

function M.new_entry(entry)
  entry.times, entry.rejected, entry.entered, entry.dwells = {}, 0, {}, {}
end

local function alarm(store, entry, time, step, severity, kind, message, extra)
  local key = (extra and extra.key) or (entry.path .. '|' .. step .. '|' .. kind)
  if store.alarm_keys[key] then return end
  store.alarm_keys[key] = true
  local a = {id = #store.alarms + 1, time = time, actor = entry.path, step = step, severity = severity,
    kind = kind, message = message, state = extra and extra.state, src = extra and extra.src}
  store.alarms[#store.alarms + 1] = a
  return a
end

local function endpoint(store, src, kind)
  if not store.endpoints[src] then
    store.endpoints[src] = {src = src, kind = kind}
    store.endpoint_order[#store.endpoint_order + 1] = src
  end
  return store.endpoints[src]
end

local function link(store, from, to, event)
  local key = from .. '>' .. to
  local l = store.traffic[key]
  if not l then
    l = {from = from, to = to, count = 0, events = {}}
    store.traffic[key] = l
    store.traffic_order[#store.traffic_order + 1] = key
  end
  l.count = l.count + 1
  if event then l.events[event] = true end
end

-- Declared I/O of a chart: every invoke src in its graph.
function M.declare(store, entry)
  entry.uses = {}
  for _, state in ipairs(entry.graph.states) do
    for _, v in ipairs(state.invoke) do
      endpoint(store, v.src, 'invoke')
      entry.uses[v.src] = true
    end
  end
end

-- Leaf states of a configuration (an active set keyed by id).
local function leaves(graph, active)
  local out = {}
  for _, state in ipairs(graph.states) do
    if active[state.id] and state.id ~= graph.root then
      local leaf = true
      for _, child in ipairs(state.children) do if active[child] then leaf = false; break end end
      if leaf then out[#out + 1] = state.id end
    end
  end
  return out
end
M.leaves = leaves

function M.observe(store, entry, raw, frame)
  local record = frame.record
  local time = abs_time(entry, raw, frame)
  store.now = math.max(store.now or time, time)
  store.first = math.min(store.first or time, time)
  local times = entry.times
  times[#times + 1] = time
  if #times > RATE_KEEP then table.remove(times, 1) end
  local step = frame.index
  if record.rejected then
    entry.rejected = entry.rejected + 1
    entry.last_rejected = {time = time, step = step, event = record.event and record.event.type, seq = record.seq}
  end
  -- Failures.
  local failed_invoke = false
  for _, v in ipairs(record.invokes) do
    if v.op == 'error' then
      failed_invoke = true
      -- done/error entries name the invoke, not its src: the graph does.
      local state = v.state and entry.graph.by_id[v.state]
      for _, declared in ipairs(state and state.invoke or {}) do
        if declared.id == v.id then v = {id = v.id, src = declared.src, error = v.error} end
      end
      alarm(store, entry, time, step, 'high', 'invoke',
        'invoke ' .. tostring(v.id) .. ((v.src and v.src ~= v.id) and (' (' .. tostring(v.src) .. ')') or '')
          .. ' failed: ' .. message_of(v.error),
        {key = entry.path .. '|' .. step .. '|invoke|' .. tostring(v.id), src = v.src or v.id})
    end
  end
  local event = record.event and record.event.type or ''
  if not failed_invoke and event:find('^error%.') then
    local e = record.event
    alarm(store, entry, time, step, 'high', 'error', event .. ': ' .. message_of(e.error or e.message or 'failed'))
  end
  if event:find('^surface%.failed') then
    local e = record.event
    alarm(store, entry, time, step, 'high', 'surface',
      event .. ': ' .. tostring(e.reason or '') .. (e.message and (' ' .. tostring(e.message)) or ''))
  end
  if raw.error ~= nil and raw.error ~= entry.null then
    local code = type(raw.error) == 'table' and raw.error.code
    alarm(store, entry, time, step, 'high', 'action', (code and (code .. ': ') or '') .. message_of(raw.error))
  end
  -- Traffic: children reporting back, sends (record.sent on the sender's
  -- record; the receiver's `from` would count the same send twice), tasks.
  local parent_path = entry.path
  if record.origin == 'child' then
    local child = event:match('^done%.actor%.(.+)$') or event:match('^error%.actor%.(.+)$')
    if child and store.actors[parent_path .. '/' .. child] then link(store, parent_path .. '/' .. child, parent_path, event) end
  end
  -- sent: to another actor (send_to, send_parent, or by system id), or to
  -- one of this actor's invokes (invoke = true, to = '<actor>/<invoke id>').
  -- A system-id send to a target that has not started links nothing.
  local sent = raw.sent
  if type(sent) == 'table' then
    for _, s in ipairs(sent) do
      if type(s) == 'table' and s.to and s.to ~= entry.null then
        if s.invoke == true then
          local id = tostring(s.to):match('/([^/]+)$')
          for _, state in ipairs(entry.graph.states) do
            for _, v in ipairs(state.invoke) do
              if v.id == id and store.endpoints[v.src] then
                store.endpoints[v.src].received = (store.endpoints[v.src].received or 0) + 1
              end
            end
          end
        elseif store.actors[s.to] then
          link(store, entry.path, s.to, s.event)
        end
      end
    end
  end
  for _, c in ipairs(record.children) do
    if type(c) == 'table' and (c.action == 'spawned' or c.action == 'started') and (c.machine == nil or c.machine == entry.null) and c.id then
      local src = tostring(c.src or tostring(c.id):match('^([^%.]+)') or c.id)
      endpoint(store, src, 'task')
      entry.uses = entry.uses or {}
      entry.uses[src] = true
    end
  end
  -- Dwell: leaf entries and exits on the scheduler clock.
  for _, id in ipairs(record.exited) do
    local since = entry.entered[id]
    if since then
      local samples = entry.dwells[id] or {}
      samples[#samples + 1] = time - since
      if #samples > 50 then table.remove(samples, 1) end
      entry.dwells[id] = samples
      entry.entered[id] = nil
    end
  end
  for _, id in ipairs(record.entered) do entry.entered[id] = time end
  -- A seeded or first record: active leaves count from now.
  for _, id in ipairs(leaves(entry.graph, frame.active)) do
    if not entry.entered[id] then entry.entered[id] = time end
  end
  for id in pairs(entry.entered) do if not frame.active[id] then entry.entered[id] = nil end end
end

local function median(samples)
  local sorted = {}
  for i, v in ipairs(samples) do sorted[i] = v end
  table.sort(sorted)
  local n = #sorted
  if n == 0 then return nil end
  if n % 2 == 1 then return sorted[(n + 1) // 2] end
  return (sorted[n // 2] + sorted[n // 2 + 1]) / 2
end

-- The stuck limit for one state, or nil when it is not watched yet.
function M.limit(store, entry, id)
  local config = store.thresholds or {}
  local default = config.default or {}
  local chart = (config.charts or {})[entry.machine] or {}
  local per = chart.states and chart.states[id]
  if per == false then return nil end
  local state = entry.graph.by_id[id]
  if per == nil and not (state and (#state.invoke > 0 or #state.after > 0)) then return nil end
  per = per or {}
  if per.max_ms then return per.max_ms end
  local samples = entry.dwells[id] or {}
  local need = per.samples or chart.samples or default.samples or 3
  if #samples < need then return nil end
  local factor = per.factor or chart.factor or default.factor or 10
  local floor = per.min_ms or chart.min_ms or default.min_ms or 1000
  return math.max(floor, factor * median(samples)), median(samples)
end

-- Raises stuck alarms at `now` (scheduler clock) and returns the time of the
-- next possible one, so a single timer covers the whole system.
function M.check(store, now)
  local next_at
  for _, path in ipairs(store.order) do
    local entry = store.actors[path]
    if entry and not entry.stopped then
      for id, since in pairs(entry.entered) do
        local limit, usual = M.limit(store, entry, id)
        if limit then
          local key = path .. '|stuck|' .. id .. '|' .. since
          if now - since >= limit then
            if not store.alarm_keys[key] then
              local function fmt(ms) return ms < 1000 and string.format('%dms', math.floor(ms + 0.5)) or string.format('%.1fs', ms / 1000) end
              local usual_text = usual and (', usually ' .. fmt(usual)) or ''
              alarm(store, entry, since + limit, #entry.history.frames, 'medium', 'stuck',
                string.format('%s active over %s%s', id, fmt(limit), usual_text), {key = key, state = id})
            end
          elseif not next_at or since + limit < next_at then
            next_at = since + limit
          end
        end
      end
    end
  end
  return next_at
end

-- Unacknowledged alarms of one unit, worst first: 'high', 'medium' or nil.
function M.severity(store, path, acked)
  local worst
  for _, a in ipairs(store.alarms) do
    if a.actor == path and not (acked and acked[tostring(a.id)]) then
      if a.severity == 'high' then return 'high' end
      worst = 'medium'
    end
  end
  return worst
end

-- Records per bucket over the last `span` ms before `now`.
function M.rate(entry, now, span, buckets)
  local out = {}
  for i = 1, buckets do out[i] = 0 end
  local start = now - span
  for _, t in ipairs(entry.times) do
    if t > start and t <= now then
      local b = math.min(buckets, math.floor((t - start) / span * buckets) + 1)
      out[b] = out[b] + 1
    end
  end
  return out
end

return M
