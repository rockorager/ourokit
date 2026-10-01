#!/usr/bin/env python3
"""Native tooltip surfaces on a private compositor; requires wtype and grim.

python3 tests/tooltip_native.py zig-out/bin/ouroctl --capture-dir .amp/in/artifacts/tooltips
"""
import argparse
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import time

from application_services import BINARY, ROOT, call, development_path
from desktop_native import sway, terminate, wait_for
import verify_development as verify


def session():
    assert shutil.which('wtype'), 'install wtype for native keyboard-focus verification'
    with tempfile.TemporaryDirectory(prefix='ouro-tooltips-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        env['SWAYSOCK'] = str(next(Path(env['WAYLAND_DISPLAY']).parent.glob('sway-ipc.*.sock')))
        editor = root / 'editor.lua'
        editor.write_text('''local o=require('ouro'); local hits=0
return o.app{id='dev.ourokit.tooltip-editor',actions={
Stats={description='Read clicks',inputSchema={type='object'},outputSchema={type='object'},
handler=function() return {hits=hits} end}},run=function() return {windows={
o.window{id='main',title='Independent application',width=760,height=400,content=function()
return o.column{key='root',gap=16,
o.button{key='under',label='Underlying application — click through',width=700,height=80,
on_press=function() hits=hits+1 end},
o.text{key='title',text='Your editor keeps keyboard focus',size=24},
o.text_input{key='editor',label='Editor',default_text='Type here: ',autofocus=true,width=700},
o.tooltip{key='tip',text='A native tooltip in an ordinary window',width=300,
o.button{key='button',label='Window tooltip'}},
o.button{key='through',label='Click through the tooltip',width=700,height=80,
on_press=function() hits=hits+1 end}} end}}} end}
''')
        logs, processes, endpoints = [], [], []
        try:
            protocol = next((ROOT / 'zig-pkg').glob('*/unstable/wlr-virtual-pointer-unstable-v1.xml'))
            subprocess.run(['wayland-scanner', 'client-header', str(protocol), str(root / 'virtual-pointer.h')], check=True)
            subprocess.run(['wayland-scanner', 'private-code', str(protocol), str(root / 'virtual-pointer.c')], check=True)
            flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'wayland-client'], text=True))
            subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I', str(root), str(ROOT / 'tests/desktop_pointer.c'),
                            str(root / 'virtual-pointer.c'), '-o', str(root / 'pointer'), *flags], check=True)
            pointer = subprocess.Popen([str(root / 'pointer')], env=env, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            processes.append(pointer)
            assert select.select([pointer.stdout], [], [], 5)[0], 'virtual pointer not ready'
            assert pointer.stdout.readline() == b'ready\n'
            keyboard = subprocess.Popen(['wtype', '-s', '60000'], env=env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            processes.append(keyboard)
            time.sleep(.15)
            assert keyboard.poll() is None
            def launch(source):
                log = (root / (source.stem + '.log')).open('w')
                logs.append(log)
                process = subprocess.Popen([str(BINARY), 'run', str(source), '--dev', '--software'],
                    env=env,
                    stdout=subprocess.DEVNULL, stderr=log)
                processes.append(process)
                endpoint = development_path(root, process, exclude=endpoints,
                                            windows=('bar' if source.stem == 'tooltip-bar' else 'main',))
                endpoints.append(endpoint)
                return endpoint
            editor_endpoint = launch(editor)
            bar_endpoint = launch(ROOT / 'examples/tooltip-bar.lua')
            wait_for(lambda: 'dev.ourokit.tooltip-editor' in sway(env, '-t', 'get_tree', '-r'), 'editor not mapped')
            sway(env, '[app_id="dev.ourokit.tooltip-editor"]', 'move', 'position', '0', '36')
            sway(env, '[app_id="dev.ourokit.tooltip-editor"]', 'focus')

            def invoke(endpoint, method, args=None):
                reply = call(endpoint, method, args)
                assert not reply.get('isError') and 'rpcError' not in reply, reply
                return reply['structuredContent']
            def windows(endpoint): return invoke(endpoint, 'runtime.inspect')['windows']
            def tree(endpoint, window): return invoke(endpoint, 'runtime.inspect', {'window': window})['windows'][0]
            def node(endpoint, window, suffix):
                return next(n for n in tree(endpoint, window)['nodes'] if n['path'].endswith(suffix))
            def popups(endpoint): return [w['window'] for w in windows(endpoint) if w['window'].startswith('__ouro_popup_')]
            def move(x, y): sway(env, 'seat', 'seat0', 'cursor', 'set', str(x), str(y))
            def leave():
                move(750, 680)
                wait_for(lambda: not popups(bar_endpoint), 'tooltip did not close on leave')
            def hover(suffix):
                n = node(bar_endpoint, 'bar', suffix)
                b = n['bounds']
                move(int(b['x'] + b['width']/2), int(b['y'] + b['height']/2))
            def opened(endpoint): return wait_for(lambda: popups(endpoint), 'tooltip did not open')[0]
            def editor_rect():
                def find(value):
                    if value.get('app_id') == 'dev.ourokit.tooltip-editor': return value['rect']
                    for child in value.get('nodes', []) + value.get('floating_nodes', []):
                        if result := find(child): return result
                return find(json.loads(sway(env, '-t', 'get_tree', '-r')))
            def focused():
                def find(value):
                    if value.get('focused') and value.get('app_id'): return value['app_id']
                    for child in value.get('nodes', []) + value.get('floating_nodes', []):
                        if result := find(child): return result
                return find(json.loads(sway(env, '-t', 'get_tree', '-r')))
            def capture(name):
                if destination := os.environ.get('OUROKIT_TOOLTIP_CAPTURE'):
                    path = Path(destination); path.mkdir(parents=True, exist_ok=True)
                    subprocess.run(['grim', str(path / name)], env=env, check=True)
            def screen():
                image = subprocess.check_output(['grim', '-t', 'ppm', '-'], env=env)
                header = b'P6\n1280 720\n255\n'
                assert image.startswith(header) and len(image) == len(header) + 1280 * 720 * 3
                return image[len(header):]
            def popup_pixels(before, after, width, top=36, right=1280):
                # The editor starts at y=72, with controls from y=84. These
                # 40px tips end by y=78; exclude underlying control repaints.
                changed = [(x, y) for y in range(top, 82) for x in range(right)
                           if before[(y*1280+x)*3:(y*1280+x+1)*3] != after[(y*1280+x)*3:(y*1280+x+1)*3]]
                assert len(changed) > width * 28, len(changed)
                left, right = min(x for x, _ in changed), max(x for x, _ in changed)
                assert width - 4 <= right - left + 1 <= width, (left, right, width)

            wait_for(lambda: any(w['window'] == 'bar' for w in windows(bar_endpoint)), 'bar not ready')
            leave()
            time.sleep(.2)
            before = screen()
            hover('/network/anchor/button')
            time.sleep(.1)
            assert not popups(bar_endpoint), 'tooltip ignored opening delay'
            leave(); time.sleep(.65)
            assert not popups(bar_endpoint), 'canceled timer opened a stale tooltip'
            hover('/network/anchor/button')
            tip = opened(bar_endpoint)
            time.sleep(.3)
            assert focused() == 'dev.ourokit.tooltip-editor', focused()
            subprocess.run(['wtype', 'x'], env=env, check=True)
            wait_for(lambda: node(editor_endpoint, 'main', '/editor')['value'].endswith('x'), 'keyboard focus stolen by tooltip')
            assert popups(bar_endpoint) == [tip]
            capture('bar-tooltip.png')
            popup_pixels(before, screen(), 260)
            assert node(bar_endpoint, 'bar', '/bar')['bounds']['height'] == 36
            print('PASS delayed/canceled hover, popup outside 36px bar, independent keyboard focus and no grab')

            invoke(bar_endpoint, 'Hide')
            wait_for(lambda: not popups(bar_endpoint), 'removed anchor retained tooltip')
            invoke(bar_endpoint, 'Show'); leave()
            invoke(bar_endpoint, 'Disable'); hover('/network/anchor/button'); time.sleep(.7)
            assert not popups(bar_endpoint)
            invoke(bar_endpoint, 'Enable'); leave()
            invoke(bar_endpoint, 'Reduce'); before = screen(); hover('/clock/anchor/button')
            tip = opened(bar_endpoint); time.sleep(.15)
            metrics = invoke(bar_endpoint, 'runtime.metrics', {'window': tip})['windows'][0]['metrics']['builds']['count']
            time.sleep(.2)
            assert invoke(bar_endpoint, 'runtime.metrics', {'window': tip})['windows'][0]['metrics']['builds']['count'] == metrics
            popup_pixels(before, screen(), 200)  # Top preference flips below the bar.
            leave(); before = screen(); hover('/edge/anchor/button'); opened(bar_endpoint); time.sleep(.2)
            capture('edge-tooltip.png')
            popup_pixels(before, screen(), 300, top=0,
                         right=int(node(bar_endpoint, 'bar', '/edge/anchor/button')['bounds']['x']))
            leave()
            print('PASS removal, disabled tooltips, reduced-motion idle and compositor edge placement')

            hover('/select/anchor/output/trigger'); opened(bar_endpoint); time.sleep(.2)
            sway(env, 'seat', 'seat0', 'cursor', 'press', 'button1')
            sway(env, 'seat', 'seat0', 'cursor', 'release', 'button1')
            def menu_open():
                stats = invoke(bar_endpoint, 'Stats')
                assert stats['errors'] == 0, stats
                return any(any(n['role'] == 'listbox' for n in tree(bar_endpoint, w)['nodes']) for w in popups(bar_endpoint))
            wait_for(menu_open, 'tooltip blocked select grab')
            subprocess.run(['wtype', '-k', 'Escape'], env=env, check=True)
            wait_for(lambda: not popups(bar_endpoint), 'select did not dismiss')
            assert invoke(bar_endpoint, 'Stats')['errors'] == 0
            print('PASS real click replaces passive tooltip with grabbing select, Escape dismisses menu')

            b = node(editor_endpoint, 'main', '/tip/anchor/button')['bounds']
            rect = editor_rect()
            move(rect['x'] + int(b['x'] + b['width']/2), rect['y'] + int(b['y'] + b['height']/2))
            tip = opened(editor_endpoint); time.sleep(.3)
            capture('window-tooltip.png')
            print('PASS ordinary-window native tooltip')
            # Focus from a real keyboard event, not a development popup bypass.
            entry = node(editor_endpoint, 'main', '/editor')['bounds']
            move(rect['x'] + int(entry['x'] + 50), rect['y'] + int(entry['y'] + 15))
            sway(env, 'seat', 'seat0', 'cursor', 'press', 'button1')
            sway(env, 'seat', 'seat0', 'cursor', 'release', 'button1')
            wait_for(lambda: not popups(editor_endpoint), 'hover tooltip did not close')
            subprocess.run(['wtype', '-k', 'Tab'], env=env, check=True)
            opened(editor_endpoint)
            subprocess.run(['wtype', '-k', 'Escape'], env=env, check=True)
            wait_for(lambda: not popups(editor_endpoint), 'Escape did not dismiss focused tooltip')
            subprocess.run(['wtype', '-M', 'shift', '-k', 'Tab', '-m', 'shift', '-k', 'Tab'], env=env, check=True)
            tip = opened(editor_endpoint); time.sleep(.3)
            # Pointer over the popup, keyboard focus still on its anchor. The
            # empty Wayland input region must deliver this press underneath.
            move(rect['x'] + int(b['x'] + 50), rect['y'] + int(b['y'] + b['height'] + 24))
            time.sleep(.1)
            assert popups(editor_endpoint) == [tip]
            sway(env, 'seat', 'seat0', 'cursor', 'press', 'button1')
            sway(env, 'seat', 'seat0', 'cursor', 'release', 'button1')
            wait_for(lambda: invoke(editor_endpoint, 'Stats')['hits'] == 1, 'tooltip intercepted underlying click')
            wait_for(lambda: not popups(editor_endpoint), 'tooltip remained after focus left anchor')
            print('PASS keyboard-focus tooltip, Escape and click-through to underlying control')
        finally:
            for process in reversed(processes): terminate(process)
            for log in logs: log.close()
            for path in root.glob('*.log'):
                errors = path.read_text()
                if sys.exc_info()[0] is not None: print(errors[-7000:], file=sys.stderr)
                assert 'panic' not in errors and 'leaked' not in errors, errors[-7000:]


if __name__ == '__main__':
    if len(sys.argv) == 1 and os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY'):
        session()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('binary', nargs='?', type=Path, default=BINARY)
        parser.add_argument('--capture-dir', type=Path)
        args = parser.parse_args()
        if args.capture_dir: os.environ['OUROKIT_TOOLTIP_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        verify.verify(args.binary.resolve())
