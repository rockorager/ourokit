# Rendering

## Scene contract

The first display list is a borrowed immutable slice of value commands:
`clear(Color)` and `solid_rectangle(RectI, Color)`. Producers must not mutate
the slice while a backend consumes it. Integer device-pixel geometry makes the
current raster result unambiguous; future logical-coordinate transforms must
be introduced above backend clipping rather than inferred from software.

The scene has no Lua, Wayland, `wl_shm`, stride, pixel format, or Vulkan state.

## Software backend

The software backend writes to a caller-provided byte slice with explicit
width, height, stride, and `rgba8_unorm` or `bgra8_unorm` format. It validates
buffer extent/stride, clips negative and oversized rectangles, preserves row
padding, and writes straight RGBA channel values. Deterministic tests assert
the exact bytes.

## Wayland shared-memory presentation

The manual Wayland example proves the complete single-buffer path through the
Wayland adapter—not scene or the software renderer. It:

1. create a sealed/appropriately sized anonymous file (for example `memfd`),
   `ftruncate`, and map it;
2. create `wl_shm_pool` and one or more `wl_buffer` objects through generated
   Wayring protocols;
3. expose each available mapping as a software `Target`;
4. use BGRA byte order for little-endian `WL_SHM_FORMAT_ARGB8888` after
   validating the platform format contract;
5. attach, damage, request a frame callback, and commit after configure/size
   acknowledgement; and
6. reuse or destroy a buffer only after the compositor's `wl_buffer.release`.

Configure/resize creates correctly sized buffers; old buffers stay alive until
released. Frame callbacks gate submission rather than driving a second loop.
A production buffer pool and frame scheduler remain future work; the example
deliberately creates a fresh shared-memory buffer for each rendered frame.

## Vulkan boundary

The future Vulkan backend is a peer of software and consumes equivalent scenes.
It owns Vulkan instance/device/queue, command pools/buffers, images, pipelines,
synchronization, descriptor/cache state, and Wayland swapchain integration.
The backend must handle device/surface loss and frames in flight without
leaking those states upward. A real prototype will settle its target/resource
interface; no fake backend or software-shaped vtable is frozen now.

Text will be shaped above both renderers into common positioned glyph runs.
Each backend may own atlas/image caching and rasterization details.
