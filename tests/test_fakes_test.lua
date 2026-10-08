-- manual_scheduler controls for test fakes (design/statecharts.md §0 Tests):
-- settle a pending invoke or task without running its source, make an
-- invoke send events, and let a running fake wait on the virtual clock. The
-- test sandbox has no setmetatable or coroutines, so tests used to wrap the
-- scheduler to keep long invokes pending.
local o = require('ouro')
local machine = o.machine

local function fails(fn, pattern)
  local ok, err = pcall(fn)
  assert(not ok, 'expected failure: ' .. pattern)
  assert(tostring(err):find(pattern, 1, true), tostring(err))
end

-- A lock screen: a long PAM conversation, a status task, progress events.
local function session()
  local ran = 0
  local chart = machine.create {
    id = 'session', initial = 'locked', context = { progress = 0, status = '' },
    events = { PROGRESS = { value = 'integer' } },
    actors = {
      pam = function() ran = ran + 1; error('the real PAM conversation must not run in a test') end,
      status = function() ran = ran + 1; return 'real' end,
    },
    states = {
      locked = {
        entry = machine.spawn('status', { id = 'status' }),
        invoke = { id = 'pam', src = 'pam',
          on_done = { target = 'unlocked', actions = machine.assign { user = function(_, e) return e.output.user end } },
          on_error = { target = 'failed', actions = machine.assign { error = function(_, e) return e.error end } } },
        on = {
          PROGRESS = { actions = machine.assign { progress = function(_, e) return e.value end } },
          ['done.actor.*'] = { actions = machine.assign { status = function(_, e) return e.output end } },
        },
      },
      unlocked = {}, failed = {},
    },
  }
  return chart, function() return ran end
end

return {
  ['pending invokes and tasks settle without running their sources'] = function()
    local chart, ran = session()
    local clock = machine.manual_scheduler()
    local actor = chart:start { id = 'session', scheduler = clock }
    local pending = clock.pending_invokes()
    assert(#pending == 2, #pending)
    assert(pending[1].id == 'status' and pending[1].kind == 'task' and not pending[1].started)
    assert(pending[2].id == 'pam' and pending[2].kind == 'invoke' and pending[2].actor == 'session'
      and pending[2].state == 'locked' and not pending[2].started)
    clock.emit('pam', { type = 'PROGRESS', value = 40 })
    assert(actor:context().progress == 40, 'emit is the invoke sending to its chart')
    clock.resolve('status', 'fake status')
    assert(actor:context().status == 'fake status')
    clock.resolve('pam', { user = 'ada' })
    assert(actor:matches('unlocked') and actor:context().user == 'ada')
    assert(#clock.pending_invokes() == 0 and clock.run_tasks() == 0 and ran() == 0, 'sources never ran')
    fails(function() clock.resolve('pam', {}) end, 'no pending invoke or task "pam"')
    actor:stop()
  end,

  ['reject delivers the error, and leaving the state drops the pending invoke'] = function()
    local chart = session()
    local clock = machine.manual_scheduler()
    local actor = chart:start { id = 'session', scheduler = clock }
    clock.reject('session:pam', { name = 'AuthFailed' })
    assert(actor:matches('failed') and actor:context().error.name == 'AuthFailed')
    -- The status task belonged to `locked`, which exited.
    assert(#clock.pending_invokes() == 0)
    actor:stop()
  end,

  ['a running fake waits on the virtual clock with sleep'] = function()
    local clock = machine.manual_scheduler()
    local chart = machine.create {
      id = 'poll', initial = 'waiting', context = {},
      actors = { slow = function(input)
        clock.sleep(nil, 250)
        return input.answer
      end },
      states = {
        waiting = { invoke = { src = 'slow', input = function() return { answer = 42 } end,
          on_done = { target = 'done', actions = machine.assign { answer = function(_, e) return e.output end } } } },
        done = {},
      },
    }
    local actor = chart:start { scheduler = clock }
    assert(clock.run_tasks() == 1)
    assert(actor:matches('waiting') and clock.pending_invokes()[1].started, 'the fake is parked in sleep')
    clock.advance(249)
    assert(actor:matches('waiting'))
    clock.advance(1)
    assert(actor:matches('done') and actor:context().answer == 42)
    fails(function() clock.sleep(nil, 10) end, 'sleep needs an invoke or task that the manual scheduler runs')
    actor:stop()
  end,

  ['machine.sleep in a running invoke finishes only after clock.advance'] = function()
    local clock = machine.manual_scheduler()
    local chart = machine.create {
      id = 'backoff', initial = 'waiting', context = { tries = 0 },
      actors = { retry = function()
        machine.sleep(1000)
        machine.sleep(500)
        return 'connected'
      end },
      states = {
        waiting = { invoke = { src = 'retry',
          on_done = { target = 'online', actions = machine.assign { result = function(_, e) return e.output end } } } },
        online = {},
      },
    }
    local actor = chart:start { scheduler = clock }
    clock.run_tasks()
    assert(actor:matches('waiting'))
    clock.advance(1000)
    assert(actor:matches('waiting'), 'the second sleep is still pending')
    clock.advance(499)
    assert(actor:matches('waiting'))
    clock.advance(1)
    assert(actor:matches('online') and actor:context().result == 'connected' and clock.now == 1500)
    assert(machine._task_sleep == nil, 'the hook is set only while an item runs')
    actor:stop()
  end,

  ['send reaches a running invoke through its receive mailbox'] = function()
    local clock = machine.manual_scheduler()
    local heard = {}
    local chart = machine.create {
      id = 'pam2', initial = 'asking', context = {},
      actors = { converse = function(_, send, receive)
        receive(function(event) heard[#heard + 1] = event.answer; send { type = 'GOT', answer = event.answer } end)
        machine.sleep(60000) -- a long conversation
      end },
      events = { GOT = { answer = 'string' } },
      states = { asking = { invoke = { id = 'converse', src = 'converse' },
        on = { GOT = { actions = machine.assign { answer = function(_, e) return e.answer end } } } } },
    }
    local actor = chart:start { scheduler = clock }
    clock.run_tasks() -- the source runs and registers its handler
    assert(clock.send('converse', { type = 'ANSWER', answer = 'secret' }))
    clock.run_tasks() -- the invoke's mailbox drains
    assert(heard[1] == 'secret' and actor:context().answer == 'secret', tostring(heard[1]))
    actor:stop()
    assert(clock.pending_invokes()[1] == nil)
  end,
}
