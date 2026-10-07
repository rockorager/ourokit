# Statecharts as the application model

Status: Phase 0 (semantics) and Phase 1 (pure-Lua prototype). The prototype
lives in [`src/lua/machine.lua`](../src/lua/machine.lua) as `ouro.machine`;
tests are in [`tests/machine_test.lua`](../tests/machine_test.lua) and
[`tests/machine_native.py`](../tests/machine_native.py).
[`examples/documents`](../examples/documents) is ported to it.

The core idea: **active states own lifetimes, effects and windows, and the UI is
a function of the state snapshot.** Statecharts own behavior over time. They
do not replace plain functions, the view, or the native editor.

## 1. Supported subset

We use SCXML semantics with an XState-like Lua surface. Supported:

| Feature | Surface | Notes |
| --- | --- | --- |
| Hierarchy | `states = { idle = {...}, saving = {...} }`, `initial = 'idle'` | `initial` is required on compound states, as in XState. |
| Parallel | `type = 'parallel'`, optional `order = {'io', 'lifecycle'}` | Every region is active at once. `order` sets region document order. |
| Final | `type = 'final'`, optional `output = fn` | Raises `done.state.<parent>`. A top-level final finishes the machine. |
| Guards | `guard = 'name' \| fn` | Pure: `(context, event, state) -> boolean`. |
| `assign` | `machine.assign(fn \| {field = value \| fn})` | The only way to change context. |
| `raise` | `machine.raise(event \| fn)` | Adds an internal event to the current macrostep. |
| `always` | `always = transition(s)` | Eventless transitions, checked after every microstep. |
| `after` | `after = { [ms] = transition }` | Integer milliseconds. Started on entry, cancelled on exit. |
| `invoke` | `invoke = { src, id?, input?, on_done?, on_error? }` | Work that lives exactly as long as its state. |
| Spawned children | `machine.spawn(chart \| fn \| 'actor', {id?, input?})`, `machine.stop(id)`, `send_to`, `send_parent` | Keyed child actors, such as one per document or tab, or one-shot tasks (§8). Ids default to `<chart or actor>.<n>`. |
| Entry/exit | `entry = action(s)`, `exit = action(s)` | Actions run in document order. Named actions in `actions = {...}` may be a list. |
| `on_done` | on compound/parallel states | Shorthand for `on = { ['done.state.<id>'] = ... }`. |
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

A transition whose targets are all descendants of its source does not exit the
source unless `reenter = true`. This is the default in SCXML internal
transitions and XState v5. A transition that targets its own state re-enters
it, which restarts its timers and invokes. A transition with no `target`
only runs its actions.

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
  reaches the sender.
- **Effects run after commit:** plain function actions, timers, invokes and
  child messages run after commit. Function actions run in order. Each sees the
  context as it was when it was reached in the macrostep. Timers and invokes
  start at the end of the macrostep, only for states that are still active.
  This matches SCXML's end-of-macrostep `<invoke>`. Their cancellation is
  recorded when the state exits.
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

External events can be declared with schemas:

```lua
events = {
  SAVE = {},
  EDIT = { field = 'string', value = 'string' },
  RESIZE = { position = 'number', animate = 'boolean?' },
}
```

The field types are `string`, `number`, `integer`, `boolean`, `table` and `any`.
A trailing `?` marks an optional field. When `events` is present, `send`
rejects undeclared types (`UnknownEvent`), missing or mistyped fields and
undeclared fields (`InvalidEvent`). `can` rejects undeclared types. Internal
types are reserved and cannot be sent:

| Type | Raised when |
| --- | --- |
| `ouro.init`, `ouro.restore` | The actor starts, from scratch or from a snapshot. |
| `after.<ms>.<state>` | A timer fires. Carries `state` and the entry `token`. |
| `done.invoke.<id>` / `error.invoke.<id>` | Invoked work returns or throws. Carries `output` or `error`, plus `state` and `token`. |
| `done.state.<id>` | A compound or parallel state completes. Carries `output`. |
| `done.actor.<child>` | A spawned child finishes: a chart reaches its final state, or a task returns. Carries `id`, `output` and the child's former `index`. |
| `error.actor.<child>` | A spawned task throws. Carries `id`, `error` and `index`. |

`done.actor.*` and `error.actor.*` events for a child that is no longer listed,
because it was stopped or cancelled with its owner, are rejected as `stale`.

A timer or invoke event whose token does not match the current entry of its
state is rejected as `stale`.

**Actions, commands, shortcuts, palette entries and MCP calls are all external
events with schemas.** One declaration serves validation, documentation and
discovery. `actor:accepted()` lists the declared events the current
configuration would take, guards included, so the palette and MCP `tools/list`
can show exactly what is possible now.

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
  When a child commits, its new snapshot replaces its entry in the parent,
  which writes the parent's signal. A view that reads only the parent
  therefore rebuilds when a child changes, and parent guards see children as
  of the start of their macrostep.
- **Serializable.** `actor:persist()` returns `machine`, `status`, `states`,
  `context`, `output` and children as `{ id, snapshot }`. It deep-copies plain
  data and fails on functions or cycles. The result round-trips through
  `ouro.json`. Tokens are not persisted. Restoring re-enters states without
  running entry actions, then restarts their timers and invokes.
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

## 5. Continuous values stay native

Pointer position, hover, drag deltas, scroll offsets, animation progress, caret
and selection, IME preedit and per-keystroke editing stay native. They are not
states and not context. A chart sees committed facts:
- `EDIT { field, value }` from `on_change`;
- `RESIZE { position }` when a split moves;
- `SELECTED { id }` when a list selection changes.

Phase 5 native widget charts (button hover/pressed, focus, menus, modal editing)
are internal, compiled in Zig and allocation-free. They are not app charts.

## 6. Layering

```diagram
┌──────────────────────────────┐
│ Domain charts (headless)     │  document: io.idle/io.saving, lifecycle.confirming
│ testable and drivable by MCP │  no widgets, no windows
└──────────────┬───────────────┘
               │ snapshot (signal)
┌──────────────▼───────────────┐
│ UI charts (presentation only)│  palette open, selected tab, wizard step
└──────────────┬───────────────┘
               │
┌──────────────▼───────────────┐      ┌───────────────────────────┐
│ view(snapshot) → windows,    │─────▶│ plain functions           │
│ dialogs, widgets             │      │ validate, encode, sort,   │
└──────────────┬───────────────┘      │ format, derive (`dirty`)  │
               │ events               └───────────────────────────┘
               ▼
          actor:send
```

- **Domain charts are headless.** The document chart knows `io.saving` and
  `lifecycle.confirming`. It does not know that a dialog exists.
- **UI charts hold presentation modes only.** Examples: palette open, which tab
  is selected, which wizard step is showing.
- **The view does the mapping.** `doc:matches('open.lifecycle.confirming')`
  mounts the confirm dialog. A layer surface exists because
  `launcher:matches('open')`.
- **Computation stays in plain functions.** For example, `dirty` is
  `revision ~= saved_revision`: a calculation, not a state. Rule of thumb: if
  what can happen next depends on what happened before, use a chart. If it is
  a calculation on current data, use a function.

## 7. Widgets send events

```lua
-- Phase 3 target
ouro.button { key = 'save', label = 'Save', send = 'SAVE' }
-- enabled defaults to doc:can('SAVE'); on_press sends to the nearest actor
```

The prototype runs on today's widgets, so it spells this out:

```lua
ouro.button { key = 'save', label = 'Save', enabled = doc:can('SAVE'), on_press = doc:sender('SAVE') }
```

Registry-anchored callback closures go away. The enabled state and the action
have one source of truth. A disabled button and a rejected MCP call fail for
the same reason, and the inspector shows that reason.

Some imperative calls must stay in callbacks for now: `ouro.start_drag`, and
anything else that needs real press provenance. They report failures as events
(`REPORT { message }`).

## 8. Active states own task scopes

Each actor opens a root scope when it starts. A spawned child's root scope is a
child of its parent's root scope. Each state entry with `after` or `invoke`
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
  - the parent, for exit actions.
  A return delivers `done.actor.<id> { output }`; a throw delivers
  `error.actor.<id> { error }`. `stop(id)` or leaving the owner state removes
  it from `children` and cancels it natively. Use this for work whose result
  is just an event, such as Open… (a chooser and reads) or a notification.
- **Token fallback (`machine.token_scheduler`).** Used where a Lua state has
  no `Vm`, so the binding is nil. Work runs in application scope (`spawn_app`,
  else `spawn`), and closing only drops delivery. A cancelled request still
  runs to completion; only its result is ignored.
- **Tests (`machine.manual_scheduler()`).** Virtual time comes from
  `advance(ms)`. Queued invokes run when `run_tasks()` is called.
  `open_scopes` counts live scopes, including actor roots. `ouroctl test`
  forbids wall-clock sleeps, and the sandbox has no `coroutine` library, so
  invokes run to completion when they run.
- **Effects run in the sender's task, not in a state scope.** That is why
  function actions are atomic (§1).
- **Still open: logical timers.** `after` still uses wall-clock `ouro.sleep`.
  Replay on a virtual clock needs the scope's timers to follow a host clock.

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

Today's hot reload discards the VM, including signals. The host has to keep
`actor:persist()` across generations before reload can actually preserve
state. That is Phase 3 work. The mapping itself is implemented and tested.

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
actors, so a late-attaching tool can call `actor:snapshot()` and
`actor.chart:graph()`.

There is one record per processed event, including rejected ones:

```lua
{
  kind = 'transition', actor = 'notes/document.2', machine = 'document', sequence = 14, commit = 203,
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
  timers  = { { action = 'started', state = 'open.io.saving', delay = 500, event = 'after.500.open.io.saving', token = 9 } },
  -- timer action: started | fired | cancelled
  invokes = { { action = 'started', state = 'open.io.saving.choosing', id = 'choose', src = 'choose', token = 10 } },
  -- invoke action: started | done | error (+ error) | cancelled
  children = { { action = 'spawned', id = 'document.3', machine = 'document' } },
  -- child action: spawned | stopped | done | error (+ error); tasks carry src instead of machine
  actions = { 'snapshot_save' },   -- action names in execution order
  states = { ... },                -- configuration after the step
  status = 'active',
  context = { ... },               -- plain deep copy of the context after the step
}
```

Lifecycle records are `{ kind = 'actor', action = 'started', actor, machine,
parent, graph }` and `{ kind = 'actor', action = 'stopped', actor, machine }`.
Records are built only while an observer is attached. They answer questions
like "why is this app waking up when idle?" through timers that are still
started, and "why is Save disabled?" through rejected events and guards.

## 11. API summary (prototype)

```lua
local machine = ouro.machine
local chart = machine.create { id, initial, context, states, on, guards, actions, actors, events, ... }
chart:graph()                      chart:initial(input)      chart:transition(snapshot, event)
chart:can(snapshot, event)         chart:restore(persisted, {renames})
local actor = chart:actor { input, scheduler, snapshot, charts, id }   -- create (render-safe)
actor:start()  actor:stop()  actor:send(event)  actor:sender(event)
actor:matches(id)  actor:can(event)  actor:has_tag(tag)  actor:accepted()
actor:snapshot()  actor:context()  actor:states()  actor:status()  actor:output()
actor:child(id)  actor:children()  actor:persist()  actor:observe(fn)
machine.inspect(fn)  machine.actors()  machine.plain(v)  machine.unset  machine.matches(snapshot, id)
machine.assign  machine.raise  machine.spawn  machine.stop  machine.send_to  machine.send_parent
machine.default_scheduler  machine.token_scheduler  machine.manual_scheduler()  machine.native_scopes
```

`chart:actor` computes the initial snapshot, which may include initial
`assign`s, and stores it in one `ouro.signal`. It is safe in an `ouro.stateful`
initializer. `start()` runs the deferred effects and must run in the task phase,
like any signal write. Reads (`matches`, `can`, `context`, `snapshot`) go
through the signal, so a mounted build that reads them rebuilds when the
snapshot changes.

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

### Contacts

Contacts is in-memory today. It has no chart-worthy behavior except
selection, renaming and the presentation style:

```lua
book = machine.create {
  id = 'contacts', initial = 'browsing', context = { contacts = seed, selected = 'ada', style = 'light' },
  events = { SELECT = {id='string'}, RENAME = {id='string', name='string'}, TOGGLE_STYLE = {}, QUIT = {} },
  guards = { known = function(c, e) return index_of(c.contacts, e.id) ~= nil end },
  states = {
    browsing = { on = {
      SELECT = { guard='known', actions=assign{selected=function(_, e) return e.id end} },
      RENAME = { guard='known', actions=assign{contacts=function(c, e) return renamed(c.contacts, e.id, e.name) end} },
      TOGGLE_STYLE = { actions=assign{style=function(c) return c.style=='light' and 'terminal' or 'light' end} },
      QUIT = 'quit' } },
    quit = { type = 'final', entry = function() ouro.exit(0) end },
  },
}
```

The three MCP actions (`GetContacts`, `SelectContact`, `RenameContact`) become
the declared `SELECT`/`RENAME` events. `ContactNotFound` is a rejected event
(the guard fails), and `GetContacts` is a snapshot read. The rename draft
stays native text-input state until "Apply name" sends `RENAME`. A one-state
chart here is ceremony compared with three signals. It earns its keep only
through the shared schema and MCP surface, and through inspection.

## 13. Open questions

- **Do signals survive?** The prototype keeps exactly one signal per actor.
  The lean is to keep only derived read-only selectors.
- ~~Fire-and-forget I/O~~ **Resolved:** one-shot spawned tasks (§8).
- ~~Duplicated facts across actors~~ **Resolved:** `snapshot.children[id]`
  exposes child snapshots, as in XState v5.
- **Copy-on-write by convention.** Nested values in context are not frozen;
  views protect reads, but an action can still mutate a table it created
  before assigning it.
- ~~Document order from sorted keys~~ **Resolved:** keep XState's map form and
  required `initial`. Parallel states may declare `order`; without it, keys sort.
- ~~Yielding in function actions~~ **Resolved:** rejected natively (§1).
- **Effects see stale context.** Function actions run after commit, with the
  context of their point in the macrostep. This is SCXML-consistent but easy
  to misread.
- **Input provenance.** Drag and other press-provenance calls cannot move into
  invokes, because spawned tasks lose provenance.
