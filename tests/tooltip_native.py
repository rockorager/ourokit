#!/usr/bin/env python3
"""Native tooltip surfaces on a private compositor; requires wtype and grim.

python3 tests/tooltip_native.py zig-out/bin/ouroctl --capture-dir .amp/in/artifacts/tooltips
"""
import argparse
import json
import math
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
local scheme, tip_text = o.signal('light'), o.signal('Bothe Consulting (87%)')
return o.app{id='dev.ourokit.tooltip-editor',actions={
Style={description='Set tooltip fixture',inputSchema={type='object',properties={scheme={type='string'},text={type='string'}}},
outputSchema={type='object'},handler=function(p) scheme:set(p.scheme); tip_text:set(p.text); return {} end},
Stats={description='Read clicks',inputSchema={type='object'},outputSchema={type='object'},
handler=function() return {hits=hits} end}},run=function() return {windows={
o.window{id='main',title='Independent application',width=760,height=400,content=function()
return o.theme{key='theme',color_scheme=scheme(),o.column{key='root',gap=16,
o.button{key='under',label='Underlying application — click through',width=700,height=80,
on_press=function() hits=hits+1 end},
o.text{key='title',text='Your editor keeps keyboard focus',size=24},
o.text_input{key='editor',label='Editor',default_text='Type here: ',autofocus=true,width=700},
o.tooltip{key='tip',text=tip_text(),
o.button{key='button',label='Window tooltip'}},
o.button{key='through',label='Click through the tooltip',width=700,height=80,
on_press=function() hits=hits+1 end}}} end}}} end}
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
                                            windows=('bar' if source.stem.startswith('tooltip-bar') else 'main',))
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
            def surface_size(endpoint, window):
                return next(w['size'] for w in windows(endpoint) if w['window'] == window)
            def tree(endpoint, window): return invoke(endpoint, 'runtime.inspect', {'window': window})['windows'][0]
            def node(endpoint, window, suffix):
                return next(n for n in tree(endpoint, window)['nodes'] if n['path'].endswith(suffix))
            def popups(endpoint): return [w['window'] for w in windows(endpoint) if w['window'].startswith('__ouro_popup_')]
            def pointer_command(command):
                pointer.stdin.write((command + '\n').encode()); pointer.stdin.flush()
                assert select.select([pointer.stdout], [], [], 5)[0], 'virtual pointer command timeout'
                assert pointer.stdout.readline() == b'done\n'
            def move(x, y): pointer_command(f'move {int(x)} {int(y)}')
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

            # No pointer or keyboard interaction with the trigger: an action
            # opens a pointer-interactive, non-grabbing popover.
            leave()
            invoke(bar_endpoint, 'OpenVolume')
            tip = opened(bar_endpoint)
            assert focused() == 'dev.ourokit.tooltip-editor'
            invoke(bar_endpoint, 'SetVolume')
            wait_for(lambda: node(bar_endpoint, tip, '/label')['label'].endswith('63%'), 'popover content did not update')
            capture('interactive-volume-popover.png')
            hover('/volume/anchor/button')
            wait_for(lambda: invoke(bar_endpoint, 'Stats')['volume_active'], 'trigger hover was not reported')
            trigger = node(bar_endpoint, 'bar', '/volume/anchor/button')['bounds']
            slider = node(bar_endpoint, tip, '/slider')['bounds']
            # Bottom-centered positioner, on an unconstrained middle trigger.
            px = trigger['x'] + trigger['width']/2 - 130
            py = trigger['y'] + trigger['height'] + 6
            x = int(px + slider['x'] + slider['width']*.25)
            y = int(py + slider['y'] + slider['height']/2)
            move(x, y)
            wait_for(lambda: invoke(bar_endpoint, 'Stats')['volume_active'], 'popover hover was not reported')
            assert popups(bar_endpoint) == [tip], 'crossing from trigger closed popover'
            pointer_command('button 272 1')
            wait_for(lambda: invoke(bar_endpoint, 'Stats')['volume'] < .4, 'popover slider press ignored')
            move(int(px + slider['x'] + slider['width']*.8), y)
            wait_for(lambda: invoke(bar_endpoint, 'Stats')['volume'] > .75, 'held slider drag failed')
            if os.environ.get('OUROKIT_POPOVER_DRAG_OUTSIDE'):
                move(int(px + 400), int(py + 150))
                wait_for(lambda: invoke(bar_endpoint, 'Stats')['volume'] > .99, 'compositor did not deliver outside-popup drag')
            else:
                print('NOT CHECKED outside-popup drag (use --drag-outside; Sway 1.7 lacks implicit grabs for layer popups)')
            assert invoke(bar_endpoint, 'Stats')['volume_active'], 'drag capture did not hold interaction'
            assert popups(bar_endpoint) == [tip]
            pointer_command('button 272 0')
            move(750, 680)
            wait_for(lambda: not invoke(bar_endpoint, 'Stats')['volume_active'], 'capture remained active after release')
            # Even a pointer-interactive popup does not promote keyboard access.
            assert focused() == 'dev.ourokit.tooltip-editor'
            invoke(bar_endpoint, 'MoveTip')
            wait_for(lambda: not popups(bar_endpoint), 'popover retained moved anchor')
            closes = invoke(bar_endpoint, 'Stats')['volume_closes']
            time.sleep(.25)
            assert not popups(bar_endpoint) and invoke(bar_endpoint, 'Stats')['volume_closes'] == closes
            invoke(bar_endpoint, 'CloseVolume'); invoke(bar_endpoint, 'OpenVolume'); opened(bar_endpoint)
            invoke(bar_endpoint, 'HideVolume')
            wait_for(lambda: not popups(bar_endpoint), 'unmounted popover retained surface')
            invoke(bar_endpoint, 'CloseVolume')
            assert invoke(bar_endpoint, 'Stats')['errors'] == 0
            print('PASS interactive popover: serial-free, reactive content, cross-surface hover, held slider drag, no focus promotion, invalidation without reopen')

            invoke(bar_endpoint, 'PassiveVolume'); invoke(bar_endpoint, 'ShowVolume')
            time.sleep(.2)
            before = screen()
            invoke(bar_endpoint, 'OpenVolume'); tip = opened(bar_endpoint)
            invoke(bar_endpoint, 'SetVolume')
            wait_for(lambda: node(bar_endpoint, tip, '/label')['label'].endswith('63%'), 'passive content not reactive')
            assert focused() == 'dev.ourokit.tooltip-editor'
            time.sleep(.2)  # Inspect observes layout before the native frame presents.
            capture('passive-volume-popover.png')
            trigger = node(bar_endpoint, 'bar', '/volume/anchor/button')['bounds']
            px = math.floor(trigger['x']) + math.ceil(trigger['width'])//2 - 130
            py = math.floor(trigger['y']) + math.ceil(trigger['height']) + 6
            after = screen()
            corner = ((py+1)*1280+px+1)*3
            assert before[corner:corner+3] == after[corner:corner+3], 'opaque root behind rounded popover corner'
            under = node(editor_endpoint, 'main', '/under')['bounds']
            rect = editor_rect()
            x = int(trigger['x'] + trigger['width']/2)
            y = int(rect['y'] + under['y'] + 10)
            assert trigger['y'] + trigger['height'] + 6 < y < trigger['y'] + trigger['height'] + 106
            move(x, y)
            hits = invoke(editor_endpoint, 'Stats')['hits']
            pointer_command('button 272 1'); pointer_command('button 272 0')
            wait_for(lambda: invoke(editor_endpoint, 'Stats')['hits'] == hits+1, 'passive popover intercepted click')
            assert not invoke(bar_endpoint, 'Stats')['volume_active']
            assert popups(bar_endpoint) == [tip]
            invoke(bar_endpoint, 'CloseVolume')
            wait_for(lambda: not popups(bar_endpoint), 'controlled passive close failed')
            print('PASS passive popover: serial-free, reactive display-only content, pointer transparency, no focus theft')
            initial_source = root / 'tooltip-bar-initial.lua'
            initial_source.write_text((ROOT / 'examples/tooltip-bar.lua').read_text()
                .replace("volume_open, volume_visible, volume = o.signal(false)", "volume_open, volume_visible, volume = o.signal(true)")
                .replace("dev.ourokit.tooltip-bar", "dev.ourokit.tooltip-bar-initial"))
            initial_endpoint = launch(initial_source)
            opened(initial_endpoint)
            assert invoke(initial_endpoint, 'Stats')['errors'] == 0
            terminate(processes[-1])
            print('PASS popover open=true on initial mount')
            if os.environ.get('OUROKIT_POPOVERS_ONLY'): return

            b = node(editor_endpoint, 'main', '/tip/anchor/button')['bounds']
            rect = editor_rect()
            move(rect['x'] + int(b['x'] + b['width']/2), rect['y'] + int(b['y'] + b['height']/2))
            tip = opened(editor_endpoint); time.sleep(.3)
            capture('window-tooltip.png')
            print('PASS ordinary-window native tooltip')
            widths = []
            for scheme, label, background in (('light', 'Bothe Consulting (87%)', (255, 255, 255)),
                    ('dark', 'Bothe Consulting (87%)', (24, 25, 27)),
                    ('light', 'iii', (255, 255, 255)), ('light', 'WWW', (255, 255, 255)),
                    ('light', 'Café 東京', (255, 255, 255))):
                move(750, 680)
                wait_for(lambda: not popups(editor_endpoint), 'tooltip did not close')
                invoke(editor_endpoint, 'Style', {'scheme': scheme, 'text': label})
                time.sleep(.1)
                move(rect['x'] + int(b['x'] + b['width']/2), rect['y'] + int(b['y'] + b['height']/2))
                tip = opened(editor_endpoint); time.sleep(.3)
                body = node(editor_endpoint, tip, '/body')['bounds']
                text_bounds = node(editor_endpoint, tip, '/text')['bounds']
                assert body['width'] == math.ceil(text_bounds['width'] + 18), (body, text_bounds)
                assert 9 <= text_bounds['x'] - body['x'] < 9.5, (body, text_bounds)
                assert surface_size(editor_endpoint, tip) == {'width': body['width'], 'height': 40}
                assert body['x'] == 0, body
                assert body['width'] < 240, body
                px = rect['x'] + int(b['x'] + b['width']/2)
                py = rect['y'] + int(b['y'] + b['height'] + 6 + 5)
                image = screen()
                assert tuple(image[(py*1280+px)*3:(py*1280+px+1)*3]) == background, (scheme, label)
                if label in ('iii', 'WWW'): widths.append(body['width'])
                if label == 'Bothe Consulting (87%)': capture('fitted-' + scheme + '-tooltip.png')
            assert widths[1] > widths[0] * 1.5, widths
            print('PASS inherited light/dark colors, shaped-text width, 8px padding and Unicode')
            # Resize the same logical popup in both directions without leaving
            # the trigger. Older xdg-shell remaps its protocol surface only.
            live_widths = []
            for label in ('iii', 'Bothe Consulting (87%)', 'WWW', 'W' * 100, 'Café 東京'):
                previous = surface_size(editor_endpoint, tip)['width']
                invoke(editor_endpoint, 'Style', {'scheme': 'light', 'text': label})
                wait_for(lambda: surface_size(editor_endpoint, tip)['width'] != previous,
                         'native tooltip did not resize in place')
                wait_for(lambda: node(editor_endpoint, tip, '/text')['label'] == label,
                         'open tooltip text did not update')
                assert popups(editor_endpoint) == [tip]
                body = node(editor_endpoint, tip, '/body')['bounds']
                text_bounds = node(editor_endpoint, tip, '/text')['bounds']
                assert surface_size(editor_endpoint, tip)['width'] == body['width']
                if len(label) < 100:
                    assert body['width'] == math.ceil(text_bounds['width'] + 18), (label, body, text_bounds)
                else:
                    assert body['width'] == 240, body
                live_widths.append(body['width'])
            assert live_widths[0] < live_widths[2] < live_widths[1] < live_widths[3], live_widths
            capture('resized-tooltip.png')
            print('PASS live native resize: shrink, grow, Unicode, capped ellipsis, same popup identity')
            for label in ('W' * 100, 'i' * 100):
                invoke(editor_endpoint, 'Style', {'scheme': 'light', 'text': label})
                wait_for(lambda: surface_size(editor_endpoint, tip) == {'width': 240, 'height': 40},
                         'capped tooltip size did not settle')
                wait_for(lambda: node(editor_endpoint, tip, '/text')['label'] == label,
                         'same-size open tooltip text did not update')
                assert surface_size(editor_endpoint, tip) == {'width': 240, 'height': 40}
                assert popups(editor_endpoint) == [tip]
            print('PASS same-size tooltip content refresh without interaction')
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
            hits = invoke(editor_endpoint, 'Stats')['hits']
            sway(env, 'seat', 'seat0', 'cursor', 'press', 'button1')
            sway(env, 'seat', 'seat0', 'cursor', 'release', 'button1')
            wait_for(lambda: invoke(editor_endpoint, 'Stats')['hits'] == hits+1, 'tooltip intercepted underlying click')
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
        parser.add_argument('--popovers-only', action='store_true', help='run focused popover checks without the subsequent tooltip resize/focus suite')
        parser.add_argument('--drag-outside', action='store_true', help='require compositor implicit grabs for layer-shell popups (newer than Sway 1.7)')
        args = parser.parse_args()
        if args.capture_dir: os.environ['OUROKIT_TOOLTIP_CAPTURE'] = str(args.capture_dir.resolve())
        if args.popovers_only: os.environ['OUROKIT_POPOVERS_ONLY'] = '1'
        if args.drag_outside: os.environ['OUROKIT_POPOVER_DRAG_OUTSIDE'] = '1'
        verify.TESTS = (Path(__file__).name,)
        verify.verify(args.binary.resolve())
