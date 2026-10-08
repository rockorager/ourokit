-- Development statechart bridge (statechart_inspector.zig). Installed,
-- inactive, in every source generation of a --dev instance: nothing here runs
-- until the development endpoint calls in.
--   attach()            observe records and seed every live actor
--   inspect(path)       one actor's complete current state, as JSON
--   send(token, json)   runtime.send, run as a task; reports through complete()
--   rollup()            one summary row per live actor (the overview), as JSON
local publish, complete, ouro, closing = ...
local machine, json = ouro.machine, ouro.json
if not machine then return nil end
local unsubscribe

-- Per-actor counters while attached, for rollup(): records, rejected events,
-- errors (failed invokes and children, error.* and surface.failed.* events,
-- record.error) and the last of each.
local stats, since_ms = {}, nil
local MAX_WAIT_MS = 60000 -- runtime.send wait.timeout_ms bound (also checked by the host)

local function error_of(record)
  if type(record.error) == 'table' then return record.error.code or record.error.message or 'error' end
  for _, invoke in ipairs(record.invokes or {}) do
    if invoke.action == 'error' then
      local err = invoke.error
      return 'invoke ' .. tostring(invoke.id) .. ' failed: ' .. tostring(type(err) == 'table' and (err.message or err.name) or err)
    end
  end
  local kind = record.event and record.event.type or ''
  if kind:find('^error%.') or kind:find('^surface%.failed') then
    local e = record.event
    local detail = e.message or (type(e.error) == 'table' and (e.error.message or e.error.name)) or e.error or e.reason
    return kind .. (detail and (': ' .. tostring(detail)) or '')
  end
end

local function count(record)
  if record.kind ~= 'transition' or not record.actor then return end
  local s = stats[record.actor]
  if not s then s = {records = 0, rejected = 0, errors = 0}; stats[record.actor] = s end
  s.records = s.records + 1
  s.last_event, s.last_time_ms = record.event and record.event.type, record.time_ms
  if record.rejected then s.rejected = s.rejected + 1 end
  if record.entered and #record.entered > 0 then s.changed_ms = record.time_ms end
  local err = error_of(record)
  if err then s.errors, s.last_error = s.errors + 1, {message = err, time_ms = record.time_ms} end
end

local function emit(kind, record)
  local ok, bytes = pcall(json.encode, record)
  if not ok then
    kind, bytes = 'other', json.encode({kind = 'encode_error', actor = record.actor,
      machine = record.machine, message = tostring(bytes)})
  end
  return publish(kind, record.actor or '', bytes)
end

local function observe(record)
  count(record)
  local kind = record.kind == 'actor' and record.action or record.kind
  if not emit(kind, record) and unsubscribe then unsubscribe(); unsubscribe = nil end
end

local function find(path)
  for _, actor in ipairs(machine.actors()) do
    if actor.path == path then return actor end
  end
end

-- snapshot.children lists child ids and also maps each id to the child's
-- snapshot, which JSON cannot hold: report one {id, machine, status,
-- states} per child instead.
local function children_of(snapshot)
  local out = {}
  for _, id in ipairs(snapshot.children or {}) do
    local child = snapshot.children[id]
    out[#out + 1] = {id = id, machine = type(child) == 'table' and child.machine or nil,
      status = type(child) == 'table' and child.status or nil, states = type(child) == 'table' and child.states or nil}
  end
  return json.array(out)
end

-- Complete current state of one actor: a synthetic started record (with the
-- graph) and an origin = 'attach' record with the configuration, the full
-- context, children, pending timers and invokes, and the accepted events.
local function current(actor)
  local clock = actor._scheduler and actor._scheduler.clock
  local now = clock and clock() or nil
  local started = {kind = 'actor', action = 'started', actor = actor.path, machine = actor.chart.id,
    parent = actor._parent and actor._parent.path, graph = actor.chart:graph(), seeded = true, time_ms = now}
  local snapshot = machine.plain(actor:snapshot())
  local record = {kind = 'transition', actor = actor.path, machine = actor.chart.id, origin = 'attach',
    seeded = true, event = {type = 'ouro.attach'}, handled = true, rejected = false, time_ms = now,
    microsteps = {}, exited = {}, entered = {}, timers = {}, invokes = {}, actions = {},
    states = snapshot.states, status = actor:status(), context = snapshot.context,
    children = children_of(snapshot), output = snapshot.output}
  for _, live in ipairs(actor:pending_timers()) do
    record.timers[#record.timers + 1] = {action = 'started', state = live.state, delay = live.delay,
      event = live.event, token = live.token, time_ms = live.time_ms}
  end
  for _, live in ipairs(actor:pending_invokes()) do
    record.invokes[#record.invokes + 1] = {action = 'started', state = live.state, id = live.id,
      src = live.src, token = live.token, time_ms = live.time_ms}
  end
  local ok, accepted = pcall(actor.accepted, actor)
  if ok then record.accepted = accepted end
  return started, record
end

local function attach()
  if unsubscribe then return end
  unsubscribe = machine.inspect(observe)
  stats, since_ms = {}, nil
  publish('seed_reset', '', '{}')
  for _, actor in ipairs(machine.actors()) do
    local ok, err = pcall(function()
      local started, record = current(actor)
      emit('seed_started', started)
      emit('seed_latest', record)
    end)
    if not ok then print('statechart inspector cannot seed ' .. tostring(actor.path) .. ': ' .. tostring(err)) end
  end
end

local function inspect(path)
  local actor = find(path)
  if not actor then return nil end
  local started, record = current(actor)
  return json.encode({actor = actor.path, machine = actor.chart.id, parent = started.parent,
    graph = started.graph, snapshot = record})
end

local function count_keys(t)
  local n = 0
  for _ in pairs(t or {}) do n = n + 1 end
  return n
end

-- The overview: one row per live actor, from live state plus the counters
-- kept while attached (observed_since_ms says since when).
local function rollup()
  local rows = {}
  for _, actor in ipairs(machine.actors()) do
    local clock = actor._scheduler and actor._scheduler.clock
    local now = clock and clock() or nil
    since_ms = since_ms or now
    local snapshot = machine.plain(actor:snapshot())
    local leaves = {}
    for _, id in ipairs(snapshot.states or {}) do
      local leaf = true
      for _, other in ipairs(snapshot.states) do
        if other:sub(1, #id + 1) == id .. '.' then leaf = false; break end
      end
      if leaf then leaves[#leaves + 1] = id end
    end
    local s = stats[actor.path] or {records = 0, rejected = 0, errors = 0}
    rows[#rows + 1] = {actor = actor.path, machine = actor.chart.id, parent = actor._parent and actor._parent.path,
      status = actor:status(), states = json.array(leaves), timers = #actor:pending_timers(),
      invokes = #actor:pending_invokes(), records = s.records, rejected = s.rejected, errors = s.errors,
      -- Per-actor observers (actor:observe) and pending wait_for calls: why
      -- an actor builds records, and whether a cancelled wait let go.
      observers = #(actor._observers or {}), waits = count_keys(actor._waiters),
      last_error = s.last_error, last_event = s.last_event, last_time_ms = s.last_time_ms,
      changed_ms = s.changed_ms, time_ms = now}
  end
  return json.encode({observed_since_ms = since_ms, actors = json.array(rows)})
end

local function same(a, b)
  if a == b then return true end
  local ok_a, ja = pcall(json.encode, a)
  local ok_b, jb = pcall(json.encode, b)
  return ok_a and ok_b and ja == jb
end

-- runtime.send: delivered through the actor's normal send path (schema,
-- strict mode, reserved prefixes), labeled origin 'dev' for records and the
-- recorder. With wait, machine.wait_for until one of wait.states matches
-- (or any commit when states is omitted) or wait.timeout_ms passes.
local function deliver(request)
  local actor = find(request.actor)
  if not actor then error('UnknownActor: no live actor ' .. tostring(request.actor), 0) end
  if type(request.event) ~= 'table' or type(request.event.type) ~= 'string' then
    error('InvalidEvent: event must be a table with a string type', 0)
  end
  -- wait is validated before anything is sent: timeout_ms 0..MAX_WAIT_MS
  -- (ouro.sleep rejects durations past ~584 years, and that error would
  -- surface in wait_for's timer task), states a list of state ids.
  local wait_states, timeout
  if request.wait ~= nil then
    if type(request.wait) ~= 'table' then error('InvalidArgument: wait must be an object', 0) end
    wait_states, timeout = request.wait.states, request.wait.timeout_ms
    if timeout == nil then timeout = 5000 end
    if math.type(timeout) ~= 'integer' or timeout < 0 or timeout > MAX_WAIT_MS then
      error('InvalidArgument: wait.timeout_ms must be an integer from 0 to ' .. MAX_WAIT_MS, 0)
    end
    if wait_states ~= nil then
      if type(wait_states) ~= 'table' then error('InvalidArgument: wait.states must be a list of state ids', 0) end
      for _, id in ipairs(wait_states) do
        if type(id) ~= 'string' then error('InvalidArgument: wait.states must be a list of state ids', 0) end
      end
    end
  end
  local before = machine.plain(actor:snapshot()).context or {}
  local last
  -- Closed however this task ends, cancellation included (runtime.send's
  -- request cancelled or its client gone retires the task's scope).
  local observer <close> = closing(actor:observe(function(record)
    if record.kind == 'transition' then last = record end
  end))
  local ok, accepted, reason = pcall(actor._send, actor, request.event, 'dev')
  local wait
  if ok and request.wait then
    -- wait_for checks the predicate once before parking: without states,
    -- that first check says no, so the wait ends at the next commit.
    local first = true
    local matched, err = pcall(machine.wait_for, actor, function(snapshot)
      if not wait_states then
        local now = not first
        first = false
        return now
      end
      for _, id in ipairs(wait_states) do
        if machine.matches(snapshot, id) then return true end
      end
      return false
    end, {timeout = timeout})
    wait = {matched = matched, error = not matched and tostring(err) or nil}
  end
  if not ok then error(accepted, 0) end
  local snapshot = machine.plain(actor:snapshot())
  local after = snapshot.context or {}
  local changed, keys = {}, {}
  for k in pairs(after) do keys[k] = true end
  for k in pairs(before) do keys[k] = true end
  for k in pairs(keys) do
    if not same(before[k], after[k]) then changed[#changed + 1] = k end
  end
  table.sort(changed)
  local changes = {}
  for _, k in ipairs(changed) do changes[k] = after[k] == nil and json.null or after[k] end
  return {actor = actor.path, accepted = accepted == true, reason = reason, states = snapshot.states,
    status = actor:status(), changed = json.array(changed), changes = changes, wait = wait,
    sequence = last and last.sequence, commit = last and last.commit, time_ms = last and last.time_ms,
    guards = last and last.guards}
end

local function send(token, text)
  local ok, result = pcall(function() return deliver(json.decode(text)) end)
  if not ok then
    local message = tostring(result)
    result = {error = {code = message:match('^(%u%a+):') or 'SendFailed', message = message}}
  end
  local encoded, bytes = pcall(json.encode, result)
  if not encoded then bytes = json.encode({error = {code = 'SendFailed', message = tostring(bytes)}}) end
  complete(token, bytes)
end

return {attach = attach, inspect = inspect, send = send, rollup = rollup}
