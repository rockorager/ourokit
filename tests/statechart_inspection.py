#!/usr/bin/env python3
"""runtime.statecharts, runtime.send and the ouro://statecharts push feed
on real development instances.

Headless: on-demand attachment with seeded late-attach state, the record
stream, idle detachment, actors carried across a development reload; then
runtime.send (accepted, rejected, wait, errors), the actor filter, push
notifications (none while idle, coalesced until read, the subscription keeps
the observer attached) and a ring overflow that the client reseeds from.
With OUROKIT_TEST_WAYLAND_DISPLAY also: the stopwatch driven over the
endpoint and replayed identically, the statechart visualizer attached by push
without periodic requests, and the visualizer attached to itself.
Run after zig build: python3 tests/statechart_inspection.py
"""
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import threading
import time

from application_services import BINARY, RpcStream, call, development_path, record, request
from desktop_native import inspect

SOURCE = '''local o = require('ouro')
local m = o.machine
-- revision REVISION
local chart = m.create {
  id = 'light', initial = 'red', context = {ready = true, count = 0},
  events = {GO = {}, STOP = {}},
  guards = {ready = function(c) return c.ready end},
  actions = {count = m.assign {count = function(c) return c.count + 1 end}},
  states = {
    red = {on = {GO = {target = 'green', guard = 'ready', actions = 'count'}}},
    green = {after = {[40] = 'red'}},
  },
}
local actor = chart:actor {id = 'signal'}
actor:start()
o.spawn(function()
  while true do
    o.sleep(150); actor:send('GO')
    o.sleep(10); actor:send('STOP')
  end
end)
return o.app {id = 'dev.ourokit.statechart-inspection', run = function() return {windows = {}} end}
'''


def statecharts(endpoint, **arguments):
    result = call(endpoint, 'runtime.statecharts', arguments)
    assert not result.get('isError'), result
    return result['structuredContent']


def wait_for(endpoint, predicate, after, **arguments):
    deadline = time.monotonic() + 8
    seen = []
    while True:
        out = statecharts(endpoint, after=after, **arguments)
        seen += out['records']
        after = out['next']
        if predicate(seen):
            return seen, out
        assert time.monotonic() < deadline, [e['record'].get('event') for e in seen]
        time.sleep(.05)


def event(entry):
    return entry['record'].get('event', {}).get('type')


# A quiet app: nothing happens unless the endpoint sends an event. BURST
# makes `count` ticker records in one turn, faster than any client reads.
QUIET = '''local o = require('ouro')
local m = o.machine
local ticker = m.create {
  id = 'ticker', initial = 'on', context = {ticks = 0}, events = {TICK = {}},
  states = {on = {on = {TICK = {actions = m.assign {ticks = function(c) return c.ticks + 1 end}}}}},
}:actor {id = 'ticker'}
ticker:start()
local counter = m.create {
  id = 'counter', initial = 'idle', context = {n = 0},
  events = {SET = {n = 'integer'}, ARM = {}, DISARM = {}, BURST = {count = 'integer'}},
  actions = {
    set = m.assign {n = function(_, e) return e.n end},
    burst = function(_, e) for _ = 1, e.count do ticker:send('TICK') end end,
  },
  states = {
    idle = {on = {SET = {actions = 'set'}, ARM = 'armed', BURST = {actions = 'burst'}}},
    armed = {after = {[60000] = 'idle'}, on = {DISARM = 'idle'}},
  },
}:actor {id = 'counter'}
counter:start()
return o.app {id = 'dev.ourokit.statechart-send', run = function() return {windows = {}} end}
'''


def send(endpoint, actor, event, **extra):
    result = call(endpoint, 'runtime.send', dict(actor=actor, event=event, **extra))
    return result['structuredContent'], result['isError']


def updates(stream, timeout):
    """Messages that arrive on a subscription within timeout seconds."""
    out, deadline = [], time.monotonic() + timeout
    while True:
        while b"\n" in stream.buffer:
            out.append(stream.read())
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([stream.socket], [], [], left)[0]:
            return out
        chunk = stream.socket.recv(65536)
        assert chunk, 'subscription closed'
        stream.buffer.extend(chunk)


def updated(messages):
    assert all(m.get('method') == 'notifications/resources/updated' and m['params']['uri'] == 'ouro://statecharts'
               for m in messages), messages
    return len(messages)


def send_and_push():
    with tempfile.TemporaryDirectory(prefix='ourokit-statechart-send-') as directory:
        root = Path(directory)
        source = root / 'app.lua'
        source.write_text(QUIET)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root), XDG_STATE_HOME=str(root / 'state'))
        process = subprocess.Popen([str(BINARY), 'run', str(source), '--dev', '--headless'],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            endpoint = development_path(root, process)
            time.sleep(.3)
            # runtime.send: the actor's normal send path, with a summary.
            out, failed = send(endpoint, 'counter', {'type': 'SET', 'n': 7})
            assert not failed and out['accepted'] and out['states'] == ['idle'], out
            assert out['changed'] == ['n'] and out['changes'] == {'n': 7} and isinstance(out['commit'], int), out
            out, failed = send(endpoint, 'counter', {'type': 'DISARM'})
            assert not failed and not out['accepted'] and out['reason'] == 'no_transition' and out['changed'] == [], out
            for actor, bad, code in (('nobody', {'type': 'SET', 'n': 1}, 'UnknownActor'),
                                     ('counter', {'type': 'NOPE'}, 'UnknownEvent'),
                                     ('counter', {'type': 'SET', 'n': 'x'}, 'InvalidEvent'),
                                     ('counter', {'type': 'ouro.x'}, 'InvalidEvent')):
                out, failed = send(endpoint, actor, bad)
                assert failed and out['error']['code'] == code, (bad, out)
            out, failed = send(endpoint, 'counter', {'type': 'ARM'}, wait={'states': ['armed'], 'timeout_ms': 2000})
            assert not failed and out['wait'] == {'matched': True} and out['states'] == ['armed'], out
            # The actor filter: one actor's complete current state.
            full = statecharts(endpoint, after=0, limit=0, actors=False, actor='counter')['actor']
            assert full['graph']['format'] == 'ouro.machine.graph' and full['machine'] == 'counter', full
            snap = full['snapshot']
            assert snap['states'] == ['armed'] and snap['context'] == {'n': 7}, snap
            assert [(t['state'], t['delay']) for t in snap['timers']] == [('armed', 60000)], snap
            assert 'DISARM' in snap['accepted'] and 'SET' not in snap['accepted'], snap
            failed = call(endpoint, 'runtime.statecharts', {'actor': 'nobody'})
            assert failed['isError'], failed

            # Push: discover advertises it, nothing arrives while idle, one
            # notification per read, and the subscription keeps the observer.
            info = request(endpoint, 'server/discover')['result']
            assert info['capabilities']['resources'] == {'subscribe': True}, info
            stream = RpcStream(endpoint)
            stream.socket.sendall(record('subscriptions/listen', {'notifications': {
                'resourceSubscriptions': ['ouro://statecharts']}}, 'feed'))
            ack = stream.read()
            assert ack['method'] == 'notifications/subscriptions/acknowledged', ack
            assert ack['params']['notifications'] == {'resourceSubscriptions': ['ouro://statecharts']}, ack
            cursor = statecharts(endpoint, after=0, limit=1024, keep_alive_ms=100)
            assert updated(updates(stream, 1.0)) == 0, 'no notifications while idle'
            send(endpoint, 'counter', {'type': 'DISARM'})
            assert updated(updates(stream, 1.0)) == 1
            send(endpoint, 'counter', {'type': 'SET', 'n': 8})
            assert updated(updates(stream, .5)) == 0, 'coalesced until the next read'
            page = statecharts(endpoint, after=cursor['next'], seed=cursor['seed'], keep_alive_ms=100)
            assert [event(e) for e in page['records']] == ['DISARM', 'SET'], page
            assert updated(updates(stream, 1.0)) == 1, 'the read re-arms a notification for newer records'
            page = statecharts(endpoint, after=page['next'], seed=page['seed'], keep_alive_ms=100)
            assert updated(updates(stream, 1.0)) == 0, 'caught up: idle again'
            # keep_alive_ms is 100 ms, but the subscriber keeps the observer.
            send(endpoint, 'counter', {'type': 'SET', 'n': 9})
            assert updated(updates(stream, 1.0)) == 1
            page = statecharts(endpoint, after=page['next'], seed=page['seed'], keep_alive_ms=100)
            assert [event(e) for e in page['records']] == ['SET'] and page['seed'] == cursor['seed'], page

            # Overflow: two bursts evict past the cursor in single turns; the
            # read reports dropped and the client reseeds from actors.
            cursor = page
            for _ in range(2):
                out, failed = send(endpoint, 'counter', {'type': 'BURST', 'count': 600})
                assert not failed and out['accepted'], out
            assert updated(updates(stream, 1.0)) == 1, 'one notification for the whole burst'
            gap = statecharts(endpoint, after=cursor['next'], seed=cursor['seed'], limit=1)
            assert gap['dropped'] and gap['first'] > cursor['next'] + 1 and 'actors' not in gap, gap
            reseed = statecharts(endpoint, after=gap['next'], actors=True, limit=0)
            ticker = next(a for a in reseed['actors'] if a['actor'] == 'ticker')
            assert ticker['latest']['context'] == {'ticks': 1200} and ticker['started']['graph']['id'] == 'ticker', ticker

            # Closing the subscription lets the observer detach after keep_alive.
            stream.close()
            statecharts(endpoint, after=reseed['next'], keep_alive_ms=100)
            time.sleep(.4)
            send(endpoint, 'counter', {'type': 'SET', 'n': 10})  # detaches on this record
            send(endpoint, 'counter', {'type': 'SET', 'n': 11})
            after = statecharts(endpoint, after=reseed['next'], seed=reseed['seed'])
            assert after['seed'] == reseed['seed'] + 1, after
            assert 11 not in [e['record'].get('event', {}).get('n') for e in after['records']], after
            print('PASS runtime.send: accepted, rejected, wait and error codes; actor filter; '
                  'push without idle notifications, coalesced per read, subscription keeps the observer; '
                  'ring overflow reported as dropped and reseeded')
        finally:
            process.terminate()
            _, stderr = process.communicate(timeout=10)
            assert b'panic' not in stderr and b'leaked' not in stderr, stderr


def main():
    with tempfile.TemporaryDirectory(prefix='ourokit-statecharts-') as directory:
        root = Path(directory)
        source = root / 'app.lua'
        source.write_text(SOURCE.replace('REVISION', '1'))
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root))
        process = subprocess.Popen([str(BINARY), 'run', str(source), '--dev', '--headless'],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            endpoint = development_path(root, process)
            time.sleep(.4)
            # Nothing is observed before the first call; attaching seeds state.
            first = statecharts(endpoint, after=0)
            assert first['records'] == [] and first['first'] == 1, first
            assert first['seed'] == 1 and [a['actor'] for a in first['actors']] == ['signal'], first
            started, latest = first['actors'][0]['started'], first['actors'][0]['latest']
            assert started['seeded'] and started['graph']['format'] == 'ouro.machine.graph'
            assert any(t['guarded'] and t['event'] == 'GO' for t in started['graph']['transitions'])
            assert latest['origin'] == 'attach' and latest['states'][0] in ('red', 'green'), latest
            assert latest['context']['count'] >= 1 and isinstance(latest['time_ms'], int), latest
            # Records flow once attached.
            seen, out = wait_for(endpoint, lambda s: any(event(e) == 'after.40.green' for e in s), 0)
            assert [e['sequence'] for e in seen] == list(range(1, len(seen) + 1))
            assert [e['time_ms'] for e in seen] == sorted(e['time_ms'] for e in seen)
            go = next(e['record'] for e in seen if event(e) == 'GO')
            assert go['handled'] and go['states'] == ['green'] and go['timers'][0]['action'] == 'started'
            assert go['microsteps'][0]['transitions'][0]['event'] == 'GO'
            stop = next(e['record'] for e in seen if event(e) == 'STOP')
            assert stop['rejected'] and stop['reason'] == 'no_transition', stop
            fired = next(e['record'] for e in seen if event(e) == 'after.40.green')
            assert fired['origin'] == 'timer' and fired['timers'][0]['action'] == 'fired'
            # Post-step guard valves and the scheduler clock from the interpreter.
            red = next(e['record'] for e in seen if e['record'].get('states') == ['red'])
            assert red['guards'] == [{'index': 2, 'passed': True}], red
            assert 0 <= go['time_ms'] - go['timers'][0]['time_ms'] <= 20, go
            assert fired['time_ms'] - go['time_ms'] >= 40, (go['time_ms'], fired['time_ms'])
            # Cursor, seed-gated actors and text mode.
            quiet = statecharts(endpoint, after=out['next'], seed=1)
            assert 'actors' not in quiet and quiet['seed'] == 1
            page = statecharts(endpoint, after=0, limit=1, actors=False, text=True)
            assert page['next'] == 1 and len(page['records']) == 1 and 'actors' not in page
            assert json.loads(page['records'][0]['record'])['kind'] == 'transition'
            # Idle detach: with a 100 ms keep-alive, the next record stops the
            # observer; the following call reattaches and reseeds.
            idle = statecharts(endpoint, after=page['next'], keep_alive_ms=100)
            time.sleep(1.2)  # about eight GO/STOP rounds
            resumed = statecharts(endpoint, after=idle['next'], keep_alive_ms=30000, seed=1)
            assert len(resumed['records']) <= 3, [event(e) for e in resumed['records']]
            assert resumed['seed'] == 2 and resumed['actors'][0]['latest']['origin'] == 'attach', resumed
            # Reload carries the root actor: same path, context preserved.
            before = resumed['actors'][0]['latest']['context']['count']
            source.write_text(SOURCE.replace('REVISION', '2'))
            reload = subprocess.run([str(BINARY), 'dev', 'reload', str(endpoint)], env=env,
                                    capture_output=True, timeout=12)
            assert reload.returncode == 0, reload
            assert call(endpoint, 'runtime.diagnostics')['structuredContent']['generation'] == 2
            reloaded = statecharts(endpoint, after=resumed['next'], seed=2)
            assert reloaded['seed'] == 3 and [a['actor'] for a in reloaded['actors']] == ['signal'], reloaded
            assert reloaded['actors'][0]['latest']['origin'] == 'attach', reloaded
            assert reloaded['actors'][0]['latest']['context']['count'] >= before > 1, (before, reloaded)
            after_reload, _ = wait_for(endpoint, lambda s: any(event(e) == 'GO' for e in s), reloaded['next'])
            assert all(e['record']['actor'] == 'signal' for e in after_reload)
            print('PASS runtime.statecharts: attach on demand with seeded actors, transition/rejected/timer '
                  'records, guard valves and clock, cursor and text mode, idle detach, actors carried across reload')
        finally:
            process.terminate()
            _, stderr = process.communicate(timeout=10)
            assert b'panic' not in stderr and b'leaked' not in stderr, stderr


COMPONENT = '''local o = require('ouro')
local m = o.machine
local chart = m.create {
  id = 'collapsible', initial = 'closed', events = {TOGGLE = {}},
  states = {closed = {on = {TOGGLE = 'open'}}, open = {on = {TOGGLE = 'closed'}}},
}
local Collapsible = m.component(chart, function(self, props)
  return o.button {key = 'b', label = props.title, send = self:event('TOGGLE')}
end)
return o.app {id = 'dev.ourokit.statechart-component', run = function()
  return {windows = {o.window {id = 'main', title = 'c', width = 300, height = 200, content = function()
    return o.column {key = 'panel', Collapsible {key = 'details', title = 'Details'}}
  end}}}
end}
'''
# Native handles in context (gap 1): a transient bus, and an undeclared one.
HANDLES = '''local o = require('ouro')
local m = o.machine
local link = m.create {
  id = 'link', initial = 'up', transient = {'bus'},
  context = function() return {bus = o.signal(0), other = o.signal(1), pings = 0} end,
  events = {PING = {}},
  states = {up = {on = {PING = {actions = m.assign {pings = function(c) return c.pings + 1 end}}}}},
}:actor {id = 'link'}
link:start()
return o.app {id = 'dev.ourokit.statechart-handles', run = function() return {windows = {}} end}
'''


def native_handles():
    """runtime.send, runtime.statecharts and the rollup work for an actor
    whose context holds native handles; they show as {"$h": type}."""
    with tempfile.TemporaryDirectory(prefix='ourokit-statechart-handles-') as directory:
        root = Path(directory)
        source = root / 'app.lua'
        source.write_text(HANDLES)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root), XDG_STATE_HOME=str(root / 'state'))
        process = subprocess.Popen([str(BINARY), 'run', str(source), '--dev', '--headless'],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            endpoint = development_path(root, process)
            time.sleep(.3)
            out, failed = send(endpoint, 'link', {'type': 'PING'})
            assert not failed and out['accepted'] is True and out['changed'] == ['pings'], out
            context = statecharts(endpoint, after=0, limit=0, actors=False, actor='link')['actor']['snapshot']['context']
            assert set(context['bus']) == {'$h'} and set(context['other']) == {'$h'} and context['pings'] == 1, context
            rows = statecharts(endpoint, after=0, limit=0, actors=False, rollup=True)['rollup']['actors']
            assert any(r['actor'] == 'link' for r in rows), rows
            assert process.poll() is None
        finally:
            process.terminate()
            process.communicate(timeout=10)
    print('PASS native handles: runtime.send, runtime.statecharts and the rollup show handles as {"$h": type}')


def send_robustness():
    """runtime.send cannot end the app, never holds up other clients, waits
    for the next commit when states are omitted, and stops when cancelled
    (second review M-2, M-6, L-4)."""
    with tempfile.TemporaryDirectory(prefix='ourokit-statechart-send2-') as directory:
        root = Path(directory)
        source = root / 'app.lua'
        source.write_text(QUIET)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root), XDG_STATE_HOME=str(root / 'state'))
        process = subprocess.Popen([str(BINARY), 'run', str(source), '--dev', '--headless'],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

        def counter():
            rows = statecharts(endpoint, after=0, limit=0, actors=False, rollup=True)['rollup']['actors']
            return next(r for r in rows if r['actor'] == 'counter')

        def background(arguments):
            box = {}
            def run():
                began = time.monotonic()
                result = call(endpoint, 'runtime.send', arguments)
                box.update(result=result, took=time.monotonic() - began)
            thread = threading.Thread(target=run, daemon=True)
            thread.start()
            return thread, box

        try:
            endpoint = development_path(root, process)
            time.sleep(.3)
            # M-2: wait.timeout_ms is bounded; nothing a client sends ends the app.
            for timeout, code in ((20000000000000, 'InvalidWaitTimeout'), (60001, 'InvalidWaitTimeout'),
                                  (-1, 'InvalidDevelopmentArgument')):
                out, failed = send(endpoint, 'counter', {'type': 'SET', 'n': 1},
                                   wait={'states': ['armed'], 'timeout_ms': timeout})
                assert failed and out['error']['code'] == code, (timeout, out)
            time.sleep(.5)
            assert process.poll() is None, 'runtime.send ended the app'
            out, failed = send(endpoint, 'counter', {'type': 'SET', 'n': 1}, wait={'states': ['idle'], 'timeout_ms': 60000})
            assert not failed and out['wait'] == {'matched': True}, out
            # L-4: without states the wait ends at the next commit, not at once.
            out, failed = send(endpoint, 'counter', {'type': 'SET', 'n': 2}, wait={'timeout_ms': 300})
            assert not failed and out['wait']['matched'] is False and 'WaitTimeout' in out['wait']['error'], out
            waiting, box = background({'actor': 'counter', 'event': {'type': 'SET', 'n': 3}, 'wait': {'timeout_ms': 5000}})
            time.sleep(.4)
            send(endpoint, 'counter', {'type': 'SET', 'n': 4})
            waiting.join(5)
            out = box['result']['structuredContent']
            assert out['wait'] == {'matched': True} and .3 < box['took'] < 2, (out, box['took'])
            # M-6: while one client waits, other clients are served at once,
            # and one of them can make the wait match.
            waiting, box = background({'actor': 'counter', 'event': {'type': 'SET', 'n': 5},
                                       'wait': {'states': ['armed'], 'timeout_ms': 8000}})
            time.sleep(.4)
            began = time.monotonic()
            row = counter()
            assert time.monotonic() - began < 1 and row['waits'] == 1 and row['observers'] == 1, row
            out, failed = send(endpoint, 'counter', {'type': 'ARM'})
            assert not failed and out['accepted'], out
            waiting.join(5)
            out = box['result']['structuredContent']
            assert out['wait'] == {'matched': True} and out['states'] == ['armed'] and box['took'] < 2, (out, box['took'])
            assert counter()['waits'] == 0 and counter()['observers'] == 0
            # Cancelling a waiting send ends its wait and drops its observer.
            send(endpoint, 'counter', {'type': 'DISARM'})
            stream = RpcStream(endpoint)
            stream.socket.sendall(record('tools/call', {'name': 'runtime.send', 'arguments': {
                'actor': 'counter', 'event': {'type': 'SET', 'n': 6}, 'wait': {'states': ['armed'], 'timeout_ms': 60000}}}, 'slow'))
            poll(lambda: counter()['waits'] == 1, 'the send never started waiting', timeout=5)
            assert counter()['observers'] == 1
            stream.socket.sendall(json.dumps({'jsonrpc': '2.0', 'method': 'notifications/cancelled',
                                              'params': {'requestId': 'slow'}}).encode() + b'\n')
            poll(lambda: (lambda r: r['waits'] == 0 and r['observers'] == 0)(counter()), 'the cancelled wait kept running', timeout=5)
            stream.close()
            assert process.poll() is None
            print('PASS runtime.send robustness: bounded wait timeout keeps the app alive; waits do not block other '
                  'clients; omitted states wait for the next commit; cancellation ends the wait and its observer')
        finally:
            process.terminate()
            _, stderr = process.communicate(timeout=10)
            assert b'panic' not in stderr and b'leaked' not in stderr, stderr


ROOT = Path(__file__).resolve().parents[1]
VISUALIZER = ROOT / 'tools/statechart-visualizer/app.lua'


def snapshot(endpoint, actor):
    return statecharts(endpoint, after=0, limit=0, actors=False, actor=actor)['actor']['snapshot']


def poll(predicate, message, timeout=20):
    deadline = time.monotonic() + timeout
    last = None
    while True:
        try:
            value = predicate()
        except (AssertionError, KeyError, StopIteration, ConnectionError, OSError) as error:
            value, last = None, error
        if value:
            return value
        assert time.monotonic() < deadline, (message, last)
        time.sleep(.1)


def native():
    """The stopwatch driven over the endpoint, watched by the visualizer."""
    with tempfile.TemporaryDirectory(prefix='ourokit-statechart-native-') as directory:
        root = Path(directory)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root), XDG_STATE_HOME=str(root / 'state'),
                   WAYLAND_DISPLAY=os.environ['OUROKIT_TEST_WAYLAND_DISPLAY'])
        processes, endpoints = [], []

        def launch(name, *args):
            with (root / f'{name}.stderr').open('w') as errors:
                process = subprocess.Popen([str(BINARY), 'run', *map(str, args)], env=env,
                                           stdout=subprocess.DEVNULL, stderr=errors)
            processes.append((name, process))
            endpoint = development_path(root, process, exclude=endpoints)
            endpoints.append(endpoint)
            return process, endpoint

        def reads(endpoint):
            return statecharts(endpoint, after=0, limit=0, actors=False)['reads']

        def live(endpoint):
            return 'connection.connected.live' in snapshot(endpoint, 'visualizer')['states']

        try:
            log = root / 'stopwatch.jsonl'
            stopwatch, sw = launch('stopwatch', ROOT / 'examples/stopwatch/ouro.json', '--dev', '--software',
                                   '--record', log)
            poll(lambda: snapshot(sw, 'stopwatch'), 'the stopwatch actor never started')
            _, viz = launch('visualizer', VISUALIZER, '--dev', '--software', '--', f'unix:{sw}')
            poll(lambda: live(viz), 'the visualizer never attached by push', timeout=60)
            time.sleep(1)
            # Idle: the attached visualizer makes no requests (only ours count).
            before = reads(sw)
            time.sleep(2)
            assert reads(sw) - before == 1, 'the visualizer polled while idle'

            # Drive the chart over the endpoint, no widget clicks.
            out, failed = send(sw, 'stopwatch', {'type': 'START'}, wait={'states': ['clock.running']})
            assert not failed and out['accepted'] and out['wait'] == {'matched': True}, out
            time.sleep(.35)
            out, failed = send(sw, 'stopwatch', {'type': 'LAP'})
            assert not failed and out['accepted'] and 'laps' in out['changed'] and len(out['changes']['laps']) == 1, out
            time.sleep(.2)
            out, failed = send(sw, 'stopwatch', {'type': 'STOP'}, wait={'states': ['clock.paused']})
            assert not failed and 'clock.paused' in out['states'] and {'banked', 'elapsed'} <= set(out['changed']), out
            state = snapshot(sw, 'stopwatch')
            context = state['context']
            assert 'clock.paused' in state['states'] and 'settings.closed' in state['states'], state
            assert context['elapsed'] == context['banked'] >= 500 and len(context['laps']) == 1, context
            assert 300 <= context['laps'][0]['total'] < context['elapsed'], context

            # The records reached the visualizer by push: it holds a frame per
            # stopwatch record, then goes quiet again.
            records = statecharts(sw, after=0, actors=False)['next']
            poll(lambda: snapshot(viz, 'visualizer')['context']['counts']['stopwatch'] >= records,
                 'the visualizer missed records', timeout=60)
            time.sleep(1)
            before = reads(sw)
            time.sleep(1.5)
            assert reads(sw) - before == 1, 'the visualizer kept requesting after STOP'

            # Replay reproduces the session driven through runtime.send.
            stopwatch.terminate()
            stopwatch.wait(timeout=10)
            endpoints.remove(sw)
            lines = [json.loads(line) for line in log.read_text().splitlines()[1:]]
            sent = [e['e']['type'] for e in lines if e.get('o') == 'dev']
            assert sent == ['START', 'LAP', 'STOP'], lines
            replay = subprocess.run([str(BINARY), 'replay', str(log), str(ROOT / 'examples/stopwatch')],
                                    capture_output=True, text=True, timeout=60, env=env)
            assert replay.returncode == 0 and replay.stdout.startswith(f'replay matched: {len(lines)} entries'), replay

            # The visualizer attached to itself, driven over its own endpoint.
            _, me = launch('self', VISUALIZER, '--dev', '--software', '--', 'self')
            poll(lambda: live(me), 'the visualizer never attached to itself', timeout=60)
            poll(lambda: snapshot(me, 'visualizer')['context']['counts']['visualizer'] >= 1,
                 'the visualizer never saw its own chart', timeout=60)
            out, failed = send(me, 'visualizer', {'type': 'SCRUB', 'value': 1})
            assert not failed and out['accepted'] and 'view.scrubbing' in out['states'] and out['changes']['cursor'] == 1, out
            out, failed = send(me, 'visualizer', {'type': 'LIVE'})
            assert not failed and 'view.following' in out['states'], out
            out, failed = send(me, 'visualizer', {'type': 'ATTACHED'})
            assert not failed and not out['accepted'] and out['reason'] == 'no_transition', out

            # Component machines by exact path, listed from mount: inspect
            # one before its first event, start it with runtime.send, then
            # the widget and the endpoint drive the same actor.
            component = root / 'component.lua'
            component.write_text(COMPONENT)
            _, comp = launch('component', component, '--dev', '--software')
            created = poll(lambda: snapshot(comp, 'collapsible@details'), 'the component was not listed at mount')
            assert created['status'] == 'created' and created['states'] == ['closed'], created
            out, failed = send(comp, 'collapsible@details', {'type': 'TOGGLE'}, wait={'states': ['open']})
            assert not failed and out['accepted'] and out['states'] == ['open'] and out['status'] == 'active', out
            tree = poll(lambda: inspect(env, comp, 'main')['windows'][0], 'no component window')
            node = next(n for n in tree['nodes'] if n.get('path') == 'panel/details/b')
            subprocess.run([str(BINARY), 'dev', 'input', str(comp), json.dumps(dict(
                window='main', token=tree['token'], pin=node['pin'], action='click', target='panel/details/b'))],
                env=env, check=True, capture_output=True, timeout=10)
            poll(lambda: snapshot(comp, 'collapsible@details')['states'] == ['closed'], 'the click did not reach the same actor')
            out, failed = send(comp, 'collapsible@details', {'type': 'TOGGLE'}, wait={'states': ['open']})
            assert not failed and out['accepted'] and out['states'] == ['open'], out

            # The overview on a real Notes session: three notes, one failing
            # write, a red unit and alarm; the alarm drills into its unit.
            for name, process in processes:  # Debug software rendering is slow: keep the CPU free.
                if name in ('visualizer', 'self') and process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            _, docs = launch('documents', ROOT / 'examples/documents/ouro.json', '--dev', '--software')
            notes = poll(lambda: snapshot(docs, 'notes'), 'the notes actor never started', timeout=60)
            first = notes['context']['next']  # Notes opens with an untitled note.
            failing = f'notes/document.{first + 1}'
            _, ov = launch('overview', VISUALIZER, '--dev', '--software', '--', f'unix:{docs}')
            poll(lambda: live(ov), 'the overview never attached', timeout=60)
            for title, path in (('Groceries', '/tmp/groceries.ournote'), ('Ideas', str(root / 'missing/ideas.ournote')),
                                ('Draft', None)):
                note = {'type': 'ADD', 'title': title, 'text': title.lower()}
                if path:
                    note['path'] = path
                out, failed = send(docs, 'notes', note)
                assert not failed and out['accepted'], out
            out, failed = send(docs, failing, {'type': 'SAVE'}, wait={'states': ['open.io.idle']})
            assert not failed and out['accepted'] and out['wait'] == {'matched': True}, out
            rollup = {r['actor']: r for r in statecharts(docs, after=0, limit=0, actors=False, rollup=True)['rollup']['actors']}
            documents = {f'notes/document.{n}' for n in range(first, first + 3)}
            assert documents <= set(rollup), rollup
            assert rollup[failing]['errors'] == 1 and 'write' in rollup[failing]['last_error']['message'], rollup
            assert rollup[failing]['parent'] == 'notes' and rollup[f'notes/document.{first}']['errors'] == 0, rollup
            assert 'open.io.idle' in rollup[f'notes/document.{first + 2}']['states'], rollup

            def node(label):
                tree = inspect(env, ov, 'main')['windows'][0]
                return tree, next(n for n in tree['nodes'] if n.get('label') == label)
            tree, row = poll(lambda: node('Open alarm 1'), 'no alarm row in the overview', timeout=60)
            assert any(n.get('label') == 'Open ' + failing for n in tree['nodes']), 'no unit tile'
            assert not any(n.get('label') == 'Open alarm 2' for n in tree['nodes']), 'one alarm only'
            assert 'screen.overview' in snapshot(ov, 'visualizer')['states']
            subprocess.run([str(BINARY), 'dev', 'input', str(ov), json.dumps(dict(
                window='main', token=tree['token'], pin=row['pin'], action='click', target=row['path']))],
                env=env, check=True, capture_output=True, timeout=10)
            state = poll(lambda: (lambda s: 'screen.unit' in s['states'] and s)(snapshot(ov, 'visualizer')),
                         'the alarm did not drill down', timeout=30)
            assert state['context']['selected'] == failing and state['context']['alarm'] == 1, state['context']
            assert 'view.scrubbing' in state['states'], state
            out, failed = send(ov, 'visualizer', {'type': 'ACK', 'id': 1})
            assert not failed and out['changes']['acked'] == {'1': True}, out
            out, failed = send(ov, 'visualizer', {'type': 'OVERVIEW'})
            assert not failed and 'screen.overview' in out['states'], out
            print('PASS statecharts native: stopwatch driven by runtime.send and replayed identically; '
                  'visualizer attached by push with no idle requests; visualizer attached to itself; '
                  'component machine addressed by instance path; overview alarm on a real Notes write '
                  'failure, rollup, drill-down and acknowledge')
        finally:
            for name, process in processes:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
                text = (root / f'{name}.stderr').read_text()
                assert 'panic' not in text and 'leaked' not in text, (name, text)


if __name__ == '__main__':
    main()
    send_and_push()
    send_robustness()
    native_handles()
    if os.environ.get('OUROKIT_TEST_WAYLAND_DISPLAY'):
        native()
