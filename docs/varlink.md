# Varlink

`ourokit.varlink` is a sans-I/O Varlink implementation. It owns protocol
framing, JSON message lifetimes, call ordering, interface descriptions, schema
validation, and the mandatory `org.varlink.service` interface. It does not open
file descriptors, submit `io_uring` operations, invoke Lua, or choose a task
scheduler.

This boundary lets the native async adapter and Lua binding share one protocol
implementation.

## Lua client API

Declarative applications load the runtime API and make an ordinary call from
any yieldable Ouro task:

```lua
local ouro = require("ouro")

local reply = ouro.varlink.call(
  "unix:/run/org.example.service",
  "org.example.Service.GetStatus",
  { verbose = true }
)

if reply.error then
  -- A Varlink service error. Its parameters remain available for details.
  handle_error(reply.error, reply.parameters)
else
  use_status(reply.parameters)
end
```

`ouro.varlink.call(address, method, parameters?)` suspends only its current Lua
task and returns one table. `reply.parameters` is the reply's optional JSON
object and `reply.error` is the optional qualified Varlink error name. Transport,
framing, malformed-reply, and capacity failures raise a Lua error. The optional
parameters table must represent a JSON object: string-keyed tables become
objects, non-empty consecutive integer-keyed tables become arrays, and values
may be booleans, finite numbers, strings, nested tables, or
`ouro.varlink.null`. The same sentinel represents JSON null in replies. Empty
plain tables are objects. Decoded arrays retain their array identity; use
`ouro.json.array()` to construct an empty array explicitly.

The runtime currently accepts standard filesystem and abstract Unix addresses,
`unix:/path` and `unix:@name`, including ignored Varlink address properties.
TCP and device transports, streaming calls (`more`), one-way calls, and protocol
upgrades are not exposed by this initial Lua API.

Outbound `ouro.varlink.call` is available whether or not the application opts
into an inbound server.

Each source generation owns a fixed-capacity call adapter (16 concurrent calls
by default), and each call uses bounded 64 KiB inbound and outbound records,
32 levels of JSON nesting, and 4096 converted values. Socket connect, send, and
receive operations use the application's shared `io_uring`; Lua never owns a
descriptor or blocks a runtime thread. Calls register as scheduler resources
under the current task's scope. Scope or source-generation cancellation cancels
the active ring operation, waits for both operation and cancellation CQEs, then
closes the coroutine without running its continuation.

## Application action server

The `actions` field on `ouro.app` controls the inbound server. Omitted/nil means
no inbound socket. An empty table enables native `Status`, `Reload`, `Activate`
and `org.varlink.service` introspection. Custom actions require an IDL declaration:

```lua
return ouro.app {
  id = "dev.example.app",
  interface = [[
    interface dev.example.app
    method Greet(name: ?string) -> (greeting: string)
  ]],
  actions = {
    Greet = function(parameters)
      return { greeting = "Hello, " .. (parameters.name or "world") }
    end,
  },
  run = function(context) return { windows = { ... } } end,
}
```

For example, these raw records show the terminating NUL as `\u0000`:

```text
{"method":"dev.example.app.Greet","parameters":{"name":"Ada"}}\u0000
{"parameters":{"greeting":"Hello, Ada"}}\u0000
```

The IDL is parsed when the declaration loads. Declared method names and handler
keys must match exactly. The custom interface is registered separately from
`dev.ourokit.runtime`; `GetInfo` lists both and `GetInterfaceDescription` serves
each original IDL document. Native built-ins cannot be replaced by custom methods.

Each function receives one parameter table and returns an output-fields table;
there is no `result` envelope. A method with no output fields may return nothing.
Inputs and outputs are checked against the method's schema. To return a declared
error, use `return ouro.action_error("ErrorName", { field = value })`; the name is
resolved within the application's interface and the error fields are validated.
Arguments and results use the same JSON conversion rules and null sentinel as
the outbound client.

Action coroutines may yield, sleep, and make outbound Varlink calls. Each call
is owned by the source generation that accepted it; cancellation during reload
returns `ActionFailed`. A Lua error is isolated to that call and also returns
`ActionFailed`, without taking down the server or application. Unknown names
return `org.varlink.service.MethodNotFound` (or `InterfaceNotFound` for an
unknown interface).

Reload validates and replaces the IDL and handlers transactionally. In-flight
calls retain the schema of their accepting generation. Changing server enablement
between nil/omitted and a table requires a process restart.

## Systemd socket activation

The application address is `$XDG_RUNTIME_DIR/ourokit/apps/<application-id>`.
Use a user socket unit with `Accept=no`, `FileDescriptorName=varlink`, and
`ListenStream=%t/ourokit/apps/<application-id>`. Ourokit validates the inherited
AF_UNIX stream listener and uses it without binding or unlinking its pathname.
The `.service` executes `ouroctl run /path/to/ouro.json`. See the complete
[Contacts example units](../examples/contacts/README.md).

Inherited-socket startup is headless: only declaration/action initialization runs.
`dev.ourokit.runtime.Activate(activationToken: ?string) -> ()` initializes the UI;
later activations present the existing UI. A service without a `run` factory
returns `ActivateFailed`. `Status` includes `uiActive`. The launcher forwards
`XDG_ACTIVATION_TOKEN`; the compositor decides whether to grant focus.

For direct development runs, an opted-in app can bind the same well-known socket
itself. Existing socket nodes are never removed during startup; stale self-owned
development sockets require explicit cleanup. Systemd is the production activator.

## Transport contract

Both `Client` and `Server` are pull-based state machines:

1. Pass received bytes to `feed`. It returns the consumed prefix; retain and
   retry any suffix after draining events or other backpressure.
2. Drain `takeEvent` and call `deinit` on each event after dispatch.
3. Drain `takeTransmit`. A transmit owns its byte slice and keeps an offset for
   short asynchronous writes. Write `remaining()`, report progress with
   `consume`, and call `deinit` only when `complete()` is true.
4. Call `endInput` on EOF. A partial NUL-terminated JSON record reports
   `error.TruncatedMessage`.

Every queue and inbound/outbound record has a configurable bound. Queue-full
conditions apply backpressure rather than borrowing transport storage or
growing without limit. Parsed requests and replies own their JSON documents,
so event values remain valid independently of receive-buffer reuse.

Varlink replies are not multiplexed. The client associates replies with calls
in wire order. The server allows handlers to finish out of order, but buffers
their replies until each call reaches the front of that order. `oneway`,
streaming `more`/`continues`, and incompatible flag combinations are enforced
by the state machines.

For an accepted upgrade, `feed` stops at the Varlink record delimiter and
leaves custom-protocol bytes with the caller. A server confirmation transmit
has `after_send == .upgrade`; the transport must switch protocols only after
that complete record has been written.

## Interfaces and services

`Interface.parse` produces an owned AST for a `.varlink` description and
preserves its exact source for introspection. It validates names, duplicate
members and fields, type syntax, local references, comments, and Varlink's
Unicode whitespace.

`Service` owns implementation metadata and a fixed-capacity registry of parsed
interfaces. It always registers `org.varlink.service`. Call `Service.handle`
first for each server event; `true` means the standard request was consumed,
while `false` leaves an application request for normal dispatch. Standard
oneway calls are consumed without a reply.

The registry also provides `validateRequest`, `validateMethodInput`,
`validateMethodOutput`, and `validateError`. Validation resolves local and
fully-qualified registered types and reports the interface, member, or
top-level parameter that failed. This is also the schema boundary available to
typed native adapters; the Lua client currently sends dynamic JSON without
loading an interface description.

`Address.parse` recognizes standard `unix:`, abstract `unix:@`, `tcp:`
(including bracketed IPv6), and `device:` addresses. It intentionally ignores
properties after `;`, as required by Varlink. Turning an address into a socket
or device remains transport work.

## Ownership summary

- `Client`, `Server`, `Interface`, and `Service` are owning values and require
  `deinit`.
- Events and transmits transfer ownership to the caller and require `deinit`.
- Outgoing `std.json.Value` parameters are borrowed only for synchronous
  serialization; queued transmits own the resulting bytes.
- Service metadata and registered interface descriptions are copied and owned.
- Parsed `Address` slices borrow from the original address string.
