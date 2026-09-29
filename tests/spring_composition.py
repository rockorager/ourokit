#!/usr/bin/env python3
"""Exercise analytic springs, interruption and reduced-motion policy."""
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

BALL = 'policy/root/track/spring/ball'
LOOP = 'policy/root/lower/loop-frame/loop/pulse'
TOAST = 'policy/root/lower/presence-frame/presence/toast'


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-spring-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/spring-composition.lua').read_text()
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

            def snapshot(startup=False):
                reply = call(endpoint, 'runtime.inspect', {'window': 'main'})
                error = reply.get('structuredContent', {}).get('error', {}).get('code')
                if startup and error == 'DevelopmentWindowNotFound': return None
                assert not reply.get('isError') and 'rpcError' not in reply, reply
                return reply['structuredContent']['windows'][0]

            def value(tree, path=BALL): return float(node(tree, path)['label'].split()[-1])
            def metric(name):
                return invoke('runtime.metrics', {'window':'main'})['windows'][0]['metrics'][name]['count']
            def builds(): return metric('builds')
            def wait(predicate, timeout=6):
                deadline = time.monotonic() + timeout
                while True:
                    tree = snapshot()
                    if predicate(tree): return tree
                    assert time.monotonic() < deadline, ('spring did not reach state', tree)
                    time.sleep(.012)
            def idle():
                time.sleep(.09); before = builds()
                for _ in range(3):
                    time.sleep(.09); assert builds() == before, 'settled motion retained a timer'
            def capture(name, expected):
                tree = snapshot(); assert value(tree) == expected
                result = invoke('runtime.capture', {'window':'main','token':tree['token']})
                image = Path(result['path']); box = node(tree, BALL)['bounds']
                _, _, pixel = png_pixel(image, int(box['x']+10), int(box['y']+10))
                assert pixel == bytes((56,154,192,255)), pixel
                destination = os.environ.get('OUROKIT_SPRING_CAPTURE')
                if destination:
                    Path(destination).mkdir(parents=True, exist_ok=True)
                    (Path(destination)/(name+'.png')).write_bytes(image.read_bytes())
                return tree

            deadline = time.monotonic() + 8
            while True:
                assert process.poll() is None, 'spring fixture exited during startup'
                try:
                    ready = snapshot(startup=True)
                    if ready and any(n['path'] == BALL for n in ready['nodes']): break
                except ConnectionRefusedError: pass
                assert time.monotonic() < deadline, 'spring fixture did not configure'
                time.sleep(.03)
            invoke('Reduce')                 # deterministic starting point
            original = capture('reduced-left', 0)
            idle()

            invoke('Full'); layouts = metric('layouts'); invoke('Right')
            samples = []
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                v = value(snapshot()); samples.append((time.monotonic(), v))
                if v > 1.01: break
                time.sleep(.012)
            assert any(b > a for (_, a), (_, b) in zip(samples, samples[1:])), samples
            assert max(v for _, v in samples) > 1, 'underdamped spring never overshot'
            assert metric('layouts') == layouts, 'transform-only spring caused relayout'

            # Retarget before rest; exact velocity continuity is covered by the
            # deterministic registry test, independent of IPC/frame latency.
            invoke('Left'); reversal = [(time.monotonic(), value(snapshot()))]
            for _ in range(35):
                time.sleep(.01); reversal.append((time.monotonic(), value(snapshot())))
            deltas = [b[1]-a[1] for a,b in zip(reversal,reversal[1:])]
            assert any(d < 0 for d in deltas), deltas
            wait(lambda t: value(t) == 0); idle()
            assert node(snapshot(), BALL)['id'] == node(original, BALL)['id']
            print('PASS overshoot, interrupted reversal, exact rest, identity and idle')

            invoke('StartLoop')
            invoke('Right'); wait(lambda t: .15 < value(t) < .85)
            invoke('Reduce')
            reduced = snapshot()
            assert value(reduced) == 1 and value(reduced, LOOP) == 1
            invoke('Hide'); assert all(n['path'] != TOAST for n in snapshot()['nodes'])
            idle(); capture('reduced-right', 1)
            invoke('Show'); assert value(snapshot(), TOAST) == 1
            invoke('Full')
            assert value(snapshot()) == 1, 'restoring full restarted settled transition'
            wait(lambda t: 0 < value(t, LOOP) < 1)
            print('PASS reduced endpoint/loop suppression/immediate presence and full restore policy')

            invoke('Reduce'); stable = snapshot(); generation = invoke('runtime.diagnostics')['generation']
            declaration = 'local spring = {mass=1,stiffness=170,damping=18}'
            for invalid in ('local spring = {mass=0,stiffness=170,damping=18}',
                            'local spring = {mass=1,stiffness=-1,damping=18}',
                            'local spring = {mass=1,stiffness=170,damping=0}',
                            'local spring = {mass=1,stiffness=170,damping=18,typo=1}'):
                atomic_write(app, fixture.replace(declaration, invalid))
                cli(env, 'reload', endpoint, succeeds=False)
                assert snapshot() == stable
            transition = "spring=declaration,motion='auto'"
            for invalid in ("spring=declaration,duration=100,motion='auto'",
                            "spring=declaration,motion='sometimes'"):
                atomic_write(app, fixture.replace(transition, invalid))
                cli(env, 'reload', endpoint, succeeds=False)
                assert snapshot() == stable
            atomic_write(app, fixture.replace('local invalid = nil', "local invalid = {mass=1,stiffness=170,damping='bad'}"))
            cli(env, 'reload', endpoint, succeeds=False); assert snapshot() == stable
            atomic_write(app, fixture.replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False); assert snapshot() == stable
            assert invoke('runtime.diagnostics')['generation'] == generation
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            invoke('Reduce')
            fresh = snapshot(); assert value(fresh) == 0
            reply = call(endpoint, 'runtime.input', {'window':'main','token':stable['token'],'action':'click','target':BALL})
            assert reply['isError'] and reply['structuredContent']['error']['code'] == 'StaleDevelopmentTarget'
            fresh = snapshot(); invoke('runtime.input', {'window':'main','token':fresh['token'],'action':'click','target':BALL})
            assert node(snapshot(), 'policy/root/status')['label'] == 'Reduced · hits 7'
            print('PASS invalid/late-failing atomic reload, retained state, stale token and fresh callback')
        finally:
            if process.poll() is None: process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            errors = (root/'stderr').read_text()
            if sys.exc_info()[0] is not None: print(errors, file=sys.stderr)
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
        if args.capture_dir: os.environ['OUROKIT_SPRING_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
