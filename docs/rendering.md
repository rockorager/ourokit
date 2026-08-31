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

Both backends avoid issuing a draw when the next non-empty draw completely
replaces its clipped pixels. Opaque source-over rectangles, all source-mode
rectangles, and clears provide coverage; translucent source-over draws do not.
The linear lookahead also culls chains of covered draws without allocating an
occlusion region or changing display-list paint order.

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

## Vulkan backend and presentation boundary

The optional Vulkan backend is a peer of software and consumes equivalent scenes.
It owns a Vulkan instance/device/compute queue, pipeline, command resources,
synchronization, and host-visible storage targets. It lowers clear, solid
rectangle, rectangular clip, damage, source, and source-over operations with
the same integer color arithmetic as software. Its synchronous headless target
and explicit readback make backend conformance testable without a window
system. Renderer calls are currently serialized and wait for GPU completion.

Vulkan is disabled by default. Software/headless builds neither compile its
shaders nor discover or link the Vulkan loader. `-Dvulkan=true` enables the real
backend, its tests, and its Wayland dma-buf example while preserving the same
renderer-neutral scene boundary.

The presentation profile renders directly into exportable
`B8G8R8A8_UNORM` modifier images with a graphics pipeline and fixed-function
premultiplied source-over blending. Clear/source writes, integer coverage,
clipping, channel order, and untouched pixels remain exact. Vulkan does not
guarantee the reference backend's integer division rounding for fixed-function
UNORM blending, so each blend-affected channel may differ by one LSB per blend
step. Software and headless compute remain the exact-byte reference profile.

It will not use `VK_KHR_wayland_surface`: that API requires libwayland
`wl_display*` and `wl_surface*` objects, which Wayring handles are not.
Ourokit's presenter exports Vulkan images as dma-bufs and uses Wayring-generated
linux-dmabuf protocols to create and commit persistent `wl_buffer` objects.
Version 4 feedback supplies ordered modifier tranches and DRM device IDs. The
host accepts only a tranche targeting the selected Vulkan primary/render node
and a modifier that is exportable with color-attachment and blend support;
version 3 falls back to an advertised renderable linear modifier. No common
choice falls back to `wl_shm`.

Without libwayland there is no Vulkan swapchain or WSI frame scheduler. The
Wayring host supplies that lifecycle itself: three persistent slots,
`wl_surface.frame` redraw throttling, `wl_buffer.release` reuse gating, and
generation-safe resize retirement, all driven by Ourokit's io_uring loop. Each
slot owns independent command/fence state, so queue submission no longer waits
on the CPU. Reuse requires both GPU completion and `wl_buffer.release`.

When available, linux-drm-syncobj pairs each slot with an exported Vulkan
timeline semaphore. Vulkan signals the acquire point, the compositor signals
the release point, and the next submission waits for that release. Otherwise
the same ownership transfers use dma-buf implicit synchronization.
`wl_surface.frame` remains the pacing signal; `wp_presentation` reports the
compositor's clock ID, presentation timestamp, refresh interval, sequence, and
hardware/vsync/zero-copy flags through `Host.takePresentationTiming`. Neither
path uses libwayland or Vulkan Wayland WSI.

The host supplies buffer age for both SHM and dma-buf slots. Each successful
commit records the current scene damage and the slot's presentation serial.
Before rendering a reused slot, `prepareFrameDamage` expands current damage by
all intervening records; new slots and ages older than retained history repaint
fully. Regions are conservatively coalesced to one bounding rectangle. The
renderer receives expanded buffer damage while `wl_surface.damage_buffer`
reports only the current visible change. This prevents stale pixels without
forcing every rotating buffer to repaint fully. Device-loss recovery, richer
region coalescing, and larger descriptor/resource caches remain future work.

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
