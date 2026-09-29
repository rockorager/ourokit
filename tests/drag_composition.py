#!/usr/bin/env python3
"""Native internal drag threshold, targeting, retention and transactional reload."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from application_services import BINARY, ROOT, call, development_path
from development_runtime import atomic_write, cli, node, png_pixel
from drawing_composition import over
import verify_development as verify

HANDLE = 'root/cards/{}/body/top/handle'
EDITOR = 'root/cards/{}/body/editor'
ZONE = 'root/cards/{}/body/dropzone'
COMPATIBLE = 'root/targets/compatible'
WRONG = 'root/targets/wrong-kind'
TABS = 'root/tab-area/documents/control'


def session():
    with tempfile.TemporaryDirectory(prefix='ouro-drag-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        fixture = (ROOT / 'examples/drag-composition.lua').read_text()
        app = root / 'app.lua'
        atomic_write(app, fixture)
        with (root / 'stderr').open('w') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                env=env, stdout=subprocess.DEVNULL, stderr=log)
        try:
            endpoint = development_path(root, process)

            def invoke(name, args=None):
                reply = call(endpoint, name, args)
                assert not reply.get('isError') and 'rpcError' not in reply, (name, reply)
                return reply['structuredContent']

            def snapshot(startup=False):
                reply = call(endpoint, 'runtime.inspect', {'window':'main'})
                if startup and reply.get('structuredContent', {}).get('error', {}).get('code') == 'DevelopmentWindowNotFound':
                    return None  # The listener can become ready before initial configure.
                assert not reply.get('isError') and 'rpcError' not in reply, reply
                return reply['structuredContent']['windows'][0]

            deadline = time.monotonic() + 8
            while True:
                assert process.poll() is None, 'drag fixture exited during startup'
                try:
                    tree = snapshot(startup=True)
                    if tree and any(n['path'] == HANDLE.format('amber') for n in tree['nodes']): break
                except ConnectionRefusedError: pass
                assert time.monotonic() < deadline, 'drag fixture did not settle'
                time.sleep(.03)

            def input_(action, target=None, **args):
                tree = snapshot()              # every drag step needs a fresh token
                if target is not None: args['target'] = target
                return invoke('runtime.input', dict(window='main',token=tree['token'],action=action,**args))

            def state(): return invoke('Inspect')

            def capture(name):
                tree = snapshot()
                result = invoke('runtime.capture', {'window':'main','token':tree['token']})
                image = Path(result['path']).read_bytes()
                (root / (name + '.png')).write_bytes(image)
                destination = os.environ.get('OUROKIT_DRAG_CAPTURE')
                if destination:
                    Path(destination).mkdir(parents=True,exist_ok=True)
                    (Path(destination)/(name+'.png')).write_bytes(image)
                return tree,image

            def drag(source, target):
                input_('pointer_down',source)
                input_('pointer_move',target)
                input_('pointer_up')

            original, original_pixels = capture('original')
            ids = {p:node(original,p)['id'] for p in
                   (HANDLE.format('amber'),EDITOR.format('amber'),EDITOR.format('violet'),
                    ZONE.format('violet'))}

            # A press still focuses and dispatches normal pointer handlers before motion.
            input_('pointer_down',HANDLE.format('amber'))
            assert state()['activations'] == 1
            assert [n['path'] for n in snapshot()['nodes'] if n['focused']] == [HANDLE.format('amber')]
            input_('pointer_move',ZONE.format('violet'))
            dragging, drag_pixels = capture('dragging')
            assert drag_pixels != original_pixels, '75% source preview/target outline was not painted'
            box = node(dragging, ZONE.format('violet'))['bounds']
            # Preview follows the grabbed source with a (12,24) logical offset.
            # This samples its plain background, away from the grip glyphs.
            _, _, actual = png_pixel(root / 'dragging.png', int(box['x'] + 118), int(box['y'] + 57))
            expected = (*over((255, 255, 255), (197, 216, 236), .75 * 255), 255)
            assert all(abs(a - b) <= 1 for a, b in zip(actual, expected)), (actual, expected)
            input_('pointer_up')
            reordered, _ = capture('reordered')
            assert state()['order'] == 'amber,violet,teal'  # amber was already before violet
            assert state()['drops'] == 1 and state()['last'] == 'amber → violet at 94.0, 33.0 (r1)', state()
            for path,identity in ids.items(): assert node(reordered,path)['id'] == identity

            # Put user text in violet, focus its independent handle, then move the card.
            input_('click',EDITOR.format('violet')); input_('key',key='a',control=True)
            input_('text',text='Keep me')
            drag(HANDLE.format('violet'),ZONE.format('amber'))
            moved = snapshot()
            assert state()['order'] == 'violet,amber,teal'
            assert node(moved,EDITOR.format('violet'))['value'] == 'Keep me'
            assert node(moved,EDITOR.format('violet'))['id'] == ids[EDITOR.format('violet')]
            assert [n['path'] for n in moved['nodes'] if n['focused']] == [HANDLE.format('violet')]
            capture('reordered')

            # Nested editor owns its gesture and must not discover the card/handle source.
            before = state().copy(); input_('pointer_down',EDITOR.format('amber'))
            input_('pointer_move',COMPATIBLE); input_('pointer_up'); assert state() == before

            # Native payload strings were copied during build, not aliased to this table.
            invoke('MutateSource'); drag(HANDLE.format('amber'),COMPATIBLE)
            assert state()['drops'] == 3 and state()['last'].startswith('amber → archive at '), state()
            before = state().copy(); drag(HANDLE.format('teal'),WRONG)
            after = state()
            assert {k: after[k] for k in ('order','drops','last')} == {k: before[k] for k in ('order','drops','last')}

            # Escape, declaration change, and source removal all cancel an active drag.
            for action in ('escape','config','remove'):
                input_('pointer_down',HANDLE.format('teal')); input_('pointer_move',COMPATIBLE)
                if action == 'escape': input_('key',key='escape')
                elif action == 'config': invoke('ChangeConfig')
                else: invoke('RemoveHandles')
                input_('pointer_up'); assert state()['drops'] == 3, action
                if action == 'remove': invoke('RestoreHandles')
                if action == 'config': invoke('ChangeConfig')
            capture('cancelled')

            generation = invoke('runtime.diagnostics')['generation']
            input_('pointer_down',HANDLE.format('teal')); input_('pointer_move',COMPATIBLE)
            stable = snapshot()
            for declaration in ("{}", "{kind='',value='x'}", "{kind='item',value=12}",
                                "{kind='item',value=string.rep('x',128)}", "{kind='item',value='x',typo=true}"):
                atomic_write(app,fixture.replace('local invalid = nil','local invalid = ' + declaration))
                cli(env,'reload',endpoint,succeeds=False)
                assert snapshot() == stable
            atomic_write(app,fixture.replace('local reject = false','local reject = true'))
            cli(env,'reload',endpoint,succeeds=False)
            assert snapshot() == stable, 'rejected reload did not preserve active drag'
            input_('pointer_up'); assert state()['drops'] == 4 and '(r1)' in state()['last']

            input_('pointer_down',HANDLE.format('teal')); input_('pointer_move',COMPATIBLE)
            old = snapshot()
            atomic_write(app,fixture.replace('local revision = 1','local revision = 2'))
            cli(env,'reload',endpoint)
            assert invoke('runtime.diagnostics')['generation'] == generation + 1
            input_('pointer_up'); assert state()['drops'] == 0, 'accepted reload retained drag session'
            drag(HANDLE.format('teal'),COMPATIBLE)
            assert state()['drops'] == 10 and '(r2)' in state()['last'], state()
            stale = call(endpoint,'runtime.input',dict(window='main',token=old['token'],action='pointer_up'))
            assert stale.get('isError') and stale['structuredContent']['error']['code'] == 'StaleDevelopmentTarget'
            capture('reloaded')
            review = TABS + '/strip/bar/2'
            draft = TABS + '/strip/bar/1'
            editor = TABS + '/panels/2/editor'
            input_('click', review)
            input_('click', editor); input_('key', key='a', control=True); input_('text', text='Keep tab text')
            tab_before = snapshot()
            identities = {p: node(tab_before, p)['id'] for p in (review, draft, editor)}
            input_('click', draft)
            input_('pointer_down', review)
            focused = [n['id'] for n in snapshot()['nodes'] if n['focused']]
            assert state()['selected'] == 2, 'tab press did not keep normal selection behavior'
            input_('pointer_move', draft); capture('tab-dragging'); input_('pointer_up')
            tab_after, _ = capture('tabs-reordered')
            assert state()['tab_order'] == '2,1' and state()['selected'] == 2
            assert node(tab_after, editor)['value'] == 'Keep tab text'
            assert [n['id'] for n in tab_after['nodes'] if n['focused']] == focused and focused
            for p, identity in identities.items(): assert node(tab_after, p)['id'] == identity
            assert node(tab_after, review)['bounds']['x'] < node(tab_after, draft)['bounds']['x']
            print('PASS preview pixel/local drop, copied payload, stable card/tab reorder/editor/focus, cancellation and transactional reload')
        finally:
            if process.poll() is None: process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            errors = (root/'stderr').read_text()
            if sys.exc_info()[0] is not None: print(errors,file=sys.stderr)
            assert process.returncode in (0,128+signal.SIGTERM),(process.returncode,errors)
            assert 'panic' not in errors and 'leaked' not in errors,errors


if __name__ == '__main__':
    if len(sys.argv)==1 and os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY'): session()
    else:
        parser=argparse.ArgumentParser(description=__doc__)
        parser.add_argument('binary',nargs='?',type=Path,default=BINARY)
        parser.add_argument('--capture-dir',type=Path)
        args=parser.parse_args()
        if args.capture_dir: os.environ['OUROKIT_DRAG_CAPTURE']=str(args.capture_dir.resolve())
        verify.TESTS=(Path(__file__).name,)
        signal.signal(signal.SIGTERM,lambda *_:sys.exit(143))
        verify.verify(args.binary.resolve())
