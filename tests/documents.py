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
local d=m.new('A','B','file:///old.ournote')
assert(d.id=='document-1' and not d.dirty)
m.edit(d,'text','new'); assert(d.dirty and d.revision==1)
local first=m.begin_save(d)
assert(d.saving and m.begin_save(d)==nil)
m.edit(d,'title','later')
assert(m.finish_save(d,first,'file:///new.ournote',true) and d.dirty and d.path=='file:///new.ournote')
local second=m.begin_save(d)
assert(not m.finish_save(d,second,d.path,false,'disk full') and d.dirty and d.error=='disk full')
assert(not m.finish_save(d,second,d.path,true) and d.dirty)
local third=m.begin_save(d); assert(m.finish_save(d,third,d.path,true) and not d.dirty)
local bytes=m.encode(d); local decoded=m.decode(bytes)
assert(decoded.title=='later' and decoded.text=='new')
assert(m.decode('{"format":"dev.ourokit.ournote","version":1,"title":"x","text":"y","extra":1}')==nil)
assert(m.decode('{broken')==nil)
assert(m.decode('{"format":"dev.ourokit.ournote","version":1,"title":"x\\ny","text":"z"}')==nil)
assert(not m.edit(d,'text','two\nlines') and d.text=='new')
local uris=m.parse_uri_list('# comment\r\nfile:///one\r\n\r\nfile:///two\n')
assert(#uris==2 and uris[1]=='file:///one' and uris[2]=='file:///two')
local canceled=m.begin_save(d); assert(m.cancel_save(d,canceled) and not d.saving and not m.cancel_save(d,canceled))
local e=m.new(); assert(e.id=='document-2'); assert(m.remove(d) and m.documents[1]==e)
o.stdout.write('PASS documents model\n')
o.exit(0)
'''

assert BINARY.exists(), "run zig build first"
with tempfile.TemporaryDirectory() as temporary:
    app = Path(temporary) / "test.lua"
    app.write_text(source)
    (Path(temporary) / "model.lua").write_bytes((ROOT / "examples/documents/model.lua").read_bytes())
    process = subprocess.run(["dbus-run-session", "--", str(BINARY), "run", str(app), "--headless"], capture_output=True, text=True, timeout=10)
    stdout, stderr = process.stdout, process.stderr
    assert process.returncode == 0, stderr
assert "LuaRuntimeError" not in stderr, stderr
assert "PASS documents model" in stdout, stdout
print("PASS documents deterministic state, strict decode, failed and raced saves")
