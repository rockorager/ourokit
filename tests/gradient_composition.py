#!/usr/bin/env python3
"""Native retained gradients: analytical color, immutable sharing and reload.

Run: python3 tests/gradient_composition.py zig-out/bin/ouroctl
Optional: --capture-dir .amp/in/artifacts/gradients
Starts private headless Sway and D-Bus; never uses the caller's desktop.
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

RAMP, FADE, HARD = 'root/samples/ramp', 'root/samples/fade/paint', 'root/samples/hard'
FULL, CROP = 'root/frame/gallery/full', 'root/frame/gallery/crop'
BLACK, WHITE, GREEN, YELLOW = (0, 0, 0, 255), (255, 255, 255, 255), (0, 255, 0, 255), (255, 255, 0, 255)
GROUND = (24, 48, 72)


def linear(start, end, t, background=(255, 255, 255)):
    """Independent ideal premultiplied linear-light interpolation and source-over."""
    def decode(byte):
        value = byte / 255
        return value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4

    def encode(value):
        return round(255 * (12.92 * value if value <= .0031308 else 1.055 * value ** (1 / 2.4) - .055))

    t = min(1, max(0, t))
    a, b = start[3] / 255, end[3] / 255
    alpha = a * (1 - t) + b * t
    return tuple(encode(decode(start[c]) * a * (1 - t) + decode(end[c]) * b * t +
                        decode(background[c]) * (1 - alpha)) for c in range(3))


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-gradients-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/gradient-composition.lua').read_text()
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
                elif now - stable_since >= .3 and all(any(n['path'] == FULL for n in t['nodes']) for t in trees):
                    break
                assert now < deadline, ('gradient windows did not settle', trees)
                time.sleep(.03)

            def click(path):
                tree = snapshot()
                invoke('runtime.input', dict(window='main', token=tree['token'], action='click', target=path))

            def stale(tree, window='main'):
                reply = call(endpoint, 'runtime.capture', dict(window=window, token=tree['token']))
                assert reply.get('isError') and reply['structuredContent']['error']['code'] == 'StaleDevelopmentTarget', reply

            def same_geometry(old, new):
                for path in (RAMP, FADE, HARD, FULL, CROP):
                    a, b = node(old, path), node(new, path)
                    assert (a['id'], a['bounds']) == (b['id'], b['bounds']), (path, a, b)

            def capture(name, window='main', ramp=(BLACK, WHITE), recording=(BLACK, WHITE)):
                tree = snapshot(window)
                result = invoke('runtime.capture', dict(window=window, token=tree['token']))
                assert result['kind'] == 'software_scene_replay', result
                output = root / (name + '.png')
                output.write_bytes(Path(result['path']).read_bytes())

                def pixel(path, x, y, expected, tolerance=0):
                    box = node(tree, path)['bounds']
                    w, h, actual = png_pixel(output, int(box['x'] + x), int(box['y'] + y))
                    assert (w, h) == (result['width'], result['height'])
                    assert actual[3] == 255 and all(abs(c - e) <= tolerance for c, e in zip(actual[:3], expected)), (
                        name, path, x, y, tuple(actual), expected)

                for path in (RAMP, FADE, HARD):
                    box = node(tree, path)['bounds']
                    assert (box['width'], box['height']) == (180, 80), (path, box)
                full, crop = node(tree, FULL), node(tree, CROP)
                assert full['role'] == crop['role'] == 'image'
                assert full['label'].startswith('Shared gradient') and crop['label'].startswith('Same gradient')
                a, b = full['bounds'], crop['bounds']
                assert (a['width'], a['height']) == (240, 160), a
                assert (b['width'], b['height']) == (117, 160), b
                assert (b['x'] - a['x'], b['y'] - a['y']) == (260, 0), (a, b)

                # Endpoints at .5 and 160.5 align sample centers exactly. Ideal
                # float math stays independent of native UNORM16 arithmetic;
                # allow two bytes for finite interpolation/encoding precision.
                for x in (0, 20, 60, 80, 120, 160, 175):
                    pixel(RAMP, x, 30, linear(*ramp, x / 160), 2)
                if ramp == (BLACK, WHITE):
                    pixel(RAMP, 80, 30, (188, 188, 188), 1)  # Not encoded-space 128.
                for x in (20, 80, 120, 175):
                    pixel(FADE, x, 30, linear((255, 0, 0, 255), (0, 0, 255, 0), x / 160), 2)
                pixel(FADE, 80, 30, (255, 188, 188), 1)  # Invisible blue contributes no hue.
                pixel(HARD, 79, 30, (48, 64, 80))
                pixel(HARD, 80, 30, (208, 144, 32))  # Last duplicate stop wins exactly here.
                pixel(HARD, 81, 30, (208, 144, 32))

                for path in (FULL, CROP):
                    pixel(path, 5, 25, GROUND)
                    # Different primitive origins (20, 60, 35) must NOT rebase
                    # the shared recording-local gradient. Crop never stretches.
                    for x, y in ((40, 25), (80, 25), (80, 80), (100, 80), (80, 135)):
                        pixel(path, x, y, linear(*recording, x / 160, GROUND), 2)
                pixel(FULL, 190, 80, recording[1][:3])
                pixel(CROP, 120, 80, GROUND)  # Beyond the canvas clip.
                if os.environ.get('OUROKIT_GRADIENT_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_GRADIENT_CAPTURE'])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / output.name).write_bytes(output.read_bytes())
                return tree

            original = capture('original')
            peer = capture('peer-original', 'peer')
            invoke('MutateSource')
            mutated = capture('source-mutated')
            same_geometry(original, mutated)
            assert node(mutated, 'root/status')['label'] == 'Revision 1 · source edits 1 · replacement count 0'
            assert snapshot('peer') == peer, 'source mutation dirtied peer'
            capture('peer-source-mutated', 'peer')
            click('root/controls/replace')
            replaced = capture('replaced', ramp=(WHITE, BLACK))
            same_geometry(original, replaced)
            assert node(replaced, 'root/status')['label'] == 'Revision 1 · source edits 1 · replacement count 3'
            stale(mutated)
            assert snapshot('peer') == peer, 'main gradient replacement dirtied peer'
            capture('peer-retained', 'peer')
            print('PASS linear-light and premultiplied pixels, hard stops, recording-local paint/crop, copied nested tables and retained identities')

            before = (snapshot(), snapshot('peer'))
            generation = invoke('runtime.diagnostics')['generation']
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert (snapshot(), snapshot('peer')) == before, 'later-window rejection changed live gradients'
            assert invoke('runtime.diagnostics')['generation'] == generation
            assert {w['window'] for w in invoke('runtime.inspect')['windows']} == {'main', 'peer'}
            capture('rejected-main', ramp=(WHITE, BLACK))
            capture('rejected-peer', 'peer')
            invoke('ReplaceMain')
            live = capture('old-callback', ramp=(WHITE, BLACK))
            assert node(live, 'root/status')['label'] == 'Revision 1 · source edits 1 · replacement count 6'

            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            accepted = capture('reloaded-main', ramp=(BLACK, GREEN), recording=(BLACK, GREEN))
            accepted_peer = capture('reloaded-peer', 'peer', ramp=(BLACK, GREEN), recording=(BLACK, GREEN))
            same_geometry(live, accepted)
            same_geometry(peer, accepted_peer)
            assert node(accepted, 'root/status')['label'] == 'Revision 2 · source edits 0 · replacement count 0'
            assert node(accepted_peer, 'root/status')['label'] == 'Peer original · revision 2'
            stale(live)
            stale(peer, 'peer')
            invoke('MutateSource')
            fresh = capture('reloaded-mutated', ramp=(BLACK, GREEN), recording=(BLACK, GREEN))
            assert node(fresh, 'root/status')['label'] == 'Revision 2 · source edits 1 · replacement count 0'
            click('root/controls/replace')
            fresh = capture('new-callback', ramp=(YELLOW, BLACK), recording=(BLACK, GREEN))
            same_geometry(accepted, fresh)
            assert node(fresh, 'root/status')['label'] == 'Revision 2 · source edits 1 · replacement count 7'
            assert snapshot('peer') == accepted_peer
            capture('peer-reloaded-retained', 'peer', ramp=(BLACK, GREEN), recording=(BLACK, GREEN))
            print('PASS shared windows, rejected later-window reload, accepted fresh gradients/callbacks and stale tokens')
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
            os.environ['OUROKIT_GRADIENT_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
