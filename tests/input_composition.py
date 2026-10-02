#!/usr/bin/env python3
"""Exercise scoped input through the real process, scheduler and reload path.

Run: python3 tests/input_composition.py zig-out/bin/ouroctl
Always uses a disposable headless compositor and private D-Bus session.
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

from application_services import BINARY, ROOT, call, development_path, request
from development_runtime import atomic_write, cli, inspect, node
import verify_development as verify


LEAF = 'root/content/inner/fields/leaf'
EDITOR = 'root/content/inner/fields/editor'
OUTER = 'root/content/outer'
BLOCKED = 'root/content/blocked'
POINTER = 'root/content/pointer/sink/action'


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-input-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/input-composition.lua').read_text()
        app = root / 'app.lua'
        atomic_write(app, fixture)
        with (root / 'stderr').open('w') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=log)
        try:
            endpoint = development_path(root, process, windows=('main',))

            def snapshot():
                return inspect(env, endpoint, 'main')

            def input_(**args):
                tree = snapshot()
                return json.loads(cli(env, 'input', endpoint,
                                      dict(window='main', token=tree['token'], **args)))

            def key(value, **modifiers):
                input_(action='key', key=value, **modifiers)

            def click(path):
                input_(action='click', target=path)

            def state():
                return call(endpoint, 'Inspect')['structuredContent']

            def clear():
                call(endpoint, 'ClearTrace')

            deadline = time.monotonic() + 8
            while not any(n['path'] == LEAF for n in snapshot()['nodes']):
                assert time.monotonic() < deadline, 'fixture did not mount'
                time.sleep(.01)
            tools = {t['name'] for t in request(endpoint, 'tools/list')['result']['tools']}
            assert {'Inspect', 'ClearTrace'} <= tools, tools
            assert not {'save', 'comment', 'delayed'} & tools, 'local commands escaped into external catalog'

            def exercise(revision, inner_step, outer_step, chord_step):
                click(LEAF)
                clear()
                builds = state()['builds']
                key('f1')
                assert state()['trace'] == 'root:F1:capture;inner:F1:capture;leaf:F1:bubble;inner:F1:bubble;', state()
                assert state()['builds'] == builds, 'observing input rebuilt a clean component'
                click(BLOCKED)
                clear()
                key('f2')
                assert state()['trace'] == 'root:F2:capture;blocked:F2:capture;', state()
                click(OUTER)
                clear()
                key('f1')
                assert state()['trace'] == 'root:F1:capture;root:F1:bubble;', state()

                click(LEAF)
                key('s', control=True)
                assert (state()['inner'], state()['outer']) == (inner_step, 0), state()
                key('s', control=True, shift=True)
                assert state()['inner'] == inner_step, 'shortcut matched extra modifier'
                click(OUTER)
                key('s', control=True)
                assert (state()['inner'], state()['outer']) == (inner_step, outer_step), state()
                key('k', control=True)
                assert state()['chords'] == 0, 'prefix invoked command'
                key('c', control=True)
                assert state()['chords'] == chord_step, state()
                key('k', control=True)
                key('escape')
                key('c', control=True)
                assert state()['chords'] == chord_step, 'Escape did not cancel prefix'
                key('k', control=True)
                key('s', control=True)
                assert state()['outer'] == 2 * outer_step, 'mismatch did not retry as a new shortcut'
                key('k', control=True)
                click(LEAF)
                key('c', control=True)
                assert state()['chords'] == chord_step, 'prefix survived focus/pointer change'
                key('d', control=True)
                deadline = time.monotonic() + 3
                while state()['delayed'] != 1:
                    assert time.monotonic() < deadline, 'yielding command never resumed'
                    time.sleep(.01)

                # Consuming Left must suppress native caret motion, while the
                # nonmatching Home/End/Right keys and text path still work.
                click(EDITOR)
                key('end')
                key('arrow_left')
                input_(action='text', text='X')
                assert state()['text'] == 'abcdX', state()
                key('home')
                key('arrow_right')
                input_(action='text', text='Y')
                assert state()['text'] == 'aYbcdX', state()

                clear()
                click(POINTER)
                assert state()['pointer'] == 'outer:capture;inner:bubble;', state()
                assert state()['activations'] == 0, 'consumed press activated stock button'
                # Pointer consumption is not keyboard consumption. Reach the
                # same button through native focus traversal.
                click(OUTER)
                key('tab')
                focused = [n['path'] for n in snapshot()['nodes'] if n['focused']]
                assert focused == [POINTER], focused
                key('enter')
                assert state()['activations'] == 1, state()
                if os.environ.get('OUROKIT_INPUT_CAPTURE'):
                    directory = Path(os.environ['OUROKIT_INPUT_CAPTURE'])
                    directory.mkdir(parents=True, exist_ok=True)
                    tree = snapshot()
                    cli(env, 'capture', endpoint, dict(window='main', token=tree['token']),
                        output=directory / f'revision-{revision}-exercised.png')
                print(f'PASS revision {revision}: filtered propagation, scoped/chord commands, yielding, editing and pointer/default isolation')

            exercise(1, 5, 11, 3)
            before = snapshot()
            previous = state()
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert snapshot() == before, 'rejected candidate mutated committed input tree'
            click(LEAF)
            key('s', control=True)
            assert state()['inner'] == previous['inner'] + 5, 'old command callback lost on rejected reload'
            click(OUTER)
            key('k', control=True)
            old = snapshot()
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            current = snapshot()
            for path in (LEAF, EDITOR, OUTER, BLOCKED, POINTER):
                assert node(current, path)['id'] == node(old, path)['id'], path
            stale = json.loads(cli(env, 'input', endpoint, dict(window='main',token=old['token'],
                               action='key',key='s',control=True), succeeds=False))
            assert stale['error']['code'] == 'StaleDevelopmentTarget', stale
            key('c', control=True)
            assert state()['chords'] == 0, 'accepted reload retained a pending shortcut sequence'
            # Uncontrolled editor contents intentionally survive accepted reload;
            # new generation's plain fixture state starts fresh for commands.
            click(EDITOR)
            key('a', control=True)
            input_(action='text', text='abcd')
            exercise(2, 13, 17, 7)
            print('PASS rejected and accepted reload: retained identities, old/fresh closures and stale-token protection')

            # Exercise the long-line path through real layout and horizontal
            # caret reveal, then switch from ASCII to a combining grapheme.
            # Seed a new editor: action=text deliberately plays each scalar
            # as separate key events, rather than bulk-pasting the fixture.
            long_fixture = fixture.replace("key='editor',", "key='long_editor',").replace(
                "default_text='abcd'", "default_text='Wi '..string.rep('k',4096)")
            atomic_write(app, long_fixture)
            cli(env, 'reload', endpoint)
            click(EDITOR.replace('/editor', '/long_editor'))
            long_line = 'Wi ' + 'k' * 4096
            key('end')
            input_(action='text', text='X')
            assert state()['text'] == long_line + 'X', state()
            key('home')
            key('arrow_right')
            input_(action='text', text='a\u0301')
            assert state()['text'] == 'Wa\u0301' + long_line[1:] + 'X', state()
            if os.environ.get('OUROKIT_INPUT_CAPTURE'):
                tree = snapshot()
                cli(env, 'capture', endpoint, dict(window='main', token=tree['token']),
                    output=Path(os.environ['OUROKIT_INPUT_CAPTURE']) / 'long-line-start.png')
            print('PASS long-line end/start editing and combining-grapheme insertion')
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
            os.environ['OUROKIT_INPUT_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
