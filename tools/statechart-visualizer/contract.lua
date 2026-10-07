-- Adapter from the interpreter's inspection contract (design/statecharts.md
-- §10: `chart:graph()` format 'ouro.machine.graph' v1, and transition/actor
-- records from `actor:observe` / `ouro.machine.inspect`) to the visualizer's
-- model. Every assumption about those shapes lives here.
local M = {}

local function list(value)
  if value == nil or value == M.null then return {} end
  if type(value) ~= 'table' then return {value} end
  return value
end

-- JSON null from records decoded off the wire; set by the caller (ouro.json.null).
M.null = nil

-- Events that never come in through the inlet manifold.
function M.is_internal(event)
  return event:find('^done%.') or event:find('^error%.') or event:find('^after%.') or event:find('^ouro%.')
end

local function delay_of(t)
  return t.delay or (t.event and tonumber(t.event:match('^after%.(%d+)%.')))
end

-- Short pipe label for a transition.
function M.event_label(t)
  if t.kind == 'after' then
    local d = t.after or 0
    return d % 1000 == 0 and ('after ' .. (d // 1000) .. 's') or ('after ' .. d .. 'ms')
  end
  if t.kind == 'always' then return 'always' end
  if t.kind == 'invoke.done' then return 'done' end
  if t.kind == 'invoke.error' then return 'error' end
  if t.kind == 'done' then return 'done' end
  return t.event or '?'
end

function M.graph(raw)
  assert(type(raw) == 'table' and type(raw.states) == 'table', 'graph needs a states array')
  assert(raw.format == nil or raw.format == 'ouro.machine.graph', 'unknown graph format ' .. tostring(raw.format))
  assert(raw.version == nil or raw.version == 1, 'unsupported graph version ' .. tostring(raw.version))
  local g = {id=raw.id or 'machine', root=raw.root or '', states={}, by_id={}, transitions={}, events={},
    transition_by_id={}}
  for index, s in ipairs(raw.states) do
    local parent = s.parent ~= M.null and s.parent or nil
    local state = {
      id=s.id, parent=parent, index=index, depth=s.depth or 0,
      initial=s.initial ~= M.null and s.initial or nil,
      label=(s.id == g.root) and g.id or (s.key or s.id:match('([^%.]+)$')),
      kind=s.type or s.kind or 'atomic', children={}, after={}, invoke={}, tags=list(s.tags),
    }
    for _, a in ipairs(list(s.after)) do state.after[#state.after+1] = {delay=a.delay, event=a.event} end
    for _, v in ipairs(list(s.invoke)) do state.invoke[#state.invoke+1] = {id=v.id, src=v.src or v.id} end
    for _, child in ipairs(list(s.children)) do state.children[#state.children+1] = child end
    g.states[index], g.by_id[s.id] = state, state
  end
  for _, state in ipairs(g.states) do
    if #state.children == 0 and state.kind ~= 'final' then state.kind = 'atomic' end
  end
  local seen = {}
  for i, t in ipairs(raw.transitions or {}) do
    local targets = list(t.targets)
    local transition = {
      id=t.index or i, index=t.index or i, source=t.source, event=t.event ~= M.null and t.event or nil,
      kind=t.kind or 'event', targets=targets,
      guard=t.guarded and (t.guard ~= M.null and t.guard or true) or nil,
      internal=#targets == 0,
    }
    if transition.kind == 'after' then transition.after = delay_of(t) end
    if transition.kind == 'always' then transition.always = true end
    transition.label = M.event_label(transition)
    g.transitions[#g.transitions+1] = transition
    g.transition_by_id[transition.id] = transition
    if transition.kind == 'event' and transition.event and not M.is_internal(transition.event)
      and transition.event ~= '*' and not seen[transition.event] then
      seen[transition.event] = true
      g.events[#g.events+1] = transition.event
    end
  end
  -- Declared external events, even ones no transition handles yet.
  for _, e in ipairs(list(raw.events)) do
    local name = type(e) == 'table' and e.type or e
    if not seen[name] then seen[name] = true; g.events[#g.events+1] = name end
  end
  -- Attach each after-transition to its source state's gauge.
  for _, t in ipairs(g.transitions) do
    if t.after then
      local state = g.by_id[t.source]
      for _, a in ipairs(state.after) do if a.delay == t.after then a.transition = t.id end end
    end
  end
  return g
end

local function event_of(raw)
  if raw == nil or raw == M.null then return nil end
  if type(raw) == 'string' then return {type=raw} end
  return raw
end

-- Normalizes one transition record. Times are ms relative to `t0` (the
-- actor's start on the scheduler clock). `time_ms` is the interpreter's
-- scheduler clock; `fallback` (receive time) applies to clockless records.
function M.record(raw, t0, fallback)
  local time = raw.time_ms and raw.time_ms ~= M.null and (raw.time_ms - (t0 or raw.time_ms)) or fallback
  local r = {
    seq=raw.sequence or raw.seq, actor=raw.actor, machine=raw.machine,
    time=time, timed=time ~= nil,
    event=event_of(raw.event), origin=raw.origin or 'external',
    rejected=raw.rejected == true, reason=raw.reason ~= M.null and raw.reason or nil,
    microsteps={}, exited=list(raw.exited), entered=list(raw.entered), taken={},
    timers={}, invokes={}, children=list(raw.children), actions=list(raw.actions),
    context=raw.context ~= M.null and raw.context or {}, status=raw.status, can=raw.can,
  }
  -- Post-step guard outcomes: an array of {index, passed[, error]}. JSON
  -- turns an empty array into an object, which still iterates as empty.
  if raw.guards and raw.guards ~= M.null then
    r.guards = {}
    for _, v in pairs(raw.guards) do
      if type(v) == 'table' and v.index then r.guards[v.index] = v.passed == true end
    end
  end
  -- Older feeds sent accepted events instead of guard outcomes.
  if not r.guards and raw.accepted and raw.accepted ~= M.null then
    r.can = r.can or {}
    for _, event in ipairs(raw.accepted) do r.can[event] = true end
    r.accepted = true
  end
  -- `states` excludes the root; the root is active while the actor is.
  r.configuration = {''}
  for _, id in ipairs(list(raw.states)) do r.configuration[#r.configuration+1] = id end
  for _, step in ipairs(list(raw.microsteps)) do
    local m = {event=event_of(step.event), transitions={}, exited=list(step.exited), entered=list(step.entered)}
    for _, t in ipairs(list(step.transitions)) do
      local id = type(t) == 'table' and t.index or t
      m.transitions[#m.transitions+1] = id
      r.taken[#r.taken+1] = id
    end
    r.microsteps[#r.microsteps+1] = m
  end
  for _, t in ipairs(list(raw.timers)) do
    local started = t.time_ms and t.time_ms ~= M.null and (t.time_ms - (t0 or t.time_ms)) or nil
    r.timers[#r.timers+1] = {op=t.action, state=t.state, delay=t.delay, token=t.token, event=t.event, time=started}
  end
  for _, v in ipairs(list(raw.invokes)) do
    r.invokes[#r.invokes+1] = {op=v.action, state=v.state, id=v.id, src=v.src, token=v.token,
      error=v.error ~= M.null and v.error or nil,
      time=v.time_ms and v.time_ms ~= M.null and (v.time_ms - (t0 or v.time_ms)) or nil}
  end
  return r
end

return M
