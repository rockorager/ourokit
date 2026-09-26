# Desktop services

`ouro.desktop` provides asynchronous desktop integration without toolkit or
subprocess dependencies. Calls must run in an Ouro task and return `nil,
error_table` on failure.

File and URI operations use the XDG Desktop Portal. This is the standardized,
sandbox-safe API and supplies native desktop choosers:

```lua
local files = assert(ouro.desktop.choose_file{
  parent='main', title='Open image', multiple=true,
  filters={{name='Images', patterns={'*.png','*.jpg'}, mime_types={'image/*'}}},
})
local destination = assert(ouro.desktop.choose_save_file{
  parent='main', current_name='output.png', current_folder='/tmp',
})
assert(ouro.desktop.open_uri('https://ourokit.dev', {parent='main'}))
assert(ouro.desktop.open_file(fd, {parent='main'})) -- a D-Bus FD value
```

`open_uri` and `open_file` pass supported `ask`, `writable`, and
`activation_token` options to the portal. `open_uri` rejects every `file:` URI;
open the file and pass its D-Bus FD value to `open_file` instead. A chooser
filter may contain glob `patterns`, `mime_types`, or both.

Omit `parent` for an unparented request. Otherwise Ourokit exports that window
and holds its `wayland:` handle until the request completes. Export failure is
explicit. Choosers return file URIs (an array for open and one URI for save).
Cancellation is reported as `Canceled`. Portal requests pre-subscribe to
`Response`, correlate the returned object path, validate sender/signature, and
send `Request.Close` during scope cancellation.
The initial method reply has a five-second deadline; the human-facing dialog
does not time out. Losing the portal service fails the wait. No file chooser UI
is implemented or installed by Ourokit.

Notifications use `org.freedesktop.Notifications`, rather than the portal,
because that is the standard notification API and provides replacement IDs,
close, actions, and close reasons used by this API. Ourokit is only a
client; it never owns or implements the notification service.

```lua
local notifications <close> = assert(ouro.desktop.notifications())
local build = assert(notifications:send{
  title='Build finished', body='Click to inspect',
  actions={{id='open', label='Open'}}, timeout=5000,
})
assert(notifications:replace(build, {title='Build failed', body='3 errors'}))
local event = assert(notifications:next()) -- action or closed
-- event.type, event.notification, event.action / event.reason
assert(notifications:withdraw(build))
```

Handles include the daemon's unique sender identity, preventing IDs from a
restarted service being mistaken for old notifications. Replacement across a
restart fails with `ServiceRestarted`; closed handles are stale. `close()` only
releases client resources and does not claim a bus name.
Activation tokens received before `ActionInvoked` are retained and returned as
`event.activation_token`. `next(timeout_ms)` supports a bounded wait and reports
service disappearance rather than waiting forever.

## Text and file-URI drag-and-drop

Boxes accept `on_drop_text=function(text) ... end` and
`on_drop_uris=function(uri_list) ... end`. The latter receives raw validated
`text/uri-list` bytes: skip blank lines and `#` comments and split on line ends.
Receiving a URI never reads or opens it automatically. Transfers are bounded
by the clipboard payload limit and use asynchronous pipes; stale/reloaded
widget callbacks cannot receive a completed old transfer.

Call `ouro.start_drag{text='hello'}` or
`ouro.start_drag{uris={'file:///tmp/note.ournote'}}` directly in a pointer-press
callback. Only a real compositor pointer press supplies the required serial;
keyboard activation, development input, child tasks, and post-yield calls fail
with `NoPointerInput`. Outbound drags require `wl_data_device_manager` v3 or newer.
Drags negotiate copy only; move, drag icons, and arbitrary
MIME payloads are not supplied in this first API.

`zig build verify` exercises private D-Bus portal/notification fixtures and
native document/drag workflows on disposable Sway. Native input tests require
`cc`, `pkg-config`, `wayland-scanner`, and `libwayland-client` development files
in addition to the existing native-test dependencies. These are test-only
dependencies; Ourokit itself still uses its own Wayland transport.
