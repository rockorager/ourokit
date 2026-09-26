#!/usr/bin/env python3
"""Optional production MCP catalog/consumer integration, without an external bridge.

Run after zig build: python3 tests/mcp_bridge.py
Two independent consumers share one explicitly started application. Discovery
only reads toolkit-owned descriptors; it never starts a desktop or dev instance.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

from application_services import BINARY, RpcStream, call, record, request

APP = 'dev.ourokit.bridgetest'


def source(version):
    name = 'Add' if version == 1 else 'AddChanged'
    return f'''local o = require('ouro')
local count = 0
return o.app {{id='{APP}', actions={{
  {name}={{description='Counter version {version}',
    inputSchema={{type='object',properties={{amount={{type='integer'}}}},required={{'amount'}},additionalProperties=false}},
    outputSchema={{type='object',properties={{count={{type='integer'}}}},required={{'count'}},additionalProperties=false}},
    handler=function(p) count=count+p.amount; return {{count=count}} end}},
}}, run=function() error('consumer must not activate UI') end}}
'''


def main():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    with tempfile.TemporaryDirectory(prefix='ourokit-consumers-') as temp:
        root = Path(temp)
        env = dict(os.environ, XDG_RUNTIME_DIR=temp, XDG_DATA_HOME=str(root / 'data'))
        app = root / 'app.lua'
        app.write_text(source(1))
        descriptor = root / f'data/ourokit/mcp/apps/{APP}.json'
        result = subprocess.run([str(BINARY), 'mcp', 'export', str(app), '--output', str(descriptor)],
                                env=env, capture_output=True, timeout=10)
        assert result.returncode == 0, result.stderr
        installed = json.loads(descriptor.read_bytes())
        assert {t['name'] for t in installed['tools']} == {'Add'}
        address = root / installed['endpoint']['runtime_path']
        assert not address.exists()
        assert not (root / 'ourokit/mcp').exists()
        print('PASS: offline action catalog discovery starts no app or socket')
        for version in (1, 2):
            app.write_text(source(version))
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--mcp', '--headless'],
                                       env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            consumers = []
            try:
                deadline = time.monotonic() + 8
                while not address.exists():
                    assert process.poll() is None and time.monotonic() < deadline
                    time.sleep(.01)
                name = 'Add' if version == 1 else 'AddChanged'
                for index in range(2):
                    peer = RpcStream(address)
                    consumers.append(peer)
                    peer.socket.sendall(record('subscriptions/listen', {'notifications': {'toolsListChanged': True}}, index))
                    assert peer.read()['method'] == 'notifications/subscriptions/acknowledged'
                    peer.socket.sendall(record('tools/list', request_id='list'))
                    assert {t['name'] for t in peer.read()['result']['tools']} == {name}
                assert call(address, name, {'amount': 2})['structuredContent'] == {'count': 2}
                assert call(address, name, {'amount': 5})['structuredContent'] == {'count': 7}
                runtime = root / f'ourokit/mcp/apps/{APP}.json'
                live = json.loads(runtime.read_bytes())
                assert live['tools'] == request(address, 'tools/list')['result']['tools']
                assert live['runtime']['pid'] == process.pid
                for method in ('runtime.status', 'runtime.reload', 'runtime.activate'):
                    assert call(address, method)['rpcError']['code'] == -32602
                consumers.pop().close()
                assert call(address, name, {'amount': 11})['structuredContent'] == {'count': 18}
                assert json.loads(descriptor.read_bytes()) == installed
                assert not (root / 'ourokit/dev').exists()
                print(f'PASS: generation {version} shared state, peer EOF isolation, runtime catalog override; no dev authority')
            finally:
                for peer in consumers:
                    peer.close()
                process.terminate()
                process.wait(timeout=8)
                errors = process.stderr.read()
                assert b'panic' not in errors and b'leaked' not in errors, errors
            assert not address.exists() and not runtime.exists()
        print('PASS: explicit restart updates live schemas and preserves installed baseline; owned endpoints clean up')


if __name__ == '__main__':
    main()
