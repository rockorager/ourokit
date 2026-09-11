#!/usr/bin/env python3
"""Cross-project bridge/export/activation/reload test.

Run after zig build: python3 tests/mcp_bridge.py --bridge /path/to/ouro-mcp
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time

from application_services import BINARY, call, record

APP = "dev.ourokit.bridgetest"


def exposed(name):
    return "ouro_" + hashlib.sha256((APP + "\0" + name).encode()).hexdigest()


class Bridge:
    def __init__(self, command, env):
        self.process = subprocess.Popen([*command, "--app", APP], env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = bytearray()
        self.next_id = 0
        self.pending = []

    def send(self, method, params=None):
        self.next_id += 1
        self.process.stdin.write(record(method, params, self.next_id))
        self.process.stdin.flush()
        return self.next_id

    def receive(self, predicate):
        deadline = time.monotonic() + 10
        while True:
            for index, message in enumerate(self.pending):
                if predicate(message):
                    return self.pending.pop(index)
            if b"\n" in self.buffer:
                wire, _, tail = self.buffer.partition(b"\n")
                self.buffer = bytearray(tail)
                assert len(wire) + 1 <= 4 * 1024 * 1024
                message = json.loads(wire)
                assert message["jsonrpc"] == "2.0", message
                self.pending.append(message)
                continue
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([self.process.stdout], [], [], remaining)[0], self.pending
            block = os.read(self.process.stdout.fileno(), 65536)
            assert block, f"bridge exited: {self.process.stderr.read()!r}"
            self.buffer.extend(block)

    def request(self, method, params=None):
        request_id = self.send(method, params)
        message = self.receive(lambda m: m.get("id") == request_id)
        assert "error" not in message, message
        assert message["result"]["resultType"] == "complete", message
        return message["result"]

    def tools(self):
        return {tool["name"]: tool for tool in self.request("tools/list")["tools"]}

    def tool(self, name, arguments=None):
        result = self.request("tools/call", {"name": exposed(name), "arguments": arguments or {}})
        assert not result.get("isError", False), result
        return result["structuredContent"]

    def listen(self):
        request_id = self.send("subscriptions/listen", {"notifications": {"toolsListChanged": True}})
        ack = self.receive(lambda m: m.get("method") == "notifications/subscriptions/acknowledged")
        assert ack["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == request_id
        assert ack["params"]["notifications"]["toolsListChanged"] is True
        return request_id

    def changed(self, subscription):
        return self.receive(lambda m: m.get("method") == "notifications/tools/list_changed" and
                            m["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] == subscription)

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
            raise
        assert self.process.returncode == 0, self.process.stderr.read()


def source(version):
    name = "Add" if version == 1 else "AddChanged"
    return f'''local o = require('ouro')
o.stdout.write('APP_STARTED\\n')
local count = 0
return o.app {{id='{APP}', actions={{
  {name}={{description='Counter version {version}',
    inputSchema={{type='object',properties={{amount={{type='integer'}}}},required={{'amount'}},additionalProperties=false}},
    outputSchema={{type='object',properties={{count={{type='integer'}}}},required={{'count'}},additionalProperties=false}},
    handler=function(p) count=count+p.amount; return {{count=count}} end}},
}}, run=function() error('bridge should not activate UI') end}}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", nargs=argparse.REMAINDER, required=True)
    command = parser.parse_args().bridge
    assert command
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    with tempfile.TemporaryDirectory(prefix="ouro-bridge-") as temp:
        root = Path(temp)
        env = os.environ.copy()
        for key in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES", "WAYLAND_SOCKET", "WAYLAND_DISPLAY"):
            env.pop(key, None)
        env.update(XDG_RUNTIME_DIR=temp, XDG_DATA_HOME=str(root / "data"),
                   XDG_DATA_DIRS=str(root / "system"), XDG_CACHE_HOME=str(root / "cache"))
        app = root / "app.lua"
        app.write_text(source(1))
        manifest = root / "ouro.json"
        manifest.write_text(json.dumps({"schema_version": 1, "id": APP, "entry": "app.lua"}))
        descriptor = root / "data/ouro/mcp/apps" / f"{APP}.json"
        exported = subprocess.run([str(BINARY), "mcp", "export", str(manifest), "--output", str(descriptor)],
                                  env=env, capture_output=True, timeout=10)
        assert exported.returncode == 0, exported.stderr
        address = root / f"ourokit/apps/{APP}"
        address.parent.mkdir(mode=0o700, parents=True)
        service = subprocess.Popen(["systemd-socket-activate", f"--listen={address}", "--fdname=mcp",
                                    "--setenv=XDG_RUNTIME_DIR", str(BINARY), "run", str(manifest)],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        bridges = []
        try:
            deadline = time.monotonic() + 5
            while not address.exists():
                assert service.poll() is None and time.monotonic() < deadline
                time.sleep(.01)
            a = Bridge(command, env)
            b = Bridge(command, env)
            bridges.extend([a, b])
            sub_a, sub_b = a.listen(), b.listen()
            assert exposed("Add") in a.tools() and exposed("Add") in b.tools()
            assert not select.select([service.stdout], [], [], .2)[0], "offline discovery started app"
            print("PASS: exported catalog feeds two stdio bridges without activating the app")
            assert a.tool("Add", {"amount": 2}) == {"count": 2}
            assert b.tool("Add", {"amount": 5}) == {"count": 7}
            assert a.tool("runtime.status")["uiActive"] is False
            print("PASS: first calls socket-activate one headless app; bridge processes share app state")

            app.write_text(source(2))
            reloaded = call(address, "runtime.reload")
            assert not reloaded["isError"], reloaded
            a.changed(sub_a)
            b.changed(sub_b)
            for bridge in (a, b):
                tools = bridge.tools()
                assert exposed("Add") not in tools and exposed("AddChanged") in tools, tools
            assert b.tool("AddChanged", {"amount": 11}) == {"count": 11}
            print("PASS: successful app reload invalidates both host catalogs and routes the new tool")

            a.close()
            bridges.remove(a)
            assert b.tool("AddChanged", {"amount": 3}) == {"count": 14}
            c = Bridge(command, env)
            bridges.append(c)
            assert exposed("AddChanged") in c.tools() and exposed("Add") not in c.tools()
            assert descriptor.read_text().find('"name":"Add"') >= 0, "test baseline unexpectedly updated"
            print("PASS: one bridge EOF leaves other calls alive; a new bridge discovers the runtime override")
        finally:
            for bridge in bridges:
                bridge.close()
            if service.poll() is None:
                service.terminate()
            try:
                service.wait(timeout=8)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait(timeout=5)
                raise


if __name__ == "__main__":
    main()
