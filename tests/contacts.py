#!/usr/bin/env python3
"""Deterministic checks for examples/contacts (no compositor needed).

First the address book and appearance charts run headless with fake services
on the manual scheduler, so loading, selection, renames, background saves,
retries and quitting are driven explicitly. Then the real app runs with
--mcp --headless against a disposable loopback HTTP server: MCP actions are
events sent to the same chart, and renames reach the server as PUTs.
Run after zig build: python3 tests/contacts.py
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import threading
import time

from application_services import BINARY, ROOT, call

source = r'''
local o=require('ouro')
local machine=o.machine
local m=require('model')(o.json)

-- Plain functions.
local seed=m.seed()
assert(#seed==500 and seed[1].id=='ada' and seed[500].id=='person-500' and seed[500].email=='person500@example.org')
local grace, index=m.find(seed,'grace'); assert(grace.name=='Grace Hopper' and index==2 and m.find(seed,'nobody')==nil)
local replaced=m.replaced(seed, m.renamed(grace,'G'))
assert(replaced[2].name=='G' and replaced[2].email=='grace@example.org' and seed[2].name=='Grace Hopper' and replaced[1]==seed[1])
assert(m.check_name('') and m.check_name('two\nlines') and not m.check_name('Ada'))
local ids=m.with(m.with({},'a'),'b'); assert(m.with(ids,'a')==ids and table.concat(m.without(ids,'a'),',')=='b')
assert(m.contact_url('http://h/c/','a b/\xc3\xa9')=='http://h/c/a%20b%2F%C3%A9')
assert(#m.decode_book('{"contacts":[{"id":"a","name":"A","email":"a@x"}]}')==1)
assert(m.decode_book('{"contacts":[{"id":"a","name":"A","email":"a@x"},{"id":"a","name":"B","email":"b@x"}]}')==nil, 'duplicate ids')
assert(m.decode_book('{broken')==nil and m.decode_book('{"contacts":[{"id":"a"}]}')==nil and m.decode_book('[]')==nil)
assert(m.decode_contact('{"contact":{"id":"a","name":"A","email":"a@x"}}').name=='A' and m.decode_contact('{"contact":5}')==nil)
assert(m.note(1)==m.note(4) and m.initials({id='alan'})=='AT')

-- Fake services record what the charts asked for.
local loads, saves, exits = 0, {}, 0
local load_result, save_error, server_email
local charts=require('charts')(o, m, {
  load=function() loads=loads+1; if type(load_result)=='string' then error({message=load_result},0) end return load_result end,
  save=function(remote, contact)
    saves[#saves+1]=(remote or 'memory')..' '..contact.id..'='..contact.name
    if save_error then error({message=save_error},0) end
    return {id=contact.id, name=contact.name, email=server_email or contact.email}
  end,
  exit=function() exits=exits+1 end,
})
local clock=machine.manual_scheduler()
local book_records={
  {id='ada',name='Ada Lovelace',email='ada@example.org'},
  {id='grace',name='Grace Hopper',email='grace@example.org'},
}
local function start()
  load_result={contacts=book_records, remote='http://server/contacts'}
  local book=charts.book:start{scheduler=clock}; clock.run_tasks(); return book
end
local function name(book, id) return m.find(book:context().contacts, id).name end

-- Loading fails, then Retry loads.
load_result='connection refused'
local book=charts.book:start{scheduler=clock}
assert(book:matches('loading') and not book:can{type='SELECT', id='ada'} and not book:can('RETRY'))
clock.run_tasks()
assert(book:matches('failed') and book:context().error=='connection refused' and book:can('RETRY'))
load_result={contacts=book_records, remote='http://server/contacts'}
book:send('RETRY'); assert(book:matches('loading')); clock.run_tasks()
local c=book:context()
assert(book:matches('ready.sync.idle') and book:matches('ready.lifecycle.running') and loads==2)
assert(c.selected=='ada' and c.draft=='Ada Lovelace' and c.error==nil and c.remote=='http://server/contacts')

-- Selection resets the draft; unknown ids are rejected, as MCP reports them.
book:send{type='SELECT', id='grace'}
assert(book:context().selected=='grace' and book:context().draft=='Grace Hopper')
assert(not book:can{type='SELECT', id='nobody'})
book:send{type='SELECT', id='nobody'}; assert(book:context().selected=='grace')
book:send{type='EDIT', value='Grace B. Hopper'}
assert(book:context().draft=='Grace B. Hopper' and name(book,'grace')=='Grace Hopper')
assert(not book:can{type='RENAME', id='grace', name=''} and not book:can{type='RENAME', id='grace', name='Grace Hopper'})
assert(not book:can{type='RENAME', id='nobody', name='x'} and book:can{type='RENAME', id='grace', name='Grace B. Hopper'})
assert(not pcall(book.send, book, {type='RENAME', id='grace'}), 'schema requires name')

-- A rename applies at once and saves in the background; the server copy wins.
server_email='grace@navy.example'
book:send{type='RENAME', id='grace', name='Grace B. Hopper'}
assert(name(book,'grace')=='Grace B. Hopper' and book:matches('ready.sync.saving') and #saves==0)
clock.run_tasks()
assert(saves[1]=='http://server/contacts grace=Grace B. Hopper' and book:matches('ready.sync.idle'))
assert(#book:context().pending==0 and m.find(book:context().contacts,'grace').email=='grace@navy.example')
server_email=nil

-- A rename during a save is written next; the stale reply does not undo it.
book:send{type='RENAME', id='ada', name='Ada B'}
book:send{type='RENAME', id='ada', name='Ada Byron'}
book:send{type='RENAME', id='grace', name='G'}
assert(#book:context().pending==2 and book:context().saving.name=='Ada B')
clock.run_tasks()
assert(table.concat(saves,'|',2)=='http://server/contacts ada=Ada B|http://server/contacts ada=Ada Byron|http://server/contacts grace=G')
assert(name(book,'ada')=='Ada Byron' and name(book,'grace')=='G' and #book:context().pending==0)
assert(book:context().draft=='G', 'renaming the selected contact updates the draft')

-- A failed save keeps the local name, retries after five seconds or on Retry.
save_error='PUT returned 503'
book:send{type='RENAME', id='ada', name='Ada'}
clock.run_tasks()
assert(book:matches('ready.sync.retrying') and book:context().error=='PUT returned 503' and name(book,'ada')=='Ada')
assert(book:can('RETRY') and #book:context().pending==1)
clock.advance(4999); assert(book:matches('ready.sync.retrying'))
clock.advance(1); assert(book:matches('ready.sync.saving')); clock.run_tasks()
assert(book:matches('ready.sync.retrying') and #saves==6)
save_error=nil
book:send('RETRY'); clock.run_tasks()
assert(book:matches('ready.sync.idle') and book:context().error==nil and #book:context().pending==0 and #saves==7)
clock.advance(10000); assert(#saves==7, 'the retry timer was canceled')

-- Quit waits for queued renames, then exits.
book:send{type='RENAME', id='ada', name='Ada L'}
book:send('QUIT')
assert(book:matches('ready.lifecycle.quitting') and exits==0 and book:can('QUIT'))
clock.run_tasks()
assert(book:status()=='done' and exits==1 and saves[#saves]=='http://server/contacts ada=Ada L')
assert(clock.open_scopes==0, 'a finished book closes every scope')

-- Quit stops waiting once a save fails, after five seconds, or on a second Quit.
exits=0
book=start(); save_error='down'
book:send{type='RENAME', id='ada', name='x'}; book:send('QUIT')
assert(exits==0); clock.run_tasks(); assert(exits==1 and book:status()=='done')
save_error=nil
book=start(); book:send{type='RENAME', id='ada', name='y'}; book:send('QUIT')
clock.advance(4999); assert(exits==1); clock.advance(1)
assert(book:matches('exiting')); clock.run_tasks(); assert(exits==2 and book:status()=='done')
assert(saves[#saves]~='http://server/contacts ada=y', 'the abandoned save was canceled')
book=start(); book:send{type='RENAME', id='ada', name='z'}; book:send('QUIT'); book:send('QUIT')
clock.run_tasks(); assert(exits==3 and book:status()=='done' and saves[#saves]~='http://server/contacts ada=z')
book=start(); book:send('QUIT'); assert(book:matches('exiting'), 'nothing pending: quit at once')
clock.run_tasks(); assert(exits==4)
load_result='down'; book=charts.book:start{scheduler=clock}; book:send('QUIT'); clock.run_tasks(); assert(exits==5)
clock.run_tasks(); assert(clock.open_scopes==0)

-- The built-in sample has no remote; saves still go through the same path.
load_result={contacts=m.seed()}
book=charts.book:start{scheduler=clock}; clock.run_tasks()
book:send{type='RENAME', id='person-480', name='Distant contact'}; clock.run_tasks()
assert(saves[#saves]=='memory person-480=Distant contact' and #book:context().contacts==500 and book:context().remote==nil)
book:stop(); assert(clock.open_scopes==0)

-- Presentation chart.
local look=charts.appearance:start{scheduler=clock}
assert(look:matches('light')); look:send('TOGGLE'); assert(look:matches('terminal')); look:send('TOGGLE'); assert(look:matches('light'))

-- Inspection data is plain.
assert(o.json.decode(o.json.encode(charts.book:graph())).id=='contacts')
assert(o.json.decode(o.json.encode(charts.appearance:graph())).id=='appearance')
o.stdout.write('PASS contacts charts\n')
o.exit(0)
'''


def charts():
    with tempfile.TemporaryDirectory() as temporary:
        app = Path(temporary) / "test.lua"
        app.write_text(source)
        for name in ("model.lua", "charts.lua"):
            shutil.copy(ROOT / "examples/contacts" / name, temporary)
        process = subprocess.run([str(BINARY), "run", str(app), "--headless"], capture_output=True, text=True, timeout=10)
        assert process.returncode == 0, process.stderr
        assert "LuaRuntimeError" not in process.stderr, process.stderr
        assert "PASS contacts charts" in process.stdout, process.stdout
    print("PASS contacts charts: loading and retry, selection, optimistic renames, queued and stale saves, save retries, quitting")


class Server(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/contacts" or self.server.fail_load:
            return self.reply(500, {})
        self.reply(200, {"contacts": list(self.server.book.values())})

    def do_PUT(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        record = self.server.book.get(self.path.removeprefix("/contacts/"))
        self.server.puts.append((self.path, body))
        if self.server.fail_save or record is None:
            return self.reply(503, {})
        record["name"] = body["name"]
        self.reply(200, {"contact": record})


class Quiet(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass  # The app closes kept-alive connections when it exits.


def serve(fail_load=False):
    server = Quiet(("127.0.0.1", 0), Server)
    server.book = {
        "ada": {"id": "ada", "name": "Ada Lovelace", "email": "ada@example.org"},
        "grace": {"id": "grace", "name": "Grace Hopper", "email": "grace@example.org"},
        "alan": {"id": "alan", "name": "Alan Turing", "email": "alan@example.org"},
    }
    server.puts, server.fail_load, server.fail_save = [], fail_load, False
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def launch(directory, server=None):
    env = dict(os.environ, XDG_RUNTIME_DIR=directory, XDG_CONFIG_HOME=directory + "/config")
    for key in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "LISTEN_PID", "LISTEN_FDS"):
        env.pop(key, None)
    if server:
        config = Path(directory, "config/dev.ourokit.contacts")
        config.mkdir(parents=True)
        url = f"http://127.0.0.1:{server.server_address[1]}/contacts"
        (config / "server.json").write_text(json.dumps({"version": 1, "url": url}))
    # single_instance owns a session-bus name, so each run gets a private bus.
    process = subprocess.Popen(["dbus-run-session", "--", str(BINARY), "run", str(ROOT / "examples/contacts/ouro.json"), "--mcp", "--headless"],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    address = Path(directory, "ourokit/apps/dev.ourokit.contacts")
    deadline = time.monotonic() + 8
    while not address.is_socket():
        assert process.poll() is None and time.monotonic() < deadline, process.stderr.read()
        time.sleep(.02)
    return process, address


def stop(process):
    os.killpg(process.pid, signal.SIGTERM)
    _, errors = process.communicate(timeout=8)
    assert b"panic" not in errors and b"LuaRuntimeError" not in errors, errors


def until(predicate, seconds=8):
    deadline = time.monotonic() + seconds
    while not predicate():
        assert time.monotonic() < deadline, "timed out"
        time.sleep(.02)


def error_code(result):
    assert result.get("isError"), result
    return result["structuredContent"]["error"]["code"]


def remote():
    server = serve()
    with tempfile.TemporaryDirectory() as directory:
        process, address = launch(directory, server)
        try:
            # The first call starts the book in application scope and waits for the GET.
            people = call(address, "GetContacts")["structuredContent"]["contacts"]
            assert [p["id"] for p in people] == ["ada", "grace", "alan"], people
            assert error_code(call(address, "SelectContact", {"id": "nobody"})) == "ContactNotFound"
            assert call(address, "SelectContact", {"id": "grace"})["structuredContent"] == {}
            renamed = call(address, "RenameContact", {"id": "grace", "name": "Rear Admiral Grace Hopper"})
            assert renamed["structuredContent"]["contact"]["name"] == "Rear Admiral Grace Hopper", renamed
            until(lambda: server.book["grace"]["name"] == "Rear Admiral Grace Hopper")
            assert server.puts == [("/contacts/grace", {"name": "Rear Admiral Grace Hopper"})], server.puts
            assert error_code(call(address, "RenameContact", {"id": "grace", "name": ""})) == "InvalidName"
            assert error_code(call(address, "RenameContact", {"id": "nobody", "name": "x"})) == "ContactNotFound"
            unchanged = call(address, "RenameContact", {"id": "grace", "name": "Rear Admiral Grace Hopper"})
            assert unchanged["structuredContent"]["contact"]["name"] == "Rear Admiral Grace Hopper"
            # A failing server keeps the local rename and retries five seconds later.
            server.fail_save = True
            call(address, "RenameContact", {"id": "ada", "name": "Ada Byron"})
            until(lambda: len(server.puts) == 2)
            server.fail_save = False
            assert call(address, "GetContacts")["structuredContent"]["contacts"][0]["name"] == "Ada Byron"
            assert server.book["ada"]["name"] == "Ada Lovelace"
            until(lambda: server.book["ada"]["name"] == "Ada Byron", 8)
            assert len(server.puts) == 3, server.puts
        finally:
            stop(process)
            server.shutdown()
    failing = serve(fail_load=True)
    with tempfile.TemporaryDirectory() as directory:
        process, address = launch(directory, failing)
        try:
            result = call(address, "GetContacts")
            assert error_code(result) == "LoadFailed" and "returned 500" in result["structuredContent"]["error"]["parameters"]["message"]
        finally:
            stop(process)
            failing.shutdown()
    with tempfile.TemporaryDirectory() as directory:
        process, address = launch(directory)
        try:
            people = call(address, "GetContacts")["structuredContent"]["contacts"]
            assert len(people) == 500 and people[-1]["id"] == "person-500"
            renamed = call(address, "RenameContact", {"id": "person-480", "name": "Distant contact"})
            assert renamed["structuredContent"]["contact"] == {"id": "person-480", "name": "Distant contact", "email": "person480@example.org"}
            assert call(address, "GetContacts")["structuredContent"]["contacts"][479]["name"] == "Distant contact"
        finally:
            stop(process)
    print("PASS contacts over MCP: HTTP load, select/rename as chart events, background PUT with retry, load failure, built-in sample")


if __name__ == "__main__":
    assert BINARY.exists(), "run zig build first"
    charts()
    remote()
