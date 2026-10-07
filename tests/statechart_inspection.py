#!/usr/bin/env python3
"""runtime.statecharts on a real headless development instance.

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
local chart = m.create {
  id = 'light', initial = 'red', context = {ready = true},
  events = {GO = {}, STOP = {}},
  guards = {ready = function(c) return c.ready end},
  states = {
    red = {on = {GO = {target = 'green', guard = 'ready'}}},
    green = {after = {[40] = 'red'}},
  },
}
local actor = chart:actor {id = 'signal'}
actor:start()
o.spawn(function()
  o.sleep(30); actor:send('GO')
  o.sleep(10); actor:send('STOP')
end)
return o.app {id = 'dev.ourokit.statechart-inspection', run = function() return {windows = {}} end}
'''


def records(endpoint, after=0, **extra):
    result = call(endpoint, 'runtime.statecharts', {'after': after, **extra})
    assert not result.get('isError'), result
    return result['structuredContent']


def main():
    with tempfile.TemporaryDirectory(prefix='ourokit-statecharts-') as directory:
        root = Path(directory)
        (root / 'app.lua').write_text(SOURCE)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(root))
        process = subprocess.Popen([str(BINARY), 'run', str(root / 'app.lua'), '--dev', '--headless'],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            endpoint = development_path(root, process)
            deadline = time.monotonic() + 8
            while True:
                out = records(endpoint)
                kinds = [(e['record']['kind'], e['record'].get('event', {}).get('type')) for e in out['records']]
                if ('transition', 'after.40.green') in kinds:
                    break
                assert time.monotonic() < deadline, kinds
                time.sleep(.05)
            entries = out['records']
            sequences = [e['sequence'] for e in entries]
            assert sequences == list(range(1, len(entries) + 1)), sequences
            times = [e['time_ms'] for e in entries]
            assert times == sorted(times), times
            started = entries[0]['record']
            assert started['kind'] == 'actor' and started['action'] == 'started' and started['actor'] == 'signal'
            graph = started['graph']
            assert graph['format'] == 'ouro.machine.graph' and graph['version'] == 1 and graph['id'] == 'light'
            assert any(t['guarded'] and t['event'] == 'GO' for t in graph['transitions'])
            by_event = {e['record'].get('event', {}).get('type'): e['record'] for e in entries[1:]}
            init, go = by_event['ouro.init'], by_event['GO']
            assert init['states'] == ['red'] and init['accepted'] == ['GO'], init
            assert go['handled'] and go['states'] == ['green'] and go['timers'][0]['action'] == 'started'
            assert go['microsteps'][0]['transitions'][0]['event'] == 'GO'
            stop = by_event['STOP']
            assert stop['rejected'] and stop['reason'] == 'no_transition', stop
            fired = by_event['after.40.green']
            assert fired['origin'] == 'timer' and fired['timers'][0]['action'] == 'fired' and fired['states'] == ['red']
            # Late attach: the live actor's start and latest record.
            assert [a['actor'] for a in out['actors']] == ['signal']
            assert out['actors'][0]['started']['graph']['id'] == 'light'
            assert out['actors'][0]['latest']['event']['type'] == 'after.40.green'
            # Cursor, paging and text mode.
            assert records(endpoint, out['next'])['records'] == []
            assert 'actors' not in records(endpoint, out['next'])
            page = records(endpoint, 0, limit=1, actors=False, text=True)
            assert page['next'] == 1 and len(page['records']) == 1 and 'actors' not in page
            assert json.loads(page['records'][0]['record'])['action'] == 'started'
            assert not page['dropped'] and page['first'] == 1
            print('PASS runtime.statecharts: lifecycle/transition/rejected/timer records, '
                  'accepted events, late-attach actors, cursor paging and text mode')
        finally:
            process.terminate()
            _, stderr = process.communicate(timeout=10)
            assert b'panic' not in stderr and b'leaked' not in stderr, stderr


if __name__ == '__main__':
    main()
