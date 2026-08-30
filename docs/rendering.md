# Rendering

## Scene and color contract

The display list contains value commands for clear, solid rectangles, and a
balanced rectangular clip stack. A borrowed `DisplayList` supports immediate
consumption. An owning `Frame` copies command and damage storage so worker
threads and asynchronous backends can safely retain it through completion.

Scene and design `Color` values are straight-alpha, 8-bit sRGB. The first
storage contract is premultiplied 8-bit encoded-sRGB, with deterministic
Porter-Duff source and source-over operations. This intentionally matches
`wl_shm` ARGB and common Pixman paths. A future linear-light, wide-gamut, or HDR
surface will use a distinct tagged format; it will not silently change these
bytes' meaning.

Integer device-pixel geometry gives clear first rasterization rules. Rectangular
damage regions must not overlap, preventing source-over commands from being
applied twice. Transforms, subpixel edge coverage, path clipping, and layer
isolation remain deliberately uncommitted until equivalent software and Vulkan
prototypes validate their semantics.

The scene has no Lua, Wayland, `wl_shm`, stride, pixel format, or Vulkan state.
UI layout uses logical floating-point geometry above this contract. The
headless scene builder applies output scale and conservatively rounds logical
edges outward into device-space display-list rectangles. Pixel formats and row
layout remain backend-only. Subpixel coverage is still deliberately unfrozen.

## Software backend

The software backend writes to a caller-provided byte slice with explicit
width, height, stride, and `rgba8_unorm` or `bgra8_unorm` byte order. It
validates target extent, clip-stack balance, and damage invariants; clips
geometry; preserves row padding; and writes premultiplied pixels. Deterministic
tests and reusable backend-conformance fixtures assert exact bytes.

Ourokit owns this backend and its lowering policy. Direct paths handle clear and
opaque rectangles. Pixman is pinned as a lazy, benchmark-only dependency while
the scene vocabulary is small. It is the selected private implementation for
future masks, images, gradients, and complex source-over composition when those
commands land; no Pixman type may cross the software-backend boundary.

`zig build bench-renderers -Doptimize=ReleaseFast` compares output-identical
1920×1080 mixed rectangle scenes against Pixman 0.46.4. Benchmarks are evidence,
not permanent thresholds: record CPU/target details when using results to alter
lowering or batching.

## Wayland shared-memory presentation

The manual Wayland example proves the persistent-buffer path through the
Wayland adapter—not scene or the software renderer. The adapter follows this
sequence:

1. create a sealed/appropriately sized anonymous file (for example `memfd`),
   `ftruncate`, and map it;
2. create one `wl_shm_pool` and three persistent `wl_buffer` objects through
   generated Wayring protocols;
3. expose each available mapping as a software `Target`;
4. use BGRA byte order for little-endian `WL_SHM_FORMAT_ARGB8888` after
   validating the platform format contract;
5. attach, damage, request a frame callback, and commit after configure/size
   acknowledgement; and
6. reuse a buffer only after the compositor's `wl_buffer.release`.

Configure/resize creates correctly sized buffers; old buffers stay alive until
released. Frame callbacks gate submission rather than driving a second loop.
Pool replacement and protocol-object destruction happen after complete event
dispatch, preserving the platform safe-point invariant. Platform-neutral frame
state now coalesces layout/paint invalidation and tracks built versus submitted
scene revisions; Wayland's pending-redraw and callback state only determine
when that prepared scene may acquire a buffer. More precise partial-damage
history remains production work.

`platform.wayland.Host.acquireFrame` returns a generation-checked synchronous
borrow of one BGRA shared-memory slot. Rendering must finish with `present` or
`discardFrame` before completion dispatch resumes. The generation prevents a
stale frame from targeting a replacement resize pool. Each toplevel owns its
own current and retired pools, frame throttle, configure state, and close
lifecycle; closing one window never disconnects the others.

## Vulkan boundary

The future Vulkan backend is a peer of software and consumes equivalent scenes.
It owns Vulkan instance/device/queue, command pools/buffers, exportable images
and memory, pipelines, synchronization, and descriptor/cache state. It must
handle device/surface loss and frames in flight without leaking those states
upward.

It will not use `VK_KHR_wayland_surface`: that API requires libwayland
`wl_display*` and `wl_surface*` objects, which Wayring handles are not. The
planned Ouro-owned presenter exports Vulkan images as dma-bufs and uses
Wayring-generated linux-dmabuf protocols to create and commit `wl_buffer`
objects. Format/modifier feedback, GPU/compositor device matching, explicit
synchronization, release ordering, and fallback policy must be proven by a real
prototype before its target/resource interface is frozen. No fake backend or
software-shaped vtable is present now.

Text is shaped above both renderers by the shared HarfBuzz-backed `text` module.
The scene will receive common positioned glyph runs; each backend may own
atlas/image caching, hinting, and rasterization details. Neither backend exposes
a `measureText` operation, chooses fonts, performs bidi, or reshapes strings.

The initial software text path consumes renderer-neutral glyph-run commands
that reference immutable shaped-run handles. Its optional FreeType integration
owns retained faces and grayscale glyph masks below the scene boundary. The
retained Label obtains metrics from text shaping; Box + Label composes a button.
Full paragraph processing remains deferred, and non-Latin input is rejected by
the narrow label constructor rather than shaped with guessed properties.

Asynchronous `scene.Frame` copies currently reject glyph commands until frame
resource leases can retain shaped/font handles. The synchronous Wayland and
benchmark path may consume a borrowed display list while its owning UI/text
scope remains alive.
