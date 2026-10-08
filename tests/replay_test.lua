-- Recording and replay (design/statecharts.md §14) and the logical clock
-- (§8). ouroctl test is a deterministic host, so the default scheduler runs
-- on a virtual clock that only machine.advance moves.
local o = require('ouro')
local machine = o.machine
local charts = require('examples.stopwatch.charts')

local function record(body)
  local lines = {}
  local recorder = machine.recorder(function(line) lines[#lines + 1] = line end, {app = 'test'})
  local ok, err = pcall(body)
  recorder.stop()
  assert(ok, err)
  return lines
end

local function fails(fn, pattern)
  local ok, err = pcall(fn)
  assert(not ok, 'expected failure: ' .. pattern)
  assert(tostring(err):find(pattern, 1, true), tostring(err))
end

-- A stopwatch session: ticks, a lap, a pause, settings.
local function session()
  local sw = charts.stopwatch:start { id = 'stopwatch' }
  sw:send('START')
  machine.advance(250)
  sw:send('LAP')
  machine.advance(120)
  sw:send('STOP')
  sw:send('OPEN_SETTINGS')
  sw:send { type = 'MAX_LAPS', value = 3 }
  sw:send('SAVE_SETTINGS')
  machine.advance(40)
  sw:send('START')
  machine.advance(300)
  sw:stop()
  return sw
end

return {
  ['machine.now is the logical clock: frozen per step, virtual here, and timer events carry their fire time'] = function()
    assert(machine.virtual_clock, 'ouroctl test runs a virtual clock')
    local start = machine.now()
    local seen = {}
    local chart = machine.create {
      id = 'clocked', initial = 'idle', context = { at = 0, fired = 0 },
      states = {
        idle = { on = { GO = { target = 'waiting', actions = machine.assign { at = function() return machine.now() end } } } },
        waiting = { after = { [75] = { target = 'idle', actions = machine.assign {
          fired = function(_, e) seen[#seen + 1] = e.time_ms; return e.time_ms end } } } },
      },
    }
    local actor = chart:start()
    actor:send('GO')
    assert(actor:context().at == start, 'assign reads the step instant')
    assert(actor:pending_timers()[1].time_ms == start)
    machine.advance(74)
    assert(actor:matches('waiting'))
    machine.advance(1)
    assert(actor:matches('idle') and actor:context().fired == start + 75 and seen[1] == start + 75)
    assert(actor:now() == start + 75)
    -- The manual scheduler's clock is the actor's clock too.
    local clock = machine.manual_scheduler()
    local manual = chart:start { scheduler = clock }
    clock.advance(10)
    manual:send('GO')
    assert(manual:context().at == 10 and manual:now() == 10)
    clock.advance(75)
    assert(manual:context().fired == 85)
    actor:stop()
  end,

  ['a recorded stopwatch session replays to identical records and snapshots'] = function()
    local lines = record(session)
    assert(#lines > 10, #lines)
    local header = o.json.decode(lines[1])
    assert(header.format == 'ouro.machine.log' and header.version == 1)
    local kinds = {}
    for i = 2, #lines do
      local entry = o.json.decode(lines[i])
      kinds[entry.k] = (kinds[entry.k] or 0) + 1
    end
    assert(kinds.start == 1 and kinds.stop == 1 and kinds.timer >= 5 and kinds.event == 7, o.json.encode(kinds))
    local report = machine.replay(table.concat(lines, '\n'))
    assert(report.ok, machine.replay_text(report))
    assert(report.compared == #lines - 1)
  end,

  ['a changed chart reports the first divergent step with a snapshot diff'] = function()
    local lines = record(session)
    -- Same chart, but ticks count 50 ms: the first tick's context differs.
    local changed = machine.create {
      id = 'stopwatch', type = 'parallel', order = { 'clock', 'settings' },
      context = { elapsed = 0, banked = 0, started_at = 0, laps = {}, max_laps = 5, show_tenths = true,
        draft_max_laps = 5, draft_show_tenths = true },
      states = {
        clock = { initial = 'idle', states = {
          idle = { on = { START = 'running' } },
          running = { after = { [100] = { target = 'running', reenter = true,
            actions = machine.assign { elapsed = function(c) return c.elapsed + 50 end } } },
            on = { STOP = 'paused', LAP = {} } },
          paused = { on = { START = 'running' } },
        } },
        settings = { initial = 'closed', states = { closed = { on = { OPEN_SETTINGS = 'open' } },
          open = { on = { MAX_LAPS = machine.set('draft_max_laps', 'integer'), SAVE_SETTINGS = 'closed' } } } },
      },
    }
    local report = machine.replay(lines, { charts = { stopwatch = changed } })
    assert(not report.ok)
    local d = report.divergence
    local text = machine.replay_text(report)
    assert(d.step == 3, text) -- start, START, then the first tick
    assert(text:find('snapshot.stopwatch.context.elapsed', 1, true), text)
    assert(text:find('recorded 100', 1, true) and text:find('replayed 50', 1, true), text)
  end,

  ['replay stubs invokes and tasks with their recorded results'] = function()
    local runs = 0
    local chart = machine.create {
      id = 'loader', initial = 'loading', context = { items = {}, notes = 0 },
      actors = {
        load = function() runs = runs + 1; return { 'a', 'b' } end,
        note = function(input) runs = runs + 1; return input end,
      },
      states = {
        loading = { invoke = { src = 'load', on_done = { target = 'ready',
          actions = machine.assign { items = function(_, e) return e.output end } } } },
        ready = { on = {
          NOTE = { actions = machine.spawn('note', { input = function(c) return #c.items end }) },
          ['done.actor.*'] = { actions = machine.assign { notes = function(c, e) return c.notes + e.output end } },
        } },
      },
    }
    -- Record on a manual scheduler, which runs invokes and tasks for real.
    local clock = machine.manual_scheduler()
    local lines = {}
    local recorder = machine.recorder(function(line) lines[#lines + 1] = line end, { scheduler = clock })
    local actor = chart:start { id = 'loader', scheduler = clock }
    clock.advance(5)
    clock.run_tasks()
    assert(actor:matches('ready') and #actor:context().items == 2)
    actor:send('NOTE')
    clock.advance(5)
    clock.run_tasks()
    assert(actor:context().notes == 2)
    recorder.stop()
    assert(runs == 2)
    local report = machine.replay(lines)
    assert(report.ok, machine.replay_text(report))
    assert(runs == 2, 'replay never runs invoke or task sources')
    local kinds = {}
    for i = 2, #lines do kinds[#kinds + 1] = o.json.decode(lines[i]).k end
    assert(table.concat(kinds, ',') == 'start,invoke,event,task', table.concat(kinds, ','))
    -- A recording whose invoke result no longer fits: the chart now has no invoke.
    local changed = machine.create { id = 'loader', initial = 'loading', context = { items = {}, notes = 0 },
      states = { loading = { on = { NOTE = {} } }, ready = {} } }
    report = machine.replay(lines, { charts = { loader = changed } })
    assert(not report.ok and report.divergence.step == 2, machine.replay_text(report))
    assert(machine.replay_text(report):find('no running invoke', 1, true), machine.replay_text(report))
  end,

  ['a live logical clock fires late wakes at their deadlines, so the stopwatch does not drift'] = function()
    -- A live clock whose host wakes it 7 ms late every time.
    local wall = 1000
    local clock = machine.logical_clock { wall = function() return wall end }
    local function scope(parent)
      local s = { alive = true, children = {} }
      if type(parent) == 'table' then parent.children[#parent.children + 1] = s end
      return s
    end
    local function close(s) s.alive = false; for _, c in ipairs(s.children) do close(c) end end
    local scheduler = { open = scope, close = close, alive = function(s) return s.alive end,
      run = function() end, after = clock.after, clock = clock.now, sync = clock.sync }
    local sw = charts.stopwatch:start { scheduler = scheduler }
    sw:send('START')
    assert(sw:context().started_at == 1000)
    for _ = 1, 100 do
      wall = clock.next() + 7
      clock.sync()
    end
    assert(sw:context().elapsed == 10000, 'ticks land on deadlines: ' .. sw:context().elapsed)
    wall = wall + 50
    sw:send('STOP') -- an input syncs the clock to wall time first
    assert(sw:context().elapsed == 10057, sw:context().elapsed)
    sw:stop()
  end,

  ['an input that arrives after a deadline the host has not woken for lets the timer fire first'] = function()
    local wall = 5000
    local clock = machine.logical_clock { wall = function() return wall end }
    local function scope(parent)
      local s = { alive = true, children = {} }
      if type(parent) == 'table' then parent.children[#parent.children + 1] = s end
      return s
    end
    local function close(s) s.alive = false; for _, c in ipairs(s.children) do close(c) end end
    local scheduler = { open = scope, close = close, alive = function(s) return s.alive end,
      run = function() end, after = clock.after, clock = clock.now, sync = clock.sync }
    local lines = {}
    local recorder = machine.recorder(function(line) lines[#lines + 1] = line end, { scheduler = scheduler })
    local sw = charts.stopwatch:start { id = 'stopwatch', scheduler = scheduler }
    sw:send('START')
    wall = 5130 -- the 100 ms tick is due, but no wake ran
    sw:send('LAP')
    sw:stop()
    recorder.stop()
    local kinds = {}
    for i = 2, #lines do
      local entry = o.json.decode(lines[i])
      kinds[#kinds + 1] = entry.k .. ':' .. #entry.r .. '@' .. entry.t
    end
    assert(table.concat(kinds, ' ') == 'start:1@0 event:1@0 timer:1@100 event:1@130 stop:0@130', table.concat(kinds, ' '))
    assert(sw:context().laps[1].total == 130)
    local report = machine.replay(lines)
    assert(report.ok, machine.replay_text(report))
  end,

  ['component machines record by instance path and replay with their plain props'] = function(t)
    local chart = machine.create {
      id = 'collapsible', initial = 'closed',
      context = function(props) return { title = props.title, opened = 0 } end,
      states = {
        closed = { on = { TOGGLE = { target = 'open', actions = machine.assign { opened = function(c) return c.opened + 1 end } } } },
        open = { on = { TOGGLE = 'closed' }, after = { [500] = 'closed' } },
      },
    }
    local Collapsible = machine.component(chart, function(self, props)
      return o.column { key = 'box',
        o.button { key = 'toggle', label = self:context().title, send = self:event('TOGGLE') } }
    end)
    local Panel = machine.component(machine.create { id = 'panel', initial = 'shown', states = { shown = {} } },
      function(self, props)
        return o.column { key = 'inner', Collapsible { key = 'details', title = 'Details', on_close = function() end } }
      end)
    local lines = {}
    local recorder = machine.recorder(function(line) lines[#lines + 1] = line end)
    t:mount(function()
      return o.column { key = 'root',
        Collapsible { key = 'first', title = 'First' },
        Collapsible { key = 'second', title = 'Second' },
        Panel { key = 'panel' },
      }
    end)
    t:click('root/first/box/toggle')
    t:click('root/second/box/toggle')
    t:click('root/panel/inner/details/box/toggle')
    t:advance(500)
    t:click('root/first/box/toggle')
    recorder.stop()
    local actors, inputs = {}, {}
    for i = 2, #lines do
      local entry = o.json.decode(lines[i])
      if entry.k == 'start' then actors[#actors + 1] = entry.a; inputs[entry.a] = entry.input end
    end
    assert(table.concat(actors, ',') == 'collapsible@first,collapsible@second,collapsible@panel/details',
      table.concat(actors, ','))
    assert(inputs['collapsible@panel/details'].title == 'Details' and inputs['collapsible@panel/details'].on_close == nil,
      'props keep plain data only')
    local report = machine.replay(lines)
    assert(report.ok, machine.replay_text(report))
    assert(report.compared == #lines - 1)
  end,

  ['activation hooks and MCP handlers tag their task, so their events record those origins'] = function(t)
    local chart = machine.create { id = 'toggle', initial = 'off',
      states = { off = { on = { GO = 'on' } }, on = { on = { GO = 'off' } } } }
    local lines = {}
    local recorder = machine.recorder(function(line) lines[#lines + 1] = line end)
    local actor = chart:start { id = 'toggle' }
    -- A callback is a task. desktop_application.lua runs activation hooks
    -- like this; the host tags MCP action tasks natively.
    t:mount(function()
      return o.button { key = 'hook', label = 'hook', on_press = function()
        machine._with_origin('activation', function() actor:send('GO') end)
        actor:send('GO')
      end }
    end)
    t:click('hook')
    recorder.stop()
    actor:stop()
    local origins = {}
    for i = 2, #lines do
      local entry = o.json.decode(lines[i])
      if entry.k == 'event' then origins[#origins + 1] = entry.o end
    end
    assert(table.concat(origins, ',') == 'activation,app', table.concat(origins, ','))
  end,

  ['an input whose effects exceed the JSON value limit still records and replays'] = function()
    local chart = machine.create { id = 'burst', initial = 'idle', context = { n = 0 },
      events = { BURST = {}, TICK = {} },
      actions = { burst = function(_, _, self) for _ = 1, 1000 do self:send('TICK') end end },
      states = { idle = { on = {
        BURST = { actions = 'burst' },
        TICK = { actions = machine.assign { n = function(c) return c.n + 1 end } },
      } } } }
    local lines = {}
    local failure
    local recorder = machine.recorder(function(line) lines[#lines + 1] = line end,
      { app = 'test', fail = function(reason) failure = reason end })
    local actor = chart:start { id = 'burst' }
    assert(actor:send('BURST'))
    recorder.stop()
    actor:stop()
    assert(actor:context().n == 1000)
    assert(failure == nil, failure)
    assert(#lines == 3, #lines) -- header, start, BURST
    local ok = pcall(o.json.decode, lines[3])
    assert(not ok, 'the BURST line is beyond the native decoder, so it exercises the Lua fallback')
    local entry = machine._json_decode(lines[3])
    assert(entry.k == 'event' and #entry.r == 1001, #entry.r)
    local report = machine.replay(lines)
    assert(report.ok, machine.replay_text(report))
  end,

  ['a recorder that cannot write stops and reports why, and the app keeps running'] = function()
    local chart = machine.create { id = 'counter', initial = 'idle', context = { n = 0 },
      states = { idle = { on = { INC = { actions = machine.assign { n = function(c) return c.n + 1 end } } } } } }
    local reason
    local writes = 0
    local recorder = machine.recorder(function()
      writes = writes + 1
      if writes > 2 then error('disk full') end
    end, { fail = function(text) reason = text end })
    local actor = chart:start { id = 'counter' }
    assert(actor:send('INC')) -- the third write raises inside the recorder
    assert(actor:send('INC'))
    assert(actor:context().n == 2, 'processing went on')
    assert(reason and reason:find('disk full', 1, true), tostring(reason))
    assert(machine._hooks == nil, 'the failed recorder uninstalled itself')
    recorder.stop()
    actor:stop()
  end,

  ['machine.advance needs a virtual clock'] = function()
    fails(function() machine.advance(-1) end, 'nonnegative integer')
  end,
}
