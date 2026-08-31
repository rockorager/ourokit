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
  main.zig                 generic declarative Lua application host
  core/                    dependency-light values and handles
  varlink/                 sans-I/O client/server protocol state machines
  loop/                    raw io_uring ownership and operations
  fs/                      language-neutral asynchronous file operations
  task/                    language-neutral tasks, scopes, resources
  design/                  generated token API
  text/                    paragraph analysis, shaping, metrics, Unicode boundaries
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
    vulkan/                Vulkan backend and software-only capability stub
  platform/wayland/        sole Wayring containment boundary
  lua/                     isolated VM and coroutine adapter
  bundle/                  source providers/snapshots; future Lua module loader
  app/                     small lifecycle/phase and per-window coordinator
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
is generation checked and allocated pointers are never encoded into
`user_data`. Logical timers use a userspace min-heap and consume no SQEs of
their own. One absolute kernel timeout follows the earliest deadline and moves
through `IORING_TIMEOUT_UPDATE`; cancellation, update, alarm, and retired CQEs
are tracked independently. Wayring and all future I/O share this ring.

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
reusable `app.turn.Coordinator` defines and tests this ordering for headless
hosts. The production `app.runWayland` coordinator preserves the same explicit
phase boundaries while additionally managing dynamic per-window work and
Wayring shutdown. Neither coordinator contains protocol, renderer, task, or UI
implementations.

Tasks and heterogeneous resources register under application, window, or
widget scopes. Child scopes now have generation-checked parent links and
recursive cancellation; canceled scopes reject new tasks, resources, and child
scopes. The common registry stores generation-checked handles,
resource kind, owner scope, and cancel/destroy lifecycle hooks. This avoids an
application object with one array and teardown loop per subsystem. Context
pointers may live inside that private registry but are never kernel identities.

Semantic pointer handlers live in a language-neutral registry adjacent to the
instance tree, keyed by generation-checked instance handles and typed handler
kind plus opaque invocation ID. Render objects never own callbacks. The Lua
build bridge stages widget-specific `ouro.button { on_press = ... }` references
and commits them only after typed descriptor reconciliation; replacement,
rollback, removal, and window teardown
release references. Routing bubbles visual descendants to the nearest bound
instance. It spawns handlers only at the task safe point, so yielding handlers
retain structured scope.

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

- Wayring reserves low `user_data` bytes 1 through 5; Ourokit uses `0xa0`
  through `0xa2` for its timer alarm/update/remove namespace.
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
and translates pointer enter/leave, motion, buttons, scrolling, keyboard focus,
keys, and frame grouping into bounded typed application data. Raw Wayland
fixed-point values and protocol handles do not cross that boundary. The adapter
compiles compositor-provided keymaps with xkbcommon and retains raw keycode,
keysym, logical navigation key, modifiers, and Unicode scalar separately. Text
composition and committed text use Wayring's generated `text-input-v3`
bindings; raw key events do not masquerade as committed text. The adapter
creates one text-input object per seat but leaves it disabled until a retained
editable target explicitly owns focus. Borrowed protocol strings are copied
and `preedit_string`, `commit_string`, and `delete_surrounding_text` fragments
remain pending until `done` queues one owned platform batch. Application state
can consume that batch only at the input safe point. Enable/disable, surrounding
text, content purpose/hints, cursor rectangle, and commit serials remain behind
the platform adapter rather than leaking Wayring objects into UI code.

`wl_keyboard.repeat_info` drives client-side repeat through the shared logical
timer heap. Xkbcommon decides whether a physical key repeats and retranslates it
against current modifiers on each expiration. The timer CQE only queues a
`.repeated` platform event; retained input policy consumes it at the safe point.

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
The first constructor-specific decoders prove the intended seam. `ouro.row`
and `ouro.column` emit Flex descriptors, `ouro.scroll` emits a single-child
viewport descriptor with instance-retained offset, `ouro.label` emits Label, and
`ouro.button` emits Box plus Label descriptors and a typed widget binding.
A bounded nested build context derives native identity and parent links from
stable local keys, so applications never manage numeric IDs. These constructors
do not add a Button render object or duplicate theme defaults in Lua.

Layout uses one-way Flutter-style box constraints in logical `f32` units. A
parent passes minimum/maximum width and height, each child returns one finite
constrained size, and the parent assigns its offset. This is not a general
equation solver. Box, Flex, and Stack are the first typed render objects; flex
factors and stack positions live as parent data on child edges, while padding
and optional physical child alignment are Box policy rather than additional
wrapper objects. Alignment loosens the child's inner constraints and positions
its intrinsic result inside the resolved padded box; widget policy resolves
direction-sensitive start/end before this render-object layer. Flex performs
bounded passes and rejects flex children on an unbounded main axis.

The render tree uses fixed-capacity generation-checked slots and intrusive
ordered child links. Layout performs no allocation. Constraint results are
cached per node; layout-affecting changes propagate dirtiness to ancestors,
while paint-only changes do not trigger layout. Scene painting preserves child
order, and hit testing traverses that order front-to-back. This render-tree
identity remains distinct from the future instance tree's semantic/keyed
identity and component lifecycle.

Instance reconciliation compares retained topology in linear time before
touching edges, so an unchanged normalized snapshot leaves both layout and
paint clean. Reorders and typed parent-data changes rebuild topology while
retaining instance and render-object identities.

Per-window frame state is renderer- and platform-neutral. Layout invalidation
dominates paint invalidation, repeated requests coalesce, and a display list is
not eligible for submission while a newer mutation remains dirty. Scene and
submitted revisions separate building from backend acceptance. An unchanged
platform configure can request another submission of the current scene without
forcing reconciliation or layout. Wayland frame callbacks only throttle the
adapter; they do not create another event loop or directly enter UI code.

Task and platform state mark window owners in a fixed-capacity reconciliation
queue; they do not produce or decode widget snapshots immediately. Repeated
marks coalesce while retaining monotonically changing requested revisions. The
reconciliation phase alone takes work and builds normalized descriptors. A
mark arriving while work is in progress schedules the newer revision for a
later pass, and removed generation-checked owners cannot leave stale work.

Mounted build owners are component lifecycle nodes, not render objects. They
have keyed generation-checked identity, hierarchical resource scopes, direct
dirty revisions, and no drawing or layout state. Initial and state-driven
builds enter a bounded stabilization cycle; independent dirty siblings build in
one pass, while writes caused by a build queue a later pass. Exceeding the pass
limit is an error rather than an unbounded reactive loop. A build revision is
committed only after its normalized descriptor output reconciles successfully.
Recursive retirement removes queued builds immediately and defers scope
cancellation to the task safe point.

Lua signals use that owner boundary rather than introducing an effects runtime.
Lua retains each arbitrary signal value; native state stores only
generation-checked signal identity and bounded signal-to-build-owner edges.
Reads during a protected build collect a provisional dependency set, which
replaces the prior set only after descriptor reconciliation succeeds. Changed
writes mark subscribed owners and use a state-only sink to wake their owning
window queue; neither operation resumes Lua or builds inline. Writes from a
build transaction are rejected. Owner disposal removes subscriptions before
its stable registry address can be released. Effects and computed signals
remain deferred.

The instance layer now accepts a compact flat snapshot of typed descriptors.
Semantic IDs are stable within a window, parents precede children, and typed
parent data is validated before mutation. Preallocated open-addressed indices
make validation, keyed lookup, render-to-instance lookup, and reconciliation
linear rather than repeatedly scanning arbitrary Lua tables. Retained IDs keep
generation-checked instance/render identities and component-state revisions;
reordering only rebuilds intrusive render edges. Reparenting a retained ID is
currently rejected because its hierarchical ownership scope is immutable.

Every instance owns a child scope. Omission detaches its render object and
queues scope cancellation, but leaves a generation tombstone until the task
safe point drains resources and child scopes. Capacity therefore explicitly
accounts for retiring instances instead of freeing identity while completions
can still arrive.

Pointer translation remains state-only. During platform-event translation, a
per-window router hit-tests the last completed layout, maps render identity to
instance identity, synthesizes hover transitions, and appends targeted data to
a bounded O(1) ring queue. Motion overflow is transactional: neither hover
state nor a partial transition changes. No routing operation invokes Lua or a
widget callback.

Text discovery, shaping, line breaking, measurement, and positioned glyph-run
construction belong in `text`, above renderers. The first real slice embeds
HarfBuzz 14.3.1 without FreeType, GLib, or ICU integration and shapes an
explicitly itemized UTF-8 run. Native discovery separately links the system
Fontconfig package and its platform dependencies. The shaping contract requires
logical-order paragraph context, byte range, direction, ISO 15924 script, BCP
47 language, face, and logical size; it never asks HarfBuzz to guess bidi or
fallback. Output contains
paragraph-relative clusters, glyph IDs, advances, offsets, font metrics, and
unsafe-break flags in logical `f32` units.

The canonical design family is generic `sans-serif`. Native Linux builds enable
a focused Fontconfig discovery capability by default; minimal/headless and cross
builds may disable it. One application-owned database holds an explicit
configuration snapshot. Queries apply config and default substitutions, then
retain `FcFontSort`'s configured, coverage-trimmed order as owned face metadata:
family, file, complete face/named-instance index, variable status, variations,
and copied charset coverage. Fontconfig data does not cross into UI, scenes, or
renderers. Configuration replacement and cache invalidation occur only at an
application safe point.

uucode at pinned commit `61e54266895f833b307de81a0e3038cf1f1bebd4`
supplies Unicode 17 data and extended-grapheme iteration. Its documented
isolated-emoji-modifier tailoring is retained rather than represented as exact
default UAX #29 behavior. Grapheme boundaries are for cursoring/selection and
remain distinct from HarfBuzz clusters.

The pure `text.analyzeScripts` stage combines uucode's singular Script and
extended-grapheme data with content-hashed official Unicode 17
Script_Extensions and property-alias data. Deterministic generated lookup data
resolves Common, Inherited, script-specific shared characters, and enclosing
paired brackets without splitting grapheme clusters. Its owned logical runs
remain independently testable and benchmarkable.

Pinned SheenBidi 3.0.0 now supplies Unicode 17 UAX #9 paragraph boundaries,
embedding levels, isolates, and brackets. Its Apache-2.0
unity source is compiled with process-global scratch memory disabled. The pure
headless `text.analyzeBidi` stage returns owned, flattened paragraph data and is
independently unit-tested and benchmarked; it owns no fonts, UI, renderer,
platform, or Lua state.

`text.itemizeParagraphs` intersects logical bidi and script boundaries per
paragraph. It excludes paragraph separators from shaping runs and preserves
embedding levels for line-specific visual ordering. Each resulting run
can produce the paragraph-relative, explicit direction/script `RunSpec` already
consumed by HarfBuzz and fallback; language remains caller-owned.

This is not yet a complete paragraph layout engine. uucode does not implement
UAX #15 normalization. Ourokit adds Unicode 17's `Line_Break` property through
uucode's custom component interface, retaining its compressed generated table
machinery. The focused linear-time UAX #14 scanner passes all 19,338 official
revision-55 conformance cases and remains independent of fonts, UI, and
renderers. Shaping mixed text as one guessed run remains forbidden.

Unicode opportunity discovery is separate from wrap policy. The first sibling
selector is an O(n) greedy implementation over measured advances. Future
Knuth-Plass selection belongs beside it and will require an explicit
box/glue/penalty projection; it will not be faked through greedy heuristics or
forced into one universal node API. Both consume shared Unicode opportunities
and text-layer measurements.

Itemized runs are fallback-shaped with full paragraph context. A linear
measurement stage projects monotone HarfBuzz clusters onto Unicode
opportunities and retains unsafe-to-break boundaries as explicit reshaping
requirements. Only after greedy selection does SheenBidi apply UAX #9 L1-L2 to
each actual line, producing visual left-to-right level runs and resetting that
line's trailing whitespace. Final headless assembly intersects those visual
runs with itemized and fallback-font spans and emits backend-neutral positioned
glyph spans. Safe boundaries reuse the whole-paragraph shape result. Lines
touching unsafe boundaries are conservatively reshaped with full paragraph
context; a changed advance returns `error.ReflowRequired` so stale wrap choices
cannot reach a renderer. Renderers never perform this text policy.

Positioned paragraph output is owned by an application-scoped `ParagraphCache`.
Its width-specific immutable entries live behind generation-checked handles,
deduplicate complete layout requests, and retain their ordered fallback fonts.
The scene's paragraph command references one such handle; owned frames lease it
until rendering completes. Software, Vulkan compute, and Vulkan dma-buf
presentation consume the same already-positioned visual spans. The existing
single-run glyph command remains a deliberately narrower shape-cache ABI rather
than being stretched to represent wrapped mixed-direction lines.

Retained Labels hold a generation-checked `ParagraphSourceHandle` identifying
width-independent text/style/font inputs. Their render-tree slots own the
current width-specific `ParagraphHandle`; a text/style or constraint change
replaces that lease transactionally. Unchanged constraints return through the
normal layout cache before paragraph lookup, shaping, or allocation. Lua Labels
can therefore wrap mixed-direction text without moving text policy into Lua or
either renderer.
Empty-line metrics remain an open line-style policy rather than inheriting an
arbitrary fallback face by accident.
Fontconfig provides candidate order and a coverage prefilter, not a shaping
algorithm. The fallback planner first shapes the entire itemized run with each
cache-owned candidate.
If no face succeeds, it selects by actual HarfBuzz `.notdef` output at extended
grapheme boundaries, merges adjacent equal-face selections, and reshapes each
span with full paragraph context. This preserves combining/emoji sequences and
Arabic joining context across necessary face boundaries. Unresolved graphemes
remain visible through the primary face and are reported. Output retains only
generation-checked font handles, never allocated font pointers. Tests use pinned
Inter and Noto Sans Arabic fixtures to prove shaping independent of host fonts.
Both backends will consume the same positioned glyph sequence. Atlas storage,
hinting, and rasterization remain backend-owned.

The application-owned font cache never opens files or blocks. Ouro's I/O layer
supplies bytes for a Fontconfig face identity. Cache keys include file, complete
index, variations, and a caller-derived source revision so replacing a file does
not silently reuse stale font data. Faces live in growable stable-address slabs;
growth cannot move a HarfBuzz font while fallback probing holds a pointer.
Acquisition deduplicates loaded identities and increments a reference count.
Generation-checked handles resolve in O(1), final release destroys the face and
invalidates every stale copy, and cache teardown is the owning application
scope's destruction path. The current linear dedupe scan is deliberately on the
cold font-load path; it can gain an index only if measurements justify one.

Fallback-shaped itemized runs are immutable and application-cached separately
from faces. A collision-safe hash key includes complete paragraph bytes,
normalized byte range, direction, script, language, exact logical size, ordered
font handles, and the Fontconfig configuration revision. Entries occupy
growable stable-address slabs behind dedicated generation-checked shape handles.
They retain every candidate face until final release, so cached span font
identities cannot become stale when the requesting layout releases its own font
references. Font cache teardown follows shape-cache teardown. Refreshing the
Fontconfig snapshot and revision is future safe-point orchestration, not a
renderer concern.

Label owns no font or rasterizer state. It retains width-independent paragraph
source identity, derives positioned lines from one-way constraints, and emits a
paragraph command. Button is Box + Label composition with behavior in a
language-neutral widget registry, not another core render object. That registry
retains hover, pressed, disabled, and pointer-armed state across reconciliation.
Pointer capture ensures a release reaches the pressed target, while release-
inside decides activation. Design-generated semantic accent roles supply idle,
hovered, and pressed colors.

The `ui/text_input` boundary now contains a unit-testable editable value and a
retained input-method session, but not yet a widget or render object. The value
owns valid UTF-8, directional selection, revisions, and cached uucode
extended-grapheme boundaries. The session keeps preedit outside committed text,
applies delete/commit/preedit batches in protocol order, and exposes bounded
surrounding state through an app-owned platform translator. A separate retained
registry keys sessions and their content instances by generation-checked
identity and build-owner lifetime; Lua rebuilds cannot reset edited values, and
omission disposes composition state deterministically. Cursor movement at this
layer is named logical previous/next; visual left/right, caret geometry, and
selection painting wait for paragraph bidi/caret maps. The Wayring-backed
adapter remains disabled until an actual retained TextInput owns focus. Raw xkb
events are never application text.

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

Vulkan is enabled by default as an explicit build capability. Vulkan-capable
builds select it as the default runtime renderer while retaining an explicit
software selection. `-Dvulkan=false` uses the type-compatible disabled boundary
and neither compiles shaders nor discovers or links the Vulkan loader.

Native software text rendering optionally links system FreeType. Backend-owned
face entries retain FontCache handles and preserve face/named-instance identity
plus variable-axis assignments. Glyph masks are cached by font generation,
glyph ID, and device size, then blended through the same premultiplied path.
FreeType objects and mask storage do not cross into scene or UI types. Builds
without text rasterization use `-Dfreetype=false`; cross builds disable it by
default. Eviction and LCD/subpixel policy await benchmark evidence.

UI layout never sees pixel formats or stride. Scene construction lowers logical
rectangles using an explicit output scale into renderer-neutral device-space
commands. Conservative floor/ceil edge snapping is the current contract;
subpixel coverage remains open until software and Vulkan implementations can
share tested semantics.

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

The Vulkan peer will own instance/device/queue selection, command buffers,
exportable images and memory, synchronization, and pipeline/cache state.
Renderer-neutral resource IDs and caching will live below scene; widgets and
render objects never hold Vulkan handles.

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
matching remain prototype questions. No Vulkan placeholder pretends this path
has already been validated.

Headless development remains first-class: deterministic software buffers,
scene logging, Button interaction tests, and retained semantic snapshots exist
now. Semantic groups, labels, and Buttons validate parent ordering, identity,
required labels, capacity, and disabled state; double buffering keeps the prior
snapshot visible until a complete build commits. A larger design-system gallery
remains planned without requiring Wayland or Vulkan.

## Lua isolation

Lua 5.5.1 is fetched by exact URL/content hash. Ourokit compiles Lua core and
`lauxlib.c`, but none of the standard-library implementation files or `linit.c`.
It never calls `luaL_openlibs`. The only initial global is the Ouro-owned table
containing `sleep`; the proof test verifies `print`, `package`, and `coroutine`
are absent.

Mounted UI builds may install constructor-specific Ouro functions into that
same table. They append compact typed descriptors only while a build owner is
actively reconciling; calls outside that phase fail. Build callbacks execute
under protected, non-yielding calls, and their descriptor storage is bounded
and borrowed only until the next build. Applications use stable string keys and
constructor tables; numeric descriptor IDs, parent links, and renderer objects
are not exposed. A future schema generator may produce these constructors and
bindings without introducing generic string `type` dispatch.

`ouro.signal(initial)` is the first reactive primitive. Calling its userdata
reads the value and `signal:set(value)` changes it. Dependency tracking belongs
to the active mounted build owner and commits transactionally with that owner's
descriptors; raw-equal writes are suppressed.

The isolated VM owns growable stable-address slabs of generation-checked
coroutines. Growth occurs only during task creation; existing slots do not move
and resume/completion paths do not allocate.
Each Lua task maps directly to its language-neutral scheduler slot and pending
`io_uring` operation slot, and carries its application/window/widget scope.
`ouro.sleep` yields with `lua_yieldk`; its continuation runs only after the task
phase explicitly resumes that coroutine. A Zig frame is not retained across
the yield. Coroutines are explicitly anchored in the Lua registry and pass
through `lua_closethread` on completion, error, or cancellation before their
anchor is released. A future bundle loader will be pure Ouro functionality,
not Lua package `require`.

## First-milestone non-goals and open questions

Non-goals: complete widgets, complete paragraph layout/font discovery, command
palette, accessibility protocols, advanced Vulkan dma-buf negotiation, bundle
manifests/packing,
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
- language inheritance, optimal-wrap item representation, Fontconfig refresh
  orchestration, and exact default versus tailored grapheme behavior;
- transform, subpixel rasterization, layer, and color-managed surface semantics;
- Vulkan device-loss recovery and richer damage-region coalescing;
- scope close semantics for multiple asynchronous resource kinds;
- versioned application bundle and native-extension ABI.
