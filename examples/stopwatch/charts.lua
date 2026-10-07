-- The stopwatch's behavior: one chart with a parallel root, because the clock
-- and the settings dialog change independently. view.lua renders it and
-- tests/stopwatch_test.lua drives it headless.
local ouro = require('ouro')
local machine = ouro.machine
local assign = machine.assign

-- Time comes from the scheduler clock (design §8): machine.now() in actions
-- and guards, and the fire time `e.time_ms` on timer events. Logical timers
-- fire at their deadlines, and re-entering `running` at a deadline arms the
-- next one exactly TICK later, so ticks never drift. `elapsed` is computed
-- from the run's start, not counted. Under manual_scheduler and replay the
-- clock is virtual, so tests and recordings stay deterministic.
local TICK = 100

-- Time banked before this run plus the time since it started.
local function since_start(c, now) return c.banked + (now - c.started_at) end

-- The newest `max` laps of a list, oldest first.
local function newest(laps, max)
  local out = {}
  for i = math.max(1, #laps - max + 1), #laps do out[#out + 1] = laps[i] end
  return out
end

local function lapped(c, elapsed)
  local laps = {}
  for i, lap in ipairs(c.laps) do laps[i] = lap end
  local previous = #laps > 0 and laps[#laps].total or 0
  laps[#laps + 1] = { total = elapsed, split = elapsed - previous }
  return newest(laps, c.max_laps)
end

local stopwatch = machine.create {
  id = 'stopwatch', type = 'parallel', order = { 'clock', 'settings' },
  context = {
    elapsed = 0, banked = 0, started_at = 0, laps = {}, max_laps = 5, show_tenths = true,
    draft_max_laps = 5, draft_show_tenths = true,
  },
  guards = {
    has_time = function(c) return c.elapsed > 0 end,
  },
  actions = {
    start = assign { started_at = function() return machine.now() end },
    tick = assign { elapsed = function(c, e) return since_start(c, e.time_ms) end },
    stop = assign(function(c)
      local elapsed = since_start(c, machine.now())
      return { elapsed = elapsed, banked = elapsed }
    end),
    lap = assign(function(c)
      local elapsed = since_start(c, machine.now())
      return { elapsed = elapsed, laps = lapped(c, elapsed) }
    end),
    clear = assign { elapsed = 0, banked = 0, laps = {} },
    edit = assign(function(c) return { draft_max_laps = c.max_laps, draft_show_tenths = c.show_tenths } end),
    apply = assign(function(c)
      return { max_laps = c.draft_max_laps, show_tenths = c.draft_show_tenths, laps = newest(c.laps, c.draft_max_laps) }
    end),
  },
  states = {
    clock = { initial = 'idle', states = {
      idle = { on = { START = { target = 'running', actions = 'start' } } },
      -- reenter = true exits and re-enters `running`, which restarts the timer
      -- at the fire time. A plain self-target would stay in the state and not
      -- restart it.
      running = {
        after = { [TICK] = { target = 'running', reenter = true, actions = 'tick' } },
        on = { STOP = { target = 'paused', actions = 'stop' }, LAP = { actions = 'lap' } },
      },
      paused = { on = {
        START = { target = 'running', actions = 'start' },
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
