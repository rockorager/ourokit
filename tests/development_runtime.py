#!/usr/bin/env python3
"""Real CLI/MCP development operations on a native Wayland application.

Run after zig build with OUROKIT_TEST_WAYLAND_DISPLAY set to an existing
compositor's absolute socket path. The compositor is owned by the caller.
Uses a private D-Bus session and disposable source/runtime files.
"""
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zlib

from application_services import BINARY, development_path, record, request, RpcStream


def source(declarations, malformed=False):
    return '''local o = require('ouro')
local function window(id, label, fail)
  local count = o.signal(0)
  return o.window {id=id, title=label, width=420, height=460, content=function()
    if fail then error('later new window rejected') end
    return o.column {key='root', gap=9,
      o.button {key='go', label=label .. ': ' .. count(), on_press=function() count:set(count()+1) end},
      o.button {key='disabled', label='Disabled', enabled=false},
      o.text_input {key='edit', label='Query', default_text='aéZ'},
      o.box {key='marker', width='fill', height=25, background=count() == 0 and '#1030c0' or '#d02010'},
      o.virtual_list {key='rows', flex=1, item_count=100, item_height=30,
        item_key=function(i) return 'row-'..i end,
        render_item=function(i) return o.text {key='label', text='Item '..i} end},
    }
  end}
end
return o.app {id='dev.ourokit.live-test', run=function() return {windows={WINDOWS}} end}
'''.replace('WINDOWS', declarations).replace("key='root',", "" if malformed else "key='root',")


def atomic_write(path, text):
    temporary = path.with_suffix('.pending')
    temporary.write_text(text)
    temporary.replace(path)


def cli(env, operation, endpoint, args=None, output=None, succeeds=True):
    command = [str(BINARY), 'dev', operation, str(endpoint)]
    if args is not None:
        command.append(json.dumps(args, ensure_ascii=False))
    if output is not None:
        command += ['--output', str(output)]
    result = subprocess.run(command, env=env, capture_output=True, timeout=12)
    assert (result.returncode == 0) == succeeds, (command, result.returncode, result.stdout, result.stderr)
    assert b'panic' not in result.stderr and b'leaked' not in result.stderr, result.stderr
    return result.stdout.decode()


def inspect(env, path, window):
    return json.loads(cli(env, 'inspect', path, {'window': window}))['windows'][0]


def node(tree, path):
    return next(n for n in tree['nodes'] if n['path'] == path)


def action(env, path, window, **args):
    tree = inspect(env, path, window)
    return json.loads(cli(env, 'input', path, dict(window=window, token=tree['token'], **args)))


def png_pixel(path, x, y):
    data = Path(path).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height = struct.unpack('>II', data[16:24])
    compressed = bytearray()
    offset = 8
    while offset < len(data):
        size = struct.unpack('>I', data[offset:offset+4])[0]
        if data[offset+4:offset+8] == b'IDAT':
            compressed.extend(data[offset+8:offset+8+size])
        offset += size + 12
    rows = zlib.decompress(compressed)
    stride = 1 + width * 4
    assert all(rows[r * stride] == 0 for r in range(height)), 'expected deterministic unfiltered RGBA PNG'
    start = y * stride + 1 + x * 4
    return width, height, rows[start:start+4]


def session(root):
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    env = dict(os.environ, XDG_RUNTIME_DIR=str(root), WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
    app = root / 'app.lua'
    atomic_write(app, source("window('retained','Retained'), window('removed','Removed')"))
    stderr = root / 'app.stderr'
    with stderr.open('wb') as log:
        process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'], env=env, stdout=subprocess.DEVNULL, stderr=log)
    capture_paths = []
    try:
        path = development_path(root, process)
        deadline = time.monotonic() + 8
        while True:
            windows = json.loads(cli(env, 'inspect', path))['windows']
            if {w['window'] for w in windows} == {'retained', 'removed'}:
                break
            assert time.monotonic() < deadline, windows
            time.sleep(.03)
        retained_handle = next(w['handle'] for w in windows if w['window'] == 'retained')
        tools = {t['name'] for t in request(path, 'tools/list')['result']['tools']}
        assert {'runtime.inspect', 'runtime.input', 'runtime.capture', 'runtime.metrics', 'runtime.diagnostics'} <= tools
        tree = inspect(env, path, 'retained')
        assert node(tree, 'root/go')['label'] == 'Retained: 0'
        disabled = json.loads(cli(env, 'input', path, {'window': 'retained', 'token': tree['token'], 'action': 'click', 'target': 'root/disabled'}, succeeds=False))
        assert disabled['error']['code'] == 'DevelopmentTargetDisabled', disabled
        reply = action(env, path, 'retained', action='click', target='root/go')
        assert reply['settled'] == 'runnable_tasks_and_backend_submission'
        assert node(inspect(env, path, 'retained'), 'root/go')['label'] == 'Retained: 1'
        stale = json.loads(cli(env, 'input', path, {'window': 'retained', 'token': tree['token'], 'action': 'click', 'target': 'root/go'}, succeeds=False))
        assert stale['error']['code'] == 'StaleDevelopmentTarget', stale

        action(env, path, 'retained', action='click', target='root/edit')
        action(env, path, 'retained', action='key', key='end')
        action(env, path, 'retained', action='key', key='arrow_left', shift=True)
        selected = node(inspect(env, path, 'retained'), 'root/edit')
        assert selected['focused'] and selected['selection']['anchor'] == 4 and selected['selection']['extent'] == 3, selected
        action(env, path, 'retained', action='text', text='Ω!')
        action(env, path, 'retained', action='key', key='backspace')
        assert node(inspect(env, path, 'retained'), 'root/edit')['value'] == 'aéΩ'
        action(env, path, 'retained', action='scroll', target='root/rows', delta=73)
        action(env, path, 'retained', action='scroll', target='root/rows', delta=-19)
        assert node(inspect(env, path, 'retained'), 'root/rows')['scroll_offset'] == 54
        # Move focus away from blinking text before testing unchanged snapshots.
        action(env, path, 'retained', action='key', key='tab')

        before = inspect(env, path, 'retained')
        generation = json.loads(cli(env, 'diagnostics', path))['generation']
        atomic_write(app, source("window('retained','Rejected'), window('added','Added'), window('late','Late',true)"))
        assert 'reload failed' in subprocess.run([str(BINARY), 'dev', 'reload', str(path)], env=env, capture_output=True, timeout=12).stderr.decode()
        diagnostic = json.loads(cli(env, 'diagnostics', path))
        assert diagnostic['generation'] == generation and diagnostic['diagnostic']['phase'] == 'build', diagnostic
        assert {w['window'] for w in json.loads(cli(env, 'inspect', path))['windows']} == {'retained', 'removed'}
        after_rejection = inspect(env, path, 'retained')
        assert after_rejection == before, (before, after_rejection)

        atomic_write(app, source("window('retained','Retained next'), window('added','Added')"))
        assert 'generation 2' in cli(env, 'reload', path)
        deadline = time.monotonic() + 8
        while True:
            windows = json.loads(cli(env, 'inspect', path))['windows']
            if {w['window'] for w in windows} == {'retained', 'added'}:
                break
            assert time.monotonic() < deadline, windows
            time.sleep(.03)
        assert next(w['handle'] for w in windows if w['window'] == 'retained') == retained_handle
        retained = inspect(env, path, 'retained')
        assert node(retained, 'root/go')['id'] == node(before, 'root/go')['id']
        stale = json.loads(cli(env, 'input', path, {'window':'retained', 'token':before['token'], 'action':'click', 'target':'root/go'}, succeeds=False))
        assert stale['error']['code'] == 'StaleDevelopmentTarget', stale
        action(env, path, 'added', action='click', target='root/go')
        added = inspect(env, path, 'added')
        assert node(added, 'root/go')['label'] == 'Added: 1'

        # Cancellation arrives with a pending input request in the same wire
        # batch. It must not act or leak its request into a reused peer slot.
        stream = RpcStream(path)
        try:
            cancel = json.dumps({'jsonrpc':'2.0', 'method':'notifications/cancelled', 'params':{'requestId':'cancel-input'}}).encode() + b'\n'
            stream.socket.sendall(record('tools/call', {'name':'runtime.input', 'arguments':{'window':'added', 'token':added['token'], 'action':'click', 'target':'root/go'}}, 'cancel-input') + cancel)
            response = stream.read()
            assert response['id'] == 'cancel-input' and response['result']['isError'], response
            assert response['result']['structuredContent']['error']['code'] == 'DevelopmentCanceled', response
        finally:
            stream.close()
        assert node(inspect(env, path, 'added'), 'root/go')['label'] == 'Added: 1'
        action(env, path, 'added', action='click', target='root/go')
        added = inspect(env, path, 'added')
        assert node(added, 'root/go')['label'] == 'Added: 2'

        output = root / 'captured.png'
        capture = json.loads(cli(env, 'capture', path, {'window':'added', 'token':added['token']}, output=output))
        capture_paths.append(Path(capture['path']))
        assert capture['kind'] == 'software_scene_replay' and Path(capture['path']).stat().st_mode & 0o777 == 0o600
        marker = node(added, 'root/marker')['bounds']
        width, height, pixel = png_pixel(output, int(marker['x'] + marker['width']/2), int(marker['y'] + marker['height']/2))
        assert (width, height) == (capture['width'], capture['height']) and pixel == b'\xd0\x20\x10\xff', pixel
        if os.environ.get('OUROKIT_TEST_CAPTURE'):
            Path(os.environ['OUROKIT_TEST_CAPTURE']).write_bytes(output.read_bytes())
        for _ in range(4):
            later = json.loads(cli(env, 'capture', path, {'window':'added', 'token':added['token']}))
            capture_paths.append(Path(later['path']))
        assert not capture_paths[0].exists() and all(p.exists() for p in capture_paths[1:])
        assert output.exists(), 'caller-owned copy must survive capture eviction'
        metrics = json.loads(cli(env, 'metrics', path, {'window':'added'}))['windows'][0]
        assert metrics['timing_enabled'] and metrics['metrics']['builds']['count'] >= 3, metrics
        assert metrics['metrics']['builds']['timed_count'] == metrics['metrics']['builds']['count']
        assert metrics['submitted_revision'] == metrics['scene_revision']
        assert json.loads(cli(env, 'diagnostics', path))['diagnostic'] is None
        print('PASS native live inspection/input/capture/metrics; rejected and accepted structural reload; identity/stale tokens/cancellation')
    finally:
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
        process.wait(timeout=10)
        errors = stderr.read_text()
        assert process.returncode in (0, 128 + signal.SIGTERM), (process.returncode, errors)
        assert 'panic' not in errors and 'leaked' not in errors, errors
        assert all(not p.exists() for p in capture_paths), 'capture survived instance exit'

    # A malformed first content build must report failure and drain its mounted
    # root owner normally, rather than masking LuaBuildFailed with an assertion.
    atomic_write(app, source("window('bad','Malformed')", malformed=True))
    failed = subprocess.run([str(BINARY), 'run', str(app), '--dev', '--software'], env=env, capture_output=True, timeout=10)
    assert failed.returncode == 1 and b'LuaBuildFailed' in failed.stderr, (failed.returncode, failed.stderr)
    assert b'panic' not in failed.stderr and b'leaked' not in failed.stderr, failed.stderr
    print('PASS malformed native startup drains build ownership')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--session':
        session(Path(sys.argv[2]))
    elif not os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY'):
        print('SKIP development runtime: set OUROKIT_TEST_WAYLAND_DISPLAY to a compositor socket')
    else:
        with tempfile.TemporaryDirectory(prefix='ouro-dev-') as directory:
            subprocess.run(['dbus-run-session', '--', sys.executable, __file__, '--session', directory], check=True, timeout=90)
