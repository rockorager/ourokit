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

-- A notification center (as in a shell): each NOTIFY carries an image, goes
-- to the front of a 50-item list and starts a popup child with a 5 s timer.
local function bytes_of(seed, count)
  local out, x = {}, seed * 7919 + 17
  for i = 1, count do x = (x * 1103515245 + 12345) % 2147483648; out[i] = string.char(x % 256) end
  return table.concat(out)
end
local notification_icon = bytes_of(0, 4096)
local function notification_center(id)
  local popup = machine.create {
    id = id .. '_popup', initial = 'shown',
    context = function(input) return { n = input.n } end,
    states = { shown = { after = { [5000] = 'gone' }, on = { DISMISS = 'gone' } }, gone = { type = 'final' } },
  }
  return machine.create {
    id = id, initial = 'running', context = { list = {}, count = 0 },
    states = { running = { on = { NOTIFY = { actions = {
      machine.assign {
        list = function(c, e)
          local list = { e.n }
          for i, n in ipairs(c.list) do if i < 50 then list[#list + 1] = n end end
          return list
        end,
        count = function(c) return c.count + 1 end,
      },
      machine.spawn(popup, { id = function(_, e) return 'popup' .. e.n.id end, input = function(_, e) return { n = e.n } end }),
    } } } } },
  }
end
local function notify(actor, i, image_bytes)
  actor:send { type = 'NOTIFY', n = { id = i, app = 'mail', summary = 'Message ' .. i,
    body = 'Hello there, this is notification number ' .. i, icon = notification_icon,
    image = { width = 64, height = 64, rowstride = 256, alpha = true, data = bytes_of(i, image_bytes) } } }
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
    assert(header.format == 'ouro.machine.log' and header.version == 3)
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

  -- Second review, M-5(a): two roots on the default id shared one path, so
  -- replay sent every event to the newest. Root paths now get a suffix
  -- (eb2b142), which the recording keeps.
  ['review2 M-5a: two roots with the default id'] = function()
    local counter = machine.create {
      id = 'counter2', initial = 'on', context = { n = 0 },
      events = { INC = {} },
      states = { on = { on = { INC = { actions = machine.assign { n = function(c) return c.n + 1 end } } } } },
    }
    local lines = record(function()
      local a = counter:start {}
      local b = counter:start {}
      assert(a.path == 'counter2' and b.path == 'counter2#2', b.path)
      a:send('INC'); a:send('INC'); b:send('INC')
      a:stop(); b:stop()
    end)
    local report = machine.replay(table.concat(lines, '\n'))
    assert(report.ok, machine.replay_text(report))
  end,

  -- Second review, M-5(b): JSON turned an integral float into an integer.
  ['review2 M-5b: float payloads keep their type'] = function()
    local chart = machine.create {
      id = 'vol', initial = 'on', context = { label = '' },
      events = { SET = { value = 'number' } },
      states = { on = { on = { SET = { actions = machine.assign { label = function(_, e) return 'Volume ' .. tostring(e.value) end } } } } },
    }
    local lines = record(function()
      local a = chart:start { id = 'vol' }
      a:send { type = 'SET', value = 3.0 }
      assert(a:context().label == 'Volume 3.0')
      a:stop()
    end)
    local report = machine.replay(table.concat(lines, '\n'))
    assert(report.ok, machine.replay_text(report))
  end,

  -- Second review, M-5(c): integer keys became strings, NaN and inf strings.
  ['review2 M-5c: integer-keyed tables and non-finite numbers keep their type'] = function()
    local chart = machine.create {
      id = 'sparse', initial = 'on', context = { picked = '' },
      events = { PICK = { map = 'table', limit = 'number' } },
      states = { on = { on = { PICK = { actions = machine.assign {
        picked = function(_, e) return tostring(e.map[10]) .. ' ' .. tostring(e.map.name) .. ' ' .. tostring(e.map[1.5]) end,
        limit = function(_, e) return e.limit end,
        weird = function(_, e) return { [true] = 'yes', ['$f'] = 'literal' } end,
      } } } } },
    }
    local lines = record(function()
      local a = chart:start { id = 'sparse' }
      a:send { type = 'PICK', map = { [10] = 'ten', [20] = 'twenty', name = 'n', [1.5] = 'half' }, limit = math.huge }
      assert(a:context().picked == 'ten n half' and a:context().limit == math.huge)
      a:send { type = 'PICK', map = {}, limit = 0 / 0 }
      a:stop()
    end)
    local report = machine.replay(table.concat(lines, '\n'))
    assert(report.ok, machine.replay_text(report))
    -- Version 1 logs (no type tags) stay readable.
    local old = { '{"format":"ouro.machine.log","version":1,"t0":0}',
      '{"k":"start","t":0,"a":"vol","m":"vol","input":{},"r":[{"a":"vol","e":"ouro.init","tr":[]}],"s":{"vol":{"states":["on"],"status":"active","children":[],"context":{"label":""}}}}' }
    local charts = { vol = machine.create { id = 'vol', initial = 'on', context = { label = '' }, states = { on = {} } } }
    report = machine.replay(old, { charts = charts })
    assert(report.ok, machine.replay_text(report))
  end,

  -- Second review, L-3: a second recorder replaced the development recorder,
  -- and stopping it left none installed.
  ['review2 L-3: recorders coexist, and stopping one keeps the others'] = function()
    local chart = machine.create { id = 'tick', initial = 'idle', context = { n = 0 },
      states = { idle = { on = { INC = { actions = machine.assign { n = function(c) return c.n + 1 end } } } } } }
    local first, second = {}, {}
    local dev = machine.recorder(function(line) first[#first + 1] = line end)
    local actor = chart:start { id = 'tick' }
    local nested = machine.recorder(function(line) second[#second + 1] = line end)
    actor:send('INC')
    nested.stop()
    actor:send('INC')
    dev.stop()
    actor:stop()
    -- header, start, INC, INC for the first; header and the one INC for the second.
    assert(#first == 4 and #second == 2, #first .. ' ' .. #second)
    assert(machine._hooks == nil)
    local report = machine.replay(first)
    assert(report.ok, machine.replay_text(report))
  end,

  -- Gap 7: an action encoding its invoke output (an ouro.mcp.call reply)
  -- raised "value cannot be encoded as JSON": the output is a read-only view.
  ['gap 7: json.encode accepts machine views, so an action can encode an invoke output'] = function()
    local clock = machine.manual_scheduler()
    local encoded
    local chart = machine.create { id = 'mcp', initial = 'calling', context = {},
      actors = { call = function() return { result = { content = { { type = 'text', text = '{}' } }, structuredContent = {} } } end },
      states = {
        calling = { invoke = { src = 'call', on_done = { target = 'done', actions = function(_, e) encoded = o.json.encode(e.output) end } } },
        done = {},
      } }
    local actor = chart:start { scheduler = clock }
    clock.run_tasks()
    assert(actor:matches('done'), 'the on_done action did not raise')
    assert(encoded == '{"result":{"content":[{"text":"{}","type":"text"}],"structuredContent":{}}}', encoded)
    assert(o.json.encode(actor:context()) == '{}')
    actor:stop()
  end,

  -- Gap 7: values JSON cannot hold record as markers; the recorder never throws.
  ['gap 7: handles and raw bytes in invoke outputs record as markers and replay'] = function()
    local clock = machine.manual_scheduler()
    local chart = machine.create { id = 'native', initial = 'calling', context = {},
      actors = { call = function() return { fn = print, bytes = '\255\254', text = 'ok' } end },
      states = {
        calling = { invoke = { src = 'call', on_done = { target = 'done',
          actions = machine.assign { reply = function(_, e) return e.output end } } } },
        done = {},
      } }
    local lines, failure = {}, nil
    local recorder = machine.recorder(function(line) lines[#lines + 1] = line end,
      { scheduler = clock, fail = function(reason) failure = reason end })
    local actor = chart:start { id = 'native', scheduler = clock }
    clock.run_tasks()
    recorder.stop()
    actor:stop()
    assert(failure == nil, failure)
    local entry = o.json.decode(lines[3])
    assert(entry.e.output.fn['$h'] == 'function' and entry.e.output.bytes['$x'] == 'fffe', lines[3])
    local report = machine.replay(lines)
    assert(report.ok, machine.replay_text(report))
    assert(report.handles == 2 and machine.replay_text(report):find('native handles', 1, true), machine.replay_text(report))
  end,

  -- Gap 9: generation pruned paths silently when an action raised.
  ['gap 9: generation keeps paths whose actions raise and reports them'] = function()
    local chart = machine.create {
      id = 'shellish', initial = 'idle', events = { LOCK = {}, UNLOCK = {} },
      actions = { tell_session = function() error('session actor has not started') end },
      states = {
        idle = { on = { LOCK = { target = 'locked', actions = 'tell_session' } } },
        locked = { on = { UNLOCK = 'idle' }, initial = 'prompt', states = { prompt = {} } },
      },
    }
    local result = machine.paths(chart)
    assert(result.states.reached == result.states.total, result.states.reached .. '/' .. result.states.total)
    assert(#result.issues == 1, #result.issues)
    local issue = result.issues[1]
    assert(issue.kind == 'error' and issue.message:find('session actor has not started', 1, true), issue.message)
    assert(issue.steps[1] == 'LOCK', issue.steps[1])
    local log = machine.paths_log(chart, result)
    local report = machine.replay(log, { charts = { shellish = chart } })
    assert(report.ok, machine.replay_text(report))
  end,

  -- Gap 3: a refused send whose event a function computes was reported as nil.
  ['gap 3: generation names the computed event of a send refused by an unstarted actor'] = function()
    local shell = machine.create { id = 'shell3', initial = 'idle', events = { ACTIVATE = { workspace = 'integer' } },
      states = { idle = { on = { ACTIVATE = {} } } } }
    local waiting = shell:actor { system_id = 'shell3' } -- created by the app, never started here
    local chart = machine.create { id = 'workspaces3', initial = 'idle', context = { workspace = 2 }, events = { PICK = {} },
      states = { idle = { on = { PICK = { actions = machine.send_to({ system = 'shell3' },
        function(c) return { type = 'ACTIVATE', workspace = c.workspace } end) } } } } }
    local result = machine.paths(chart)
    local found
    for _, issue in ipairs(result.issues) do if issue.kind == 'not_started' then found = issue end end
    assert(found, 'the refused send is reported')
    assert(found.message == 'workspaces3 sent ACTIVATE to shell3, which has not started', found.message)
    waiting:stop()
  end,

  -- Gap 4: generation ran function actions against the real platform modules,
  -- so an action using ouro.shell (absent in the tool host) raised.
  ['gap 4: generation isolates platform effects and reports them apart from errors'] = function()
    local chart = machine.create { id = 'workspaces4', initial = 'idle', events = { ACTIVATE = {}, DONE = {} },
      actions = { activate = function(_, _, self)
        o.shell.workspaces.activate(3)
        local client <close> = o.desktop.notifications()
        client:send { title = 'Switched to ' .. o.shell.workspaces.name(3) }
        self:send('DONE')
      end },
      states = {
        idle = { on = { ACTIVATE = { target = 'switching', actions = 'activate' } } },
        switching = { on = { DONE = 'switched' } },
        switched = {},
      } }
    assert(o.shell == nil and o.desktop == nil, 'the test host has no shell or desktop modules')
    local result = machine.paths(chart)
    assert(result.states.reached == result.states.total, 'the action still sent DONE')
    local effects, errors = {}, 0
    for _, issue in ipairs(result.issues) do
      if issue.kind == 'effect' then effects[#effects + 1] = issue.message
      elseif issue.kind == 'error' then errors = errors + 1 end
    end
    table.sort(effects)
    assert(errors == 0, 'no real errors')
    assert(table.concat(effects, ',') == 'ouro.desktop.notifications(),ouro.desktop.notifications().send(),'
      .. 'ouro.shell.workspaces.activate(),ouro.shell.workspaces.name()', table.concat(effects, ','))
    assert(o.shell == nil and o.desktop == nil, 'the real modules are back afterwards')
    local report = machine.replay(machine.paths_log(chart, result), { charts = { workspaces4 = chart } })
    assert(report.ok, machine.replay_text(report))
  end,

  -- Recording size (§14 "Size"): the development log of a long-running shell
  -- grew by 190-270 KB per notification popup, because each image was written
  -- with its event, again in every delta of the list holding it and again by
  -- the popup it was passed to. Values of 1 KB or more are now blobs, written
  -- once per log; binary strings are base64.
  ['recording size: 50 notifications with 16 KB images cost about one image each, and replay'] = function()
    local center = notification_center('size_center')
    local lines = record(function()
      local actor = center:start { id = 'center' }
      for i = 1, 50 do notify(actor, i, 16384); machine.advance(1000) end
      machine.advance(6000)
      actor:stop()
    end)
    local bytes, icon_lines = 0, 0
    for _, line in ipairs(lines) do
      bytes = bytes + #line + 1
      if line:find('"k":"blob"', 1, true) and #line > 5000 and #line < 6000 then icon_lines = icon_lines + 1 end
    end
    local per = bytes // 50
    -- One 16 KB image is 21848 bytes of base64.
    assert(per < 26000, 'bytes per notification: ' .. per)
    assert(icon_lines == 1, 'the shared 4 KB icon is written once, not ' .. icon_lines .. ' times')
    local report = machine.replay(lines)
    assert(report.ok, machine.replay_text(report))
    assert(report.compared == 102, report.compared)
  end,

  -- Size policy: the development log rotates into segments; each segment
  -- after the first opens with a checkpoint, and replays alone from it.
  ['rotation: every segment replays from its checkpoint, with popup timers at their recorded deadlines'] = function()
    local center = notification_center('rotate_center')
    local segments, size, limit = { {} }, 0, 60000
    local t0 = machine.now()
    local recorder = machine.recorder(function(line)
      local segment = segments[#segments]
      segment[#segment + 1] = line
      size = size + #line + 1
      return size >= limit
    end, { app = 'test', t0 = t0, rotate = function()
      segments[#segments + 1] = { o.json.encode { format = 'ouro.machine.log', version = 3, t0 = t0, app = 'test', segment = #segments + 1 } }
      size = 0
      return true
    end })
    local ok, err = pcall(function()
      local actor = center:start { id = 'center' }
      for i = 1, 20 do notify(actor, i, 8192); machine.advance(700) end
      machine.advance(6000)
      actor:stop()
    end)
    recorder.stop()
    assert(ok, err)
    assert(#segments >= 3, 'the log rotated: ' .. #segments .. ' segments')
    local pending = 0
    for n, segment in ipairs(segments) do
      if n > 1 then
        local first = o.json.decode(segment[2])
        assert(first.k == 'checkpoint', segment[2])
        for _, line in ipairs(segment) do
          local entry = o.json.decode(line)
          if entry.checkpoint then
            for _, timers in pairs(entry.timers) do pending = pending + #timers end
          end
        end
      end
      local report = machine.replay(segment)
      assert(report.ok, 'segment ' .. n .. ': ' .. machine.replay_text(report))
    end
    assert(pending > 0, 'checkpoints carried running popup timers')
  end,

  -- A spawned task and an invoke started before a rotation finish after it:
  -- the checkpoint lists them, replay stubs them, and their recorded results
  -- apply. A child spawned after the checkpoint gets the live auto id.
  ['rotation: a task and an invoke in flight across a checkpoint complete in the next segment'] = function()
    local chart = machine.create {
      id = 'straddle', initial = 'ready', context = { got = {}, watched = 0 },
      actors = {
        fetch = function(input) return input end,
        watch = function() return 7 end,
      },
      states = { ready = {
        invoke = { id = 'watch', src = 'watch', on_done = { actions = machine.assign {
          watched = function(_, e) return e.output end } } },
        on = {
          FETCH = { actions = machine.spawn('fetch', { id = 'fetch', input = function() return 'first' end }) },
          MORE = { actions = machine.spawn('fetch', { input = function() return 'auto' end }) },
          PING = {},
          ['done.actor.*'] = { actions = machine.assign { got = function(c, e)
            local got = { table.unpack(c.got) }
            got[#got + 1] = e.id .. '=' .. e.output
            return got
          end } },
        },
      } },
    }
    local clock = machine.manual_scheduler()
    local segments, rotate_now = { {} }, false
    local recorder = machine.recorder(function(line)
      local segment = segments[#segments]
      segment[#segment + 1] = line
      return rotate_now
    end, { scheduler = clock, app = 'test', rotate = function()
      rotate_now = false
      segments[#segments + 1] = { o.json.encode { format = 'ouro.machine.log', version = 3, t0 = 0, app = 'test', segment = #segments + 1 } }
      return true
    end })
    local ok, err = pcall(function()
      local actor = chart:start { id = 'straddle', scheduler = clock }
      clock.advance(10)
      actor:send('FETCH')
      clock.advance(10)
      rotate_now = true
      actor:send('PING') -- written to segment 1; the checkpoint opens segment 2
      clock.advance(10)
      assert(#segments == 2, 'rotated once')
      clock.resolve('fetch', 'late')
      clock.resolve('watch', 7)
      actor:send('MORE')
      clock.run_tasks()
      local got = actor:context().got
      assert(#got == 2 and got[1] == 'fetch=late' and got[2]:find('=auto$'), table.concat(got, ','))
      assert(actor:context().watched == 7)
      actor:stop()
    end)
    recorder.stop()
    assert(ok, err)
    local checkpoint
    for _, line in ipairs(segments[2]) do
      local entry = o.json.decode(line)
      if entry.checkpoint then checkpoint = entry end
    end
    for n, segment in ipairs(segments) do
      local report = machine.replay(segment)
      assert(report.ok, 'segment ' .. n .. ': ' .. machine.replay_text(report))
    end
    assert(checkpoint.tasks.straddle[1].id == 'fetch' and checkpoint.tasks.straddle[1].owner == 'ready', segments[2][3])
    assert(checkpoint.invokes.straddle[1].id == 'watch', segments[2][3])
  end,

  -- Generation never runs invoke or task sources; it completes their stubs.
  -- With no recorded output (--from) it used to fabricate one (json.null,
  -- {}), and a chart that reads its output, like ouroshell's clock, got
  -- "attempt to index a userdata (field 'output')" as an issue. Fabricated
  -- results that the chart cannot handle are now skipped as isolated
  -- effects, never reported as errors.
  ['generation: unknown invoke and task outputs are skipped as isolated effects, not errors (ouroshell clock)'] = function()
    local function charts(id)
      return machine.create {
        id = id, initial = 'loading', context = { text = '', zone = '', user = '' },
        actors = {
          now = function() return o.desktop.clock() end,
          whoami = function() return o.session.user() end,
        },
        states = {
          loading = { invoke = { id = 'now', src = 'now',
            on_done = { target = 'showing', actions = machine.assign {
              text = function(_, e) return e.output.text end,
              zone = function(_, e) return e.output.zone:upper() end } },
            on_error = 'failed' } },
          showing = {
            after = { [1000] = 'loading' },
            on = {
              LOCK = { target = 'locking', actions = machine.spawn('whoami', { id = 'who' }) },
            },
          },
          locking = { on = { ['done.actor.who'] = { target = 'locked', actions = machine.assign {
            user = function(_, e) return e.output.name:lower() end } } } },
          locked = {},
          failed = {},
        },
      }
    end
    local chart = charts('clock_isolated')
    local result = machine.paths(chart)
    local errors, skipped = {}, {}
    for _, issue in ipairs(result.issues) do
      if issue.kind == 'error' then errors[#errors + 1] = issue.message end
      if issue.kind == 'isolated' then skipped[#skipped + 1] = issue.message end
    end
    assert(#errors == 0, 'no false errors: ' .. table.concat(errors, ' | '))
    assert(#skipped == 1 and skipped[1]:find('done.invoke.now', 1, true), table.concat(skipped, ' | '))
    assert(machine._paths_summary(result):find('skipped: isolated effect', 1, true), machine._paths_summary(result))
    local reached = {}
    for _, target in ipairs(result.unreached) do reached[target] = false end
    assert(reached.sfailed == nil, 'the error path is still explored')
    assert(reached.sshowing == false, 'no state is reached on a fabricated output')
    -- Recorded outputs (--from) are real data: the whole chart is reached,
    -- through the spawned task too.
    local seeded = charts('clock_seeded')
    result = machine.paths(seeded, { outputs = {
      now = { { text = '12:00', zone = 'utc' } }, whoami = { { name = 'Ada' } } } })
    for _, issue in ipairs(result.issues) do assert(issue.kind ~= 'error', issue.message) end
    assert(result.states.reached == result.states.total, machine._paths_summary(result))
    local report = machine.replay(machine.paths_log(seeded, result), { charts = { clock_seeded = seeded } })
    assert(report.ok, machine.replay_text(report))
  end,

  -- A chart that is normally a child (documents' `document`) generated on
  -- its own: send_parent used to raise "has no parent". The generated root
  -- now has a stand-in parent that takes the event, and generation reports
  -- what it received as an observation. From the parent's generation, the
  -- spawned child's states and transitions are targets too.
  ['generation: a child chart gets a stand-in parent, and the parent generation covers it'] = function()
    local item = machine.create {
      id = 'gen_item', initial = 'viewing',
      context = function(input) return { label = input and input.label or '' } end,
      states = {
        viewing = { on = { EDIT = 'editing', CLOSE = { actions = machine.send_parent { type = 'ITEM_CLOSED' } } } },
        editing = { on = { SAVE = 'saved', CANCEL = { target = 'viewing', actions = machine.send_parent('EDIT_CANCELED') } } },
        saved = { type = 'final' },
      },
    }
    local list = machine.create {
      id = 'gen_list', initial = 'idle', context = { closed = 0 },
      states = { idle = { on = {
        ADD = { actions = machine.spawn(item, { id = 'item', input = function() return { label = 'one' } end }) },
        ITEM_CLOSED = { actions = machine.assign { closed = function(c) return c.closed + 1 end } },
        EDIT_CANCELED = {},
      } } },
    }
    local result = machine.paths(item)
    local observed = {}
    for _, issue in ipairs(result.issues) do
      assert(issue.kind ~= 'error', 'no false errors: ' .. issue.message)
      if issue.kind == 'observed' then observed[#observed + 1] = issue.message end
    end
    table.sort(observed)
    assert(table.concat(observed, '|') == 'gen_item sent EDIT_CANCELED to its parent|gen_item sent ITEM_CLOSED to its parent',
      table.concat(observed, '|'))
    assert(result.states.reached == result.states.total)
    local summary = machine._paths_summary(result)
    assert(summary:find('observed (stand-in parent)', 1, true), summary)
    -- The generated log replays with the same stand-in.
    local report = machine.replay(machine.paths_log(item, result), { charts = { gen_item = item } })
    assert(report.ok, machine.replay_text(report))
    -- From the parent: the child is spawned, explored and counted.
    result = machine.paths(list)
    local child = result.children and result.children.gen_item
    assert(child, 'the parent reports its children\'s coverage')
    assert(child.states.reached == child.states.total and child.transitions.reached == child.transitions.total,
      machine._paths_summary(result))
    assert(result.states.total == 1, 'the parent\'s own counts are unchanged')
    report = machine.replay(machine.paths_log(list, result), { charts = { gen_list = list, gen_item = item } })
    assert(report.ok, machine.replay_text(report))
    -- A real recording still raises: no stand-in outside generated logs.
    local lines = record(function()
      local a = item:start { id = 'gen_item', input = { label = 'x' } }
      local ok = pcall(a.send, a, 'CLOSE')
      assert(not ok, 'a root without a parent still raises live')
      a:stop()
    end)
    report = machine.replay(lines, { charts = { gen_item = item } })
    assert(report.ok, machine.replay_text(report))
  end,

  ['machine.advance needs a virtual clock'] = function()
    fails(function() machine.advance(-1) end, 'nonnegative integer')
  end,
}
