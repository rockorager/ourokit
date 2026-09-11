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
            assert len(response) <= 4 * 1024 * 1024
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


class RpcStream:
    """Unbuffered socket reader so quiet checks also inspect already-read bytes."""
    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(8)
        self.socket.connect(str(path))
        self.buffer = bytearray()

    def close(self):
        self.socket.close()

    def read(self):
        while b"\n" not in self.buffer:
            chunk = self.socket.recv(65536)
            assert chunk, "peer closed before reply"
            self.buffer.extend(chunk)
        line, _, remaining = self.buffer.partition(b"\n")
        self.buffer = bytearray(remaining)
        assert len(line) < 4 * 1024 * 1024
        return json.loads(line)

    def quiet(self):
        assert not self.buffer and not select.select([self.socket], [], [], .12)[0], "unexpected catalog notification"

    def cancel(self, request_id):
        self.socket.sendall(json.dumps({"jsonrpc": "2.0", "method": "notifications/cancelled",
                                       "params": {"requestId": request_id}}).encode() + b"\n")
        assert self.read() == {"jsonrpc": "2.0", "id": request_id, "result": {
            "resultType": "complete", "_meta": {"io.modelcontextprotocol/subscriptionId": request_id}}}


def check_catalog_changes(directory, path, app, source, process):
    published = directory / "ouro/mcp/apps/dev.ourokit.servicetest.json"
    initial = published.read_bytes()
    descriptor = json.loads(initial)
    assert set(descriptor) == {"schema_version", "application_id", "endpoint", "tools", "runtime"}
    assert descriptor["schema_version"] == 1 and descriptor["application_id"] == "dev.ourokit.servicetest"
    assert descriptor["endpoint"] == {"runtime_path": "ourokit/apps/dev.ourokit.servicetest"}
    assert descriptor["tools"] == request(path, "tools/list")["result"]["tools"]
    names = [tool["name"] for tool in descriptor["tools"]]
    assert names == sorted(names)
    assert descriptor["runtime"] == {"pid": process.pid, "start_ticks":
                                     Path(f"/proc/{process.pid}/stat").read_text().rsplit(")", 1)[1].split()[19]}
    assert published.stat().st_mode & 0o777 == 0o600
    assert published.stat().st_uid == os.getuid()

    stream = RpcStream(path)
    try:
        for invalid in ({}, {"resourcesListChanged": True}, {"toolsListChanged": False}, {"toolsListChanged": 1}):
            stream.socket.sendall(record("subscriptions/listen", {"notifications": invalid}, "bad"))
            assert stream.read()["error"]["code"] == -32602
        ids = ["catalog-a", 9007199254740993]
        for request_id in ids:
            stream.socket.sendall(record("subscriptions/listen", {"notifications": {
                "toolsListChanged": True, "resourcesListChanged": True}}, request_id))
            ack = stream.read()
            assert ack == {"jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged", "params": {
                "notifications": {"toolsListChanged": True}, "_meta": {"io.modelcontextprotocol/subscriptionId": request_id}}}
        stream.socket.sendall(record("tools/list", request_id="after-ack"))
        assert stream.read()["id"] == "after-ack"
        stream.quiet()

        def reload(candidate, changed, fails=False):
            before = published.stat()
            before_bytes = published.read_bytes()
            app.write_text(candidate)
            stream.socket.sendall(record("tools/call", {"name": "runtime.reload"}, "reload"))
            response = stream.read()
            # Runtime reply and notifications can complete in either order.
            messages = [response]
            for _ in range(len(ids) if changed else 0):
                messages.append(stream.read())
            replies = [m for m in messages if m.get("id") == "reload"]
            assert len(replies) == 1 and replies[0]["result"]["isError"] == fails, messages
            updates = [m for m in messages if m.get("method") == "notifications/tools/list_changed"]
            assert {m["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] for m in updates} == (set(ids) if changed else set())
            after = published.stat()
            if changed:
                assert after.st_ino != before.st_ino
            else:
                assert (after.st_ino, after.st_mtime_ns) == (before.st_ino, before.st_mtime_ns)
                assert published.read_bytes() == before_bytes
            assert json.loads(published.read_bytes())["tools"] == request(path, "tools/list")["result"]["tools"]
            stream.quiet()

        # Handler state and recursive object/declaration ordering are not catalog changes.
        reload(source.replace("'initial'", "'handler-only'"), False)
        reordered = source.replace("type='object', additionalProperties=false", "additionalProperties=false, type='object'")
        reordered = reordered.replace("properties=properties, required=required", "required=required, properties=properties")
        lines = reordered.splitlines()
        first = next(i for i, line in enumerate(lines) if line.startswith("    Get ="))
        second = next(i for i, line in enumerate(lines) if line.startswith("    Set ="))
        lines[first], lines[second] = lines[second], lines[first]
        reload("\n".join(lines), False)
        # Each independent catalog dimension must invalidate subscribers.
        described = source.replace("Service test action", "Changed description")
        reload(described, True)
        schema = described.replace("local str, int = {type='string'}, {type='integer'}", "local str, int = {type='string'}, {type='number'}")
        reload(schema, True)
        renamed = schema.replace("    Invalid =", "    Renamed =")
        reload(renamed, True)
        reload(renamed.replace("type='number'", "type='number', minimum=0"), False, fails=True)
        assert call(path, "runtime.status")["structuredContent"]["diagnostic"] is not None
        stream.cancel(ids.pop())
        reload(source, True)
        stream.cancel(ids.pop())
        stream.quiet()
    finally:
        stream.close()

    # Saturated pending calls must still admit a cancellation notification.
    saturated = RpcStream(path)
    try:
        for i in range(32):
            saturated.socket.sendall(record("subscriptions/listen", {"notifications": {"toolsListChanged": True}}, i))
            assert saturated.read()["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == i
        saturated.socket.sendall(record("tools/list", request_id="over-capacity"))
        assert saturated.read()["error"]["code"] == -32000
        saturated.cancel(17)
        saturated.socket.sendall(record("tools/list", request_id="available"))
        assert saturated.read()["id"] == "available"
        assert call(path, "runtime.status")["isError"] is False
    finally:
        saturated.close()

    # A nonreading subscriber with large IDs fills its bounded output queue;
    # another peer must still reload and observe each committed catalog.
    slow = RpcStream(path)
    observer = RpcStream(path)
    try:
        slow.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
        for i in range(32):
            slow.socket.sendall(record("subscriptions/listen", {"notifications": {"toolsListChanged": True}}, str(i) + "x" * 8192))
        observer.socket.sendall(record("subscriptions/listen", {"notifications": {"toolsListChanged": True}}, "healthy"))
        assert observer.read()["method"] == "notifications/subscriptions/acknowledged"
        for i in range(6):
            app.write_text(source.replace("Service test action", f"Slow subscriber round {i}"))
            assert call(path, "runtime.reload")["isError"] is False
            assert observer.read()["method"] == "notifications/tools/list_changed"
        observer.cancel("healthy")
    finally:
        observer.close()
        slow.close()
    print("PASS: catalog startup/identity, deterministic reloads, changed-only subscription invalidation, rollback, cancellation, saturation and slow-peer isolation")


def check_publication_safety(directory, env):
    for mode in ("normal", "trailing", "replacement", "crash", "outside", "symlink-dir", "symlink-file", "writable-dir", "writable-file"):
        runtime = directory / mode
        runtime.mkdir(mode=0o700)
        app = runtime / "app.lua"
        source = """
local o = require('ouro')
return o.app {id='dev.test.catalog', actions={
  Probe={description='Probe', inputSchema={type='object'}, outputSchema={type='object'}, handler=function() return {} end}
}}
"""
        app.write_text(source)
        manifest = runtime / "ouro.json"
        manifest.write_text(json.dumps({"schema_version": 1, "id": "dev.test.catalog", "entry": "app.lua"}))
        published = runtime / "ouro/mcp/apps/dev.test.catalog.json"
        victim = runtime / "victim"
        victim.write_text("preserve victim")
        if mode == "symlink-dir":
            (runtime / "elsewhere").mkdir()
            (runtime / "ouro").symlink_to(runtime / "elsewhere", target_is_directory=True)
        elif mode in ("symlink-file", "writable-dir", "writable-file"):
            published.parent.mkdir(parents=True, mode=0o700)
            if mode == "symlink-file":
                published.symlink_to(victim)
            elif mode == "writable-dir":
                published.parent.chmod(0o777)
            else:
                published.write_text("preserve unsafe file")
                published.chmod(0o666)
        endpoint = directory / "outside.sock" if mode == "outside" else runtime / "overridden.sock"
        local_env = dict(env, XDG_RUNTIME_DIR=str(runtime))
        listener_path = str(endpoint)
        if mode == "trailing":
            local_env["XDG_RUNTIME_DIR"] += "///"
            endpoint = runtime / "ourokit/apps/dev.test.catalog"
            endpoint.parent.mkdir(parents=True, mode=0o700)
            listener_path = local_env["XDG_RUNTIME_DIR"] + "/ourokit/apps/dev.test.catalog"
        log = runtime / "log"
        with log.open("wb") as errors:
            process = subprocess.Popen(["systemd-socket-activate", f"--listen={listener_path}", "--fdname=mcp",
                                        "--setenv=XDG_RUNTIME_DIR", "--setenv=WAYLAND_DISPLAY",
                                        str(BINARY), "run", str(manifest), "--software"],
                                       env=local_env, stdout=subprocess.DEVNULL, stderr=errors)
            try:
                for _ in range(200):
                    if endpoint.exists():
                        break
                    assert process.poll() is None, log.read_text()
                    time.sleep(.01)
                assert call(endpoint, "Probe")["isError"] is False
                safe = mode in ("normal", "trailing", "replacement", "crash")
                if safe:
                    descriptor = json.loads(published.read_bytes())
                    expected_path = "ourokit/apps/dev.test.catalog" if mode == "trailing" else "overridden.sock"
                    assert descriptor["endpoint"] == {"runtime_path": expected_path}
                    assert descriptor["runtime"]["pid"] == process.pid
                if mode == "replacement":
                    replacement = runtime / "replacement.json"
                    replacement.write_text("replacement stays")
                    replacement.replace(published)
                # Publication failures, including a safe inode replaced by its
                # owner, cannot invalidate this successfully committed reload.
                app.write_text(source.replace("description='Probe'", "description='Changed'"))
                assert call(endpoint, "runtime.reload")["isError"] is False
                assert next(t for t in request(endpoint, "tools/list")["result"]["tools"] if t["name"] == "Probe")["description"] == "Changed"
                if mode == "trailing":
                    assert json.loads(published.read_bytes())["endpoint"] == {"runtime_path": "ourokit/apps/dev.test.catalog"}
                if mode == "crash":
                    process.kill()
                else:
                    process.terminate()
                process.wait(timeout=8)
                if mode in ("normal", "trailing"):
                    assert not published.exists()
                elif mode == "replacement":
                    assert published.read_text() == "replacement stays"
                elif mode == "crash":
                    assert published.exists() and not Path(f"/proc/{process.pid}").exists()
                elif mode == "symlink-file":
                    assert published.is_symlink() and victim.read_text() == "preserve victim"
                elif mode == "writable-file":
                    assert published.read_text() == "preserve unsafe file"
                else:
                    assert not published.exists()
                assert "panic" not in log.read_text() and "leaked" not in log.read_text(), log.read_text()
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=8)
    print("PASS: runtime publication is best effort, normalizes trailing runtime slashes, uses actual endpoints, rejects symlink/unsafe paths, preserves replacement inodes, cleans graceful shutdown and identifies crash residue")


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
        check_publication_safety(directory, env)

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
                assert info["supportedVersions"] == ["2026-07-28"] and info["capabilities"] == {"tools": {"listChanged": True}}
                assert info["ttlMs"] == 60000 and info["cacheScope"] == "private"
                tools = request(path, "tools/list")["result"]
                assert {t["name"] for t in tools["tools"]} == {"runtime.status", "runtime.reload", "runtime.activate", "Get", "Set", "Delayed", "Invalid", "Fail"}
                assert tools["ttlMs"] == 60000 and tools["cacheScope"] == "private"
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
                        oversized.sendall(b" " * (4 * 1024 * 1024) + b"\n")
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

                check_catalog_changes(directory, path, app, source, process)
                assert process.wait(timeout=40) == 0, log.read_text()
                assert path.exists(), "application unlinked inherited socket"
                assert not (directory / "ouro/mcp/apps/dev.ourokit.servicetest.json").exists()
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
