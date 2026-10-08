-- Statechart prototype semantics (design/statecharts.md). Runs under
-- `ouroctl test`; timers and invokes use the deterministic manual scheduler.
local o = require('ouro')
local machine = o.machine
local assign, raise = machine.assign, machine.raise

local function join(list)
  local out = {}
  for i = 1, #list do out[i] = list[i] end
  return table.concat(out, ',')
end

local function fails(fn, pattern)
  local ok, err = pcall(fn)
  assert(not ok, 'expected failure: ' .. pattern)
  assert(tostring(err):find(pattern, 1, true), tostring(err))
end

local function recorder(actor)
  local records = {}
  actor:observe(function(record) records[#records + 1] = record end)
  return records
end

local function last(list) return list[#list] end

-- a(a1(a11, a12), a2), b(b1), with a parallel p(r1(x, y), r2(u, v)) and out.
local function nested(log)
  local function note(text) return function() log[#log + 1] = text end end
  local function state(name, def)
    def.entry, def.exit = note('enter ' .. name), note('exit ' .. name)
    return def
  end
  return machine.create {
    id = 'nested', initial = 'a',
    states = {
      a = state('a', { initial = 'a1', on = { INNER = '.a2', OUTER = { target = '.a2', reenter = true } },
        states = {
          a1 = state('a1', { initial = 'a11', states = {
            a11 = state('a11', { on = { GO = '#b.b1', SIB = 'a12', SELF = { target = 'a11', reenter = true }, STAY = 'a11' } }),
            a12 = state('a12', {}),
          }}),
          a2 = state('a2', { on = { PAR = '#p' } }),
        }}),
      b = state('b', { initial = 'b1', states = { b1 = state('b1', {}) } }),
      p = state('p', { type = 'parallel', states = {
        r1 = state('r1', { initial = 'x', states = { x = state('x', { on = { E = 'y', F = 'y' } }), y = state('y', {}) } }),
        r2 = state('r2', { initial = 'u', states = { u = state('u', { on = { E = 'v', F = '#out' } }), v = state('v', {}) } }),
      }}),
      out = state('out', {}),
    },
  }
end

return {
  ['compile rejects malformed charts with precise messages'] = function()
    fails(function() machine.create { id = 'm', initial = 'a', states = { a = { bogus = 1 } } } end, 'unknown field "bogus"')
    fails(function() machine.create { id = 'm', states = { a = {} } } end, 'needs initial')
    fails(function() machine.create { id = 'm', initial = 'z', states = { a = {} } } end, 'initial "z"')
    fails(function() machine.create { id = 'm', initial = 'a', states = { a = { on = { X = 'nope' } } } } end, 'unknown target "nope"')
    fails(function() machine.create { id = 'm', initial = 'a', states = { a = { on = { X = { guard = 'g' } } } } } end, 'unknown guard "g"')
    fails(function() machine.create { id = 'm', initial = 'a', states = { a = { entry = 'act' } } } end, 'unknown action "act"')
    fails(function() machine.create { id = 'm', initial = 'a', states = { a = { invoke = { src = 'load' } } } } end, 'unknown actor "load"')
    fails(function() machine.create { id = 'm', initial = 'a', states = { a = { type = 'final', on = { X = 'a' } } } } end, 'cannot declare on')
    fails(function() machine.create { id = 'm', initial = 'a', states = { a = { after = { [1.5] = 'a' } } } } end, 'nonnegative integers')
    fails(function() machine.create { id = 'm', initial = 'a', states = { ['a.b'] = {} } } end, 'must be an identifier')
    fails(function() machine.create { id = 'm', initial = 'a', events = { ['done.x'] = {} }, states = { a = {} } } end, 'invalid external event')
  end,

  ['graph export describes states, transitions, timers and invokes as plain data'] = function()
    local chart = machine.create {
      id = 'doc', initial = 'loading',
      guards = { valid = function() return true end },
      actors = { load = function() return 1 end },
      events = { SAVE = {}, RENAME = { title = 'string', force = 'boolean?' } },
      states = {
        loading = { invoke = { src = 'load', on_done = 'ready', on_error = 'failed' } },
        failed = { type = 'final' },
        ready = { type = 'parallel', on_done = 'loading', states = {
          edit = { initial = 'clean', states = {
            clean = { on = { RENAME = { target = 'dirty', guard = 'valid' } } },
            dirty = { after = { [500] = 'clean' }, on = { SAVE = 'clean' }, tags = { 'unsaved' } },
          }},
          view = { initial = 'plain', states = { plain = { always = { target = 'fancy', guard = function() return false end } }, fancy = {} } },
        }},
      },
    }
    local g = chart:graph()
    assert(g.format == 'ouro.machine.graph' and g.version == 1 and g.id == 'doc' and g.root == '')
    local states = {}
    for _, s in ipairs(g.states) do states[s.id] = s end
    assert(states[''].type == 'compound' and states[''].initial == 'loading')
    assert(states['ready'].type == 'parallel' and join(states['ready'].children) == 'ready.edit,ready.view')
    assert(states['ready.edit'].initial == 'ready.edit.clean' and states['ready.edit'].parent == 'ready')
    assert(states['failed'].final and states['failed'].type == 'final')
    assert(states['ready.edit.dirty'].after[1].delay == 500 and states['ready.edit.dirty'].after[1].event == 'after.500.ready.edit.dirty')
    assert(states['loading'].invoke[1].src == 'load' and states['loading'].invoke[1].id == 'load')
    assert(states['ready.edit.dirty'].tags[1] == 'unsaved')
    -- Document order is depth-first with lexically sorted keys.
    local order = {}
    for i, s in ipairs(g.states) do order[i] = s.id end
    assert(join(order) == ',failed,loading,ready,ready.edit,ready.edit.clean,ready.edit.dirty,ready.view,ready.view.fancy,ready.view.plain', join(order))
    local by = {}
    for _, t in ipairs(g.transitions) do by[t.source .. ' ' .. (t.event or 'always')] = t end
    local rename = by['ready.edit.clean RENAME']
    assert(rename.guarded and rename.guard == 'valid' and rename.targets[1] == 'ready.edit.dirty' and rename.kind == 'event')
    assert(by['ready.view.plain always'].guarded and by['ready.view.plain always'].guard == 'function')
    assert(by['ready.edit.dirty after.500.ready.edit.dirty'].kind == 'after')
    assert(by['loading done.invoke.load'].kind == 'invoke.done' and by['loading error.invoke.load'].targets[1] == 'failed')
    assert(by['ready done.state.ready'].kind == 'done' and not by['ready.edit.dirty SAVE'].guarded)
    assert(g.events[1].type == 'RENAME' and g.events[1].fields.title == 'string' and g.events[1].fields.force == 'boolean?')
    assert(g.events[2].type == 'SAVE')
    -- Plain data all the way down.
    assert(o.json.decode(o.json.encode(g)).states[1].id == '')
    assert(chart:graph() == g)
  end,

  ['exit and entry order follow the least common compound ancestor'] = function()
    local log = {}
    local actor = nested(log):start { scheduler = machine.manual_scheduler() }
    assert(join(log) == 'enter a,enter a1,enter a11', join(log))
    assert(join(actor:states()) == 'a,a.a1,a.a1.a11')
    local records = recorder(actor)
    actor:send('SIB')
    assert(join(last(records).exited) == 'a.a1.a11' and join(last(records).entered) == 'a.a1.a12')
    actor:send('INNER') -- '.a2' from a: a is the domain and is not exited.
    assert(join(last(records).exited) == 'a.a1.a12,a.a1' and join(last(records).entered) == 'a.a2')
    actor:send('OUTER') -- reenter = true exits and re-enters a itself.
    assert(join(last(records).exited) == 'a.a2,a' and join(last(records).entered) == 'a,a.a2')
    for i = #log, 1, -1 do log[i] = nil end
    actor:send('PAR')
    assert(join(log) == 'exit a2,exit a,enter p,enter r1,enter x,enter r2,enter u', join(log))
    assert(join(actor:states()) == 'p,p.r1,p.r1.x,p.r2,p.r2.u')
  end,

  ['order on a parallel state sets region document order; it is validated'] = function()
    local function parallel(order)
      return { id = 'p', initial = 'both', states = { both = { type = 'parallel', order = order,
        states = { alpha = { initial = 'a', states = { a = {} } }, zeta = { initial = 'z', states = { z = {} } } } } } }
    end
    fails(function() machine.create(parallel({ 'zeta' })) end, 'order of p.both is missing region "alpha"')
    fails(function() machine.create(parallel({ 'zeta', 'alpha', 'zeta' })) end, 'lists region "zeta" twice')
    fails(function() machine.create(parallel({ 'zeta', 'alpha', 'beta' })) end, 'names unknown region "beta"')
    fails(function() machine.create(parallel({ zeta = 1, alpha = 2 })) end, 'must be a list of region keys')
    fails(function() machine.create(parallel('zeta')) end, 'must be a list of region keys')
    fails(function() machine.create { id = 'c', initial = 'a', order = { 'a' }, states = { a = {} } } end, 'only parallel states declare order')
    fails(function() machine.create { id = 'c', initial = 'a', states = { a = { order = {}, initial = 'x', states = { x = {} } } } } end, 'only parallel states declare order')

    local log = {}
    local function note(text) return function() log[#log + 1] = text end end
    local function chart(order)
      return machine.create {
        id = 'ordered', type = 'parallel', order = order,
        states = {
          zeta = { initial = 'z1', entry = note('enter zeta'), exit = note('exit zeta'), on = { OUT = '#alpha' },
            states = { z1 = { on = { GO = 'z2' } }, z2 = {} } },
          alpha = { initial = 'a1', entry = note('enter alpha'), exit = note('exit alpha'),
            states = { a1 = { on = { GO = '#zeta' } }, a2 = {} } },
        },
      }
    end
    -- Without order, regions sort by key: alpha, then zeta.
    local sorted = chart(nil):start { scheduler = machine.manual_scheduler() }
    assert(join(log) == 'enter alpha,enter zeta' and join(sorted:states()) == 'alpha,alpha.a1,zeta,zeta.z1', join(log))
    assert(chart(nil):graph().states[2].id == 'alpha')
    log = {}
    sorted:send('GO') -- alpha is first, so its GO (re-entering everything) preempts zeta's.
    assert(sorted:matches('zeta.z1'), join(sorted:states()))
    assert(join(log) == 'exit zeta,exit alpha,enter alpha,enter zeta', join(log))

    log = {}
    local ordered = chart({ 'zeta', 'alpha' })
    local actor = ordered:start { scheduler = machine.manual_scheduler() }
    assert(join(log) == 'enter zeta,enter alpha' and join(actor:states()) == 'zeta,zeta.z1,alpha,alpha.a1', join(log))
    local ids = {}
    for i, state in ipairs(ordered:graph().states) do ids[i] = state.id end
    assert(join(ids) == ',zeta,zeta.z1,zeta.z2,alpha,alpha.a1,alpha.a2', join(ids))
    log = {}
    actor:send('GO') -- zeta is first now: its GO wins and alpha's is preempted.
    assert(actor:matches('zeta.z2') and actor:matches('alpha.a1') and #log == 0, join(actor:states()))
    actor:send('OUT') -- the domain is the parallel root: every region exits (in reverse) and re-enters.
    assert(join(log) == 'exit alpha,exit zeta,enter zeta,enter alpha', join(log))
    assert(join(actor:states()) == 'zeta,zeta.z1,alpha,alpha.a1', join(actor:states()))
  end,

  ['self-targets re-enter only with reenter = true (XState v5); deep transitions exit inner first'] = function()
    local log = {}
    local actor = nested(log):start { scheduler = machine.manual_scheduler() }
    for i = #log, 1, -1 do log[i] = nil end
    assert(actor:send('STAY')) -- a plain self-target acts inside the state
    assert(#log == 0, join(log))
    actor:send('SELF')
    assert(join(log) == 'exit a11,enter a11', join(log))
    -- On a compound state, a plain self-target resets its children without
    -- exiting the state itself.
    local reset = machine.create { id = 'reset', initial = 'outer', states = {
      outer = { initial = 'one', entry = function() log[#log + 1] = 'enter outer' end, exit = function() log[#log + 1] = 'exit outer' end,
        on = { RESET = 'outer' }, states = { one = { on = { NEXT = 'two' } }, two = {} } } } }
    local r = reset:start { scheduler = machine.manual_scheduler() }
    r:send('NEXT')
    for i = #log, 1, -1 do log[i] = nil end
    r:send('RESET')
    assert(r:matches('outer.one') and #log == 0, join(log))
    for i = #log, 1, -1 do log[i] = nil end
    actor:send('GO')
    assert(join(log) == 'exit a11,exit a1,exit a,enter b,enter b1', join(log))
  end,

  ['parallel regions take the same event in one microstep and resolve conflicts in document order'] = function()
    local log = {}
    local actor = nested(log):start { scheduler = machine.manual_scheduler() }
    actor:send('INNER'); actor:send('PAR')
    local records = recorder(actor)
    actor:send('E')
    local step = last(records).microsteps[1]
    assert(#last(records).microsteps == 1 and #step.transitions == 2)
    assert(join(step.exited) == 'p.r2.u,p.r1.x' and join(step.entered) == 'p.r1.y,p.r2.v', join(step.exited) .. ' / ' .. join(step.entered))
    actor:send('OUTER') -- no handler in p
    assert(last(records).rejected and last(records).reason == 'no_transition')
    -- F: r1 (earlier) wants y, r2 wants to leave p. Their exit sets overlap and
    -- r2's source is not a descendant of r1's, so r2's transition is preempted.
    local fresh = nested({}):start { scheduler = machine.manual_scheduler() }
    fresh:send('INNER'); fresh:send('PAR')
    fresh:send('F')
    assert(fresh:matches('p.r1.y') and fresh:matches('p.r2.u') and not fresh:matches('out'))
  end,

  ['guards are tried in order, child handlers win, and can() evaluates guards'] = function()
    local chart = machine.create {
      id = 'g', initial = 'parent', context = { n = 0 },
      states = {
        parent = { initial = 'child', on = { GO = 'fallback', BUMP = { actions = assign { n = function(c) return c.n + 1 end } } },
          states = { child = { on = { GO = {
            { target = '#big', guard = function(c, e) return e.amount > 10 end },
            { target = '#small', guard = function(c, e) return e.amount > 0 end },
          } } } } },
        fallback = {}, big = {}, small = {},
      },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    assert(actor:can { type = 'GO', amount = 50 } and actor:can('BUMP'))
    fails(function() actor:can('NOPE') end, 'UnknownEvent: g does not accept "NOPE"')
    actor:send { type = 'GO', amount = 0 } -- both child guards fail; parent handles it.
    assert(actor:matches('fallback'))
    local second = chart:start { scheduler = machine.manual_scheduler() }
    second:send { type = 'GO', amount = 5 }
    assert(second:matches('small'))
    local third = chart:start { scheduler = machine.manual_scheduler() }
    third:send('BUMP'); third:send('BUMP') -- targetless: no exit or entry.
    assert(third:matches('parent.child') and third:context().n == 2)
  end,

  ['assign is the only way to change context and snapshots are immutable'] = function()
    local chart = machine.create {
      id = 'ctx', initial = 'idle', context = function(input) return { items = { 'a' }, title = input.title, extra = true } end,
      states = { idle = { on = {
        ADD = { actions = assign(function(c, e)
          local items = {}
          for i, item in ipairs(c.items) do items[i] = item end
          items[#items + 1] = e.item
          return { items = items }
        end) },
        CLEAR = { actions = assign { extra = machine.unset, title = function(_, e) return e.title end } },
        MUTATE = { actions = function(c) c.title = 'mutated' end },
      } } },
    }
    local actor = chart:start { input = { title = 'T' }, scheduler = machine.manual_scheduler() }
    local before = machine.raw(actor:snapshot())
    actor:send { type = 'ADD', item = 'b' }
    local after = machine.raw(actor:snapshot())
    assert(before ~= after and #before.context.items == 1 and #after.context.items == 2)
    assert(actor:context().items[2] == 'b' and actor:context().title == 'T')
    fails(function() actor:context().title = 'x' end, 'read-only')
    fails(function() actor:send('MUTATE') end, 'read-only')
    assert(actor:context().title == 'T')
    actor:send { type = 'CLEAR', title = 'U' }
    assert(actor:context().extra == nil and actor:context().title == 'U')
  end,

  ['always transitions and raised events run to completion in one macrostep'] = function()
    local chart = machine.create {
      id = 'rtc', initial = 'idle', context = { n = 0, trail = '' },
      actions = { mark = assign { trail = function(c, e) return c.trail .. e.type .. ';' end } },
      states = {
        idle = { on = { START = { target = 'counting', actions = raise('PING') } } },
        counting = {
          always = { target = 'done', guard = function(c) return c.n >= 3 end },
          on = { PING = { target = 'counting', reenter = true, actions = { 'mark', assign { n = function(c) return c.n + 1 end }, raise('PING') } } },
        },
        done = { entry = 'mark' },
      },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    local records = recorder(actor)
    actor:send('START')
    assert(#records == 1 and actor:matches('done') and actor:context().n == 3, tostring(actor:context().n))
    local r = records[1]
    -- START, PING, PING, PING (each then checks always), then the always step.
    assert(#r.microsteps == 5, tostring(#r.microsteps))
    assert(r.microsteps[2].event == 'PING' and r.microsteps[5].event == nil)
    -- Eventless steps keep the last processed event, as SCXML's _event does.
    assert(actor:context().trail == 'PING;PING;PING;PING;', actor:context().trail)
  end,

  ['an eventless livelock fails without committing a partial snapshot'] = function()
    local chart = machine.create {
      id = 'loop', initial = 'a',
      states = { a = { on = { GO = 'b' } }, b = { always = 'c' }, c = { always = 'b' } },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    fails(function() actor:send('GO') end, 'exceeded 1000 microsteps')
    assert(actor:matches('a'))
  end,

  ['guard errors leave the previous snapshot in place'] = function()
    local chart = machine.create {
      id = 'err', initial = 'a', context = { n = 1 },
      states = { a = { on = { GO = { target = 'b', actions = assign { n = 2 }, guard = function(c, e)
        if e.explode then error('boom') end
        return true
      end } } }, b = {} },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    fails(function() actor:send { type = 'GO', explode = true } end, 'boom')
    assert(actor:matches('a') and actor:context().n == 1)
    actor:send('GO')
    assert(actor:matches('b') and actor:context().n == 2)
  end,

  ['events sent by effects queue behind the current macrostep'] = function()
    local order = {}
    local chart = machine.create {
      id = 'queue', initial = 'a',
      states = {
        a = { on = { GO = { target = 'b', actions = function(_, _, self) order[#order + 1] = 'effect'; self:send('NEXT') end } } },
        b = { entry = function() order[#order + 1] = 'enter b' end, on = { NEXT = 'c' } },
        c = {},
      },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    local records = recorder(actor)
    actor:send('GO')
    assert(actor:matches('c') and #records == 2 and records[1].event.type == 'GO' and records[2].event.type == 'NEXT')
    assert(join(order) == 'effect,enter b', join(order))
    assert(records[2].sequence == records[1].sequence + 1)
    assert(records[2].commit > records[1].commit)
  end,

  ['final states raise done events for compound and parallel parents'] = function()
    local chart = machine.create {
      id = 'fin', initial = 'work',
      states = {
        work = { type = 'parallel', on_done = 'finished', states = {
          one = { initial = 'busy', on_done = { actions = assign { one = true } }, states = { busy = { on = { A = 'ok' } }, ok = { type = 'final' } } },
          two = { initial = 'busy', states = { busy = { on = { B = 'ok' } }, ok = { type = 'final' } } },
        }},
        finished = { on = { END = 'over' } },
        over = { type = 'final', output = function(c) return { one = c.one } end },
      },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    local records = recorder(actor)
    actor:send('A')
    assert(actor:matches('work.one.ok') and actor:context().one)
    actor:send('B')
    assert(actor:matches('finished'), join(actor:states()))
    local events = {}
    for i, step in ipairs(last(records).microsteps) do events[i] = step.event end
    -- done.state.work.two has no handler, so it takes no microstep.
    assert(join(events) == 'B,done.state.work', join(events))
    actor:send('END')
    assert(actor:status() == 'done' and actor:output().one == true)
    actor:send('END')
    assert(last(records).rejected and last(records).reason == 'done')
    assert(not actor:can('END'))
  end,

  ['after timers start on entry, fire once, and are cancelled on exit'] = function()
    local clock = machine.manual_scheduler()
    local chart = machine.create {
      id = 'timer', initial = 'idle',
      states = {
        idle = { on = { ARM = 'armed' } },
        armed = { after = { [100] = 'fired', [300] = 'late' }, on = { DISARM = 'idle', RESET = { target = 'armed', reenter = true } } },
        fired = { on = { ARM = 'armed' } },
        late = {},
      },
    }
    local actor = chart:start { scheduler = clock }
    local records = recorder(actor)
    actor:send('ARM')
    local started = last(records).timers
    assert(#started == 2 and started[1].action == 'started' and started[1].delay == 100 and started[2].delay == 300)
    assert(clock.open_scopes == 2) -- the actor's root, plus one scope for this entry holding both timers
    clock.advance(50)
    actor:send('DISARM')
    local cancelled = last(records).timers
    assert(#cancelled == 2 and cancelled[1].action == 'cancelled' and cancelled[2].action == 'cancelled')
    assert(clock.open_scopes == 1)
    clock.advance(500) -- stale spawned sleeps finish but deliver nothing.
    assert(actor:matches('idle') and last(records).event.type == 'DISARM')
    actor:send('ARM')
    clock.advance(60)
    actor:send('RESET') -- re-entry restarts both timers with a new token.
    local reset = last(records).timers
    assert(reset[1].action == 'cancelled' and reset[3].action == 'started' and reset[3].token ~= reset[1].token)
    clock.advance(60) -- the first entry's 100ms timer would fire now.
    assert(actor:matches('armed'))
    clock.advance(40)
    assert(actor:matches('fired'))
    local fired = last(records)
    assert(fired.origin == 'timer' and fired.timers[1].action == 'fired' and fired.timers[1].delay == 100)
    assert(fired.timers[2].action == 'cancelled' and fired.timers[2].delay == 300 and #fired.timers == 2)
    -- A forged or stale timer event is rejected by token.
    local snapshot = chart:initial()
    local _, _, record = chart:transition(snapshot, { type = 'after.100.armed', state = 'armed', token = 99 })
    assert(record.rejected and record.reason == 'stale')
    fails(function() actor:send('after.100.armed') end, 'reserved')
  end,

  ['invokes deliver results, errors and callback events; exiting cancels them'] = function()
    local clock = machine.manual_scheduler()
    local chart = machine.create {
      id = 'inv', initial = 'idle', context = { name = 'n' },
      actors = {
        load = function(input) if input.fail then error('no such file', 0) end return input.name .. '!' end,
        watch = function(input, send) send { type = 'TICK', n = 1 }; send { type = 'TICK', n = 2 }; return 'watched' end,
      },
      states = {
        idle = { on = { LOAD = 'loading', FAIL = 'failing', WATCH = 'watching' } },
        loading = { invoke = { src = 'load', input = function(c) return { name = c.name } end,
          on_done = { target = 'ready', actions = assign { result = function(_, e) return e.output end } },
          on_error = 'failed' }, on = { CANCEL = 'idle' } },
        failing = { invoke = { src = 'load', input = function() return { fail = true } end, on_error = {
          target = 'failed', actions = assign { error = function(_, e) return e.error end } } } },
        watching = { invoke = { id = 'watcher', src = 'watch', on_done = 'idle' },
          on = { TICK = { actions = assign { ticks = function(c, e) return (c.ticks or 0) + e.n end } } } },
        ready = {}, failed = {},
      },
    }
    local actor = chart:start { scheduler = clock }
    local records = recorder(actor)
    actor:send('LOAD')
    assert(last(records).invokes[1].action == 'started' and last(records).invokes[1].src == 'load')
    assert(clock.run_tasks() == 1 and actor:matches('ready') and actor:context().result == 'n!')
    assert(last(records).invokes[1].action == 'done' and last(records).origin == 'invoke')

    local failing = chart:start { scheduler = clock }
    local failing_records = recorder(failing)
    failing:send('FAIL'); clock.run_tasks()
    assert(failing:matches('failed') and failing:context().error == 'no such file')
    assert(last(failing_records).invokes[1].action == 'error' and last(failing_records).invokes[1].error == 'no such file')

    local cancelled = chart:start { scheduler = clock }
    local cancelled_records = recorder(cancelled)
    clock.advance(5)
    cancelled:send('LOAD')
    local running = cancelled:pending_invokes()
    assert(#running == 1 and running[1].state == 'loading' and running[1].id == 'load' and running[1].src == 'load' and running[1].time_ms == 5)
    assert(last(cancelled_records).invokes[1].time_ms == 5)
    cancelled:send('CANCEL')
    assert(last(cancelled_records).invokes[1].action == 'cancelled')
    assert(#cancelled:pending_invokes() == 0)
    clock.run_tasks() -- the stale task runs to completion; its result is dropped.
    assert(cancelled:matches('idle') and last(cancelled_records).event.type == 'CANCEL')

    local watching = chart:start { scheduler = clock }
    watching:send('WATCH'); clock.run_tasks()
    assert(watching:matches('idle') and watching:context().ticks == 3)
  end,

  ['spawned child actors talk to their parent and finish into done events'] = function()
    local clock = machine.manual_scheduler()
    local child = machine.create {
      id = 'item', initial = 'open', context = function(input) return { label = input.label } end,
      states = {
        open = { after = { [1000] = 'expired' }, on = {
          PING = { actions = machine.send_parent(function(c) return { type = 'PONG', label = c.label } end) },
          CLOSE = 'closed' } },
        expired = {},
        closed = { type = 'final', output = function(c) return c.label end },
      },
    }
    local parent = machine.create {
      id = 'list', initial = 'running', context = { pongs = '' },
      states = { running = { on = {
        ADD = { actions = machine.spawn(child, { id = function(_, e) return e.id end, input = function(_, e) return { label = e.label } end }) },
        PING = { actions = machine.send_to(function(_, e) return e.id end, 'PING') },
        PONG = { actions = assign { pongs = function(c, e) return c.pongs .. e.label end } },
        REMOVE = { actions = machine.stop(function(_, e) return e.id end) },
        ['done.actor.a'] = { actions = assign { closed = function(_, e) return e.output end } },
      } } },
    }
    local seen = {}
    local stop_inspecting = machine.inspect(function(record) seen[#seen + 1] = record end)
    local actor = parent:start { scheduler = clock }
    actor:send { type = 'ADD', id = 'a', label = 'A' }
    actor:send { type = 'ADD', id = 'b', label = 'B' }
    assert(join(actor:snapshot().children) == 'a,b' and actor:child('a'):matches('open'))
    assert(actor:child('b').path == 'list/b' and #actor:children() == 2)
    fails(function() actor:send { type = 'ADD', id = 'a', label = 'again' } end, 'already exists')
    actor:send { type = 'PING', id = 'b' }
    assert(actor:context().pongs == 'B')
    actor:child('a'):send('CLOSE')
    assert(actor:context().closed == 'A' and join(actor:snapshot().children) == 'b' and actor:child('a') == nil)
    local b = actor:child('b')
    actor:send { type = 'REMOVE', id = 'b' }
    -- Only the parent's root scope is left: a finished, and b stopped.
    assert(#actor:children() == 0 and b:status() == 'stopped' and clock.open_scopes == 1)
    actor:stop()
    assert(clock.open_scopes == 0)
    clock.advance(2000) -- the stopped child's timer is dropped.
    assert(b:matches('open'))
    stop_inspecting()
    local lifecycle, child_records = {}, 0
    for _, record in ipairs(seen) do
      if record.kind == 'actor' then lifecycle[#lifecycle + 1] = record.action .. ' ' .. record.actor end
      if record.kind == 'transition' and record.actor == 'list/b' then child_records = child_records + 1 end
    end
    assert(join(lifecycle) == 'started list,started list/a,started list/b,stopped list/b,stopped list', join(lifecycle))
    assert(child_records >= 2)
    assert(seen[1].graph.id == 'list')
    -- Records are emitted after their effects, so a child's record can precede
    -- its parent's; commit gives the global order snapshots changed in.
    local ping, pong
    for _, record in ipairs(seen) do
      if record.kind == 'transition' and record.actor == 'list' and record.event.type == 'PING' then ping = record end
      if record.kind == 'transition' and record.actor == 'list' and record.event.type == 'PONG' then pong = record end
    end
    assert(ping.commit < pong.commit)
  end,

  ['prefix descriptors, the state argument and done.actor positions'] = function()
    local leaf = machine.create { id = 'leaf', initial = 'open', states = { open = { on = { CLOSE = 'closed' } }, closed = { type = 'final' } } }
    local chart = machine.create {
      id = 'tabs', initial = 'idle', context = { removed = '' }, events = { ANYTHING = {} },
      states = {
        idle = { on = {
          ADD = { actions = machine.spawn(leaf, { id = function(_, e) return e.id end }) },
          GO = { target = 'busy', guard = function(_, _, state) return #state.children >= 2 and state.matches('idle') end },
          ['done.actor.*'] = { actions = assign { removed = function(c, e, state)
            return c.removed .. e.id .. '@' .. e.index .. '/' .. #state.children .. ';' end } },
        } },
        busy = { on = { ['done.*'] = 'idle', ['*'] = { actions = assign { other = true } } } },
      },
    }
    fails(function() machine.create { id = 'x', initial = 'a', states = { a = { on = { ['a*b'] = 'a' } } } } end, 'invalid event descriptor')
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    actor:send { type = 'ADD', id = 'a' }
    assert(not actor:can('GO'))
    actor:send { type = 'ADD', id = 'b' }
    actor:send { type = 'ADD', id = 'c' }
    assert(actor:can('GO'))
    actor:child('b'):send('CLOSE')
    actor:child('a'):send('CLOSE')
    assert(actor:context().removed == 'b@2/2;a@1/1;', actor:context().removed)
    actor:send { type = 'ADD', id = 'd' }
    actor:send('GO')
    actor:send('ANYTHING')
    assert(actor:matches('busy') and actor:context().other)
    actor:child('d'):send('CLOSE') -- done.actor.d matches 'done.*' before '*'.
    assert(actor:matches('idle'))
  end,

  ['parents read child snapshots from snapshot.children in the view, guards and assign'] = function(t)
    local item = machine.create {
      id = 'item', initial = 'clean', context = function(input) return { label = input.label } end,
      states = { clean = { on = { EDIT = 'dirty' } }, dirty = { on = { SAVE = 'clean' } } },
    }
    local function dirty_ids(state)
      local out = {}
      for _, id in ipairs(state.children) do
        if machine.matches(state.children[id], 'dirty') then out[#out + 1] = id end
      end
      return out
    end
    local list = machine.create {
      id = 'list', initial = 'idle', context = {},
      states = {
        idle = { on = {
          ADD = { actions = machine.spawn(item, { id = function(_, e) return e.id end, input = function(_, e) return { label = e.label } end }) },
          QUIT = { target = 'done', guard = function(_, _, state) return #dirty_ids(state) == 0 end },
          SUMMARY = { actions = assign { summary = function(_, _, state) return join(dirty_ids(state)) end } },
        } },
        done = {},
      },
    }
    local actor = list:start { scheduler = machine.manual_scheduler() }
    actor:send { type = 'ADD', id = 'a', label = 'A' }
    actor:send { type = 'ADD', id = 'b', label = 'B' }
    local snapshot = actor:snapshot()
    assert(#snapshot.children == 2 and snapshot.children[1] == 'a' and snapshot.children[2] == 'b')
    assert(snapshot.children.a.context.label == 'A' and machine.matches(snapshot.children.b, 'clean'))
    assert(snapshot.children.a.machine == 'item' and not machine.matches(snapshot.children.b, 'dirty'))
    fails(function() snapshot.children.a.context.label = 'x' end, 'read-only')
    local before = machine.raw(actor:snapshot())
    actor:child('b'):send('EDIT') -- a child commit replaces the parent's snapshot
    assert(machine.raw(actor:snapshot()) ~= before and machine.matches(actor:snapshot().children.b, 'dirty'))
    assert(not actor:can('QUIT'))
    actor:send('SUMMARY')
    assert(actor:context().summary == 'b')
    assert(not list:can(machine.raw(actor:snapshot()), 'QUIT')) -- the pure functions see children too
    actor:child('b'):send('SAVE')
    assert(actor:can('QUIT'))
    -- A view reading only the parent rebuilds when a child changes.
    t:mount(function()
      local children = actor:snapshot().children
      local labels = {}
      for _, id in ipairs(children) do
        labels[#labels + 1] = children[id].context.label .. (machine.matches(children[id], 'dirty') and '*' or '')
      end
      return o.column { key = 'root',
        o.text { key = 'labels', text = table.concat(labels, ',') },
        o.button { key = 'edit', label = 'Edit A', on_press = function() actor:child('a'):send('EDIT') end },
      }
    end)
    assert(t:node('root/labels').label == 'A,B')
    t:click('root/edit')
    assert(t:node('root/labels').label == 'A*,B')
  end,

  ['guards, assigns and actions cannot wait, spawn or exit'] = function()
    local chart = machine.create {
      id = 'atomic', initial = 'a', context = { n = 0 },
      actions = {
        nap = function() o.sleep(1) end,
        fork = function() o.spawn(function() end) end,
        leave = function() o.exit(0) end,
        swallow = function() pcall(o.sleep, 1) end,
      },
      states = {
        a = { on = {
          NAP = { actions = 'nap' }, FORK = { actions = 'fork' },
          LEAVE = { actions = 'leave' }, SWALLOW = { actions = 'swallow' },
          GUARD = { target = 'b', guard = function() o.sleep(1); return true end },
          ASSIGN = { target = 'b', actions = assign { n = function() o.sleep(1); return 1 end } },
          ENTER = 'b',
        } },
        b = { entry = function() o.sleep(1) end },
      },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    fails(function() actor:send('NAP') end, "YieldInAction: action 'nap' (atomic.a on NAP) called ouro.sleep")
    -- Ouro I/O (files, D-Bus, HTTP...) is covered by tests/machine_native.py.
    fails(function() actor:send('FORK') end, "action 'fork' (atomic.a on FORK) called ouro.spawn")
    fails(function() actor:send('LEAVE') end, "action 'leave' (atomic.a on LEAVE) called ouro.exit")
    fails(function() actor:send('SWALLOW') end, "action 'swallow' (atomic.a on SWALLOW) called ouro.sleep")
    -- Guards and assigns fail inside the pure step: nothing commits.
    fails(function() actor:send('GUARD') end, "guard 'function' (atomic.a on GUARD) called ouro.sleep")
    fails(function() actor:send('ASSIGN') end, "assign 'assign' (atomic.a on ASSIGN) called ouro.sleep")
    assert(actor:matches('a') and actor:context().n == 0)
    -- Entry actions run after commit, so the transition stands.
    fails(function() actor:send('ENTER') end, "action 'function' (atomic.b entry) called ouro.sleep")
    assert(actor:matches('b'))
  end,

  ['spawned tasks report done or error and are canceled with their owner state'] = function()
    local clock = machine.manual_scheduler()
    local chart = machine.create {
      id = 'tasks', initial = 'idle', context = { log = '' },
      actors = { read = function(input) if input.fail then error('unreadable', 0) end return input.name:upper() end },
      actions = { note = assign { log = function(c, e)
        return c.log .. e.type:match('^(%a+)%.actor') .. ':' .. tostring(e.output or e.error) .. ';' end } },
      states = {
        idle = { on = {
          READ = { actions = machine.spawn('read', { input = function(_, e) return { name = e.name, fail = e.fail } end }) },
          STOP = { actions = machine.stop(function(_, e) return e.id end) },
          ENTER = 'busy',
          ['done.actor.read.*'] = { actions = 'note' }, ['error.actor.*'] = { actions = 'note' },
        } },
        busy = {
          entry = machine.spawn(function(input) return input end, { id = 'inner', input = function() return 'inner' end }),
          on = { LEAVE = 'idle', ['done.actor.inner'] = { actions = 'note' } },
        },
      },
    }
    local actor = chart:start { scheduler = clock }
    local records = recorder(actor)
    actor:send { type = 'READ', name = 'a' }
    local id = actor:snapshot().children[1]
    assert(id:match('^read%.%d+$') and actor:snapshot().children[id].status == 'active', id)
    assert(last(records).children[1].action == 'spawned' and last(records).children[1].src == 'read')
    clock.run_tasks()
    assert(actor:context().log == "done:A;" and #actor:snapshot().children == 0, actor:context().log)
    assert(last(records).origin == 'child' and last(records).children[1].action == 'done')
    actor:send { type = 'READ', name = 'b', fail = true }
    clock.run_tasks()
    assert(actor:context().log == 'done:A;error:unreadable;', actor:context().log)
    assert(last(records).children[1].action == 'error' and last(records).children[1].error == 'unreadable')
    -- stop(id) cancels a task before it reports.
    actor:send { type = 'READ', name = 'c' }
    actor:send { type = 'STOP', id = actor:snapshot().children[1] }
    assert(#actor:snapshot().children == 0 and last(records).children[1].action == 'stopped')
    clock.run_tasks()
    assert(actor:context().log == 'done:A;error:unreadable;')
    -- Leaving the owner state drops and cancels its task.
    actor:send('ENTER')
    assert(actor:snapshot().children[1] == 'inner' and clock.open_scopes == 3) -- root, busy, inner
    actor:send('LEAVE')
    assert(#actor:snapshot().children == 0 and clock.open_scopes == 1)
    clock.run_tasks()
    assert(actor:context().log == 'done:A;error:unreadable;')
    -- Results for unknown children are stale.
    local _, _, record = chart:transition(machine.raw(actor:snapshot()), { type = 'done.actor.read.99', output = 1 })
    assert(record.rejected and record.reason == 'stale')
    actor:send('ENTER'); clock.run_tasks()
    assert(actor:context().log == 'done:A;error:unreadable;done:inner;')
  end,

  ['send reports whether the event was taken, with the record reason'] = function()
    local chart = machine.create {
      id = 'reply', initial = 'a',
      states = {
        a = { on = {
          GO = { target = 'b', actions = function(_, _, self) assert(select(2, self:send('NEXT')) == 'queued') end },
          BOOM = { guard = function() error('boom') end },
        } },
        b = { on = { NEXT = 'c' } },
        c = { on = { END = 'over' } },
        over = { type = 'final' },
      },
    }
    local actor = chart:actor { scheduler = machine.manual_scheduler() }
    assert(actor:status() == 'created' and not actor:started())
    actor:start()
    assert(actor:status() == 'active' and actor:started())
    local ok, reason = actor:send('NEXT')
    assert(ok == false and reason == 'no_transition')
    fails(function() actor:send('BOOM') end, 'boom') -- guard errors still raise
    ok, reason = actor:send('GO') -- its effect's NEXT is queued, then taken
    assert(ok == true and reason == nil and actor:matches('c'))
    assert(actor:send('END') == true and actor:status() == 'done')
    ok, reason = actor:send('END')
    assert(ok == false and reason == 'done')
    actor:stop()
    ok, reason = actor:send('END')
    assert(ok == false and reason == 'stopped')
  end,

  ['plain uses only its first argument and keeps JSON nulls and empty arrays'] = function()
    local function two() return { a = 1 }, 2 end
    assert(machine.plain(two()).a == 1)
    local entry = { exec = o.json.null, actions = o.json.array({}), keywords = { 'x' } }
    local copied = machine.plain(entry)
    assert(copied.exec == o.json.null and copied ~= entry)
    assert(o.json.encode(copied.actions) == '[]' and o.json.encode(copied.keywords) == '["x"]')
    assert(o.json.encode(machine.plain({})) == '{}') -- unmarked empty tables stay objects
    local chart = machine.create { id = 'entries', initial = 'a', context = { entry = entry }, states = { a = {} } }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    local saved = actor:persist()
    assert(saved.context.entry.exec == o.json.null and o.json.encode(saved.context.entry.actions) == '[]')
  end,

  ['wait_for returns at once when the predicate holds and fails fast otherwise'] = function()
    local chart = machine.create {
      id = 'waits', initial = 'a',
      states = {
        a = { on = { GO = 'b', WAIT = { actions = function(_, _, self)
          machine.wait_for(self, function(s) return machine.matches(s, 'b') end)
        end } } },
        b = { on = { END = 'over' } },
        over = { type = 'final' },
      },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    local snapshot = machine.wait_for(actor, function(s) return machine.matches(s, 'a') end)
    assert(snapshot.states[1] == 'a')
    -- Waiting inside an action is a wait like any other.
    fails(function() actor:send('WAIT') end, "action 'function' (waits.a on WAIT) called Ouro I/O")
    fails(function() machine.wait_for(actor, function() return false end, { timeout = 1.5 }) end, 'nonnegative integer')
    actor:send('GO'); actor:send('END')
    fails(function() machine.wait_for(actor, function(s) return machine.matches(s, 'a') end) end, 'WaitEnded: waits is done')
    assert(next(actor._waiters) == nil)
  end,

  ['event bindings are plain { actor, event, field } tables validated at creation'] = function()
    local chart = machine.create {
      id = 'bind', initial = 'a',
      events = { SAVE = {}, EDIT = { field = 'string', value = 'string' }, SELECT = { value = 'integer' } },
      states = { a = { on = { SAVE = {}, EDIT = {}, SELECT = {} } } },
    }
    local actor = chart:actor { scheduler = machine.manual_scheduler() }
    local save = actor:event('SAVE')
    assert(save.actor == actor and save.event == 'SAVE' and save.field == nil)
    local keys = 0
    for _ in pairs(save) do keys = keys + 1 end
    assert(keys == 2)
    local edit = { type = 'EDIT', field = 'title' }
    local binding = actor:event(edit, 'value')
    assert(binding.event == edit and binding.field == 'value', 'the event is not copied')
    assert(actor:event('SELECT', 'value').field == 'value')
    fails(function() actor:event('SAVEE') end, 'UnknownEvent: bind does not accept "SAVEE"')
    fails(function() actor:event('done.state.a') end, 'reserved')
    fails(function() actor:event({ title = 'x' }) end, 'string type')
    fails(function() actor:event('SAVE', '') end, 'nonempty string')
    fails(function() actor:event('SAVE', 3) end, 'nonempty string')
  end,

  ['selectors compute once per context for guards, can() and the view'] = function()
    local runs = 0
    local matches = machine.selector(function(c, prefix)
      runs = runs + 1
      local out = {}
      for _, item in ipairs(c.items) do if item:sub(1, #prefix) == prefix then out[#out + 1] = item end end
      return out
    end)
    local chart = machine.create {
      id = 'pick', initial = 'idle', context = { items = { 'apple', 'apricot', 'banana' }, query = 'ap' },
      states = { idle = { on = {
        PICK = { guard = function(c) return #matches(c, c.query) > 0 end, actions = assign { picked = function(c) return matches(c, c.query)[1] end } },
        QUERY = { actions = assign { query = function(_, e) return e.query end } },
      } } },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    assert(actor:can('PICK') and actor:can('PICK'))
    assert(#matches(actor:context(), actor:context().query) == 2) -- the view
    assert(runs == 1, runs)
    actor:send('PICK') -- the guard and the assign share the result
    assert(actor:context().picked == 'apple' and runs == 1, runs)
    actor:send { type = 'QUERY', query = 'ban' } -- a new context recomputes
    assert(#matches(actor:context(), actor:context().query) == 1 and runs == 2, runs)
    assert(#matches(actor:context(), 'z') == 0 and runs == 3) -- different arguments recompute
  end,

  ['actions derive MCP input schemas from chart events'] = function()
    local chart = machine.create {
      id = 'book', initial = 'ready', context = { names = { ada = 'Ada' } },
      events = { RENAME = { id = 'string', name = 'string' }, PING = { count = 'integer?', extra = 'any?', list = 'table?' } },
      states = { ready = { on = {
        RENAME = { guard = function(c, e) return c.names[e.id] ~= nil end,
          actions = assign { names = function(c, e) local names = {}; for k, v in pairs(c.names) do names[k] = v end; names[e.id] = e.name; return names end } },
        PING = {},
      } } },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    local actions = machine.actions(actor, {
      Rename = { event = 'RENAME', description = 'Rename', errors = { no_transition = 'ContactNotFound' },
        output = function(s, e) return { name = s.context.names[e.id] } end,
        output_schema = { type = 'object', properties = { name = { type = 'string' } }, required = { 'name' }, additionalProperties = false } },
      Ping = { event = 'PING', description = 'Ping' },
      Names = { description = 'Read', output = function(s) return { count = #machine.plain(s.context.names) } end },
    })
    local rename = actions.Rename.inputSchema
    assert(rename.type == 'object' and rename.additionalProperties == false and join(rename.required) == 'id,name')
    assert(rename.properties.id.type == 'string' and rename.properties.name.type == 'string')
    local ping = actions.Ping.inputSchema
    assert(ping.required == nil and ping.properties.count.type == 'integer' and ping.properties.extra == true)
    assert(join(ping.properties.list.type) == 'object,array')
    assert(actions.Ping.outputSchema.type == 'object' and actions.Names.inputSchema.type == 'object')
    assert(actions.Rename.handler { id = 'ada', name = 'Lovelace' }.name == 'Lovelace')
    assert(actions.Ping.handler {} == nil and actions.Names.handler {}.count == 0)
    fails(function() machine.actions(actor, { Bad = { event = 'NOPE', description = 'x' } }) end, 'declares no NOPE event schema')
    -- Rejections become ouro.action_error; see tests/machine_native.py for the MCP round trip.
  end,

  ['machine.set assigns e.value and declares the event'] = function()
    local chart = machine.create {
      id = 'search', initial = 'idle', context = { query = '', selected = 1 },
      states = { idle = { on = {
        QUERY = machine.set('query', 'string'),
        ['search.select'] = machine.set('selected', 'integer'),
        ['search.clear'] = { actions = assign { query = '' } },
      } } },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    assert(actor:send { type = 'QUERY', value = 'fire' } and actor:context().query == 'fire')
    fails(function() actor:send { type = 'QUERY', value = 3 } end, 'InvalidEvent: QUERY.value must be string')
    fails(function() actor:send('QUERY') end, 'InvalidEvent: QUERY requires value')
    assert(actor:send { type = 'search.select', value = 4 } and actor:context().selected == 4)
    actor:send('search.clear') -- dotted user names group events
    assert(actor:context().query == '')
    local events = {}
    for _, e in ipairs(chart:graph().events) do events[e.type] = e end
    assert(events.QUERY.fields.value == 'string' and events['search.select'].fields.value == 'integer')
    assert(events['search.clear'].schema == false)
    local transition
    for _, t in ipairs(chart:graph().transitions) do if t.event == 'QUERY' then transition = t end end
    assert(transition.actions[1] == 'set query')
    fails(function() machine.set('') end, 'context field name')
    fails(function() machine.set('x', 'date') end, 'machine.set type')
  end,

  ['runtime prefixes are reserved and undeclared events fail in strict mode'] = function()
    assert(machine.strict == true, 'ouroctl test is strict')
    for _, name in ipairs({ 'surface.closed.main', 'done.x', 'error.x', 'after.x', 'ouro.x' }) do
      fails(function() machine.create { id = 'm', initial = 'a', events = { [name] = {} }, states = { a = {} } } end, 'invalid external event name')
    end
    fails(function() machine.create { id = 'm', initial = 'a', states = { a = { on = { ['surface.x'] = machine.set('x') } } } } end, 'plain event name')
    local chart = machine.create {
      id = 'win', initial = 'shown', context = {},
      states = {
        shown = { on = { HIDE = 'hidden', ['surface.close_requested.main'] = 'hidden', ['surface.*'] = { actions = assign { seen = true } } } },
        hidden = { on = { SHOW = 'shown' } },
      },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    local records = recorder(actor)
    fails(function() actor:send('surface.close_requested.main') end, 'reserved')
    fails(function() actor:send('HIDDEN') end, 'UnknownEvent: win does not accept "HIDDEN"')
    -- The runtime delivers reserved events: no schema or declaration check.
    assert(actor:deliver({ type = 'surface.mapped.main' }, 'surface') == true and actor:context().seen)
    assert(last(records).origin == 'surface' and last(records).event.type == 'surface.mapped.main')
    assert(actor:deliver('surface.close_requested.main', 'surface') and actor:matches('hidden'))
    local ok, reason = actor:deliver('surface.closed.main')
    assert(ok == false and reason == 'no_transition' and last(records).origin == 'runtime')
    machine.strict = false
    ok, reason = actor:send('HIDDEN')
    assert(ok == false and reason == 'undeclared' and actor:can('HIDDEN') == false)
    machine.strict = true
    assert(join(actor:accepted()) == 'SHOW')
  end,

  ['components keep per-instance machine state and start on their first event'] = function(t)
    local chart = machine.create {
      id = 'collapsible', initial = 'closed',
      context = function(props) return { title = props.title } end,
      states = { closed = { on = { TOGGLE = 'open' } }, open = { on = { TOGGLE = 'closed' } } },
    }
    local actors = {}
    local Collapsible = machine.component(chart, function(self, props)
      actors[props.title] = self
      local open = self:matches('open')
      return o.column { key = 'box',
        o.button { key = 'toggle', label = (open and 'Hide ' or 'Show ') .. self:context().title, on_press = self:sender('TOGGLE') },
        open and o.text { key = 'body', text = 'Body of ' .. props.title } or nil,
      }
    end)
    t:mount(function()
      return o.column { key = 'root',
        Collapsible { key = 'first', title = 'First' },
        Collapsible { key = 'second', title = 'Second' },
      }
    end)
    assert(actors.First:status() == 'created' and actors.Second:status() == 'created')
    assert(t:node('root/first/box/toggle').label == 'Show First')
    t:click('root/first/box/toggle')
    assert(t:node('root/first/box/toggle').label == 'Hide First' and t:node('root/first/box/body').label == 'Body of First')
    assert(t:node('root/second/box/toggle').label == 'Show Second' and actors.Second:status() == 'created')
    assert(actors.First:status() == 'active')
    t:click('root/first/box/toggle')
    assert(t:node('root/first/box/toggle').label == 'Show First')
  end,

  ['reload hooks persist roots, carry them into new charts and hold their work until release'] = function()
    local clock = machine.manual_scheduler()
    local doc_v1 = machine.create {
      id = 'doc', initial = 'clean', context = function(input) return { title = input.title } end,
      states = { clean = { on = { EDIT = 'dirty' } }, dirty = { after = { [100] = 'clean' } } },
    }
    local app_v1 = machine.create {
      id = 'app', initial = 'running', context = { n = 0 },
      states = { running = { initial = 'idle', states = {
        idle = { on = { ADD = { actions = machine.spawn(doc_v1, { id = function(_, e) return e.id end, input = function(_, e) return { title = e.id } end }) },
          WAIT = 'waiting' } },
        waiting = { after = { [50] = 'idle' }, on = { BACK = 'idle' } },
      } } },
    }
    local app = app_v1:start { scheduler = clock }
    app:send { type = 'ADD', id = 'a' }
    app:child('a'):send('EDIT')
    app:send('WAIT')
    local done = machine.create { id = 'once', initial = 'a', states = { a = { on = { END = 'b' } }, b = { type = 'final' } } }:start { scheduler = clock }
    done:send('END')
    local bad = machine.create { id = 'bad', initial = 'a', context = function() return { f = function() end } end, states = { a = {} } }:start { scheduler = clock }
    local entries, skipped = machine.persist_roots()
    local ids = {}
    for _, entry in ipairs(entries) do ids[#ids + 1] = entry.id .. '/' .. entry.machine end
    table.sort(ids)
    assert(join(ids) == 'app/app', join(ids)) -- done, unserializable and child actors are left out
    assert(#skipped == 1 and skipped[1]:find('^bad: machine value is not serializable'), tostring(skipped[1]))
    local mine
    for _, entry in ipairs(entries) do if entry.id == 'app' then mine = entry end end

    -- The new source renames waiting, and doc lost its dirty state.
    local doc_v2 = machine.create {
      id = 'doc', initial = 'clean', context = function(input) return { title = input.title, pinned = false } end,
      states = { clean = { on = { EDIT = 'clean' } } },
    }
    local app_v2 = machine.create {
      id = 'app', initial = 'running', context = { n = 0, extra = 'new' },
      states = { running = { initial = 'idle', states = {
        idle = { on = { ADD = { actions = machine.spawn(doc_v2, { id = function(_, e) return e.id end, input = function(_, e) return { title = e.id } end }) },
          WAIT = 'paused' } },
        paused = { after = { [50] = 'idle' }, on = { BACK = 'idle' } },
      } } },
    }
    local fresh_clock = machine.manual_scheduler()
    machine.carry({ mine, { id = 'other', machine = 'nope', snapshot = mine.snapshot } })
    local restored = app_v2:start { scheduler = fresh_clock, renames = { ['running.waiting'] = 'running.paused' } }
    assert(restored:restored() and restored:matches('running.paused') and restored:context().extra == 'new')
    local a = restored:child('a')
    assert(a and a:restored() and a:matches('clean') and a:context().title == 'a', 'the child falls back and keeps its old context')
    assert(#fresh_clock.timers == 0, 'restored timers wait for release')
    local unrelated = app_v2:start { scheduler = fresh_clock, id = 'other' }
    assert(not unrelated:restored(), 'a chart id mismatch starts fresh')
    machine.release()
    assert(#fresh_clock.timers == 1)
    fresh_clock.advance(50)
    assert(restored:matches('running.idle'))
    assert(not app_v2:start { scheduler = fresh_clock }:restored(), 'entries are consumed and the hold ends')

    -- A held timer whose state exits before release is skipped.
    local again = machine.manual_scheduler()
    machine.carry({ mine })
    local held = app_v2:start { scheduler = again, renames = { ['running.waiting'] = 'running.paused' } }
    held:send('BACK') -- transitions after restore behave normally
    machine.release()
    assert(held:matches('running.idle') and #again.timers == 0)
  end,

  ['records carry the scheduler clock and post-step guard valves'] = function()
    local clock = machine.manual_scheduler()
    local chart = machine.create {
      id = 'valves', initial = 'filling', context = { level = 0 },
      states = {
        filling = {
          always = { target = 'full', guard = function(c) return c.level >= 3 end },
          after = { [100] = { target = 'drained', guard = function(c) return c.level == 0 end } },
          on = {
            POUR = { actions = assign { level = function(c) return c.level + 1 end } },
            BIG = { target = 'full', guard = function(_, e) return e.amount > 10 end },
          },
        },
        full = {}, drained = {},
      },
    }
    local actor = chart:start { scheduler = clock }
    local records = recorder(actor)
    local index = {}
    for _, t in ipairs(chart:graph().transitions) do index[(t.event or 'always'):match('^[%w]+')] = t.index end
    local function valve(record, key)
      for _, v in ipairs(record.guards) do if v.index == index[key] then return v end end
    end
    clock.advance(40)
    actor:send('POUR')
    local r = last(records)
    assert(r.time_ms == 40 and r.timers[1] == nil)
    assert(valve(r, 'always').passed == false and valve(r, 'after').passed == false)
    -- BIG reads e.amount: a bare {type = 'BIG'} makes it throw, so it is closed with the error.
    assert(valve(r, 'BIG').passed == false and valve(r, 'BIG').error:find('attempt to compare', 1, true), valve(r, 'BIG').error)
    assert(#r.guards == 3)
    assert(#actor:pending_invokes() == 0)
    local timers = actor:pending_timers()
    assert(#timers == 1 and timers[1].state == 'filling' and timers[1].delay == 100 and timers[1].time_ms == 0)
    clock.advance(10)
    actor:send('POUR')
    actor:send('POUR') -- level 3: the always valve opens and fires in the same step
    r = last(records)
    assert(r.time_ms == 50 and actor:matches('full') and #r.guards == 0, 'no guarded transitions are active in full')
    assert(o.json.decode(o.json.encode(r)).time_ms == 50)
    local fresh = machine.manual_scheduler()
    fresh.advance(7)
    local other = chart:start { scheduler = fresh }
    local other_records = recorder(other)
    other:send('POUR')
    assert(last(other_records).timers[1] == nil and other:pending_timers()[1].time_ms == 7)
  end,

  ['stopping a never-started or already-canceled actor is safe'] = function()
    local clock = machine.manual_scheduler()
    local chart = machine.create { id = 'lazy', initial = 'idle', states = {
      idle = { on = { GO = 'busy' } }, busy = { after = { [100] = 'idle' } } } }
    local never = chart:actor { scheduler = clock, lazy = true, scope = 'task' }
    local before = never._store()
    never:stop()
    assert(never:status() == 'stopped' and clock.open_scopes == 0)
    assert(never._store() == before, 'no snapshot signal write for an actor that never committed')
    assert(select(2, never:send('GO')) == 'stopped')
    never:stop() -- idempotent
    local running = chart:actor { scheduler = clock, lazy = true, scope = 'task' }
    running:send('GO') -- starts lazily and opens its root and state scopes
    assert(running:status() == 'active' and clock.open_scopes == 2)
    clock.close(running._root_scope) -- the instance scope was canceled first
    running:stop()
    assert(running:status() == 'stopped' and clock.open_scopes == 0)
    clock.advance(200)
    assert(running:matches('busy'), 'no timer fires after stop')
  end,

  ['handles ignores guards and value widgets enable on it'] = function(t)
    local chart = machine.create {
      id = 'editor', initial = 'closed', context = { title = 'a' },
      states = {
        closed = { on = { OPEN = 'open' } },
        open = { on = {
          TITLE = { guard = function(c, e) return e.value ~= c.title end, actions = assign { title = function(_, e) return e.value end } },
          CLOSE = 'closed' } },
      },
    }
    local actor = chart:actor { scheduler = machine.manual_scheduler() }
    assert(not actor:handles('TITLE') and actor:handles('OPEN'))
    fails(function() actor:handles('TYPO') end, 'UnknownEvent')
    local started = o.signal(false)
    t:mount(function()
      return o.column { key = 'root',
        o.text_input { key = 'title', text = actor:context().title, send = actor:event('TITLE') },
        o.button { key = 'open', label = 'Open', enabled = not started() or nil, send = actor:event('OPEN'),
          on_press = nil },
        o.button { key = 'start', label = 'Start', on_press = function() started:set(true); actor:start(); actor:send('OPEN') end },
      }
    end)
    fails(function() t:click('root/title') end, 'DevelopmentTargetDisabled') -- closed: no TITLE transition at all
    t:click('root/start')
    assert(actor:matches('open') and actor:handles('TITLE'))
    assert(not actor:can { type = 'TITLE', value = 'a' }, 'the guard refuses the current value...')
    t:click('root/title') -- ...but the input is enabled: handles ignores guards
    assert(t:node('root/title').focused)
  end,

  ['rebuild locality: typing in one document re-renders only its readers'] = function(t)
    local doc = machine.create {
      id = 'doc', initial = 'open', context = function(input) return { title = input.title, text = '' } end,
      states = { open = { on = { TEXT = machine.set('text', 'string'), TITLE = machine.set('title', 'string') } } },
    }
    local notes = machine.create {
      id = 'notes', initial = 'running', context = { split = 0.25 },
      states = { running = { on = {
        ADD = { actions = machine.spawn(doc, { id = function(_, e) return e.id end, input = function(_, e) return { title = e.id } end }) },
        RESIZE = machine.set('split', 'number'),
      } } },
    }
    local actor = notes:start { scheduler = machine.manual_scheduler() }
    actor:send { type = 'ADD', id = 'a' }; actor:send { type = 'ADD', id = 'b' }
    local renders = {}
    local function counted(name, body)
      return o.stateful(function(props)
        return function() renders[name .. (props.id or '')] = (renders[name .. (props.id or '')] or 0) + 1; return body(props) end
      end)
    end
    -- The tab bar reads every child's title through snapshot.children.
    local TabBar = counted('tabs', function()
      local children, labels = actor:snapshot().children, {}
      for _, id in ipairs(children) do labels[#labels + 1] = children[id].context.title end
      return o.text { key = 'labels', text = table.concat(labels, ',') }
    end)
    local Editor = counted('editor', function(props) return o.text { key = 'text', text = actor:child(props.id):context().text } end)
    local Split = counted('split', function() return o.text { key = 'split', text = tostring(actor:context().split) } end)
    local Count = counted('count', function() return o.text { key = 'count', text = tostring(#actor:children()) } end)
    t:mount(function()
      return o.column { key = 'root',
        TabBar { key = 'tabs' }, Editor { key = 'ea', id = 'a' }, Editor { key = 'eb', id = 'b' }, Split { key = 'split' }, Count { key = 'count' },
        o.button { key = 'type', label = 'Type', on_press = function() actor:child('a'):send { type = 'TEXT', value = 'hello' } end },
        o.button { key = 'rename', label = 'Rename', on_press = function() actor:child('b'):send { type = 'TITLE', value = 'B' } end },
        o.button { key = 'resize', label = 'Resize', on_press = function() actor:send { type = 'RESIZE', value = 0.5 } end },
        o.button { key = 'add', label = 'Add', on_press = function() actor:send { type = 'ADD', id = 'c' } end },
      }
    end)
    local function counts() return string.format('tabs=%d ea=%d eb=%d split=%d count=%d',
      renders.tabs, renders.editora, renders.editorb, renders.split, renders.count) end
    assert(counts() == 'tabs=1 ea=1 eb=1 split=1 count=1', counts())
    t:click('root/type') -- a keystroke in document a
    assert(counts() == 'tabs=1 ea=2 eb=1 split=1 count=1', counts())
    assert(t:node('root/ea/text').label == 'hello')
    t:click('root/rename') -- b's title: the tab bar reads it
    assert(counts() == 'tabs=2 ea=2 eb=1 split=1 count=1', counts())
    assert(t:node('root/tabs/labels').label == 'a,B')
    t:click('root/resize') -- a notes-level field
    assert(counts() == 'tabs=2 ea=2 eb=1 split=2 count=1', counts())
    t:click('root/add') -- membership changes: children readers re-render
    assert(counts() == 'tabs=3 ea=2 eb=1 split=2 count=2', counts())
    assert(t:node('root/tabs/labels').label == 'a,B,c')
  end,

  ['rebuild locality: fields, configuration and selectors'] = function(t)
    local results = machine.selector(function(c)
      local out = {}
      for _, entry in ipairs(c.entries) do if entry:find(c.query, 1, true) then out[#out + 1] = entry end end
      return out
    end)
    local launcher = machine.create {
      id = 'launcher', initial = 'hidden', context = { query = '', error = 'none', entries = { 'files', 'firefox', 'terminal' } },
      states = {
        hidden = { on = { TOGGLE = 'open' } },
        open = { on = { TOGGLE = 'hidden', QUERY = machine.set('query', 'string'), FAIL = machine.set('error', 'string'),
          SUBMIT = { guard = function(c) return c.query ~= '' end } } },
      },
    }
    local actor = launcher:start { scheduler = machine.manual_scheduler() }
    local renders = {}
    local function counted(name, body)
      return o.stateful(function() return function() renders[name] = (renders[name] or 0) + 1; return body() end end)
    end
    local Query = counted('query', function() return o.text { key = 'q', text = actor:context().query } end)
    local Error = counted('error', function() return o.text { key = 'e', text = actor:context().error } end)
    local Mode = counted('mode', function() return o.text { key = 'm', text = actor:matches('open') and 'open' or 'hidden' } end)
    local List = counted('list', function() return o.text { key = 'l', text = tostring(#results(actor:context())) } end)
    local Again = counted('again', function() return o.text { key = 'l', text = tostring(#results(actor:context())) } end)
    local Can = counted('can', function() return o.text { key = 'c', text = tostring(actor:can('SUBMIT')) } end)
    t:mount(function()
      return o.column { key = 'root',
        Query { key = 'query' }, Error { key = 'error' }, Mode { key = 'mode' }, List { key = 'list' }, Again { key = 'again' }, Can { key = 'can' },
        o.button { key = 'toggle', label = 'Toggle', on_press = function() actor:send('TOGGLE') end },
        o.button { key = 'type', label = 'Type', on_press = function() actor:send { type = 'QUERY', value = 'fi' } end },
        o.button { key = 'fail', label = 'Fail', on_press = function() actor:send { type = 'FAIL', value = 'boom' } end },
      }
    end)
    local function counts() return string.format('query=%d error=%d mode=%d list=%d again=%d can=%d',
      renders.query, renders.error, renders.mode, renders.list, renders.again, renders.can) end
    assert(counts() == 'query=1 error=1 mode=1 list=1 again=1 can=1', counts())
    t:click('root/toggle') -- a state change: only configuration readers (matches, can)
    assert(counts() == 'query=1 error=1 mode=2 list=1 again=1 can=2', counts())
    t:click('root/type') -- QUERY: not the error reader; both selector users (one via cache-hit replay);
    -- can() too, because its guard read query
    assert(counts() == 'query=2 error=1 mode=2 list=2 again=2 can=3', counts())
    assert(t:node('root/list/l').label == '2' and t:node('root/again/l').label == '2' and t:node('root/can/c').label == 'true')
    t:click('root/fail') -- error only
    assert(counts() == 'query=2 error=2 mode=2 list=2 again=2 can=3', counts())
  end,

  ['views are cached per table, so repeated reads and iteration do not allocate'] = function()
    local rows = {}
    for i = 1, 200 do rows[i] = { id = i } end
    local chart = machine.create { id = 'rows', initial = 'a', context = { rows = rows, meta = { n = 1 } }, states = { a = { on = { BUMP = machine.set('meta') } } } }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    local seen, count = {}, 0
    for _, row in ipairs(actor:context().rows) do seen[row] = true end
    for _, row in ipairs(actor:context().rows) do if seen[row] then count = count + 1 end end
    assert(count == 200, 'the same view userdata comes back for each row')
    local ctx = actor:context()
    local first = ctx.meta
    seen[first] = 'meta'
    assert(seen[ctx.meta] == 'meta' and seen[actor:context().meta] == 'meta')
    actor:send { type = 'BUMP', value = { n = 2 } }
    assert(seen[actor:context().meta] == nil and actor:context().meta.n == 2, 'a replaced table gets its own view')
    assert(seen[actor:context().rows[1]] == true, 'unchanged tables keep theirs')
  end,

  ['root actors start in a test body on the native scheduler'] = function(t)
    assert(machine.native_scopes and machine.default_scheduler.kind == 'native')
    local chart = machine.create {
      id = 'plain', initial = 'idle', context = { n = 0 },
      actors = { load = function() return 41 end },
      states = {
        idle = { on = { LOAD = 'loading' } },
        loading = { invoke = { src = 'load', on_done = { target = 'ready', actions = assign { n = function(_, e) return e.output + 1 end } } } },
        ready = {},
      },
    }
    local actor = chart:start() -- no manual scheduler, outside any task
    assert(actor:matches('idle'))
    actor:send('LOAD') -- opens the root scope under the host's application scope
    assert(actor:matches('loading') and #actor:pending_invokes() == 1)
    -- The runner drains runnable tasks while it settles mounted UI.
    t:mount(function() return o.text { key = 'n', text = tostring(actor:context().n) } end)
    assert(actor:matches('ready') and t:node('n').label == '42', t:node('n').label)
    actor:stop()
  end,

  -- Review findings (independent review of the branch), adopted as regressions.

  -- XState v5: the parallel source is neither exited nor re-entered, but every
  -- region below it is, so an untargeted region starts over from its initial
  -- state (getTransitionDomain/computeExitSet in xstate's stateUtils.ts).
  ['review M5: a parallel source with a descendant target is not exited (XState v5)'] = function()
    local log = {}
    local chart = machine.create {
      id = 'p', initial = 'open',
      states = { open = {
        type = 'parallel', order = { 'io', 'life' },
        entry = function() log[#log + 1] = 'enter open' end, exit = function() log[#log + 1] = 'exit open' end,
        on = { GO = '.io.saving', AGAIN = { target = '.io.saving', reenter = true } },
        states = {
          io = { initial = 'idle', states = { idle = {}, saving = {} } },
          life = { initial = 'a', states = { a = { on = { NEXT = 'b' } }, b = {} } },
        },
      } },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    actor:send('NEXT')
    log = {}
    assert(actor:send('GO') and actor:matches('open.io.saving'))
    assert(#log == 0, 'the parallel source was exited: ' .. table.concat(log, ','))
    assert(actor:matches('open.life.a'), 'as in XState v5, the untargeted region restarts: ' .. join(actor:states()))
    actor:send('NEXT')
    assert(actor:send('AGAIN') and table.concat(log, ',') == 'exit open,enter open' and actor:matches('open.life.a'))
  end,

  ['review H4: spawning after restore does not reuse child ids'] = function()
    local doc = machine.create { id = 'doc', initial = 'open', states = { open = {} } }
    local notes = machine.create { id = 'notes', initial = 'running',
      states = { running = { on = { ADD = { actions = machine.spawn(doc) } } } } }
    local before = notes:start { scheduler = machine.manual_scheduler() }
    for _ = 1, 4 do assert(before:send('ADD')) end
    local persisted = o.json.decode(o.json.encode(before:persist()))
    assert(math.type(persisted.serial) == 'integer', 'the serial is persisted')
    before:stop()
    local after = notes:start { scheduler = machine.manual_scheduler(), snapshot = notes:restore(persisted) }
    assert(#after:children() == 4)
    for _ = 1, 3 do assert(after:send('ADD')) end
    assert(#after:children() == 7)
    -- Snapshots persisted before the serial was: ids still skip taken ones.
    persisted.serial = nil
    local legacy = notes:start { scheduler = machine.manual_scheduler(), snapshot = notes:restore(persisted) }
    for _ = 1, 3 do assert(legacy:send('ADD')) end
    assert(#legacy:children() == 7)
  end,

  ['review M6: a throwing action does not drop events already queued'] = function()
    local chart = machine.create {
      id = 'q', initial = 'a',
      states = {
        a = { on = { GO = { target = 'b', actions = {
          function(_, _, self) assert(select(2, self:send('NEXT')) == 'queued') end,
          function() error('boom') end,
        } } } },
        b = { on = { NEXT = 'c' } },
        c = { on = { CHECK = { guard = function() error('bad guard') end } , LAST = 'd' } },
        d = {},
      },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    fails(function() actor:send('GO') end, 'boom')
    assert(actor:matches('c'), 'queued NEXT was dropped: ' .. join(actor:states()))
    fails(function() actor:send('CHECK') end, 'bad guard') -- a guard error: nothing commits for it
    assert(actor:matches('c') and actor:send('LAST') and actor:matches('d'))
  end,

  ['review H1: a stopped actor starts no effects'] = function()
    local clock = machine.manual_scheduler()
    local child = machine.create {
      id = 'child', initial = 'idle', actors = { save = function() return true end },
      states = {
        idle = { on = { CLOSE = { target = 'closing', actions = machine.send_parent('CLOSE_ME') } } },
        closing = { after = { [1000] = 'idle' }, invoke = { src = 'save' } },
      },
    }
    local parent = machine.create { id = 'parent', initial = 'running', states = { running = {
      entry = machine.spawn(child, { id = 'c' }), on = { CLOSE_ME = { actions = machine.stop('c') } } } } }
    local actor = parent:start { scheduler = clock }
    local kid = actor:child('c')
    kid:send('CLOSE') -- the parent stops it while it runs its own effects
    assert(kid:status() == 'stopped')
    assert(#kid:pending_timers() == 0 and #kid:pending_invokes() == 0, 'a stopped child started work')
    assert(clock.open_scopes == 0 and clock.run_tasks() == 0, 'scopes or tasks left: ' .. clock.open_scopes)
    -- An actor stopped by its own action skips its remaining effects too.
    local ran = false
    local self_stop = machine.create { id = 'selfstop', initial = 'a', states = {
      a = { on = { GO = { target = 'b', actions = { function(_, _, self) self:stop() end, function() ran = true end } } } },
      b = { after = { [10] = 'a' } } } }
    local s2 = self_stop:start { scheduler = clock }
    s2:send('GO')
    assert(not ran and #s2:pending_timers() == 0 and s2:status() == 'stopped')
    actor:stop()
  end,

  ['review H2: a selector filled by an untracked guard still tracks the view'] = function(t)
    local results = machine.selector(function(c)
      local out = {}
      for _, e in ipairs(c.entries) do if e:find(c.query, 1, true) then out[#out + 1] = e end end
      return out
    end)
    local chart = machine.create {
      id = 'launcher', initial = 'open', context = { query = '', entries = { 'alpha', 'beta', 'gamma' } },
      states = {
        open = { on = { QUERY = machine.set('query', 'string'),
          ACTIVATE = { target = 'done', guard = function(c) return #results(c) > 0 end } } },
        done = {},
      },
    }
    local actor = chart:actor { scheduler = machine.manual_scheduler() }
    actor:observe(function() end) -- valve states evaluate the guard right after each commit
    actor:start()
    local Count = o.stateless(function() return o.text { key = 'count', text = tostring(#results(actor:context())) } end)
    t:mount(function()
      return o.column { key = 'root',
        o.button { key = 'a', label = 'a', send = actor:event { type = 'QUERY', value = 'a' } },
        o.button { key = 'al', label = 'al', send = actor:event { type = 'QUERY', value = 'al' } },
        Count { key = 'c' },
      }
    end)
    assert(t:node('root/count').label == '3')
    t:click('root/a'); t:click('root/al')
    assert(t:node('root/count').label == '1', 'stale selector view: ' .. t:node('root/count').label)
  end,

  ['review M7: integer fields accept integral floats'] = function()
    local chart = machine.create { id = 'settings', initial = 'open', context = { laps = 5 },
      states = { open = { on = { LAPS = machine.set('laps', 'integer') } } } }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    assert(actor:send { type = 'LAPS', value = 6.0 })
    assert(actor:context().laps == 6 and math.type(actor:context().laps) == 'integer')
    fails(function() actor:send { type = 'LAPS', value = 6.5 } end, 'must be integer')
    fails(function() actor:send { type = 'LAPS', value = '7' } end, 'must be integer')
  end,

  ['review L10: pairs over snapshot.children tracks each child'] = function(t)
    local doc = machine.create { id = 'doc', initial = 'open', context = { title = 'a' },
      states = { open = { on = { RENAME = machine.set('title', 'string') } } } }
    local notes = machine.create { id = 'notes', initial = 'running',
      states = { running = { entry = machine.spawn(doc, { id = 'd' }) } } }
    local actor = notes:start { scheduler = machine.manual_scheduler() }
    local kid = actor:child('d')
    t:mount(function()
      local titles = {}
      for key, child in pairs(actor:snapshot().children) do
        if type(key) == 'string' then titles[#titles + 1] = child.context.title end
      end
      return o.column { key = 'root',
        o.text { key = 'titles', text = table.concat(titles, ',') },
        o.button { key = 'rename', label = 'Rename', send = kid:event { type = 'RENAME', value = 'b' } },
      }
    end)
    assert(t:node('root/titles').label == 'a')
    t:click('root/rename')
    assert(t:node('root/titles').label == 'b', 'stale render: ' .. t:node('root/titles').label)
  end,

  -- review L11 (wait_for on a created actor that stops) is in tests/machine_native.py.

  ['review L12: a task spawned by an exit action belongs to a surviving ancestor'] = function()
    local clock = machine.manual_scheduler()
    local chart = machine.create {
      id = 'exits', initial = 'outer', context = { log = '' },
      actors = { note = function(input) return input end },
      states = {
        outer = { initial = 'inner', on = { LEAVE = 'gone' }, states = {
          inner = { exit = machine.spawn('note', { id = 'bye', input = function() return 'bye' end }) } } },
        gone = { on = { ['done.actor.bye'] = { actions = assign { log = function(c, e) return c.log .. e.output end } } } },
      },
    }
    local actor = chart:start { scheduler = clock }
    actor:send('LEAVE') -- inner and outer both exit: the root owns the task
    assert(actor:snapshot().children[1] == 'bye')
    clock.run_tasks()
    assert(actor:context().log == 'bye', 'the task was cancelled with an exiting owner')
  end,

  ['review L13: root on_done is rejected, bindings respect non-strict, child tokens'] = function()
    fails(function() machine.create { id = 'r', initial = 'a', on_done = 'a', states = { a = { type = 'final' } } } end,
      'the root cannot declare on_done')
    local chart = machine.create { id = 'strictness', initial = 'a', states = { a = { on = { GO = {} } } } }
    local actor = chart:actor { scheduler = machine.manual_scheduler() }
    fails(function() actor:event('TYPO') end, 'UnknownEvent')
    machine.strict = false
    local binding = actor:event('TYPO')
    machine.strict = true
    assert(binding.event == 'TYPO')
    -- A stale done.actor from an earlier child with the same id is rejected.
    local leaf = machine.create { id = 'leaf', initial = 'open', states = { open = { on = { CLOSE = 'closed' } }, closed = { type = 'final' } } }
    local parent = machine.create { id = 'parent', initial = 'idle', states = { idle = { on = {
      ADD = { actions = machine.spawn(leaf, { id = 'x' }) }, DROP = { actions = machine.stop('x') } } } } }
    local p = parent:start { scheduler = machine.manual_scheduler() }
    p:send('ADD')
    local old = p:child('x')
    p:send('DROP'); p:send('ADD')
    local snapshot = machine.raw(p:snapshot())
    local _, _, record = parent:transition(snapshot, { type = 'done.actor.x', id = 'x', token = old._token })
    assert(record.rejected and record.reason == 'stale', 'a stale token removed the new child')
    p:child('x'):send('CLOSE')
    assert(#p:children() == 0, 'the current child still finishes')
  end,

  ['event schemas validate external events and drive accepted()'] = function()
    local chart = machine.create {
      id = 'schema', initial = 'clean',
      events = { EDIT = { text = 'string' }, SAVE = {}, RESIZE = { width = 'integer', animate = 'boolean?' } },
      states = {
        clean = { on = { EDIT = 'dirty', RESIZE = {} } },
        dirty = { on = { SAVE = 'clean', EDIT = {} } },
      },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    fails(function() actor:send('UNKNOWN') end, 'UnknownEvent')
    fails(function() actor:can('UNKNOWN') end, 'UnknownEvent')
    fails(function() actor:send('EDIT') end, 'requires text')
    fails(function() actor:send { type = 'EDIT', text = 1 } end, 'must be string')
    fails(function() actor:send { type = 'EDIT', text = 'x', other = 1 } end, 'not declared')
    fails(function() actor:send { type = 'RESIZE', width = 1.5 } end, 'must be integer')
    assert(join(actor:accepted()) == 'EDIT,RESIZE')
    actor:send { type = 'EDIT', text = 'x' }
    assert(join(actor:accepted()) == 'EDIT,SAVE')
  end,

  ['observer records carry steps, rejections and plain context'] = function()
    local chart = machine.create {
      id = 'obs', initial = 'a', context = { n = 0 },
      states = { a = { on = { GO = { target = 'b', guard = 'ok', actions = assign { n = 1 } } } }, b = { on = { BACK = 'a' } } },
      guards = { ok = function() return true end },
    }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    local records = recorder(actor)
    actor:send('BACK') -- declared (b handles it) but not accepted in a
    local rejected = records[1]
    assert(rejected.rejected and rejected.reason == 'no_transition' and rejected.actor == 'obs' and rejected.origin == 'external')
    actor:send { type = 'GO', note = 'hi' }
    local r = records[2]
    assert(r.kind == 'transition' and r.handled and not r.rejected and r.event.note == 'hi')
    assert(r.microsteps[1].transitions[1].guard == 'ok' and r.microsteps[1].transitions[1].source == 'a')
    assert(r.microsteps[1].transitions[1].index == chart:graph().transitions[1].index)
    assert(join(r.exited) == 'a' and join(r.entered) == 'b' and join(r.states) == 'b')
    assert(type(r.context) == 'table' and r.context.n == 1)
    assert(o.json.decode(o.json.encode(r)).context.n == 1)
  end,

  ['rejected events keep the same snapshot, so the signal is not written'] = function()
    local chart = machine.create { id = 'w', initial = 'a', states = { a = { on = { GO = 'b' } }, b = { on = { BACK = 'a' } } } }
    local actor = chart:start { scheduler = machine.manual_scheduler() }
    local before = machine.raw(actor:snapshot())
    assert(actor:send('BACK') == false)
    assert(machine.raw(actor:snapshot()) == before)
    actor:send('GO')
    assert(machine.raw(actor:snapshot()) ~= before and actor:matches('b'))
  end,

  ['persist and restore map old state IDs onto a new chart'] = function()
    local clock = machine.manual_scheduler()
    local v1 = machine.create {
      id = 'editor', initial = 'editing', context = { text = '', count = 1 },
      states = {
        editing = { initial = 'clean', states = { clean = { on = { TYPE = 'dirty' } }, dirty = { after = { [100] = 'autosaved' } }, autosaved = {} } },
        closed = {},
      },
    }
    local actor = v1:start { scheduler = clock }
    actor:send('TYPE')
    local saved = actor:persist()
    assert(o.json.decode(o.json.encode(saved)).states[2] == 'editing.dirty')
    -- Same chart: exact restore, timers restart.
    local same = v1:start { scheduler = clock, snapshot = saved }
    assert(same:matches('editing.dirty'))
    clock.advance(100)
    assert(same:matches('editing.autosaved'))
    -- New chart renames dirty to modified, drops autosaved, and changes count's type.
    local v2 = machine.create {
      id = 'editor', initial = 'editing', context = { text = 'default', count = 'one', mode = 'insert' },
      states = { editing = { initial = 'clean', states = { clean = {}, modified = { initial = 'typing', states = { typing = {}, paused = {} } } } } },
    }
    local mapped = v2:restore(saved, { renames = { ['editing.dirty'] = 'editing.modified' } })
    assert(join(mapped.states) == 'editing,editing.modified,editing.modified.typing', join(mapped.states))
    assert(mapped.context.text == '' and mapped.context.count == 'one' and mapped.context.mode == 'insert')
    local restored = v2:start { scheduler = clock, snapshot = mapped }
    assert(restored:matches('editing.modified.typing'))
    -- Unknown states fall back to the nearest surviving ancestor.
    local fallback = v2:restore({ machine = 'editor', states = { 'editing', 'editing.autosaved' }, context = {} })
    assert(join(fallback.states) == 'editing,editing.clean')
    fails(function() v2:start { snapshot = saved } end, 'use restore')
  end,

  ['the pure transition function is deterministic and side-effect free'] = function()
    local ran = 0
    local chart = machine.create {
      id = 'pure', initial = 'a', context = { n = 0 },
      states = { a = { on = { GO = { target = 'b', actions = { assign { n = 1 }, function() ran = ran + 1 end } } } },
        b = { after = { [10] = 'a' } } },
    }
    local s0 = chart:initial()
    local s1, effects = chart:transition(s0, 'GO')
    local s1b = chart:transition(s0, 'GO')
    assert(ran == 0 and s0.states[1] == 'a' and s0.context.n == 0)
    assert(s1.states[1] == 'b' and s1.context.n == 1 and s1b.context.n == 1 and s1 ~= s1b)
    local kinds = {}
    for i, effect in ipairs(effects) do kinds[i] = effect.kind end
    -- Exiting a closes its entry scope, then the action, then b's timer.
    assert(join(kinds) == 'scope_close,action,timer_start' and effects[3].delay == 10, join(kinds))
    assert(chart:can(s0, 'GO') and not chart:can(s1, 'GO'))
  end,

  ['the snapshot lives in one signal that drives the view'] = function(t)
    local chart = machine.create {
      id = 'counter', initial = 'idle', context = { n = 0 },
      states = {
        idle = { on = { INC = { actions = assign { n = function(c) return c.n + 1 end } }, LOCK = 'locked' } },
        locked = { on = { UNLOCK = 'idle' } },
      },
    }
    local actor = chart:actor { scheduler = machine.manual_scheduler() }
    local started = o.signal(false)
    t:mount(function()
      return o.column { key = 'root',
        o.text { key = 'count', text = tostring(actor:context().n) },
        o.text { key = 'mode', text = actor:matches('locked') and 'locked' or 'idle' },
        o.button { key = 'start', label = 'Start', enabled = not started(), on_press = function() started:set(true); actor:start() end },
        o.button { key = 'inc', label = 'Increment', enabled = started() and actor:can('INC'), on_press = actor:sender('INC') },
        o.button { key = 'lock', label = 'Lock', enabled = started() and actor:can('LOCK'), on_press = actor:sender('LOCK') },
        o.button { key = 'unlock', label = 'Unlock', enabled = started() and actor:can('UNLOCK'), on_press = actor:sender('UNLOCK') },
      }
    end)
    t:click('root/start')
    t:click('root/inc'); t:click('root/inc')
    assert(t:node('root/count').label == '2')
    t:click('root/lock')
    assert(t:node('root/mode').label == 'locked')
    fails(function() t:click('root/inc') end, 'DevelopmentTargetDisabled')
    t:click('root/unlock')
    t:click('root/inc')
    assert(t:node('root/count').label == '3' and t:node('root/mode').label == 'idle')
  end,

  ['records show inter-actor sends and errors'] = function()
    local clock = machine.manual_scheduler()
    local item = machine.create { id = 'item', initial = 'idle', events = { PING = {} }, states = {
      idle = { on = { PING = { actions = machine.send_parent({ type = 'PONG' }) } } } } }
    local list = machine.create { id = 'list', initial = 'ready', context = { n = 0 },
      events = { ADD = {}, PING = {}, PONG = {}, BAD = {}, BOOM = {} },
      states = { ready = { on = {
        ADD = { actions = machine.spawn(item, { id = 'one' }) },
        PING = { actions = machine.send_to('one', 'PING') },
        PONG = { actions = assign { n = function(c) return c.n + 1 end } },
        BAD = { guard = function() error('guard broke') end, target = 'ready' },
        BOOM = { actions = function() error('InvalidThing: action broke') end },
      } } } }
    local records = {}
    local stop = machine.inspect(function(r) if r.kind == 'transition' then records[#records + 1] = r end end)
    local actor = list:start { scheduler = clock }
    actor:send('ADD')
    actor:send('PING')
    stop()
    local by = {}
    for _, r in ipairs(records) do by[r.actor .. ':' .. r.event.type] = r end
    local ping = by['list:PING']
    assert(#ping.sent == 1 and ping.sent[1].kind == 'send_to' and ping.sent[1].to == 'list/one'
      and ping.sent[1].event == 'PING', 'send_to is on the sender record')
    local child = by['list/one:PING']
    assert(child.origin == 'actor' and child.from == 'list', 'the receiver record names its sender')
    assert(child.sent[1].kind == 'send_parent' and child.sent[1].to == 'list' and child.sent[1].event == 'PONG')
    local pong = by['list:PONG']
    assert(pong.origin == 'actor' and pong.from == 'list/one' and actor:context().n == 1)
    assert(#by['list:ADD'].sent == 0 and by['list:ADD'].error == nil)

    local seen = recorder(actor)
    local ok, err = pcall(actor.send, actor, 'BAD')
    assert(not ok and tostring(err):find('guard broke'))
    local bad = last(seen)
    assert(bad.event.type == 'BAD' and bad.rejected and bad.reason == 'error' and bad.error.code == 'Error'
      and bad.error.message:find('guard broke') and join(bad.states) == 'ready' and bad.commit == nil,
      'a transition error still emits a rejected record')
    ok, err = pcall(actor.send, actor, 'BOOM')
    assert(not ok and tostring(err):find('action broke'))
    local boom = last(seen)
    assert(boom.event.type == 'BOOM' and not boom.rejected and boom.error.code == 'InvalidThing'
      and boom.error.message:find('action broke'), 'an effect error marks its record')
    actor:stop()
  end,

  ['a shared manual clock drops the timers and scopes of stopped and exited states'] = function()
    local clock = machine.manual_scheduler()
    local chart = machine.create { id = 'timed', initial = 'waiting', events = { FLIP = {} }, states = {
      waiting = { after = { [1000] = 'done' }, on = { FLIP = 'other' } },
      other = { after = { [1000] = 'done' }, on = { FLIP = 'waiting' } },
      done = {} } }
    for _ = 1, 2000 do chart:start { scheduler = clock }:stop() end
    local live = chart:start { scheduler = clock }
    for _ = 1, 2000 do live:send('FLIP') end
    assert(#clock.timers <= 64, 'cancelled timers stay queued: ' .. #clock.timers)
    assert(clock.pending() == 1)
    local children = 0
    for _ in pairs(live._root_scope and live._root_scope.children or {}) do children = children + 1 end
    assert(children <= 64, 'exited state scopes stay under the root: ' .. children)
    clock.advance(1000)
    assert(live:matches('done'))
  end,

  ['the default logical clock removes a cancelled timer when its state exits or its actor stops'] = function()
    assert(machine.virtual_clock and machine.clock, 'ouroctl test runs the native scheduler on a virtual clock')
    local queue = machine.clock.timers
    local base = #queue
    local chart = machine.create { id = 'hourly', initial = 'idle', events = { ENTER = {}, LEAVE = {} }, states = {
      idle = { on = { ENTER = 'waiting' } },
      waiting = { after = { [3600000] = 'expired' }, on = { LEAVE = 'idle' } },
      expired = {} } }
    -- The queue is checked on every cycle, so a few thousand cycles prove the
    -- same as more; test-stress covers volume. Kept small for the 10 s worker.
    local live = chart:start()
    for _ = 1, 2000 do
      live:send('ENTER')
      assert(#queue == base + 1)
      live:send('LEAVE')
    end
    assert(#queue == base, 'exited states leave timers queued: ' .. #queue - base)
    for _ = 1, 500 do
      local actor = chart:start()
      actor:send('ENTER')
      actor:stop()
    end
    assert(#queue == base, 'stopped actors leave timers queued: ' .. #queue - base)
    -- Firing order and deadlines are unchanged by removal.
    live:send('ENTER')
    machine.advance(3599999)
    assert(live:matches('waiting'))
    machine.advance(1)
    assert(live:matches('expired') and #queue == base)
    live:stop()
  end,
}
