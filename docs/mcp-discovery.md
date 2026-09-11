# Local MCP application discovery

This is Ouro's version 1 discovery convention, independent of MCP's wire
protocol. The bridge is a separate `ouro-mcp` project. No registry daemon is
required. The first bridge supports MCP `2026-07-28` only.

## Installed descriptors

Install `<application-id>.json` under `ouro/mcp/apps` in an XDG data directory.
Search `$XDG_DATA_HOME` first, then each `$XDG_DATA_DIRS` entry in order. Unset
or empty variables use `~/.local/share` and `/usr/local/share:/usr/share`.
Ignore relative XDG directories. The first file for an ID wins as a whole;
an invalid higher-priority file must not expose a lower-priority application.
Only IDs consisting of ASCII letters, digits, dot, underscore and hyphen are
accepted, excluding empty, `.` and `..`. The filename must match the ID.

```json
{
  "schema_version": 1,
  "application_id": "dev.ourokit.contacts",
  "endpoint": {"runtime_path": "ourokit/apps/dev.ourokit.contacts"},
  "tools": []
}
```

`tools` contains the same complete Tool objects as the application's
`tools/list`, including runtime tools and error-aware output schemas. Tool
names must be unique. The endpoint is relative to an absolute
`$XDG_RUNTIME_DIR`; reject absolute paths, empty segments, `.` and `..`.
It names the socket file itself, not a directory; append no extra filename.
Do not expand environment variables or execute commands from descriptors.
System-installed applications still use per-user runtime sockets. Enabling
their socket units is the installer's responsibility.

Descriptors are bounded to 256 KiB, UTF-8 JSON, and are written atomically.
Export runs the application's declaration for packaging, never its UI factory
or action handlers. It is not an untrusted-code sandbox. Bridge discovery
only reads descriptors and never executes exports or connects to all apps.

## Running applications

Running apps publish the same descriptor to
`$XDG_RUNTIME_DIR/ouro/mcp/apps/<application-id>.json` with an additional field:

```json
{"runtime":{"pid":1234,"start_ticks":"987654"}}
```

`start_ticks` is field 22 of Linux `/proc/<pid>/stat`, represented as a decimal
string. Accept an override only while that process exists, belongs to the
current UID, and has the matching start time. Runtime directories/files must
be owned by that UID, non-symlink, and inaccessible for writing by others.
This prevents stale catalogs from surviving a crash or PID reuse. These are
same-user discovery hints, not authentication or permission grants.

An override applies only to an installed, permitted app with the same ID and
endpoint. It does not independently expose uninstalled processes. It replaces
the installed tool catalog, never its endpoint. Publish on successful catalog
changes, not failed reloads. Graceful shutdown removes only the publisher's
own file; a replacement must be preserved. Publication failures must not
invalidate an already committed application generation.

Bridges watch installed and runtime descriptors (bounded local rescanning is
acceptable), without waking apps. Removing a live override restores the
installed baseline. Changing the selected installation or descriptor invalidates
its cached live catalog. This version has one service endpoint per application;
multiple bridge processes do not imply multiple application instances.

## Bridge behavior

Each `ouro-mcp` process serves one stdin/stdout MCP connection. Optional repeated
`--app <application-id>` arguments restrict the exposed applications. With no
filter, expose the discovered catalog; configure the host's tool approvals
accordingly. Logs go to stderr. EOF cancels/drains this bridge's requests and
subscriptions, not other bridges or applications.

Exposed tool names are `ouro_` plus the lowercase hex SHA-256 digest of
`UTF-8(application_id) + NUL + UTF-8(original_tool_name)`. This yields stable,
collision-resistant names within MCP's 128-character limit. Descriptions are
prefixed with the application ID and original name for model visibility.
Arguments and results retain their original schemas and shape.
Preserve JSON number lexemes in forwarded arguments, results, schemas and
caches; binary floating-point conversion must not alter validation or values.

On first use, connect to the app's socket, request `subscriptions/listen` with
`notifications.toolsListChanged: true`, validate acknowledgment, then fetch
`tools/list`. Ordinary method-not-found/unsupported-filter responses fall back
to on-access discovery; transport errors do not authorize replay. Keep at most
one list refresh outstanding, with a dirty reread for changes during refresh.
Notify subscribed upstream clients when the aggregate catalog changes.
Forward tool calls with bridge-owned downstream IDs; correlate and translate
cancellation and subscription IDs. Never automatically retry tool calls.

Only complete results are supported; absent `resultType` falls back to complete.
Enforce the 256 KiB wire bound and bounded requests, subscriptions and output.
Return honest errors for disconnected apps, stale removed tools, capacity
limits and unsupported protocol versions. One slow peer must not create
unbounded queues or affect another bridge process.

## Cache

Store live tool-list results below `$XDG_CACHE_HOME/ouro/mcp` (default
`~/.cache/ouro/mcp`). Cache keys include the selected descriptor content and
origin, endpoint, protocol revision, and effective exposure/authorization
context. A cache is disposable and never registers an app on its own.

Honor MCP `ttlMs` and `cacheScope`. A changed-tool notification invalidates the
cache immediately. Expiry is checked on access, not an app-waking timer.
Randomize refresh eligibility earlier within the advertised TTL, persist the
chosen expiry, and coordinate concurrent refreshes using a per-entry lock,
rechecking freshness after acquiring it. Use atomic replacement. Corrupt cache
entries are misses, and `ttlMs: 0` is never a fresh entry. Never cache tool-call
results or replay mutations after a missing response.
