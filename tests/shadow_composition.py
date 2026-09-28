#!/usr/bin/env python3
"""Native outset shadows: pixels, hit bounds, replacement and atomic reload.

Run: python3 tests/shadow_composition.py zig-out/bin/ouroctl
Optional: --capture-dir .amp/in/artifacts/shadows
Starts private headless Sway and D-Bus; never uses the caller's desktop.
"""
import argparse
import math
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

HARD = 'root/gallery/hard/layout/target'
PROBE = 'root/gallery/hard/layout/probe'
KNOCKOUT = 'root/gallery/knockout/layout/target'
BLUR = 'root/gallery/blur/layout/target'
VIEWPORT = 'root/gallery/clip/outer/viewport/scroll'
CLIPPED = VIEWPORT + '/layout/target'
GROUND, GOLD, ORIGINAL, RELOADED = (220, 230, 240), (232, 182, 90), (32, 48, 64), (128, 48, 32)


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-shadows-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/shadow-composition.lua').read_text()
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
                trees = tuple(snapshot(w) for w in ('main', 'peer'))
                now = time.monotonic()
                if trees != previous:
                    previous, stable_since = trees, now
                elif now - stable_since >= .3 and all(any(n['path'] == HARD for n in t['nodes']) for t in trees):
                    break
                assert now < deadline, ('shadow windows did not settle', trees)
                time.sleep(.03)

            def click(path):
                tree = snapshot()
                invoke('runtime.input', dict(window='main', token=tree['token'], action='click', target=path))

            def stale(tree, window='main'):
                reply = call(endpoint, 'runtime.capture', dict(window=window, token=tree['token']))
                assert reply.get('isError') and reply['structuredContent']['error']['code'] == 'StaleDevelopmentTarget', reply

            def same_geometry(old, new):
                for path in (HARD, PROBE, KNOCKOUT, BLUR, VIEWPORT, CLIPPED):
                    a, b = node(old, path), node(new, path)
                    assert (a['id'], a['bounds']) == (b['id'], b['bounds']), (path, a, b)

            def capture(name, window='main', mode=0, color=ORIGINAL):
                tree = snapshot(window)
                result = invoke('runtime.capture', dict(window=window, token=tree['token']))
                assert result['kind'] == 'software_scene_replay', result
                output = root / (name + '.png')
                output.write_bytes(Path(result['path']).read_bytes())

                def pixel(path, x, y, expected=None, tolerance=0):
                    box = node(tree, path)['bounds']
                    w, h, actual = png_pixel(output, int(box['x'] + x), int(box['y'] + y))
                    assert (w, h) == (result['width'], result['height'])
                    assert actual[3] == 255, (name, path, actual)
                    if expected is not None:
                        assert all(abs(c - e) <= tolerance for c, e in zip(actual[:3], expected)), (
                            name, path, x, y, tuple(actual), expected)
                    return tuple(actual[:3])

                for path in (HARD, KNOCKOUT, BLUR, CLIPPED):
                    box = node(tree, path)['bounds']
                    assert (box['width'], box['height']) == (80, 60), (path, box)
                hard, probe = node(tree, HARD), node(tree, PROBE)
                assert hard['role'] == 'button' and probe['label'] == 'Shadow-only hit probe'
                assert probe['bounds']['x'] + probe['bounds']['width']/2 == hard['bounds']['x'] + 92
                pixel(HARD, 40, 30, GOLD)  # Shadow paints before background and border.
                pixel(HARD, 1, 30, (36, 112, 128))
                pixel(HARD, 92, 30, color if mode == 0 else GROUND)
                pixel(HARD, 40, 70, color if mode == 0 else GROUND)
                pixel(HARD, -8, 30, (64, 80, 160) if mode == 1 else GROUND)
                pixel(HARD, -18, 30, GROUND)
                pixel(HARD, 110, 30, GROUND)

                pixel(KNOCKOUT, 40, 30, GROUND)  # No background: original interior stays clear.
                pixel(KNOCKOUT, 40, 2, GROUND)
                pixel(KNOCKOUT, 2, 2, (32, 64, 96))  # Outside rounded corner, inside expanded shape.
                pixel(KNOCKOUT, -7, 30, (32, 64, 96))
                pixel(KNOCKOUT, -15, 30, GROUND)

                # Independent continuous half-plane Gaussian integral. The box
                # centerline is >3sigma from either horizontal edge. Allow 3
                # sRGB bytes for discrete sampling and A8 coverage quantization.
                falloff = []
                for distance in (2, 8, 12):
                    sigma = 12 / 2
                    cutoff = math.erf(3 / math.sqrt(2))
                    coverage = (cutoff - math.erf((distance + .5) / (sigma * math.sqrt(2)))) / (2 * cutoff)
                    expected = over(GROUND, (0, 0, 0), round(255 * coverage))
                    falloff.append(pixel(BLUR, 80 + distance, 30, expected, 3)[0])
                assert falloff[0] < falloff[1] < falloff[2] < GROUND[0], falloff
                pixel(BLUR, 102, 30, GROUND)  # Beyond the finite 3sigma support.
                pixel(BLUR, 40, 30, (255, 255, 255))

                viewport, target = node(tree, VIEWPORT)['bounds'], node(tree, CLIPPED)['bounds']
                assert (viewport['width'], viewport['height']) == (110, 94), viewport
                assert (target['x'] - viewport['x'], target['y'] - viewport['y']) == (20, 20)
                pixel(CLIPPED, 85, 30, ORIGINAL)  # Inside viewport, outside box.
                pixel(CLIPPED, 95, 30, GROUND)  # Shadow continues here geometrically, but is clipped.
                pixel(CLIPPED, 40, 70, ORIGINAL)
                pixel(CLIPPED, 40, 78, GROUND)
                if os.environ.get('OUROKIT_SHADOW_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_SHADOW_CAPTURE'])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / output.name).write_bytes(output.read_bytes())
                return tree

            original = capture('original')
            peer = capture('peer-original', 'peer')
            click(PROBE)
            assert node(snapshot(), 'root/status')['label'] == 'Revision 1 · mode 0 · presses 0'
            click(HARD)
            assert node(snapshot(), 'root/status')['label'] == 'Revision 1 · mode 0 · presses 3'
            click('root/controls/cycle')
            replaced = capture('replaced', mode=1)
            same_geometry(original, replaced)
            stale(original)
            invoke('RemoveShadow')
            removed = capture('removed', mode=2)
            same_geometry(original, removed)
            stale(replaced)
            invoke('ResetShadow')
            restored = capture('restored')
            same_geometry(original, restored)
            assert snapshot('peer') == peer, 'main shadow replacement dirtied peer'
            capture('peer-retained', 'peer')
            print('PASS hard/signed-spread pixels, transparent rounded knockout, Gaussian falloff, ancestor clip, unchanged geometry and nonclickable shadow')

            before = (snapshot(), snapshot('peer'))
            generation = invoke('runtime.diagnostics')['generation']
            for invalid in ('false', '{}', '{color="#fff"}', '{color="#000000",blur=-1}',
                            '{color="#000000",x=0/0}', '{color="#000000",spread=math.huge}',
                            '{color="#000000",y="down"}', '{{color="#000000"}}'):
                atomic_write(app, fixture.replace('local invalid_shadow = nil', 'local invalid_shadow = ' + invalid))
                cli(env, 'reload', endpoint, succeeds=False)
                assert (snapshot(), snapshot('peer')) == before, ('invalid shadow changed live windows', invalid)
                assert invoke('runtime.diagnostics')['generation'] == generation
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert (snapshot(), snapshot('peer')) == before, 'later-window rejection changed live shadows'
            assert invoke('runtime.diagnostics')['generation'] == generation
            assert {w['window'] for w in invoke('runtime.inspect')['windows']} == {'main', 'peer'}
            capture('rejected-main')
            capture('rejected-peer', 'peer')
            click(HARD)
            live = snapshot()
            assert node(live, 'root/status')['label'] == 'Revision 1 · mode 0 · presses 6'

            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            accepted = capture('reloaded-main', color=RELOADED)
            accepted_peer = capture('reloaded-peer', 'peer', color=RELOADED)
            same_geometry(live, accepted)
            same_geometry(peer, accepted_peer)
            assert node(accepted, 'root/status')['label'] == 'Revision 2 · mode 0 · presses 0'
            assert node(accepted_peer, 'root/status')['label'] == 'Peer original · revision 2'
            stale(live)
            stale(peer, 'peer')
            click(PROBE)
            assert node(snapshot(), 'root/status')['label'] == 'Revision 2 · mode 0 · presses 0'
            click(HARD)
            assert node(snapshot(), 'root/status')['label'] == 'Revision 2 · mode 0 · presses 7'
            invoke('ReplaceShadow')
            fresh = capture('new-callback', mode=1, color=RELOADED)
            same_geometry(accepted, fresh)
            assert snapshot('peer') == accepted_peer
            print('PASS replacement/removal, invalid declarations, rejected later-window reload, accepted reload, old/fresh callbacks and stale tokens')
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
            os.environ['OUROKIT_SHADOW_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
