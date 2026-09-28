#!/usr/bin/env python3
"""Run the native development/control suite without using the caller's desktop.

Invoked by zig build test-development with the freshly built ouroctl artifact.
Sway and each test's process group exist only for this bounded verification run.
Missing dependencies, compositor startup failure and test failures are errors.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
TESTS = (
    'development_runtime.py',
    'control_composition.py',
    'selection_composition.py',
    'input_composition.py',
    'overlay_composition.py',
    'animation_composition.py',
    'drawing_composition.py',
    'path_composition.py',
    'desktop_activation.py',
    'application_services.py',
    'catalog_export.py',
    'mcp_bridge.py',
    'desktop_services.py',
    'secrets.py',
    'xdg.py',
    'desktop_install.py',
    'documents.py',
    'desktop_native.py',
)


def stop(process):
    """Stop the process group, including descendants of a failed test."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=5)


def environment(root, binary):
    env = os.environ.copy()
    for key in (
        'DISPLAY', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'WAYLAND_DEBUG',
        'SWAYSOCK', 'I3SOCK', 'DBUS_SESSION_BUS_ADDRESS',
        'DBUS_STARTER_ADDRESS', 'DBUS_STARTER_BUS_TYPE',
        'XDG_ACTIVATION_TOKEN', 'DESKTOP_STARTUP_ID',
        'LISTEN_PID', 'LISTEN_FDS', 'LISTEN_FDNAMES',
        'OUROKIT_TEST_WAYLAND_DISPLAY', 'OUROKIT_TEST_CAPTURE',
        'PYTHONOPTIMIZE',
    ):
        env.pop(key, None)
    for kind in ('config', 'data', 'cache', 'state'):
        directory = root / kind
        directory.mkdir()
        env[f'XDG_{kind.upper()}_HOME'] = str(directory)
        if kind in ('config', 'data'):
            env[f'XDG_{kind.upper()}_DIRS'] = str(directory)
    env.update(
        XDG_RUNTIME_DIR=str(root),
        OUROKIT_TEST_BINARY=str(binary),
        WLR_BACKENDS='headless',
        WLR_RENDERER='pixman',
        WLR_LIBINPUT_NO_DEVICES='1',
        WLR_HEADLESS_OUTPUTS='1',
        PYTHONUNBUFFERED='1',
    )
    return env


def verify(binary):
    missing = [name for name in ('sway', 'swaymsg', 'dbus-run-session', 'dbus-daemon', 'gdbus')
               if shutil.which(name) is None]
    if missing:
        raise RuntimeError('missing native test dependencies: ' + ', '.join(missing) +
                           '; on Debian/Ubuntu install sway dbus-daemon libglib2.0-bin')
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise RuntimeError(f'ouroctl is not executable: {binary}')
    with tempfile.TemporaryDirectory(prefix='ourokit-verify-') as directory:
        root = Path(directory)
        env = environment(root, binary)
        config = root / 'sway.conf'
        config.write_text('xwayland disable\noutput * mode 1280x720 scale 1\n'
                          'default_border none\nfor_window [app_id=".*"] floating enable\n')
        with (root / 'sway.log').open('w+') as log:
            compositor = subprocess.Popen(['sway', '--config', str(config)], env=env,
                                          stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                deadline = time.monotonic() + 10
                while True:
                    if compositor.poll() is not None:
                        raise RuntimeError(f'Sway exited during startup: {compositor.returncode}')
                    displays = [p for p in root.glob('wayland-*') if p.is_socket()]
                    sockets = list(root.glob('sway-ipc.*.sock'))
                    if len(displays) == 1 and len(sockets) == 1:
                        probe = subprocess.run(['swaymsg', '-s', str(sockets[0]), '-t', 'get_outputs', '-r'],
                                               env=env, capture_output=True, timeout=3)
                        if probe.returncode == 0 and any(o['active'] for o in json.loads(probe.stdout)):
                            env['OUROKIT_TEST_WAYLAND_DISPLAY'] = str(displays[0])
                            break
                    if time.monotonic() >= deadline:
                        raise TimeoutError('Sway did not create a ready headless output')
                    time.sleep(.05)
                for name in TESTS:
                    print(f'RUN {name}', flush=True)
                    process = subprocess.Popen(['dbus-run-session', '--', sys.executable, str(ROOT / 'tests' / name)],
                                               cwd=ROOT, env=env, start_new_session=True)
                    try:
                        code = process.wait(timeout=120)
                        if code:
                            raise RuntimeError(f'{name} failed with exit status {code}')
                    finally:
                        stop(process)
                    if compositor.poll() is not None:
                        raise RuntimeError('Sway exited while tests were running')
                print(f'PASS development verification: all {len(TESTS)} suites ran on a private headless compositor', flush=True)
            except BaseException:
                log.seek(0)
                print('--- disposable Sway log ---\n' + log.read(), file=sys.stderr)
                raise
            finally:
                stop(compositor)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit('usage: verify_development.py /absolute/path/to/ouroctl')
    # Let finally blocks stop test children and the compositor on cancellation.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        verify(Path(sys.argv[1]).resolve())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        sys.exit(str(error))
