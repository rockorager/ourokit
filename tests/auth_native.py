#!/usr/bin/env python3
"""Exercise the real Lua/io_uring/PAM bridge with a disposable mock libpam.

No system PAM files, accounts, or credentials are read or changed.
"""
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ.get('OUROKIT_TEST_BINARY', ROOT / 'zig-out/bin/ouroctl')).resolve()

SOURCE = r'''
local o = require('ouro')
local function fails(expected, value, reason) assert(value == nil and reason == expected, reason) end
fails('InvalidService', o.auth.start('../invalid', 'fixture-user'))
fails('InvalidUsername', o.auth.start('fixture', ''))
local function attempt(service)
  local a <close> = assert(o.auth.start(service, 'fixture-user'))
  -- Responses come only from a masked text_input; Lua has no response API.
  assert(a.submit == nil and a.respond == nil and a.clear_input == nil)
  local e = assert(a:next()); assert(e.type == 'info')
  e = assert(a:next()); assert(e.type == 'prompt' and e.echo and e.text == 'Identity')
  a:cancel()
  fails('ConversationClosed', a:next())
end
-- Canceled workers are reaped asynchronously; slot reuse is covered natively.
attempt('fixture')
local crashed <close> = assert(o.auth.start('crash', 'fixture-user'))
local crash = assert(crashed:next())
assert(crash.type == 'result' and not crash.success and crash.reason == 'worker_failed')
local blocked = assert(o.auth.start('blocked', 'fixture-user'))
o.spawn(function() o.sleep(1); blocked:cancel() end)
fails('ConversationClosed', blocked:next())
local a = assert(o.auth.start('fixture', 'fixture-user'))
assert(a:next().type == 'info')
assert(a:next().type == 'prompt')
a:cancel()
fails('ConversationClosed', a:next())
-- Leave one abandoned conversation for process-shutdown draining.
assert(o.auth.start('blocked', 'fixture-user'))
o.stdout.write('PASS Lua auth: no response API, prompts, crash, cancellation and shutdown\n')
o.exit(0)
return o.app {id='dev.ourokit.auth-fixture'}
'''

def verify_reload(root, env, service='fixture'):
    app = root / 'reload.lua'
    app.write_text('''
local o = require('ouro')
o.spawn(function()
  local auth <close> = assert(o.auth.start('SERVICE', 'fixture-user'))
  if 'SERVICE' == 'fixture' then
    assert(auth:next().type == 'info')
    assert(auth:next().type == 'prompt')
  else o.sleep(100) end -- allow the deliberately blocked PAM call to begin
  o.stdout.write('READY auth reload\\n')
  auth:next() -- canceled while awaiting a response in the old generation
  o.stdout.write('UNEXPECTED old authentication resumed\\n')
end)
return o.app {id='dev.ourokit.auth-reload'}
'''.replace('SERVICE', service))
    process = subprocess.Popen([str(BINARY), 'run', str(app), '--headless', '--dev'], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert select.select([process.stdout], [], [], 5)[0], 'auth reload startup timeout'
        assert process.stdout.readline() == 'READY auth reload\n'
        started = time.monotonic()
        endpoint = next((root / 'ourokit/dev').glob('*'))
        app.write_text('''
local o = require('ouro')
assert(not o.auth.start('fixture', 'fixture-user'), 'candidate must not authenticate')
return o.app {id='dev.ourokit.auth-reload'}
''')
        result = subprocess.run([str(BINARY), 'dev', 'reload', str(endpoint)], env=env,
                                capture_output=True, text=True, timeout=5)
        assert result.returncode == 0 and 'as generation 2' in result.stdout, (result.stdout, result.stderr)
        process.terminate()
        stdout, stderr = process.communicate(timeout=5)
        assert process.returncode == 128 + signal.SIGTERM and 'UNEXPECTED' not in stdout, (process.returncode, stdout, stderr)
        assert time.monotonic() - started < 2, 'blocked PAM generation retirement exceeded 2 seconds'
        print(f'PASS auth: reload cancels {service} conversation; candidate cannot launch PAM')
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=5)

def main():
    with tempfile.TemporaryDirectory(prefix='ourokit-auth-') as temp:
        root = Path(temp)
        subprocess.run([os.environ.get('OUROKIT_TEST_ZIG', 'zig'), 'cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'tests/pam_fixture.c'), '-o', str(root / 'libpam.so.0')], check=True)
        harness = root / 'auth_native'
        subprocess.run([os.environ.get('OUROKIT_TEST_ZIG', 'zig'), 'cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-I', str(ROOT / 'src/lua'), str(ROOT / 'tests/auth_native.c'),
                        str(ROOT / 'src/lua/auth.c'), '-pthread', '-ldl', '-o', str(harness)], check=True)
        app = root / 'app.lua'
        app.write_text(SOURCE)
        env = dict(os.environ, LD_LIBRARY_PATH=str(root), XDG_RUNTIME_DIR=str(root))
        native = subprocess.run([str(harness)], env=env, capture_output=True, text=True, timeout=15)
        assert native.returncode == 0 and 'PASS native auth' in native.stdout, (native.stdout, native.stderr)
        print(native.stdout.strip())
        started = time.monotonic()
        try:
            result = subprocess.run([str(BINARY), 'run', str(app), '--headless'], env=env,
                                    capture_output=True, text=True, timeout=15)
        except subprocess.TimeoutExpired as error:
            raise AssertionError(('auth timeout', error.stdout, error.stderr)) from error
        assert result.returncode == 0, (result.stdout, result.stderr)
        assert time.monotonic() - started < 2, 'blocked PAM shutdown exceeded 2 seconds'
        assert 'PASS Lua auth:' in result.stdout, (result.stdout, result.stderr)
        print(result.stdout.strip())
        verify_reload(root, env)
        verify_reload(root, env, 'blocked')

if __name__ == '__main__':
    main()
