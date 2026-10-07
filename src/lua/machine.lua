local ouro, view, raw, scope_open, scope_spawn, scope_close, scope_alive, atomic_call,
  waiter_new, waiter_park, waiter_wake, waiter_waiting = ...
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

-- Like plain, but never fails: records must survive arbitrary payloads.
local function inspectable(value, seen)
  value = raw(value)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' or kind == 'number' or kind == 'string' or is_json_null(value) then return value end
  if kind ~= 'table' then return '<' .. kind .. '>' end
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
function M.matches(snapshot, id)
  if snapshot == nil then return false end
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
local ROOT_KEYS = {id=true, context=true, guards=true, actions=true, actors=true, events=true}
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

local function compile(def)
  if type(def) ~= 'table' then fail('machine.create expects a table') end
  if type(def.id) ~= 'string' or not def.id:match('^[%a_][%w_%-]*$') then fail('machine id must be an identifier') end
  local chart = {__chart = true, id = def.id, nodes = {}, by_id = {}, transitions = {}, def = def}
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
      local delays = {}
      for delay in pairs(sdef.after) do
        if math.type(delay) ~= 'integer' or delay < 0 then fail('after delays in %s must be nonnegative integers', where(node)) end
        delays[#delays + 1] = delay
      end
      table.sort(delays)
      for _, delay in ipairs(delays) do
        local event = 'after.' .. delay .. '.' .. (node.id == '' and def.id or node.id)
        node.after[#node.after + 1] = {delay = delay, event = event}
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
      if node.type ~= 'compound' and node.type ~= 'parallel' then fail('on_done needs a compound or parallel state (%s)', where(node)) end
      on(node, 'done.state.' .. (node.id == '' and def.id or node.id), sdef.on_done, 'done')
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
    elseif field.type ~= 'any' then
      local ok = field.type == 'integer' and math.type(value) == 'integer' or type(value) == field.type
      if not ok then fail('InvalidEvent: %s.%s must be %s', event.type, name, field.type) end
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

local function graph(chart)
  local g = {format = 'ouro.machine.graph', version = 1, id = chart.id, root = '', states = {}, transitions = {}, events = {}}
  for i, node in ipairs(chart.nodes) do
    local children = {}
    for j, child in ipairs(node.children) do children[j] = child.id end
    local after, invoke, tags = {}, {}, {}
    for j, a in ipairs(node.after) do after[j] = {delay = a.delay, event = a.event} end
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
  if not t.reenter and t.source.type == 'compound' then
    local all = true
    for _, target in ipairs(t.targets) do if not is_descendant(target, t.source) then all = false; break end end
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
    exited = {}, entered = {}, timers = {}, invokes = {}, children = {}, actions = {}}
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
local function remove_child(children, id)
  for i, existing in ipairs(children) do
    if existing == id then
      table.remove(children, i)
      children[id] = nil
      return i
    end
  end
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
        m.serial = m.serial + 1
        id = (a.chart and a.chart.id or (a.src_name ~= 'function' and a.src_name) or 'task') .. '.' .. m.serial
      end
      if type(id) ~= 'string' or id == '' or id:find('/', 1, true) then fail('spawned child id must be a nonempty string without /') end
      for _, existing in ipairs(m.children) do
        if existing == id then fail('child %q already exists in %s', id, m.chart.id) end
      end
      m.children[#m.children + 1] = id
      local input = evaluate(a.input, m, a.label)
      if a.chart then
        m.effects[#m.effects + 1] = {kind = 'spawn', id = id, chart = a.chart, input = input}
      else
        m.children[id] = {status = 'active', src = a.src_name, owner = owner.id}
        m.effects[#m.effects + 1] = {kind = 'spawn_task', id = id, src = a.src, src_name = a.src_name, input = input,
          owner = owner.id, token = m.entries[owner.id]}
      end
    elseif a.kind == 'stop' then
      local id = evaluate(a.id, m, a.label)
      if remove_child(m.children, id) then m.effects[#m.effects + 1] = {kind = 'stop', id = id} end
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
    remove_child(m.children, id)
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
  for _, node in ipairs(sorted(exit_set(chart, active, transitions), by_reverse_order)) do
    step.exited[#step.exited + 1] = node.id
    m.record.exited[#m.record.exited + 1] = node.id
    run_actions(m, node.exit, node.parent or chart.root)
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
      run_actions(m, node.exit, node.parent or chart.root)
    end
    m.effects[#m.effects + 1] = {kind = 'done', output = output}
  end
  -- Start timers and invokes only for states still active after the
  -- macrostep, in document order, like SCXML's end-of-macrostep invoke.
  for _, node in ipairs(sorted(m.pending_start)) do
    if m.active[node] then
      local token = m.entries[node.id]
      for _, a in ipairs(node.after) do
        m.effects[#m.effects + 1] = {kind = 'timer_start', state = node.id, delay = a.delay, event = a.event, token = token}
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
    local index = remove_child(m.children, id)
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

local function can(chart, snapshot, event)
  if snapshot.status ~= 'active' then return false end
  event = normalize_event(event)
  if not internal_type(event.type) and not chart.declared[event.type] then
    if M.strict then fail('UnknownEvent: %s does not accept %q', chart.id, event.type) end
    return false
  end
  local active = active_set(chart, snapshot)
  local cv, ev = view(snapshot.context), view(event)
  local meta = {children = view(snapshot.children), matches = function(id)
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
function M.selector(fn)
  if type(fn) ~= 'function' then fail('selector expects a function') end
  local last_key, last_args, last_result, has_result = nil, nil, nil, false
  return function(data, ...)
    local key, n = raw(data), select('#', ...)
    if has_result and key == last_key and n == last_args.n then
      local same = true
      for i = 1, n do
        if raw((select(i, ...))) ~= last_args[i] then same = false; break end
      end
      if same then return last_result end
    end
    local args = {n = n}
    for i = 1, n do args[i] = raw((select(i, ...))) end
    last_result = fn(data, ...)
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
          local accepted, reason = target:send(event)
          if not accepted then
            local code = spec.errors and spec.errors[reason]
              or (reason == 'no_transition' and 'EventRejected' or 'ActorUnavailable')
            return ouro.action_error(code, {event = spec.event, reason = reason})
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

function M.actors()
  local list, live = {}, {}
  for _, path in ipairs(registry_order) do
    local actor = registry[path]
    -- Component actors die with their instance scope; drop them here.
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
-- may read initial props) and starts on its first event, in the callback's
-- instance scope: its timers and invokes end when the instance unmounts.
-- render(self, props) reads self:context()/matches()/can() and returns UI.
function M.component(chart, render)
  if type(chart) ~= 'table' or not chart.__chart then fail('component expects a chart') end
  if type(render) ~= 'function' then fail('component expects a render function') end
  return ouro.stateful(function(props)
    local actor = chart:actor {input = props, lazy = true, scope = 'task'}
    return function() return render(actor, props) end
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
if scope_open then
  M.default_scheduler = {
    kind = 'native',
    open = function(parent) return scope_open(parent) end,
    close = function(scope) scope_close(scope) end,
    alive = function(scope) return scope_alive(scope) end,
    run = function(scope, fn) scope_spawn(scope, fn) end,
    after = function(scope, delay, fn) scope_spawn(scope, function() ouro.sleep(delay); fn() end) end,
  }
end

-- Fallback where no native binding exists (a Lua state without a Vm), and for
-- comparison: spawned work has no handle, so it runs in application scope and
-- a closed scope only drops its delivery.
local function token_scope(parent)
  local scope = {alive = true, children = {}}
  if type(parent) == 'table' then parent.children[#parent.children + 1] = scope end
  return scope
end
local function close_token_scope(scope)
  scope.alive = false
  for _, child in ipairs(scope.children) do close_token_scope(child) end
end
M.token_scheduler = {
  kind = 'token',
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
  local s = {kind = 'manual', now = 0, timers = {}, tasks = {}, sequence = 0, open_scopes = 0}
  function s.open(parent)
    s.open_scopes = s.open_scopes + 1
    return token_scope(parent)
  end
  local function close(scope)
    if scope.alive then s.open_scopes = s.open_scopes - 1 end
    scope.alive = false
    for _, child in ipairs(scope.children) do close(child) end
  end
  s.close = close
  function s.alive(scope) return scope.alive end
  function s.after(scope, delay, fn)
    s.sequence = s.sequence + 1
    s.timers[#s.timers + 1] = {at = s.now + delay, sequence = s.sequence, fn = function() if scope.alive then fn() end end}
  end
  function s.run(scope, fn) s.tasks[#s.tasks + 1] = function() if scope.alive then fn() end end end
  function s.pending() return #s.timers, #s.tasks end
  function s.run_tasks()
    local count = 0
    while #s.tasks > 0 do
      local fn = table.remove(s.tasks, 1)
      fn()
      count = count + 1
    end
    return count
  end
  function s.advance(ms)
    local target = s.now + ms
    while true do
      local best
      for i, t in ipairs(s.timers) do
        if t.at <= target and (not best or t.at < s.timers[best].at
          or (t.at == s.timers[best].at and t.sequence < s.timers[best].sequence)) then best = i end
      end
      if not best then break end
      local t = table.remove(s.timers, best)
      s.now = t.at
      t.fn()
    end
    s.now = target
  end
  return s
end

local Actor = {}

local function create_actor(chart, options)
  options = options or {}
  local actor = {chart = chart, id = options.id or chart.id, _observers = {}, _queue = {}, _timers = {}, _invokes = {}, _scopes = {}, _tasks = {},
    _waiters = {}, _lazy = options.lazy == true, _scope_mode = options.scope,
    _children = {}, _started = false, _status = 'created', _scheduler = options.scheduler or M.default_scheduler,
    _signal_factory = options.signal or ouro.signal, _parent = options.parent, _charts = options.charts or {}}
  for name, fn in pairs(Actor) do actor[name] = fn end
  actor.path = options.parent and (options.parent.path .. '/' .. actor.id) or actor.id
  local snapshot, effects, record
  if options.snapshot then
    local persisted = options.snapshot
    if persisted.machine ~= chart.id then fail('snapshot belongs to %s, not %s', tostring(persisted.machine), chart.id) end
    for _, id in ipairs(persisted.states) do
      local node = chart.by_id[id]
      if not node or node == chart.root then fail('snapshot state %q is not in machine %s (use restore)', tostring(id), chart.id) end
    end
    snapshot = {machine = chart.id, status = persisted.status or 'active', states = {}, context = copy(raw(persisted.context or {})),
      children = {}, entries = {}, serial = 0, output = persisted.output}
    for i, id in ipairs(persisted.states) do snapshot.states[i] = id end
    table.sort(snapshot.states, function(a, b) return chart.by_id[a].order < chart.by_id[b].order end)
    effects = {}
    for _, id in ipairs(snapshot.states) do
      local node = chart.by_id[id]
      snapshot.serial = snapshot.serial + 1
      snapshot.entries[id] = snapshot.serial
      if snapshot.status == 'active' then
        for _, a in ipairs(node.after) do
          effects[#effects + 1] = {kind = 'timer_start', state = id, delay = a.delay, event = a.event, token = snapshot.serial}
        end
        for _, inv in ipairs(node.invokes) do
          local input = inv.input and raw(atomic('input of invoke ' .. inv.id, inv.input, view(snapshot.context), view({type = 'ouro.restore'})))
          effects[#effects + 1] = {kind = 'invoke_start', state = id, id = inv.id, src = inv.src, src_name = inv.src_name,
            input = input, token = snapshot.serial}
        end
      end
    end
    for _, child in ipairs(persisted.children or {}) do
      local child_chart = actor._charts[child.snapshot.machine] or (child.snapshot.machine == chart.id and chart)
      if not child_chart then fail('no chart for restored child machine %s', tostring(child.snapshot.machine)) end
      snapshot.children[#snapshot.children + 1] = child.id
      effects[#effects + 1] = {kind = 'spawn', id = child.id, chart = child_chart, snapshot = child.snapshot}
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
  return actor
end

function Actor:_read()
  return self._store()
end

function Actor:snapshot() return view(self:_read()) end
function Actor:context() return view(self:_read().context) end
-- 'created' until start(), then the snapshot status (active | done | stopped).
function Actor:status()
  local status = self:_read().status
  if self._status == 'created' then return 'created' end
  return status
end
function Actor:started() return self._status ~= 'created' end
function Actor:states() return view(self:_read().states) end
function Actor:output() return view(self:_read().output) end

function Actor:matches(id)
  local snapshot = self:_read()
  if not self.chart.by_id[id] or id == '' then fail('machine %s has no state %q', self.chart.id, tostring(id)) end
  if self._set_for ~= snapshot then
    local set = {}
    for _, state in ipairs(snapshot.states) do set[state] = true end
    self._set_for, self._set = snapshot, set
  end
  return self._set[id] == true
end

function Actor:has_tag(tag)
  for _, id in ipairs(self:_read().states) do
    if self.chart.by_id[id].tags[tag] then return true end
  end
  return false
end

function Actor:can(event)
  return can(self.chart, self:_read(), event)
end

-- External events the current configuration would accept, for palettes,
-- shortcuts and MCP tools. Requires declared events.
function Actor:accepted()
  local list = {}
  local names = {}
  for name in pairs(self.chart.declared) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    if self:can(name) then list[#list + 1] = name end
  end
  return list
end

function Actor:child(id) return self._children[id] end

function Actor:children()
  local list = {}
  for _, id in ipairs(self:_read().children) do
    if self._children[id] then list[#list + 1] = self._children[id] end
  end
  return list
end

function Actor:observe(fn) return subscribe(self._observers, fn) end

function Actor:persist()
  local snapshot = self._snapshot
  local states = {}
  for i, id in ipairs(snapshot.states) do states[i] = id end
  local out = {machine = snapshot.machine, status = snapshot.status, states = states, context = plain(snapshot.context),
    output = plain(snapshot.output), children = {}}
  for _, id in ipairs(snapshot.children) do
    local child = self._children[id]
    if child then out.children[#out.children + 1] = {id = id, snapshot = child:persist()} end
  end
  return out
end

local function finalize(actor, record, origin)
  actor._sequence = (actor._sequence or 0) + 1
  record.actor, record.machine, record.sequence, record.origin = actor.path, actor.chart.id, actor._sequence, origin
  local snapshot = actor._snapshot
  local states = {}
  for i, id in ipairs(snapshot.states) do states[i] = id end
  record.states, record.status = states, snapshot.status
  record.context = inspectable(snapshot.context)
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
  commit(parent, next_snapshot)
end

-- The actor's root scope, opened on first need (a timer, invoke or task), so
-- actors that never schedule work never touch the scheduler. Child actors
-- nest under their parent's root. A root actor lives in application scope,
-- like spawn_app: it outlives the task that started it (a widget callback,
-- an MCP action) until stop(), done or source reload. Component actors
-- (scope = 'task') hang under the instance scope of the callback that first
-- needed one, so their work ends when the instance unmounts.
local function root_scope(actor)
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

local function run_effects(actor, effects, record)
  local first_error
  for _, effect in ipairs(effects) do
    local ok, err = pcall(function()
      local kind = effect.kind
      if kind == 'action' then
        atomic(effect.label, effect.fn, view(effect.context), view(effect.event), actor)
      elseif kind == 'timer_start' then
        local key = effect.state .. '|' .. effect.delay
        local live = {token = effect.token, state = effect.state, delay = effect.delay, event = effect.event}
        actor._timers[key] = live
        record.timers[#record.timers + 1] = {action = 'started', state = effect.state, delay = effect.delay,
          event = effect.event, token = effect.token}
        actor._scheduler.after(scope_for(actor, effect.state, effect.token), effect.delay, function()
          if actor._timers[key] ~= live then return end
          actor._timers[key] = nil
          actor:_deliver({type = effect.event, state = effect.state, token = effect.token}, 'timer')
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
        local live = {token = effect.token, state = effect.state, id = effect.id, src = effect.src_name}
        actor._invokes[key] = live
        record.invokes[#record.invokes + 1] = {action = 'started', state = effect.state, id = effect.id,
          src = effect.src_name, token = effect.token}
        actor._scheduler.run(scope_for(actor, effect.state, effect.token), function()
          local function send(event)
            if actor._invokes[key] == live then actor:send(event) end
          end
          local ok, result = pcall(effect.src, effect.input, send)
          if actor._invokes[key] ~= live then return end
          actor._invokes[key] = nil
          if ok then
            actor:_deliver({type = 'done.invoke.' .. effect.id, state = effect.state, token = effect.token, output = result}, 'invoke')
          else
            actor:_deliver({type = 'error.invoke.' .. effect.id, state = effect.state, token = effect.token, error = result}, 'invoke')
          end
        end)
      elseif kind == 'invoke_cancel' then
        local key = effect.state .. '|' .. effect.id
        local live = actor._invokes[key]
        if live and live.token == effect.token then
          actor._invokes[key] = nil
          record.invokes[#record.invokes + 1] = {action = 'cancelled', state = effect.state, id = effect.id,
            src = effect.src, token = effect.token}
        end
      elseif kind == 'scope_close' then
        local entry = actor._scopes[effect.state]
        if entry and entry.token == effect.token then
          actor._scopes[effect.state] = nil
          actor._scheduler.close(entry.scope)
        end
      elseif kind == 'spawn' then
        local child = create_actor(effect.chart, {id = effect.id, input = effect.input, parent = actor, snapshot = effect.snapshot,
          scheduler = actor._scheduler, signal = actor._signal_factory, charts = actor._charts})
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
        actor._scheduler.run(scope, function()
          local ok, result = pcall(effect.src, effect.input)
          if actor._tasks[effect.id] ~= live then return end
          actor._tasks[effect.id] = nil
          if ok then
            actor:_deliver({type = 'done.actor.' .. effect.id, id = effect.id, output = result}, 'child')
          else
            actor:_deliver({type = 'error.actor.' .. effect.id, id = effect.id, error = result}, 'child')
          end
          actor._scheduler.close(scope)
        end)
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
      elseif kind == 'send_to' then
        local child = actor._children[effect.id]
        if not child then fail('machine %s has no child %q', actor.chart.id, tostring(effect.id)) end
        child:send(effect.event)
      elseif kind == 'send_parent' then
        if not actor._parent then fail('machine %s has no parent', actor.chart.id) end
        actor._parent:send(effect.event)
      elseif kind == 'done' then
        actor._status = 'done'
        -- A finished actor runs nothing else; its state scopes are closed.
        if actor._root_scope then actor._scheduler.close(actor._root_scope) end
        if actor._parent then
          actor._parent:_deliver({type = 'done.actor.' .. actor.id, id = actor.id, output = effect.output}, 'child')
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

commit = function(actor, snapshot)
  if snapshot ~= actor._snapshot then
    actor._snapshot = snapshot
    actor._store:set(snapshot)
    propagate(actor)
    if next(actor._waiters) then notify_waiters(actor, snapshot) end
  end
end

local function forget_finished_children(actor)
  local live = {}
  for _, id in ipairs(actor._snapshot.children) do live[id] = true end
  for id in pairs(actor._children) do
    if not live[id] and actor._children[id]._status ~= 'running' then actor._children[id] = nil end
  end
end

function Actor:_process()
  if self._processing then return end
  self._processing = true
  local ok, err = pcall(function()
    while #self._queue > 0 do
      local item = table.remove(self._queue, 1)
      local snapshot, effects, record = transition(self.chart, self._snapshot, item.event)
      item.accepted, item.reason = not record.rejected, record.reason
      commit(self, snapshot)
      commits = commits + 1
      record.commit = commits
      local effect_error = run_effects(self, effects, record)
      forget_finished_children(self)
      if wants_records(self) then
        finalize(self, record, item.origin)
        emit(self, record)
      end
      if effect_error then error(effect_error, 0) end
    end
  end)
  self._processing = false
  if not ok then
    self._queue = {}
    error(err, 0)
  end
end

local function enqueue(actor, event, origin)
  local item = {event = event, origin = origin}
  actor._queue[#actor._queue + 1] = item
  actor:_process()
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

function Actor:send(event)
  event = normalize_event(event)
  if internal_type(event.type) then fail('InvalidEvent: %q is reserved for the machine runtime', event.type) end
  if not validate_event(self.chart, event) then return false, 'undeclared' end
  if self._status == 'created' then
    if not self._lazy then fail('machine %s was sent an event before start', self.path) end
    self:start() -- Component machines start on their first event.
  end
  if self._status == 'stopped' then return false, 'stopped' end
  return enqueue(self, event, 'external')
end

-- A plain event binding for widgets: exactly { actor, event, field }.
-- Validated now, like can(), so typos fail at render; the event is neither
-- copied nor frozen (send copies payloads). With `field`, the widget sends a
-- copy of the event with event[field] = its value.
function Actor:event(event, field)
  local normalized = normalize_event(event)
  if internal_type(normalized.type) then fail('InvalidEvent: %q is reserved for the machine runtime', normalized.type) end
  if not self.chart.declared[normalized.type] then
    fail('UnknownEvent: %s does not accept %q', self.chart.id, normalized.type)
  end
  if field ~= nil and (type(field) ~= 'string' or field == '') then fail('event binding field must be a nonempty string') end
  return {actor = self, event = event, field = field}
end

-- Returns a function that sends the event; use for on_press and commands.
function Actor:sender(event)
  normalize_event(event)
  return function() self:send(event) end
end

function Actor:start()
  if self._status ~= 'created' then return self end
  self._status = 'running'
  registry[self.path] = self
  registry_order[#registry_order + 1] = self.path
  if #inspectors > 0 or #self._observers > 0 then
    emit(self, {kind = 'actor', action = 'started', actor = self.path, machine = self.chart.id,
      parent = self._parent and self._parent.path, graph = self.chart:graph()})
  end
  local pending = self._pending
  self._pending = nil
  commits = commits + 1
  pending.record.commit = commits
  self._processing = true
  local ok, err = pcall(function()
    local effect_error = run_effects(self, pending.effects, pending.record)
    if wants_records(self) then
      finalize(self, pending.record, pending.record.event.type == 'ouro.restore' and 'restore' or 'init')
      emit(self, pending.record)
    end
    if effect_error then error(effect_error, 0) end
  end)
  self._processing = false
  if not ok then error(err, 0) end
  self:_process()
  return self
end

function Actor:stop()
  if self._status == 'stopped' then return end
  local was_started = self._status ~= 'created'
  self._status = 'stopped'
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
  self._timers, self._invokes, self._tasks = {}, {}, {}
  for _, entry in pairs(self._scopes) do self._scheduler.close(entry.scope) end
  self._scopes = {}
  if self._root_scope then self._scheduler.close(self._root_scope) end
  for _, id in ipairs(self._snapshot.children) do
    local child = self._children[id]
    if child then child:stop() end
  end
  self._children = {}
  local snapshot = copy(self._snapshot)
  snapshot.status = 'stopped'
  if was_started then commit(self, snapshot) else self._snapshot = snapshot end
  registry[self.path] = nil
  for i, path in ipairs(registry_order) do
    if path == self.path then table.remove(registry_order, i); break end
  end
  if was_started and wants_records(self) then
    finalize(self, record, 'stop')
    emit(self, record)
    emit(self, {kind = 'actor', action = 'stopped', actor = self.path, machine = self.chart.id})
  end
end

---------------------------------------------------------------------------
-- Public chart API
---------------------------------------------------------------------------

function M.create(def)
  local chart = compile(def)
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
    if type(fresh) == 'function' then fresh = atomic('context of ' .. self.id, fresh, options.input) end
    fresh = copy(raw(fresh or {}))
    local old = raw(persisted.context or {})
    for k, v in pairs(old) do
      if fresh[k] == nil or type(fresh[k]) == type(v) then fresh[k] = v end
    end
    return {machine = self.id, status = 'active', states = complete(self, wanted), context = fresh,
      children = persisted.children or {}}
  end
  return chart
end

ouro.machine = M
