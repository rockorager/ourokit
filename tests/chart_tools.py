#!/usr/bin/env python3
"""ouroctl's statechart tooling from the command line (no compositor needed).

Gap 8: `ouroctl test` with a relative *_test.jsonl path found no manifest.
Gap 9: `ouroctl test --generate` pruned paths silently when an action raised.
Run after zig build: python3 tests/chart_tools.py
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OUROKIT_TEST_BINARY", ROOT / "zig-out/bin/ouroctl"))

CHARTS = """local o = require('ouro')
local machine = o.machine
local session = machine.create { id = 'session', initial = 'idle', events = { LOCK = {}, UNLOCK = {} },
  actions = { tell_shell = function() error('shell actor has not started') end },
  states = {
    idle = { on = { LOCK = { target = 'locked', actions = 'tell_shell' } } },
    locked = { initial = 'prompt', on = { UNLOCK = 'idle' }, states = { prompt = {} } },
  } }
return o.app { id = 'dev.ourokit.chart-tools', run = function() return { windows = {} } end }
"""


def run(*args, cwd=ROOT, ok=True):
    result = subprocess.run([str(BINARY), *args], cwd=cwd, capture_output=True, text=True, timeout=300)
    assert (result.returncode == 0) == ok, (args, cwd, result.stdout, result.stderr)
    return result.stdout


def relative_paths():
    stopwatch = ROOT / "examples/stopwatch"
    out = run("test", "stopwatch_paths_test.jsonl", cwd=stopwatch / "tests")
    assert "1 passed, 0 failed" in out, out
    out = run("test", "tests", cwd=stopwatch)
    assert "1 passed, 0 failed" in out, out


def reported_issues():
    with tempfile.TemporaryDirectory(prefix="ouro-chart-tools-") as directory:
        app = Path(directory)
        (app / "app.lua").write_text(CHARTS)
        (app / "ouro.json").write_text('{"schema_version":1,"id":"dev.ourokit.chart-tools","entry":"app.lua"}')
        out = run("test", "--generate", str(app))
        assert "session: " in out and "reach 3/3 states" in out, out
        assert "an input raised" in out and "shell actor has not started" in out and "first after: LOCK" in out, out
        out = run("test", str(app))
        assert "1 passed, 0 failed" in out, out


def main():
    assert BINARY.exists(), "run zig build first"
    relative_paths()
    reported_issues()
    print("PASS chart tools: relative *_test.jsonl paths find their manifest; generation reports raising "
          "actions and keeps their paths")


if __name__ == "__main__":
    main()
