# Application benchmark

This benchmark compares three small Wayland applications using either of two
matched profiles:

- `button` (default): one 480×320 window and one 160×44 clickable,
  text-labelled control;
- `settings`: one 560×360 window with a heading, a counter label, and a row of
  160×40 Increment and disabled controls. Increment updates the counter in all
  three applications.

Ourokit uses its Lua instance/reconciliation path, HarfBuzz shaping, FreeType
software glyph cache, display list, Wayring adapter, and shared raw `io_uring`.
GTK 4 uses `GtkApplication`/`GtkButton`; Qt 6 uses
`QApplication`/`QPushButton`.

Build the release binaries:

```sh
ZIG=/path/to/zig-0.16.0 tools/application-benchmark/build.sh
```

The benchmark entry point explicitly disables Vulkan. `settings.lua` is a
benchmark-owned fixture, not the evolving widget gallery. Do not compare old
results that initialized Vulkan or included the gallery's text field to this
software-only matched workload.

Run under a disposable Sway session with `sway.conf` from this directory
(floating windows, scale 1, no borders; nested or headless is fine):

```sh
tools/application-benchmark/run.py --iterations 20 --idle-seconds 5 --output results.json
tools/application-benchmark/run.py --profile settings --iterations 20 \
  --output settings-results.json
```

The harness randomizes application order in each round. Startup is process
launch to Sway's `window::new`, which occurs when the xdg-toplevel maps with a
buffer. This is a mapping/IPC receipt boundary, **not first presentation or
visible pixels**. Matching checks both application ID and launched PID. After a
configurable settling interval it reads Linux `/proc` RSS, PSS, private memory,
and consumed process CPU time. Reported values are medians
after warmups and therefore describe warm-cache launch on that machine—not cold
boot, first installation, or another compositor.

GTK is forced to its Cairo renderer and Qt uses the QWidget raster backing
store, matching the benchmark's explicitly selected Ourokit software backend.
On a minimal compositor, run the harness inside
`dbus-run-session` so the desktop toolkits see a normal session bus.

The controls have matched dimensions and behavior within each profile, not
matched pixels. GTK and Qt include mature native theme/style machinery;
Ourokit currently draws a
minimal token-colored Box/Label composition. Dynamic library pages are counted
in RSS but mostly discounted by PSS and private-memory figures, so retain all
three columns. The GTK/Qt comparison does not claim event latency:
a valid comparison needs the same injected input timestamp and a compositor-
observed presentation timestamp for all three applications.

## Idle accounting is not a wakeup counter

Each launch now has a separate, configurable idle observation interval after
settling. The harness reads counters only at its boundaries, rather than polling
the application during that interval. JSON retains the raw snapshots and actual
elapsed duration, not just medians:

- Launch CPU uses process-wide `/proc/PID/stat` user + system ticks, including
  worker threads. Its resolution is `1 / CLK_TCK`; it is not the old main-thread
  `/proc/PID/schedstat` number.
- Idle CPU sums `/proc/PID/task/TID/schedstat` runtime for all boundary-live
  threads. Percent means percentage of **one core**, not the whole machine.
- Voluntary and involuntary context switches come from each thread's `status`.
  These are **context switches, not scheduler wakeups, timer expirations, or
  interrupts**. `wakeups` is deliberately null. Exact wakeups need scheduler
  tracing with appropriate permissions and a defined target-TID filter; this
  unprivileged harness does not install tracing dependencies or relabel proxies.
- A changed task set/start time invalidates the high-resolution idle totals
  rather than producing a false zero. Threads both born and exited between
  snapshots cannot be seen by those counters; the additional process CPU tick
  delta includes their CPU. Snapshot reads are not atomic; their duration is
  retained. Compositor, D-Bus services and child processes are excluded.

Use longer intervals and repeated runs for tiny idle costs; a zero in a short
sample is not proof that the application never wakes. Keep the compositor
visible and unobstructed, avoid interacting with it, and do not build concurrently
with measurement. Retain output mode/scale, CPU, kernel, toolkit versions and
binary hashes in the JSON. Compare identical environments and protocols.

## Representative scrolling and observable presentation

`scroll.zig` is an **Ourokit-only closed-loop software probe**, not a GTK/Qt
comparison or the full application runner. It embeds the existing
`examples/virtual-list.lua` stories: 10,000 fixed-height rows, variable-height
wrapped rows with controls, or the narrower wrapped viewport. It uses the real
Lua reconciliation, input routing, layout, text/glyph caches, damage tracking,
software renderer and Wayland host. The benchmark pins Source Sans 3 Regular
for both text and controls; it is not a theme/font comparison.

```sh
python3 tools/application-benchmark/scroll.py \
  --story variable/initial --iterations 5 --frames 301 --warmup-frames 31 \
  --compositor-description 'COMPOSITOR VERSION; BACKEND; RENDERER; OUTPUT MODE' \
  --output scroll-results.json
```

Run under a compositor with working `wp_presentation`, floating windows and
scale 1. No physical input is injected: after acquiring a buffer the probe
positions its synthetic pointer, timestamps immediately before routing a
24-logical-pixel axis event, reconciles/renders/commits, and waits for that
commit's presentation feedback. Direction reverses every 120 events. It checks
that every event actually changes the retained scroll offset. Only one frame is
outstanding, so feedback cannot be misattributed or overwritten by a later frame.
Logging occurs after the measured loop.

The first 31 frames (initial frame plus 30 scroll events) are warmup by default.
Every raw sample retains input, submission, presentation and feedback-receipt
timestamps, clock ID, refresh interval, output sequence and hardware/vsync flags.
Percentiles use nearest rank **within each run**, not pooled pseudo-independent
frames. Presentation intervals exclude the warmup-to-measured boundary.

`runtime_input_to_presentation_ms` is available only when the compositor's clock
is Linux `CLOCK_MONOTONIC`, matching the injected timestamp. Receipt time and
frame callbacks are never used as presentation time. Unknown clocks leave
latency null; a single consistent other clock can still measure frame intervals.
Unknown refresh leaves the long-interval count null. Intervals >1.5× refresh are
reported as long intervals, **not a count of dropped application frames**.

This load is synchronized to previous feedback, so it does not characterize
queued device input, input arriving at arbitrary refresh phases, open-loop
overload, or hardware-to-photon latency. Headless presentation is a compositor
timestamp without a physical screen. Report the hardware flags alongside numbers.
Missing/discarded feedback or occlusion can time out; that is unavailable data,
not zero latency. The driver returns nonzero and retains failure metadata. If
measurement completes but teardown fails, it retains the full trace with
`measurement_complete_cleanup_failed`, and still exits nonzero.

## Reload integration boundary

Reload measurement is intentionally pending the development CLI/control
contract. Do not time an unrelated app-control call or call its response
"edit-to-visible". The small integration should launch a private development
instance of a temporary copy of a fixture, discover its explicitly logged dev
endpoint, and alternate two valid source revisions with a visible marker.
Timestamp completion of an atomic file replacement, request reload, and record
the acknowledgment separately. Verify the new source/scene revision and marker
through inspect/capture, then correlate that revision to compositor presentation
only if the final API exposes that relationship. Otherwise report
**edit-to-verified-software-capture** (including CLI, polling and capture costs),
not edit-to-visible. A software capture or committed scene revision alone is
not evidence of compositor presentation. Include a rejected edit that preserves
the last-good revision; never count rejection as a successful reload sample.

Measurement checks (no display required):

```sh
python3 -m unittest discover -s tools/application-benchmark -p 'test_*.py' -v
```
