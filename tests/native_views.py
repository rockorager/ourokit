#!/usr/bin/env python3
"""Native APIs with I/O accept statechart context views (no compositor needed).

actor:context() and the tables read from it are read-only views (userdata),
while native bindings read tables raw. Each binding that takes a table
unwraps a view to the table behind it. tests/native_views_test.lua covers the
sandbox-only bindings (json.encode, drawing, gradients, UI declarations);
this covers the ones that need a session bus, a socket, the file system,
real desktop entries or an MCP host. Run it under dbus-run-session.
"""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OUROKIT_TEST_BINARY", ROOT / "zig-out/bin/ouroctl"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

source = r'''
local o = require('ouro')
local machine = o.machine
local port, scratch = PORT, 'SCRATCH'
local chart = machine.create {
  id = 'views', initial = 'idle',
  context = {
    signal = { path = '/dev/ourokit/Views', interface = 'dev.ourokit.Views', member = 'Changed',
      signature = 'as(us)', args = { { 'a', 'b' }, { 42, 'x' } } },
    names = { 'org.freedesktop.DBus' },
    request = { method = 'POST', headers = { ['x-view'] = 'yes' }, body = 'from context' },
    write = { permissions = 'private' },
    read = { max_bytes = 64 },
    notification = { title = 'Saved', body = 'from context', actions = { { id = 'open', label = 'Open' } } },
    chooser = { title = 'Pick', filters = { { name = 'Text', patterns = { '*.txt' } } } },
  },
  events = { FOUND = { entry = 'table' } },
  states = { idle = { on = { FOUND = { actions = machine.assign { entry = function(_, e) return e.entry end } } } } },
}
local actor = chart:start()
local c = actor:context()
local function check(label, ok, err)
  if not ok then error(label .. ': ' .. tostring(type(err) == 'table' and err.message or err), 0) end
  return ok
end

local failures = {}
local function section(label, fn)
  local ok, err = pcall(fn)
  if not ok then failures[#failures + 1] = label .. ': ' .. tostring(err) end
end

section('D-Bus', function()
  -- Call arguments, a whole emit request, and nested signal arguments.
  local bus <close> = check('connect', o.dbus.connect('session'))
  local stream <close> = check('subscribe', bus:subscribe { path = c.signal.path, interface = c.signal.interface, member = c.signal.member })
  check('emit (view args)', bus:emit { path = c.signal.path, interface = c.signal.interface, member = c.signal.member,
    signature = c.signal.signature, args = c.signal.args })
  check('emit (view request)', bus:emit(c.signal))
  for _ = 1, 2 do
    local message = check('next', stream:next(2000))
    assert(message.args[1][2] == 'b' and message.args[2][1] == 42 and message.args[2][2] == 'x', 'signal arguments')
  end
  local reply = check('call', bus:call { destination = 'org.freedesktop.DBus', path = '/org/freedesktop/DBus',
    interface = 'org.freedesktop.DBus', member = 'NameHasOwner', signature = 's', args = c.names })
  assert(reply.args[1] == true, 'NameHasOwner')
end)

section('HTTP', function()
  -- A request options table and a headers table from context.
  local url = 'http://127.0.0.1:' .. port .. '/echo'
  local response = check('http.post', o.http.post(url, c.request))
  assert(response.status == 200 and response.body == 'yes|from context', response.body)
  response = check('http.request', o.http.request { url = url, method = 'POST', headers = c.request.headers, body = 'b' })
  assert(response.body == 'yes|b', response.body)
end)

section('files', function()
  local path = scratch .. '/written'
  check('files.write', o.files.write(path, 'bytes', c.write))
  assert(check('files.read', o.files.read(path, c.read)) == 'bytes')
end)

section('prepare_launch', function()
  -- A real desktop entry kept in context, as the launcher does.
  local entries = o.xdg.applications.list()
  assert(#entries == 1, 'one desktop entry')
  actor:send { type = 'FOUND', entry = entries[1] }
  local launch = o.xdg.applications.prepare_launch(actor:context().entry)
  assert(launch.argv[1] == 'viewer' and launch.argv[2] == '--flag', table.concat(launch.argv, ' '))
end)

section('desktop', function()
  -- A notification spec from context reaches a notification server.
  local service <close> = check('connect', o.dbus.connect('session'))
  local received
  local export <close> = check('export', service:export { path = '/org/freedesktop/Notifications',
    interface = 'org.freedesktop.Notifications', signals = {}, methods = {
      Notify = { input = 'susssasa{sv}i', output = 'u', handler = function(r) received = r.args; return { 1 } end },
      CloseNotification = { input = 'u', output = '', handler = function() return {} end },
    } })
  local name <close> = check('own_name', service:own_name('org.freedesktop.Notifications'))
  local client <close> = check('notifications', o.desktop.notifications())
  check('send', client:send(c.notification))
  assert(received[4] == 'Saved' and received[6][1] == 'open' and received[6][2] == 'Open', 'notification arguments')
  -- Portal options pass validation; this bus has no portal to answer.
  local _, err = o.desktop.choose_file(c.chooser)
  assert(err and err.name ~= 'InvalidOptions', err and err.message)
end)

if #failures > 0 then
  o.stderr.write(table.concat(failures, '\n') .. '\n')
  o.exit(1)
end
o.stdout.write('PASS native views\n')
o.exit(0)
'''

# An MCP action may return context (a tracked view) as its output.
mcp_source = r'''
local o = require('ouro')
local machine = o.machine
local actor = machine.create { id = 'out', initial = 'idle', context = { count = 3, tags = { 'a', 'b' } },
  states = { idle = {} } }:start()
local schema = { type = 'object', properties = { count = { type = 'integer' }, tags = { type = 'array' } },
  required = { 'count', 'tags' }, additionalProperties = false }
return o.app { id = 'dev.ourokit.viewstest', run = function() error('headless MCP must not run the UI') end, actions = {
  Context = { description = 'The whole context', inputSchema = { type = 'object', additionalProperties = false },
    outputSchema = schema, handler = function() return actor:context() end },
} }
'''


class Echo(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        reply = (self.headers.get("x-view", "") + "|").encode() + body
        self.send_response(200)
        self.send_header("content-length", str(len(reply)))
        self.end_headers()
        self.wfile.write(reply)

    def log_message(self, *_):
        pass


def script_check():
    server = HTTPServer(("127.0.0.1", 0), Echo)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="ourokit-native-views-") as temporary:
            root = Path(temporary)
            (root / "data/applications").mkdir(parents=True)
            (root / "data/applications/viewer.desktop").write_text(
                "[Desktop Entry]\nType=Application\nName=Viewer\nExec=viewer --flag %F\n")
            app = root / "views.lua"
            app.write_text(source.replace("PORT", str(server.server_port)).replace("SCRATCH", temporary))
            env = dict(os.environ, XDG_RUNTIME_DIR=temporary, XDG_DATA_HOME=str(root / "data"),
                       XDG_DATA_DIRS=str(root / "share"))
            result = subprocess.run([str(BINARY), "run", str(app), "--headless"],
                                    env=env, capture_output=True, text=True, timeout=20)
            assert result.returncode == 0 and "PASS native views" in result.stdout, result.stderr
    finally:
        server.shutdown()


def mcp_check():
    from application_services import call
    with tempfile.TemporaryDirectory(prefix="ourokit-native-views-mcp-") as temporary:
        app = Path(temporary) / "app.lua"
        app.write_text(mcp_source)
        env = dict(os.environ, XDG_RUNTIME_DIR=temporary)
        process = subprocess.Popen([str(BINARY), "run", str(app), "--mcp", "--headless"], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            address = Path(temporary) / "ourokit/apps/dev.ourokit.viewstest"
            deadline = time.monotonic() + 8
            while not address.exists():
                assert process.poll() is None and time.monotonic() < deadline, "no MCP socket"
                time.sleep(.02)
            result = call(address, "Context")
            assert result.get("structuredContent") == {"count": 3, "tags": ["a", "b"]}, result
        finally:
            process.terminate()
            _, errors = process.communicate(timeout=8)
            assert "panic" not in errors, errors


assert BINARY.exists(), "run zig build first"
assert os.environ.get("DBUS_SESSION_BUS_ADDRESS"), "run under dbus-run-session"
failed = []
for check in (script_check, mcp_check):
    try:
        check()
    except AssertionError as error:
        failed.append(f"{check.__name__}: {error}")
assert not failed, "\n".join(failed)
print("PASS native APIs accept context views: D-Bus call/emit, HTTP, files, prepare_launch, desktop and MCP output")
