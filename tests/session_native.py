#!/usr/bin/env python3
"""Strict disposable Wayland peer for native session client integration.

This tests client wire behavior and actual SHM rendering, not compositor security
or KMS presentation. Never connects to the user's compositor.
"""
import array
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1] if len(sys.argv) > 1 else os.environ.get('OUROKIT_TEST_BINARY', ROOT / 'zig-out/bin/ouroctl')).resolve()

SOURCE = r'''
local o = require('ouro')
return o.app {id='dev.ourokit.session-fixture', theme={color_scheme='dark'}, run=function()
  local visible = o.signal(false)
  local clicked = o.signal(false)
  local typed = o.signal('')
  local topology_done = false
  o.spawn(function()
    local ok, reason = pcall(function()
      local outputs <close> = o.session.outputs()
      local first = table.concat(outputs:next(), ',')
      assert(first == 'TEST-1,TEST-2', 'initial outputs: '..first)
      while table.concat(outputs:next(), ',') ~= 'TEST-1,TEST-3' do end
      outputs:close()
      local names, reason = outputs:next()
      assert(names == nil and reason == 'closed')
      topology_done = true
    end)
    if not ok then o.stdout.write(tostring(reason)..'\n'); o.exit(1) end
  end)
  o.spawn(function()
    local idle <close> = o.session.idle(123, true)
    assert(idle:next() == 'idled')
    assert(idle:next() == 'resumed')
    idle:close()
    assert(idle:next() == 'closed')
    local ordinary <close> = o.session.idle(456)
    assert(ordinary:next() == 'idled')
    assert(ordinary:next() == 'resumed')
    local power <close> = o.session.power('TEST-1')
    assert(power:next() == 'on')
    power:set(false); assert(power:next() == 'off')
    power:set(true); assert(power:next() == 'on')
    local lock = o.session.lock()
    assert(not pcall(function() lock:unlock() end))
    visible:set(true)
    assert(lock:next() == 'locked')
    lock:close() -- close/GC must not unlock a secure session
    o.sleep(1000)
    assert(clicked(), 'per-output pointer input did not reach the lock UI')
    assert(typed() == 'TEST-3:a', 'keyboard input did not reach the hotplugged output')
    assert(topology_done, 'output stream did not report hotplug')
    LOSS
    lock:unlock(); assert(lock:next() == 'unlocked')
    visible:set(false)
    o.sleep(80)
    local denied = o.session.lock(); assert(denied:next() == 'finished')
    local second = o.session.lock(); visible:set(true)
    assert(second:next() == 'locked')
    assert(not pcall(function() lock:unlock() end), 'old lock must not unlock the new lock')
    o.sleep(80)
    second:unlock(); assert(second:next() == 'unlocked')
    visible:set(false)
    o.stdout.write('PASS session client\n')
    o.exit(0)
  end)
  return {windows=function()
    if not visible() then return {} end
    return {o.lock_surface {id='lock', outputs='all', background='#182233', content=function(output)
      return o.column {key='root', children={
        o.text {key='title', text='Native session lock — '..output},
        o.button {key='input', label=clicked() and 'Input received' or 'Test input', width=180, height=48,
          on_press=function() clicked:set(true) end},
        o.text {key='note', text='Protocol test fixture; not a production lock screen'},
        o.text_input {key='keyboard', default_text='', autofocus=true, width=180,
          label='Non-secret input test', on_change=function(value) typed:set(output..':'..value) end},
      }}
    end}}
  end}
end}
'''

def u32(value):
    return struct.pack('<I', value & 0xffffffff)

class Peer:
    def __init__(self, root, remove_managers=False):
        self.root, self.remove_managers = root, remove_managers
        self.xml = {}
        wanted = {'wayland.xml', 'ext-idle-notify-v1.xml', 'ext-session-lock-v1.xml',
                  'wlr-output-power-management-unstable-v1.xml'}
        supplied = os.environ.get('OUROKIT_TEST_PROTOCOL_XMLS')
        paths = map(Path, supplied.split(os.pathsep)) if supplied else (ROOT / 'zig-pkg').rglob('*.xml')
        for path in paths:
            if path.name in wanted:
                for interface in ET.parse(path).getroot().findall('interface'):
                    self.xml[interface.attrib['name']] = interface
        assert 'ext_session_lock_v1' in self.xml
        self.objects = {1: ('wl_display', {})}
        self.globals = {1: ('wl_compositor', 4), 2: ('wl_shm', 1), 3: ('wl_seat', 7),
                        4: ('ext_idle_notifier_v1', 2), 5: ('ext_session_lock_manager_v1', 1),
                        6: ('zwlr_output_power_manager_v1', 1), 7: ('wl_output', 4), 8: ('wl_output', 4)}
        self.output_names = {7: 'TEST-1', 8: 'TEST-2', 9: 'TEST-3'}
        self.sizes = {7: (480, 300), 8: (640, 360), 9: (420, 260)}
        self.listener = socket.socket(socket.AF_UNIX)
        self.path = str(root / 'wayland-test')
        self.listener.bind(self.path)
        self.listener.listen(1)
        self.listener.settimeout(8)
        self.fds, self.buffer, self.captures = [], b'', {}
        self.locks = self.unlocks = self.idles = self.powers = 0
        self.acked = set()
        self.locked = threading.Event()
        self.failure = None
        self.hotplug_at = None
        self.click_at = None

    def send(self, obj, event, *values):
        interface = self.objects[obj][0]
        events = self.xml[interface].findall('event')
        opcode, descriptor = next((i, e) for i, e in enumerate(events) if e.attrib['name'] == event)
        body, fds = b'', []
        for arg, value in zip(descriptor.findall('arg'), values, strict=True):
            if arg.attrib['type'] == 'fd':
                fds.append(value)
            elif arg.attrib['type'] == 'string':
                raw = value.encode() + b'\0'
                body += u32(len(raw)) + raw + b'\0' * (-len(raw) % 4)
            elif arg.attrib['type'] == 'array':
                body += u32(len(value)) + value + b'\0' * (-len(value) % 4)
            else:
                body += u32(value)
        wire = u32(obj) + u32(((len(body) + 8) << 16) | opcode) + body
        if fds:
            assert self.socket.sendmsg([wire], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', fds))]) == len(wire)
        else:
            self.socket.sendall(wire)

    def destroy(self, obj):
        self.send(1, 'delete_id', obj)
        del self.objects[obj]

    def request(self, obj, opcode, body):
        interface, data = self.objects[obj]
        descriptor = self.xml[interface].findall('request')[opcode]
        name, args, offset = descriptor.attrib['name'], {}, 0
        for arg in descriptor.findall('arg'):
            key, kind = arg.attrib['name'], arg.attrib['type']
            if kind == 'fd':
                args[key] = self.fds.pop(0)
            elif kind == 'new_id' and 'interface' not in arg.attrib:
                length = struct.unpack_from('<I', body, offset)[0]; offset += 4
                args['interface'] = body[offset:offset+length-1].decode(); offset += (length+3)//4*4
                args['version'], args[key] = struct.unpack_from('<II', body, offset); offset += 8
            elif kind == 'string':
                length = struct.unpack_from('<I', body, offset)[0]; offset += 4
                args[key] = body[offset:offset+length-1].decode(); offset += (length+3)//4*4
            else:
                args[key] = struct.unpack_from('<I', body, offset)[0]; offset += 4
                if kind == 'new_id': self.objects[args[key]] = (arg.attrib['interface'], {})
        assert offset == len(body), (interface, name, args)
        if interface == 'wl_display':
            if name == 'get_registry':
                self.registry = args['registry']
                for number, (iface, version) in self.globals.items(): self.send(self.registry, 'global', number, iface, version)
            elif name == 'sync':
                self.send(args['callback'], 'done', 1); self.destroy(args['callback'])
        elif interface == 'wl_registry':
            target, iface, number = args['id'], args['interface'], args['name']
            self.objects[target] = (iface, {'global': number})
            if iface == 'wl_shm': self.send(target, 'format', 0)
            if iface == 'wl_seat': self.send(target, 'capabilities', 3); self.send(target, 'name', 'test-seat')
            if iface == 'wl_output':
                w, h = self.sizes[number]
                self.send(target, 'geometry', 0, 0, 300, 200, 0, 'Fixture', 'Output', 0)
                self.send(target, 'mode', 3, w, h, 60000)
                self.send(target, 'scale', 1)
                self.send(target, 'name', self.output_names[number]); self.send(target, 'done')
        elif interface == 'wl_shm' and name == 'create_pool':
            self.objects[args['id']][1].update(fd=args['fd'])
        elif interface == 'wl_shm_pool' and name == 'create_buffer':
            self.objects[args['id']][1].update(args, fd=os.dup(data['fd']))
        elif interface == 'ext_idle_notifier_v1' and name.startswith('get_'):
            assert (name, args['timeout']) in [('get_input_idle_notification', 123), ('get_idle_notification', 456)]
            self.idles += 1
            self.send(args['id'], 'idled'); self.send(args['id'], 'resumed')
        elif interface == 'zwlr_output_power_manager_v1' and name == 'get_output_power':
            self.send(args['id'], 'mode', 1)
        elif interface == 'zwlr_output_power_v1' and name == 'set_mode':
            self.powers += 1; self.send(obj, 'mode', args['mode'])
        elif interface == 'ext_session_lock_manager_v1' and name == 'lock':
            self.locks += 1
            self.objects[args['id']][1].update(outputs=set(), mapped=set(), acknowledged=False)
            if self.locks == 2: self.send(args['id'], 'finished')
        elif interface == 'ext_session_lock_v1':
            if name == 'get_lock_surface':
                output = self.objects[args['output']][1]['global']
                assert output not in data['outputs'], 'duplicate lock surface'
                data['outputs'].add(output)
                surface = self.objects[args['surface']][1]
                assert not surface.get('committed') and not surface.get('buffer'), 'role created after surface commit'
                surface.update(lock=obj, output=output, role=args['id'])
                self.objects[args['id']][1].update(surface=args['surface'], serial=100+output)
                self.send(args['id'], 'configure', 100+output, *self.sizes[output])
            elif name == 'unlock_and_destroy':
                assert data['acknowledged'], 'unlock before locked acknowledgement'
                self.unlocks += 1
            elif name == 'destroy':
                assert not data['acknowledged'], 'destroy after locked acknowledgement'
        elif interface == 'ext_session_lock_surface_v1' and name == 'ack_configure':
            assert args['serial'] == data['serial']; self.acked.add(obj)
        elif interface == 'wl_seat' and name == 'get_pointer': self.pointer = args['id']
        elif interface == 'wl_seat' and name == 'get_keyboard':
            self.keyboard = args['id']
            keymap = b'''xkb_keymap {
              xkb_keycodes { include "evdev+aliases(qwerty)" };
              xkb_types { include "complete" };
              xkb_compatibility { include "complete" };
              xkb_symbols { include "pc+us+inet(evdev)" };
            };\0'''
            fd = os.memfd_create('fixture-keymap')
            try:
                os.write(fd, keymap)
                self.send(self.keyboard, 'keymap', 1, fd, len(keymap))
                self.send(self.keyboard, 'repeat_info', 0, 0)
            finally:
                os.close(fd)
        elif interface == 'wl_surface':
            if name == 'attach': data['buffer'] = args['buffer']
            if name == 'frame': data['callback'] = args['callback']
            if name == 'commit':
                data['committed'] = True
                if 'lock' in data:
                    assert data['role'] in self.acked and data.get('buffer'), 'empty/unconfigured lock commit'
                    buffer = self.objects[data['buffer']][1]
                    w, h = self.sizes[data['output']]
                    assert (buffer['width'], buffer['height']) == (w, h), 'configure size mismatch'
                    pixels = os.pread(buffer['fd'], buffer['stride'] * h, buffer['offset'])
                    self.captures[self.output_names[data['output']]] = (w, h, buffer['stride'], pixels)
                    lock = self.objects.get(data['lock'])
                    if lock:
                        lock[1]['mapped'].add(data['output'])
                        required = {7, 8} if self.locks == 1 else {7, 9}
                        if not lock[1]['acknowledged'] and required <= lock[1]['mapped']:
                            lock[1]['acknowledged'] = True
                            self.send(data['lock'], 'locked')
                            if self.locks == 1:
                                self.locked.set(); self.hotplug_at = time.monotonic()+.1; self.click_at = time.monotonic()+.2
                    self.send(data['buffer'], 'release')
                if data.get('callback'):
                    callback = data.pop('callback'); self.send(callback, 'done', 10); self.destroy(callback)
        if descriptor.attrib.get('type') == 'destructor':
            if interface in ('wl_shm_pool', 'wl_buffer'): os.close(data['fd'])
            self.destroy(obj)

    def run(self):
        try:
            self.socket, _ = self.listener.accept(); self.socket.settimeout(.02)
            while True:
                now = time.monotonic()
                if self.hotplug_at and now >= self.hotplug_at:
                    self.hotplug_at = None
                    if self.remove_managers:
                        for global_name in (4, 5, 6):
                            self.send(self.registry, 'global_remove', global_name)
                    self.send(self.registry, 'global_remove', 8)
                    self.globals[9] = ('wl_output', 4)
                    self.send(self.registry, 'global', 9, 'wl_output', 4)
                if self.click_at and now >= self.click_at:
                    self.click_at = None
                    surface = next(i for i, (name, d) in self.objects.items() if name == 'wl_surface' and d.get('output') == 7)
                    self.send(self.pointer, 'enter', 55, surface, 30*256, 42*256)
                    self.send(self.pointer, 'button', 56, 10, 272, 1)
                    self.send(self.pointer, 'button', 57, 11, 272, 0)
                    self.send(self.pointer, 'frame')
                    keyboard_surface = next(i for i, (name, d) in self.objects.items() if name == 'wl_surface' and d.get('output') == 9)
                    self.send(self.keyboard, 'enter', 58, keyboard_surface, b'')
                    self.send(self.keyboard, 'key', 59, 12, 30, 1)
                    self.send(self.keyboard, 'key', 60, 13, 30, 0)
                try: chunk, controls, _, _ = self.socket.recvmsg(65536, socket.CMSG_SPACE(64*4))
                except socket.timeout: continue
                except ConnectionResetError: break # client may exit with unread input events
                if not chunk: break
                for level, kind, content in controls:
                    if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
                        fds = array.array('i'); fds.frombytes(content); self.fds.extend(fds)
                self.buffer += chunk
                while len(self.buffer) >= 8:
                    obj, header = struct.unpack_from('<II', self.buffer)
                    size, opcode = header >> 16, header & 0xffff
                    if len(self.buffer) < size: break
                    message, self.buffer = self.buffer[8:size], self.buffer[size:]
                    self.request(obj, opcode, message)
        except BaseException as error:
            self.failure = error
        finally:
            if hasattr(self, 'socket'): self.socket.close()
            self.listener.close()
            for _, data in self.objects.values():
                if 'fd' in data: os.close(data['fd'])
            for fd in self.fds: os.close(fd)

def verify(loss=False, remove_managers=False):
    with tempfile.TemporaryDirectory(prefix='ourokit-session-') as temp:
        root = Path(temp)
        peer = Peer(root, remove_managers)
        thread = threading.Thread(target=peer.run, daemon=True); thread.start()
        app = root / 'app.lua'
        on_loss = 'o.sleep(60000)' if loss == 'killed' else "o.stdout.write('PASS session client loss\\n'); o.exit(0)"
        removed = '''
    lock:unlock(); assert(lock:next() == 'unlocked'); visible:set(false)
    for _, create in ipairs({o.session.lock,
        function() return o.session.idle(123, true) end,
        function() return o.session.power('TEST-1') end}) do
      local resource <close> = create()
      assert(resource:next() == 'failed', 'removed manager must reject new resources')
    end
    o.stdout.write('PASS session client manager removal\\n'); o.exit(0)
'''
        app.write_text(SOURCE.replace('LOSS', removed if remove_managers else on_loss if loss else ''))
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root), WAYLAND_DISPLAY=peer.path)
        env.pop('WAYLAND_SOCKET', None)
        process = subprocess.Popen([str(BINARY), 'run', str(app), '--software', '--dev'], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            if not peer.locked.wait(8):
                process.terminate()
                stdout, stderr = process.communicate(timeout=5)
                raise AssertionError(('lock was not acknowledged', peer.failure, peer.idles, peer.powers, stdout, stderr))
            # Reload while locked must leave the original VM and surfaces alive.
            endpoint = next((root / 'ourokit/dev').glob('*'))
            reload = subprocess.run([str(BINARY), 'dev', 'reload', str(endpoint)], env=env,
                                    capture_output=True, text=True, timeout=5)
            assert 'SessionLockActive' in reload.stdout + reload.stderr, (reload.stdout, reload.stderr)
            if loss == 'killed':
                time.sleep(.4) # allow the same hotplug/input path before abrupt death
                process.kill()
            stdout, stderr = process.communicate(timeout=10)
            if loss == 'killed':
                assert process.returncode == -9, (stdout, stderr)
            else:
                assert process.returncode == 0 and 'PASS session client' in stdout, (stdout, stderr)
        finally:
            if process.poll() is None: process.terminate(); process.wait(timeout=5)
            thread.join(timeout=3)
        assert peer.failure is None, peer.failure
        assert peer.idles == 2 and peer.powers == 2
        assert peer.unlocks == (0 if loss else 1 if remove_managers else 2), peer.unlocks
        assert peer.locks == (1 if loss or remove_managers else 3), peer.locks
        assert set(peer.captures) == {'TEST-1', 'TEST-2', 'TEST-3'}, peer.captures.keys()
        capture = os.environ.get('OUROKIT_TEST_CAPTURE')
        if capture and not loss and not remove_managers:
            from PIL import Image
            directory = Path(capture); directory.mkdir(parents=True, exist_ok=True)
            for name, (w, h, stride, pixels) in peer.captures.items():
                Image.frombytes('RGBA', (w, h), pixels, 'raw', 'BGRA', stride).save(directory / f'lock-{name}.png')
        print('PASS session:', 'manager removal preserves existing lock/hotplug and rejects new resources' if remove_managers else f'{loss}: exit never unlocks' if loss else 'idle v1/v2, power, ack/configure, input, hotplug, denial, relock, stale unlock, reload rejection and rendering')

def verify_unavailable():
    with tempfile.TemporaryDirectory(prefix='ourokit-session-unavailable-') as temp:
        root = Path(temp)
        peer = Peer(root)
        del peer.globals[5], peer.globals[6]
        peer.globals[4] = ('ext_idle_notifier_v1', 1)
        thread = threading.Thread(target=peer.run, daemon=True); thread.start()
        app = root / 'app.lua'
        app.write_text('''
local o = require('ouro')
return o.app {id='dev.ourokit.session-unavailable', run=function()
  o.spawn(function()
    local idle <close> = o.session.idle(123, true)
    assert(idle:next() == 'failed'); assert(idle:next() == 'closed')
    local power <close> = o.session.power('TEST-1')
    assert(power:next() == 'failed')
    local lock <close> = o.session.lock()
    assert(lock:next() == 'failed')
    assert(not pcall(function() lock:unlock() end))
    o.stdout.write('PASS unavailable protocols and old idle version\\n')
    o.exit(0)
  end)
  return {windows=function() return {} end}
end}
''')
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root), WAYLAND_DISPLAY=peer.path)
        env.pop('WAYLAND_SOCKET', None)
        result = subprocess.run([str(BINARY), 'run', str(app), '--software', '--dev'], env=env,
                                capture_output=True, text=True, timeout=10)
        thread.join(timeout=3)
        assert result.returncode == 0 and 'PASS unavailable' in result.stdout, (result.stdout, result.stderr)
        assert peer.failure is None, peer.failure
        assert peer.locks == peer.idles == peer.powers == 0, 'must not downgrade or use a different protocol'
        print(result.stdout.strip())

if __name__ == '__main__':
    verify()
    verify(loss=True)
    verify(loss='killed')
    verify(remove_managers=True)
    verify_unavailable()
