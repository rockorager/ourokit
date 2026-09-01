# Ourokit

Ourokit is a Linux application platform: an Ouro-owned design system, typed UI
and render-object architecture, renderer-neutral scenes, software and future
Vulkan backends, Wayland integration through Wayring, an embedded Lua 5.5
application environment, and one raw `io_uring` event loop owned by Ourokit.

This repository is at first-milestone scope. It currently proves canonical
design-token generation, clear/rectangle scene rendering, generation-safe raw
`io_uring` timers and cancellation, a zero-standard-library Lua coroutine, and
safe-point resumption after timer completion. It does not yet provide a widget
catalog. A headless declarative-window reconciler
now proves stable native identity, per-window resource scopes, transactional
snapshot validation, and callback-free platform event queuing. A reusable
multi-window Wayring host connects that model to independently configured,
rendered, resized, and closed xdg-toplevels.
The first headless UI kernel adds logical box constraints, typed Box/Flex/Stack
render objects, cached allocation-free layout, ordered scene construction, and
hit testing. A separate keyed instance layer now reconciles normalized typed
snapshots into scoped render objects, and a bounded pointer router targets
instances without callbacks. Mounted build owners provide scoped component
lifecycle and direct dirty scheduling. A provisional constructor-specific Lua
bridge proves non-yielding component builds into typed normalized descriptors.
The first ergonomic constructor composes `ouro.button` from Box and Label while
the eventual generated constructor ABI remains intentionally unfrozen. A
minimal Lua signal primitive tracks per-build-owner dependencies
transactionally, rejects writes during builds, and wakes only subscribed dirty
work without entering Lua. The isolated VM now supports independently waiting,
scope-owned coroutine tasks in growable stable-address slabs, with direct
scheduler and `io_uring` completion routing. A reusable native host loads a
declarative Lua application, owns all native services, invokes button handlers
as scoped task-phase coroutines, and presents signal-driven descriptors through
the same mounted render path. The shared text layer uses pinned HarfBuzz for
real OpenType run shaping, pinned SheenBidi for Unicode 17 paragraph bidi, and
pinned uucode plus official Unicode 17 Script_Extensions data for grapheme-safe
script and combined paragraph itemization. A uucode custom field and focused
UAX #14 scanner provide fully conformant Unicode 17 line opportunities; greedy
line selection is a separate linear-time strategy so future Knuth-Plass policy
does not contaminate segmentation. HarfBuzz cluster advances feed that selector,
unsafe selected boundaries remain explicit, and SheenBidi performs line-local
UAX #9 L1-L2 ordering only after wrapping. A final headless stage intersects
visual and fallback-font spans into backend-neutral positioned glyphs, reusing
safe paragraph shaping and requesting reflow when unsafe reshaping changes a
line width. The design system requests generic `sans-serif`, and native Linux
builds use Fontconfig's
configured primary and fallback faces. Pinned font fixtures keep shaping tests
deterministic without putting shaping or measurement in a renderer.

## Requirements

- Linux 5.10 or newer with `io_uring`
- Zig 0.16.0 exactly (Wayring's current minimum and target)
- Python 3 for deterministic token validation/generation
- Fontconfig development files for native Linux font discovery
- FreeType development files for native software text rasterization
- xkbcommon development files for native Wayland keyboard translation
- Vulkan loader and headers, plus `glslc` (not required with `-Dvulkan=false`)
- A C/C++ toolchain is not required separately; Zig compiles embedded Lua and
  HarfBuzz

## Build and test

```sh
zig build
zig build test
zig fmt --check build.zig src examples tools
zig build tokens
```

The default build includes both software and Vulkan renderers and installs
`zig-out/lib/libourokit.a`. Use `-Dvulkan=false` for a software-only build that
does not require Vulkan or `glslc`. `zig build test` includes Vulkan and
deterministic software pixel tests, userspace timer-heap tests, real kernel
`io_uring` alarm/update/cancel tests, and the Lua coroutine/timer safe-point
integration test. The suite covers
logical constraints, Flex/Stack layout, invalidation caching, scene lowering,
and hit testing without a compositor, plus keyed reconciliation, safe
retirement, and transactional pointer routing. Signal tests cover equal-write
suppression, dynamic dependency replacement, failed-build rollback, build-time
write rejection, and owner disposal. Text tests fetch pinned Inter and Noto Sans
Arabic fixtures and verify HarfBuzz shaping plus Unicode grapheme segmentation.
Fallback tests verify configured-order face selection, grapheme-safe boundaries,
visible unresolved glyphs, stable font handles, and Fontconfig variable-instance
translation. Paragraph tests cover real mixed-script itemized shaping, measured
break segments, unsafe-boundary propagation, greedy selection, and line-local
visual bidi runs. The growable font cache tests deduplication, stable addresses
across growth, reference ownership, source replacement, and stale-handle
rejection. A separate immutable shaped-run cache verifies complete request
identity, fallback output, retained candidate lifetimes, stable growth, and
stale shape handles.
The normal library build does not embed either font.

## Native UI embedding

The `ourokit_ui` Zig module is the platform-neutral embedding boundary for
native hosts such as compositors. It exports `core`, `text`, `scene`, `layout`,
`render_object`, the `software` renderer, and a thin `Surface` owner. `Surface`
reconciles parent-before-child `Descriptor` snapshots, owns fixed-capacity
render-object and scene storage, lays out in logical coordinates, lowers a
display list at an explicit output scale, hit tests by descriptor ID, and
provides platform-free pointer capture through `pointerPress`, `pointerMotion`,
and `pointerRelease`.

Text remains explicit: a caller that uses Label render objects must create and
attach its own paragraph source/layout caches, and text-capable software
rendering requires caller-owned glyph/font caches. Fontconfig discovery is
always disabled for `ourokit_ui`; `-Dfreetype=true` only enables explicit glyph
rasterization. The module does not import Ourokit's Lua runtime, task scheduler,
application/window host, Wayland client, generated Wayland protocols, or Vulkan
renderer. A consumer-only smoke test can be run independently with:

```sh
zig build test-ourokit-ui-consumer
```

The public `ourokit.varlink` module provides bounded sans-I/O client and server
state machines, `.varlink` interface parsing and schema validation, standard
address parsing, and the mandatory `org.varlink.service` implementation. See
[the Varlink transport and ownership contract](docs/varlink.md).

Native Linux builds enable Fontconfig by default. Minimal/headless builds and
cross-compilation can omit that system capability with `-Dfontconfig=false`;
deterministic shaping and rendering tests remain available.

Software glyph rasterization is also optional (`-Dfreetype=false`) and disabled
by default for cross targets. The
`ouro.label { key, text, size?, alignment?, max_lines?, overflow? }` constructor
retains width-independent text/style identity, resolves a cached paragraph from
its current box constraints, and rasterizes through a backend-owned FreeType
glyph cache. It supports Unicode itemization, bidi, fallback shaping, and
wrapping; unchanged constraints perform no layout acquisition or allocation.
`ouro.row`, `ouro.column`, `ouro.scroll`, and `ouro.label` provide nested composition without
application-managed numeric IDs or parent links. `ouro.button` composes a Box
and Label using generated design tokens and retains hover, pressed, and disabled
state in the widget layer. Buttons activate on press; release clears their
pressed visual state. Its
Box centers the constrained Label within the padded button bounds; this child
placement remains separate from paragraph alignment. Button is not a renderer
primitive. `ouro.listbox` and its direct `ouro.option` children provide a
controlled single-selection list with one Tab stop and Up/Down/Home/End navigation.
Direction-aware alignment, whole-line clipping, and shaped ellipsis
remain text-layer policy; renderers never inject the ellipsis. Editing and
selection remain deferred. Software and Vulkan consume the identical positioned
glyph sequence.

After editing canonical token JSON:

```sh
zig build generate-tokens
zig build tokens
```

Generated code under `src/design/generated` is checked in and marked as
generated. Do not edit it directly.

To run the reproducible software-renderer comparison against pinned Pixman
0.46.4 (fetched only for this optional step):

```sh
zig build bench-renderers -Doptimize=ReleaseFast
```

To profile pure headless bidi analysis, script analysis, combined paragraph
itemization, UAX #14 opportunities, shaped measurement, greedy selection, and
line-local bidi independently from UI, rendering, and Wayland:

```sh
zig build bench-paragraph -Doptimize=ReleaseFast \
  -Dfontconfig=false -Dfreetype=false
```

The optional end-to-end application benchmark compares one matched clickable
Label/Button window against GTK 4 and Qt 6 under Wayland. GTK/Qt development
packages are required only for this benchmark; normal Ourokit builds do not
link either toolkit:

```sh
ZIG=/path/to/zig-0.16.0 tools/application-benchmark/build.sh
tools/application-benchmark/run.py --iterations 20 --output results.json
tools/application-benchmark/run.py --profile settings --iterations 20 \
  --output settings-results.json
```

See [the benchmark protocol](tools/application-benchmark/README.md) before
interpreting startup or memory results.

## Wayland development

Wayring is pinned as a Zig package and wrapped by `src/platform/wayland`.
Ourokit owns the ring; Wayring borrows it. Run the declarative example on a
Wayland desktop with:

```sh
zig build run-wayland-example
```

The executable wrapper is intentionally tiny. Its application is
`examples/wayland.lua`, which declares the app, window, signal, and button;
`app.runWayland` owns the ring, scheduler, Lua VM, font/text caches, retained UI,
selected renderer, and Wayland presentation. Vulkan-capable builds select Vulkan
by default; pass `--software` after `--` to select software rendering instead.

Run any declarative application directly through the reusable host:

```sh
zig build run-app -- path/to/application.lua
# After `zig build`, the installed CLI provides the same host:
zig-out/bin/ouroctl run path/to/application.lua
```

The reusable host follows the same renderer default. Pass `--software` to force
the software renderer.

Text inputs support an explicit controlled or retained-value contract. Use
`text` with `on_change` when application state is authoritative:

```lua
local query = ouro.signal("")

ouro.text_input {
  key = "query",
  text = query(),
  on_change = function(value)
    query:set(value)
  end,
}
```

Use `default_text` instead when native retained editing state should own the
value after first mount. Exactly one of `text` and `default_text` is required.
`on_change` runs as a scoped Lua task during the task safe point, never from an
input protocol callback; selection-only changes do not invoke it. `enabled =
false` removes the field from focus traversal and rejects all interaction.
`read_only = true` keeps focus, selection, navigation, and copy available while
rejecting text-input commits, deletion, cut, and paste.

## Storybook

Storybook catalogs are explicit Lua entry points containing named, isolated
component states. Open the native interactive catalog browser with:

```sh
zig-out/bin/ouroctl storybook run examples/storybook.lua
```

The browser is an ordinary Ourokit application: its catalog scrolls through
the normal pointer input path, selection uses a signal, and the selected story
is mounted as live content at its declared viewport and color scheme. Force a
renderer with `--software` or `--vulkan`.

List a catalog for people or tools with:

```sh
zig-out/bin/ouroctl storybook list examples/storybook.lua
zig-out/bin/ouroctl storybook list examples/storybook.lua --json
```

Render every story through the platform-neutral window runtime and software
renderer, or select one story by ID:

```sh
zig-out/bin/ouroctl storybook snapshot examples/storybook.lua
zig-out/bin/ouroctl storybook snapshot examples/storybook.lua \
  --story button/disabled-dark --output .amp/in/artifacts --json
```

Each story declares a fixed logical viewport, optional `snapshot_scale`, color
scheme, and ordinary Ourokit content callback. Snapshot scale affects PNG
raster dimensions only; the interactive browser uses its window's native
output scale. Snapshots use pinned Inter and Noto Sans Arabic fixtures, write
PNG files atomically beneath the output directory, and report SHA-256 hashes. A
fresh Lua VM and retained UI runtime are created for each PNG so signals,
globals, tasks, and widget state cannot leak between stories. Slash-separated
story IDs create corresponding output subdirectories; unsafe path segments are
rejected. See
[`examples/storybook.lua`](examples/storybook.lua) for the declaration format
and a catalog of every built-in widget.

Stories can deterministically reach real retained widget states by replaying
declarative actions against slash-separated widget-key paths:

```lua
actions = {
  { type = "hover", target = "content/button" },
  { type = "pointer_down", target = "content/button" },
  { type = "click", target = "content/other-button" },
  { type = "scroll", target = "content/list", delta = 180 },
}
```

Playback uses the normal hit tester, pointer router, button policy, callback
tasks, scroll policy, signals, reconciliation, layout, and paint path. Scroll
deltas are logical surface units and follow the target scroll widget's declared
axis. Event timestamps and serials are fixed, and each action settles before
the next begins. Wall-clock `ouro.sleep` calls fail during playback rather than
making snapshots timing dependent. The interactive Storybook browser is
available through `storybook run`; deterministic actions remain a snapshot
playback contract while the live browser accepts ordinary user input.

Constrained and themed composition use the same nested callback convention as
rows, columns, and scroll views:

```lua
ouro.theme {
  key = "dark-preview",
  color_scheme = "dark",
  children = function()
    ouro.box {
      key = "viewport",
      width = 640,
      height = 480,
      padding = 12,
      alignment = "center",
      children = function()
        ouro.button { key = "action", label = "Continue" }
      end,
    }
  end,
}
```

Run the Vulkan renderer through Ourokit's libwayland-free linux-dmabuf
presenter with:

```sh
zig build run-wayland-vulkan-example
```

The Vulkan example uses linux-dmabuf v4 device/modifier feedback, direct
rendering, and linux-drm-syncobj timelines when advertised. It falls back to
shared memory when the compositor and Vulkan device have no common renderable
ARGB8888 modifier.

Close the window normally to exit. CI or a headless compositor can use
`zig build run-wayland-example -- --exit-after-first-frame`. Exercise
independent multi-window lifetime with:

```sh
zig build run-wayland-example -- --two-windows
```

The Wayland, xdg-shell, linux-dmabuf, presentation-time, and drm-syncobj XML
archives are pinned Zig build dependencies used to generate protocol code; no
system libwayland is linked. See
[ARCHITECTURE.md](ARCHITECTURE.md) and
[docs/rendering.md](docs/rendering.md) for the verified integration contract
and shared-memory/dma-buf presentation paths.

## Documentation

- [Architecture](ARCHITECTURE.md)
- [Design system](docs/design-system.md)
- [Text shaping](docs/text.md)
- [Rendering](docs/rendering.md)
- [Runtime, tasks, Lua, and io_uring](docs/runtime.md)
- [Application model](docs/application-model.md)
- [Transactional source reload](docs/hot-reload.md)

Instance-adjacent typed pointer bindings now replace proof-wide global event
dispatch. Widget-specific callbacks such as `ouro.button { on_press = ... }`
use explicit Lua registry lifetime and task-phase scoped coroutine dispatch;
render objects and platform callbacks remain callback-free.
