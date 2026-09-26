#!/usr/bin/env python3
"""Private-bus desktop service integration entry point.

Usage: tests/desktop_services.py /path/to/ouroctl

Runs the adjacent Lua portal/notification fixture, never the real session bus.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import signal


def main():
    assert len(sys.argv) <= 2, "usage: desktop_services.py [OUROCTL]"
    binary = Path(sys.argv[1] if len(sys.argv) == 2 else os.environ.get("OUROKIT_TEST_BINARY", "zig-out/bin/ouroctl")).resolve()
    assert binary.is_file(), binary
    with tempfile.TemporaryDirectory(prefix="ourokit-desktop-") as temporary:
        daemon = subprocess.Popen(
            ["dbus-daemon", "--session", "--nofork", "--print-address=1"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            start_new_session=True)
        try:
            address = daemon.stdout.readline().strip()
            assert address.startswith("unix:"), address
            env = os.environ.copy()
            env["DBUS_SESSION_BUS_ADDRESS"] = address
            env["XDG_RUNTIME_DIR"] = temporary
            (Path(temporary) / "document").write_text("external-open fixture")
            env["OURO_DESKTOP_PRIVATE_BUS"] = "1"
            driver = Path(__file__).with_name("desktop_services.lua")
            if not driver.exists():
                raise FileNotFoundError(f"desktop test driver missing: {driver}")
            run = subprocess.Popen([str(binary), "run", str(driver), "--headless"], env=env,
                                   start_new_session=True)
            try:
                result = run.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(run.pid, signal.SIGKILL)
                run.wait()
                raise RuntimeError("desktop service driver exceeded 30 second deadline")
            if result:
                raise subprocess.CalledProcessError(result, run.args)
        finally:
            if daemon.poll() is None:
                os.killpg(daemon.pid, signal.SIGTERM)
                try: daemon.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(daemon.pid, signal.SIGKILL); daemon.wait()


if __name__ == "__main__":
    main()
