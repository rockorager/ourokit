#!/usr/bin/env python3
"""Component machines in a real window: unmount stops the actor, remount is fresh.

Runs on the private compositor that verify_development.py provides. A keyed
component machine runs a 100 ms timer and a parked invoke. Hiding it must stop
both (no further ticks from that instance), and showing it again must create a
new actor with initial state. Each mount has a number, so stderr shows which
instance ticked.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from application_services import development_path
from desktop_native import BINARY, inspect, node, run, terminate, wait_for

WINDOW = "main"
SOURCE = r'''
local o = require('ouro')
local machine = o.machine

local ticker = machine.create {
  id = 'ticker', initial = 'idle',
  context = function(props) return { mount = props.mount, ticks = 0 } end,
  events = { START = {} },
  states = {
    idle = { on = { START = 'running' } },
    running = {
      after = { [100] = { target = 'running', actions = {
        -- Re-entering 'running' also restarts its invoke, by design.
        machine.assign(function(c) return { ticks = c.ticks + 1 } end),
        function(c) print('tick ' .. c.mount) end,
      } } },
      invoke = { src = function(input)
        print('invoke started ' .. input.mount)
        o.sleep(60000)
        print('invoke finished ' .. input.mount)
      end, input = function(c) return { mount = c.mount } end },
    },
  },
}

local Ticker = machine.component(ticker, function(self)
  local c = self:context()
  return o.button { key = 'start', label = 'mount ' .. c.mount .. ' ticks ' .. c.ticks,
    on_press = self:sender('START') }
end)

-- Only an explicit actor:stop() reports this; scope cancellation alone does not.
machine.inspect(function(record)
  if record.kind == 'actor' and record.action == 'stopped' and record.machine == 'ticker' then print('ticker stopped') end
end)

local page = machine.create {
  id = 'page', initial = 'shown', context = { mounts = 1 },
  events = { HIDE = {}, SHOW = {} },
  states = {
    shown = { on = { HIDE = 'hidden' } },
    hidden = { on = { SHOW = { target = 'shown', actions = machine.assign(function(c) return { mounts = c.mounts + 1 } end) } } },
  },
}:start()

return o.app { id = 'dev.ourokit.component-machines', run = function()
  return { windows = { o.window { id = 'main', title = 'Component machines', width = 400, height = 240,
    content = function()
      return o.column { key = 'root', gap = 8,
        o.button { key = 'hide', label = 'Hide', on_press = page:sender('HIDE') },
        o.button { key = 'show', label = 'Show', on_press = page:sender('SHOW') },
        page:matches('shown') and Ticker { key = 'ticker', mount = page:context().mounts } or nil,
      }
    end } } }
end }
'''


def main():
    with tempfile.TemporaryDirectory(prefix="ouro-component-machines-") as temporary:
        root = Path(temporary)
        source = root / "app.lua"
        source.write_text(SOURCE)
        env = dict(os.environ, WAYLAND_DISPLAY=os.environ["OUROKIT_TEST_WAYLAND_DISPLAY"])
        log = root / "stderr"
        with log.open("w+") as error_file:
            app = subprocess.Popen([str(BINARY), "run", str(source), "--dev", "--software"],
                                   env=env, stdout=subprocess.DEVNULL, stderr=error_file)
            try:
                endpoint = development_path(Path(env["XDG_RUNTIME_DIR"]), app)
                wait_for(lambda: inspect(env, endpoint).get("windows"), "window did not appear")

                def click(target):
                    # Every tick rebuilds the UI, so a token can go stale before
                    # the click lands; retry with a fresh one.
                    for _ in range(20):
                        tree = inspect(env, endpoint, WINDOW)["windows"][0]
                        result = run(str(BINARY), "dev", "input", str(endpoint), json.dumps({
                            "window": WINDOW, "token": tree["token"], "action": "click", "target": target}),
                            env=env, ok=None)
                        if result.returncode == 0:
                            return
                        assert "StaleDevelopmentTarget" in result.stdout, result.stdout
                    raise AssertionError(f"click on {target} stayed stale")

                def lines():
                    error_file.flush()
                    return log.read_text().splitlines()

                def label():
                    nodes = inspect(env, endpoint, WINDOW)["windows"][0]["nodes"]
                    found = [n for n in nodes if n["path"] == "root/ticker/start"]
                    return found[0]["label"] if found else None

                # Mount 1 runs: its timer ticks and its invoke is parked.
                assert label() == "mount 1 ticks 0", label()
                click("root/ticker/start")
                wait_for(lambda: lines().count("tick 1") >= 3, "mount 1 did not tick")
                assert "invoke started 1" in lines()
                wait_for(lambda: label() not in (None, "mount 1 ticks 0"), "ticks did not reach the UI")

                # Unmount: the actor is stopped. No further ticks from mount 1,
                # and its invoke never resumes.
                click("root/hide")
                assert label() is None
                wait_for(lambda: lines().count("ticker stopped") == 1, "unmount did not stop the actor")
                stopped_at = lines().count("tick 1")
                time.sleep(0.6)
                assert lines().count("tick 1") == stopped_at, "unmounted instance kept ticking"
                assert "invoke finished 1" not in lines()

                # Remount: a fresh actor with initial state, started by its own event.
                click("root/show")
                assert label() == "mount 2 ticks 0", label()
                time.sleep(0.3)
                assert "tick 2" not in lines(), "a remounted instance must not start before its first event"
                click("root/ticker/start")
                wait_for(lambda: lines().count("tick 2") >= 3, "mount 2 did not tick")
                assert "invoke started 2" in lines()
                assert lines().count("tick 1") == stopped_at

                # And it stops again on the next unmount.
                click("root/hide")
                wait_for(lambda: lines().count("ticker stopped") == 2, "second unmount did not stop the actor")
                stopped_at = lines().count("tick 2")
                time.sleep(0.6)
                assert lines().count("tick 2") == stopped_at, "second instance kept ticking"
                assert not any(line.startswith("Lua:") for line in lines()), lines()
                print("PASS component machines: unmount stops timer and invoke; remount starts fresh in a real window")
            except BaseException:
                print(log.read_text())
                raise
            finally:
                terminate(app)


if __name__ == "__main__":
    main()
