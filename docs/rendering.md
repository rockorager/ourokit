# Rendering

## Scene and color contract

The display list contains value commands for clear, solid rectangles, and a
balanced rectangular clip stack. A borrowed `DisplayList` supports immediate
consumption. An owning `Frame` copies command and damage storage so worker
threads and asynchronous backends can safely retain it through completion.

Scene and design `Color` values are straight-alpha, 8-bit ordinary desktop
colors: sRGB/BT.709 primaries with a pure gamma-2.2 display response. Renderers
decode RGB with that transfer, premultiply in linear light, and
apply Porter-Duff source/source-over there. Alpha and A8 glyph/geometry coverage
are linear quantities, never gamma-decoded. Image texels are unpremultiplied and
decoded before bilinear filtering, then filtered and composited in premultiplied
linear light.

Presentation bytes are premultiplied 8-bit gamma-2.2 ordinary desktop colors.
Output conversion unpremultiplies linear RGB, gamma-2.2 encodes it, and
premultiplies the encoded result. This preserves the `wl_shm` ARGB and ordinary
untagged dma-buf contract even for transparent surfaces; alpha is never encoded.
No compositor high-precision format or color-management protocol is required.
This is SDR with sRGB/BT.709 primaries, not wide gamut or HDR;
blending a translucent surface with other windows remains the compositor's job.

Decoded PNG, JPEG, WebP, and SVG image-cache bytes remain explicitly piecewise
sRGB. Texels are sRGB-decoded into the shared linear-light working space, so
images and gamma-2.2 UI colors compose without encoded-space blending. Storybook
and renderer-review PNG exports convert gamma-2.2 presentation pixels back to
straight piecewise sRGB; PNG files are therefore interchange images, not dumps
of Wayland buffer encoding.

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

Each render call allocates an RGBA16 UNORM working buffer (8 bytes/pixel) using
the target's allocator. All draws in that call blend at 16-bit precision; only
damaged pixels are encoded back to presentation storage. A leading clear avoids
reading caller storage; otherwise damaged pixels are imported from the existing
8-bit output. Precision persists across draws, not across separate render calls.
Opaque output conversion uses an exact 64 KiB gamma-2.2 lookup table. The
piecewise sRGB table remains separate for image interchange and PNG export.
UNORM16 cannot represent every near-black gamma-2.2 value: opaque code 1
rounds to linear zero. Conversion uses nearest quantization without a special
transfer-function exception; encoded round trips can differ by one byte level.

Ourokit owns this backend and its lowering policy. Direct paths handle clear and
opaque rectangles. Pixman is pinned as a lazy, benchmark-only dependency while
the scene vocabulary is small; no Pixman type crosses the software-backend
boundary. Any future Pixman lowering must preserve linear-light semantics.

`zig build bench-renderers -Doptimize=ReleaseFast` measures 1920×1080 mixed
rectangle scenes against legacy encoded-8-bit Pixman 0.46.4. The two outputs
intentionally differ and are independently checked against their respective
color math. Ourokit's timing includes linear working storage and presentation
conversion; this is not an output-identical speed comparison. Record CPU/target
details when using results to alter lowering or batching.

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

The Vulkan backend is a peer of software and consumes equivalent scenes.
It owns a Vulkan instance/device/compute queue, pipeline, command resources,
synchronization, and host-visible storage targets. It lowers clear, solid
rectangle, rectangular clip, damage, source, and source-over operations with
the same linear RGBA16 integer color arithmetic as software. Its synchronous
headless target and explicit readback make backend conformance testable without
a window system. Compute calls serialize and wait for GPU completion.

Vulkan is enabled by default and is the default runtime renderer when compiled
in. `-Dvulkan=false` produces a software-only build that neither compiles Vulkan
shaders nor discovers or links the Vulkan loader. Both configurations preserve
the same renderer-neutral scene boundary.

The presentation profile blends into a persistent `R16G16B16A16_SFLOAT`
attachment owned by each target. Scene draws honor damage; a second subpass
converts the entire attachment into an exportable `B8G8R8A8_UNORM` modifier image.
The high-precision attachment is private to Vulkan, not shared with the
compositor. Missing FP16 color/blend/transfer support disables dma-buf graphics
and preserves the existing SHM/software fallback. FP16 blending can differ
slightly from the integer reference; graphics fixtures allow one byte of output
error. Software and headless compute remain the exact-byte reference profile.

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
The scene receives common positioned glyph runs; each backend may own
atlas/image caching, hinting, and rasterization details. Neither backend exposes
a `measureText` operation, chooses fonts, performs bidi, or reshapes strings.

The shared FreeType glyph cache explicitly selects Adobe hinting and enables
its default size-dependent stem darkening for available CFF, Type 1, and CID
drivers. This gives the bundled Source families suitable small-size weight for
linear-light blending without altering shaping advances. Outlines load with
`FT_LOAD_TARGET_LIGHT | FT_LOAD_NO_BITMAP` and render with
`FT_RENDER_MODE_NORMAL`; experimental auto-hinter darkening is not forced.
This phase-aware, light-hinted, Adobe-darkened mode (B) is the sole rendering
policy. Historical unhinted comparisons are not selectable build modes.
Glyph atlases remain A8 grayscale coverage, independent of text
color, background polarity, and display subpixel layout.

The renderers accumulate fractional advances and offsets in device space.
Only the final glyph origin is quantized to 1/64 pixel, then split into an
integer anchor and nonnegative X/Y raster phases using floor semantics.
FreeType translates the loaded outline by that phase before rasterization
(negating scene Y for FreeType's Y-up axis). Bitmap bearings include the
phase; placement adds only the integer anchor. Software and Vulkan share
the phase-bearing cache key, including font generation and fractional size.

Only requested phases are cached. CPU masks are bounded to 16 MiB and 16,384
entries; a miss that exceeds either budget clears old masks. Returned mask
pointers must be consumed before the next cache lookup. Vulkan retains its
2048×2048 atlas and a 16,384-entry limit. Preflight visits the same positions
as drawing; if full, it waits for outstanding GPU work, clears the atlas,
and retries once with only the current scene. A scene that still cannot fit
returns `GlyphAtlasFull` before recording or uploading its frame. It does not
evict live frame entries or eagerly allocate all 64×64 phase combinations.

Retained Text nodes emit a `paragraph` command referencing an immutable width-
specific `ParagraphLayout`. That layout already contains line tops, baselines,
visual-order spans, font handles, glyph IDs, and positions. Software, Vulkan
compute, and Vulkan dma-buf presentation consume that same sequence; their only
text work is backend-owned glyph rasterization and caching. The lower-level
single-run command remains available for focused consumers, and display lists
may contain both command kinds.

Asynchronous `scene.Frame.initWithResources` copies scene storage and leases
all referenced shape and paragraph handles. Plain frame construction rejects
unleased text commands. Borrowed display lists remain valid only while their
owning UI/text scope is alive.
