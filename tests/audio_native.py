#!/usr/bin/env python3
"""Real PipeWire integration, isolated socket/config; never touches host audio."""
import ctypes as C
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time

from application_services import call, development_path

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / 'zig-out/bin/ouroctl').resolve()
CONFIG = '''
context.properties = { core.daemon = true core.name = ouro-audio-test }
context.spa-libs = { audio.convert.* = audioconvert/libspa-audioconvert support.* = support/libspa-support }
context.modules = [
 { name = libpipewire-module-protocol-native }
 { name = libpipewire-module-metadata }
 { name = libpipewire-module-spa-node-factory }
 { name = libpipewire-module-client-node }
 { name = libpipewire-module-access }
 { name = libpipewire-module-adapter }
]
context.objects = [
 { factory = metadata args = { metadata.name = default } }
 { factory = adapter args = { factory.name = support.null-audio-sink node.name = fixture.one node.description = "First Output" media.class = Audio/Sink audio.position = [ FL FR ] } }
 { factory = adapter args = { factory.name = support.null-audio-sink node.name = fixture.two node.description = "Second Output" media.class = Audio/Sink audio.position = [ MONO ] } }
]
'''

class Snapshot(C.Structure):
    _fields_ = [('identity', C.c_uint64), ('volume', C.c_double), ('id', C.c_uint32),
                ('connected', C.c_int), ('available', C.c_int), ('muted', C.c_int),
                ('error', C.c_int), ('name', C.c_char * 512), ('description', C.c_char * 512)]

def run(env, *args):
    p = subprocess.run(args, env=env, capture_output=True, text=True, timeout=5)
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return p.stdout

def main():
    with tempfile.TemporaryDirectory(prefix='ourokit-audio-') as temp:
        root = Path(temp)
        env = dict(os.environ, XDG_RUNTIME_DIR=temp, PIPEWIRE_RUNTIME_DIR=temp,
                   PIPEWIRE_REMOTE='ouro-audio-test', PIPEWIRE_CONFIG_DIR=temp)
        # Keep the standard client config separate from the private daemon config.
        env.pop('PIPEWIRE_CONFIG_DIR')
        os.environ.update({k: env[k] for k in ('XDG_RUNTIME_DIR', 'PIPEWIRE_RUNTIME_DIR', 'PIPEWIRE_REMOTE')})
        config = root / 'daemon.conf'; config.write_text(CONFIG)
        libpath = root / 'audio.so'
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libpipewire-0.3'], text=True).split()
        subprocess.run(['gcc', '-shared', '-fPIC', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'src/lua/audio.c'), '-pthread', '-lm', '-o', str(libpath), *flags], check=True)
        subprocess.run(['gcc', '-std=gnu11', '-Wall', '-Wextra', '-Werror',
                        str(ROOT / 'tests/audio_route.c'), '-pthread', '-lm', '-o', str(root / 'routes'), *flags], check=True)
        print(run(env, str(root / 'routes')).strip())
        lib = C.CDLL(str(libpath))
        lib.ouro_audio_create.restype = C.c_void_p
        for name in ('launch', 'fd', 'done', 'stop', 'destroy'):
            getattr(lib, 'ouro_audio_' + name).argtypes = [C.c_void_p]
        lib.ouro_audio_snapshot.argtypes = [C.c_void_p, C.POINTER(Snapshot)]
        lib.ouro_audio_set.argtypes = [C.c_void_p, C.c_uint64, C.c_int, C.c_double]
        handle = lib.ouro_audio_create(); assert handle
        assert lib.ouro_audio_launch(handle) == 0
        fd = lib.ouro_audio_fd(handle)
        latest = Snapshot()
        def wait(predicate, label):
            deadline = time.monotonic() + 5
            while not predicate(latest):
                assert time.monotonic() < deadline, (label, latest.connected, latest.available, latest.name, latest.volume, latest.error)
                if select.select([fd], [], [], .1)[0]:
                    os.read(fd, 1); lib.ouro_audio_snapshot(handle, C.byref(latest))
            return latest
        def metadata(value):
            run(env, 'pw-metadata', '-n', 'default', '0', 'default.audio.sink', value, 'Spa:String:JSON')
        def start():
            p = subprocess.Popen(['pipewire', '-c', str(config)], env=env, stdout=subprocess.DEVNULL, stderr=log)
            for _ in range(100):
                if (root / 'ouro-audio-test').exists(): break
                assert p.poll() is None, 'daemon startup failed'
                time.sleep(.02)
            return p
        daemon = None
        with (root / 'daemon.log').open('w+') as log:
            try:
                assert lib.ouro_audio_set(handle, 0, 0, .5) == 1
                daemon = start()
                wait(lambda s: s.connected, 'connect after initially absent daemon')
                assert not latest.available
                metadata('{"name":"fixture.one"}')
                wait(lambda s: s.available and s.name == b'fixture.one', 'first default')
                first_id, first_identity = latest.id, latest.identity
                assert latest.description == b'First Output'
                run(env, 'pw-cli', 'set-param', str(first_id), 'Props', '{channelVolumes:[0.027,0.512],mute:true}')
                wait(lambda s: s.muted and abs(s.volume - .3) < 1e-5, 'external asymmetric volume/mute')
                assert lib.ouro_audio_set(handle, first_identity, 0, .5) == 0
                wait(lambda s: abs(s.volume - .5) < 1e-5, 'set cubic volume')
                dump = json.loads(run(env, 'pw-dump', str(first_id)))
                props = dump[0]['info']['params']['Props'][0]
                assert props['channelVolumes'] == [.125, .125] and props['mute'], props
                for _ in range(7): assert lib.ouro_audio_set(handle, first_identity, 2, .03) == 0
                wait(lambda s: abs(s.volume - .71) < 1e-5, 'rapid relative increments')
                assert lib.ouro_audio_set(handle, first_identity, 2, 1) == 0
                wait(lambda s: abs(s.volume - 1) < 1e-5, 'upper clamp')
                assert lib.ouro_audio_set(handle, first_identity, 2, -1) == 0
                wait(lambda s: s.volume == 0, 'lower clamp')
                assert lib.ouro_audio_set(handle, first_identity, 1, 0) == 0
                wait(lambda s: not s.muted, 'unmute independently')
                metadata('{"name":"fixture.two"}')
                wait(lambda s: s.available and s.name == b'fixture.two', 'switch default')
                assert latest.identity != first_identity
                assert lib.ouro_audio_set(handle, first_identity, 0, .2) == 3
                metadata('{"name":"missing"}')
                wait(lambda s: not s.available and not s.name, 'missing default')
                metadata('broken-json')
                assert lib.ouro_audio_set(handle, first_identity, 1, 1) == 1
                metadata('{"name":"fixture.one"}')
                wait(lambda s: s.available and s.name == b'fixture.one', 'restore default')
                run(env, 'pw-cli', 'destroy', str(first_id))
                wait(lambda s: not s.available, 'output removal')
                daemon.terminate(); daemon.wait(timeout=5); daemon = None
                wait(lambda s: not s.connected and not s.available, 'disconnect')
                daemon = start()
                metadata('{"name":"fixture.one"}')
                wait(lambda s: s.available and s.name == b'fixture.one', 'reconnect')
                assert latest.identity != first_identity
                assert lib.ouro_audio_set(handle, first_identity, 0, .2) == 3
                print('PASS native audio: absent service, external Props, cubic scaling, mute, relative bursts/clamps, defaults, removal, reconnect, stale identity')
                lua = root / 'test.lua'
                lua.write_text('''
local o = require('ouro')
local output <close> = assert(o.audio.default_output())
assert(not output().available)
local initial = assert(output:next()); assert(not initial.available)
local function fails(expected, value, reason) assert(value == nil and reason == expected, reason) end
fails('InvalidVolume', output:set_volume(-.1))
fails('InvalidVolume', output:set_volume(1.01))
fails('InvalidVolume', output:set_volume(0/0))
fails('InvalidVolume', output:set_volume('0.5'))
fails('InvalidMute', output:set_muted(1))
fails('OutputUnavailable', output:set_muted(true))
local state
repeat state = assert(output:next()) until state.available
state.volume = 55; assert(output().volume ~= 55)
assert(output:set_volume(.2))
repeat state = assert(output:next()) until math.abs(state.volume-.2) < .0001
for i=1,9 do assert(output:adjust_volume(.04)) end
repeat state = assert(output:next()) until math.abs(state.volume-.56) < .0001
assert(output:set_muted(true))
repeat state = assert(output:next()) until state.muted
-- Close while next is parked must wake it, and repeated close is harmless.
o.spawn(function() o.sleep(20); output:close() end)
repeat state = output:next() until state == nil
fails('OutputClosed', output())
assert(output:close())
-- Scope/generation shutdown must retire an abandoned live worker.
assert(o.audio.default_output())
o.stdout.write('PASS Lua audio: snapshots, next stream, validation, relative burst, close/wakeup, abandoned shutdown\\n')
o.exit(0)
return o.app{id='dev.ourokit.audio-test'}
''')
                result = run(env, str(BINARY), 'run', str(lua), '--headless')
                assert 'PASS Lua audio:' in result, result
                print(result.strip())
                lua.write_text('''
local o = require('ouro')
local output = assert(o.audio.default_output())
repeat local s = assert(output:next()) until s.available
local _, initial_error = output:set_volume(.33)
return o.app{id='dev.ourokit.audio-reload', actions={
 State={description='Audio state',inputSchema={type='object'},outputSchema={type='object'},
 handler=function() return {state=output(), initial_error=initial_error} end},
 Set={description='Set after commit',inputSchema={type='object'},outputSchema={type='object'},
 handler=function() assert(output:set_volume(.47)); return {} end}
}}
''')
                app = subprocess.Popen([str(BINARY), 'run', str(lua), '--headless', '--dev'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=log)
                try:
                    endpoint = development_path(root, app)
                    for generation in range(2, 5):
                        reply = call(endpoint, 'runtime.reload')['structuredContent']
                        assert reply.get('generation') == generation, reply
                        state = call(endpoint, 'State')['structuredContent']
                        assert state['initial_error'] == 'AudioCandidate' and state['state']['available'], state
                        assert not call(endpoint, 'Set').get('isError')
                    deadline = time.monotonic() + 3
                    while abs(call(endpoint, 'State')['structuredContent']['state']['volume']-.47) > .0001:
                        assert time.monotonic() < deadline
                        time.sleep(.02)
                    app.terminate()
                    assert app.wait(timeout=5) == 143
                    print('PASS audio reload: candidate observation, write isolation, commit activation, retired-worker cleanup, shutdown')
                finally:
                    if app.poll() is None: app.terminate(); app.wait(timeout=5)
            finally:
                lib.ouro_audio_stop(handle)
                deadline = time.monotonic() + 2
                while not lib.ouro_audio_done(handle):
                    assert time.monotonic() < deadline, 'worker stop timeout'
                    time.sleep(.005)
                lib.ouro_audio_destroy(handle)
                if daemon is not None: daemon.terminate(); daemon.wait(timeout=5)

if __name__ == '__main__': main()
