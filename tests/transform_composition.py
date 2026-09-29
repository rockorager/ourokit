#!/usr/bin/env python3
"""Native paint-only transforms: independent coordinates, pixels, input and reload.

Run: python3 tests/transform_composition.py zig-out/bin/ouroctl
Optional: --capture-dir .amp/in/artifacts/transforms
Uses private headless Sway and D-Bus, never the caller's desktop.
"""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from application_services import BINARY, ROOT, call, development_path
from development_runtime import atomic_write, cli, node, png_pixel
from drawing_composition import over
import verify_development as verify

MUTABLE = 'root/gallery/mutable'
MARKER, OLD, NEW = (MUTABLE + '/layout/' + name for name in ('marker', 'old', 'new'))
TARGET = MUTABLE + '/layout/motion/target'
CHILD = TARGET + '/content/child'
NESTED = 'root/gallery/nested'
OUTER = NESTED + '/layout/outer'
INNER = OUTER + '/layout/inner'
CLIPPING = 'root/gallery/clipping'
CLIP = CLIPPING + '/layout/clip'
GROUP = CLIP + '/layout/group'
COPIED = 'root/gallery/copied'
CARD = COPIED + '/layout/card'
GROUND, SHADOW = (232, 238, 244), (32, 48, 64)
ORIGINAL, RELOADED = (56, 154, 192), (99, 180, 138)


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-transforms-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/transform-composition.lua').read_text()
        app = root / 'app.lua'
        atomic_write(app, fixture)
        with (root / 'stderr').open('w') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=log)
        try:
            endpoint = development_path(root, process)

            def invoke(name, args=None):
                reply = call(endpoint, name, args)
                assert not reply.get('isError') and 'rpcError' not in reply, (name, reply)
                return reply['structuredContent']

            def snapshot(window='main'):
                return invoke('runtime.inspect', {'window': window})['windows'][0]

            deadline = time.monotonic() + 8
            previous, stable_since = None, time.monotonic()
            while True:
                assert process.poll() is None, 'transform application exited during startup'
                try:
                    trees = tuple(snapshot(w) for w in ('main', 'peer'))
                except ConnectionRefusedError:
                    trees = None  # Socket can bind before listen completes.
                now = time.monotonic()
                if trees != previous:
                    previous, stable_since = trees, now
                elif trees is not None and now - stable_since >= .3 and all(any(n['path'] == TARGET for n in t['nodes']) for t in trees):
                    break
                assert now < deadline, ('transform windows did not settle', trees)
                time.sleep(.03)

            def click(path):
                tree = snapshot()
                invoke('runtime.input', dict(window='main', token=tree['token'], action='click', target=path))

            def blocked(path):
                before = snapshot()
                reply = call(endpoint, 'runtime.input', dict(window='main', token=before['token'], action='click', target=path))
                assert reply.get('isError') and reply['structuredContent']['error']['code'] == 'DevelopmentTargetOccluded', reply
                assert snapshot() == before, 'occluded input changed the live tree'

            def status(revision, hits, under):
                actual = node(snapshot(), 'root/status')['label']
                assert actual == f'Revision {revision} · hits {hits} · under {under}', actual

            def metric(name):
                return invoke('runtime.metrics', {'window': 'main'})['windows'][0]['metrics'][name]['count']

            def stale(tree, window='main'):
                reply = call(endpoint, 'runtime.capture', dict(window=window, token=tree['token']))
                assert reply.get('isError') and reply['structuredContent']['error']['code'] == 'StaleDevelopmentTarget', reply

            def progress(tree):
                return float(node(tree, TARGET)['label'].removeprefix('Progress '))

            def stable_layout(old, new):
                for path in (MUTABLE, MARKER, OLD, NEW, NESTED, OUTER, INNER, CLIPPING, CLIP, GROUP, COPIED, CARD, TARGET, CHILD):
                    a, b = node(old, path), node(new, path)
                    assert a['id'] == b['id'], (path, a, b)
                    if path not in (TARGET, CHILD):
                        assert a['bounds'] == b['bounds'], (path, a, b)

            def rect(tree, path, panel, expected):
                base, actual = node(tree, panel)['bounds'], node(tree, path)['bounds']
                x, y, w, h = expected
                expected = dict(x=base['x'] + x, y=base['y'] + y, width=w, height=h)
                assert all(abs(actual[k] - v) < .002 for k, v in expected.items()), (path, actual, expected)

            def geometry(tree, value):
                # Expand translation + origin + scale*(point-origin) by hand.
                rect(tree, TARGET, MUTABLE, (20 + 70*value, 30 + 5*value, 60 + 30*value, 40 + 20*value))
                rect(tree, CHILD, MUTABLE, (30 + 75*value, 40 + 10*value, 20 + 10*value, 12 + 6*value))
                rect(tree, MARKER, MUTABLE, (20, 30, 60, 40))
                rect(tree, OLD, MUTABLE, (40, 40, 20, 20))
                rect(tree, NEW, MUTABLE, (130, 55, 10, 20))
                rect(tree, OUTER, NESTED, (20, 21, 150, 120))
                rect(tree, INNER, NESTED, (63.5, 45, 30, 22.5))
                rect(tree, CLIP, CLIPPING, (30, 30, 100, 80))
                rect(tree, GROUP, CLIPPING, (55, 10, 90, 90))
                rect(tree, CARD, COPIED, (46, 35, 80, 50))

            def capture(name, window='main', value=1, color=ORIGINAL):
                tree = snapshot(window)
                assert progress(tree) == value, (name, progress(tree), value)
                geometry(tree, value)
                result = invoke('runtime.capture', dict(window=window, token=tree['token']))
                assert result['kind'] == 'software_scene_replay', result
                output = root / (name + '.png')
                output.write_bytes(Path(result['path']).read_bytes())
                if os.environ.get('OUROKIT_TRANSFORM_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_TRANSFORM_CAPTURE'])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / output.name).write_bytes(output.read_bytes())

                def pixel(panel, x, y, expected, tolerance=0):
                    base = node(tree, panel)['bounds']
                    w, h, actual = png_pixel(output, int(base['x'] + x), int(base['y'] + y))
                    assert (w, h) == (result['width'], result['height'])
                    assert all(abs(a-b) <= tolerance for a, b in zip(actual, (*expected, 255))), (name, panel, x, y, actual, expected)

                # Probe using analytically transformed points, not reported target bounds.
                x, y, scale = 20 + 70*value, 30 + 5*value, 1 + .5*value
                pixel(MUTABLE, x + 45*scale, y + 20*scale, color)
                pixel(MUTABLE, x + scale, y + 20*scale, (36, 112, 128))
                pixel(MUTABLE, x + 20*scale, y + 15*scale, (232, 182, 90))
                pixel(MUTABLE, x + 65*scale, y + 20*scale, SHADOW)
                pixel(MUTABLE, x + 35*scale, y + 45*scale, SHADOW)
                pixel(MUTABLE, 50, 50, (192, 91, 55) if value else color)
                pixel(NESTED, 10, 10, GROUND)
                pixel(NESTED, 30, 30, (173, 195, 216))
                pixel(NESTED, 75, 55, (173, 116, 206))
                pixel(NESTED, 110, 55, (173, 195, 216))
                pixel(CLIPPING, 65, 35, over(GROUND, (192, 80, 48), 127.5), 2)
                pixel(CLIPPING, 105, 65, over(GROUND, color, 127.5), 2)
                for point in ((80, 20), (137, 65), (128, 32), (35, 65)):
                    pixel(CLIPPING, *point, GROUND)
                pixel(COPIED, 47, 36, GROUND)  # Outside the scaled rounded corner.
                pixel(COPIED, 65, 55, (117, 185, 138))
                pixel(COPIED, 135, 55, GROUND)
                return tree

            original, peer = capture('original'), capture('peer-original', 'peer')
            click(OLD)
            blocked(NEW)
            click(TARGET)
            status(1, 1, 3)
            layouts = metric('layouts')
            invoke('Identity')
            identity = capture('identity', value=0)
            assert metric('layouts') == layouts, 'transform-only removal performed layout'
            stable_layout(original, identity)
            stale(original)
            blocked(OLD)
            click(NEW)
            click(TARGET)
            status(1, 2, 6)
            layouts = metric('layouts')
            invoke('Transform')
            restored = capture('transform-restored')
            assert metric('layouts') == layouts, 'transform-only update performed layout'
            stable_layout(identity, restored)
            click(OLD)
            status(1, 2, 9)
            assert snapshot('peer') == peer, 'main transforms dirtied peer'
            before = (snapshot(), snapshot('peer'))
            invoke('MutateSource')
            assert (snapshot(), snapshot('peer')) == before, 'source-table mutation changed retained native values'
            capture('copied-main')
            capture('copied-peer', 'peer')
            invoke('RestoreSource')
            print('PASS independent transformed/nested bounds and pixels, shadow/clip/opacity, copied native values, stable IDs/layout and old/new-position hit routing')

            invoke('Animate')
            deadline, previous_value, intermediate = time.monotonic() + 6, -1, []
            while True:
                moving = snapshot()
                value = progress(moving)
                assert previous_value <= value <= 1, (previous_value, value)
                geometry(moving, value)
                stable_layout(restored, moving)
                if .15 < value < .85 and (not intermediate or value > progress(intermediate[-1]) + .05):
                    intermediate.append(moving)
                if value == 1:
                    break
                previous_value = value
                assert time.monotonic() < deadline, 'transform animation did not finish'
                time.sleep(.02)
            assert len(intermediate) >= 2, 'no increasing intermediate transform samples'
            capture('animation-final')
            stale(intermediate[0])
            time.sleep(.08)
            builds = metric('builds')
            for _ in range(3):
                time.sleep(.08)
                assert metric('builds') == builds, 'completed animation kept rebuilding'
            assert snapshot('peer') == peer
            invoke('Transform')
            print('PASS bounded native animation: independent intermediate visual bounds, exact endpoint pixels and idle completion')

            before = (snapshot(), snapshot('peer'))
            generation = invoke('runtime.diagnostics')['generation']
            for invalid in ('false', '{scale=0}', '{scale=-1}', '{scale=0/0}', '{x=math.huge}', '{origin={y="bad"}}'):
                atomic_write(app, fixture.replace('local invalid_transform = nil', 'local invalid_transform = ' + invalid))
                cli(env, 'reload', endpoint, succeeds=False)
                assert (snapshot(), snapshot('peer')) == before, ('invalid transform changed live windows', invalid)
                assert invoke('runtime.diagnostics')['generation'] == generation
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert (snapshot(), snapshot('peer')) == before, 'later-window rejection changed transformed scenes'
            assert invoke('runtime.diagnostics')['generation'] == generation
            assert {w['window'] for w in invoke('runtime.inspect')['windows']} == {'main', 'peer'}
            capture('rejected-main')
            capture('rejected-peer', 'peer')
            click(TARGET)
            click(OLD)
            live = capture('old-callbacks')
            status(1, 3, 12)

            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            accepted = capture('reloaded-main', color=RELOADED)
            accepted_peer = capture('reloaded-peer', 'peer', color=RELOADED)
            stable_layout(live, accepted)
            stable_layout(peer, accepted_peer)
            status(2, 0, 0)
            assert node(accepted_peer, 'root/status')['label'] == 'Peer revision 2'
            stale(live)
            stale(peer, 'peer')
            click(TARGET)
            click(OLD)
            blocked(NEW)
            status(2, 7, 11)
            invoke('Identity')
            blocked(OLD)
            click(NEW)
            click(TARGET)
            fresh = capture('new-identity-callbacks', value=0, color=RELOADED)
            status(2, 14, 22)
            stable_layout(accepted, fresh)
            assert snapshot('peer') == accepted_peer
            print('PASS invalid transforms, atomic two-window reload, old/fresh callbacks, post-reload hit mapping and stale tokens')
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
            os.environ['OUROKIT_TRANSFORM_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
