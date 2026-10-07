#!/usr/bin/env python3
"""Deterministic checks for examples/launcher (no compositor needed).

The launcher chart is headless: discovery and launching are fakes and
invokes run on the manual scheduler, so every scan, launch, failure and
cancellation is driven explicitly. Storybook then renders the shared view
from charts driven into each state.
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OUROKIT_TEST_BINARY", ROOT / "zig-out/bin/ouroctl"))

source = r'''
local o=require('ouro')
local machine=o.machine
local m=require('model')
local null=o.json.null

local function entry(id, name, fields)
  local e={id=id..'.desktop', path='/apps/'..id..'.desktop', name=name, generic_name=null, comment=null, icon=null,
    exec=id, working_directory=null, keywords={}, actions={}, hidden=false, no_display=false, terminal=false,
    dbus_activatable=false, visible=true}
  for k,v in pairs(fields or {}) do e[k]=v end
  return e
end
local apps={
  entry('org.gnome.Terminal','Terminal',{generic_name='Terminal emulator',keywords={'shell','prompt','command'}}),
  entry('firefox','Firefox',{comment='Browse the web',generic_name='Web Browser'}),
  entry('files','Files',{comment='Access and organize files',keywords={'folder','manager'}}),
  entry('hidden','Hidden tool',{visible=false,no_display=true}),
  entry('calc','Calculator',{comment='Perform calculations'}),
  entry('settings','Settings',{keywords={'preferences'}}),
}
local function names(list) local out={} for i,e in ipairs(list) do out[i]=e.name end return table.concat(out,',') end

-- Plain functions.
local catalog=m.catalog(apps)
assert(names(catalog)=='Calculator,Files,Firefox,Settings,Terminal', names(catalog))
assert(m.results(catalog,'')==catalog)
assert(names(m.results(catalog,'f'))=='Files,Firefox', names(m.results(catalog,'f')))
assert(names(m.results(catalog,'web'))=='Firefox')                -- generic name and comment
assert(names(m.results(catalog,'shell'))=='Terminal')             -- keyword prefix
assert(names(m.results(catalog,'fi'))=='Files,Firefox')
assert(names(m.results(catalog,'organize files'))=='Files')        -- every word must match
assert(names(m.results(catalog,'ter'))=='Terminal')
assert(names(m.results(catalog,'TERM'))=='Terminal')              -- case-insensitive
assert(names(m.results(catalog,'nothing'))=='')
assert(names(m.results(catalog,'(.'))=='')                       -- patterns are literal
assert(m.move(1,-1,5)==5 and m.move(5,1,5)==1 and m.move(2,1,5)==3 and m.move(1,1,0)==1)
assert(m.clamp(9,3)==3 and m.clamp(0,3)==1 and m.clamp(2,0)==1)
assert(m.icon(entry('a','A',{icon='/abs/path.png'}))==nil and m.icon(entry('a','A',{icon='firefox'}))=='firefox')
assert(m.icon(entry('a','A'))==nil and m.detail(entry('a','A'))=='a.desktop')

-- Fake services record what the chart asked for.
local scans, launches = 0, {}
local scan_error, launch_error
local charts=require('charts')(o, m, {
  scan=function() scans=scans+1; if scan_error then error(scan_error, 0) end return apps end,
  launch=function(e) launches[#launches+1]=e.id; if launch_error then error(launch_error, 0) end return true end,
})
local clock=machine.manual_scheduler()
local launcher=charts.launcher:start { scheduler=clock }
local records={}
launcher:observe(function(r) records[#records+1]=r end)
local function last() return records[#records] end
local function invoked(action) for _,i in ipairs(last().invokes) do if i.action==action then return i end end end

-- Hidden: nothing runs, only opening is possible.
assert(launcher:matches('hidden') and clock.open_scopes==1)
assert(not launcher:can('ACTIVATE') and launcher:can('TOGGLE') and launcher:can('OPEN'))
launcher:send('CLOSE'); assert(last().rejected and last().reason=='no_transition')

-- Opening scans in a scope owned by open.loading.
launcher:send('TOGGLE')
assert(launcher:matches('open.loading') and launcher:has_tag('busy'))
assert(invoked('started').src=='scan' and clock.open_scopes==2 and scans==0)
assert(not launcher:can('ACTIVATE'), 'cannot launch before the scan finishes')
launcher:send{type='QUERY', text='fi'}                           -- typing during a scan is kept
assert(launcher:context().query=='fi')
clock.run_tasks()
assert(scans==1 and launcher:matches('open.ready') and not launcher:has_tag('busy'))
assert(clock.open_scopes==1, 'the scan scope closed with open.loading')
assert(#launcher:context().entries==5, 'hidden entries are filtered out')
assert(names(m.results(launcher:context().entries, launcher:context().query))=='Files,Firefox')

-- Keyboard selection wraps over the filtered results.
assert(launcher:context().selected==1)
launcher:send{type='MOVE', delta=1}; assert(launcher:context().selected==2)
launcher:send{type='MOVE', delta=1}; assert(launcher:context().selected==1)
launcher:send{type='MOVE', delta=-1}; assert(launcher:context().selected==2)
launcher:send{type='QUERY', text=''}; assert(launcher:context().selected==1, 'a new query resets selection')
launcher:send{type='SELECT', index=4}; assert(launcher:context().selected==4)
launcher:send{type='SELECT', index=99}; assert(last().rejected and launcher:context().selected==4)
assert(not pcall(launcher.send, launcher, {type='MOVE', delta=0.5}), 'schema requires an integer delta')
assert(not pcall(launcher.send, launcher, {type='LAUNCH'}), 'undeclared events are rejected')

-- No match, no launch.
launcher:send{type='QUERY', text='nothing'}
assert(not launcher:can('ACTIVATE'))
launcher:send('ACTIVATE'); assert(last().rejected and launcher:matches('open.ready'))

-- Enter launches the selection, then the launcher closes.
launcher:send{type='QUERY', text='term'}
launcher:send('ACTIVATE')
assert(launcher:matches('open.launching') and launcher:context().launching.name=='Terminal')
assert(invoked('started').src=='launch' and #launches==0)
assert(not launcher:can('ACTIVATE'), 'one launch at a time')
clock.run_tasks()
assert(launches[1]=='org.gnome.Terminal.desktop' and launcher:matches('hidden'))
assert(clock.open_scopes==1)

-- Reopening rescans, starts from an empty query, and keeps the old list
-- while scanning.
launcher:send('OPEN')
local c=launcher:context()
assert(launcher:matches('open.loading') and c.query=='' and c.selected==1 and c.launching==nil and #c.entries==5)
clock.run_tasks(); assert(scans==2)

-- A pointer activation names its row.
launcher:send{type='ACTIVATE', index=3}
assert(launcher:context().launching.name=='Firefox' and launcher:context().selected==3)
launch_error={name='NoExec', message='entry has no Exec'}
clock.run_tasks()
assert(launcher:matches('open.ready') and launcher:context().error=='entry has no Exec', 'launch failure keeps the launcher open')
launcher:send{type='QUERY', text='c'}; assert(launcher:context().error==nil, 'typing clears the error')
launch_error=nil

-- Escape (CLOSE) while launching cancels the launch: it never runs.
launcher:send('ACTIVATE')
assert(launcher:matches('open.launching'))
local before=#launches
launcher:send('CLOSE')
assert(launcher:matches('hidden') and invoked('cancelled').src=='launch' and clock.open_scopes==1)
clock.run_tasks(); assert(#launches==before and launcher:matches('hidden'))

-- Toggling closed during a scan cancels it; the next open scans again.
launcher:send('TOGGLE'); assert(launcher:matches('open.loading'))
launcher:send('TOGGLE'); assert(launcher:matches('hidden') and invoked('cancelled').src=='scan')
clock.run_tasks(); assert(scans==2, 'a cancelled scan never runs')

-- Discovery failure: an error state that Enter (or RETRY) retries.
scan_error={name='ApplicationDiscoveryBusy', message='a scan is already running'}
launcher:send('OPEN'); clock.run_tasks()
assert(launcher:matches('open.failed') and launcher:context().error=='a scan is already running')
assert(launcher:can('RETRY') and launcher:can('ACTIVATE'))
scan_error=nil
launcher:send('ACTIVATE'); assert(launcher:matches('open.loading'))
clock.run_tasks(); assert(launcher:matches('open.ready') and launcher:context().error==nil, 'a successful scan clears the error')

-- What the palette or MCP would see right now.
local accepted={}
for _,t in ipairs(launcher:accepted()) do accepted[#accepted+1]=t end
table.sort(accepted)
assert(table.concat(accepted,',')=='ACTIVATE,CLOSE,MOVE,QUERY,SELECT,TOGGLE', table.concat(accepted,','))
launcher:send('CLOSE')
accepted={}
for _,t in ipairs(launcher:accepted()) do accepted[#accepted+1]=t end
table.sort(accepted)
assert(table.concat(accepted,',')=='OPEN,TOGGLE', table.concat(accepted,','))

-- Inspection data is plain. The context is not: entries hold ouro.json.null.
assert(o.json.decode(o.json.encode(charts.launcher:graph())).id=='launcher')
assert(not pcall(launcher.persist, launcher), 'platform nulls are not plain data')

launcher:stop(); assert(clock.open_scopes==0)
o.stdout.write('PASS launcher charts\n')
o.exit(0)
'''

assert BINARY.exists(), "run zig build first"
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    app = root / "test.lua"
    app.write_text(source)
    for name in ("model.lua", "charts.lua", "view.lua", "stories.lua"):
        (root / name).write_bytes((ROOT / "examples/launcher" / name).read_bytes())
    process = subprocess.run([str(BINARY), "run", str(app), "--headless"], capture_output=True, text=True, timeout=10)
    assert process.returncode == 0, process.stderr
    assert "LuaRuntimeError" not in process.stderr, process.stderr
    assert "PASS launcher charts" in process.stdout, process.stdout
    print("PASS launcher charts: discovery, search, selection, launch, failures and state-owned cancellation")

    # The same view, rendered from charts driven into each state.
    output = Path(os.environ.get("OUROKIT_TEST_CAPTURE", root / "frames")).resolve()
    if output.suffix:
        output = output.parent
    output = output / "launcher"
    stories = root / "stories.lua"
    listed = subprocess.run([str(BINARY), "storybook", "list", str(stories), "--json"],
                            capture_output=True, text=True, timeout=30)
    assert listed.returncode == 0, listed.stderr
    ids = [story["id"] for story in json.loads(listed.stdout)["stories"]]
    assert ids == ["launcher/loading", "launcher/ready", "launcher/filtered", "launcher/launching",
                   "launcher/launch-error", "launcher/discovery-error", "launcher/no-match"], ids
    shot = subprocess.run([str(BINARY), "storybook", "snapshot", str(stories), "--output", str(output), "--json"],
                          capture_output=True, text=True, timeout=60)
    assert shot.returncode == 0, shot.stderr
    assert "panic" not in shot.stderr, shot.stderr
    for story in ids:
        png = output / (story + ".png")  # "launcher/ready" -> launcher/ready.png
        assert png.exists(), sorted(p.name for p in output.rglob("*"))
        assert png.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"
    print(f"PASS launcher storybook: {len(ids)} frames in {output}")
