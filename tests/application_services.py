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


def record(method, params=None, request_id=1):
    params = dict(params or {})
    params["_meta"] = {
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities": {},
        "io.modelcontextprotocol/clientInfo": {"name": "ourokit-test", "version": "1"},
    }
    return json.dumps({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}).encode() + b"\n"


def request(path, method, params=None):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(8)
        client.connect(str(path))
        client.sendall(record(method, params))
        response = bytearray()
        while b"\n" not in response:
            chunk = client.recv(65536)
            if not chunk:
                raise AssertionError(f"connection closed before {method} replied")
            response.extend(chunk)
            assert len(response) <= 256 * 1024
        value = json.loads(response.split(b"\n", 1)[0])
        assert value["jsonrpc"] == "2.0" and value["id"] == 1, value
        if "result" in value:
            assert value["result"]["resultType"] == "complete", value
        return value


def call(path, name, arguments=None):
    response = request(path, "tools/call", {"name": name, "arguments": arguments or {}})
    if "error" in response:
        return {"rpcError": response["error"]}
    result = response["result"]
    assert json.loads(result["content"][0]["text"]) == result["structuredContent"]
    return result


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
                args = ["systemd-socket-activate", f"--listen={path}", "--fdname=mcp",
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
                            status = call(path, "runtime.status")["structuredContent"]
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
    # Noninteractive launchers may ignore SIGINT. The runtime deliberately
    # preserves that disposition; these tests need enabled shutdown signals.
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
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
local empty = {type='object', additionalProperties=false}
local str, int = {type='string'}, {type='integer'}
local function obj(properties, required)
  return {type='object', properties=properties, required=required, additionalProperties=false}
end
local function action(input, output, handler)
  return {description='Service test action', inputSchema=input, outputSchema=output, handler=handler}
end
return o.app {
  id = 'dev.ourokit.servicetest',
  actions = {
    Get = action(empty, obj({value=str, empty={type='array',items=str}}, {'value','empty'}), function() return {value=value, empty=o.json.array()} end),
    Set = action(obj({value=str}, {'value'}), empty, function(p) value=p.value end),
    Delayed = action(empty, obj({value=str}, {'value'}), function() o.sleep(30000); return {value=value} end),
    Invalid = action(empty, obj({value=int}, {'value'}), function() return {value='not an integer'} end),
    Fail = action(empty, empty, function() return o.action_error('Rejected', {reason='test'}) end),
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
            process = subprocess.Popen(["systemd-socket-activate", f"--listen={path}", "--fdname=mcp",
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
                status = call(path, "runtime.status")["structuredContent"]
                assert status["uiActive"] is False
                info = request(path, "server/discover")["result"]
                assert info["supportedVersions"] == ["2026-07-28"] and info["capabilities"] == {"tools": {}}
                assert info["ttlMs"] == 0 and info["cacheScope"] == "private"
                tools = request(path, "tools/list")["result"]
                assert {t["name"] for t in tools["tools"]} == {"runtime.status", "runtime.reload", "runtime.activate", "Get", "Set", "Delayed", "Invalid", "Fail"}
                assert tools["ttlMs"] == 0 and tools["cacheScope"] == "private"
                assert all("inputSchema" in t and "outputSchema" in t and t["description"] for t in tools["tools"])
                assert call(path, "Set", {"value": "changed"})["structuredContent"] == {}
                assert call(path, "Get")["structuredContent"] == {"value": "changed", "empty": []}
                assert call(path, "Set", {"value": 23})["rpcError"]["code"] == -32602
                assert call(path, "Missing")["rpcError"]["code"] == -32602
                assert request(path, "initialize")["error"]["code"] == -32601
                invalid = call(path, "Invalid")
                assert invalid["isError"] is True and invalid["structuredContent"]["error"]["code"] == "ActionFailed"
                failure = call(path, "Fail")
                assert failure["isError"] is True and failure["structuredContent"] == {
                    "error": {"code": "Rejected", "message": "Rejected", "parameters": {"reason": "test"}}}
                assert call(path, "runtime.activate")["structuredContent"]["error"]["code"] == "ActivateFailed"
                assert call(path, "runtime.status")["structuredContent"]["uiActive"] is False
                print("PASS: inherited listener, headless calls/introspection, typed inputs/outputs/errors, no-UI activation error")

                with socket.socket(socket.AF_UNIX) as cancel:
                    cancel.settimeout(8)
                    cancel.connect(str(path))
                    cancel.sendall(record("tools/call", {"name": "Delayed"}, "cancel-me"))
                    cancel.sendall(b'{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"cancel-me"}}\n')
                    with cancel.makefile("rb") as stream:
                        terminal = json.loads(stream.readline())
                        assert terminal["id"] == "cancel-me" and terminal["result"]["isError"] is True
                        cancel.sendall(record("tools/call", {"name": "Get"}, "after-cancel"))
                        after = json.loads(stream.readline())
                        assert after["id"] == "after-cancel" and after["result"]["structuredContent"]["value"] == "changed"
                with socket.socket(socket.AF_UNIX) as oversized:
                    oversized.settimeout(8)
                    oversized.connect(str(path))
                    try:
                        oversized.sendall(b" " * (256 * 1024) + b"\n")
                        assert oversized.recv(1) == b""
                    except (BrokenPipeError, ConnectionResetError):
                        pass
                assert call(path, "runtime.status")["structuredContent"]["uiActive"] is False
                print("PASS: explicit cancellation keeps connection usable; oversized peer cannot terminate server")

                delayed = socket.socket(socket.AF_UNIX)
                delayed.settimeout(8)
                delayed.connect(str(path))
                delayed.sendall(record("tools/call", {"name": "Delayed"}, "delayed"))
                # A second connection remains responsive while this task sleeps.
                assert call(path, "Get")["structuredContent"]["value"] == "changed"
                # Status completes ahead of the sleeping action on the SAME connection.
                delayed.sendall(record("tools/call", {"name": "runtime.status"}, "status"))
                stream = delayed.makefile("rb")
                status_response = json.loads(stream.readline())
                assert status_response["id"] == "status" and status_response["result"]["structuredContent"]["uiActive"] is False
                app.write_text(source.replace("'initial'", "'reloaded'"))
                assert call(path, "runtime.reload")["structuredContent"]["generation"] == 2
                cancelled = json.loads(stream.readline())
                assert cancelled["id"] == "delayed" and cancelled["result"]["isError"] is True
                stream.close()
                delayed.close()
                assert call(path, "Get")["structuredContent"]["value"] == "reloaded"
                app.write_text(source.replace("type='integer'", "type='integer', minimum=0"))
                assert call(path, "runtime.reload")["structuredContent"]["error"]["code"] == "ReloadFailed"
                assert call(path, "Get")["structuredContent"]["value"] == "reloaded"
                assert call(path, "runtime.status")["structuredContent"]["uiActive"] is False
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
                    response = call(failure_path, "runtime.activate")
                    assert response["structuredContent"]["error"]["code"] == "ActivateFailed", response
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
  actions = {
    Set = {description='Set title', inputSchema={type='object', properties={title={type='string'}}, required={'title'}, additionalProperties=false}, outputSchema={type='object'}, handler=function(p) title:set(p.title) end},
    Stop = {description='Exit', inputSchema={type='object'}, outputSchema={type='object'}, handler=function() o.stdout.write('finished\\n'); o.exit(9) end},
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
                    assert call(native_path, "runtime.status")["structuredContent"]["uiActive"] is False
                    assert call(native_path, "Set", {"title": "Before activation"})["structuredContent"] == {}
                    activation = call(native_path, "runtime.activate")
                    assert activation["structuredContent"] == {}, activation
                    assert call(native_path, "runtime.status")["structuredContent"]["uiActive"] is True
                    assert call(native_path, "runtime.activate")["structuredContent"] == {}
                    assert call(native_path, "Set", {"title": "While running"})["structuredContent"] == {}
                    with socket.socket(socket.AF_UNIX) as stop:
                        stop.connect(str(native_path))
                        stop.sendall(record("tools/call", {"name": "Stop"}))
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
