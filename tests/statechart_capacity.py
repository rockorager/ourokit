#!/usr/bin/env python3
"""Statechart actors do not exhaust signals in a real headless application.

From the statecharts review: each actor holds several hidden signals, and the
signal graph had a fixed capacity, so creating actors failed after about 150
cycles. The stopped actors are kept referenced here, as an application that
keeps finished actors would; that makes the result independent of when the
garbage collector runs. Needs no compositor.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OUROKIT_TEST_BINARY", ROOT / "zig-out/bin/ouroctl"))

SOURCE = r'''
local o = require('ouro')
local machine = o.machine
local chart = machine.create { id = 'tiny', initial = 'idle', context = { n = 0 },
  states = { idle = { on = { X = 'idle' } } } }
local finished = {}
for i = 1, 3000 do
  local ok, err = pcall(function()
    local a = chart:start()
    a:send('X')
    assert(a:context().n == 0)
    a:stop()
    finished[#finished + 1] = a
  end)
  if not ok then error('cycle ' .. i .. ': ' .. tostring(err), 0) end
end
assert(finished[1]:status() == 'stopped' and finished[3000]:context().n == 0)
o.stdout.write('PASS statechart capacity: 3000 actors created, stopped and kept\n')
o.exit(0)
'''

assert BINARY.exists(), "run zig build first"
with tempfile.TemporaryDirectory() as temporary:
    app = Path(temporary) / "capacity.lua"
    app.write_text(SOURCE)
    result = subprocess.run([str(BINARY), "run", str(app), "--headless"], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0 and "PASS" in result.stdout, (result.returncode, result.stdout, result.stderr)
    print(result.stdout.strip())
