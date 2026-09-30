#!/usr/bin/env python3
"""Native retained scroll state, callback settlement, pixels and atomic reload.

Run: python3 tests/scroll_composition.py zig-out/bin/ouroctl
Uses the verification runner's private headless Sway and D-Bus.
"""
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from application_services import BINARY, call, development_path
from development_runtime import atomic_write, cli, node, png_pixel
import verify_development as verify

SOURCE = '''local o=require('ouro')
local revision=1
local reject=false
local invalid=nil
local function window(id)
 local request, report = o.signal(nil), o.signal('Measuring')
 local token, calls = 0, 0
 return o.window {id=id,title=id,width=380,height=420,content=function()
  if reject and id=='peer' then error('later window rejected') end
  local r=request()
  return o.column {key='root',gap=12,
   o.button {key='jump',label='Jump',on_press=function()
    token=token+1; request:set({offset=91,token=token}) end},
   o.box {key='frame',height=80,width='fill',
    o.scroll {key='view',scrollbar=true,scroll_to=invalid or r,
     on_scroll=function(m) calls=calls+1
      report:set(string.format('V%d offset %.0f calls %d',revision,m.offset,calls)) end,
     o.column {key='rows',gap=0,
      o.box {key='red',height=160,width='fill',background='#d02010'},
      o.box {key='blue',height=160,width='fill',background='#1030c0'}}}},
   o.text {key='report',text=report()},
   o.virtual_list {key='virtual',height=160,scrollbar=true,
    scroll_to=r and {offset=200003,token=r.token} or nil,
    item_count=10000,item_height=40,item_key=function(i) return 'row-'..i end,
    render_item=function(i) return o.text {key='label',text='Row '..i} end}}
 end}
end
return o.app {id='dev.ourokit.scroll-test',run=function()
 return {windows={window('main'),window('peer')}} end}
'''


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-scroll-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        app = root / 'app.lua'
        atomic_write(app, SOURCE)
        with (root / 'stderr').open('w') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=log)
        try:
            endpoint = development_path(root, process)

            def invoke(name, args=None):
                reply = call(endpoint, name, args)
                assert not reply.get('isError') and 'rpcError' not in reply, (name, reply)
                return reply['structuredContent']

            def snapshot(window='main'):
                return invoke('runtime.inspect', {'window': window})['windows'][0]

            deadline = time.monotonic() + 8
            while True:
                try:
                    first, peer = snapshot(), snapshot('peer')
                    if node(first, 'root/report')['label'] == 'V1 offset 0 calls 1':
                        break
                except (ConnectionRefusedError, StopIteration):
                    pass
                assert process.poll() is None and time.monotonic() < deadline
                time.sleep(.03)

            def input(**args):
                tree = snapshot()
                return invoke('runtime.input', dict(window='main', token=tree['token'], **args))

            view = 'root/frame/view'
            input(action='click', target='root/jump')
            moved = snapshot()
            assert node(moved, view)['scroll_metrics'] == dict(axis='vertical', offset=91,
                                                              viewport=80, content=320, max_offset=240), node(moved, view)
            assert node(moved, 'root/report')['label'] == 'V1 offset 91 calls 2'
            assert node(moved, 'root/virtual')['scroll_offset'] == 200003
            assert len(moved['nodes']) < 70, 'deep request eagerly mounted rows'
            input(action='scroll', target=view, delta=23)
            scrolled = snapshot()
            assert node(scrolled, 'root/report')['label'] == 'V1 offset 114 calls 3'
            assert node(scrolled, view)['id'] == node(first, view)['id']
            assert node(scrolled, view)['bounds'] == node(first, view)['bounds']
            assert snapshot('peer') == peer
            # Independent content pixels on either side of the red/blue edge.
            output = root / 'scroll.png'
            cli(env, 'capture', endpoint, dict(window='main', token=scrolled['token']), output=output)
            bounds = node(scrolled, view)['bounds']
            x, y = int(bounds['x']) + 10, int(bounds['y'])
            assert png_pixel(output, x, y + 20)[2] == bytes((208, 32, 16, 255))
            assert png_pixel(output, x, y + 60)[2] == bytes((16, 48, 192, 255))
            assert snapshot() == scrolled, 'unchanged observation queued work'
            print('PASS native requests, callback feedback settlement, copied metrics, bounded virtual rows and independent pixels')

            for invalid in ('{offset=-1,token=1}', '{offset=0,token=0}', '{offset=0,token=1,extra=true}'):
                atomic_write(app, SOURCE.replace('local invalid=nil', 'local invalid=' + invalid))
                cli(env, 'reload', endpoint, succeeds=False)
                assert snapshot() == scrolled and snapshot('peer') == peer
            atomic_write(app, SOURCE.replace('local revision=1', 'local revision=2').replace('local reject=false', 'local reject=true'))
            cli(env, 'reload', endpoint, succeeds=False)
            assert snapshot() == scrolled and snapshot('peer') == peer
            atomic_write(app, SOURCE.replace('local revision=1', 'local revision=2'))
            cli(env, 'reload', endpoint)
            accepted = snapshot()
            assert node(accepted, view)['scroll_offset'] == 114
            assert node(accepted, view)['id'] == node(scrolled, view)['id']
            assert node(accepted, 'root/report')['label'] == 'V2 offset 114 calls 1'
            assert node(snapshot('peer'), 'root/report')['label'] == 'V2 offset 0 calls 1'
            stale = call(endpoint, 'runtime.capture', dict(window='main', token=scrolled['token']))
            assert stale.get('isError') and stale['structuredContent']['error']['code'] == 'StaleDevelopmentTarget'
            input(action='click', target='root/jump')
            assert node(snapshot(), 'root/report')['label'] == 'V2 offset 91 calls 2'
            print('PASS invalid requests, later-window rollback, retained offsets and fresh reload subscriptions')
        finally:
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            errors = (root / 'stderr').read_text()
            assert process.returncode in (0, 128 + signal.SIGTERM), (process.returncode, errors)
            assert 'panic' not in errors and 'leaked' not in errors, errors


if __name__ == '__main__':
    if len(sys.argv) == 1 and os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY'):
        session()
    else:
        verify.TESTS = (Path(__file__).name,)
        verify.verify(Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else BINARY)
