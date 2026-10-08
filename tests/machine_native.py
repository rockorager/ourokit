#!/usr/bin/env python3
"""Statechart timers and invokes on the real scheduler (no compositor needed).

`ouroctl test` forbids wall-clock sleeps, so machine_test.lua uses a manual
scheduler. This runs the default scheduler on native task scopes: each state
entry opens a scope, exiting closes it, and closing cancels sleeping timers and
in-flight invokes (their code after the sleep never runs). The token scheduler
fallback is checked too: it only drops stale deliveries.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("OUROKIT_TEST_BINARY", ROOT / "zig-out/bin/ouroctl"))

source = r'''
local o = require('ouro')
local machine = o.machine
assert(machine.strict == false, 'production runs reject undeclared events instead of raising')
machine.strict = true -- this test wants typos to fail loudly
assert(machine.native_scopes and machine.default_scheduler.kind == 'native', 'native scope binding missing')
local log = {}
local after_sleep = {}
machine.inspect(function(r)
  if r.kind == 'transition' then
    for _, t in ipairs(r.timers) do log[#log + 1] = 'timer ' .. t.action .. ' ' .. t.state .. ' ' .. t.delay end
    for _, i in ipairs(r.invokes) do log[#log + 1] = 'invoke ' .. i.action .. ' ' .. i.id end
  end
end)
local chart = machine.create {
  id = 'native', initial = 'idle', context = {},
  actors = { fetch = function(input) o.sleep(input.ms); after_sleep[#after_sleep + 1] = input.ms; return 'fetched ' .. input.ms end },
  states = {
    idle = { on = { ARM = 'armed', FETCH = 'fetching', SLOW = 'slow' } },
    armed = { after = { [40] = 'expired' }, on = { DISARM = 'idle' } },
    expired = { on = { RESET = 'idle' } },
    fetching = { invoke = { src = 'fetch', input = function() return { ms = 20 } end,
      on_done = { target = 'idle', actions = machine.assign { result = function(_, e) return e.output end } } } },
    slow = { invoke = { src = 'fetch', input = function() return { ms = 60 } end,
      on_done = { target = 'idle', actions = machine.assign { result = function(_, e) return e.output end } } },
      on = { CANCEL = 'idle' } },
  },
}
local actor = chart:start()
actor:send('ARM')
o.sleep(80)
assert(actor:matches('expired'), 'timer did not fire')
actor:send('RESET')
actor:send('ARM')
o.sleep(10)
actor:send('DISARM')
o.sleep(60)
assert(actor:matches('idle'), 'cancelled timer fired')
actor:send('FETCH')
assert(actor:matches('fetching'))
o.sleep(60)
assert(actor:matches('idle') and actor:context().result == 'fetched 20', 'invoke result missing')
actor:send('SLOW')
o.sleep(10)
actor:send('CANCEL')
o.sleep(100)
assert(actor:matches('idle') and actor:context().result == 'fetched 20', 'stale invoke result applied')
-- Native cancellation: the 60ms fetch was unwound in its sleep.
assert(table.concat(after_sleep, ',') == '20', 'canceled invoke kept running: ' .. table.concat(after_sleep, ','))

-- Stopping an actor closes its root scope, and children nest under it.
local child = machine.create { id = 'child', initial = 'busy', states = {
  busy = { invoke = { src = 'fetch', input = function() return { ms = 50 } end, on_done = 'finished' } },
  finished = {} },
  actors = { fetch = function(input) o.sleep(input.ms); after_sleep[#after_sleep + 1] = 'child'; return true end } }
local parent = machine.create { id = 'parent', initial = 'on', states = { on = { on = {
  ADD = { actions = machine.spawn(child, { id = 'c' }) } } } } }
local p = parent:start()
p:send('ADD')
o.sleep(10)
p:stop()
o.sleep(80)
assert(table.concat(after_sleep, ',') == '20', 'stopped child kept running: ' .. table.concat(after_sleep, ','))

-- The token fallback: work runs to completion, but its result is dropped.
local tokens = chart:start { scheduler = machine.token_scheduler }
tokens:send('SLOW'); o.sleep(10); tokens:send('CANCEL'); o.sleep(100)
assert(tokens:matches('idle') and tokens:context().result == nil)
assert(table.concat(after_sleep, ',') == '20,60', 'token scheduler: ' .. table.concat(after_sleep, ','))
local expected = table.concat({
  'timer started armed 40', 'timer fired armed 40',
  'timer started armed 40', 'timer cancelled armed 40',
  'invoke started fetch', 'invoke done fetch',
  'invoke started fetch', 'invoke cancelled fetch'}, '|')
local first = {}
for i = 1, 8 do first[i] = log[i] end
assert(table.concat(first, '|') == expected, table.concat(log, '|'))
-- Waiting inside a function action is rejected before it touches the task,
-- even when the action swallows the operation's own failure.
local strict = machine.create { id = 'strict', initial = 'a', states = { a = { on = {
  READ = { actions = function() local _ = o.files.read('/nonexistent') end },
  NAP = { actions = function() pcall(o.sleep, 5) end },
} } } }
local s = strict:start()
local ok, err = pcall(s.send, s, 'READ')
assert(not ok and err:find("YieldInAction: action 'function' (strict.a on READ) called Ouro I/O", 1, true), tostring(err))
ok, err = pcall(s.send, s, 'NAP')
assert(not ok and err:find('called ouro.sleep', 1, true), tostring(err))
o.sleep(1) -- this task is still healthy
assert(o.files.write('/tmp/ourokit-machine-native-probe', 'ok'))

-- A one-shot spawned task reads in its owner's scope; leaving the owner cancels it.
local reader = machine.create { id = 'reader', initial = 'idle', context = {},
  actors = { read = function(input) o.sleep(input.ms); after_sleep[#after_sleep + 1] = 'read ' .. input.ms
    return o.files.read('/tmp/ourokit-machine-native-probe') end },
  states = {
    idle = { on = { GO = 'reading' } },
    reading = {
      entry = machine.spawn('read', { id = 'r', input = function() return { ms = 10 } end }),
      on = { ['done.actor.r'] = { target = 'idle', actions = machine.assign { text = function(_, e) return e.output end } },
             SLOW = { actions = machine.spawn('read', { id = 'slow', input = function() return { ms = 80 } end }) },
             LEAVE = 'idle' } },
  } }
local r = reader:start()
r:send('GO'); o.sleep(50)
assert(r:matches('idle') and r:context().text == 'ok', 'spawned read did not report')
r:send('GO'); r:send('SLOW'); o.sleep(20)
assert(r:matches('idle') and r:snapshot().children[1] == nil)
r:send('GO'); r:send('SLOW'); o.sleep(30); r:send('LEAVE'); o.sleep(100)
assert(table.concat(after_sleep, ',') == '20,60,read 10,read 10,read 10', 'canceled task ran on: ' .. table.concat(after_sleep, ','))

-- wait_for parks the task and wakes on the actor's commits.
local gate = machine.create { id = 'gate', initial = 'closed', context = { n = 0 }, states = {
  closed = { on = { OPEN = 'open', BUMP = { actions = machine.assign { n = function(c) return c.n + 1 end } } } },
  open = { on = { END = 'gone' } }, gone = { type = 'final' } } }
local g = gate:start()
local order = {}
o.spawn(function() o.sleep(20); order[#order + 1] = 'bump'; g:send('BUMP'); o.sleep(10); order[#order + 1] = 'open'; g:send('OPEN') end)
local snap = machine.wait_for(g, function(s) return machine.matches(s, 'open') end, { timeout = 1000 })
order[#order + 1] = 'woke'
assert(table.concat(order, ',') == 'bump,open,woke' and snap.context.n == 1, table.concat(order, ','))
assert(next(g._waiters) == nil)
local started = o._monotonic_ms()
local ok, err = pcall(machine.wait_for, g, function(s) return machine.matches(s, 'closed') end, { timeout = 30 })
assert(not ok and err:find('WaitTimeout: gate did not match within 30 ms', 1, true), tostring(err))
assert(o._monotonic_ms() - started >= 25 and next(g._waiters) == nil)
o.spawn(function() o.sleep(10); g:send('END') end)
ok, err = pcall(machine.wait_for, g, function(s) return machine.matches(s, 'closed') end)
assert(not ok and err:find('WaitEnded: gate is done', 1, true), tostring(err))
local h = gate:start()
o.spawn(function() o.sleep(5); h:send('BUMP') end)
ok, err = pcall(machine.wait_for, h, function(s) if s.context.n > 0 then error('bad predicate', 0) end return false end)
assert(not ok and err == 'bad predicate', tostring(err))
o.spawn(function() o.sleep(5); h:stop() end)
ok, err = pcall(machine.wait_for, h, function(s) return machine.matches(s, 'open') end)
assert(not ok and err:find('WaitEnded: gate is stopped', 1, true), tostring(err))
-- Canceling the waiting task drops its subscription and timer.
local watched = gate:start { id = 'watched' }
local flags = {}
local watcher = machine.create { id = 'watcher', initial = 'idle', states = {
  idle = { on = { WATCH = 'watching' } },
  watching = { entry = machine.spawn(function()
    machine.wait_for(watched, function(s) return machine.matches(s, 'open') end, { timeout = 200 })
    flags.woke = true
  end), on = { STOP = 'idle' } } } }
local w = watcher:start()
w:send('WATCH'); o.sleep(10)
assert(next(watched._waiters) ~= nil, 'watcher is not waiting')
w:send('STOP'); o.sleep(10); o.sleep(1) -- the canceled task unwinds at the next safe point
assert(next(watched._waiters) == nil, 'canceled wait kept its subscription')
watched:send('OPEN'); o.sleep(250)
assert(not flags.woke)

-- stop() after the native scope was already canceled (an unmounted
-- instance) is safe: closing a stale scope is a no-op.
local late = machine.create { id = 'late', initial = 'idle', states = {
  idle = { on = { GO = 'busy' } }, busy = { after = { [30] = 'idle' } } } }:actor { lazy = true, scope = 'task' }
late:send('GO')
machine.default_scheduler.close(late._root_scope)
late:stop(); late:stop()
o.sleep(50)
assert(late:status() == 'stopped' and late:matches('busy'))

-- Review H1: a child stopped by its parent mid-effects runs no invoke.
local ran = false
local stoppable = machine.create { id = 'stoppable', initial = 'idle',
  actors = { save = function() o.sleep(20); ran = true end },
  states = {
    idle = { on = { CLOSE = { target = 'saving', actions = machine.send_parent('CLOSE_ME') } } },
    saving = { invoke = { src = 'save' } } } }
local holder = machine.create { id = 'holder', initial = 'running', states = { running = {
  entry = machine.spawn(stoppable, { id = 'c' }), on = { CLOSE_ME = { actions = machine.stop('c') } } } } }
local h1 = holder:start()
local kid = h1:child('c')
kid:send('CLOSE')
assert(kid:status() == 'stopped')
o.sleep(60)
assert(not ran, 'the invoke of a stopped actor ran')
h1:stop()

-- Review L11: wait_for on a created actor ends with WaitEnded when it stops.
local created = machine.create { id = 'created', initial = 'a', states = { a = { on = { GO = 'b' } }, b = {} } }:actor { lazy = true }
local outcome
o.spawn(function()
  local ok, err = pcall(machine.wait_for, created, function(s) return machine.matches(s, 'b') end)
  outcome = ok and 'matched' or tostring(err)
end)
o.sleep(5)
created:stop()
o.sleep(5); o.sleep(1)
assert(outcome and outcome:find('WaitEnded: created is stopped', 1, true), tostring(outcome))

-- Gap 5: machine.sleep in an invoke waits on the logical clock (it wakes at
-- its deadline), and leaving the state cancels the wait.
local slept = {}
local napper = machine.create { id = 'napper', initial = 'idle',
  actors = { nap = function(ms) local t0 = machine.now(); machine.sleep(ms); slept[#slept + 1] = machine.now() - t0; return ms end },
  states = {
    idle = { on = { NAP = 'napping', LONG = 'long' } },
    napping = { invoke = { src = 'nap', input = function() return 40 end, on_done = 'idle' } },
    long = { invoke = { src = 'nap', input = function() return 200 end, on_done = 'idle' }, on = { LEAVE = 'idle' } },
  } }
local n = napper:start()
n:send('NAP'); o.sleep(20)
assert(n:matches('napping') and #slept == 0, 'woke early')
o.sleep(60)
assert(n:matches('idle') and slept[1] >= 40 and slept[1] < 60, 'slept ' .. tostring(slept[1]))
n:send('LONG'); o.sleep(20); n:send('LEAVE'); o.sleep(250)
assert(#slept == 1, 'a canceled machine.sleep woke')
n:stop()

o.stdout.write('PASS machine native\n')
o.exit(0)
'''

# An actor started inside an MCP action handler outlives the call: its root
# scope is application scope, not the per-call action scope (which used to
# be left non-empty, panicking when the call returned).
mcp_source = r'''
local o = require('ouro')
local machine = o.machine
local chart = machine.create { id = 'book', initial = 'loading', context = { loaded = false, names = { ada = 'Ada' } },
  actors = { load = function() o.sleep(30); return true end },
  events = { RENAME = { id = 'string', name = 'string' } },
  states = {
    loading = { invoke = { src = 'load', on_done = { target = 'ready', actions = machine.assign { loaded = true } } } },
    ready = { on = { RENAME = { guard = function(c, e) return c.names[e.id] ~= nil end,
      actions = machine.assign { names = function(c, e) local n = {}; for k, v in pairs(c.names) do n[k] = v end; n[e.id] = e.name; return n end } } } },
  } }
local book
local empty = { type = 'object', additionalProperties = false }
local state = { type = 'object', properties = { ready = { type = 'boolean' } }, required = { 'ready' }, additionalProperties = false }
local actions = machine.actions(function() return book end, {
  Rename = { event = 'RENAME', description = 'Rename once loaded', errors = { no_transition = 'NotFoundOrLoading' },
    output = function(s, e) return { name = s.context.names[e.id] } end,
    output_schema = { type = 'object', properties = { name = { type = 'string' } }, required = { 'name' }, additionalProperties = false } },
  WaitReady = { description = 'Wait until loaded', wait = function(s) return machine.matches(s, 'ready') end, timeout = 1000,
    output = function(s) return { ready = s.context.loaded } end, output_schema = state },
}, { chart = chart, before = function(actor) if not actor then return o.action_error('NotStarted', {}) end end })
actions.Start = { description = 'Start the actor', inputSchema = empty, outputSchema = state,
  handler = function() book = book or chart:start(); return { ready = book:matches('ready') } end }
actions.Read = { description = 'Read the actor', inputSchema = empty, outputSchema = state,
  handler = function() return { ready = book ~= nil and book:matches('ready') and book:context().loaded } end }
return o.app { id = 'dev.ourokit.machinetest', actions = actions, run = function() error('headless MCP must not run the UI') end }
'''


def mcp_check():
    import sys, time
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from application_services import call, request
    with tempfile.TemporaryDirectory(prefix="ourokit-machine-mcp-") as temporary:
        app = Path(temporary) / "app.lua"
        app.write_text(mcp_source)
        env = dict(os.environ, XDG_RUNTIME_DIR=temporary)
        process = subprocess.Popen([str(BINARY), "run", str(app), "--mcp", "--headless"], env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            address = Path(temporary) / "ourokit/apps/dev.ourokit.machinetest"
            deadline = time.monotonic() + 8
            while not address.exists():
                assert process.poll() is None and time.monotonic() < deadline, process.stderr.read() if process.poll() is not None else "no socket"
                time.sleep(.02)
            early = call(address, "Rename", {"id": "ada", "name": "Lovelace"})
            assert early["structuredContent"]["error"]["code"] == "NotStarted", early
            first = call(address, "Start")
            assert first["structuredContent"] == {"ready": False}, first
            # The chart rejects RENAME while loading: an action error with the reason.
            loading = call(address, "Rename", {"id": "ada", "name": "Lovelace"})
            error = loading["structuredContent"]["error"]
            assert loading["isError"] and error["code"] == "NotFoundOrLoading" and error["parameters"]["reason"] == "no_transition", loading
            ready = call(address, "WaitReady")  # wait_for inside an MCP handler, woken by the invoke's commit
            assert ready["structuredContent"] == {"ready": True}, ready
            time.sleep(.05)
            assert process.poll() is None, process.stderr.read()
            second = call(address, "Read")
            assert second["structuredContent"] == {"ready": True}, second
            renamed = call(address, "Rename", {"id": "ada", "name": "Lovelace"})
            assert renamed["structuredContent"] == {"name": "Lovelace"}, renamed
            missing = call(address, "Rename", {"id": "nobody", "name": "x"})
            assert missing["structuredContent"]["error"]["code"] == "NotFoundOrLoading", missing
            invalid = request(address, "tools/call", {"name": "Rename", "arguments": {"id": "ada"}})
            assert "error" in invalid, invalid  # inputSchema comes from the chart's RENAME schema
        finally:
            process.terminate()
            _, errors = process.communicate(timeout=8)
            assert "panic" not in errors, errors


def strict_check():
    """machine.strict follows the host: strict under --dev, rejecting otherwise."""
    with tempfile.TemporaryDirectory(prefix="ourokit-machine-strict-") as temporary:
        app = Path(temporary) / "strict.lua"
        app.write_text("local o = require('ouro'); o.stdout.write('strict=' .. tostring(o.machine.strict) .. '\\n'); o.exit(0)\n")
        env = dict(os.environ, XDG_RUNTIME_DIR=temporary)
        for flags, expected in ((["--headless"], "strict=false"), (["--dev", "--headless"], "strict=true")):
            result = subprocess.run([str(BINARY), "run", str(app), *flags], env=env, capture_output=True, text=True, timeout=10)
            assert result.returncode == 0 and expected in result.stdout, (flags, result.stdout, result.stderr)


assert BINARY.exists(), "run zig build first"
strict_check()
mcp_check()
with tempfile.TemporaryDirectory() as temporary:
    app = Path(temporary) / "machine.lua"
    app.write_text(source)
    process = subprocess.run([str(BINARY), "run", str(app), "--headless"], capture_output=True, text=True, timeout=10)
    assert process.returncode == 0, process.stderr
    assert "PASS machine native" in process.stdout, (process.stdout, process.stderr)
print("PASS statechart after/invoke, spawned tasks and wait_for on native scopes: exit and stop cancel sleeping work; actions cannot wait; waits wake on commits; token fallback drops stale results")
