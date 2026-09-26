#!/usr/bin/env python3
"""Standard D-Bus activation and isolated development, using a real private bus.

Run after zig build: python3 tests/desktop_activation.py
Requires dbus-run-session and gdbus. No MCP bridge or compositor required.
Set OUROKIT_TEST_WAYLAND_DISPLAY for native UI/token coverage on a compositor
advertising xdg_activation_v1.
"""
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time

from application_services import BINARY, call, development_path, request

APP = 'org.example.Ourokit-Test'
OBJECT = '/org/example/Ourokit_Test'
INTERFACE = 'org.freedesktop.Application'


def command(env, *args, succeeds=True):
    result = subprocess.run([str(BINARY), *args], env=env, capture_output=True, timeout=10)
    assert (result.returncode == 0) == succeeds, (args, result.returncode, result.stdout, result.stderr)
    assert b'panic' not in result.stderr and b'leaked' not in result.stderr, result.stderr
    return result


def dbus(env, member, *args, succeeds=True, app=APP, path=OBJECT):
    result = subprocess.run(['gdbus', 'call', '--session', '--dest', app,
                             '--object-path', path, '--method', INTERFACE + '.' + member, *args],
                            env=env, capture_output=True, timeout=10)
    assert (result.returncode == 0) == succeeds, (member, result.stdout, result.stderr)
    return result


def line(process):
    assert select.select([process.stdout], [], [], 8)[0], 'desktop hook did not run'
    data = process.stdout.readline()
    assert data, process.stderr.read()
    return json.loads(data)


def source(single=True):
    return f'''local o = require('ouro')
local function emit(value) o.stdout.write(o.json.encode(value) .. '\\n') end
return o.app {{ id='{APP}', single_instance={str(single).lower()},
  activate=function(data) emit({{kind='activate', token=data['activation-token'], startup=data['desktop-startup-id']}}) end,
  open=function(uris, data) emit({{kind='open', uris=uris, token=data['activation-token']}}) end,
  activate_action=function(name, parameters, data)
    if name == 'Reject' then return nil, {{name='org.example.Rejected', message='intentional rejection'}} end
    emit({{kind='action', name=name, count=#parameters, value=parameters[1] and parameters[1].value, token=data['activation-token']}})
  end,
  run=function() error('headless test invoked UI factory') end,
}}
'''


def session(root):
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    env = dict(os.environ, XDG_RUNTIME_DIR=str(root), WAYLAND_DISPLAY='deliberately-unavailable')
    app = root / 'app.lua'
    app.write_text(source())
    production = subprocess.Popen([str(BINARY), 'run', str(app), '--headless'], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    devs = []
    try:
        assert line(production) == {'kind': 'activate'}
        assert not (root / 'ourokit').exists(), 'ordinary application started an MCP server'
        activation_env = dict(env, XDG_ACTIVATION_TOKEN='fresh-token-71', DESKTOP_STARTUP_ID='startup-23')
        command(activation_env, 'activate', APP)
        assert line(production) == {'kind': 'activate', 'token': 'fresh-token-71', 'startup': 'startup-23'}
        # Launching a second ordinary copy follows application policy, not actions.
        command(activation_env, 'run', str(app), '--headless', '--', 'file:///tmp/a%20b', 'https://example.test/document')
        assert line(production) == {'kind': 'open', 'uris': ['file:///tmp/a%20b', 'https://example.test/document'], 'token': 'fresh-token-71'}
        command(env, 'activate', APP, '--action', 'NewWindow')
        assert line(production) == {'kind': 'action', 'name': 'NewWindow', 'count': 0}
        dbus(env, 'ActivateAction', 'Named', "[<int32 37>, <'second'>]", "{'activation-token': <'dbus-token'>}")
        assert line(production) == {'kind': 'action', 'name': 'Named', 'count': 2, 'value': 37, 'token': 'dbus-token'}
        rejected = dbus(env, 'ActivateAction', 'Reject', '[]', '{}', succeeds=False)
        assert b'org.example.Rejected' in rejected.stderr
        dbus(env, 'Activate', "{'activation-token': <int32 7>}", succeeds=False)
        # Introspection verifies the actual exported standard wire signatures.
        xml = subprocess.check_output(['gdbus', 'introspect', '--session', '--dest', APP,
                                       '--object-path', OBJECT, '--xml'], env=env)
        assert b'org.freedesktop.Application' in xml and b'type="av"' in xml and b'type="as"' in xml
        print('PASS: Activate/Open/ActivateAction, typed variants, errors, standard path and platform tokens, single-instance forwarding without MCP')

        paths = []
        for _ in range(2):
            p = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--headless'], env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            devs.append(p)
            assert line(p) == {'kind': 'activate'}
            paths.append(development_path(root, p, paths))
        assert paths[0] != paths[1]
        assert not select.select([production.stdout], [], [], .15)[0], 'development activated production'
        for path in paths:
            assert path.stat().st_mode & 0o777 == 0o600
            assert {t['name'] for t in request(path, 'tools/list')['result']['tools']} == {
                'runtime.status', 'runtime.reload', 'runtime.inspect', 'runtime.input',
                'runtime.capture', 'runtime.metrics', 'runtime.diagnostics'}
            command(env, 'dev', 'status', str(path))
        # No actions at all, and action enablement can change on reload.
        app.write_text(source().replace("  run=function()", "  actions={}, run=function()"))
        command(env, 'dev', 'reload', str(paths[0]))
        assert call(paths[0], 'runtime.status')['structuredContent']['activeGeneration'] == 2
        assert call(paths[1], 'runtime.status')['structuredContent']['activeGeneration'] == 1
        app.write_text(source())
        command(env, 'dev', 'reload', str(paths[0]))
        assert call(paths[0], 'runtime.status')['structuredContent']['activeGeneration'] == 3
        for target in (APP, str(root / 'ourokit/apps' / APP)):
            command(env, 'dev', 'status', target, succeeds=False)
            command(env, 'dev', 'reload', target, succeeds=False)
        assert not (root / 'ourokit/mcp').exists()
        assert not (root / 'ourokit/apps').exists()
        print('PASS: two private dev copies coexist with production, no actions required, isolated reloads and no production discovery')
        for p in devs:
            p.terminate()
            assert p.wait(timeout=8) == 143
        devs.clear()
        assert all(not path.exists() for path in paths)
        # Opting out of single-instance must launch a fresh application too.
        app.write_text(source(False))
        p = subprocess.Popen([str(BINARY), 'run', str(app), '--headless'], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        devs.append(p)
        assert line(p) == {'kind': 'activate'}
        assert not select.select([production.stdout], [], [], .15)[0]
        print('PASS: application-controlled multi-instance policy and endpoint cleanup')
    finally:
        for p in [*devs, production]:
            if p.poll() is None:
                p.terminate()
            p.wait(timeout=8)
            errors = p.stderr.read()
            assert b'panic' not in errors and b'leaked' not in errors, errors

    # The bus starts this service through the standard .service convention.
    auto_id = 'org.example.OurokitAuto'
    auto = root / 'auto.lua'
    auto.write_text(f'''local o=require('ouro')
return o.app {{id='{auto_id}', single_instance=true,
  activate_action=function(name)
    if name == 'Probe' then return nil, {{name='org.example.AutoStarted', message='standard service activation'}} end
    if name == 'Stop' then o.spawn(function() o.sleep(20); o.exit(0) end) end
  end}}
''')
    service = root / 'data/dbus-1/services' / (auto_id + '.service')
    service.write_text(f'[D-BUS Service]\nName={auto_id}\nExec={BINARY} run {auto} --headless --dbus-activated\n')
    result = dbus(env, 'ActivateAction', 'Probe', '[]', '{}', succeeds=False,
                  app=auto_id, path='/org/example/OurokitAuto')
    assert b'org.example.AutoStarted' in result.stderr, result.stderr
    dbus(env, 'ActivateAction', 'Stop', '[]', '{}', app=auto_id, path='/org/example/OurokitAuto')
    time.sleep(.1)
    print('PASS: real D-Bus service auto-launch and delayed desktop request delivery')
    if os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY'):
        native(root, env)


def native(root, env):
    app_id = 'org.example.NativeActivation'
    object_path = '/org/example/NativeActivation'
    app = root / 'native.lua'
    app.write_text(f'''local o=require('ouro')
local function emit(kind) o.stdout.write(o.json.encode({{kind=kind}}) .. '\\n') end
return o.app {{id='{app_id}', single_instance=true,
  activate=function() emit('activate') end,
  run=function()
    emit('ui')
    return {{windows={{o.window {{id='main',title='Standard activation',width=320,height=160,
      content=function() return o.text {{key='label',text='Standard desktop activation'}} end}}}}}}
  end}}
''')
    native_env = dict(env, WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'], WAYLAND_DEBUG='client')
    log = root / 'native.log'
    with log.open('wb') as errors:
        process = subprocess.Popen([str(BINARY), 'run', str(app), '--software', '--dbus-activated'],
                                   env=native_env, stdout=subprocess.PIPE, stderr=errors, bufsize=0)
        try:
            # Wait for the name without triggering activation or an app hook.
            for _ in range(100):
                probe = subprocess.run(['gdbus', 'introspect', '--session', '--dest', app_id,
                                        '--object-path', object_path], env=env, capture_output=True)
                if probe.returncode == 0:
                    break
                assert process.poll() is None, log.read_text()
                time.sleep(.02)
            else:
                raise AssertionError(log.read_text())
            assert not select.select([process.stdout], [], [], .1)[0], 'bus startup synthesized Activate'
            assert 'wl_surface' not in log.read_text(), 'bus startup created UI prematurely'
            dbus(env, 'Activate', "{'activation-token': <'native-token-71'>}", app=app_id, path=object_path)
            assert line(process) == {'kind': 'activate'}
            assert line(process) == {'kind': 'ui'}
            for _ in range(150):
                if 'native-token-71' in log.read_text():
                    break
                assert process.poll() is None, log.read_text()
                time.sleep(.02)
            else:
                raise AssertionError('Wayland token not forwarded: ' + log.read_text())
            command(env, 'activate', app_id)
            assert line(process) == {'kind': 'activate'}
            assert not select.select([process.stdout], [], [], .2)[0], 'repeated activation reran UI'
            trace = log.read_text()
            assert trace.count('native-token-71') == 1, trace
            assert 'xdg_activation_v1' in trace and '.activate(' in trace
            assert not (root / 'ourokit/apps' / app_id).exists()
            print('PASS: native delayed UI, one UI factory invocation, token forwarded exactly once, repeated standard activation')
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=8)
            assert process.returncode == 143, log.read_text()
            assert 'panic' not in log.read_text() and 'leaked' not in log.read_text(), log.read_text()


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--session':
        session(Path(sys.argv[2]))
    else:
        with tempfile.TemporaryDirectory(prefix='ourokit-desktop-') as temp:
            root = Path(temp)
            (root / 'data/dbus-1/services').mkdir(parents=True)
            env = dict(os.environ, XDG_DATA_HOME=str(root / 'data'))
            subprocess.run(['dbus-run-session', '--', sys.executable, __file__, '--session', temp],
                           env=env, check=True, timeout=90)
