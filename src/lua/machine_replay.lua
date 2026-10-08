local ouro, M = ...
-- Statechart recording and replay (design/statecharts.md §14). Charts hold
-- all application state, so the inputs that cross into the root actors fully
-- determine behavior. The recorder logs each input as one JSON line together
-- with what it caused: compact records and per-actor snapshot deltas. Replay
-- drives the same charts with the same inputs on a virtual logical clock,
-- stubs invokes and spawned tasks with their recorded results, records what
-- it observes the same way, and compares line by line.

local json = ouro.json
local FORMAT, VERSION = 'ouro.machine.log', 1

local function fail(message, ...)
  error(select('#', ...) > 0 and string.format(message, ...) or message, 0)
end

---------------------------------------------------------------------------
-- Charts by id. Replay looks charts up by the ids in the log, so every chart
-- created in this VM is remembered; the last one created with an id wins.
---------------------------------------------------------------------------
local charts = {}
local create = M.create
function M.create(def)
  local chart = create(def)
  charts[chart.id] = chart
  return chart
end
function M.charts()
  local out = {}
  for id, chart in pairs(charts) do out[id] = chart end
  return out
end

---------------------------------------------------------------------------
-- JSON-safe copies. Views are unwrapped; functions, userdata and cycles
-- become marker strings, so a line can always be written. Non-string keys
-- are kept only in pure arrays.
---------------------------------------------------------------------------
local raw = M.raw
local function safe(value, seen)
  value = raw(value)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' or kind == 'string' then return value end
  if kind == 'number' then
    if value ~= value or value == math.huge or value == -math.huge then return tostring(value) end
    return value
  end
  if value == json.null then return value end
  if kind ~= 'table' then return '<' .. kind .. '>' end
  seen = seen or {}
  if seen[value] then return '<cycle>' end
  seen[value] = true
  local count, array = 0, true
  for k in pairs(value) do
    count = count + 1
    if math.type(k) ~= 'integer' or k < 1 then array = false end
  end
  local out = {}
  if array and count == #value then
    for i = 1, count do out[i] = safe(value[i], seen) end
    if count == 0 then
      local ok, text = pcall(json.encode, value)
      if ok and text == '[]' then json.array(out) end
    end
  else
    for k, v in pairs(value) do out[tostring(raw(k))] = safe(v, seen) end
  end
  seen[value] = nil
  return out
end

local function encode(entry)
  local ok, text = pcall(json.encode, entry)
  if ok then return text end
  return json.encode(safe(entry))
end

---------------------------------------------------------------------------
-- Recorder. recorder(write, options) installs M._hooks and calls write(line)
-- once per input. options.t0 is the logical time of t = 0 (default: now);
-- options.scheduler limits recording to actors on that scheduler (default
-- machine.default_scheduler); options.header = false skips the header line.
---------------------------------------------------------------------------
local function same_list(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function ids(list)
  local out = {}
  for i = 1, #list do out[i] = list[i] end
  return json.array(out)
end

-- What changed in one actor's snapshot. Context values compare by identity:
-- copy-on-write shares unchanged values, so this is exact and cheap.
local function delta(old, new)
  local d, changed = {}, false
  if not old or not same_list(old.states, new.states) then d.states = ids(new.states); changed = true end
  if not old or old.status ~= new.status then d.status = new.status; changed = true end
  if (old and old.output) ~= new.output then d.output = safe(new.output); changed = true end
  if not old or old.context ~= new.context then
    local set, unset = nil, nil
    local before = old and old.context or {}
    for k, v in pairs(new.context) do
      if before[k] ~= v then set = set or {}; set[tostring(k)] = safe(v) end
    end
    for k in pairs(before) do
      if new.context[k] == nil then unset = unset or {}; unset[#unset + 1] = tostring(k) end
    end
    if unset then table.sort(unset) end
    if set then d.context = set; changed = true end
    if unset then d.unset = unset; changed = true end
    if not old and not set then d.context = {}; changed = true end
  end
  if not old or not same_list(old.children, new.children) then d.children = ids(new.children); changed = true end
  return changed and d or nil
end

local function compact(actor, record)
  local transitions = {}
  for _, micro in ipairs(record.microsteps or {}) do
    for _, t in ipairs(micro.transitions or {}) do transitions[#transitions + 1] = t.index end
  end
  return {a = actor.path, e = record.event and record.event.type, x = record.reason, tr = json.array(transitions)}
end

local function classify(event, origin)
  local kind = event.type
  if origin == 'timer' then return 'timer' end
  if origin == 'invoke' and (kind:find('^done%.invoke%.') or kind:find('^error%.invoke%.')) then return 'invoke' end
  if origin == 'child' then return 'task' end
  return 'event'
end

function M.recorder(write, options)
  options = options or {}
  if type(write) ~= 'function' then fail('recorder expects a write function') end
  local scheduler = options.scheduler or M.default_scheduler
  local function now() return scheduler.clock and scheduler.clock() or 0 end
  local r = {count = 0, t0 = options.t0, tracked = {}, last = {}, current = nil, buffer = nil}
  if r.t0 == nil then r.t0 = now() end

  local function emit(entry)
    r.count = r.count + 1
    local line = encode(entry)
    if r.buffer then r.buffer[#r.buffer + 1] = line else write(line) end
  end
  if options.header ~= false then
    write(encode({format = FORMAT, version = VERSION, t0 = r.t0, app = options.app}))
  end

  local function track(actor)
    if r.last[actor] == nil then
      r.tracked[#r.tracked + 1] = actor
      r.last[actor] = false
    end
  end

  local hooks = {scheduler = options.scheduler}
  function hooks.enter(actor, kind, event, origin)
    local entry = {t = now() - r.t0, a = actor.path, r = json.array({})}
    if kind == 'input' then
      entry.k = classify(event, origin)
      entry.o = origin
      entry.e = safe(event)
    elseif kind == 'start' then
      entry.k, entry.m = 'start', actor.chart.id
      if actor._restored then
        local ok, snapshot = pcall(actor.persist, actor)
        if ok then entry.snapshot = snapshot else entry.unrecordable = tostring(snapshot) end
      else
        local ok, input = pcall(M.plain, actor._input)
        if ok then entry.input = input
        else
          -- The input holds functions (injected services): carry the
          -- initial snapshot instead. Entry effects of the initial state
          -- are then not re-run by replay, which marks the step lossy.
          local persisted, snapshot = pcall(actor.persist, actor)
          if persisted then entry.snapshot, entry.lossy = snapshot, true
          else entry.unrecordable = tostring(input) end
        end
      end
    elseif kind == 'stop' then
      if actor._status == 'created' then r.current = false; return end
      entry.k = 'stop'
    else
      entry.k = kind -- release
    end
    r.current = entry
  end
  function hooks.step(actor, record, origin)
    if origin == 'init' or origin == 'restore' then track(actor) end
    local entry = r.current
    if entry then entry.r[#entry.r + 1] = compact(actor, record) end
  end
  function hooks.leave(actor, kind, ok, err)
    local entry = r.current
    r.current = nil
    if not entry then return end
    local changes, live = {}, {}
    local any = false
    for _, tracked in ipairs(r.tracked) do
      local snapshot = tracked._snapshot
      local d = delta(r.last[tracked] or nil, snapshot)
      if d then changes[tracked.path] = d; any = true end
      r.last[tracked] = snapshot
      if snapshot.status == 'stopped' or tracked._status == 'stopped' then
        if not d and r.last[tracked] then
          -- Stopped without a snapshot change (never committed): say so.
          changes[tracked.path] = {status = 'stopped'}; any = true
        end
        r.last[tracked] = nil
      else
        live[#live + 1] = tracked
      end
    end
    r.tracked = live
    if any then entry.s = changes end
    if not ok then entry.err = tostring(err) end
    emit(entry)
  end
  -- Source reload: a candidate VM's lines wait for release (a failed
  -- candidate leaves nothing behind) and start a new generation.
  function hooks.carry()
    r.buffer = {}
    emit({k = 'reload', t = now() - r.t0})
  end
  function hooks.released()
    emit({k = 'released', t = now() - r.t0})
    local lines = r.buffer
    r.buffer = nil
    for _, line in ipairs(lines or {}) do write(line) end
  end
  r.hooks = hooks
  function r.stop() if M._hooks == hooks then M._hooks = nil end end
  M._hooks = hooks
  return r
end

---------------------------------------------------------------------------
-- Replay
---------------------------------------------------------------------------

-- Virtual scheduler for replay: a logical clock that only the replayer
-- moves, token scopes, and invokes and tasks that never run. Their
-- info.complete/info.send are called with the recorded results instead.
local function replay_scheduler(start)
  local s = {kind = 'replay', pending = {}}
  local clock = M.logical_clock {start = start}
  s.logical = clock
  s.clock, s.after = clock.now, clock.after
  function s.open(parent)
    local scope = {alive = true, children = {}}
    if type(parent) == 'table' then parent.children[#parent.children + 1] = scope end
    return scope
  end
  local function close(scope)
    scope.alive = false
    clock.cancel(scope)
    for _, child in ipairs(scope.children) do close(child) end
    scope.children = {}
  end
  s.close = close
  function s.alive(scope) return scope.alive end
  function s.run(scope, _, info)
    if info then s.pending[#s.pending + 1] = {info = info, scope = scope} end
  end
  function s.find(actor, kind, id, take)
    for i, item in ipairs(s.pending) do
      local info = item.info
      if info.actor == actor and info.kind == kind and info.id == id and item.scope.alive then
        if take then table.remove(s.pending, i) end
        return info
      end
    end
  end
  return s
end

M._replay_scheduler = replay_scheduler
M._decode_log = nil -- set below

local function decode_lines(source)
  local lines = {}
  if type(source) == 'table' then
    for i, line in ipairs(source) do lines[i] = line end
  elseif type(source) == 'string' then
    for line in source:gmatch('[^\n]+') do
      if line:find('%S') then lines[#lines + 1] = line end
    end
  else fail('replay expects log text or a list of lines') end
  local entries = {}
  for i, line in ipairs(lines) do
    local ok, value = pcall(json.decode, line)
    if not ok or type(value) ~= 'table' then fail('replay: line %d is not a JSON object', i) end
    entries[i] = value
  end
  local header = table.remove(entries, 1)
  if not header or header.format ~= FORMAT then fail('replay: the first line is not an %s header', FORMAT) end
  if header.version ~= VERSION then fail('replay: unsupported log version %s', tostring(header.version)) end
  return header, entries
end

local function equal(a, b)
  if a == b then return true end
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function show(value)
  if value == nil then return 'nil' end
  if value == json.null then return 'null' end
  if type(value) == 'string' then return string.format('%q', value) end
  local ok, text = pcall(json.encode, safe(value))
  text = ok and text or tostring(value)
  if #text > 160 then text = text:sub(1, 157) .. '...' end
  return text
end

-- Field-level differences between two values, as {path, recorded, replayed}.
local function differences(path, a, b, out, depth)
  if #out >= 24 or equal(a, b) then return out end
  if type(a) == 'table' and type(b) == 'table' and depth < 6 then
    local keys, seen = {}, {}
    for k in pairs(a) do keys[#keys + 1] = k; seen[k] = true end
    for k in pairs(b) do if not seen[k] then keys[#keys + 1] = k end end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    for _, k in ipairs(keys) do differences(path .. '.' .. tostring(k), a[k], b[k], out, depth + 1) end
    return out
  end
  out[#out + 1] = {path = path, recorded = a, replayed = b}
  return out
end

-- Full per-actor snapshots, rebuilt by applying deltas.
local function apply(states, changes)
  for path, d in pairs(changes or {}) do
    local s = states[path] or {context = {}}
    if d.states then s.states = d.states end
    if d.status then s.status = d.status end
    if d.output ~= nil then s.output = d.output end
    if d.children then s.children = d.children end
    if d.context then
      local context = {}
      for k, v in pairs(s.context) do context[k] = v end
      for k, v in pairs(d.context) do context[k] = v end
      s.context = context
    end
    for _, k in ipairs(d.unset or {}) do s.context[k] = nil end
    states[path] = s
  end
end

local function describe(entry)
  if not entry then return 'nothing (the log ended)' end
  local kind = entry.k
  local e = entry.e and entry.e.type
  if kind == 'event' then return string.format('event %s on %s from %s', e, entry.a, tostring(entry.o))
  elseif kind == 'timer' or kind == 'invoke' or kind == 'task' then return string.format('%s %s on %s', kind, e, entry.a)
  elseif kind == 'start' then return string.format('start %s (%s)', entry.a, tostring(entry.m))
  elseif entry.a then return string.format('%s %s', kind, entry.a) end
  return kind
end

-- replay(log, options) -> report. options.charts maps chart ids to charts
-- (default: every chart created in this VM, see machine.charts()).
function M.replay(source, options)
  options = options or {}
  local header, entries = decode_lines(source)
  local chart_for = options.charts or charts
  local t0 = header.t0 or 0
  local observed, observed_lines = {}, {}
  local scheduler, recorder, roots, released
  local saved_hooks = M._hooks
  local report = {format = 'ouro.machine.replay', ok = true, entries = #entries, compared = 0}
  -- options.records(record): the §10 inspection stream of the replayed
  -- actors (graphs, microsteps, timers, invokes), e.g. for the visualizer.
  local unsubscribe = options.records and M.inspect(function(record)
    local root = record.actor and record.actor:match('^[^/]+')
    for _, actor in ipairs(roots or {}) do
      if actor.path == root and actor._scheduler == scheduler then return options.records(record) end
    end
  end)

  local function generation(start)
    if recorder then
      -- The previous generation's actors are gone in the live run: stop
      -- them quietly so their ids are free.
      recorder.stop()
      for _, actor in ipairs(roots or {}) do pcall(actor.stop, actor) end
    end
    scheduler, roots, released = replay_scheduler(start), {}, false
    recorder = M.recorder(function(line)
      observed_lines[#observed_lines + 1] = line
      observed[#observed + 1] = json.decode(line)
    end, {scheduler = scheduler, t0 = t0, header = false})
  end

  -- The replay's own roots and their children, newest first: finished
  -- actors leave machine.actors() but may still get a stop.
  local function actor_at(path)
    local root_id, rest = path:match('^([^/]+)/?(.*)$')
    for i = #(roots or {}), 1, -1 do
      local actor = roots[i]
      if actor.path == root_id and actor._status ~= 'stopped' then
        for id in rest:gmatch('[^/]+') do
          actor = actor._children[id]
          if not actor then return nil end
        end
        return actor
      end
    end
  end

  local recorded_states, replayed_states = {}, {}
  local function diverge(index, message)
    local recorded, replayed = entries[index], observed[index]
    local expected, actual = {}, {}
    for path, s in pairs(recorded_states) do expected[path] = s end
    for path, s in pairs(replayed_states) do actual[path] = s end
    local diffs = {}
    if recorded and replayed then
      if not equal(recorded.r, replayed.r) then differences('records', recorded.r, replayed.r, diffs, 0) end
      apply(expected, recorded.s)
      apply(actual, replayed.s)
      differences('snapshot', expected, actual, diffs, 0)
      for _, field in ipairs({'k', 'a', 't', 'e', 'err'}) do
        if not equal(recorded[field], replayed[field]) then
          table.insert(diffs, 1, {path = field, recorded = recorded[field], replayed = replayed[field]})
        end
      end
    end
    report.ok = false
    report.divergence = {step = index, line = index + 1, t = recorded and recorded.t,
      message = message, recorded = recorded, replayed = replayed, differences = diffs}
  end

  local function compare()
    for j = report.compared + 1, #observed do
      local recorded, replayed = entries[j], observed[j]
      if not recorded then
        diverge(j, 'replay produced ' .. describe(replayed) .. ' after the recording ended')
        return false
      end
      if recorded.lossy then replayed.r, recorded.r = nil, nil end
      if not equal(recorded, replayed) then
        local what = describe(recorded)
        local message
        if describe(replayed) ~= what or recorded.t ~= replayed.t then
          message = 'replay produced ' .. describe(replayed) .. ' at t=' .. tostring(replayed.t) ..
            ' where the recording has ' .. what
        elseif not equal(recorded.r, replayed.r) then
          message = what .. ' took different transitions'
        elseif recorded.err ~= replayed.err then
          message = what .. (replayed.err and ' raised an error' or ' no longer raises')
        else
          message = what .. ' led to a different snapshot'
        end
        diverge(j, message)
        return false
      end
      apply(recorded_states, recorded.s)
      apply(replayed_states, replayed.s)
      report.compared = j
    end
    return true
  end

  local function deliver_stub(entry, kind, prefix)
    local id = entry.e.type:match('^done%.' .. prefix .. '%.(.+)$') or entry.e.type:match('^error%.' .. prefix .. '%.(.+)$')
    local info = scheduler.find(entry.a, kind, id, true)
    if not info then return false end
    if entry.e.type:find('^done') then info.complete(true, entry.e.output)
    else info.complete(false, entry.e.error) end
    return true
  end

  local function perform(index, entry)
    local kind = entry.k
    if kind == 'reload' then
      generation(t0 + entry.t)
      M.carry({})
      return true
    elseif kind == 'released' then
      if not released then released = true; M.release() end
      return true
    elseif kind == 'release' then
      if not released then released = true; M.release() end
      return true
    elseif kind == 'timer' then
      scheduler.logical.advance_to(t0 + entry.t)
      return true
    end
    scheduler.logical.advance_to(t0 + entry.t)
    if not compare() then return false end
    if kind == 'start' then
      local chart = chart_for[entry.m]
      if not chart then
        diverge(index, string.format('no chart %q to start %s; replay loads charts created by the app module', tostring(entry.m), entry.a))
        return false
      end
      if entry.unrecordable then
        diverge(index, 'the recording could not capture how ' .. entry.a .. ' started: ' .. entry.unrecordable)
        return false
      end
      local actor = chart:actor {id = entry.a, input = entry.input, snapshot = entry.snapshot, scheduler = scheduler}
      roots[#roots + 1] = actor
      actor:start()
      return true
    end
    local actor = actor_at(entry.a)
    if not actor then
      diverge(index, 'replay has no running actor ' .. tostring(entry.a) .. ' for ' .. describe(entry))
      return false
    end
    if kind == 'stop' then actor:stop(); return true end
    if kind == 'invoke' then
      if not deliver_stub(entry, 'invoke', 'invoke') then
        diverge(index, 'replay has no running invoke for ' .. describe(entry))
        return false
      end
      return true
    elseif kind == 'task' then
      if not deliver_stub(entry, 'task', 'actor') then
        diverge(index, 'replay has no running task for ' .. describe(entry))
        return false
      end
      return true
    end
    -- An event: delivered as recorded. Live sends were validated before they
    -- were recorded; invalid ones never reach the log.
    pcall(actor._deliver, actor, entry.e, entry.o)
    return true
  end

  local ok, err = pcall(function()
    generation(t0)
    for index, entry in ipairs(entries) do
      if not perform(index, entry) then return end
      if not compare() then return end
      -- A recorded timer must have fired by now.
      if index > #observed and entries[index].k ~= 'reload' and entries[index].k ~= 'released' and entries[index].k ~= 'release' then
        diverge(index, 'the recording has ' .. describe(entries[index]) .. ' but replay did not produce it')
        return
      end
    end
    if #observed < #entries then
      local index = #observed + 1
      diverge(index, 'the recording has ' .. describe(entries[index]) .. ' but replay did not produce it')
    end
  end)
  if recorder then recorder.stop() end
  if unsubscribe then unsubscribe() end
  for _, actor in ipairs(roots or {}) do pcall(actor.stop, actor) end
  M._hooks = saved_hooks
  if not ok then
    report.ok = false
    report.error = tostring(err)
  end
  report.replayed = #observed
  report.observed = options.keep_lines and observed_lines or nil
  report.states = replayed_states
  return report
end

-- A readable report for terminals and test failures.
function M.replay_text(report)
  local out = {}
  if report.error then
    out[#out + 1] = 'replay failed: ' .. report.error
  elseif report.ok then
    out[#out + 1] = string.format('replay matched: %d entries, identical records and snapshots', report.compared)
  else
    local d = report.divergence
    out[#out + 1] = string.format('DIVERGED at step %d (log line %d, t=%s ms): %s', d.step, d.line,
      tostring(d.t), d.message)
    out[#out + 1] = string.format('  matched %d of %d entries before it', report.compared, report.entries)
    for _, diff in ipairs(d.differences or {}) do
      out[#out + 1] = string.format('  %-40s recorded %s', diff.path, show(diff.recorded))
      out[#out + 1] = string.format('  %-40s replayed %s', '', show(diff.replayed))
    end
  end
  return table.concat(out, '\n')
end

M._decode_log = decode_lines
M._canonical_safe = safe

-- `ouroctl replay`: replay_tool(log, options_json) -> text, ok
function M.replay_tool(log, options_json)
  local options = options_json ~= '' and json.decode(options_json) or {}
  local records
  if options.records then
    records = {}
    options.records = function(record) records[#records + 1] = encode(record) end
  end
  local report = M.replay(log, {keep_lines = options.json, records = options.records})
  local extra = records and (table.concat(records, '\n') .. '\n') or nil
  if options.json then
    report.states = nil
    return json.encode(safe(report)), report.ok, extra
  end
  return M.replay_text(report) .. '\n', report.ok, extra
end
