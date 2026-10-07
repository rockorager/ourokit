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

  ['machine.advance needs a virtual clock'] = function()
    fails(function() machine.advance(-1) end, 'nonnegative integer')
  end,
}
