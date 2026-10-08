#!/usr/bin/env python3
"""Native menu/toast motion, input and timers. Optional --record-dir uses wf-recorder."""
import argparse
import os
from pathlib import Path
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time

from application_services import BINARY, ROOT, call, development_path
from desktop_native import protocol_xml, sway, terminate, wait_for
from development_runtime import png_pixel
import verify_development as verify


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-menu-toast-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root), WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        env['SWAYSOCK'] = str(next(Path(env['WAYLAND_DISPLAY']).parent.glob('sway-ipc.*.sock')))
        processes, recorder = [], None
        log = (root / 'app.log').open('w')
        try:
            protocol = protocol_xml('wlr-virtual-pointer-unstable-v1.xml', BINARY)
            subprocess.run(['wayland-scanner','client-header',str(protocol),str(root / 'virtual-pointer.h')], check=True)
            subprocess.run(['wayland-scanner','private-code',str(protocol),str(root / 'virtual-pointer.c')], check=True)
            flags = shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','wayland-client'], text=True))
            subprocess.run(['cc','-I',str(root),str(ROOT / 'tests/desktop_pointer.c'),str(root / 'virtual-pointer.c'),
                            '-o',str(root / 'pointer'),*flags], check=True)
            pointer = subprocess.Popen([str(root / 'pointer')], env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            processes.append(pointer)
            assert select.select([pointer.stdout],[],[],5)[0] and pointer.stdout.readline() == b'ready\n'
            keyboard = subprocess.Popen(['wtype','-s','90000'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            processes.append(keyboard)
            time.sleep(.15)
            app = subprocess.Popen([str(BINARY),'run',str(ROOT / 'examples/menus-and-toasts.lua'),'--dev','--software'],
                                   env=env, stdout=subprocess.DEVNULL, stderr=log)
            processes.append(app)
            endpoint = development_path(root, app, windows=('main',))
            wait_for(lambda: 'dev.ourokit.menus-and-toasts' in sway(env,'-t','get_tree','-r'), 'window not mapped')
            sway(env,'[app_id="dev.ourokit.menus-and-toasts"]','move','position','100','100')
            sway(env,'[app_id="dev.ourokit.menus-and-toasts"]','focus')

            def invoke(method, args=None):
                reply = call(endpoint, method, args)
                assert not reply.get('isError') and 'rpcError' not in reply, (method, reply)
                return reply['structuredContent']
            def tree(window='main'): return invoke('runtime.inspect', {'window':window})['windows'][0]
            def node(suffix, window='main'): return next(n for n in tree(window)['nodes'] if n['path'].endswith(suffix))
            def popups(): return [w['window'] for w in invoke('runtime.inspect')['windows'] if w['window'] != 'main']
            def move(x,y): sway(env,'seat','seat0','cursor','set',str(x),str(y))
            def point(suffix):
                b=node(suffix)['bounds']; move(100+int(b['x']+b['width']/2),100+int(b['y']+b['height']/2))
            def click(suffix):
                point(suffix)
                sway(env,'seat','seat0','cursor','press','button1')
                sway(env,'seat','seat0','cursor','release','button1')
            def key(name): subprocess.run(['wtype','-k',name], env=env, check=True)
            def open_menu(suffix):
                click(suffix)
                return wait_for(lambda: popups(), 'menu did not open')[0]
            def capture(name, window='main'):
                for _ in range(30):
                    reply=call(endpoint,'runtime.capture',{'window':window,'token':tree(window)['token']})
                    if not reply.get('isError'): break
                    assert reply['structuredContent']['error']['code'] == 'StaleDevelopmentTarget', reply
                else: raise AssertionError('could not capture a current animation frame')
                image=reply['structuredContent']
                target=root / (name+'.png')
                target.write_bytes(Path(image['path']).read_bytes())
                if output := os.environ.get('OUROKIT_MENU_TOAST_CAPTURE'):
                    destination=Path(output); destination.mkdir(parents=True,exist_ok=True)
                    (destination/target.name).write_bytes(target.read_bytes())
                return target
            def builds(window='main'): return invoke('runtime.metrics',{'window':window})['windows'][0]['metrics']['builds']['count']
            def idle(window='main'):
                time.sleep(.3); before=builds(window); time.sleep(.15)
                assert builds(window) == before, 'settled animation still requests builds'
            def record(name):
                nonlocal recorder
                if output := os.environ.get('OUROKIT_MENU_TOAST_RECORD'):
                    destination=Path(output); destination.mkdir(parents=True,exist_ok=True)
                    with (root/'recorder.log').open('w') as output_log:
                        recorder=subprocess.Popen(['wf-recorder','-D','-g','100,100 780x480','-r','60','-c','libx264',
                            '-F','format=yuv420p','-x','yuv420p','-p','crf=18','-p','preset=ultrafast',
                            '-f',str(destination/(name+'.mp4'))],env=env,stdout=output_log,stderr=subprocess.STDOUT)
                    time.sleep(.25)
                    assert recorder.poll() is None
            def stop_recording():
                nonlocal recorder
                if recorder:
                    recorder.send_signal(signal.SIGINT); assert recorder.wait(timeout=10) == 0; recorder=None

            # Slow mode exposes intermediate frames to assertions, not just a
            # before/after image. Production defaults are recorded below.
            invoke('Slow')
            def screen(name):
                target=root/(name+'.ppm')
                subprocess.run(['grim','-t','ppm','-g','100,100 780x480',str(target)],env=env,check=True)
                return target.read_bytes()
            before=screen('before')
            popup=open_menu('/menu/trigger')
            time.sleep(.12)
            intermediate=screen('entering')
            assert intermediate != before
            key('Escape')  # Must release the grab even during the entry fade.
            wait_for(lambda:not popups(),'entry dismissal waited for animation')
            assert node('/menu/trigger')['focused']
            popup=open_menu('/menu/trigger'); time.sleep(1.3)
            assert screen('settled') != intermediate
            key('Escape'); wait_for(lambda:not popups(),'menu stayed open')
            popup=open_menu('/select/trigger')
            key('Down'); key('Return')
            wait_for(lambda:not popups(),'select did not commit')
            assert invoke('Stats')['selected'] == 2
            assert node('/select/trigger')['focused']
            print('PASS intermediate/settled menu frames, early Escape and select input/focus')

            move(950,680); invoke('Show'); time.sleep(1.3)
            first=node('/toast-1/reveal')['bounds']; second=node('/toast-2/reveal')['bounds']
            invoke('HideFirst'); time.sleep(.25)
            shrinking=node('/toast-1/reveal')['bounds']; moving=node('/toast-2/reveal')['bounds']
            assert 0 < shrinking['height'] < first['height']
            assert second['y']-first['height'] < moving['y'] < second['y']
            assert not node('/toast-1/reveal/spacing/card/row/dismiss')['enabled']
            invoke('ShowFirst'); time.sleep(1.3)
            assert abs(node('/toast-1/reveal')['bounds']['height']-first['height']) < .1
            invoke('Reduce'); invoke('HideFirst')
            wait_for(lambda:not any(n['path'].endswith('/toast-1/reveal') for n in tree()['nodes']), 'reduced exit retained content')
            assert abs(node('/toast-2/reveal')['bounds']['y']-first['y']) < .1
            popup=open_menu('/menu/trigger'); time.sleep(.08)
            assert png_pixel(capture('menu-reduced',popup),100,100)[2][3] == 255
            idle(popup); key('Return'); wait_for(lambda:not popups(),'menu action did not close')
            assert invoke('Stats')['menu_hits'] == 1
            assert node('/menu/trigger')['focused']
            idle()
            print('PASS retained toast reversal, continuous stack closing, reduced endpoints and idle')

            invoke('Normal'); invoke('Full'); invoke('Hide'); time.sleep(.3)
            invoke('Timed'); move(950,680); time.sleep(.8)
            point('/toast-1/reveal/spacing/live-1600/card/row/message')
            time.sleep(.2); move(950,680); time.sleep(.1)
            point('/toast-1/reveal/spacing/live-1600/card/row/message')
            time.sleep(1.8)
            assert invoke('Stats')['first'], 'hover failed to pause expiration'
            started=time.monotonic(); move(950,680)
            wait_for(lambda:not invoke('Stats')['first'],'toast did not expire after hover',timeout=1.3)
            assert time.monotonic()-started < 1.3, 'hover reset the full timeout instead of preserving remaining time'
            assert invoke('Stats')['last_reason'] == 'timeout'
            time.sleep(.3)
            invoke('Timed')
            # Move keyboard focus into the first toast without activating it.
            for _ in range(15):
                if node('/toast-1/reveal/spacing/live-1600/card/row/dismiss')['focused']: break
                key('Tab')
            assert node('/toast-1/reveal/spacing/live-1600/card/row/dismiss')['focused']
            time.sleep(1.8); assert invoke('Stats')['first'], 'keyboard focus failed to pause expiration'
            key('Return')
            wait_for(lambda:not invoke('Stats')['first'],'manual dismissal did not run')
            assert invoke('Stats')['last_reason'] == 'manual'
            invoke('Timed'); time.sleep(.2); invoke('Remove')
            before=invoke('Stats')['dismissals']; time.sleep(1.8)
            assert invoke('Stats')['dismissals'] == before, 'removed toast timer fired'
            print('PASS remaining-time hover/focus pause, single manual/timeout notifications and scope cancellation')

            invoke('Sticky'); invoke('Mount'); invoke('Hide'); time.sleep(.3)
            for reduced,name in ((False,'full-motion'),(True,'reduced-motion')):
                invoke('Reduce' if reduced else 'Full'); move(950,680); record(name)
                time.sleep(.3); invoke('Show'); time.sleep(.7)
                click('/toast-1/reveal/spacing/live-0/card/row/dismiss'); time.sleep(.7)
                popup=open_menu('/menu/trigger'); time.sleep(.6)
                capture(name+'-menu',popup); key('Escape'); wait_for(lambda:not popups(),'recorded menu stayed open')
                popup=open_menu('/select/trigger'); time.sleep(.6); key('Escape')
                wait_for(lambda:not popups(),'recorded select stayed open')
                invoke('ShowFirst'); time.sleep(.7); capture(name)
                invoke('Hide'); time.sleep(.6); stop_recording(); idle()
            print('PASS normal/reduced demonstrations and final idle')
        finally:
            if recorder:
                recorder.send_signal(signal.SIGINT); recorder.wait(timeout=10)
            for process in reversed(processes): terminate(process)
            log.close()
            errors=(root/'app.log').read_text()
            if sys.exc_info()[0] is not None: print(errors[-7000:],file=sys.stderr)
            assert 'panic' not in errors and 'leaked' not in errors, errors[-7000:]


if __name__ == '__main__':
    if len(sys.argv) == 1 and os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY'):
        session()
    else:
        parser=argparse.ArgumentParser(description=__doc__)
        parser.add_argument('binary',nargs='?',type=Path,default=BINARY)
        parser.add_argument('--capture-dir',type=Path)
        parser.add_argument('--record-dir',type=Path)
        args=parser.parse_args()
        if args.capture_dir: os.environ['OUROKIT_MENU_TOAST_CAPTURE']=str(args.capture_dir.resolve())
        if args.record_dir: os.environ['OUROKIT_MENU_TOAST_RECORD']=str(args.record_dir.resolve())
        verify.TESTS=(Path(__file__).name,)
        verify.verify(args.binary.resolve())
