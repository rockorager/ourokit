# MCP

Ourokit, ourosettings, and the Ouro compositor use MCP over local Unix sockets.
This document defines their transport contract and Ourokit's Lua client API.
The [discovery contract](mcp-discovery.md) defines installed and runtime
catalogs for the separate `ouro-mcp` stdio bridge. Agent authorization and
multi-instance application routing remain separate from discovery metadata.

## Local transport

Use MCP revision `2026-07-28`, JSON-RPC 2.0, and UTF-8 JSON records terminated by
one newline over Unix stream sockets. A connection may carry concurrent requests
and resource subscriptions; correlate replies by request ID, not wire order.
Bound records to 256 KiB including the delimiter. Preserve each host's existing
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
`cacheScope: "private"`; settings discovery and resource reads retain `ttlMs: 0`.
Tool-list notifications invalidate fresh cache entries immediately. TTL is a
freshness bound checked on access, not an app-waking polling interval. Local
clients and the first bridge do not support initialization-based MCP revisions.

## Settings resources

The complete settings resource is `ouro://settings`. A resource URI's path is
an RFC 6901 JSON pointer, percent-encoded for transport. Decode URI escapes once,
then apply JSON pointer escaping. Encode bytes other than URI unreserved
characters and `/` as uppercase percent escapes. Reject query strings,
fragments, malformed escapes, and invalid pointers. Do not normalize slashes or
Unicode. Examples:

- `ouro://settings/compositor`: compositor configuration.
- `ouro://settings/appearance/color_scheme`: appearance preference.
- `ouro://settings/`: the empty-name member at the settings root, not the root.
- A key `a/b` is the pointer segment `a~1b`; a literal `%2F` is `%252F`.

`resources/list` includes the root and supported settings section resources.
`resources/templates/list` advertises the pointer resource family. Resource
contents have MIME type `application/json` and a `text` field encoding:

```json
{"revision":"opaque-store-revision","exists":true,"value":{"general":{}}}
```

`revision` is the existing global optimistic-concurrency token, not a numeric
sequence. A valid pointer that selects no value is still a readable selection
resource: return `exists: false, value: null`. Stored JSON null instead returns
`exists: true, value: null`. Unsupported resource families are invalid resource
requests, not missing selections. Settings persistence and normalization remain
authoritative; reading must not reinterpret their missing/null behavior.
Preserve number lexemes in compositor JSON: `1`, `1.0`, and `1e0` can have
different validity in Ouro's integer fields. Transport decoding must not change
which settings the compositor accepts.

## Settings mutations

Expose `settings.set` and `settings.set_section` through `tools/list` and
`tools/call`, with JSON Schemas and descriptions explaining full replacement:

- `settings.set`: `{ expected_revision, settings }` replaces all settings.
- `settings.set_section`: `{ expected_revision, section, value? }` replaces one
  complete section. Omitted/null `preferred_output` clears it; other sections
  reject omitted/null values, as before. This is not a merge operation.

Success uses `structuredContent: { revision, settings }` plus serialized JSON
in a text content block. If duplicating the complete JSON would exceed the
record limit, text contains only `{ revision }`; `structuredContent` still
contains the complete result. This keeps large valid writes acknowledgeable
without lowering the settings store's existing size limit.

Tool execution failures use `isError: true` and
`structuredContent: { error: { code, message, revision? } }`. Codes are
`Conflict`, `InvalidParameters`, and `PersistenceFailed`; `Conflict` includes
the current revision. Output schemas cover both success and execution failure.
Malformed RPC envelopes and unknown tools use JSON-RPC errors instead.

Preserve atomic persistence, no-op suppression, validation, and fail-stop
behavior for an ambiguous durable commit. A successful write means desired
settings were persisted, not that compositor hardware changes have completed.
Never automatically replay a mutation after losing its response.

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

Ouro preserves its initial settings validation gate, runtime last-good config,
retry backoff, and application-safe-point handoff. Ourokit's native appearance
service likewise reconnects and retains its last good color scheme. Ordinary
windows inherit this service without requiring a Lua subscription.

## Keybinding calls

Keep Ouro's `call` configuration shape:

```json
["call", "unix:/run/user/1000/example.sock", "toggle_launcher", {}]
```

The address after `unix:` is a literal absolute path or `@`-prefixed Linux
abstract socket name. Semicolons are part of the name, not transport properties.

The third field becomes an MCP tool name rather than a qualified Varlink
method. Send `tools/call` with `name` and `arguments`. A configured call needs no
discovery round trip. Preserve nonblocking independent calls, the five-second
timeout, the 16-call bound, and no retries. Treat JSON-RPC errors and
`isError: true` as failures; discard successful results. Unsupported interim
results must fail explicitly rather than look successful. Existing Varlink
targets must migrate; unchanged configuration shape is not wire compatibility.

## Cutover

ourosettings exposes only MCP at `$XDG_RUNTIME_DIR/ouro/settings.mcp.sock`.
The `--socket` option overrides that path. One systemd listener activates one
process with one settings store. There is no Varlink endpoint, dual-protocol
dispatch, or wire-compatibility bridge.

Ourokit's appearance service, Lua clients, app control server, and `ouroctl`
use MCP exclusively. There are no legacy API aliases or IDL declarations.

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
local address = "unix:" .. assert(ouro.xdg.runtime_dir) .. "/ouro/settings.mcp.sock"
local uri = "ouro://settings/appearance/color_scheme"
local reply = ouro.mcp.request(address, "resources/read", {uri = uri})
if reply.error then error(reply.error.message) end
local selection = ouro.json.decode(reply.result.contents[1].text)
-- selection.exists distinguishes a missing value from stored JSON null.
```

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
of intermediate values. The [watch example](../examples/ourosettings-watch.lua)
demonstrates this flow; [the one-shot example](../examples/ourosettings.lua)
prints the current color scheme.

Every source generation owns 16 concurrent client slots by default, shared by
requests and subscriptions. Each uses an independent Unix connection, bounded
256 KiB records and a 64 KiB receive chunk. Scope cancellation, reload, and exit
cancel and drain active `io_uring` operations before releasing their buffers;
this also covers a callback suspended on another resource. Outbound clients
are available regardless of whether the app enables an inbound server.

## App tools and ownership

Declaring `actions = {}` enables `runtime.status`, `runtime.reload`, and
`runtime.activate`, plus `server/discover` and `tools/list`, at
`$XDG_RUNTIME_DIR/ourokit/apps/<application-id>`. Custom actions declare
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
are handled by the bridge and native MCP clients.

Use `FileDescriptorName=mcp` for systemd socket activation. The host checks
same-user peer credentials and retains existing listener/pathname ownership
rules. Activation, reload, and in-flight action lifetimes remain host-owned.

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
