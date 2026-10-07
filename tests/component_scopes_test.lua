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
      after = { [1000] = { target = 'running', actions = machine.assign(function(c) return { ticks = c.ticks + 1 } end) } },
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
    -- counts every scope the actors hold. Time advances from a button so the
    -- runner settles the UI afterwards, as after any input.
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
        o.button { key = 'second', label = 'Advance', on_press = function() clock.advance(1000) end },
        page:matches('shown') and Ticker { key = 'ticker' } or nil,
      }
    end)

    -- Mounted and running: the timer fires, the invoke is parked.
    t:click('root/ticker/start')
    local first = latest
    assert(first:matches('running') and first:status() == 'active', first:status())
    assert(t:node('root/ticker/start').label == 'Running')
    t:click('root/second'); t:click('root/second')
    assert(first:context().ticks == 2, first:context().ticks)
    assert(clock.open_scopes > 0 and count(records, first, 'invokes', 'started') >= 1)

    -- Unmounting stops the actor explicitly: timer and invoke are cancelled,
    -- every scope it opened is closed, and time no longer reaches it.
    t:click('root/hide')
    assert(first:status() == 'stopped', first:status())
    assert(count(records, first, 'timers', 'cancelled') >= 1 and count(records, first, 'invokes', 'cancelled') >= 1)
    assert(clock.open_scopes == 0, clock.open_scopes)
    for _ = 1, 5 do t:click('root/second') end
    assert(first:context().ticks == 2)

    -- Remounting creates a fresh actor with initial state; it starts on its
    -- first event and runs its own timer.
    t:click('root/show')
    assert(latest ~= first and latest:status() ~= 'stopped')
    assert(latest:matches('idle') and latest:context().starts == 0 and latest:context().ticks == 0)
    assert(t:node('root/ticker/start').label == 'Start')
    t:click('root/ticker/start')
    t:click('root/second')
    assert(latest:matches('running') and latest:context().starts == 1 and latest:context().ticks == 1)
    assert(first:status() == 'stopped' and first:context().ticks == 2)

    t:click('root/hide')
    assert(latest:status() == 'stopped' and clock.open_scopes == 0)
    unsubscribe()
    page:stop()
    machine.default_scheduler = previous
  end,
}
