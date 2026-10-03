# System audio

All public audio APIs live under `ouro.audio`. This first surface controls the
default **system output**, using libpipewire directly. It does not use PulseAudio,
`wpctl` subprocesses, WirePlumber libraries, or D-Bus. A session manager normally
publishes PipeWire's `default.audio.sink` metadata; Ourokit follows that resolved
default rather than inventing its own device-selection policy.

```lua
local ouro = require('ouro')
local output = assert(ouro.audio.default_output())

-- In a UI build, this read subscribes that build to confirmed changes.
local state = output()
if state.available then
  -- state.name, state.description, state.volume, state.muted
end

-- In event handlers/tasks:
local ok, err = output:set_muted(true)
ok, err = output:set_volume(0.5)
ok, err = output:adjust_volume(0.05) -- safe for rapid repeated volume keys

-- Optional side effects outside rendering (e.g. a short volume OSD):
ouro.spawn(function()
  while true do
    local current, reason = output:next()
    if not current then break end
    -- Compare confirmed volume/mute/identity with your previous snapshot.
    -- Update signals or start your application's OSD expiry timer here.
  end
end)
```

## Snapshots and lifetimes

`default_output()` takes no arguments and must run in an Ouro task, outside a UI
build. Keep one handle for the bar/controller lifetime, not one per render.
Creation does not wait for the audio server. Initial state is unavailable; server
startup, disconnect, reconnect, default changes, and hot-unplug are observed
asynchronously. Retries use an approximately one-second interval. Missing metadata
or a default name that does not resolve to an `Audio/Sink` means unavailable.

`output()` returns a new Lua table; mutating it does not change the backend:

| Field | Meaning |
| --- | --- |
| `connected` | A PipeWire connection exists. |
| `available` | The selected sink has usable volume/mute parameters. Not a guarantee of audible playback. |
| `identity` | Handle-local identity token; never reused across removal/reconnect. Absent without a selected sink. |
| `id` | PipeWire node ID, recyclable by the server; do not persist it. |
| `name` | PipeWire `node.name` for the selected sink. |
| `description` | Human-readable `node.description`, possibly empty. |
| `volume`, `muted` | Present only when `available` is true. |
| `error` | Optional asynchronous error name; see below. |

`output:next()` is a yielding, task-only change stream. Its first call returns the
current snapshot, then calls return the latest newer snapshot, coalescing bursts
instead of accumulating an unbounded event queue. There may be only one waiting
reader per handle. Reactive `output()` reads do not consume the stream. Compare
fields to detect meaningful volume changes; connection and identity changes also
wake readers.

`output:close()` is idempotent and wakes a pending `next()` with `nil,
"OutputClosed"`. Lua `<close>`, garbage collection, owner-scope cancellation,
generation retirement, and process shutdown also close it. Canceling a task
waiting in `next()` closes that handle. Native resources are reaped asynchronously;
callbacks and PipeWire teardown do not run on the UI thread. Do not use a
top-level `<close>` local for a handle retained by returned application callbacks:
that local closes when the entry chunk returns, not when the bar unmounts.

## Volume and control semantics

The public scale is cubic/perceptual: `0` is silence and `1` is 100%/unity gain.
PipeWire receives linear gain `volume³`, so `0.5` writes `0.125`. Reading applies
the cube root to **channel 0**, matching wpctl's scalar convention. Observations
can exceed `1` if another mixer enables amplification. `set_volume` accepts only
finite numbers in `[0, 1]`; it deliberately does not enable amplification.
All channel volumes are set equally, resetting balance. Muting does not change
volume, and changing volume does not unmute.

`adjust_volume(delta)` accepts finite `[-1, 1]` and clamps its result to `[0, 1]`.
The worker serializes accepted adjustments against pending commands and confirmed
backend values, avoiding lost increments from repeated reads of a stale Lua
snapshot. Concurrent writes by other mixer clients can still race; there is no
cross-client atomic mixer transaction.

Hardware outputs use active Device `Route` parameters matched by `device.id` and
`card.profile.device`, with `save=true`; sinks without usable Route controls use
Node `Props`. No hardware/session policy or device switching is performed.

Setters return `true` when queued, **not** when acknowledged. Snapshots are never
optimistically changed. Commands carry the selected sink's identity and are
rejected/dropped rather than retargeted if the default changes or the service
reconnects. Observe subsequent snapshots to show the confirmed result.

## Errors and limits

Fallible operations return `nil, error_name` (a string). Common names:
`InvalidArguments`, `InvalidVolume`, `InvalidMute`, `TaskRequired`,
`OutputUnavailable`, `OutputClosed`, `AlreadyWaiting`, `StaleOutput`,
`AudioQueueFull`, `AudioCapacityExceeded`, `AudioUnavailable`, and `AudioStopped`.
Reload candidates may observe audio, but setters return `AudioCandidate` until
the generation commits; evaluating rejected candidate code cannot change audio.
Allocation/scheduler failures report `OutOfMemory`, `SignalCapacityExceeded`,
`ResourceCapacityExceeded`, `CouldNotPrepare`, `CouldNotPark`, or
`CouldNotTrackSignal`.

Asynchronous PipeWire failures appear in `snapshot.error`: `PermissionDenied`,
`StaleOutput`, `AudioBackendError`, or `AudioCapacityExceeded`. They clear on a
new connection or successful command submission. No write is automatically
retried across reconnect. A server may silently clamp or ignore unsupported
controls; always render the confirmed snapshot rather than treating acceptance
as success. There are at most eight handles per generation, 32 queued commands
per handle, 256 observed nodes/devices, and 64 active routes per device.

## Build and verification

Building requires PipeWire/SPA development headers (`libpipewire-0.3-dev` on
Debian); runtime requires `libpipewire-0.3-0`. Verified with PipeWire 0.3.65.
`zig build test-audio` starts a private daemon with silent null sinks, a private
runtime directory/socket, and no hardware/session manager. It exercises the real
protocol, external changes, units, rapid adjustments, selection changes,
hot-unplug, reconnect, Lua delivery, and cleanup. Test tools require `pipewire-bin`,
GCC, pkg-config and Python 3. They do not touch the user's audio service.
Active hardware Route parsing, profile matching, saved writes and permission
rejection use a worker-level SPA-pod fixture; real ALSA/Bluetooth hardware is not
available in the orb. Repeated source reloads test candidate write isolation,
activation after commit and worker retirement.

Playback/recording, codecs, video and A/V synchronization are outside this API.
Future app-local playback can live alongside this controller under `ouro.audio`;
its player volume will be distinct from system-output volume.
