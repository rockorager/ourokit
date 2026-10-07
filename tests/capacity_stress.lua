-- Large workloads must not hit fixed capacities, and everything they create
-- must be freed again: unmounted component machines and stopped actors return
-- native objects and the Lua heap to their baseline. Run by
-- zig build test-stress with a long timeout: Debug builds take about a minute.
local o = require('ouro')
local machine = o.machine

-- t:resources() runs a full collection before measuring the Lua heap.
local function settled_baseline(t)
  return t:resources()
end

local function assert_baseline(before, after, label)
  for _, field in ipairs { 'instances', 'render_objects', 'scopes', 'signals', 'callbacks' } do
    assert(after[field] == before[field],
      ('%s: %s %d, baseline %d'):format(label, field, after[field], before[field]))
  end
  -- Some Lua growth is legitimate (interned strings, table capacity), but it
  -- must not scale with the work done.
  assert(after.lua_kb <= before.lua_kb * 1.25 + 512,
    ('%s: lua heap %d KiB, baseline %d KiB'):format(label, after.lua_kb, before.lua_kb))
end

return {
  ['1000 component rows mount and remount 50 times'] = function(t)
    -- Each row holds an instance scope, its actor's hidden signals and a
    -- button callback; unmounting must release all of them. (Row actors start
    -- lazily, so their timers are covered by the 10000-actor case.)
    -- `mounted` keeps the latest actor of each row reachable, so the garbage
    -- collector cannot be what frees their signals.
    local mounted = {}
    local Row = machine.component(machine.create {
      id = 'row', initial = 'closed', context = function(p) return { title = p.title } end,
      events = { TOGGLE = {} },
      states = {
        closed = { on = { TOGGLE = 'open' }, after = { [60000] = 'open' } },
        open = { on = { TOGGLE = 'closed' } },
      },
    }, function(self, props)
      mounted[props.title] = self
      return o.button { key = 'b', label = self:context().title, send = self:event('TOGGLE') }
    end)
    local page = machine.create {
      id = 'page', initial = 'hidden', events = { TOGGLE = {} },
      states = { shown = { on = { TOGGLE = 'hidden' } }, hidden = { on = { TOGGLE = 'shown' } } },
    }:start()
    t:mount(function()
      local rows = { o.button { key = 'toggle', label = 'Toggle', send = page:event('TOGGLE') } }
      if page:matches('shown') then
        for i = 1, 1000 do rows[i + 1] = Row { key = 'r' .. i, title = 'Row ' .. i } end
      end
      return o.scroll { key = 's', o.column { key = 'c', children = rows } }
    end, { width = 300, height = 600 })

    -- Warm up once so caches and buffers reach their working size.
    t:click('s/c/toggle')
    t:click('s/c/toggle')
    local baseline = settled_baseline(t)
    for cycle = 1, 50 do
      t:click('s/c/toggle')
      if cycle == 1 then
        local shown = t:resources()
        assert(shown.instances >= baseline.instances + 1000, shown.instances)
        assert(shown.signals >= baseline.signals + 3000, shown.signals)
        assert(shown.scopes >= baseline.scopes + 1000, shown.scopes)
        assert(t:node('s/c/r1000/b').label == 'Row 1000')
      end
      t:click('s/c/toggle')
    end
    assert(mounted['Row 1000']:status() == 'stopped')
    local kept = t:resources()
    assert(kept.signals == baseline.signals and kept.scopes == baseline.scopes,
      ('unmount left %d signals and %d scopes'):format(kept.signals - baseline.signals, kept.scopes - baseline.scopes))
    mounted = {}
    assert_baseline(baseline, settled_baseline(t), 'after 50 remounts')
    page:stop()
  end,

  ['10000 actors created and stopped'] = function(t)
    -- The native scheduler: each actor opens a real scope and a logical
    -- timer, and stop() must cancel and free both.
    local chart = machine.create {
      id = 'tiny', initial = 'idle', context = { n = 0 }, events = { X = {} },
      states = { idle = { on = { X = 'busy' } }, busy = { after = { [1000] = 'idle' } } },
    }
    local warm = chart:start()
    warm:send('X')
    warm:stop()
    local baseline = settled_baseline(t)
    -- Stopped actors stay reachable, so only stop() can have freed their
    -- signals, scopes and timers.
    local stopped = {}
    for i = 1, 10000 do
      local actor = chart:start()
      actor:send('X')
      assert(actor:matches('busy') and actor:context().n == 0, 'cycle ' .. i)
      actor:stop()
      stopped[i] = actor
    end
    local kept = t:resources()
    assert(kept.signals == baseline.signals and kept.scopes == baseline.scopes,
      ('stop left %d signals and %d scopes'):format(kept.signals - baseline.signals, kept.scopes - baseline.scopes))
    stopped = nil
    assert_baseline(baseline, settled_baseline(t), 'after 10000 actors')
  end,
}
