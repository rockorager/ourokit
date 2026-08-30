# Ourokit

Ourokit is a Linux application platform: an Ouro-owned design system, typed UI
and render-object architecture, renderer-neutral scenes, software and Vulkan
backends, Wayland integration through Wayring, an embedded Lua 5.5
application environment, and one raw `io_uring` event loop owned by Ourokit.

This repository is at first-milestone scope. It currently proves canonical
design-token generation, clear/rectangle scene rendering, generation-safe raw
`io_uring` timers and cancellation, a zero-standard-library Lua coroutine, and
safe-point resumption after timer completion. It does not yet provide a widget
catalog or usable application shell. A headless declarative-window reconciler
now proves stable native identity, per-window resource scopes, transactional
snapshot validation, and callback-free platform event queuing. A reusable
multi-window Wayring host connects that model to independently configured,
rendered, resized, and closed xdg-toplevels.

## Requirements

- Linux 5.10 or newer with `io_uring`
- Zig 0.16.0 exactly (Wayring's current minimum and target)
- Python 3 for deterministic token validation/generation
- Vulkan loader and headers, plus `glslc` for the Vulkan shader
- A C toolchain is not required separately; Zig compiles embedded Lua

## Build and test

```sh
zig build
zig build test
zig fmt --check build.zig src examples
zig build tokens
```

The default build installs `zig-out/lib/libourokit.a`. `zig build test` includes
real kernel `io_uring` timeout/cancel tests, deterministic software and Vulkan
pixel tests, and the Lua coroutine/timer safe-point integration test.

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

## Wayland development

Wayring is pinned as a Zig package and wrapped by `src/platform/wayland`.
Ourokit owns the ring; Wayring borrows it. Run the software-rendered example
on a Wayland desktop with:

```sh
zig build run-wayland-example
```

Close the window normally to exit. CI or a headless compositor can use
`zig build run-wayland-example -- --exit-after-first-frame`. Exercise
independent multi-window lifetime with:

```sh
zig build run-wayland-example -- --two-windows
```

The Wayland and xdg-shell XML archives are pinned Zig build dependencies used
to generate protocol code; no system libwayland is linked. See
[ARCHITECTURE.md](ARCHITECTURE.md) and
[docs/rendering.md](docs/rendering.md) for the verified integration contract
and shared-memory presentation path.

## Documentation

- [Architecture](ARCHITECTURE.md)
- [Design system](docs/design-system.md)
- [Rendering](docs/rendering.md)
- [Runtime, tasks, Lua, and io_uring](docs/runtime.md)
- [Application model](docs/application-model.md)
