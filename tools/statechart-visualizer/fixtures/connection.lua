-- A reconnecting client: invoked socket with a connect timeout, guarded
-- retry backoff and a nested online vessel with a sync pump.
local o = require('ouro')
local machine = o.machine
local assign = machine.assign

local function chart(control)
  return machine.create {
    id = 'connection', initial = 'offline',
    context = {peer = 'sync.example:443', retries = 0, last_error = false, synced = 0},
    events = {CONNECT = {}, DISCONNECT = {}, SYNC = {}, DROP = {}},
    guards = {retries_left = function(c) return c.retries < 5 end},
    actions = {
      failed = assign {retries = function(c) return c.retries + 1 end, last_error = function(_, e) return tostring(e.error or 'timeout') end},
      reset = assign {retries = 0, last_error = false},
      synced = assign {synced = function(c, e) return c.synced + (e.output or 0) end},
    },
    actors = {
      connect = function() return control.write() end,
      pull = function() return 42 end,
    },
    states = {
      offline = {on = {CONNECT = 'connecting'}},
      connecting = {
        invoke = {id = 'socket', src = 'connect', on_done = {target = 'online', actions = 'reset'},
          on_error = {target = 'backoff', actions = 'failed'}},
        after = {[4000] = {target = 'backoff', actions = 'failed'}}},
      online = {initial = 'idle', on = {DROP = 'backoff', DISCONNECT = 'offline'}, states = {
        idle = {on = {SYNC = 'syncing'}},
        syncing = {invoke = {id = 'sync', src = 'pull', on_done = {target = 'idle', actions = 'synced'}}},
      }},
      backoff = {after = {[2000] = {target = 'connecting', guard = 'retries_left'}}, on = {DISCONNECT = 'offline'}},
    },
  }
end

local function script(d)
  d.at(600, 'CONNECT')
  d.fail('ECONNREFUSED')
  d.run(1400)                -- connect fails → backoff
  d.advance(3400)            -- backoff timer → connecting again
  d.run(4100)                -- connected → online.idle
  d.at(5000, 'SYNC')
  d.at(5300, 'SYNC')         -- rejected: already syncing
  d.run(6200)                -- pull done → idle
  d.at(8000, 'DROP')         -- → backoff, retry timer armed
end

return {chart = chart, script = script}
