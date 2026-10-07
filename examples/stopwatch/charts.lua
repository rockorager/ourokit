-- The stopwatch's behavior: one chart with a parallel root, because the clock
-- and the settings dialog change independently. view.lua renders it and
-- tests/stopwatch_test.lua drives it headless.
local ouro = require('ouro')
local machine = ouro.machine
local assign = machine.assign

-- `after` delays are constants, and apps have no millisecond clock, so the
-- stopwatch counts ticks. Each tick re-arms the timer, so `elapsed` falls
-- behind wall time by the timer latency, at most a few milliseconds per tick.
local TICK = 100

-- The newest `max` laps of a list, oldest first.
local function newest(laps, max)
  local out = {}
  for i = math.max(1, #laps - max + 1), #laps do out[#out + 1] = laps[i] end
  return out
end

local function lapped(c)
  local laps = {}
  for i, lap in ipairs(c.laps) do laps[i] = lap end
  local previous = #laps > 0 and laps[#laps].total or 0
  laps[#laps + 1] = { total = c.elapsed, split = c.elapsed - previous }
  return newest(laps, c.max_laps)
end

local stopwatch = machine.create {
  id = 'stopwatch', type = 'parallel', order = { 'clock', 'settings' },
  context = {
    elapsed = 0, laps = {}, max_laps = 5, show_tenths = true,
    draft_max_laps = 5, draft_show_tenths = true,
  },
  guards = {
    has_time = function(c) return c.elapsed > 0 end,
  },
  actions = {
    tick = assign { elapsed = function(c) return c.elapsed + TICK end },
    lap = assign { laps = lapped },
    clear = assign { elapsed = 0, laps = {} },
    edit = assign(function(c) return { draft_max_laps = c.max_laps, draft_show_tenths = c.show_tenths } end),
    apply = assign(function(c)
      return { max_laps = c.draft_max_laps, show_tenths = c.draft_show_tenths, laps = newest(c.laps, c.draft_max_laps) }
    end),
  },
  states = {
    clock = { initial = 'idle', states = {
      idle = { on = { START = 'running' } },
      -- Targeting its own state re-enters `running`, which restarts the timer.
      running = {
        after = { [TICK] = { target = 'running', actions = 'tick' } },
        on = { STOP = 'paused', LAP = { actions = 'lap' } },
      },
      paused = { on = {
        START = 'running',
        RESET = { target = 'idle', guard = 'has_time', actions = 'clear' },
      } },
    } },
    -- The dialog edits drafts; Save copies them over, Cancel drops them.
    settings = { initial = 'closed', states = {
      closed = { on = { OPEN_SETTINGS = { target = 'open', actions = 'edit' } } },
      open = { on = {
        MAX_LAPS = machine.set('draft_max_laps', 'integer'),
        TENTHS = machine.set('draft_show_tenths', 'boolean'),
        SAVE_SETTINGS = { target = 'closed', actions = 'apply' },
        CANCEL = 'closed',
      } },
    } },
  },
}

return { stopwatch = stopwatch, TICK = TICK }
