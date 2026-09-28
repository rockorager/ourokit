#!/usr/bin/env python3
"""Stock selection contracts, independent of Lua/Zig visual implementation.

  zig build
  python3 tests/selection_composition.py zig-out/bin/ouroctl
  python3 tests/selection_composition.py zig-out/bin/ouroctl --capture-dir .amp/in/artifacts/selections

Standalone runs own a private compositor and D-Bus session via verify_development.
Missing dependencies fail, never skip. Reloads rewrite only a temporary fixture.
Ignored callback traces are plain Lua data: reading them requires an explicit
refresh, so they cannot accidentally hide native selection behind a Lua rebuild.
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

from application_services import BINARY, ROOT, development_path
from development_runtime import atomic_write, cli, inspect, node, png_pixel
import verify_development as verify


KINDS = ('list', 'radio', 'tabs')
OPTIONS = ('first', 'middle', 'last')
REPORT = 'root/actions/report'
EXTERNAL = 'root/actions/external'


def group(kind, mode='live'):
    return f'root/skin/groups/{mode}/{kind}-frame/{kind}'


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-selections-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/selection-composition.lua').read_text()
        app = root / 'app.lua'
        atomic_write(app, fixture)
        stderr = root / 'app.stderr'
        with stderr.open('wb') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=log)
        try:
            endpoint = development_path(root, process)

            def snapshot(window='main'):
                return inspect(env, endpoint, window)

            def windows():
                return json.loads(cli(env, 'inspect', endpoint))['windows']

            def settle(names):
                # Initial/reload configure only. Never retry stale input tokens.
                deadline = time.monotonic() + 8
                previous, stable = None, time.monotonic()
                while True:
                    trees = tuple(snapshot(name) for name in names)
                    now = time.monotonic()
                    if trees != previous:
                        previous, stable = trees, now
                    elif now - stable >= .3:
                        return
                    assert now < deadline, 'native windows did not settle'
                    time.sleep(.05)

            def builds(window='main'):
                result = json.loads(cli(env, 'metrics', endpoint, {'window': window}))
                return result['windows'][0]['metrics']['builds']['count']

            def input_(window='main', **args):
                tree = snapshot(window)
                return json.loads(cli(env, 'input', endpoint,
                                      dict(window=window, token=tree['token'], **args)))

            def click(path, window='main'):
                input_(window, action='click', target=path)

            def key(value, **args):
                input_(action='key', key=value, **args)

            def label(path, expected, window='main'):
                actual = node(snapshot(window), path)['label']
                assert actual == expected, (path, actual, expected)

            def focused(path):
                actual = [n['path'] for n in snapshot()['nodes'] if n['focused']]
                assert actual == [path], (actual, path)

            def selected(kind, option, mode='live', window='main'):
                tree = snapshot(window)
                for name in OPTIONS:
                    item = node(tree, group(kind, mode) + '/' + name)
                    assert item['selected'] == (name == option), (kind, mode, option, item)
                    if kind == 'radio':
                        assert item['checked'] == (name == option), item

            def capture(name, samples=(), indicators=None, window='main'):
                tree = snapshot(window)
                output = root / (name + '.png')
                result = json.loads(cli(env, 'capture', endpoint,
                                        dict(window=window, token=tree['token']), output=output))
                assert result['kind'] == 'software_scene_replay', result

                def pixel_at(path, x, y, color):
                    width, height, pixel = png_pixel(output, int(x), int(y))
                    assert (width, height) == (result['width'], result['height'])
                    assert pixel == bytes.fromhex(color + 'ff'), (path, (x, y), pixel, color)

                for path, color in samples:
                    bounds = node(tree, path)['bounds']
                    # Interior, above glyphs and clear of focus/indicator borders.
                    pixel_at(path, bounds['x'] + bounds['width'] - 5, bounds['y'] + 4, color)
                if indicators:
                    for mode in ('live', 'ignored', 'disabled'):
                        active = indicators if mode == 'live' else 'middle'
                        for option in OPTIONS:
                            background = ('963f62' if option == 'last' else '763457') if option == active else (
                                '263d61' if option == 'last' else '17324d')
                            path = group('radio', mode) + '/' + option
                            bounds = node(tree, path)['bounds']
                            color = ('94a6b8' if mode == 'disabled' else 'f3ecd1') if option == active else background
                            pixel_at(path, bounds['x'] + 14, bounds['y'] + bounds['height']/2, color)
                            path = group('tabs', mode) + '/' + option
                            bounds = node(tree, path)['bounds']
                            color = 'b25a19' if option == active and mode != 'disabled' else background
                            pixel_at(path, bounds['x'] + bounds['width']/2,
                                     bounds['y'] + bounds['height'] - 1, color)
                if os.environ.get('OUROKIT_SELECTIONS_CAPTURE'):
                    target = Path(os.environ['OUROKIT_SELECTIONS_CAPTURE'])
                    target.mkdir(parents=True, exist_ok=True)
                    (target / output.name).write_bytes(output.read_bytes())

            def trace(kind, live, ignored):
                text = lambda values: ''.join(f'{value};' for value in values)
                label('root/traces/' + kind,
                      f'{kind} live: {text(live)} ignored: {text(ignored)}')

            def exercise(revision, values):
                first, middle, last = values
                label('root/revision', f'Selection revision {revision} / main')
                # Retained windows preserve pointer position across reload.
                input_(action='hover', target='root/revision')
                tree = snapshot()
                for mode in ('live', 'ignored', 'disabled'):
                    for kind, role, child_role in (('list', 'listbox', 'option'),
                                                  ('radio', 'radio_group', 'radio'),
                                                  ('tabs', 'tab_list', 'tab')):
                        parent = node(tree, group(kind, mode))
                        assert parent['role'] == role and parent['visible'], parent
                        assert parent['enabled'] == (mode != 'disabled'), parent
                        selected(kind, 'middle', mode)
                        for option, name in zip(OPTIONS, ('North', 'West', 'East')):
                            item = node(tree, group(kind, mode) + '/' + option)
                            assert item['role'] == child_role and item['label'] == name, item
                            assert item['enabled'] == (mode != 'disabled') and item['visible'], item
                            bounds = item['bounds']
                            # Horizontal tab bars stretch to the tallest tab.
                            height = 37 if kind == 'tabs' or option == 'last' else 32
                            assert bounds['width'] > 0 and bounds['height'] == height, bounds
                    close = node(tree, group('tabs', mode) + '/first/close')
                    assert close['role'] == 'button' and close['label'] == 'Close North', close
                    assert close['enabled'] == (mode != 'disabled'), close
                    outer = node(tree, group('tabs', mode) + '/first')['bounds']
                    child = close['bounds']
                    assert outer['x'] <= child['x'] and outer['y'] <= child['y'], (outer, child)
                    assert child['x'] + child['width'] <= outer['x'] + outer['width'], (outer, child)
                    assert child['y'] + child['height'] <= outer['y'] + outer['height'], (outer, child)
                samples = [(group(kind) + '/' + option, color) for kind in KINDS
                           for option, color in (('first', '17324d'), ('middle', '763457'), ('last', '263d61'))]
                capture(f'revision-{revision}-initial', samples, indicators='middle')

                # Theme and per-option hover/selected paint must work without Lua builds.
                count = builds()
                for kind in KINDS:
                    for option, color in (('first', '315b27'), ('last', '5c6f21'), ('middle', '763457')):
                        path = group(kind) + '/' + option
                        input_(action='hover', target=path)
                        capture(f'revision-{revision}-{kind}-hover-{option}', [(path, color)])
                    # Baseline disabled options still paint hover, but cannot select.
                    path = group(kind, 'disabled') + '/first'
                    input_(action='hover', target=path)
                    capture(f'revision-{revision}-{kind}-disabled-hover', [(path, '315b27')])
                input_(action='hover', target='root/revision')
                assert builds() == count, 'hover rebuilt Lua selection recipes'

                expected = {}
                for kind in KINDS:
                    path = group(kind)
                    forward = 'arrow_right' if kind == 'tabs' else 'arrow_down'
                    backward = 'arrow_left' if kind == 'tabs' else 'arrow_up'
                    click(path + '/last'); selected(kind, 'last'); focused(path)
                    click(path + '/last'); selected(kind, 'last')
                    key('home'); selected(kind, 'first')
                    key(backward); selected(kind, 'first' if kind == 'list' else 'last')
                    key('end'); selected(kind, 'last')
                    key(forward); selected(kind, 'last' if kind == 'list' else 'first')
                    # Lists are vertical only; tab bars horizontal only.
                    if kind != 'radio':
                        count = builds()
                        key('arrow_left' if kind == 'list' else 'arrow_up')
                        key('arrow_right' if kind == 'list' else 'arrow_down')
                        selected(kind, 'last' if kind == 'list' else 'first')
                        assert builds() == count, 'irrelevant axis rebuilt Lua'
                    click(path + '/middle'); selected(kind, 'middle')
                    key(forward); selected(kind, 'last')
                    key(backward); selected(kind, 'middle')
                    expected[kind] = [last, last, first, first if kind == 'list' else last,
                                      last, last if kind == 'list' else first, middle, last, middle]
                    if kind == 'radio':
                        key('arrow_right'); selected(kind, 'last')
                        key('arrow_left'); selected(kind, 'middle')
                        expected[kind] += [last, middle]
                click(REPORT)
                for kind in KINDS:
                    trace(kind, expected[kind], [])

                # No signal writes here: listbox changes locally; controlled groups don't.
                requests = {}
                count = builds()
                for kind in KINDS:
                    path = group(kind, 'ignored')
                    forward = 'arrow_right' if kind == 'tabs' else 'arrow_down'
                    backward = 'arrow_left' if kind == 'tabs' else 'arrow_up'
                    for _ in range(2):
                        click(path + '/last')
                        selected(kind, 'last' if kind == 'list' else 'middle', 'ignored')
                        focused(path)
                    key(forward); selected(kind, 'last' if kind == 'list' else 'middle', 'ignored')
                    key(backward); selected(kind, 'middle', 'ignored')
                    key('home'); selected(kind, 'first' if kind == 'list' else 'middle', 'ignored')
                    key('end'); selected(kind, 'last' if kind == 'list' else 'middle', 'ignored')
                    requests[kind] = [last, last, last, middle if kind == 'list' else first, first, last]
                input_(action='hover', target='root/revision')
                assert builds() == count, 'ignored requests rebuilt Lua'
                capture(f'revision-{revision}-ignored-native',
                        [(group(kind, 'ignored') + '/last', '963f62' if kind == 'list' else '263d61')
                         for kind in KINDS])
                click(REPORT)  # A real rebuild restores the ignored listbox's declared value.
                for kind in KINDS:
                    selected(kind, 'middle', 'ignored')
                    trace(kind, expected[kind], requests[kind])

                # Disabled groups/options cannot call back or steal focus.
                for kind in KINDS:
                    suffixes = ('', '/first', '/middle', '/last') + (('/first/close',) if kind == 'tabs' else ())
                    for suffix in suffixes:
                        tree = snapshot()
                        error = json.loads(cli(env, 'input', endpoint, dict(window='main',
                            token=tree['token'], action='click', target=group(kind, 'disabled') + suffix), succeeds=False))
                        assert error['error']['code'] == 'DevelopmentTargetDisabled', error
                        focused(REPORT)

                # One stop per group, plus the independently focusable tab close child.
                count = builds()
                for path in (group('tabs', 'ignored') + '/first/close', group('tabs', 'ignored'),
                             group('radio', 'ignored'), group('list', 'ignored'),
                             group('tabs') + '/first/close', group('tabs'), group('radio'), group('list')):
                    key('tab', shift=True); focused(path)
                assert builds() == count, 'focus traversal rebuilt Lua'
                capture(f'revision-{revision}-focus')

                # Clicking/keyboard-activating a close child must not select its parent tab.
                close = group('tabs') + '/first/close'
                click(close); focused(close); selected('tabs', 'middle')
                key('enter'); selected('tabs', 'middle')
                key('space'); selected('tabs', 'middle')
                label('root/closes', 'Closes: ' + f'{revision}:{first};' * 3)
                for kind in KINDS:
                    trace(kind, expected[kind], requests[kind])
                click(EXTERNAL)
                for kind in KINDS:
                    selected(kind, 'first')
                    trace(kind, expected[kind], requests[kind])
                label('root/forbidden', 'Forbidden: 0')
                capture(f'revision-{revision}-exercised',
                        [(group(kind) + '/first', '763457') for kind in KINDS], indicators='first')
                print(f'PASS revision {revision}: exact pointer/keyboard traces, clamp/wrap boundaries, ignored request contracts, disabled/focus, close child and theme paint')

            settle(('main', 'peer'))
            exercise(1, (41, -7, 103))
            # Each window owns independent selection state and callback closures.
            selected('radio', 'middle', window='peer')
            click(group('radio') + '/last', 'peer')
            selected('radio', 'last', window='peer')
            selected('radio', 'first')
            before = {name: snapshot(name) for name in ('main', 'peer')}
            generation = json.loads(cli(env, 'diagnostics', endpoint))['generation']
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2')
                         .replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            diagnostic = json.loads(cli(env, 'diagnostics', endpoint))
            assert diagnostic['generation'] == generation and diagnostic['diagnostic']['phase'] == 'build', diagnostic
            assert {w['window'] for w in windows()} == {'main', 'peer'}
            for name in before:
                assert snapshot(name) == before[name], ('rejected candidate mutated committed window', name)
            click(group('tabs') + '/first/close', 'peer')
            label('root/closes', 'Closes: 1:41;', 'peer')
            click(group('radio') + '/first', 'peer')
            label('root/traces/radio', 'radio live: 103;41; ignored: ', 'peer')
            click(group('tabs') + '/first/close')
            label('root/closes', 'Closes: ' + '1:41;' * 4)
            print('PASS rejected multi-window reload: both snapshots intact, removed-window handlers remain live')

            old = snapshot()
            handle = next(w['handle'] for w in windows() if w['window'] == 'main')
            atomic_write(app, fixture.replace('local revision = 1', 'local revision = 2'))
            cli(env, 'reload', endpoint)
            diagnostic = json.loads(cli(env, 'diagnostics', endpoint))
            assert diagnostic['generation'] == generation + 1 and diagnostic['diagnostic'] is None, diagnostic
            assert {w['window'] for w in windows()} == {'main', 'added'}
            settle(('main', 'added'))
            after = snapshot()
            assert next(w['handle'] for w in windows() if w['window'] == 'main') == handle
            for mode in ('live', 'ignored', 'disabled'):
                for kind in KINDS:
                    suffixes = ('', '/first', '/middle', '/last') + (('/first/close',) if kind == 'tabs' else ())
                    for suffix in suffixes:
                        path = group(kind, mode) + suffix
                        assert node(after, path)['id'] == node(old, path)['id'], path
            stale = json.loads(cli(env, 'input', endpoint, dict(window='main', token=old['token'],
                                action='click', target=group('list') + '/last'), succeeds=False))
            assert stale['error']['code'] == 'StaleDevelopmentTarget', stale
            exercise(2, (-19, 83, 6))
            selected('tabs', 'middle', window='added')
            click(group('tabs') + '/last', 'added')
            selected('tabs', 'last', window='added')
            label('root/traces/tabs', 'tabs live: 6; ignored: ', 'added')
            selected('tabs', 'first')
            print('PASS accepted multi-window reload: retained identities, stale token rejected, fresh isolated handlers')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            errors = stderr.read_text()
            assert process.returncode in (0, 128 + signal.SIGTERM), (process.returncode, errors)
            assert 'panic' not in errors and 'leaked' not in errors, errors


if __name__ == '__main__':
    if os.environ.get('OUROKIT_SELECTIONS_SESSION') == '1' or (
            len(sys.argv) == 1 and os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY')):
        session()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('binary', nargs='?', type=Path, default=BINARY)
        parser.add_argument('--capture-dir', type=Path)
        args = parser.parse_args()
        if args.capture_dir:
            os.environ['OUROKIT_SELECTIONS_CAPTURE'] = str(args.capture_dir.resolve())
        os.environ['OUROKIT_SELECTIONS_SESSION'] = '1'
        verify.TESTS = (Path(__file__).name,)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        verify.verify(args.binary.resolve())
