-- Folds normalized transition records into per-step plant frames. A frame is
-- everything the plant needs to draw one point in history: the active
-- configuration, context, running timers, pump states and valve positions.
local M = {}

local function copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

function M.new(graph)
  return {graph=graph, frames={}}
end

-- Appends one normalized record and returns its frame.
function M.append(history, record)
  local graph = history.graph
  local previous = history.frames[#history.frames]
  local frame = {
    record=record, index=#history.frames + 1, time=record.time, timed=record.timed,
    active={}, timers=previous and copy(previous.timers) or {},
    pumps=previous and copy(previous.pumps) or {},
    context=record.context or (previous and previous.context) or {},
    changed={}, taken={}, guards={}, entered={}, exited={},
  }
  if record.configuration then
    for _, id in ipairs(record.configuration) do frame.active[id] = true end
  elseif previous then
    for id in pairs(previous.active) do frame.active[id] = true end
    for _, id in ipairs(record.exited) do frame.active[id] = nil end
    for _, id in ipairs(record.entered) do frame.active[id] = true end
  end
  for _, id in ipairs(record.taken) do frame.taken[id] = true end
  for _, id in ipairs(record.entered) do frame.entered[id] = true end
  for _, id in ipairs(record.exited) do frame.exited[id] = true end
  for _, timer in ipairs(record.timers) do
    local key = timer.state .. '@' .. tostring(timer.delay)
    if timer.op == 'started' then
      frame.timers[key] = {state=timer.state, delay=timer.delay, started=timer.time or record.time, token=timer.token}
    else
      frame.timers[key] = nil
      if timer.op == 'fired' then frame.fired = frame.fired or {}; frame.fired[key] = true end
    end
  end
  for _, invoke in ipairs(record.invokes) do
    frame.pumps[invoke.state .. '|' .. invoke.id] = {status=invoke.op == 'started' and 'running' or invoke.op,
      state=invoke.state, src=invoke.src, error=invoke.error, since=invoke.time or record.time, token=invoke.token}
  end
  -- Valves follow the record's post-step guard outcomes. Older feeds only
  -- had accepted events (can), which decide a valve only when its
  -- transition is the sole handler of that event in the source state.
  for _, t in ipairs(graph.transitions) do
    if t.guard and frame.active[t.source] then
      local value
      if record.guards then value = record.guards[t.id] end
      if value == nil and not record.guards and record.can and t.kind == 'event' and t.event then
        local handlers = 0
        for _, u in ipairs(graph.transitions) do
          if u.source == t.source and u.event == t.event then handlers = handlers + 1 end
        end
        if handlers == 1 then value = record.can[t.event] == true end
      end
      if value ~= nil then frame.guards[t.id] = value end
    end
  end
  local before = previous and previous.context or {}
  for k, v in pairs(frame.context) do
    if before[k] ~= v then frame.changed[k] = true end
  end
  history.frames[frame.index] = frame
  return frame
end

-- Remaining milliseconds for a running timer at `now` (machine time).
function M.remaining(timer, now)
  return math.max(0, timer.delay - (now - timer.started))
end

return M
