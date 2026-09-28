#!/usr/bin/env python3
"""Real lock-surface keyboard -> native credential buffer -> disposable PAM.

No production dev-input bypass: only the isolated Wayland peer supplies keys.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time

from session_native import BINARY, ROOT, Peer

SOURCE = r'''
local o = require('ouro')
return o.app {id='dev.ourokit.secure-entry', theme={color_scheme='dark'}, run=function()
  local visible, prompt = o.signal(false), o.signal(nil)
  local auth, submissions, cancellations = nil, 0, 0
  o.spawn(function()
    local lock = o.session.lock()
    visible:set(true)
    assert(lock:next() == 'locked')
    auth = assert(o.auth.start('fixture', 'fixture-user'))
    assert(auth.respond == nil, 'there must be no Lua credential submission API')
    while true do
      local event, reason = auth:next()
      if not event then
        assert(CANCEL_MODE and reason == 'ConversationClosed')
        o.sleep(100)
        assert(cancellations == 1 and submissions == 0)
        prompt:set(nil)
        o.stdout.write('PASS secure Escape: nonsecret callback, conversation canceled, no unlock\n')
        o.exit(0)
      end
      if event.type == 'prompt' then prompt:set(event)
      elseif event.type == 'result' then
        assert(event.success and event.reason == 'success', event.reason)
        o.sleep(100) -- let the nonsecret submission callback run independently
        assert(submissions == 2)
        prompt:set(nil)
        lock:unlock(); assert(lock:next() == 'unlocked')
        visible:set(false)
        o.stdout.write('PASS secure lock entry: two prompts, two outputs, native submission\n')
        o.exit(0)
      end
    end
  end)
  return {windows=function()
    if not visible() then return {} end
    return {o.lock_surface{id='secure', outputs='all', background='#182233', content=function(output)
      local p = prompt()
      local children = {
        o.text{key='title', text='Native secure entry — '..output},
        o.text{key='prompt', text=p and p.text or 'Awaiting secure lock'},
      }
      if p then
        children[#children+1] = o.auth_input{key='credential', conversation=auth, prompt_id=p.id, width=240,
          on_submit=function(...) assert(select('#', ...) == 0); submissions=submissions+1 end,
          on_cancel=function(...) assert(select('#', ...) == 0); cancellations=cancellations+1 end,
          on_error=function(code) error(code) end}
      end
      children[#children+1] = o.text{key='note', text='Disposable PAM fixture; always masked, including echo-on'}
      return o.column{key='root', children=children}
    end}}
  end}
end}
'''


class SecurePeer(Peer):
    def __init__(self, root):
        super().__init__(root)
        self.send_lock = threading.RLock()

    def send(self, *args):
        with self.send_lock:
            super().send(*args)

    def request(self, *args):
        super().request(*args)
        self.hotplug_at = self.click_at = None

    def keys(self, output, keys, control=False):
        surface = next(i for i, (name, d) in list(self.objects.items())
                       if name == 'wl_surface' and d.get('output') == output)
        with self.send_lock:
            self.send(self.keyboard, 'enter', 500, surface, b'')
            self.send(self.keyboard, 'modifiers', 501, 4 if control else 0, 0, 0, 0)
            for code in keys:
                self.send(self.keyboard, 'key', 502, 20, code, 1)
                self.send(self.keyboard, 'key', 503, 21, code, 0)
            self.send(self.keyboard, 'modifiers', 504, 0, 0, 0, 0)

    def type(self, output, text):
        codes = {'-': 12}
        for row, start in [('qwertyuiop', 16), ('asdfghjkl', 30), ('zxcvbnm', 44)]:
            codes.update({c: start+i for i, c in enumerate(row)})
        self.keys(output, [codes[c] for c in text])


def dev(env, path, operation, params=None):
    args = [str(BINARY), 'dev', operation, str(path)]
    if params is not None:
        args.append(json.dumps(params))
    return subprocess.run(args, env=env, capture_output=True, text=True, timeout=5)


def wait_prompt(env, endpoint, text):
    end = time.monotonic() + 5
    while time.monotonic() < end:
        result = dev(env, endpoint, 'inspect')
        if result.returncode == 0:
            windows = json.loads(result.stdout)['windows']
            windows = [json.loads(dev(env, endpoint, 'inspect', {'window': w['window']}).stdout)['windows'][0] for w in windows]
            if len(windows) == 2 and all(text in json.dumps(w) and 'Secure authentication' in json.dumps(w) for w in windows):
                return windows
        time.sleep(.02)
    raise AssertionError(('secure prompt did not render', result.stdout, result.stderr))


def verify(cancel=False):
    with tempfile.TemporaryDirectory(prefix='ourokit-secure-entry-') as temp:
        root = Path(temp)
        subprocess.run([os.environ.get('OUROKIT_TEST_ZIG', 'zig'), 'cc', '-shared', '-fPIC',
                        str(ROOT / 'tests/pam_fixture.c'), '-o', str(root / 'libpam.so.0')], check=True)
        peer = SecurePeer(root)
        thread = threading.Thread(target=peer.run, daemon=True)
        thread.start()
        app = root / 'app.lua'
        app.write_text(SOURCE.replace('CANCEL_MODE', 'true' if cancel else 'false'))
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root), WAYLAND_DISPLAY=peer.path, LD_LIBRARY_PATH=str(root))
        env.pop('WAYLAND_SOCKET', None)
        process = subprocess.Popen([str(BINARY), 'run', str(app), '--software', '--dev'], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert peer.locked.wait(5), ('lock did not render', peer.failure)
            endpoint = next((root / 'ourokit/dev').glob('*'))
            windows = wait_prompt(env, endpoint, 'Identity')
            for w in windows:
                params = {'window': w['window'], 'token': w['token']}
                capture = dev(env, endpoint, 'capture', params)
                assert 'SecureInputProtected' in capture.stdout + capture.stderr
                injection = dev(env, endpoint, 'input', dict(params, action='text', text='injected'))
                assert 'SecureInputProtected' in injection.stdout + injection.stderr, (injection.stdout, injection.stderr)
            if cancel:
                peer.type(7, 'discarded')
                peer.keys(7, [1])
                stdout, stderr = process.communicate(timeout=5)
                assert process.returncode == 0 and 'PASS secure Escape' in stdout, (stdout, stderr)
                assert peer.unlocks == 0
                print(stdout.strip())
                return
            # Shared native prompt across output-local trees; no Lua signal holds text.
            peer.type(7, 'ali')
            peer.type(8, 'ce')
            peer.keys(8, [46, 45, 47], control=True) # copy/cut/paste are ignored
            peer.keys(8, [28])
            windows = wait_prompt(env, endpoint, 'Challenge')
            time.sleep(.05)
            before = dict(peer.captures)
            peer.type(7, 'test-only-responsx')
            peer.keys(7, [14])
            peer.type(7, 'e')
            time.sleep(.05)
            for w in windows:
                inspected = dev(env, endpoint, 'inspect', {'window': w['window']})
                assert 'test-only' not in inspected.stdout and 'alice' not in inspected.stdout
                node = next(n for n in json.loads(inspected.stdout)['windows'][0]['nodes'] if n['path'] == 'root/credential')
                assert node['label'] == 'Secure authentication' and node.get('value') is None and node.get('selection') is None, node
            assert before == peer.captures, 'secret editing changed the constant-mask pixels'
            capture = os.environ.get('OUROKIT_TEST_CAPTURE')
            if capture:
                from PIL import Image
                directory = Path(capture); directory.mkdir(parents=True, exist_ok=True)
                for name, (w, h, stride, pixels) in peer.captures.items():
                    Image.frombytes('RGBA', (w, h), pixels, 'raw', 'BGRA', stride).save(directory / f'secure-{name}.png')
            peer.keys(7, [28])
            stdout, stderr = process.communicate(timeout=5)
            assert process.returncode == 0 and 'PASS secure lock entry' in stdout, (stdout, stderr)
            assert peer.unlocks == 1, peer.unlocks
            print(stdout.strip())
            print('PASS secure inspection: fixed metadata/mask, protected capture and synthetic input, clipboard shortcuts ignored')
        finally:
            if process.poll() is None:
                process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            if process.returncode != 0: print(stdout, stderr)
            thread.join(timeout=3)
        assert peer.failure is None, peer.failure


if __name__ == '__main__':
    verify()
    verify(cancel=True)
