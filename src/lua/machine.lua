local ouro, view, raw, scope_open, scope_spawn, scope_close, scope_alive, atomic_call,
  waiter_new, waiter_park, waiter_wake, waiter_waiting, tracked_view, signal_release, is_tracked = ...
is_tracked = is_tracked or function() return false end
-- Frees a hidden signal's slot at once (reads keep the final value).
local release_signal = signal_release or function() end
-- Guards, assigns, expressions and function actions run as native atomic
-- sections: waiting, spawning or exiting inside them raises YieldInAction.
local atomic = atomic_call or function(_, fn, ...) return fn(...) end

-- Statechart prototype (design/statecharts.md). A chart is compiled once into
-- nodes with stable dotted IDs. `transition` is a pure macrostep: it returns
-- the next immutable snapshot, the effects to run after commit, and an
-- inspection record. Actors own one ouro.signal holding the snapshot, run the
-- effects, and schedule `after` timers and `invoke` work on a scheduler.

local M = {}
-- machine.wait_for wake codes (the native waiter reports -1 when canceled).
local WAKE_MATCH, WAKE_TIMEOUT, WAKE_ENDED, WAKE_ERROR = 1, 2, 3, 4
local unset = {}
M.unset = unset
local MAX_MICROSTEPS = 1000

local function fail(message, ...)
  error(select('#', ...) > 0 and string.format(message, ...) or message, 0)
end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function is_array(t)
  return type(t) == 'table' and t[1] ~= nil
end

-- JSON values from platform APIs (ouro.json.null, arrays marked with
-- ouro.json.array) survive copies: null passes through, and an empty table
-- that encodes as [] is marked again (non-empty sequences encode as arrays).
local json = ouro.json
local function is_json_null(value) return json ~= nil and value == json.null end
local function keep_array_mark(source, copy_of)
  if json and next(copy_of) == nil then
    local ok, text = pcall(json.encode, source)
    if ok and text == '[]' then json.array(copy_of) end
  end
  return copy_of
end

-- Deep, serializable copy. Views are unwrapped; functions and cycles fail.
local function plain(value, seen)
  value = raw(value)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' or kind == 'number' or kind == 'string' then return value end
  if is_json_null(value) then return value end
  if kind ~= 'table' then fail('machine value is not serializable: %s', kind) end
  seen = seen or {}
  if seen[value] then fail('machine value contains a cycle') end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do
    local key = raw(k)
    if type(key) ~= 'string' and math.type(key) ~= 'integer' then fail('machine table keys must be strings or integers') end
    out[key] = plain(v, seen)
  end
  seen[value] = nil
  return keep_array_mark(value, out)
end
-- Only the first argument: machine.plain(f()) must not pass extra returns
-- as the internal cycle set.
M.plain = function(value) return plain(value) end

-- Native handles (and functions) have no plain form. Inspection, records and
-- recordings show them as an opaque marker {"$h": "<type>"}: the metatable's
-- __name when there is one (e.g. "ouro.dbus.connection"), else the Lua type.
local get_metatable = getmetatable
local function handle_type(value)
  local kind = type(value)
  if kind == 'userdata' and get_metatable then
    local ok, mt = pcall(get_metatable, value)
    if ok and type(mt) == 'table' and type(mt.__name) == 'string' then return mt.__name end
  end
  return kind
end
local function opaque(value) return {['$h'] = handle_type(value)} end

-- Like plain, but never fails: records and dev tools must survive arbitrary
-- payloads. Handles become opaque markers.
local function inspectable(value, seen)
  value = raw(value)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' or kind == 'number' or kind == 'string' or is_json_null(value) then return value end
  if kind ~= 'table' then return opaque(value) end
  seen = seen or {}
  if seen[value] then return '<cycle>' end
  seen[value] = true
  local out = {}
  for k, v in pairs(value) do
    local key = raw(k)
    if type(key) ~= 'string' and math.type(key) ~= 'integer' then key = tostring(key) end
    out[key] = inspectable(v, seen)
  end
  seen[value] = nil
  return out
end
M.raw = raw
M.inspectable = function(value) return inspectable(value) end

-- Context for inspection: transient fields (native handles a chart declares,
-- §4) are always opaque, whatever they hold.
local function inspectable_context(chart, context)
  local out = inspectable(context)
  if chart.transient and type(out) == 'table' then
    for key in pairs(chart.transient) do
      local value = raw(context)[key]
      if value ~= nil then out[key] = opaque(raw(value)) end
    end
  end
  return out
end

-- Context for persist and carry: transient fields are left out (they restore
-- as nil; re-acquire them when actor:restored()). Anything else must be
-- plain, and an error names the field.
local function persist_context(chart, context)
  context = raw(context)
  if type(context) ~= 'table' then return plain(context) end
  local out = {}
  for key, value in pairs(context) do
    if not (chart.transient and chart.transient[key]) then
      local ok, copy = pcall(plain, value)
      if not ok then
        fail('context.%s: %s (declare native handles transient)', tostring(key), tostring(copy))
      end
      out[raw(key)] = copy
    end
  end
  return keep_array_mark(context, out)
end

-- Action constructors. Each returns a tagged description; nothing runs here.
local function action(kind, fields)
  fields.__action = kind
  return fields
end
function M.assign(updater)
  if type(updater) ~= 'function' and type(updater) ~= 'table' then fail('assign expects a function or table') end
  return action('assign', {updater = updater})
end
function M.raise(event) return action('raise', {event = event}) end
-- Spawn a child actor: a chart, or a one-shot task (a function, or the name
-- of one in `actors`) that runs in the owning state's scope and reports back
-- with done.actor.<id> { output } or error.actor.<id> { error }.
function M.spawn(src, options)
  options = options or {}
  if type(src) == 'table' and src.__chart then
    return action('spawn', {chart = src, id = options.id, input = options.input})
  elseif type(src) == 'function' or type(src) == 'string' then
    return action('spawn', {src = src, id = options.id, input = options.input})
  end
  fail('spawn expects a chart, a function or an actor name')
end

-- Whether a snapshot (or snapshot view) has state `id` active; use it on
-- children snapshots: machine.matches(state.children[id], 'open.io.saving').
-- Unknown ids raise when the snapshot's chart is known (charts register by
-- id when created), so typos fail loudly as with actor:matches.
-- State ids per machine id, the union over every chart created with that id
-- (a factory called twice, tests, stories, reload), so matches() never
-- rejects a state of an older chart that shares the id. Strings only.
local state_ids_by_machine = {}
function M.matches(snapshot, id)
  if snapshot == nil then return false end
  local known = state_ids_by_machine[snapshot.machine]
  if known and (id == '' or not known[id]) then fail('machine %s has no state %q', snapshot.machine, tostring(id)) end
  for _, state in ipairs(snapshot.states or {}) do
    if state == id then return true end
  end
  return false
end
function M.stop(id) return action('stop', {id = id}) end
function M.send_to(id, event) return action('send_to', {id = id, event = event}) end
function M.send_parent(event) return action('send_parent', {event = event}) end

local FIELD_TYPES = {string=true, number=true, integer=true, boolean=true, table=true, any=true}

-- Field setter: `on = { QUERY = machine.set('query', 'string') }` assigns
-- e.value to context.query and declares QUERY = { value = 'string' }, the
-- payload value widgets send.
function M.set(field, kind)
  if type(field) ~= 'string' or field == '' then fail('machine.set expects a context field name') end
  kind = kind or 'any'
  if not FIELD_TYPES[kind] then fail('machine.set type must be one of string, number, integer, boolean, table, any') end
  return {__set = field, kind = kind}
end

local function normalize_event(event)
  if type(event) == 'string' then return {type = event} end
  if type(event) ~= 'table' or type(event.type) ~= 'string' or event.type == '' then
    fail('machine events are strings or tables with a string type')
  end
  return copy(event)
end

-- Runtime events use reserved lowercase dotted prefixes. Charts may handle
-- them in `on` (e.g. ['surface.closed.main'], ['done.actor.*']) but never
-- declare or send them; the runtime delivers them with actor:deliver.
M.reserved_prefixes = {'after.', 'done.', 'error.', 'ouro.', 'surface.'}
local function internal_type(name)
  for _, prefix in ipairs(M.reserved_prefixes) do
    if name:sub(1, #prefix) == prefix then return true end
  end
  return false
end

-- Strict mode raises on undeclared events (typos fail loudly); otherwise
-- send returns false, 'undeclared'. The host is expected to relax it
-- outside development.
M.strict = true

---------------------------------------------------------------------------
-- Compilation
---------------------------------------------------------------------------

local STATE_KEYS = {type=true, initial=true, order=true, states=true, on=true, always=true, after=true, invoke=true,
  entry=true, exit=true, on_done=true, tags=true, description=true, output=true}
local ROOT_KEYS = {id=true, context=true, guards=true, actions=true, actors=true, events=true, transient=true, delays=true}
local TRANSITION_KEYS = {target=true, guard=true, actions=true, reenter=true, description=true}
local INVOKE_KEYS = {id=true, src=true, input=true, on_done=true, on_error=true}
local function is_descendant(a, b)
  local p = a.parent
  while p do
    if p == b then return true end
    p = p.parent
  end
  return false
end

-- The longest `after` delay, about 24.8 days (2^31 - 1 ms, as in browsers).
M.max_delay_ms = 2147483647

local function compile(def)
  if type(def) ~= 'table' then fail('machine.create expects a table') end
  if type(def.id) ~= 'string' or not def.id:match('^[%a_][%w_%-]*$') then fail('machine id must be an identifier') end
  local chart = {__chart = true, id = def.id, nodes = {}, by_id = {}, transitions = {}, def = def, child_charts = {}}
  local guards, actions, actors = def.guards or {}, def.actions or {}, def.actors or {}

  local function where(node) return node.id == '' and def.id or def.id .. '.' .. node.id end

  local function build(sdef, key, parent)
    if type(sdef) ~= 'table' then fail('state %s must be a table', key) end
    for k in pairs(sdef) do
      if not STATE_KEYS[k] and not (parent == nil and ROOT_KEYS[k]) then
        fail('unknown field %q in state %s', tostring(k), parent and key or def.id)
      end
    end
    local node = {key = key, parent = parent, children = {}, def = sdef, on = {}, always = {}, after = {}, invokes = {},
      tags = {}, depth = parent and parent.depth + 1 or 0}
    node.id = parent == nil and '' or (parent.id == '' and key or parent.id .. '.' .. key)
    if sdef.type == 'parallel' then node.type = 'parallel'
    elseif sdef.type == 'final' then node.type = 'final'
    elseif sdef.type ~= nil then fail('invalid type %q in state %s', tostring(sdef.type), where(node))
    elseif sdef.states then node.type = 'compound'
    else node.type = 'atomic' end
    if node.type == 'final' then
      for _, k in ipairs({'states', 'on', 'always', 'after', 'invoke', 'initial', 'on_done'}) do
        if sdef[k] ~= nil then fail('final state %s cannot declare %s', where(node), k) end
      end
      if parent == nil then fail('the root state cannot be final') end
    elseif sdef.output ~= nil then fail('only final states declare output (%s)', where(node)) end
    if (node.type == 'compound' or node.type == 'parallel') and (type(sdef.states) ~= 'table' or next(sdef.states) == nil) then
      fail('state %s needs child states', where(node))
    end
    node.order = #chart.nodes + 1
    chart.nodes[node.order] = node
    chart.by_id[node.id] = node
    if sdef.order ~= nil and node.type ~= 'parallel' then
      fail('only parallel states declare order (%s)', where(node))
    end
    if sdef.states then
      local keys = {}
      for k in pairs(sdef.states) do
        if type(k) ~= 'string' or not k:match('^[%a_][%w_%-]*$') then
          fail('state key %q in %s must be an identifier', tostring(k), where(node))
        end
        keys[#keys + 1] = k
      end
      if sdef.order ~= nil then
        -- Lua tables have no insertion order, so parallel regions may name
        -- theirs: it fixes entry, exit and conflict resolution.
        if type(sdef.order) ~= 'table' then fail('order of %s must be a list of region keys', where(node)) end
        local seen, count = {}, 0
        for k in pairs(sdef.order) do
          if math.type(k) ~= 'integer' then fail('order of %s must be a list of region keys', where(node)) end
          count = count + 1
        end
        if count ~= #sdef.order then fail('order of %s must be a list without holes', where(node)) end
        for _, k in ipairs(sdef.order) do
          if type(k) ~= 'string' or sdef.states[k] == nil then fail('order of %s names unknown region %q', where(node), tostring(k)) end
          if seen[k] then fail('order of %s lists region %q twice', where(node), k) end
          seen[k] = true
        end
        for _, k in ipairs(keys) do
          if not seen[k] then fail('order of %s is missing region %q', where(node), k) end
        end
        keys = sdef.order
      else
        table.sort(keys) -- Without order, document order sorts keys.
      end
      for _, k in ipairs(keys) do node.children[#node.children + 1] = build(sdef.states[k], k, node) end
    end
    if node.type == 'compound' then
      if type(sdef.initial) ~= 'string' then fail('compound state %s needs initial', where(node)) end
      for _, child in ipairs(node.children) do if child.key == sdef.initial then node.initial = child end end
      if not node.initial then fail('initial %q of %s is not a child state', sdef.initial, where(node)) end
    elseif sdef.initial ~= nil then fail('only compound states declare initial (%s)', where(node)) end
    if sdef.tags then for _, tag in ipairs(sdef.tags) do node.tags[tag] = true end end
    return node
  end
  chart.root = build(def, def.id, nil)

  local function resolve(source, target)
    if type(target) ~= 'string' then fail('transition target in %s must be a string', where(source)) end
    local id
    if target:sub(1, 1) == '#' then id = target:sub(2)
    elseif target:sub(1, 1) == '.' then id = source.id == '' and target:sub(2) or source.id .. target
    elseif source.parent == nil then id = target
    else id = source.parent.id == '' and target or source.parent.id .. '.' .. target end
    local node = chart.by_id[id]
    if not node or node == chart.root then fail('unknown target %q from %s', target, where(source)) end
    return node
  end

  local function compile_actions(spec, context, list, label)
    list = list or {}
    if spec == nil then return list end
    local items = (type(spec) == 'table' and not spec.__action) and spec or {spec}
    for i = 1, #items do
      local item, name = items[i], label
      if type(item) == 'string' then
        name = item
        item = actions[name]
        if item == nil then fail('unknown action %q in %s', name, context) end
      end
      if type(item) == 'function' then
        list[#list + 1] = {kind = 'fn', fn = item, name = name or 'function',
          label = "action '" .. (name or 'function') .. "' (" .. context .. ')'}
      elseif type(item) == 'table' and item.__action then
        local a = copy(item); a.kind = item.__action; a.name = name or item.name or item.__action
        a.label = a.kind .. " '" .. a.name .. "' (" .. context .. ')'
        if a.kind == 'spawn' and a.chart then chart.child_charts[a.chart.id] = a.chart end
        if a.kind == 'spawn' and a.src ~= nil then
          if type(a.src) == 'string' then
            a.src_name = a.src
            a.src = actors[a.src_name]
            if type(a.src) ~= 'function' then fail('unknown actor %q in %s', a.src_name, context) end
          else a.src_name = 'function' end
        end
        list[#list + 1] = a
      elseif type(item) == 'table' and name and is_array(item) then
        compile_actions(item, context, list, name) -- A named list of actions.
      else fail('invalid action in %s', context) end
    end
    return list
  end

  local function compile_guard(guard, context)
    if guard == nil then return nil end
    if type(guard) == 'string' then
      local fn = guards[guard]
      if type(fn) ~= 'function' then fail('unknown guard %q in %s', guard, context) end
      return fn, guard
    end
    if type(guard) ~= 'function' then fail('guard in %s must be a name or function', context) end
    return guard, 'function'
  end

  local setters = {}
  local function add_transitions(node, event, spec, kind, into)
    if spec == nil then return end
    local list
    if type(spec) == 'table' and spec.__set then
      if not event or internal_type(event) or event:find('*', 1, true) then
        fail('machine.set needs a plain event name (%s)', where(node))
      end
      if setters[event] and setters[event] ~= spec.kind then fail('event %s is set with two value types', event) end
      setters[event] = spec.kind
      local field = spec.__set
      local setter = M.assign {[field] = function(_, e) return e.value end}
      setter.name = 'set ' .. field
      list = {{actions = setter}}
    elseif type(spec) == 'string' then list = {{target = spec}}
    elseif type(spec) == 'table' and is_array(spec) then list = spec
    elseif type(spec) == 'table' then list = {spec}
    else fail('invalid transition for %s in %s', tostring(event), where(node)) end
    for _, entry in ipairs(list) do
      local item = type(entry) == 'string' and {target = entry} or entry
      if type(item) ~= 'table' then fail('invalid transition for %s in %s', tostring(event), where(node)) end
      for k in pairs(item) do
        if not TRANSITION_KEYS[k] then fail('unknown transition field %q in %s', tostring(k), where(node)) end
      end
      local context = where(node) .. (event and (' on ' .. event) or ' always')
      local t = {source = node, event = event, kind = kind, reenter = item.reenter == true,
        actions = compile_actions(item.actions, context), description = item.description}
      t.guard, t.guard_name = compile_guard(item.guard, context)
      if t.guard then t.guard_label = "guard '" .. t.guard_name .. "' (" .. context .. ')' end
      if item.target ~= nil then
        t.targets = {}
        local targets = type(item.target) == 'table' and item.target or {item.target}
        for i = 1, #targets do t.targets[i] = resolve(node, targets[i]) end
      end
      t.index = #chart.transitions + 1
      chart.transitions[t.index] = t
      into[#into + 1] = t
    end
  end

  local function on(node, event, spec, kind)
    node.on[event] = node.on[event] or {}
    add_transitions(node, event, spec, kind, node.on[event])
  end

  for _, node in ipairs(chart.nodes) do
    local sdef = node.def
    node.entry = compile_actions(sdef.entry, where(node) .. ' entry')
    node.exit = compile_actions(sdef.exit, where(node) .. ' exit')
    if sdef.output ~= nil and type(sdef.output) ~= 'function' then fail('output of %s must be a function', where(node)) end
    node.output = sdef.output
    if sdef.on then
      local names = {}
      for name in pairs(sdef.on) do
        if type(name) ~= 'string' or name == '' or (name:find('*', 1, true) and name ~= '*' and not name:match('^[^*]+%.%*$')) then
          fail('invalid event descriptor %q in %s', tostring(name), where(node))
        end
        names[#names + 1] = name
      end
      table.sort(names)
      for _, name in ipairs(names) do on(node, name, sdef.on[name], 'event') end
    end
    add_transitions(node, nil, sdef.always, 'always', node.always)
    if sdef.after then
      -- Keys are integer ms, or names of chart `delays` (XState-style), whose
      -- value is ms or function(context, event) -> ms, evaluated on entry.
      local delays = {}
      for delay in pairs(sdef.after) do
        if type(delay) == 'string' then
          local named = def.delays and def.delays[delay]
          if named == nil then fail('after delay %q in %s is not in the chart\'s delays', delay, where(node)) end
        elseif math.type(delay) ~= 'integer' or delay < 0 or delay > M.max_delay_ms then
          fail('after delays in %s must be integers from 0 to %d ms, or delay names', where(node), M.max_delay_ms)
        end
        delays[#delays + 1] = delay
      end
      table.sort(delays, function(a, b)
        if type(a) ~= type(b) then return type(a) == 'number' end
        return a < b
      end)
      for _, delay in ipairs(delays) do
        local event = 'after.' .. delay .. '.' .. (node.id == '' and def.id or node.id)
        local entry = {delay = delay, event = event}
        if type(delay) == 'string' then
          local named = def.delays[delay]
          if type(named) == 'function' then entry.fn, entry.label = named, 'delay ' .. delay
          else entry.ms = named end
        end
        node.after[#node.after + 1] = entry
        on(node, event, sdef.after[delay], 'after')
      end
    end
    if sdef.invoke then
      local list = (type(sdef.invoke) == 'table' and is_array(sdef.invoke)) and sdef.invoke or {sdef.invoke}
      for i, inv in ipairs(list) do
        if type(inv) ~= 'table' then fail('invoke in %s must be a table', where(node)) end
        for k in pairs(inv) do
          if not INVOKE_KEYS[k] then fail('unknown invoke field %q in %s', tostring(k), where(node)) end
        end
        local src, src_name = inv.src, nil
        if type(src) == 'string' then
          src_name = src
          src = actors[src_name]
          if type(src) ~= 'function' then fail('unknown actor %q in %s', src_name, where(node)) end
        elseif type(src) ~= 'function' then fail('invoke src in %s must be a name or function', where(node))
        else src_name = 'function' end
        local id = inv.id or (src_name ~= 'function' and src_name) or ((node.id == '' and def.id or node.id) .. ':' .. i)
        if type(id) ~= 'string' then fail('invoke id in %s must be a string', where(node)) end
        if inv.input ~= nil and type(inv.input) ~= 'function' then fail('invoke input in %s must be a function', where(node)) end
        node.invokes[#node.invokes + 1] = {id = id, src = src, src_name = src_name, input = inv.input}
        on(node, 'done.invoke.' .. id, inv.on_done, 'invoke.done')
        on(node, 'error.invoke.' .. id, inv.on_error, 'invoke.error')
      end
    end
    if sdef.on_done ~= nil then
      if node == chart.root then
        fail('the root cannot declare on_done: a finished machine is done (status, wait_for, done.actor to its parent)')
      end
      if node.type ~= 'compound' and node.type ~= 'parallel' then fail('on_done needs a compound or parallel state (%s)', where(node)) end
      on(node, 'done.state.' .. (node.id == '' and def.id or node.id), sdef.on_done, 'done')
    end
  end

  if def.delays ~= nil then
    if type(def.delays) ~= 'table' then fail('delays must be a table of names') end
    for name, value in pairs(def.delays) do
      if type(name) ~= 'string' or not name:match('^[%a_][%w_]*$') then fail('delay names must be identifiers') end
      if type(value) ~= 'function' and (math.type(value) ~= 'integer' or value < 0 or value > M.max_delay_ms) then
        fail('delay %q must be integer ms from 0 to %d or a function', name, M.max_delay_ms)
      end
    end
  end
  if def.transient ~= nil then
    if type(def.transient) ~= 'table' then fail('transient must be a list of context field names') end
    chart.transient = {}
    for _, name in ipairs(def.transient) do
      if type(name) ~= 'string' or name == '' then fail('transient must be a list of context field names') end
      chart.transient[name] = true
    end
  end
  if def.events ~= nil then
    if type(def.events) ~= 'table' then fail('events must be a table') end
    chart.events = {}
    for name, schema in pairs(def.events) do
      if type(name) ~= 'string' or internal_type(name) then fail('invalid external event name %q', tostring(name)) end
      local fields = {}
      for field, kind in pairs(schema) do
        local base, optional = tostring(kind):match('^(%a+)(%??)$')
        if type(field) ~= 'string' or field == 'type' or not FIELD_TYPES[base or ''] then
          fail('invalid schema field %q for event %s', tostring(field), name)
        end
        fields[field] = {type = base, optional = optional == '?'}
      end
      chart.events[name] = fields
    end
  end
  for name, kind in pairs(setters) do
    chart.events = chart.events or {}
    if not chart.events[name] then chart.events[name] = {value = {type = kind, optional = false}} end
  end
  -- Declared events: explicit schemas, setters, and every plain event name a
  -- state handles. Anything else is a typo (or another actor's event).
  chart.declared = {}
  for name in pairs(chart.events or {}) do chart.declared[name] = true end
  for _, node in ipairs(chart.nodes) do
    for name in pairs(node.on) do
      if not internal_type(name) and not name:find('*', 1, true) then chart.declared[name] = true end
    end
  end
  return chart
end

-- True when the event may be sent; false (non-strict) for undeclared ones.
local function validate_event(chart, event)
  if internal_type(event.type) then return true end
  if not chart.declared[event.type] then
    if M.strict then fail('UnknownEvent: %s does not accept %q', chart.id, event.type) end
    return false
  end
  local fields = chart.events and chart.events[event.type]
  if not fields then return true end
  for name, value in pairs(event) do
    if name ~= 'type' then
      local field = fields[name]
      if not field then fail('InvalidEvent: %s.%s is not declared', event.type, tostring(name)) end
    end
  end
  for name, field in pairs(fields) do
    local value = event[name]
    if value == nil then
      if not field.optional then fail('InvalidEvent: %s requires %s', event.type, name) end
    elseif field.type == 'integer' then
      -- Like MCP's numeric rule: an integral float (1.0, from a spinbox or
      -- slider) is an integer.
      local integer = type(value) == 'number' and math.tointeger(value) or nil
      if integer == nil then fail('InvalidEvent: %s.%s must be integer', event.type, name) end
      event[name] = integer
    elseif field.type == 'table' then
      -- Context reads are read-only views; a view of a table is that table.
      local target = raw(value)
      if type(target) ~= 'table' then fail('InvalidEvent: %s.%s must be table', event.type, name) end
      event[name] = target
    elseif field.type ~= 'any' then
      if type(value) ~= field.type then fail('InvalidEvent: %s.%s must be %s', event.type, name, field.type) end
    end
  end
  return true
end

---------------------------------------------------------------------------
-- Static graph export
---------------------------------------------------------------------------

local function action_names(list)
  local names = {}
  for i, a in ipairs(list) do names[i] = a.name end
  return names
end

-- The ms of an `after` entry: its integer key, a constant named delay, or the
-- named delay function's result for this entry (validated like a constant).
local function delay_ms(a, context, event, meta)
  if a.fn == nil then return a.ms or a.delay end
  local ms = atomic(a.label, a.fn, context, event, meta)
  if math.type(ms) == 'float' then ms = math.tointeger(ms) end
  if math.type(ms) ~= 'integer' or ms < 0 or ms > M.max_delay_ms then
    fail('%s must return integer ms from 0 to %d, got %s', a.label, M.max_delay_ms, tostring(ms))
  end
  return ms
end

local function graph(chart)
  local g = {format = 'ouro.machine.graph', version = 1, id = chart.id, root = '', states = {}, transitions = {}, events = {}}
  for i, node in ipairs(chart.nodes) do
    local children = {}
    for j, child in ipairs(node.children) do children[j] = child.id end
    local after, invoke, tags = {}, {}, {}
    for j, a in ipairs(node.after) do after[j] = {delay = a.delay, event = a.event, ms = a.ms or (not a.fn and a.delay or nil)} end
    for j, inv in ipairs(node.invokes) do invoke[j] = {id = inv.id, src = inv.src_name} end
    for tag in pairs(node.tags) do tags[#tags + 1] = tag end
    table.sort(tags)
    g.states[i] = {id = node.id, key = node.key, type = node.type, parent = node.parent and node.parent.id,
      depth = node.depth, children = children, initial = node.initial and node.initial.id,
      final = node.type == 'final', after = after, invoke = invoke, entry = action_names(node.entry),
      exit = action_names(node.exit), tags = tags, description = node.def.description}
  end
  for i, t in ipairs(chart.transitions) do
    local targets
    if t.targets then
      targets = {}
      for j, n in ipairs(t.targets) do targets[j] = n.id end
    end
    g.transitions[i] = {index = i, source = t.source.id, event = t.event, kind = t.kind, targets = targets,
      guard = t.guard_name, guarded = t.guard ~= nil, actions = action_names(t.actions), reenter = t.reenter,
      description = t.description}
  end
  local names = {}
  for name in pairs(chart.declared) do names[#names + 1] = name end
  table.sort(names)
  for i, name in ipairs(names) do
    local fields = {}
    for field, spec in pairs(chart.events and chart.events[name] or {}) do fields[field] = spec.type .. (spec.optional and '?' or '') end
    g.events[i] = {type = name, fields = fields, schema = chart.events ~= nil and chart.events[name] ~= nil}
  end
  return g
end

---------------------------------------------------------------------------
-- Pure macrostep (SCXML algorithm, without history)
---------------------------------------------------------------------------

local function by_order(a, b) return a.order < b.order end
local function by_reverse_order(a, b) return a.order > b.order end

local function sorted(set, compare)
  local list = {}
  for node in pairs(set) do list[#list + 1] = node end
  table.sort(list, compare or by_order)
  return list
end

local function active_set(chart, snapshot)
  local active = {[chart.root] = true}
  for _, id in ipairs(snapshot.states) do
    local node = chart.by_id[id]
    if not node then fail('snapshot state %q is not in machine %s', id, chart.id) end
    active[node] = true
  end
  return active
end

local function is_atomic(node) return node.type == 'atomic' or node.type == 'final' end

-- Event descriptors: the exact type, then dotted prefixes ('done.actor.*'),
-- then '*'. More specific descriptors are tried first within a state.
local function descriptors(event_type)
  local list = {event_type}
  local prefix = event_type
  while true do
    prefix = prefix:match('^(.*)%.[^.]*$')
    if not prefix then break end
    list[#list + 1] = prefix .. '.*'
  end
  list[#list + 1] = '*'
  return list
end

local function select_transitions(chart, active, event_type, guard_args)
  local enabled, seen = {}, {}
  local names = event_type and descriptors(event_type)
  for _, state in ipairs(sorted(active)) do
    if is_atomic(state) then
      local node, found = state, false
      while node and not found do
        local lists = names and {} or {node.always}
        if names then for _, name in ipairs(names) do lists[#lists + 1] = node.on[name] end end
        for _, list in ipairs(lists) do
          for _, t in ipairs(list) do
            if t.guard == nil or atomic(t.guard_label, t.guard, guard_args()) then
              if not seen[t] then seen[t] = true; enabled[#enabled + 1] = t end
              found = true
              break
            end
          end
          if found then break end
        end
        node = node.parent
      end
    end
  end
  return enabled
end

-- Probing guards without a payload (the inspector's valves, accepted()):
-- the event is a tracked view that notes reads of fields a real event must
-- carry: a required schema field, or any field of an event without a schema
-- (its payload is unknown). A guard that reads one cannot be decided by the
-- probe: it is payload-dependent, not failed, whatever it returned or raised.
-- Optional fields read as nil, as in a real event that omits them.
local function needs_payload(chart, event_type, key)
  if internal_type(event_type) then return false end
  local fields = chart.events and chart.events[event_type]
  if fields == nil then return key == nil or key ~= 'type' end
  if key == nil then return next(fields) ~= nil end
  local field = fields[key]
  return field ~= nil and not field.optional
end
local function probe_guard(chart, t, context, event, meta)
  local read = false
  local probe = tracked_view and tracked_view(event, function(e, key)
    if needs_payload(chart, e.type, key) then read = true end
    if key ~= nil then return view(e[key]) end
  end) or view(event)
  local ok, result = pcall(atomic, t.guard_label, t.guard, context, probe, meta)
  if read then return 'payload' end
  if not ok then return 'error', tostring(result) end
  return result and 'passed' or 'failed'
end

local function lcca(chart, nodes)
  local first = nodes[1]
  local anc = first.parent
  while anc do
    if anc.type == 'compound' or anc == chart.root then
      local all = true
      for i = 2, #nodes do if not is_descendant(nodes[i], anc) then all = false; break end end
      if all then return anc end
    end
    anc = anc.parent
  end
  return chart.root
end

local function transition_domain(chart, t)
  if not t.targets then return nil end
  if t.source == chart.root then
    -- The root is always active; transitions from it act inside it.
    if not t.reenter then return chart.root end
  end
  -- XState v5: unless reenter, a transition whose targets are the source or
  -- its descendants acts inside the source (compound or parallel), which is
  -- neither exited nor re-entered.
  if not t.reenter then
    local all = true
    for _, target in ipairs(t.targets) do
      if target ~= t.source and not is_descendant(target, t.source) then all = false; break end
    end
    if all then return t.source end
  end
  local nodes = {t.source}
  for _, target in ipairs(t.targets) do nodes[#nodes + 1] = target end
  return lcca(chart, nodes)
end

local function exit_set(chart, active, transitions)
  local set = {}
  for _, t in ipairs(transitions) do
    local domain = transition_domain(chart, t)
    if domain then
      for node in pairs(active) do
        if is_descendant(node, domain) then set[node] = true end
      end
    end
  end
  return set
end

local function remove_conflicts(chart, active, enabled)
  local filtered = {}
  for _, t1 in ipairs(enabled) do
    local preempted, remove = false, {}
    local exit1 = exit_set(chart, active, {t1})
    for _, t2 in ipairs(filtered) do
      local exit2 = exit_set(chart, active, {t2})
      local intersects = false
      for node in pairs(exit1) do if exit2[node] then intersects = true; break end end
      if intersects then
        if is_descendant(t1.source, t2.source) then remove[t2] = true
        else preempted = true; break end
      end
    end
    if not preempted then
      local kept = {}
      for _, t in ipairs(filtered) do if not remove[t] then kept[#kept + 1] = t end end
      kept[#kept + 1] = t1
      filtered = kept
    end
  end
  return filtered
end

local function in_final_state(active, node)
  if node.type == 'compound' then
    for _, child in ipairs(node.children) do
      if active[child] and child.type == 'final' then return true end
    end
    return false
  elseif node.type == 'parallel' then
    for _, child in ipairs(node.children) do
      if not in_final_state(active, child) then return false end
    end
    return true
  end
  return false
end

local function new_record(event)
  return {kind = 'transition', event = event, handled = false, rejected = false, microsteps = {},
    exited = {}, entered = {}, timers = {}, invokes = {}, children = {}, actions = {}, sent = {}}
end

-- record.error: {code, message}. The code is the message's `Name:` prefix
-- (YieldInAction, InvalidEvent, ...), after any `chunk:line: ` position, or
-- 'Error'.
local function error_info(err)
  local message = tostring(err)
  local code = message:match('^(%u%w+):') or message:match('^[^%s:]+:%d+: (%u%w+):')
  return {code = code or 'Error', message = message}
end

local function apply_assign(m, a)
  local updates
  if type(a.updater) == 'function' then
    updates = atomic(a.label, a.updater, m.view(), m.event_view, m.meta())
    if updates == nil then return end
    updates = raw(updates)
    if type(updates) ~= 'table' then fail('assign function must return a table of updates') end
  else
    updates = {}
    for k, v in pairs(a.updater) do
      if type(v) == 'function' then updates[k] = atomic(a.label, v, m.view(), m.event_view, m.meta()) else updates[k] = v end
    end
  end
  local context = copy(m.context)
  for k, v in pairs(updates) do
    if v == unset then context[k] = nil else context[k] = raw(v) end
  end
  m.context = context
  m.context_view = nil
end

local function evaluate(value, m, label)
  if type(value) == 'function' then return raw(atomic(label, value, m.view(), m.event_view, m.meta())) end
  return value
end

-- Children are an array of ids in spawn order plus id -> child snapshot.
-- Each spawn also records a token under entries['@' .. id], so a late
-- done.actor/error.actor from an earlier child with the same id is stale.
local function child_token_key(id) return '@' .. id end

local function remove_child(m, id)
  for i, existing in ipairs(m.children) do
    if existing == id then
      table.remove(m.children, i)
      m.children[id] = nil
      m.entries[child_token_key(id)] = nil
      return i
    end
  end
end

local function has_child(children, id)
  if children[id] ~= nil then return true end
  for _, existing in ipairs(children) do if existing == id then return true end end
  return false
end

-- `owner` is the state whose scope owns spawned tasks: the transition's
-- domain (or source), the entered state, or an exiting state's parent.
local function run_actions(m, list, owner)
  for _, a in ipairs(list) do
    m.record.actions[#m.record.actions + 1] = a.name
    if a.kind == 'assign' then apply_assign(m, a)
    elseif a.kind == 'raise' then m.internal[#m.internal + 1] = normalize_event(evaluate(a.event, m, a.label))
    elseif a.kind == 'fn' then
      m.effects[#m.effects + 1] = {kind = 'action', fn = a.fn, label = a.label, context = m.context, event = m.event}
    elseif a.kind == 'spawn' then
      local id = evaluate(a.id, m, a.label)
      if id == nil then
        -- The serial persists across restore; skipping taken ids also covers
        -- snapshots persisted before it did.
        local prefix = a.chart and a.chart.id or (a.src_name ~= 'function' and a.src_name) or 'task'
        repeat
          m.serial = m.serial + 1
          id = prefix .. '.' .. m.serial
        until not has_child(m.children, id)
      end
      if type(id) ~= 'string' or id == '' or id:find('/', 1, true) then fail('spawned child id must be a nonempty string without /') end
      for _, existing in ipairs(m.children) do
        if existing == id then fail('child %q already exists in %s', id, m.chart.id) end
      end
      m.children[#m.children + 1] = id
      m.serial = m.serial + 1
      local token = m.serial
      m.entries[child_token_key(id)] = token
      local input = evaluate(a.input, m, a.label)
      if a.chart then
        m.effects[#m.effects + 1] = {kind = 'spawn', id = id, chart = a.chart, input = input, child_token = token}
      else
        m.children[id] = {status = 'active', src = a.src_name, owner = owner.id}
        m.effects[#m.effects + 1] = {kind = 'spawn_task', id = id, src = a.src, src_name = a.src_name, input = input, child_token = token,
          owner = owner.id, token = m.entries[owner.id]}
      end
    elseif a.kind == 'stop' then
      local id = evaluate(a.id, m, a.label)
      if remove_child(m, id) then m.effects[#m.effects + 1] = {kind = 'stop', id = id} end
    elseif a.kind == 'send_to' then
      m.effects[#m.effects + 1] = {kind = 'send_to', id = evaluate(a.id, m, a.label), event = normalize_event(evaluate(a.event, m, a.label))}
    elseif a.kind == 'send_parent' then
      m.effects[#m.effects + 1] = {kind = 'send_parent', event = normalize_event(evaluate(a.event, m, a.label))}
    else fail('unknown action kind %s', tostring(a.kind)) end
  end
end

-- On exit: cancel started timers and invokes, and close the entry's scope
-- (which also holds tasks spawned by actions this state owned).
local function cancel_started(m, node)
  local token = m.entries[node.id]
  if m.pending_start[node] then
    m.pending_start[node] = nil
  else
    local started = m.started_tokens[node.id]
    if started and (#node.after > 0 or #node.invokes > 0) then
      for _, a in ipairs(node.after) do
        m.effects[#m.effects + 1] = {kind = 'timer_cancel', state = node.id, delay = a.delay, event = a.event, token = started}
      end
      for _, inv in ipairs(node.invokes) do
        m.effects[#m.effects + 1] = {kind = 'invoke_cancel', state = node.id, id = inv.id, src = inv.src_name, token = started}
      end
    end
    m.started_tokens[node.id] = nil
  end
  -- Tasks this state owned are canceled with its scope; drop them now.
  local owned = {}
  for _, id in ipairs(m.children) do
    local child = m.children[id]
    if type(child) == 'table' and child.owner == node.id and child.machine == nil then owned[#owned + 1] = id end
  end
  for _, id in ipairs(owned) do
    remove_child(m, id)
    m.effects[#m.effects + 1] = {kind = 'stop', id = id}
  end
  if token then m.effects[#m.effects + 1] = {kind = 'scope_close', state = node.id, token = token} end
end

local function enter_states(m, transitions, step)
  local chart, active = m.chart, m.active
  local to_enter = {}
  local add_descendants, add_ancestors
  local function any_descendant(child)
    for node in pairs(to_enter) do if is_descendant(node, child) then return true end end
    return false
  end
  add_descendants = function(node)
    to_enter[node] = true
    if node.type == 'compound' then
      add_descendants(node.initial)
      add_ancestors(node.initial, node)
    elseif node.type == 'parallel' then
      for _, child in ipairs(node.children) do
        if not any_descendant(child) then add_descendants(child) end
      end
    end
  end
  add_ancestors = function(node, ancestor)
    local anc = node.parent
    while anc and anc ~= ancestor do
      to_enter[anc] = true
      if anc.type == 'parallel' then
        for _, child in ipairs(anc.children) do
          if not any_descendant(child) then add_descendants(child) end
        end
      end
      anc = anc.parent
    end
  end
  for _, t in ipairs(transitions) do
    if t.targets then
      for _, target in ipairs(t.targets) do add_descendants(target) end
      local domain = transition_domain(chart, t)
      for _, target in ipairs(t.targets) do add_ancestors(target, domain) end
      -- Only a parallel root can be a domain; its exited regions re-enter.
      if domain.type == 'parallel' then
        for _, child in ipairs(domain.children) do
          if not to_enter[child] and not any_descendant(child) then add_descendants(child) end
        end
      end
    elseif t.initial then
      add_descendants(chart.root)
    end
  end
  for _, node in ipairs(sorted(to_enter)) do
    if not active[node] then
      active[node] = true
      m.serial = m.serial + 1
      m.entries[node.id] = m.serial
      if #node.after > 0 or #node.invokes > 0 then m.pending_start[node] = true end
      if node ~= chart.root then
        step.entered[#step.entered + 1] = node.id
        m.record.entered[#m.record.entered + 1] = node.id
      end
      run_actions(m, node.entry, node)
      if node.type == 'final' then
        local parent = node.parent
        local output = node.output and raw(atomic('output of ' .. node.id, node.output, m.view(), m.event_view, m.meta()))
        if parent == chart.root then
          m.done, m.output = true, output
        else
          local done = {type = 'done.state.' .. parent.id, output = output}
          m.internal[#m.internal + 1] = done
          local grand = parent.parent
          if grand and grand.type == 'parallel' and in_final_state(active, grand) then
            if grand == chart.root then m.done = true
            else m.internal[#m.internal + 1] = {type = 'done.state.' .. grand.id} end
          end
        end
      end
    end
  end
end

local function microstep(m, transitions, event_type)
  local chart, active = m.chart, m.active
  local step = {event = event_type, transitions = {}, exited = {}, entered = {}}
  for i, t in ipairs(transitions) do
    local targets
    if t.targets then
      targets = {}
      for j, n in ipairs(t.targets) do targets[j] = n.id end
    end
    step.transitions[i] = {index = t.index, source = t.source.id, event = t.event, targets = targets, guard = t.guard_name}
  end
  local exiting = exit_set(chart, active, transitions)
  for _, node in ipairs(sorted(exiting, by_reverse_order)) do
    step.exited[#step.exited + 1] = node.id
    m.record.exited[#m.record.exited + 1] = node.id
    -- Tasks spawned by exit actions belong to the nearest ancestor that stays
    -- active after this microstep (or the root), not to an exiting state.
    local owner = node.parent
    while owner and exiting[owner] do owner = owner.parent end
    run_actions(m, node.exit, owner or chart.root)
    cancel_started(m, node)
    active[node] = nil
    m.entries[node.id] = nil
  end
  for _, t in ipairs(transitions) do
    run_actions(m, t.actions, t.targets and transition_domain(chart, t) or t.source)
  end
  enter_states(m, transitions, step)
  m.record.microsteps[#m.record.microsteps + 1] = step
  m.count = m.count + 1
  if m.count > MAX_MICROSTEPS then fail('machine %s exceeded %d microsteps (eventless loop?)', chart.id, MAX_MICROSTEPS) end
end

local function begin(chart, snapshot, event)
  local m = {chart = chart, context = snapshot.context, entries = copy(snapshot.entries), serial = snapshot.serial,
    children = copy(snapshot.children), effects = {}, internal = {}, pending_start = {}, started_tokens = copy(snapshot.entries),
    count = 0, record = new_record(event)}
  m.active = snapshot.states and active_set(chart, snapshot) or {}
  m.view = function()
    if not m.context_view then m.context_view = view(m.context) end
    return m.context_view
  end
  m.set_event = function(e) m.event, m.event_view = e, view(e) end
  -- Third argument to guards, assign and expressions: the configuration and
  -- children as of this point in the macrostep (read-only).
  m.meta = function()
    if not m.meta_value then
      m.meta_value = {
        matches = function(id)
          local node = chart.by_id[id]
          if not node or id == '' then fail('machine %s has no state %q', chart.id, tostring(id)) end
          return m.active[node] == true
        end,
        children = view(m.children),
      }
    end
    return m.meta_value
  end
  m.guard_args = function() return m.view(), m.event_view, m.meta() end
  m.set_event(event)
  return m
end

local function run_to_completion(m)
  while not m.done do
    local enabled = remove_conflicts(m.chart, m.active, select_transitions(m.chart, m.active, nil, m.guard_args))
    if #enabled == 0 then
      if #m.internal == 0 then break end
      local internal = table.remove(m.internal, 1)
      m.set_event(internal)
      enabled = remove_conflicts(m.chart, m.active, select_transitions(m.chart, m.active, internal.type, m.guard_args))
      if #enabled > 0 then microstep(m, enabled, internal.type) end
    else
      microstep(m, enabled, nil)
    end
  end
end

local function finish(m, snapshot)
  local chart = m.chart
  local status, output = snapshot.status, snapshot.output
  if m.done then
    status, output = 'done', m.output
    -- SCXML exits the remaining configuration when the machine finishes.
    for _, node in ipairs(sorted(m.active, by_reverse_order)) do
      cancel_started(m, node)
      run_actions(m, node.exit, chart.root) -- everything exits; the root owns tasks
    end
    m.effects[#m.effects + 1] = {kind = 'done', output = output}
  end
  -- Start timers and invokes only for states still active after the
  -- macrostep, in document order, like SCXML's end-of-macrostep invoke.
  for _, node in ipairs(sorted(m.pending_start)) do
    if m.active[node] then
      local token = m.entries[node.id]
      for _, a in ipairs(node.after) do
        m.effects[#m.effects + 1] = {kind = 'timer_start', state = node.id, delay = a.delay, event = a.event, token = token,
          ms = a.fn and delay_ms(a, m.view(), m.event_view, m.meta()) or a.ms or a.delay}
      end
      for _, inv in ipairs(node.invokes) do
        local input = inv.input and raw(atomic('input of invoke ' .. inv.id, inv.input, m.view(), m.event_view, m.meta()))
        m.effects[#m.effects + 1] = {kind = 'invoke_start', state = node.id, id = inv.id, src = inv.src,
          src_name = inv.src_name, input = input, token = token}
      end
    end
  end
  local states = {}
  for _, node in ipairs(sorted(m.active)) do
    if node ~= chart.root then states[#states + 1] = node.id end
  end
  local next_snapshot = {machine = chart.id, status = status, states = states, context = m.context,
    children = m.children, entries = m.entries, serial = m.serial, output = output}
  m.record.handled = true
  return next_snapshot, m.effects, m.record
end

local function initial(chart, input)
  local context = chart.def.context
  if type(context) == 'function' then context = atomic('context of ' .. chart.id, context, input) end
  if context == nil then context = {} end
  context = raw(context)
  if type(context) ~= 'table' then fail('machine context must be a table') end
  local snapshot = {machine = chart.id, status = 'active', context = copy(context), children = {}, entries = {}, serial = 0}
  local m = begin(chart, snapshot, {type = 'ouro.init', input = input})
  microstep(m, {{initial = true, source = chart.root, actions = {}}}, 'ouro.init')
  m.record.microsteps[1].transitions = {}
  run_to_completion(m)
  return finish(m, snapshot)
end

local function transition(chart, snapshot, event)
  event = normalize_event(event)
  if snapshot.status ~= 'active' then
    local record = new_record(event)
    record.rejected, record.reason = true, snapshot.status
    return snapshot, {}, record
  end
  local m = begin(chart, snapshot, event)
  local record = m.record
  local timer = event.type:sub(1, 6) == 'after.'
  local invoke_done = event.type:sub(1, 12) == 'done.invoke.'
  local invoke_error = event.type:sub(1, 13) == 'error.invoke.'
  if timer or invoke_done or invoke_error then
    if event.token == nil or snapshot.entries[event.state] ~= event.token then
      record.rejected, record.reason = true, 'stale'
      return snapshot, {}, record
    end
    if timer then
      local delay = tonumber(event.type:match('^after%.(%d+)%.'))
      record.timers[#record.timers + 1] = {action = 'fired', state = event.state, delay = delay, event = event.type, token = event.token}
    else
      local id = event.type:sub(invoke_done and 13 or 14)
      record.invokes[#record.invokes + 1] = {action = invoke_done and 'done' or 'error', state = event.state, id = id,
        token = event.token, error = invoke_error and event.error or nil}
    end
  end
  local child_changed = false
  local actor_done = event.type:sub(1, 11) == 'done.actor.'
  if actor_done or event.type:sub(1, 12) == 'error.actor.' then
    local id = event.type:sub(actor_done and 12 or 13)
    local expected = m.entries[child_token_key(id)]
    local index = (expected == nil or event.token == expected) and remove_child(m, id) or nil
    if not index then
      record.rejected, record.reason = true, 'stale'
      return snapshot, {}, record
    end
    event.index = index -- Position the child had, for selection updates.
    record.children[#record.children + 1] = {action = actor_done and 'done' or 'error', id = id,
      error = (not actor_done) and event.error or nil}
    child_changed = true
  end
  local enabled = remove_conflicts(chart, m.active, select_transitions(chart, m.active, event.type, m.guard_args))
  if #enabled == 0 and not child_changed then
    record.rejected, record.reason = true, 'no_transition'
    if timer or invoke_done or invoke_error then record.rejected, record.reason = false, nil end
    return snapshot, {}, record
  end
  if #enabled > 0 then microstep(m, enabled, event.type) end
  run_to_completion(m)
  return finish(m, snapshot)
end

local function can(chart, snapshot, event, context_view, children_view)
  if snapshot.status ~= 'active' then return false end
  event = normalize_event(event)
  if not internal_type(event.type) and not chart.declared[event.type] then
    if M.strict then fail('UnknownEvent: %s does not accept %q', chart.id, event.type) end
    return false
  end
  local active = active_set(chart, snapshot)
  local cv, ev = context_view or view(snapshot.context), view(event)
  local meta = {children = children_view or view(snapshot.children), matches = function(id)
    local node = chart.by_id[id]
    if not node or id == '' then fail('machine %s has no state %q', chart.id, tostring(id)) end
    return active[node] == true
  end}
  return #select_transitions(chart, active, event.type, function() return cv, ev, meta end) > 0
end

-- Build a legal configuration containing as many wanted states as possible.
local function complete(chart, wanted)
  local states = {}
  local function contains(node)
    for _, w in ipairs(wanted) do if w == node or is_descendant(w, node) then return true end end
    return false
  end
  local function visit(node)
    if node ~= chart.root then states[#states + 1] = node end
    if node.type == 'compound' then
      local choice = node.initial
      for _, child in ipairs(node.children) do
        if contains(child) then choice = child; break end
      end
      visit(choice)
    elseif node.type == 'parallel' then
      for _, child in ipairs(node.children) do visit(child) end
    end
  end
  visit(chart.root)
  table.sort(states, by_order)
  local ids = {}
  for i, node in ipairs(states) do ids[i] = node.id end
  return ids
end

---------------------------------------------------------------------------
-- Actors
---------------------------------------------------------------------------

local inspectors = {}
local commits = 0 -- Global commit order across actors, for records.
local registry = {}
local registry_order = {}

-- machine.actors() lists registered actors by path. A path belongs to its
-- latest actor: a remounted component registers before the old instance's
-- unmount stops it, and that stop must not unregister the new one.
-- Actors on an `unlisted` scheduler (replay's sandbox) stay out of the app's
-- registry: they neither appear in machine.actors() nor claim app paths.
local function register(actor)
  if actor._scheduler.unlisted then return end
  if registry[actor.path] == nil then registry_order[#registry_order + 1] = actor.path end
  registry[actor.path] = actor
end

-- Root actor paths are unique among live actors, so records, the recorder and
-- replay tell them apart. A root whose id (default or explicit) is taken by a
-- live actor gets the next free deterministic suffix: 'counter', 'counter#2',
-- 'counter#3'. Replay runs on an unlisted scheduler and keeps the recorded
-- path as is. Children are unique per parent.
local function claim_path(actor)
  if actor._parent or actor._scheduler.unlisted then return end
  local holder = registry[actor.path]
  if holder == nil or holder == actor then return end
  local base, n = actor.id, 2
  while registry[base .. '#' .. n] ~= nil do n = n + 1 end
  actor.id = base .. '#' .. n
  actor.path = actor.id
end
-- System ids (XState v5's systemId): chart:actor { system_id = 'shell' }
-- makes an actor addressable app-wide, as machine.system('shell') and
-- machine.send_to({ system = 'shell' }, event), from creation until it stops
-- or finishes. A system id names one live actor at a time.
local systems = {}
function M.system(id) return systems[id] end

local function unregister(actor)
  if actor._system_id and systems[actor._system_id] == actor then systems[actor._system_id] = nil end
  if registry[actor.path] ~= actor then return end
  registry[actor.path] = nil
  for i, path in ipairs(registry_order) do
    if path == actor.path then table.remove(registry_order, i); break end
  end
end

local function emit(actor, record)
  local list = {}
  for _, fn in ipairs(actor._observers) do list[#list + 1] = fn end
  for _, fn in ipairs(inspectors) do list[#list + 1] = fn end
  for _, fn in ipairs(list) do
    local ok, err = pcall(fn, record)
    if not ok then print('machine observer failed: ' .. tostring(err)) end
  end
end

local function wants_records(actor)
  return #actor._observers > 0 or #inspectors > 0
end

local function subscribe(list, fn)
  if type(fn) ~= 'function' then fail('observer must be a function') end
  list[#list + 1] = fn
  return function()
    for i, existing in ipairs(list) do
      if existing == fn then table.remove(list, i); return end
    end
  end
end

function M.inspect(fn) return subscribe(inspectors, fn) end

-- External input boundaries (design §14). An input enters the system when no
-- actor is processing: a send from a widget, MCP or app code, a runtime
-- delivery, a timer firing, an invoke or task result, a root start or stop.
-- Everything it causes (child sends, send_parent, spawns) is internal and a
-- function of the charts. Entering a boundary first syncs the scheduler
-- clock, so due timers fire before the input. M._hooks, when a recorder or
-- replayer installs it, sees each boundary of a recorded actor tree: a root
-- that is not a component machine, on the default scheduler (or the one the
-- replayer passed). depth counts every processing actor; recorded_depth only
-- recorded ones, so a component machine's effect sending to a root actor is
-- still an input (origin 'component').
local depth, recorded_depth, current_scheduler = 0, 0, nil
M._hooks = nil
M._origin = nil -- an origin label hosts may set around a synchronous hook (activation)

local function recorded(actor)
  local hooks = M._hooks
  if not hooks then return false end
  local root = actor
  while root._parent do root = root._parent end
  -- Component machines record too, keyed by instance path (machine.component).
  if hooks.watches then return hooks.watches(root) end
  return root._scheduler == (hooks.scheduler or M.default_scheduler)
end

-- A recorder never throws into the app: a failing hook uninstalls the
-- recorder, which reports why (hooks.failed), and processing goes on.
local function call_hook(hooks, name, ...)
  local fn = hooks[name]
  if not fn then return nil end
  local ok, result = pcall(fn, ...)
  if ok then return result end
  if M._hooks == hooks then M._hooks = nil end
  if hooks.failed then pcall(hooks.failed, 'recorder ' .. name .. ' failed: ' .. tostring(result)) end
  return nil
end

-- Runs fn(...) as processing of `actor`; at the outermost level it is an
-- input boundary of kind 'input' (event, origin), 'start', 'stop' or 'release'.
local function boundary(actor, kind, event, origin, fn, ...)
  if depth == 0 then
    local sync = actor._scheduler.sync
    if sync then sync() end
  end
  local hooks = recorded_depth == 0 and recorded(actor) and M._hooks or nil
  if hooks then
    if origin == 'external' or origin == 'actor' then
      origin = depth > 0 and 'component' or (M._current_origin and M._current_origin()) or M._origin or 'app'
    end
    call_hook(hooks, 'enter', actor, kind, event, origin)
  end
  local counted = recorded(actor)
  local previous = current_scheduler
  depth, current_scheduler = depth + 1, actor._scheduler
  if counted then recorded_depth = recorded_depth + 1 end
  local ok, a, b = pcall(fn, ...)
  depth, current_scheduler = depth - 1, previous
  if counted then recorded_depth = recorded_depth - 1 end
  if hooks then call_hook(hooks, 'leave', actor, kind, ok, not ok and a or nil) end
  if not ok then error(a, 0) end
  return a, b
end

local function step_hook(actor, record, origin)
  local hooks = M._hooks
  if hooks and hooks.step and recorded(actor) then call_hook(hooks, 'step', actor, record, origin) end
end

-- Logical time of the scheduler running the current macrostep (design §8):
-- frozen for the step, virtual under manual_scheduler, replay and
-- deterministic hosts. Outside a macrostep, the default scheduler's clock.
function M.now()
  local scheduler = current_scheduler or M.default_scheduler
  local clock = scheduler.clock
  return clock and clock() or nil
end

-- Deterministic hosts: move the default virtual clock, firing due timers.
function M.advance(ms)
  if not M.clock then fail('machine.advance needs the native scheduler') end
  if not M.virtual_clock then fail('machine.advance needs a virtual clock (a deterministic host)') end
  M.clock.advance(ms)
end

-- XState's waitFor: yield the running task until predicate(snapshot) holds
-- and return that snapshot. Wakes on the actor's commits, never polls.
-- Raises WaitTimeout after options.timeout ms, WaitEnded when the actor
-- stops or finishes without matching. Inside guards, assigns and actions it
-- is a wait like any other and raises YieldInAction. Canceling the waiting
-- task closes its waiter, which drops the subscription and the timer.
function M.wait_for(actor, predicate, options)
  options = options or {}
  if type(actor) ~= 'table' or not actor._waiters then fail('wait_for expects an actor') end
  if type(predicate) ~= 'function' then fail('wait_for expects a predicate function') end
  local timeout = options.timeout
  if timeout ~= nil and (math.type(timeout) ~= 'integer' or timeout < 0) then
    fail('wait_for timeout must be a nonnegative integer of milliseconds')
  end
  local snapshot = actor._snapshot
  if atomic('wait_for predicate', predicate, view(snapshot)) then return view(snapshot) end
  if snapshot.status ~= 'active' or actor._status == 'stopped' then
    fail('WaitEnded: %s is %s', actor.path, actor._status == 'stopped' and 'stopped' or snapshot.status)
  end
  if not waiter_new then fail('WaitUnavailable: machine.wait_for needs the Ouro runtime') end
  local entry = {predicate = predicate}
  local timer
  local waiter <close> = waiter_new(function()
    actor._waiters[entry] = nil
    if timer then scope_close(timer) end
  end)
  entry.waiter = waiter
  actor._waiters[entry] = true
  if timeout then
    timer = scope_open('application')
    scope_spawn(timer, function() ouro.sleep(timeout); waiter_wake(waiter, WAKE_TIMEOUT) end)
  end
  local code = waiter_park(waiter)
  if code == WAKE_MATCH then return view(entry.snapshot)
  elseif code == WAKE_TIMEOUT then fail('WaitTimeout: %s did not match within %d ms', actor.path, timeout)
  elseif code == WAKE_ENDED then fail('WaitEnded: %s is %s', actor.path, entry.snapshot.status)
  elseif code == WAKE_ERROR then error(entry.error, 0)
  else fail('WaitCanceled: %s', actor.path) end
end

-- A memoized derivation over immutable machine data. The cache holds the
-- last result per raw first argument (a context or snapshot, or their views)
-- plus raw-equal extra arguments, so a guard, can()/accepted() and the view
-- share one computation per snapshot. Treat the result as read-only.
-- A cache hit replays the signal reads the computation made, so a render
-- that only hits the cache still depends on the fields behind the result.
function M.selector(fn)
  if type(fn) ~= 'function' then fail('selector expects a function') end
  local last_key, last_args, last_result, last_reads, last_tracked, has_result = nil, nil, nil, nil, false, false
  return function(data, ...)
    local key, n = raw(data), select('#', ...)
    -- Tracked when any input is a tracked view: its reads go to signals.
    local tracked = is_tracked(data)
    for i = 1, n do if not tracked and is_tracked((select(i, ...))) then tracked = true end end
    if has_result and key == last_key and n == last_args.n then
      local same = true
      for i = 1, n do
        if raw((select(i, ...))) ~= last_args[i] then same = false; break end
      end
      -- Reuse replays the entry's reads, so a tracked caller depends on what
      -- the computation read. An entry computed on plain views (a guard after
      -- commit, can() outside a render) recorded none, so a tracked caller
      -- recomputes it. Inputs read at the call site (results(c.entries,
      -- c.query)) were tracked by the caller and stay memoized.
      if same and (last_tracked or not tracked) then
        for _, signal in ipairs(last_reads) do M._track(signal) end
        return last_result
      end
    end
    local args = {n = n}
    for i = 1, n do args[i] = raw((select(i, ...))) end
    local reads, ok, result = M._recording(fn, data, ...)
    if not ok then error(result, 0) end
    last_result, last_reads, last_tracked = result, reads, tracked
    last_key, last_args, has_result = key, args, true
    return last_result
  end
end

-- Chart event field types as a JSON Schema for MCP inputSchema.
local JSON_TYPES = {string = 'string', number = 'number', integer = 'integer', boolean = 'boolean'}
local function event_schema(chart, event_type)
  local properties, required = {}, {}
  for name, field in pairs(chart.events[event_type]) do
    if field.type == 'any' then properties[name] = true
    elseif field.type == 'table' then properties[name] = {type = {'object', 'array'}}
    else properties[name] = {type = JSON_TYPES[field.type]} end
    if not field.optional then required[#required + 1] = name end
  end
  table.sort(required)
  local schema = {type = 'object', properties = properties, additionalProperties = false}
  if #required > 0 then schema.required = required end
  return schema
end

local EMPTY_OUTPUT = {type = 'object', additionalProperties = false}

-- Build ouro.app `actions` entries whose inputs are chart events:
--   machine.actions(actor, {
--     RenameContact = { event = 'RENAME', description = '...',
--       errors = { no_transition = 'ContactNotFound' },     -- reject reason -> error code
--       wait = function(snapshot) ... end, timeout = 5000,  -- optional wait_for
--       output = function(snapshot, event) return {...} end, output_schema = {...} },
--     GetContacts = { description = '...', output = ..., output_schema = ... },  -- no event: a read
--   }, { before = function(actor) ... end })  -- may return an ouro.action_error
-- `actor` may be a function returning the actor (resolved per call). The
-- inputSchema comes from the chart's declared event schema; the handler
-- sends the event, turns a rejection into ouro.action_error(code,
-- {event, reason}) and returns output(snapshot, event).
function M.actions(actor, specs, options)
  options = options or {}
  local function resolve() if type(actor) == 'function' then return actor() end return actor end
  local function chart_of()
    if type(actor) == 'table' then return actor.chart end
    return options.chart or fail('machine.actions with an actor function needs options.chart')
  end
  local entries = {}
  for name, spec in pairs(specs) do
    if type(spec) ~= 'table' or type(spec.description) ~= 'string' then fail('action %s needs a description', tostring(name)) end
    local input_schema = EMPTY_OUTPUT
    if spec.event then
      local chart = chart_of()
      if not chart.events or not chart.events[spec.event] then
        fail('action %s: %s declares no %s event schema', name, chart.id, spec.event)
      end
      input_schema = event_schema(chart, spec.event)
    end
    entries[name] = {
      description = spec.description,
      inputSchema = input_schema,
      outputSchema = spec.output_schema or EMPTY_OUTPUT,
      handler = function(params)
        local target = resolve()
        if options.before then
          local err = options.before(target)
          if err ~= nil then return err end
        end
        local event
        if spec.event then
          event = {type = spec.event}
          for key, value in pairs(params or {}) do event[key] = value end
          local accepted, reason = target:_send(event, 'mcp')
          if not accepted then
            local code = spec.errors and spec.errors[reason]
              or (reason == 'no_transition' and 'EventRejected' or 'ActorUnavailable')
            -- The payload fields plus {event, reason}, e.g. {id, event, reason}.
            local parameters = {}
            for key, value in pairs(params or {}) do parameters[key] = value end
            parameters.event, parameters.reason = spec.event, reason
            return ouro.action_error(code, parameters)
          end
        end
        if spec.wait then
          local ok, err = pcall(M.wait_for, target, spec.wait, {timeout = spec.timeout})
          if not ok then
            local code = tostring(err):match('^(Wait%a+)') or 'WaitFailed'
            return ouro.action_error(code, {message = tostring(err)})
          end
        end
        if spec.output then return spec.output(target:snapshot(), event) end
      end,
    }
  end
  return entries
end

-- Source reload (driven by the host):
--   old VM:  entries, skipped = machine.persist_roots()   -- read-only
--   new VM:  machine.carry(entries) before the candidate's source and run()
--   commit:  machine.release() in the new VM; a failed candidate never calls it
-- Creating a root actor whose id and chart id match a carried entry restores
-- it (chart:restore, with options.renames). Restored state is visible at
-- once, so the candidate's UI builds from it; restored timers and invokes
-- start when the candidate commits; a failed candidate starts nothing.
local carried, held = nil, nil

function M.persist_roots()
  local entries, skipped = {}, {}
  for _, actor in ipairs(M.actors()) do
    if not actor._parent and not actor._lazy and actor._status == 'running' and actor._snapshot.status == 'active' then
      local ok, snapshot = pcall(actor.persist, actor)
      if ok then entries[#entries + 1] = {id = actor.id, machine = actor.chart.id, snapshot = snapshot}
      else skipped[#skipped + 1] = actor.id .. ': ' .. tostring(snapshot) end
    end
  end
  return entries, skipped
end

function M.carry(entries)
  carried, held = {}, {}
  for i, entry in ipairs(entries or {}) do carried[i] = entry end
  if M._hooks then call_hook(M._hooks, 'carry') end
end

function M._take_carried(chart, actor, options)
  if not carried or options.parent or options.snapshot or options.lazy then return nil end
  for i, entry in ipairs(carried) do
    if entry.id == actor.id and entry.machine == chart.id then
      table.remove(carried, i)
      return entry
    end
  end
end

function M._hold(actor, effects)
  if not held then return effects end
  local kept = {}
  for _, effect in ipairs(effects) do
    if effect.kind == 'timer_start' or effect.kind == 'invoke_start' then held[#held + 1] = {actor = actor, effect = effect}
    else kept[#kept + 1] = effect end
  end
  return kept
end

function M.release()
  local list = held or {}
  carried, held = nil, nil
  local order, by_actor = {}, {}
  for _, item in ipairs(list) do
    local actor, effect = item.actor, item.effect
    if actor._status == 'created' then
      -- Not started yet: start() will run it.
      actor._pending.effects[#actor._pending.effects + 1] = effect
    elseif actor._status == 'running' and actor._snapshot.status == 'active'
      and actor._snapshot.entries[effect.state] == effect.token then
      if not by_actor[actor] then by_actor[actor] = {}; order[#order + 1] = actor end
      local effects = by_actor[actor]
      effects[#effects + 1] = effect
    end -- Stopped, or the state was exited since: skip.
  end
  local first_error
  for _, actor in ipairs(order) do
    local err = M._run_released(actor, by_actor[actor])
    first_error = first_error or err
  end
  if M._hooks then call_hook(M._hooks, 'released') end
  if first_error then error(first_error, 0) end
end

function M.actors()
  local list, live = {}, {}
  for _, path in ipairs(registry_order) do
    local actor = registry[path]
    -- A scope = 'task' actor dies with its task's scope; drop it here.
    if actor and actor._root_scope and actor._scheduler.alive and not actor._scheduler.alive(actor._root_scope) then
      registry[path] = nil
      actor = nil
    end
    if actor then list[#list + 1] = actor; live[#live + 1] = path end
  end
  registry_order = live
  return list
end

-- Local UI state as a one-state (or more) machine per mounted instance,
-- replacing ouro.stateful + signals:
--   local Collapsible = machine.component(chart, function(self, props) ... end)
--   Collapsible { key = 'details', title = 'Details' }
-- The actor is created when the instance mounts (input = props, so context
-- may read initial props) and is registered then, so machine.actors() lists it
-- and runtime.send can reach it. It starts on its first event, from any task
-- (a widget callback, a dev tool, a test body); its root scope is application
-- scope, and the unmount hook's stop() ends its timers and invokes.
-- render(self, props) reads self:context()/matches()/can() and returns UI.
-- When the instance leaves (unmount, key reuse, owner disposal, or a build
-- that rolled back), the runtime's on_unmount hook stops the actor: its
-- scope retires and its work ends. Remounting creates a fresh actor.
local component_ids = {} -- live component actors by id; unmount removes them
function M.component(chart, render)
  if type(chart) ~= 'table' or not chart.__chart then fail('component expects a chart') end
  if type(render) ~= 'function' then fail('component expects a render function') end
  return ouro.stateful(function(props, path, values)
    -- Keyed by instance path, so recordings and replay tell instances apart
    -- (design §14); a second live instance on the same path gets a suffix.
    local id = chart.id .. '@' .. tostring(path or props.key)
    local base, n = id, 1
    while component_ids[id] and component_ids[id]._status ~= 'stopped' do n = n + 1; id = base .. '#' .. n end
    local actor = chart:actor {id = id, input = props, lazy = true}
    actor._component = true
    -- A recorder logs the plain part of the initial props (§14).
    if M._hooks then actor._recorded_input = call_hook(M._hooks, 'component_input', values) end
    component_ids[id] = actor
    return function() return render(actor, props) end, function()
      actor:stop()
      if component_ids[id] == actor then component_ids[id] = nil end
    end
  end)
end

local function spawn_task(fn)
  local spawn_app = ouro.spawn_app
  if spawn_app and pcall(spawn_app, fn) then return end
  ouro.spawn(fn)
end

-- The scheduler seam. Each actor opens a root scope when it starts (a child
-- of its parent actor's root); each active state entry with after/invoke work
-- opens one scope under it; timers and invokes run inside; exiting the state
-- closes it, and stopping the actor closes the root.
--
-- With the native binding, closing a scope cancels its tasks: sleeping timers
-- and in-flight invokes unwind. The per-entry token check stays as a second
-- line of defense and is what the token scheduler relies on.
M.native_scopes = scope_open ~= nil

-- Drop dead entries once a list doubles since its last compaction, so a
-- long-lived owner (a root scope, a manual clock) stays bounded.
local function compact(list, keep)
  if #list < (list.compact_at or 32) then return end
  local j = 0
  for i = 1, #list do
    local item = list[i]
    list[i] = nil
    if keep(item) then j = j + 1; list[j] = item end
  end
  list.compact_at = math.max(32, 2 * j)
end

-- Logical time (design §8). A scheduler clock reads one logical instant per
-- external input: it is frozen for the macrostep and its effects, so guards,
-- assigns, records and machine.now() agree. `after` timers sit in one queue
-- ordered by (deadline, start order). A firing runs at its deadline, and
-- every timer due at or before wall time fires before the next external
-- input is processed. A live clock follows the host's monotonic time between
-- inputs. A virtual clock (deterministic hosts, replay) moves only through
-- advance(). Either way the order and the instants are a function of the
-- inputs and their times, which is what makes a recording replayable.
--   clock.now()           logical ms
--   clock.after(scope, delay, fn)
--   clock.sync()          fire timers due by wall time, then catch up (live only)
--   clock.advance(ms)     fire timers due within ms, then move to now + ms
--   clock.advance_to(t)   the same, to an absolute instant
function M.logical_clock(options)
  options = options or {}
  -- by_scope finds the queued timers of a scope when it closes (it holds only
  -- scopes with queued timers); dead counts cancelled timers still queued.
  local c = {timers = {}, sequence = 0, firing = false, fired = 0, dead = 0, compact_at = 32, by_scope = {}, pass = 0}
  local alive, wall, wake = options.alive or function(scope) return scope.alive end, options.wall, options.wake
  local time = options.start
  local function current()
    if time == nil then time = wall and wall() or 0 end
    return time
  end
  function c.now() return current() end
  local function live(timer) return not timer.dead and alive(timer.scope) end
  local function link(timer)
    local mine = c.by_scope[timer.scope]
    if not mine then mine = {}; c.by_scope[timer.scope] = mine end
    mine[#mine + 1] = timer
  end
  -- Remove every timer that can no longer fire. Order is kept, so firing order
  -- and replay are unaffected.
  local function sweep()
    local list, j = c.timers, 0
    c.by_scope = {}
    for i = 1, #list do
      local timer = list[i]
      list[i] = nil
      if live(timer) then j = j + 1; list[j] = timer; link(timer) end
    end
    c.dead = 0
  end
  local function pop()
    local timer = table.remove(c.timers, 1)
    if timer.dead then c.dead = c.dead - 1 end
    local mine = c.by_scope[timer.scope]
    if mine then
      for i, other in ipairs(mine) do
        if other == timer then table.remove(mine, i); break end
      end
      if not mine[1] then c.by_scope[timer.scope] = nil end
    end
    return timer
  end
  function c.after(scope, delay, fn)
    c.sequence = c.sequence + 1
    -- Scopes closed without cancel() (a parent's close cascading natively)
    -- are caught here, once the queue has doubled since the last pass.
    if #c.timers >= c.compact_at then
      sweep()
      c.compact_at = math.max(32, 2 * #c.timers)
    end
    local timer = {at = current() + delay, sequence = c.sequence, scope = scope, fn = fn}
    -- A zero-delay timer started while timers fire belongs to the next turn,
    -- so an `after 0` loop yields instead of spinning inside one pass.
    if delay == 0 and c.firing then timer.pass = c.pass end
    local list, i = c.timers, #c.timers
    while i > 0 and (list[i].at > timer.at) do i = i - 1 end
    table.insert(list, i + 1, timer)
    link(timer)
    if wake and list[1] == timer then wake(timer.at) end
  end
  -- A scope closed: its timers will never fire. Tombstone them and sweep once
  -- tombstones are at least half the queue, so a cancelled timer leaves the
  -- queue when its state exits, not when its deadline passes. Without this a
  -- virtual clock (moved only by advance()) or a 1 h delay keeps every one.
  function c.cancel(scope)
    local mine = c.by_scope[scope]
    if not mine then return end
    c.by_scope[scope] = nil
    for _, timer in ipairs(mine) do
      if not timer.dead then timer.dead = true; c.dead = c.dead + 1 end
    end
    if c.dead > 0 and c.dead * 2 >= #c.timers then sweep() end
  end
  -- The earliest pending deadline, dropping timers whose scope closed.
  function c.next()
    while c.timers[1] and not live(c.timers[1]) do pop() end
    return c.timers[1] and c.timers[1].at
  end
  function c.advance_to(target)
    if c.firing then return end
    c.firing = true
    c.pass = c.pass + 1
    local pass, deferred = c.pass, false
    local ok, err = pcall(function()
      while c.timers[1] and c.timers[1].at <= target do
        local head = c.timers[1]
        -- Started by this pass with zero delay: stop here. The clock stays at
        -- its deadline (no pending timer is skipped); the live clock's next
        -- wake or the next advance() continues from it.
        if head.pass == pass and live(head) then deferred = true; break end
        local timer = pop()
        if live(timer) then
          if timer.at > current() then time = timer.at end
          c.fired = c.fired + 1
          local fired, failure = pcall(timer.fn)
          if not fired then print('machine timer failed: ' .. tostring(failure)) end
        end
      end
      if not deferred and target > current() then time = target end
    end)
    c.firing = false
    if not ok then error(err, 0) end
    if wake and c.next() then wake(c.timers[1].at) end
  end
  function c.advance(ms)
    if math.type(ms) ~= 'integer' or ms < 0 then fail('advance expects nonnegative integer milliseconds') end
    c.advance_to(current() + ms)
  end
  function c.sync()
    local now = wall and wall()
    if now then c.advance_to(now) end
  end
  return c
end

-- Deterministic hosts (Storybook playback, `ouroctl test`) disable wall-clock
-- sleeps; the host sets this so the default clock is virtual and only
-- machine.advance(ms) moves it.
M.virtual_clock = false
if scope_open then
  local monotonic = ouro._monotonic_ms
  local function wall() if not M.virtual_clock then return monotonic() end end
  -- One native wake task sleeps until the earliest deadline; an earlier
  -- timer closes its scope and arms a new one.
  local wake_scope, wake_at, clock
  local function wake(at)
    if M.virtual_clock then return end
    if wake_scope and wake_at <= at and scope_alive(wake_scope) then return end
    if wake_scope then scope_close(wake_scope) end
    local scope = scope_open('application')
    wake_scope, wake_at = scope, at
    scope_spawn(scope, function()
      -- Always sleep, even for a due timer: sleep(0) goes through the event
      -- loop, so input is handled between turns of an `after 0` loop.
      local delay = at - monotonic()
      ouro.sleep(delay > 0 and delay or 0)
      if wake_scope == scope then wake_scope = nil end
      clock.sync()
    end)
  end
  clock = M.logical_clock {alive = function(scope) return scope_alive(scope) end, wall = wall, wake = wake}
  M.clock = clock
  M.default_scheduler = {
    kind = 'native',
    open = function(parent) return scope_open(parent) end,
    close = function(scope) scope_close(scope); clock.cancel(scope) end,
    alive = function(scope) return scope_alive(scope) end,
    run = function(scope, fn) scope_spawn(scope, fn) end,
    after = clock.after,
    clock = clock.now,
    sync = clock.sync,
  }
end

-- machine.sleep(ms) for invokes and spawned tasks: waits on the scheduler's
-- logical clock instead of wall time, so backoff and timeouts stay
-- deterministic under a virtual clock, manual_scheduler and replay. A
-- scheduler that runs tasks itself (manual_scheduler) sets machine._task_sleep
-- while a task runs. The wait is cancelled with the calling task.
function M.sleep(ms)
  if math.type(ms) == 'float' then ms = math.tointeger(ms) end
  if math.type(ms) ~= 'integer' or ms < 0 or ms > M.max_delay_ms then
    fail('machine.sleep expects integer ms from 0 to %d', M.max_delay_ms)
  end
  if M._task_sleep then return M._task_sleep(ms) end
  if not (waiter_new and scope_open and M.clock) then return ouro.sleep(ms) end
  local timer = scope_open() -- a child of the running task's scope
  local waiter <close> = waiter_new(function()
    scope_close(timer)
    M.clock.cancel(timer)
  end)
  M.clock.after(timer, ms, function() waiter_wake(waiter, WAKE_MATCH) end)
  waiter_park(waiter)
end

-- Fallback where no native binding exists (a Lua state without a Vm), and for
-- comparison: spawned work has no handle, so it runs in application scope and
-- a closed scope only drops its delivery.
local function is_alive(scope) return scope.alive end
local function token_scope(parent)
  local scope = {alive = true, children = {}}
  if type(parent) == 'table' then
    compact(parent.children, is_alive)
    parent.children[#parent.children + 1] = scope
  end
  return scope
end
local function close_token_scope(scope)
  scope.alive = false
  for _, child in ipairs(scope.children) do close_token_scope(child) end
  scope.children = {}
end
M.token_scheduler = {
  kind = 'token',
  clock = ouro._monotonic_ms,
  open = token_scope,
  close = close_token_scope,
  alive = function(scope) return scope.alive end,
  run = function(scope, fn) spawn_task(function() if scope.alive then fn() end end) end,
  after = function(scope, delay, fn)
    spawn_task(function() ouro.sleep(delay); if scope.alive then fn() end end)
  end,
}
M.default_scheduler = M.default_scheduler or M.token_scheduler

-- Deterministic scheduler for tests: virtual time and explicit task runs.
function M.manual_scheduler()
  local s = {kind = 'manual', now = 0, timers = {}, tasks = {}, sequence = 0, open_scopes = 0, pass = 0}
  function s.clock() return s.now end -- virtual time for records
  function s.open(parent)
    s.open_scopes = s.open_scopes + 1
    return token_scope(parent)
  end
  local function close(scope)
    if scope.alive then s.open_scopes = s.open_scopes - 1 end
    scope.alive = false
    for _, child in ipairs(scope.children) do close(child) end
    scope.children = {}
  end
  s.close = close
  function s.alive(scope) return scope.alive end
  local function live_timer(t) return t.scope.alive end
  function s.after(scope, delay, fn)
    s.sequence = s.sequence + 1
    -- Timers of closed scopes never fire; drop them so a shared clock stays bounded.
    compact(s.timers, live_timer)
    s.timers[#s.timers + 1] = {at = s.now + delay, sequence = s.sequence, scope = scope,
      -- As on the logical clock: zero delay while firing waits for the next advance().
      pass = delay == 0 and s.firing and s.pass or nil,
      fn = function() if scope.alive then fn() end end}
  end
  -- Invokes and spawned tasks. run_tasks() runs queued ones for real, each in
  -- a coroutine, so one that calls machine.sleep(ms) parks until advance()
  -- reaches its wake time. A test fake can instead settle a pending one
  -- without running it (design §0 Tests):
  --   clock.pending_invokes()      -> {{id, kind, actor, src, state, started}}
  --   clock.resolve(id, value)     done.invoke.<id> / done.actor.<id>
  --   clock.reject(id, err)        error.invoke.<id> / error.actor.<id>
  --   clock.emit(id, event)        the invoke's send(event): invoke -> chart
  --   clock.send(id, event)        the invoke's receive handler: chart -> invoke
  -- `id` is the invoke id or the spawned task's id; with two pending items of
  -- one id, the first started wins. Pass 'actor path:id' to pick one.
  local items = {}
  local co = M._coroutine
  local function resume(item, ...)
    if item.done or not item.scope.alive then return end
    local previous, previous_sleep = s.current, M._task_sleep
    s.current = item
    -- machine.sleep(ms) inside this item parks it on the virtual clock.
    M._task_sleep = function(ms) return s.sleep(nil, ms) end
    local ok, err
    if co then
      item.co = item.co or co.create(item.fn)
      ok, err = co.resume(item.co, ...)
      if ok and co.status(item.co) == 'dead' then item.done = true end
    else
      ok, err = pcall(item.fn)
      item.done = true
    end
    s.current, M._task_sleep = previous, previous_sleep
    if not ok then item.done = true; error(err, 0) end
  end
  function s.run(scope, fn, info)
    local item = {scope = scope, fn = fn, info = info}
    s.tasks[#s.tasks + 1] = item
    if info then items[#items + 1] = item end
  end
  -- Parks the running invoke or task until advance() reaches now + ms.
  function s.sleep(scope, ms)
    local item = s.current
    if not item or not co then fail('sleep needs an invoke or task that the manual scheduler runs') end
    s.after(scope or item.scope, ms, function() resume(item) end)
    co.yield()
  end
  function s.pending()
    local live = 0
    for _, t in ipairs(s.timers) do if t.scope.alive then live = live + 1 end end
    return live, #s.tasks
  end
  function s.run_tasks()
    local count = 0
    while #s.tasks > 0 do
      local item = table.remove(s.tasks, 1)
      if not item.co then resume(item) end
      count = count + 1
    end
    return count
  end
  local function live_items()
    local list = {}
    for _, item in ipairs(items) do
      if not item.done and not item.settled and item.scope.alive then list[#list + 1] = item end
    end
    items = list
    return list
  end
  function s.pending_invokes()
    local out = {}
    for _, item in ipairs(live_items()) do
      local info = item.info
      out[#out + 1] = {id = info.id, kind = info.kind, actor = info.actor, src = info.src, state = info.state,
        started = item.co ~= nil}
    end
    return out
  end
  local function find(id)
    local actor, local_id = tostring(id):match('^(.*):([^:]+)$')
    for _, item in ipairs(live_items()) do
      if item.info.id == (local_id or id) and (not actor or item.info.actor == actor) then return item end
    end
    fail('no pending invoke or task %q', tostring(id))
  end
  local function settle(id, ok, value)
    local item = find(id)
    item.settled, item.done = true, true
    for i, queued in ipairs(s.tasks) do if queued == item then table.remove(s.tasks, i); break end end
    item.info.complete(ok, value)
  end
  function s.resolve(id, value) settle(id, true, value) end
  function s.reject(id, err) settle(id, false, err) end
  function s.emit(id, event)
    local item = find(id)
    if not item.info.send then fail('%s is a task; only invokes send events', tostring(id)) end
    return item.info.send(event)
  end
  function s.send(id, event)
    local item = find(id)
    local post = item.info.post
    if not post then fail('%s cannot receive events (invokes receive through receive(fn))', tostring(id)) end
    return post(event)
  end
  function s.advance(ms)
    local target = s.now + ms
    s.pass = s.pass + 1
    local pass = s.pass
    local outer = s.firing
    s.firing = true
    local ok, err = pcall(function()
      while true do
        local best
        for i, t in ipairs(s.timers) do
          if t.at <= target and (not best or t.at < s.timers[best].at
            or (t.at == s.timers[best].at and t.sequence < s.timers[best].sequence)) then best = i end
        end
        if not best then break end
        if s.timers[best].pass == pass and s.timers[best].scope.alive then target = s.now; break end
        local t = table.remove(s.timers, best)
        s.now = t.at
        t.fn()
      end
    end)
    s.firing = outer
    if not ok then error(err, 0) end
    s.now = target
  end
  return s
end

local Actor = {}

local function create_actor(chart, options)
  options = options or {}
  local actor = {chart = chart, id = options.id or chart.id, _observers = {}, _queue = {}, _timers = {}, _invokes = {}, _scopes = {}, _tasks = {},
    _waiters = {}, _lazy = options.lazy == true, _scope_mode = options.scope, _token = options.token, _input = options.input,
    _children = {}, _started = false, _status = 'created', _scheduler = options.scheduler or M.default_scheduler,
    _signal_factory = options.signal or ouro.signal, _parent = options.parent, _charts = options.charts or {}}
  for name, fn in pairs(Actor) do actor[name] = fn end
  actor.path = options.parent and (options.parent.path .. '/' .. actor.id) or actor.id
  if options.system_id ~= nil then
    if type(options.system_id) ~= 'string' or options.system_id == '' then fail('system_id must be a nonempty string') end
    local holder = systems[options.system_id]
    if holder and holder._status ~= 'stopped' and not holder._released then
      fail('DuplicateSystemId: %q already names %s', options.system_id, holder.path)
    end
    actor._system_id = options.system_id
  end
  local snapshot, effects, record
  local carried_entry = M._take_carried(chart, actor, options)
  if carried_entry then
    options = copy(options)
    options.snapshot = chart:restore(carried_entry.snapshot, {renames = options.renames, input = options.input})
  end
  actor._restored = options.snapshot ~= nil
  if options.snapshot then
    local persisted = options.snapshot
    if persisted.machine ~= chart.id then fail('snapshot belongs to %s, not %s', tostring(persisted.machine), chart.id) end
    for _, id in ipairs(persisted.states) do
      local node = chart.by_id[id]
      if not node or node == chart.root then fail('snapshot state %q is not in machine %s (use restore)', tostring(id), chart.id) end
    end
    snapshot = {machine = chart.id, status = persisted.status or 'active', states = {}, context = copy(raw(persisted.context or {})),
      children = {}, entries = {}, serial = math.tointeger(persisted.serial) or 0, output = persisted.output}
    for i, id in ipairs(persisted.states) do snapshot.states[i] = id end
    table.sort(snapshot.states, function(a, b) return chart.by_id[a].order < chart.by_id[b].order end)
    effects = {}
    for _, id in ipairs(snapshot.states) do
      local node = chart.by_id[id]
      snapshot.serial = snapshot.serial + 1
      snapshot.entries[id] = snapshot.serial
      if snapshot.status == 'active' then
        for _, a in ipairs(node.after) do
          effects[#effects + 1] = {kind = 'timer_start', state = id, delay = a.delay, event = a.event, token = snapshot.serial,
            ms = a.fn and delay_ms(a, view(snapshot.context), view({type = 'ouro.restore'})) or a.ms or a.delay}
        end
        for _, inv in ipairs(node.invokes) do
          local input = inv.input and raw(atomic('input of invoke ' .. inv.id, inv.input, view(snapshot.context), view({type = 'ouro.restore'})))
          effects[#effects + 1] = {kind = 'invoke_start', state = id, id = inv.id, src = inv.src, src_name = inv.src_name,
            input = input, token = snapshot.serial}
        end
      end
    end
    -- Restored timers and invokes wait for release() while a reload is held.
    effects = M._hold(actor, effects)
    for _, child in ipairs(persisted.children or {}) do
      local machine_id = child.snapshot.machine
      local child_chart = actor._charts[machine_id] or chart.child_charts[machine_id] or (machine_id == chart.id and chart)
      if not child_chart then fail('no chart for restored child machine %s', tostring(machine_id)) end
      snapshot.children[#snapshot.children + 1] = child.id
      snapshot.serial = snapshot.serial + 1
      snapshot.entries[child_token_key(child.id)] = snapshot.serial
      -- Children map onto their chart too: renamed or removed states fall
      -- back to the nearest surviving ancestor.
      effects[#effects + 1] = {kind = 'spawn', id = child.id, chart = child_chart, snapshot = child_chart:restore(child.snapshot),
        child_token = snapshot.serial}
    end
    record = new_record({type = 'ouro.restore'})
    record.handled = true
    for _, id in ipairs(snapshot.states) do record.entered[#record.entered + 1] = id end
  else
    snapshot, effects, record = initial(chart, options.input)
  end
  actor._snapshot = snapshot
  actor._pending = {effects = effects, record = record}
  actor._store = actor._signal_factory(snapshot)
  actor._config = actor._signal_factory(0)
  actor._members = actor._signal_factory(0)
  actor._keys = {}
  -- A lazy (component) actor is inspectable and sendable from creation, with
  -- its initial snapshot; its root scope and effects still wait for start.
  if actor._lazy and not actor._parent then claim_path(actor); register(actor) end
  if actor._system_id then systems[actor._system_id] = actor end
  return actor
end

---------------------------------------------------------------------------
-- Rebuild locality. Besides the snapshot, each actor keeps hidden signals:
--   one per top-level context key, created when a render first reads it;
--   configuration (states, status, output), bumped only when they change;
--   membership (the children ids), bumped only when they change;
--   all (_store), set on every own commit: the coarse fallback for pairs()
--   and for snapshot fields without a finer signal.
-- context(), snapshot() and snapshot.children are tracked views whose field
-- reads read those signals, so the dependency graph records exactly what a
-- render (or a guard evaluated by can()) looked at. A child's commit updates
-- its parent's snapshot for guards and pure transitions but writes no parent
-- signal: snapshot.children[id] reads go to the child's own signals.
---------------------------------------------------------------------------

local recorder -- signals read while a selector computes
function M._track(signal)
  if recorder then recorder[#recorder + 1] = signal end
  signal()
end
function M._recording(fn, ...)
  local outer, reads = recorder, {}
  recorder = reads
  local ok, result = pcall(fn, ...)
  recorder = outer
  if outer then for _, signal in ipairs(reads) do outer[#outer + 1] = signal end end
  return reads, ok, result
end
local track = M._track

local function key_signal(actor, key)
  local signal = actor._keys[key]
  if not signal then
    signal = actor._signal_factory(actor._snapshot.context[key])
    actor._keys[key] = signal
  end
  return signal
end

local function context_view(actor)
  local context = actor._snapshot.context
  if actor._context_for ~= context then
    actor._context_for = context
    actor._context_view = tracked_view(context, function(t, key)
      if key == nil then track(actor._store); return nil end -- # and pairs: every key
      -- A stopped or finished actor's signals are released; reads keep working untracked.
      if not actor._released then track(key_signal(actor, key)) end
      return view(t[key])
    end)
  end
  return actor._context_view
end

local snapshot_view
local function children_view(actor)
  local children = actor._snapshot.children
  if actor._children_for ~= children then
    actor._children_for = children
    actor._children_view = tracked_view(children, function(t, key)
      if key == nil or math.type(key) == 'integer' then
        track(actor._members)
        return key and t[key] or nil
      end
      local child = actor._children[key]
      if child and t[key] ~= nil then return snapshot_view(child) end
      track(actor._members)
      return view(t[key]) -- a task child's entry
    end)
  end
  return actor._children_view
end

snapshot_view = function(actor)
  local snapshot = actor._snapshot
  if actor._snapshot_for ~= snapshot then
    actor._snapshot_for = snapshot
    actor._snapshot_view = tracked_view(snapshot, function(t, key)
      if key == 'context' then return context_view(actor) end
      if key == 'children' then return children_view(actor) end
      if key == 'states' or key == 'status' or key == 'output' or key == 'machine' then track(actor._config)
      else track(actor._store) end
      return view(t[key])
    end)
  end
  return actor._snapshot_view
end

local function bump(signal) signal:set(signal() + 1) end

-- True when this actor was created from a persisted snapshot (including
-- state carried across a source reload); apps skip one-time setup then.
function Actor:restored() return self._restored end

-- Whole-snapshot read: fields are tracked as they are read (§6).
function Actor:snapshot() return snapshot_view(self) end
function Actor:context() return context_view(self) end
-- 'created' until start(), 'stopped' after stop() (even if it never started),
-- otherwise the snapshot status (active | done).
function Actor:status()
  track(self._config)
  if self._status == 'created' or self._status == 'stopped' then return self._status end
  return self._snapshot.status
end
function Actor:started() track(self._config); return self._status ~= 'created' end
function Actor:states() track(self._config); return view(self._snapshot.states) end
function Actor:output() track(self._config); return view(self._snapshot.output) end

function Actor:matches(id)
  track(self._config)
  local snapshot = self._snapshot
  if not self.chart.by_id[id] or id == '' then fail('machine %s has no state %q', self.chart.id, tostring(id)) end
  if self._set_for ~= snapshot.states then
    local set = {}
    for _, state in ipairs(snapshot.states) do set[state] = true end
    self._set_for, self._set = snapshot.states, set
  end
  return self._set[id] == true
end

function Actor:has_tag(tag)
  track(self._config)
  for _, id in ipairs(self._snapshot.states) do
    if self.chart.by_id[id].tags[tag] then return true end
  end
  return false
end

-- Guards run on the tracked views, so their context reads are dependencies.
function Actor:can(event)
  track(self._config)
  return can(self.chart, self._snapshot, event, context_view(self), children_view(self))
end

-- True when some active state has a transition for this event type,
-- ignoring guards: value widgets enable on it, so an input disables when the
-- state takes no such edits at all, without guards locking it out.
function Actor:handles(event_type)
  track(self._config)
  local snapshot = self._snapshot
  if self._status == 'stopped' or snapshot.status ~= 'active' then return false end
  if type(event_type) ~= 'string' or event_type == '' then fail('handles expects an event type') end
  local chart = self.chart
  if not internal_type(event_type) and not chart.declared[event_type] then
    if M.strict then fail('UnknownEvent: %s does not accept %q', chart.id, event_type) end
    return false
  end
  local names = descriptors(event_type)
  for node in pairs(active_set(chart, snapshot)) do
    for _, name in ipairs(names) do
      local list = node.on[name]
      if list and #list > 0 then return true end
    end
  end
  return false
end

-- External events the current configuration would accept, for palettes,
-- shortcuts and MCP tools. Requires declared events.
-- accepted() -> accepted, guarded: the declared events an active transition
-- takes now without a payload (no guard, or a guard that passed without
-- reading payload fields), and those an active transition handles but whose
-- guard reads the payload, so only a real event can decide them. Both sorted
-- and disjoint. Guards are probed: one that raises without reading the
-- payload just doesn't count; nothing is raised or recorded as an error.
function Actor:accepted()
  track(self._config)
  local chart, snapshot = self.chart, self._snapshot
  local accepted, guarded = {}, {}
  if self._status == 'stopped' or snapshot.status ~= 'active' then return accepted, guarded end
  local active = active_set(chart, snapshot)
  local context, children = context_view(self), children_view(self)
  local meta = {children = children, matches = function(id)
    local node = chart.by_id[id]
    if not node or id == '' then fail('machine %s has no state %q', chart.id, tostring(id)) end
    return active[node] == true
  end}
  local names = {}
  for name in pairs(chart.declared) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local takes, pending = false, false
    local patterns = descriptors(name)
    for _, state in ipairs(sorted(active)) do
      if takes then break end
      if is_atomic(state) then
        local node = state
        while node and not takes do
          for _, pattern in ipairs(patterns) do
            for _, t in ipairs(node.on[pattern] or {}) do
              local outcome = t.guard == nil and 'passed' or probe_guard(chart, t, context, {type = name}, meta)
              if outcome == 'passed' then takes = true; break end
              if outcome == 'payload' then pending = true end
            end
            if takes then break end
          end
          node = node.parent
        end
      end
    end
    if takes then accepted[#accepted + 1] = name elseif pending then guarded[#guarded + 1] = name end
  end
  return accepted, guarded
end

function Actor:child(id) return self._children[id] end

-- Running invokes, for late-attaching inspectors: {state, id, src, token,
-- time_ms} with time_ms the scheduler clock when the invoke started.
function Actor:pending_invokes()
  local list = {}
  for _, live in pairs(self._invokes) do
    list[#list + 1] = {state = live.state, id = live.id, src = live.src, token = live.token, time_ms = live.time_ms}
  end
  table.sort(list, function(a, b) return a.state < b.state or (a.state == b.state and a.id < b.id) end)
  return list
end

-- Running after-timers, for late-attaching inspectors: {state, delay, event,
-- token, time_ms} with time_ms the scheduler clock when the timer started.
-- The actor's scheduler clock (logical ms; design §8).
function Actor:now() local fn = self._scheduler.clock; return fn and fn() or nil end

function Actor:pending_timers()
  local list = {}
  for _, live in pairs(self._timers) do
    list[#list + 1] = {state = live.state, delay = live.delay, event = live.event, token = live.token, time_ms = live.time_ms,
      ms = live.ms}
  end
  table.sort(list, function(a, b) return a.state < b.state or (a.state == b.state and a.event < b.event) end)
  return list
end

function Actor:children()
  track(self._members)
  local list = {}
  for _, id in ipairs(self._snapshot.children) do
    if self._children[id] then list[#list + 1] = self._children[id] end
  end
  return list
end

function Actor:observe(fn) return subscribe(self._observers, fn) end

-- The snapshot as plain data for dev tools: never fails; native handles and
-- transient fields are opaque {"$h": type} markers.
function Actor:inspectable()
  local snapshot = self._snapshot
  local states = {}
  for i, id in ipairs(snapshot.states) do states[i] = id end
  local children = {}
  for _, id in ipairs(snapshot.children) do
    children[#children + 1] = id
    local child = snapshot.children[id]
    if child ~= nil then
      local actor = self._children[id]
      children[id] = actor and actor:inspectable() or inspectable(child)
    end
  end
  return {machine = snapshot.machine, status = snapshot.status, states = states,
    context = inspectable_context(self.chart, snapshot.context), output = inspectable(snapshot.output),
    children = children}
end

function Actor:persist()
  local snapshot = self._snapshot
  local states = {}
  for i, id in ipairs(snapshot.states) do states[i] = id end
  local out = {machine = snapshot.machine, status = snapshot.status, states = states, context = persist_context(self.chart, snapshot.context),
    output = plain(snapshot.output), serial = snapshot.serial, children = {}}
  for _, id in ipairs(snapshot.children) do
    local child = self._children[id]
    if child then out.children[#out.children + 1] = {id = id, snapshot = child:persist()} end
  end
  return out
end

-- Scheduler clock in ms (virtual for the manual scheduler, host monotonic
-- otherwise); records use differences only.
local function clock(actor)
  local fn = actor._scheduler.clock
  return fn and fn() or nil
end

-- Valve states for the visualizer: every guarded transition whose source is
-- active, evaluated against the committed snapshot. Event transitions see a
-- bare {type = event}; after transitions their timer event; always ones
-- {type = 'ouro.always'}. A throwing guard is closed, with its error.
local function valve_states(actor)
  local chart, snapshot = actor.chart, actor._snapshot
  local out = {}
  if snapshot.status ~= 'active' then return out end
  local active = active_set(chart, snapshot)
  local context = view(snapshot.context)
  local meta = {children = view(snapshot.children), matches = function(id)
    local node = chart.by_id[id]
    if not node or id == '' then fail('machine %s has no state %q', chart.id, tostring(id)) end
    return active[node] == true
  end}
  for _, t in ipairs(chart.transitions) do
    if t.guard and active[t.source] then
      local event = {type = t.event or 'ouro.always'}
      if t.kind == 'after' then event.state, event.token = t.source.id, snapshot.entries[t.source.id] end
      local outcome, err = probe_guard(chart, t, context, event, meta)
      if outcome == 'payload' then out[#out + 1] = {index = t.index, passed = false, payload = true}
      elseif outcome == 'error' then out[#out + 1] = {index = t.index, passed = false, error = err}
      else out[#out + 1] = {index = t.index, passed = outcome == 'passed'} end
    end
  end
  return out
end

local function finalize(actor, record, origin)
  actor._sequence = (actor._sequence or 0) + 1
  record.time_ms = clock(actor)
  record.guards = valve_states(actor)
  record.actor, record.machine, record.sequence, record.origin = actor.path, actor.chart.id, actor._sequence, origin
  local snapshot = actor._snapshot
  local states = {}
  for i, id in ipairs(snapshot.states) do states[i] = id end
  record.states, record.status = states, snapshot.status
  record.context = inspectable_context(actor.chart, snapshot.context)
  record.event = inspectable(record.event)
  for _, entry in ipairs(record.invokes) do entry.error = inspectable(entry.error) end
end

local commit

-- A child's committed snapshot replaces its entry in the parent's snapshot
-- (snapshot.children[id]), so parent guards, assigns and the view read it.
local function propagate(child)
  local parent = child._parent
  if not parent or parent._children[child.id] ~= child then return end
  local current = parent._snapshot
  local listed = false
  for _, id in ipairs(current.children) do if id == child.id then listed = true; break end end
  if not listed or current.children[child.id] == child._snapshot then return end
  local children = copy(current.children)
  children[child.id] = child._snapshot
  local next_snapshot = copy(current)
  next_snapshot.children = children
  -- For guards and pure transitions only: views read the child's own signals.
  parent._snapshot = next_snapshot
  propagate(parent)
  if next(parent._waiters) then M._notify_waiters(parent, next_snapshot) end
end

-- The actor's root scope, opened on first need (a timer, invoke or task), so
-- actors that never schedule work never touch the scheduler. Child actors
-- nest under their parent's root. A root actor lives in application scope,
-- like spawn_app: it outlives the task that started it (a widget callback,
-- an MCP action) until stop(), done or source reload. Component actors do
-- too; their instance's unmount hook stops them. scope = 'task' instead
-- hangs the root under the current task's scope.
local function root_scope(actor)
  if actor._status == 'stopped' then fail('machine %s is stopped', actor.path) end
  if not actor._root_scope then
    local parent = actor._parent and root_scope(actor._parent)
      or (actor._scope_mode ~= 'task' and 'application' or nil)
    actor._root_scope = actor._scheduler.open(parent)
  end
  return actor._root_scope
end

local function scope_for(actor, state, token)
  local entry = actor._scopes[state]
  if entry and entry.token == token then return entry.scope end
  if entry then actor._scheduler.close(entry.scope) end
  entry = {token = token, scope = actor._scheduler.open(root_scope(actor))}
  actor._scopes[state] = entry
  return entry.scope
end

-- Runtime deliveries (timers, invoke and task results) run in runtime tasks.
-- An error while handling one (a throwing action or guard) is already on the
-- step's record and was not raised by app code, so report it instead of
-- ending the task.
local function deliver_reported(actor, event, origin)
  local ok, err = pcall(actor._deliver, actor, event, origin)
  if not ok then print(('machine %s: handling %s failed: %s'):format(actor.path, tostring(event.type), tostring(err))) end
end

-- A callback invoke's cleanup runs once, protected, when it is cancelled.
local function cleanup_invoke(live)
  local cleanup = live.cleanup
  live.cleanup, live.handler, live.mailbox = nil, nil, {}
  if cleanup then
    local ok, err = pcall(cleanup)
    if not ok then print('machine invoke cleanup failed: ' .. tostring(err)) end
  end
end

-- The active invoke with this id, if any (send_to targets it after children).
local function active_invoke(actor, id)
  for _, live in pairs(actor._invokes) do
    if live.id == id and live.mailbox then return live end
  end
end

local function run_effects(actor, effects, record)
  local first_error
  for _, effect in ipairs(effects) do
    -- A stopped actor starts nothing, even mid-list (stopped by a parent or
    -- by one of its own effects).
    if actor._status == 'stopped' then break end
    local ok, err = pcall(function()
      local kind = effect.kind
      if kind == 'action' then
        atomic(effect.label, effect.fn, view(effect.context), view(effect.event), actor)
      elseif kind == 'timer_start' then
        local key = effect.state .. '|' .. effect.delay
        local ms = effect.ms or effect.delay
        local live = {token = effect.token, state = effect.state, delay = effect.delay, event = effect.event,
          time_ms = clock(actor), ms = ms}
        actor._timers[key] = live
        record.timers[#record.timers + 1] = {action = 'started', state = effect.state, delay = effect.delay,
          event = effect.event, token = effect.token, time_ms = live.time_ms, ms = ms}
        actor._scheduler.after(scope_for(actor, effect.state, effect.token), ms, function()
          if actor._timers[key] ~= live then return end
          actor._timers[key] = nil
          -- Timer events carry their fire time: the deadline, on a logical clock.
          deliver_reported(actor, {type = effect.event, state = effect.state, token = effect.token, time_ms = clock(actor)}, 'timer')
        end)
      elseif kind == 'timer_cancel' then
        local key = effect.state .. '|' .. effect.delay
        local live = actor._timers[key]
        if live and live.token == effect.token then
          actor._timers[key] = nil
          record.timers[#record.timers + 1] = {action = 'cancelled', state = effect.state, delay = effect.delay,
            event = effect.event, token = effect.token}
        end
      elseif kind == 'invoke_start' then
        local key = effect.state .. '|' .. effect.id
        local live = {token = effect.token, state = effect.state, id = effect.id, src = effect.src_name, time_ms = clock(actor)}
        actor._invokes[key] = live
        record.invokes[#record.invokes + 1] = {action = 'started', state = effect.state, id = effect.id,
          src = effect.src_name, token = effect.token, time_ms = live.time_ms}
        local function send(event)
          if actor._invokes[key] == live then actor:_send(event, 'invoke') end
        end
        local scope = scope_for(actor, effect.state, effect.token)
        -- receive(fn): events the chart sends to this invoke (send_to its id)
        -- queue in a mailbox that one task in the invoke's scope drains in
        -- order. The last registration wins; the mailbox ends with the state.
        live.mailbox = {}
        live.drain = function()
          if live.draining or not live.handler or not live.mailbox[1] then return end
          live.draining = true
          actor._scheduler.run(scope, function()
            while live.mailbox[1] and live.handler and actor._invokes[key] == live do
              local ok, err = pcall(live.handler, table.remove(live.mailbox, 1))
              if not ok then live.complete(false, err) end
            end
            live.draining = false
          end)
        end
        local function receive(fn)
          if type(fn) ~= 'function' then fail('receive expects a function') end
          live.handler = fn
          live.drain()
        end
        -- Like machine.send_to('<invoke id>', event) from the chart.
        local function post(event)
          if actor._invokes[key] ~= live then return false end
          live.mailbox[#live.mailbox + 1] = normalize_event(event)
          live.drain()
          return true
        end
        local function complete(ok, result)
          if actor._invokes[key] ~= live then return end
          -- A src that returns a function is a callback invoke: it stays
          -- active until its state exits, and the function is its cleanup.
          if ok and type(result) == 'function' and not live.cleanup then
            live.cleanup = result
            return
          end
          actor._invokes[key] = nil
          if ok then
            deliver_reported(actor, {type = 'done.invoke.' .. effect.id, state = effect.state, token = effect.token, output = result}, 'invoke')
          else
            deliver_reported(actor, {type = 'error.invoke.' .. effect.id, state = effect.state, token = effect.token, error = result}, 'invoke')
          end
        end
        -- info lets a replay scheduler stub the source: it never calls fn and
        -- completes the invoke from the recording instead.
        live.complete = complete
        actor._scheduler.run(scope, function()
          complete(pcall(effect.src, effect.input, send, receive))
        end, {kind = 'invoke', actor = actor.path, id = effect.id, src = effect.src_name, state = effect.state,
          token = effect.token, complete = complete, send = send, receive = receive, post = post})
      elseif kind == 'invoke_cancel' then
        local key = effect.state .. '|' .. effect.id
        local live = actor._invokes[key]
        if live and live.token == effect.token then
          actor._invokes[key] = nil
          record.invokes[#record.invokes + 1] = {action = 'cancelled', state = effect.state, id = effect.id,
            src = effect.src, token = effect.token}
          cleanup_invoke(live)
        end
      elseif kind == 'scope_close' then
        local entry = actor._scopes[effect.state]
        if entry and entry.token == effect.token then
          actor._scopes[effect.state] = nil
          actor._scheduler.close(entry.scope)
        end
      elseif kind == 'spawn' then
        local child = create_actor(effect.chart, {id = effect.id, input = effect.input, parent = actor, snapshot = effect.snapshot,
          scheduler = actor._scheduler, signal = actor._signal_factory, charts = actor._charts, token = effect.child_token})
        actor._children[effect.id] = child
        record.children[#record.children + 1] = {action = 'spawned', id = effect.id, machine = effect.chart.id}
        propagate(child)
        child:start()
      elseif kind == 'spawn_task' then
        -- A one-shot task gets its own scope under its owner state's scope,
        -- so stop(id) and leaving the owner both cancel it.
        local owner = effect.owner == '' and root_scope(actor) or scope_for(actor, effect.owner, effect.token)
        local scope = actor._scheduler.open(owner)
        local live = {scope = scope}
        actor._tasks[effect.id] = live
        record.children[#record.children + 1] = {action = 'spawned', id = effect.id, src = effect.src_name}
        local function complete(ok, result)
          if actor._tasks[effect.id] ~= live then return end
          actor._tasks[effect.id] = nil
          if ok then
            deliver_reported(actor, {type = 'done.actor.' .. effect.id, id = effect.id, output = result, token = effect.child_token}, 'child')
          else
            deliver_reported(actor, {type = 'error.actor.' .. effect.id, id = effect.id, error = result, token = effect.child_token}, 'child')
          end
          actor._scheduler.close(scope)
        end
        actor._scheduler.run(scope, function() complete(pcall(effect.src, effect.input)) end,
          {kind = 'task', actor = actor.path, id = effect.id, src = effect.src_name, token = effect.child_token,
            complete = complete})
      elseif kind == 'stop' then
        local child, task = actor._children[effect.id], actor._tasks[effect.id]
        actor._children[effect.id], actor._tasks[effect.id] = nil, nil
        if child then
          record.children[#record.children + 1] = {action = 'stopped', id = effect.id, machine = child.chart.id}
          child:stop()
        elseif task then
          record.children[#record.children + 1] = {action = 'stopped', id = effect.id}
          actor._scheduler.close(task.scope)
        end
      elseif kind == 'send_to' or kind == 'send_parent' then
        local target
        if kind == 'send_to' and type(effect.id) == 'table' then
          -- { system = id }: an actor anywhere in the app (machine.system).
          local system = effect.id.system
          target = type(system) == 'string' and systems[system]
          if not target then fail('machine %s: no actor has system id %q', actor.chart.id, tostring(system)) end
          if target._status == 'created' and not target._lazy then
            -- Created but not started (a sibling the app starts later): rejected, not raised.
            record.sent[#record.sent + 1] = {kind = kind, to = target.path, system = system, event = effect.event.type,
              accepted = false, reason = 'not_started'}
            return
          end
          local sent = {kind = kind, to = target.path, system = system, event = effect.event.type}
          record.sent[#record.sent + 1] = sent
          sent.accepted, sent.reason = target:_send(effect.event, 'actor', actor.path)
          return
        elseif kind == 'send_to' then
          target = actor._children[effect.id]
          local invoke = not target and active_invoke(actor, effect.id)
          if invoke then
            -- An active invoke's mailbox (receive).
            local event = copy(effect.event)
            record.sent[#record.sent + 1] = {kind = kind, to = actor.path .. '/' .. effect.id, invoke = true,
              event = event.type, accepted = true}
            invoke.mailbox[#invoke.mailbox + 1] = event
            invoke.drain()
            return
          end
          if not target then fail('machine %s has no child or invoke %q', actor.chart.id, tostring(effect.id)) end
        else
          target = actor._parent
          if not target then fail('machine %s has no parent', actor.chart.id) end
        end
        -- Inter-actor traffic is visible on both records: `sent` on the
        -- sender's, origin 'actor' and `from` on the receiver's.
        local sent = {kind = kind, to = target.path, event = effect.event.type}
        record.sent[#record.sent + 1] = sent
        sent.accepted, sent.reason = target:_send(effect.event, 'actor', actor.path)
      elseif kind == 'done' then
        actor._status = 'done'
        -- A finished actor runs nothing else; its state scopes are closed.
        if actor._root_scope then actor._scheduler.close(actor._root_scope) end
        if actor._parent then
          actor._parent:_deliver({type = 'done.actor.' .. actor.id, id = actor.id, output = effect.output, token = actor._token}, 'child')
        end
      end
    end)
    if not ok and not first_error then first_error = err end
  end
  return first_error
end

-- Re-check every wait_for on this actor against a newly committed snapshot.
local function notify_waiters(actor, snapshot)
  for entry in pairs(actor._waiters) do
    if not waiter_waiting(entry.waiter) then
      actor._waiters[entry] = nil
    else
      local ok, matched = pcall(atomic, 'wait_for predicate', entry.predicate, view(snapshot))
      if not ok then
        entry.error = matched
        waiter_wake(entry.waiter, WAKE_ERROR)
      elseif matched then
        entry.snapshot = snapshot
        waiter_wake(entry.waiter, WAKE_MATCH)
      elseif snapshot.status ~= 'active' then
        entry.snapshot = snapshot
        waiter_wake(entry.waiter, WAKE_ENDED)
      end
    end
  end
end

M._notify_waiters = notify_waiters

local function same_configuration(a, b)
  if a.status ~= b.status or a.output ~= b.output or #a.states ~= #b.states then return false end
  for i, id in ipairs(a.states) do if b.states[i] ~= id then return false end end
  return true
end

local function same_members(a, b)
  if #a ~= #b then return false end
  for i, id in ipairs(a) do if b[i] ~= id then return false end end
  return true
end

-- Write only what changed: copy-on-write shares unchanged context values, so
-- a key signal set to a raw-equal value invalidates nothing.
commit = function(actor, snapshot)
  if snapshot ~= actor._snapshot then
    local old = actor._snapshot
    actor._snapshot = snapshot
    actor._store:set(snapshot)
    if old.context ~= snapshot.context then
      for key, signal in pairs(actor._keys) do signal:set(snapshot.context[key]) end
    end
    if not same_configuration(old, snapshot) then bump(actor._config) end
    if not same_members(old.children, snapshot.children) then bump(actor._members) end
    propagate(actor)
    if next(actor._waiters) then notify_waiters(actor, snapshot) end
  end
end

-- After the final commit (stop, or reaching a top-level final state): release
-- every hidden signal so the actor holds no signal slots, and drop it from
-- machine.actors(). Reads keep returning the final values, untracked.
local function retire(actor)
  if actor._released then return end
  actor._released = true
  release_signal(actor._store)
  release_signal(actor._config)
  release_signal(actor._members)
  for _, signal in pairs(actor._keys) do release_signal(signal) end
  unregister(actor)
end

-- A finished actor is done for good: its children stop (their scopes already
-- closed with its root), and it retires like a stopped one.
local function retire_if_done(actor)
  if actor._status ~= 'done' or actor._released then return end
  local invokes = actor._invokes
  actor._invokes = {}
  for _, live in pairs(invokes) do cleanup_invoke(live) end
  for _, child in pairs(actor._children) do child:stop() end
  actor._children = {}
  retire(actor)
end

local function forget_finished_children(actor)
  local live = {}
  for _, id in ipairs(actor._snapshot.children) do live[id] = true end
  for id in pairs(actor._children) do
    if not live[id] and actor._children[id]._status ~= 'running' then actor._children[id] = nil end
  end
end

function M._run_released(actor, effects)
  return boundary(actor, 'release', nil, 'restore', function()
    local record = new_record({type = 'ouro.release'})
    record.handled = true
    local err = run_effects(actor, effects, record)
    step_hook(actor, record, 'restore')
    if wants_records(actor) then
      finalize(actor, record, 'restore')
      emit(actor, record)
    end
    return err
  end)
end

function Actor:_process()
  if self._processing then return end
  self._processing = true
  -- An error (guard, assign, action) affects only the event that raised it:
  -- events already queued keep processing, and the first error reaches the
  -- sender afterwards.
  local first_error
  while #self._queue > 0 do
    local item = table.remove(self._queue, 1)
    local ok, err = pcall(function()
      local stepped, snapshot, effects, record = pcall(transition, self.chart, self._snapshot, item.event)
      if not stepped then
        -- A guard, assign or expression raised: nothing commits, but observers
        -- still see the event, rejected with reason 'error'.
        item.accepted, item.reason = false, 'error'
        if wants_records(self) then
          record = new_record(item.event)
          record.rejected, record.reason, record.error = true, 'error', error_info(snapshot)
          finalize(self, record, item.origin)
          record.from = item.from
          emit(self, record)
        end
        error(snapshot, 0)
      end
      item.accepted, item.reason = not record.rejected, record.reason
      commit(self, snapshot)
      commits = commits + 1
      record.commit = commits
      local effect_error = run_effects(self, effects, record)
      forget_finished_children(self)
      step_hook(self, record, item.origin)
      if wants_records(self) then
        finalize(self, record, item.origin)
        record.from = item.from
        if effect_error ~= nil then record.error = error_info(effect_error) end
        emit(self, record)
      end
      retire_if_done(self)
      if effect_error then error(effect_error, 0) end
    end)
    if not ok and first_error == nil then first_error = err end
  end
  self._processing = false
  if first_error ~= nil then error(first_error, 0) end
end

local function enqueue(actor, event, origin, from)
  -- An outside input first lets due timers fire, before it joins the queue:
  -- otherwise a timer fired by the sync would process behind it.
  if depth == 0 then
    local sync = actor._scheduler.sync
    if sync then sync() end
  end
  local item = {event = event, origin = origin, from = from}
  actor._queue[#actor._queue + 1] = item
  if actor._processing then return nil, 'queued' end
  boundary(actor, 'input', event, origin, actor._process, actor)
  -- Sent while this actor is mid-macrostep (from one of its own effects): it
  -- is queued behind the current step, so the outcome is not known yet.
  if item.accepted == nil then return nil, 'queued' end
  return item.accepted, item.reason
end

function Actor:_deliver(event, origin)
  if self._status ~= 'running' and self._status ~= 'done' then return false, self._status end
  return enqueue(self, event, origin)
end

-- Runtime delivery (surfaces, timers, children): reserved event types are
-- allowed, no schema or declaration check, same queue and macrostep as
-- send. `origin` labels inspection records (default 'runtime').
function Actor:deliver(event, origin)
  event = normalize_event(event)
  if self._status == 'created' and self._lazy then self:start() end
  return self:_deliver(event, origin or 'runtime')
end

function Actor:send(event) return self:_send(event, 'external') end

-- send with an origin label for records ('widget', 'mcp', 'invoke', ...).
-- `from` is the sending actor's path for send_to/send_parent (record.from).
function Actor:_send(event, origin, from)
  event = normalize_event(event)
  if internal_type(event.type) then fail('InvalidEvent: %q is reserved for the machine runtime', event.type) end
  if not validate_event(self.chart, event) then return false, 'undeclared' end
  if self._status == 'created' then
    if not self._lazy then fail('machine %s was sent an event before start', self.path) end
    self:start() -- Component machines start on their first event.
  end
  if self._status == 'stopped' then return false, 'stopped' end
  return enqueue(self, event, origin or 'external', from)
end

-- A plain event binding for widgets: exactly { actor, event, field }.
-- Validated now, like can(), so typos fail at render; the event is neither
-- copied nor frozen (send copies payloads). With `field`, the widget sends a
-- copy of the event with event[field] = its value.
function Actor:event(event, field)
  if field ~= nil and (type(field) ~= 'string' or field == '') then fail('event binding field must be a nonempty string') end
  -- A lazy binding: function(snapshot) -> event or nil, resolved by the widget
  -- at render and again at dispatch; the resolved event is validated by
  -- can() and send() then.
  if type(event) == 'function' then return {actor = self, event = event, field = field} end
  local normalized = normalize_event(event)
  if internal_type(normalized.type) then fail('InvalidEvent: %q is reserved for the machine runtime', normalized.type) end
  if M.strict and not self.chart.declared[normalized.type] then
    fail('UnknownEvent: %s does not accept %q', self.chart.id, normalized.type)
  end
  if field ~= nil and (type(field) ~= 'string' or field == '') then fail('event binding field must be a nonempty string') end
  return {actor = self, event = event, field = field}
end

-- Returns a function that sends the event; use for on_press and commands.
function Actor:sender(event)
  normalize_event(event)
  return function() self:_send(event, 'callback') end
end

function Actor:start()
  if self._status ~= 'created' then return self end
  -- Before the start boundary, so the recorder logs the final path.
  claim_path(self)
  boundary(self, 'start', nil, nil, self._start, self)
  return self
end

function Actor:_start()
  self._status = 'running'
  bump(self._config) -- status() changes from 'created'
  register(self)
  if #inspectors > 0 or #self._observers > 0 then
    emit(self, {kind = 'actor', action = 'started', actor = self.path, machine = self.chart.id, time_ms = clock(self),
      parent = self._parent and self._parent.path, graph = self.chart:graph()})
  end
  local pending = self._pending
  self._pending = nil
  commits = commits + 1
  pending.record.commit = commits
  self._processing = true
  local ok, err = pcall(function()
    local effect_error = run_effects(self, pending.effects, pending.record)
    step_hook(self, pending.record, pending.record.event.type == 'ouro.restore' and 'restore' or 'init')
    if wants_records(self) then
      finalize(self, pending.record, pending.record.event.type == 'ouro.restore' and 'restore' or 'init')
      if effect_error ~= nil then pending.record.error = error_info(effect_error) end
      emit(self, pending.record)
    end
    retire_if_done(self)
    if effect_error then error(effect_error, 0) end
  end)
  self._processing = false
  -- Like _process (M6): an entry error does not strand events queued during
  -- start (a child's send_parent from its entry); they process, then the
  -- first error reaches the starter.
  local drained, drain_err = pcall(self._process, self)
  if not ok then error(err, 0) end
  if not drained then error(drain_err, 0) end
end

function Actor:stop()
  if self._status == 'stopped' then return end
  boundary(self, 'stop', nil, 'stop', self._stop, self)
end

function Actor:_stop()
  local was_started = self._status ~= 'created'
  self._status = 'stopped'
  -- A finished actor already retired its signals; status() reads _status.
  if not self._released then bump(self._config) end
  self._queue = {}
  local record = new_record({type = 'ouro.stop'})
  record.handled = true
  for _, live in pairs(self._timers) do
    record.timers[#record.timers + 1] = {action = 'cancelled', state = live.state, delay = live.delay,
      event = live.event, token = live.token}
  end
  for _, live in pairs(self._invokes) do
    record.invokes[#record.invokes + 1] = {action = 'cancelled', state = live.state, id = live.id,
      src = live.src, token = live.token}
  end
  local invokes = self._invokes
  self._timers, self._invokes, self._tasks = {}, {}, {}
  for _, live in pairs(invokes) do cleanup_invoke(live) end
  for _, entry in pairs(self._scopes) do self._scheduler.close(entry.scope) end
  self._scopes = {}
  if self._root_scope then self._scheduler.close(self._root_scope) end
  -- Every child it still holds, listed or finished-but-not-yet-forgotten.
  for _, child in pairs(self._children) do child:stop() end
  self._children = {}
  local snapshot = copy(self._snapshot)
  snapshot.status = 'stopped'
  if was_started and not self._released then commit(self, snapshot) else self._snapshot = snapshot end
  -- Waiters end even if the actor never started (no commit notified them).
  if next(self._waiters) then M._notify_waiters(self, snapshot) end
  -- The final commit is done; nothing writes the hidden signals after this.
  retire(self)
  if was_started and wants_records(self) then
    finalize(self, record, 'stop')
    emit(self, record)
    emit(self, {kind = 'actor', action = 'stopped', actor = self.path, machine = self.chart.id, time_ms = clock(self)})
  end
end

---------------------------------------------------------------------------
-- Public chart API
---------------------------------------------------------------------------

function M.create(def)
  local chart = compile(def)
  local known = state_ids_by_machine[chart.id]
  if not known then known = {}; state_ids_by_machine[chart.id] = known end
  for id in pairs(chart.by_id) do if type(id) == 'string' then known[id] = true end end
  local exported
  function chart:graph()
    exported = exported or graph(self)
    return exported
  end
  function chart:initial(input) return initial(self, input) end
  function chart:transition(snapshot, event) return transition(self, snapshot, event) end
  function chart:can(snapshot, event) return can(self, snapshot, event) end
  function chart:has_state(id) return id ~= '' and self.by_id[id] ~= nil end
  function chart:actor(options) return create_actor(self, options) end
  function chart:start(options) return create_actor(self, options):start() end
  -- Map a persisted snapshot from an older chart onto this one: rename IDs,
  -- fall back to the nearest surviving ancestor, complete the configuration
  -- with initial states, and keep context fields whose type still matches.
  function chart:restore(persisted, options)
    options = options or {}
    local renames = options.renames or {}
    local wanted = {}
    for _, old in ipairs(persisted.states or {}) do
      local id = renames[old] or old
      while id ~= '' and not self.by_id[id] do
        local parent = id:match('^(.*)%.[^.]+$')
        id = parent or ''
        if renames[id] then id = renames[id] end
      end
      if id ~= '' then wanted[#wanted + 1] = self.by_id[id] end
    end
    local fresh = self.def.context
    if type(fresh) == 'function' then
      -- A restored child has no input; if the fresh context can't be built,
      -- the old context is kept as is.
      local ok, value = pcall(atomic, 'context of ' .. self.id, fresh, options.input)
      fresh = ok and value or {}
    end
    fresh = copy(raw(fresh or {}))
    local old = raw(persisted.context or {})
    for k, v in pairs(old) do
      if fresh[k] == nil or type(fresh[k]) == type(v) then fresh[k] = v end
    end
    return {machine = self.id, status = 'active', states = complete(self, wanted), context = fresh,
      children = persisted.children or {}, serial = persisted.serial}
  end
  return chart
end

ouro.machine = M
