# Native session services

`ouro.session` supplies Wayland idle notifications, output power control and
**ext-session-lock-v1** ownership. `ouro.auth` supplies asynchronous Linux PAM
conversations. These are built-in capabilities, not native plugins or commands
launched by the shell. Ourokit does not choose inactivity timeouts, suspend
policy, a PAM service/account, or a lock-screen design.

Create session resources from `ouro.app.run` or its tasks, after the native host
is attached. Read events in an Ourokit task (`ouro.spawn` or a widget callback).
There is one outstanding reader per resource. Native callbacks never enter Lua;
events resume readers at the task safe point. Invalid session arguments and
invalid operations raise Lua errors. Protocol absence is an asynchronous
`"failed"` event, never an insecure fallback.

## Idle and output power streams

```lua
local idle <close> = ouro.session.idle(300000) -- milliseconds, uint32
while true do
  local event = idle:next()
  if event == "idled" then
    -- Apply the shell's inactivity policy, unless caffeinate is enabled.
  elseif event == "resumed" then
    -- Reset the shell's inactivity policy.
  else
    break -- failed or closed; do not busy-loop on a terminal stream
  end
end
```

`idle(timeout_ms, input_only?)` defaults to `false`: ext-idle-notify v1 honors
surface idle inhibitors. `true` requires v2 and measures input inactivity even
when another client inhibits idle. It fails rather than silently falling back
on a v1 compositor. Notifications use the host's current seat; seat removal
fails existing idle streams. Recreate them for a replacement seat.

The harmless [idle observer example](../examples/session-idle.lua) renders the
events without locking, suspending or changing display power.

```lua
local power <close> = ouro.session.power("DP-1") -- wl_output.name
local mode = power:next() -- "on", "off", or "failed"
if mode == "on" then
  power:set(false)
  -- Wait for "off"; set() itself only queues the request.
end
```

Power uses wlr-output-power-management v1. The compositor controls whether it
grants ownership; another controller, an absent output/protocol, or output
removal can produce terminal `"failed"`. Recreate the stream after hotplug.
`set(boolean)` coalesces unsent requests to the latest value. `on`/`off` events
report compositor state. Power-off is **not** a security boundary: lock and
await its acknowledgement first if the screen must be secured. Closing power
ownership does not promise to restore the display; wake/restore is shell policy.

Idle/power `close()`, Lua 5.4 `<close>`, garbage collection, task-wait
cancellation, and generation retirement release native ownership. After the
terminal event has been consumed, `next()` returns `"closed"`. There are 32
session resource slots per process and 16 queued events per resource. A slow
consumer that overflows its queue gets terminal `"failed"`, not lost transitions
presented as a valid acknowledgement. Close terminal handles to reclaim slots.

`ouro.session.outputs()` returns an output-topology stream. Its first `next()`
returns a full, sorted, dense array of names, including `{}` when there are no
outputs. Discovery waits for names of connected outputs, rather than reporting
an incomplete array while registry binding is in progress. Later reads return
full snapshots after coalesced topology or name
changes. Terminal reads return `nil, "closed"` or `nil, "failed"`. `close()`,
`<close>`, GC, task cancellation, and generation retirement are scoped like the
other session resources.

## Secure lock ownership and output surfaces

```lua
-- Keep this in long-lived shell state, not a transient component task.
local lock = ouro.session.lock()
show_lock_ui:set(true)
local event = lock:next()
if event == "locked" then
  -- ONLY here may the shell close its logind sleep-delay inhibitor FD.
elseif event == "finished" or event == "failed" then
  -- No acknowledgement: report failure; do not pretend the session is secured.
end
```

`lock()` requests exclusive session-lock ownership. Only one pending/held lock
is allowed. Declare its UI through the application's reactive `windows`:

```lua
windows = function()
  if not show_lock_ui() then return {} end
  return {
    ouro.lock_surface {
      id = "lock",
      outputs = "all",
      background = "#182233",
      content = function(output_name)
        return render_lock_screen(output_name) -- ordinary Ourokit widgets
      end,
    },
  }
end
```

Use `outputs = "all"` to cover existing and newly connected outputs, or
`output = "DP-1"` for one named output; exactly one selector is required.
Output-template expansion supplies each output name to `content`, with an
independent retained UI/input tree and compositor-configured logical size.
Stable IDs retain state. The same output cannot have two lock declarations.
The native role is always `ext_session_lock_surface_v1`, **never a layer-shell
overlay**, despite sharing internal output/render plumbing with layer windows.
Ourokit acknowledges configure before the first correctly sized non-null
buffer, and uses its normal software/Vulkan rendering and keyboard/pointer
routing. Lock surfaces cannot parent native popups; use in-surface UI instead.
Do not remove/re-add a surface on the same output during one lock ownership:
the protocol allows only one lock surface per output per lock object.

`"locked"` comes from the compositor, not from creating a surface, drawing a
frame, a timer, or receiving configure. Current Ouro waits for presentation on
active KMS outputs before this acknowledgement. Newly connected outputs are
still protected by the compositor while their lock surface is being created.
This depends on the compositor's security implementation, not the client UI.

After a successful authentication result, call `lock:unlock()` on that exact
acknowledged handle. Calling before `locked`, or using a handle from an earlier
lock, raises an error. `lock:next() == "unlocked"` means the native
`unlock_and_destroy` request was queued, **not an unlock acknowledgement** (the
protocol has none). Stop showing the UI after this event; later locks create
fresh native surfaces even if the declaration IDs are retained.

`"finished"` means the compositor ended that lock object: refusal before
acknowledgement, or a compositor-authorized end after acknowledgement. Do not
interpret it as authentication success. `"failed"` is also terminal but does
not prove the desktop is unlocked if a lock was already requested.

### Failure and reload stay fail-closed

- Closing, garbage-collecting or canceling a pending/held lock **never unlocks
  or destroys it**. Keep its handle reachable; `close()` is deliberately not
  a lock cancellation API. An abandoned live lock cannot be acquired again.
- Reload is rejected with `SessionLockActive` from lock request through held or
  abandoned ownership. The old VM, lock handle and UI stay authoritative.
  Reload candidates cannot acquire locks or start authentication; their idle
  and power requests are staged until commit. Existing authentication is
  killed when an unlocked generation retires.
- Errors and normal process exit do not send an implicit unlock. Transport or
  process loss delegates fail-closed protection to the compositor. Before
  `locked`, the shell must not claim that protection was established.
- **Current Ouro does not support replacement-locker recovery after losing an
  acknowledged locker.** Restarting the locker cannot recover it. Terminate the
  locked graphical session from a trusted VT or SSH session. Do not
  restart/reload Ouroshell while locked.

Use the existing `ouro.dbus` logind APIs for `PrepareForSleep`, `Suspend`, and
`Inhibit` FD ownership. For lock-before-suspend: retain the delay FD, request the
lock, render all outputs, await exactly `"locked"`, then close the FD. A delay
inhibitor has a logind-enforced time limit; failure handling belongs to the
shell. Caffeinate gates inactivity actions only, leaving manual locking and
lock-before-suspend active. No surface idle inhibitor is needed to pause the
shell's own policy; this API does not add one.

## Asynchronous authentication

```lua
local auth, err = ouro.auth.start(pam_service, session_username)
if not auth then return false, err end
local conversation <close> = auth
while true do
  local event, read_error = conversation:next()
  if not event then return false, read_error end
  if event.type == "prompt" then
    prompt:set { conversation=conversation, prompt_id=event.id, text=event.text }
  elseif event.type == "result" then
    prompt:set(nil)
    if event.success then lock:unlock() end
    return event.success
  else
    show_auth_message(event.type, event.text) -- "info" or "error"
  end
end
```

Render each prompt with native credential entry, never `text_input`:

```lua
local p = prompt() -- read the credential-free signal in the content builder
ouro.auth_input {
  key="password", conversation=p.conversation, prompt_id=p.prompt_id,
  autofocus=true, -- default; width and height are optional
  on_submit=function() end,
  on_cancel=function() prompt:set(nil) end,
  on_error=function(code) show_entry_error(code) end,
}
```

`ouro.auth_input` is the standard Lua field recipe over `ouro.secure_entry`.
The native primitive accepts the same conversation, prompt, autofocus, and
nonsecret callbacks. It has no default background, border, radius, padding,
or fixed height; width defaults to `fill`. Customize its `height`, `padding`,
`padding_x`, `padding_y`, `alignment`, `background`, `border`, `border_width`,
`radius`, `foreground`, and `font_size`, or compose surrounding content with
ordinary layout primitives. General theme typography and foreground apply to
the unstyled mask; the stock recipe keeps its standard font size and metrics.
Keeping the same parent, key, conversation, and prompt preserves the native
credential buffer when switching between the recipe and primitive.

Neither API accepts children or a replacement mask. Styling changes only the
presentation of the native constant mask; it never exposes credential text,
length, selection, or ordinary text-editor behavior to Lua.

`auth_input` always renders the same eight-dot mask, even while empty and for
echo-on prompts. It has no getters, length, `on_change`, `value`, `text`,
`default_text`, placeholder, or key bindings. Native editing is UTF-8 and
limited to 512 bytes. Enter submits; Escape clears and cancels; Ctrl+A selects
all; Ctrl+U clears; Backspace/Delete and cursor/home/end edit natively. There is
no clipboard, IME, undo, history, development capture, or synthetic-input path.
The app may retain only credential-free signals and prompt-table metadata.
Each output has its own focus/UI tree, but controls bound to the same
conversation and prompt share one native buffer. Removing/rebinding a control
clears that buffer, including removal caused by output unplug. Inspection
exposes a fixed label and null value/selection, never credentials or length;
capture and synthetic input reject the entire affected window with
`SecureInputProtected`, including playback already in progress.

`start(service, username)` returns owned conversation userdata or `nil, error`.
Choose a distribution-installed PAM service appropriate to screen unlock and
the trusted session account; Ourokit installs no PAM policy and derives no
account from editable lock-screen text. The worker dynamically loads
`libpam.so.0` and calls `pam_start`, `pam_authenticate`, `pam_acct_mgmt`, and
`pam_end`. It does not change passwords, open a login session, set credentials,
or elevate the process. Account denial/expired credentials fail authentication.

`next()` waits asynchronously and returns one of:

- `{type="prompt", id=integer, echo=boolean, text=string}`;
- `{type="info", text=string}` or `{type="error", text=string}`;
- `{type="result", success=boolean, reason=string}` (terminal). Reasons are
  `success`, `denied`, `unavailable`, `canceled`, `timeout`, and `worker_failed`.

There is no `respond` API; Lua never receives credential bytes. Non-secret
buttons may call `auth:submit(id)` or `auth:clear_input(id)`, returning `true`
or `nil, error`. Stale/duplicate IDs are rejected. Submitted does not mean
authenticated: only a later `success=true` result permits unlock, and no error
ever unlocks. Explicit cancel makes the next read `nil, "ConversationClosed"`.
Close, `<close>`, GC, task cancellation, and retirement suppress success. Only
one reader is allowed; `AlreadyWaiting` indicates misuse.

Limits: four native workers per source generation; service/user/response
lengths 64/256/512 bytes. Service names allow ASCII alphanumeric, `-`, `_`, `.`.
PAM text is truncated to 512 bytes; up to 32 PAM messages per conversation
callback are supported. An eight-event queue overflow fails closed; there is no
backpressure.
Missing PAM or worker/backend errors yield unsuccessful results. Startup
allocation/I/O failures return an error, never success.

Authentication is process-isolated. A native supervisor thread uses
`SOCK_SEQPACKET` with a runtime-owned `/proc/self/exe --ourokit-auth-worker`:
the worker is the same binary, not a third-party helper, and does not change the
native plugin ABI. FDs are sanitized and stdio is `/dev/null`. The overall
deadline is 120 seconds, cancellation is checked every 50 ms, then the process
group receives TERM for 200 ms and KILL with a 500 ms bounded wait. A bounded
32-slot PID-only reaper handles kernel-uninterruptible workers, avoiding
indefinite pthread cancellation and shutdown waits.

Startup locks and `MADV_DONTDUMP`s entry mappings and permanently disables
shell dumps and unprivileged ptrace; workers disable dumps too. Native staging
is bounded and wiped after transfer, cancellation, and destruction. Trusted PAM
owns returned response allocations. PAM modules, privileged system processes,
and privileged inspectors are trusted; this does not claim safety against
arbitrary malicious PAM. Never substitute ordinary `text_input`, Lua strings,
logs, task results, clipboard, or persistence for `auth_input`.

## Application-scoped tasks

`ouro.spawn_app(fn)` accepts one zero-argument function, returns nothing, and
may only run from a running task. It starts in application scope and therefore
survives widget unmount, but its source generation cancels it. Only the running
generation may start one; candidate evaluation and retirement reject it.
Tasks already in application scope (including `app.run` children) should use
ordinary `ouro.spawn`. Those task bodies may run during candidate evaluation:
only their native idle/power/output requests are staged until commit. Do not
call `spawn_app` indirectly from candidate startup. Buttons whose work must
survive widget unmount should use `spawn_app`.

## Verification boundary

`zig build test-session` runs `tests/session_native.py`, `tests/auth_native.py`
and `tests/secure_entry.py` with disposable Wayland wire/render and test-only
`tests/pam_fixture.c` PAM fixtures against the just-built host;
`zig build verify` includes them. They
check protocol ordering, configured SHM pixels, independent outputs, input,
hotplug, denial/relock, reload rejection, exit without unlock, asynchronous
prompts, native editing, success/denial, stale submissions, buffer bounds,
crashes and cancellation. `Peer(root, remove_managers=False)` remains the entry
point. Fixture services require `fixture-user`: `fixture` expects `alice` then
`test-only-response`; `deny-account` accepts those but rejects account;
`blocked` ignores TERM forever; `crash` raises SIGSEGV; `edited` checks Unicode;
`end-failed` fails PAM cleanup; and `limit` checks exactly 512 `x` bytes. No real
credentials, system PAM configuration or user's compositor are touched.

These tests do not validate KMS presentation, physical display power, real
multi-monitor GPUs, actual suspend/resume, the deployed PAM stack or compositor
fail-closed security. The full 120-second timeout and kernel-uninterruptible
reaping path are not exercised; blocked PAM cancellation, retirement and shutdown are
checked against a two-second test bound. Test hardware and authentication
on a disposable Ouro session before deploying
a lock policy. The native APIs are not a completed or audited lock-screen app.
