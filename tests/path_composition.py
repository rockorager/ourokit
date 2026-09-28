#!/usr/bin/env python3
"""Native path pixels, copied snapshots and transactional two-window reloads.

Run: python3 tests/path_composition.py zig-out/bin/ouroctl
Optional: --capture-dir .amp/in/artifacts/paths
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

FULL = 'root/frame/gallery/full'
CROP = 'root/frame/gallery/crop'
ORIGINAL, RELOADED = (16, 32, 48), (38, 57, 75)
REPLACED, NEW_CALLBACK = (64, 36, 56), (81, 53, 32)


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-paths-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/path-composition.lua').read_text()
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

            # Only initial Wayland configure is asynchronous. Do not retry away
            # stale-token failures in the otherwise-idle operations below.
            deadline = time.monotonic() + 8
            previous, stable_since = None, time.monotonic()
            while True:
                trees = tuple(snapshot(w) for w in ('main', 'peer'))
                now = time.monotonic()
                if trees != previous:
                    previous, stable_since = trees, now
                elif now - stable_since >= .3 and all(any(n['path'] == FULL for n in t['nodes']) for t in trees):
                    break
                assert now < deadline, ('path windows did not settle', trees)
                time.sleep(.03)

            def capture(name, window='main', full_bg=ORIGINAL, shared_bg=ORIGINAL):
                tree = snapshot(window)
                result = invoke('runtime.capture', dict(window=window, token=tree['token']))
                assert result['kind'] == 'software_scene_replay', result
                output = root / (name + '.png')
                output.write_bytes(Path(result['path']).read_bytes())
                full, crop = node(tree, FULL), node(tree, CROP)
                assert full['role'] == crop['role'] == 'image'
                assert full['label'].startswith('Full paths:') and crop['label'].startswith('Shared paths')
                a, b = full['bounds'], crop['bounds']
                assert (a['width'], a['height']) == (260, 180), a
                assert (b['width'], b['height']) == (117, 180), b
                assert b['x'] == a['x'] + 260 + 23 and b['y'] == a['y'], (a, b)

                def pixel(box, x, y, expected, tolerance=0):
                    w, h, actual = png_pixel(output, int(box['x'] + x), int(box['y'] + y))
                    assert (w, h) == (result['width'], result['height'])
                    assert actual[3] == 255 and all(abs(c - e) <= tolerance for c, e in zip(actual[:3], expected)), (
                        name, x, y, tuple(actual), expected)

                red, teal, blue = (192, 80, 32), (32, 192, 128), (64, 96, 224)
                green, gold, pink = (117, 206, 159), (232, 182, 90), (199, 125, 232)
                for box, background in ((a, full_bg), (b, shared_bg)):
                    pixel(box, 7, 8, background)
                    pixel(box, 25, 24, red)
                    pixel(box, 50, 40, over(red, teal, 128), 1)
                    pixel(box, 70, 60, over(over(red, teal, 128), blue, 160), 1)
                    pixel(box, 85, 60, gold)  # A later rectangle must cover the stroke.
                    pixel(box, 104, 60, over(over(background, teal, 128), blue, 160), 1)
                    pixel(box, 50, 90, over(background, teal, 128), 1)
                    pixel(box, 25, 115, gold)  # Open triangular fill closes implicitly.
                    pixel(box, 65, 125, background)
                    # Exact curve midpoints: quadratic (60,137.5); cubic (125,140).
                    # The empty chord point rejects accidental polyline/closure paint.
                    pixel(box, 60, 138, (239, 141, 112))
                    pixel(box, 60, 164, background)
                pixel(a, 125, 141, (121, 186, 250))
                pixel(a, 125, 165, full_bg)
                pixel(a, 150, 45, green)
                pixel(a, 190, 45, full_bg)  # Same-winding even-odd hole.
                pixel(a, 230, 45, green)
                for y, color in ((105, green), (130, gold), (155, pink)):
                    pixel(a, 175, y, color)
                    pixel(a, 151, y, full_bg if y == 105 else color)
                    pixel(a, 145, y, full_bg)
                # Off-axis point outside the round disk but inside a square cap.
                pixel(a, 149, 124, full_bg)
                pixel(a, 149, 149, pink)
                pixel(b, 120, 141, (230, 234, 240))  # Clipped cubic cannot bleed.
                if os.environ.get('OUROKIT_PATH_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_PATH_CAPTURE'])
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
            print('PASS mixed paint order, even-odd hole, implicit close, curve/cap pixels and copied nested tables')

            invoke('runtime.input', dict(window='main', token=mutated['token'], action='click', target='root/controls/replace'))
            replaced = capture('replaced', full_bg=REPLACED)
            assert 'replacements 1' in node(replaced, 'root/status')['label']
            assert node(replaced, FULL)['bounds'] == node(initial, FULL)['bounds']
            stale(mutated)
            assert snapshot('peer') == peer, 'replacement invalidated a shared original in peer'
            capture('replacement-peer', 'peer')

            before = (snapshot(), snapshot('peer'))
            generation = invoke('runtime.diagnostics')['generation']
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert (snapshot(), snapshot('peer')) == before, 'failed later-window candidate changed live drawings'
            assert invoke('runtime.diagnostics')['generation'] == generation
            assert {w['window'] for w in invoke('runtime.inspect')['windows']} == {'main', 'peer'}
            capture('rejected-main', full_bg=REPLACED)
            capture('rejected-peer', 'peer')
            invoke('ReplaceMain')  # Old closures and snapshots survive candidate VM destruction.
            live = capture('still-live', full_bg=REPLACED)
            assert 'replacements 2' in node(live, 'root/status')['label']

            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            accepted = capture('reloaded-main', full_bg=RELOADED, shared_bg=RELOADED)
            accepted_peer = capture('reloaded-peer', 'peer', full_bg=RELOADED, shared_bg=RELOADED)
            assert node(accepted, 'root/status')['label'] == 'Revision 2 · source edits 0 · replacements 0'
            assert node(accepted_peer, 'root/status')['label'] == 'Shared original · revision 2'
            for old, new in ((live, accepted), (peer, accepted_peer)):
                for path in (FULL, CROP):
                    assert node(old, path)['id'] == node(new, path)['id'], path
            stale(live)
            stale(peer, 'peer')
            invoke('runtime.input', dict(window='main', token=accepted['token'], action='click', target='root/controls/replace'))
            fresh = capture('new-callback', full_bg=NEW_CALLBACK, shared_bg=RELOADED)
            assert node(fresh, 'root/status')['label'] == 'Revision 2 · source edits 0 · replacements 1'
            stale(accepted)
            invoke('MutateSource')
            fresh = capture('reloaded-mutated', full_bg=NEW_CALLBACK, shared_bg=RELOADED)
            assert node(fresh, 'root/status')['label'] == 'Revision 2 · source edits 1 · replacements 1'
            assert snapshot('peer') == accepted_peer
            capture('reloaded-retained-peer', 'peer', full_bg=RELOADED, shared_bg=RELOADED)
            print('PASS retained sharing/crop, rejected later-window reload, accepted two-window reload, new callbacks and stale tokens')
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
            os.environ['OUROKIT_PATH_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
