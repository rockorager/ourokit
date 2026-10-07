-- Component machines live and die with their mounted instance.
local o = require('ouro')
local machine = o.machine

-- A component chart with a running timer and a parked invoke while 'running'.
-- Each timer tick re-enters 'running' and counts.
local ticker = machine.create {
  id = 'ticker', initial = 'idle', context = { starts = 0, ticks = 0 },
  events = { START = {} },
  states = {
    idle = { on = { START = { target = 'running', actions = machine.assign(function(c) return { starts = c.starts + 1 } end) } } },
    running = {
      after = { [1000] = { target = 'running', reenter = true, actions = machine.assign(function(c) return { ticks = c.ticks + 1 } end) } },
      invoke = { src = function() return 'parked until the clock runs tasks' end },
    },
  },
}

local function count(records, actor, kind, action)
  local n = 0
  for _, r in ipairs(records) do
    if r.actor == actor.path then
      for _, entry in ipairs(r[kind] or {}) do
        if entry.action == action then n = n + 1 end
      end
    end
  end
  return n
end

return {
  ['component invoke scopes are retired when their instance unmounts'] = function(t)
    -- Real native scopes. Teardown used to abort: the instance tree still had
    -- an occupied slot, waiting for scopes nothing would ever free.
    local loads = 0
    local chart = machine.create {
      id = 'loader', initial = 'idle',
      events = { LOAD = {} },
      states = {
        idle = { on = { LOAD = 'loading' } },
        -- The invoke finishes, but its state, and so its scope, stays active.
        loading = { invoke = { src = function() loads = loads + 1; return loads end } },
      },
    }
    local actor
    local Loader = machine.component(chart, function(self)
      actor = self
      return o.button { key = 'load', label = self:matches('loading') and 'Loading' or 'Load', on_press = self:sender('LOAD') }
    end)
    t:mount(function() return o.column { key = 'root', Loader { key = 'loader' } } end)
    t:click('root/loader/load')
    assert(actor:matches('loading') and t:node('root/loader/load').label == 'Loading')
    assert(loads == 1)
    -- Teardown now unmounts the instance with the actor's scopes still open.
  end,

  ['component machines stop on unmount and start fresh on remount'] = function(t)
    -- ouroctl test forbids wall-clock sleeps, so component actors created in
    -- this test use virtual time: the timer really fires on clock.advance, the
    -- invoke stays parked because the clock never runs tasks, and open_scopes
    -- counts every scope the actors hold. t:settle() lets the view catch up
    -- after the test body advances the clock.
    local clock = machine.manual_scheduler()
    local previous = machine.default_scheduler
    machine.default_scheduler = clock
    local records = {}
    local unsubscribe = machine.inspect(function(r) records[#records + 1] = r end)
    -- The page is app state; it decides whether the ticker is mounted.
    local page = machine.create {
      id = 'page', initial = 'shown', events = { HIDE = {}, SHOW = {} },
      states = { shown = { on = { HIDE = 'hidden' } }, hidden = { on = { SHOW = 'shown' } } },
    }:start()
    local latest
    local Ticker = machine.component(ticker, function(self)
      latest = self
      return o.button { key = 'start', label = self:matches('running') and 'Running' or 'Start', on_press = self:sender('START') }
    end)
    t:mount(function()
      return o.column { key = 'root',
        o.button { key = 'hide', label = 'Hide', on_press = page:sender('HIDE') },
        o.button { key = 'show', label = 'Show', on_press = page:sender('SHOW') },
        page:matches('shown') and Ticker { key = 'ticker' } or nil,
      }
    end)

    -- Mounted and running: the timer fires, the invoke is parked.
    t:click('root/ticker/start')
    local first = latest
    assert(first:matches('running') and first:status() == 'active', first:status())
    assert(t:node('root/ticker/start').label == 'Running')
    clock.advance(2500); t:settle()
    assert(first:context().ticks == 2, first:context().ticks)
    assert(clock.open_scopes > 0 and count(records, first, 'invokes', 'started') >= 1)

    -- Unmounting stops the actor explicitly: timer and invoke are cancelled,
    -- every scope it opened is closed, and time no longer reaches it.
    t:click('root/hide')
    assert(first:status() == 'stopped', first:status())
    assert(count(records, first, 'timers', 'cancelled') >= 1 and count(records, first, 'invokes', 'cancelled') >= 1)
    assert(clock.open_scopes == 0, clock.open_scopes)
    clock.advance(10000); t:settle()
    assert(first:context().ticks == 2)

    -- Remounting creates a fresh actor with initial state; it starts on its
    -- first event and runs its own timer.
    t:click('root/show')
    assert(latest ~= first and latest:status() ~= 'stopped')
    assert(latest:matches('idle') and latest:context().starts == 0 and latest:context().ticks == 0)
    assert(t:node('root/ticker/start').label == 'Start')
    t:click('root/ticker/start')
    clock.advance(1000); t:settle()
    assert(latest:matches('running') and latest:context().starts == 1 and latest:context().ticks == 1)
    assert(first:status() == 'stopped' and first:context().ticks == 2)

    t:click('root/hide')
    assert(latest:status() == 'stopped' and clock.open_scopes == 0)
    unsubscribe()
    page:stop()
    machine.default_scheduler = previous
  end,

  ['t:settle shows state changed from the test body'] = function(t)
    local clock = machine.manual_scheduler()
    local light = machine.create {
      id = 'light', initial = 'red', events = { GO = {} },
      states = { red = { on = { GO = 'green' } }, green = { after = { [500] = 'red' } } },
    }:start { scheduler = clock }
    t:mount(function() return o.text { key = 'state', text = light:matches('green') and 'green' or 'red' } end)
    assert(t:node('state').label == 'red')
    light:send('GO')
    t:settle()
    assert(t:node('state').label == 'green')
    clock.advance(500)
    t:settle()
    assert(t:node('state').label == 'red')
    light:stop()
  end,

  -- Capacity cases from the statecharts review. Each actor holds several
  -- hidden signals; these used to exhaust a fixed signal capacity of 256.
  -- 300 rows also pass the old per-window budget of 256 nodes: build storage,
  -- instances, render objects, semantics and bindings grow while preparing.
  ['capacity: a list of 300 component machines mounts'] = function(t)
    local Row = machine.component(machine.create {
      id = 'row', initial = 'closed', context = function(p) return { title = p.title } end,
      states = { closed = { on = { TOGGLE = 'open' } }, open = { on = { TOGGLE = 'closed' } } },
    }, function(self)
      return o.button { key = 'b', label = self:context().title, send = self:event('TOGGLE') }
    end)
    t:mount(function()
      local rows = {}
      for i = 1, 300 do rows[i] = Row { key = 'r' .. i, title = 'Row ' .. i } end
      return o.scroll { key = 's', o.column { key = 'c', children = rows } }
    end, { width = 300, height = 300 })
    assert(t:node('s/c/r300/b').label == 'Row 300')
    assert(t:resources().instances > 300)
  end,

  ['capacity: 40 component machine rows remount repeatedly'] = function(t)
    local Row = machine.component(machine.create {
      id = 'row', initial = 'closed', context = function(p) return { title = p.title } end,
      states = { closed = { on = { TOGGLE = 'open' } }, open = { on = { TOGGLE = 'closed' } } },
    }, function(self)
      return o.text { key = 't', text = self:context().title }
    end)
    local page = machine.create {
      id = 'page', initial = 'shown', events = { TOGGLE = {} },
      states = { shown = { on = { TOGGLE = 'hidden' } }, hidden = { on = { TOGGLE = 'shown' } } },
    }:start { scheduler = machine.manual_scheduler() }
    t:mount(function()
      local rows = {}
      if page:matches('shown') then
        for i = 1, 40 do rows[i] = Row { key = 'r' .. i, title = 'Row ' .. i } end
      end
      return o.column { key = 'root',
        o.button { key = 'toggle', label = 'Toggle', send = page:event('TOGGLE') },
        o.column { key = 'c', children = rows },
      }
    end, { width = 300, height = 1600 })
    for _ = 1, 20 do
      t:click('root/toggle')
      t:click('root/toggle')
    end
    assert(t:node('root/c/r40/t').label == 'Row 40')
    page:stop()
  end,

  ['capacity: 3000 actors created and stopped'] = function()
    local chart = machine.create { id = 'tiny', initial = 'idle', states = { idle = { on = { X = 'idle' } } } }
    for i = 1, 3000 do
      local ok, err = pcall(function() local a = chart:start { scheduler = machine.manual_scheduler() }; a:stop() end)
      assert(ok, 'cycle ' .. i .. ': ' .. tostring(err))
    end
  end,
}
