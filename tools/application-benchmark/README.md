# Application benchmark

This benchmark compares small Wayland applications using either of two
matched profiles:

- `button` (default): one 480×320 window and one 160×44 clickable,
  text-labelled control;
- `settings`: one 560×360 window with a heading, a counter label, and a row of
  160×40 Increment and disabled controls. Increment updates the counter in all
  applications.

Ourokit uses its Lua instance/reconciliation path, HarfBuzz shaping, FreeType
software glyph cache, display list, Wayring adapter, and shared raw `io_uring`.
GTK 4 uses `GtkApplication`/`GtkButton`; Qt 6 uses
`QApplication`/`QPushButton`.

Build the release binaries:

```sh
ZIG=/path/to/zig-0.16.0 tools/application-benchmark/build.sh
```

The benchmark entry point defaults to software rendering. `settings.lua` is a
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

## Optional pinned GPUI comparison

`gpui/` implements the same button and settings workloads with GPUI entities,
flex layout, text, and clickable divs. Its disabled control has no handler.
It uses a real Wayland window via `gpui_platform`, not GPUI's headless mode.
Cargo pins both crates to the same Zed revision and checks in the dependency
lockfile; `rust-toolchain.toml` pins the upstream Rust version. Linux build
prerequisites include a C/C++ toolchain, pkg-config, and development libraries
for Wayland, xkbcommon, fontconfig, FreeType, and Vulkan/GL drivers at runtime.
Python 3.11+ is required by the build helper.

```sh
zig build build-application-benchmark -Doptimize=ReleaseFast
strip zig-out/benchmark-apps/ourokit zig-out/benchmark-apps/ourokit-settings
python3 tools/application-benchmark/build_gpui.py --jobs 2
python3 tools/application-benchmark/run.py --toolkits ourokit gpui \
  --ourokit-renderer vulkan --iterations 20 --warmups 3 --idle-seconds 5 \
  --environment-description 'Record GPU, driver, Sway backend, and validation evidence here' \
  --output gpui-button.json
python3 tools/application-benchmark/run.py --toolkits ourokit gpui \
  --ourokit-renderer vulkan --profile settings --iterations 20 --warmups 3 \
  --idle-seconds 5 --output gpui-settings.json
```

`--toolkits` defaults to the original Ourokit/GTK/Qt comparison; installing
GPUI is optional. The build helper records compiler, source, lockfile, and
binary hashes beside the executable. The harness rejects a GPUI binary that
does not match that metadata. JSON retains launch diagnostics, warmup samples,
selected command arguments, and the local worktree status.

**Requesting Vulkan is not proof of GPU presentation.** Ourokit can fall back
to software if DMA-BUF export/import is unavailable. Outside measurements,
verify its Wayland DMA-BUF creation, surface attachment, and presentation
feedback, and retain GPUI's adapter/backend diagnostic. Both must use the
intended hardware device for a hardware comparison. Turn protocol tracing off
before measuring; llvmpipe results are not hardware GPU results.

This measures whole-application startup, CPU memory, and idle activity—not
layout throughput, scrolling throughput, frame latency, or shader performance.
GPU allocations are not included in the process memory columns. Headless
Sway can exercise hardware rendering but cannot establish physical-display
latency. Controls match dimensions and behavior, not font shaping or pixels;
this fixture is not the full Zed application. Keep binary versions, compositor,
power conditions, and measurement protocol with any reported result.

## Matched large-list and rebuild frame workloads

The optional `workload` binary compares three programmatically driven workloads
against GPUI on the same Wayland Vulkan setup:

- `scroll`: 10,000 virtualized rows, moving down 14 pixels each generation;
- `rebuild`: 1,000 nonvirtualized keyed rows, changing every label each generation;
- `relayout`: 1,000 nonvirtualized keyed rows with unchanged labels, alternating
  every row's height between 28 and 32 pixels.

Both implementations use a 640×720 viewport at scale 1, the repository's embedded
Source Sans 3 Regular at 14 pixels, a natural 18.5625-pixel text line, four-pixel
row padding, alternating row backgrounds, and the same labels. Ordinary rows
are 28 pixels high. This pins typography separately from the earlier small
application fixtures, whose default fonts and line heights differ.

```sh
zig build build-frame-workload -Doptimize=ReleaseFast
python3 tools/application-benchmark/build_gpui.py --workload --jobs 2
python3 tools/application-benchmark/workload.py --iterations 5 \
  --frames 331 --warmup-frames 31 \
  --environment-description 'GPU; driver; compositor backend/mode; power conditions' \
  --output workload-results.json
```

Run inside the same disposable, unobstructed compositor/session bus used above.
Finish builds and screenshot/protocol checks before measuring. GPUI profiling is
enabled only for the opt-in workload build. Validate hardware selection and
DMA-BUF presentation outside measurements; the native workload refuses software
fallback. Both workloads require keyboard focus and scale 1. A headless seat
without a keyboard leaves GPUI inactive and triggers its default 30 Hz animation
throttle; use a persistent private virtual keyboard with a keymap, but no injected
keys, rather than changing toolkit throttling policy. Verify focus before measuring.
For capture checks, either executable accepts `--hold-ms 5000` after
its arguments: Ourokit uses `scroll 2`, GPUI uses `--profile scroll --frames 2`.

`build_ns` measures Ourokit reconciliation/layout/display-list generation or
GPUI's public `Draw` span. `submit_ns` measures native GPU encoding/host submission
or GPUI's synchronous platform `Present` span. Their sum, `work_ns`, is **CPU-side
wall time**, including any blocking inside those spans, not GPU execution time.
State mutation, initialization, and callback waits are outside these spans.
Ourokit acquires a reusable buffer outside its submission span; GPUI's platform
span includes surface-texture acquisition. Instrumentation boundaries therefore
differ; phase names do not imply identical internal work. GPUI requires exactly one
same-window Draw/Present pair for each generation and collects the final pair
before quitting. Logging and serialization happen after the timed loop.

Both workloads are paced by Wayland frame callbacks. Submission intervals are
recorded separately and are **not presentation timestamps**. Work exceeding
16.67 ms is not a dropped-frame count. This does not measure physical input
latency, display latency, or uncapped throughput.

The harness randomizes toolkit/profile order within each independent iteration,
discards the first 31 of 331 frames by default, and reports nearest-rank
percentiles within each run. Do not pool frames as independent experiments.
JSON preserves every raw frame, diagnostics, hashes, environment, and failure;
completed runs are saved before starting the next. Retained row/offset checks
guard against measuring an unchanged scene. Report virtualized scrolling
separately from full-list rebuilding rather than treating them as interchangeable
list benchmarks.

## Sparse updates and sustained churn

`retained.py` runs four diagnostic profiles, optionally paired with GPUI.
The original three matched workloads remain available.

- `sparse-parent`: rebuild the parent of 1,000 rows when only row 7's label
  changes. All other labels and row geometry stay unchanged.
- `sparse-leaf`: make the same change through a signal read by one retained
  stateful row. Report root and row callback counts rather than assuming that
  isolation avoids all native reconciliation or layout work.
- `sustained-scroll`: traverse a 10,000-row virtual list at four rows per
  generation, reversing every 2,400 generations. The default long run covers
  two full out-and-back cycles after warmup. This updates the root's
  `scroll_to` request through a signal; it does not inject wheel input or
  isolate the native input-driven scroll path.
- `keyed-churn`: repeatedly reverse, rotate by 17 rows, then replace the oldest
  eight of 1,000 rows with new identities. The native probe checks every row's
  text/geometry and verifies that surviving row handles do not change.

```sh
zig build build-frame-workload -Doptimize=ReleaseFast
python3 tools/application-benchmark/retained.py \
  --binary zig-out/benchmark-apps/ourokit-workload \
  --environment-description 'GPU, driver, compositor mode, CPU and governors' \
  --output retained-results.json
```

For a quick matched comparison (one process per toolkit/profile, 300 measured
frames each, roughly 45 seconds of timing after setup):

```sh
python3 tools/application-benchmark/build_gpui.py --workload --jobs 2
python3 tools/application-benchmark/retained.py \
  --binary zig-out/benchmark-apps/ourokit-workload \
  --gpui-binary zig-out/benchmark-apps/gpui-workload \
  --iterations 1 --sparse-frames 331 --sustained-frames 331 --warmup-frames 31 \
  --environment-description 'GPU, driver, compositor mode, CPU and governors' \
  --output retained-comparison.json
```

Each toolkit pair runs consecutively, with alternating starting toolkit across
profiles and repetitions. GPUI's leaf profile retains 1,000 cached row entities
and notifies only row 7; actual root/row callbacks are reported, not assumed to
match Ourokit's invalidation behavior. Keys, values, order, typography, geometry
and scroll offsets match. GPUI checks row values/order and bounds; native checks
also cover instance-handle survival. Validate screenshots before timing.
The short run does not reach scroll reversal and cannot establish memory trends.
Acquisition boundaries still differ as documented above; compare CPU work, not
presentation latency. Native cache/layout gauges and `cycle_work` have no GPUI
equivalent in this probe.

Use the same focused private Wayland/Vulkan setup described above. Defaults are
three independent runs per profile, 331 sparse or 9,631 sustained generations,
with 31 warmups excluded. At 60 Hz, each sustained run takes about 160 seconds;
the native-only suite takes roughly 17 minutes plus setup (twice that paired).
No builds, profiling or
captures should overlap measurement. Existing output paths are rejected.

Each run preserves raw samples, phase distributions and 600-generation windows
for early/late comparisons. `work` remains build plus submit; `cycle_work` also
includes state mutation, cancellation/retirement and acquisition calls. Neither
includes callback waits, diagnostic validation, all event-loop overhead, or
display latency. Callback counters add instrumentation overhead. Layout counts
count entire layout phases, **not individual nodes visited**.

Lua heap queries do not force GC: they measure managed bytes, not allocations
or GC-pause time. Cache fields report live entries, index capacity and slab
counts, not byte consumption. A 1 Hz `/proc/PID/smaps_rollup` sampler preserves
RSS/PSS/private KiB and read durations; it excludes startup, warmup and result
serialization from `measured_memory`. GPU allocations are not included. Sample
storage is allocated and touched before measurement so filling the trace does
not look like an application leak. Report memory ranges and trends over the
observed duration; a plateau is not proof that no longer-term leak exists.

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

## Reload measurement requires the development CLI

The `reload.py` driver uses `run --dev`, `dev reload`, `dev inspect`,
`dev capture --output`, and `dev diagnostics`. Build the CLI in the mode being
measured and record that mode in the environment description; debug and release
results are not interchangeable.

```sh
python3 tools/application-benchmark/reload.py \
  --binary zig-out/bin/ouroctl --iterations 5 --warmups 1 \
  --environment-description 'ReleaseFast; COMPOSITOR VERSION/BACKEND/OUTPUT' \
  --output reload-results.json
```

It launches a private development instance with a temporary source/runtime
directory, resolves the compositor socket before isolating `XDG_RUNTIME_DIR`,
and discovers only the explicitly logged development endpoint. It never attaches
to production application control or edits the original fixture. ImageMagick is
required to decode PNGs; no compositor screenshot is taken in this timed path.

Each atomic edit changes a unique semantic label and alternates a solid red/blue
patch. Timing starts immediately after `os.replace` returns. A successful reload
acknowledgment is recorded separately, then inspect must expose the expected
label and a token different from the previous revision. Capture must echo that
token and identify `software_scene_replay`. The copied PNG's dimensions/byte
count must agree with metadata, and decoded pixels must contain the new patch
without the old color. Read-only inspection/capture retries are bounded and
retained in the sample; reload itself is issued exactly once per edit.

The result is **edit-to-verified-software-capture**, including CLI startup,
polling, copying, PNG decoding and pixel-verification costs. Source writing and
file synchronization precede the starting timestamp. This is not a renderer-only
measurement, edit-to-visible, or compositor presentation latency. A final invalid
edit must fail reload while preserving the last-good semantic marker and exact
decoded RGB content; rejection is not a successful latency sample.

Raw timestamps, acknowledgment text, tokens, hashes, failures, and per-run
distributions are retained in JSON. Copied PNGs are retained in a sibling
`<output-stem>-captures` directory because the server's private capture paths
expire. Warmup results are separate from measured samples. Any measurement or
cleanup failure exits nonzero while preserving completed results.

Measurement checks (no display required):

```sh
python3 -m unittest discover -s tools/application-benchmark -p 'test_*.py' -v
```
