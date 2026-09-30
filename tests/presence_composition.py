#!/usr/bin/env python3
"""Exercise native retained exits, reversals, input eligibility and atomic reload."""
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

PANEL = 'root/gallery/panel/viewport/layers/life/state/card'
UNDER = 'root/gallery/panel/viewport/layers/under'
TOAST = 'root/gallery/toast/viewport/life/toast'


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-presence-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/presence-composition.lua').read_text()
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

            def panel(tree):
                return next((n for n in tree['nodes'] if n['path'] == PANEL), None)

            def value(tree):
                return float(panel(tree)['label'].split()[1])

            def wait(predicate, startup=False):
                deadline = time.monotonic() + 8
                while True:
                    try:
                        tree = snapshot()
                    except ConnectionRefusedError:
                        if not startup:
                            raise
                        tree = None
                    if tree and predicate(tree):
                        return tree
                    assert time.monotonic() < deadline, ('presence did not settle', tree)
                    time.sleep(.02)

            def input(action, path):
                tree = snapshot()
                invoke('runtime.input', dict(window='main', token=tree['token'], action=action, target=path))

            def idle():
                time.sleep(.1)
                def counts():
                    return [invoke('runtime.metrics', {'window': w})['windows'][0]['metrics']['builds']['count']
                            for w in ('main', 'peer')]
                before = counts()
                time.sleep(.35)
                assert counts() == before, 'settled presence kept rebuilding'

            def capture(name, visible):
                tree = snapshot()
                assert bool(panel(tree)) == visible
                result = invoke('runtime.capture', dict(window='main', token=tree['token']))
                image = Path(result['path'])
                bounds = node(tree, UNDER)['bounds']
                _, height, actual = png_pixel(image, int(bounds['x']+20), int(bounds['y']+20))
                expected = (56, 154, 192, 255) if visible else (232, 238, 244, 255)
                assert actual == bytes(expected), (actual, expected)
                status = node(tree, 'root/status')['bounds']
                assert status['y'] + status['height'] <= height, 'status clipped below window'
                if os.environ.get('OUROKIT_PRESENCE_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_PRESENCE_CAPTURE'])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / (name+'.png')).write_bytes(image.read_bytes())
                return tree

            wait(lambda t: panel(t) and value(t) == 1, startup=True)
            idle()
            original = capture('entered', True)
            peer = snapshot('peer')
            input('click', PANEL)
            assert panel(snapshot())['label'].endswith('count 1')
            invoke('Close')
            exiting = wait(lambda t: panel(t) and .3 < value(t) < .85)
            assert not panel(exiting)['enabled']
            assert panel(exiting)['id'] == panel(original)['id']
            # Exact input rejection/fall-through during exit is covered with a
            # controlled native clock in development_test.zig. Debug rendering
            # can stale every inspect/input pair while this real clock moves.
            invoke('Open')
            reopened = wait(lambda t: panel(t) and value(t) == 1)
            assert panel(reopened)['id'] == panel(original)['id']
            assert panel(reopened)['label'].endswith('count 1')
            assert node(reopened, 'root/status')['label'] == 'Hits 3 · underlying 0'
            assert snapshot('peer') == peer
            idle()
            capture('reopened', True)
            input('click', TOAST+'/content/dismiss')
            wait(lambda t: panel(t) is None)
            idle()
            capture('exited', False)
            input('click', UNDER)
            assert node(snapshot(), 'root/status')['label'] == 'Hits 3 · underlying 1'
            input('click', 'root/controls/open')
            wait(lambda t: panel(t) and value(t) == 1)
            assert panel(snapshot())['label'].endswith('count 0'), 'completed exit retained stale component state'
            print('PASS native entry/exit, retained reversal state, disabled exit semantics, post-exit input, idle and independent peer')

            invoke('Close')
            moving = wait(lambda t: panel(t) and .6 < value(t) < .95)
            generation = invoke('runtime.diagnostics')['generation']
            atomic_write(app, fixture.replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            after = snapshot()
            if panel(after):
                assert value(after) <= value(moving) and not panel(after)['enabled']
                assert panel(after)['id'] == panel(moving)['id']
            assert invoke('runtime.diagnostics')['generation'] == generation
            wait(lambda t: panel(t) is None)
            invoke('Open')
            wait(lambda t: panel(t) and value(t) == 1)
            idle()
            before, peer_before = snapshot(), snapshot('peer')
            for invalid in ('1', "'false'"):
                atomic_write(app, fixture.replace('local invalid = nil', 'local invalid = '+invalid))
                cli(env, 'reload', endpoint, succeeds=False)
                assert (snapshot(), snapshot('peer')) == (before, peer_before)
            input('click', PANEL)
            assert node(snapshot(), 'root/status')['label'] == 'Hits 6 · underlying 1'
            invoke('Close')
            wait(lambda t: panel(t) and value(t) < .8)
            invoke('Remove')
            assert panel(snapshot()) is None
            idle()
            invoke('Instant')
            invoke('Open')
            invoke('Mount')
            assert value(snapshot()) == 1
            invoke('Close')
            assert panel(snapshot()) is None
            idle()
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            wait(lambda t: panel(t) and value(t) == 1)
            stale = call(endpoint, 'runtime.capture', dict(window='main', token=before['token']))
            assert stale['isError'] and stale['structuredContent']['error']['code'] == 'StaleDevelopmentTarget'
            input('click', PANEL)
            assert node(snapshot(), 'root/status')['label'] == 'Hits 7 · underlying 0'
            idle()
            capture('reloaded', True)
            # Teardown while an exit is pending must not retain timers or tasks.
            invoke('Close')
            print('PASS removal/zero duration, rejected active and idle reload, accepted reload, fresh callbacks and stale tokens')
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
            os.environ['OUROKIT_PRESENCE_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
