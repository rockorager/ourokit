# Varlink

`ourokit.varlink` is a sans-I/O Varlink implementation. It owns protocol
framing, JSON message lifetimes, call ordering, interface descriptions, schema
validation, and the mandatory `org.varlink.service` interface. It does not open
file descriptors, submit `io_uring` operations, invoke Lua, or choose a task
scheduler.

This boundary lets the native async adapter and a later Lua binding share one
protocol implementation.

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
top-level parameter that failed. This is the intended schema boundary for a
future dynamic Lua API; raw Zig users may dispatch the owned JSON directly.

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
