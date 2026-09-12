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

The build compiles Lua's core C files, `lauxlib.c`, and an explicit library
allowlist in `src/lua/safe_libraries.c`. The allowlist includes the pinned base,
string, table, math, and UTF-8 implementation sources to register selected
functions directly; it never calls `luaL_openlibs` or the broad library openers.
Library tables belong to each VM and are available as ordinary Lua globals:

| Surface | Available |
| --- | --- |
| Base | `assert`, `error`, `ipairs`, `next`, `pairs`, `pcall`, `select`, `tonumber`, `tostring`, `type`, `xpcall` |
| `string` | Standard Lua 5.5.1 functions except `dump`; includes pattern matching, formatting and binary packing. String method syntax works. |
| `table` | `concat`, `create`, `insert`, `pack`, `unpack`, `remove`, `move`, `sort` |
| `math` | Standard non-compatibility numeric functions and constants, excluding `random` and `randomseed` |
| `utf8` | Unchanged Lua `char`, `charpattern`, `codes`, `codepoint`, `len`, `offset`, including strict/lax behavior and byte indexing |

No `io`, `os`, `package`, `debug`, or `coroutine` library is exposed. Base I/O
(`print`, `warn`, `dofile`, `loadfile`), dynamic `load`, raw/metatable accessors,
and `collectgarbage` are also absent. Output, file access, module loading,
process exit and asynchronous task lifetimes remain Ouro-owned. The two clock
operations exposed under the Ouro API do not install an ambient `os` table.
`ouro.time()` synchronously returns the current Unix timestamp as an integer;
`ouro.date(format[, timestamp])` synchronously formats local time, or UTC when
`format` starts with Lua's `!` prefix. They use the host process timezone and
the pinned Lua release's `os.time`/`os.date` implementations. No process or
filesystem operations from Lua's OS library are exposed. The existing
`require` implementation is preserved: it exposes `ouro`, and bundled hosts
add their scoped application-module loader, not Lua's package/native loader.

`pcall` and `xpcall` can wrap yielding Ouro callbacks. They catch Lua errors,
including errors after an awaited operation, but cannot catch host task
cancellation or keep a canceled task running. Lua library callbacks retain
upstream yield restrictions (for example, a `table.sort` comparator cannot
await I/O).

The math RNG is never initialized. Table sorting uses Lua's documented fixed
pivot-randomization alternative instead of requesting OS entropy. This avoids
adding hidden I/O to permitted library calls; Lua's existing VM hash seeding is
unchanged. These libraries execute synchronously and may consume substantial
CPU or memory on large inputs. The allowlist controls capabilities, not CPU or
memory quotas, and is not by itself an untrusted-code security boundary.

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

The runtime API is a built-in module loaded with `local ouro = require("ouro")`;
it is not installed as an ambient global and cannot be shadowed by application
source. The async API exposes `ouro.sleep(milliseconds)` and
`ouro.spawn(function)`. Spawn queues a non-retained child coroutine under the
currently running task's ownership scope and returns no handle; the child does
not run inline, and normal scope cancellation (including reload and shutdown)
owns its lifetime. It is rejected outside task-phase execution. The sleep C
callback
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
`row`, `column`, `scroll`, `text`, and `button` functions. They are available only during
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

## Application discovery

Wayland source hosts expose `ouro.xdg.applications.list()` inside Ouro tasks.
It yields a fresh desktop-entry snapshot, sorted by desktop-file ID. Only one
scan per source generation may run at a time; concurrent calls raise
`ApplicationDiscoveryBusy`. Export/deterministic hosts do not scan the machine
and raise `ApplicationDiscoveryUnavailable` instead.

```lua
local ouro = require("ouro")
local entries = ouro.xdg.applications.list()
for _, entry in ipairs(entries) do
    if entry.visible then
        -- Store/search/display the entry in the shell.
        local ok, launch = pcall(ouro.xdg.applications.prepare_launch, entry)
        if ok then
            -- launch.argv is an array; launch.cwd is a path or ouro.json.null.
            -- Preparation does not spawn anything.
        end
    end
end
```

Roots come from `XDG_DATA_HOME` (default `$HOME/.local/share`) followed by
`XDG_DATA_DIRS` (default `/usr/local/share:/usr/share`). Relative roots are
ignored. The process copies the roots, `XDG_CURRENT_DESKTOP`, and
`LC_ALL`/`LC_MESSAGES`/`LANG` once; reloading source does not change that
environment. Nested filenames become hyphenated desktop IDs. The first root
wins, including hidden or malformed overrides. Ordinary symlinks are followed,
directory cycles are skipped, and magic links are rejected.

Each entry has `id`, `path`, localized `name`, `generic_name`, `comment`, `icon`,
`keywords`, `exec`, `try_exec`, `working_directory`, `actions`, and the booleans
`hidden`, `no_display`, `terminal`, `dbus_activatable`, `visible`. Actions contain
`id`, localized `name`, `exec`, and `icon`. Missing optional fields use
`ouro.json.null`; empty lists remain arrays. `visible` combines Hidden,
NoDisplay, and OnlyShowIn/NotShowIn. `TryExec` is retained as metadata but ignored
for visibility; discovery does not look up its target or check permissions.
Invalid entries are skipped; I/O and capacity errors fail the scan rather than
returning an indistinguishable partial snapshot. Limits are 1 MiB per desktop
file, 64 MiB of file contents, 65,536 directory entries, and 32 nested directories.

`prepare_launch(entry[, {action = id, terminal_argv = {"terminal", "-e"}}])`
prepares Exec as literal argv without a shell. It expands `%c`, `%k`, `%i`, and
`%%`, removes file/URL placeholders because no documents are supplied, and
rejects invalid field codes. Terminal entries require an explicit argument
prefix. D-Bus-only entries/actions without Exec raise `NoExec`; this is not a
D-Bus activation API. The shell owns launching, search/ranking, refresh timing,
history, and UI.

Native callers use `xdg.applications.Scan` on their existing `loop.Loop`.
Open, stat, read, and close operations use io_uring. Directory enumeration
(`getdents64`) is synchronous because Linux has no ring opcode for it.
Parsing also runs on the loop thread. There
is no worker, private ring, polling, watcher, or persistent cache. Cancellation
drains in-flight operations and closes owned descriptors before retiring the
task; only the task-phase continuation can publish the result to Lua.
