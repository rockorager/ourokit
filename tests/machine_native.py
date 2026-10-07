#!/usr/bin/env python3
"""Statechart timers and invokes on the real scheduler (no compositor needed).

`ouroctl test` forbids wall-clock sleeps, so machine_test.lua uses a manual
scheduler. This runs the default scheduler: after/invoke over spawn + sleep,
with per-entry tokens dropping cancelled timers and stale results.
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
local log = {}
machine.inspect(function(r)
  if r.kind == 'transition' then
    for _, t in ipairs(r.timers) do log[#log + 1] = 'timer ' .. t.action .. ' ' .. t.state .. ' ' .. t.delay end
    for _, i in ipairs(r.invokes) do log[#log + 1] = 'invoke ' .. i.action .. ' ' .. i.id end
  end
end)
local chart = machine.create {
  id = 'native', initial = 'idle', context = {},
  actors = { fetch = function(input) o.sleep(input.ms); return 'fetched ' .. input.ms end },
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
local expected = table.concat({
  'timer started armed 40', 'timer fired armed 40',
  'timer started armed 40', 'timer cancelled armed 40',
  'invoke started fetch', 'invoke done fetch',
  'invoke started fetch', 'invoke cancelled fetch'}, '|')
assert(table.concat(log, '|') == expected, table.concat(log, '|'))
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
print("PASS statechart after/invoke over spawn + sleep with stale-token cancellation")
