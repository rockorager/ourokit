# Ourokit

Ourokit is a Linux desktop application toolkit with declarative Lua UI, native
Wayland windows, software and Vulkan rendering, and tools for fast development.
Optional shell extensions support panels, launchers, and workspace controls.
See the [product vision](vision.md) for the intended outcomes and scope.

The toolkit is under development. It includes retained components and signals,
text editing and shaping, images, themes, scrolling and virtual lists, scoped
asynchronous tasks, source reload, and a native Storybook with headless snapshots.
Desktop services include portal file choosers, URI opening, notifications, and
text/file drag-and-drop. App-local typed drags include previews and retained
card/tab reordering; see the [drag example](examples/drag-composition.lua).
Form controls include checkboxes, radio groups, selects,
sliders, spinboxes, split views, tabs, and in-window modal dialogs; native text
inputs support multiline editing. See the
[form controls example](examples/forms.lua). Animated switches, checkboxes,
collapsibles, and accordions inherit reduced-motion policy; try the
[motion components example](examples/motion-components.lua). Native tooltips extend
outside windows and layer-shell bars without stealing input; try the
[tooltip bar example](examples/tooltip-bar.lua). Animated native menus/selects and
in-window toasts also respect reduced motion; see
[menus and toasts](examples/menus-and-toasts.lua). It is not yet a complete
desktop toolkit: OS accessibility and richer data widgets remain unfinished.

## Application surface

Start with the [application model](docs/application-model.md), the `ouroctl`
host, and the examples. Applications compose widgets and state; the host owns
the event loop, native resources, rendering, and task lifetimes.

| Surface | Role |
| --- | --- |
| Lua `ouro.app`, `run(context)`, windows, widgets, components, signals and tasks | Ordinary application authoring |
| `ouro.json` and `ouroctl run` | Application identity, entry point and launch; individual Lua files can also run directly |
| `ouroctl dev …` and Storybook | Explicit per-instance development and component testing |
| Desktop hooks and the [D-Bus API](docs/dbus.md) | Standard desktop integration and an escape hatch for application-specific services |
| [`ouro.http`](docs/http.md) | Scoped, yielding HTTP(S) requests through libcurl and the shared io_uring loop |
| Declared actions, `--mcp` and `ouroctl mcp export` | Optional production automation; not UI lifecycle or development authority |
| Layer surfaces and the [shell workspace API](docs/workspaces.md) | Optional shell extensions |
| [Session services and authentication](docs/session.md) | Native idle, display power, secure lock surfaces and asynchronous PAM |
| [Native plugins](docs/native-plugins.md) and `ourokit_ui` | Experimental native integration and low-level UI embedding |

There is one UI startup form: `run(context)` returns a static or reactive
`windows` declaration. Top-level `ouro.app.windows` is rejected. Actions and
shell extensions are not prerequisites for opening a window. The
[Contacts example](examples/contacts/README.md) uses the ordinary application
surface and optionally exposes actions over MCP.

The Zig modules exposed by `src/ourokit.zig` support embedding and internal
testing, but their exports do not constitute separate stable SDKs. Internal
render objects, resource handles, and protocol machinery are implementation
boundaries, not concepts ordinary application authors need to manage. Public
Lua and native-extension contracts are also evolving; no stable ABI is promised.

## Requirements

- Linux 5.10 or newer with `io_uring`
- Zig 0.16.0 exactly (Wayring's current minimum and target)
- Rust/Cargo 1.85 or newer for the pinned resvg image bridge (tested with 1.94)
- Python 3 for deterministic token validation/generation
- Fontconfig development files for native Linux font discovery
- FreeType development files for native software text rasterization
- xkbcommon development files for native Wayland keyboard translation
- libcurl development files, version 7.85 or newer with TLS and asynchronous DNS,
  plus system CA certificates (Debian: `libcurl4-openssl-dev ca-certificates`)
- Vulkan loader and headers, plus `glslc` (not required with `-Dvulkan=false`)
- A C/C++ toolchain is not required separately; Zig compiles embedded Lua and
  HarfBuzz

## Prebuilt ouroctl

[CI](.github/workflows/release.yml) publishes a software-rendering (`-Dvulkan=false`)
x86_64 Linux `ouroctl` as GitHub release assets:

- every push to `main` creates prerelease `commit-<full commit SHA>`;
- a pushed `v*` tag creates a normal release with that name;
- running the workflow manually with a commit SHA backfills `commit-<sha>`.

Each release has `ouroctl-x86_64-linux-gnu.tar.gz` (`bin/ouroctl`, the plugin
header and licenses) and its `.sha256`, and a GitHub build-provenance
attestation. The binary is built on Debian 12 with `-Dcpu=baseline`, so it
needs glibc 2.36 or newer and any x86_64 CPU. At runtime it needs Fontconfig,
FreeType, xkbcommon, libcurl and PipeWire (Debian: `libfontconfig1 libfreetype6
libxkbcommon0 libcurl4 libpipewire-0.3-0`). System audio observation and controls
live under [`ouro.audio`](docs/audio.md), using PipeWire directly.

Install it with [mise](https://mise.jdx.dev), pinning a commit:

```toml
[tools]
"github:rockorager/ourokit" = "commit-<full commit SHA>"
```

or `mise use "github:rockorager/ourokit@commit-<full commit SHA>"`. mise
verifies the asset digest and attestation. Commit releases are prereleases,
so `latest` resolves only to `v*` releases.

## Build and test

```sh
zig build
zig build verify
```

`verify` is the routine pre-commit check: Zig tests (including token validation),
Lua component tests, Zig formatting, real-process development/control suites,
and disposable native session/PAM, PipeWire and HTTP(S) fixtures. Building audio
requires `libpipewire-0.3-dev`; `zig build test-audio` also needs `pipewire-bin`,
GCC and pkg-config and uses an isolated daemon with silent null sinks.
HTTP tests require the
OpenSSL CLI and run with `zig build test-http`. The native development
suite starts its own headless Sway with software rendering and private D-Bus
sessions; it does not use your desktop, session bus, or compositor configuration.
It checks inspection, input, capture pixels, rejected and accepted reloads,
retained identity, cancellation, desktop activation, and production isolation.
It tests the CLI artifact from this build, not a previously installed binary,
and runs again even when the build is cached.

Run as a regular user with Python 3, Sway (including `swaymsg`),
`dbus-run-session`, `dbus-daemon`, `gdbus`, and system fonts installed.
Native tooltip checks also use `grim`, `wtype`, `wayland-scanner`, and a C
compiler with Wayland client headers to create a private virtual pointer.
Window-theme checks use `/usr/bin/python3` with PyGObject for a private Settings portal.
On Debian/Ubuntu the additional packages are `sway dbus-daemon libglib2.0-bin
grim wtype libwayland-bin libwayland-dev gcc pkg-config python3-gi`.
Missing tools, compositor startup failures, timeouts and failed tests are errors,
not skipped checks. The compositor and test process groups are stopped on exit.
This verifies software-rendered native behavior, not GPU presentation latency or
integration with a particular desktop environment.

For focused iteration, `zig build test` runs the Zig suite without a compositor;
`zig build test-components` runs Lua component tests and the test runner's
black-box contracts without Python, Sway, or D-Bus.
`zig build test-development` runs only the isolated native/control suites.
`zig build test-session` runs strict session-protocol rendering and asynchronous
mock-PAM tests without touching a real compositor, PAM policy or credentials.
Individual Python tests still support `OUROKIT_TEST_WAYLAND_DISPLAY` for manual
use on a disposable compositor. The `verify` command always creates its own.

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

## Native plugins

The default runner supports experimental C-ABI plugins declared in an
application manifest's `native_modules` list. C and Zig shared libraries can
register Lua-facing functions and native state backed by existing Ourokit
signals, without linking Lua or writing a custom launcher. Native functions can
return immutable rectangle drawings for `ouro.canvas`; the example surrounds a
C-painted meter with ordinary widgets. Run
`zig build build-native-example`, then
`zig-out/bin/ouroctl run zig-out/examples/native/ouro.json` after building the
runner. See [the native plugin API](docs/native-plugins.md) for ownership,
reload, and trust rules. Direct native widget hooks, external CPU/GPU buffers,
and asynchronous native operations remain subsequent stages.

## Native UI embedding

The `ourokit_ui` Zig module is the platform-neutral embedding boundary for
native hosts such as compositors. It exports `core`, `text`, `scene`, `layout`,
`render_object`, the `software` renderer, and a thin `Surface` owner. `Surface`
reconciles parent-before-child `Descriptor` snapshots, owns fixed-capacity
render-object and scene storage, lays out in logical coordinates, lowers a
display list at an explicit output scale, hit tests by descriptor ID, and
provides platform-free pointer capture through `pointerPress`, `pointerMotion`,
and `pointerRelease`.

Images remain caller-decoded at this boundary: insert an `ImageBitmap` into an
`ImageCache`, call `Surface.attachImageCache`, and render with
`software.renderResources`. Neither Cargo nor the image decoders are required.

Immutable `path` geometry and bounds are always available. Rendering nonempty
paths requires opting into `-Dui-paths=true` (dependency option `.@"ui-paths" = true`),
which builds the tiny-skia/resvg bridge with Cargo or links a supplied ABI-2 bridge
with `-Dresvg-system=true`. Without it, rendering a nonempty path returns
`error.PathRasterizerDisabled` before changing the target. The full `ourokit`
module always enables path rasterization.

Outset Box shadows (`shadow.Style`) are pure Zig and available without opt-in
or Cargo. They do not change layout or hit bounds. See the
[shadow rendering contract](docs/rendering.md#outset-box-shadows) for clipping,
blur, cache, and device limits.

Text remains explicit: a caller that uses Text render objects must create and
attach its own paragraph source/layout caches, and text-capable software
rendering requires caller-owned glyph/font caches. Fontconfig discovery is
always disabled for `ourokit_ui`; `-Dfreetype=true` only enables explicit glyph
rasterization. The module does not import Ourokit's Lua runtime, task scheduler,
application/window host, Wayland client, generated Wayland protocols, or Vulkan
renderer. A consumer-only smoke test can be run independently with:

```sh
zig build test-ourokit-ui-consumer
```

The public `ourokit.mcp` module provides bounded sans-I/O MCP client and server
state machines, literal Unix address parsing, and JSON Schema validation. See
[the MCP transport and Lua API](docs/mcp.md).

Ordinary `ouroctl run` opens the application without an MCP server. Desktop
activation uses `org.freedesktop.Application`; `single_instance = true` selects
application-wide ownership and forwarding through the session bus. See the runnable
[Contacts application](examples/contacts/README.md) and
[permission dialog](examples/permission-dialog/README.md).

Development is explicit per process. `--dev` prints a unique private socket
path; two development copies never forward to each other or to production.
Status and reload require that exact path, independent of declared actions:

```sh
ouroctl run examples/contacts/ouro.json --dev
ouroctl dev status "$development_socket"
ouroctl dev reload "$development_socket"
ouroctl activate dev.example.app
```

Optional `--mcp` exposes only declared actions at
`$XDG_RUNTIME_DIR/ourokit/apps/<application-id>`. It cannot enable development
diagnostics or determine desktop lifecycle. `--headless` is a separate explicit
launch option; neither declaring actions nor exporting them starts a service.

Export an installed tool catalog without opening the UI or connecting to a
running application:

```sh
ouroctl mcp export examples/contacts/ouro.json --output dev.ourokit.contacts.json
```

Install the result under `$XDG_DATA_HOME/ourokit/mcp/apps` for a user application,
or `$datadir/ourokit/mcp/apps` for a system package. Optional MCP consumers can
read these descriptors without starting applications. See the
[XDG discovery and runtime-catalog contract](docs/mcp-discovery.md).

See [transactional source reload](docs/hot-reload.md) for the generation and
failure-preservation guarantees.

Installed applications use `ouro.json` so identity is
known before mutable Lua source is evaluated:

```json
{
  "schema_version": 1,
  "id": "dev.example.Contacts",
  "entry": "app.lua",
  "minimum_runtime_api": 1
}
```

From the application directory, `ouroctl run` loads `./ouro.json` and validates
that the returned `ouro.app` declaration has the same ID. It does not search
parent directories. `ouroctl run app.lua` remains available as an explicit
override.

`minimum_runtime_api` is optional and checked before loading application code.
For direct Lua entries, use `require('ouro').runtime.api_level` with a guard for
older hosts lacking `runtime`. `ouroctl version` includes the executing host's
API level and source revision: package version `0.1.0` alone cannot identify
features in per-commit binaries. See [runtime compatibility](docs/runtime.md#runtime-api-compatibility)
for the level contract, legacy behavior, and downstream test example.

Native Linux builds enable Fontconfig by default. Minimal/headless builds and
cross-compilation can omit that system capability with `-Dfontconfig=false`;
deterministic shaping and rendering tests remain available. Application and
Storybook runners require Fontconfig and installed fonts; embedded native hosts
can still supply their own font bytes explicitly.

Software glyph rasterization is also optional (`-Dfreetype=false`) and disabled
by default for cross targets. The
`ouro.text { key, text, size?, alignment?, max_lines?, overflow? }` constructor
retains width-independent text/style identity, resolves a cached paragraph from
its current box constraints, and rasterizes through a backend-owned FreeType
glyph cache. It supports Unicode itemization, bidi, fallback shaping, and
wrapping; unchanged constraints perform no layout acquisition or allocation.
`ouro.image { key, src, width?, height?, fit?, tint?, alt? }` loads PNG, JPEG,
WebP, and self-contained static SVG asynchronously. Use `bytes` instead of `src`
for encoded data. `ouro.icon` uses the same native Image primitive with a 24×24
default and inherited foreground tint for file/byte sources. Named XDG icons use
`ouro.xdg.icon { key, name, theme? }` (also accepted by `ouro.icon`), with system
theme inheritance, size/scale lookup, and `hicolor` fallback. Regular named icons
keep their colors; `-symbolic` icons inherit the foreground. See
[XDG icon authoring](docs/application-model.md#xdg-named-icons-use-the-system-icon-themes)
and `examples/xdg-icons.lua`. See [image authoring](docs/application-model.md#images-and-icons-load-asynchronously)
and `examples/images.lua` for formats, fit modes, and theme-aware icons.

`ouro.row`, `ouro.column`, `ouro.scroll`, and `ouro.text` provide nested composition without
application-managed numeric IDs or parent links. Each widget constructor takes
one props table and returns an opaque description; it does not emit UI when
called. A window or story's `content` function returns one root description, or
nil for empty content. Containers take ordered array entries in the props table
or an explicit dense `children = { ... }` table, never both or a child callback.
Use a structural parent such as a row or column for multiple widgets and keep
stable local `key` values. `ouro.button` composes a Box
and Text using generated design tokens and retains hover, pressed, and disabled
state in the widget layer. Buttons activate on press; release clears their
pressed visual state. Buttons are content-sized by default, use token-derived
height and horizontal padding, and constrain labels to one ellipsized line;
applications may still declare an explicit width. The Box centers the Text
within those padded bounds, separately from paragraph alignment. Button is not
a renderer primitive. `ouro.listbox` and its direct `ouro.option` children
provide a controlled single-selection list with one Tab stop and
Up/Down/Home/End navigation.
For large generic collections, `ouro.virtual_list { key = "people",
item_count = 10000, item_key = person_key, item_height = 40, render_item =
render_person }` mounts only viewport rows; see
[`examples/virtual-list.lua`](examples/virtual-list.lua).
Both ordinary and virtual viewports support native `scrollbar=true`, deferred
`on_scroll(metrics)` observation, and one-shot `scroll_to={offset=...,token=...}`
requests; see [`examples/scroll-storybook.lua`](examples/scroll-storybook.lua).
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

To profile CPU text rasterization with a Folio-sized editor (960×760 logical
pixels, 680 px wrapping width, 23 px text):

```sh
zig build bench-software-text -Doptimize=ReleaseFast -Dvulkan=false
# Arguments: mode, frames, prose repetitions, integer output scale.
zig build bench-software-text -Doptimize=ReleaseFast -Dvulkan=false -- all 120 1024 2
# Start empty and hold a key; the prose repetition argument is unused here.
zig build bench-software-text -Doptimize=ReleaseFast -Dvulkan=false -- typing 120 1 2
zig build build-software-text-benchmark -Doptimize=ReleaseFast -Dvulkan=false
perf record -e cpu-clock:u -F 499 -g --call-graph dwarf -o /tmp/ouro-text.data -- \
  zig-out/bin/ourokit-software-text-benchmark warm 3000 1024 1
perf report -i /tmp/ouro-text.data
```

Modes are `all`, `blank` (clear and presentation conversion only), `warm`
(full redraw), `scroll` (integer offsets), `fractional` (quarter-pixel logical
offsets), `caret` (synthetic 2×27 px damage, not runtime damage tracking), and
`typing` (retained multiline editor updates starting empty).
Raster modes report one cold render and timed frames with persistent glyph
and working buffers, plus cache occupancy. Scrolling can introduce new subpixel phases;
its timed samples include those misses. Compare 8, 128, and 1024 repetitions
at the same viewport to expose work on offscreen text. The fixture uses pinned
Inter for reproducibility, not Folio's system-dependent `serif` font. Pixel
checks verify visible text, cold/warm equality, scrolling, and damage isolation.
Frame timings exclude shaping/layout, validation, Lua, Wayland, and compositor
latency; `perf` covers the whole process, so use enough frames to amortize setup.
`typing` times edit/layout/scene separately, then compares whole-paragraph ink
damage against changed-line ink damage, both with reused working storage. It
checks identical output after every character and reports damaged pixel counts.
It does not simulate compositor backpressure or presentation-buffer age.
These are CPU measurements, not an end-to-end CPU/GPU comparison.

To profile pure headless bidi analysis, script analysis, combined paragraph
itemization, UAX #14 opportunities, shaped measurement, greedy selection, and
line-local bidi independently from UI, rendering, and Wayland:

```sh
zig build bench-paragraph -Doptimize=ReleaseFast \
  -Dfontconfig=false -Dfreetype=false
```

The optional end-to-end application benchmark compares one matched clickable
Text/Button window against GTK 4 and Qt 6 under Wayland. GTK/Qt development
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
# Run the layer-shell panel example:
zig build run-wayland-example -- --layer-shell
```

The executable wrapper is intentionally tiny. Its application is
`examples/wayland.lua`, which declares the app, window, signal, and button;
`app.runWayland` owns the ring, scheduler, Lua VM, font/text caches, retained UI,
selected renderer, and Wayland presentation. Vulkan-capable builds select Vulkan
by default; pass `--software` after `--` to select software rendering instead.
The layer-shell example requires a compositor advertising
`zwlr_layer_shell_v1`. Ourokit targets the current version 5 protocol while
remaining compatible with older versions when declarations do not request
newer-version features. A layer declaration can select an output by its
`wl_output.name`; declare one uniquely identified surface per output for
multi-monitor panels or backgrounds. Named surfaces wait through output removal
and are recreated if that output returns.

Shell applications can opt into reactive `ext-workspace-v1` snapshots and
workspace actions through [`ouro.shell.workspaces`](docs/workspaces.md).

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

return ouro.text_input {
  key = "query",
  text = query(),
  label = "Application query",
  placeholder = "Search applications...",
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

Optional `placeholder` is a muted display-only hint for empty fields without
active IME preedit; it never enters the value or `on_change` data. Optional
`label` provides an independent semantic accessible name, not a visible label.
See the [input and box API](docs/application-model.md#inherited-visual-defaults)
for styling, precedence, and accessibility limitations.

## Lua component tests

Run from the project root with the installed `ouroctl`; neither the Ourokit
source tree nor Python helpers are needed:

```sh
ouroctl test                              # recursively find tests/**/*_test.lua
ouroctl test tests/counter_test.lua       # one file
ouroctl test tests/editor                 # one directory subtree
ouroctl test --filter increment          # literal substring in file or test name
ouroctl test --list                       # evaluate files, but do not run tests
ouroctl test --json                       # one JSON report on stdout
ouroctl test --timeout-ms 20000           # default: 10000 per worker
```

Each file returns a table mapping nonempty names to functions. Import modules
at file scope: `require('components.counter')` resolves from the working
directory as `components/counter.lua` or `components/counter/init.lua`.
As in Storybook, cached imports remain available during tests, but first-time
disk imports after file evaluation are rejected.

```lua
local Counter = require('components.counter')

return {
  ['increment updates the count'] = function(t)
    t:mount(Counter, { width = 420, height = 300 })
    assert(t:node('root/count').label == '0')
    t:click('root/increment')
    assert(t:node('root/count').label == '1')
  end,
}
```

Files and test names run in lexical order. Every test re-evaluates its file in
a fresh process, Lua VM, module cache, and retained UI runtime. File evaluation
must therefore only declare fixtures and tests, not perform external side effects.
The runner cleans up mounted UI after success or failure, terminates workers
that exceed their deadline (including infinite Lua loops), and continues with
remaining tests. Exit status is 0 for success, 1 for failures or no matching
tests, and 2 for invalid CLI arguments. Failed results include Lua diagnostics;
JSON reports contain `results`, `passed`, `failed`, `listed`, and `error_message`.

The test context provides:

- `t:mount(content, options?)`: mount one content callback per test; options
  accept `width`, `height`, and `padding`. Defaults are 640 × 480 logical pixels,
  light theme, scale 1, and 12-pixel root padding. Padding must be a finite,
  non-negative number; `padding=0` gives content the full viewport, matching
  `ouro.window {padding=0}` and `ouro.story {padding=0}`.
- `t:node(path)`: copy a public semantic node by slash-separated widget keys.
  Inspect `label`, `value`, `role`, `bounds`, `focused`, `checked`, `selection`,
  and other development-inspection fields. IDs are hexadecimal strings;
  absent optional fields are nil. Missing paths fail explicitly.
- `t:click(path)`, `t:hover(path)`, `t:scroll(path, delta)`, `t:text(text)`,
  and `t:key(key, modifiers?)`: drive the normal retained input path. For
  example, `t:key('a', { control = true })` selects all text in a focused editor.
- `t:input { action = ..., ... }`: the same action arguments as
  `ouroctl dev input`, without a window or token, including pointer down/move/up.
- `t:settle()`: settle after changing state from the test body. This runs pending
  task-phase work, then dispatch and reconciliation, as after an input. Without
  it, the next `t:node` or `t:click` fails with `DevelopmentRuntimeNotSettled`.
  Examples are sending a chart event or advancing a `machine.manual_scheduler()`
  clock.

Mount and input drain runnable callbacks, reconciliation, layout, and scene
preparation before returning. `t:node` and input first settle changes made
outside input, such as a statechart driven directly with `actor:send` or a
manual scheduler's `clock.advance(ms)`. They do not wait for animation completion or
arbitrary async work. Sleeps and callbacks awaiting external work fail rather
than introduce timing-dependent tests. For statechart timers, give actors a
`machine.manual_scheduler()` and call `t:settle()` after advancing it. Use reduced motion where a test needs stable control state. Assertions
use ordinary Lua `assert`; no additional framework dependency is required.

These tests cover component behavior and pure Lua models, not real compositor
delivery, desktop services, or pixel comparisons. Use Lua fakes passed into
application models for controlled service outcomes, Storybook for snapshots,
and a small separate desktop integration suite where needed. Ourokit's Python
protocol and desktop fixtures remain internal regression tests, not an app SDK.
See [`tests/components_test.lua`](tests/components_test.lua) for complete examples.

## Storybook

Storybook catalogs are explicit Lua entry points containing named, isolated
component states. Local `require('view')` imports resolve relative to the catalog
directory, using the same `view.lua` / `view/init.lua` lookup and module cache as
applications. Import shared modules during catalog evaluation; cached imports
remain available in content callbacks, but first-time disk imports after
bootstrap are rejected. No bundling or working-directory change is required.
Headless catalogs reject sleeps; any spawned bootstrap tasks are drained before
rendering. Lua errors and tracebacks are written to stderr, leaving JSON stdout
machine-readable. Open the native interactive catalog browser with:

```sh
zig-out/bin/ouroctl storybook run examples/storybook.lua
```

The browser is an ordinary Ourokit application: its catalog scrolls through
the normal pointer input path, selection uses a signal, and the selected story
is mounted as live content at its declared viewport and color scheme. Force a
renderer with `--software` or `--vulkan`.

For retained Lua components, run `examples/components.lua` instead. Its counters
show independent rebuild counts, state-preserving prop changes and reordering,
and state reset after unmount/remount. See the
[component authoring contract](docs/application-model.md#declarative-surfaces).

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

Snapshots use lossless compressed PNG by default. Run `zig build test-storybook`
to verify local imports, diagnostics, empty status text, and headless output.

Each story declares a fixed logical viewport, optional `snapshot_scale`, color
scheme, optional `padding`, and ordinary Ourokit content callback. Story padding
is a finite, non-negative logical number; omitted/nil keeps the 12-pixel inset,
while `padding=0` renders edge-to-edge. It applies to snapshots and the native
browser's preview rectangle. Snapshot scale affects PNG
raster dimensions only; the interactive browser uses its window's native
output scale. Snapshots use Fontconfig's system fonts, write
PNG files atomically beneath the output directory, and report SHA-256 hashes.
Pin the font files and Fontconfig configuration for reproducible snapshots. A
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

`{ type = "tab", target = "content/control" }` replays a real Tab press and
asserts that the next focus stop has that semantic path; it does not directly
assign focus. Click and pointer-down actions also support `ouro.switch`.
The `switch/*` stories cover light/dark, checked/unchecked, disabled, and
keyboard-focused states. Switches expose controlled `checked` and
`on_change(boolean)`; see [the API](docs/application-model.md#controlled-switches).

Application-wide themes override colors, typography, control geometry, and
per-widget defaults on `ouro.app { theme = { ... }, windows = { ... } }`.
Nested `ouro.theme` descriptions inherit and override those defaults; explicit
widget props win. See [the theme API](docs/application-model.md#inherited-visual-defaults).
These three applications share exactly the same Contacts content and behavior:

```sh
zig-out/bin/ouroctl run examples/themes/paper.lua --software
zig-out/bin/ouroctl run examples/themes/terminal.lua --software
zig-out/bin/ouroctl run examples/themes/candy.lua --software
```

Constrained and themed composition use the same returned descriptions as rows,
columns, and scroll views. A content function can return this tree:

```lua
return ouro.theme {
  key = "dark-preview",
  color_scheme = "dark",
  children = {
    ouro.box {
      key = "viewport",
      width = 640,
      height = 480,
      padding = 12,
      alignment = "center",
      children = {
        ouro.button { key = "action", label = "Continue" },
      },
    },
  },
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
- [D-Bus clients and services](docs/dbus.md)
- [Native idle, output power, session locks and authentication](docs/session.md)
- [Desktop choosers, external opening, and notifications](docs/desktop-services.md)
- [XDG directories](docs/xdg.md), [secret storage](docs/secrets.md), and [desktop installation](docs/desktop-installation.md)
- [Local file I/O](docs/files.md) and [multi-document example](docs/documents.md)
- [Application model](docs/application-model.md)
- [Transactional source reload](docs/hot-reload.md)
- [Native plugins](docs/native-plugins.md)

Instance-adjacent typed pointer bindings now replace proof-wide global event
dispatch. Widget-specific callbacks such as `ouro.button { on_press = ... }`
use explicit Lua registry lifetime and task-phase scoped coroutine dispatch;
render objects and platform callbacks remain callback-free.
