#!/usr/bin/env python3
"""Verify in-window overlay geometry, input, Lua policy and transactional reload.

Run: python3 tests/overlay_composition.py zig-out/bin/ouroctl
Optional: --capture-dir .amp/in/artifacts/overlays
Always starts a private headless compositor and D-Bus session.
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

from application_services import BINARY, ROOT, call, development_path
from development_runtime import atomic_write, cli, inspect, node, png_pixel
import verify_development as verify

SCROLL = 'root/row/frame/scroll'
ANCHOR = SCROLL + '/body/overlay'
TRIGGER = ANCHOR + '/trigger'
PANEL = ANCHOR + '/panel'
INSIDE = PANEL + '/content/inside'
NESTED = PANEL + '/content/nested'
OUTSIDE = 'root/row/outside'


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-overlays-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/overlay-composition.lua').read_text()
        app = root / 'app.lua'
        atomic_write(app, fixture)
        with (root / 'stderr').open('w') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=log)
        try:
            endpoint = development_path(root, process)

            def snapshot():
                return inspect(env, endpoint, 'main')

            def state():
                return call(endpoint, 'Inspect')['structuredContent']

            def input_(**args):
                tree = snapshot()
                return json.loads(cli(env, 'input', endpoint, dict(window='main', token=tree['token'], **args)))

            def click(path):
                input_(action='click', target=path)

            def key(name, **modifiers):
                input_(action='key', key=name, **modifiers)

            def focused(path):
                actual = [n['path'] for n in snapshot()['nodes'] if n['focused']]
                assert actual == [path], (actual, path)

            def bounds(path):
                return node(snapshot(), path)['bounds']

            def capture(name, panel=PANEL, color=b'\xdc\xeb\xea\xff'):
                tree = snapshot()
                output = root / (name + '.png')
                result = json.loads(cli(env, 'capture', endpoint,
                                       dict(window='main', token=tree['token']), output=output))
                box = node(tree, panel)['bounds']
                x, y = int(box['x'] + 5), int(box['y'] + box['height'] - 5)
                width, height, pixel = png_pixel(output, x, y)
                assert pixel == color, (name, box, pixel, color)
                assert (width, height) == (result['width'], result['height'])
                if os.environ.get('OUROKIT_OVERLAY_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_OVERLAY_CAPTURE'])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / output.name).write_bytes(output.read_bytes())

            deadline = time.monotonic() + 8
            while not any(n['path'] == TRIGGER and n.get('bounds', {}).get('width', 0) > 0
                          for n in snapshot()['nodes']):
                assert time.monotonic() < deadline, 'overlay fixture did not configure'
                time.sleep(.01)

            def exercise(revision, initial, increment):
                before = bounds(ANCHOR)
                trigger_id = node(snapshot(), TRIGGER)['id']
                click(TRIGGER)
                assert state()['opened'], state()
                assert bounds(ANCHOR) == before, 'floating content changed inline size'
                panel, trigger, scroll = bounds(PANEL), bounds(TRIGGER), bounds(SCROLL)
                assert panel['x'] == trigger['x'] + trigger['width'] + 7, (panel, trigger)
                assert panel['y'] == trigger['y'], (panel, trigger)
                assert panel['y'] + panel['height'] > scroll['y'] + scroll['height'], (panel, scroll)
                click(INSIDE)
                assert state()['count'] == initial + increment, state()
                assert state()['outside'] == 0, 'inside press reported as outside'
                capture(f'revision-{revision}-open')

                # Scroll the trigger without rebuilding the overlay. Its native
                # origin, hit target and painted pixels must all move together.
                input_(action='scroll', target=SCROLL, delta=11)
                moved, moved_trigger = bounds(PANEL), bounds(TRIGGER)
                assert moved['y'] == panel['y'] - 11, (panel, moved)
                assert moved['y'] == moved_trigger['y'], (moved, moved_trigger)
                click(INSIDE)
                assert state()['count'] == initial + 2 * increment, state()

                click(NESTED + '/trigger')
                click(NESTED + '/panel/action')
                assert state()['nested_count'] == 7 and state()['outside'] == 0, state()
                capture(f'revision-{revision}-nested', NESTED + '/panel', b'\xf5\xdf\xbd\xff')
                click(INSIDE)
                assert not state()['nested'] and state()['opened'], state()
                assert state()['count'] == initial + 2 * increment, 'nested dismissal clicked through'
                click(INSIDE)
                assert state()['count'] == initial + 3 * increment, state()

                call(endpoint, 'Ignore')
                click(OUTSIDE)
                assert state()['opened'] and state()['outside'] == 1, state()
                assert state()['underneath'] == 0, 'ignored dismissal clicked through'
                call(endpoint, 'Accept')
                click(OUTSIDE)
                assert not state()['opened'] and state()['outside'] == 2, state()
                assert state()['underneath'] == 0, 'dismissal clicked through'
                focused(TRIGGER)
                click(OUTSIDE)
                assert state()['underneath'] == 1, state()
                assert node(snapshot(), TRIGGER)['id'] == trigger_id

                call(endpoint, 'Modal')
                click(TRIGGER)
                focused(INSIDE)
                key('tab', shift=True)
                focused(NESTED + '/trigger')
                key('tab')
                focused(INSIDE)
                key('escape')
                assert not state()['opened'], state()
                focused(TRIGGER)
                click(TRIGGER)
                click(OUTSIDE)
                assert not state()['opened'] and state()['underneath'] == 1, state()
                focused(TRIGGER)
                print(f'PASS revision {revision}: clip escape, scroll-following, nested hits, controlled dismissal, modal focus and restoration')

            exercise(1, 3, 5)
            click(TRIGGER)
            before, previous = snapshot(), state()
            declaration = "key='overlay',side='right',alignment='start',gap=7,margin=9"
            for field, value in (("side='right'", "side='middle'"), ("alignment='start'", "alignment='stretch'"),
                                 ('gap=7', 'gap=-1'), ('margin=9', 'margin=-1'), ('margin=9', 'margin=9,flip=0')):
                invalid = fixture.replace(declaration, declaration.replace(field, value))
                atomic_write(app, invalid)
                cli(env, 'reload', endpoint, succeeds=False)
                assert snapshot() == before, ('invalid overlay mutated committed state', value)
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert snapshot() == before, 'later-window failure mutated overlay state'
            click(INSIDE)
            assert state()['count'] == previous['count'] + 5, state()
            key('escape')
            old = snapshot()
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            for path in (ANCHOR, TRIGGER, OUTSIDE):
                assert node(snapshot(), path)['id'] == node(old, path)['id'], path
            stale = json.loads(cli(env, 'input', endpoint,
                               dict(window='main', token=old['token'], action='click', target=TRIGGER), succeeds=False))
            assert stale['error']['code'] == 'StaleDevelopmentTarget', stale
            # Scroll state survives reload; restore the original geometry for
            # independently expected placement and asymmetric callback counts.
            input_(action='scroll', target=SCROLL, delta=-100)
            exercise(2, 19, 11)
            click(TRIGGER)
            call(endpoint, 'Narrow')
            # Window dimensions are initial preferences; an established
            # toplevel's resize comes from the compositor, not the Lua signal.
            sockets = list(Path(os.environ['OUROKIT_TEST_WAYLAND_DISPLAY']).parent.glob('sway-ipc.*.sock'))
            assert len(sockets) == 1, sockets
            resized = subprocess.run(['swaymsg', '-s', str(sockets[0]),
                                      '[app_id="dev.ourokit.overlay-composition"] resize set width 340 px height 390 px'],
                                     env=env, capture_output=True, check=True)
            assert all(r['success'] for r in json.loads(resized.stdout)), resized.stdout
            deadline = time.monotonic() + 5
            while bounds('root')['width'] > 340:
                assert time.monotonic() < deadline, 'native resize did not settle'
                time.sleep(.01)
            panel = bounds(PANEL)
            assert panel['x'] >= 9 and panel['x'] + panel['width'] <= 331, panel
            capture('revision-2-narrow')
            print('PASS transactional validation/reload, retained trigger identity, fresh callbacks, stale tokens and window-edge fitting')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            errors = (root / 'stderr').read_text()
            assert process.returncode in (0, 128 + signal.SIGTERM), (process.returncode, errors)
            assert 'panic' not in errors and 'leaked' not in errors, errors


if __name__ == '__main__':
    if len(sys.argv) == 1 and os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY'):
        session()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('binary', nargs='?', type=Path, default=BINARY)
        parser.add_argument('--capture-dir', type=Path)
        args = parser.parse_args()
        if args.capture_dir:
            os.environ['OUROKIT_OVERLAY_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
