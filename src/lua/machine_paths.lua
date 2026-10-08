local ouro, M = ...
-- Generated chart tests (design/statecharts.md §14). A breadth-first search
-- over real actor runs finds event paths that reach every reachable state
-- and take every transition it can. Each search node is a path of inputs,
-- re-run from a fresh actor on a virtual replay scheduler, so timers, guards,
-- assigns and stubbed invokes behave exactly as they would in replay. Event
-- payloads are guard-aware: candidates come from the event schema and from
-- the values in the node's context (ids, names, numbers), plus payloads and
-- invoke results harvested from recordings. Selected paths are rendered as
-- replay logs, which `ouroctl test` runs (`*_test.jsonl`).

local json = ouro.json
local safe = M._canonical_safe

-- Deterministic text for a value: sorted keys, so states dedupe reliably.
local function canonical(value, depth)
  value = M.raw(value)
  depth = depth or 0
  local kind = type(value)
  if kind == 'string' then return string.format('%q', value) end
  if kind ~= 'table' then return tostring(value) end
  if depth > 8 then return '{...}' end
  local keys = {}
  for k in pairs(value) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    if type(a) == type(b) then return a < b end
    return type(a) < type(b)
  end)
  local parts = {}
  for i, k in ipairs(keys) do parts[i] = tostring(k) .. '=' .. canonical(value[k], depth + 1) end
  return '{' .. table.concat(parts, ',') .. '}'
end

-- Strings and integers found in a context, for guard-aware payloads.
local function harvest(value, strings, numbers, budget)
  value = M.raw(value)
  if budget.left <= 0 then return end
  budget.left = budget.left - 1
  if type(value) == 'string' then
    if #value <= 64 then strings[value] = true end
  elseif math.type(value) == 'integer' then
    numbers[value] = true
  elseif type(value) == 'table' then
    -- Keys too: a field name in context is often a valid payload value.
    for k, v in pairs(value) do
      if type(k) == 'string' and #k <= 64 then strings[k] = true end
      harvest(v, strings, numbers, budget)
    end
  end
end

local function sorted_keys(set, limit)
  local list = {}
  for k in pairs(set) do list[#list + 1] = k end
  table.sort(list)
  while #list > limit do table.remove(list) end
  return list
end

local function domain(kind, strings, numbers)
  if kind == 'string' then
    local out = {}
    for _, s in ipairs(strings) do out[#out + 1] = s end
    out[#out + 1] = ''
    out[#out + 1] = 'x'
    return out
  elseif kind == 'integer' then
    local out, seen = {}, {}
    for _, n in ipairs(numbers) do for _, v in ipairs({n, n + 1}) do
      if not seen[v] then seen[v] = true; out[#out + 1] = v end
    end end
    for _, v in ipairs({0, 1, -1}) do if not seen[v] then seen[v] = true; out[#out + 1] = v end end
    return out
  elseif kind == 'number' then return {0, 0.5, 1}
  elseif kind == 'boolean' then return {true, false}
  elseif kind == 'table' then return {{}}
  end
  return {'x', 1, true}
end

-- Payload candidates for one event type at one node.
local function payloads(chart, name, context, seeds, limit)
  local out, seen = {}, {}
  local function add(event)
    local key = canonical(event)
    if not seen[key] and #out < limit then seen[key] = true; out[#out + 1] = event end
  end
  for _, event in ipairs(seeds[name] or {}) do add(event) end
  local fields = chart.events and chart.events[name]
  if not fields then add({type = name}); return out end
  local strings, numbers = {}, {}
  harvest(context, strings, numbers, {left = 400})
  local string_list, number_list = sorted_keys(strings, 12), sorted_keys(numbers, 4)
  local names = {}
  for field in pairs(fields) do names[#names + 1] = field end
  table.sort(names)
  local partial = {{type = name}}
  for _, field in ipairs(names) do
    local spec = fields[field]
    local values = domain(spec.type, string_list, number_list)
    local next_partial = {}
    for _, base in ipairs(partial) do
      if spec.optional then next_partial[#next_partial + 1] = base end
      for _, v in ipairs(values) do
        local e = {}
        for k, x in pairs(base) do e[k] = x end
        e[field] = v
        next_partial[#next_partial + 1] = e
        if #next_partial >= 400 then break end
      end
    end
    partial = next_partial
  end
  -- Spread the picks over the whole product instead of its first rows, so
  -- every field varies.
  local room = limit - #out
  if #partial <= room then
    for _, e in ipairs(partial) do add(e) end
  elseif room > 0 then
    for i = 0, room - 1 do add(partial[1 + (i * (#partial - 1)) // math.max(1, room - 1)]) end
  end
  return out
end

local function copy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

local function live_actors(root)
  local list = {root}
  local i = 1
  while list[i] do
    local actor = list[i]
    for _, id in ipairs(actor._snapshot.children) do
      local child = actor._children[id]
      if child and child._status == 'running' then list[#list + 1] = child end
    end
    i = i + 1
  end
  return list
end

-- Applies one input; false when it does not apply (no timer, no stub, an
-- invalid payload or a raising step).
local function apply(scheduler, root, input)
  if input.k == 'event' then
    local target = root
    if input.a ~= root.path then
      target = nil
      for _, actor in ipairs(live_actors(root)) do if actor.path == input.a then target = actor end end
      if not target then return false end
    end
    local ok, accepted
    if input.o == 'surface' then ok, accepted = pcall(target._deliver, target, copy(input.e), 'surface')
    else ok, accepted = pcall(target._send, target, copy(input.e), 'external') end
    return ok and accepted ~= false
  elseif input.k == 'timer' then
    local at = scheduler.logical.next()
    if not at then return false end
    scheduler.logical.advance_to(at)
    return true
  end
  local info = scheduler.find(input.a, input.k, input.id, true)
  if not info then return false end
  return (pcall(info.complete, input.ok, input.value))
end

-- Runs a path from a fresh actor. Returns the actor and scheduler (or nil if
-- an input did not apply) and the coverage it reached.
local function run(chart, setup, path, covered)
  local scheduler = M._replay_scheduler(0)
  local saved = M._hooks
  M._hooks = {scheduler = scheduler, enter = function() end, leave = function() end,
    step = function(actor, record)
      if covered and actor._parent == nil then
        -- States entered in passing (an always chain) count too.
        for _, micro in ipairs(record.microsteps or {}) do
          for _, t in ipairs(micro.transitions or {}) do covered['t' .. t.index] = true end
          for _, id in ipairs(micro.entered or {}) do covered['s' .. id] = true end
        end
        for _, id in ipairs(actor._snapshot.states) do covered['s' .. id] = true end
      end
    end}
  local ok, actor, applied = pcall(function()
    local actor = chart:actor {id = chart.id, input = setup.input, scheduler = scheduler}
    actor:start()
    for _, input in ipairs(path) do
      if not apply(scheduler, actor, input) then return actor, false end
    end
    return actor, true
  end)
  M._hooks = saved
  if not ok then return nil end
  if not applied then actor:stop(); return nil end
  return actor, scheduler
end

local function node_key(actor, scheduler)
  local parts = {}
  for _, a in ipairs(live_actors(actor)) do
    parts[#parts + 1] = a.path .. ':' .. table.concat(a._snapshot.states, ',') .. ':' .. a._snapshot.status
      .. ':' .. canonical(a._snapshot.context)
  end
  local timers = {}
  for _, t in ipairs(scheduler.logical.timers) do
    if t.scope.alive then timers[#timers + 1] = tostring(t.at - scheduler.logical.now()) end
  end
  local stubs = {}
  for _, item in ipairs(scheduler.pending) do
    if item.scope.alive then stubs[#stubs + 1] = item.info.kind .. '|' .. item.info.actor .. '|' .. item.info.id end
  end
  return table.concat(parts, ';') .. '|' .. table.concat(timers, ',') .. '|' .. table.concat(stubs, ',')
end

local function candidates(chart, actor, scheduler, options)
  local list = {}
  for _, target in ipairs(live_actors(actor)) do
    if target == actor or options.children ~= false then
      local names = {}
      for name in pairs(target.chart.declared) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        if target:handles(name) then
          for _, e in ipairs(payloads(target.chart, name, target._snapshot.context, options.seeds, options.payloads)) do
            list[#list + 1] = {k = 'event', a = target.path, e = e}
          end
        end
      end
      -- Surface events the active states name explicitly (the runtime
      -- delivers them; failures carry reason and message).
      local surface = {}
      for _, id in ipairs({'', table.unpack(target._snapshot.states)}) do
        for name in pairs(target.chart.by_id[id].on) do
          if name:find('^surface%.') and not name:find('*', 1, true) then surface[name] = true end
        end
      end
      for _, name in ipairs(sorted_keys(surface, 16)) do
        local e = {type = name}
        if name:find('^surface%.failed') then e.reason, e.message = 'generated', 'generated failure' end
        list[#list + 1] = {k = 'event', o = 'surface', a = target.path, e = e}
      end
    end
  end
  if scheduler.logical.next() then list[#list + 1] = {k = 'timer'} end
  for _, item in ipairs(scheduler.pending) do
    local info = item.info
    if item.scope.alive then
      local outputs = options.outputs[info.src or ''] or options.outputs[info.id] or {json.null, {}}
      for _, value in ipairs(outputs) do
        list[#list + 1] = {k = info.kind, a = info.actor, id = info.id, ok = true, value = value}
      end
      list[#list + 1] = {k = info.kind, a = info.actor, id = info.id, ok = false,
        value = (options.errors[info.src or ''] or options.errors[info.id] or {'generated error'})[1]}
    end
  end
  return list
end

local function describe_input(input)
  if input.k == 'event' then return input.e.type end
  if input.k == 'timer' then return 'timer' end
  return (input.ok and 'done.' or 'error.') .. input.k .. '.' .. input.id
end

-- Harvests event payloads and invoke/task results from recordings.
local function seed(options, logs)
  options.seeds, options.outputs, options.errors = options.seeds or {}, options.outputs or {}, options.errors or {}
  for _, text in ipairs(logs or {}) do
    local ok, _, entries = pcall(M._decode_log, text)
    if ok then
      for _, entry in ipairs(entries) do
        local e = entry.e
        if entry.k == 'event' and e and entry.o ~= 'surface' and entry.o ~= 'runtime' then
          options.seeds[e.type] = options.seeds[e.type] or {}
          table.insert(options.seeds[e.type], e)
        elseif (entry.k == 'invoke' or entry.k == 'task') and e then
          -- Keyed by id, and by src for tasks: spawned ids are `<src>.<n>`.
          local id = e.type:match('^%a+%.%a+%.(.+)$')
          local keys = {id}
          if entry.k == 'task' and id:find('%.%d+$') then keys[2] = id:gsub('%.%d+$', '') end
          for _, key in ipairs(keys) do
            if e.type:find('^done') then
              options.outputs[key] = options.outputs[key] or {}
              table.insert(options.outputs[key], e.output == nil and json.null or e.output)
            else
              options.errors[key] = options.errors[key] or {}
              table.insert(options.errors[key], e.error)
            end
          end
        end
      end
    end
  end
end

-- paths(chart, options) -> {paths = {{inputs, targets}}, reached, unreached, nodes}
-- options: depth (8), nodes (600), payloads per event (6), input, seeds,
-- outputs/errors by invoke src or id, logs (recordings to harvest).
function M.paths(chart, options)
  options = options or {}
  seed(options, options.logs)
  options.depth, options.nodes, options.payloads = options.depth or 8, options.nodes or 1500, options.payloads or 6
  local saved_strict, saved_origin = M.strict, M._origin
  M.strict, M._origin = true, 'generated'
  local graph = chart:graph()
  local targets = {}
  for _, state in ipairs(graph.states) do if state.id ~= '' then targets[#targets + 1] = 's' .. state.id end end
  for _, t in ipairs(graph.transitions) do targets[#targets + 1] = 't' .. t.index end
  local setup = {input = options.input}
  -- Find an input that builds the initial context.
  if not run(chart, setup, {}) then
    setup.input = {}
    if not run(chart, setup, {}) then
      M.strict, M._origin = saved_strict, saved_origin
      return nil, 'the chart cannot start without input'
    end
  end
  local first = {}
  local function cover(path, covered)
    local new = false
    for target in pairs(covered) do if not first[target] then first[target] = path; new = true end end
    return new
  end
  local covered = {}
  local root, scheduler = run(chart, setup, {}, covered)
  cover({}, covered)
  local seen = {[node_key(root, scheduler)] = true}
  root:stop()
  -- Coverage-guided breadth-first: paths that reached something new are
  -- expanded before the rest of their depth.
  local hot, queue, head, visited = {}, {{}}, 1, 0
  local function done()
    for _, t in ipairs(targets) do if not first[t] then return false end end
    return true
  end
  while (hot[1] or queue[head]) and visited < options.nodes and not done() do
    local path = table.remove(hot, 1)
    if not path then path = queue[head]; head = head + 1 end
    if #path < options.depth then
      local actor, sched = run(chart, setup, path)
      if actor then
        local list = candidates(chart, actor, sched, options)
        actor:stop()
        for _, input in ipairs(list) do
          local next_path = {}
          for i, x in ipairs(path) do next_path[i] = x end
          next_path[#next_path + 1] = input
          local reached = {}
          local child, child_scheduler = run(chart, setup, next_path, reached)
          visited = visited + 1
          if child then
            local new = cover(next_path, reached)
            local key = node_key(child, child_scheduler)
            child:stop()
            if not seen[key] then
              seen[key] = true
              if new then hot[#hot + 1] = next_path else queue[#queue + 1] = next_path end
            end
          end
          if visited >= options.nodes then break end
        end
      end
    end
  end
  -- Greedy cover in document order: states first, then transitions.
  local selected, chosen = {}, {}
  for _, target in ipairs(targets) do
    local path = first[target]
    if path and not chosen[target] then
      local reached = {}
      local actor = run(chart, setup, path, reached)
      if actor then actor:stop() end
      local names = {}
      for _, t in ipairs(targets) do
        if reached[t] and not chosen[t] then chosen[t] = true; names[#names + 1] = t end
      end
      local inputs = {}
      for i, input in ipairs(path) do inputs[i] = describe_input(input) end
      selected[#selected + 1] = {inputs = path, steps = inputs, targets = names}
    end
  end
  local unreached = {}
  for _, t in ipairs(targets) do if not first[t] then unreached[#unreached + 1] = t end end
  M.strict, M._origin = saved_strict, saved_origin
  local states, transitions = 0, 0
  for _, t in ipairs(targets) do
    if t:sub(1, 1) == 's' then states = states + 1 else transitions = transitions + 1 end
  end
  local reached_states, reached_transitions = 0, 0
  for t in pairs(first) do
    if t:sub(1, 1) == 's' then reached_states = reached_states + 1 else reached_transitions = reached_transitions + 1 end
  end
  -- The first path that reached each state, for the state stories.
  local reach = {}
  for _, t in ipairs(targets) do
    if t:sub(1, 1) == 's' and first[t] then reach[#reach + 1] = {state = t:sub(2), inputs = first[t]} end
  end
  return {chart = chart.id, setup = setup, paths = selected, unreached = unreached, nodes = visited, reach = reach,
    states = {reached = reached_states, total = states}, transitions = {reached = reached_transitions, total = transitions}}
end

-- Renders selected paths as one replay log: start, inputs, stop per path.
function M.paths_log(chart, result, options)
  options = options or {}
  local lines = {}
  local scheduler = M._replay_scheduler(0)
  local saved_strict, saved_origin = M.strict, M._origin
  M.strict, M._origin = true, 'generated'
  local described = {}
  for i, path in ipairs(result.paths) do described[i] = {steps = json.array(path.steps), targets = json.array(path.targets)} end
  lines[1] = M._json_encode({format = 'ouro.machine.log', version = 2, t0 = 0, app = options.app,
    generated = {chart = chart.id, states = result.states, transitions = result.transitions,
      unreached = json.array(result.unreached), paths = described}})
  local recorder = M.recorder(function(line) lines[#lines + 1] = line end, {scheduler = scheduler, t0 = 0, header = false})
  local ok, err = pcall(function()
    for _, path in ipairs(result.paths) do
      local actor = chart:actor {id = chart.id, input = result.setup.input, scheduler = scheduler}
      actor:start()
      for _, input in ipairs(path.inputs) do
        if not apply(scheduler, actor, input) then error('a generated path no longer applies: ' .. describe_input(input), 0) end
      end
      actor:stop()
    end
  end)
  recorder.stop()
  M.strict, M._origin = saved_strict, saved_origin
  if not ok then error(err, 0) end
  return table.concat(lines, '\n') .. '\n'
end

local function summary_line(result)
  local text = string.format('%s: %d paths reach %d/%d states and %d/%d transitions (%d runs)', result.chart,
    #result.paths, result.states.reached, result.states.total, result.transitions.reached, result.transitions.total,
    result.nodes)
  if #result.unreached > 0 then
    local names = {}
    for i, t in ipairs(result.unreached) do
      names[i] = (t:sub(1, 1) == 's' and 'state ' or 'transition #') .. t:sub(2)
    end
    text = text .. '\n  not reached: ' .. table.concat(names, ', ')
  end
  return text
end

-- `ouroctl test --generate`: generate_tool(recordings, options_json) -> json, ok
-- Generates for every chart the app module created (or options.charts).
function M.generate_tool(recordings, options_json)
  local options = options_json ~= '' and json.decode(options_json) or {}
  local logs = {}
  if recordings ~= '' then
    for block in (recordings .. '\n\30'):gmatch('(.-)\n\30') do
      if block:find('%S') then logs[#logs + 1] = block end
    end
  end
  local ids = {}
  for id in pairs(M.charts()) do ids[#ids + 1] = id end
  table.sort(ids)
  local files, summaries, ok = {}, {}, true
  local plan = {charts = {}}
  for _, id in ipairs(ids) do
    local wanted = not options.charts or false
    for _, name in ipairs(options.charts or {}) do if name == id then wanted = true end end
    if wanted then
      local chart = M.charts()[id]
      local result, err = M.paths(chart, {depth = options.depth, nodes = options.nodes, logs = logs})
      if not result then
        summaries[#summaries + 1] = id .. ': skipped (' .. tostring(err) .. ')'
      else
        local rendered, text = pcall(M.paths_log, chart, result, {app = options.app})
        if rendered then
          files[id .. '_paths_test.jsonl'] = text
          summaries[#summaries + 1] = summary_line(result)
          local states = {}
          for i, item in ipairs(result.reach) do
            local steps = {}
            for j, input in ipairs(item.inputs) do steps[j] = describe_input(input) end
            states[i] = {state = item.state, inputs = item.inputs, steps = json.array(steps)}
          end
          plan.charts[#plan.charts + 1] = {chart = id, input = result.setup.input, states = states}
        else
          ok = false
          summaries[#summaries + 1] = id .. ': rendering failed: ' .. tostring(text)
        end
      end
    end
  end
  if options.entry and #plan.charts > 0 then
    files['states.stories.lua'] = M.state_stories_source(options.entry, plan)
    local count = 0
    for _, c in ipairs(plan.charts) do count = count + #c.states end
    summaries[#summaries + 1] = string.format('states.stories.lua: %d stories, one per reached state', count)
  end
  return json.encode({files = files, summary = table.concat(summaries, '\n')}), ok
end

---------------------------------------------------------------------------
-- State stories: one Storybook frame per state a chart reaches. The story
-- re-runs the first path that reached the state at catalog time and renders
-- the app's view of that actor (story_views.lua: {[chart id] = function(actor)
-- return content end, viewport = {...}}), or a generic panel of the chart's
-- configuration and context.
---------------------------------------------------------------------------

-- Each value is encoded on its own, under the JSON encoder's per-call value
-- limit, and invoke/task results are shared: a big `load` output appears once.
local function long_string(text)
  local level = '='
  while text:find(']' .. level .. ']', 1, true) do level = level .. '=' end
  return '[' .. level .. '[' .. text .. ']' .. level .. ']'
end

function M.state_stories_source(entry, plan)
  local out = {
    '-- Generated by `ouroctl test --generate`: one story per state each chart',
    '-- reaches, at the end of the first path that reached it (design/statecharts.md',
    '-- section 14). Regenerate instead of editing. Optional story_views.lua maps',
    '-- chart ids to view functions; other charts render a state panel.',
    '--   ouroctl storybook snapshot states.stories.lua --output <dir>',
    "local ouro = require('ouro')",
    "for _, name in ipairs({'app', 'window', 'layer_surface', 'lock_surface'}) do",
    '  if ouro[name] == nil then ouro[name] = function(t) return t end end',
    'end',
    'ouro.xdg = ouro.xdg or {}',
    'ouro.xdg.paths = ouro.xdg.paths or function(id)',
    "  local root = '/nonexistent/ourokit-stories/'",
    "  return {config = root .. 'config/' .. id, data = root .. 'data/' .. id, state = root .. 'state/' .. id,",
    "    cache = root .. 'cache/' .. id, config_dirs = {}, data_dirs = {}}",
    'end',
    string.format('require(%q)', entry),
    "local has_views, views = pcall(require, 'story_views')",
    'local decode = ouro.machine._json_decode',
    'local values = {}',
  }
  local refs, count = {}, 0
  local function ref(value)
    local key = canonical(value)
    if not refs[key] then
      count = count + 1
      refs[key] = count
      out[#out + 1] = 'values[' .. count .. '] = decode(' .. long_string(M._json_encode({value = value})) .. ').value'
    end
    return refs[key]
  end
  local charts = {}
  for _, chart in ipairs(plan.charts) do
    local states = {}
    for _, item in ipairs(chart.states) do
      local inputs = {}
      for i, input in ipairs(item.inputs) do
        local copy_of = {}
        for k, v in pairs(input) do copy_of[k] = v end
        if copy_of.value ~= nil then copy_of.vref, copy_of.value = ref(copy_of.value), nil end
        inputs[i] = copy_of
      end
      states[#states + 1] = string.format('    {state = %q, steps = decode(%s), inputs = decode(%s)},', item.state,
        long_string(M._json_encode(item.steps or json.array({}))), long_string(M._json_encode(json.array(inputs))))
    end
    charts[#charts + 1] = string.format('  {chart = %q, input = decode(%s).input, states = {\n%s\n  }},', chart.chart,
      long_string(M._json_encode({input = chart.input})), table.concat(states, '\n'))
  end
  out[#out + 1] = 'local plan = {values = values, charts = {'
  out[#out + 1] = table.concat(charts, '\n')
  out[#out + 1] = '}}'
  out[#out + 1] = 'return ouro.machine.state_stories(plan, has_views and views or nil)'
  out[#out + 1] = ''
  return table.concat(out, '\n')
end

local function short(value)
  local ok, text = pcall(json.encode, safe(value))
  text = ok and text or tostring(value)
  if #text > 90 then text = text:sub(1, 87) .. '...' end
  return text
end

local function panel(chart, actor, state, steps, active)
  return function()
    local snapshot = actor._snapshot
    local rows = {
      ouro.text {key = 'title', text = chart.id .. ' · ' .. state, size = 20},
      ouro.text {key = 'path', text = 'path: ' .. (#steps > 0 and table.concat(steps, ' → ') or '(initial state)')},
      ouro.text {key = 'status', text = active and 'active after the path' or 'passed through on the path (an always chain)'},
      ouro.text {key = 'states', text = 'configuration', size = 16},
    }
    for i, node in ipairs(chart.nodes) do
      if node.id ~= '' then
        local on = M.matches(snapshot, node.id)
        rows[#rows + 1] = ouro.text {key = 's' .. i, text = string.rep('    ', node.depth - 1) .. (on and '● ' or '○ ') .. node.key,
          foreground = node.id == state and '#1565c0' or (on and '#2e7d32' or '#9e9e9e')}
      end
    end
    rows[#rows + 1] = ouro.text {key = 'context', text = 'context', size = 16}
    local keys = {}
    for k in pairs(snapshot.context) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for i, k in ipairs(keys) do
      rows[#rows + 1] = ouro.text {key = 'c' .. i, text = k .. ' = ' .. short(snapshot.context[k])}
    end
    return ouro.box {key = 'panel', width = 'fill', height = 'fill', padding = 16, background = '#ffffff',
      ouro.column {key = 'rows', gap = 4, children = rows}}
  end
end

function M.state_stories(plan, views)
  views = views or {}
  local stories = {}
  for _, entry in ipairs(plan.charts) do
    local chart = M.charts()[entry.chart]
    if chart then
      for _, item in ipairs(entry.states) do
        -- The actor stays running: the story renders its snapshot.
        local inputs = {}
        for i, input in ipairs(item.inputs) do
          inputs[i] = input
          if input.vref then
            inputs[i] = {}
            for k, v in pairs(input) do inputs[i][k] = v end
            inputs[i].value, inputs[i].vref = plan.values[input.vref], nil
          end
        end
        local actor = run(chart, {input = entry.input}, inputs)
        if not actor then
          error(string.format('the generated path to %s.%s no longer applies; regenerate with ouroctl test --generate',
            entry.chart, item.state), 0)
        end
        do
          local active = M.matches(actor._snapshot, item.state)
          local view = views[entry.chart]
          local id = entry.chart .. '/' .. item.state:gsub('%.', '-')
          stories[#stories + 1] = ouro.story {
            id = id, group = entry.chart,
            name = item.state .. (active and '' or ' (passed through)'),
            viewport = view and (views.viewport or {width = 480, height = 520}) or {width = 720, height = 760},
            color_scheme = 'light',
            content = view and view(actor) or panel(chart, actor, item.state, item.steps or {}, active),
          }
        end
      end
    end
  end
  return ouro.storybook {title = 'Generated chart states', stories = stories}
end
