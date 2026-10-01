#!/usr/bin/env python3
"""Native animated controls and disclosures; optionally record the real compositor.

python3 tests/motion_components.py zig-out/bin/ouroctl --capture-dir /tmp/motion
Add --record-dir <directory> to record full/reduced-motion MP4s (wf-recorder).
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from application_services import BINARY, ROOT, call, development_path
from development_runtime import node
import verify_development as verify

BASE = 'policy/page/root/'
LEFT = BASE + 'columns/left/'
SWITCH = LEFT + 'toggles/body/sync/control'
CHECK = LEFT + 'toggles/body/save/control'
DETAILS = LEFT + 'disclosure/body/details/'
REVEAL = DETAILS + 'presence/reveal'
EDITOR = REVEAL + '/content/settings/name'
FAQ = BASE + 'columns/accordion/body/faq/'


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-motion-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        with (root / 'stderr').open('w') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(ROOT / 'examples/motion-components.lua'),
                                        '--dev', '--software'], env=env,
                                       stdout=subprocess.DEVNULL, stderr=log)
        recorder = None
        try:
            endpoint = development_path(root, process, windows=('main',))

            def invoke(name, args=None):
                reply = call(endpoint, name, args)
                assert not reply.get('isError') and 'rpcError' not in reply, (name, reply)
                return reply['structuredContent']

            def snapshot():
                return invoke('runtime.inspect', {'window': 'main'})['windows'][0]

            def input_(**args):
                return invoke('runtime.input', dict(window='main', token=snapshot()['token'], **args))

            def wait(predicate):
                deadline = time.monotonic() + 5
                while True:
                    tree = snapshot()
                    if predicate(tree): return tree
                    assert time.monotonic() < deadline, 'component did not reach expected state'
                    time.sleep(.015)

            def pause(): time.sleep(.55)

            def idle():
                time.sleep(.35)
                def builds(): return invoke('runtime.metrics', {'window': 'main'})['windows'][0]['metrics']['builds']['count']
                before = builds()
                time.sleep(.12)
                assert builds() == before, 'settled components still request builds'

            def capture(name):
                if directory := os.environ.get('OUROKIT_MOTION_CAPTURE'):
                    destination = Path(directory)
                    destination.mkdir(parents=True, exist_ok=True)
                    result = invoke('runtime.capture', {'window': 'main', 'token': snapshot()['token']})
                    (destination / (name + '.png')).write_bytes(Path(result['path']).read_bytes())

            def record(name):
                nonlocal recorder
                directory = os.environ.get('OUROKIT_MOTION_RECORD')
                if not directory: return
                destination = Path(directory)
                destination.mkdir(parents=True, exist_ok=True)
                socket = next(Path(env['WAYLAND_DISPLAY']).parent.glob('sway-ipc.*.sock'))
                tree = json.loads(subprocess.check_output(['swaymsg', '-s', str(socket), '-t', 'get_tree', '-r'], env=env))
                def window(value):
                    if value.get('app_id') == 'dev.ourokit.motion-components': return value
                    for child in value.get('nodes', []) + value.get('floating_nodes', []):
                        if found := window(child): return found
                bounds = window(tree)['rect']
                geometry = f"{bounds['x']},{bounds['y']} {bounds['width']}x{bounds['height']}"
                recorder_log = (root / (name + '-recorder.log')).open('w')
                recorder = subprocess.Popen(['wf-recorder', '-D', '-g', geometry, '-r', '60', '-c', 'libx264',
                                             '-F', 'format=yuv420p', '-x', 'yuv420p',
                                             '-p', 'crf=18', '-p', 'preset=ultrafast',
                                             '-f', str(destination / (name + '.mp4'))],
                                            env=env, stdout=recorder_log, stderr=subprocess.STDOUT)
                recorder_log.close()
                time.sleep(.3)
                assert recorder.poll() is None, (root / (name + '-recorder.log')).read_text()

            def stop_recording():
                nonlocal recorder
                if recorder:
                    recorder.send_signal(signal.SIGINT)
                    assert recorder.wait(timeout=10) == 0
                    recorder = None

            wait(lambda t: any(n['path'] == SWITCH for n in t['nodes']))
            idle()
            original = node(snapshot(), SWITCH)['id']
            record('full-motion')
            pause()
            input_(action='click', target=SWITCH)
            pause()
            input_(action='click', target=CHECK)
            pause()
            assert node(snapshot(), SWITCH)['checked'] and node(snapshot(), CHECK)['checked']
            invoke('Off'); pause(); invoke('On'); time.sleep(.07); invoke('Off'); pause()
            assert node(snapshot(), SWITCH)['id'] == original
            input_(action='click', target=DETAILS + 'trigger')
            wait(lambda t: any(n['path'] == REVEAL and n['bounds']['height'] > 30 for n in t['nodes']))
            pause()
            assert node(snapshot(), DETAILS + 'trigger')['expanded'] is True
            editor_id = node(snapshot(), EDITOR)['id']
            input_(action='click', target=EDITOR)
            input_(action='text', text='!')
            draft = node(snapshot(), EDITOR)['value']
            assert '!' in draft, draft
            invoke('Close')
            # Inspection can consume the entire 240ms exit on a debug software
            # renderer. Queue reversal before doing a round-trip inspection.
            invoke('Open'); pause()
            assert node(snapshot(), EDITOR)['id'] == editor_id
            assert node(snapshot(), EDITOR)['value'] == draft, (draft, node(snapshot(), EDITOR)['value'])
            invoke('Close')
            closing = snapshot()
            assert not any(n['path'] == EDITOR and n['enabled'] for n in closing['nodes'])
            invoke('Open'); pause()
            input_(action='click', target=FAQ + 'item-motion/trigger'); pause()
            input_(action='click', target=FAQ + 'item-keyboard/trigger'); pause()
            assert node(snapshot(), FAQ + 'item-motion/trigger')['expanded'] is False
            assert node(snapshot(), FAQ + 'item-keyboard/trigger')['expanded'] is True
            input_(action='key', key='space'); pause()
            assert node(snapshot(), FAQ + 'item-keyboard/trigger')['expanded'] is False
            input_(action='key', key='enter'); pause()
            assert node(snapshot(), FAQ + 'item-keyboard/trigger')['expanded'] is True
            idle(); capture('light-expanded')
            stop_recording()
            print('PASS native controls, interrupted disclosure/editor retention, keyboard and idle')

            invoke('Dark'); invoke('Collapse'); invoke('Close'); pause(); invoke('Off'); pause()
            record('reduced-motion')
            pause()
            invoke('Open'); time.sleep(.04); invoke('Reduce')
            reduced_tree = snapshot()
            assert node(reduced_tree, DETAILS + 'trigger')['expanded'] is True
            reduced_height = node(reduced_tree, REVEAL)['bounds']['height']
            pause()
            assert node(snapshot(), REVEAL)['bounds']['height'] == reduced_height
            invoke('On'); pause(); invoke('Off'); pause()
            invoke('First'); pause(); invoke('Second'); pause(); invoke('Third'); pause()
            invoke('Close')
            assert all(n['path'] != REVEAL for n in snapshot()['nodes'])
            pause(); invoke('Open'); pause()
            idle(); capture('dark-reduced')
            stop_recording()
            invoke('Full'); idle()
            print('PASS live reduced-motion settlement, immediate removal, theme and no idle wakeups')
        finally:
            if recorder and recorder.poll() is None:
                recorder.send_signal(signal.SIGINT)
                try: recorder.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    recorder.kill()
                    recorder.wait(timeout=5)
            if process.poll() is None: process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            errors = (root / 'stderr').read_text()
            if sys.exc_info()[0] is not None: print(errors, file=sys.stderr)
            assert process.returncode in (0, 128 + signal.SIGTERM), (process.returncode, errors)
            assert 'panic' not in errors and 'leaked' not in errors, errors


if __name__ == '__main__':
    if len(sys.argv) == 1 and os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY'):
        session()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('binary', nargs='?', type=Path, default=BINARY)
        parser.add_argument('--capture-dir', type=Path)
        parser.add_argument('--record-dir', type=Path)
        args = parser.parse_args()
        if args.capture_dir: os.environ['OUROKIT_MOTION_CAPTURE'] = str(args.capture_dir.resolve())
        if args.record_dir: os.environ['OUROKIT_MOTION_RECORD'] = str(args.record_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
