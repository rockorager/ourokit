local ouro, view, raw = ...

-- Statechart prototype (design/statecharts.md). A chart is compiled once into
-- nodes with stable dotted IDs. `transition` is a pure macrostep: it returns
-- the next immutable snapshot, the effects to run after commit, and an
-- inspection record. Actors own one ouro.signal holding the snapshot, run the
-- effects, and schedule `after` timers and `invoke` work on a scheduler.

local M = {}
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

-- Deep, serializable copy. Views are unwrapped; functions and cycles fail.
local function plain(value, seen)
  value = raw(value)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' or kind == 'number' or kind == 'string' then return value end
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
  return out
end
M.plain = plain

-- Like plain, but never fails: records must survive arbitrary payloads.
local function inspectable(value, seen)
  value = raw(value)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' or kind == 'number' or kind == 'string' then return value end
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
function M.spawn(chart, options)
  if type(chart) ~= 'table' or not chart.__chart then fail('spawn expects a chart') end
  options = options or {}
  return action('spawn', {chart = chart, id = options.id, input = options.input})
end
function M.stop(id) return action('stop', {id = id}) end
function M.send_to(id, event) return action('send_to', {id = id, event = event}) end
function M.send_parent(event) return action('send_parent', {event = event}) end

local function normalize_event(event)
  if type(event) == 'string' then return {type = event} end
  if type(event) ~= 'table' or type(event.type) ~= 'string' or event.type == '' then
    fail('machine events are strings or tables with a string type')
  end
  return copy(event)
end

local function internal_type(name)
  return name:sub(1, 6) == 'after.' or name:sub(1, 5) == 'done.' or name:sub(1, 6) == 'error.' or name:sub(1, 5) == 'ouro.'
end

---------------------------------------------------------------------------
-- Compilation
---------------------------------------------------------------------------

local STATE_KEYS = {type=true, initial=true, states=true, on=true, always=true, after=true, invoke=true,
  entry=true, exit=true, on_done=true, tags=true, description=true, output=true}
local ROOT_KEYS = {id=true, context=true, guards=true, actions=true, actors=true, events=true}
local TRANSITION_KEYS = {target=true, guard=true, actions=true, reenter=true, description=true}
local INVOKE_KEYS = {id=true, src=true, input=true, on_done=true, on_error=true}
local FIELD_TYPES = {string=true, number=true, integer=true, boolean=true, table=true, any=true}

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
    if sdef.states then
      local keys = {}
      for k in pairs(sdef.states) do
        if type(k) ~= 'string' or not k:match('^[%a_][%w_%-]*$') then
          fail('state key %q in %s must be an identifier', tostring(k), where(node))
        end
        keys[#keys + 1] = k
      end
      table.sort(keys) -- Document order: child keys sort lexically.
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

  local function compile_actions(spec, context)
    if spec == nil then return {} end
    local list = {}
    local items = (type(spec) == 'table' and not spec.__action) and spec or {spec}
    for i = 1, #items do
      local item, name = items[i], nil
      if type(item) == 'string' then
        name = item
        item = actions[name]
        if item == nil then fail('unknown action %q in %s', name, context) end
      end
      if type(item) == 'function' then list[#list + 1] = {kind = 'fn', fn = item, name = name or 'function'}
      elseif type(item) == 'table' and item.__action then
        local a = copy(item); a.kind = item.__action; a.name = name or item.__action; list[#list + 1] = a
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

  local function add_transitions(node, event, spec, kind, into)
    if spec == nil then return end
    local list
    if type(spec) == 'string' then list = {{target = spec}}
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
  return chart
end

local function validate_event(chart, event)
  if not chart.events or internal_type(event.type) then return end
  local fields = chart.events[event.type]
  if not fields then fail('UnknownEvent: %s does not accept %q', chart.id, event.type) end
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
  if chart.events then
    local names = {}
    for name in pairs(chart.events) do names[#names + 1] = name end
    table.sort(names)
    for i, name in ipairs(names) do
      local fields = {}
      for field, spec in pairs(chart.events[name]) do fields[field] = spec.type .. (spec.optional and '?' or '') end
      g.events[i] = {type = name, fields = fields}
    end
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
            if t.guard == nil or t.guard(guard_args()) then
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
    updates = a.updater(m.view(), m.event_view, m.meta())
    if updates == nil then return end
    updates = raw(updates)
    if type(updates) ~= 'table' then fail('assign function must return a table of updates') end
  else
    updates = {}
    for k, v in pairs(a.updater) do
      if type(v) == 'function' then updates[k] = v(m.view(), m.event_view, m.meta()) else updates[k] = v end
    end
  end
  local context = copy(m.context)
  for k, v in pairs(updates) do
    if v == unset then context[k] = nil else context[k] = raw(v) end
  end
  m.context = context
  m.context_view = nil
end

local function evaluate(value, m)
  if type(value) == 'function' then return raw(value(m.view(), m.event_view, m.meta())) end
  return value
end

local function run_actions(m, list)
  for _, a in ipairs(list) do
    m.record.actions[#m.record.actions + 1] = a.name
    if a.kind == 'assign' then apply_assign(m, a)
    elseif a.kind == 'raise' then m.internal[#m.internal + 1] = normalize_event(evaluate(a.event, m))
    elseif a.kind == 'fn' then
      m.effects[#m.effects + 1] = {kind = 'action', fn = a.fn, context = m.context, event = m.event}
    elseif a.kind == 'spawn' then
      local id = evaluate(a.id, m)
      if type(id) ~= 'string' or id == '' or id:find('/', 1, true) then fail('spawned child id must be a nonempty string without /') end
      for _, existing in ipairs(m.children) do
        if existing == id then fail('child %q already exists in %s', id, m.chart.id) end
      end
      m.children[#m.children + 1] = id
      m.effects[#m.effects + 1] = {kind = 'spawn', id = id, chart = a.chart, input = evaluate(a.input, m)}
    elseif a.kind == 'stop' then
      local id = evaluate(a.id, m)
      for i, existing in ipairs(m.children) do
        if existing == id then
          table.remove(m.children, i)
          m.effects[#m.effects + 1] = {kind = 'stop', id = id}
          break
        end
      end
    elseif a.kind == 'send_to' then
      m.effects[#m.effects + 1] = {kind = 'send_to', id = evaluate(a.id, m), event = normalize_event(evaluate(a.event, m))}
    elseif a.kind == 'send_parent' then
      m.effects[#m.effects + 1] = {kind = 'send_parent', event = normalize_event(evaluate(a.event, m))}
    else fail('unknown action kind %s', tostring(a.kind)) end
  end
end

local function cancel_started(m, node)
  if m.pending_start[node] then m.pending_start[node] = nil; return end
  local token = m.started_tokens[node.id]
  if not token or (#node.after == 0 and #node.invokes == 0) then return end
  for _, a in ipairs(node.after) do
    m.effects[#m.effects + 1] = {kind = 'timer_cancel', state = node.id, delay = a.delay, event = a.event, token = token}
  end
  for _, inv in ipairs(node.invokes) do
    m.effects[#m.effects + 1] = {kind = 'invoke_cancel', state = node.id, id = inv.id, src = inv.src_name, token = token}
  end
  m.effects[#m.effects + 1] = {kind = 'scope_close', state = node.id, token = token}
  m.started_tokens[node.id] = nil
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
      run_actions(m, node.entry)
      if node.type == 'final' then
        local parent = node.parent
        local output = node.output and raw(node.output(m.view(), m.event_view, m.meta()))
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
    run_actions(m, node.exit)
    cancel_started(m, node)
    active[node] = nil
    m.entries[node.id] = nil
  end
  for _, t in ipairs(transitions) do run_actions(m, t.actions) end
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
      run_actions(m, node.exit)
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
        local input = inv.input and raw(inv.input(m.view(), m.event_view, m.meta()))
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
  if type(context) == 'function' then context = context(input) end
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
  if event.type:sub(1, 11) == 'done.actor.' then
    local id = event.type:sub(12)
    for i, existing in ipairs(m.children) do
      if existing == id then
        table.remove(m.children, i)
        event.index = i -- Position the child had, for selection updates.
        record.children[#record.children + 1] = {action = 'done', id = id}
        child_changed = true
        break
      end
    end
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
  if chart.events and not internal_type(event.type) and not chart.events[event.type] then
    fail('UnknownEvent: %s does not accept %q', chart.id, event.type)
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

function M.actors()
  local list = {}
  for _, path in ipairs(registry_order) do
    if registry[path] then list[#list + 1] = registry[path] end
  end
  return list
end

local function spawn_task(fn)
  local spawn_app = ouro.spawn_app
  if spawn_app and pcall(spawn_app, fn) then return end
  ouro.spawn(fn)
end

-- The scheduler seam. Each active state entry with after/invoke work opens
-- one scope; timers and invokes run inside it; exiting closes it. Phase 2
-- replaces this with native child task scopes that cancel the work. Today
-- spawned work has no handle, so tasks run in application scope and a closed
-- scope only drops their delivery (and the per-entry token rejects
-- anything that slips through).
M.default_scheduler = {
  open = function() return {alive = true} end,
  close = function(scope) scope.alive = false end,
  run = function(scope, fn) spawn_task(function() if scope.alive then fn() end end) end,
  after = function(scope, delay, fn)
    spawn_task(function() ouro.sleep(delay); if scope.alive then fn() end end)
  end,
}

-- Deterministic scheduler for tests: virtual time and explicit task runs.
function M.manual_scheduler()
  local s = {now = 0, timers = {}, tasks = {}, sequence = 0, open_scopes = 0}
  function s.open() s.open_scopes = s.open_scopes + 1; return {alive = true} end
  function s.close(scope)
    if scope.alive then s.open_scopes = s.open_scopes - 1 end
    scope.alive = false
  end
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
  local actor = {chart = chart, id = options.id or chart.id, _observers = {}, _queue = {}, _timers = {}, _invokes = {}, _scopes = {},
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
          local input = inv.input and raw(inv.input(view(snapshot.context), view({type = 'ouro.restore'})))
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
function Actor:status() return self:_read().status end
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
  if not self.chart.events then return list end
  local names = {}
  for name in pairs(self.chart.events) do names[#names + 1] = name end
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

local function scope_for(actor, state, token)
  local entry = actor._scopes[state]
  if entry and entry.token == token then return entry.scope end
  if entry then actor._scheduler.close(entry.scope) end
  entry = {token = token, scope = actor._scheduler.open()}
  actor._scopes[state] = entry
  return entry.scope
end

local function run_effects(actor, effects, record)
  local first_error
  for _, effect in ipairs(effects) do
    local ok, err = pcall(function()
      local kind = effect.kind
      if kind == 'action' then
        effect.fn(view(effect.context), view(effect.event), actor)
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
        child:start()
      elseif kind == 'stop' then
        local child = actor._children[effect.id]
        actor._children[effect.id] = nil
        if child then
          record.children[#record.children + 1] = {action = 'stopped', id = effect.id, machine = child.chart.id}
          child:stop()
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
        if actor._parent then
          actor._parent:_deliver({type = 'done.actor.' .. actor.id, id = actor.id, output = effect.output}, 'child')
        end
      end
    end)
    if not ok and not first_error then first_error = err end
  end
  return first_error
end

local function commit(actor, snapshot)
  if snapshot ~= actor._snapshot then
    actor._snapshot = snapshot
    actor._store:set(snapshot)
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
      commit(self, snapshot)
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

function Actor:_deliver(event, origin)
  if self._status ~= 'running' and self._status ~= 'done' then return end
  self._queue[#self._queue + 1] = {event = event, origin = origin}
  self:_process()
end

function Actor:send(event)
  if self._status == 'created' then fail('machine %s was sent an event before start', self.path) end
  event = normalize_event(event)
  if internal_type(event.type) then fail('InvalidEvent: %q is reserved for the machine runtime', event.type) end
  validate_event(self.chart, event)
  if self._status == 'stopped' then return end
  self._queue[#self._queue + 1] = {event = event, origin = 'external'}
  self:_process()
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
  self._timers, self._invokes = {}, {}
  for _, entry in pairs(self._scopes) do self._scheduler.close(entry.scope) end
  self._scopes = {}
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
    if type(fresh) == 'function' then fresh = fresh(options.input) end
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
