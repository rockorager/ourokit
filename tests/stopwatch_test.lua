-- examples/stopwatch: the chart on a manual clock, then the view driven
-- through the retained input path. The example was first written from
-- design/statecharts.md alone, so this is also the doc's test case.
local o = require('ouro')
local machine = o.machine
local charts = require('examples.stopwatch.charts')
local view = require('examples.stopwatch.view')

local function start()
  local clock = machine.manual_scheduler()
  return charts.stopwatch:start { scheduler = clock }, clock
end

local function totals(sw)
  local out = {}
  for i, lap in ipairs(sw:context().laps) do out[i] = lap.total end
  return table.concat(out, ',')
end

return {
  ['the clock counts ticks, pauses and resets'] = function()
    local sw, clock = start()
    assert(sw:matches('clock.idle') and sw:matches('settings.closed'), 'a parallel root enters both regions')
    assert(not sw:can('RESET') and not sw:can('LAP'))
    sw:send('START')
    clock.advance(350)
    assert(sw:context().elapsed == 300, sw:context().elapsed)
    sw:send('STOP')
    clock.advance(1000)
    assert(sw:matches('clock.paused') and sw:context().elapsed == 300, 'the tick timer ends with running')
    sw:send('START'); clock.advance(100); sw:send('STOP')
    assert(sw:context().elapsed == 400)
    assert(sw:send('RESET') and sw:matches('clock.idle') and sw:context().elapsed == 0)
    sw:send('START'); sw:send('STOP')
    assert(not sw:can('RESET'), 'nothing to reset before the first tick')
  end,

  ['laps record splits and keep the newest max_laps'] = function()
    local sw, clock = start()
    sw:send('START')
    for _ = 1, 7 do clock.advance(200); sw:send('LAP') end
    assert(totals(sw) == '600,800,1000,1200,1400', totals(sw))
    assert(sw:context().laps[5].split == 200)
  end,

  ['settings edit drafts; cancel drops them and save applies them'] = function(t)
    local sw, clock = start()
    sw:send('START')
    for _ = 1, 4 do clock.advance(100); sw:send('LAP') end
    t:mount(view.content(sw), { width = 420, height = 460 })
    t:click('root/page/controls/settings')
    assert(sw:matches('settings.open'))
    t:click('root/settings/body/laps/spinbox/control/decrease')
    assert(sw:context().draft_max_laps == 4 and math.type(sw:context().draft_max_laps) == 'integer',
      'an integer spinbox sends integers')
    t:click('root/settings/body/tenths/switch')
    assert(sw:context().draft_show_tenths == false)
    t:key('escape')
    assert(sw:matches('settings.closed') and sw:context().max_laps == 5 and sw:context().show_tenths)
    t:click('root/page/controls/settings')
    assert(sw:context().draft_max_laps == 5, 'opening copies the saved settings')
    t:click('root/settings/body/laps/spinbox/control/decrease')
    t:click('root/settings/body/laps/spinbox/control/decrease')
    t:click('root/settings/body/tenths/switch')
    t:click('root/settings/body/actions/save')
    local c = sw:context()
    assert(c.max_laps == 3 and not c.show_tenths and totals(sw) == '200,300,400', totals(sw))
  end,

  ['buttons follow the chart and the time follows the context'] = function(t)
    local sw, clock = start()
    t:mount(view.content(sw), { width = 420, height = 460 })
    assert(t:node('root/page/time').label == '0:00.0')
    assert(not t:node('root/page/controls/lap').enabled and not t:node('root/page/controls/reset').enabled)
    t:click('root/page/controls/toggle')
    assert(t:node('root/page/controls/toggle').label == 'Stop' and t:node('root/page/controls/lap').enabled)
    clock.advance(1300)
    t:click('root/page/controls/lap')
    assert(t:node('root/page/time').label == '0:01.3' and t:node('root/page/laps/lap-1').label == 'Lap 1  0:01.3  (+0:01.3)')
    t:click('root/page/controls/toggle')
    assert(t:node('root/page/controls/reset').enabled and not t:node('root/page/controls/lap').enabled)
    t:click('root/page/controls/reset')
    assert(t:node('root/page/time').label == '0:00.0' and sw:matches('clock.idle'))
    assert(view.format(61234, true) == '1:01.2' and view.format(61234, false) == '1:01')
  end,
}
