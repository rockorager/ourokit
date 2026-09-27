#!/usr/bin/env python3
"""Run the Secret Service fixture on a private session bus."""
import os, signal, subprocess, sys, tempfile
import time
from pathlib import Path

SERVER = '''local o=require('ouro'); local d=o.dbus
local bus <close> = assert(d.connect('session'))
local base='/org/freedesktop/secrets'
local api <close> = assert(bus:export{path=base,interface='org.freedesktop.Secret.Service',methods={
 OpenSession={input='sv',output='vo',handler=function() return {d.variant('s',''),base..'/session/test'} end},
 SearchItems={input='a{ss}',output='aoao',handler=function() return {{},{base..'/item/test'}} end},
 Unlock={input='ao',output='aoo',handler=function() return {{},base..'/prompt/test'} end},
}})
local session <close> = assert(bus:export{path=base..'/session/test',interface='org.freedesktop.Secret.Session',methods={
 Close={input='',output='',handler=function() assert(o.files.write(o.xdg.runtime_dir..'/session-closed','yes')); return {} end},
}})
local prompt <close> = assert(bus:export{path=base..'/prompt/test',interface='org.freedesktop.Secret.Prompt',methods={
 Prompt={input='s',output='',handler=function() assert(o.files.write(o.xdg.runtime_dir..'/prompt-active','yes')); return {} end},
 Dismiss={input='',output='',handler=function() assert(o.files.write(o.xdg.runtime_dir..'/prompt-dismissed','yes')); return {} end},
}})
local owner <close> = assert(bus:own_name('org.freedesktop.secrets'))
assert(o.files.write(o.xdg.runtime_dir..'/server-ready','yes'))
while true do o.sleep(1000) end
'''
CLIENT = '''local o=require('ouro')
o.spawn(function()
 while not o.files.read(o.xdg.runtime_dir..'/prompt-active') do o.sleep(5) end
 o.exit(0)
end)
o.secrets.get('org.example.Cancel','key')
error('pending prompt returned before cancellation')
'''

def stop(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL); process.wait()

def wait_file(path, process):
    deadline=time.monotonic()+5
    while not path.exists():
        assert process.poll() is None, 'secret mock exited'
        assert time.monotonic()<deadline, f'timed out waiting for {path.name}'
        time.sleep(.01)

binary = Path(sys.argv[1] if len(sys.argv)>1 else os.environ.get('OUROKIT_TEST_BINARY','zig-out/bin/ouroctl')).resolve()
assert binary.is_file(), binary
with tempfile.TemporaryDirectory(prefix='ourokit-secrets-') as temporary:
    daemon=subprocess.Popen(['dbus-daemon','--session','--nofork','--print-address=1'],stdout=subprocess.PIPE,text=True,start_new_session=True)
    try:
        address=daemon.stdout.readline().strip(); assert address.startswith('unix:')
        env=os.environ.copy(); env['DBUS_SESSION_BUS_ADDRESS']=address; env['XDG_RUNTIME_DIR']=temporary
        run=subprocess.Popen([str(binary),'run',str(Path(__file__).with_name('secrets.lua')),'--headless'],env=env,start_new_session=True)
        try: code=run.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(run.pid,signal.SIGKILL); run.wait(); raise RuntimeError('secret fixture timed out')
        if code: raise subprocess.CalledProcessError(code,run.args)
        root=Path(temporary)
        (root/'server.lua').write_text(SERVER)
        (root/'client.lua').write_text(CLIENT)
        server=subprocess.Popen([str(binary),'run',str(root/'server.lua'),'--headless'],env=env,start_new_session=True)
        try:
            wait_file(root/'server-ready',server)
            client=subprocess.Popen([str(binary),'run',str(root/'client.lua'),'--headless'],env=env,start_new_session=True)
            try: assert client.wait(timeout=10)==0, 'canceled client failed'
            except subprocess.TimeoutExpired:
                raise AssertionError('client did not cancel; fixture markers: '+', '.join(p.name for p in root.iterdir()))
            finally: stop(client)
            wait_file(root/'prompt-dismissed',server)
            wait_file(root/'session-closed',server)
            print('PASS secret task cancellation dismisses prompt and closes session')
        finally: stop(server)
    finally:
        stop(daemon)
