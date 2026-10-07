#!/usr/bin/env python3
"""runtime.statecharts on a real headless development instance.

Covers on-demand attachment with seeded late-attach state, the record
stream, idle detachment, and actors carried across a development reload.
Run after zig build: python3 tests/statechart_inspection.py
Needs XDG_RUNTIME_DIR-style private directories only; no compositor.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

from application_services import BINARY, call, development_path

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
            assert go['timers'][0]['time_ms'] == go['time_ms'], go
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
            # After reload the root actor stays visible under its path. (The
            # host does not yet call machine.carry, so its context restarts.)
            source.write_text(SOURCE.replace('REVISION', '2'))
            reload = subprocess.run([str(BINARY), 'dev', 'reload', str(endpoint)], env=env,
                                    capture_output=True, timeout=12)
            assert reload.returncode == 0, reload
            assert call(endpoint, 'runtime.diagnostics')['structuredContent']['generation'] == 2
            reloaded = statecharts(endpoint, after=resumed['next'], seed=2)
            assert reloaded['seed'] == 3 and [a['actor'] for a in reloaded['actors']] == ['signal'], reloaded
            assert reloaded['actors'][0]['latest']['origin'] == 'attach', reloaded
            after_reload, _ = wait_for(endpoint, lambda s: any(event(e) == 'GO' for e in s), reloaded['next'])
            assert all(e['record']['actor'] == 'signal' for e in after_reload)
            print('PASS runtime.statecharts: attach on demand with seeded actors, transition/rejected/timer '
                  'records, guard valves and clock, cursor and text mode, idle detach, actors kept by path across reload')
        finally:
            process.terminate()
            _, stderr = process.communicate(timeout=10)
            assert b'panic' not in stderr and b'leaked' not in stderr, stderr


if __name__ == '__main__':
    main()
