# MCP

Ourokit supports MCP over local Unix sockets for application automation and
optional agent integrations. This document defines its transport contract and
Lua client API. Desktop appearance uses the D-Bus Settings portal, not MCP.
The [discovery contract](mcp-discovery.md) defines installed and runtime
catalogs for optional MCP consumers. Agent authorization and
multi-instance application routing remain separate from discovery metadata.

## Local transport

Use MCP revision `2026-07-28`, JSON-RPC 2.0, and UTF-8 JSON records terminated by
one newline over Unix stream sockets. A connection may carry concurrent requests
and resource subscriptions; correlate replies by request ID, not wire order.
Bound records to 4 MiB including the delimiter. Preserve each host's existing
event-loop ownership, peer checks, short-write handling, and cancellation rules.

Every request carries `params._meta` with
`io.modelcontextprotocol/protocolVersion: "2026-07-28"` and
`io.modelcontextprotocol/clientCapabilities: {}`. Include client identity in
`io.modelcontextprotocol/clientInfo`. There is no `initialize` handshake.
Ordinary results carry `resultType: "complete"`. Unsupported versions produce
JSON-RPC error `-32022` with `data.supported` and `data.requested`.

Servers always emit `resultType`. Clients follow MCP's required fallback for an
absent `resultType`, treating it as `"complete"`; present but malformed or unknown
values are invalid. This does not add support for legacy version negotiation.

Servers implement `server/discover` and the discovery methods for advertised
capabilities. Ourokit app discovery and tool lists use `ttlMs: 60000` and
`cacheScope: "private"`.
Tool-list notifications invalidate fresh cache entries immediately. TTL is a
freshness bound checked on access, not an app-waking polling interval. Local
clients and the first bridge do not support initialization-based MCP revisions.

## Subscription and read ordering

Use `subscriptions/listen` with `notifications.resourceSubscriptions`. Its
first notification is `notifications/subscriptions/acknowledged`, echoing the
accepted URI filter. Each subscription notification carries the listen request
ID in `_meta["io.modelcontextprotocol/subscriptionId"]`.

Notifications contain the changed URI, not its value or revision. Notify only
when that URI's selected value or existence changes; unrelated commits and
no-op writes do not notify. Multiple subscriptions and ordinary requests can
share a connection. Cancellation uses `notifications/cancelled` with the listen
request ID; disconnect discards subscription state.

Clients subscribe, await acknowledgment of their URI, then read current state.
Keep at most one read outstanding per watched resource. A notification during
that read marks it dirty; after accepting the response, issue another read if
dirty. This avoids missing a change without accumulating reads. Reconnect means
subscribe and read again, not replay. Ignore stale completions from a retired
connection. Bounded output can coalesce invalidations or disconnect a slow
subscriber; it must not silently drop the last invalidation on a live stream.

## Lua client API

Use these functions from a yieldable Ouro task, not a UI build function:

- `ouro.mcp.call(address, tool_name, arguments?)` sends `tools/call`.
- `ouro.mcp.request(address, method, params?)` sends an ordinary MCP request,
  such as `server/discover`, `tools/list`, or `resources/read`.
- `ouro.mcp.subscribe(address, uri, callback)` listens for one resource URI.

Calls and ordinary requests return `{result=...}` or `{error=...}`. `result`
is the complete MCP result object; `error` is the JSON-RPC error object with
`code`, `message`, and optional `data`. A tool execution failure is a successful
RPC exchange with `result.isError == true`, not `reply.error`. Transport,
framing, capacity, and unsupported-result failures raise Lua errors. No call is
automatically retried.

```lua
local ouro = require("ouro")
local address = "unix:" .. assert(ouro.xdg.runtime_dir) .. "/example-service.sock"
local uri = "example://documents/current"
local reply = ouro.mcp.request(address, "resources/read", {uri = uri})
if reply.error then error(reply.error.message) end
ouro.stdout.write(reply.result.contents[1].text .. "\n")
```

The address after `unix:` is a literal absolute path or `@`-prefixed Linux
abstract socket name. Semicolons are part of the name, not transport properties.

Parameters must be JSON objects. String-keyed Lua tables encode objects,
dense integer-keyed tables encode arrays, and `ouro.json.array()` constructs
an empty array. Decoded arrays retain their array identity. `ouro.mcp.null`
and `ouro.json.null` are the same JSON-null sentinel. Conversion in both
directions is bounded to 32 nesting levels and 4096 values; numbers must be
finite. Lua's numeric types cannot losslessly represent every JSON number;
use resource text unchanged when exact number lexemes matter.

`subscribe` suspends the current task between notifications; it does not start
a background task. The callback first receives a matching acknowledgment, then
resource invalidations as `{method, params}`. Read the resource after the
acknowledgment and after each update. A terminal listen result or RPC error is
delivered as `{result}` or `{error}` and ends the subscription. EOF without a
terminal result raises an error. The subscription does not reconnect itself.

Callbacks may yield, update signals, and issue independent `request` calls.
Returning exactly `false` stops immediately and closes the subscription's
connection, discarding buffered notifications. Callback errors also close it.
Reads pause during callbacks; there is no unbounded callback queue. A slow
subscriber may be disconnected by its server and must establish a new
subscription before rereading. Notifications are invalidations, not a history
of intermediate values.

Every source generation owns 16 concurrent client slots by default, shared by
requests and subscriptions. Each uses an independent Unix connection, bounded
4 MiB records and a 64 KiB receive chunk. Scope cancellation, reload, and exit
cancel and drain active `io_uring` operations before releasing their buffers;
this also covers a callback suspended on another resource. Outbound clients
are available regardless of whether the app enables an inbound server.

## App tools and ownership

`ouroctl run --mcp` explicitly exposes declared actions, `server/discover`, and
`tools/list` at `$XDG_RUNTIME_DIR/ourokit/apps/<application-id>`.
Declaring actions alone enables no inbound server. `--dev` creates a separate
private per-instance endpoint with development status/reload tools, regardless
of actions. Production catalogs never include runtime tools. Custom actions declare
`description`, `inputSchema`, `outputSchema`, and `handler` together. See
[the application model](application-model.md) and the runnable
[Contacts service](../examples/contacts/README.md). Installed descriptors and
process-identified runtime catalogs allow offline discovery without a broker.

App servers advertise `tools.listChanged: true`. Clients request
`subscriptions/listen` with `notifications: {toolsListChanged: true}`, verify
the accepted acknowledgment, then fetch `tools/list`. A successful reload that
changes tool names, descriptions or schemas emits `notifications/tools/list_changed`.
Handler-only changes and failed reloads do not invalidate the catalog. Each
notification carries the listen request ID in subscription metadata. Canceling
the listen yields a terminal complete result; disconnect discards its state.
The resource-only Lua `subscribe` helper is unchanged; catalog subscriptions
are handled by native MCP clients and optional consumers.

The host checks same-user peer credentials and removes only paths it owns.
No inherited systemd MCP listener is adopted. Desktop launch and activation use
desktop entries and `org.freedesktop.Application`, not MCP. Reload and runtime
diagnostics are development-only; in-flight action lifetimes remain host-owned.

The public `ourokit.mcp.Client` and `Server` are sans-I/O state machines:

1. Feed bytes and retain any unconsumed suffix during backpressure.
2. Drain events; each owns its parsed JSON document and needs `deinit`.
3. Drain transmits; each owns bytes and an offset for short writes. Write
   `remaining()`, advance with `consume`, and release after `complete()`.
4. Call `endInput` on EOF; an incomplete record is `TruncatedMessage`.

Requests correlate by ID, not response order. Client `CallHandle.value` is the
numeric wire ID. Server handles are private tokens whose pending records own
the peer's string or numeric ID. Outgoing JSON values are borrowed only during
serialization. Parsed `Address` slices borrow from their input. Protocol errors
are fatal to a client transport; they never authorize replaying its request.

## Sources

- [MCP 2026-07-28 changes](https://modelcontextprotocol.io/specification/2026-07-28/changelog)
- [Transport bindings](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports)
- [Subscriptions](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions)
- [Resources](https://modelcontextprotocol.io/specification/2026-07-28/server/resources)
- [Tools](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
- [Server discovery](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)
