#!/usr/bin/env python3
"""One application opens 40 windows, closes them, and opens them again.

Runs on the private compositor that verify_development.py provides. Window
slots, runtime slots and the Wayland client's object tables used to be sized
for 16 windows when the app connected. They now grow, so all 40 windows map;
closing them returns the app to its one control window, and reopening reuses
what the first round allocated.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

from application_services import development_path
from desktop_native import BINARY, inspect, run, terminate, wait_for

COUNT = 40
SOURCE = r'''
local o = require('ouro')
local machine = o.machine

local windows = machine.create {
  id = 'windows', initial = 'closed', events = { OPEN = {}, CLOSE = {} },
  states = { closed = { on = { OPEN = 'open' } }, open = { on = { CLOSE = 'closed' } } },
}:start()

return o.app { id = 'dev.ourokit.many-windows', run = function()
  return { windows = function()
    local list = { o.window { id = 'main', title = 'Many windows', width = 240, height = 120,
      content = function()
        return o.column { key = 'root', gap = 8,
          o.button { key = 'open', label = 'Open', on_press = windows:sender('OPEN') },
          o.button { key = 'close', label = 'Close', on_press = windows:sender('CLOSE') },
        }
      end } }
    if windows:matches('open') then
      for i = 1, %d do
        list[#list + 1] = o.window { id = 'w' .. i, title = 'Window ' .. i, width = 160, height = 80,
          content = function() return o.text { key = 'label', text = 'Window ' .. i } end }
      end
    end
    return list
  end }
end }
''' % COUNT


def main():
    with tempfile.TemporaryDirectory(prefix="ouro-many-windows-") as temporary:
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

                def window_ids():
                    try:
                        windows = inspect(env, endpoint).get("windows", [])
                    except AssertionError:
                        return None  # still starting up
                    return sorted(window["window"] for window in windows)

                def click(target):
                    tree = inspect(env, endpoint, "main")["windows"][0]
                    run(str(BINARY), "dev", "input", str(endpoint), json.dumps({
                        "window": "main", "token": tree["token"], "action": "click", "target": target}), env=env)

                wait_for(lambda: window_ids() == ["main"], "control window did not appear")
                expected = sorted(["main"] + [f"w{i}" for i in range(1, COUNT + 1)])
                for round_number in (1, 2):
                    click("root/open")
                    wait_for(lambda: window_ids() == expected, f"round {round_number}: {COUNT} windows did not all map", timeout=30)
                    labels = {window["window"]: window for window in inspect(env, endpoint, f"w{COUNT}")["windows"]}
                    assert f"w{COUNT}" in labels, labels.keys()
                    click("root/close")
                    wait_for(lambda: window_ids() == ["main"], f"round {round_number}: windows did not close", timeout=30)
                assert app.poll() is None, "the application exited"
                errors = [line for line in log.read_text().splitlines() if line.startswith("Lua:")]
                assert not errors, errors
                print(f"PASS many windows: {COUNT} windows open past the old limit of 16, close back to one, twice")
            except BaseException:
                print(log.read_text())
                raise
            finally:
                terminate(app)


if __name__ == "__main__":
    main()
