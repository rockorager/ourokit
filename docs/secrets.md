# Secret storage

`ouro.secrets` stores application secrets through the desktop's [Secret Service
API](https://specifications.freedesktop.org/secret-service/latest/). It never
writes a plaintext fallback.

```lua
assert(ouro.secrets.set('com.example.MyApp', 'refresh-token', bytes))
local bytes, err = ouro.secrets.get('com.example.MyApp', 'refresh-token')
local removed, err = ouro.secrets.delete('com.example.MyApp', 'refresh-token')
```

All calls are scheduler-friendly asynchronous D-Bus operations. `get` returns
the binary Lua string, or `nil` with no error when absent. `set` returns `true`.
`delete` returns `true` when removed and `false` when absent. Failures return
`nil, { kind='secrets', name=..., message=... }`. Both identifiers must be
non-empty, NUL-free strings. Items are matched by the explicit attributes
`ourokit.application` and `ourokit.key` (plus an Ourokit schema attribute).

The implementation uses the Secret Service `plain` transport session. Thus the
secret travels unencrypted over the authenticated user session bus; this is
distinct from a plaintext **at-rest** fallback, which Ourokit does not provide.
Storage protection at rest and prompt policy belong to the Secret Service.
Missing services and missing default collections for new items are errors;
Ourokit does not silently create collections or persist elsewhere. Existing
items are updated in their current collection, even if the default changed.

Prompts are supported, including cancellation. Service owner loss, malformed
protocol replies, and duplicate matching items fail closed. Pending prompts are
dismissed and sessions/connections are closed when a task is canceled.
Calls stay pinned to the unique bus owner that opened the session; a replacement
service cannot receive a later operation's secret. Prompts currently use an
empty window identifier (unparented). Initial method calls have five-second
deadlines; human prompt waits do not time out. Cancellation after a successful
write/delete cannot undo the mutation. Operations are not automatically retried.

## Security limits

Lua strings are immutable, garbage-collected, and cannot be reliably zeroized.
Callers must avoid logging or retaining secret strings. Attribute namespacing
prevents accidental key collisions; it is not access-control isolation from
other processes running as the user. Ourokit never includes values in its
errors, logs, signals, labels, or persistent Lua module state.

Protocol behavior follows the Secret Service specification's Service,
Collection, Item, Session, Prompt, and `Secret` type definitions.
