# Native plugins (experimental ABI 1)

The default `ouroctl` runner can load explicitly declared C-ABI shared
libraries. Plugins register synchronous Lua-facing functions and native-backed
dependencies in Ourokit's existing signal graph. Both C and Zig plugins use
`include/ourokit/plugin.h`; neither links Lua nor imports Ourokit's Zig internals.

This is the first implementation stage, not the complete native-component SDK.
Custom layout/paint/input/semantics hooks, CPU-frame submission, DMA-BUF import,
Wayland subsurfaces, and scoped asynchronous plugin operations are **not yet
implemented**. There are no placeholder capability flags claiming support for
them. Application authors can currently combine native-backed functions/state
with existing Lua components and widgets.

## Run the examples

From the repository root:

```sh
zig build
zig build build-native-example
zig-out/bin/ouroctl run zig-out/examples/native/ouro.json
```

Add `-Dvulkan=false` to both build commands and `--software` to the run command
for a software-only build. The counter example renders normal Ourokit widgets,
but its value lives in `counter.c`. Pressing Add 7 calls C, publishes a native
dependency, and rebuilds the subscribed Lua content. `echo.zig` demonstrates
scalar/string argument and result exchange through the same header.

Run the dynamic-library integration suite with `zig build test-native-plugins`.
It is also part of `zig build test`.

## Explicit loading

Declare modules in `ouro.json`, relative to the manifest directory (not the
entry Lua file):

```json
{
  "schema_version": 1,
  "id": "dev.example.player",
  "entry": "src/app.lua",
  "native_modules": [
    { "name": "player", "path": "lib/player.so" }
  ]
}
```

Lua accesses the resulting module table with `require("player")`. Native names
use the same canonical dotted-name rules as Lua modules. `ouro` is reserved;
duplicate native names are rejected. Registered native names take precedence
over matching application Lua files. They are available after bootstrap freezes
the Lua module closure. Undeclared libraries are never searched for or loaded by
`require`; Lua's `package`/`loadlib` facilities remain unavailable.

Libraries load before application evaluation, including `ouroctl mcp export`.
An invocation that only activates an already-running app does not load them.
Paths reject absolute paths and `.`/`..` components, but this is not a native
code sandbox: system dynamic linking, dependencies, and library constructors
execute with full process privileges. Only run trusted plugins. A crash or
memory error in a plugin can crash or corrupt the application.

## ABI and calls

Export the data symbol `ouro_plugin`, an `ouro_plugin_descriptor` containing
the ABI version, descriptor size, and initialization function. The host checks
the version and minimum size before calling initialization. A plugin likewise
checks the supplied API version and size before accessing its function table.
ABI 1 is experimental; unsupported versions fail explicitly.

Initialization receives an opaque `ouro_context` and a versioned function
table. It can register named functions, a destruction callback, and signals.
Registration copies names and completes before Lua can call any function.
There are no raw Lua state, Wayland, renderer, or event-loop pointers in the ABI.

Functions receive opaque call/context handles plus their registered user pointer.
Arguments are zero-indexed and support nil, booleans, signed 64-bit integers,
doubles, and length-delimited strings. Tables, functions, and arbitrary userdata
are not supported yet. Each call returns one value, defaulting to nil. Argument
strings are borrowed for the duration of the callback; `set_result` and
`set_error` copy string bytes immediately, including embedded NULs. Check every
API status, then return `OURO_OK` or `OURO_ERROR`.

Host API functions never raise Lua errors through a plugin frame. The callback
returns normally before Ourokit converts a failure into a Lua error, preserving
Zig `defer`/C cleanup. Plugins must not throw exceptions or unwind across the ABI.
Native calls are ordinary indirect C-ABI calls; scalar argument conversion is
direct, while string results currently require an ownership copy.

All APIs are event-thread-only and synchronous. Call/context pointers are not
thread-safe. Functions must return promptly: do not block the runner, drive its
event loop, or retain a call handle. ABI 1 provides no way to post a completion,
resume a Lua task, or cancel background work. Work must not outlive callbacks.

## State, signals, and reload

Each module initializes once **per source generation**. It can serve many Lua
components in that generation, retaining native state across UI rebuilds. Store
that state behind the registered user pointer, not mutable process globals.
Register destruction as soon as state is allocated; it runs on initialization
failure too. On normal teardown, Lua tasks/owners are disposed and the VM closes
before module destruction; the host then releases the module's signal handles.

Create signal dependencies during initialization. A getter calls `signal_read`
to subscribe the current build reader; the value itself stays native-owned.
An action calls `signal_publish` when its value changes. Publication queues dirty
readers without executing Lua. Mark getters `OURO_FUNCTION_READ_ONLY`. Unmarked
functions cannot run during a build transaction, and read-only functions cannot
publish signals. These are API contracts, not protection from malicious code.

Reload candidates receive fresh module state, so a rejected candidate cannot
replace the active generation's state through this API. A successful reload
resets plugin state, just as it resets Lua state. Effects in external systems or
plugin globals are not rolled back. Persistent native services across reload
need a separate lifetime contract and are not supplied by this ABI.

Library handles remain open until the runner and all its generations are
destroyed. Lua reload does not reload native code or reread the module list.
Restart the application after changing libraries or native manifest entries;
replace built library files atomically rather than overwriting a mapped file.

## Linked hosts

The registration boundary does not depend on dynamic loading. A Zig host can
pass `ourokit.native.Module` descriptors in `WaylandRunOptions.native_modules`
to `runWayland`/`runWaylandSource`. It may link those descriptors statically or
obtain them through `ourokit.native.Libraries.open`. Keep descriptors, names,
and code alive until the runner returns. This reuses the default runner's
registration and lifecycle; it is not a separate C application-host API.

## Subsequent rendering and scheduling work

Native components need retained instances, declarative property updates,
constraint-based measurement, focus/input routing, semantics, and paint hooks.
Custom-painted widgets should emit scene commands; externally rendered content
should submit frames through explicit readiness/release ownership. CPU images,
DMA-BUF imports, and subsurface presentation have different capabilities and
must be exercised before their interfaces become supported ABI.

Similarly, native async operations need scoped cancellation and a completion
handoff to the owning loop. Those interfaces should share this registration
boundary, but should not expose the raw completion queue or allow Lua re-entry.
