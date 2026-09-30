#!/usr/bin/env python3
"""Exercise Lua drawing snapshots, ordered pixels, sharing and transactional reload.

Run: python3 tests/drawing_composition.py zig-out/bin/ouroctl
Optional: --capture-dir .amp/in/artifacts/drawings
Starts private headless Sway and D-Bus; requires ouro.drawing support.
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

GALLERY = 'root/frame/gallery'
FULL, CROP = GALLERY + '/full', GALLERY + '/crop'


def over(background, foreground, alpha):
    # Independent reference: straight sRGB bytes -> linear source-over -> sRGB.
    def decode(value):
        value /= 255
        return value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4

    def encode(value):
        return round(255 * (12.92 * value if value <= .0031308 else 1.055 * value ** (1 / 2.4) - .055))

    return tuple(encode(decode(f) * alpha / 255 + decode(b) * (1 - alpha / 255))
                 for b, f in zip(background, foreground))


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-drawings-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/drawing-composition.lua').read_text()
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

            # Initial configure is asynchronous; all subsequent operations are
            # idle and must use a fresh token without hiding stale-token errors.
            deadline = time.monotonic() + 8
            previous, stable_since = None, time.monotonic()
            while True:
                trees = tuple(snapshot(w) for w in ('main', 'peer'))
                now = time.monotonic()
                if trees != previous:
                    previous, stable_since = trees, now
                elif now - stable_since >= .3 and all(any(n['path'] == FULL for n in t['nodes']) for t in trees):
                    break
                assert now < deadline, ('drawing windows did not settle', trees)
                time.sleep(.03)

            def capture(name, window='main', full_bg=(16, 32, 48), shared_bg=(16, 32, 48)):
                tree = snapshot(window)
                result = invoke('runtime.capture', dict(window=window, token=tree['token']))
                assert result['kind'] == 'software_scene_replay', result
                output = root / (name + '.png')
                output.write_bytes(Path(result['path']).read_bytes())
                full, crop = node(tree, FULL), node(tree, CROP)
                assert full['role'] == crop['role'] == 'image'
                assert full['label'].startswith('Full drawing:') and crop['label'].startswith('Same recording')
                a, b = full['bounds'], crop['bounds']
                assert (a['width'], a['height']) == (240, 150), a
                assert (b['width'], b['height']) == (117, 150), b
                assert b['x'] == a['x'] + 240 + 23 and b['y'] == a['y'], (a, b)

                def pixel(box, x, y, expected, tolerance=0):
                    w, h, actual = png_pixel(output, int(box['x'] + x), int(box['y'] + y))
                    assert (w, h) == (result['width'], result['height'])
                    assert actual[3] == 255 and all(abs(c - e) <= tolerance for c, e in zip(actual[:3], expected)), (
                        name, x, y, tuple(actual), expected)

                red, teal, blue = (192, 80, 32), (32, 192, 128), (64, 96, 224)
                for box, background in ((a, full_bg), (b, shared_bg)):
                    pixel(box, 7, 8, background)
                    pixel(box, 29, 27, red)
                    pixel(box, 70, 45, over(red, teal, 128), 1)
                    # Different alphas and asymmetric points discriminate both
                    # paint order and origin/extent mistakes. One byte allows
                    # the renderer's finite linear-light working precision.
                    pixel(box, 100, 70, over(over(red, teal, 128), blue, 160), 1)
                    pixel(box, 100, 100, over(background, blue, 160), 1)
                    pixel(box, 2, 126, (117, 206, 159))
                    pixel(box, 37, 126, background)
                pixel(a, 197, 28, (232, 182, 90))
                pixel(a, 197, 105, (232, 182, 90))
                pixel(a, 175, 25, full_bg)  # Outside the rounded corner.
                pixel(a, 220, 111, full_bg)
                pixel(b, 119, 70, (230, 234, 240))  # Beyond the canvas clip.
                pixel(b, -3, 126, (230, 234, 240))  # Negative origin cannot bleed.
                if os.environ.get('OUROKIT_DRAWING_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_DRAWING_CAPTURE'])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / output.name).write_bytes(output.read_bytes())
                return tree

            def stale(tree, window='main'):
                reply = call(endpoint, 'runtime.capture', dict(window=window, token=tree['token']))
                assert reply.get('isError') and reply['structuredContent']['error']['code'] == 'StaleDevelopmentTarget', reply

            initial = capture('original')
            peer = capture('shared-peer', 'peer')
            invoke('MutateSource')
            mutated = capture('source-mutated')
            assert 'source edits 1' in node(mutated, 'root/status')['label']
            assert node(mutated, FULL)['id'] == node(initial, FULL)['id']
            assert snapshot('peer') == peer, 'source mutation dirtied a non-subscribing window'
            capture('source-mutated-peer', 'peer')
            print('PASS copied tables survive mutation; shared recordings, ordered alpha, rounded corners and unscaled crop')

            invoke('runtime.input', dict(window='main', token=mutated['token'], action='click', target='root/controls/replace'))
            replaced = capture('replaced', full_bg=(64, 36, 56))
            assert 'replacements 1' in node(replaced, 'root/status')['label']
            assert node(replaced, FULL)['id'] == node(initial, FULL)['id']
            assert node(replaced, FULL)['bounds'] == node(initial, FULL)['bounds']
            stale(mutated)
            assert snapshot('peer') == peer, 'main replacement invalidated a shared original in peer'
            capture('replacement-peer', 'peer')
            print('PASS same-size reactive replacement invalidates old tokens without replacing peer/cropped original')

            before = (snapshot(), snapshot('peer'))
            generation = invoke('runtime.diagnostics')['generation']
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert (snapshot(), snapshot('peer')) == before, 'failed candidate changed live drawings'
            assert invoke('runtime.diagnostics')['generation'] == generation
            assert {w['window'] for w in invoke('runtime.inspect')['windows']} == {'main', 'peer'}
            capture('rejected-main', full_bg=(64, 36, 56))
            capture('rejected-peer', 'peer')

            # Constructor errors must not discard resources from the live VM.
            declaration = 'local shared = o.drawing(source)'
            for invalid in (
                '{width=0/0,height=1,rectangles={}}',
                '{width=1,height=1,rectangles={{y=0,width=1,height=1,color="#ffffff"}}}',
                '{width=1,height=1,rectangles={[2]={x=0,y=0,width=1,height=1,color="#ffffff"}}}',
                '{width=1,height=1,rectangles={{x=0,y=0,width=1,height=1,color="#fff"}}}',
                '{width=1,height=1,rectangles={{x=0,y=0,width=1,height=1,color="#ffffff",corner_radius=-1}}}',
            ):
                atomic_write(app, fixture.replace(declaration, 'o.drawing(' + invalid + ')\n' + declaration))
                cli(env, 'reload', endpoint, succeeds=False)
                assert (snapshot(), snapshot('peer')) == before, invalid
                assert invoke('runtime.diagnostics')['generation'] == generation

            # Old closures and userdata still work after the candidate VM dies.
            invoke('ReplaceMain')
            live = capture('still-live', full_bg=(64, 36, 56))
            assert 'replacements 2' in node(live, 'root/status')['label']
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            accepted = capture('reloaded-main', full_bg=(38, 57, 75), shared_bg=(38, 57, 75))
            accepted_peer = capture('reloaded-peer', 'peer', full_bg=(38, 57, 75), shared_bg=(38, 57, 75))
            assert 'Revision 2 · source edits 0 · replacements 0' == node(accepted, 'root/status')['label']
            for old, new in ((live, accepted), (peer, accepted_peer)):
                for path in (FULL, CROP):
                    assert node(old, path)['id'] == node(new, path)['id'], path
            stale(live)
            stale(peer, 'peer')
            invoke('MutateSource')
            capture('reloaded-mutated', full_bg=(38, 57, 75), shared_bg=(38, 57, 75))
            assert 'Revision 2 · source edits 1' in node(snapshot(), 'root/status')['label']
            print('PASS failed build/constructor reloads retain live drawings; accepted reload replaces both windows and closures')
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
            os.environ['OUROKIT_DRAWING_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
