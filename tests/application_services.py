#!/usr/bin/env python3
"""Real-process stdio and inherited-listener checks; no compositor required.

Run after `zig build`: python3 tests/application_services.py
Requires systemd-socket-activate. Uses only temporary application files/sockets.
Set OUROKIT_TEST_WAYLAND_DISPLAY to an absolute compositor socket path to also
exercise native activation, repeated activation, live actions and exit draining.
"""
import json
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "zig-out/bin/ouroctl"


def call(path, method, parameters=None):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(8)
        client.connect(str(path))
        client.sendall(json.dumps({"method": method, "parameters": parameters or {}}).encode() + b"\0")
        response = bytearray()
        while b"\0" not in response:
            chunk = client.recv(65536)
            if not chunk:
                raise AssertionError(f"connection closed before {method} replied")
            response.extend(chunk)
        return json.loads(response.split(b"\0", 1)[0])


def check_signal_shutdown(directory, env):
    manifest = directory / "interrupt" / "ouro.json"
    manifest.parent.mkdir()
    app = manifest.parent / "interrupt.lua"
    manifest.write_text(json.dumps({"schema_version": 1, "id": "dev.ourokit.interrupt",
                                    "entry": "interrupt.lua"}))
    path = directory / "ourokit/apps/dev.ourokit.interrupt"
    sources = {
        "module-bootstrap": "o.stdout.write('ready\\n'); o.stdin.read(1); o.exit(0)",
        "ui-bootstrap": """
return o.app {
  id = 'dev.ourokit.interrupt', actions = {},
  run = function() o.stdout.write('ready\\n'); o.sleep(30000) end,
}
""",
        "inherited-headless": "return o.app {id='dev.ourokit.interrupt', actions={}}",
    }
    if os.environ.get("OUROKIT_TEST_WAYLAND_DISPLAY"):
        sources["native"] = """
return o.app {
  id = 'dev.ourokit.interrupt', actions = {},
  run = function() return {windows={o.layer_surface {
    id='panel', namespace='interrupt-test', layer='top',
    width=0, height=36, anchors={'top', 'left', 'right'},
    exclusive_zone=36, keyboard_interactivity='none',
    content=function() return o.text{key='title', text='Interrupt test'} end,
  }}} end,
}
"""
    for name, source in sources.items():
        app.write_text("local o = require('ouro')\n" + source)
        inherited = name == "inherited-headless"
        for sig in (signal.SIGINT, signal.SIGTERM):
            # Reuse the exact pathname on the next launch: leftover owned
            # sockets must fail this test rather than being manually removed.
            args = [str(BINARY), "run", str(app if name == "module-bootstrap" else manifest), "--software"]
            child_env = env.copy()
            if name == "native":
                child_env["WAYLAND_DISPLAY"] = os.environ["OUROKIT_TEST_WAYLAND_DISPLAY"]
            if inherited:
                path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                args = ["systemd-socket-activate", f"--listen={path}", "--fdname=varlink",
                        "--setenv=XDG_RUNTIME_DIR", "--setenv=WAYLAND_DISPLAY"] + args
            process = subprocess.Popen(args, env=child_env, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                if name in ("module-bootstrap", "ui-bootstrap"):
                    assert select.select([process.stdout], [], [], 8)[0], "bootstrap never became ready"
                    assert process.stdout.readline() == b"ready\n"
                else:
                    deadline = time.monotonic() + 8
                    while True:
                        assert process.poll() is None, process.stderr.read().decode()
                        assert time.monotonic() < deadline, "server never became ready"
                        if path.exists():
                            status = call(path, "dev.ourokit.runtime.Status")["parameters"]
                            if inherited or status["uiActive"]:
                                break
                        time.sleep(.01)
                if name != "module-bootstrap":
                    assert path.is_socket()
                    identity = path.stat().st_ino
                process.send_signal(sig)
                assert process.wait(timeout=8) == 128 + sig
                errors = process.stderr.read().decode()
                assert "panic" not in errors and "leaked" not in errors, errors
                if inherited:
                    assert path.is_socket() and path.stat().st_ino == identity
                    # This path belongs to the test's socket activator.
                    path.unlink()
                else:
                    assert not path.exists(), f"{name} left an owned socket behind"
                print(f"PASS: {name} {sig.name} exits cleanly and preserves socket ownership")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=8)
                process.stdin.close()
                process.stdout.close()
                process.stderr.close()


def main():
    with tempfile.TemporaryDirectory(prefix="ourokit-services-") as temp:
        directory = Path(temp)
        env = os.environ.copy()
        for key in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES", "WAYLAND_SOCKET"):
            env.pop(key, None)
        env.update(XDG_RUNTIME_DIR=temp, WAYLAND_DISPLAY="no-compositor-for-this-test")

        echo = directory / "echo.lua"
        echo.write_text("""
local o = require('ouro')
local bytes = ''
while true do
  local part = o.stdin.read(37)
  if part == nil then break end
  bytes = bytes .. part
end
o.stderr.write('diagnostic only\\n')
o.stdout.write(o.json.encode(o.json.decode(bytes)) .. '\\n')
o.exit(7)
""")
        payload = {"nested": [None, [], {}, {"text": "a\0b"}], "value": "x" * 17000}
        result = subprocess.run([str(BINARY), "run", str(echo), "--software"],
                                input=json.dumps(payload).encode(), capture_output=True, env=env, timeout=8)
        assert result.returncode == 7, result.stderr.decode()
        assert json.loads(result.stdout) == payload
        assert result.stderr == b"diagnostic only\n", result.stderr
        assert not (directory / "ourokit").exists(), "stdio-only app created a server namespace"
        print("PASS: async stdin/stdout/stderr, JSON array/null roundtrip, explicit exit, no UI/socket")

        check_signal_shutdown(directory, env)

        app = directory / "app.lua"
        source = """
local o = require('ouro')
local value = 'initial'
return o.app {
  id = 'dev.ourokit.servicetest',
  interface = [[interface dev.ourokit.servicetest
    method Get() -> (value: string, empty: []string)
    method Set(value: string) -> ()
    method Delayed() -> (value: string)
    method Invalid() -> (value: int)
    method Fail() -> ()
    error Rejected(reason: string)
  ]],
  actions = {
    Get = function() return {value = value, empty = o.json.array()} end,
    Set = function(p) value = p.value end,
    Delayed = function() o.sleep(30000); return {value = value} end,
    Invalid = function() return {value = 'not an integer'} end,
    Fail = function() return o.action_error('Rejected', {reason = 'test'}) end,
  },
}
"""
        app.write_text(source)
        manifest = directory / "ouro.json"
        manifest.write_text(json.dumps({"schema_version": 1, "id": "dev.ourokit.servicetest", "entry": "app.lua"}))
        path = directory / "ourokit/apps/dev.ourokit.servicetest"
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        log = directory / "service.log"
        with log.open("wb") as errors:
            process = subprocess.Popen(["systemd-socket-activate", f"--listen={path}", "--fdname=varlink",
                                        "--setenv=XDG_RUNTIME_DIR", "--setenv=WAYLAND_DISPLAY",
                                        str(BINARY), "run", str(manifest), "--software"],
                                       env=env, stdout=subprocess.DEVNULL, stderr=errors)
            try:
                for _ in range(200):
                    if path.exists():
                        break
                    if process.poll() is not None:
                        raise AssertionError(log.read_text())
                    time.sleep(.01)
                status = call(path, "dev.ourokit.runtime.Status")["parameters"]
                assert status["uiActive"] is False
                info = call(path, "org.varlink.service.GetInfo")["parameters"]
                assert set(info["interfaces"]) == {"org.varlink.service", "dev.ourokit.runtime", "dev.ourokit.servicetest"}
                description = call(path, "org.varlink.service.GetInterfaceDescription",
                                   {"interface": "dev.ourokit.servicetest"})["parameters"]["description"]
                assert "method Get()" in description and "CallAction" not in description
                assert call(path, "dev.ourokit.servicetest.Set", {"value": "changed"}) == {"parameters": {}}
                assert call(path, "dev.ourokit.servicetest.Get")["parameters"] == {"value": "changed", "empty": []}
                assert call(path, "dev.ourokit.servicetest.Set", {"value": 23})["error"] == "org.varlink.service.InvalidParameter"
                assert call(path, "dev.ourokit.servicetest.Invalid")["error"] == "dev.ourokit.runtime.ActionFailed"
                assert call(path, "dev.ourokit.servicetest.Fail") == {
                    "error": "dev.ourokit.servicetest.Rejected", "parameters": {"reason": "test"}}
                assert call(path, "dev.ourokit.runtime.Activate")["error"] == "dev.ourokit.runtime.ActivateFailed"
                assert call(path, "dev.ourokit.runtime.Status")["parameters"]["uiActive"] is False
                print("PASS: inherited listener, headless calls/introspection, typed inputs/outputs/errors, no-UI activation error")

                delayed = socket.socket(socket.AF_UNIX)
                delayed.settimeout(8)
                delayed.connect(str(path))
                delayed.sendall(b'{"method":"dev.ourokit.servicetest.Delayed"}\0')
                # A second connection remains responsive while this task sleeps.
                assert call(path, "dev.ourokit.servicetest.Get")["parameters"]["value"] == "changed"
                app.write_text(source.replace("'initial'", "'reloaded'"))
                assert call(path, "dev.ourokit.runtime.Reload")["parameters"]["generation"] == 2
                assert b"ActionFailed" in delayed.recv(65536)
                delayed.close()
                assert call(path, "dev.ourokit.servicetest.Get")["parameters"]["value"] == "reloaded"
                app.write_text(source.replace("method Get()", "method Missing()"))
                assert call(path, "dev.ourokit.runtime.Reload")["error"] == "dev.ourokit.runtime.ReloadFailed"
                assert call(path, "dev.ourokit.servicetest.Get")["parameters"]["value"] == "reloaded"
                assert call(path, "dev.ourokit.runtime.Status")["parameters"]["uiActive"] is False
                print("PASS: headless reload, pending-call cancellation, invalid declaration rollback")

                assert process.wait(timeout=40) == 0, log.read_text()
                assert path.exists(), "application unlinked inherited socket"
                print("PASS: 30-second headless idle exit retains inherited socket pathname")
            except Exception:
                print(log.read_text())
                raise
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=8)

        for name, run in (
            ("bad-factory", "function() return 42 end"),
            ("no-compositor", "function() return {windows={o.window{id='main', title='Test', width=50, height=50, content=function() end}}} end"),
        ):
            app.write_text(source.replace("  actions = {", f"  run = {run},\n  actions = {{"))
            failure_path = directory / name
            with log.open("wb") as errors:
                process = subprocess.Popen(["systemd-socket-activate", f"--listen={failure_path}",
                                            "--setenv=XDG_RUNTIME_DIR", "--setenv=WAYLAND_DISPLAY",
                                            str(BINARY), "run", str(manifest), "--software"],
                                           env=env, stdout=subprocess.DEVNULL, stderr=errors)
                try:
                    for _ in range(200):
                        if failure_path.exists():
                            break
                        time.sleep(.01)
                    response = call(failure_path, "dev.ourokit.runtime.Activate")
                    assert response["error"] == "dev.ourokit.runtime.ActivateFailed", response
                    assert process.wait(timeout=8) == 1, log.read_text()
                    assert "panic" not in log.read_text() and "leaked" not in log.read_text(), log.read_text()
                    print(f"PASS: {name} returns ActivateFailed before clean teardown")
                except Exception:
                    print(log.read_text())
                    raise
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=8)

        display = os.environ.get("OUROKIT_TEST_WAYLAND_DISPLAY")
        if display:
            env["WAYLAND_DISPLAY"] = display
            app.write_text("""
local o = require('ouro')
local title = o.signal('Initial')
return o.app {
  id = 'dev.ourokit.servicetest',
  interface = [[interface dev.ourokit.servicetest
    method Set(title: string) -> ()
    method Stop() -> ()
  ]],
  actions = {
    Set = function(p) title:set(p.title) end,
    Stop = function() o.stdout.write('finished\\n'); o.exit(9) end,
  },
  run = function() return {windows={o.window {
    id='main', title='Lifecycle test', width=300, height=100,
    content=function() return o.text{key='title', text=title()} end,
  }}} end,
}
""")
            native_path = directory / "native"
            with log.open("wb") as errors:
                process = subprocess.Popen(["systemd-socket-activate", f"--listen={native_path}",
                                            "--setenv=XDG_RUNTIME_DIR", "--setenv=WAYLAND_DISPLAY",
                                            str(BINARY), "run", str(manifest), "--software"],
                                           env=env, stdout=subprocess.PIPE, stderr=errors)
                try:
                    for _ in range(200):
                        if native_path.exists():
                            break
                        time.sleep(.01)
                    assert call(native_path, "dev.ourokit.runtime.Status")["parameters"]["uiActive"] is False
                    assert call(native_path, "dev.ourokit.servicetest.Set", {"title": "Before activation"}) == {"parameters": {}}
                    activation = call(native_path, "dev.ourokit.runtime.Activate")
                    assert activation == {"parameters": {}}, activation
                    assert call(native_path, "dev.ourokit.runtime.Status")["parameters"]["uiActive"] is True
                    assert call(native_path, "dev.ourokit.runtime.Activate") == {"parameters": {}}
                    assert call(native_path, "dev.ourokit.servicetest.Set", {"title": "While running"}) == {"parameters": {}}
                    with socket.socket(socket.AF_UNIX) as stop:
                        stop.connect(str(native_path))
                        stop.sendall(b'{"method":"dev.ourokit.servicetest.Stop"}\0')
                        stdout, _ = process.communicate(timeout=8)
                    assert process.returncode == 9 and stdout == b"finished\n", log.read_text()
                    assert native_path.exists()
                    assert "panic" not in log.read_text() and "leaked" not in log.read_text(), log.read_text()
                    print("PASS: native activation on shared ring, repeat activation, live action, action exit/output drain")
                except Exception:
                    print(log.read_text())
                    raise
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=8)


if __name__ == "__main__":
    main()
