#!/usr/bin/env python3
"""Native command-mode editing, retained identity and caret-shape regression."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

from application_services import BINARY, development_path
from development_runtime import cli, inspect, node


SOURCE = r"""
local o = require('ouro')
local entry, shape = o.signal(false), o.signal('block')
local value = o.signal('Wi á\n\nlast')
return o.app {id='dev.ourokit.editor-commands', run=function()
  return {windows={o.window {id='main',title='Native editing',width=560,height=240,content=function()
    return o.column {key='root',gap=12,padding=16,
      o.text {key='title',text='Native editor · '..shape()..' caret'},
      o.box {key='keys',on_key={keys={'O','Shift+O','Escape','F1','F2','F3'},
        states={'pressed'},propagate=true,handler=function(e)
          if e.key == 'O' then entry:set(true)
          elseif e.key == 'Escape' then entry:set(false)
          elseif e.key == 'F1' then shape:set('beam')
          elseif e.key == 'F2' then shape:set('block')
          elseif e.key == 'F3' then shape:set('underline') end
        end},
        o.text_input {key='editor',multiline=true,width=500,height=150,
          default_text='Wi á\n\nlast',text_entry=entry(),caret_shape=shape(),
          font_size=28,key_bindings={
            ['O']='insert_line_below',['Shift+O']='insert_line_above',
            ['Escape']='collapse_selection',
            ['Home']='move_logical_line_start',['End']='move_logical_line_end',
          }},
      },
    }
  end}}}
end}
"""


def session(controlled=False):
    with tempfile.TemporaryDirectory(prefix='ouro-editor-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        app = root / 'app.lua'
        source = SOURCE.replace("default_text='Wi á\\n\\nlast'",
                                'text=value(),on_change=function(v) value:set(v) end') if controlled else SOURCE
        app.write_text(source)
        with (root / 'stderr').open('w') as log:
            process = subprocess.Popen([str(BINARY), 'run', str(app), '--dev', '--software'],
                                       env=env, stdout=subprocess.DEVNULL, stderr=log)
        keyboard = None
        try:
            endpoint = development_path(root, process, windows=('main',))
            # Keep a real seat keyboard present so compositor focus and caret
            # visibility are exercised, not only development-injected keys.
            keyboard = subprocess.Popen(['wtype', '-s', '100', '-k', 'F12', '-s', '30000'], env=env)
            time.sleep(.2)
            path = 'root/keys/editor'

            def snapshot():
                return inspect(env, endpoint, 'main')

            def editor():
                return node(snapshot(), path)

            def input_(**args):
                # A compositor caret-blink frame can invalidate an inspection
                # between CLI processes. Retry only this explicit pre-input
                # rejection, never an accepted or ambiguously completed edit.
                for _ in range(3):
                    arguments = dict(window='main', token=snapshot()['token'], **args)
                    result = subprocess.run([str(BINARY), 'dev', 'input', str(endpoint), json.dumps(arguments)],
                                            env=env, capture_output=True, text=True, timeout=12)
                    reply = json.loads(result.stdout)
                    if reply.get('error', {}).get('code') == 'StaleDevelopmentTarget':
                        continue
                    assert result.returncode == 0, (reply, result.stderr)
                    return reply
                raise AssertionError('input remained stale across three fresh inspections')

            def key(value, **modifiers):
                input_(action='key', key=value, **modifiers)

            def selection(anchor, extent):
                actual = editor()['selection']
                assert (actual['anchor'], actual['extent']) == (anchor, extent), actual

            def text(expected):
                assert editor()['value'] == expected, editor()

            def capture(name):
                directory = os.environ.get('OUROKIT_EDITOR_CAPTURE')
                if directory:
                    output = Path(directory)
                    output.mkdir(parents=True, exist_ok=True)
                    cli(env, 'capture', endpoint, dict(window='main', token=snapshot()['token']),
                        output=output / f'{name}.png')

            deadline = time.monotonic() + 8
            while not any(n['path'] == path for n in snapshot()['nodes']):
                assert time.monotonic() < deadline, 'editor did not mount'
                time.sleep(.01)
            input_(action='click', target=path)
            identity = editor()['id']
            key('home', control=True)
            key('arrow_right', shift=True)
            key('arrow_right', shift=True)
            selection(0, 2)
            key('escape')
            selection(2, 2)  # active extent, not sorted start or another grapheme
            key('arrow_left', shift=True)
            key('arrow_left', shift=True)
            selection(2, 0)
            key('escape')
            selection(0, 0)
            original = 'Wi á\n\nlast'
            text(original)
            key('z', control=True)  # collapse/navigation created no undo entry
            text(original)
            key('x')  # suppressed direct typing
            text(original)
            key('end')
            selection(6, 6)
            key('o')  # native edit and nonconsuming Lua mode listener
            text('Wi á\n\n\nlast')
            selection(7, 7)
            assert editor()['text_entry'] is True, editor()
            input_(action='text', text='new')
            text('Wi á\nnew\n\nlast')
            key('escape')
            assert editor()['text_entry'] is False, editor()
            key('z', control=True)
            text('Wi á\n\n\nlast')
            key('z', control=True)
            text(original)
            selection(6, 6)
            key('o', shift=True)
            text('\nWi á\n\nlast')
            selection(0, 0)
            key('escape')
            key('z', control=True)
            text(original)
            key('z', control=True, shift=True)
            text('\nWi á\n\nlast')
            selection(0, 0)
            capture('block-empty-line')
            key('z', control=True)
            key('home', control=True)
            for shape, command in [('beam', 'f1'), ('block', 'f2'), ('underline', 'f3')]:
                key(command)
                selection(0, 0)
                assert editor()['id'] == identity, 'shape/mode switch remounted editor'
                text(original)
                capture(shape)
            key('f2')
            key('arrow_right')
            capture('block-narrow')
            key('end')
            capture('block-eol')
            print(f'PASS {"controlled echo" if controlled else "uncontrolled"}: native line insertion, collapse at both extents, entry policy, undo/redo, retained caret shapes')
        finally:
            if keyboard is not None:
                keyboard.terminate()
                keyboard.wait(timeout=5)
            if process.poll() is None:
                process.send_signal(signal.SIGTERM)
            process.wait(timeout=10)
            errors = (root / 'stderr').read_text()
            assert process.returncode in (0, 128 + signal.SIGTERM), (process.returncode, errors)
            assert 'panic' not in errors and 'leaked' not in errors, errors


if __name__ == '__main__':
    session()
    session(controlled=True)
