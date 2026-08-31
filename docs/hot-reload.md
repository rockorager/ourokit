# Transactional source reload

Ourokit treats application source as runtime input. A disk-backed application
can replace its Lua source while the process, native windows, platform
connection, renderer, and retained UI stay alive. Reload is an explicit
operation; automatic file watching may request the same operation later but is
not a separate reload mechanism.

The defining guarantee is:

> A reload either commits one complete, validated source generation or leaves
> the currently running generation entirely intact.

This is source reload, not mutation of live Lua functions. Ourokit never
executes changed files into the active Lua state. Doing that would retain stale
globals, module values, closures, subscriptions, and suspended coroutines in
ways application authors could not reason about.

## User experience

A development application is launched from a source entry path rather than
from source bytes detached from their origin:

```sh
ourokit run ./app.lua --dev
```

After saving one or more files, the author requests a reload through either:

- the built-in `Reload Source` application command, with a conventional
  `Ctrl+Shift+R` shortcut once keyboard commands are available; or
- the development control interface, exposed by the CLI as
  `ourokit reload dev.example.app`.

Both only enqueue a reload request. They do not read files, enter Lua, or
reconcile UI from an input callback. The request is consumed at an application
safe point. Repeated requests coalesce to the newest source snapshot.

On success, the next frame uses the new source. On failure, the application
keeps running its previous source and last good frame. Ourokit reports a
structured diagnostic with generation, file, line, phase, and Lua traceback;
the same diagnostic is available to the in-app development surface and control
client. Reload failure is not a process-fatal error.

Production bundles use the same generation machinery with an immutable source
provider. A production host need not expose a reload command or development
control endpoint.

## Lifetime model

Reload separates process-lifetime native services from replaceable application
language state:

```diagram
┌──────────────────── process lifetime ────────────────────────────┐
│ io_uring · scheduler · Wayland · renderers · fonts · state store │
│                                                                  │
│  ┌──────── retained native application ───────────────────────┐  │
│  │ window IDs/handles · keyed instances · widget state        │  │
│  └─────────────────────────────────────────────────────────────┘  │
│                              ▲                                   │
│                              ┃ atomic commit                     │
│  ┌──────── active source generation ────────┐                    │
│  │ source snapshot · Lua VM · module cache  │                    │
│  │ declarations · callbacks · subscriptions │                    │
│  │ generation-owned tasks and resources     │                    │
│  └──────────────────────────────────────────┘                    │
└──────────────────────────────────────────────────────────────────┘
```

A source generation owns everything whose meaning can depend on the exact
source text:

- one fresh isolated Lua state;
- one immutable source snapshot and module cache;
- the evaluated application declaration;
- Lua closures and registry references;
- signal subscriptions into that generation;
- language tasks, timers, and other language-created resources.

The native host survives generation replacement. Window declarations continue
to reconcile by application window ID. Retained widget and render identity
continue to reconcile by stable keys and typed descriptor identity. Unchanged
IDs therefore do not recreate Wayland windows, and unchanged keys do not
discard native widget state.

The application ID is process identity. A candidate whose application ID does
not match the active generation is rejected with `ApplicationIdChanged`; that
change requires a restart.

## Source and modules

`app.runWayland` currently receives detached source bytes. A reloadable host
instead receives a source provider:

```zig
pub const SourceProvider = union(enum) {
    disk: DiskSource,
    bundle: EmbeddedBundle,
};
```

The `bundle` module owns source paths, snapshots, and module resolution. The
`app` coordinator owns when a snapshot becomes active. Lua owns compilation and
module execution. Platform and UI modules never read application files.

Disk paths are resolved relative to the entry file's source root. Ourokit
provides a constrained `require` implementation without exposing Lua's
`package`, native module loading, environment search paths, or path traversal.
Resolution supports `name.lua` and `name/init.lua` within the source root.
Every module is loaded at most once per generation, while every generation has
a fresh module cache.

Imports must be resolved while preparing the entry point and its top-level
module dependency closure. First-time lazy imports from a later event callback
are rejected. This keeps the active generation backed by a complete immutable
snapshot and guarantees that all source in the dependency closure compiled
before commit.

Each file read records canonical path, bytes, content hash, and filesystem
identity. After candidate preparation, the disk provider revalidates every
dependency. If a file changed during preparation, the mixed snapshot is
discarded and the latest request is prepared again. Atomic-save renames are
detected by filesystem identity, not only modification time.

The host keeps the source root as an opened directory capability. Module names
cannot escape it through `..`, absolute paths, or symlink traversal. Lua never
receives a general filesystem API merely to support imports.

## State that survives

Reload persistence is explicit rather than accidental.

### Native retained state

The following survives automatically when semantic identity and type remain
compatible:

- native window identity and compositor state by window ID;
- instance/render-object identity by stable widget keys;
- widget-owned interaction state such as focus, scrolling, selection, and
  other future retained component state;
- renderer, font, glyph, and shape caches.

Removing an ID performs its normal lifecycle and cancellation. Reintroducing a
previously removed ID creates new identity; stale handles never become valid
again. A compositor-closed window remains tombstoned until a committed source
generation omits it, preserving the existing no-accidental-resurrection rule.

Compatibility is explicit. A mounted component has both a placement key and a
component-family token. The placement key identifies that component among its
siblings; the family token determines whether its retained state layout is
compatible with replacement source. Built-in constructors use their generated
schema identity and native state version. Future source-defined components use
a stable module-local `hot_id` and positive integer `hot_version`:

```lua
local ouro = require("ouro")
local Counter = ouro.component {
  hot_id = "counter",
  hot_version = 2,
  -- component declaration
}
```

The resulting family identity is the canonical module name plus `hot_id` plus
`hot_version`; source line numbers are never identity. The `hot_id` must be
unique within its module. A retained position preserves component state only
when both placement key and family token match. Changing `hot_version`
intentionally remounts that component subtree, retires its old execution scope,
and runs its initializer again. This gives state-layout changes an explicit
escape hatch without forcing authors to rename every call-site key.

### Application state

Ordinary Lua globals and module locals reset. State intended to survive source
replacement uses a stable key:

```lua
local ouro = require("ouro")
local count = ouro.state("counter", 0)

local settings = ouro.state("settings", {
  version = 2,
  initial = function()
    return { theme = "dark" }
  end,
  migrate = function(previous, previous_version)
    if previous_version == 1 then
      return { theme = previous.dark and "dark" or "light" }
    end
    return previous
  end,
})
```

`ouro.state` has signal semantics for builds but stores a bounded,
language-neutral value in the process-lifetime application state store. The
two-argument value form is shorthand for version 1 with that value as its
initial value. The versioned form uses `initial` only when the key does not
exist. When the stored and requested versions differ, `migrate` receives a
candidate-owned copy and the previous version. Migration may move either
forward or backward so source edit/undo remains supported. A missing or failed
migration rejects the candidate.

Reload preparation reads an immutable view of the active store and stages new
keys and migrated values; it cannot mutate active state before commit. A
migration runs in the same effect-free `preparing` capability phase as entry
evaluation. Its result is copied into a language-neutral value and validated
before the candidate can commit. Multiple declarations of one key in a
generation must request the same version.

Reloadable values initially support nil, booleans, finite numbers, strings,
and acyclic arrays/maps composed from those values. Functions, threads,
userdata, cycles, and native handles are generation-owned and cannot be
persisted. A migration that returns an unsupported value fails preparation
rather than silently resetting user state. Reusing a key at the same version
returns its stored value; authors must increment the version when source starts
expecting a different layout. Renaming a key remains the explicit reset
mechanism.

`ouro.signal(value)` remains generation-local and resets on reload. This gives
authors a clear choice instead of trying to infer which arbitrary Lua values
should survive.

Keys no longer referenced by source remain in the bounded store for the
process lifetime, making edit/undo cycles stable. Development tooling can show
and explicitly clear them; reload does not garbage-collect user state based on
one source generation.

## Preparation and commit

Reload runs as a state machine owned by the application coordinator:

```diagram
                 request
                    │
                    ▼
┌────────┐    ┌────────────┐    ┌─────────┐    ┏━━━━━━━━┓
│ active │───→│ snapshot + │───→│ prepare │───▶┃ commit ┃
└────────┘    │ compile    │    │ + build │    ┗━━━┳━━━━┛
     ▲        └──────┬─────┘    └────┬────┘        ┃
     │               │ error         │ error       ▼
     └───────────────┴────────────────┘       ┌──────────┐
          diagnostic; old app continues      │ retire old│
                                              └──────────┘
```

Preparation performs all fallible source-dependent work without mutating the
active generation:

1. Read a stable source snapshot.
2. Create a candidate generation at a stable address.
3. Install only reviewed Ouro APIs and the snapshot-backed module loader.
4. Compile and execute the entry point and top-level module closure.
5. Stage and validate new or migrated reloadable state.
6. Validate application ID, lifecycle callbacks, component-family tokens, and
   the complete window declaration.
7. Invoke every desired window build at its current configured size (or its
   initial size for a new window).
8. Validate typed descriptors, semantic snapshots, callback bindings, state
   dependencies, capacities, and module/source stability.
9. Produce a prepared application change containing no unvalidated Lua table
   data.

Candidate code executes in a `preparing` capability phase. APIs with external
effects, task spawning, or process-lifetime resource creation reject calls in
that phase. The application entry point and UI builds are declaration work;
effects begin only through lifecycle or event callbacks after commit.

Commit occurs between the task and reconciliation phases, when no Lua code,
build, input dispatch, or frame submission is in progress. It is allocation
free and cannot fail after preparation. In one commit it:

1. installs staged application-state keys;
2. reconciles the desired native window set by ID;
3. applies prepared descriptors to retained window runtimes by stable identity;
4. replaces callback capabilities and signal dependency sets;
5. switches the active generation pointer;
6. invalidates affected scenes and schedules frames;
7. queues cancellation of the old generation's language work.

The previous display list remains valid until the replacement list is built
and accepted by a renderer. Reload never produces a blank error frame as an
intermediate state.

Preparing all windows before mutation is essential. Per-window transactional
reconciliation alone is insufficient because a later window failure would
otherwise leave an application containing parts of two generations.

## Reload lifecycle

State initialization and side effects have deliberately different lifetimes:

- application entry points, state `initial`/`migrate` functions, component
  initializers, and UI builds run during preparation and must be effect-free;
- application and component `start` callbacks run after commit in fresh
  generation-owned execution scopes; and
- replacing a generation or remounting a component cancels its execution scope
  and all tasks/resources below it.

An application may declare post-commit work explicitly:

```lua
local ouro = require("ouro")
return ouro.app {
  id = "dev.example.app",
  start = function()
    -- Spawn subscriptions, services, and other generation-owned effects here.
  end,
  windows = { ... },
}
```

`start` is spawned only after the generation pointer and prepared UI commit. It
inherits the generation root execution scope and may yield. At the first task
safe point after commit, queued cancellation of the old generation is applied
before the scheduler grants new `start` work, preventing overlapping old and
new services. Future source-defined components follow the same model: `init`
creates reloadable plain state only when the family is first mounted, while
`start` establishes effects after each compatible source-generation commit.
Retained state is rebound to the new component declaration before its new
`start` runs.

There is no synchronous user `stop` callback in the atomic commit path.
Generation-owned native resources receive normal scope cancellation, suspended
Lua tasks unwind through `lua_closethread`, and resource-specific cleanup runs
through their lifecycle hooks. This prevents arbitrary old source from
re-entering Lua or delaying a commit.

Preparation failures preserve the old generation exactly. A `start` failure is
different: it occurs after a successful commit because effectful work cannot be
preflighted safely. It is reported as a structured runtime diagnostic, cancels
the failed start task according to normal task rules, and does not roll back to
source whose retirement has already begun.

## Callbacks, tasks, and retirement

Native input bindings store a generation-checked callback capability, not a
bare Lua registry integer. Dispatch resolves that capability through its source
generation. Replacing or removing a binding releases it through the generation
that created it, so registry references are never accidentally unreferenced in
the wrong Lua state.

Native instance scopes continue to own native widget resources and survive
compatible reloads. Language execution uses a separate scope tree rooted at
the source generation. It maps window/widget semantic identity to execution
scopes so either event cancels the right work:

- removing a window or widget cancels its language execution subtree; and
- replacing a source generation cancels all of that generation's language
  execution, including suspended handlers and timers.

The old Lua state is not closed synchronously during commit. It enters a
retiring list, queued cancellations are applied at the next task safe point,
and suspended coroutines unwind through `lua_closethread`. Completion routing
continues to recognize retiring generations until their kernel operations,
tasks, resources, registry references, and scopes are drained. Only then does
Ourokit close the old VM and destroy its source snapshot.

Rapid reload requests do not wait for retirement. Requests coalesce by source
revision, candidates older than the newest completed snapshot are discarded,
and more than one old generation may drain concurrently within a fixed host
capacity.

## Native host implementation

The production runner now owns a `SourceReload` coordinator rather than one
fixed `Application` and `Vm`. The implemented ownership boundary includes:

- `main.zig` passes a retained disk source provider instead of source bytes
  detached from their origin;
- the runner fetches active application, UI-build, and signal ownership once
  per turn and services coalesced requests at its reconciliation safe point;
- window runtime records are keyed by window identity, with host capacity
  independent of the initial declaration count;
- callback bindings carry generation capabilities rather than raw Lua
  registry references;
- every candidate window owns its staged descriptors, semantics, handlers,
  shapes, signal dependencies, and revision-checked instance plan;
- candidate layout and scene lowering run in isolated scratch storage before
  any retained window changes;
- one application commit validates every window and reserves callback capacity
  before applying the first retained plan;
- old generations cancel and drain asynchronously while task and completion
  routing continues by owning VM; and
- source, declaration, and build failures become structured diagnostics and do
  not escape the run loop after successful startup.

The first runner integration deliberately accepts only an unchanged window-ID
set. Added and removed windows still require transactional native-host
preparation, and a public control transport still needs to wake the event loop
and submit the in-process request. Snapshot-backed modules, persistent state,
component-family identity, and post-commit lifecycle hooks also remain future
slices below.

These changes belong in existing ownership modules. There is still no broad
`runtime` module: `bundle` owns source, `lua` owns language generations and
bindings, UI owns prepared typed snapshots, and `app` orders their transaction.

## Development control interface

Development mode exposes a per-user control endpoint under
`$XDG_RUNTIME_DIR`, with permissions preventing access by other users. The
existing sans-I/O Varlink implementation is suitable for the protocol. Its
transport remains integrated with Ourokit's shared `io_uring` loop.

The initial interface needs only:

```text
Reload() -> (generation: int)
error ReloadFailed (diagnostic: Diagnostic)
Status() -> (activeGeneration: int, reloading: bool, diagnostic: ?Diagnostic)
```

The CLI discovers an app by application ID and calls this endpoint. The server
keeps the `Reload` call pending without blocking the event loop until the newest
coalesced request either commits or fails. Every caller waiting on that request
receives the committed generation or the same structured `ReloadFailed` error,
so `ourokit reload` has useful shell exit status without polling. A request that
arrives during preparation advances the requested source revision; an older
candidate cannot satisfy it and is discarded before commit. `Status` remains
available for development surfaces that observe reload without initiating it.
The built-in command calls the same in-process request API and does not depend
on the control socket.

Automatic watching is optional policy on top. An inotify watcher may debounce
changes and enqueue `Reload`, but it receives no privileged fast path and
cannot weaken snapshot or transactional guarantees.

## Required verification

The reload implementation is not complete until headless integration tests
prove these cases:

- syntax, module execution, declaration, and UI-build failures retain the old
  generation, callbacks, state, windows, and display list;
- a successful reload switches every window and callback in one commit;
- changing a callback uses the new closure immediately after commit;
- unchanged window IDs preserve native handles;
- unchanged widget keys preserve compatible native widget state;
- matching component family/version preserves state, while changing
  `hot_version` remounts and reruns initialization;
- added, removed, reordered, and title-updated windows reconcile correctly;
- `ouro.state` values survive, migrate transactionally in either version
  direction, and remain unchanged after failed migrations;
- ordinary signals and module locals reset;
- post-commit `start` runs in the new generation scope and its failure cannot
  resurrect or partially reactivate the old generation;
- old sleeping handlers are canceled and to-be-closed values unwind;
- completions for retiring generations cannot resume the active generation;
- edits or atomic renames during preparation cannot commit a mixed snapshot;
- repeated requests coalesce and stale candidates never replace newer source;
- callback references are released from the Lua state that owns them; and
- source reload still obeys the existing rule that only the task phase enters
  yieldable Lua and only reconciliation performs UI builds.

Wayland tests then need only verify that a retained ID keeps its native window
while title/content changes become visible. The transaction, failure, state,
and task semantics should remain testable without a compositor.

## Delivery order

The smallest sequence that preserves the final architecture is:

1. Add disk/embedded source providers, immutable snapshots, controlled
   `require`, and structured Lua diagnostics.
2. Introduce `SourceGeneration` and make initial startup use the same
   prepare/commit path as every later reload.
3. Replace declaration-indexed runner arrays with keyed, capacity-bounded
   window runtime records.
4. Add prepared multi-window builds and an allocation-free application commit.
5. Add generation callback capabilities, execution scopes, and asynchronous
   old-generation retirement.
6. Add versioned keyed `ouro.state`, migration, component family/version
   identity, and their staged commit views.
7. Add post-commit application/component lifecycle scopes.
8. Add the completion-returning built-in reload request and development control
   endpoint.
9. Optionally add file watching as another request producer.

There must not be a separate unsafe “quick reload” path. Startup, explicit
reload, control-interface reload, and future watcher reload all use the same
generation transaction.
