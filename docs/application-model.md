# Application model

`app` is a small coordinator, not an implementation home. It owns the process
lifetime and orders sibling loop/task/Lua/platform/UI/renderer modules. The
reusable turn coordinator fixes that order in one implementation. The retained
UI and Wayland example now exercise reconciliation, layout/scene construction,
and frame submission as distinct phases; the general `App` host hooks remain
the integration seam rather than absorbing those implementations.

## Declarative windows

Applications declare their desired window set rather than imperatively owning
Wayring objects. The first working application-facing surface is:

```lua
local ouro = require("ouro")

return ouro.app {
  id = "dev.ouro.example",
  actions = {
    ping = function() return "pong" end,
  },
  run = function(context)
    local clicked = ouro.signal(false)
    return { windows = {
      ouro.window {
        id = "main",
        title = "Example (" .. context.instance_id .. ")",
        width = 480,
        height = 320,
        min_width = 360,
        min_height = 240,
        content = function()
          ouro.row {
            key = "layout",
            cross_alignment = "stretch",
            children = function()
              ouro.box { key = "sidebar", width = 120, children = function() end }
              ouro.column {
                key = "content",
                flex = 1,
                children = function()
                  ouro.label { key = "title", text = "Example" }
                  ouro.button {
                    key = "run",
                    label = clicked() and "Clicked" or "Run",
                    on_press = function()
                      clicked:set(not clicked())
                    end,
                  }
                end,
              }
            end,
          }
        end,
      },
    } }
  end,
}
```

Application actions belong to the headless application service and do not call
`run` or initialize a native UI. A UI runtime invokes `run(context)` once for
each candidate source generation. Reload therefore prepares a fresh run and
atomically replaces the active run only after all returned windows validate.

The public surface is deliberately small and its cross-language descriptor ABI
remains unfrozen. Constructors are specific native decoders, not one generic
`{ type = "..." }` table parser. The native contract is explicit in
`app/windows.zig`:

- a complete declaration snapshot is validated before reconciliation;
- non-empty string IDs provide semantic identity across snapshots;
- generation-checked handles provide native identity within one process;
- each native window owns a child of the application resource scope;
- newly present IDs create, retained IDs update, and missing IDs begin close;
- native close/configure and typed pointer notifications enter a bounded data
  queue only;
- closed declarations remain suppressed until omitted, preventing accidental
  resurrection from stale Lua state;
- the platform owns Wayring objects and shared-memory buffers behind a native
  host boundary; declarations never contain protocol objects.

Mutable title and minimum dimensions are updated in place; initial dimensions
apply at creation. A zero minimum leaves that axis unconstrained. A future
layer-shell declaration will be a distinct type rather than a mode bit on an
interchangeable generic window.
The reusable `app.runWayland` host implements this contract and owns the loop,
scheduler, isolated VM, font/text caches, retained per-window UI, software
renderer, and Wayland adapter. The executable example only embeds a Lua source
file and selects one- or two-window declarations; application code owns no
native services or protocol objects.

Close requests do not invoke Lua during protocol dispatch or reconciliation.
They are translated to application input, may mark a Lua task runnable, and
are observed only in the task phase. A resulting declaration change is applied
in a later reconciliation phase. Window removal queues recursive cancellation
of its widget/task/resource scope at the next task safe point.

Pointer enter/leave, motion, buttons, axis source/deltas/stops, discrete wheel
steps, high-resolution 120-unit wheel steps, and protocol frame grouping follow
the same state-only path. Events carry generation-checked window identity and
logical coordinates, not Wayring objects or raw Wayland fixed-point values.

Normalized widget descriptors cross into instance construction; instances own
identity, lifecycle, state, focus, command contribution, and reconciliation. A
small closed render-object set (Box, Flex, Stack, Text, Image, Scroll,
TextInput, and Canvas only when their distinct behavior is demonstrated) owns
layout, paint, clip, and hit testing. Scenes are immutable backend-neutral
output.

The implemented headless render-tree kernel starts with Box, Flex, Stack, and a
constraint-aware Label backed by immutable paragraph source and layout handles.
It uses one-way minimum/maximum box constraints and logical `f32` geometry.
Parents position children after each child chooses a finite constrained size.
Flex factors and stack offsets are typed edge metadata, not wrapper nodes. The
fixed-capacity tree caches unchanged constraint results, allocates paragraph
work only when Label inputs or width change, separates paint-only from layout
invalidation, builds ordered display lists, and performs reverse-order hit
testing without Wayland or Lua.

Declarative rows and columns expose that edge metadata as a contextual
`flex = <positive integer>` child property. It is rejected anywhere except on
a direct row or column child. `cross_alignment = "start" | "center" | "end" |
"stretch"` controls the container's cross axis; flex children use tight fitting
and divide the remaining bounded main-axis space according to their factors.
Boxes may opt into generated theme surfaces with `surface = "background" |
"card" | "popover" | "sidebar"`; omitting it leaves the Box transparent.
`width` and `height` accept a non-negative number or `"fill"`; omitted values
remain intrinsic. Optional `min_width` and `min_height` participate in the same
one-way constraints and yield when a parent supplies a tighter maximum.

Above it, the implemented instance reconciler consumes parent-before-child
typed descriptor snapshots with stable numeric semantic IDs. It validates the
whole snapshot and capacity before mutation, preserves instance identity and
state revisions across updates/reordering, and uses preallocated hash indices
for linear reconciliation and constant-time identity lookup. Identical
snapshots compare retained child topology without detaching edges, leaving
layout and paint caches untouched. Each instance owns a hierarchical resource
scope. Removed instances become retiring tombstones and queue cancellation;
their identity is recycled only after a later task safe point drains their
scopes.

The language-neutral per-window frame state coalesces layout and paint
invalidation across turns. Layout must complete before scene construction, and
a dirty scene cannot be submitted. Scene revisions become submitted revisions
only after a backend accepts the frame. Repeated same-size Wayland configure
events may reuse an immutable display list without rerunning reconciliation or
layout, while the adapter's frame callback continues to throttle presentation.

A bounded reconciliation queue separates state invalidation from snapshot
production. Task or platform phases only mark a generation-checked window
owner dirty. Marks deduplicate without allocation, including while an older
revision is being reconciled. Only the reconciliation phase consumes work and
constructs typed descriptors; successful completion records the applied
revision, while failure can explicitly retain the work for retry. Window
removal unregisters the owner and removes queued stale work.

Mounted components now have a separate language-neutral build-owner registry.
A build owner has keyed identity, parent/child ownership, a component scope,
and requested/building/built revisions, but no render-object fields. New owners
queue an initial build; later invalidation targets the owner directly instead
of searching the retained tree. Stabilization is bounded by passes rather than
total component count, so many independent dirty components remain one pass
while state writes during builds schedule subsequent passes. Descriptor
reconciliation must succeed before the build revision commits. Retiring a
component recursively removes pending descendant work and queues its scope for
safe-point cancellation.

The initial signal primitive is deliberately narrower than a general reactive
runtime. Lua owns each signal value. A bounded native edge table associates
generation-checked signals with reads made by the currently building owner.
Dependencies remain provisional until normalized descriptor reconciliation
succeeds; rollback leaves the prior set intact. Changed writes only dirty
subscribed owners. A state-only build-owner sink queues the owning window unless
that window is already reconciling, where bounded local stabilization handles
the mark. Neither path enters Lua. Disposal removes subscriptions before owner
retirement. Computed signals and effects are not implemented yet.

The pointer router consumes the callback-free Wayland event data, hit-tests the
last completed render layout, and queues generation-checked instance targets.
Hover enter/leave transitions and motion/button/axis events use a bounded ring
queue. Queue overflow cannot partially change hover state. Application code
observes this data only from the task phase. The current proof resolves an
active target's instance-owned typed pointer binding, bubbling from a visual
descendant such as a Label to its owning widget instance and scope, then spawns
its registry-referenced Lua function as an independently yieldable coroutine task.
Bindings use generation-checked instance handles; stale targets are dropped.
The application-facing binding is constructor-specific, currently
`ouro.button { on_press = function() ... end }`; numeric instance IDs and the
compact pointer event ABI are not exposed. Build references commit only after
descriptor reconciliation succeeds; rollback, replacement, removal, and window
teardown release them.

Padding is Box layout policy rather than a wrapper render object. Theme, keyed
identity, focus, shortcuts, and stateful components are instance/widget policy,
not render-object variants. There will be no universal generic node and no
permanent arbitrary table parser based on repeated string `type` dispatch.

The eventual component schema should generate Lua constructors, compact Zig
bindings/decoding into this normalized snapshot, Lua language-server types,
documentation, and cross-language validation. The constructor-specific bridge
proves this route end to end: a protected non-yielding mounted Lua build emits
Box/Stack/Label descriptors directly into bounded native storage, which the
existing transactional reconciler validates. It has no generic string `type`
parser or application-facing descriptor escape hatch. The constructors maintain
a bounded native parent stack: `ouro.row` and `ouro.column` normalize to Flex,
`ouro.scroll` normalizes to a single-child Scroll viewport, `ouro.label`
normalizes to Label, and `ouro.button` normalizes to Box plus Label. The
single-selection `ouro.listbox` composes a vertical Flex with direct
`ouro.option` Box/Label children. It is one focus stop, uses integer values,
and calls `on_select(value)` for pointer selection and Up/Down/Home/End navigation;
the application remains the source of truth through the `selected` property.
Options are transparent over their containing surface at rest and retain hover
state across reconciliation. Default options use accent steps 3 and 5 for hover
and selection. `appearance = "sidebar"` instead uses gray steps 3 and 5 plus a
medium selected label for navigation catalogs without introducing a separate
widget.
Applications provide stable local keys but no numeric IDs or parent links.
Their visual defaults come from generated Radix-derived semantic tokens and
documented component recipes, with no Lua theme mirror. Buttons are
intrinsically sized with Radix Themes size-2 geometry: 32-pixel height,
12-pixel horizontal padding, 4-pixel radius, medium label face, primary color
pair, and one-line ellipsis. Text inputs fill their bounded parent width by
default and use the corresponding 32-pixel height, 8-pixel inset, 4-pixel
radius, surface, and input-border roles; focus replaces that border color with
`ring` rather than adding an outline. The Wayland example exercises this actual
Lua-build path for both windows. Both mounted
window owners also read one shared signal, proving dependency identity across
separate per-window registries sharing one VM.

For the benchmark slice, `ouro.button` owns composition and input policy while
emitting only Box and Label render objects. Button is not a render object. Its
stable string key is normalized into domain-separated semantic IDs; duplicate
or colliding IDs are rejected by snapshot validation rather than silently
aliasing instances. A language-neutral widget registry retains enabled,
hovered, pressed, and armed state across reconciliation. Enabled Buttons
activate on left-button press; release clears the pressed visual regardless of
the pointer's current position. CQE and Wayland
dispatch still only enqueue state; callbacks spawn Lua tasks during the task
phase. Labels pass valid UTF-8 through paragraph itemization, bidi, fallback
shaping, and width-dependent wrapping.

Instances also retain focusability and deterministic descriptor traversal
order. A window-local focus manager holds only a generation-checked instance
handle. Tab and Shift-Tab move through enabled controls with wrapping during the
input safe point, pointer presses request focus through the same policy, and
Controls currently add no visual focus outline. Text input focus changes its
existing one-pixel border to the generated focus color without affecting layout,
and remains visible through its caret. Enter and Space activate on key press and
enqueue the existing Button callback task;
Wayland dispatch never calls Lua directly.

Editable text begins at a separate, platform-neutral model boundary. It owns
UTF-8 bytes, a directional anchor/extent selection, revisioning, and cached
indexes of Unicode extended-grapheme and default word boundaries. Replacement,
selection, and movement therefore cannot split combining sequences, emoji ZWJ
sequences, or regional-indicator pairs. Word movement and deletion use the
Unicode 17 UAX #29 table rather than ASCII classes. Neutral editing intents keep
platform key translation separate from model operations, while paragraph caret
maps own visual bidi and vertical geometry. The model has no Lua, Wayland,
renderer, shaping-cache, or IME ownership.

Select-all is a local editing intent. The app clipboard coordinator represents
paste as a scheduler-owned asynchronous resource and queues data-only platform
actions. Its completion owns validated UTF-8 and retains the original
generation-checked text-input target, which the input safe point validates
again before editing. Scope cancellation queues platform cancellation without
delivering racing data to disposed targets. Ctrl+V consumes Wayring selection
offers through incrementally read `io_uring` pipes; unavailable, oversized, or
invalid UTF-8 input is a no-op. Ctrl+C and Ctrl+X copy the normalized selection
into an owned effect before returning from the input phase; only then may cut
delete it. The Wayland adapter owns each resulting `wl_data_source` and serves
UTF-8/plain-text send requests with short-write-aware `io_uring` operations.
Wayland offer/source pipe I/O never runs in a blocking protocol callback or an
in-process clipboard substitute.

Primary-button text selection stores its bidi-aware anchor in the retained edit
session. The input router keeps delivering motion to the captured instance even
when hover moves over another instance or leaves the window; paragraph hit
testing clamps that motion to a valid line and caret. Release clears the gesture
without changing the selected anchor/extent. Gesture state never enters the
render object or scene.

Commands live in an authoritative registry independent of the retained render
tree. Entries need stable semantic IDs plus revisioned invocation handles,
scope, title/category/aliases, enabled state and reason, state, argument schema,
shortcut, and destructive/reversible metadata. Contextual widget commands may
register there, but external enumeration never walks render objects.

Headless retained layout, software glyph rendering, deterministic scene
logging, Button interaction state tests, and semantic snapshots are available
now. The semantic snapshot is a validated, allocation-free-after-init retained
tree of groups, labels, and Buttons. Lua text is copied into an inactive buffer
before another Lua API call can collect it, and the buffer becomes visible only
when the surrounding build transaction commits. A future design-system gallery
will expand this path without requiring Wayland or Vulkan.
