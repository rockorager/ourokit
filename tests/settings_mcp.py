#!/usr/bin/env python3
"""Exercise production Lua clients against a disposable MCP-only ourosettings.

Run after zig build: python3 tests/settings_mcp.py --daemon /path/to/ourosettings
"""
import argparse
import copy
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
META = {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {},
    "io.modelcontextprotocol/clientInfo": {"name": "ourokit-test", "version": "1"},
}


def request(address, method, params):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(address))
        connection.sendall(json.dumps({"jsonrpc": "2.0", "id": 73, "method": method,
                                       "params": {**params, "_meta": META}}).encode() + b"\n")
        wire = bytearray()
        while b"\n" not in wire:
            block = connection.recv(65536)
            assert block, "daemon closed before reply"
            wire.extend(block)
            assert len(wire) <= 256 * 1024
        reply = json.loads(wire)
        assert reply["id"] == 73 and "error" not in reply, reply
        assert reply["result"]["resultType"] == "complete", reply
        return reply["result"]


def snapshot(address):
    result = request(address, "resources/read", {"uri": "ouro://settings"})
    return json.loads(result["contents"][0]["text"])


def replace(address, state):
    result = request(address, "tools/call", {"name": "settings.set", "arguments": {
        "expected_revision": state["revision"], "settings": state["value"],
    }})
    assert result["isError"] is False, result
    return result["structuredContent"]


def line(process, expected):
    actual = bytearray()
    deadline = time.monotonic() + 5
    while not actual.endswith(b"\n"):
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([process.stdout], [], [], remaining)[0], actual
        byte = os.read(process.stdout.fileno(), 1)
        assert byte, f"example exited: {process.stderr.read()!r}"
        actual.extend(byte)
    assert actual == expected, actual


def stop(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daemon", type=Path, required=True)
    parser.add_argument("--ouroctl", type=Path, default=ROOT / "zig-out/bin/ouroctl")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ourokit-mcp-") as temp:
        directory = Path(temp)
        address = directory / "ouro/settings.mcp.sock"
        address.parent.mkdir(mode=0o700)
        env = os.environ.copy()
        for key in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES", "WAYLAND_SOCKET", "WAYLAND_DISPLAY"):
            env.pop(key, None)
        env["XDG_RUNTIME_DIR"] = temp
        daemon = subprocess.Popen([str(args.daemon.resolve()), "--socket", str(address),
                                   "--state", str(directory / "state.json"), "--idle-ms", "300000"],
                                  env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        watcher = None
        try:
            deadline = time.monotonic() + 5
            while not address.exists():
                assert daemon.poll() is None, daemon.stderr.read()
                assert time.monotonic() < deadline, "daemon did not bind"
                time.sleep(.01)
            binary = str(args.ouroctl.resolve())
            query = subprocess.run([binary, "run", str(ROOT / "examples/ourosettings.lua")],
                                   env=env, capture_output=True, timeout=5)
            assert query.returncode == 0 and query.stdout == b"default\n" and query.stderr == b"", query
            watcher = subprocess.Popen([binary, "run", str(ROOT / "examples/ourosettings-watch.lua")],
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            line(watcher, b"default\n")
            state = snapshot(address)
            state["value"]["appearance"]["color_scheme"] = "dark"
            replace(address, state)
            line(watcher, b"dark\n")
            state = snapshot(address)
            unchanged = copy.deepcopy(state)
            state["value"]["compositor"]["general"] = {"mcp_test": True}
            changed = replace(address, state)
            assert changed["revision"] != unchanged["revision"]
            same = snapshot(address)
            assert replace(address, same)["revision"] == same["revision"]
            assert not select.select([watcher.stdout], [], [], .25)[0], "unrelated/no-op update notified"
            state = snapshot(address)
            state["value"]["appearance"]["color_scheme"] = "light"
            replace(address, state)
            line(watcher, b"light\n")
            print("PASS: Lua examples read initial state, subscribe before reading, and suppress unrelated/no-op updates")

            source = directory / "tools.lua"
            source.write_text('''local ouro = require('ouro')
local address = 'unix:' .. ouro.xdg.runtime_dir .. '/ouro/settings.mcp.sock'
assert(ouro.varlink == nil)
local listed = ouro.mcp.request(address, 'tools/list').result.tools
assert(#listed == 2)
local read = ouro.mcp.request(address, 'resources/read', {uri='ouro://settings'})
local current = ouro.json.decode(read.result.contents[1].text)
local written = ouro.mcp.call(address, 'settings.set_section', {
  expected_revision=current.revision, section='appearance', value={color_scheme='dark'},
})
assert(written.error == nil and written.result.isError == false)
assert(written.result.structuredContent.settings.appearance.color_scheme == 'dark')
local conflict = ouro.mcp.call(address, 'settings.set_section', {
  expected_revision=current.revision, section='appearance', value={color_scheme='light'},
})
assert(conflict.error == nil and conflict.result.isError == true)
assert(conflict.result.structuredContent.error.code == 'Conflict')
local missing = ouro.mcp.request(address, 'resources/read', {uri='ouro://settings/missing'})
local selection = ouro.json.decode(missing.result.contents[1].text)
assert(selection.exists == false and selection.value == ouro.mcp.null)
ouro.stdout.write('tools ok\\n')
ouro.exit(0)
''')
            called = subprocess.run([binary, "run", str(source)], env=env, capture_output=True, timeout=5)
            assert called.returncode == 0 and called.stdout == b"tools ok\n" and called.stderr == b"", called
            line(watcher, b"dark\n")
            stop(watcher)
            assert watcher.returncode == 128 + signal.SIGTERM and watcher.stderr.read() == b""
            assert not (directory / "ourokit/apps").exists()
            print("PASS: Lua tool discovery, writes, conflict errors, JSON null, and subscription shutdown")
        finally:
            if watcher is not None:
                stop(watcher)
            stop(daemon)


if __name__ == "__main__":
    main()
