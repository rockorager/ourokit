#!/usr/bin/env python3
"""Exercise native transition reversal, input, idle completion and atomic reload."""
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

SLIDE = 'root/gallery/slide/viewport/motion/card'
FADE = 'root/gallery/fade/viewport/motion/card'
HOVER = 'root/gallery/hover/viewport/motion/card'


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-transitions-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/transition-composition.lua').read_text()
        app = root / 'app.lua'
        atomic_write(app, fixture)
        with (root / 'stderr').open('w') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=log)
        try:
            endpoint = development_path(root, process)

            def invoke(name, args=None):
                reply = call(endpoint, name, args)
                assert not reply.get('isError') and 'rpcError' not in reply, (name, reply, call(endpoint, 'runtime.diagnostics'))
                return reply['structuredContent']

            def snapshot(window='main'):
                return invoke('runtime.inspect', {'window': window})['windows'][0]

            def value(tree, path=SLIDE):
                return float(node(tree, path)['label'].split()[-1])

            def wait(predicate, timeout=6, startup=False):
                deadline = time.monotonic() + timeout
                while True:
                    try:
                        tree = snapshot()
                    except ConnectionRefusedError:
                        if not startup:
                            raise
                        tree = None
                    if tree and predicate(tree):
                        return tree
                    assert time.monotonic() < deadline, ('transition did not settle', tree)
                    time.sleep(.02)

            def metric(name, window='main'):
                return invoke('runtime.metrics', {'window': window})['windows'][0]['metrics'][name]['count']

            def idle():
                time.sleep(.1)
                before = [metric('builds', w) for w in ('main', 'peer')]
                for _ in range(3):
                    time.sleep(.1)
                    assert [metric('builds', w) for w in ('main', 'peer')] == before, 'settled transition kept rebuilding'

            def input(action, path):
                tree = snapshot()
                invoke('runtime.input', dict(window='main', token=tree['token'], action=action, target=path))

            def capture(name, target):
                tree = snapshot()
                assert value(tree) == value(tree, FADE) == target
                viewport = node(tree, 'root/gallery/slide/viewport')['bounds']
                card = node(tree, SLIDE)['bounds']
                assert card['width'] == 80 and abs(card['x'] - viewport['x'] - 10 - 80*target) < .001, (card, viewport, target)
                result = invoke('runtime.capture', dict(window='main', token=tree['token']))
                image = Path(result['path'])
                fade = node(tree, FADE)['bounds']
                expected = over((232, 238, 244), (56, 154, 192), 255*(.25+.75*target))
                _, _, actual = png_pixel(image, int(fade['x']+20), int(fade['y']+20))
                assert all(abs(a-b) <= 2 for a, b in zip(actual, (*expected, 255))), (actual, expected)
                _, _, actual = png_pixel(image, int(card['x']+15), int(card['y']+20))
                assert actual == bytes((56, 154, 192, 255)), actual
                if os.environ.get('OUROKIT_TRANSITION_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_TRANSITION_CAPTURE'])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / (name+'.png')).write_bytes(image.read_bytes())
                return tree

            wait(lambda t: any(n['path'] == SLIDE for n in t['nodes']), 8, startup=True)
            idle()
            original = capture('closed', 0)
            peer = snapshot('peer')
            assert value(peer) == .35
            invoke('Open')
            forward = wait(lambda t: .3 < value(t) < .7)
            invoke('Close')
            reverse = snapshot()
            assert .1 < value(reverse) < .85 and abs(value(reverse)-value(forward)) < .2
            lower = wait(lambda t: 0 < value(t) < value(reverse)-.06)
            invoke('Open')
            second = snapshot()
            assert abs(value(second)-value(lower)) < .2 and value(second) < .85
            invoke('Noise')
            wait(lambda t: value(t) == 1)
            assert snapshot('peer') == peer, 'main transition dirtied independent peer'
            # Noise changes only status text, so check no layout while the
            # transition itself runs, separately from that unrelated update.
            layouts = metric('layouts')
            invoke('Close')
            wait(lambda t: value(t) == 0)
            assert metric('layouts') == layouts
            for path in (SLIDE, FADE, HOVER):
                assert node(snapshot(), path)['id'] == node(original, path)['id']
            idle()
            capture('reversed', 0)
            input('hover', HOVER)
            wait(lambda t: value(t, HOVER) == 1.12)
            capture('hovered', 0)
            input('hover', 'root/controls/open')
            wait(lambda t: value(t, HOVER) == 1)
            input('click', 'root/controls/open')
            wait(lambda t: value(t) == 1)
            idle()
            capture('open', 1)
            input('click', SLIDE)
            assert node(snapshot(), 'root/status')['label'] == 'Hits 3 · unrelated 1'
            print('PASS native reversals, hover scaling, slide/fade pixels, retained identity, no relayout and idle completion')

            invoke('Close')
            wait(lambda t: .2 < value(t) < .8)
            invoke('Retime')
            wait(lambda t: value(t) == 0)
            invoke('Open')
            moving = wait(lambda t: .2 < value(t) < .6)
            generation = invoke('runtime.diagnostics')['generation']
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            after = snapshot()
            assert value(after) >= value(moving), 'rejected reload reset the live transition'
            assert node(after, SLIDE)['id'] == node(moving, SLIDE)['id']
            assert invoke('runtime.diagnostics')['generation'] == generation
            wait(lambda t: value(t) == 1)
            invoke('Close')
            wait(lambda t: .2 < value(t) < .8)
            invoke('Instant')
            assert value(snapshot()) == 1
            invoke('Remove')
            assert all(n['path'] != SLIDE for n in snapshot()['nodes'])
            idle()
            invoke('Show')
            assert value(snapshot()) == 1
            idle()
            before, peer_before = snapshot(), snapshot('peer')
            generation = invoke('runtime.diagnostics')['generation']
            for invalid in ('false', "'1'", '0/0', 'math.huge'):
                atomic_write(app, fixture.replace('local invalid = nil', 'local invalid = '+invalid))
                cli(env, 'reload', endpoint, succeeds=False)
                assert (snapshot(), snapshot('peer')) == (before, peer_before)
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert (snapshot(), snapshot('peer')) == (before, peer_before)
            assert invoke('runtime.diagnostics')['generation'] == generation
            input('click', SLIDE)
            assert node(snapshot(), 'root/status')['label'] == 'Hits 6 · unrelated 1'
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            assert value(snapshot()) == 0 and value(snapshot('peer')) == .35
            stale = call(endpoint, 'runtime.capture', dict(window='main', token=before['token']))
            assert stale['isError'] and stale['structuredContent']['error']['code'] == 'StaleDevelopmentTarget'
            input('click', SLIDE)
            assert node(snapshot(), 'root/status')['label'] == 'Hits 7 · unrelated 0'
            idle()
            capture('reloaded', 0)
            print('PASS timing changes, instant settlement, removal/remount and atomic reload with old/fresh callbacks')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            errors = (root / 'stderr').read_text()
            if sys.exc_info()[0] is not None:
                print(errors, file=sys.stderr)
            assert process.returncode in (0, 128+signal.SIGTERM), (process.returncode, errors)
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
            os.environ['OUROKIT_TRANSITION_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
