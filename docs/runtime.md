# Loop, tasks, and Lua

## Raw io_uring

`src/loop` owns ring creation, destruction, preparation, submission, waiting,
CQE dispatch, timers, and cancellation. The first operation directory is
allocated once and does not move. `user_data` encodes only operation kind,
24-bit slot, and 32-bit generation. Dispatch validates all fields before slot
access; stale and foreign completions are explicit outcomes.

Timeout storage lives in its slot until the timeout's terminal CQE. Cancellation
uses `IORING_OP_TIMEOUT_REMOVE`; the cancel CQE does not release the operation
slot because the timeout CQE may arrive later. Tests exercise both expiration
and cancellation against the real kernel.

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

The proof API registers only `ouro.sleep(milliseconds)`. The C callback records
the request and calls `lua_yieldk`. After `lua_resume` reports a yield in task
phase, Zig prepares a real ring timeout. The CQE phase validates completion and
marks the language-neutral task runnable; it cannot call Lua. The next task
phase calls `lua_resume`, which enters the continuation and then application
code. No Zig stack frame survives across the yield.

Every future standard-library capability requires an explicit review of
blocking behavior, allocation/performance, sandbox/capability effects, and
whether an asynchronous Ouro API should own the operation instead.
