#!/usr/bin/env python3
"""Exercise native elapsed-time animation, identity, cancellation and reload.

Run: python3 tests/animation_composition.py zig-out/bin/ouroctl
Optional: --capture-dir .amp/in/artifacts/animations
Always starts private headless Sway and D-Bus; no clock-stepping API is used.
Requires an ouroctl implementing ouro.animation (not the pre-animation binary).
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

TRACK = 'root/tracks/motion'
BAR = TRACK + '/bar'
VALUE = BAR + '/content/value'
HIT = BAR + '/content/hit'


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-animations-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/animation-composition.lua').read_text()
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

            def state():
                return invoke('Inspect')

            def builds(window='main'):
                return invoke('runtime.metrics', {'window': window})['windows'][0]['metrics']['builds']['count']

            def width(tree):
                bar = node(tree, BAR)
                value = int(node(tree, VALUE)['label'])
                assert bar['bounds']['width'] == value, (bar, value)
                return value

            def wait_for(predicate, message, window='main', timeout=6):
                deadline = time.monotonic() + timeout
                while True:
                    tree = snapshot(window)
                    if predicate(tree):
                        return tree
                    assert time.monotonic() < deadline, (message, tree)
                    time.sleep(.015)

            def present(tree):
                return any(n['path'] == BAR and n['bounds']['width'] > 0 for n in tree['nodes'])

            def intermediate(window='main', low=43, high=277):
                return wait_for(lambda t: present(t) and low < width(t) < high,
                                'no intermediate animation geometry', window)

            def complete(window='main', endpoint_width=277):
                return wait_for(lambda t: present(t) and width(t) == endpoint_width,
                                'animation did not reach exact endpoint', window)

            def idle(*windows):
                # Let the final submitted frame drain before measuring a quiet
                # interval. Multiple reads catch recurring rebuilds, not just a
                # coincidentally idle sample between native timer ticks.
                time.sleep(.08)
                before = {w: builds(w) for w in windows}
                for _ in range(4):
                    time.sleep(.09)
                    after = {w: builds(w) for w in windows}
                    assert after == before, ('animation kept rebuilding an idle window', before, after)

            def fresh_operation(operation, window='main', predicate=lambda _: True):
                # Native ticks legitimately stale tokens between inspection and
                # input/capture. Retry only the explicit pre-dispatch rejection;
                # never retry an operation that might already have acted.
                deadline = time.monotonic() + 6
                stale_count = 0
                sampled_widths = []
                while True:
                    tree = snapshot(window)
                    if present(tree) and len(sampled_widths) < 24:
                        sampled_widths.append(width(tree))
                    if predicate(tree):
                        args = dict(window=window, token=tree['token'])
                        if operation == 'input':
                            args.update(action='click', target=HIT)
                        reply = call(endpoint, 'runtime.' + operation, args)
                        assert 'rpcError' not in reply, reply
                        result = reply['structuredContent']
                        if not reply.get('isError'):
                            return tree, result
                        assert result['error']['code'] == 'StaleDevelopmentTarget', reply
                        stale_count += 1
                    assert time.monotonic() < deadline, ('could not acquire fresh animation target',
                                                         operation, stale_count, sampled_widths)
                    time.sleep(.005)

            def capture(name, progressing=False):
                tree, result = fresh_operation('capture', predicate=lambda t:
                    present(t) and (65 < width(t) < 245 if progressing else width(t) == 277))
                output = root / (name + '.png')
                output.write_bytes(Path(result['path']).read_bytes())
                box = node(tree, BAR)['bounds']
                w, h, pixel = png_pixel(output, int(box['x'] + 2), int(box['y'] + 73))
                assert pixel == b'\x37\x65\x6f\xff', (name, box, pixel)
                assert (w, h) == (result['width'], result['height'])
                if os.environ.get('OUROKIT_ANIMATION_CAPTURE'):
                    destination = Path(os.environ['OUROKIT_ANIMATION_CAPTURE'])
                    destination.mkdir(parents=True, exist_ok=True)
                    (destination / output.name).write_bytes(output.read_bytes())

            def placement(tree):
                group, bar = node(tree, TRACK), node(tree, BAR)
                assert group['role'] == 'group' and bar['parent'] == group['id'], (group, bar)
                box = bar['bounds']
                marker = node(tree, 'root/tracks/marker')['bounds']
                spacer = node(tree, 'root/tracks/spacer')['bounds']
                assert box['x'] == marker['x'] == spacer['x'] + 47 + 19, (box, marker, spacer)
                assert box['y'] == spacer['y'] == marker['y'] + 13 + 11, (box, marker, spacer)
                assert box['height'] == 76, box

            wait_for(present, 'animation fixture did not mount', timeout=8)
            # Explicit remount removes compositor startup time from the first
            # intermediate-frame requirement.
            invoke('RemoveMain')
            invoke('RestartMain')
            placement(intermediate())
            capture('revision-1-progressing', progressing=True)
            placement(complete())
            capture('revision-1-final')
            idle('main', 'peer')
            fresh_operation('input')
            assert state()['count'] == 8, state()
            print('PASS one shot: intermediate and exact final geometry/text, grid placement, capture and idle metrics')

            invoke('RemoveMain')
            invoke('RestartMain')
            before = intermediate(low=130, high=230)
            for action in ('Unrelated', 'Reorder'):
                invoke(action)
                after = snapshot()
                assert width(after) >= width(before), ('unchanged keyed track restarted', action, before, after)
                for path in (TRACK, BAR, HIT):
                    assert node(after, path)['id'] == node(before, path)['id'], path
                placement(after)
                before = after
            # Change two timing options on a live track. It must visibly restart,
            # rather than continue at its already-observed late progress.
            before = intermediate(low=180, high=277)
            invoke('RetimeMain')
            after = snapshot()
            assert width(after) < width(before), ('timing change did not restart', before, after)
            complete()
            idle('main', 'peer')
            invoke('RemoveMain')
            invoke('RestartMain')
            assert width(intermediate(high=180)) < 180, 'remount retained completed progress'
            complete()
            print('PASS keyed continuity across unrelated rebuild/reorder, changed timing and remount restart')

            invoke('LoopMain')
            previous = width(intermediate())
            increased = wrapped = False
            deadline = time.monotonic() + 6
            while not (increased and wrapped):
                current = width(snapshot())
                assert 43 <= current <= 277, current
                increased |= current > previous + 2
                wrapped |= current < previous - 80
                previous = current
                assert time.monotonic() < deadline, ('loop did not advance and wrap', increased, wrapped)
                time.sleep(.02)
            invoke('RemoveMain')
            removed = wait_for(lambda t: all(n['path'] != TRACK for n in t['nodes']), 'removed track remained')
            idle('main', 'peer')
            stale = call(endpoint, 'runtime.input', dict(window='main', token=before['token'], action='click', target=HIT))
            assert stale['isError'] and stale['structuredContent']['error']['code'] == 'StaleDevelopmentTarget', stale
            assert snapshot() == removed, 'removed loop changed the committed scene'
            invoke('NilMain')
            assert not present(snapshot()), 'nil render unexpectedly produced a layout child'
            intermediate()
            complete()
            invoke('InstantMain')
            assert width(snapshot()) == 277, 'zero duration did not immediately render progress 1'
            idle('main', 'peer')
            print('PASS looping, removal cancellation without rebuild churn, nil output and zero-duration completion')

            # Same logical key in a second native window must not inherit the
            # completed main track or dirty main while the peer animates.
            main_builds = builds()
            invoke('StartPeer')
            placement(intermediate('peer', 91, 203))
            complete('peer', 203)
            assert builds() == main_builds, 'peer animation rebuilt main'
            fresh_operation('input', 'peer')
            assert state() == {'revision': 1, 'count': 8, 'peer_count': 5}, state()
            idle('main', 'peer')
            invoke('RemovePeer')
            invoke('StartPeer')
            intermediate('peer', 91, 203)
            invoke('ClosePeer')
            assert {w['window'] for w in invoke('runtime.inspect')['windows']} == {'main'}
            idle('main')
            invoke('RemovePeer')
            invoke('OpenPeer')
            print('PASS independent window clocks, callback isolation and closing an active track')

            # An active committed track must survive a candidate that fails only
            # after both retained windows were prepared. Its geometry continues;
            # equality of whole snapshots would be the wrong assertion here.
            invoke('RemoveMain')
            invoke('RestartMain')
            invoke('StartPeer')
            before = intermediate(low=130, high=235)
            peer_before = intermediate('peer', 91, 203)
            generation = invoke('runtime.diagnostics')['generation']
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            after = snapshot()
            peer_after = snapshot('peer')
            assert invoke('runtime.diagnostics')['generation'] == generation
            assert width(after) >= width(before), 'failed reload reset committed animation'
            assert width(peer_after) >= width(peer_before), 'failed reload reset peer animation'
            assert node(after, BAR)['id'] == node(before, BAR)['id']
            assert node(peer_after, BAR)['id'] == node(peer_before, BAR)['id']
            assert {w['window'] for w in invoke('runtime.inspect')['windows']} == {'main', 'peer'}
            fresh_operation('input')
            fresh_operation('input', 'peer')
            assert state() == {'revision': 1, 'count': 13, 'peer_count': 10}, state()
            complete()
            complete('peer', 203)
            idle('main', 'peer')

            # Validation failures must preserve an idle committed tree exactly.
            before = snapshot()
            declaration = "duration=peer and 1200 or duration(),easing=peer and 'ease_in' or easing(),loop=not peer and looping(),"
            assert fixture.count(declaration) == 1
            for invalid in ('duration=-1,', 'duration=1.5,', "easing='linear',",
                            "duration=1200,easing='unknown',", 'duration=0,loop=true,'):
                atomic_write(app, fixture.replace(declaration, invalid))
                cli(env, 'reload', endpoint, succeeds=False)
                assert snapshot() == before, ('invalid animation changed committed tree', invalid)
                assert state()['count'] == 13 and state()['revision'] == 1, state()

            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            after = intermediate()
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            for path in (TRACK, BAR, HIT):
                assert node(after, path)['id'] == node(before, path)['id'], path
            stale = call(endpoint, 'runtime.input', dict(window='main', token=before['token'], action='click', target=HIT))
            assert stale['isError'] and stale['structuredContent']['error']['code'] == 'StaleDevelopmentTarget', stale
            assert state()['count'] == 19 and state()['peer_count'] == 0, state()
            capture('revision-2-progressing', progressing=True)
            fresh_operation('input')
            assert state()['count'] == 30, 'accepted reload retained old callback closure'
            complete()
            capture('revision-2-final')
            idle('main', 'peer')
            print('PASS failed multiwindow reload preserves active track/old handlers; successful reload restarts with fresh handlers and stale tokens')
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
            os.environ['OUROKIT_ANIMATION_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
