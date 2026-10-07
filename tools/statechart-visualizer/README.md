# Statechart plant

A development visualizer for [`ouro.machine`](../../design/statecharts.md) actors,
drawn as a process-plant HMI / P&ID. It is an ordinary Ourokit application built
on `ouro.drawing` paths, `ouro.canvas`, `ouro.stack`, `ouro.layout_builder`, Box
transforms and native `ouro.animation`. It uses no plugins or web views.

| Chart concept | Plant symbol |
| --- | --- |
| Atomic state | Tank. It fills with liquid while active. A final state is a double-walled tank and fills green. |
| Compound state | Vessel containing its children, with a header band. It is lit while active. |
| Parallel state | Compartments separated by a double bulkhead, side by side or stacked to fit the window |
| Transition | Orthogonally routed pipe with a flange at the source and a flow arrow at the target. The pipe is energized while its source is active. A taken transition turns amber and sends a pulse from source to target, one microstep after another. A state's targetless and self transitions share one recirculation loop that lists their events. |
| Guarded transition | Valve: green when open, red when closed, grey when the guard was not evaluated |
| `after` | Gauge in the tank's corner. It counts down while the timer runs and flashes when it fires. |
| `invoke` | Pump. The rotor spins while running. The casing turns red on error, green when done, and the pump stops with an × when cancelled. |
| External events | Inlet manifold with one nozzle per declared or handled event. A rejected event bursts red at the inlet. |
| Context | Tag faceplates. A tag gets an amber border when the last step changed it. |
| History | Event-log timeline: ticks coloured by origin, a scrub slider, step buttons and **Go live** |

Timers and invokes are also listed in the side panel.

## Run it

```sh
zig build -Dvulkan=false -Doptimize=ReleaseSafe   # use ReleaseSafe: Debug software rendering runs at ~1 fps
# In-process demo: runs fixtures/*.lua charts in real time, observes with ouro.machine.inspect
zig-out/bin/ouroctl run tools/statechart-visualizer/app.lua
# Attach to another app's development instance
zig-out/bin/ouroctl run tools/statechart-visualizer/feed.lua --dev   # or any app using ouro.machine
zig-out/bin/ouroctl run tools/statechart-visualizer/app.lua -- unix:$DEVELOPMENT_SOCKET
# Headless frames of real recorded streams (manual scheduler)
zig-out/bin/ouroctl storybook snapshot tools/statechart-visualizer/storybook.lua --output out
```

## Where the data comes from

All shapes are the inspection hooks in design/statecharts.md §10.
[`contract.lua`](contract.lua) is the only file that knows them:

- **Graph:** `chart:graph()`, format `ouro.machine.graph` v1. It supplies the
  states (type, parent, children, initial, `after`, `invoke`), the transitions
  (index, kind, targets, `guarded`) and the events. The actor `started` record
  carries it.
- **Records:** one `transition` record per processed event, rejected ones
  included, plus actor `started`/`stopped` records.
  [`history.lua`](history.lua) folds them into frames: the active configuration
  (`states` plus the root), the taken transition indices from `microsteps`,
  timers keyed by state and delay, pumps keyed by state and invoke ID, and the
  context and which fields it changed.

Three sources feed the same `ingest` function in [`app.lua`](app.lua):

1. **Headless frames:** [`scenario.lua`](scenario.lua) runs a fixture chart on
   `machine.manual_scheduler()`, whose virtual clock fills `time_ms`.
2. **In-process:** `ouro.machine.inspect` in the visualizer's own VM.
3. **Live attach:** see below.

## Live attachment

`--dev` instances now publish statechart records to the development endpoint:

```diagram
┌─────────────── app (--dev) ───────────────┐        ┌──────── visualizer ────────┐
│ ouro.machine actors                       │        │                            │
│   │ machine.inspect(fn), attached by the  │        │ ouro.mcp.call(socket,      │
│   ▼ first call, dropped when idle         │        │   'runtime.statecharts',   │
│ ouro.json.encode(record) ──► host ring    │◄───────│   {after=cursor,seed=…})   │
│   (1024 records, monotonic time_ms,       │  MCP   │ json.decode → ingest       │
│    per-actor started + latest record)     │        │ poll: 200 ms when idle,    │
│ runtime.statecharts attaches/seeds at a   │        │ immediately while a full   │
│ safe point, then reads the ring           │        │ page is returned           │
└───────────────────────────────────────────┘        └────────────────────────────┘
```

- `src/lua/statechart_inspector.zig` installs an inactive bridge in every
  source generation of a `--dev` instance. The first `runtime.statecharts`
  call attaches it to the active VM. It seeds every live actor from
  `machine.actors()`, `actor:snapshot()` and `actor.chart:graph()`, then
  subscribes `ouro.machine.inspect`. Each call renews the subscription. The
  next record after `keep_alive_ms` (default 30 s) without a call
  unsubscribes, so idle instances build no records. Production instances
  install nothing.
- `runtime.statecharts {after, limit, actors, seed, text, keep_alive_ms}`
  returns `{next, first, dropped, time_ms, seed, records = [{sequence, time_ms, record}], actors}`.
  `actors` holds each live actor's started record (with its graph) and its
  latest record, keyed by actor path. Root actors therefore stay visible
  across reload. Reattaching or reloading reseeds `actors` and bumps `seed`.
  The visualizer passes the last `seed` it saw and gets `actors` back only
  when that changed; a reseed of the same chart keeps its history.
- `text = true` returns records as JSON strings, because `ouro.mcp` converts
  at most 4096 values per reply.

Try it with any agent or the CLI through MCP `tools/call`:

```json
{"name": "runtime.statecharts", "arguments": {"after": 0, "limit": 20}}
```

The next step would be push instead of polling: a `resourceSubscriptions` URI
such as `ourokit-dev://statecharts` on the control server. That would let
`ouro.mcp.subscribe` follow the documented subscribe → acknowledge → read →
dirty-read discipline. The control server only supports `toolsListChanged`
today.

## Known limits

- Valves and times come from the records: `guards` (post-step outcomes for
  guarded transitions whose source is active) and `time_ms` (the scheduler
  clock: virtual on the manual scheduler, host monotonic otherwise). A seeded
  attach snapshot has no guard outcomes, so its valves stay grey until the
  next record. Running invokes at attach are read from the interpreter's
  private table; timers come from `actor:pending_timers()`.
- Headless snapshots cannot advance native animations, so stories pin the
  pulse and rotor phases explicitly.
- A window has fixed budgets of 256 widget instances and 512 scene commands.
  Paint commands of the same style are merged into local groups
  (`draw.compact`), labels are bare positioned text, and moving parts are small
  sprites. The real Notes chart uses about 100 instances and 250 commands.
- Software rendering needs an optimized build. A Debug `ouroctl` renders this
  window at about 1 fps; ReleaseSafe renders it at about 45 fps.
