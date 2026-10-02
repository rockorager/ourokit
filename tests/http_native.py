#!/usr/bin/env python3
"""Exercise the real Lua/curl/io_uring path against disposable loopback peers."""
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import select
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import time


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == '/slow':
            self.server.slow_started.set()
            self.server.release_slow.wait(10)
        if self.path == '/delay':
            time.sleep(0.15)
        body = b'a\x00b\xff-tail'
        status = 404 if self.path == '/missing' else 302 if self.path == '/redirect' else 200
        if self.path == '/gzip':
            body = gzip.compress(b'z' * 4097)
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Repeat', 'first')
        self.send_header('x-repeat', 'second')
        if self.path == '/redirect':
            self.send_header('Location', '/must-not-follow')
        if self.path == '/gzip':
            self.send_header('Content-Encoding', 'gzip')
        self.end_headers()
        try:
            if self.command != 'HEAD':
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the client cancels or times out.

    do_HEAD = do_GET

    def do_POST(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        self.send_response(201)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Method', self.command)
        self.send_header('X-Received', self.headers.get('X-Sent', 'absent'))
        self.end_headers()
        self.wfile.write(body)

    do_PATCH = do_POST


def serve(context=None):
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.slow_started = threading.Event()
    server.release_slow = threading.Event()
    if context:
        server.socket = context.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server, thread


SOURCE = r'''
local o = require('ouro')
local h = o.http
local base = 'http://localhost:HTTP_PORT'
local function fails(expected, fn)
    local ok, err = pcall(fn)
    assert(not ok and string.find(err, expected, 1, true), tostring(err))
end
local bytes = 'a\0b\255-tail'
local r = h.get(base .. '/', {max_bytes=#bytes})
assert(r.status == 200 and r.body == bytes)
assert(#r.headers['x-repeat'] == 2)
assert(r.headers['x-repeat'][1] == 'first' and r.headers['x-repeat'][2] == 'second')
r = h.post(base .. '/', {body='post\0payload\255', headers={['X-Sent']='unequal'}})
assert(r.status == 201 and r.body == 'post\0payload\255')
assert(r.headers['x-method'][1] == 'POST' and r.headers['x-received'][1] == 'unequal')
r = h.request {url=base .. '/', method='PATCH', body='patch\0end'}
assert(r.body == 'patch\0end' and r.headers['x-method'][1] == 'PATCH')
assert(h.request {url=base .. '/', method='HEAD'}.body == '')
assert(h.get(base .. '/missing').status == 404)
assert(h.get(base .. '/redirect').status == 302)
fails('ResponseTooLarge', function() h.get(base .. '/', {max_bytes=#bytes-1}) end)
assert(#h.get(base .. '/gzip', {max_bytes=4097}).body == 4097)
fails('ResponseTooLarge', function() h.get(base .. '/gzip', {max_bytes=4096}) end)
fails('HttpTimeout', function() h.get(base .. '/slow', {timeout_ms=30}) end)
fails('InvalidUrl', function() h.get('file:///etc/passwd') end)
fails('InvalidHeader', function() h.get(base, {headers={['X-Bad']='x\r\nInjected: true'}}) end)
fails('InvalidMethod', function() h.request {url=base, method='GET\r\n'} end)
fails('InvalidHttpLimits', function() h.get(base, {timeout_ms=0}) end)
fails('CertificateVerificationFailed', function() h.get('https://localhost:TLS_PORT/') end)
local tick = false
o.spawn(function() o.sleep(5); tick = true end)
assert(h.get(base .. '/delay').status == 200 and tick, 'network request blocked timer task')
local done = 0
for i=1,8 do
    o.spawn(function()
        local value = 'concurrent-' .. i
        assert(h.post(base .. '/', {body=value}).body == value)
        done = done + 1
    end)
end
while done < 8 do o.sleep(1) end
-- Repeated completion and fd reuse, not just one successful transfer.
for i=1,20 do assert(h.get(base .. '/').body == bytes) end
o.stdout.write('PASS HTTP: binary bodies, headers, status, bounds, TLS rejection, timers and concurrency\n')
o.exit(0)
return o.app {id='dev.ourokit.http-fixture'}
'''


def run(binary, root, env, source, expected):
    app = root / 'app.lua'
    app.write_text(source)
    result = subprocess.run([str(binary), 'run', str(app), '--headless'],
                            env=env, capture_output=True, text=True, timeout=15)
    assert result.returncode == 0 and expected in result.stdout, (result.returncode, result.stdout, result.stderr)
    print(result.stdout.strip())


def reload_test(binary, root, env, server):
    server.slow_started.clear()
    app = root / 'reload.lua'
    app.write_text(f'''
local o = require('ouro')
o.spawn(function()
  o.http.get('http://localhost:{server.server_port}/slow')
  o.stdout.write('UNEXPECTED old HTTP task resumed\\n')
end)
return o.app {{id='dev.ourokit.http-reload'}}
''')
    process = subprocess.Popen([str(binary), 'run', str(app), '--headless', '--dev'],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert server.slow_started.wait(5), 'request never reached server'
        endpoints = list((root / 'ourokit/dev').glob('*'))
        assert len(endpoints) == 1, endpoints
        app.write_text('''
local o = require('ouro')
o.spawn(function() o.stdout.write('READY replacement\\n') end)
return o.app {id='dev.ourokit.http-reload'}
''')
        result = subprocess.run([str(binary), 'dev', 'reload', str(endpoints[0])],
                                env=env, capture_output=True, text=True, timeout=5)
        assert result.returncode == 0 and 'as generation 2' in result.stdout, (result.stdout, result.stderr)
        assert select.select([process.stdout], [], [], 5)[0], 'replacement did not run'
        assert process.stdout.readline() == 'READY replacement\n'
        process.terminate()
        stdout, stderr = process.communicate(timeout=5)
        assert process.returncode == 128 + signal.SIGTERM and 'UNEXPECTED' not in stdout, (stdout, stderr)
        print('PASS HTTP: reload cancels old requests without resuming retired Lua; shutdown drains')
    finally:
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)


def main():
    binary = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/ouroctl').resolve()
    with tempfile.TemporaryDirectory(prefix='ourokit-http-') as directory:
        root = Path(directory)
        key, cert = root / 'key.pem', root / 'cert.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                        '-keyout', str(key), '-out', str(cert), '-days', '1',
                        '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'],
                       check=True, capture_output=True)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        servers = [serve(), serve(context)]
        http, tls = (item[0] for item in servers)
        # No ambient proxy, session bus, credentials, or trust overrides.
        env = {key: value for key, value in os.environ.items()
               if key.lower() not in ('http_proxy', 'https_proxy', 'all_proxy', 'no_proxy')
               and key not in ('CURL_CA_BUNDLE', 'SSL_CERT_FILE', 'SSL_CERT_DIR', 'DBUS_SESSION_BUS_ADDRESS')}
        env.update(XDG_RUNTIME_DIR=str(root), NO_PROXY='*', HOME=str(root))
        try:
            source = SOURCE.replace('HTTP_PORT', str(http.server_port)).replace('TLS_PORT', str(tls.server_port))
            run(binary, root, env, source, 'PASS HTTP:')
            reload_test(binary, root, env, http)
        finally:
            for server, thread in servers:
                server.release_slow.set()
                server.shutdown()
                server.server_close()
                thread.join()


if __name__ == '__main__':
    main()
