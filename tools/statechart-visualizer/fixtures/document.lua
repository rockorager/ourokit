-- The `document` chart from design/statecharts.md §12, standalone (no parent
-- notes actor), plus a write timeout so the plant has a timer gauge.
-- `script(drive)` is a deterministic scenario: send events, run invoked work,
-- advance virtual time. `drive` supplies send/run/advance/fail.
local o = require('ouro')
local machine = o.machine
local assign = machine.assign

local function chart(control)
  return machine.create {
    id = 'document', initial = 'open',
    context = {title = 'notes.txt', text = '', path = false, revision = 0, saved_revision = 0,
      save_revision = 0, error = false},
    events = {EDIT = {field = 'string', value = 'string'}, SAVE = {}, CLOSE = {}, CANCEL = {}, DISCARD = {}},
    guards = {
      has_path = function(c) return c.path ~= false end,
      unsafe = function(c, _, s) return c.revision ~= c.saved_revision or s.matches('open.io.saving') end,
      idle = function(_, _, s) return s.matches('open.io.idle') end,
      saved_clean = function(c, _, s) return s.matches('open.io.idle') and c.revision == c.saved_revision end,
      save_finished = function(_, _, s) return s.matches('open.io.idle') end,
    },
    actions = {
      edit = assign {text = function(_, e) return e.value end, revision = function(c) return c.revision + 1 end},
      snapshot_save = assign {save_revision = function(c) return c.revision end},
      set_target = assign {path = function(_, e) return e.output end},
      saved = assign {saved_revision = function(c) return c.save_revision end, error = false},
      report = assign {error = function(_, e) return tostring(e.error) end},
      report_timeout = assign {error = 'write timed out'},
    },
    actors = {
      choose = function() return control.choose() end,
      write = function(input) return control.write(input) end,
    },
    states = {
      open = {type = 'parallel', on = {EDIT = {actions = 'edit'}}, states = {
        io = {initial = 'idle', states = {
          idle = {on = {SAVE = 'saving'}},
          saving = {initial = 'choosing', entry = 'snapshot_save', states = {
            choosing = {always = {target = 'writing', guard = 'has_path'},
              invoke = {src = 'choose', on_done = {target = 'writing', actions = 'set_target'},
                on_error = {target = '#open.io.idle', actions = 'report'}}},
            writing = {
              invoke = {src = 'write', input = function(c) return {path = c.path, revision = c.revision} end,
                on_done = {target = '#open.io.idle', actions = 'saved'},
                on_error = {target = '#open.io.idle', actions = 'report'}},
              after = {[5000] = {target = '#open.io.idle', actions = 'report_timeout'}}},
          }},
        }},
        lifecycle = {initial = 'active', states = {
          active = {on = {CLOSE = {{target = 'confirming', guard = 'unsafe'}, {target = '#closed'}}}},
          confirming = {initial = 'prompt', on = {CANCEL = 'active'}, states = {
            prompt = {on = {SAVE = 'awaiting', DISCARD = {target = '#closed', guard = 'idle'}}},
            awaiting = {always = {{target = '#closed', guard = 'saved_clean'}, {target = 'prompt', guard = 'save_finished'}}},
          }},
        }},
      }},
      closed = {type = 'final'},
    },
  }
end

local function script(d)
  d.at(800, 'EDIT', {field = 'text', value = 'Hello'})
  d.at(1500, 'SAVE')                 -- choosing: invoke the file chooser
  d.run(2300)                        -- chooser returns a path → writing
  d.run(2900)                        -- write succeeds → idle, clean
  d.at(3400, 'DISCARD')              -- rejected: nothing handles it now
  d.at(4000, 'EDIT', {field = 'text', value = 'Hello, plant'})
  d.at(4600, 'SAVE')                 -- has a path: always → writing in one macrostep
  d.fail('ENOSPC: no space left on device')
  d.run(5400)                        -- write throws → idle with error
  d.at(6000, 'CLOSE')                -- unsafe → confirming.prompt
  d.at(7000, 'SAVE')                 -- both regions take SAVE
  d.hang()
  d.advance(12000)                   -- write never returns: 5 s timeout fires
  d.at(12600, 'DISCARD')             -- guarded by idle → closed (final)
  d.at(13400, 'SAVE')                -- rejected: the machine is done
end

return {chart = chart, script = script}
