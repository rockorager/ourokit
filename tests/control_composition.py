#!/usr/bin/env python3
"""Public control contracts, independent of Lua/Zig visual implementation.

  zig build
  python3 tests/control_composition.py /absolute/path/to/ouroctl
  python3 tests/control_composition.py zig-out/bin/ouroctl --capture-dir .amp/in/artifacts/controls

Standalone runs start a disposable compositor/private bus through verify_development;
the full verification suite supplies its own isolated compositor and bus.
Missing native dependencies fail, never skip.
Only source copies in a temporary directory are rewritten for reload tests.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from application_services import BINARY, ROOT, development_path
from development_runtime import atomic_write, cli, inspect, node, png_pixel
import verify_development as verify


WINDOW = 'main'
CUSTOM = 'root/custom'
CHECK = 'root/checks/live'
SWITCH = 'root/switches/live'
IGNORED_CHECK = 'root/ignored/check'
IGNORED_SWITCH = 'root/ignored/switch'
EXTERNAL = 'root/external'
DISABLED = ('root/disabled-button', 'root/checks/disabled', 'root/switches/disabled')
CONTROLS = (CUSTOM, CHECK, SWITCH, IGNORED_CHECK, IGNORED_SWITCH, EXTERNAL, *DISABLED)


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-controls-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/control-composition.lua').read_text()
        app = root / 'app.lua'
        atomic_write(app, fixture)
        stderr = root / 'app.stderr'
        with stderr.open('wb') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=log)
        try:
            endpoint = development_path(root, process, windows=(WINDOW,))

            def snapshot():
                return inspect(env, endpoint, WINDOW)

            def build_count():
                result = json.loads(cli(env, 'metrics', endpoint, {'window': WINDOW}))
                return result['windows'][0]['metrics']['builds']['count']

            def input_(**args):
                tree = snapshot()
                return json.loads(cli(env, 'input', endpoint,
                                      dict(window=WINDOW, token=tree['token'], **args)))

            def key(value, **args):
                input_(action='key', key=value, **args)

            def click(target):
                input_(action='click', target=target)

            def label(path, expected):
                actual = node(snapshot(), path)['label']
                assert actual == expected, (path, actual, expected)

            def focused(path):
                actual = [n['path'] for n in snapshot()['nodes'] if n['focused']]
                assert actual == [path], (actual, path)

            def states(check, switch):
                tree = snapshot()
                for path, expected in ((CHECK, check), (SWITCH, switch),
                                       (IGNORED_CHECK, False), (IGNORED_SWITCH, True),
                                       (DISABLED[1], False), (DISABLED[2], True)):
                    assert node(tree, path)['checked'] is expected, (path, node(tree, path))

            # Wait only for initial native configure, not to conceal stale input.
            deadline = time.monotonic() + 8
            previous, stable = None, time.monotonic()
            while True:
                tree = snapshot()
                now = time.monotonic()
                if tree != previous:
                    previous, stable = tree, now
                elif now - stable >= .3:
                    break
                assert now < deadline, 'initial window did not settle'
                time.sleep(.05)

            def capture(name):
                tree = snapshot()
                output = root / (name + '.png')
                result = json.loads(cli(env, 'capture', endpoint,
                                        dict(window=WINDOW, token=tree['token']), output=output))
                assert result['kind'] == 'software_scene_replay', result
                bounds = node(tree, CUSTOM + '/content/swatch')['bounds']
                width, height, pixel = png_pixel(output, int(bounds['x'] + bounds['width']/2),
                                                int(bounds['y'] + bounds['height']/2))
                assert (width, height) == (result['width'], result['height'])
                assert pixel == b'\x19\x3b\xc7\xff', (bounds, pixel)
                if os.environ.get('OUROKIT_CONTROLS_CAPTURE'):
                    target = Path(os.environ['OUROKIT_CONTROLS_CAPTURE'])
                    target.mkdir(parents=True, exist_ok=True)
                    (target / output.name).write_bytes(output.read_bytes())

            def exercise(revision, counts):
                tree = snapshot()
                label('root/revision', f'Composition revision {revision}')
                label(CUSTOM, f'Semantic action {revision}')
                label(CHECK, 'Archive locally')
                label(SWITCH, 'Publish remotely')
                label(CUSTOM + '/content/copy/title', 'Visible custom action')
                label(CUSTOM + '/content/copy/detail', f'Count {counts[0]}')
                roles = ((CUSTOM, 'button'), (CHECK, 'checkbox'), (SWITCH, 'switch'))
                for path, role in roles:
                    control = node(tree, path)
                    assert control['role'] == role and control['enabled'] and control['visible'], control
                outer = node(tree, CUSTOM)['bounds']
                for path in ('content/swatch', 'content/copy/title', 'content/copy/detail'):
                    bounds = node(tree, CUSTOM + '/' + path)['bounds']
                    assert bounds['width'] > 0 and bounds['height'] > 0, bounds
                    assert outer['x'] <= bounds['x'] and outer['y'] <= bounds['y'], (outer, bounds)
                    assert bounds['x'] + bounds['width'] <= outer['x'] + outer['width'] + .01, (outer, bounds)
                    assert bounds['y'] + bounds['height'] <= outer['y'] + outer['height'] + .01, (outer, bounds)
                states(True, False)
                label('root/changes', 'Changes: ')
                capture(f'revision-{revision}-initial')
                builds = build_count()
                input_(action='hover', target=CUSTOM)
                input_(action='hover', target='root/revision')
                assert build_count() == builds, 'hover rebuilt Lua composition'
                click(CUSTOM)
                focused(CUSTOM)
                label(CUSTOM + '/content/copy/detail', f'Count {counts[1]}')
                key('enter')
                label(CUSTOM + '/content/copy/detail', f'Count {counts[2]}')
                key('space')
                label(CUSTOM + '/content/copy/detail', f'Count {counts[3]}')

                # Disabled hits are explicit errors and must neither call back nor steal focus.
                for path in DISABLED:
                    tree = snapshot()
                    assert not node(tree, path)['enabled'], node(tree, path)
                    error = json.loads(cli(env, 'input', endpoint, dict(window=WINDOW,
                        token=tree['token'], action='click', target=path), succeeds=False))
                    assert error['error']['code'] == 'DevelopmentTargetDisabled', error
                    focused(CUSTOM)
                    label('root/forbidden', 'Forbidden: 0')

                # Exactly one focus stop per enabled control; disabled siblings are skipped.
                builds = build_count()
                key('tab'); focused(CHECK)
                assert build_count() == builds, 'focus rebuilt Lua composition'
                key('space'); states(False, False)
                label('root/changes', 'Changes: C0;')
                key('enter'); states(True, False)
                label('root/changes', 'Changes: C0;C1;')
                click(CHECK); states(False, False)
                label('root/changes', 'Changes: C0;C1;C0;')
                key('tab'); focused(SWITCH)
                key('enter'); states(False, True)
                label('root/changes', 'Changes: C0;C1;C0;S1;')
                key('space'); states(False, False)
                label('root/changes', 'Changes: C0;C1;C0;S1;S0;')
                click(SWITCH); states(False, True)
                expected = 'Changes: C0;C1;C0;S1;S0;S1;'
                label('root/changes', expected)

                key('tab'); focused(IGNORED_CHECK)
                key('space'); states(False, True)
                key('enter'); states(False, True)
                key('tab'); focused(IGNORED_SWITCH)
                key('enter'); states(False, True)
                key('space'); states(False, True)
                label('root/requests', 'Requests: C1;C1;S0;S0;')
                key('tab'); focused(EXTERNAL)
                key('tab', shift=True); focused(IGNORED_SWITCH)
                click(CHECK); click(SWITCH); states(True, False)
                expected += 'C1;S0;'
                label('root/changes', expected)
                click(EXTERNAL); states(False, True)
                label('root/changes', expected)  # External updates emit no callbacks.
                label('root/forbidden', 'Forbidden: 0')
                capture(f'revision-{revision}-exercised')
                print(f'PASS revision {revision}: custom content, exact callbacks, keyboard/focus, disabled and controlled toggles')

            exercise(1, (5, 12, 19, 26))
            before = snapshot()
            generation = json.loads(cli(env, 'diagnostics', endpoint))['generation']
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            diagnostic = json.loads(cli(env, 'diagnostics', endpoint))
            assert diagnostic['generation'] == generation, diagnostic
            assert diagnostic['diagnostic']['phase'] == 'build', diagnostic
            assert [w['window'] for w in json.loads(cli(env, 'inspect', endpoint))['windows']] == [WINDOW]
            assert snapshot() == before, 'rejected candidate mutated committed controls'
            click(CUSTOM)
            label(CUSTOM + '/content/copy/detail', 'Count 33')
            click(CHECK); click(SWITCH); states(True, False)
            label('root/changes', 'Changes: C0;C1;C0;S1;S0;S1;C1;S0;C1;S0;')
            label('root/forbidden', 'Forbidden: 0')
            print('PASS rejected reload: identical committed snapshot, live original handlers')

            old = snapshot()
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            diagnostic = json.loads(cli(env, 'diagnostics', endpoint))
            assert diagnostic['generation'] == generation + 1 and diagnostic['diagnostic'] is None, diagnostic
            after = snapshot()
            for path in CONTROLS:
                assert node(after, path)['id'] == node(old, path)['id'], path
            stale = json.loads(cli(env, 'input', endpoint, dict(window=WINDOW, token=old['token'],
                                action='click', target=CUSTOM), succeeds=False))
            assert stale['error']['code'] == 'StaleDevelopmentTarget', stale
            exercise(2, (31, 44, 57, 70))
            print('PASS accepted reload: retained semantic identities, stale token rejected, fresh handlers usable')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            errors = stderr.read_text()
            assert process.returncode in (0, 128 + signal.SIGTERM), (process.returncode, errors)
            assert 'panic' not in errors and 'leaked' not in errors, errors


if __name__ == '__main__':
    if os.environ.get('OUROKIT_CONTROLS_SESSION') == '1' or (
            len(sys.argv) == 1 and os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY')):
        session()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('binary', nargs='?', type=Path, default=BINARY)
        parser.add_argument('--capture-dir', type=Path)
        args = parser.parse_args()
        if args.capture_dir:
            os.environ['OUROKIT_CONTROLS_CAPTURE'] = str(args.capture_dir.resolve())
        os.environ['OUROKIT_CONTROLS_SESSION'] = '1'
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
