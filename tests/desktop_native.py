#!/usr/bin/env python3
"""Native desktop-completeness checks on a disposable/private Wayland desktop.

Normally this is run by verify_development.py's private Sway.  When no display
is supplied this file starts an equally isolated, bounded headless Sway.  It
never connects to the user's desktop.
"""
import json
import os
from pathlib import Path
import shutil
import shlex
import select
import subprocess
import sys
import tempfile
import time

from application_services import call, development_path
from session_native import protocol_xml

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OUROKIT_TEST_BINARY", ROOT / "zig-out/bin/ouroctl"))


def run(*args, env, ok=True, timeout=10):
    if len(args) >= 4 and args[0] == str(BINARY) and args[1] == 'dev':
        env = dict(env, XDG_RUNTIME_DIR=str(Path(args[3]).parents[2]))
    result = subprocess.run(args, env=env, capture_output=True, text=True, timeout=timeout)
    assert ok is None or (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    return result


def sway(env, *command):
    return run("swaymsg", "-s", env["SWAYSOCK"], *command, env=env).stdout


def wait_for(predicate, message, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.04)
    raise AssertionError(message)


def inspect(env, endpoint, window=None):
    args = [str(BINARY), "dev", "inspect", str(endpoint)]
    if window:
        args.append(json.dumps({"window": window}))
    return json.loads(run(*args, env=env).stdout)


def click(env, endpoint, window, target):
    tree = inspect(env, endpoint, window)["windows"][0]
    body = {"window": window, "token": tree["token"], "action": "click", "target": target}
    return run(str(BINARY), "dev", "input", str(endpoint), json.dumps(body), env=env)


def node(env, endpoint, window, path):
    tree = inspect(env, endpoint, window)["windows"][0]
    return next(item for item in tree["nodes"] if item["path"] == path)


def capture(env, endpoint, window, name):
    destination = os.environ.get("OUROKIT_TEST_CAPTURE")
    if not destination:
        return
    directory = Path(destination).resolve()
    # OUROKIT_TEST_CAPTURE may name the requested artifact root or a legacy file.
    if directory.suffix:
        directory = directory.parent / "desktop"
    directory.mkdir(parents=True, exist_ok=True)
    tree = inspect(env, endpoint, window)["windows"][0]
    body = {"window": window, "token": tree["token"]}
    run(str(BINARY), "dev", "capture", str(endpoint), json.dumps(body),
        "--output", str(directory / name), env=env)


def terminate(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def wait_portal(process, env):
    def probe():
        if process.poll() is not None:
            raise AssertionError("portal exited: " + process.stderr.read())
        result = subprocess.run(["gdbus", "introspect", "--session", "--dest",
                                 "org.freedesktop.portal.Desktop", "--object-path",
                                 "/org/freedesktop/portal/desktop"], env=env, capture_output=True)
        return result.returncode == 0
    wait_for(probe, "private portal did not own its name")


def portal_source(save_uri, open_uri, log):
    # The parent string is recorded before responding, making the test prove
    # that the real xdg-foreign export reached the portal, not merely that the
    # chooser returned a canned URI.
    return f'''local o=require('ouro'); local d=assert(o.dbus); local b=assert(d.connect('session'))
local requests={{}}
local function val(options,name) for _,v in ipairs(options) do if v[1]==name then return v[2].value end end end
local function method(name,uri)
 return {{input='ssa{{sv}}',output='o',handler=function(r)
  assert(r.args[1]:sub(1,8)=='wayland:')
  assert(o.files.write({json.dumps(log.as_uri())},name..' '..r.args[1]))
  local token=assert(val(r.args[3],'handle_token')); local p='/org/freedesktop/portal/desktop/request/'..r.sender:sub(2):gsub('%.','_')..'/'..token
  if r.args[2]=='pending' then
   -- Return an alternate request path, as older portals do. A client that is
   -- cancelled before this reply reaches it can only close the predicted path.
   local function closable(path, label)
    requests[#requests+1]=assert(b:export{{path=path,interface='org.freedesktop.portal.Request',methods={{Close={{input='',output='',handler=function()
     assert(o.files.write({json.dumps(log.as_uri())},'closed '..label..' request')); return {{}} end}}}},signals={{}}}})
   end
   closable(p, 'predicted')
   p='/org/freedesktop/portal/desktop/request/alternate/'..token
   closable(p, 'alternate')
   assert(o.files.write({json.dumps(log.as_uri())},'replying '..p))
   return {{p}}
  end
  assert(b:emit{{destination=r.sender,path=p,interface='org.freedesktop.portal.Request',member='Response',signature='ua{{sv}}',args={{0,{{{{'uris',d.variant('as',{{uri}})}}}}}}}})
  return {{p}}
 end}}
end
local x <close> = assert(b:export{{path='/org/freedesktop/portal/desktop',interface='org.freedesktop.portal.FileChooser',methods={{
 OpenFile=method('OpenFile',{json.dumps(open_uri)}),SaveFile=method('SaveFile',{json.dumps(save_uri)})}},signals={{}}}})
local n <close> = assert(b:own_name('org.freedesktop.portal.Desktop'))
while true do o.sleep(1000) end
'''


def document_test(root, env):
    saved = root / "saved.ournote"
    initial = root / "initial.ournote"
    initial.write_text('{"format":"dev.ourokit.ournote","version":1,"title":"From disk","text":"opened"}')
    portal_log = root / "portal.log"
    portal = root / "portal.lua"
    portal.write_text(portal_source(saved.as_uri(), initial.as_uri(), portal_log))
    portal_process = subprocess.Popen([str(BINARY), "run", str(portal), "--headless"], env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    wait_portal(portal_process, env)
    app_env = dict(env, WAYLAND_DISPLAY=env["OUROKIT_TEST_WAYLAND_DISPLAY"],
                   XDG_CONFIG_HOME=str(root / 'notes-config'), XDG_STATE_HOME=str(root / 'notes-state'))
    errors = root / "documents.stderr"
    with errors.open("w+") as error_file:
        app = subprocess.Popen([str(BINARY), "run", str(ROOT / "examples/documents/app.lua"), "--dev", "--software"],
                               env=app_env, stdout=subprocess.DEVNULL, stderr=error_file)
        try:
            try:
                endpoint = development_path(Path(env["XDG_RUNTIME_DIR"]), app)
            except AssertionError as failure:
                error_file.flush()
                raise AssertionError(f"{failure}: {errors.read_text()}") from failure
            wait_for(lambda: inspect(app_env, endpoint).get("windows"), "document window did not appear")
            window = "main"
            panel = lambda value, leaf: f"documents/tabs/control/panels/{value}/drop/layers/body/{leaf}"
            header = lambda value, leaf="": f"documents/tabs/control/strip/bar/{value}" + (f"/{leaf}" if leaf else "")

            def input_action(**action):
                tree = inspect(app_env, endpoint, window)["windows"][0]
                return run(str(BINARY), "dev", "input", str(endpoint),
                           json.dumps({"window":window, "token":tree["token"], **action}), env=app_env,
                           timeout=60 if action["action"] == "text" else 10)

            capture(app_env, endpoint, window, "document-normal.png")
            # The split's public children and divider must all have real geometry.
            sidebar = node(app_env, endpoint, window, "documents/sidebar")["bounds"]
            tabs = node(app_env, endpoint, window, "documents/tabs")["bounds"]
            divider_path = "documents/divider"
            divider = node(app_env, endpoint, window, divider_path)["bounds"]
            assert 150 <= sidebar["width"] < tabs["width"] and divider["width"] > 0, (sidebar, divider, tabs)
            click(app_env, endpoint, window, divider_path)
            input_action(action="key", key="arrow_right")
            adjusted = node(app_env, endpoint, window, divider_path)["bounds"]
            assert adjusted["x"] > divider["x"], (divider, adjusted)
            adjusted_sidebar = node(app_env, endpoint, window, "documents/sidebar")["bounds"]
            adjusted_tabs = node(app_env, endpoint, window, "documents/tabs")["bounds"]
            assert adjusted_sidebar["width"] > sidebar["width"] and adjusted_tabs["width"] < tabs["width"]
            capture(app_env, endpoint, window, "document-divider-focus.png")
            click(app_env, endpoint, window, header(1))
            input_action(action="key", key="home")
            capture(app_env, endpoint, window, "document-tab-focus.png")

            click(app_env, endpoint, window, panel(1, "title"))
            input_action(action="key", key="a", control=True)
            input_action(action="text", text="Native save")
            body = "First line\nSecond line\n" + "x\n" * 30
            click(app_env, endpoint, window, panel(1, "text"))
            input_action(action="text", text=body)
            field = node(app_env, endpoint, window, panel(1, "text"))
            assert field["multiline"] and field["scroll_offset"] > 0, field
            assert field["selection"]["extent"] == len(body.encode()), field
            capture(app_env, endpoint, window, "document-scrolled.png")

            click(app_env, endpoint, window, panel(1, "actions/open"))
            try:
                wait_for(lambda: any(n["path"] == panel(2, "title") and n["value"] == "From disk"
                                     for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"]),
                         "portal-opened document tab did not appear")
            except AssertionError as failure:
                error = next((n.get("label") for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"]
                              if n["path"] == panel(1, "error")), None)
                raise AssertionError(f"{failure}; UI error={error}; portal={portal_log.read_text() if portal_log.exists() else 'no call'}") from failure
            hidden = node(app_env, endpoint, window, panel(1, "text"))
            assert hidden["id"] == field["id"] and not hidden["visible"], hidden
            tree = inspect(app_env, endpoint, window)["windows"][0]
            rejected = subprocess.run([str(BINARY), "dev", "input", str(endpoint), json.dumps({
                "window":window, "token":tree["token"], "action":"click", "target":panel(1, "text")})],
                env=app_env, capture_output=True, text=True)
            assert rejected.returncode != 0 and json.loads(rejected.stdout)["error"]["code"] == "DevelopmentTargetHidden", rejected
            click(app_env, endpoint, window, header(1))
            restored = node(app_env, endpoint, window, panel(1, "text"))
            assert restored["id"] == field["id"] and restored["selection"] == field["selection"]
            assert restored["scroll_offset"] == field["scroll_offset"]
            # The retained field also keeps its edit history across tab switches.
            click(app_env, endpoint, window, panel(1, "text"))
            input_action(action="key", key="end", control=True)
            input_action(action="text", text="x")
            click(app_env, endpoint, window, header(2))
            click(app_env, endpoint, window, header(1))
            click(app_env, endpoint, window, panel(1, "text"))
            input_action(action="key", key="z", control=True)
            assert node(app_env, endpoint, window, panel(1, "text"))["value"] == body

            input_action(action="scroll", target=panel(1, "text"), delta=-10000)
            time.sleep(.7)  # A caret blink must not undo manual scrolling.
            assert node(app_env, endpoint, window, panel(1, "text"))["scroll_offset"] == 0
            for action in [{"action":"key", "key":"home", "control":True},
                           {"action":"key", "key":"arrow_down", "shift":True},
                           {"action":"key", "key":"arrow_down", "shift":True},
                           {"action":"key", "key":"arrow_down", "shift":True}]:
                input_action(**action)
            selection = node(app_env, endpoint, window, panel(1, "text"))["selection"]
            assert selection["anchor"] == 0 and selection["extent"] > len("First line\nSecond line\n")
            capture(app_env, endpoint, window, "document-multiline-selection.png")
            click(app_env, endpoint, window, panel(1, "actions/save"))
            wait_for(saved.exists, "portal save did not write the returned local URI")
            persisted = json.loads(saved.read_text())
            assert persisted["title"] == "Native save" and persisted["text"] == body, persisted

            # Re-open what was actually written through the application's open hook.
            run(str(BINARY), "activate", "dev.ourokit.documents", saved.as_uri(), env=app_env, ok=False)
            # Dev instances intentionally do not own the production bus name; use the
            # chooser again with its URI switched by replacing the service fixture.
            portal_process.terminate(); portal_process.wait(timeout=5)
            portal.write_text(portal_source(saved.as_uri(), saved.as_uri(), portal_log))
            portal_process = subprocess.Popen([str(BINARY), "run", str(portal), "--headless"], env=env,
                                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            wait_portal(portal_process, env)
            click(app_env, endpoint, window, panel(1, "actions/open"))
            wait_for(lambda: any(n["path"] == panel(3, "title") and n["value"] == "Native save"
                                 for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"]),
                     "saved file did not reopen in a tab")
            assert node(app_env, endpoint, window, panel(3, "text"))["value"] == body

            # Closing a background tab selects and targets that exact dirty note.
            click(app_env, endpoint, window, header(1))
            click(app_env, endpoint, window, panel(1, "title"))
            input_action(action="text", text="!")
            click(app_env, endpoint, window, header(3))
            click(app_env, endpoint, window, panel(3, "text"))
            input_action(action="key", key="end", control=True)
            input_action(action="text", text="second dirty note")
            editor_bounds = node(app_env, endpoint, window, panel(1, "text"))["bounds"]
            click(app_env, endpoint, window, header(1, "close"))
            dialog = "documents/tabs/control/panels/1/drop/layers/close-confirm"
            wait_for(lambda: any(n["path"] == dialog and n["visible"]
                                 for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"]),
                     "background tab close targeted the wrong note")
            assert node(app_env, endpoint, window, panel(1, "text"))["bounds"] == editor_bounds
            assert not any(n["path"] == "documents/tabs/control/panels/3/drop/layers/close-confirm" for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"])
            input_action(action="key", key="escape")
            wait_for(lambda: not any(n["path"] == dialog for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"]),
                     "Escape did not cancel background close confirmation")

            # A compositor close is a request, not destruction of dirty tabs.
            sway(app_env, '[app_id="dev.ourokit.documents"]', "kill")
            wait_for(lambda: any(n["path"] == dialog for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"]),
                     "native close bypassed dirty-document interception")
            capture(app_env, endpoint, window, "document-unsaved-close.png")
            input_action(action="key", key="escape")
            wait_for(lambda: not any(n["path"] == dialog for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"]),
                     "Escape did not cancel close confirmation")
            # Discarding the first dirty tab advances the native close walk to
            # the next dirty note; cancel there keeps it and the clean tab open.
            sway(app_env, '[app_id="dev.ourokit.documents"]', "kill")
            wait_for(lambda: any(n["path"] == dialog for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"]),
                     "second close request did not prompt")
            click(app_env, endpoint, window, dialog + "/body/actions/discard")
            next_dialog = "documents/tabs/control/panels/3/drop/layers/close-confirm"
            wait_for(lambda: any(n["path"] == next_dialog and n["visible"] for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"]),
                     "window close did not advance to the next dirty note")
            input_action(action="key", key="escape")
            remaining = inspect(app_env, endpoint, window)["windows"][0]["nodes"]
            assert {n["path"] for n in remaining if n["role"] == "tab"} == {header(2), header(3)}
            assert not any(n["role"] == "dialog" for n in remaining)
            assert node(app_env, endpoint, window, panel(3, "text"))["value"] == body + "second dirty note"
            evidence = portal_log.read_text()
            assert evidence.startswith("OpenFile wayland:"), evidence
            # Finish a confirmed window close, then inspect a fresh process.
            # Only saved paths return; the discarded dirty text must not.
            sway(app_env, '[app_id="dev.ourokit.documents"]', "kill")
            wait_for(lambda: any(n["path"] == next_dialog for n in inspect(app_env, endpoint, window)["windows"][0]["nodes"]),
                     'final close did not prompt')
            click(app_env, endpoint, window, next_dialog + '/body/actions/discard')
            assert app.wait(timeout=10) == 0
            session = json.loads((root / 'notes-state/dev.ourokit.documents/session.json').read_text())
            assert session['uris'] == [initial.as_uri(), saved.as_uri()] and session['selected'] == saved.as_uri(), session
            preference = json.loads((root / 'notes-config/dev.ourokit.documents/preferences.json').read_text())
            assert preference['split_position'] != 0.25, preference
            app = subprocess.Popen([str(BINARY), "run", str(ROOT / "examples/documents/app.lua"), "--dev", "--software"],
                                   env=app_env, stdout=subprocess.DEVNULL, stderr=error_file)
            endpoint = development_path(Path(env['XDG_RUNTIME_DIR']), app)
            wait_for(lambda: endpoint.exists(), 'restored Notes endpoint did not appear')
            wait_for(lambda: inspect(app_env, endpoint).get('windows'), 'restored window did not appear')
            wait_for(lambda: node(app_env, endpoint, window, panel(2, 'text'))['value'] == body,
                     'saved note was not restored from disk')
            restored = inspect(app_env, endpoint, window)['windows'][0]['nodes']
            assert len([n for n in restored if n['role']=='tab']) == 2
            assert node(app_env, endpoint, window, panel(1, 'text'))['value'] == 'opened'
            assert node(app_env, endpoint, window, panel(2, 'text'))['visible']
            assert abs(node(app_env, endpoint, window, 'documents/sidebar')['bounds']['width'] - adjusted_sidebar['width']) < 2
            capture(app_env, endpoint, window, 'notes-restored.png')
            print("PASS tabbed documents UI, retained editors, split geometry, portal save/reopen, native close and session restoration")
        finally:
            terminate(app)
            terminate(portal_process)
            error_file.seek(0)
            text = error_file.read()
            assert "panic" not in text and "leaked" not in text, text


def parent_lifetime_test(root, env):
    portal = root / 'cancel-portal.lua'
    portal_log = root / 'cancel-portal.log'
    portal.write_text(portal_source('file:///tmp/unused', 'file:///tmp/unused', portal_log))
    portal_process = subprocess.Popen([str(BINARY), 'run', str(portal), '--headless'], env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    wait_portal(portal_process, env)
    source = root / "parents.lua"
    source.write_text('''local o=require('ouro'); local status=o.signal('ready')
return o.app{id='dev.ourokit.parent-lifetime',run=function() return {windows={
 o.window{id='one',title='one',width=260,height=160,content=function() return o.column{key='root',
  o.button{key='test',label='Export twice',on_press=function()
   local a,ae=o._desktop_parent('one'); assert(a,ae and ae.message)
   local b,be=o._desktop_parent('two'); assert(b,be and be.message)
   assert(a.handle:sub(1,8)=='wayland:' and b.handle:sub(1,8)=='wayland:' and a.handle~=b.handle)
   a:close(); assert(b.handle:sub(1,8)=='wayland:'); b:close(); status:set('closed') end},
  o.button{key='pending',label='Pending chooser',on_press=function() o.desktop.choose_file{parent='one',title='pending'} end},
  o.text{key='status',text=status()}} end},
 o.window{id='two',title='two',width=260,height=160,content=function() return o.text{key='peer',text='peer'} end}}} end}
''')
    app_env = dict(env, WAYLAND_DISPLAY=env["OUROKIT_TEST_WAYLAND_DISPLAY"])
    process = subprocess.Popen([str(BINARY), "run", str(source), "--dev", "--software"], env=app_env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        endpoint = development_path(Path(env["XDG_RUNTIME_DIR"]), process)
        wait_for(lambda: len(inspect(app_env, endpoint).get("windows", [])) == 2, "parent windows unavailable")
        click(app_env, endpoint, "one", "root/test")
        wait_for(lambda: node(app_env, endpoint, "one", "root/status")["label"] == "closed", "two exports did not complete")
        click(app_env, endpoint, 'one', 'root/pending')
        # The portal logs the request on arrival and again just before it
        # replies with the alternate path. Closing the window before the client
        # has that reply makes it close the predicted path instead, which is
        # correct but not what this checks, so give the reply time to arrive.
        wait_for(lambda: portal_log.exists() and portal_log.read_text().startswith('replying '),
                 'pending request never reached portal')
        time.sleep(1)
        sway(app_env, '[app_id="dev.ourokit.parent-lifetime" title="one"]', 'kill')
        wait_for(lambda: portal_log.read_text().startswith('closed '), 'closing owner did not send Request.Close')
        assert portal_log.read_text() == 'closed alternate request', \
            f'closing owner did not close the returned path: {portal_log.read_text()}'
        print("PASS sequential parent exports; window cancellation closes alternate portal request")
    finally:
        terminate(process)
        terminate(portal_process)
        errors = process.stderr.read()
        assert "panic" not in errors and "leaked" not in errors, errors


def drag_test(root, env):
    """Two real Wayland clients, with Sway's private seat providing serials."""
    xml = os.environ.get('OUROKIT_TEST_POINTER_XML') or protocol_xml('wlr-virtual-pointer-unstable-v1.xml', BINARY)
    run('wayland-scanner', 'client-header', str(xml), str(root / 'virtual-pointer.h'), env=env)
    run('wayland-scanner', 'private-code', str(xml), str(root / 'virtual-pointer.c'), env=env)
    flags = shlex.split(run('pkg-config', '--cflags', '--libs', 'wayland-client', env=env).stdout)
    pointer_binary = root / 'pointer'
    run('cc', '-I'+str(root), str(ROOT / 'tests/desktop_pointer.c'), str(root / 'virtual-pointer.c'),
        '-o', str(pointer_binary), *flags, env=env)
    source = root / "drag-source.lua"; target = root / "drag-target.lua"
    source.write_text('''local o=require('ouro'); local s=o.signal('ready')
return o.app{id='dev.ourokit.drag-source',run=function() return {windows={o.window{id='source',title='Drag source',width=300,height=180,content=function()
 return o.column{key='root',o.button{key='drag',label='Drag text',on_press=function() local ok,e=o.start_drag{text='native text'}; s:set(ok and 'started' or e.name) end},
 o.button{key='files',label='Drag files',on_press=function() local ok,e=o.start_drag{uris={'file:///tmp/a%20b','file:///tmp/second'}}; s:set(ok and 'files started' or e.name) end},
 o.text{key='status',text=s()}} end}}} end}
''')
    target.write_text('''local o=require('ouro'); local s=o.signal('waiting')
return o.app{id='dev.ourokit.drag-target',run=function() return {windows={o.window{id='target',title='Drag target',width=360,height=220,content=function()
 return o.box{key='drop',width='fill',height='fill',on_drop_text=function(v) s:set(v) end,
 on_drop_uris=function(v) assert(v=='file:///tmp/a%20b\\nfile:///tmp/second\\n'); s:set('two file URIs') end,
 o.text{key='status',text=s()}} end}}} end}
''')
    app_env = dict(env, WAYLAND_DISPLAY=env["OUROKIT_TEST_WAYLAND_DISPLAY"])
    processes=[]
    pointer = subprocess.Popen([str(pointer_binary)], env=app_env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert select.select([pointer.stdout], [], [], 5)[0], 'virtual pointer startup timed out'
        assert pointer.stdout.readline().strip() == 'ready'
        endpoints = []
        for path in (source, target):
            runtime = root / (path.stem + '-runtime')
            runtime.mkdir(mode=0o700)
            client_env = dict(app_env, XDG_RUNTIME_DIR=str(runtime))
            processes.append(subprocess.Popen([str(BINARY), "run", str(path), "--dev", "--software"], env=client_env,
                                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True))
            endpoints.append(development_path(runtime, processes[-1]))
        source_ep, target_ep = endpoints
        wait_for(lambda: inspect(app_env, source_ep).get("windows") and inspect(app_env, target_ep).get("windows"), "drag clients unavailable")
        # Development clicks have no compositor pointer serial and must be rejected.
        click(app_env, source_ep, "source", "root/drag")
        wait_for(lambda: node(app_env, source_ep, "source", "root/status")["label"] != "ready", "synthetic drag result missing")
        assert node(app_env, source_ep, "source", "root/status")["label"] == "NoPointerInput"

        sway(app_env, '[app_id="dev.ourokit.drag-source"]', "move", "position", "40", "60")
        sway(app_env, '[app_id="dev.ourokit.drag-target"]', "move", "position", "600", "60")
        bounds = node(app_env, source_ep, "source", "root/drag")["bounds"]
        x, y = 40 + int(bounds["x"] + bounds["width"] / 2), 60 + int(bounds["y"] + bounds["height"] / 2)
        sway(app_env, "seat", "seat0", "cursor", "set", str(x), str(y))
        sway(app_env, "seat", "seat0", "cursor", "press", "button1")
        wait_for(lambda: node(app_env, source_ep, "source", "root/status")["label"] == "started",
                 "native press did not start drag: " + str(node(app_env, source_ep, "source", "root/status")))
        sway(app_env, "seat", "seat0", "cursor", "set", "750", "150")
        time.sleep(.15)  # Allow offer/accept/action negotiation before releasing.
        sway(app_env, "seat", "seat0", "cursor", "release", "button1")
        wait_for(lambda: node(app_env, target_ep, "target", "drop/status")["label"] == "native text", "real text drag did not reach second client")
        bounds = node(app_env, source_ep, "source", "root/files")["bounds"]
        x, y = 40 + int(bounds["x"] + bounds["width"] / 2), 60 + int(bounds["y"] + bounds["height"] / 2)
        sway(app_env, "seat", "seat0", "cursor", "set", str(x), str(y))
        sway(app_env, "seat", "seat0", "cursor", "press", "button1")
        wait_for(lambda: node(app_env, source_ep, "source", "root/status")["label"] == "files started", "file drag did not start")
        sway(app_env, "seat", "seat0", "cursor", "set", "750", "150")
        time.sleep(.15)
        sway(app_env, "seat", "seat0", "cursor", "release", "button1")
        wait_for(lambda: node(app_env, target_ep, "target", "drop/status")["label"] == "two file URIs", "file URI drop did not arrive intact")
        print("PASS synthetic drag rejected; real private-seat two-client text and file-URI drags")
        forms_test(root, app_env)
        layer_input_test(root, app_env)
    finally:
        terminate(pointer)
        for process in processes:
            terminate(process)
            errors=process.stderr.read()
            assert process.returncode in (0, 143, -15), (process.returncode, errors)
            assert "panic" not in errors and "leaked" not in errors, errors


def layer_input_test(root, env):
    """Compositor hit testing, not development-injected widget clicks."""
    runtime = root / 'layer-input-runtime'
    runtime.mkdir(mode=0o700)
    env = dict(env, XDG_RUNTIME_DIR=str(runtime))
    source = root / 'layer-input.lua'
    text = '''local o=require('ouro')
local mode=o.signal('default')
local under, card = 0, 0
return o.app {id='dev.ourokit.layer-input', actions={
  Stats={description='Click counts',inputSchema={type='object'},outputSchema={type='object'},
    handler=function() return {under=under,card=card} end},
  SetRegion={description='Change input policy',
    inputSchema={type='object',properties={mode={type='string'}},required={'mode'}},
    outputSchema={type='object'},handler=function(v) mode:set(v.mode) return {} end},
},run=function() return {windows=function()
  local m=mode()
  local windows={o.window{id='under',title='Under notification',width=620,height=420,
    content=function() return o.button{key='under',label='Underlying window',width=600,height=360,
      on_press=function() under=under+1 end} end}}
  if m~='closed' then
    local region=nil
    if m=='card' then region={x=20,y=10,width=400,height=62} end
    if m=='empty' then region={} end
    windows[#windows+1]=o.layer_surface{id='notification',namespace='input-test',output='HEADLESS-1',
      layer='overlay',width=420,height=160,anchors={'top','left'},margins={top=100,left=100},
      background='#00000000',input_region=region,
      content=function() return o.button{key='card',label='Notification card',width=420,height=72,
        on_press=function() card=card+1 end} end}
  end
  return windows
end} end}
'''
    source.write_text(text)
    process = subprocess.Popen([str(BINARY), 'run', str(source), '--dev', '--software'],
                               env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        endpoint = development_path(runtime, process)
        wait_for(lambda: len(inspect(env, endpoint).get('windows', [])) == 2, 'layer input windows unavailable')
        sway(env, '[app_id="dev.ourokit.layer-input"]', 'move', 'position', '0', '0')

        def stats():
            return call(endpoint, 'Stats')['structuredContent']

        def check(x, y, target):
            before = stats()
            # Leave and re-enter so this checks hit testing, not an active grab.
            sway(env, 'seat', 'seat0', 'cursor', 'set', '700', '350')
            sway(env, 'seat', 'seat0', 'cursor', 'set', str(x), str(y))
            sway(env, 'seat', 'seat0', 'cursor', 'press', 'button1')
            sway(env, 'seat', 'seat0', 'cursor', 'release', 'button1')
            expected = dict(before)
            if target:
                expected[target] += 1
                try:
                    wait_for(lambda: stats() == expected, f'click at {x},{y} did not reach {target}')
                except AssertionError as error:
                    raise AssertionError((x, y, target, expected, stats())) from error
            # Also detect unexpected delivery to either window for swallowed clicks.
            time.sleep(.12)
            assert stats() == expected, (x, y, target, expected, stats())

        def policy(mode):
            assert not call(endpoint, 'SetRegion', {'mode': mode}).get('isError')
            wait_for(lambda: len(inspect(env, endpoint).get('windows', [])) == (1 if mode == 'closed' else 2),
                     'layer input policy did not reconcile')
            time.sleep(.12)  # Let the compositor process the surface commit.

        check(140, 140, 'card')
        check(140, 200, None)  # Default still swallows transparent padding.
        policy('card')
        for scale in ('1', '1.5'):
            sway(env, 'output', 'HEADLESS-1', 'scale', scale)
            time.sleep(.2)
            check(140, 140, 'card')
            check(140, 200, 'under')
            check(110, 140, 'under')  # Nonzero x origin, over visible card.
            check(140, 105, 'under')  # Nonzero y origin.
            check(140, 171, 'card')
            check(140, 173, 'under')  # Just outside the bottom edge at both scales.
        source.write_text(text.replace('input_region=region', 'input_region=false'))
        assert call(endpoint, 'runtime.reload').get('isError'), 'invalid region reload accepted'
        check(140, 200, 'under')
        source.write_text(text)
        policy('empty')
        check(140, 140, 'under')  # Empty != nil, even over opaque content.
        policy('default')
        check(140, 200, None)  # nil resets the compositor's input region.
        policy('closed')
        policy('card')
        check(140, 140, 'card')
        check(140, 200, 'under')
        sway(env, 'output', 'HEADLESS-1', 'disable')
        time.sleep(.2)
        sway(env, 'output', 'HEADLESS-1', 'enable')
        time.sleep(.3)
        check(140, 140, 'card')
        check(140, 200, 'under')
        print('PASS layer input: default, rectangle, empty, reset, invalid reload, reopen, output reconnect, 1x/1.5x and edges')
    finally:
        terminate(process)
        sway(env, 'output', 'HEADLESS-1', 'scale', '1')
        errors = process.stderr.read()
        assert process.returncode in (0, 143, -15), (process.returncode, errors)
        assert 'panic' not in errors and 'leaked' not in errors, errors


def forms_test(root, env):
    """Use the real private seat for a dropdown grab; replay other inputs."""
    runtime = root / 'forms-runtime'
    runtime.mkdir(mode=0o700)
    env = dict(env, XDG_RUNTIME_DIR=str(runtime))
    process = subprocess.Popen([str(BINARY), 'run', str(ROOT / 'examples/forms.lua'), '--dev', '--software'],
                               env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        endpoint = development_path(runtime, process)
        wait_for(lambda: inspect(env, endpoint).get('windows'), 'form window unavailable')
        sway(env, '[app_id="dev.ourokit.forms"]', 'move', 'position', '80', '40')

        def input_action(window, retiring=False, **action):
            tree = inspect(env, endpoint, window)['windows'][0]
            body = dict(window=window, token=tree['token'], **action)
            result = subprocess.run([str(BINARY), 'dev', 'input', str(endpoint), json.dumps(body)],
                                    env=env, text=True, capture_output=True)
            # An action may retire its own popup before playback acknowledges
            # the final key/button release. Accept only that exact outcome;
            # callers also assert the committed/cancelled parent state below.
            if result.returncode:
                assert retiring and json.loads(result.stdout)['error']['code'] == 'StaleDevelopmentTarget', result
                assert all(w['window'] != window for w in inspect(env, endpoint)['windows'])

        def key(window, name, retiring=False, **modifiers):
            input_action(window, retiring, action='key', key=name, **modifiers)

        def open_select():
            bounds = node(env, endpoint, 'main', 'root/form/encoding/trigger')['bounds']
            x, y = 80 + int(bounds['x'] + bounds['width']/2), 40 + int(bounds['y'] + bounds['height']/2)
            sway(env, 'seat', 'seat0', 'cursor', 'set', str(x), str(y))
            sway(env, 'seat', 'seat0', 'cursor', 'press', 'button1')
            sway(env, 'seat', 'seat0', 'cursor', 'release', 'button1')
            popup = wait_for(lambda: next((w['window'] for w in inspect(env, endpoint)['windows']
                                         if w['window'].startswith('__ouro_popup_')), None), 'select popup unavailable')
            # This suite replays token-bound inputs against settled geometry.
            # menus_and_toasts.py tests real seat input during the 120ms entry.
            time.sleep(.25)
            return popup

        capture(env, endpoint, 'main', 'forms-native.png')
        popup = open_select()
        capture(env, endpoint, popup, 'forms-select-open.png')
        key(popup, 'arrow_down')
        assert node(env, endpoint, 'main', 'root/form/encoding/trigger')['label'] == 'Encoding: UTF-16'
        key(popup, 'enter', retiring=True)
        wait_for(lambda: len(inspect(env, endpoint)['windows']) == 1, 'select did not close')
        assert node(env, endpoint, 'main', 'root/form/encoding/trigger')['label'] == 'Encoding: ASCII'
        assert node(env, endpoint, 'main', 'root/form/encoding/trigger')['focused']
        popup = open_select()
        key(popup, 'home')
        key(popup, 'escape', retiring=True)
        wait_for(lambda: len(inspect(env, endpoint)['windows']) == 1, 'select cancellation did not close')
        assert node(env, endpoint, 'main', 'root/form/encoding/trigger')['label'] == 'Encoding: ASCII'
        popup = open_select()
        # Pointer selection commits and closes, unlike arrow navigation.
        input_action(popup, retiring=True, action='click', target='motion/surface/theme/scroll/choices/1')
        wait_for(lambda: len(inspect(env, endpoint)['windows']) == 1, 'pointer selection did not close')
        assert node(env, endpoint, 'main', 'root/form/encoding/trigger')['label'] == 'Encoding: UTF-8'

        click(env, endpoint, 'main', 'root/form/reset')
        assert node(env, endpoint, 'main', 'root/confirm/body/actions/cancel')['focused']
        key('main', 'tab', shift=True)
        assert node(env, endpoint, 'main', 'root/confirm/body/actions/reset')['focused']
        capture(env, endpoint, 'main', 'forms-dialog-native.png')
        key('main', 'escape')
        assert node(env, endpoint, 'main', 'root/form/reset')['focused']
        print('PASS native select pointer grab, preview/commit/cancel, modal traversal and focus restoration')
    finally:
        terminate(process)
        errors = process.stderr.read()
        assert process.returncode in (0, 143, -15), (process.returncode, errors)
        assert 'panic' not in errors and 'leaked' not in errors, errors


def focus_test(root, env):
    source = root / 'focus.lua'
    source.write_text('''local ouro=require('ouro')
local function content() return ouro.row {key='workspaces', gap=12,
 ouro.button {key='one', label='1', width=48, border_width=0, background='#304055', hover='#304055'},
 ouro.button {key='two', label='2', width=48, border_width=0, background='#304055', hover='#304055'},
 ouro.button {key='three', label='3', width=48, border_width=0, background='#304055', hover='#304055'},
} end
local function search() return ouro.box {key='shell', width='fill', height=48,
 alignment='center', background='#ffffff', border='#e0e1e6', border_width=1, radius=4,
 ouro.row {key='row', gap=8, cross_alignment='center',
  ouro.box {key='start', width=4},
  ouro.xdg.icon {key='icon',name='system-search-symbolic',theme='Adwaita',width=20,height=20,alt=''},
  ouro.text_input {key='search',default_text='',placeholder='Search apps and commands…',
   autofocus=true,flex=1,padding_x=0,border_width=0,background='#00000000',focus='#ff00ff'},
  ouro.box {key='end',width=4},
 }} end
return ouro.app {id='dev.ourokit.focus-test', run=function() return {windows={
 ouro.window {id='main', title='Keyboard focus', width=260, height=80, content=content},
 ouro.layer_surface {id='panel', namespace='focus-test', layer='top',
   width=260, height=80, keyboard_interactivity='none', content=content},
 ouro.window {id='search',title='Composite search field',width=520,height=90,content=search},
}} end}
''')
    env = dict(env, WAYLAND_DISPLAY=env['OUROKIT_TEST_WAYLAND_DISPLAY'])
    process = subprocess.Popen([str(BINARY), 'run', str(source), '--dev', '--software'],
                               env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        endpoint = development_path(Path(env['XDG_RUNTIME_DIR']), process)
        wait_for(lambda: len(inspect(env, endpoint).get('windows', [])) == 3, 'focus windows unavailable')
        # Capture even without an artifact request: decoded pixels are assertions,
        # not merely optional screenshots. Flat hover colors isolate the ring.
        directory = Path(os.environ.get('OUROKIT_TEST_CAPTURE', root / 'focus-captures')).resolve()
        directory.mkdir(parents=True, exist_ok=True)

        def pixels(window, name):
            tree = inspect(env, endpoint, window)['windows'][0]
            path = directory / name
            run(str(BINARY), 'dev', 'capture', str(endpoint),
                json.dumps(dict(window=window, token=tree['token'])), '--output', str(path), env=env)
            return subprocess.check_output(['magick', str(path), '-depth', '8', 'rgba:-'])

        before = pixels('panel', 'focus-panel-before.png')
        click(env, endpoint, 'panel', 'workspaces/one')
        assert node(env, endpoint, 'panel', 'workspaces/one')['focused']
        assert pixels('panel', 'focus-panel-click.png') == before
        click(env, endpoint, 'main', 'workspaces/one')
        mouse = pixels('main', 'focus-mouse.png')
        tree = inspect(env, endpoint, 'main')['windows'][0]
        run(str(BINARY), 'dev', 'input', str(endpoint), json.dumps(dict(
            window='main', token=tree['token'], action='key', key='tab')), env=env)
        focused = node(env, endpoint, 'main', 'workspaces/two')
        assert focused['focused']
        keyboard = pixels('main', 'focus-keyboard.png')
        width = int(subprocess.check_output(['magick', 'identify', '-format', '%w', str(directory / 'focus-keyboard.png')]))
        changed = [(i // 4 % width, i // 4 // width) for i in range(0, len(mouse), 4)
                   if mouse[i:i+4] != keyboard[i:i+4]]
        bounds = focused['bounds']
        x, y, w, h = (int(bounds[k]) for k in ('x', 'y', 'width', 'height'))
        assert changed and all(x <= px < x+w and y <= py < y+h for px, py in changed), changed
        # All four edges must remain visible, not merely be clipped away.
        for px, py in ((x+w//2, y), (x+w//2, y+h-1), (x, y+h//2), (x+w-1, y+h//2)):
            i = (py * width + px) * 4
            assert keyboard[i:i+4] != mouse[i:i+4], (px, py)
        click(env, endpoint, 'main', 'workspaces/one')
        assert pixels('main', 'focus-mouse-restored.png') == mouse
        print('PASS native focus: mouse unchanged; keyboard ring stays inside bounds with all four edges; click removes it')
        assert node(env, endpoint, 'search', 'shell/row/search')['focused']
        search = pixels('search', 'borderless-search-focused.png')
        # A deliberately distinctive focus color must never paint on this
        # borderless editor inside the application-owned search-field border.
        assert not any(search[i:i+4] == bytes((255, 0, 255, 255)) for i in range(0, len(search), 4))
        print('PASS native borderless search retains autofocus without drawing an inner ring')
    finally:
        terminate(process)
        errors = process.stderr.read()
        assert process.returncode in (0, 143, -15), (process.returncode, errors)
        assert 'panic' not in errors and 'leaked' not in errors, errors


def systemd_source(log):
    """A private-bus stand-in for systemd's StartTransientUnit; records, never runs."""
    return f'''local o=require('ouro'); local b=assert(o.dbus.connect('session')); local count=0
local x <close> = assert(b:export{{path='/org/freedesktop/systemd1',interface='org.freedesktop.systemd1.Manager',methods={{
 StartTransientUnit={{input='ssa(sv)a(sa(sv))',output='o',handler=function(r)
  local unit={{name=r.args[1],mode=r.args[2]}}
  for _,p in ipairs(r.args[3]) do
   if p[1]=='ExecStart' then local e=p[2].value[1]; unit.path=e[1]; unit.argv=e[2]
   else unit[p[1]]=p[2].value end
  end
  count=count+1
  assert(o.files.write({json.dumps(log.as_uri())}..'.'..count,o.json.encode(unit)))
  return {{'/org/freedesktop/systemd1/job/'..count}}
 end}}}},signals={{}}}})
local n <close> = assert(b:own_name('org.freedesktop.systemd1'))
while true do o.sleep(1000) end
'''


def launcher_test(root, env):
    """The overlay surface exists only while the launcher chart is open."""
    data, share = root / 'launcher-data', root / 'launcher-share'
    (data / 'applications').mkdir(parents=True)
    share.mkdir()
    (share / 'icons').symlink_to('/usr/share/icons')
    entries = {
        'alpha.desktop': 'Name=Alpha Editor\nComment=Edit alpha files\nIcon=accessories-text-editor\nExec=alpha-editor --new-window %F\n',
        'beta.desktop': 'Name=Beta Terminal\nIcon=utilities-terminal\nKeywords=shell;\nExec=beta-term\n',
        'gamma.desktop': 'Name=Gamma Viewer\nIcon=image-x-generic\nExec=gamma\nPath=/tmp\n',
        'hidden.desktop': 'Name=Hidden Helper\nExec=hidden\nNoDisplay=true\n',
    }
    for name, body in entries.items():
        (data / 'applications' / name).write_text('[Desktop Entry]\nType=Application\n' + body)
    log = root / 'systemd.log'
    fake = root / 'systemd.lua'
    fake.write_text(systemd_source(log))
    units = lambda: sorted(root.glob('systemd.log.*'), key=lambda p: int(p.suffix[1:]))

    def start_systemd():
        process = subprocess.Popen([str(BINARY), 'run', str(fake), '--headless'], env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        def owned():
            assert process.poll() is None, process.stderr.read()
            # NameHasOwner, unlike introspection, never bus-activates a real systemd.
            reply = subprocess.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
                                    '--object-path', '/org/freedesktop/DBus', '--method',
                                    'org.freedesktop.DBus.NameHasOwner', 'org.freedesktop.systemd1'],
                                   env=env, capture_output=True, text=True)
            return reply.stdout.strip() == '(true,)'
        wait_for(owned, 'fake systemd did not own its name')
        return process

    app_env = dict(env, WAYLAND_DISPLAY=env['OUROKIT_TEST_WAYLAND_DISPLAY'],
                   XDG_DATA_HOME=str(data), XDG_DATA_DIRS=str(share))
    manifest = str(ROOT / 'examples/launcher/ouro.json')
    systemd = start_systemd()
    app = subprocess.Popen([str(BINARY), 'run', manifest, '--dev', '--software'], env=app_env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    status = 'scrim/panel/body/status'
    search = 'scrim/panel/body/search'

    def windows():
        return [w['window'] for w in inspect(app_env, endpoint).get('windows', [])]

    def label(path):
        return node(app_env, endpoint, 'launcher', path)['label']

    def send(**action):
        # Icons finish loading asynchronously and refresh the token; retry when stale.
        for _ in range(5):
            tree = inspect(app_env, endpoint, 'launcher')['windows'][0]
            result = run(str(BINARY), 'dev', 'input', str(endpoint), json.dumps(
                dict(window='launcher', token=tree['token'], **action)), env=app_env, ok=None)
            if result.returncode == 0:
                return
            assert 'StaleDevelopmentTarget' in result.stdout, result.stdout
            # Input that retires its own surface (Escape) also reports stale.
            if 'launcher' not in windows():
                return
        raise AssertionError('launcher input stayed stale')

    key = lambda name: send(action='key', key=name)
    type_text = lambda text: send(action='text', text=text)

    def opened(expected='3 applications'):
        wait_for(lambda: 'launcher' in windows(), 'launcher surface did not appear')
        wait_for(lambda: label(status) == expected, f'launcher never showed {expected!r}')

    def closed():
        wait_for(lambda: windows() == [], 'launcher surface was not retired: ' + (label(status) if windows() else ''))

    try:
        endpoint = development_path(Path(env['XDG_RUNTIME_DIR']), app)
        # The first launch opens: activation arrives before run, run sends OPEN.
        opened()
        assert node(app_env, endpoint, 'launcher', search)['focused']
        capture(app_env, endpoint, 'launcher', 'launcher-open.png')

        # Search, then Enter launches through prepare_launch and closes.
        type_text('ga')
        wait_for(lambda: label(status) == '1 application', 'query did not filter')
        key('enter')
        closed()
        unit = json.loads(wait_for(units, 'no unit started')[0].read_text())
        assert unit['name'].startswith('app-ourokit-gamma-') and unit['name'].endswith('.service'), unit
        assert unit['path'] == '/usr/bin/env' and unit['argv'] == ['env', '--', 'gamma'], unit
        assert unit['WorkingDirectory'] == '/tmp' and unit['mode'] == 'fail' and unit['Type'] == 'exec', unit

        # A declared action toggles it back; the query starts empty again.
        assert call(endpoint, 'Toggle')['structuredContent'] == {'open': True}
        opened()
        assert node(app_env, endpoint, 'launcher', search)['value'] == ''
        # Up wraps to the last row, Down twice lands on the second.
        for name in ('arrow_up', 'arrow_down', 'arrow_down'):
            key(name)
        key('enter')
        closed()
        assert json.loads(wait_for(lambda: units()[1:], 'second unit missing')[0].read_text())['argv'] == ['env', '--', 'beta-term']

        # Escape closes without launching.
        call(endpoint, 'Open')
        opened()
        key('escape')
        closed()
        assert len(units()) == 2

        # Without systemd the launch fails; the launcher stays open and says so.
        terminate(systemd)
        call(endpoint, 'Toggle')
        opened()
        type_text('alpha')
        wait_for(lambda: label(status) == '1 application', 'alpha query did not filter')
        key('enter')
        wait_for(lambda: label(status).startswith('Could not launch: '), 'launch failure not shown')
        assert windows() == ['launcher']
        capture(app_env, endpoint, 'launcher', 'launcher-launch-error.png')
        assert call(endpoint, 'Close')['structuredContent']['open'] is False
        closed()
        print('PASS launcher: layer surface follows the chart; search, keyboard selection, launch, Escape and launch failure')
    finally:
        terminate(app)
        terminate(systemd)
        errors = app.stderr.read()
        assert 'panic' not in errors and 'leaked' not in errors, errors

    # Production: single instance, toggled by activation like a compositor key binding.
    def pixel(x=640, y=360):
        shot = root / 'launcher-screen.png'
        run('grim', '-t', 'png', '-l', '0', str(shot), env=app_env)
        return tuple(subprocess.check_output(['magick', str(shot), '-crop', f'1x1+{x}+{y}', '-depth', '8', 'rgb:-']))
    center = lambda: sum(pixel()) / 3
    # The selected first row is tinted with the accent: the scan finished.
    selected_row = lambda: (lambda r, g, b: b > r + 4 and r > 200)(*pixel(640, 213))

    app = subprocess.Popen([str(BINARY), 'run', manifest, '--software'], env=app_env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        wait_for(lambda: center() > 200, 'launcher panel never covered the output')
        wait_for(selected_row, 'production launcher never listed applications')
        destination = os.environ.get('OUROKIT_TEST_CAPTURE')
        if destination:
            directory = Path(destination).resolve()
            directory = (directory.parent / 'desktop') if directory.suffix else directory
            directory.mkdir(parents=True, exist_ok=True)
            shutil.copy(root / 'launcher-screen.png', directory / 'launcher-sway-output.png')
        run(str(BINARY), 'activate', 'dev.ourokit.launcher', env=app_env)
        wait_for(lambda: center() < 100, 'activation did not hide the launcher')
        run(str(BINARY), 'activate', 'dev.ourokit.launcher', env=app_env)
        wait_for(lambda: center() > 200, 'activation did not show the launcher again')
        # A second `run` forwards to the owner and exits; that toggles too.
        run(str(BINARY), 'run', manifest, '--software', env=app_env)
        wait_for(lambda: center() < 100, 'forwarded launch did not hide the launcher')
        assert app.poll() is None, 'hidden launcher must keep running'
        print('PASS launcher: single instance toggles on activation; hidden keeps the process alive')
    finally:
        terminate(app)
        errors = app.stderr.read()
        assert 'panic' not in errors and 'leaked' not in errors, errors


def launcher_surface_failure_test(root, env):
    """A launcher whose surface cannot be shown returns to hidden with the reason."""
    app_env = dict(env, WAYLAND_DISPLAY=env['OUROKIT_TEST_WAYLAND_DISPLAY'])
    source = (ROOT / 'examples/launcher/view.lua').read_text()
    guard = 'if not launcher:matches("open") then return {} end\n'
    breaks = [
        # Rejected while the last good (empty) list is kept.
        ('declaration', source.replace('background = "#10141c99"', 'background = "#zz"'), 'InvalidThemeColor', False),
        # The content function throws on its first build: the Lua message arrives.
        ('content', source.replace('function M.content(launcher)\n', 'function M.content(launcher)\n    error("broken view")\n'),
         'broken view', False),
        # windows() itself throws; run's `send = launcher` binds the declaration.
        ('windows', source.replace(guard, guard + '      error("broken windows")\n'), 'broken windows', False),
        # A retained layer surface may not change its namespace. Typing changes
        # it here; the last valid surface stays until the chart hides it.
        ('transition', source.replace('namespace = "ourokit-launcher"',
                                      'namespace = launcher:context().query == "" and "ourokit-launcher" or "ourokit-other"'),
         'LayerSurfaceNamespaceChanged', True),
    ]
    for reason, view, detail, typed in breaks:
        assert view != source, reason
        directory = root / f'launcher-{reason}'
        directory.mkdir()
        for name in ('app.lua', 'charts.lua', 'model.lua', 'ouro.json'):
            shutil.copy(ROOT / 'examples/launcher' / name, directory / name)
        (directory / 'view.lua').write_text(view)
        app = subprocess.Popen([str(BINARY), 'run', str(directory / 'ouro.json'), '--dev', '--software'], env=app_env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            endpoint = development_path(Path(env['XDG_RUNTIME_DIR']), app)
            state = lambda: call(endpoint, 'State')['structuredContent']
            for attempt in range(2):  # it can be opened again, and fails again
                if attempt:
                    assert call(endpoint, 'Open')['structuredContent']['open'] is True
                if typed:
                    wait_for(lambda: 'launcher' in [w['window'] for w in inspect(app_env, endpoint).get('windows', [])],
                             'transition launcher never opened')
                    for _ in range(5):
                        # The keystroke can retire its own surface before replying.
                        if 'launcher' not in [w['window'] for w in inspect(app_env, endpoint).get('windows', [])]:
                            break
                        tree = inspect(app_env, endpoint, 'launcher')['windows'][0]
                        if run(str(BINARY), 'dev', 'input', str(endpoint), json.dumps(
                                {'window': 'launcher', 'token': tree['token'], 'action': 'text', 'text': 'x'}),
                                env=app_env, ok=None).returncode == 0:
                            break
                wait_for(lambda: state()['open'] is False and f'({reason})' in state().get('error', ''),
                         f'{reason} failure never reached the chart')
                assert detail in state()['error'], state()
                wait_for(lambda: inspect(app_env, endpoint).get('windows', []) == [], 'no surface may remain')
            assert app.poll() is None, 'a failed bound surface must not exit the app'
            print(f'PASS launcher surface {reason} failure: hidden with "{state()["error"]}"')
        finally:
            terminate(app)
            errors = app.stderr.read()
            assert 'panic' not in errors and 'leaked' not in errors, errors


def unbound_transition_test(root, env):
    """An unbound surface's illegal transition is logged; the last valid set stays."""
    source = root / 'unbound-transition.lua'
    source.write_text('''local o=require('ouro'); local machine=o.machine
local flip=machine.create{id='flip',initial='window',events={FLIP={}},states={window={on={FLIP='layer'}},layer={}}}
local actor=flip:actor()
return o.app{id='dev.ourokit.unbound-transition',
 actions=machine.actions(actor,{Flip={event='FLIP',description='flip'}}),
 run=function() actor:start()
  return {windows=function()
   local content=function() return o.text{key='t',text='still here'} end
   if actor:matches('window') then return {o.window{id='main',title='Main',width=240,height=120,content=content}} end
   return {o.layer_surface{id='main',namespace='flip',layer='top',width=240,height=120,content=content}}
  end} end}
''')
    app_env = dict(env, WAYLAND_DISPLAY=env['OUROKIT_TEST_WAYLAND_DISPLAY'])
    app = subprocess.Popen([str(BINARY), 'run', str(source), '--dev', '--software'], env=app_env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        endpoint = development_path(Path(env['XDG_RUNTIME_DIR']), app, windows=('main',))
        call(endpoint, 'Flip')
        time.sleep(.5)
        assert app.poll() is None, 'a role change must not crash the app'
        assert [w['window'] for w in inspect(app_env, endpoint)['windows']] == ['main']
        assert node(app_env, endpoint, 'main', 't')['label'] == 'still here'
        print('PASS unbound role change: logged, last valid window kept, app alive')
    finally:
        terminate(app)
        errors = app.stderr.read()
        assert 'window declaration failed: WindowRoleChanged' in errors, errors
        assert 'panic' not in errors and 'leaked' not in errors, errors


def surface_events_test(root, env):
    """A window bound with send = actor reports mapped, close_requested and closed."""
    source = root / 'surface-probe.lua'
    source.write_text('''local o=require('ouro'); local machine=o.machine; local assign=machine.assign
local probe=machine.create{id='probe',initial='closed',context={log={}},events={OPEN={},CLOSE={}},
 actions={log=assign{log=function(c,e)
  local l={} for i,v in ipairs(c.log) do l[i]=v end
  l[#l+1]=e.type..(e.width and (':'..e.width..'x'..e.height) or '') return l end}},
 on={['surface.*']={actions='log'}},
 states={closed={on={OPEN='open'}},
  open={on={CLOSE='closed',['surface.close_requested.probe']={target='closed',actions='log'}}}}}
local actor=probe:actor()
return o.app{id='dev.ourokit.surface-probe',
 actions=machine.actions(actor,{
  Open={event='OPEN',description='open'},
  Log={description='log',output=function(s) return {log=machine.plain(s.context.log),open=machine.matches(s,'open')} end,
   output_schema={type='object',properties={log={type='array',items={type='string'}},open={type='boolean'}}}}}),
 run=function() actor:start(); actor:send('OPEN')
  return {windows=function()
   if not actor:matches('open') then return {} end
   return {o.window{id='probe',title='Probe',width=320,height=200,send=actor,content=function() return o.text{key='t',text='probe'} end}}
  end} end}
''')
    app_env = dict(env, WAYLAND_DISPLAY=env['OUROKIT_TEST_WAYLAND_DISPLAY'])
    app = subprocess.Popen([str(BINARY), 'run', str(source), '--dev', '--software'], env=app_env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        endpoint = development_path(Path(env['XDG_RUNTIME_DIR']), app)
        log = lambda: call(endpoint, 'Log')['structuredContent']
        mapped = wait_for(lambda: [e for e in log()['log'] if e.startswith('surface.mapped.probe:')], 'mapped never arrived')
        assert mapped == ['surface.mapped.probe:320x200'], mapped
        # The compositor's close request goes to the chart, which closes.
        sway(app_env, '[app_id="dev.ourokit.surface-probe"]', 'kill')
        wait_for(lambda: log()['open'] is False, 'close request did not reach the chart')
        wait_for(lambda: log()['log'][-1] == 'surface.closed.probe', 'closed never arrived after teardown')
        assert inspect(app_env, endpoint).get('windows', []) == []
        call(endpoint, 'Open')
        wait_for(lambda: log()['log'].count('surface.mapped.probe:320x200') == 2, 'reopened surface did not map')
        assert log()['log'] == ['surface.mapped.probe:320x200', 'surface.close_requested.probe', 'surface.closed.probe',
                                'surface.mapped.probe:320x200'], log()
        print('PASS surface events: mapped with size, close_requested decided by the chart, closed after teardown, reopen')
    finally:
        terminate(app)
        errors = app.stderr.read()
        assert 'panic' not in errors and 'leaked' not in errors, errors


def workspaces_test(root, env):
    """ouro.shell.workspaces.watch() feeds a chart from ext-workspace-v1 done batches."""
    from workspace_proxy import WorkspaceProxy
    upstream = env['OUROKIT_TEST_WAYLAND_DISPLAY']
    proxy = WorkspaceProxy(upstream, str(root / 'wayland-workspaces'))
    app_env = dict(env, WAYLAND_DISPLAY=proxy.path)
    source = root / 'workspace-bar.lua'
    source.write_text('''local o=require('ouro'); local machine=o.machine; local assign=machine.assign
local bar=machine.create{id='bar',initial='watching',context={available=false,workspaces={},updates=0},
 events={WORKSPACES={snapshot='table'},ACTIVATE={handle='string'},PAUSE={},RESUME={}},
 actions={store=assign(function(c,e) return {available=e.snapshot.available,workspaces=e.snapshot.workspaces,updates=c.updates+1} end),
  activate=function(_,e) o.shell.workspaces.activate(e.handle) end},
 actors={watch=function(_,send)
  local watch <close> = o.shell.workspaces.watch()
  while true do send{type='WORKSPACES',snapshot=watch:next()} end
 end},
 states={
  watching={invoke={src='watch'},on={WORKSPACES={actions='store'},ACTIVATE={actions='activate'},PAUSE='paused'}},
  paused={on={RESUME='watching',ACTIVATE={actions='activate'}}}}}
local actor=bar:actor()
local function state(s)
 local names={} for i,w in ipairs(s.context.workspaces) do names[i]=w.name..(w.active and '*' or '') end
 return {available=s.context.available,updates=s.context.updates,names=table.concat(names,' '),watching=machine.matches(s,'watching')}
end
local schema={type='object',properties={available={type='boolean'},updates={type='integer'},names={type='string'},watching={type='boolean'}}}
return o.app{id='dev.ourokit.workspace-bar',
 actions=machine.actions(actor,{State={description='state',output=state,output_schema=schema},
  Pause={event='PAUSE',description='pause'},Resume={event='RESUME',description='resume'}}),
 run=function() actor:start()
  return {windows={o.layer_surface{id='bar',namespace='bar',layer='top',width=0,height=40,anchors={'top','left','right'},
   content=function()
    local c=actor:context(); local children={}
    for i,w in ipairs(c.workspaces) do
     children[#children+1]=o.button{key='w'..i,label=w.name..(w.active and ' *' or ''),
      on_press=function() actor:send{type='ACTIVATE',handle=w.handle} end}
    end
    return o.row{key='workspaces',gap=8,children=children}
   end}}}
 end}
''')
    app = subprocess.Popen([str(BINARY), 'run', str(source), '--dev', '--software'], env=app_env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        endpoint = development_path(Path(env['XDG_RUNTIME_DIR']), app, windows=('bar',))
        state = lambda: call(endpoint, 'State')['structuredContent']
        wait_for(lambda: state()['names'] == 'One* Two Three', 'first workspace snapshot never reached the chart')
        assert state()['available'] and proxy.binds == 1, (state(), proxy.binds)
        # A click sends ACTIVATE; the request goes out at the safe point, the
        # compositor answers with a done batch, the watcher wakes the chart.
        click(app_env, endpoint, 'bar', 'workspaces/w2')
        wait_for(lambda: state()['names'] == 'One Two* Three', 'activation never came back as a snapshot')
        assert proxy.activations == ['Two'], proxy.activations
        wait_for(lambda: node(app_env, endpoint, 'bar', 'workspaces/w2')['label'] == 'Two *', 'bar label not updated')
        proxy.rename(2, 'Mail')
        wait_for(lambda: state()['names'] == 'One Two* Mail', 'rename never reached the chart')
        # Leaving the watching state closes the watcher with its scope.
        updates = state()['updates']
        call(endpoint, 'Pause')
        proxy.rename(0, 'Web')
        time.sleep(.3)
        assert state()['updates'] == updates and state()['names'] == 'One Two* Mail', state()
        # A new watcher starts from the current snapshot.
        call(endpoint, 'Resume')
        wait_for(lambda: state()['names'] == 'Web Two* Mail', 'resumed watcher did not see the current snapshot')
        print('PASS workspaces: watch() streams done batches into a chart; activation round trip; closing with the state stops it')
    finally:
        terminate(app)
        errors = app.stderr.read()
        assert 'panic' not in errors and 'leaked' not in errors, errors

    # Nobody watches: the manager is never bound.
    quiet = root / 'no-workspaces.lua'
    quiet.write_text("local o=require('ouro') return o.app{id='dev.ourokit.no-workspaces',run=function() "
                     "return {windows={o.window{id='main',title='Quiet',width=200,height=100,"
                     "content=function() return o.text{key='t',text='quiet'} end}}} end}")
    binds = proxy.binds
    app = subprocess.Popen([str(BINARY), 'run', str(quiet), '--dev', '--software'], env=app_env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    try:
        endpoint = development_path(Path(env['XDG_RUNTIME_DIR']), app, windows=('main',))
        time.sleep(.3)
        assert proxy.binds == binds, 'an app that never watches must not bind ext-workspace'
        print('PASS workspaces: an app that never watches never binds the protocol')
    finally:
        terminate(app)
        proxy.close()


def suite(root, env):
    assert BINARY.is_file(), f"missing {BINARY}; wait for /tmp/ouro-desktop-build.log then build"
    focus_test(root, env)
    workspaces_test(root, env)
    surface_events_test(root, env)
    launcher_test(root, env)
    launcher_surface_failure_test(root, env)
    unbound_transition_test(root, env)
    document_test(root, env)
    parent_lifetime_test(root, env)
    drag_test(root, env)


def main():
    required = ("sway", "swaymsg", "dbus-run-session")
    assert not [x for x in required if not shutil.which(x)], "missing native test dependencies"
    if os.environ.get("OUROKIT_TEST_WAYLAND_DISPLAY"):
        with tempfile.TemporaryDirectory(prefix="ouro-desktop-native-") as temporary:
            env = dict(os.environ, WAYLAND_DISPLAY=os.environ["OUROKIT_TEST_WAYLAND_DISPLAY"])
            # verify_development does not export SWAYSOCK, derive its private IPC socket.
            sockets = list(Path(env["XDG_RUNTIME_DIR"]).glob("sway-ipc.*.sock"))
            assert len(sockets) == 1
            env["SWAYSOCK"] = str(sockets[0])
            suite(Path(temporary), env)
        return
    # Standalone mode mirrors verify_development.py, but runs only this suite.
    with tempfile.TemporaryDirectory(prefix="ouro-desktop-compositor-") as temporary:
        runtime = Path(temporary)
        config = runtime / "sway.conf"
        config.write_text("xwayland disable\noutput * mode 1280x720 scale 1\n"
                          "default_border none\nfor_window [app_id=\".*\"] floating enable\n")
        env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS="headless",
                   WLR_RENDERER="pixman", WLR_LIBINPUT_NO_DEVICES="1", WLR_HEADLESS_OUTPUTS="1")
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "SWAYSOCK", "DBUS_SESSION_BUS_ADDRESS"):
            env.pop(key, None)
        compositor = subprocess.Popen(["sway", "--config", str(config)], env=env,
                                      stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            def ready():
                displays = [p for p in runtime.glob("wayland-*") if p.is_socket()]
                sockets = list(runtime.glob("sway-ipc.*.sock"))
                if len(displays) == len(sockets) == 1:
                    return displays[0], sockets[0]
            display, socket = wait_for(ready, "private Sway did not become ready", 10)
            env.update(OUROKIT_TEST_WAYLAND_DISPLAY=str(display), SWAYSOCK=str(socket),
                       OUROKIT_TEST_BINARY=str(BINARY))
            # The portal and app must share one private session bus.
            result = subprocess.run(["dbus-run-session", "--", sys.executable, __file__], env=env)
            assert result.returncode == 0, result.returncode
        finally:
            terminate(compositor)


if __name__ == "__main__":
    main()
