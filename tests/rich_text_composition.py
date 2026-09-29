#!/usr/bin/env python3
"""Native rich text: shaping, span links, retained updates and atomic reload.

Run: python3 tests/rich_text_composition.py zig-out/bin/ouroctl
Optional: --capture-dir .amp/in/artifacts/rich-text
Uses the shared private headless Sway wrapper, never the caller's desktop.
"""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import struct
import sys
import tempfile
import time
import zlib

from application_services import BINARY, ROOT, call, development_path
from development_runtime import atomic_write, cli, node
import verify_development as verify

STORY = 'root/card/story'
GUIDE = STORY + '/guide'
NORMAL = 'root/links/normal'
DISABLED = 'root/links/disabled'
INKS = (b'\x26\x38\x4a\xff', b'\xa2\x3b\x72\xff', b'\x12\x6b\x8c\xff')


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-rich-text-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/rich-text-composition.lua').read_text()
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
            while True:
                assert process.poll() is None, 'rich-text application exited during startup'
                try:
                    tree = snapshot()
                    if any(n['path'] == GUIDE for n in tree['nodes']):
                        break
                except ConnectionRefusedError:
                    pass
                assert time.monotonic() < deadline, 'rich-text windows did not settle'
                time.sleep(.03)

            def input_(action, target=None, **args):
                tree = snapshot()
                if target is not None:
                    args['target'] = target
                return invoke('runtime.input', dict(window='main', token=tree['token'], action=action, **args))

            def status(value):
                assert node(snapshot(), 'root/status')['label'] == f'Activations {value}'

            def capture(name, inks=INKS):
                tree = snapshot()
                result = invoke('runtime.capture', {'window': 'main', 'token': tree['token']})
                image = Path(result['path']).read_bytes()
                # Authored solid colors survive antialiasing at glyph interiors;
                # require each style rather than depending on font geometry.
                width, height = struct.unpack('>II', image[16:24])
                compressed, offset = bytearray(), 8
                while offset < len(image):
                    size = struct.unpack('>I', image[offset:offset + 4])[0]
                    if image[offset + 4:offset + 8] == b'IDAT':
                        compressed.extend(image[offset + 8:offset + 8 + size])
                    offset += size + 12
                rgba = zlib.decompress(compressed)
                assert len(rgba) == height * (1 + width * 4)
                assert all(rgba[y * (1 + width * 4)] == 0 for y in range(height)), 'expected unfiltered RGBA PNG'
                for color in inks:
                    assert rgba.count(color) > 4, (name, color, rgba.count(color))
                destination = os.environ.get('OUROKIT_RICH_TEXT_CAPTURE')
                if destination:
                    Path(destination).mkdir(parents=True, exist_ok=True)
                    (Path(destination) / (name + '.png')).write_bytes(image)
                return tree, image

            original, pixels = capture('wide')
            peer = snapshot('peer')
            story = node(original, STORY)
            assert story['label'] == 'Native rich text keeps one paragraph while links wrap with the surrounding words. Read the composition guide — ثم يعود النص من اليمين إلى اليسار بأمان.'
            for path, enabled in ((GUIDE, True), (NORMAL, True), (DISABLED, False)):
                link = node(original, path)
                assert link['role'] == 'link' and link['label'] and link['enabled'] == enabled, link

            input_('click', GUIDE); input_('click', NORMAL); status(6)
            before = snapshot()
            reply = call(endpoint, 'runtime.input', dict(window='main', token=before['token'], action='click', target=DISABLED))
            assert reply.get('isError'), reply
            status(6)
            input_('key', key='tab')
            focused = [n['path'] for n in snapshot()['nodes'] if n['focused']]
            assert focused and focused[0] != DISABLED, focused
            for _ in range(8):
                if focused == [GUIDE]:
                    break
                input_('key', key='tab')
                focused = [n['path'] for n in snapshot()['nodes'] if n['focused']]
                assert focused and DISABLED not in focused, focused
            assert focused == [GUIDE], focused
            input_('key', key='enter'); status(9)

            before_mutation, retained_pixels = capture('focused')
            invoke('MutateSource')
            after_mutation, after_pixels = capture('copied')
            assert after_mutation == before_mutation and after_pixels == retained_pixels, 'native spans aliased Lua source tables'
            invoke('RestoreSource')
            story_id, normal_id = node(snapshot(), STORY)['id'], node(snapshot(), NORMAL)['id']
            invoke('Compact')
            compact, changed = capture('compact')
            assert node(compact, STORY)['bounds']['height'] > story['bounds']['height'], 'paragraph did not reflow'
            assert node(compact, STORY)['id'] == story_id and node(compact, NORMAL)['id'] == normal_id
            assert changed != pixels
            invoke('Restyle')
            styled, restyled_pixels = capture('restyled')
            assert node(styled, STORY)['id'] == story_id and node(styled, NORMAL)['id'] == normal_id
            assert node(styled, NORMAL)['bounds'] == node(compact, NORMAL)['bounds']
            assert restyled_pixels != changed, 'style-only update did not repaint'
            assert snapshot('peer') == peer, 'main state dirtied peer window'

            generation = invoke('runtime.diagnostics')['generation']
            stable = (snapshot(), snapshot('peer'))
            invalids = ('{}', "{{text=''}}", "{{text='x',size=0}}", "{{text='x',on_press=function() end}}",
                        "{{text='e'},{text='́x'}}", "{{text='x'},[3]={text='gap'}}")
            for declaration in invalids:
                atomic_write(app, fixture.replace('local invalid = nil', 'local invalid = ' + declaration))
                cli(env, 'reload', endpoint, succeeds=False)
                assert (snapshot(), snapshot('peer')) == stable
                assert invoke('runtime.diagnostics')['generation'] == generation
            nested = fixture.replace("o.text {key='intro',text='A single paragraph can mix emphasis, color, direction and accessible links.'",
                "o.button {key='outer',label='Outer',on_press=function() end, o.text {key='inside',spans={{key='bad',text='bad',on_press=function() end}}}")
            atomic_write(app, nested); cli(env, 'reload', endpoint, succeeds=False)
            assert (snapshot(), snapshot('peer')) == stable
            atomic_write(app, fixture.replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert (snapshot(), snapshot('peer')) == stable

            input_('click', NORMAL); status(12)  # Old callback remains live after rejection.
            old = snapshot()
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace("'#126b8c'", "'#26734d'"))
            cli(env, 'reload', endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            fresh = snapshot()
            assert node(fresh, STORY)['id'] == node(old, STORY)['id']
            stale = call(endpoint, 'runtime.capture', {'window': 'main', 'token': old['token']})
            assert stale.get('isError') and stale['structuredContent']['error']['code'] == 'StaleDevelopmentTarget'
            input_('click', NORMAL); status(7)
            capture('reloaded', (INKS[0], INKS[1], b'\x26\x73\x4d\xff'))
            print('PASS rich shaping/reflow and authored colors, fragment link hits, semantics/focus, copied spans, stable IDs and transactional reload')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            errors = (root / 'stderr').read_text()
            if sys.exc_info()[0] is not None:
                print(errors, file=sys.stderr)
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
            os.environ['OUROKIT_RICH_TEXT_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
