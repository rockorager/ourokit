-- A component machine with invoke work opens its scopes under the widget
-- instance's task scope. Unmounting the instance must retire them so the
-- instance can be collected. Teardown used to abort: the instance tree still had
-- an occupied slot, waiting for scopes nothing would ever free.
local o = require('ouro')
local machine = o.machine

return {
  ['component invoke scopes are retired when their instance unmounts'] = function(t)
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
}
