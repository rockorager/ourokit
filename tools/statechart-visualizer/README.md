# Statechart visualizer

A development visualizer for [`ouro.machine`](../../design/statecharts.md)
actors, drawn in Harel / SCXML / Stately notation. It is an ordinary Ourokit
application built on `ouro.drawing` paths, `ouro.canvas`, `ouro.stack`,
`ouro.layout_builder`, Box transforms and native `ouro.animation`. It uses no
plugins or web views.

| Chart concept | Drawn as |
| --- | --- |
| Atomic state | Rounded rectangle labeled with its key, with `entry / action`, `exit / action` and `invoke: src` lines. Active states get an accent outline and a light fill. |
| Compound state | Rounded container with a title; children nest inside |
| Parallel state | Regions separated by dashed lines, each labeled |
| Initial / final | A filled dot with an arrow to the initial child; a double border for final states |
| Transition | Orthogonal arrow with an event pill: `EVENT [guard]`, `after 100ms`, `always`, `done.*`. Self and targetless transitions share a small loop. A taken transition turns orange and a pulse runs along it, one microstep after another. |
| Guard | The `[guard]` text: green when it passed, red when it failed, grey when not evaluated (`record.guards`) |
| `after` | Its pill counts down while the timer runs. Named delays show their name (`after slow`), with the evaluated duration only while the timer runs; durations come from the records' `ms` (and `pending_timers()` on late attach), so function delays count down too. Timers are keyed by their event. |
| `invoke` | A status chip on the `invoke:` line: running, done, error or cancelled |
| Events | Left panel: one pill per declared event, highlighted when accepted. An event whose guards need its payload to decide (`record.guarded`, or guard entries flagged `payload` or erroring on the bare event) is available with payload: highlighted, marked `…`, and it opens the payload editor. A rejected event flashes. Clicking a pill sends it (`runtime.send`, or the actor itself in-process); events with fields open a payload editor. |
| Context | Right panel: a tree with changed keys highlighted, plus running timers and invokes. Native handles (`{"$h": type}`) show as opaque `‹type›` values. |
| History | Timeline below: ticks colored by origin, a scrub slider, step buttons, Play for recordings and **Live** |

Light and dark palettes follow the app theme (`color_scheme`).

## System overview (ISA-101)

The window opens on an overview of the whole actor system, following ISA-101
"high-performance HMI" principles. Views form a hierarchy with breadcrumbs:

| Level | View |
| --- | --- |
| 1/2 | **Overview**: unit tiles, topology, alarm list |
| 3 | **Unit**: one actor's statechart, events, context, timeline (above) |
| 4 | **Record**: one step in full (event, payload, microsteps, timers, invokes, changed context, alarms) |

- **Units:** one tile per live actor: roots in columns, spawned children
  below their parent, component machines grouped by instance path. A tile
  shows path and chart, active leaf states, pending timers, running invokes and
  a 30-second event-rate sparkline. Placement follows first-seen order, so it
  is stable as records arrive. Clicking a tile opens its statechart.
- **Topology:** parent/child elbows; dashed traffic lines from `record.sent`
  and children reporting back (`done.actor.*`, `error.actor.*`); an I/O bus
  to external endpoints, which are every invoke `src` in the graphs and every
  spawned task `src`. A stub darkens while its invoke runs.
- **Grey by default; colour only when abnormal:**
  - red: failed invokes and children, `error.*`, `surface.failed.*` and
    `record.error` (action errors such as `YieldInAction`, guard or assign
    errors);
  - amber: a stuck state;
  - a brief amber flash: a rejected event.
- **Stuck states:** busy leaf states (with an invoke or `after`) alarm when
  the current dwell exceeds 10x their median dwell (at least 1 s, after 3
  samples). [`thresholds.lua`](thresholds.lua) changes this per chart or
  per state (`{max_ms = n}`, or `false` to stop watching). The `watch`
  region sleeps until the earliest deadline, so nothing runs periodically.
- **Alarms:** time, unit, severity and message, newest first. Unacknowledged
  alarms keep their unit coloured. **Ack** / **Ack all** acknowledge. Clicking
  an alarm opens its unit at the step that raised it, with a banner.

[`overview.lua`](overview.lua) folds the records into alarms, dwell samples,
rates and topology at ingest. This is a pure function of the records, so a
recording shows the same alarms. The display hierarchy and acknowledgements
are chart state (`screen`, `acked`). Agents get the same overview from the
app with `runtime.statecharts {rollup = true}`.

## Run it

```sh
zig build -Dvulkan=false -Doptimize=ReleaseSafe   # use ReleaseSafe: Debug software rendering runs at ~1 fps
# In-process demo: runs fixtures/*.lua charts in real time, observes with ouro.machine.inspect
zig-out/bin/ouroctl run tools/statechart-visualizer/app.lua
# Attach to any --dev app (its log prints "development socket: <path>")
zig-out/bin/ouroctl run examples/stopwatch/ouro.json --dev
zig-out/bin/ouroctl run tools/statechart-visualizer/app.lua -- unix:$DEVELOPMENT_SOCKET
# Attach to itself (it inspects its own visualizer chart)
zig-out/bin/ouroctl run tools/statechart-visualizer/app.lua --dev -- self
# Headless frames (manual scheduler, recorded streams)
zig-out/bin/ouroctl storybook snapshot tools/statechart-visualizer/storybook.lua --output out
# The visualizer's own chart, on a manual clock with fake services
(cd tools/statechart-visualizer && for t in charts overview client contract delays; do ../../zig-out/bin/ouroctl test ${t}_test.lua; done)
# A recorded session (design/statecharts.md §14): expand it, then scrub or play it
zig-out/bin/ouroctl replay ~/.local/state/ourokit/recordings/dev.ourokit.stopwatch.jsonl examples/stopwatch --records /tmp/stopwatch.records.jsonl
zig-out/bin/ouroctl run tools/statechart-visualizer/app.lua -- /tmp/stopwatch.records.jsonl
```

A recording holds inputs only. `ouroctl replay --records` replays it against
the app's charts and writes the §10 records it produced, graphs included,
which is what this tool draws. [`recording.lua`](recording.lua) parses the
file.

## Where the data comes from

All shapes are the inspection hooks in design/statecharts.md §10.
[`contract.lua`](contract.lua) is the only file that knows them:

- **Graph:** `chart:graph()`, format `ouro.machine.graph` v1, carried by the
  actor `started` record.
- **Records:** one `transition` record per processed event, rejected ones
  included, plus actor `started`/`stopped` records.
  [`history.lua`](history.lua) folds them into frames: the configuration,
  taken transitions from `microsteps`, timers, invokes, guards, and the context
  with its changed keys.

[`model.lua`](model.lua) holds that inspected data (append-only, rebuilt from
the app at any time). It is the sanctioned large-cache exception of design
§6: services only stage records in its inbox, and the chart's `RECORDS`
assign drains them. Everything about the session is in the `visualizer`
chart ([`charts.lua`](charts.lua)), one parallel chart:

```diagram
connection: starting ─┬─► in_process            (machine.inspect in this VM)
                      ├─► loading ─► loaded | failed   (a records file)
                      └─► connected{attaching ─ATTACHED─► live}
                              │ error NoPush ─► polling (re-enters every 200 ms)
                              └ other error ─► detached ─after 1s─► connected
view:       following ⇄ scrubbing ⇄ playing (after 500ms steps, stops at the end)
editor:     closed ⇄ open   (payload drafts; INJECT / SEND_PAYLOAD spawn 'inject')
screen:     overview ─SELECT/OPEN_ALARM─► unit ─RECORD─► record   (OVERVIEW, UNIT go back)
watch:      idle ⇄ waiting  (invoke 'watch' sleeps until the next stuck deadline)
```

Effects are injected services (`observe`, `follow`, `poll`, `load`,
`inject`, `watch`), so `charts_test.lua` runs the chart without sockets. Views are pure
functions of the chart and the model; there is no `o.signal` or
`ouro.stateful`. Each ingest batch is a `RECORDS` event that bumps `revision`.

## Live attachment: push

```diagram
┌──────────── app (--dev) ────────────┐            ┌──────── visualizer ─────────┐
│ actors ─► machine.inspect observer  │            │ connected (invoke follow):  │
│   (attached on demand) ─► ring      │ subscribe  │   ouro.mcp.subscribe(       │
│   1024 records, seed, reads         │◄───────────│     'ouro://statecharts')   │
│                                     │ updated    │   on ack / each update:     │
│ control server: one notification    │───────────►│   runtime.statecharts       │
│ per subscriber until the next read  │            │     {after, seed, text}     │
│                                     │◄───────────│   send RECORDS batch        │
└─────────────────────────────────────┘   fetch    └─────────────────────────────┘
```

- Notify-then-fetch: the endpoint sends `notifications/resources/updated`
  when records arrive, at most once until the client next reads.
  [`client.lua`](client.lua) fetches until `more` is false, skips an
  actor's `latest` once the cursor passed it (`latest_sequence`), and
  starts over when `epoch` changes (the app restarted behind the address). Nothing is
  sent, and neither process wakes, while the app is idle.
- Leaving `connected` cancels the invoke; scope cancellation closes the
  subscription socket. The subscription keeps the app's observer attached;
  closing it lets the observer detach after `keep_alive_ms`.
- A ring overflow past the cursor comes back as `dropped`. The client then
  reseeds from `actors` (the late-attach read) and the header counts the gap.
- Endpoints without the resource fall back to polling.
- Event pills call `runtime.send {actor, event}`. The input is labeled origin
  `dev`, so `ouroctl replay` reproduces sessions driven from here.
- The visualizer filters its own RECORDS/ATTACHED records when it inspects
  itself, so self-attach does not feed back.

`tests/statechart_inspection.py` checks this on real instances: the stopwatch
driven over the endpoint and replayed identically, no requests from an
attached visualizer while idle, records arriving without polling, a ring
overflow reseed, self-attach, and a real Notes session whose failed write
raises an alarm that drills into its unit.

Storybook `overview/*` stories use real Notes records
([`fixtures/notes_session.lua`](fixtures/notes_session.lua)): input logs
written by hand, filled in with the replayed expectations, and expanded with
`ouroctl replay <log> examples/documents --records`.

## Known limits

- A seeded attach snapshot has no guard outcomes, so guard text stays grey
  until the next record.
- Headless snapshots cannot advance native animations, so stories pin the
  pulse phase explicitly.
- A window has fixed budgets of 256 widget instances and 512 scene commands.
  Paint commands of the same style are merged (`draw.compact`) and pills are
  bare positioned text. Very large charts can exceed the scene budget.
- Layout is a layered placement with greedy pill placement; dense regions
  (many transitions between few states) can still crowd their pills.
- Software rendering needs an optimized build. A Debug `ouroctl` renders this
  window at about 1 fps; ReleaseSafe at about 45 fps.
