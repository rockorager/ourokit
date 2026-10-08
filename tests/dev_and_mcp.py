#!/usr/bin/env python3
"""--dev and --mcp together: two endpoints, each with its own authority.

One instance serves the production actions endpoint at
$XDG_RUNTIME_DIR/ourokit/apps/<id> and the private development endpoint under
ourokit/dev/. The application endpoint lists and calls only the app's actions;
runtime.* tools are unknown there. The development endpoint keeps runtime.*.
Both survive a source reload and re-publish their catalogs, inputs record with
origin 'mcp' (action calls) and 'dev' (runtime.send), and shutdown removes both
sockets. Runs on the private compositor verify_development.py provides.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile

from application_services import call, development_path, request
from desktop_native import BINARY, terminate, wait_for

APP_ID = "dev.ourokit.devmcp"

SOURCE = r'''
local o = require('ouro')
local machine = o.machine
local chart = machine.create {
  id = 'counter', initial = 'idle', context = { count = 0 },
  events = { BUMP = {} },
  states = { idle = { on = { BUMP = { actions = machine.assign(function(c) return { count = c.count + 1 } end) } } } },
}
local counter = chart:actor { id = 'counter' }
local empty = { type = 'object', additionalProperties = false }
local count = { type = 'object', properties = { count = { type = 'integer' } }, required = { 'count' }, additionalProperties = false }
return o.app { id = 'dev.ourokit.devmcp',
  actions = {
    Bump = { description = 'Count one', inputSchema = empty, outputSchema = count,
      handler = function() counter:send('BUMP'); return { count = counter:context().count } end },
    -- EXTRA
  },
  run = function()
    counter:start()
    return { windows = { o.window { id = 'main', title = 'devmcp', width = 240, height = 120,
      content = function() return o.text { key = 'count', text = tostring(counter:context().count) } end } } }
  end,
}
'''

EXTRA = '''Read = { description = 'Read the count', inputSchema = empty, outputSchema = count,
      handler = function() return { count = counter:context().count } end },'''


def tool_names(path):
    return [tool["name"] for tool in request(path, "tools/list")["result"]["tools"]]


def main():
    with tempfile.TemporaryDirectory(prefix="ouro-dev-and-mcp-") as temporary:
        root = Path(temporary)
        app = root / "app.lua"
        app.write_text(SOURCE)
        runtime = Path(os.environ["XDG_RUNTIME_DIR"])
        env = dict(os.environ, WAYLAND_DISPLAY=os.environ["OUROKIT_TEST_WAYLAND_DISPLAY"],
                   XDG_STATE_HOME=str(root / "state"))
        application = runtime / "ourokit/apps" / APP_ID
        published = runtime / "ourokit/mcp/apps" / f"{APP_ID}.json"
        errors = root / "app.stderr"
        with errors.open("w+") as error_file:
            process = subprocess.Popen([str(BINARY), "run", str(app), "--dev", "--mcp", "--software"],
                                       env=env, stdout=subprocess.DEVNULL, stderr=error_file)
            try:
                development = development_path(runtime, process, windows=("main",))
                wait_for(application.is_socket, "application endpoint did not appear")

                # The application endpoint: declared actions only.
                assert tool_names(application) == ["Bump"], tool_names(application)
                assert call(application, "Bump")["structuredContent"] == {"count": 1}
                for name in ("runtime.statecharts", "runtime.status", "runtime.reload", "runtime.send"):
                    refused = call(application, name, {} if name != "runtime.send" else
                                   {"actor": "counter", "event": {"type": "BUMP"}})
                    assert refused.get("rpcError", {}).get("message") == "Unknown tool", (name, refused)
                discovery = request(application, "server/discover")["result"]
                assert "resources" not in discovery["capabilities"], discovery
                wait_for(published.exists, "the application catalog was not published")
                descriptor = json.loads(published.read_text())
                assert descriptor["endpoint"]["runtime_path"] == f"ourokit/apps/{APP_ID}", descriptor
                assert [t["name"] for t in descriptor["tools"]] == ["Bump"], descriptor

                # The development endpoint: runtime.* plus the actions.
                names = tool_names(development)
                assert "runtime.statecharts" in names and "Bump" in names, names
                sent = call(development, "runtime.send", {"actor": "counter", "event": {"type": "BUMP"}})
                assert sent["structuredContent"]["accepted"], sent
                assert call(development, "runtime.statecharts", {})["structuredContent"]["actors"], "no actors"
                assert "resources" in request(development, "server/discover")["result"]["capabilities"]

                # The application path is one per id: a second instance asking
                # for it fails and leaves the first one's endpoint alone.
                second = subprocess.run([str(BINARY), "run", str(app), "--dev", "--mcp", "--software"],
                                        env=env, capture_output=True, text=True, timeout=20)
                assert second.returncode != 0 and "AddressInUse" in second.stderr, second.stderr
                assert call(application, "Bump")["structuredContent"] == {"count": 3}
                assert len([p for p in (runtime / "ourokit/dev").iterdir()]) == 1, "second dev endpoint left behind"

                # A reload adds an action: both endpoints stay, and both catalogs change.
                app.write_text(SOURCE.replace("-- EXTRA", EXTRA))
                reloaded = subprocess.run([str(BINARY), "dev", "reload", str(development)], env=env,
                                          capture_output=True, text=True, timeout=20)
                assert reloaded.returncode == 0, reloaded.stdout + reloaded.stderr
                assert tool_names(application) == ["Bump", "Read"], tool_names(application)
                assert "Read" in tool_names(development)
                wait_for(lambda: [t["name"] for t in json.loads(published.read_text())["tools"]] == ["Bump", "Read"],
                         "the application catalog was not re-published")
                assert call(application, "Read")["structuredContent"] == {"count": 3}
                assert call(application, "runtime.statecharts").get("rpcError"), "runtime.* leaked after reload"
                assert call(development, "runtime.status")["structuredContent"]["activeGeneration"] == 2

                # Recording origins: the action's send is 'mcp', runtime.send is 'dev'.
                recording = root / f"state/ourokit/recordings/{APP_ID}.jsonl"
                origins = {json.loads(line).get("o") for line in recording.read_text().splitlines() if line}
                assert {"mcp", "dev"} <= origins, origins
            except BaseException:
                error_file.flush()
                print(errors.read_text())
                raise
            finally:
                terminate(process)
        assert not application.exists() and not development.exists(), "endpoints left behind after exit"
        print("PASS --dev --mcp: actions on the application endpoint, runtime.* only on the development "
              "endpoint, both survive a reload, recorded origins mcp and dev, both sockets removed")


if __name__ == "__main__":
    main()
