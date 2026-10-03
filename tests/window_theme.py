#!/usr/bin/env python3
"""Verify scheme inheritance and native window roots on a private compositor/bus.

python3 tests/window_theme.py zig-out/bin/ouroctl --capture-dir .amp/in/artifacts/window-theme
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from application_services import BINARY, ROOT, development_path
from development_runtime import atomic_write, cli, inspect, node, png_pixel
import verify_development as verify


def session():
    # The portal fixture uses the distro's PyGObject, not pip dependencies.
    if sys.executable != '/usr/bin/python3':
        subprocess.run(['/usr/bin/python3', str(Path(__file__).resolve())], check=True)
        return
    from appearance_portal import Portal, pump, stop

    with tempfile.TemporaryDirectory(prefix='ouro-window-theme-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=directory,
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        source = (ROOT / 'examples/window-theme.lua').read_text()
        app = root / 'app.lua'
        atomic_write(app, source)
        with (root / 'stderr').open('w') as errors:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=errors)
        portal = None
        try:
            endpoint = development_path(root, process, windows=('main', 'defaults'))
            pump(.3)

            def tree(window='main'):
                return inspect(env, endpoint, window)

            def click(path):
                current = tree()
                cli(env, 'input', endpoint, dict(window='main', token=current['token'], action='click', target=path))

            def geometry(padding):
                actual = node(tree(), 'root')['bounds']
                assert actual == dict(x=padding, y=padding, width=580-2*padding, height=440-2*padding), actual
                peer = node(tree('defaults'), 'root')['bounds']
                assert peer == dict(x=12, y=12, width=236, height=116), peer

            def schemes(expected):
                current = tree()
                for path, label in (
                    ('retained/scheme', 'Inherited scheme: ' + expected),
                    ('light/scheme', 'Explicit light (black palette background): light'),
                    ('dark/nested/scheme', 'Nested dark (white palette background): dark'),
                ):
                    assert node(current, 'root/page/body/' + path + '/label')['label'] == label

            def capture(name, color, modal=False, window='main'):
                current = tree(window)
                output = root / (name + '.png')
                result = json.loads(cli(env, 'capture', endpoint, dict(window=window, token=current['token']), output=output))
                assert result['kind'] == 'software_scene_replay', result
                width, height = result['width'], result['height']
                # Every corner, not just one edge: catches a default inset or
                # an app-theme clear color leaking around the declared root.
                for x, y in ((0, 0), (width-1, 0), (0, height-1), (width-1, height-1)):
                    assert png_pixel(output, x, y)[2] == color, (name, x, y, png_pixel(output, x, y)[2], color)
                if modal:
                    bounds = node(current, 'root/dialog')['bounds']
                    assert bounds == dict(x=0, y=0, width=width, height=height), bounds
                if os.environ.get('OUROKIT_WINDOW_THEME_CAPTURE'):
                    target = Path(os.environ['OUROKIT_WINDOW_THEME_CAPTURE'])
                    target.mkdir(parents=True, exist_ok=True)
                    (target / output.name).write_bytes(output.read_bytes())
                return output.read_bytes()

            geometry(0)
            schemes('light')
            capture('fallback-light', b'\x18\x34\x4b\xff')
            capture('defaults', b'\xff\xff\xff\xff', window='defaults')
            identity = node(tree(), 'root/page/body/retained/scheme')['id']
            root_identity = node(tree(), 'root')['id']
            portal = Portal(os.environ['DBUS_SESSION_BUS_ADDRESS'], 1)
            pump(.4)
            assert portal.reads == 1
            schemes('dark')
            assert node(tree(), 'root/page/body/retained/scheme')['id'] == identity
            capture('live-dark', b'\x18\x34\x4b\xff')
            click('root/page/body/modal')
            # #0000006e over #18344b in linear-light sRGB, then encoded
            # back to sRGB and rounded to bytes: [16, 38, 56].
            capture('dark-modal', b'\x10\x26\x38\xff', modal=True)
            click('root/dialog/body/close')
            portal.change(2); pump(.2); schemes('light')
            click('root/page/body/modal')
            capture('light-modal', b'\x10\x26\x38\xff', modal=True)
            click('root/dialog/body/close')
            portal.change(0); pump(.2); schemes('light')
            assert portal.reads == 1, 'signals must not poll the portal'
            portal.close(); portal = Portal(os.environ['DBUS_SESSION_BUS_ADDRESS'], 1)
            pump(.3); schemes('dark')
            portal.close(); portal = None
            pump(.2); schemes('light')
            print('PASS resolved scheme: inherited/explicit light and dark, fixed colors, live portal signals, owner loss/restart, retained identity')

            click('root/page/body/inset'); geometry(19)
            capture('custom-inset', b'\x70\x45\x24\xff')
            click('root/page/body/inset'); geometry(12)
            capture('restored-defaults', b'\xff\xff\xff\xff')
            click('root/page/body/inset'); geometry(0)
            before = capture('restored-zero', b'\x18\x34\x4b\xff')
            changed = source.replace('local initial_padding = 0', 'local initial_padding = 7').replace("'#18344b'", "'#432167'")
            atomic_write(app, changed.replace('local reject = false', 'local reject = true'))
            cli(env, 'reload', endpoint, succeeds=False)
            geometry(0)
            assert capture('rejected-reload', b'\x18\x34\x4b\xff') == before
            # Force an old-generation rebuild after rollback, rather than only
            # checking that its previously painted image survived.
            click('root/page/body/modal')
            capture('rollback-modal', b'\x10\x26\x38\xff', modal=True)
            click('root/dialog/body/close')
            atomic_write(app, changed)
            cli(env, 'reload', endpoint)
            geometry(7)
            capture('accepted-reload', b'\x43\x21\x67\xff')
            assert node(tree(), 'root')['id'] == root_identity
            atomic_write(app, source.replace("'#18344b'", "'#00000000'"))
            cli(env, 'reload', endpoint)
            geometry(0)
            capture('transparent-root', b'\0\0\0\0')
            print('PASS roots: zero/custom/default inset, full-window modal pixels/geometry, reactive overrides, rejected/accepted reload, alpha, window isolation')
        finally:
            if portal is not None:
                portal.close()
            stop(process)
            stderr = (root / 'stderr').read_text()
            assert process.returncode in (0, 143), (process.returncode, stderr)
            assert 'panic' not in stderr and 'leaked' not in stderr, stderr


if __name__ == '__main__':
    if os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY'):
        session()
    else:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('binary', nargs='?', type=Path, default=BINARY)
        parser.add_argument('--capture-dir', type=Path)
        args = parser.parse_args()
        if args.capture_dir:
            os.environ['OUROKIT_WINDOW_THEME_CAPTURE'] = str(args.capture_dir.resolve())
        verify.TESTS = (Path(__file__).name,)
        verify.verify(args.binary.resolve())
