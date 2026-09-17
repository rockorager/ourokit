# D-Bus client

`ouro.dbus` is a generic Linux D-Bus client. It uses ourokit's shared `io_uring`
loop, with no libdbus, GIO, subprocess bridge, or new package dependency. The
wire codec derives from [Monstar](https://github.com/rockorager/monstar); its MIT
license is retained in `src/dbus/LICENSE`.

## Connect and call

Run this code in an ouro task: application startup, `run`, an asynchronous
callback, or `ouro.spawn`. These operations yield the current coroutine; they
do not block the event loop. Do not call them from synchronous UI builds.

```lua
local ouro = require("ouro")
local connection, failure = ouro.dbus.connect("session")
assert(connection, failure and failure.message)
local bus <close> = connection

local reply, err = bus:call {
  destination = "org.freedesktop.DBus",
  path = "/org/freedesktop/DBus",
  interface = "org.freedesktop.DBus",
  member = "ListNames",
  signature = "",
  args = {},
  timeout_ms = 5000,
}
assert(reply, err and err.message)
for _, name in ipairs(reply.args[1]) do
  ouro.stdout.write(name .. "\n")
end
```

`connect` accepts `"session"`, `"system"`, or an explicit address such as
`"unix:path=/run/user/1000/bus"`. It supports filesystem and Linux abstract Unix
sockets, percent-escaped address values, and semicolon-separated alternatives.
Session discovery uses `DBUS_SESSION_BUS_ADDRESS`, then `$XDG_RUNTIME_DIR/bus`;
system discovery uses `DBUS_SYSTEM_BUS_ADDRESS`, then `/run/dbus/system_bus_socket`.
Authentication uses EXTERNAL with the process UID. Connection success means
authentication, Unix-FD negotiation, `Hello`, and internal match registration
have completed. Startup has a two-second deadline.

Every call specifies `destination`, `path`, `interface`, `member`, `signature`,
and `args`, even for an empty body (`signature = "", args = {}`). `timeout_ms`
defaults to 25000 and accepts integers from 1 to 2147483647. Calls on the same
bus can run concurrently in separate tasks. Replies are correlated by serial,
not arrival order.

A reply or signal is a table with `signature` and positional `args`. It also
contains `sender`, `destination`, `path`, `interface`, and `member` when present
in the received header. The bus does not infer types or introspect methods.

## Subscribe to signals

```lua
local stream, err = bus:subscribe {
  sender = "org.freedesktop.DBus",
  path = "/org/freedesktop/DBus",
  interface = "org.freedesktop.DBus",
  member = "NameOwnerChanged",
}
assert(stream, err and err.message)
local signals <close> = stream
while true do
  local message, failure = signals:next()
  if not message then
    ouro.stderr.write(failure.message .. "\n")
    break
  end
  local name, previous, current = table.unpack(message.args)
  ouro.stdout.write(name .. ": " .. previous .. " -> " .. current .. "\n")
end
```

All four match fields are optional exact matches. `subscribe` waits for the
bus daemon to register the match, with a two-second deadline. Well-known
senders are resolved to unique names and tracked across ownership changes.
Each stream has one consumer: a second simultaneous `next` returns an error.
`next` waits indefinitely when its queue is empty. `stream:close()` unregisters
the match and wakes its waiter; `bus:close()` closes all its streams and calls.

## Values follow the supplied signature

| D-Bus type | Lua representation |
| --- | --- |
| `y`, `n`, `q`, `i`, `u`, `x` | Integer, checked against the exact wire width |
| `t` | `ouro.dbus.uint64("18446744073709551615")`; nonnegative Lua integers also accepted when sending |
| `d` | Number |
| `b` | Boolean, not an integer |
| `s`, `o`, `g` | String, validated as UTF-8 text, object path, or signature respectively |
| `ay` | Binary Lua string on receive; string or byte sequence on send |
| Other arrays | Dense positional table, including `{}` for an empty array |
| Structs | Dense positional table in field order |
| Dictionaries | Ordered sequence of `{key, value}` pairs, preserving duplicate keys |
| `v` | `ouro.dbus.variant(signature, value)` with read-only `.signature` and `.value` fields |
| `h` | Owned FD userdata with `:close()`, `__close`, and GC cleanup |

Decoded `t` values always use uint64 userdata. `tostring(value)` gives its exact
decimal representation, and two uint64 userdata compare by value. No floating
point conversion is needed. A variant signature must describe exactly one
complete type. Its payload is checked when marshalled; a table payload remains
a normal mutable Lua table.

For example, an `a{sv}` argument is represented as:

```lua
local options = {
  { "enabled", ouro.dbus.variant("b", true) },
  { "labels", ouro.dbus.variant("as", { "first", "second" }) },
}
-- signature = "a{sv}", args = { options }
```

FD passing uses negotiated `SCM_RIGHTS`. Receiving creates an owned,
close-on-exec descriptor; sending duplicates it, so closing the Lua value does
not invalidate an in-flight send. There is deliberately no constructor from
an arbitrary integer or raw-FD accessor. A received FD can be passed to another
D-Bus method; general file/stream operations on it are not exposed here.

## Errors and lifetime

Operations return `nil, error_table` on failure. Error tables contain `kind`,
`name`, and `message`:

- `remote`: the peer's D-Bus error name, first string argument as its message
  when available, plus the original reply's `signature`, `args`, and headers.
- `timeout`: the local deadline elapsed.
- `overflow`: the subscription's bounded signal queue overflowed.
- `local`: invalid arguments, closed handles, transport failure, or capacity
  limits. `name` identifies the native error.

The `variant` and `uint64` value constructors raise ordinary Lua errors for
invalid constructor arguments. Use `pcall` if accepting untrusted input.

Connections and subscriptions belong to the scope that created them, not to
the last task that used them. Scope cancellation closes its resources. Canceling
a child task waiting on a shared connection detaches only that wait; the task
does not resume with an error result. Timing out also leaves the bus usable.
Neither cancellation nor timeout undoes an operation already sent to the peer.

Use `<close>` or explicit `:close()` for deterministic cleanup. Close is
idempotent and schedules native cleanup without yielding. GC is a fallback.
A stream keeps its connection reachable. Source-generation retirement closes
its connections even if the task that created them has already finished;
replacement generations sharing retained native scopes remain unaffected.
There is no automatic reconnect.

## Bounds and current scope

Per Lua generation: 8 connections, 64 subscriptions, and 128 outstanding waits.
Each signal queue holds at most 64 messages or 1 MiB; overflow closes that
stream rather than silently dropping events. Each native transmit queue holds
at most 256 messages or 4 MiB. Incoming messages are limited to 16 MiB and
16 FDs each; the native receive queue is bounded to 256 messages or 16 MiB.
Lua encoding/decoding allows at most 4096 values and 32 nesting levels; a
binary string counts as one value. These are implementation limits, not
configurable API knobs.

This is a client, not an object server: no exported Lua methods, signal
emission API, automatic proxies, introspection cache, TCP transport, or
cookie authentication. It can call introspection and property methods like
any other D-Bus method using explicit signatures.

## Native embedding and tests

`ourokit.dbus.Client` must stay at a stable address while operations are
pending. `init` starts authentication; `send` copies bytes and duplicates FDs.
Dispatch owned socket and timer completions through `dispatch` and
`dispatchTimer`. Call `collectCanceled` at host safe points before submitting
I/O, including after cancellation completions: it also pumps writes and
retries submission backpressure. Consume messages with `takeMessage` and
call `Message.deinit` when finished. Shutdown requires `close`, continued
pumping/completion dispatch until `canDeinit`, then `deinit`. The Lua adapter
also requires `shutdown` on generation retirement before draining.

The example needs no compositor:

```sh
zig build -Dvulkan=false
dbus-run-session -- zig-out/bin/ouroctl run examples/dbus.lua
dbus-run-session -- env OURO_DBUS_INTEGRATION=1 zig build test -Dvulkan=false
```

Live tests are opt-in; ordinary tests still cover the codec, malformed input,
fragmented full-duplex transport, FD ownership, and cancellation. `dbus-daemon`
is a test fixture, not a runtime dependency of the implementation.
