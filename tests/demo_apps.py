#!/usr/bin/env python3
"""Native demo checks on a disposable Weston X11 display.

Requires DISPLAY, OUROKIT_TEST_WAYLAND_DISPLAY (absolute socket), xdotool,
ImageMagick and systemd-socket-activate. Optional OUROKIT_DEMO_ARTIFACTS saves
window captures and a scrolling clip. Never run on a display with personal apps.
Run after zig build: python3 tests/demo_apps.py
"""
import fcntl
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time

from application_services import BINARY, ROOT, call


def pointer(origin, x, y):
    subprocess.run(["xdotool", "mousemove", str(origin[0] + x), str(origin[1] + y), "click", "1"], check=True)
    time.sleep(.15)


def type_text(value):
    subprocess.run(["xdotool", "key", "ctrl+a"], check=True)
    subprocess.run(["xdotool", "type", "--clearmodifiers", "--delay", "5", value], check=True)
    time.sleep(.15)


def screen():
    return subprocess.check_output(["magick", "import", "-window", "root", "-depth", "8", "rgb:-"])


def window(process, width):
    screen_width = int(subprocess.check_output(["xdotool", "getdisplaygeometry"]).split()[0])
    for _ in range(50):
        assert process.poll() is None, "demo exited before showing its window"
        # The host leaves a white outer inset. Find the first full-width row,
        # ignoring the desktop's small white labels; no fixed window position.
        offset = screen().find(b"\xff" * (width * 3))
        if offset >= 0:
            y, x = divmod(offset // 3, screen_width)
            return x, y
        time.sleep(.05)
    raise AssertionError("native window did not appear")


def capture(directory, name, origin, size):
    if directory:
        subprocess.run(["magick", "import", "-window", "root", "-crop",
                        f"{size[0]}x{size[1]}+{origin[0]}+{origin[1]}",
                        str(directory / (name + ".png"))], check=True)


def stop(process):
    if process.poll() is None:
        process.terminate()
    process.wait(timeout=8)


def contacts(env, directory, artifacts):
    address = directory / "contacts.socket"
    process = subprocess.Popen(["systemd-socket-activate", f"--listen={address}", "--fdname=mcp",
                                "--setenv=XDG_RUNTIME_DIR", "--setenv=WAYLAND_DISPLAY",
                                str(BINARY), "run", str(ROOT / "examples/contacts/ouro.json"), "--software"],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    recorder = None
    try:
        for _ in range(100):
            if address.exists():
                break
            time.sleep(.02)
        people = call(address, "GetContacts")["structuredContent"]["contacts"]
        assert len(people) == 500 and people[0]["id"] == "ada" and people[-1]["id"] == "person-500"
        assert call(address, "runtime.status")["structuredContent"]["uiActive"] is False
        assert call(address, "SelectContact", {"id": "alan"})["structuredContent"] == {}
        assert call(address, "runtime.activate")["structuredContent"] == {}
        origin = window(process, 940)
        time.sleep(.4)
        capture(artifacts, "contacts-fallback", origin, (940, 650))
        assert call(address, "SelectContact", {"id": "ada"})["structuredContent"] == {}
        time.sleep(.3)
        capture(artifacts, "contacts-light", origin, (940, 650))
        pointer(origin, 560, 348)
        type_text("Ada Byron")
        capture(artifacts, "contacts-editing", origin, (940, 650))
        pointer(origin, 650, 400)
        actual = call(address, "GetContacts")["structuredContent"]["contacts"][0]["name"]
        assert actual == "Ada Byron", actual
        if artifacts:
            recorder = subprocess.Popen(["ffmpeg", "-loglevel", "error", "-y", "-f", "x11grab",
                                         "-framerate", "20", "-video_size", "940x650", "-i",
                                         f"{os.environ['DISPLAY']}+{origin[0]},{origin[1]}", "-t", "10",
                                         "-c:v", "libx264", "-preset", "veryfast", "-crf", "20",
                                         "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                                         str(artifacts / "contacts-scroll.mp4")])
            time.sleep(.5)
        subprocess.run(["xdotool", "mousemove", str(origin[0] + 210), str(origin[1] + 330)], check=True)
        for _ in range(24):
            subprocess.run(["xdotool", "click", "5"], check=True)
            time.sleep(.04)
        capture(artifacts, "contacts-scrolled", origin, (940, 650))
        assert call(address, "SelectContact", {"id": "person-480"})["structuredContent"] == {}
        changed = call(address, "RenameContact", {"id": "person-480", "name": "Distant contact"})
        assert changed["structuredContent"]["contact"]["name"] == "Distant contact"
        time.sleep(.8)
        pointer(origin, 840, 50)
        capture(artifacts, "contacts-terminal", origin, (940, 650))
        if recorder:
            assert recorder.wait(timeout=15) == 0
        assert call(address, "SelectContact", {"id": "ada"})["structuredContent"] == {}
        assert call(address, "GetContacts")["structuredContent"]["contacts"][0]["name"] == "Ada Byron"
        time.sleep(.2)
        pointer(origin, 500, 505)
        out, errors = process.communicate(timeout=8)
        assert process.returncode == 0 and out == b"" and b"panic" not in errors, errors
        print("PASS: 500 headless contacts, activation, UI rename, scrolling, distant MCP edit, themes, clean Quit")
    finally:
        if recorder and recorder.poll() is None:
            recorder.terminate()
            recorder.wait(timeout=8)
        stop(process)


def dialog(env, artifacts, allowed):
    read_fd, write_fd = os.pipe()
    fcntl.fcntl(write_fd, fcntl.F_SETPIPE_SZ, 4096)
    process = subprocess.Popen([str(BINARY), "run", str(ROOT / "examples/permission-dialog/ouro.json"), "--software"],
                               env=env, stdin=subprocess.PIPE, stdout=write_fd, stderr=subprocess.PIPE)
    try:
        process.stdin.write(b'{"app_name":"Screenshot tool"}')
        process.stdin.close()
        process.stdin = None
        origin = window(process, 620)
        time.sleep(.3)
        if allowed:
            capture(artifacts, "permission-light", origin, (620, 420))
            pointer(origin, 450, 300)
            assert process.poll() is None
            assert not select.select([read_fd], [], [], 0)[0], "empty confirmation produced a decision"
            capture(artifacts, "permission-validation", origin, (620, 420))
            pointer(origin, 310, 205)
            type_text("allow")
            pointer(origin, 450, 300)
            assert process.poll() is None, "lowercase confirmation must not allow"
            assert not select.select([read_fd], [], [], 0)[0], "lowercase confirmation produced a decision"
            pointer(origin, 310, 205)
            type_text("ALLOW")
            pointer(origin, 515, 56)
            capture(artifacts, "permission-terminal", origin, (620, 420))
            pointer(origin, 515, 56)
            os.write(write_fd, b"x" * 4096)
            pointer(origin, 450, 300)
            time.sleep(.3)
            assert process.poll() is None, "full stdout must suspend rather than block or exit"
            capture(artifacts, "permission-pending", origin, (620, 420))
            pointer(origin, 170, 300)  # Must not enqueue a second decision.
            assert os.read(read_fd, 4096) == b"x" * 4096
        else:
            pointer(origin, 170, 300)
        _, errors = process.communicate(timeout=8)
        assert process.returncode == 0 and errors == b"", errors
        assert os.read(read_fd, 4096) == (b'{"allowed":true}\n' if allowed else b'{"allowed":false}\n')
        print("PASS: dialog " + ("validation, theme retention, backpressured async output, single allow" if allowed else "denial without confirmation"))
    finally:
        os.close(write_fd)
        os.close(read_fd)
        stop(process)


def main():
    artifacts = Path(os.environ["OUROKIT_DEMO_ARTIFACTS"]) if "OUROKIT_DEMO_ARTIFACTS" in os.environ else None
    if artifacts:
        artifacts.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ourokit-demo-checks-") as temp:
        env = os.environ.copy()
        for key in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES", "WAYLAND_SOCKET"):
            env.pop(key, None)
        env.update(XDG_RUNTIME_DIR=temp, WAYLAND_DISPLAY=os.environ["OUROKIT_TEST_WAYLAND_DISPLAY"])
        contacts(env, Path(temp), artifacts)
        dialog(env, artifacts, True)
        dialog(env, artifacts, False)
        assert not (Path(temp) / "ourokit/apps/dev.ourokit.permission-dialog").exists()
        for source in (b"not json", b"x" * 65537):
            result = subprocess.run([str(BINARY), "run", str(ROOT / "examples/permission-dialog/ouro.json"), "--software"],
                                    input=source, capture_output=True, env=env, timeout=8)
            assert result.returncode != 0 and result.stdout == b""
        print("PASS: malformed/oversized requests fail closed; permission dialog creates no service socket")


if __name__ == "__main__":
    main()
