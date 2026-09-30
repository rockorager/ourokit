#!/usr/bin/env python3
"""Native rounded child clips: pixels, corner fall-through and atomic reload.

Run: python3 tests/clip_composition.py zig-out/bin/ouroctl
Optional: --capture-dir .amp/in/artifacts/clips
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
import verify_development as verify

SHAPE = 'root/gallery/shape/layout/target'
UNDER = 'root/gallery/shape/layout/under'
CORNER = SHAPE + '/content/corner'
OWN = 'root/gallery/own/layout/target'
OUTER = 'root/gallery/nested/layout/outer'
INNER = OUTER + '/layout/inner'
VIEWPORT = 'root/gallery/ancestor/layout/viewport/scroll'
ANCESTOR = VIEWPORT + '/layout/target'
GROUND, SHADOW = (220, 230, 240), (32, 48, 64)
ORIGINAL, RELOADED = (56, 154, 192), (99, 180, 138)


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-clips-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/clip-composition.lua').read_text()
        app = root / 'app.lua'
        atomic_write(app, fixture)
        with (root / 'stderr').open('w') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=log)
        try:
            endpoint = development_path(root, process, windows=('main', 'peer'))

            def invoke(name, args=None):
                reply = call(endpoint, name, args)
                assert not reply.get('isError') and 'rpcError' not in reply, (name, reply)
                return reply['structuredContent']

            def snapshot(window='main'):
                return invoke('runtime.inspect', {'window': window})['windows'][0]

            deadline = time.monotonic() + 8
            previous, stable_since = None, time.monotonic()
            while True:
                assert process.poll() is None, 'clip application exited during startup'
                try:
                    trees = tuple(snapshot(w) for w in ('main', 'peer'))
                except ConnectionRefusedError:
                    # A bound socket path can appear before listen completes.
                    trees = None
                now = time.monotonic()
                if trees != previous:
                    previous, stable_since = trees, now
                elif trees is not None and now - stable_since >= .3 and all(any(n['path'] == SHAPE for n in t['nodes']) for t in trees):
                    break
                assert now < deadline, ('clip windows did not settle', trees)
                time.sleep(.03)

            def click(path):
                tree = snapshot()
                invoke('runtime.input', dict(window='main', token=tree['token'], action='click', target=path))

            def blocked(path):
                before = snapshot()
                reply = call(endpoint, 'runtime.input', dict(window='main', token=before['token'], action='click', target=path))
                assert reply.get('isError') and reply['structuredContent']['error']['code'] == 'DevelopmentTargetOccluded', reply
                assert snapshot() == before, 'blocked input changed live state'

            def status(expected):
                actual = node(snapshot(), 'root/status')['label']
                assert actual == expected, (actual, expected)

            def stale(tree, window='main'):
                reply = call(endpoint, 'runtime.capture', dict(window=window, token=tree['token']))
                assert reply.get('isError') and reply['structuredContent']['error']['code'] == 'StaleDevelopmentTarget', reply

            def same_geometry(old, new):
                for path in (SHAPE, UNDER, CORNER, OWN, OUTER, INNER, VIEWPORT, ANCESTOR):
                    a, b = node(old, path), node(new, path)
                    assert (a['id'], a['bounds']) == (b['id'], b['bounds']), (path, a, b)

            def capture(name, window='main', rounded=True, color=ORIGINAL):
                tree = snapshot(window)
                result = invoke('runtime.capture', dict(window=window, token=tree['token']))
                assert result['kind'] == 'software_scene_replay', result
                output = root / (name + '.png')
                output.write_bytes(Path(result['path']).read_bytes())

                def pixel(path, x, y, expected):
                    box = node(tree, path)['bounds']
                    w, h, actual = png_pixel(output, int(box['x'] + x), int(box['y'] + y))
                    assert (w, h) == (result['width'], result['height'])
                    assert tuple(actual) == (*expected, 255), (name, path, x, y, tuple(actual), expected)

                for path in (SHAPE, OWN, ANCESTOR):
                    box = node(tree, path)['bounds']
                    assert (box['width'], box['height']) == (80, 60), (path, box)
                assert node(tree, UNDER)['bounds'] == node(tree, CORNER)['bounds'], 'corner probes must target the same point'
                assert all(node(tree, p)['role'] == 'button' for p in (SHAPE, UNDER, CORNER))
                pixel(SHAPE, 2, 2, (192, 91, 55) if rounded else color)
                pixel(SHAPE, 77, 57, GROUND if rounded else color)
                pixel(SHAPE, 40, 30, color)
                pixel(SHAPE, 40, 2, color)
                pixel(SHAPE, -3, 30, GROUND)

                pixel(OWN, 2, 2, GROUND)
                pixel(OWN, 40, 2, color)
                pixel(OWN, 40, 30, color)
                pixel(OWN, 90, 30, SHADOW)  # Own shadow paints outside its own child clip.
                pixel(OWN, 40, 70, SHADOW)
                pixel(OWN, -4, 30, GROUND)

                outer, inner = node(tree, OUTER)['bounds'], node(tree, INNER)['bounds']
                assert (outer['width'], outer['height'], inner['width'], inner['height']) == (100, 90, 90, 80)
                assert (inner['x'] - outer['x'], inner['y'] - outer['y']) == (25, 10)
                pixel(OUTER, 2, 2, GROUND)
                pixel(OUTER, 10, 40, (255, 255, 255))
                pixel(INNER, 2, 2, (255, 255, 255))  # Inside outer curve, outside inner curve.
                pixel(INNER, 35, 35, (173, 116, 206))
                pixel(OUTER, 98, 12, GROUND)  # Inside inner curve, outside outer curve.
                pixel(INNER, 82, 35, GROUND)  # Inner content cannot escape outer right bound.

                viewport, target = node(tree, VIEWPORT)['bounds'], node(tree, ANCESTOR)['bounds']
                assert (viewport['width'], viewport['height']) == (110, 94)
                assert (target['x'] - viewport['x'], target['y'] - viewport['y']) == (20, 20)
                pixel(ANCESTOR, 2, 2, GROUND)
                pixel(ANCESTOR, 40, 30, color)
                pixel(ANCESTOR, 85, 30, SHADOW)
                pixel(ANCESTOR, 95, 30, GROUND)  # Ancestor cuts the otherwise-painted shadow.
                pixel(ANCESTOR, 40, 70, SHADOW)
                pixel(ANCESTOR, 40, 78, GROUND)
                if os.environ.get('OUROKIT_CLIP_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_CLIP_CAPTURE'])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / output.name).write_bytes(output.read_bytes())
                return tree

            original = capture('original')
            peer = capture('peer-original', 'peer')
            click(UNDER)
            blocked(CORNER)
            status('Revision 1 · clip true · radius 24 · inside 0 · under 3')
            click(SHAPE)
            status('Revision 1 · clip true · radius 24 · inside 1 · under 3')
            click('root/controls/square')
            square = capture('square', rounded=False)
            same_geometry(original, square)
            stale(original)
            blocked(UNDER)
            click(CORNER)
            status('Revision 1 · clip true · radius 0 · inside 2 · under 3')
            invoke('Round')
            rounded = capture('round-restored')
            same_geometry(original, rounded)
            click('root/controls/toggle')
            unclipped = capture('unclipped', rounded=False)
            same_geometry(original, unclipped)
            stale(square)
            blocked(UNDER)
            click(CORNER)
            status('Revision 1 · clip false · radius 24 · inside 3 · under 3')
            invoke('ToggleClip')
            click(UNDER)
            restored = capture('clip-restored')
            status('Revision 1 · clip true · radius 24 · inside 3 · under 6')
            same_geometry(original, restored)
            assert snapshot('peer') == peer, 'main clip/radius changes dirtied peer'
            capture('peer-retained', 'peer')
            print('PASS rounded pixels, nested clips, own/ancestor shadow rules, stable IDs/bounds, radius-only updates and corner fall-through')

            before = (snapshot(), snapshot('peer'))
            generation = invoke('runtime.diagnostics')['generation']
            for invalid in ('1', '"true"'):
                atomic_write(app, fixture.replace('clip=peer or clipped()', 'clip=' + invalid))
                cli(env, 'reload', endpoint, succeeds=False)
                assert (snapshot(), snapshot('peer')) == before, ('malformed clip changed live windows', invalid)
                assert invoke('runtime.diagnostics')['generation'] == generation
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert (snapshot(), snapshot('peer')) == before, 'later-window rejection changed live clips'
            assert invoke('runtime.diagnostics')['generation'] == generation
            assert {w['window'] for w in invoke('runtime.inspect')['windows']} == {'main', 'peer'}
            capture('rejected-main')
            capture('rejected-peer', 'peer')
            click(SHAPE)
            click(UNDER)
            live = capture('old-callbacks')
            status('Revision 1 · clip true · radius 24 · inside 4 · under 9')

            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            accepted = capture('reloaded-main', color=RELOADED)
            accepted_peer = capture('reloaded-peer', 'peer', color=RELOADED)
            same_geometry(live, accepted)
            same_geometry(peer, accepted_peer)
            status('Revision 2 · clip true · radius 24 · inside 0 · under 0')
            assert node(accepted_peer, 'root/status')['label'] == 'Peer original · revision 2'
            stale(live)
            stale(peer, 'peer')
            click(UNDER)
            blocked(CORNER)
            click(SHAPE)
            capture('new-callbacks', color=RELOADED)
            status('Revision 2 · clip true · radius 24 · inside 7 · under 11')
            invoke('Square')
            click(CORNER)
            fresh = capture('new-square', rounded=False, color=RELOADED)
            status('Revision 2 · clip true · radius 0 · inside 14 · under 11')
            same_geometry(accepted, fresh)
            assert snapshot('peer') == accepted_peer
            print('PASS strict boolean validation, rejected/accepted two-window reload, old/fresh callbacks, clipping after reload and stale tokens')
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
            os.environ['OUROKIT_CLIP_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
