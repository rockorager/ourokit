# Transactional source reload

Source reload replaces a disk-backed application's Lua generation while keeping
the process, Wayland connection, renderer, and compatible retained UI alive.
It is a development operation, not a production application action.

```sh
ouroctl run app.lua --dev
# Use the exact "development socket: ..." path printed by this process.
ouroctl dev status "$development_socket"
ouroctl dev reload "$development_socket"
```

Only `--dev` enables reload. Declaring actions does not enable a server, and
optional production `--mcp` does not expose runtime tools. Development copies
never acquire or activate the application's production D-Bus name. Desktop
activation is described separately in [the application model](application-model.md).

## Validation failures preserve the last-good application

The runner prepares a fresh Lua VM and builds every candidate window before
changing live UI. Source, declaration, UI-build, and local capacity failures
reject the candidate. The active generation, native windows, callback bindings,
focus, and last-good scene remain usable.

The transaction covers local application ownership, not rollback of external
systems. A native protocol, allocation, or device failure after local commit
shuts down the host; it is not reported as successful rollback. Application code
that performs external effects during source evaluation cannot expect those
effects to be undone by rejection.

`runtime.reload` replies only after its request commits or fails. Success
returns the new generation. Failure returns an MCP tool error with a structured
`ReloadFailed` error; `runtime.status` exposes the latest diagnostic. Diagnostic
fields are phase, source, and message. Lua messages may include source locations
and traceback text; there is no separate structured line/traceback contract.

A reload acknowledgment establishes source commit, not compositor presentation.
Use a fresh runtime inspection and capture to verify replacement content.
Software scene replay is not GPU readback or proof of pixels reaching a screen.

## Source generations have separate ownership

```diagram
┌───────────────────────────────────────────────────────┐
│ Process: event loop, scheduler, Wayland, renderer      │
│ Native windows and keyed retained widget state       │
└────────────────────────┬──────────────────────────────┘
                         │ adopts prepared UI
              ┌──────────▼──────────┐
              │ Active generation   │
              │ Lua VM and modules  │
              │ callbacks and tasks │
              └──────────┬──────────┘
                         │ replaced at safe point
              ┌──────────▼──────────┐
              │ Retiring generation │
              │ cancel and drain    │
              └─────────────────────┘
```

`bundle` owns source providers and snapshots. `lua` owns language state and
bindings. Window runtimes own prepared typed UI and retained native state.
`app.SourceReload` and the runner order the application-wide transaction.

Each generation owns its Lua VM, module cache, declarations, closures, signal
graph, and language tasks/resources. Old source is never patched into a live
VM. Callback capabilities identify their owning generation, so an old registry
reference cannot be dispatched or released through a replacement VM.

Retirement is asynchronous. Removed runtimes detach callbacks and signal
dependencies before the old VM is marked detached. Old tasks receive scope
cancellation, suspended coroutines unwind, and pending kernel work drains before
the generation is destroyed. Retirement capacity is bounded; exhaustion rejects
a candidate rather than discarding still-live resources.

## Preserved state follows native identity

- Unchanged application window IDs preserve native window handles.
- Compatible keyed widgets preserve retained native state, including focus,
  text editing, selection, and scrolling where the widget owns that state.
- Renderer, font, glyph, and paragraph caches belong to the surviving host.
- Lua locals, globals, module values, and `ouro.signal` values reset with the VM.
  Native retention is not general application-state persistence.

The application ID cannot change during reload. Such a candidate fails with
`ApplicationIdChanged` and requires a new process. Development enablement and
socket identity are launch configuration. Optional action declarations and their
schemas may be added, changed, or removed across generations independently.

Window declarations may be added, removed, reordered, and updated. New windows
are built once in stable reserved runtime slots; commit adopts that validated
build rather than executing unchecked source again. Removed windows undergo
normal closure and scope retirement. Adding replacements needs temporary free
slot capacity while old windows retire. Reusing an ID that is still retiring
fails with `SourceWindowRetiring`.

A compositor-closed window is suppressed while its declaration remains present.
A committed generation must omit that ID before later source can create it
again. Suppressed declarations are still validated in scratch runtimes, so an
invalid hidden window cannot enter the active generation unnoticed.

## Preparation precedes native changes

The runner consumes reload requests at its task/reconciliation safe point:

1. Read source and evaluate a candidate in a fresh generation.
2. Validate identity and window declarations; reserve local window IDs, scopes,
   strings, and stable runtime slots without issuing native changes.
3. Build every desired window at its configured or initial size, including
   additions and suppressed declarations.
4. Validate retained instance plans, layout, scene lowering, callback capacity,
   and aggregate instance-scope capacity across all windows.
5. Commit prepared runtime ownership and control schemas, reconcile native
   windows, invalidate replacement frames, and retire old source.

A later window's build failure cannot leave earlier windows partially replaced.
Local allocation and capacity checks occur before retained UI changes. The
subsequent native commit may still fail as described above.

Requests visible in one batch coalesce. Requests arriving during preparation
remain queued for the next transaction; they are not satisfied by the earlier
candidate's acknowledgment. There is no automatic file watcher or built-in
reload keyboard command today.

## Modules are generation-local

Disk startup and reload evaluate source in scheduler-owned coroutines. Module
cache misses yield through asynchronous capability-relative file reads. Module
names resolve within the entry source root as `name.lua` or `name/init.lua`;
path traversal and arbitrary native module loading are not enabled by `require`.
`require("ouro")` resolves the runtime-owned module without a disk read.

The module loader freezes after UI initialization. Already loaded modules stay
available, but a callback cannot load previously unseen mutable source. Explicit
headless execution leaves loading available until a deferred UI factory finishes.

Files are not currently revalidated as one atomic multi-file snapshot after
preparation. Avoid changing dependencies during a reload; atomic per-file saves
do not themselves guarantee a consistent multi-file revision.

## Development transport stays private

`--dev` logs a random `$XDG_RUNTIME_DIR/ourokit/dev/<32-hex-digits>` endpoint.
Its parent directories are 0700 and the socket is 0600. The server checks the
Unix peer UID. No development catalog is published in production discovery
directories, and CLI requests require the explicit endpoint, never an app ID.

The transport uses bounded MCP `tools/list` and `tools/call` messages on the
shared event loop. Runtime tools are reserved; application actions cannot
replace them. Invalid calls use JSON-RPC errors; execution failures use MCP
`isError` and structured error results. Pending application actions remain owned
by their source generation and are canceled when that generation retires.

The runner registers development operation schemas before admitting peers.
`takeDevelopmentRequest` transfers an owned request and unique token at a safe
point. `developmentPending` rejects canceled, disconnected, shutdown, and retired
requests. Input playback advances one event at a time, running normal dispatch,
tasks, reconciliation, and frame work between events. The runner completes a
request only after the final event settles, not when it is merely queued.

## Verification covers transactions and native integration

Headless tests exercise candidate failures, aggregate capacity rejection,
retained widget identity, removed callback detachment, signal dependency
survival, and ownership across generation retirement. Native tests additionally
exercise window creation/removal, visible replacement content, stale targets,
and input on newly added windows.

Versioned application-state migration, source-defined component family tokens,
post-commit application lifecycle hooks, multi-file dependency revalidation, and
file watching are not implemented contracts. Applications should not depend on
proposed APIs for those features.
