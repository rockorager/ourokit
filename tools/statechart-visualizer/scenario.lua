-- Runs a fixture chart on ouro.machine's manual scheduler and records the
-- real inspection stream (time_ms is the virtual clock). Deterministic, so
-- it also feeds headless snapshots.
local o = require('ouro')
local machine = o.machine

local M = {}

-- Runs exactly one queued invoke or task on a manual scheduler, through its
-- run_tasks (queued items are records, not functions, since 653f6fc);
-- work that item queues stays queued for a later call.
function M.run_one(clock)
  local item = table.remove(clock.tasks, 1)
  if not item then return end
  if type(item) == 'function' then return item() end
  local rest, held, run = clock.tasks, {}, clock.run
  clock.tasks = {item}
  clock.run = function(...)
    run(...)
    held[#held + 1] = table.remove(clock.tasks)
  end
  local ok, err = pcall(clock.run_tasks)
  clock.run = run
  for _, queued in ipairs(held) do rest[#rest + 1] = queued end
  clock.tasks = rest
  if not ok then error(err, 0) end
end

function M.run(fixture)
  local clock = machine.manual_scheduler()
  local mode = {}
  local control = {
    -- Invoked work completes when the script runs it.
    choose = function() return '/home/user/notes.txt' end,
    write = function()
      if mode.fail then local message = mode.fail; mode.fail = nil; error(message, 0) end
      return true
    end,
  }
  local chart = fixture.chart(control)
  local actor = chart:actor {scheduler = clock}
  local records, lifecycle = {}, {}
  actor:observe(function(record)
    if record.kind == 'transition' then
      records[#records + 1] = record
    else
      lifecycle[#lifecycle + 1] = record
    end
  end)
  actor:start()
  local d = {}
  function d.advance(t) clock.advance(t - clock.now) end
  function d.at(t, type, fields)
    d.advance(t)
    local event = {type = type}
    for k, v in pairs(fields or {}) do event[k] = v end
    actor:send(event)
  end
  -- Completes exactly one piece of queued invoked work.
  function d.run(t)
    d.advance(t)
    M.run_one(clock)
  end
  function d.fail(message) mode.fail = message end
  function d.hang() end
  fixture.script(d)
  return {graph = chart:graph(), records = records, lifecycle = lifecycle, actor = actor}
end

-- Real-time driver for live demos: the default scheduler, invoked work that
-- takes wall-clock time, and the same script paced with ouro.sleep. Loops
-- forever (stop/restart a fresh actor each lap); call from a task. `clock`
-- is a coarse 50 ms counter task for stamping records in-process.
function M.live(fixture, options)
  options = options or {}
  local mode = {}
  local control = {
    choose = function() o.sleep(800); return '/home/user/notes.txt' end,
    write = function()
      local wait = mode.hang and 60000 or 650
      mode.hang = false
      o.sleep(wait)
      if mode.fail then local message = mode.fail; mode.fail = nil; error(message, 0) end
      return true
    end,
  }
  local chart = fixture.chart(control)
  while true do
    local actor = chart:actor {id = options.id}
    actor:start()
    local now = 0
    local d = {}
    function d.advance(t) if t > now then o.sleep(t - now); now = t end end
    function d.at(t, type, fields)
      d.advance(t)
      local event = {type = type}
      for k, v in pairs(fields or {}) do event[k] = v end
      actor:send(event)
    end
    d.run = d.advance
    function d.fail(message) mode.fail = message end
    function d.hang() mode.hang = true end
    fixture.script(d)
    o.sleep(options.rest or 4000)
    actor:stop()
    mode = {}
    o.sleep(600)
  end
end

return M
