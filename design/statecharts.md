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

## 0. Writing an app

[`examples/stopwatch`](../examples/stopwatch) is the smallest complete app,
first written from this document alone. Its shape:

```lua
-- charts.lua: behavior. machine.create is pure, so charts are made at load.
local machine = require('ouro').machine
local stopwatch = machine.create {
  id = 'stopwatch', type = 'parallel', order = { 'clock', 'settings' },  -- a parallel root
  context = { elapsed = 0, laps = {}, max_laps = 5, draft_max_laps = 5 },
  states = {
    clock = { initial = 'idle', states = {
      idle = { on = { START = 'running' } },
      running = { after = { [100] = { target = 'running', reenter = true, actions = 'tick' } }, on = { STOP = 'paused' } },
      paused = { on = { START = 'running' } },
    } },
    settings = { initial = 'closed', states = { ... MAX_LAPS = machine.set('draft_max_laps', 'integer') ... } },
  },
  actions = { tick = machine.assign { elapsed = function(c) return c.elapsed + 100 end } },
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

Guards, assigns, expressions and function actions are atomic: they cannot
wait, spawn or exit (§1). Function actions get the actor for reading and for
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
  scope. Capacity is fixed (1024 in the Wayland runner). Never-started work is
  discarded on close, so rapid toggling reuses slots.
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
- **Still open: logical timers.** `after` still uses wall-clock `ouro.sleep`.
  Replay on a virtual clock needs the scope's timers to follow a host clock.
- **`after` delays are constants.** They are the integer keys of the `after`
  table, fixed when the chart is created; a delay computed from context is
  not supported. Use a fixed tick and count, or one state per delay.
- **Missing: a millisecond clock for apps.** Lua's `os.time()` has one-second
  resolution, and the runtime's monotonic clock is private. So a stopwatch
  counts `after` ticks, and its elapsed time falls behind wall time by the
  timer latency of each tick. The proposed fix is a scheduler-backed clock
  readable from assigns, virtual under `manual_scheduler`.

An invoke `src` is `function(input, send) ... return output end`. It runs as an
Ouro task and may yield on Ouro I/O. `send` delivers events to the machine
while the state is still active, for callback-style sources. A throw becomes
`error.invoke.<id>` with the error value.

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
