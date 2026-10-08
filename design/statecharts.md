# Statecharts as the application model

Status: Phases 0–1 done (GO). Phase 2 is shrunk: there is no native
interpreter. The interpreter stays in Lua and snapshots stay Lua tables.
Only three parts are native: chart validation at load, logical timers, and
the existing waiters and task scopes. Phase 3, the app-model integration in
Lua, is in progress. The implementation
lives in [`src/lua/machine.lua`](../src/lua/machine.lua) as `ouro.machine`;
tests are in [`tests/machine_test.lua`](../tests/machine_test.lua) and
[`tests/machine_native.py`](../tests/machine_native.py).
[`examples/documents`](../examples/documents), [`examples/contacts`](../examples/contacts),
[`examples/launcher`](../examples/launcher) and [`examples/stopwatch`](../examples/stopwatch)
are built on it.

The core idea: **active states own lifetimes, effects and windows, and the UI is
a function of the state snapshot.** Charts hold *all* application state,
including presentation state such as query text, selection and appearance.
Signals are not an application state mechanism (§6). Charts do not replace
plain functions, the view, or the native editor's per-keystroke state (§5).

## Goals

Status per goal: **met**, **partly** (what is missing is named), or **open**.
Test names are from `tests/machine_test.lua` unless a file is given.

| Goal | Met by | Proven by | Status |
| --- | --- | --- | --- |
| **G1** XState semantics and surface: map form, required `initial`, v5 internal and `reenter` rules, parallel `order` | §1 | 'order on a parallel state…'; 'self-targets re-enter only with reenter = true (XState v5)…'; 'review M5…'; 'parallel regions take the same event in one microstep…'; 'exit and entry order follow the least common compound ancestor' | met (no history states or delayed `send`, §1) |
| **G2** Active states own lifetimes: tasks, timers, I/O, windows and surfaces; leaving a state cancels them | §8, §0 Windows, §2 Runtime events | `machine_native.py` (exit and stop cancel sleeping work); 'after timers… are cancelled on exit'; 'invokes… exiting cancels them'; 'spawned tasks… are canceled with their owner state'; `http_native.py` (reload cancels requests); `desktop_native.py` 'launcher: layer surface follows the chart' | met |
| **G3** Charts hold all application state; the UI is a pure view of snapshots; plain functions compute | §6, §5, §7 | documents, contacts, launcher and stopwatch keep no app signals: `documents.py`, `contacts.py`, `launcher.py`, `stopwatch_test.lua` | met |
| **G4** Easy to reason about, for humans and agents, over fewer lines; an app can be written from this doc alone | §0, §4 Callback signatures, §11 | `examples/stopwatch`, first written from this doc alone by the review; `tests/stopwatch_test.lua` | met |
| **G5** One event model for widgets, shortcuts, commands, palette, MCP, activation and surfaces, with request/response | §2 (send results, `wait_for`, `deliver`, `machine.actions`), §7 | `bindings_test.lua`; 'send reports whether the event was taken…'; 'wait_for…'; 'actions derive MCP input schemas…'; `contacts.py` (MCP as chart events); `desktop_native.py` 'launcher: single instance toggles on activation', 'surface events: … close_requested decided by the chart' | met (a palette is bound buttons or options; there is no stock palette widget) |
| **G6** Agent-first dev loop: inspect states and records, live visualizer, deterministic record/replay, generated tests, reload that keeps state | §10 (records, Dev tools), §9, §8 Logical time, §14 | `statechart_inspection.py`; `tools/statechart-visualizer/storybook.lua` (`recording/*` stories draw a real session); 'records carry the scheduler clock and post-step guard valves'; `chart_reload.py`; 'reload hooks persist roots…'; `chart_replay.py` (real stopwatch, contacts, documents and launcher sessions replay identically; a changed chart diverges at its first step; generated tests fail on it); `replay_test.lua`; `examples/*/tests/*_paths_test.jsonl` (`ouroctl test examples`) | met: recordings under `--dev`/`--record`, `ouroctl replay` with divergence reports, logical clocks, generated paths (guard-aware, seeded by recordings) as `ouroctl test` files, visualizer scrubbing (§14). Generated paths are not emitted as Storybook stories |
| **G7** Performance at the real boundaries: few Lua–Zig crossings, per-field rebuild locality, cached views, unchanged text work; the interpreter stays in Lua and snapshots stay Lua tables | §6 Rebuild locality, Status | 'rebuild locality: typing in one document re-renders only its readers'; 'rebuild locality: fields, configuration and selectors'; 'views are cached per table…' | met: render counts and allocation are proven by tests; Lua–Zig crossings and text work by call-path analysis, not measured (performance is not measured yet, by decision) |
| **G8** No fixed limits on runtime objects; actors and components release native resources on stop and unmount | §8 Resources and capacities | `zig build test-stress` (1000 rows × 50 remounts, 10k actors, back to baseline); `component_scopes_test.lua` (300 rows); `statechart_capacity.py`; growth unit tests (§8) | partly: application windows (16), virtual-list and layout-builder snapshots, and clipboard requests are still fixed; test-stress currently fails on retained cancelled timers (§8) |
| **G9** Failures reach charts instead of crashing: `surface.failed`, atomic commits, `YieldInAction`, rejected events with reasons | §1 Algorithm, §2 Sending, Runtime events | 'guard errors leave the previous snapshot in place'; 'an eventless livelock fails without committing…'; 'guards, assigns and actions cannot wait, spawn or exit'; 'review M6…'; `desktop_native.py` 'launcher surface … failure', 'unbound role change: logged, last valid window kept' | met |
| **G10** Headless testability: `manual_scheduler`, `ouroctl test` settling, chart tests with fake services | §8 Tests, §0 Tests | `documents.py`, `contacts.py`, `launcher.py` (fake services); `stopwatch_test.lua`; `component_scopes_test.lua` 't:settle shows state changed from the test body' | met: native-scheduler tests run on a virtual logical clock (`t:advance`, §8); `replay_test.lua` |

## 0. Writing an app

[`examples/stopwatch`](../examples/stopwatch) is the smallest complete app,
first written from this document alone. Its shape:

```lua
-- charts.lua: behavior. machine.create is pure, so charts are made at load.
local machine = require('ouro').machine
local stopwatch = machine.create {
  id = 'stopwatch', type = 'parallel', order = { 'clock', 'settings' },  -- a parallel root
  context = { elapsed = 0, banked = 0, started_at = 0, laps = {}, max_laps = 5, draft_max_laps = 5 },
  states = {
    clock = { initial = 'idle', states = {
      idle = { on = { START = { target = 'running', actions = 'start' } } },
      running = { after = { [100] = { target = 'running', reenter = true, actions = 'tick' } },
                  on = { STOP = { target = 'paused', actions = 'stop' } } },
      paused = { on = { START = { target = 'running', actions = 'start' } } },
    } },
    settings = { initial = 'closed', states = { ... MAX_LAPS = machine.set('draft_max_laps', 'integer') ... } },
  },
  actions = {   -- machine.now() is the scheduler's logical clock (§8)
    start = machine.assign { started_at = function() return machine.now() end },
    tick = machine.assign { elapsed = function(c, e) return c.banked + (e.time_ms - c.started_at) end },
    stop = machine.assign(function(c)
      local elapsed = c.banked + (machine.now() - c.started_at)
      return { elapsed = elapsed, banked = elapsed }
    end),
  },
}

-- view.lua: a function of the snapshot that hands widgets event bindings (§7).
function M.content(sw)
  return function()
    local running = sw:matches('clock.running')
    return ouro.button { key = 'toggle', label = running and 'Stop' or 'Start',
      send = sw:event(running and 'STOP' or 'START') }
  end
end

-- app.lua
return ouro.app {
  id = 'dev.ourokit.stopwatch',
  run = function()
    local sw = charts.stopwatch:start { id = 'stopwatch' }   -- run is a task
    return { windows = { ouro.window { id = 'main', title = 'Stopwatch', content = view.content(sw) } } }
  end,
}
```

- **Charts** are created at module load. A root may be a compound state with
  `initial`, or `type = 'parallel'` with regions and an optional `order`.
- **Root actors start in a task.** `chart:start(options)` is
  `chart:actor(options):start()`. `start()` runs deferred effects and writes
  signals, so it needs the task phase. `run()` is a task: it may start
  actors and even wait on I/O before returning windows. So are widget
  callbacks, MCP action handlers and invokes. Module load is not. An actor
  that MCP actions share with the UI is created at load with
  `chart:actor { id = ... }`, which is render-safe, and started by whichever
  needs it first (contacts). Root actors live in application scope whichever
  task starts them (§8), until `stop()`, a final state, or source reload.
- **Give root actors stable ids.** Reload restores an actor only when the
  reload candidate creates one with the same id and chart id (§9). That is
  only actors created while the candidate runs: at module load or in `run()`.
  An actor created later, for example lazily in a callback, starts fresh.
- **Views** are content functions that read `actor:context()`, `matches()`
  and `can()`, and give widgets `actor:event(...)` bindings. Reads are
  tracked per field (§6). Content functions must not send events.
- **Windows.** A static `{ windows = { ... } }` behaves as usual: a close
  request closes the window, and closing the last window exits.
  - `send = actor` on a window routes its close request to the chart as
    `surface.close_requested.<id>`, and nothing closes until the declaration
    drops the window. A static list never drops it, so bind a static window
    only if the chart handles the request, for example by entering a state
    that exits.
  - For a surface that a state owns, return `windows = function() ... end`
    and declare the surface while `actor:matches('open')` (launcher, §12).
  - `{ windows = ..., send = actor }` binds the declaration as a whole. It
    reports only `surface.failed` when `windows()` fails, and changes no
    close behavior.
  - `on_close_request = actor:sender('QUIT')` on an unbound window is the
    callback form (documents, contacts).
- **Exiting.** `ouro.exit` is not allowed in actions (§1), so exit from an
  invoke: `exiting = { invoke = { src = 'exit', on_done = 'exited' } }`.
- **Tests.** Start actors with `scheduler = machine.manual_scheduler()` and
  drive time with `clock.advance(ms)` (§8). `ouroctl test` can mount the real
  view with `t:mount(view.content(actor))` and click through it
  (`tests/stopwatch_test.lua`).

## 1. Supported subset

We use SCXML semantics with an XState-like Lua surface. Supported:

| Feature | Surface | Notes |
| --- | --- | --- |
| Hierarchy | `states = { idle = {...}, saving = {...} }`, `initial = 'idle'` | `initial` is required on compound states, as in XState. |
| Parallel | `type = 'parallel'`, optional `order = {'io', 'lifecycle'}` | Every region is active at once. `order` sets region document order. |
| Final | `type = 'final'`, optional `output = fn` | Raises `done.state.<parent>`. A top-level final finishes the machine. |
| Guards | `guard = 'name' \| fn` | Pure: `(context, event, state) -> boolean`. |
| Field setters | `on = { QUERY = machine.set('query', 'string') }` | Assigns `e.value` to the field and declares `QUERY = { value = 'string' }`. |
| `assign` | `machine.assign(fn \| {field = value \| fn})` | The only way to change context. |
| `raise` | `machine.raise(event \| fn)` | Adds an internal event to the current macrostep. |
| `always` | `always = transition(s)` | Eventless transitions, checked after every microstep. |
| `after` | `after = { [ms] = transition }` | Integer milliseconds. Started on entry, cancelled on exit. |
| `invoke` | `invoke = { src, id?, input?, on_done?, on_error? }` | Work that lives exactly as long as its state. |
| Spawned children | `machine.spawn(chart \| fn \| 'actor', {id?, input?})`, `machine.stop(id)`, `send_to`, `send_parent` | Keyed child actors, such as one per document or tab, or one-shot tasks (§8). Ids default to `<chart or actor>.<n>`. |
| Entry/exit | `entry = action(s)`, `exit = action(s)` | Actions run in document order. Named actions in `actions = {...}` may be a list. |
| `on_done` | on compound/parallel states | Shorthand for `on = { ['done.state.<id>'] = ... }`. Not on the root: a finished machine is `done` (status, `wait_for`, `done.actor.<id>` to its parent), so `machine.create` rejects a root `on_done`. |
| Tags | `tags = {'busy'}` | Use `actor:has_tag('busy')` in the view. |

Not supported: **history states**, delayed `send`, `<data>`/`<script>`, and
deep or shallow history targets. The `in` guard is spelled `state.matches(id)`
inside a guard. Transition order within one state follows the event
descriptor: the exact type first, then dotted prefixes (`done.actor.*`), then
`*`.

### Region order

`states` is a map keyed by state name, as in XState, and `initial` is required
on compound states. Sibling order matters only between parallel regions,
because a compound state has exactly one active child. For regions it decides:
- the order regions are entered;
- the order they exit, which is the reverse;
- which transition wins a conflict, since the earlier region's does.

XState gets this order for free, because JavaScript objects keep insertion
order. Lua tables do not, so a parallel state can declare it:

```lua
open = { type = 'parallel', order = { 'io', 'lifecycle' }, states = {
  io = { initial = 'idle', states = { ... } },
  lifecycle = { initial = 'active', states = { ... } },
} }
```

`order` must list exactly the region keys: no missing, unknown or duplicated
keys, and no holes. Only parallel states accept it. Violations fail at
`machine.create` and name the state. Without `order`, regions and all other
children sort by key. Document order, as listed by `chart:graph()`, is
depth-first in that sibling order.

Transition targets resolve as follows:
- `'sibling'`: a sibling of the source.
- `'.child.grandchild'`: a descendant of the source.
- `'#full.id'`: an absolute ID.

Transition domains follow XState v5 (`getTransitionDomain`):
- **Without `reenter`**, a transition whose targets are its source or the
  source's descendants acts *inside* the source. The source, compound or
  parallel, is neither exited nor re-entered: its entry and exit actions don't
  run, and its own timers and invokes keep going. Everything active below it
  is exited and the target configuration entered. For a parallel source, every
  region restarts, and untargeted regions go to their initial states.
- **A plain self-target** (`RESET = 'editing'` on `editing`) therefore does
  not restart the state. On an atomic state it only runs actions; on a
  compound state it resets the children to `initial`.
- **With `reenter = true`**, the source is exited and re-entered, restarting
  its timers and invokes. Use it for polling loops:
  `after = { [5000] = { target = 'polling', reenter = true } }`.
- **Otherwise** the domain is the least common compound ancestor of source and
  targets.
- A transition with no `target` only runs its actions.

```lua
states = {
  -- Self-target without reenter: stays in `polling`; the 5 s timer fires once.
  -- With reenter = true: exits and re-enters `polling`, so the timer restarts.
  polling = { after = { [5000] = { target = 'polling', reenter = true, actions = 'fetch' } } },
  -- Parallel source targeting a descendant: `open` is not exited (its entry,
  -- exit, timers and invokes are untouched), but both regions restart:
  -- SAVE lands in io.saving and `life` goes back to its initial `a`.
  open = { type = 'parallel', on = { SAVE = '.io.saving' }, states = {
    io = { initial = 'idle', states = { idle = {}, saving = {} } },
    life = { initial = 'a', states = { a = { on = { NEXT = 'b' } }, b = {} } },
  } },
}
```

### Algorithm

The prototype follows the SCXML algorithm without history:

- **Microstep:** compute the exit set from each transition's domain, which is
  the source, or the LCCA of source and targets when the transition re-enters.
  Exit those states in reverse document order and run their `exit` actions.
  Run the transitions' actions. Enter the entry set in document order. This
  includes the default initial states of compound targets and every region of
  any parallel state entered.
- **Selection:** for each atomic state in document order, walk outward and take
  the first enabled transition. Remove conflicts: when two exit sets intersect,
  the transition whose source is a descendant wins. Otherwise the earlier
  transition in document order wins.
- **Macrostep (run to completion):** take one external event, then repeat:
  take `always` transitions while enabled, and when none are, take the next
  raised internal event. External events sent while a macrostep is running,
  including events sent by effects, queue behind it. More than 1000
  microsteps is an error (an eventless livelock).
- **Atomic commit:** a macrostep is computed on copy-on-write data. If a guard,
  assign or expression throws, the previous snapshot stays and the error
  reaches the sender. The error affects only that event: events already
  queued behind it stay queued and are processed, and the first error is
  raised once the queue drains.
- **Effects run after commit:** plain function actions, timers, invokes and
  child messages run after commit. Function actions run in order. Each sees the
  context as it was when it was reached in the macrostep. Timers and invokes
  start at the end of the macrostep, only for states that are still active.
  This matches SCXML's end-of-macrostep `<invoke>`. Their cancellation is
  recorded when the state exits. `actor:stop()` cuts the remaining effects
  short: no action, timer, invoke or child message runs for a stopped actor,
  even one queued by the macrostep that stopped it.
- **Guards, assigns, expressions and function actions cannot wait.** They
  run as native atomic sections. Inside one, `ouro.sleep`, `ouro.exit`,
  `ouro.spawn`, `ouro.spawn_app` and every Ouro I/O wait (files, D-Bus,
  HTTP, portals, notifications) fail before they touch the task. When the
  section ends, it raises `YieldInAction: action 'report' (document.open on
  EDIT) called Ouro I/O, which waits or spawns; move async work into an invoke
  or a spawned actor`. It raises even if the function swallowed the
  operation's own error. A failing guard or assign aborts the macrostep with
  nothing committed. Function actions and entry actions run after commit, so
  the transition stands. Waiting work belongs in an `invoke` or a spawned task.
  Function actions run in the sender's task, such as a button callback, and the
  commit can unmount that button and cancel the task mid-wait. The documents
  port hit this before the rule existed: the session save ran in an exit action
  and was cancelled by the closing dialog. Its notifications also waited on
  D-Bus from inside actions.

## 2. Events

An event is a table with a string `type` and flat payload fields:
`{ type = 'RENAME', title = 'Draft' }`. `send('SAVE')` is shorthand for
`{ type = 'SAVE' }`. Payloads are copied on send, and guards and actions get a
read-only view.

### Naming

- **Event names are scoped per actor.** `send` always targets an actor. There
  is no global bus and no global namespace, so two charts may both have
  `SELECT`.
- **Runtime events use reserved lowercase dotted prefixes**
  (`machine.reserved_prefixes`): `after.`, `done.`, `error.`, `ouro.` and
  `surface.`. Charts may *handle* them in `on`, for example
  `['surface.closed.main']`, `['done.actor.*']` or `['surface.*']`. A chart
  that declares one in `events` or `machine.set` fails at `machine.create`.
  `send` refuses them, because only the runtime delivers them.
- **Dotted user names group events**, for example `search.query` and
  `search.clear`. Prefix descriptors such as `['search.*']` match them.
- **Charts declare their events.** The declared set is the union of three
  sources: the explicit `events` schemas, `machine.set` setters, and every
  plain event name some state handles. With `machine.strict = true`, the
  default, `send`, `can` and `actor:event` raise `UnknownEvent` for anything
  else, so typos fail loudly. Non-strict, `send` returns `false,
  'undeclared'`. The host sets it: strict under `--dev`, in `ouroctl test`
  and in Storybook; non-strict for production `ouroctl run`, with or without
  `--mcp` or `--headless`. Headless test scripts opt in with
  `machine.strict = true`.

### Schemas

```lua
events = {
  SAVE = {},
  EDIT = { field = 'string', value = 'string' },
  RESIZE = { position = 'number', animate = 'boolean?' },
}
```

The field types are `string`, `number`, `integer`, `boolean`, `table` and `any`.
`integer` accepts integral floats (`6.0`, as spinboxes and sliders send) and
normalizes them to integers, like the MCP numeric rule. A trailing `?` marks an
optional field. Events with a schema reject missing or
mistyped fields and undeclared fields (`InvalidEvent`). Declared events without
a schema accept any payload. `machine.set(field, type)` declares
`{ value = type }`. That is the payload value widgets send (§7), so
`on = { QUERY = machine.set('query', 'string') }` needs no other glue.

### Sending and delivering

- `actor:send(event)` returns `accepted, reason`, synchronously, because the
  macrostep runs to completion inside the call. `reason` uses the record
  vocabulary: `no_transition`, `stale`, `done`, `stopped` (or `undeclared`
  when non-strict). An event sent while the same actor is mid-macrostep, for
  example from its own effect, is queued and returns `nil, 'queued'`. Guard
  and assign errors raise.
- `actor:deliver(event [, origin])` is the runtime's entry point: surface
  lifecycle events, timers, children. Reserved types are allowed and there is
  no schema or declaration check. It uses the same queue and macrostep, and
  `origin` labels the inspection records (`'surface'`, default `'runtime'`).
- `machine.wait_for(actor, predicate, {timeout = ms})` is XState's `waitFor`.
  It parks the running task until `predicate(snapshot)` holds and returns that
  snapshot, waking on the actor's commits, never by polling. It raises
  `WaitTimeout`, or `WaitEnded` when the actor stops or finishes without
  matching. Only tasks may wait: MCP handlers, callbacks, invokes and spawned
  tasks. Inside actions it raises `YieldInAction`. Cancelling the waiting task
  drops its subscription and timer.

### Runtime events

| Type | Raised when |
| --- | --- |
| `ouro.init`, `ouro.restore` | The actor starts, from scratch or from a snapshot. |
| `after.<ms>.<state>` | A timer fires. Carries `state` and the entry `token`. |
| `done.invoke.<id>` / `error.invoke.<id>` | Invoked work returns or throws. Carries `output` or `error`, plus `state` and `token`. |
| `done.state.<id>` | A compound or parallel state completes. Carries `output`. |
| `done.actor.<child>` | A spawned child finishes: a chart reaches its final state, or a task returns. Carries `id`, `output` and the child's former `index`. |
| `error.actor.<child>` | A spawned task throws. Carries `id`, `error` and `index`. |
| `surface.<kind>.<window>` | A window or layer surface declared with `send = actor` is mapped, has a close requested, is closed, or fails (`reason`, `message`). Delivered with origin `surface`. |

`done.actor.*` and `error.actor.*` events for a child that is no longer listed,
because it was stopped or cancelled with its owner, are rejected as `stale`.
A timer or invoke event whose token does not match the current entry of its
state is rejected as `stale`.

### Commands, shortcuts and MCP are events

Actions, commands, shortcuts, palette entries and MCP calls are all external
events with schemas. `actor:accepted()` lists the declared events the current
configuration would take, guards included. `machine.actions` derives MCP tools
from the same declarations:

```lua
actions = machine.actions(book, {
  RenameContact = { event = 'RENAME', description = 'Rename a contact',
    errors = { no_transition = 'ContactNotFound' },          -- rejection reason -> error code
    output = function(snapshot, e) return { contact = ... } end, output_schema = {...} },
  GetContacts = { description = 'Read the address book',     -- no event: a read
    wait = function(s) return not machine.matches(s, 'loading') end, timeout = 5000,
    output = function(snapshot) return { contacts = ... } end, output_schema = {...} },
}, { before = function(actor) ... end })                      -- may return ouro.action_error
```

`inputSchema` comes from the chart's event schema. The handler sends the
event and turns a rejection into `ouro.action_error(code, {event, reason})`.
It can optionally `wait_for`, then returns `output(snapshot, event)`. The
actor may be a function, which is resolved per call; it then needs
`options.chart`.

## 3. Snapshots

A snapshot is immutable. A new table is created only when something changed:

```lua
{
  machine  = 'document',          -- chart id
  status   = 'active',            -- 'active' | 'done' | 'stopped'
  states   = { 'open', 'open.io', 'open.io.idle', 'open.lifecycle', 'open.lifecycle.active' },
  context  = { title = 'Untitled', text = '', revision = 0, saved_revision = 0 },
  children = {                    -- spawned children
    'document.1', 'document.2',    -- array part: ids in spawn order
    ['document.1'] = { machine = 'document', states = {...}, context = {...}, ... },  -- child snapshots
    ['notify.7'] = { status = 'active', src = 'notify', owner = 'open' },            -- a running task
  },
  output   = nil,                 -- set when status == 'done'
  -- runtime bookkeeping, not part of the persisted form:
  entries  = { ['open.io.saving'] = 7 }, serial = 7,
}
```

- **Stable state IDs.** An ID is the dotted path of keys from the root, such as
  `open.io.saving`. The root is `''`. IDs do not depend on sibling order, so
  changing a parallel state's `order` changes no ID.
  `matches(id)` rejects unknown IDs, so typos fail loudly.
- **Active configuration.** `states` lists every active state except the root,
  including compound ancestors and every parallel region, in document order.
- **Parents read children, as in XState v5.** `snapshot.children[id]` is the
  child's current snapshot as a read-only view. It is readable from the view
  (`actor:snapshot().children`), from guards, assigns and expressions (the
  third `state` argument's `state.children`), and from the pure
  `chart:transition`. `ipairs` and `#` still give ids in spawn order.
  `machine.matches(child, 'open.io.saving')` tests a child's configuration.
  When a child commits, its new snapshot replaces its entry in the parent's
  snapshot, so parent guards and pure transitions see children as of the
  start of their macrostep. No parent signal is written: a render that reads
  `snapshot.children[id]` depends on that child's own signals (§6).
- **Serializable.** `actor:persist()` returns `machine`, `status`, `states`,
  `context`, `output` and children as `{ id, snapshot }`. It deep-copies plain
  data and fails on functions or cycles. The result round-trips through
  `ouro.json`. It includes `serial`, so default child ids (`<chart>.<n>`)
  stay unique after a restore or reload. Spawning also skips any id that is
  still taken, which covers snapshots persisted before `serial` was. Entry
  and child tokens are not persisted. Restoring re-enters states without
  running entry actions, then restarts their timers and invokes.
- **Child tokens.** Each spawn records a token, and a `done.actor.<id>` or
  `error.actor.<id>` carrying an earlier child's token is rejected as
  `stale`. A late event from a stopped child cannot remove a re-spawned child
  with the same id.
- **Rejected events do not write.** If no transition is taken, the snapshot
  table is unchanged and the signal is not written.

## 4. Context

Context changes only through `assign`. Everything else reads it through
**read-only views**: guards, expressions, function actions, `actor:context()`
and the view. A view is native userdata over the underlying table. Indexing,
`#`, `pairs` and `ipairs` work and recurse into nested tables. Any write raises
`machine context is read-only`. Two views of the same table compare equal.

Views are userdata because the app sandbox has no `setmetatable` and Lua 5.5
`<const>` is binding-only. As a result, `type(view) == 'userdata'` and
`next(view)` does not work. Use `machine.plain(view)` for a deep, serializable
copy.

`assign` produces a new shallow copy with the updates applied.
`machine.unset` deletes a field. Updates that return views are unwrapped.
Nested tables are replaced, never mutated in place: copy-on-write, by
convention.

### Callback signatures

`ctx` and `event` are read-only views (`event` is the triggering event; for an
entry action it is the event of the transition that entered the state).
`state` is `{ matches = fn(id), children = view }`. `state.matches` rejects
unknown ids, and `state.children` maps child ids to child snapshots (§3).

| Callback | Called as | Returns |
| --- | --- | --- |
| guard: `guard = fn` or `guards = { name = fn }` | `fn(ctx, event, state)` | a boolean |
| `machine.assign(fn)` | `fn(ctx, event, state)` | a table of updates, `{ field = value }`; `machine.unset` deletes a field; `nil` changes nothing |
| `machine.assign { field = value_or_fn }` | `fn(ctx, event, state)`, per field | the field's new value; non-function values are used as is |
| `machine.set(field, type)` | — | assigns `event.value` to `ctx[field]` |
| function action, in `actions`, `entry`, `exit` or a transition | `fn(ctx, event, actor)`, after commit | ignored |
| expressions: `raise(fn)`, `send_parent(fn)`, `send_to(id_fn, event_fn)`, `spawn(src, { id = fn, input = fn })`, invoke `input`, final `output` | `fn(ctx, event, state)` | the value |
| `context = fn` | `fn(input)` once, at `chart:actor` | the initial context |
| invoke `src`, or `actors = { name = fn }` | `fn(input, send)` as a task | its output becomes `done.invoke.<id>`'s `output`; a throw becomes `error.invoke.<id>`'s `error` |
| `machine.spawn(fn_or_name, ...)` task | `fn(input)` as a task | `done.actor.<id>` / `error.actor.<id>` |
| `machine.component(chart, render)` | `render(self, props)` | a description or nil |
| `machine.wait_for(actor, pred)` | `pred(snapshot)` | a boolean |
| `machine.selector(fn)` returns `sel` | `sel(data, ...)` calls `fn(data, ...)` | `fn`'s result, memoized while `data` and the arguments are raw-equal |
| `machine.actions` specs | `before(actor)`; `output(snapshot, event)` | `nil` or an `ouro.action_error`; the output table |

`machine.now()` (the logical clock, §8) is readable in all of the
callbacks above that run inside a macrostep. Guards, assigns, expressions and
function actions are atomic: they cannot wait, spawn or exit (§1). Function actions get the actor for reading and for
sending; a send from an action queues behind the current macrostep and
returns `nil, 'queued'`. Each sees the context as it was when it was reached
in the macrostep, not the final context.

## 5. Continuous values stay native

Pointer position, hover, drag deltas, scroll offsets, animation progress, caret
and selection, IME preedit and the editor's per-keystroke buffer stay native.
They are not states and not context. A chart sees committed values, and owns
them from then on:
- `QUERY { value }` from a text field's change;
- `RESIZE { position }` when a split moves;
- `SELECT { value }` when a list or tab selection changes.

Phase 5 native widget charts (button hover/pressed, focus, menus, modal editing)
are internal, compiled in Zig and allocation-free. They are not app charts.

## 6. Layering: charts hold all application state

**Decision.** Every piece of application state lives in a chart's context or
configuration. That includes presentation state such as query text,
selection, the open tab, appearance, and a collapsible's open flag. Signals
are not an app-facing state mechanism. The only signals left are the hidden
per-field ones each actor keeps so views rebuild precisely (§6). This reverses an interim decision to keep signals for
presentation state. The reasons:
- one model to learn and reason about;
- replay, reload, the inspector and MCP only see what is in charts;
- "presentation" state leaks into behavior anyway: the launcher's `ACTIVATE`
  guard depends on the query.
Code that is easy to reason about matters more than fewer lines. The ceremony
is handled with setters, value widgets and component machines.

```diagram
┌──────────────────────────────┐
│ Domain charts (headless)     │  document: io.saving, lifecycle.confirming
│ drivable by tests and MCP    │  contacts: loading, sync, lifecycle
└──────────────┬───────────────┘
               │ snapshot.children / send_to
┌──────────────▼───────────────┐
│ UI charts                    │  notes: tabs, selection, split, close walk
│ (app-level presentation)     │  launcher: query, selected, open/hidden
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐      ┌───────────────────────────┐
│ Component machines           │      │ plain functions +         │
│ (per mounted instance)       │      │ machine.selector          │
│ collapsible open, hover menu │      │ validate, encode, rank,   │
└──────────────┬───────────────┘      │ derive (`dirty`, results) │
               │ snapshots            └─────────────▲─────────────┘
┌──────────────▼───────────────┐                    │
│ view(snapshots) → windows,   │────────────────────┘
│ dialogs, widgets             │
└──────────────┬───────────────┘
               │ events: actor:event bindings, send =, senders
               ▼
          actor:send
```

- **Domain charts are headless.** The document chart knows `io.saving` and
  `lifecycle.confirming`. It does not know that a dialog exists.
- **UI charts hold presentation state and modes.** Examples:
  - the launcher's `query` and `selected` (`QUERY = machine.set('query', 'string')`);
  - notes' selected tab and split position;
  - contacts' appearance (`light` / `terminal`).
  App-wide presentation state lives here, not in signals.
- **Component machines hold per-instance UI state** (below).
- **The view does the mapping.** `doc:matches('open.lifecycle.confirming')`
  mounts the confirm dialog. A layer surface exists because
  `launcher:matches('open')`. Windows report back with `surface.*` events.
- **Computation stays in plain functions,** memoized with `machine.selector`
  when a guard and the view share it. `dirty` is `revision ~= saved_revision`;
  the launcher's results are `results(c)`, computed once per context for both
  the `ACTIVATE` guard and the list.

Where state goes:

| State | Where | Why |
| --- | --- | --- |
| Note text, path, save progress | domain chart (`document`) | lifecycle, async I/O, rules |
| Which tab is selected, split position | UI chart (`notes`) | app-wide, persisted with the session |
| Launcher query and highlighted row | UI chart (`launcher`), `machine.set` | the `ACTIVATE` guard depends on it |
| Light / terminal appearance | UI chart (contacts' `appearance`) | one source of truth for the theme and MCP |
| A collapsible's open flag, a menu's hover row | component machine | local to one mounted instance |
| Caret, selection, IME preedit, scroll offset | native widget | continuous values (§5) |
| Search results, `dirty`, labels | `machine.selector` / plain function | derived, never stored |

Rule of thumb: if you would have reached for a signal, add a context field
(`machine.set` for the common "store the widget's value" case). If what can
happen next depends on what happened before, make it a state. If it is a
calculation on current data, make it a (memoized) function.

### Rebuild locality: per-field tracking

A render, or a guard that `can()` evaluates during one, depends on exactly
the snapshot fields it reads. Retained subtree skipping therefore keeps
working: a keystroke in one document re-renders that document's editor, not
the tab bar or anything that reads `notes`. Each actor keeps hidden signals,
with no new public API:

| Signal | Read by | Written |
| --- | --- | --- |
| one per top-level context key, created on first read | `ctx.key` through `actor:context()` or `snapshot().context` | when that key's value changes; copy-on-write shares unchanged values, so a raw-equal write invalidates nothing; added and removed keys included |
| configuration | `matches`, `has_tag`, `states`, `status`, `started`, `output`, `can`, `handles`, `accepted`, `snapshot().states/status/output` | when the active configuration, status or output changes, and on start/stop |
| membership | `actor:children()`, `#`/`ipairs` of `snapshot().children` | when the children ids change |
| all (the snapshot signal) | `pairs`/`#` over a context, other snapshot fields | on every own commit: the coarse fallback |

- **Children.** `snapshot().children[id]` returns the child's own tracked
  snapshot view, so `children[id].context.title` depends on that child's
  `title` signal alone. A child commit updates the parent's snapshot for
  guards and pure transitions but writes no parent signal.
- **Guards.** `can()` runs guards on the tracked views, so a Save button
  depends on configuration plus exactly the fields its guard reads.
- **Selectors.** `machine.selector` records the signals a computation read and
  replays them on a cache hit, so every caller depends on the inputs.
- **Granularity** is the top-level context key: `ctx.doc.title` depends on
  `doc`. Keep independently changing data in separate keys.
- **Coarse fallback.** Iterating a context (`pairs`, `#`) depends on
  everything. `actor:snapshot()` itself costs nothing; its fields are tracked
  as they are read. `wait_for` and records do not use signals.
- **Cached views.** One read-only view per raw table, held in a native
  weak-keyed table, so repeated reads and iterating a 200-row list don't
  allocate. The semantics are the same in development and production.
- **Snapshots stay Lua tables.** The interpreter stays in Lua (see Status),
  so snapshots stay plain tables with copy-on-write, identity-comparable
  values. Native pieces (chart validation, logical timers) must not change
  that, because the per-key identity diff depends on it.

`tests/machine_test.lua` counts renders in the 'rebuild locality' tests, and
both fail on the previous one-signal-per-actor design.

### Components: per-instance machines instead of ouro.stateful

```lua
local Collapsible = machine.component(machine.create {
  id = 'collapsible', initial = 'closed',
  context = function(props) return { title = props.title } end,  -- input = props
  states = { closed = { on = { TOGGLE = 'open' } }, open = { on = { TOGGLE = 'closed' } } },
}, function(self, props)
  return ouro.column { key = 'box',
    ouro.button { key = 'toggle', label = self:context().title, send = self:event('TOGGLE') },
    self:matches('open') and props.children or nil,
  }
end)

Collapsible { key = 'details', title = 'Details', ... }
```

- One actor exists per mounted keyed instance. It is created when the
  instance mounts, with `input = props`, so the context can read initial
  props. Keys preserve it across reorders, and unmounting forgets it.
- It **starts on its first event**, in the callback's task, because
  initializers and renders may not write signals or schedule work. Entry
  effects of the initial state therefore run at that first event.
- Its root scope hangs under the instance scope of the callback that first
  needed one, so its timers and invokes end when the instance unmounts. Root
  scopes open lazily, so a component without `after`/`invoke` never opens one.
  (Instance teardown retires VM-owned child scopes, so components with
  timers tear down cleanly.)
- Component actors are not carried across reload (`persist_roots` skips
  them), and `machine.actors()` drops them once their scope is gone.

## 7. Widgets send events

`actor:event(event [, field])` returns a plain binding, `{ actor, event,
field }`, validated at render like `can()`. Widgets take one in `send`, their
main trigger. Every `on_*` hook also accepts one, and so do `commands`
entries and a text input's `on_command` map. The binding is lowered in
`src/lua/controls.lua`, which wraps the native `box`, `row`, `column`,
`split` and `text_editor` constructors. Recipes such as button, tabs and
select pass bindings through to them.

```lua
ouro.button { key = 'save', label = 'Save', send = doc:event('SAVE') }
ouro.text_input { key = 'query', text = c.query, send = launcher:event('QUERY') }
ouro.split_view { key = 'split', position = c.split, send = notes:event('RESIZE', 'position'), ... }
ouro.tabs { key = 'tabs', selected = c.selected, send = notes:event('SELECT'), on_close = notes:event('CLOSE_TAB'), tabs = ... }
ouro.box { key = 'scrim', commands = { close = launcher:event('CLOSE') }, shortcuts = { Escape = 'close' }, ... }
ouro.text_input { ..., on_command = { submit = launcher:event('ACTIVATE'), cancel = launcher:event('CLOSE') } }
ouro.menu_button { key = 'more', label = 'More', items = {
  { key = 'save', label = 'Save', send = doc:event('SAVE') },
} }
```

- **Activations** (`on_press`, button and menu item `send`, `on_cancel`,
  `commands`) send the event as is. Unless `enabled` is set, the widget is
  enabled while `actor:can(event)` holds. A refused command is left out with
  its shortcuts, so the key falls through to outer scopes as if unbound. A
  refused dialog `on_cancel` leaves Escape unhandled.
- **Value hooks** (`on_change`, `on_select`, `on_activate`, `on_interaction_change`, `on_scroll`, drops; `send` on
  text input, switch, checkbox, slider, select, spinbox, listbox, tabs, split
  view, collapsible) send a copy of the event with the new value in
  `field`, which defaults to `value`, matching `machine.set`. The view reads
  the value back from the actor's context: `text = c.query`. Unless `enabled`
  is set, value widgets (accordion included) are enabled while
  `actor:handles(type)` holds, that is while some active state has a
  transition for the event at all, guards ignored. An input disables while
  its state takes no edits, for example while closed. Checking can() with the
  current value would fail for guards such as documents' "the edit changes
  something" and lock the input. `split_view` has no native disabled state;
  it simply stops reporting position changes.
- **Tracking.** `can()` and `handles()` read the actor's configuration signal,
  and `can()`'s guards read field signals (§6). Recipes lower at
  composition time, and a direct primitive lowers where it is declared, so
  either way the enclosing build tracks the read and enablement follows the
  chart.
- `send` and the classic hook on one widget are an error. Functions remain an
  escape hatch for imperative calls, not a way to hold state.
- `actor:sender(event)` still returns a function, for windows and direct calls.

The enabled state and the action have one source of truth. A disabled button
and a rejected MCP call fail for the same reason, and the inspector shows that
reason.

Some imperative calls must stay in callbacks for now: `ouro.start_drag`, and
anything else that needs real press provenance. They report failures as events
(`REPORT { message }`).

## 8. Active states own task scopes

Each actor opens a root scope on first need, at its first timer, invoke or
task. A spawned child's root scope is a child of its parent's root scope. Each state entry with `after` or `invoke`
work opens one scope under the actor's root. Timers and invokes run inside it,
and exiting the state closes it. A finished or stopped actor closes its root,
and with it everything below. The interpreter goes through a small scheduler
seam:

```lua
scheduler.open(parent)           -- actor start: parent actor's root (or nil); state entry: the actor's root
scheduler.run(scope, fn)         -- invoke: run fn as a task in the scope
scheduler.after(scope, ms, fn)   -- after: spawn sleep(ms) then fn in the scope
scheduler.close(scope)           -- exit, done or stop: cancel the scope's subtree
```

- **Native (`machine.default_scheduler`, `kind = 'native'`).** These are the
  private open, spawn, close and alive closures from `src/lua/scopes.zig`.
  They are passed to the embedded chunk and never installed on `ouro`.
  Closing a scope cancels its tasks. Sleeping timers and in-flight invokes
  unwind at the next safe point, so code after the `sleep` never runs and
  to-be-closed values close. `tests/machine_native.py` checks this for state
  exit and for `actor:stop()` with a nested child. Per-entry tokens still
  reject any `after.*` or `done.invoke.*` event from an older entry. With
  native scopes nothing stale should arrive; the check also guards forged
  events.
- **Where the root scope hangs.** A root actor's scope is application scope,
  like `spawn_app`, through the binding's `open('application')`. An actor
  started from a widget callback or an MCP action handler outlives that task
  until `stop()`, its final state, or source reload. Earlier, parenting the
  root under the calling task left a Lua-opened scope under the per-call MCP
  action scope, and the process panicked when the call returned; the contacts
  port found this, and `tests/machine_native.py` now covers it. Where
  application spawns are unavailable (Storybook, reload candidates), the root
  falls back to the running task's scope. Generation reload retires every
  scope. Never-started work is discarded on close, so rapid toggling reuses
  slots. Capacities are covered under Resources and capacities below.
- **One-shot tasks.** These are XState's `spawnChild(fromPromise)`.
  `machine.spawn(fn_or_actor_name, {id?, input?})` lists the task under
  `snapshot.children` and runs `fn(input)` in its own scope. That scope sits
  under the **owning state's** scope:
  - the transition's domain, or its source when there is no target;
  - the entered state, for entry actions;
  - for exit actions, the nearest ancestor that stays active after the
    microstep, or the actor root (never a state that exits in the same step).
  A return delivers `done.actor.<id> { output }`; a throw delivers
  `error.actor.<id> { error }`. `stop(id)` or leaving the owner state removes
  it from `children` and cancels it natively. Use this for work whose result
  is just an event, such as Open… (a chooser and reads) or a notification.
- **Token fallback (`machine.token_scheduler`).** Used where a Lua state has
  no `Vm`, so the binding is nil. Work runs in application scope (`spawn_app`,
  else `spawn`), and closing only drops delivery. A cancelled request still
  runs to completion; only its result is ignored.
- **Tests (`machine.manual_scheduler()`).** It returns a plain table whose
  fields are functions, so call them with a dot: `clock.advance(ms)` fires due
  timers in time order on virtual time, `clock.run_tasks()` runs queued invokes
  and spawned tasks, and `clock.pending()` returns the timer and task counts.
  `clock.now` is the virtual time and `clock.open_scopes` counts live scopes,
  including actor roots. `ouroctl test`
  forbids wall-clock sleeps, and the sandbox has no `coroutine` library, so
  invokes run to completion when they run.
- **Effects run in the sender's task, not in a state scope.** That is why
  function actions are atomic (§1).
- **Logical time.** Every scheduler has a clock (`scheduler.clock()`, in
  ms). The default scheduler's is a **logical clock** (`machine.clock`,
  built by `machine.logical_clock`):
  - It reads one instant per external input (§14): entering an input syncs
    it, and it stays frozen for the macrostep and its effects. Guards,
    assigns, records, `pending_timers()` and `machine.now()` agree.
  - `after` timers sit in one queue ordered by deadline, then start order.
    `deadline = clock when started + delay`. A firing runs *at its
    deadline*: the clock reads the deadline while it is processed, even if
    the host woke late. Every timer due by wall time fires before the next
    external input is processed. A timer started while one fires counts from
    that deadline, so periodic ticks never drift.
  - One native wake task (a scope from `scopes.zig` and one `ouro.sleep`)
    sleeps until the earliest deadline; an earlier timer replaces it. Closing
    a state's scope (exit or stop) removes its timers from the queue then,
    not at their deadline: they are tombstoned and swept once tombstones are
    half the queue, keeping order. Per-entry tokens still guard delivery.
  - **Live** (the Wayland host, `ouroctl run`, including `--headless`), the
    clock follows the host's monotonic time between inputs.
  - **Virtual** in deterministic hosts (Storybook playback and `ouroctl
    test`, where wall-clock sleeps are disabled): the host sets
    `machine.virtual_clock` and only `machine.advance(ms)` moves time.
    `t:advance(ms)` in `ouroctl test` advances and settles the mounted UI.
    `manual_scheduler()` keeps its own virtual clock, and replay uses one
    per generation (§14).

  The order of firings and their instants is a function of the inputs and
  their times, so a recording replays exactly. The queue and the clock are
  Lua over the native wake task: one crossing per armed deadline, not per
  timer. Porting the queue to Zig is possible if profiling asks for it.
- **`after` delays are constants.** They are the integer keys of the `after`
  table, fixed when the chart is created; a delay computed from context is
  not supported. Use a fixed tick that re-enters its state
  (`{ target = 'running', reenter = true }`) and compute from the clock
  below, or one state per delay.
- **A millisecond clock for apps.** `machine.now()` returns the logical time
  of the scheduler running the current macrostep, and `actor:now()` the
  actor's scheduler clock. Both work in guards, assigns, expressions and
  actions. Outside a macrostep `machine.now()` reads the default clock.
  Timer events carry `time_ms`, their fire time (the deadline). The clock is
  virtual under `manual_scheduler`, in `ouroctl test` and in replay, so tests
  and recordings stay deterministic. The stopwatch computes
  `elapsed = banked + (now - started_at)` instead of counting ticks
  (`tests/stopwatch_test.lua`, `tests/replay_test.lua` 'a live logical clock
  fires late wakes at their deadlines…').

An invoke `src` is `function(input, send) ... return output end`. It runs as an
Ouro task and may yield on Ouro I/O. `send` delivers events to the machine
while the state is still active, for callback-style sources. A throw becomes
`error.invoke.<id>` with the error value.

### Resources and capacities

Goal G8: the number of live actors, components, signals, scopes and tasks is
not capped, and stopping or unmounting gives their native resources back at
once, not when the garbage collector runs.

**What `actor:stop()` releases:**
- It makes a final commit, then releases the actor's hidden signals (the
  snapshot, configuration, membership and every per-key signal) through the
  runtime's private `release(signal)`. No new key signals are created
  afterwards. A released signal reads its last value untracked and raises
  "signal was released" on write.
- It closes the actor's root scope, which opens lazily, only once an `after`
  or `invoke` needs one. Closing cancels every state scope below it: suspended
  coroutines unwind, logical timers are removed, in-flight kernel operations
  are cancelled, and their slots drain before reuse.
- Stopping a never-started actor only sets `status = 'stopped'`. `stop()` is
  idempotent and safe after the scope is already gone.

**What a component unmount releases:** `machine.component` returns
`render, function() actor:stop() end`, and the instance tree calls the second
function exactly once when the keyed instance leaves (application model,
`ouro.stateful`). Everything above then happens deterministically. Cancelling
the instance scope also retires any Lua-opened child scopes beneath it rather
than panicking, and so does ending an MCP action. A remount starts fresh.

**Capacities.** Configured sizes are initial sizes. Growth happens while a
commit, build or reload is *prepared*, so commit itself never fails. Slots
that the kernel or a suspended Lua continuation points at grow in chunks that
never move (`core.StableSlots`).

| Object | Grows | Landed in |
| --- | --- | --- |
| Signal graph: signals, subscription edges, readers, pending reads | on demand, while a commit is validated | 7d20b81 |
| Actor hidden signals | released on `stop()` and component unmount | 247bcd0, ff9d0e4 |
| Scheduler scopes, resources and tasks | on demand; reconcile and reload reserve scopes while preparing | de18a08 |
| Lua task slots, logical timers | chunked slots, timer heap | earlier |
| io_uring operation slots, whole-file reads, module loader, MCP calls, stdio | stable chunks; a full submission ring is flushed early, not an error | 19073d0 |
| HTTP requests (was 16) | stable chunks | 2c7c299 |
| Per-window budgets: instances, render objects, semantic nodes and text, pointer bindings, buttons, text inputs, list boxes, animations, scene commands (was 256 nodes, 512 commands), UI build storage, prepared reload builds | while a build is prepared; large trees have linear repaint, allocation, retirement and inspection paths | be20adb |
| D-Bus connections (8), calls (128), subscriptions (64), owned names (64); audio watchers (8) | stable chunks | a93ad61 |

**Still fixed, not by design (open):**
- application windows (16): wayring sizes its object tables from it when it
  connects;
- per-build virtual list snapshots (32 lists, 256 materialized rows) and
  layout-builder snapshots (128), which are copied by value;
- clipboard requests (16).

**Fixed by design.** These limits guard against hostile input, protocol
abuse or pathological depth. They do not count live objects:
- HTTP, D-Bus, file and module byte limits (`max_bytes`, `max_header_bytes`,
  module size);
- MCP receive buffers (64 KiB per call) and JSON value depth and count;
- widget nesting (32), build stabilization passes, Lua nesting and stack depth;
- inbound D-Bus method calls from peers (128);
- the platform input-event queue;
- compositor-mirrored outputs and workspaces, and mirrored PipeWire objects;
- damage regions, which merge beyond 8 rectangles.

**Proof:**
- `zig build test-stress` (`tests/capacity_stress.lua`) has two tests:
  '1000 component rows mount and remount 50 times' and '10000 actors created
  and stopped'. Both check that instances, render objects, scopes, signals,
  callbacks and the Lua heap return to baseline, including while the stopped
  actors are still referenced. It takes about 50 s in Debug, using the
  `t:resources()` test API. Known regression: it currently fails, because
  the logical clock (abbcdcd) keeps cancelled timers; the interpreter thread
  has the report.
- `tests/component_scopes_test.lua` has these tests:
  - 'capacity: a list of 300 component machines mounts' (about 80 rows used
    to fail with "cannot append box descriptor");
  - 40 rows remounted 20 times;
  - 3000 create/stop cycles.
  Before 7d20b81, it failed with "signal capacity exceeded".
- `tests/statechart_capacity.py` keeps 3000 actors in a headless app. It used
  to fail at cycle 65.
- Unit tests:
  - the scope-growth test in `src/lua/scopes.zig`;
  - 'reconcile plans … at capacity' and 'reconcile grows instance and render
    storage during preparation' (`src/ui/instance/tree.zig`);
  - 'operation slots grow past their initial capacity and a full ring is
    flushed early' (`io_uring.zig`);
  - the module loader loading nested modules with `module_capacity` 1;
  - 'HTTP requests owned by a retired state scope …', now with 20 requests;
  - 'stopped statechart actors release their hidden signals at once'
    (`src/app/source_generation.zig`).

## 9. Reload keeps state

`chart:restore(persisted, { renames = { ['old.id'] = 'new.id' } })` maps a
snapshot from an older chart onto the new one:

1. Rename each old ID, then fall back to the nearest surviving ancestor.
2. Build a legal configuration. In each compound state, choose the child that
   contains a wanted state, otherwise its `initial`. Parallel states keep every
   region.
3. Carry context over field by field, keeping old values whose type still
   matches the new initial context (or that the new context lacks).
4. `chart:actor { snapshot = mapped }` re-enters without entry actions and
   restarts timers and invokes.

The host keeps root actors across source reload with three hooks, and the
host side belongs to the scopes thread:

1. In the live VM, `machine.persist_roots()` returns `entries, skipped`. The
   entries are `{id, machine, snapshot}` for every started, active root actor
   except component actors. `skipped` lists `"id: error"` for actors whose
   context cannot be persisted; those start fresh.
2. In the candidate VM, `machine.carry(entries)` runs before the source.
   Creating a root actor whose `id` and chart id match an entry restores it
   through `chart:restore`, using the actor option `renames`. Children go
   through their own chart's `restore`; a child whose fresh context needs
   input keeps its old context.
3. After the candidate commits, `machine.release()` starts the held work.

Carry only reaches actors the candidate creates while it runs, that is at
module load or in `run()`. `machine.release()` drops entries nobody claimed,
so an actor created later (lazily in a callback, say) starts fresh.

Restored state is visible immediately, so the candidate's UI builds from it.
Restored timers and invokes start when the candidate commits, skipping states
exited since then. A failed candidate starts nothing. `actor:restored()` tells
app code to skip one-time setup, for example documents not re-opening its
saved session.

## 10. Inspection hooks

### Static graph: `chart:graph()`

Plain, JSON-encodable data, computed once per chart:

```lua
{
  format = 'ouro.machine.graph', version = 1, id = 'document', root = '',
  states = {   -- document order; the root is first with id ''
    { id = 'open.io.saving', key = 'saving', type = 'compound',  -- atomic|compound|parallel|final
      parent = 'open.io', depth = 3, children = { 'open.io.saving.choosing', 'open.io.saving.writing' },
      initial = 'open.io.saving.choosing', final = false,
      after = { { delay = 500, event = 'after.500.open.io.saving' } },
      invoke = { { id = 'write', src = 'write' } },    -- src is the actor name, or 'function'
      entry = { 'snapshot_save' }, exit = {}, tags = { 'busy' }, description = nil },
  },
  transitions = {  -- document order; index is stable for the chart
    { index = 12, source = 'open.io.idle', event = 'SAVE', kind = 'event',
      -- kind: event | always | after | done | invoke.done | invoke.error
      targets = { 'open.io.saving' },    -- nil for transitions that only run actions
      guard = 'can_save', guarded = true, actions = { 'snapshot_save' }, reenter = false },
  },
  events = { { type = 'EDIT', fields = { field = 'string', value = 'string' } } },
}
```

### Live records: `actor:observe(fn)` and `machine.inspect(fn)`

`actor:observe(fn)` sees one actor. `machine.inspect(fn)` sees every actor,
including spawned children. Both return an unsubscribe function, and observer
errors are logged without breaking the machine. `machine.actors()` lists live
actors, so a late-attaching tool can call `actor:snapshot()`,
`actor.chart:graph()` and `actor:pending_timers()`. The last returns
`{state, delay, event, token, time_ms}` per running `after` timer, so gauges
can resume counting down.

There is one record per processed event, including rejected ones:

```lua
{
  kind = 'transition', actor = 'notes/document.2', machine = 'document', sequence = 14, commit = 203,
  time_ms = 81234,           -- scheduler clock: virtual for manual_scheduler, host monotonic otherwise
  -- sequence counts this actor's records; commit is the global order in which
  -- snapshots committed. Records are emitted after their effects, so a child's
  -- record can arrive before the parent record that caused it: sort by commit.
  origin = 'external',       -- external | timer | invoke | child | init | restore | stop
  event = { type = 'SAVE' },
  handled = true, rejected = false, reason = nil,  -- reason: no_transition | stale | done | stopped
  microsteps = {
    { event = 'SAVE', transitions = { { index = 12, source = 'open.io.idle', targets = { 'open.io.saving' }, event = 'SAVE', guard = nil } },
      exited = { 'open.io.idle' }, entered = { 'open.io.saving', 'open.io.saving.choosing' } },
  },
  exited = { 'open.io.idle' }, entered = { 'open.io.saving', 'open.io.saving.choosing' },
  timers  = { { action = 'started', state = 'open.io.saving', delay = 500, event = 'after.500.open.io.saving', token = 9, time_ms = 81234 } },
  -- timer action: started (+ time_ms) | fired | cancelled
  invokes = { { action = 'started', state = 'open.io.saving.choosing', id = 'choose', src = 'choose', token = 10 } },
  -- invoke action: started | done | error (+ error) | cancelled
  children = { { action = 'spawned', id = 'document.3', machine = 'document' } },
  -- child action: spawned | stopped | done | error (+ error); tasks carry src instead of machine
  actions = { 'snapshot_save' },   -- action names in execution order
  states = { ... },                -- configuration after the step
  status = 'active',
  context = { ... },               -- plain deep copy of the context after the step
  guards = { { index = 12, passed = true }, { index = 14, passed = false, error = '...' } },
}
```

`guards` are valve states for the visualizer. They cover every guarded
transition whose source is active after the step, evaluated against the
committed snapshot. Event transitions see a bare `{type = event}`, `after`
transitions their timer event, and `always` transitions `{type = 'ouro.always'}`.
A guard that throws, for example because it reads a payload field, is
`passed = false` with its `error`. `index` maps to
`chart:graph().transitions[].index`.

Lifecycle records are `{ kind = 'actor', action = 'started', actor, machine,
parent, graph, time_ms }` and `{ kind = 'actor', action = 'stopped', actor,
machine, time_ms }`.
Records are built only while an observer is attached. They answer questions
like "why is this app waking up when idle?" through timers that are still
started, and "why is Save disabled?" through rejected events and guards.

### Dev tools: `runtime.statecharts` and the plant visualizer

**`runtime.statecharts`** is a tool on the `--dev` endpoint, called through
MCP `tools/call`. Production instances install nothing
([application model](../docs/application-model.md)).

```json
{"name": "runtime.statecharts", "arguments": {"after": 0, "limit": 20}}
```

- **On-demand attach.** Nothing is observed until the first call. It attaches
  a `machine.inspect` observer at a safe point and seeds `actors`. For every
  live actor it gives the started record, including its graph, plus a
  synthetic `origin = 'attach'` record of the current snapshot. Running timers
  and invokes come from `pending_timers()` and `pending_invokes()`.
- **`keep_alive_ms`** (default 30,000). Each call renews the observer. The
  first record after that long without a call detaches it, so an idle
  instance builds no records.
- **Seeds.** A reload or re-attach reseeds `actors` and increments `seed`. Pass
  the last `seed` you saw to get `actors` back exactly when it changed. Root
  actors stay visible across reload.
- **Records.** They are JSON-encoded in the VM, stamped with host monotonic
  `time_ms`, and kept in a 1,024-record ring. A call returns `{next, first,
  dropped, time_ms, seed, records = [{sequence, time_ms, record}], actors}`
  after the `after` cursor. Records include `guards` (valve outcomes),
  `time_ms` and `accepted` (the declared events the actor would take).
  `text = true` returns records as JSON strings, for clients such as
  `ouro.mcp` that convert at most 4,096 values per reply.

**The plant visualizer** ([`tools/statechart-visualizer`](../tools/statechart-visualizer/README.md))
draws actors as a process-plant diagram:
- states are tanks and vessels, and transitions are pipes;
- guards are valves, `after` timers are gauges, and invokes are pumps;
- context fields are tag faceplates;
- a history timeline can be scrubbed.

It reads only the graph and records described above.

```sh
zig build -Dvulkan=false -Doptimize=ReleaseSafe   # Debug software rendering runs at ~1 fps
zig-out/bin/ouroctl run tools/statechart-visualizer/app.lua                        # in-process demo charts
zig-out/bin/ouroctl run tools/statechart-visualizer/app.lua -- unix:$DEV_SOCKET   # attach to any --dev app
zig-out/bin/ouroctl storybook snapshot tools/statechart-visualizer/storybook.lua --output out
```

When attached, it polls `runtime.statecharts`: every 200 ms while idle, and
again immediately whenever it receives a full page. It also loads a recorded
log (§14) and scrubs it step by step. Open: push delivery through a resource
subscription instead of polling.

## 11. API summary (prototype)

```lua
local machine = ouro.machine
local chart = machine.create { id, initial, context, states, on, guards, actions, actors, events, ... }
chart:graph()                      chart:initial(input)      chart:transition(snapshot, event)
chart:can(snapshot, event)         chart:restore(persisted, {renames, input})
local actor = chart:actor { input, scheduler, snapshot, charts, id, renames, lazy, scope }   -- create (render-safe)
local actor = chart:start { ... }  -- chart:actor(options):start()
actor:start()  actor:stop()  actor:send(event) -> accepted, reason  actor:deliver(event, origin)
actor:sender(event)  actor:event(event [, field])
actor:matches(id)  actor:can(event)  actor:has_tag(tag)  actor:accepted()
actor:snapshot()  actor:context()  actor:states()  actor:status()  actor:started()  actor:restored()
actor:output()  actor:child(id)  actor:children()  actor:persist()  actor:observe(fn)
machine.assign  machine.set  machine.raise  machine.spawn  machine.stop  machine.send_to  machine.send_parent
machine.wait_for(actor, pred, {timeout})  machine.selector(fn)  machine.actions(actor, specs, opts)
machine.component(chart, render)  machine.matches(snapshot, id)  machine.plain(v)  machine.raw(view)  machine.unset
-- machine.matches raises for state ids unknown to the snapshot's chart;
-- machine.raw(view) returns the table behind a read-only view (identity checks).
actor:handles(type)  actor:pending_timers()  actor:pending_invokes()
machine.inspect(fn)  machine.actors()  machine.strict  machine.reserved_prefixes
machine.persist_roots()  machine.carry(entries)  machine.release()
machine.default_scheduler  machine.token_scheduler  machine.manual_scheduler()  machine.native_scopes
machine.now()  actor:now()  machine.advance(ms)  machine.clock  machine.virtual_clock  machine.logical_clock(opts)
machine.recorder(write, opts)  machine.replay(log, opts) -> report  machine.replay_text(report)
machine.paths(chart, opts)  machine.paths_log(chart, result)  machine.charts()
```

`chart:actor` computes the initial snapshot, which may include initial
`assign`s, and keeps it with the actor's hidden signals (§6). It is safe in
a component initializer. `start()` runs the deferred effects and must run in
the task phase, like any signal write. `status()` is `'created'` until then.
Reads (`matches`, `can`, `context`, `snapshot`) go through the actor's hidden
per-field signals, so a mounted build rebuilds when the fields it read change
(§6).

## 12. Sketches

### Documents (implemented)

There are two charts. `notes` is the application: open documents, selection,
the split, and the close-window walk. `document` is spawned once per open note.

```lua
document = machine.create {
  id = 'document', initial = 'open',
  events = { EDIT = {field='string', value='string'}, SAVE = {}, SAVE_AS = {}, CLOSE = {},
             CANCEL = {}, DISCARD = {}, REPORT = {message='string'} },
  states = {
    open = { type = 'parallel', order = { 'io', 'lifecycle' },
      on = { EDIT = { {guard='invalid_edit', actions='report_edit'}, {guard='changes', actions='apply_edit'} } },
      states = {
        io = { initial = 'idle', states = {
          idle   = { on = { SAVE = 'saving', SAVE_AS = {target='saving', actions=assign{save_as=true}} } },
          saving = { initial = 'choosing', entry = 'begin_save', states = {      -- bytes + revision at save start
            choosing = { always = {target='writing', guard='has_path'},
                         invoke = { src='choose', on_done={target='writing', actions=...},
                                    on_error={ {target='#open.io.idle', guard='canceled'},
                                               {target='#open.io.idle', actions='report'} } } },
            writing  = { invoke = { src='write', on_done={target='#open.io.idle', actions='saved'},
                                    on_error={target='#open.io.idle', actions='fail'} } },
          }},
        }},
        lifecycle = { initial = 'active', states = {
          active     = { on = { CLOSE = { {target='confirming', guard='unsafe'}, {target='#closed'} } } },
          confirming = { initial = 'prompt', on = { CANCEL = {target='active', actions=send_parent('CLOSE_CANCELED')} },
            states = {
              prompt   = { on = { SAVE = {target='awaiting', guard='idle'}, DISCARD = {target='#closed', guard='idle'} } },
              awaiting = { always = { {target='#closed', guard='saved_clean'}, {target='prompt', guard='idle'} } },
            }},
        }},
      }},
    closed = { type = 'final', output = function(c) return { path = c.path } end },
  },
}
```

- `dirty(c)` is a plain function: `c.revision ~= c.saved_revision`. A save that
  finishes after newer edits records `saved_revision` from its snapshot, so the
  document stays dirty. There are no serial numbers or `save_active` identity
  checks.
- The dialog's Save is the same `SAVE` event. `io.idle` starts saving and
  `lifecycle.prompt` moves to `awaiting` in one microstep, because both
  parallel regions take it. While a save is running, `can('SAVE')` is false.
  That replaces `begin_save`'s "Save already in progress" error and the
  `enabled = not d.saving` checks.
- `CLOSE_WINDOW` moves `notes` into `running.closing`. Its entry captures the
  session (each child's path and the selected path) from
  `state.children`. Then `walking` decides with pure `always` transitions: with
  no dirty or saving child it goes to `quitting`. Otherwise it goes to
  `prompting`, selecting the first unsafe child and sending it `CLOSE`.
  `done.actor.document.*` re-enters `walking` but not `closing`, so the
  capture survives. That needs the default transition, not `reenter = true`;
  the first version of the port got this wrong. A child's `CANCEL` sends
  `CLOSE_CANCELED`, which returns to `open`. `quitting` invokes the session
  save, which then exits.
- Notifications and Open… are spawned tasks. `report` assigns the error and
  spawns `notify`. `OPEN` spawns `open` (the chooser, which needs only
  `parent`, not press provenance, plus the reads), and its `done.actor.open.*`
  sends one `ADD` per note. Drops and activation URIs use `OPEN_URIS` and the
  `read` task.
- The view maps `doc:matches('open.lifecycle.confirming')` to the dialog and
  `doc:matches('open.io.saving')` to disabled Save buttons. The compositor
  close request is just `notes:sender('CLOSE_WINDOW')`.

### Layer-shell launcher

```lua
launcher = machine.create {
  id = 'launcher', initial = 'hidden', context = { query = '', entries = {}, index = 1 },
  events = { TOGGLE = {}, QUERY = {text='string'}, MOVE = {delta='integer'}, ACTIVATE = {}, CLOSE = {} },
  actors = { scan = function() return ouro.xdg.applications.list() end,
             launch = function(entry) return ouro.xdg.applications.prepare_launch(entry) --[[ + spawn ]] end },
  states = {
    hidden = { on = { TOGGLE = 'open' } },
    open = { initial = 'loading', on = { TOGGLE = 'hidden', CLOSE = 'hidden' },   -- CLOSE = Escape or compositor close
      after = { [60000] = 'hidden' },                                            -- idle auto-hide, cancelled on exit
      states = {
        loading  = { invoke = { src='scan', on_done={target='ready', actions=assign{entries=output}},
                                on_error='failed' } },
        ready    = { on = { QUERY = {actions=assign{query=..., index=1}}, MOVE = {actions=assign{index=...}},
                            ACTIVATE = {target='launching', guard='has_match'} } },
        launching = { invoke = { src='launch', input=selected_entry, on_done='#hidden', on_error='ready' } },
        failed   = { on = { QUERY = 'loading' } },
      }},
  },
}
-- view(snapshot): the surface exists only while open.
windows = function()
  if not launcher:matches('open') then return {} end
  return { ouro.layer_surface { id='launcher', layer='overlay', keyboard_interactivity='exclusive',
    on_close_request = launcher:sender('CLOSE'), content = function() return results(launcher) end } }
end
```

Closing the surface (`hidden`) cancels the scan and the auto-hide timer,
because they belong to `open`. Ranking results is a plain function of
`query` and `entries`. The keyboard binding `Super` sends `TOGGLE` as an
external event, and so can MCP.

[`examples/launcher`](../examples/launcher) implements this without the
auto-hide timer. Differences from the sketch:
- `failed` retries on `RETRY` or Enter (`ACTIVATE`), not on `QUERY`.
- `QUERY` and `MOVE` live on `open`, so typing during a scan is kept.
- `launch` starts a transient systemd user unit over D-Bus, because Lua
  cannot spawn processes.
- The compositor binding runs `ouroctl activate dev.ourokit.launcher`. The
  first launch opens it, and `activate` toggles it after that.

Where the reactive `windows` declaration fits and where it fights:
- **Fits:** `windows()` is a pure read of `matches('open')`.
  `on_close_request`, Escape and click-outside all become one `CLOSE` event.
  The commit that cancels the scan or launch also invalidates the
  declaration, so the surface retires with them.
- **Fights:** retirement happens on the next declaration pass. Nothing ties
  it to the state's scope, and the chart never learns whether the surface
  mapped. A surface the compositor rejects, or an invalid declaration that
  keeps the last good list, leaves `open` with no surface. Widget-local state
  (focus, scroll, caret) resets on every reopen, while context survives
  unless an entry action resets it. Two lifetimes have to agree by
  convention.

**Resolved by surface events.** A declaration with `send = actor` makes the
surface report back. The runtime delivers `surface.mapped.<id>`,
`surface.close_requested.<id>`, `surface.closed.<id>` and
`surface.failed.<id> { reason, message }` with `actor:deliver`, from an
application-scope task in the task phase. See the
[application model](../docs/application-model.md#surfaces-bound-to-a-statechart).
- A close request no longer closes anything. The chart leaves `open`, and
  the declaration drops the surface.
- A rejected declaration, an illegal transition of a retained surface
  (`transition`), or content that fails on its first build (with the Lua
  message), sends `failed`. `run`'s `{ windows = fn, send = actor }` also
  binds the declaration, so an error thrown by `windows()` arrives as
  `surface.failed` with reason `windows`. The launcher returns to `hidden`
  with the reason in context, where its MCP `State` action reports it.
- Retirement still follows the declaration pass, but `closed` tells the
  chart when teardown has finished.
- The launcher handles `surface.mapped` and `surface.closed` as explicit
  no-op transitions, so the inspector shows no rejections for them.
- Still fatal: native protocol failures.

### Contacts (implemented)

[`examples/contacts`](../examples/contacts) loads its address book from an
optional HTTP server (`server.json` in its config directory) or the built-in
sample, and saves renames with `PUT`. `contacts` is the domain chart.
`appearance` holds the window style in context
(`STYLE = machine.set('style', 'string')`).

```lua
book = machine.create {
  id = 'contacts', initial = 'loading', context = { contacts = {}, pending = {}, draft = '' },
  events = { SELECT = {id='string'}, RENAME = {id='string', name='string'}, RETRY = {}, QUIT = {} },
  states = {
    loading = { invoke = { src='load', on_done={target='ready', actions='loaded'}, on_error={target='failed', actions='fail'} },
                on = { QUIT = 'exiting' } },
    failed  = { on = { RETRY = 'loading', QUIT = 'exiting' } },
    ready = { type = 'parallel', order = { 'sync', 'lifecycle' },
      on = { SELECT = {guard='known', actions='select'}, EDIT = machine.set('draft', 'string'), RENAME = {guard='renames', actions='rename'} },
      states = {
        sync = { initial = 'idle', states = {
          idle     = { always = { target='saving', guard='pending' } },
          saving   = { entry = 'begin_save',          -- the record as it was when the save started
                       invoke = { src='save', on_done={target='idle', actions='saved'}, on_error={target='retrying', actions='fail'} } },
          retrying = { after = { [5000] = 'saving' }, on = { RETRY = 'saving' } },
        }},
        lifecycle = { initial = 'running', states = {
          running  = { on = { QUIT = 'quitting' } },
          quitting = { always = {target='#exiting', guard='settled'}, after = { [5000] = '#exiting' }, on = { QUIT = '#exiting' } },
        }},
      }},
    exiting = { invoke = { src='exit', on_done='exited', on_error='exited' } },   -- actions cannot exit
    exited  = { type = 'final' },
  },
}
```

- `RENAME` applies locally at once and appends the id to `pending`, an
  ordered set. `sync` writes one record at a time. A reply replaces the local
  record only if the name still matches what was sent; otherwise the id stays
  pending and the newer name is written next. There are no serials.
- `quitting.settled` reads the other region: nothing pending, or
  `ready.sync.retrying`. Quitting cancels an in-flight `PUT` only at the
  deadline or on a second Quit.
- The MCP actions send events to this actor. `GetContacts` and
  `SelectContact` come from `machine.actions`: the input schema is the
  `SELECT` declaration, and a `no_transition` rejection maps to
  `ContactNotFound`. Their `before` hook waits with `machine.wait_for` until
  `loading` ends. `RenameContact` stays hand-written. The chart refuses a
  `RENAME` for an unknown id, an invalid name or an unchanged name, and
  `send()` reports all three as `no_transition`, but MCP answers each one
  differently: `ContactNotFound`, `InvalidName`, or the unchanged record.
- The rename draft is context (`EDIT`, a `machine.set`), not native
  text-input state. It resets on selection and when the selected contact is
  renamed elsewhere.
- The view is all `send =` bindings (§7). Apply name is
  `send = book:event { type = 'RENAME', id = person.id, name = c.draft }`.
  Its enabled state is `can()` of that event, so the button and MCP refuse
  empty names for the same reason.

## 13. Open questions

- ~~Do signals survive?~~ **Resolved:** charts hold all application state,
  presentation state included. Signals survive only as each actor's hidden
  per-field signals (§6). Derived data uses `machine.selector`.
- ~~Fire-and-forget I/O~~ **Resolved:** one-shot spawned tasks (§8).
- ~~Duplicated facts across actors~~ **Resolved:** `snapshot.children[id]`
  exposes child snapshots, as in XState v5.
- **Copy-on-write by convention.** Nested values in context are not frozen;
  views protect reads, but an action can still mutate a table it created
  before assigning it.
- ~~Document order from sorted keys~~ **Resolved:** keep XState's map form and
  required `initial`. Parallel states may declare `order`; without it, keys sort.
- ~~Yielding in function actions~~ **Resolved:** rejected natively (§1).
- ~~Request/response over events~~ **Resolved:** `send` returns
  `accepted, reason`, and `machine.wait_for` wakes on commits (§2).
- ~~Two schemas per command~~ **Resolved:** `machine.actions` derives MCP
  `inputSchema` from the chart's event schema (§2). Output schemas are still
  written by hand.
- ~~Strict mode wiring~~ **Resolved:** the host sets `machine.strict` from
  `--dev` (§2).
- ~~Instance-scope teardown~~ **Resolved by the scopes thread:** cancelling a
  scope now retires the VM-owned scopes beneath it.
- **Selector caching** keeps one entry per selector. A selector called with
  alternating contexts, for example per child, recomputes. Per-key caches
  may be needed.
- **Effects see stale context.** Function actions run after commit, with the
  context of their point in the macrostep. This is SCXML-consistent but easy
  to misread.
- **Input provenance.** Drag and other press-provenance calls cannot move into
  invokes, because spawned tasks lose provenance.
- **Logical timer queue in Lua.** The clock and the timer queue (§8) are Lua
  over one native wake task, not Zig. Timers need one crossing per armed
  deadline. Move the queue native if profiling shows it.
- **Recording origins.** `activation` and hand-written MCP handlers record as
  `app`. Only `machine.actions` handlers know they are `mcp`. A host-set
  `machine._origin` around a yielding hook could mislabel another task's
  sends.
- **Component machines are not recorded** (§14), so replay misses UI state
  that lives only in them.

## 14. Record, replay and generated tests

Charts hold all application state (§6). So the inputs that cross into the
root actors fully determine app behavior, and a log of them replays.

### Inputs and boundaries

An input enters the system when no actor is processing:
- a send from a widget, MCP, app code or a component machine;
- a runtime delivery, such as a surface event;
- a timer firing;
- an invoke or spawned-task result, or an invoke's `send` callback;
- a root actor's start, stop or held work release.

Everything an input causes is internal and a function of the charts:
child sends, `send_parent`, spawns, `always` chains and function actions.
`machine.lua` marks each input as a *boundary*. Entering one syncs the
scheduler clock (§8), so due timers fire first. An installed recorder or
replayer (`M._hooks`) sees every boundary of a **recorded tree**. That is a
root actor on the default scheduler, or the replayer's, plus its children.
Component machines (§6) are not recorded: they are per-instance UI state,
recreated by rendering and not carried by reload either. A component's
effect that sends to a root actor is an input with origin `component`.

### Recording

`ouroctl run --dev` records by default to
`$XDG_STATE_HOME/ourokit/recordings/<application id>.jsonl`, the last
development run of each app. `ouroctl run --record <log.jsonl>` records
anywhere, including production, `--mcp` and `--headless`. The host opens one
file per process. Every source generation installs `machine.recorder`
before app code runs, so reloads continue the same log. The recorder writes
each line synchronously; a failed write stops recording, not the app.

**Format: JSON lines, `ouro.machine.log` version 1.** The first line is the
header. Each later line is one input with what it caused:

```json
{"format":"ouro.machine.log","version":1,"t0":1782223,"app":"dev.ourokit.stopwatch"}
{"k":"start","t":0,"a":"stopwatch","m":"stopwatch","input":{},"r":[{"a":"stopwatch","e":"ouro.init","tr":[]}],"s":{"stopwatch":{"states":["clock","clock.idle","settings","settings.closed"],"status":"active","children":[],"context":{"elapsed":0,"laps":[]}}}}
{"k":"event","t":20713,"a":"stopwatch","o":"widget","e":{"type":"START"},"r":[{"a":"stopwatch","e":"START","tr":[1]}],"s":{"stopwatch":{"states":["clock","clock.running","settings","settings.closed"],"context":{"started_at":1802936}}}}
{"k":"timer","t":20813,"a":"stopwatch","o":"timer","e":{"type":"after.100.clock.running","state":"clock.running","token":6,"time_ms":1803036},"r":[{"a":"stopwatch","e":"after.100.clock.running","tr":[2]}],"s":{"stopwatch":{"context":{"elapsed":100}}}}
```

| Field | Meaning |
| --- | --- |
| `t0` (header) | Logical ms of `t = 0`: host monotonic time when the log opened. Contexts may hold absolute `machine.now()` values, so replay runs its clock at `t0 + t`. |
| `k` | `start`, `event`, `timer`, `invoke`, `task`, `stop`, `release`, `reload` or `released` |
| `t` | Logical ms since `t0`: the input's instant, or a timer's deadline |
| `a` | Actor path, such as `notes/document.2` |
| `o` | Origin: `widget`, `callback` (`actor:sender`), `mcp` (`machine.actions`), `invoke` (a result or an invoke's `send`), `child` (a task result), `timer`, `surface`, `runtime`, `component`, `app` (any other app code; hosts may set `machine._origin`, e.g. `activation`, around a synchronous hook) |
| `e` | The event as delivered, payload included. Invoke and task results carry `output` or `error`. |
| `m`, `input` / `snapshot` | On `start`: the chart id and the actor's `input`. A restored or carried actor gets its persisted snapshot instead (§3). An input that is not plain data (injected services) falls back to the initial snapshot and marks the step `lossy`. |
| `r` | Compact records for every actor step the input caused: actor, event type, transition indices (`chart:graph()`), and rejection reason `x` |
| `s` | Snapshot deltas of the recorded actors that changed: `states`, `status`, `children` ids, `output`, changed top-level `context` keys, and `unset` keys. Copy-on-write makes the comparison an identity check per key. |
| `err` | The error the input raised, if any |

Reload writes `reload` first. The candidate's lines are held until its
commit (`machine.release()`): carried actors' `start` lines with snapshots,
the events `run` sent, then `release` per actor and `released`. A failed
candidate leaves nothing behind.

### Replay

```sh
ouroctl replay <log.jsonl> [application.lua|ouro.json|directory] [--json]
```

Replay loads the application's modules in the deterministic test host
without calling `run`, so the charts get created. `machine.charts()`
remembers every chart by id. Then `machine.replay(log)` runs the inputs
against those charts:
- **Clock.** Each generation gets a virtual replay scheduler, a logical
  clock at `t0 + t`. Before each input the replayer advances to the input's
  `t`, so timers fire on their own at their deadlines, exactly as live. A
  `timer` line is therefore a check, not an input.
- **Stubs.** Invokes and spawned tasks never run. The scheduler keeps their
  `complete`/`send` handles (`scheduler.run(scope, fn, info)`), and a
  recorded result completes the matching one. With no running invoke to
  complete, replay reports the divergence.
- **Events.** Events are delivered as recorded. Live sends were validated,
  and an invalid send never reaches the log.
- **Reload.** A `reload` line starts a new generation: the old actors stop,
  `machine.carry({})` holds restored work, and the first `release` or
  `released` line calls `machine.release()`.

Replay records what it observes with the same recorder, then compares it
line by line with the log: kinds, times, events, compact records and
snapshot deltas. **The first line that differs is the divergence.** The
report names the input, and lists field differences against the full
snapshots rebuilt from deltas. Here a chart's `after` delay changed from 40
to 30 ms:

```text
DIVERGED at step 5 (log line 6, t=437 ms): replay produced timer after.30.green on signal at t=427 where the recording has timer after.40.green on signal
  matched 4 of 19 entries before it
  e                                        recorded {"type":"after.40.green","time_ms":1697811,"token":5,"state":"green"}
                                           replayed {"type":"after.30.green","state":"green","token":5,"time_ms":1697801}
  t                                        recorded 437
                                           replayed 427
```

The exit status is 0 for identical replays, 1 for a divergence. `--json`
returns the report with the replayed lines. In Lua, `machine.replay(text or
lines, {charts = {id = chart}})` returns `{ok, compared, divergence =
{step, line, t, message, recorded, replayed, differences}}`, and
`machine.replay_text(report)` formats it.

**Limits.** Replay reproduces chart behavior, not the world:
- function actions run again, so their side effects (prints, signals they
  write outside charts) repeat;
- charts must be created when the app module loads, not inside `run`;
- context values that are not JSON (functions, userdata) are recorded as
  markers and cannot be reproduced;
- component machines are not recorded.

### Generated tests

```sh
ouroctl test --generate <application> [--output <dir>] [--from <log.jsonl>]... [--depth <n>]
ouroctl test examples/stopwatch          # runs examples/stopwatch/tests/*_test.jsonl
```

`machine.paths(chart, options)` searches for event paths that reach every
state of the chart's graph and take every transition. It works breadth
first, expanding first the paths that reached something new.
- **Real runs.** A search node is a path of inputs, re-run on a fresh actor
  with a replay scheduler. Guards, assigns, timers and stubbed invokes
  behave as in replay, and `always` chains count the states they pass
  through.
- **Inputs at a node.** Every declared event the actor or a live child
  `handles()`, the earliest pending timer, and a result (output or error)
  for each running invoke or task.
- **Guard-aware payloads.** Candidates come from the event schema, filled
  with the values found in the node's context (ids, names, integers and
  their successors). Recordings passed with `--from` add their payloads and
  their real invoke and task results, which unlocks states behind a `load`.
- **Dedupe and budget.** Nodes dedupe on configuration, context, children,
  pending timers and stubs. The depth limit is 8 and the run limit 1500.

Each chart the app module created gets one `<chart>_paths_test.jsonl`. It
replays the selected paths as start, inputs and stop. The header's
`generated` field lists each path's steps, the targets it covers, and
coverage with anything left unreached. `ouroctl test` treats every
`*_test.jsonl` as one test, `replay`, against the application found by
walking up to `ouro.json`. A chart change that alters a covered behavior
fails with the divergence report. After an intended change, regenerate.
Real recordings saved as `*_test.jsonl` work the same way.

Results on the examples (`zig build test-components` runs the committed
files):

| App | Chart | States | Transitions | Seeded by `tests/seed.jsonl` |
| --- | --- | --- | --- | --- |
| stopwatch | `stopwatch` | 7/7 | 11/11 | not needed |
| documents | `notes` | 7/7 | 19/20 | Open… and drop results |
| documents | `document` | 12/12 | 15/18 | chooser results, including `Canceled` |
| contacts | `contacts` | 12/12 | 19/19 | a two-person `load`, a failed `save` |
| contacts | `appearance` | 1/1 | 1/1 | not needed |
| launcher | `launcher` | 6/6 | 19/19 | a two-entry `scan`, a `launch` |

The seeds are hand-written logs: small fake results instead of a real
desktop's application list or the 500-row contacts sample. The search
cannot reach some transitions:
- a standalone `document` has no parent, so `CANCEL`'s `send_parent` raises;
- `notes` reaches the close walk's done-while-closing transition only
  through a deeper child interaction than the default budget allows.

Without seeds, contacts reaches 4/12 states and the launcher 5/6. Their
invokes then return only `null` or `{}`, which their `on_done` actions
reject.
