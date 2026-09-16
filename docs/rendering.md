# Rendering

## Scene and color contract

The display list contains value commands for clear, solid rectangles, and a
balanced rectangular clip stack. A borrowed `DisplayList` supports immediate
consumption. An owning `Frame` copies command and damage storage so worker
threads and asynchronous backends can safely retain it through completion.

Scene and design `Color` values, including Lua hex literals and Radix tokens,
are straight-alpha, 8-bit sRGB. Renderers decode RGB with the piecewise sRGB
transfer, premultiply in linear light, and
apply Porter-Duff source/source-over there. Alpha and A8 glyph/geometry coverage
are linear quantities, never gamma-decoded. Image texels are unpremultiplied and
decoded before bilinear filtering, then filtered and composited in premultiplied
linear light.

Presentation bytes are premultiplied 8-bit piecewise sRGB desktop colors.
Output conversion unpremultiplies linear RGB, sRGB-encodes it, and
premultiplies the encoded result. This preserves the `wl_shm` ARGB and ordinary
untagged dma-buf contract even for transparent surfaces; alpha is never encoded.
No compositor high-precision format or color-management protocol is required.
This is SDR with sRGB/BT.709 primaries, not wide gamut or HDR;
blending a translucent surface with other windows remains the compositor's job.

The direct-presentation prototype deliberately replaces the earlier gamma-2.2
output transfer across software, compute readback, and graphics presentation.
Opaque scene RGB now round-trips to the same sRGB codes, including dark colors.
This changes display bytes, especially near black; it is not a byte-compatible
optimization. Explicitly named gamma-2.2 core helpers remain for older captures.

Decoded PNG, JPEG, WebP, and SVG image-cache bytes remain explicitly piecewise
sRGB. Texels are sRGB-decoded into the shared linear-light working space, so
images and UI colors compose without encoded-space blending. Storybook
and renderer-review PNG exports unassociate presentation pixels without another
transfer; PNG files contain straight sRGB rather than Wayland premultiplied RGB.

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
Opaque output conversion uses an exact 64 KiB piecewise sRGB lookup table,
also used for image interchange. All 256 opaque gray codes survive import and
export. Alpha-bearing pixels still incur ordinary premultiplied quantization.

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

For a provably opaque reconstructed scene, the presentation prototype blends
directly into the exported `B8G8R8A8_SRGB` modifier image. Vulkan decodes the
destination RGB before blending and encodes RGB on attachment writes; alpha
remains linear. There is no working image, conversion subpass, copy, aliasing,
or feedback loop. Eight-bit storage quantizes after each draw, unlike FP16.
Ordinary damaged UI pixels are reconstructed, not accumulated indefinitely.
Reconstruction prevents temporal accumulation but cannot recover sub-code
contributions within a frame: twenty alpha-1 black overlays over white produce
255 on llvmpipe and 251 on Intel Lunar Lake, versus 246 with FP16. Fixed-function
sRGB precision is implementation-dependent; regression tests require stable
reconstruction rather than one driver's accumulated rounding result. In the
representative text/overlap/dark-ramp capture, direct and converted sRGB differed
by at most one channel code; that bound is not guaranteed for arbitrary scenes.

`DisplayList.isOpaque` conservatively requires a full opaque clear or rectangle
and rejects later source replacements that could introduce transparency.
Rounded rectangles do not establish full coverage. The Wayland runner calls
`Host.prepareScene` before acquisition; a changed proof retires the old pool
through the same generation-safe lifecycle as resize. Callers that omit this
step retain alpha-capable storage. Rendering an unproven scene to a direct
target fails before submission. The selected modifier must independently
support sRGB export, color attachment blending, and its reported plane layout;
otherwise even an opaque scene uses the converted path.

Transparent and unproven scenes blend into the supplied persistent
`R16G16B16A16_SFLOAT` attachment shared by a window's slots. A second subpass
converts it to an exported `B8G8R8A8_UNORM` image. This private working image
preserves alpha correctness: half-white over transparent exports RGB128/A128,
not the RGB188/A128 that direct sRGB attachment storage would produce.
Missing FP16 color/blend/transfer support still disables dma-buf graphics and
preserves SHM/software fallback. FP16 fixtures retain their precision checks;
focused direct fixtures allow only measured quantization differences.
Software and headless compute remain the exact-byte reference profile.

These rules follow Vulkan's [sRGB framebuffer blending specification](https://docs.vulkan.org/spec/latest/chapters/framebuffer.html)
and [DRM modifier extension](https://docs.vulkan.org/refpages/latest/refpages/source/VK_EXT_image_drm_format_modifier.html):
DRM format names do not distinguish Vulkan UNORM and sRGB transfers. Actual
format/modifier support is queried rather than inferred from the DRM name.

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
Wayring host supplies that lifecycle itself: up to three persistent slots,
`wl_surface.frame` redraw throttling, `wl_buffer.release` reuse gating, and
generation-safe resize retirement, all driven by Ourokit's io_uring loop.
Only the first slot is allocated initially; the pool grows when all existing
slots are unavailable. Each slot owns its export image and command/fence state.
Converted slots retain the same high-precision working image; direct slots
have no working allocation. Render-pass dependencies on
the single graphics queue order working-image writes after earlier conversion
reads without a CPU wait between slots. Reuse requires both GPU completion and
`wl_buffer.release`. Resize creates a new working image; retired storage lives
until its slots finish using it.

When available, linux-drm-syncobj pairs each slot with an exported Vulkan
timeline semaphore. Vulkan signals the acquire point, the compositor signals
the release point, and the next submission waits for that release. Otherwise
the same ownership transfers use dma-buf implicit synchronization.
`wl_surface.frame` remains the pacing signal; `wp_presentation` reports the
compositor's clock ID, presentation timestamp, refresh interval, sequence, and
hardware/vsync/zero-copy flags through `Host.takePresentationTiming`. Neither
path uses libwayland or Vulkan Wayland WSI.

The host tracks buffer age per SHM/direct slot and per converted Vulkan working image. Each
successful commit records the current scene damage and the corresponding
presentation serial. `prepareFrameDamage` expands damage by intervening records;
new storage and ages older than retained history repaint fully. A newly added
converted Vulkan slot uses the existing working image's history, so it does
not require a full scene redraw. A new direct slot always reconstructs fully,
even if requested damage is empty. Discard invalidates the converted pool's
shared age or the affected direct slot's age, respectively.
Regions are conservatively coalesced to one bounding rectangle. The renderer
receives expanded damage while `wl_surface.damage_buffer` reports only the
current visible change. Device-loss recovery, richer region coalescing, and
larger descriptor/resource caches remain future work.

### Reproducing the presentation comparison

Build with Zig 0.16 and run the executable directly:

```sh
zig build build-presentation-probe -Doptimize=ReleaseFast
zig-out/bin/presentation-probe /tmp/presentation 2844 1704
# Optional: compositor-selected modifier in decimal or 0x-prefixed hex.
zig-out/bin/presentation-probe /tmp/presentation-native 2844 1704 MODIFIER
```

The probe compares converted opaque, direct opaque, and converted transparent
scenes using two slots, 8 warmups, and 60 measured submissions per case. It
reports actual image memory requirements, Vulkan timestamp median/p95, and
CPU submit-plus-wait median/p95 for full and 128×64 damage. Without a modifier,
linear mapped attachments permit PNG captures of text, dark ramps, and overlap.
With a modifier, it tests native export allocation/rendering but does **not**
hand buffers to a compositor or measure compositor frame times. Unsupported
modifiers are reported, not silently substituted. The baseline probe uses the
same workload and instrumentation against the supplied FP16/gamma-2.2 snapshot.

Orb llvmpipe measurements at 2844×1704: two export images require 38,823,936
bytes; the shared FP16 image also requires 38,823,936 bytes. Direct removes the
latter: window image allocations fall from 74.05 to 37.03 MiB. This is not
driver-resident accounting and does not predict Intel compression or modifiers.
Measured software-Vulkan timestamp medians (full / partial, milliseconds) were
32.826 / 26.135 for the supplied baseline, 31.824 / 25.257 for converted sRGB,
and 2.724 / 0.558 for direct sRGB. These are executed software-driver costs,
not Intel performance claims or compositor frame-time measurements.

Local Intel Lunar Lake testing with native modifier 0 at the same extent and
two slots reports 38,769,408 exported bytes plus 39,370,752 working bytes for
converted rendering; direct retains only the exported bytes. Release-build
GPU timestamp medians (full / partial, milliseconds) are 0.918 / 0.742 for the
FP16 gamma-2.2 baseline, 0.883 / 0.736 for converted sRGB, and 0.864 / 0.016
for direct sRGB. Removing the full-window conversion primarily benefits small
damage, not full redraws. These are command timestamps, not presentation latency.
The 960×540 direct-versus-converted sRGB capture differs by at most one channel
code, with mean RGB delta 0.001410 and 1,612 differing pixels out of 518,400.

On an isolated Intel-backed Sway Vulkan compositor, a transparent layer fixture
passes 40 alternating opacity changes with rapid output resizes, followed by
opaque/transparent/opaque captures and clean application exit. Synchronization
validation reports no diagnostics. Its half-white output over black matches
the software reference; all captured RGB channels differ by at most two codes.
The local full suite passes all 511 tests, and running the 483-test root executable
directly under synchronization validation also passes without diagnostics.

Matched hello-world processes on that compositor, created at 2844×1704 physical
pixels (1.5× scale) without subsequent resizing, report the following after
10 seconds settling and a 30-second idle sample:

| Renderer | PSS (MiB) | DRM resident (MiB) | Threads |
| --- | ---: | ---: | ---: |
| Ourokit shared FP16 baseline | 12.57 | 114.10 | 3 |
| Ourokit direct sRGB | 12.62 | 76.10 | 3 |
| Qt Quick OpenGL | 49.19 | 97.63 | 10 |

All three consumed zero additional CPU ticks during the idle sample. DRM
clients are deduplicated by PCI device and client ID; GPU residency is not
added to PSS. These are process residency observations, not just image memory
requirements. Compositor/modifier choice and resize history affect residency:
the earlier Qt result on the Ouro desktop was lower, so this Sway comparison
does not establish an across-compositor ranking.

Still check the installed Ouro compositor's explicit-sync handoff and actual
presentation latency before treating these command-time results as end-to-end
performance. Record `/proc/PID/fdinfo` DRM resident totals deduplicated by device
and client ID separately from PSS, at matched sizes and slot counts. The orb has
no Intel DRM device; the hardware results above come from the local runner.

For validation, set `VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation` and
`VK_LAYER_ENABLES=VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT`
when running the probe or compiled root test executable **directly**. Do not
inject validation into Zig's `--listen` test protocol. The standalone
`test-ourokit-ui-consumer` image mismatch predates this prototype; it is not
part of the passing root suite or evidence of direct-path correctness.

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
