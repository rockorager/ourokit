#!/usr/bin/env python3
"""Native group opacity: independent pixels, invisible input, animation and reload.

Run: python3 tests/opacity_composition.py zig-out/bin/ouroctl
Optional: --capture-dir .amp/in/artifacts/opacity
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

GROUP = 'root/gallery/mutable/layout/motion/group'
OUTER = 'root/gallery/nested/layout/outer'
INNER = OUTER + '/inner'
DECORATION = 'root/gallery/decoration/layout/group'
CLIP = 'root/gallery/clipping/layout/clip'
CLIPPED = CLIP + '/layout/group'
GROUND, RED = (232, 238, 244), (192, 80, 48)
ORIGINAL, RELOADED = (50, 108, 186), (36, 180, 138)


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-opacity-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/opacity-composition.lua').read_text()
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
                assert process.poll() is None, 'opacity application exited during startup'
                try:
                    trees = tuple(snapshot(w) for w in ('main', 'peer'))
                except ConnectionRefusedError:
                    # A bound socket can appear before the listener is ready.
                    trees = None
                now = time.monotonic()
                if trees != previous:
                    previous, stable_since = trees, now
                elif trees is not None and now - stable_since >= .3 and all(any(n['path'] == GROUP for n in t['nodes']) for t in trees):
                    break
                assert now < deadline, ('opacity windows did not settle', trees)
                time.sleep(.03)

            def click(path):
                tree = snapshot()
                invoke('runtime.input', dict(window='main', token=tree['token'], action='click', target=path))

            def status(revision, count):
                actual = node(snapshot(), 'root/status')['label']
                assert actual == f'Revision {revision} · count {count}', actual

            def alpha(tree):
                return float(node(tree, GROUP)['label'].removeprefix('Opacity '))

            def same_geometry(old, new):
                for path in (GROUP, GROUP + '/paint', OUTER, INNER, DECORATION, CLIP, CLIPPED):
                    a, b = node(old, path), node(new, path)
                    assert (a['id'], a['bounds']) == (b['id'], b['bounds']), (path, a, b)

            def stale(tree, window='main'):
                reply = call(endpoint, 'runtime.capture', dict(window=window, token=tree['token']))
                assert reply.get('isError') and reply['structuredContent']['error']['code'] == 'StaleDevelopmentTarget', reply

            def capture(name, window='main', expected_alpha=.5, color=ORIGINAL):
                tree = snapshot(window)
                result = invoke('runtime.capture', dict(window=window, token=tree['token']))
                assert result['kind'] == 'software_scene_replay', result
                assert alpha(tree) == expected_alpha, (name, alpha(tree), expected_alpha)
                output = root / (name + '.png')
                output.write_bytes(Path(result['path']).read_bytes())
                if os.environ.get('OUROKIT_OPACITY_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_OPACITY_CAPTURE'])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / output.name).write_bytes(output.read_bytes())

                def pixel(path, x, y, foreground, opacity=1):
                    box = node(tree, path)['bounds']
                    w, h, actual = png_pixel(output, int(box['x'] + x), int(box['y'] + y))
                    assert (w, h) == (result['width'], result['height'])
                    # Independent sRGB -> linear source-over -> sRGB reference.
                    # Allow two byte levels for the native UNORM16 intermediate.
                    expected = (*over(GROUND, foreground, opacity * 255), 255)
                    assert all(abs(a - b) <= 2 for a, b in zip(actual, expected)), (name, path, x, y, actual, expected)

                for path, opacity in ((GROUP, expected_alpha), (INNER, .25)):
                    bounds = node(tree, path)['bounds']
                    assert (bounds['width'], bounds['height']) == (120, 100), bounds
                    pixel(path, 15, 15, RED, opacity)
                    pixel(path, 55, 35, color, opacity)  # Blue covers red before isolation fades.
                    pixel(path, 100, 50, color, opacity)  # Blue alone must match the overlap.
                    pixel(path, 10, 95, GROUND)  # Transparent layer area preserves the backdrop.
                assert node(tree, GROUP)['role'] == 'button'
                assert node(tree, GROUP)['enabled']
                pixel(DECORATION, 1, 30, (36, 112, 128), .5)  # Own border.
                pixel(DECORATION, 60, 40, (232, 182, 90), .5)  # Own background.
                pixel(DECORATION, 20, 20, (56, 148, 100), .5)  # Opaque child replaces background.
                pixel(DECORATION, 90, 30, (32, 48, 64), .5)  # Shadow is in the same group.
                pixel(DECORATION, 40, 66, (32, 48, 64), .5)
                pixel(DECORATION, -4, 30, GROUND)
                pixel(CLIP, 2, 2, GROUND)
                pixel(CLIP, 40, 2, RED, .5)
                pixel(CLIP, 55, 35, color, .5)
                pixel(CLIP, 98, 87, GROUND)
                pixel(CLIP, 105, 35, GROUND)  # Recording extends here but ancestor clip does not.
                return tree

            original = capture('original')
            peer = capture('peer-original', 'peer')
            click(GROUP)
            status(1, 3)
            assert node(snapshot(), GROUP)['focused']
            invoke('Zero')
            zero = capture('zero', expected_alpha=0)
            same_geometry(original, zero)
            assert node(zero, GROUP)['focused'], 'opacity zero lost keyboard focus'
            stale(original)
            click(GROUP)
            status(1, 6)
            capture('invisible-hit', expected_alpha=0)
            invoke('Full')
            full = capture('full', expected_alpha=1)
            same_geometry(original, full)
            invoke('Half')
            half = capture('half-restored')
            same_geometry(original, half)
            assert snapshot('peer') == peer, 'main opacity changes dirtied peer'
            print('PASS isolated overlap, nested opacity, own paint/shadow, rounded ancestor clipping, stable IDs/bounds and zero-opacity focus/input')

            invoke('Fade')
            deadline = time.monotonic() + 6
            previous_alpha, intermediate = -1, []
            while True:
                moving = snapshot()
                value = alpha(moving)
                assert previous_alpha <= value <= 1, ('fade moved backwards', previous_alpha, value)
                same_geometry(half, moving)
                if .15 < value < .85 and (not intermediate or value > alpha(intermediate[-1]) + .05):
                    intermediate.append(moving)
                if value == 1:
                    break
                previous_alpha = value
                assert time.monotonic() < deadline, 'fade did not reach exact endpoint'
                time.sleep(.02)
            assert len(intermediate) >= 2, ('no increasing intermediate opacity samples', [alpha(t) for t in intermediate])
            # Heavy Debug rendering can invalidate every inspect→capture token
            # during motion. Check native progress directly, then capture the
            # settled endpoint; static 0/.5/1 captures independently verify pixels.
            finished = capture('animation-final', expected_alpha=1)
            same_geometry(moving, finished)
            stale(intermediate[0])
            time.sleep(.08)  # Let the last submitted frame drain before checking idle builds.
            def builds():
                return invoke('runtime.metrics', {'window': 'main'})['windows'][0]['metrics']['builds']['count']
            idle_builds = builds()
            for _ in range(3):
                time.sleep(.08)
                assert builds() == idle_builds, 'completed fade kept rebuilding'
            assert snapshot('peer') == peer, 'animation dirtied peer'
            invoke('Half')
            capture('animation-reset')
            print('PASS bounded native opacity animation: increasing intermediate samples, exact endpoint pixels, retained geometry and idle completion')

            before = (snapshot(), snapshot('peer'))
            generation = invoke('runtime.diagnostics')['generation']
            for invalid in ('-.1', '1.1', '0/0', 'math.huge', '"half"', 'false'):
                atomic_write(app, fixture.replace('local invalid_opacity = nil', 'local invalid_opacity = ' + invalid))
                cli(env, 'reload', endpoint, succeeds=False)
                assert (snapshot(), snapshot('peer')) == before, ('invalid opacity changed live windows', invalid)
                assert invoke('runtime.diagnostics')['generation'] == generation
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert (snapshot(), snapshot('peer')) == before, 'later-window rejection changed live groups'
            assert invoke('runtime.diagnostics')['generation'] == generation
            assert {w['window'] for w in invoke('runtime.inspect')['windows']} == {'main', 'peer'}
            capture('rejected-main')
            capture('rejected-peer', 'peer')
            click(GROUP)
            live = capture('old-callback')
            status(1, 9)

            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            accepted = capture('reloaded-main', color=RELOADED)
            accepted_peer = capture('reloaded-peer', 'peer', color=RELOADED)
            same_geometry(live, accepted)
            same_geometry(peer, accepted_peer)
            status(2, 0)
            assert node(accepted_peer, 'root/status')['label'] == 'Peer revision 2'
            stale(live)
            stale(peer, 'peer')
            invoke('Zero')
            click(GROUP)
            fresh = capture('new-invisible-callback', expected_alpha=0, color=RELOADED)
            status(2, 7)
            same_geometry(accepted, fresh)
            invoke('Full')
            capture('new-full', expected_alpha=1, color=RELOADED)
            assert snapshot('peer') == accepted_peer
            print('PASS invalid opacity rejection, atomic two-window reload, retained/fresh callbacks, stale tokens and post-reload zero/one transitions')
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
            os.environ['OUROKIT_OPACITY_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
