# Loop, tasks, and Lua

## Raw io_uring

`src/loop` owns ring creation, destruction, preparation, submission, waiting,
CQE dispatch, timers, and cancellation. Logical timers live in a dynamically
growing userspace min-heap with generation-checked handles and deterministic
insertion-order ties. Their handles never enter kernel `user_data`.

One absolute `IORING_OP_TIMEOUT` tracks the earliest heap deadline regardless
of logical timer count. `IORING_TIMEOUT_UPDATE` moves that alarm when the root
changes; removing the final timer cancels it. Alarm, update, removal, and the
retired cancellation CQE are tracked separately so every legal CQE ordering is
safe. Logical cancellation invalidates its handle immediately. Tests exercise
heap ordering/growth/stale handles, one-alarm operation, updates, expiration,
and cancellation against the real kernel.

Wayland keyboard repeat uses the same heap. The adapter honors compositor
`repeat_info`, asks xkbcommon whether the held key repeats, cancels on release,
focus leave, or capability loss, and rearms one logical timer per held key. An
expired repeat queues a translated `.repeated` key event; it cannot enter Lua or
mutate retained UI during CQE dispatch. Fractional-millisecond rates retain
nanosecond cadence rather than accumulating integer-millisecond truncation.

Wayland text composition is a separate channel from keyboard metadata. Ourokit
binds `zwp_text_input_manager_v3` through generated Wayring code and creates a
per-seat text-input object, but does not enable it merely because a surface has
keyboard focus. A retained editable target must explicitly activate it with
validated UTF-8 surrounding text, byte-indexed cursor/anchor state, content
hints/purpose, and optional cursor geometry.

Incoming preedit, commit, and surrounding-delete messages borrow Wayring's
receive storage, so the adapter copies each fragment into bounded host-owned
storage. Only `done` emits one atomic batch; the window event queue then owns
another copy until the platform-input safe point. A mismatched `done` serial is
reported with the edits (which must still be applied) while preventing callers
from treating compositor state as synchronized. No protocol callback resumes
Lua or mutates an editable model.

## Tasks and resources

The language-neutral scheduler separates `waiting`, `runnable`, and `running`.
Completion phases can only move waiting tasks to runnable. Only
`takeRunnable`, called by app's task phase, grants execution permission.

Scopes own tasks and heterogeneous resources through one registry. Resource
lifecycle hooks request cancellation and destroy context; generation-checked
handles make stale copies inert. Scope cancellation is first queued, then
applied at the task safe point. Future application/window/widget scopes use the
same mechanism rather than type-specific application arrays.

## Embedded Lua

Exact release: **Lua 5.5.1** (official source archive dated 2026-07-24).

- Source: <https://www.lua.org/ftp/lua-5.5.1.tar.gz>
- SHA-256: `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`
- License: MIT, from <https://www.lua.org/license.html>
- Zig package content hash:
  `N-V-__8AAPqeFQDipy0CdI6MKBmwYYarybBTO3IIJPrSzH_w`

The build compiles Lua's core C files and `lauxlib.c` only. It excludes
`lbaselib`, `lcorolib`, `ldblib`, `liolib`, `lmathlib`, `loadlib`, `loslib`,
`lstrlib`, `ltablib`, `lutf8lib`, and `linit`. No call to `luaL_openlibs`
exists. Consequently base, package, coroutine, table, string, math, utf8, io,
os, and debug libraries are all absent.

One isolated `lua.Vm` owns growable stable-address slabs of coroutine tasks. Each
task has generation-checked Lua identity, a language-neutral scheduler handle,
an explicit application/window/widget owner scope, and a Lua registry reference
that anchors its coroutine without retaining it accidentally on the main stack.
Direct scheduler-slot and growable logical-timer maps route
resumes and completions rather than scanning tasks. Slabs grow only when task
creation exhausts the free list; existing entries never move, and resume/CQE
paths do not allocate. Multiple coroutines may wait independently while Lua
execution itself remains single-threaded and confined to the task phase.

The VM can also spawn a scoped coroutine from an explicit Lua registry function
reference with typed native arguments without running it immediately. Routed
UI events resolve generation-checked instance-owned pointer bindings and use
this seam only during task phase; the scheduler subsequently grants execution.
An event handler may therefore await Ouro I/O without blocking later handlers
or bypassing scope cancellation.

The proof async API registers only `ouro.sleep(milliseconds)`. Its C callback
uses the VM's current generation-checked task, records the request, and calls
`lua_yieldk`. After `lua_resume` reports a yield, Zig registers the timer under
that task's actual owner scope and inserts a generation-checked logical timer.
The shared heap's one real ring alarm wakes the CQE phase, which drains expired
handles and marks only the corresponding language-neutral tasks runnable; it
cannot call Lua. The next task phase calls `lua_resume`, which
enters the continuation and then application code. No Zig stack frame survives
across the yield. Normal completion, errors, and cancellation call Lua 5.5's
`lua_closethread` before releasing the registry reference, ensuring pending
to-be-closed values unwind and the slot can be safely generation-reused.

Mounted UI builds extend the same Ouro-owned table with the constructor-specific
`row`, `column`, `scroll`, `label`, and `button` functions. They are available only during
a protected build-owner callback in the reconciliation phase, cannot yield, and
write directly into a bounded typed descriptor buffer. Applications provide
stable string keys; numeric descriptor IDs, parent links, generic widget table
parsing, and renderer access are not exposed. Button callbacks are explicitly
registry-anchored and staged with the build; they become visible only after
descriptor reconciliation succeeds.

`ouro.signal(initial)` creates full userdata whose Lua user value stores the
application value. Calling a signal reads it; `signal:set(value)` writes it.
Only reads made during a mounted UI build are tracked. The fixed-capacity native
graph stores generation-checked signal handles and stable build-owner
references. Dependencies are provisional until descriptor reconciliation
succeeds, so Lua errors, forbidden build-time writes, and native transaction
failures preserve the prior set. Raw-equal writes do not invalidate anything;
changed writes enqueue subscribed owners without resuming Lua. Owners detach
before their registry is destroyed, and Lua closes before the graph so userdata
finalizers cannot reach freed runtime state.

Every future standard-library capability requires an explicit review of
blocking behavior, allocation/performance, sandbox/capability effects, and
whether an asynchronous Ouro API should own the operation instead.
