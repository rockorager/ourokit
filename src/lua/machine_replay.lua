local ouro, M, task_origin, coroutine_library = ...
-- Private to the statechart runtime (applications have no coroutines): the
-- manual scheduler runs invokes and tasks in coroutines so machine.sleep
-- can wait for its virtual clock.
M._coroutine = coroutine_library
-- Statechart recording and replay (design/statecharts.md §14). Charts hold
-- all application state, so the inputs that cross into the root actors fully
-- determine behavior. The recorder logs each input as one JSON line together
-- with what it caused: compact records and per-actor snapshot deltas. Replay
-- drives the same charts with the same inputs on a virtual logical clock,
-- stubs invokes and spawned tasks with their recorded results, records what
-- it observes the same way, and compares line by line.

local json = ouro.json
local FORMAT, VERSION = 'ouro.machine.log', 2

-- Input origins per task: hosts tag MCP action calls natively; activation
-- hooks run under _with_origin. Sub-tasks do not inherit a tag.
function M._current_origin() return task_origin and task_origin() or nil end
function M._with_origin(origin, fn, ...)
  if not task_origin then return fn(...) end
  local previous = task_origin(origin)
  local results = table.pack(pcall(fn, ...))
  task_origin(previous)
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2, results.n)
end

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
-- Type-faithful JSON (log format version 2). Views are unwrapped; functions,
-- userdata and cycles become marker strings, so a line can always be
-- written. JSON alone loses Lua types, so three compact tags keep them:
--   {"$f": 3}            a float with an integral value (3.0), and
--   {"$f": "nan"|"inf"|"-inf"} the non-finite numbers;
--   {"$t": [[k, v], ...]} a table with non-string keys that is not a dense
--                         array (sparse or mixed maps, boolean or float keys);
--   {"$h": "<type>"}      a native handle (userdata, function, thread): its
--                         metatable __name when known, else its Lua type.
--                         Opaque: replay passes the marker table instead;
--   {"$x": "<hex>"}       a string that is not valid UTF-8 (raw bytes);
--   {"$o": {...}}         an object whose only key is itself a tag, escaped.
-- Everything else is plain JSON, so lines stay readable. revive() undoes the
-- tags after decoding; version 1 logs have none and decode as before.
---------------------------------------------------------------------------
local install, uninstall -- recorder registry, below
local raw = M.raw
local TAGS = {['$f'] = true, ['$t'] = true, ['$o'] = true, ['$h'] = true, ['$x'] = true}
-- The interpreter's machine.inspectable names handles ({"$h": name}); use
-- it when present.
local function handle(value, kind)
  local inspect = M.inspectable
  if inspect then
    local ok, marker = pcall(inspect, value)
    if ok and type(marker) == 'table' and type(marker['$h']) == 'string' then return {['$h'] = marker['$h']} end
  end
  return {['$h'] = kind}
end
local function key_order(a, b)
  local ta, tb = type(a[1]), type(b[1])
  if ta ~= tb then return ta < tb end
  if ta == 'boolean' then return (a[1] and 1 or 0) < (b[1] and 1 or 0) end
  if ta == 'number' or ta == 'string' then return a[1] < b[1] end
  return tostring(a[1]) < tostring(b[1])
end
local function safe(value, seen)
  value = raw(value)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' then return value end
  if kind == 'string' then
    if utf8.len(value) then return value end
    return {['$x'] = (value:gsub('.', function(c) return string.format('%02x', c:byte()) end))}
  end
  if kind == 'number' then
    if value ~= value then return {['$f'] = 'nan'} end
    if value == math.huge then return {['$f'] = 'inf'} end
    if value == -math.huge then return {['$f'] = '-inf'} end
    if math.type(value) == 'float' and value == math.floor(value) then return {['$f'] = value} end
    return value
  end
  if value == json.null then return value end
  if kind ~= 'table' then return handle(value, kind) end
  seen = seen or {}
  if seen[value] then return {['$h'] = 'cycle'} end
  seen[value] = true
  local count, array = 0, true
  for k in pairs(value) do
    count = count + 1
    if math.type(k) ~= 'integer' or k < 1 then array = false end
  end
  local out = {}
  local strings = true
  for k in pairs(value) do if type(raw(k)) ~= 'string' then strings = false; break end end
  if array and count == #value then
    for i = 1, count do out[i] = safe(value[i], seen) end
    if count == 0 then
      local ok, text = pcall(json.encode, value)
      if ok and text == '[]' then json.array(out) end
    end
  elseif strings then
    local only
    for k, v in pairs(value) do out[k] = safe(v, seen); only = k end
    if count == 1 and TAGS[only] then out = {['$o'] = out} end
  else
    local pairs_list = {}
    for original, v in pairs(value) do
      local k = raw(original)
      local key = (type(k) == 'number' or type(k) == 'string' or type(k) == 'boolean') and k or tostring(k)
      pairs_list[#pairs_list + 1] = {key, v}
    end
    table.sort(pairs_list, key_order)
    for i, pair in ipairs(pairs_list) do pairs_list[i] = json.array({safe(pair[1], seen), safe(pair[2], seen)}) end
    out = {['$t'] = json.array(pairs_list)}
  end
  seen[value] = nil
  return out
end

-- The native encoder and decoder stop at 4096 values per call. One input can
-- cause more (an action that sends 1000 events), so big lines fall back to
-- these Lua versions, with the same output: sorted keys, `[]` for marked
-- empty arrays. A recording line is never refused for its size.
local function is_empty_array(t)
  local ok, text = pcall(json.encode, t)
  return ok and text == '[]'
end

local function lua_encode(value, out)
  local kind = type(value)
  if value == nil or value == json.null then out[#out + 1] = 'null'
  elseif kind == 'boolean' or kind == 'number' or kind == 'string' then out[#out + 1] = json.encode(value)
  elseif kind == 'table' then
    local n = #value
    local count = 0
    for _ in pairs(value) do count = count + 1 end
    if (n > 0 and count == n) or (count == 0 and is_empty_array(value)) then
      out[#out + 1] = '['
      for i = 1, n do
        if i > 1 then out[#out + 1] = ',' end
        lua_encode(value[i], out)
      end
      out[#out + 1] = ']'
    else
      local keys = {}
      for k in pairs(value) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = '{'
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = ',' end
        local v = value[k]
        if v == nil then v = value[math.tointeger(tonumber(k)) or k] end
        out[#out + 1] = json.encode(k)
        out[#out + 1] = ':'
        lua_encode(v, out)
      end
      out[#out + 1] = '}'
    end
  else out[#out + 1] = json.encode('<' .. kind .. '>') end
  return out
end

local function encode(entry)
  local value = safe(entry)
  local ok, text = pcall(json.encode, value)
  if ok then return text end
  return table.concat(lua_encode(value, {}))
end

local escapes = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
local function lua_decode(text)
  local pos = 1
  local function fail_at(what) error(string.format('invalid JSON at byte %d: %s', pos, what), 0) end
  local function space() pos = text:find('[^ \t\r\n]', pos) or #text + 1 end
  local value
  local function str()
    local out = {}
    pos = pos + 1
    while true do
      local stop = text:find('["\\]', pos)
      if not stop then fail_at('unterminated string') end
      out[#out + 1] = text:sub(pos, stop - 1)
      if text:sub(stop, stop) == '"' then pos = stop + 1; break end
      local c = text:sub(stop + 1, stop + 1)
      if c == 'u' then
        local code = tonumber(text:sub(stop + 2, stop + 5), 16) or fail_at('bad escape')
        pos = stop + 6
        if code >= 0xD800 and code < 0xDC00 and text:sub(pos, pos + 1) == '\\u' then
          local low = tonumber(text:sub(pos + 2, pos + 5), 16)
          if low and low >= 0xDC00 and low < 0xE000 then
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            pos = pos + 6
          end
        end
        out[#out + 1] = utf8.char(code)
      else
        out[#out + 1] = escapes[c] or fail_at('bad escape')
        pos = stop + 2
      end
    end
    return table.concat(out)
  end
  function value()
    space()
    local c = text:sub(pos, pos)
    if c == '{' then
      local out = {}
      pos = pos + 1
      space()
      if text:sub(pos, pos) == '}' then pos = pos + 1; return out end
      while true do
        space()
        if text:sub(pos, pos) ~= '"' then fail_at('object key') end
        local key = str()
        space()
        if text:sub(pos, pos) ~= ':' then fail_at('colon') end
        pos = pos + 1
        out[key] = value()
        space()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == '}' then return out end
        if sep ~= ',' then fail_at('comma') end
      end
    elseif c == '[' then
      local out = {}
      pos = pos + 1
      space()
      if text:sub(pos, pos) == ']' then pos = pos + 1; return json.array(out) end
      while true do
        out[#out + 1] = value()
        space()
        local sep = text:sub(pos, pos)
        pos = pos + 1
        if sep == ']' then return out end
        if sep ~= ',' then fail_at('comma') end
      end
    elseif c == '"' then return str()
    elseif text:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
    elseif text:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
    elseif text:sub(pos, pos + 3) == 'null' then pos = pos + 4; return json.null
    else
      local number = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
      if not number or number == '' then fail_at('value') end
      pos = pos + #number
      return math.tointeger(tonumber(number)) or tonumber(number)
    end
  end
  local result = value()
  space()
  if pos <= #text then fail_at('trailing data') end
  return result
end

local function decode_plain(text)
  local ok, value = pcall(json.decode, text)
  if ok then return value end
  return lua_decode(text)
end

local revived_handles = 0
local function revive(value)
  if type(value) ~= 'table' or value == json.null then return value end
  local key, inner = next(value)
  if key ~= nil and next(value, key) == nil and TAGS[key] then
    if key == '$f' then
      if inner == 'nan' then return 0.0 / 0.0 end
      if inner == 'inf' then return math.huge end
      if inner == '-inf' then return -math.huge end
      return inner + 0.0
    elseif key == '$t' then
      local out = {}
      for _, pair in ipairs(inner) do out[revive(pair[1])] = revive(pair[2]) end
      return out
    elseif key == '$h' then
      revived_handles = revived_handles + 1
      return {['$h'] = inner}
    elseif key == '$x' then
      return (tostring(inner):gsub('%x%x', function(h) return string.char(tonumber(h, 16)) end))
    else
      local out = {}
      for k, v in pairs(inner) do out[k] = revive(v) end
      return out
    end
  end
  for k, v in pairs(value) do value[k] = revive(v) end
  return value
end

local function decode(text) return revive(decode_plain(text)) end
M._json_decode, M._json_encode = decode, encode

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
  if (old and old.output) ~= new.output then d.output = new.output; changed = true end
  if not old or old.context ~= new.context then
    local set, unset = nil, nil
    local before = old and old.context or {}
    for k, v in pairs(new.context) do
      if before[k] ~= v then set = set or {}; set[tostring(k)] = v end
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

-- Several recorders may run at once (the development recorder, a public
-- machine.recorder, paths_log, replay's own). M._hooks is the only one, or a
-- composite that hands each boundary to the recorders watching that actor's
-- scheduler. A failing recorder is dropped alone; stopping one keeps the rest.
local installed = {}
local composite = {}
local function reinstall()
  if #installed == 0 then M._hooks = nil
  elseif #installed == 1 then M._hooks = installed[1]
  else M._hooks = composite end
end
install = function(hooks) installed[#installed + 1] = hooks; reinstall() end
uninstall = function(hooks)
  for i, h in ipairs(installed) do
    if h == hooks then table.remove(installed, i); break end
  end
  reinstall()
end
local function root_of(actor)
  while actor._parent do actor = actor._parent end
  return actor
end
local function each(name, actor, ...)
  local list = {}
  for i, h in ipairs(installed) do list[i] = h end
  local root = actor and root_of(actor)
  local result
  for _, h in ipairs(list) do
    if h[name] and (not root or h.watches(root)) then
      local ok, value = pcall(h[name], actor, ...)
      if not ok then pcall(h.failed, 'recorder ' .. name .. ' failed: ' .. tostring(value))
      elseif result == nil then result = value end
    end
  end
  return result
end
function composite.watches(root)
  for _, h in ipairs(installed) do if h.watches(root) then return true end end
  return false
end
function composite.enter(actor, ...) each('enter', actor, ...) end
function composite.leave(actor, ...) each('leave', actor, ...) end
function composite.step(actor, ...) each('step', actor, ...) end
function composite.carry() each('carry') end
function composite.released() each('released') end
function composite.component_input(values)
  local result
  for _, h in ipairs(installed) do
    local ok, value = pcall(h.component_input, values)
    if ok and result == nil then result = value end
  end
  return result
end

function M.recorder(write, options)
  options = options or {}
  if type(write) ~= 'function' then fail('recorder expects a write function') end
  local scheduler = options.scheduler or M.default_scheduler
  local function now() return scheduler.clock and scheduler.clock() or 0 end
  local r = {count = 0, t0 = options.t0, tracked = {}, last = {}, current = nil, buffer = nil}
  if r.t0 == nil then r.t0 = now() end

  -- A recording never throws into the app: an entry that cannot be written
  -- stops recording, and the host reports the reason (runtime.diagnostics).
  function r.fail(reason)
    if r.failed then return end
    r.failed = tostring(reason)
    r.stop()
    if options.fail then pcall(options.fail, r.failed) end
  end
  local function emit(entry)
    if r.failed then return end
    r.count = r.count + 1
    local ok, line = pcall(encode, entry)
    if not ok then return r.fail('cannot encode recording entry ' .. r.count .. ': ' .. tostring(line)) end
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
  function hooks.failed(reason) r.fail(reason) end
  function hooks.watches(root) return root._scheduler == (scheduler or M.default_scheduler) end
  -- Component props hold descriptions and callbacks: keep the plain data.
  -- Replay re-runs the context function on it; a context that read a
  -- dropped prop diverges at the start step.
  function hooks.component_input(values)
    local function project(value, depth)
      value = raw(value)
      local kind = type(value)
      if kind == 'string' or kind == 'number' or kind == 'boolean' or value == json.null then return value end
      if kind ~= 'table' or depth > 8 then return nil end
      local out = {}
      for k, v in pairs(value) do
        if type(k) == 'string' or math.type(k) == 'integer' then out[k] = project(v, depth + 1) end
      end
      return out
    end
    local out = project(values, 0) or {}
    out.children = nil
    return out
  end
  function hooks.enter(actor, kind, event, origin)
    local entry = {t = now() - r.t0, a = actor.path, r = json.array({})}
    if kind == 'input' then
      entry.k = classify(event, origin)
      entry.o = origin
      entry.e = event
    elseif kind == 'start' then
      entry.k, entry.m = 'start', actor.chart.id
      if actor._component then
        entry.input, entry.component = actor._recorded_input or {}, true
      elseif actor._restored then
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
  function r.stop() uninstall(hooks) end
  install(hooks)
  return r
end

---------------------------------------------------------------------------
-- Replay
---------------------------------------------------------------------------

-- Virtual scheduler for replay: a logical clock that only the replayer
-- moves, token scopes, and invokes and tasks that never run. Their
-- info.complete/info.send are called with the recorded results instead.
local function replay_scheduler(start)
  -- unlisted: replayed actors stay out of machine.actors() and never claim
  -- (or rename around) the live app's paths.
  local s = {kind = 'replay', unlisted = true, pending = {}}
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
    local ok, value = pcall(decode_plain, line)
    if not ok or type(value) ~= 'table' then fail('replay: line %d is not a JSON object', i) end
    entries[i] = value
  end
  local header = table.remove(entries, 1)
  if not header or header.format ~= FORMAT then fail('replay: the first line is not an %s header', FORMAT) end
  if header.version ~= 1 and header.version ~= VERSION then
    fail('replay: unsupported log version %s', tostring(header.version))
  end
  -- Version 1 has no type tags.
  revived_handles = 0
  if header.version >= 2 then
    for i, entry in ipairs(entries) do entries[i] = revive(entry) end
  end
  header.handles = revived_handles
  return header, entries
end

-- Strict about number subtypes (3 vs 3.0); NaN equals NaN.
local function equal(a, b)
  if type(a) == 'number' and type(b) == 'number' then
    if a ~= a and b ~= b then return true end
    return a == b and math.type(a) == math.type(b)
  end
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
local replay
-- Replay runs function actions again, so platform effects are isolated as in
-- generation (machine_paths.lua): ouro.shell, desktop, dbus, files, ... are
-- inert while it runs, and a replay never touches the desktop.
function M.replay(source, options)
  local restore = M._isolate_effects and M._isolate_effects() or function() end
  local results = table.pack(pcall(replay, source, options))
  restore()
  if not results[1] then error(results[2], 0) end
  return table.unpack(results, 2, results.n)
end

replay = function(source, options)
  options = options or {}
  local header, entries = decode_lines(source)
  local chart_for = options.charts or charts
  local t0 = header.t0 or 0
  local observed, observed_lines = {}, {}
  local scheduler, recorder, roots, released
  local report = {format = 'ouro.machine.replay', ok = true, entries = #entries, compared = 0,
    handles = header.handles}
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
      observed[#observed + 1] = decode(line)
    end, {scheduler = scheduler, t0 = t0, header = false})
  end

  -- The replay's own roots and their children, newest first: finished
  -- actors leave machine.actors() but may still get a stop.
  -- Component ids hold '/' (instance paths), so match roots by prefix.
  local function actor_at(path)
    for i = #(roots or {}), 1, -1 do
      local actor = roots[i]
      local rest
      if path == actor.path then rest = ''
      elseif path:sub(1, #actor.path + 1) == actor.path .. '/' then rest = path:sub(#actor.path + 2) end
      if rest and actor._status ~= 'stopped' then
        for id in rest:gmatch('[^/]+') do
          actor = actor._children[id]
          if not actor then break end
        end
        if actor then return actor end
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
      if entry.component then actor._component, actor._recorded_input = true, entry.input end
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
  if (report.handles or 0) > 0 then
    out[#out + 1] = string.format('note: %d recorded values were native handles ({"$h": type}); '
      .. 'replay passed opaque markers in their place', report.handles)
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
