#!/usr/bin/env python3
"""Deterministic model checks for examples/documents (no compositor needed)."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OUROKIT_TEST_BINARY", ROOT / "zig-out/bin/ouroctl"))

source = r'''
local o=require('ouro')
local m=require('model')(o.json)
local d=m.new('A','first\nsecond','file:///old.ournote')
assert(d.id=='document-1' and d.tab_value==1 and not d.dirty and m.selected()==d)
m.edit(d,'text','new\nbody'); assert(d.dirty and d.revision==1)
local first=m.begin_save(d)
assert(d.saving and m.begin_save(d)==nil)
m.edit(d,'title','later'); m.edit(d,'text','new\nbody\nlate edit')
assert(m.finish_save(d,first,'file:///new.ournote',true) and d.dirty and d.path=='file:///new.ournote')
local second=m.begin_save(d)
assert(not m.finish_save(d,second,d.path,false,'disk full') and d.dirty and d.error=='disk full')
assert(not m.finish_save(d,second,d.path,true) and d.dirty)
local third=m.begin_save(d); assert(m.finish_save(d,third,d.path,true) and not d.dirty)
local bytes=m.encode(d); local decoded=m.decode(bytes)
assert(decoded.title=='later' and decoded.text=='new\nbody\nlate edit')
assert(m.decode('{"format":"dev.ourokit.ournote","version":1,"title":"x","text":"y","extra":1}')==nil)
assert(m.decode('{broken')==nil)
assert(m.decode('{"format":"dev.ourokit.ournote","version":1,"title":"x\\ny","text":"z"}')==nil)
assert(m.decode('{"format":"dev.ourokit.ournote","version":1,"title":"x","text":"bad\\rline"}')==nil)
assert(not m.edit(d,'text','bad\r\nlines') and d.text=='new\nbody\nlate edit')
assert(not m.edit(d,'title','two\nlines') and d.title=='later')
local uris=m.parse_uri_list('# comment\r\nfile:///one\r\n\r\nfile:///two\n')
assert(#uris==2 and uris[1]=='file:///one' and uris[2]=='file:///two')
local canceled=m.begin_save(d); assert(m.cancel_save(d,canceled) and not d.saving and not m.cancel_save(d,canceled))
local e=m.new('E'); local f=m.new('F'); local g=m.new('G')
assert(e.id=='document-2' and e.tab_value==2 and m.selected()==g)
assert(m.select(e.tab_value)==e and m.selected_id==e.id)
assert(m.remove(e) and m.selected()==f) -- selected first chooses its next neighbor
assert(m.remove(f) and m.selected()==g) -- selected middle chooses its next neighbor
local h=m.new('H'); assert(m.select(h.id)==h)
assert(m.remove(h) and m.selected()==g) -- selected last chooses its previous neighbor
local background=m.new('background'); m.select(g.id)
assert(m.remove(background) and m.selected()==g) -- background close preserves selection
assert(m.remove(d) and m.selected()==g)
assert(m.select(99999)==nil and m.selected()==g)

-- Canceling a chooser leaves the snapshot dirty and a stale completion cannot
-- clear a later active save. A raced edit remains dirty after its snapshot lands.
m.edit(g,'text','dirty')
local canceled=m.begin_save(g); assert(m.cancel_save(g,canceled) and g.dirty)
local active=m.begin_save(g); assert(not m.finish_save(g,canceled,'file:///stale',true) and g.saving)
m.edit(g,'text','raced')
assert(m.finish_save(g,active,'file:///g.ournote',true) and g.dirty and g.path=='file:///g.ournote')
local final=m.begin_save(g); assert(m.finish_save(g,final,g.path,true) and not g.dirty)
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
o.stdout.write('PASS documents model\n')
o.exit(0)
'''

assert BINARY.exists(), "run zig build first"
with tempfile.TemporaryDirectory() as temporary:
    app = Path(temporary) / "test.lua"
    app.write_text(source)
    (Path(temporary) / "model.lua").write_bytes((ROOT / "examples/documents/model.lua").read_bytes())
    (Path(temporary) / "storage.lua").write_bytes((ROOT / "examples/documents/storage.lua").read_bytes())
    env=dict(os.environ, XDG_CONFIG_HOME=temporary+'/config', XDG_STATE_HOME=temporary+'/state')
    process = subprocess.run(["dbus-run-session", "--", str(BINARY), "run", str(app), "--headless"], env=env, capture_output=True, text=True, timeout=10)
    stdout, stderr = process.stdout, process.stderr
    assert process.returncode == 0, stderr
assert "LuaRuntimeError" not in stderr, stderr
assert "PASS documents model" in stdout, stdout
print("PASS documents deterministic selection/close state, strict decode, canceled and raced saves")
