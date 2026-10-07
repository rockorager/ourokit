#!/usr/bin/env python3
"""Statechart timers and invokes on the real scheduler (no compositor needed).

`ouroctl test` forbids wall-clock sleeps, so machine_test.lua uses a manual
scheduler. This runs the default scheduler on native task scopes: each state
entry opens a scope, exiting closes it, and closing cancels sleeping timers and
in-flight invokes (their code after the sleep never runs). The token scheduler
fallback is checked too: it only drops stale deliveries.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OUROKIT_TEST_BINARY", ROOT / "zig-out/bin/ouroctl"))

source = r'''
local o = require('ouro')
local machine = o.machine
assert(machine.native_scopes and machine.default_scheduler.kind == 'native', 'native scope binding missing')
local log = {}
local after_sleep = {}
machine.inspect(function(r)
  if r.kind == 'transition' then
    for _, t in ipairs(r.timers) do log[#log + 1] = 'timer ' .. t.action .. ' ' .. t.state .. ' ' .. t.delay end
    for _, i in ipairs(r.invokes) do log[#log + 1] = 'invoke ' .. i.action .. ' ' .. i.id end
  end
end)
local chart = machine.create {
  id = 'native', initial = 'idle', context = {},
  actors = { fetch = function(input) o.sleep(input.ms); after_sleep[#after_sleep + 1] = input.ms; return 'fetched ' .. input.ms end },
  states = {
    idle = { on = { ARM = 'armed', FETCH = 'fetching', SLOW = 'slow' } },
    armed = { after = { [40] = 'expired' }, on = { DISARM = 'idle' } },
    expired = { on = { RESET = 'idle' } },
    fetching = { invoke = { src = 'fetch', input = function() return { ms = 20 } end,
      on_done = { target = 'idle', actions = machine.assign { result = function(_, e) return e.output end } } } },
    slow = { invoke = { src = 'fetch', input = function() return { ms = 60 } end,
      on_done = { target = 'idle', actions = machine.assign { result = function(_, e) return e.output end } } },
      on = { CANCEL = 'idle' } },
  },
}
local actor = chart:start()
actor:send('ARM')
o.sleep(80)
assert(actor:matches('expired'), 'timer did not fire')
actor:send('RESET')
actor:send('ARM')
o.sleep(10)
actor:send('DISARM')
o.sleep(60)
assert(actor:matches('idle'), 'cancelled timer fired')
actor:send('FETCH')
assert(actor:matches('fetching'))
o.sleep(60)
assert(actor:matches('idle') and actor:context().result == 'fetched 20', 'invoke result missing')
actor:send('SLOW')
o.sleep(10)
actor:send('CANCEL')
o.sleep(100)
assert(actor:matches('idle') and actor:context().result == 'fetched 20', 'stale invoke result applied')
-- Native cancellation: the 60ms fetch was unwound in its sleep.
assert(table.concat(after_sleep, ',') == '20', 'canceled invoke kept running: ' .. table.concat(after_sleep, ','))

-- Stopping an actor closes its root scope, and children nest under it.
local child = machine.create { id = 'child', initial = 'busy', states = {
  busy = { invoke = { src = 'fetch', input = function() return { ms = 50 } end, on_done = 'finished' } },
  finished = {} },
  actors = { fetch = function(input) o.sleep(input.ms); after_sleep[#after_sleep + 1] = 'child'; return true end } }
local parent = machine.create { id = 'parent', initial = 'on', states = { on = { on = {
  ADD = { actions = machine.spawn(child, { id = 'c' }) } } } } }
local p = parent:start()
p:send('ADD')
o.sleep(10)
p:stop()
o.sleep(80)
assert(table.concat(after_sleep, ',') == '20', 'stopped child kept running: ' .. table.concat(after_sleep, ','))

-- The token fallback: work runs to completion, but its result is dropped.
local tokens = chart:start { scheduler = machine.token_scheduler }
tokens:send('SLOW'); o.sleep(10); tokens:send('CANCEL'); o.sleep(100)
assert(tokens:matches('idle') and tokens:context().result == nil)
assert(table.concat(after_sleep, ',') == '20,60', 'token scheduler: ' .. table.concat(after_sleep, ','))
local expected = table.concat({
  'timer started armed 40', 'timer fired armed 40',
  'timer started armed 40', 'timer cancelled armed 40',
  'invoke started fetch', 'invoke done fetch',
  'invoke started fetch', 'invoke cancelled fetch'}, '|')
local first = {}
for i = 1, 8 do first[i] = log[i] end
assert(table.concat(first, '|') == expected, table.concat(log, '|'))
o.stdout.write('PASS machine native\n')
o.exit(0)
'''

assert BINARY.exists(), "run zig build first"
with tempfile.TemporaryDirectory() as temporary:
    app = Path(temporary) / "machine.lua"
    app.write_text(source)
    process = subprocess.run([str(BINARY), "run", str(app), "--headless"], capture_output=True, text=True, timeout=10)
    assert process.returncode == 0, process.stderr
    assert "PASS machine native" in process.stdout, (process.stdout, process.stderr)
print("PASS statechart after/invoke on native scopes: exit and stop cancel sleeping work; token fallback drops stale results")
