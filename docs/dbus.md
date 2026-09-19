# D-Bus

`ouro.dbus` supports Linux D-Bus clients and services on the same connection.
It uses ourokit's shared `io_uring`
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

## Export a service

A service connects to the existing bus, exports interfaces, and acquires a
well-known name. It does not create a bus daemon or listen on another socket.
Register exports before acquiring the name so callers cannot race registration.

```lua
local service <close> = assert(bus:export {
  path = "/dev/ourokit/Example",
  interface = "dev.ourokit.Example",
  methods = {
    Echo = {
      input = "s", output = "s",
      handler = function(request)
        ouro.sleep(10) -- Handlers may yield, including calling another service.
        return {request.args[1] .. "!"}
      end,
    },
  },
  signals = { Changed = "us" }, -- Optional introspection declarations.
})
local name <close> = assert(bus:own_name("dev.ourokit.Example"))
-- Keep this scope alive while serving, or retain handles in application state.
```

`export` returns immediately with a closeable handle. Each declaration requires
an explicit `input` signature, `output` signature, and `handler` function.
Declarations are copied: editing the original tables does not change an export.
Multiple interfaces can share a path, but duplicate path/interface pairs fail.
`org.freedesktop.DBus.Introspectable.Introspect` is supplied automatically at
exported paths, using the method and optional signal declarations.

A handler receives the same message table shape as a signal, including `sender`
and positional `args`. It returns a positional argument table matching `output`;
use `{}` for an empty reply. Return `nil, {name="dev.example.Error", message="..."}`
for an application error. Exceptions, invalid results, and invalid error tables
produce `org.freedesktop.DBus.Error.Failed`; exception text is not sent to peers.
Wrong input signatures produce `InvalidArgs` without invoking the handler.
Missing objects/methods produce `UnknownObject`/`UnknownMethod`. Calls omitting
an interface are accepted only when the method resolves unambiguously.

Handlers run concurrently in child tasks, so replies may finish out of order.
The binding directs each reply to the original sender and call serial, at most
once. Calls with `NO_REPLY_EXPECTED` still invoke the handler but send no reply
or error. A caller timing out does not cancel work already running in the service.

`own_name` waits up to two seconds for `RequestName`, with `DO_NOT_QUEUE` and
without replacement. If another connection owns the name it returns
`nil, error_table` with `name = "NameUnavailable"`. Name handles and exports
belong to their creating scope and keep the connection reachable. Closing a
name schedules `ReleaseName`; closing an export unregisters its methods, cancels
its dispatcher and handler scope, and fails outstanding requests while the
connection remains usable. Closing the bus or retiring its source generation
closes both. Canceling name acquisition schedules release even if acquisition
was already sent. Do not mix raw `RequestName`/`ReleaseName` calls with managed
ownership of the same name.

An active dispatcher retains its export handle, so use `<close>`, explicit
`:close()`, or scope cancellation rather than relying on GC to stop a service.
Handler-created tasks and resources share the export's child scope. They can
outlive a single method call, but are canceled when the export closes.

Emit signals from an ouro task using explicit wire types:

```lua
assert(bus:emit {
  path = "/dev/ourokit/Example", interface = "dev.ourokit.Example",
  member = "Changed", signature = "us", args = {42, "updated"},
})
```

`emit` returns `true` once the signal is queued, or `nil, error_table`.
An optional `destination` sends a directed signal instead of a broadcast.
Emission does not require an export; signal declarations describe introspection
and do not constrain `emit`. There is no delivery acknowledgment.

For notification actions, call `ouro.activation_token()` directly inside the
button's input callback, before any other yield. It yields while requesting an
XDG activation token using that callback's real seat serial and source surface.
It returns a token string, or `nil, error_table` when unavailable or timed out.
The input provenance is single-use and does not transfer to spawned tasks;
timers, key repeats and callbacks without input cannot authorize activation.

Send the token to the notification's original D-Bus sender in a directed
`ActivationToken` signal before `ActionInvoked`. The receiving application must
use the token to activate its window. Token acquisition alone does not change
focus. Revalidate the notification after the yield, since it may have expired
or been replaced while waiting.

[`examples/dbus_notifications.lua`](../examples/dbus_notifications.lua) implements
the four notification methods, IDs, replacement, expiration, and
`NotificationClosed`. It prints notifications instead of rendering windows;
it does not advertise actions, icons, or markup support. Test on a private bus
before using it in a desktop session with an existing notification daemon.

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

Per Lua generation: 8 connections, 64 subscriptions/exports combined, 64 owned
names, and 128 outstanding waits. Each export uses one child scope and an idle
dispatcher wait. An export accepts at most 128 methods and 128 signal declarations.
There are at most 128 pending incoming calls per generation, and at most 64
calls or 1 MiB of wire data per export, including queued and running requests.
Excess calls receive `LimitsExceeded`. If the transmit queue cannot accept an
automatic reply/error, the connection closes rather than dropping replies.
Each signal queue holds at most 64 messages or 1 MiB; overflow closes that
stream rather than silently dropping events. Each native transmit queue holds
at most 256 messages or 4 MiB. Incoming messages are limited to 16 MiB and
16 FDs each; the native receive queue is bounded to 256 messages or 16 MiB.
Lua encoding/decoding allows at most 4096 values and 32 nesting levels; a
binary string counts as one value. These are implementation limits, not
configurable API knobs.

There are no automatic proxies, introspection cache, automatic Properties or
ObjectManager implementation, TCP transport, or cookie authentication.
Properties and other interfaces can be called or exported with explicit methods.

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
dbus-run-session -- zig-out/bin/ouroctl run examples/dbus_notifications.lua
dbus-run-session -- env OURO_DBUS_INTEGRATION=1 zig build test -Dvulkan=false
```

Live tests are opt-in; ordinary tests still cover the codec, malformed input,
fragmented full-duplex transport, FD ownership, and cancellation. `dbus-daemon`
is a test fixture, not a runtime dependency of the implementation.
