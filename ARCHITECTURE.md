# Ourokit architecture

## Platform scope

Ourokit is the complete native application platform, not a Lua framework with
supporting graphics. Lua is one application-language boundary. The platform
also owns design data, typed UI policy and retention, text shaping, scenes,
rendering backends, Linux eventing, Wayland presentation, resource lifecycle,
and eventual application bundles/native extensions.

The intended source structure grows only when modules gain real code:

```text
design/
  tokens/                  canonical Ouro token data
  components/              future component schemas
  icons/                   future Ouro icon sources
  provenance/
tools/design/
src/
  ourokit.zig              library exports
  main.zig                 future application host executable
  core/                    dependency-light values and handles
  loop/                    raw io_uring ownership and operations
  task/                    language-neutral tasks, scopes, resources
  design/                  generated token API
  text/                    future discovery, shaping, metrics, breaking
  ui/
    widget/                future Lua-facing declarations
    instance/              identity, lifecycle, reconciliation, state
    render_object/         small closed typed render-object set
    layout/
    input/
    focus/
    semantics/
    command/               authoritative command registry
  scene/                   immutable renderer-neutral display lists
  renderer/
    software/
    vulkan/                headless Vulkan compute backend
  platform/wayland/        sole Wayring containment boundary
  lua/                     isolated VM and coroutine adapter
  bundle/                  future pure-Lua bundle/module loader
  app/                     small lifecycle/phase coordinator
examples/                  added only when environment-testable
tests/                     cross-module tests as needed
```

There is deliberately no broad `runtime/` module. `app` assembles sibling
implementations and must not absorb them.

## Dependency direction

```diagram
┌─────────────┐
│ Design data │
└──────┬──────┘
       ▼
┌──────────────────┐
│ Widgets/UI policy│
└────────┬─────────┘
         ▼
┌──────────────────────┐      ┌──────────────┐
│ Typed render objects │◀─────│ Text metrics │
└──────────┬───────────┘      └──────────────┘
           ▼
┌────────────────────────┐
│ Renderer-neutral scene │
└───────────┬────────────┘
      ┌─────┴─────┐
      ▼           ▼
┌──────────┐  ┌────────┐
│ Software │  │ Vulkan │
└────┬─────┘  └───┬────┘
     └──────┬─────┘
            ▼
     ┌──────────────┐
     │ Wayland      │
     │ presentation │
     └──────────────┘
```

The scene does not depend on Wayland. Render objects contain no Vulkan or
`wl_shm` state. Renderers do not depend on Lua. Lua cannot access renderer
internals. Design values are generated from canonical data, never hard-coded
as backend policy. `core` contains only small values that break real cycles.

## Event loop and safe points

Ourokit owns and directly drives one `std.os.linux.IoUring`. Operation identity
is a slot plus generation encoded into `user_data`; allocated pointers are
never encoded. Slots retain kernel-referenced timeout storage until terminal
CQEs. Cancel CQEs and operation CQEs are tracked separately, so either ordering
is safe. Wayring and all future I/O share this ring.

Each application turn has explicit phases:

```text
reap CQEs and dispatch Wayring
→ translate platform events
→ mark tasks runnable
→ resume Lua tasks
→ reconcile dirty instances
→ layout and build scenes
→ submit permitted frames
→ flush Wayland and SQEs
```

The invariant is strict: CQE/platform callbacks only update operation state and
mark tasks runnable. They never call `lua_resume`. Lua executes only after the
language-neutral scheduler grants a runnable task during the task phase.
Disposal queues scope cancellation; queued cancellation is applied at that same
safe point, never synchronously during reconciliation or destruction. The
reusable `app.turn.Coordinator` owns this ordering and restores the idle state
on phase failure, so each application host does not reproduce the sequence.

Tasks and heterogeneous resources register under application, window, or
widget scopes. Child scopes now have generation-checked parent links and
recursive cancellation; canceled scopes reject new tasks, resources, and child
scopes. The common registry stores generation-checked handles,
resource kind, owner scope, and cancel/destroy lifecycle hooks. This avoids an
application object with one array and teardown loop per subsystem. Context
pointers may live inside that private registry but are never kernel identities.

## Wayring integration

Pinned Wayring commit `700b194fff32adc619c6ebdae5199223f87f9fc0`
targets Zig 0.16.0 and already supports caller ownership through
`Reactor.initBorrowed(allocator, *IoUring, config)`. No Wayring change is
required.

Wayring prepares multishot `recvmsg`, `sendmsg`, accept, and cancellation SQEs.
It does not submit, wait, or own the global CQ loop. Ourokit batches those SQEs
with its own and calls `submit`. Wayring's `Reactor.route` validates operation,
slot, and generation before actor access. Ourokit filters its own disjoint tags
before passing CQEs to Wayring.

Shared-ring constraints:

- Wayring reserves low `user_data` bytes 1 through 5; Ourokit uses `0xa0` and
  `0xa1` for first-milestone timeout operations.
- Wayring's provided-buffer group ID must not collide with other users.
- The ring and Wayring reactor retain stable addresses.
- SQ capacity and submission ownership are shared.
- Closing a Wayring peer performs descriptor-wide cancellation. No other
  subsystem may independently operate on that Wayland socket, and the peer
  remains alive until cancel, receive, and send terminal CQEs arrive.
- Selected receive payload/control slices are borrowed until released.

Wayring has no libwayland-style prepare/read/dispatch/flush API. Its persistent
receive represents prepare/read; actor completion plus generated dispatch
represents event dispatch; queued transmit data plus `prepareSend` represents
flush. Ourokit's host retains the display connection, registry, required
globals, per-window surfaces, configure state, frame callbacks, persistent
shared-memory buffers, and independent close state rather than flattening them
into a fictional generic window protocol. The host binds `wl_seat` when present
and translates pointer enter/leave, motion, buttons, scrolling, and frame
grouping into bounded typed application data. Raw Wayland fixed-point values
and protocol handles do not cross that boundary. Keyboard support remains a
separate addition because keymap and compose handling require an explicit XKB
design rather than raw key events masquerading as text input.

Driver dispatch can prepare SQEs before returning. The host records that fact
until the application flush phase submits the shared ring; calling `prepare`
again is not sufficient because it need not report already-prepared work. The
same rule applies to SQEs returned directly by connection close preparation.

Application window identity and desired-state reconciliation are
language-neutral. A validated declaration snapshot creates, updates, or closes
generation-checked native instances through a platform host boundary. Every
window receives a child resource scope. Protocol callbacks can enqueue bounded
close/configure data and mark native teardown complete, but cannot invoke Lua
or reconcile declarations. Closed IDs remain tombstoned until a declaration
snapshot omits them, preventing stale state from recreating a compositor-closed
window. The reusable Wayring host implements this boundary for multiple
toplevels. One window can configure, resize, frame, and close without tearing
down its siblings or the display connection. Busy current and retired buffer
generations remain mapped until `wl_buffer.release`; only then are their
protocol objects and mappings destroyed. On display loss, protocol requests
are no longer attempted: local mappings are released, native windows are
reported closed through the same state-only sink, scopes are canceled at the
next task safe point, and Wayring cancellation CQEs are drained before teardown.

## UI, text, scene, and commands

The eventual retained path has four genuinely distinct forms:

1. Lua widgets declare composition and application state.
2. Instances own identity, lifecycle, keyed matching, focus, commands, and
   component state.
3. Typed Zig render objects own layout, paint, clipping, hit testing, and only
   behavior that fundamentally warrants a core type.
4. Scenes contain immutable backend-neutral drawing/resource references.

Padding, theme selection, focus, commands, and keyed identity are not render
objects. Ourokit will avoid repeated parsing of arbitrary `{ type = "..." }`
tables; component schemas should eventually generate Lua constructors, compact
Zig decoding, language-server types, documentation, and validation tests. That
generator is not part of milestone one, and no permanent widget ABI is frozen.

Text discovery, shaping, line breaking, measurement, and positioned glyph-run
construction belong in `text`, above renderers. Both backends consume the same
glyph sequence. Atlas storage and rasterization remain backend-owned.

Commands are not discovered by walking render objects. A future authoritative
registry owns stable semantic IDs and revisioned invocation handles plus title,
category, aliases, scope, enabled reason, state, arguments, shortcuts, and
destructive/reversible metadata. Widgets may contribute contextual entries.

## Rendering backends

The current software backend consumes the same display list contract intended
for Vulkan and writes premultiplied encoded-sRGB RGBA/BGRA bytes into
caller-provided dimensions and stride. Scene colors remain straight-alpha sRGB;
the backend owns conversion and deterministic source/source-over composition.
Tests cover clipping, damage, alpha, format, row padding, clear, rectangles, and
reusable conformance fixtures.

Frame-owned immutable command and damage storage can outlive the scene-building
stack for worker or asynchronous backend use. Borrowed display-list views are
only synchronous conveniences. Rectangular clip and non-overlapping damage
semantics are established; transforms, subpixel coverage, paths, layers, and
advanced color spaces remain open until both real backends validate them.

Ourokit owns software lowering. Direct paths remain for clear and opaque
rectangles. Pinned Pixman is an optional benchmark dependency and the selected
private engine for future masks, transformed images, gradients, regions, and
complex composition. Pixman types never enter scene, UI, or platform APIs, and
default headless builds do not fetch or link it.

The Vulkan peer owns instance/device/queue selection, command buffers,
synchronization, and pipeline state. Its first backend-specific target uses
host-visible Vulkan storage for deterministic headless conformance. Exportable
images and memory, renderer-neutral resource IDs, and caching will live below
scene as presentation and scene vocabularies grow; widgets and render objects
never hold Vulkan handles.

Ourokit cannot use the conventional `VK_KHR_wayland_surface` path without
libwayland: Vulkan requires ABI `wl_display*` and `wl_surface*` objects, while
Wayring intentionally provides its own connection and generation-checked
protocol handles. Those representations are not interchangeable. Wayring
remains the only Wayland implementation, so the planned Vulkan presenter is an
Ouro-owned dma-buf path rather than a standard Wayland swapchain.

The intended prototype will negotiate DRM formats/modifiers from linux-dmabuf
feedback, render into Vulkan external-memory images, export their plane FDs,
and create `wl_buffer` objects through protocols generated for Wayring. Vulkan
owns image/memory/queue lifetime; the Wayland presenter owns protocol objects
and surface commits; a shared frame lease prevents either side from recycling
resources before compositor release and GPU completion. Explicit-sync protocol
selection, fallback behavior, multi-plane formats, modifier policy, and device
matching remain presentation-prototype questions. The headless renderer does
not pretend that this dma-buf path has already been validated.

Headless development remains first-class: deterministic software buffers and
scene logging exist now; semantic snapshots and a design-system gallery are
planned without requiring Wayland or Vulkan.

## Lua isolation

Lua 5.5.1 is fetched by exact URL/content hash. Ourokit compiles Lua core and
`lauxlib.c`, but none of the standard-library implementation files or `linit.c`.
It never calls `luaL_openlibs`. The only initial global is the Ouro-owned table
containing `sleep`; the proof test verifies `print`, `package`, and `coroutine`
are absent.

`ouro.sleep` yields with `lua_yieldk`; its continuation runs only after the task
phase explicitly resumes the coroutine. A Zig frame is not retained across the
yield. A future bundle loader will be pure Ouro functionality, not Lua package
`require`.

## First-milestone non-goals and open questions

Non-goals: complete widgets, text shaping/font discovery, command palette,
accessibility protocols, Vulkan dma-buf presentation, bundle manifests/packing,
installation/package management, native `.so` extensions, broad Lua standard
libraries, network/filesystem APIs, permissions/sandboxing, and full Spectrum
coverage.

Open questions intentionally left unfrozen:

- exact normalized Lua descriptor and generated-constructor ABI above the
  established language-neutral window declaration contract;
- close-policy ergonomics when an application retains a compositor-closed
  declaration, including the eventual default for the last window;
- frame resource leases for future image and glyph references;
- renderer-neutral image/glyph resource identity and cache eviction;
- transform, subpixel rasterization, layer, and color-managed surface semantics;
- Vulkan external-memory, dma-buf presentation, and synchronization contract
  after a real Wayring-native prototype;
- scope close semantics for multiple asynchronous resource kinds;
- versioned application bundle and native-extension ABI.
