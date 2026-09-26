#!/usr/bin/env python3
"""Render the real runner against a private Settings portal fixture.

Run after zig build with /usr/bin/python3 (requires PyGObject, dbus-daemon,
grim, and ImageMagick). Set OUROKIT_TEST_WAYLAND_DISPLAY to an absolute socket
on a disposable, otherwise empty compositor. OUROKIT_APPEARANCE_ARTIFACTS may
name a directory for the rendered no-portal, dark, light, and restarted states.
The fixture never connects to or changes the user's session bus.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import time

from gi.repository import Gio, GLib

ROOT = Path(__file__).resolve().parents[1]
PORTAL = "org.freedesktop.portal.Desktop"
PATH = "/org/freedesktop/portal/desktop"
INTERFACE = "org.freedesktop.portal.Settings"
NAMESPACE = "org.freedesktop.appearance"
XML = f"""<node><interface name='{INTERFACE}'>
<method name='ReadAll'><arg type='as' direction='in'/>
<arg type='a{{sa{{sv}}}}' direction='out'/></method>
<signal name='SettingChanged'><arg type='s'/><arg type='s'/><arg type='v'/></signal>
</interface></node>"""


class Portal:
    def __init__(self, address, value):
        self.value = value
        self.reads = 0
        self.bus = Gio.DBusConnection.new_for_address_sync(
            address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
            Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        self.registration = self.bus.register_object(
            PATH, Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], self.read, None, None)
        reply = self.bus.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            "RequestName", GLib.Variant("(su)", (PORTAL, 4)), None,
            Gio.DBusCallFlags.NONE, 1000, None)
        assert reply.unpack() == (1,), reply

    def read(self, bus, sender, path, interface, method, parameters, invocation):
        assert method == "ReadAll" and parameters.unpack() == ([NAMESPACE],)
        self.reads += 1
        invocation.return_value(GLib.Variant("(a{sa{sv}})", ({
            NAMESPACE: {"color-scheme": GLib.Variant("u", self.value)},
        },)))

    def change(self, value):
        self.value = value
        self.bus.emit_signal(None, PATH, INTERFACE, "SettingChanged",
                             GLib.Variant("(ssv)", (NAMESPACE, "color-scheme", GLib.Variant("u", value))))
        self.bus.flush_sync(None)

    def close(self):
        self.bus.unregister_object(self.registration)
        self.bus.close_sync(None)


def pump(seconds):
    end = time.monotonic() + seconds
    context = GLib.MainContext.default()
    while time.monotonic() < end:
        while context.pending():
            context.iteration(False)
        time.sleep(.005)


def capture(app, env, directory, name):
    pump(.5)
    assert app.poll() is None, "application exited before capture"
    output = directory / (name + ".png")
    subprocess.run(["grim", str(output)], env=env, check=True)
    return subprocess.check_output(["magick", str(output), "-depth", "8", "rgb:-"])


def stop(process):
    if process.poll() is None:
        process.terminate()
    process.wait(timeout=5)


def main():
    display = Path(os.environ["OUROKIT_TEST_WAYLAND_DISPLAY"])
    assert display.is_absolute() and display.exists()
    with tempfile.TemporaryDirectory(prefix="ourokit-appearance-") as temporary:
        directory = Path(temporary)
        artifacts = Path(os.environ.get("OUROKIT_APPEARANCE_ARTIFACTS", temporary))
        artifacts.mkdir(parents=True, exist_ok=True)
        bus = subprocess.Popen(["dbus-daemon", "--session", "--nofork", "--print-address=1"],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        app = portal = None
        try:
            address = bus.stdout.readline().strip()
            assert address.startswith("unix:"), address
            env = os.environ.copy()
            for key in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES", "WAYLAND_SOCKET"):
                env.pop(key, None)
            env.update(DBUS_SESSION_BUS_ADDRESS=address, XDG_RUNTIME_DIR=temporary,
                       WAYLAND_DISPLAY=str(display))
            with (directory / "app.stderr").open("wb") as errors:
                app = subprocess.Popen([str(ROOT / "zig-out/bin/ouroctl"), "run",
                                        str(ROOT / "examples/system-appearance.lua"), "--software"],
                                       env=env, stdout=subprocess.DEVNULL, stderr=errors)
                fallback = capture(app, env, artifacts, "appearance-no-portal")
                assert fallback.count(b"\xff\xff\xff") > 10000, "no window rendered without a portal"
                portal = Portal(address, 1)
                dark = capture(app, env, artifacts, "appearance-dark")
                assert portal.reads == 1, portal.reads
                assert sum(a != b for a, b in zip(dark, fallback)) > 30000, "dark read did not repaint"
                portal.change(2)
                light = capture(app, env, artifacts, "appearance-light")
                assert light == fallback, "light signal did not restore the fallback palette"
                assert portal.reads == 1, "a signal caused an unnecessary read"
                portal.close()
                portal = None
                pump(.1)
                portal = Portal(address, 1)
                restarted = capture(app, env, artifacts, "appearance-restarted")
                assert restarted == dark, "portal restart did not restore the dark palette"
                assert portal.reads == 1
                portal.close()
                portal = None
                lost = capture(app, env, artifacts, "appearance-owner-lost")
                assert lost == fallback, "owner loss did not reset to fallback"
                stop(app)
                assert app.returncode == 143, app.returncode
            stderr = (directory / "app.stderr").read_text()
            assert all(line.startswith(("info: application socket: ", "info: Wayland output available: "))
                       for line in stderr.splitlines()), stderr
            print("PASS: no-portal startup, dark initial read, light signal, dark restart, owner-loss fallback, clean shutdown")
        finally:
            if portal is not None:
                portal.close()
            if app is not None:
                stop(app)
            stop(bus)


if __name__ == "__main__":
    main()
