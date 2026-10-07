#!/usr/bin/env python3
"""Deterministic checks for examples/documents (no compositor needed).

The document and notes charts are headless: services are fakes and timers and
invokes run on the manual scheduler, so every save, cancel, race and close
walk is driven explicitly.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OUROKIT_TEST_BINARY", ROOT / "zig-out/bin/ouroctl"))

source = r'''
local o=require('ouro')
local machine=o.machine
local m=require('model')(o.json)

-- Plain functions.
local note={title='later',text='new\nbody'}
local decoded=m.decode(m.encode(note)); assert(decoded.title=='later' and decoded.text=='new\nbody')
assert(m.decode('{"format":"dev.ourokit.ournote","version":1,"title":"x","text":"y","extra":1}')==nil)
assert(m.decode('{broken')==nil)
assert(m.decode('{"format":"dev.ourokit.ournote","version":1,"title":"x\\ny","text":"z"}')==nil)
assert(m.decode('{"format":"dev.ourokit.ournote","version":1,"title":"x","text":"bad\\rline"}')==nil)
assert(m.check_edit('text','bad\r\nlines') and m.check_edit('title','two\nlines') and not m.check_edit('text','ok\n'))
local uris=m.parse_uri_list('# comment\r\nfile:///one\r\n\r\nfile:///two\n')
assert(#uris==2 and uris[1]=='file:///one' and uris[2]=='file:///two')
assert(m.dirty({revision=2,saved_revision=1}) and not m.dirty({revision=1,saved_revision=1}))

-- Fake services record what the charts asked for.
local chooser, writes, notices, persisted, exits = {}, {}, {}, nil, 0
local write_result = true
local charts=require('charts')(o, m, {
  choose=function(name) chooser[#chooser+1]=name; return chooser.answer, chooser.err end,
  write=function(path, bytes) writes[#writes+1]={path=path, bytes=bytes}; if write_result then return true end return nil, {name='NoSpace', message='disk full'} end,
  notify=function(options) notices[#notices+1]=options.title..': '..options.body end,
  persist=function(split, paths, selected) persisted={split=split, paths=paths, selected=selected} end,
  exit=function() exits=exits+1 end,
})
local clock=machine.manual_scheduler()
local function start() return charts.notes:start { input={split=0.3}, scheduler=clock } end
local function ids(actor) local out={} for i,d in ipairs(actor:children()) do out[i]=d:context().id end return table.concat(out,',') end

-- Editing, validation and dirty state.
local notes=start()
notes:send('NEW')
local d=notes:child('document-1')
assert(notes:context().selected==1 and d:context().tab_value==1 and not m.dirty(d:context()))
d:send{type='EDIT', field='text', value='new\nbody'}
assert(m.dirty(d:context()) and d:context().revision==1)
d:send{type='EDIT', field='text', value='bad\r\nlines'}
assert(d:context().text=='new\nbody' and d:context().error=='text must use LF line endings')
assert(notices[#notices]=='Ourokit Notes: text must use LF line endings')
assert(not pcall(d.send, d, {type='EDIT', field='text'}), 'schema requires value')

-- Save without a path asks the chooser, then writes the bytes from save start.
chooser.answer='file:///new.ournote'
d:send('SAVE')
assert(d:matches('open.io.saving.choosing') and not d:can('SAVE') and not d:can('SAVE_AS'))
clock.run_tasks()
assert(chooser[1]=='Untitled.ournote' and #writes==1 and writes[1].path=='file:///new.ournote')
assert(m.decode(writes[1].bytes).text=='new\nbody')
assert(d:matches('open.io.idle') and not m.dirty(d:context()) and d:context().path=='file:///new.ournote')
assert(d:context().error==nil and notices[#notices]=='Note saved: Untitled')
assert(notes:context().paths['document-1']=='file:///new.ournote')

-- A raced edit after the save started stays dirty; a known path skips the chooser.
d:send{type='EDIT', field='title', value='later'}
d:send('SAVE')
assert(d:matches('open.io.saving.writing') and #chooser==1)
d:send{type='EDIT', field='text', value='new\nbody\nlate edit'}
clock.run_tasks()
assert(m.decode(writes[2].bytes).text=='new\nbody' and m.dirty(d:context()) and d:matches('open.io.idle'))

-- A failed write keeps the edits dirty and reports the error.
write_result=false
d:send('SAVE'); clock.run_tasks()
assert(m.dirty(d:context()) and d:context().error=='disk full' and d:matches('open.io.idle'))
write_result=true
d:send('SAVE'); clock.run_tasks()
assert(not m.dirty(d:context()) and d:context().error==nil)

-- Save as always asks; a canceled chooser is silent, other errors report.
d:send{type='EDIT', field='text', value='dirty'}
chooser.answer, chooser.err = nil, {name='Canceled', message='canceled'}
d:send('SAVE_AS'); clock.run_tasks()
assert(#chooser==2 and d:matches('open.io.idle') and m.dirty(d:context()) and d:context().error==nil)
chooser.err={name='PortalFailed', message='portal unavailable'}
d:send('SAVE_AS'); clock.run_tasks()
assert(d:context().error=='portal unavailable' and notices[#notices]=='Ourokit Notes: portal unavailable')
chooser.answer, chooser.err = 'file:///other.ournote', nil
d:send('SAVE_AS'); clock.run_tasks()
assert(d:context().path=='file:///other.ournote' and not m.dirty(d:context()))

-- Selection: a closed tab hands selection to its next neighbor, else the previous.
notes:send{type='ADD', title='E'}; notes:send{type='ADD', title='F'}; notes:send{type='ADD', title='G'}
assert(ids(notes)=='document-1,document-2,document-3,document-4' and notes:context().selected==4)
notes:send{type='CLOSE_TAB', value=2}  -- clean: closes at once
assert(ids(notes)=='document-1,document-3,document-4' and notes:context().selected==3)
notes:send{type='SELECT', value=4}; notes:send{type='CLOSE_TAB', value=4}
assert(notes:context().selected==3)
notes:send{type='ADD', title='background'}; notes:send{type='SELECT', value=1}
notes:send{type='CLOSE_TAB', value=5} -- like the original close(d), closing selects the tab first
assert(notes:context().selected==3 and ids(notes)=='document-1,document-3')
notes:send{type='SELECT', value=99}
assert(notes:context().selected==3, 'unknown tab values are rejected')

-- Closing a dirty note asks; Cancel keeps it, Save closes once it is clean.
local g=notes:child('document-3')
g:send{type='EDIT', field='text', value='dirty'}
notes:send{type='CLOSE_TAB', value=3}
assert(notes:context().selected==3 and g:matches('open.lifecycle.confirming.prompt'))
g:send('CANCEL'); assert(g:matches('open.lifecycle.active'))
notes:send{type='CLOSE_TAB', value=3}
write_result=false; chooser.answer='file:///g.ournote'
g:send('SAVE'); assert(g:matches('open.lifecycle.confirming.awaiting') and not g:can('DISCARD'))
clock.run_tasks()
assert(g:matches('open.lifecycle.confirming.prompt') and g:context().error=='disk full', 'failed save keeps the prompt')
write_result=true
g:send('SAVE'); clock.run_tasks()
assert(ids(notes)=='document-1' and g:status()=='done' and notes:context().selected==1)
assert(notes:context().paths['document-3']=='file:///g.ournote')

-- Closing the last tab outside the window walk persists an empty session.
notes:send{type='CLOSE_TAB', value=1}
assert(notes:matches('quitting') and exits==0); clock.run_tasks()
assert(notes:status()=='done' and exits==1 and #persisted.paths==0 and persisted.selected==nil and persisted.split==0.3)

-- The window close walk prompts each dirty note in order; Cancel aborts it.
exits, persisted = 0, nil
notes=start()
notes:send{type='ADD', title='A', text='a', path='file:///a.ournote'}
notes:send{type='ADD', title='B', text='b', path='file:///b.ournote'}
notes:send{type='ADD', title='C', text='c', path='file:///c.ournote'}
notes:send{type='RESIZE', position=0.4}
notes:child('document-1'):send{type='EDIT', field='text', value='a!'}
notes:child('document-3'):send{type='EDIT', field='text', value='c!'}
notes:send{type='SELECT', value=2}
notes:send('CLOSE_WINDOW')
assert(notes:matches('running.closing.walking') and notes:context().selected==1)
assert(notes:child('document-1'):matches('open.lifecycle.confirming'))
assert(not notes:can('CLOSE_WINDOW'))
notes:child('document-1'):send('CANCEL')
assert(notes:matches('running.open') and notes:context().closing==nil)
notes:send('CLOSE_WINDOW')
notes:child('document-1'):send('DISCARD')
assert(ids(notes)=='document-2,document-3' and notes:child('document-3'):matches('open.lifecycle.confirming'))
assert(notes:context().selected==3)
notes:child('document-3'):send('CANCEL')
assert(notes:matches('running.open') and ids(notes)=='document-2,document-3')
-- Final walk: discarding the last dirty note quits with the captured tabs.
notes:send('CLOSE_WINDOW')
notes:child('document-3'):send('DISCARD')
clock.run_tasks()
assert(notes:status()=='done' and exits==1)
assert(table.concat(persisted.paths,',')=='file:///b.ournote,file:///c.ournote' and persisted.selected=='file:///c.ournote' and persisted.split==0.4)

-- Inspection data is plain.
assert(o.json.decode(o.json.encode(charts.document:graph())).id=='document')
assert(o.json.decode(o.json.encode(charts.notes:graph())).id=='notes')

local storage=require('storage')
local position,paths,selected=storage.load()
assert(position==0.25 and #paths==0 and selected==nil)
assert(storage.save(0.37,{{path='file:///first.ournote'},{title='unsaved'},{path='file:///second.ournote'}},{path='file:///first.ournote'}))
position,paths,selected=storage.load()
assert(position==0.37 and #paths==2 and paths[1]=='file:///first.ournote' and paths[2]=='file:///second.ournote' and selected==paths[1])
local dirs=o.xdg.paths('dev.ourokit.documents')
assert(o.files.write(dirs.config..'/preferences.json','{"version":1,"split_position":12}'))
assert(o.files.write(dirs.state..'/session.json','{"version":1,"uris":["https://not-a-local-note",false,"file:///valid"],"selected":4}'))
position,paths,selected=storage.load()
assert(position==0.25 and #paths==1 and paths[1]=='file:///valid' and selected==nil)
assert(o.files.write(dirs.state..'/session.json','{broken'))
position,paths=storage.load(); assert(position==0.25 and #paths==0)
assert(storage.save(0.4,{},nil))
assert(o.files.read(dirs.state..'/session.json'):find('"uris":[]',1,true))
o.stdout.write('PASS documents charts\n')
o.exit(0)
'''

assert BINARY.exists(), "run zig build first"
with tempfile.TemporaryDirectory() as temporary:
    app = Path(temporary) / "test.lua"
    app.write_text(source)
    for name in ("model.lua", "storage.lua", "charts.lua"):
        (Path(temporary) / name).write_bytes((ROOT / "examples/documents" / name).read_bytes())
    env=dict(os.environ, XDG_CONFIG_HOME=temporary+'/config', XDG_STATE_HOME=temporary+'/state')
    process = subprocess.run(["dbus-run-session", "--", str(BINARY), "run", str(app), "--headless"], env=env, capture_output=True, text=True, timeout=10)
    stdout, stderr = process.stdout, process.stderr
    assert process.returncode == 0, stderr
assert "LuaRuntimeError" not in stderr, stderr
assert "PASS documents charts" in stdout, stdout
print("PASS documents charts: saves, races, chooser cancel/failure, close prompts, selection and the window close walk")
