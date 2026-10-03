# Application model

Write an application in Lua and launch it with `ouroctl run`. The host owns the
event loop, native windows, rendering, and task lifetimes. Application code owns
state, composition, and behavior; it does not need renderer or protocol handles.
Use `--dev` for an isolated development instance. Neither an action catalog nor
a production MCP server is required to build or inspect its UI.

## Declarative surfaces

Applications declare their desired window set rather than imperatively owning
Wayring objects. `run(context)` is the UI entry point:

```lua
local ouro = require("ouro")

return ouro.app {
  id = "dev.ouro.example",
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
          return ouro.row {
            key = "layout",
            cross_alignment = "stretch",
            children = {
              ouro.box { key = "sidebar", width = 120, children = {} },
              ouro.column {
                key = "content",
                flex = 1,
                children = {
                  ouro.text { key = "title", text = "Example" },
                  ouro.button {
                    key = "run",
                    label = clicked() and "Clicked" or "Run",
                    on_press = function()
                      clicked:set(not clicked())
                    end,
                  },
                },
              },
            },
          }
        end,
      },
    } }
  end,
}
```

`run` returns `{ windows = ... }`; `windows` does not belong on `ouro.app` itself.
This keeps UI creation under the same lifecycle for direct launch, deferred
desktop activation, and source reload. A deliberately headless application may
omit `run`; it cannot subsequently open a UI. Actions remain optional and do not
select when `run` executes.

`run` may also return a reactive window declaration function:

```lua
local launcher_open = ouro.signal(false)
-- An action or input callback calls launcher_open:set(not launcher_open()).
-- Inside run, after creating the persistent panel declaration:
return { windows = function()
  local windows = { panel }
  if launcher_open() then
    windows[#windows + 1] = ouro.layer_surface {
      id = "launcher", namespace = "launcher", layer = "overlay",
      width = 640, height = 480, keyboard_interactivity = "exclusive",
      content = launcher_content,
    }
  end
  return windows
end }
```

Signal reads in `windows()` use the same dependency graph as widget builds.
The function is non-yielding and must not write signals or perform effects;
create state in `run` or application initialization. New IDs mount native
surfaces, omitted IDs retire them, and retained IDs preserve their widget
runtime. Reopening a removed ID mounts fresh widgets after teardown drains.
An empty reactive list keeps the application alive for later state changes.
An optional `on_close_request=function() ... end` on a window intercepts a
compositor close request. The callback runs in that window's task scope; omit
the window from the reactive declaration to close it after confirmation.
Without the callback, close requests retain their usual automatic behavior.
Process exit/shutdown does not wait for close confirmation. The
[document example](documents.md) demonstrates save/discard/cancel and explicitly
exits after the last document closes.
Retained windows with the same `content` function do not rerender content just
because `windows()` reruns or a title changes. Each content function tracks its
own signal reads; replacing that function invalidates only its window. Store
stable content functions outside `windows()` when their identity should survive
declaration updates. Geometry and host appearance changes still invalidate the
affected window as needed.
Evaluation and parsing failures retain the last valid list. `outputs = "all"` still
expands to stable per-output IDs. Source reload retains matching IDs and their
widget identity, retires removed IDs, and prepares added IDs before committing.
Preparing additions needs temporary window-slot headroom while removed windows
remain live; exceeding it rejects the candidate without replacing the last-good
UI. See [source reload](hot-reload.md) for validation and commit boundaries.

Widget constructors take one props table and return an opaque description;
calling a constructor does not emit UI. A window, layer surface, or story's
`content` function must return one root description, or nil for empty content.
Helper functions used to render UI follow the same return contract. Multiple
widgets need a structural parent such as a row or column, not a list of roots.

Containers accept either ordered array entries in their props table or an
explicit dense `children = { ... }` table, but not both. Children are descriptions,
never a function that emits widgets. For example, the array-entry form is:

```lua
return ouro.column {
  key = "content",
  ouro.text { key = "title", text = "Example" },
  ouro.button { key = "run", label = "Run", on_press = function() end },
}
```

Build dynamic child lists in a local table, append descriptions in order, and
pass that table as `children`. Keep explicit stable keys on each widget.
Event handlers such as `on_press` and `on_select` remain callbacks.

**Choose stateless by default; use stateful for per-instance state.**

Both constructors define reusable components, following the state-ownership
distinction of Flutter's `StatelessWidget` and `StatefulWidget`:

| Constructor | Use when | Function returns |
| --- | --- | --- |
| `ouro.stateless(render)` | UI is derived from props, children, inherited theme, or externally owned signals | A description or nil |
| `ouro.stateful(initialize)` | Each mounted instance needs its own persistent state or setup | A render function that returns a description or nil |

Stateless does not mean static or noninteractive. A stateless component can
read existing signals and pass callbacks to controls; it just does not create
its own persistent Lua state. Ordinary Lua helpers can also return descriptions,
but `ouro.stateless` waits until the inherited theme is known before rendering.

For example, a Card only arranges its inputs:

```lua
local Card = ouro.stateless(function(props, children, theme)
  return ouro.box {
    key = props.key,
    padding = 16,
    background = theme.colors.card,
    children = children,
  }
end)
```

Use `ouro.stateful` for a Counter that owns a separate count per instance:

```lua
local Counter = ouro.stateful(function(props)
  -- Initialize once for each mounted instance.
  local count = ouro.signal(props.initial or 0)
  local function increment()
    count:set(count() + 1)
  end

  -- Rebuild the description when its inputs change.
  return function()
    return ouro.column {
      key = "counter",
      gap = 12,
      ouro.text { key = "value", text = props.title .. ": " .. count() },
      ouro.button { key = "increment", label = "Increment", on_press = increment },
    }
  end
end)

-- Inside a window or story's content function:
return ouro.row {
  key = "counters",
  gap = 24,
  Counter { key = "first", title = "First", initial = 0 },
  Counter { key = "second", title = "Second", initial = 100 },
}
```

Calling `Counter { ... }` creates a description, not a mounted instance. The
outer initializer runs when reconciliation mounts that component. Its returned
function rebuilds UI descriptions; keep it free of side effects, signal writes,
and yielding operations. Keep state creation outside the rebuild function.
Define component constructors outside rebuild functions too, so their definition
identity remains stable. Initialization is provisional until the build commits;
a failed build can discard it and retry. Initializers must also avoid external
side effects, signal writes, and yielding operations.

Props are read through the stable, read-only `props` userdata captured by the
initializer. Read changing props inside the rebuild function or event handler;
copying a scalar such as `local title = props.title` during initialization
captures only its initial value. An `initial` prop is an ordinary application
convention, not a special property that resets state on later parent updates.
Prop comparisons are shallow: replace a table-valued prop when its contents
change rather than mutating it in place. Nested tables, including
`props.children`, are not frozen; treat them as read-only too.

Keys identify component instances within their parent. Reordering the same
keyed component preserves its state. Removing it unmounts it; showing it again
initializes a new instance. Replacing a component definition at the same key
also creates a new instance. Rebuilding descriptions does not recreate retained
native widgets whose identities remain unchanged. A mounted component returning
nil hides its UI without unmounting the component itself.

Signal dependencies belong to the component render that reads them. A changed
signal schedules its owning window, but only affected Lua renders execute;
clean components reuse their retained descriptions. When the enclosing build,
inherited context, and descendant dependencies are also unchanged, native
lowering retains the component's existing subtree in place. It does not emit
another descriptor snapshot of that subtree. Native handles, callbacks, editor
state, and semantic descendants survive this skip. Dirty descendants prevent an
ancestor skip and are visited through its retained description.

These are build boundaries, not layout or paint boundaries: native layout still
responds to changed constraints, and interaction paint still updates normally.
The window retains one transactional commit and rollback. Native-sampled output
(animations, virtual lists, images, canvases, and scroll declarations) continues
to lower; builds requiring layout-builder measurement use complete descriptors.

Children supplied to a stateful component are available as `props.children`.
Stateless components receive children as their second render argument, as in
the Card example above.

**Theme-aware stateless composition and activation.**

`ouro.stateless(function(props, children, theme) ... end)` defines a stateless
description constructor. Its render function runs during native lowering, at
the same non-yielding safe point as component rendering, and returns a description
or nil. `theme` is a fresh value of the effective inherited native theme:
`colors`, `typography`, `controls`, `widgets`, and `reduced_motion`, including host appearance,
application defaults, and enclosing overrides. It is not `ouro.tokens.light`.
Changing this value does not change native defaults. Treat props and children
as read-only snapshots. Do not create state, write signals, perform effects, or
yield inside the render function; create state outside and pass its values in
props, or read existing signals. Composition signal dependencies are replaced
transactionally when lowered, independently of component render dependencies.
Each mounted component owns its composition reads; skipping its native subtree
preserves those reads, including dependencies of nested components.

Unlike `ouro.stateful`, a stateless component creates no mounted state,
semantic namespace, or layout wrapper. Forward `props.key` to the returned root to preserve keyed
native identity across rebuilds and source reload. Every full lowering expands
it again. A clean enclosing native boundary may skip expansion, but a changed
inherited theme or composition dependency prevents that skip. Hover, pressed, and keyboard-focus paint
updates do not lower descriptions or run composition functions.

Buttons, checkboxes, switches, separators, options, radios, tabs, selection
groups, dialogs, sliders, and split views are stock Lua compositions over box,
text, and layout primitives. Applications have the same primitive boundary:

```lua
local Action = ouro.stateless(function(props, children, theme)
  return ouro.box {
    key=props.key, activate=true, role='button', label=props.label,
    enabled=props.enabled, on_press=props.on_press,
    padding_x=12, padding_y=6, radius=theme.controls.radius or 4,
    background=theme.colors.accent,
    states={hover=theme.colors.accent_hover,
            pressed=theme.colors.accent_selected,
            disabled=theme.colors.disabled, focus=theme.colors.ring},
    content_theme={colors={foreground=theme.colors.accent_text}},
    ouro.row {key='content', children=children},
  }
end)
```

`box.activate=true` opts into native primary-button capture, press activation,
Space/Enter activation, repeat suppression, focus traversal, and cancellation.
`enabled=false` blocks activation and focus and cancels an armed press.
`focus_request`, `on_cancel`, and `on_interaction_change` use the existing control
contracts. Supply either `on_press()` or `on_change(not checked)`, not both;
`checked` remains application-controlled. Box roles are `group` (default),
`button`, `checkbox`, `switch`, `separator`, and `dialog`. Only `dialog` adds
input policy by role alone: it establishes a native modal boundary, as described
under [in-window modal dialogs](#in-window-modal-dialogs).
`label`, `checked`, and `enabled` are copied to the semantic snapshot.

Any box or text under an interaction owner can declare `states`, independently
of the owner's visual structure. It binds to the nearest activation, range, or
selection ancestor, or itself when `activate=true`, `range`, or `option` is set.
Colors change a box's background or text's foreground. For activation and
ranges, precedence is disabled, pressed, hover, then the ordinary color.
Missing pressed falls back to hover; other missing states use the ordinary
color. Box-only `focus` recolors an existing border for keyboard-visible focus,
or draws a 2-pixel inset outline when borderless. These properties change paint
only. Omit `states` for chrome that never changes with interaction.

**Selection groups.** Rows and columns can opt into native selection policy:

```lua
ouro.row {
  key='choices', selection='radio_group', selected=choice(),
  on_select=function(value) choice:set(value) end,
  main_axis_size='min', gap=12, cross_alignment='center',
  ouro.box {key='first', option=17, label='First', width=80, height=40},
  ouro.box {key='second', option=29, label='Second', width=140, height=64},
}
```

`selection` is `listbox`, `radio_group`, or `tab_list`. It supplies the semantic
role and native input policy without adding a wrapper. `selected` must be an
integer and `on_select(value)` must be a function. `enabled`, `focus_request`,
`label`, `on_activate(value)`, and `on_cancel()` keep the stock group contracts;
`semantic=false` is not allowed. `appearance='default' | 'sidebar'` is passed
to item recipes through `context.selection`; it does not choose group layout.

Layout and keyboard policy are independent: listbox arrows remain vertical,
tab-list arrows horizontal, and radio-group arrows work on both axes. Rows and
columns accept `main_axis_size='min' | 'max'` (default `min`) and normal child
`flex` factors, including when selection is enabled. `max` uses the available
bounded main-axis extent; `min` uses the children's extent. The stock
`listbox`, `radio_group`, and `tab_bar` constructors are Lua recipes that choose
their usual axis, spacing, stretch alignment, and `main_axis_size='max'`.

**Selection items.** `ouro.box {key='entry', option=17, label='Entry', ...}`
registers custom content as a direct child of a selection-enabled row or column,
including the stock groups. Values must be unique integers. The native group supplies role,
selected/checked state, enabled state, focus, and keyboard policy; the item
must not override `activate`, `role`, `checked`, or `enabled`, or disable its
semantics. Nested activation controls remain independent, as with tab close
buttons. Decorative rows, columns, and stacks may use `semantic=false` to keep
child semantic paths directly under the item.

Selection paint supports `selected` and `hover`, with selected taking precedence;
missing colors fall back to the ordinary color. `pressed` and `disabled` paint
belong to activation and range owners only. The group draws an inset focus
outline around its selected item; descendants may also declare `focus` paint.

Stateless render functions receive an optional fourth argument, `context`.
When directly under a selection group, `context.selection` contains `role`
(`listbox`, `radio_group`, or `tab_list`), `selected`, `enabled`, and `appearance`.
These are the group's declared values at lowering, not a subscription to native
hover or selection changes. Use `states` for native repaint without rebuilding.
Listboxes can retain a new selection without a Lua rebuild; radio groups and
tab bars remain controlled and only change selection when the application
updates their declared value.

`content_theme` applies native theme inheritance to a box's descendants without
adding a layout node. A box's explicit `foreground` then sets the descendant
foreground and clears the text-widget foreground override, so nested themes
and explicit text colors can override it. Box padding resolves per edge: explicit
`padding_left/right/top/bottom` overrides `padding_x`/`padding_y`, which override
`padding` (default zero). Edge values must be finite, non-negative numbers;
an explicit zero overrides a broader inset. Box alignment accepts all nine
positions: `top_left`, `top`, `top_right`, `left`, `center`, `right`,
`bottom_left`, `bottom`, `bottom_right`. Left/right remain vertically centered;
top/bottom are horizontally centered. Positions are physical, not text-direction
dependent. Box alignment loosens child constraints and places the child inside the
padding and border; omitting it preserves the existing constraint propagation.
Text paragraph alignment instead accepts `start`, `center`, `end`, or `justify`;
`start` and `end` follow the paragraph direction, not physical left/right.
`text.weight` accepts `normal` or `medium`, using the
host's matching font candidates. Decorative boxes/text may set `semantic=false`;
empty text is omitted from semantics automatically while retaining its layout
and native identity. Decorative descendants keep the nearest semantic parent.
Activation owners must remain semantic. Text editing, IME, selection, sliders, and other specialized
native policies are unchanged by this composition boundary.

Desktop components use a distinct layer-shell declaration rather than a mode
bit on `ouro.window`. Layer-surface content fills the configured rectangle
without the default window inset; add padding explicitly inside the content:

```lua
ouro.layer_surface {
  id = "panel",
  namespace = "ouro-shell",
  output = "DP-1", -- optional wl_output name; omit for compositor selection
  layer = "top", -- background, bottom, top, or overlay
  width = 0,
  height = 32,
  anchors = { "top", "left", "right" },
  exclusive_zone = 32,
  exclusive_edge = "top", -- optional v5 disambiguation: top, bottom, left, or right
  margins = { top = 0, right = 0, bottom = 0, left = 0 },
  keyboard_interactivity = "none", -- none, exclusive, or on_demand
  background = "#111820B8", -- optional #RRGGBB or #RRGGBBAA
  background_effect = "blur", -- optional compositor backdrop blur
  content = function()
    return ouro.text { key = "clock", text = "12:00" }
  end,
}
```

A zero width requires both left and right anchors; a zero height requires both
top and bottom anchors. In those cases the compositor chooses that dimension.
An exclusive edge must also be one of the anchors. It is optional when the
compositor can infer the edge, but disambiguates corner-anchored exclusive zones
with version 5 of `wlr-layer-shell`. Because the protocol has no request to
unset an explicit edge, remove and recreate the declaration to return to
automatic inference.

Set `output` to the name advertised by `wl_output.name` to place a surface on a
specific active output. Ourokit logs discovered output names. Declare one layer
surface with a unique ID for each output that should host a panel, wallpaper, or
other component. If a named output is absent, its declaration waits without
affecting surfaces on other outputs. Removing an output tears down its native
surface; if an output with the same name returns, Ourokit recreates the surface
while preserving its declarative identity and UI runtime. Wayland guarantees
these names are unique for one compositor instance, but not persistent across
sessions, so application configuration may need to follow compositor naming.
Omit `output` to retain compositor-selected placement.

For a panel on every output, use `outputs = "all"` instead of `output`. The
native runner creates an independent window/UI instance for each discovered
output and calls `content(output_name)` for that instance. New outputs are
added automatically; disconnected outputs retain their identities for
reconnection and source reload. The clock or other application-level state can
still be shared across all content callbacks. Each materialized surface counts
toward the application's window capacity (16 by default, including retained
disconnected names). `output` and `outputs` cannot be specified together.

```lua
ouro.layer_surface {
  id = "panel", namespace = "shell-panel", outputs = "all",
  layer = "top", height = 40, anchors = { "top", "left", "right" },
  exclusive_zone = 40,
  content = function(output_name)
    return ouro.text { key = "output", text = output_name }
  end,
}
```

`background` replaces the implicit root background across the entire native
surface. Alpha is preserved: the tint is painted once over a transparent clear,
not over an opaque theme background. It does not change widget theme colors;
opaque content can still cover it. Omit it (or set it to `nil`) for the existing
theme background behavior. Both `#RRGGBB` and `#RRGGBBAA` use the same color
validation as theme colors.

`background_effect = "blur"` requests real compositor backdrop blur over the
whole surface using `ext-background-effect-v1`. Blur strength and algorithm are
compositor policy; there is no radius property. If the protocol or blur
capability is unavailable, the specified background still renders normally.
Omit it (or set it to `nil`) to remove the effect. The blur region follows native
resizes and output scaling. Closing/reopening or reconnecting an output creates
a fresh effect object, and capability changes are handled without changing the
tint.

`input_region = { x = 0, y = 0, width = 420, height = 72 }` restricts pointer
and touch input to one rectangle in **surface-local logical coordinates**,
independent of output scale or renderer. The compositor delivers input outside
it to surfaces underneath, including through transparent padding. Omit it (or
set it to `nil`) to accept input over the entire surface, the existing default.
Set `input_region = {}` to make the entire surface click-through. Each omitted
rectangle field defaults to zero; either zero dimension makes the region empty.
Fields must be integers, dimensions must be non-negative, and coordinates,
dimensions, and right/bottom edges must fit signed 32-bit values. Negative
origins are allowed; the compositor clips the rectangle to the surface.

For example, a 420×160 notification surface with a known 72-unit card height
can leave the area below the card click-through:

```lua
ouro.layer_surface {
  id = "notification", namespace = "shell-notification", layer = "overlay",
  width = 420, height = 160,
  background = "#00000000",
  input_region = { width = 420, height = 72 },
  content = function()
    return ouro.button { key = "card", label = "New message", width = 420, height = 72 }
  end,
}
```

This is an explicit input policy, not alpha-based hit testing: transparent pixels
inside the rectangle still accept input, and visible pixels outside it do not.
It does not change painting, layout, or keyboard interactivity. For auto-sized
content, the application must supply and update the input bounds; Ourokit does
not infer them from the widget tree. Reactive window declarations and source
reload can change or remove the region without recreating the surface, and it
is reapplied after output reconnection.

Namespace, output, and surface role are immutable for a retained ID, while
size, layer, anchors, exclusive zone and edge, margins, keyboard interactivity,
background, background effect, and input region update transactionally, including
on source reload. Invalid color/effect/region values reject the new declaration.

## User-initiated anchored popups

Call `ouro.popup` synchronously in a button's `on_press`, before yielding. It
uses that button's current layout rectangle, parent surface, and triggering
input serial; callers cannot supply an old serial or arbitrary parent.

```lua
on_press = function()
  local menu, err = ouro.popup {
    width = 240, height = 74,
    content = function()
      return ouro.button {
        label = "Open settings",
        on_press = function() open_settings() end,
      }
    end,
    on_close = function() menu_open:set(false) end,
  }
  if menu then menu_open:set(true) end
end
```

Dimensions are integer logical pixels from 1 through 16384. The reactive
content renders in a separate native `xdg_popup`, below and right-aligned to
the button. The compositor may flip or slide it on either axis, without
resizing the parent. Only one popup may be open; nesting is not supported.
Failure returns `nil, { name = ..., message = ... }`.

`transparent=true` removes the native root's background for custom fades or
shaped content; it defaults to false for grabbing popups. This does not change
the rectangular input region or grab policy. Passive popups always have a
transparent root.

The first enabled focusable item receives logical focus. Escape, outside
click, compositor dismissal, `menu:close()`, opener disposal, or parent teardown
closes the menu. `close()` is idempotent and legal during render: it requests
closure, and `on_close` runs at the next task safe point. Focus returns to the
opener before dismissal notification. An unmounted opener cancels its scoped
tasks, including `on_close`; applications should not depend on that callback
running after disposal. Selected action tasks belong to the opener, so merely
dismissing the popup does not cancel a pending activation-token request.

A layer parent with keyboard policy `none` is temporarily promoted to
`exclusive` only for this explicit user action, then restored to its declared
policy. Unlike `on_demand`, this requests immediate keyboard focus for an
already-mapped top/overlay banner. Incoming banners never request keyboard
focus. Compositors can keep
physical keyboard focus on the parent; Ourokit routes its keys to the grabbed
popup and preserves the physical source for activation. Keyboard opening uses
the actual keyboard serial, never a previous pointer serial. Compositors that
only accept pointer serials for popup grabs cannot support keyboard opening;
use an Ouro build with keyboard-initiated popup-grab support.

### Animated menus and selects

`ouro.menu_button` combines a button trigger with a grabbing native popup:

```lua
ouro.menu_button {
  key='actions', label='Workspace actions', popup_width=240, popup_height=80,
  content=function(close)
    return ouro.column {key='items', cross_alignment='stretch',
      ouro.button {key='save', label='Save', variant='ghost',
        on_press=function() close(); save_workspace() end},
      ouro.button {key='settings', label='Settings', variant='ghost',
        on_press=function() close(); open_settings() end}}
  end,
}
```

`content(close)` is a render callback; invoke `close` from an item action, not
while constructing the content. `popup_width`/`popup_height` default to 240×200
integer logical pixels. Button options include `label`, `variant`, `tone`,
`width`, `height`, `flex`, `enabled`, `focus_request`, and custom children.
Optional `on_error(error)` handles opening failures. Disabling or removing the
trigger closes its popup. Content uses ordinary button Tab traversal; this is
not a menu-item role, roving-arrow menu, or nested-menu implementation.

Menus and `ouro.select` share a 120ms ease-out entry fade and scale from 0.98 to
1. `duration` overrides the nonnegative integer milliseconds; `motion` accepts
`'auto'` (default), `'reduce'`, or `'full'`. Auto captures the opener's effective
reduced-motion preference at opening, including desktop and enclosing-theme
policy. Reduced motion starts at the endpoint with no animation wakeups.
Popup colors also inherit the opener's effective theme. The scale origin is
the nominal top-right anchor; it does not track compositor flips or slides.
Dismissal is immediate, including during entry, so animation never prolongs a
grab. Selection preview, commit/cancel, and focus restoration are unchanged.

### Tooltips outside the parent window

Wrap exactly one trigger child with `ouro.tooltip`. It uses a **non-grabbing
native `xdg_popup`**, so a tooltip on a narrow layer-shell bar can extend beyond
the bar without resizing it or taking keyboard focus from another application.
The popup has an empty input region: clicks go through it. Tooltips work with
ordinary windows and layer surfaces, not lock surfaces or nested popups.

```lua
ouro.tooltip {
  key = 'network-tip', text = 'Connected to the studio network',
  width = 260, side = 'bottom',
  ouro.button {key = 'network', label = 'Network', on_press = open_network},
}
```

Hover or keyboard focus within the child starts a cancellable opening delay.
Leaving both states, disabling/removing the tooltip, moving its anchor, or
closing the parent dismisses it. A pointer press on the trigger or Escape
also dismisses it without consuming the event. A keyboard-inactive bar does
not receive Escape from the independently focused application. Moving between
descendants does not restart the timer. Opening a select or menu replaces a
tooltip; an already-open grabbing menu takes priority.

Options are `text` (required nonempty string), `enabled` (default true),
`delay` (integer milliseconds, 0–60000; default 500), `width`/`height`
(integer logical pixels, 1–16384; default height 40), `gap` (0–1024; default 6),
and `side` (`top`, `bottom`, `left`, `right`; default `bottom`). Side is a
preference: the compositor can flip or slide the surface at screen edges.
Without an explicit `width`, the native surface fits its shaped text with 8px
horizontal padding and a 1px border on each side, rounded up to whole logical
pixels and capped at 240px. Measurement happens before native creation. The
surface resizes in place when the label changes; explicit widths remain fixed.
Text is single-line and ellipsizes at the available width. On xdg-shell versions
older than 3, a required resize dismisses the tooltip instead; the next hover
uses the new measured size. Keep the child's accessible label meaningful rather
than relying on the tooltip for essential information.

An enter fade defaults to 120ms; `duration` and `motion = 'auto' | 'reduce' |
'full'` use the existing animation policy. Auto inherits the trigger's effective
reduced-motion preference when opening. Dismissal is immediate. Colors inherit
the trigger's theme: `popover`, `popover_foreground`, and `border`, so light mode
uses a light tooltip and dark mode uses a dark tooltip. Optional
`on_error(error)` receives popup-creation or resize failures.
See `examples/tooltip-bar.lua` for a 36px bar, including a tooltip around a select.

`ouro.measure_text {text=..., size=..., max_width=..., max_lines=..., overflow=...}`
returns `{width, height}` in logical pixels during a UI build. It uses the same
shaping, fallback fonts, inherited typography, and optional `weight`/`spans` as
`ouro.text`. The default maximum width is 16384; line count and overflow defaults
match `ouro.text`. `popup:resize {width=..., height=...}` queues new positive
integer dimensions, retaining the popup's anchor, side, gap, and input policy.
It returns `true` or `nil, error`, including `PopupResizeUnsupported` on xdg-shell
versions older than 3. The host applies the compositor-confirmed dimensions only
after the subsequent configure handshake.

For custom passive content, `on_interaction_change(active, anchor)` supplies an
opaque anchor when the active target has visible bounds. Pass it as
`ouro.popup {anchor=anchor, width=..., height=..., side='bottom', gap=6,
content=function() ... end}`; unlike menus this may follow a delay. The runtime
rechecks the target's lifetime, current interaction state, and bounds before
opening and while visible. A caller cannot forge a parent or reuse a removed
target. Omitting `anchor` retains the synchronous, input-authorized menu
contract above. Passive content should be noninteractive; its surface receives
neither pointer nor keyboard input. Its root is transparent.

This does not change `ouro.anchored` or `ouro.dialog`: those remain in-window
compositions, not native popup surfaces.

## Application lifetime and UI activation

An application can run without windows. Its entry module declares shared state,
the optional MCP tools and action handlers. `run(context)` initializes
the UI only when requested. Actions and window callbacks share the same Lua VM
and closures; invoking a method never implicitly initializes Wayland.

Declaring `actions` does not start a server or select single-instance policy.
`ouroctl run --mcp` explicitly enables an optional production actions endpoint;
`--dev` instead creates a private development endpoint with live runtime tools,
even when `actions` is absent. Each action has a description, `inputSchema`, `outputSchema`, and
handler. The table key is the exact tool name; `runtime.` names are reserved.
Use `tools/call` with `{name, arguments}`. There is no `interface` field, IDL,
qualified-method alias, initialization handshake, or old wire protocol.

Schemas are validated before a candidate generation can commit. The supported
JSON Schema subset is deliberately closed: `type` (one type or an array of
types), `properties`, `required`, `additionalProperties` (boolean or schema),
`items`, `enum`, `anyOf`, `title`, `description`, and boolean schemas. Types are
`object`, `array`, `string`, `number`, `integer`, `boolean`, and `null`. Input and
output roots must declare `type = "object"`. Unknown keywords, including `$ref`,
`format`, numeric bounds, and string patterns, reject the declaration rather
than being silently ignored. Nesting is bounded to 64 levels. Numeric validation
compares decimal lexemes exactly; integers include `1.0` and `1e0`, but not a
fraction rounded by floating point. Numeric exponent/normalized scale values
outside signed 64-bit range fail numeric constraints. Native callers must run
`mcp.schema.check` before `validate`.

Successful action output must match its declared schema and is returned in
`structuredContent`, with the same JSON in a text content block. A nil Lua
return means `{}`. `ouro.action_error(code, parameters)` produces `isError: true`
with `structuredContent = {error = {code, message, parameters}}`; errors need no
IDL declaration. Lua exceptions and invalid output become `ActionFailed` tool
errors. Discovery wraps each success output schema with an `anyOf` branch for
this common error envelope. Unknown tools and invalid arguments use JSON-RPC
errors instead. Lists/discovery use `ttlMs: 60000` and `cacheScope: "private"`.
Clients can subscribe to `toolsListChanged` using `subscriptions/listen`.
Successful catalog-changing reloads invalidate cached lists immediately;
unchanged catalogs and rejected candidates do not. See the
[discovery contract](mcp-discovery.md) for offline export and runtime publication.

Records are newline-delimited JSON-RPC and bounded to 4 MiB including newline.
Replies correlate by request ID and can arrive out of order. Each connection
allows one custom action in flight; a second receives a `Busy` tool error.
Runtime status and cancellation remain available while an action sleeps.
`notifications/cancelled` with `requestId` cancels that action; its terminal tool
error retires the request. Disconnect and source-generation retirement also
cancel actions without resuming their old Lua continuations. The server admits
at most eight same-UID peers and owns separate bounded read/write operations.
See the [MCP contract](mcp.md) for request metadata and result-type rules.

Direct `ouroctl run` launches the UI without any MCP server. `--headless`
explicitly runs only application tasks and IPC until exit. Optional production
MCP uses `$XDG_RUNTIME_DIR/ourokit/apps/<application-id>`, exposes actions only,
and never activates the UI. Existing listeners are not replaced or adopted.

Desktop activation follows the [Desktop Entry Specification](https://specifications.freedesktop.org/desktop-entry-spec/latest/dbus.html).
Declare `single_instance = true` to own the application's session-bus name.
Subsequent ordinary launches forward to that owner. The default is false:
each launch is a new process, without a public bus name. Development always
creates an independent process and neither calls nor owns the production name.

The optional declaration hooks are:

```lua
single_instance = true,
activate = function(platform_data) end,
open = function(uris, platform_data) end,
activate_action = function(name, parameters, platform_data) end,
```

These map to `org.freedesktop.Application.Activate(a{sv})`, `Open(asa{sv})`,
and `ActivateAction(sava{sv})`, each with an empty reply. The object path is the
application ID with dots replaced by slashes, prefixed by `/`, and hyphens
replaced by underscores. `parameters` contains typed `ouro.dbus.variant`
values. Known platform fields `activation-token` and `desktop-startup-id` are
strings; other fields remain typed variants. Hooks may yield and may return
`nil, {name='org.example.Error', message='...'}` to reject delivery. Missing
Open/action hooks return `org.freedesktop.DBus.Error.NotSupported`.

Install a matching `<id>.desktop` with `DBusActivatable=true` and a session-bus
`<id>.service` whose Exec runs `ouroctl run <manifest> --dbus-activated`.
The latter acquires the name but waits for an actual method call before UI
initialization; it requires `single_instance=true`. The desktop Exec fallback
uses ordinary `run`. `ouroctl activate <id>`, optionally `--action <name>` or
`-- <URI>...`, calls the standard interface and can trigger bus activation.
Ordinary `run` accepts the same action/URI launch arguments. Pass URIs, not raw
file paths. Command-line actions carry an empty parameter array; D-Bus callers
may send typed parameters. `XDG_ACTIVATION_TOKEN` and `DESKTOP_STARTUP_ID` are
forwarded as platform data. A Wayland token is consumed once when a surface is
ready; focus remains compositor policy. Repeated activation does not rerun the
UI factory. See [Contacts packaging](../examples/contacts/README.md).

Closing the last window drains accepted calls/output and exits. Explicit
`ouro.exit(code)` drains stdio output, cancels remaining tasks and exits.
Lua state is process-local, not persistent storage.

Ctrl+C (`SIGINT`) and `SIGTERM` request shutdown through the event loop, cancel
remaining tasks, and remove only the runtime socket owned by the application.
`ouroctl run` exits with status 130 or 143 respectively.
`SIGKILL` and crashes cannot run cleanup; any orphaned socket
still requires explicit removal after confirming no listener owns it.
Native hosts must enter the application runner before starting other threads
so worker threads inherit its signal mask. The runner restores the calling
thread's previous mask after teardown and preserves ignored signal dispositions.

Headless reload validates a fresh declaration without invoking `run`. UI reload
prepares a fresh UI in a candidate source generation and atomically replaces the
active generation only after its windows, schemas and handlers validate.
Reload resets Lua state. Development enablement is fixed for each process;
declared action sets may change on reload. Production never exposes reload.

### Live development operations

`ouroctl run app.lua --dev` logs `development socket: <path>`. Pass that exact
instance path to each command; development never discovers a production app ID.
The private, same-UID endpoint also accepts MCP `tools/call` with the corresponding
`runtime.inspect`, `runtime.input`, `runtime.capture`, `runtime.diagnostics`, and
`runtime.metrics` names. These tools are absent from `--mcp` production endpoints.

```sh
ouroctl dev inspect "$socket"
ouroctl dev inspect "$socket" '{"window":"main"}'
ouroctl dev input "$socket" '{"window":"main","token":"TOKEN","action":"click","target":"root/save"}'
ouroctl dev capture "$socket" '{"window":"main","token":"FRESH_TOKEN"}' --output frame.png
ouroctl dev metrics "$socket" '{"window":"main"}'
ouroctl dev diagnostics "$socket"
ouroctl dev reload "$socket"
```

Inspection without `window` lists live windows, handles, sizes and opaque tokens.
With `window`, it returns `windows: [{window, token, nodes}]`: semantic paths,
roles, labels, values, logical bounds, enabled/checked/selected/focused state,
text selection and scroll offsets. Semantic IDs are strings. Paths can be null
for unkeyed or ambiguous nodes; bounds may extend beyond clips. Snapshots fail
explicitly above 1,024 nodes or 64 KiB of text instead of silently truncating.

Input and capture require a fresh token from inspection. Reinspect after
`StaleDevelopmentTarget`; tokens cover window identity, source generation and
runtime/scene revisions, not just the path. Input accepts `click`, `hover`,
`pointer_down`, or `pointer_move` with `target`, `pointer_up` without a target,
`scroll` with `target` and signed `delta`, `key` with a logical
`key` name and optional `shift`/`control`/`alt`/`logo`, or `text` with UTF-8 `text`.
Keys include `tab`, `enter`, `space`, `escape`, `backspace`, `delete`, `home`,
`end`, `page_up`, `page_down`, `arrow_left/right/up/down`, and lowercase letters.
Text types printable characters into the focused editable field through normal
translated key events (up to 16 KiB); active IME composition and control
characters are rejected. Use key actions for navigation or Enter. Disabled,
read-only, stale, occluded, or noninteractive targets fail explicitly.

To exercise an internal drag, press its source with `pointer_down`, move to a
destination with `pointer_move`, then `pointer_up`. Inspect between actions;
you can capture the live preview before release. Escape cancels the drag.

Input runs normal routing, dispatch, runnable tasks, reconciliation and backend
submission before returning a fresh token and
`settled: "runnable_tasks_and_backend_submission"`. It does not await sleeping
tasks, animation completion or compositor presentation. Cancellation/disconnect
releases an in-flight press through routing but cannot undo callbacks already
run. Inspection and diagnostics do not evaluate Lua or expose arbitrary mutation.

Capture returns `{window, token, kind, path, width, height, bytes}`. Its kind is
`software_scene_replay`, never presented GPU readback. The endpoint retains four
private mode-0600 PNG files, deleting older captures and cleaning them up on
normal exit. `--output` atomically copies a capture to a durable caller-selected
path. Capture is bounded to 16 million pixels. Metrics report actual successful
CPU build/layout/paint counts and timings, routed events, accepted backend
submissions and resource counts; none measures input-to-presentation latency.
Diagnostics return active `source`, `generation`, and the latest structured
reload `diagnostic` (`phase`, `source`, `message`) or null. CLI operations print
JSON and exit nonzero on errors; reload/status retain their text output.

## Standalone subprocess dialogs

No service is needed for a small dialog. A parent process can send a request on
stdin, close that pipe to delimit the request, and read a decision from stdout.
`ouro.stdin.read(max_bytes)` returns a byte string or nil at EOF.
`ouro.stdout.write(bytes)` and `ouro.stderr.write(bytes)` complete all bytes;
all three operations yield only the calling task, including under backpressure.
Runtime diagnostics use stderr. `ouro.json.encode`, `ouro.json.decode` and
`ouro.json.null` provide JSON conversion independently of any MCP server.
Decoded arrays preserve their array identity, even when empty. Use
`ouro.json.array()` for a new empty array or `ouro.json.array(sequence)` to mark
a dense sequence explicitly. Plain `{}` encodes as an object.

Exit is separate from serialization: write the result, then call `ouro.exit(0)`.
The parent should treat a crash, window close without a decision, or malformed
output as no permission granted, and cancel the child when its request ends.
See the [permission dialog](../examples/permission-dialog/app.lua) and
[Contacts service](../examples/contacts/app.lua).

Outbound `ouro.mcp.call(address, toolName, arguments)` is available independently
of inbound server opt-in. It returns `{result, error}`: `result` is the complete
MCP result (including `structuredContent` and `isError`), while `error` is a
JSON-RPC error. Use `ouro.mcp.request` for ordinary non-tool requests and
`ouro.mcp.subscribe` for resource notifications. There are no automatic retries.

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

Mutable toplevel title and minimum dimensions are updated in place; initial
dimensions apply at creation. A zero minimum leaves that axis unconstrained.
Layer surfaces follow their separate configure/acknowledge contract and reuse
the same retained UI, input, scaling, rendering, frame pacing, and teardown
paths after configuration.
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
small closed render-object set (Box, Flex, Grid, Stack, Text, Image, Scroll,
TextInput, and Canvas only when their distinct behavior is demonstrated) owns
layout, paint, clip, and hit testing. Scenes are immutable backend-neutral
output.

The implemented headless render-tree kernel includes Box, Flex, Grid, Stack, and a
constraint-aware Text backed by immutable paragraph source and layout handles.
It uses one-way minimum/maximum box constraints and logical `f32` geometry.
Parents position children after each child chooses a finite constrained size.
Flex factors and stack offsets are typed edge metadata, not wrapper nodes. The
fixed-capacity tree caches unchanged constraint results, allocates paragraph
work only when Text inputs or width change, separates paint-only from layout
invalidation, builds ordered display lists, and performs reverse-order hit
testing without Wayland or Lua.

Declarative rows and columns expose that edge metadata as a contextual
`flex = <positive integer>` child property. It is rejected anywhere except on
a direct nonwrapping row or column child. `cross_alignment = "start" | "center" | "end" |
"stretch"` controls the container's cross axis. `flex=N` uses tight fitting
(Expanded): after measuring non-flex children, divide the remaining bounded
main-axis space by the flex factors and require each child to occupy its share.

Rows also accept `cross_alignment="baseline"`: align the first alphabetic text
baseline of each child, rather than its bounding box. This works with both flex
fits and with `wrap=true`, where every run gets its own baseline. Columns reject
this horizontal-only alignment. Children without a text baseline stay at the
top; they still contribute their full height. Surplus height stays below the
children, and tighter parent constraints still win (overflow is not clipped
implicitly).

The row reserves the largest distance above **and** below the baseline, even
when those distances come from different children. Text and rich text report
the first laid-out line's baseline. Boxes include padding, borders, and child
alignment. Columns forward the first baseline-bearing child; rows, grids,
stacks, and splits forward the topmost child baseline. Anchored content forwards
only its trigger. Stateful/stateless composition and layout builders preserve
these metrics through their returned native subtree.

Images, canvas drawings, empty boxes, and Scroll viewports have no baseline.
Text editors report their first logical line (or visible placeholder), not the
caret's line or the internally scrolled position. Paint transforms, opacity,
and scrolling do not change baseline layout. For example:

```lua
ouro.row {key="name", gap=12, cross_alignment="baseline",
  ouro.text {key="label", text="Name", size=18},
  ouro.text_input {key="input", default_text="Ada", flex=1, height=46},
  ouro.button {key="save", label="Save"},
}
```

See `baseline/mixed`, `baseline/changed` (font-size click playback), and
`baseline/wrap` in `examples/layout-storybook.lua`.

Use `flex={factor=N, fit="loose"}` for Flexible: the child receives zero as its
minimum and its share as its maximum, so it may choose a smaller size. `factor`
is a positive integer up to 65535; `fit` defaults to `"tight"`. Unused allocation
is **not redistributed** to siblings. Both fits still require a bounded main
axis and are rejected on direct Wrap children. These are parent constraints,
not CSS grow/shrink/basis rules. Stock controls that forward `flex` also accept
the table form; custom components forward it to their returned root.

`main_alignment` accepts `"start"` (default), `"center"`, `"end"`,
`"space_between"`, `"space_around"`, or `"space_evenly"`. It distributes the
space left after the children's **actual** sizes and mandatory gaps. `gap`
remains a minimum; the space modes add to it. No negative spacing is introduced
when content overflows. A single child centers for around/evenly and starts for
between. Directions are physical (left-to-right rows, top-to-bottom columns).
`main_axis_size="min"` shrink-wraps actual content, subject to parent minima;
use `"max"` to fill a bounded axis when you want alignment space.

```lua
ouro.row {main_axis_size="max", main_alignment="space_between", gap=12,
  ouro.button {label="Back"},
  ouro.box {flex={factor=1, fit="loose"}, width="fill", max_width=320,
    ouro.text_input {key="search", placeholder="Search"}},
  ouro.button {label="Save"},
}
```

#### Constraint-aware composition

`ouro.layout_builder {key=..., render=function(constraints) ... end}` chooses
one returned description (or nil) from its **local incoming constraints**.
The argument contains `min_width`, `max_width`, `min_height`, and `max_height`
in logical pixels, not the window size or the child's measured size. Unbounded
maxima are positive infinity (`math.huge`), as on a Scroll's scrolling axis.
The child receives the same constraints; the builder adds no padding or size
policy. Put sizing, caps, or alignment on an enclosing Box. Contextual `flex`
and grid placement belong on the builder itself.

```lua
ouro.box {key="form", width="fill", max_width=640, padding=16,
  ouro.layout_builder {key="arrangement", render=function(c)
    local wide = c.max_width >= 440
    local fields = {key="fields", gap=12,
      ouro.box {key="name", width="fill", flex=wide and 1 or nil,
        ouro.text_input {key="input", placeholder="Name"}},
      ouro.box {key="team", width="fill", flex=wide and 1 or nil,
        ouro.text_input {key="input", placeholder="Team"}},
    }
    return wide and ouro.row(fields) or ouro.column(fields)
  end},
}
```

The callback runs during a protected build, never inside live native layout or
paint. Candidate measurement pauses at each unresolved builder; lowering then
resumes with those bounds, in native measurement order. Only a fully measured
candidate can commit. A failed callback or selected subtree leaves the previous
instances, handlers, and signal dependencies intact, including during reload.
Root callbacks and stateful initializers are not repeated by these probe passes.
Keyed children with the same parent retain identity across arrangement changes.

Builder output is retained when constraints, declaration, enclosing build
scope, and signal dependencies are unchanged. Signal reads in `render` belong
to that builder; child components keep their own dependencies. As with other
render functions, keep callbacks deterministic and free of side effects.
The argument is a private table; modifying it does not change native bounds.

**No intrinsic feedback:** a builder cannot be measured with different inputs
within one native layout pass. This rejects, for example, an auto grid track
that sizes itself from the builder, or stretch on an unbounded cross axis.
Give that child a fixed-size Box, or use bounded non-intrinsic tracks. Ordinary
unbounded constraints are allowed; circular size-dependent composition is not.
There are at most 128 builders per window build, with bounded probe passes and
the existing nesting/node-capacity limits. Apps without builders do no probes.

See `builder/wide`, `builder/narrow`, and `builder/changed` in
`examples/layout-storybook.lua`; the last story clicks a local width toggle
without resizing the window.

#### Wrapping rows and columns

`ouro.row` and `ouro.column` accept `wrap=true` (default false) and `run_gap`
(default: `gap`). Both gaps must be finite, non-negative logical pixels.
Wrapping is greedy in child order: each child receives loose bounds for the
**whole run**, and starts a new run only when its size plus the gap would exceed
the main-axis maximum. An exact fit stays in the current run; an oversized child
is constrained to the whole run without creating an empty run. Rows advance
downward; columns advance rightward. An unbounded main axis produces one run.

`cross_alignment` operates within each run, using its tallest/widest child.
`stretch` stretches to that run's cross extent, not the entire container.
`main_axis_size="min"` (Lua default) uses the longest run; `"max"` fills the
bounded main axis. Incoming minimum constraints still apply. Runs can overflow
the bounded cross axis. Fill children use the whole bounded axis; they do not
share the remaining line space. **Direct wrapped children cannot use `flex`**;
put a nonwrapping row/column inside a sized child for weighted subdivisions.

`main_alignment` aligns the items independently within each run, using the
Wrap container's resolved main size; it does not alter greedy line breaking.
It does not distribute the runs along the cross axis.

```lua
ouro.row {
  key = "tags", wrap = true, gap = 8, run_gap = 12, cross_alignment = "center",
  ouro.box { key = "short", width = 74, height = 28 },
  ouro.box { key = "long", width = 136, height = 42 },
  ouro.box { key = "last", width = 93, height = 32 },
}
```

#### Explicit grids

`ouro.grid` takes required dense `columns` and `rows` arrays, each containing
1–32 tracks. A track is a finite non-negative pixel number, `"auto"`, or
`{fr=<finite positive weight>}`. `column_gap` and `row_gap` default to zero.
Direct children require one-based `column` and `row`. `column_span` and
`row_span` default to one and must be positive integers wholly inside the
declared tracks. No implicit tracks, automatic placement, named areas, minmax,
or CSS sizing algorithm are provided. Grids accept `semantic=false` like other
decorative containers, and contextual `flex` when placed in a nonwrapping row
or column. Their children cannot use `flex`.

```lua
ouro.grid {
  key = "panel", columns = {112, {fr=1}, {fr=2}}, rows = {"auto", 64, 92},
  column_gap = 10, row_gap = 14,
  ouro.text { key = "heading", column = 2, row = 1, column_span = 2,
              text = "An auto-height heading spanning unequal columns" },
  ouro.box { key = "rail", column = 1, row = 2, row_span = 2,
             width = "fill", height = "fill", background = "#DCEBFA" },
  ouro.box { key = "footer", column = 2, row = 3, column_span = 2,
             width = "fill", height = "fill", background = "#DDEFD8" },
}
```

Sizing is deliberately one-way: resolve columns, measure child heights at their
resolved spanning width, then resolve rows. Fixed tracks never grow or shrink.
Auto tracks grow from intrinsic child contributions. Spans include their inner
gaps; any intrinsic deficit is divided equally among the span's auto tracks,
shortest spans first, with declaration order breaking ties. Bounded fractional
tracks have **zero intrinsic minimum** and divide the non-negative space left
after fixed tracks, auto tracks, and gaps according to their weights. On an
unbounded axis, fractional tracks behave as auto tracks instead (weights do not
apply). Auto measurement requires children to support intrinsic sizing along
the measured axis; weighted Flex children need a bounded axis, as elsewhere.

Children receive loose cell bounds and sit at the cell origin. Omitted sizes
stay intrinsic; use a fill Box for stretching and its `alignment` for placement
inside the cell. A span changes placement constraints, not child identity.
Overlapping cells are allowed: children paint in declaration order and hit
testing visits them in reverse order. Reordering keyed children or changing
their placement retains their instances.

Grid placement on a stock control or custom stateless/stateful component flows
through to its returned root without adding a layout wrapper. Explicit placement
on that root overrides inherited fields. Placement stops at the first native
container; its descendants use their own parent's layout contract.

**Overflow is not implicit clipping.** The grid's own size obeys its incoming
constraints, but fixed/auto tracks and their children may extend beyond it;
they do not silently shrink to fit. Grid and wrapping Flex do not clip paint.
Use an `ouro.scroll` viewport or a Box with `clip=true` to clip it. Unclipped
ancestors allow hits on overflowing children, including transformed children;
explicit clips and the window viewport still gate hits. Each node's own hit
region remains its transformed layout bounds, not its shadow or pixel alpha.
Anchored floating children use the separate overlay traversal described below.

Native callers use `types.Flex.wrap/run_gap`, `types.Grid`,
`GridTracks.init(&.{ .{.fixed=112}, .auto, .{.fr=2} })`, and zero-based
`ParentData.grid` placement with spans defaulting to one. Track arrays are
value-owned by the render object; no caller-owned slice must remain alive.
Native Flex defaults remain unchanged (`main_axis_size=.max`, gaps zero).
Layout uses fixed-size track scratch storage and caches unchanged constraints.

`examples/layout-storybook.lua` covers wide/narrow rows, column runs, asymmetric
grid spans with wrapping text, and visible versus clipped overflow:

```sh
zig-out/bin/ouroctl storybook snapshot examples/layout-storybook.lua \
  --output .amp/in/artifacts/layout
```

#### Boxes and stacks

Boxes may opt into generated theme surfaces with `surface = "background" |
"card" | "popover" | "sidebar"`. Explicit `background` overrides `surface`,
including a fully transparent color; omitting both leaves the Box transparent.
`background` and `border` accept `#RRGGBB` or `#RRGGBBAA` (including color
values from `ouro.tokens`), using the same validation as buttons and inputs.
`background` also accepts an immutable [`ouro.linear_gradient`](#linear-gradient-paints).
Use [`ouro.color.with_alpha(color, alpha)`](design-system.md#deriving-a-color-with-alpha)
to derive a color with a replacement alpha from 0 to 1 without slicing tokens.
`border_width` and `radius` are finite, non-negative logical pixels, defaulting
to zero. A positive border width uses `border` or the inherited theme's `border`
color; zero hides it even if `border` is supplied. Border width participates in
layout alongside padding. Boxes do not inherit control geometry or introduce a
new widget-default section. An invalid `surface` remains an error even when
`background` is supplied.

Use asymmetric padding and alignment without an extra layout wrapper:

```lua
ouro.box {key="card", width=240, height=120, padding=12, padding_x=20,
  padding_left=0, padding_bottom=24, alignment="bottom_right",
  ouro.button {key="action", label="Save", on_press=save},
}
```

Here the content insets are left 0, right 20, top 12, bottom 24, plus any
border width. Parent constraints still win when insets exceed available space;
padding does not imply clipping. Per-edge properties belong to Box, not control
theme defaults. Custom control recipes can forward them to their root Box.

`width` and `height` accept a non-negative number or `"fill"`; omitted values
remain intrinsic. Optional `min_width`, `min_height`, `max_width`, and
`max_height` add constraints in logical border-box units (including padding and
border). Minima default to zero; omitted maxima add no cap. Values must be
finite and nonnegative, each minimum must not exceed its maximum, and an
explicit numeric width/height must lie within its declared interval.

Parent constraints always win: a tighter parent maximum overrides a child
minimum, and a larger parent minimum overrides a child maximum. In particular,
tight Expanded or cross-axis stretch can force a Box beyond its own maximum.
Use loose Flexible or an aligned parent Box when the child should stay capped.
Fill uses the resulting maximum; a local cap therefore makes fill finite even
on an otherwise unbounded scroll axis. These bounds constrain the Box, not
arbitrary overflowing child paint; clipping remains explicit.

`aspect_ratio` is an optional finite positive number expressing **outer width
divided by outer height**, including padding and border. It sizes arbitrary
content, not just images:

```lua
ouro.box {key="preview", max_width=480, aspect_ratio=16/9, padding=12,
  background="#DCEBFA", alignment="center",
  ouro.text {key="label", text="Preview"},
}
```

The Box first applies its ordinary bounds, explicit dimensions, and fill rules
within the parent's constraints. It then starts from the available maximum
width and derives height; if width is unbounded, it starts from maximum height
instead. Maximum bounds are checked before minimum bounds, recomputing the
other dimension to preserve the ratio. If no matching size fits, the final
clamp respects the constraints and sacrifices the ratio. Tight width and height
therefore override a conflicting ratio. Avoid setting both axes to fill when
you want the ratio to determine one of them.

With both axes unbounded, ratio sizing fails with `AspectRatioInUnboundedAxes`;
provide a numeric dimension or a local maximum. Minima alone do not choose a
preferred size. A vertical Scroll usually supplies bounded width, and a
horizontal Scroll bounded height, so the other dimension can follow the ratio.
An extreme ratio whose resulting size cannot fit finite native coordinates
fails with `InvalidLayoutSize`. Zero, negative, non-finite, and non-number ratio
declarations are rejected.

The child is laid out once after the outer size is resolved, with tight inner
constraints after subtracting padding/border, or loose inner constraints when
Box alignment is set. Child content does not determine ratio sizing. Changing
or removing the ratio invalidates layout while preserving keyed identity.
See the `aspect/*` stories in `examples/layout-storybook.lua` for wide/narrow
flex cards, ratio-change playback, and tight-parent precedence.

For a centered, capped-width form that still fits narrow parents:

```lua
ouro.box {width="fill", alignment="center",
  ouro.box {width="fill", max_width=640, padding=24,
    form_content},
}
```

Set `clip = true` to clip children to the Box's rounded border-box shape:

```lua
ouro.box {
  width = 180, height = 120, radius = 16, clip = true,
  ouro.image {src = "photo.png", width = 180, height = 120, fit = "cover"},
}
```

Omitted, nil, or false `clip` leaves child painting unchanged; other values are
errors. Radius zero clips to a rectangle. The radius is clamped to half the
smaller extent. Nested clips intersect, including ancestor Scroll viewports.
The Box's own background, border, outline, and shadow paint before its child
clip; ancestor clips still apply to them. Changing `clip` or `radius` repaints
without changing layout or retained identity. Pointer hits outside the rounded
contour skip the Box and its descendants, allowing an underlying sibling to be
hit. This does not add alpha-based hit testing for images or arbitrary paths.

Edges have per-draw antialiasing: this is not an isolated group or a group-opacity
effect. Multiple overlapping children blend separately at the clipped edge.
See `examples/clip-storybook.lua` and `examples/clip-composition.lua` for nested
clips, shadows, content, and corner hit testing.

`height_factor` is an optional finite number from zero to one. A Box lays out
its child at natural height within the incoming maximum, then multiplies its
natural outer height (including padding and border) by this factor. Parent
minimum/tight constraints still win. The factor does not squeeze the child or
change its width constraints; changing only the factor can reuse child layout.
It conflicts with explicit `height` or `height='fill'`. Combine it with
`clip=true` to reveal natural-height content, and `presence` to manage exit
input/lifetime. A zero factor alone does not unmount or disable descendants.

Set `opacity = 0.5` on a Box to fade its complete subtree as one group:

```lua
ouro.box {
  opacity = 0.5, padding = 16, radius = 12, surface = "card",
  ouro.text {text = "The card and its content fade together"},
}
```

Opacity must be a finite number from zero to one; omitted or nil means one.
The Box's own background, border, outline, shadow, and children render into a
transparent linear-light surface, which is then scaled and composited once.
Overlapping opaque children do not become extra dark in their overlap. Nested
groups composite independently. Ancestor rounded clips apply once to the
finished group; clips declared inside it still apply separately to each draw.

Opacity is paint-only: changing it preserves layout, identity, state, focus,
semantics, and pointer behavior. Zero opacity is invisible but still interactive;
disable its controls or omit the subtree when interaction should stop.
Exactly one uses the ordinary rendering path without a layer. Values are
quantized to 16-bit coverage. The existing `ouro.animation` render callback can
drive opacity just like other numeric Box properties.

Anchored floating content is painted separately in the window's overlay plane.
It escapes inline ancestor opacity, just as it escapes their clips. Set opacity
on the floating Box itself to fade a popup; nested popups remain independent.

Temporary layers are cropped to painted bounds, including overflowing children
and shadows, and limited to 64 MiB of pixels per submission, 1024 groups, and
16 nested groups. Exceeding a limit returns a rendering error rather than
silently dropping the effect. See `examples/opacity-storybook.lua` and
`examples/opacity-composition.lua` for overlap, nested clips, input, and fades.

Set `transform` on a Box to move or uniformly scale its paint without relayout:

```lua
ouro.box {
  width = 80, height = 60, background = "#389ac0",
  transform = { x = 40, y = -8, scale = 1.5, origin = { x = 40, y = 30 } },
  ouro.text { text = "Paint only" },
}
```

The map is `translation + origin + scale * (point - origin)`, in local logical
pixels. Translation and origin default to zero; scale defaults to one. Omitted
or nil `transform` is identity. All fields must be finite numbers, and scale
must be positive with a finite reciprocal. Zero, negative scale, numeric strings,
and malformed tables are errors. Rotation, skew, and nonuniform scale are not
supported. Nested maps apply child first, then parent. The native build copies
the parsed values; later mutations of the source table do not change retained
paint until another build reads it.

Transforms include background, border, outline, shadow, and descendants, including
text, images, drawing paths, gradients, and internal clips. Ancestor clips stay
in the ancestor's coordinate system. Opacity still isolates the complete group.
Existing device-coordinate, shadow, gradient, and layer limits apply after
scaling; unrepresentable compositions fail rather than silently dropping a map.

Layout sizes, offsets, sibling placement, scroll extents, identity, state, and
focus stay unchanged. Semantic inspection reports transformed visual bounds;
pointer hit testing maps back into local coordinates. Text selection, caret/IME
positioning, slider/split dragging, and wheel input account for the visual scale.
Raw pointer listener coordinates remain window coordinates. Layout-based
`ensure_visible` and virtual-list measurements do not change. `ouro.animation`
can drive transform fields without relayout. Anchored popups follow the visual
trigger bounds but do not inherit its scale; apply a transform to the floating
Box to transform the popup itself. See `examples/transform-storybook.lua` and
`examples/transform-composition.lua` for nested origins, clipping, input, and motion.

Boxes accept one optional outset `shadow`:

```lua
ouro.box {
  width = 180, height = 90, radius = 12, surface = "card",
  shadow = { x = 0, y = 4, blur = 12, spread = 0, color = "#00000040" },
  ouro.text { text = "Elevated card" },
}
```

`color` is required and uses the same hex/token format as `background`.
`x`, `y`, `blur`, and `spread` default to zero in logical pixels. All must be
finite numbers; `blur` must be nonnegative, while offsets and spread may be
negative. Omitted or nil `shadow` removes it; false and malformed tables are
errors. Positive spread expands the rounded border box and negative spread
contracts it. Blur uses a Gaussian with standard deviation `blur / 2`.

The shadow paints before the box background, border, and outline. The original
rounded box interior is excluded even when the box background is transparent.
Shadows do not change layout, semantic bounds, hit targets, or scroll extents.
They extend past the box's own content clip but obey ancestor clips such as
`ouro.scroll`. There are no inset shadows, lists of shadows, or drawing-command
shadows. Device-space blur is limited to 128 pixels after output scaling; masks
are limited to 8192 pixels per axis and 16 Mi pixels. These limits are checked
when the scene is built. See `examples/shadow-storybook.lua` for spread,
transparent knockout, clipping, and anchored-popup compositions.

`ouro.stack { key = "layers", ... }` overlays an ordered array of children at
the same origin. It also accepts `children = { ... }`, following the same dense
array and key conventions as rows and columns. Children paint in declaration
order; hit testing starts with the last child. Put decorative backgrounds first
and foreground controls last so the background cannot intercept their hits.
Hit testing uses transformed layout bounds and explicit rounded Box clips, not
alpha-based click-through.

Ordinary children receive loose parent bounds; their maximum extent determines
Stack's size, constrained by its parent. Fill children expand it to bounded
space; unbounded axes remain intrinsic. A fill Box can center foreground content:

```lua
ouro.stack {
  key = "layers",
  ouro.image {
    key = "fade", src = "images/vignette.svg",
    width = "fill", height = "fill", fit = "fill",
  },
  ouro.box {
    key = "foreground", width = "fill", height = "fill", alignment = "center",
    ouro.button { key = "action", label = "Activate", on_press = activate },
  },
}
```

To anchor or stretch a child, give it `positioned={left,top,right,bottom,width,height}`.
Insets and extents are logical pixels. Positioned children do **not** contribute
to Stack's size or baseline. They receive constraints after ordinary children
have determined the Stack's size; no iterative solver or intrinsic prepass is
involved.

```lua
ouro.box { key="preview", width="fill", aspect_ratio=16/9,
  ouro.stack { key="layers",
    ouro.box { key="background", width="fill", height="fill", background="#DCEBFA" },
    ouro.button { key="badge", label="Open", positioned={right=12,top=12}, on_press=open },
    ouro.box { key="caption", positioned={left=12,right=12,bottom=12,height=40},
      padding=8, background="#FFFFFF",
      ouro.text { key="text", text="Stretches between the side insets" } },
  } }
```

Opposing edges give the child a tight extent, clamped to zero when the insets
exceed the Stack's size. Otherwise `positioned.width`/`height` give tight extents;
an unspecified extent is unbounded so the child can choose its natural size.
Leading edges win positioning; a lone trailing edge subtracts the child's size.
An axis with neither edge starts at zero. Each axis accepts at most two of its
leading edge, trailing edge, and extent. Values must be finite, extents must be
non-negative, and the table must specify at least one field. Negative insets
allow overflow; Stack does not add clipping. Use an enclosing clipped Box when
needed.

A Stack containing only positioned children fills finite parent bounds on both
axes. It rejects an unbounded axis: supply a sized/aspect-ratio Box or an ordinary
child to establish the size. An empty Stack retains its minimum-constrained size.
Placement passes through stateless/stateful controls and animations to their
native root; explicit root placement overrides the inherited table. It does not
leak into descendants. Layout builders receive the resolved positioned constraints.
Other parents reject `positioned`.

The native `ParentData.stack {x,y}` remains for internal offset-based layout,
including virtual lists; these children still contribute to the Stack's size.
Public Stack children do not interpret bare `x`/`y`. Stack's own `flex` works only
inside a nonwrapping row or column; stack children cannot use `flex`.

#### In-window anchored overlays

`ouro.anchored` takes one inline trigger and an optional second child containing
floating content. Its normal layout size is exactly the trigger's size; opening
the floating child does not move surrounding content. The floating child is
measured against the window viewport, positioned after normal layout, and drawn
after ordinary content. Its paint and hit testing escape ancestor Scroll clips
and layout bounds, while event routing and retained identity keep their logical
ancestry. Later overlays draw above earlier ones; nested overlays draw above
their containing overlay. Hidden ancestors suppress their overlays. Inline
ancestor opacity does not fade floating content; set it on the floating Box.
Placement follows transformed trigger bounds, but inline ancestor transforms
do not scale floating content. A transform on the floating Box still applies.

Options are `side="top" | "bottom" | "left" | "right"` (default `"bottom"`),
`alignment="start" | "center" | "end"` (default `"start"`, along the side's
cross axis), `gap=4`, `margin=8`, and `flip=true`. Gap and margin are finite,
non-negative logical pixels. The floating child receives loose bounds inside
the viewport margin. Placement tries the opposite side when it fits better,
then clamps to the viewport margin. Resizing, scrolling the trigger, and changing
content size update placement natively. Use an inner Scroll for oversized content.
The primitive itself neither clips nor decorates the floating child.
Wheel routing and focus/`ensure_visible` scrolling stop at the floating child's
boundary: they may scroll a viewport inside the popup, but not the trigger's
ancestor viewport. Scrolling the trigger itself still moves the popup.

Lua owns visibility, dismissal and focus policy. Omit the second child to close
the overlay; the trigger retains its identity. Use existing Box keyboard hooks
for Escape and `on_pointer_down_outside` for outside dismissal. A floating Box
with `role="dialog"` opts into existing modal focus containment and restoration;
without that role the overlay does not automatically move or trap focus. A
nonmodal recipe can restore its trigger with `focus_request` on close.

```lua
local opened = ouro.signal(false)
local function close() opened:set(false) end
-- Inside a build function:
return ouro.anchored {
  key="menu", side="bottom", alignment="start", gap=6,
  ouro.button {key="trigger", label="Actions", on_press=function() opened:set(true) end},
  opened() and ouro.box {
    key="panel", role="dialog", label="Actions", width=200, padding=12, surface="popover",
    on_cancel=close,
    on_pointer_down_outside={button=272, propagate=false, handler=close},
    ouro.button {key="done", label="Done", on_press=close},
  } or nil,
}
```

This is not `ouro.popup`: it creates no Wayland surface, takes no compositor
grab, requires no real-input token, and cannot draw outside the current window.
Use `ouro.popup` when a compositor-managed popup surface is required. Neither
API is implicitly substituted for the other. Native callers use
`Object.anchored = types.Anchored{...}` with `.none` on both child edges.

#### Duration animations

`ouro.animation` rebuilds a description from native elapsed-time progress:

```lua
ouro.animation {
  key = "grow", duration = 300, easing = "ease_out",
  render = function(progress)
    return ouro.box {
      key = "bar", width = 43 + 200 * progress, height = 20,
      background = "#37656f",
    }
  end,
}
```

`duration` is required, in non-negative integer milliseconds. `easing` is
`"linear"` (default), `"ease_in"` (quadratic), `"ease_out"` (inverse quadratic),
or `"ease_in_out"` (smoothstep). `loop=true` repeats; it requires a positive
duration. A one-shot starts at zero and reaches exactly one at its deadline;
zero duration renders one immediately and requests no further frames. Loops
wrap to zero at each duration boundary. Missed frames do not extend duration.

The key is local to its logical parent and component instance. Rebuilds and
keyed reordering retain the timeline when its duration, easing and loop options
are unchanged. Changing those options or the key restarts from the initial
progress, without retargeting from the current value. Removing the declaration
stops it; remounting starts fresh. Accepted source reloads start fresh too;
rejected reloads do not alter the committed timelines. Each window owns its
own timelines, which are disposed when that window closes.

`render(progress)` follows the same non-yielding, side-effect-free rules as
component rendering. It may read signals and return a description or nil. It
does not run as an asynchronous task. The wrapper adds a semantic group but no
layout node; its returned root receives the ordinary parent constraints and
can inherit grid placement declared on the animation wrapper. Put other layout
properties on the returned root. Returning nil does not stop a still-mounted
animation; omit the animation declaration to stop it.

Zig samples time and easing and requests the shared native animation timer.
Only active timelines request wakeups, at most 16 ms apart or sooner at a
one-shot deadline. Animation frames reuse clean root/stateful descriptions and
rerun lowering, including the animation render callback; this is not a native
property binding or an independent Lua timer loop. Headless snapshots remain
at their initial progress unless the host explicitly advances the runtime
clock. Native hosts use the existing `advanceAnimations`/`animationDelay` pair.
The language-neutral core is `ui.animation.Registry`.

This primitive does not include pause/seek, completion callbacks, or exit
animations after a declaration is removed. Numeric springs and shared motion
policy are described below; retained exits use `ouro.presence`.

#### Interruptible numeric transitions

`ouro.transition` animates a finite numeric value toward a changing target:

```lua
local opened = ouro.signal(false)
-- Inside a content/component render callback:
return ouro.transition {
  key = "panel-motion", target = opened() and 1 or 0,
  duration = 200, easing = "ease_out",
  render = function(value)
    return ouro.box {
      key = "panel", width = 180, height = 120, background = "#389ac0",
      opacity = value, transform = { x = 24 * (1 - value) },
      ouro.text { text = "Panel" },
    }
  end,
}
```

`key`, `target`, and `render(value)` are required, plus `duration` or a `spring`
configuration (see below). Duration and easing
use the same units and options as `ouro.animation`. Target and optional `initial`
must be finite numbers; numeric strings are rejected. Without `initial`, a new
transition starts already at its target and requests no frames. With `initial`,
it animates from that value on mount. Zero duration immediately uses the target.
Transitions cannot loop.

A changed target starts from the last value committed to the UI build, even if
the native clock has sampled a newer value that has not yet been published.
It takes the full configured duration from that point, so rapid reversals are
continuous in value, not necessarily in velocity. Changing duration or easing
also retargets from the committed value. Rebuilding with unchanged target and
timing does not restart; changing only `initial` has no effect until remount.
Equal endpoints and completed transitions request no timer wakeups.

Identity is keyed within the logical parent/component and independent per window.
Removal cancels the transition immediately; remount and accepted source reload
start fresh using `initial` or the target. A rejected build or source reload does
not retarget live state. Returning nil from `render` keeps a mounted transition
alive, just like `ouro.animation`.

The render callback has the same non-yielding description-only contract as
`ouro.animation`. Both primitives share the native registry, clock, frame cadence,
and capacity. Transitions add no layout node; changing only opacity/transform
keeps layout cached. Width/height changes can still require layout. Invisible
opacity-zero content remains interactive unless the application disables it.
Completion callbacks are not included.

Run `examples/transition-composition.lua` for hover scaling, an interruptible
sliding panel, and a group fade. `tests/transition_composition.py` exercises real
native input, reversal, idle completion, independent windows, and source reload.

#### Springs and reduced motion

Use `spring` instead of `duration`/`easing` on a numeric transition:

```lua
ouro.transition {
  key = "slide", target = opened() and 1 or 0,
  spring = {mass = 1, stiffness = 170, damping = 26},
  motion = "auto",
  render = function(value)
    return ouro.box {key = "panel", width = 180, height = 120,
      transform = {x = 200 * value}, background = "#389ac0"}
  end,
}
```

An empty spring table uses the values above. Each parameter must be a finite
number between 0.000001 and 1000000 inclusive; unknown fields and numeric strings
are rejected. Targets, initial values, and positions used when retargeting into
a spring must have magnitude at most 1000000000000. Springs cannot specify
duration/easing, cannot loop, and are only supported by `ouro.transition`.

Underdamped, critically damped, and overdamped springs use an analytic solution
in seconds, independent of frame count. Retargeting or changing spring parameters
preserves the last committed position **and velocity**; converting from a duration
transition starts with zero velocity. Springs can overshoot: clamp a value used
for opacity yourself. A spring settles to the exact target when displacement is
at most 0.0001 and speed at most 0.001 units/second, or after a hard 10-second cap
per retarget. Settled springs request no wakeups.

All three wrappers (`animation`, `transition`, `presence`) accept `motion`:
`"auto"` (default) follows the inherited theme's `reduced_motion` boolean;
`"reduce"` always settles immediately; `"full"` always animates. The native host
reads `org.freedesktop.appearance/reduced-motion` from the Settings portal and
responds to changes without polling. Missing/unknown preferences mean full motion.
Override that default in the application `theme` or with
`ouro.theme {reduced_motion = true, ...}`; explicit false also overrides it.

Reduced mode uses the transition target or animation progress 1 immediately,
suppresses looping wakeups, and removes exiting presence immediately. Restoring
full motion restarts duration animations (including loops); settled numeric
transitions stay settled until retargeted. Policy changes preserve keyed identity
and remain transactional across failed builds/reloads.

`examples/spring-composition.lua` demonstrates interruption and policy changes;
`tests/spring_composition.py` verifies native overshoot, no relayout, exact rest,
loop suppression, presence removal, and reload rollback.

#### Retained enter/exit transitions

`ouro.presence` adds subtree lifetime to numeric transitions:

```lua
return ouro.presence {
  key = "panel-lifetime", present = opened(), duration = 200, easing = "ease_out",
  render = function(value)
    return ouro.box {
      key = "panel", width = 180, height = 120, background = "#389ac0",
      opacity = value, transform = { x = 24 * (1 - value) },
      ouro.text { text = "Panel" },
    }
  end,
}
```

Keep the declaration mounted and change the required boolean `present` rather
than conditionally returning the declaration. `key`, `duration`, and `render`
are required; easing follows `ouro.transition`. Presence cannot loop. A new
present subtree enters from 0 toward 1. An initially absent subtree does not
call `render` or request frames. Zero duration mounts/removes immediately.

Setting `present=false` transitions toward 0 while retaining the keyed subtree,
including component state and layout space. At zero it stops calling `render`
and removes that subtree. Reopening before removal reverses from the last
committed value with the same identities and state; reopening after removal
mounts fresh state. Reversals take the full configured duration, as numeric
transitions do. Presence adds no layout node and applies no paint effects itself.

Exiting content still paints but becomes non-interactive immediately, including
nested presence and floated descendants. It loses pointer capture and focus,
is skipped by hit testing and focus traversal, and reports disabled semantics.
Exiting dialogs release their focus boundary and restore the eligible opener.
Entering content is interactive immediately, even at opacity zero. Removing the
presence declaration or its parent, or closing its window, cancels immediately;
it does not wait for descendant exits. Accepted source reload starts fresh;
rejected candidates leave the live lifetime and state untouched.

Run `examples/presence-composition.lua` for a dismissible toast and sliding panel.
`tests/presence_composition.py` checks native lifetime, reversals, state retention,
disabled exit input, idle completion, independent windows, and atomic reload.

### Inherited visual defaults

Set `theme` on `ouro.app` to style every window without repeating widget props:

```lua
return ouro.app {
  id = "dev.ouro.example",
  theme = {
    color_scheme = "dark",
    colors = { primary = "#83d75c", primary_foreground = "#101810" },
    typography = { family = "monospace", size = 15 },
    controls = { height = 36, radius = 0, border_width = 1 },
    widgets = { button = { padding_x = 20 } },
  },
  run = function() return { windows = { ouro.window {
    id = "main", title = "Example",
    content = function()
      return ouro.button { key = "save", label = "Save" }
    end,
  } } } end,
}
```

Resolution order is host appearance → app theme → enclosing `ouro.theme`
overrides → explicit widget props. Nested tables merge field by field; missing
fields inherit. `color_scheme = "light" | "dark"` replaces the inherited color
palette, then explicit `colors` apply; it does not reset typography or metrics.
`reduced_motion` is a strict boolean, inherited independently of the palette.
Colors use the generated semantic token names and `#RRGGBB` or `#RRGGBBAA`.
Unknown theme fields and invalid colors/metrics are errors, not ignored typos.

Use the [Lua token catalog](design-system.md#lua-token-catalog) to reference
generated values instead of repeating literals: `ouro.tokens.foundation.spacing_3`,
`ouro.tokens.foundation.typography_2`, or `ouro.tokens.palette.light.indigo.step_9`.
`ouro.tokens.light` and `ouro.tokens.dark` provide fixed semantic palettes, not
the currently inherited theme; their colors act as explicit overrides.

The standard runner follows the [Settings portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Settings.html)
over the session D-Bus automatically (`org.freedesktop.appearance`, keys
`color-scheme` and `reduced-motion`).
Omit `theme.color_scheme` to follow the
system; typography, metrics, and individual color overrides still apply. Set
`color_scheme = "light"` or `"dark"` on the app or a nested `ouro.theme` to pin
that palette. Explicit colors remain explicit even when they match the previous
system default.

Startup never waits for the portal. The initial fallback and the
no-preference value (`0`) use the light palette; `1` prefers dark and `2` light.
Unknown values, missing settings, and unavailable services use the fallback.
Changes invalidate existing windows
without remounting their components. New windows and reloaded Lua inherit the
latest snapshot. Portal owner loss resets to the fallback. D-Bus owner-change
signals discover a returning service and trigger a fresh read, without polling.
Both portal versions are supported through `ReadAll`; `SettingChanged` supplies
live updates. The session address comes from `DBUS_SESSION_BUS_ADDRESS`, or
`$XDG_RUNTIME_DIR/bus` when unset. An unavailable or disconnected session bus
uses the fallback for the rest of that application run. No Lua subscription or
toolkit-specific settings daemon is needed for ordinary theme following.
See [system-appearance.lua](../examples/system-appearance.lua) for a following
window with an explicitly light section.

Native hosts can use `app.appearance.Store`: `current` is a typed `Snapshot`,
`update(snapshot)` publishes changes, and `takeEvent()` returns
`.appearance_changed` with the newest snapshot. Equal updates are suppressed and
multiple pending changes coalesce. `Snapshot.color_scheme` is `.default`,
`.light`, or `.dark`; `Snapshot.reduced_motion` is a boolean, defaulting to false.
Pass a process-lifetime store as `app.WaylandRunOptions.appearance`
to supply appearance instead of connecting to the portal. The store is not
thread-safe: update it on the owning event-loop thread and wake that loop. The
runner consumes its events at the UI safe point. Its built-in portal
client shares the native I/O loop and survives Lua source-generation retirement.

The supported defaults are:

| Section | Fields |
| --- | --- |
| `typography` | `family`, `size` |
| `controls` | `height`, `radius`, `border_width` |
| `widgets.button` | `height`, `padding_x`, `radius`, `border_width`, `font_size`, `background`, `foreground`, `border`, `hover`, `pressed`, `disabled`, `disabled_foreground`, `focus` |
| `widgets.text_input` | Same as button except `hover` and `pressed` |
| `widgets.option` | Same as button except `disabled`, `disabled_foreground`, and `focus`; `pressed` is the selected background |
| `widgets.text` | `foreground`, `font_size` |

### Controlled switches

`ouro.switch` is a Lua-composed binary control with a required boolean `checked`
value and non-empty accessible `label`:

```lua
local dnd = ouro.signal(false)

ouro.switch {
  key = "do-not-disturb",
  label = "Do Not Disturb",
  checked = dnd(),
  enabled = true,
  on_change = function(value) dnd:set(value) end,
}
```

`enabled` defaults to true. `on_change` is optional and receives the boolean
inverse of the last committed `checked` value. The application must supply the
new value on rebuild; the switch never changes it optimistically. Ignoring a
request leaves the control unchanged. External updates do not emit callbacks.
There is no `default_checked` or uncontrolled mode. Keep the same `key` to retain
native identity and focus across state, callback, theme, and sibling-order updates.

Switch thumbs animate with `transition`; checkbox marks fade and scale. Both
accept `duration` (nonnegative integer milliseconds, default 180) and `motion`
(`'auto'`, `'reduce'`, or `'full'`, default `'auto'`). Initial values mount settled;
accepted changes animate from the last committed visual value, including rapid
reversals. The semantic checked state changes immediately. Motion changes paint
without relayout. Reduced motion settles immediately, and settled controls request
no animation wakeups. See [springs and reduced motion](#springs-and-reduced-motion)
for inherited desktop policy and explicit overrides.

Primary-button press, Space, and Enter request a change. Keyboard repeats and
releases do not emit changes. Enabled switches are one Tab/Shift+Tab focus stop;
pointer presses focus them too. Disabled switches cannot focus or activate, and
disabling a focused switch clears focus. Callbacks run as ordinary scoped Lua
tasks, never during platform dispatch.

`label` is semantic only, not visible text or a larger clickable label. Compose
an adjacent `ouro.text` in a centered row when a visible label is needed. The
semantic snapshot records role `switch`, `checked`, `enabled`, and the label;
as with other widgets, an OS accessibility bridge is not yet implemented.

The fixed size-2 control has a 35×20 track within 43×28 hit bounds that reserve
space for the focus ring. It uses inherited semantic colors and a pill radius;
`theme.controls.radius` overrides the radius. It accepts contextual `flex` but
no children or button-style dimension/visual props. See the
[Lua recipe and intentional Radix departures](design-system.md) and
`switch/*` stories in `examples/storybook.lua` for both palettes, on/off,
disabled, keyboard focus, and controlled pointer activation.

### Button variants and tones

```lua
ouro.row { key = "actions", gap = 8,
  ouro.button { key = "cancel", label = "Cancel", variant = "soft", tone = "neutral" },
  ouro.button { key = "delete", label = "Delete", tone = "destructive" },
}
```

`variant` is `"solid"` (default), `"soft"`, `"surface"`, or `"ghost"`, and
`tone` is `"accent"` (default), `"neutral"`, or `"destructive"`. They follow
the Radix Themes button recipes: solid fills with step 9, soft with step 3,
surface adds a step 7 border over the `surface` role, and ghost stays
transparent until hovered. Use one solid accent button for the primary action
and soft or ghost neutral buttons around it. See
[design-system.md](design-system.md#widget-design-guidance) for the exact roles
and intentional departures. Unknown values are build errors.

Theme `widgets.button` colors style only the default solid accent button;
its geometry fields apply to every variant. Per-button color props override
any variant. Custom button content inherits the variant's label color and size
through the theme scope, so `ouro.text` and tinted `ouro.icon` children match
the automatic label in enabled and disabled states.

`ouro.separator { key = "rule", orientation = "horizontal" }` draws a 1-pixel
`border` rule that fills the bounded axis of its parent. `orientation` may
also be `"vertical"`. It is a stateless Lua recipe over a box with the
`separator` semantic role, not a native widget kind. It accepts no children
and does not take focus.

### Checkboxes, radio groups, and selects

`ouro.checkbox` has the same controlled `checked`, `label`, `enabled`,
`on_change`, motion options, and keyboard contract as `ouro.switch`, with a square checkmark.
Its label is semantic; compose visible text alongside it.

```lua
ouro.radio_group {
  key = "reload", selected = mode(), enabled = true,
  on_select = function(value) mode:set(value) end,
  ouro.radio { key = "ask", value = 17, label = "Ask before reloading" },
  ouro.radio { key = "always", value = 29, label = "Always reload" },
}

ouro.select {
  key = "encoding", label = "Encoding", selected = encoding(), width = 240,
  options = {{value=1, label="UTF-8"}, {value=2, label="UTF-16"}},
  on_select = function(value) encoding:set(value) end,
}
```

Radio groups are one focus stop. Arrow keys request the next/previous value in
declaration order, wrapping at the ends; Home/End request the first/last value.
Pointer presses request that radio's value. The application must accept the
request through `selected`; ignoring it leaves the group unchanged. Direct
children have unique integer `value`s. `enabled=false` disables the entire
group; individually disabled options and mixed-state checkboxes are not yet
supported.

`ouro.select` is a shipped Lua composition of a native button, anchored popup,
scroll viewport, and listbox. `options` must be nonempty, with unique integer
values and string labels, and `selected` must name an option. The trigger uses
the neutral surface button recipe: the selected text starts at the left and a
chevron icon sits at the right. Its optional `label` stays semantic: the
trigger's accessible label is `"<label>: <selected text>"`, but only the
selected text is visible. Without `width` or `flex`, the trigger and popup are
240 pixels wide. Up/Down/Home/End preview inside the popup;
Enter, Space, or a pointer selection commits through `on_select(value)` and
closes it. Escape, outside click, and native dismissal cancel the preview.
Focus returns to the trigger. `enabled=false` disables the trigger and closes
an open popup. Optional `on_error(error)` handles popup-creation failure.
This is a non-editable select, not a searchable combobox, and opening requires
the same genuine input authority as `ouro.popup`.

### Split views and tabs

`ouro.split_view` takes exactly two positional child descriptions. It is
controlled: `position` is a fraction from 0 through 1, and dragging or keyboard
input requests a new fraction through `on_change(fraction)`; the application
must provide it on rebuild. `axis` is `"horizontal"` or `"vertical"`.
`min_first` and `min_second` are optional pixel minima, proportionally reduced
when the view is too small to satisfy both. Optional `flex` has its usual
row/column meaning.

```lua
ouro.split_view {
  key = "workspace", axis = "horizontal", position = split(),
  min_first = 160, min_second = 400,
  on_change = function(fraction) split:set(fraction) end,
  sidebar, editor,
}
```

The native separator has semantic key `divider`. Axis arrows request a 10-pixel
move; Home and End request the effective first- and second-pane minima. Pointer
dragging preserves the initial grab offset instead of snapping the divider to
the pointer.

`ouro.split_view` is a Lua recipe with an 8-pixel divider, transparent at rest,
and theme-aware hover, pressed, and keyboard-focus paint. For custom divider
content, use the native `ouro.split` primitive with three ordered children:
first pane, second pane, and divider content. It accepts the same layout and
callback properties, plus finite non-negative `divider_size` (default 8),
measured along the split axis.

```lua
ouro.split {
  key='workspace', axis='horizontal', position=split(), divider_size=24,
  on_change=function(fraction) split:set(fraction) end,
  sidebar, editor,
  ouro.box {key='grip', semantic=false, alignment='center',
    background='#dddddd', states={hover='#c8d9fa', focus='#3468d4'},
    ouro.box {key='mark', semantic=false, width=4, height=40,
      radius=2, background='#666666'}},
}
```

The primitive owns an unpainted resize slot at `workspace/divider`. Its content
receives tight divider bounds and inherits native interaction state, so nested
boxes and text can declare `states` without Lua input handlers or rebuilds on
hover/focus. `focus_request` targets the resize slot. The slot keeps its identity
when its content changes; descendant semantic paths appear beneath `divider`
with decorative `semantic=false` containers omitted from those paths. Nested activation controls
remain independent. Omitting `on_change` keeps the focus stop but makes no
resize requests; removing the callback during a drag cancels that drag.

`ouro.tabs` is a Lua composition over native `tab_bar`/`tab` widgets and hidden,
retained panel boxes. It requires `key`, semantic `label`, controlled integer
`selected`, `on_select(value)`, and a nonempty `tabs` array. Each tab has a
unique integer `value`, string `label`, `content`, and optional `closable=true`;
closable tabs require `on_close(value)`. The control also accepts optional
`flex`. Its header follows the Radix Themes tab list: intrinsically sized
40-pixel tabs with gray step 11 labels, a gray step 3 hover, and a
medium-weight step 12 label over a 2-pixel `primary` indicator for the
selection. A separator rule runs under the bar, and a horizontal scroll strip
(semantic key `strip`) holds tabs that overflow. Close buttons are neutral ghost
icon buttons.

```lua
ouro.tabs {
  key = "documents", label = "Open documents", selected = selected(),
  on_select = select_document, on_close = close_document,
  tabs = {{value=1, label="Notes", closable=true, content=notes_editor}},
}
```

Stable keys keep every panel mounted and preserve native text, selection,
scroll, and undo state across switches. Inactive panels retain layout but are
excluded from painting, focus, pointer/keyboard input, and IME ownership.
Switching away cancels an active IME composition rather than retaining it.
See the [single-window documents example](documents.md) for a sidebar split
from tabbed editors.

### Sliders and numeric inputs

```lua
ouro.slider {
  key = "size", label = "Text size", width = 300,
  value = size(), min = 8, max = 32, step = 1,
  on_change = function(value) size:set(value) end,
}
ouro.spinbox {
  key = "size-number", label = "Text size",
  value = size(), min = 8, max = 32, step = 1,
  on_change = function(value) size:set(value) end,
}
```

Both require finite numeric `value`, `min`, `max`, and positive `step`, with
`min < max` and `value` within the bounds. Requests clamp to the bounds and snap
to steps anchored at `min`; `max` remains reachable even when off-grid.
Values remain controlled. Both accept `enabled` (default true) and contextual
`flex`. `label` names the control but does not add a visible label.

The horizontal slider is one focus stop. Press/drag requests values, including
when the captured pointer leaves its bounds. Left/Down and Right/Up move one
step, PageDown/PageUp ten, and Home/End to the bounds. Disabling or removing it
cancels dragging. `width` defaults to 200 and must be at least 32 logical pixels;
layout may constrain it. Development inspection exposes `range` with all four
numeric fields.

`ouro.slider` is a Lua recipe over boxes, a stack, and flex spacers. To build a
different horizontal value control, opt a box into native range input:

```lua
ouro.box {
  key='level', label='Level', width=240, height=40,
  range={value=level(), min=-2, max=7, step=0.5, inset=20},
  on_change=function(value) level:set(value) end,
  -- Supply your own track, thumb, or other content here.
}
```

`range` supplies the slider semantic role, focus stop, pointer dragging,
keyboard commands, and the same validation and controlled-value contract as
the stock slider. It requires a `label` and semantics; do not also supply
`activate`, `role`, `option`, `checked`, or `on_press`. `enabled`,
`focus_request`, `on_cancel`, and native `states` paint work as on other controls.
Omitting `on_change` leaves a focusable control that makes no value requests.

`range.inset` is the finite non-negative distance from each outer horizontal
edge to its value endpoint, defaulting to zero. Pointer mapping uses the
actual laid-out width minus both insets, with a minimum travel of one pixel
when constrained smaller. The stock recipe declares 14 pixels to account for
its padding, border, and half-thumb width; custom recipes choose their own
geometry. Removing the range binding or hiding/disabling the box cancels a
drag. No track or thumb is inserted by Zig.

The spinbox is a shipped Lua composition of a native single-line field and
decrement/increment buttons, sharing the native range validation and snapping.
Its `width` controls the field (default 100), excluding buttons. Typed text is
a draft: Enter parses and commits it, Escape resets it, invalid text resets to
the controlled value, and blur does not commit. Up/Down and the buttons request
one step from the controlled value. The controlled value takes precedence over
a draft based on a different value.
The field and enabled buttons participate in ordinary Tab traversal.

### Collapsible content and accordions

`ouro.collapsible` combines a disclosure button, animated indicator, and a
natural-height reveal. It requires `key`, a visible/semantic `label`, controlled
boolean `expanded`, `on_change(expanded)`, and exactly one content child:

```lua
ouro.collapsible {
  key='details', label='Workspace details', expanded=opened(),
  on_change=function(value) opened:set(value) end,
  ouro.column {key='body', gap=12,
    ouro.text {key='hint', text='No fixed content height required.'},
    ouro.text_input {key='name', label='Name', default_text='My workspace'},
  },
}
```

Tab/Shift+Tab visits the header; Enter, Space, and primary pointer press request
a change. `enabled=false` disables the header, not the content of an already
expanded panel. The header at `details/trigger` reports button role and optional
`expanded` state; ordinary buttons report null for that state. The underlying
Box API exposes `expanded` only on activating semantic buttons.

`duration` and `motion` use the toggle defaults above. The body uses `presence`:
closing makes it non-interactive immediately, clips/fades its natural layout,
and unmounts it when the exit finishes. Reversing before removal preserves
native identity and editor drafts; reopening after removal starts fresh. Keep
long-lived application state outside the body. Reduced motion opens/removes
immediately. `focus_request` targets the header; `flex`, `x`, and `y` apply to
the outer column. Give the column bounded width for wrapping content.

`ouro.accordion` composes single-open collapsibles with separators. Supply a
nonempty `items` array with unique string `key`, `label`, and `content` fields,
plus optional per-item `enabled`. Its controlled `expanded` is an item key or
nil; `on_change(key_or_nil)` must update application state. It accepts the same
`duration`, `motion`, group `enabled`, `flex`, `x`, and `y` options, but no children.

```lua
ouro.accordion {
  key='help', expanded=section(), on_change=function(key) section:set(key) end,
  items={
    {key='sync', label='Sync settings', content=sync_settings},
    {key='storage', label='Storage', content=storage_settings},
  },
}
```

Only the selected section is expanded/interactable; the previous section may
still paint while exiting. Header paths use `help/item-<key>/trigger`. Headers
use ordinary Tab order, not arrow-key roving focus. These components preserve
the current toolkit's internal semantics; they do not add an OS accessibility
bridge. Run `examples/motion-components.lua` for the interactive showcase or
snapshot `examples/motion-storybook.lua` for light, dark, disabled, focused, and
expanded states. `tests/motion_components.py` exercises the native application
and can record compositor videos with `--record-dir` (requires `wf-recorder`).

### Application-owned toasts

`ouro.toast` is a controlled, in-window notification card, not an OS notification
or a native popup. Place it in a bounded-width column with `gap=0`; each card
includes an 8px trailing gap that collapses with its height:

```lua
local saved = ouro.signal(false)
ouro.column {key='notifications', width=340, gap=0,
  ouro.toast {key='saved', present=saved(), message='Changes saved',
    on_dismiss=function(reason) saved:set(false) end}}
```

Keep the declaration mounted and set `present=false` to animate its exit.
Entry/exit combine a 16px horizontal slide, opacity, and natural-height reveal
(180ms ease-out by default). `duration` and `motion` use the toggle policy;
reduced motion snaps to the endpoint. Exiting content becomes noninteractive
immediately. Reversals retain the current reveal geometry without jumping.
Settled toasts request no animation frames.

Required fields are `present` (boolean), `message` (nonempty string), and
`on_dismiss(reason)`. The callback receives `'manual'` from the labeled dismiss
button or `'timeout'` from expiration, once per presentation. It requests a
state change; the caller must update `present`. Messages wrap to at most three
lines, then ellipsize. `width` defaults to `'fill'`.

`timeout` defaults to 5000 integer milliseconds (0–86400000); 0 makes it sticky.
The budget begins when the live card mounts, including entry time. Hover or
keyboard focus within **that card** pauses the budget; leaving both resumes
the remaining time, not a fresh duration. Other cards continue counting down,
and window blur does not pause the whole stack. Setting `present=false` or
removing the card cancels its timer scope. Reopening/reversing an exit or changing
`timeout` starts a fresh budget. Updating just the message does not reset it.
There is no global queue, swipe gesture, automatic focus stealing, or screen
reader live-region bridge. Use desktop notification services for notifications
that must outlive the window.

Run `examples/menus-and-toasts.lua` for normal/reduced motion and auto-dismiss.
`tests/menus_and_toasts.py --record-dir <directory>` records both modes using
`wf-recorder` on a disposable compositor.

### In-window modal dialogs

Place an `ouro.dialog` last in a full-area `ouro.stack`, after the normal page
content. Mount/unmount it from application state. Supply a required semantic
`label`, an optional card `width` (default 360), and one content child, usually
a column with visible title, body, and action buttons. `on_cancel()` receives
Escape; it must update state to dismiss the dialog. Clicking the backdrop does
not dismiss it automatically.

The Lua recipe draws the dim backdrop and centered themed panel. The native
runtime blocks input outside the dialog, moves focus inside, contains
Tab/Shift+Tab traversal, and restores the opener on unmount or hiding if it
still exists and is enabled. A child's explicit cancel handler or a text
field's active IME composition takes precedence over dialog Escape.

For custom presentation, use `ouro.box {role='dialog', key=..., label=...}`
with any layout, paint, and content. This opts into the same native modal
policy without adding a backdrop or panel. Supply `on_cancel()` to handle
Escape, including when there are no focusable children. A dialog box requires
semantics, `enabled=true`, and no activation; `semantic=false`,
`enabled=false`, and `activate=true` are rejected. Dismiss it by unmounting it
or setting `hidden=true`, not by disabling it.

Only one dialog descriptor per window is supported, including hidden
descriptors; nested dialogs are rejected. This is an application modal
surface, not an OS file chooser or a separate native window.

Run `ouroctl run examples/forms.lua` for the interactive settings smoke app,
or snapshot `examples/forms-storybook.lua` for light, dark, disabled, changed,
and modal states. These controls reuse Box/Text/Flex/Stack render primitives;
Lua composes the standard parts and Zig owns input, focus, and range policy.

### Internal drag-and-drop and reordering

Boxes accept `drag={kind='card',value='document-7'}` and
`drop={kind='card',on_drop=function(value,x,y) ... end}`. `kind` and `value`
are nonempty UTF-8 strings of at most 127 bytes with no NUL. Unknown fields,
non-string values, and missing callbacks reject the build. Native instances
copy the parsed strings; mutating a Lua table does not change an already built
source. A subsequent rebuild reads its current declaration normally.

A primary-button press arms the nearest source, retaining normal press
activation and focus behavior. Six logical pixels of motion start a drag.
Nested controls/editors own their gestures; use a separate handle if a card
contains interactive children. Once active, native motion/release handling
takes precedence over generic pointer hooks. The source subtree replays above
the scene at 75% opacity on an opaque theme-surface backing, offset from the
grabbed position by (12,24) logical pixels and without ancestor clipping. A
matching target gets a focus-color outline. The preview has no hit-test or
semantic nodes and does not change layout. Both renderers use the ordinary
scene commands.

Release invokes the nearest matching drop ancestor with the copied `value`
and target-local logical `x,y` (including inverse paint transforms). Hidden,
noninteractive, disabled, mismatched and source-descendant targets cannot
accept. Modal boundaries still apply. Escape, pointer/keyboard leave, source
removal/hiding/configuration changes, or an accepted source reload cancel the
session. A rejected reload preserves it. This is in-window only: it does not
export OS data, cross windows, or automatically scroll/reorder collections.
Use the [desktop drag API](desktop-services.md#text-and-file-uri-drag-and-drop)
for external text and file transfers.

The drop callback updates the application's ordered data. Keep stable keys
while changing sibling order to retain native editor text, selection, undo and
focus. `ouro.option`, `ouro.radio`, and `ouro.tab` forward `drag`/`drop` to their
boxes; each `ouro.tabs.tabs` entry can also provide them for its header. Tab
panels stay keyed by integer `value`, independent of array order. Choose a
different `kind` for independent reorder groups. Tab presses still select the
tab before dragging; close buttons keep their normal gesture.

Run `examples/drag-composition.lua` for retained card and tab reordering, or
`python3 tests/drag_composition.py zig-out/bin/ouroctl --capture-dir <directory>`
for native preview pixels, input/focus, cancellation and atomic-reload checks.

### Rich text and inline links

`ouro.text` accepts either a `text` string or a dense, nonempty `spans` array.
Spans form **one paragraph**, sharing wrapping, alignment, bidi ordering and
ellipsis. Each span has nonempty `text` and may override `size`, `weight`
(`normal` or `medium`), and `foreground`; omitted values inherit the text's
defaults. Sizes must be finite and positive. Span boundaries must fall between
extended graphemes, not inside combining sequences or joined emoji.

```lua
ouro.text {key='help', size=16, spans={
  {text='Read the '},
  {text='composition guide', key='guide', weight='medium',
    on_press=function() open_guide() end},
  {text=' before continuing.', foreground='#526579'},
}}
```

`on_press` makes a span an inline link and requires a stable `key`. Links use
normal pointer-press activation, Tab/Shift-Tab focus, Enter/Space activation,
and `enabled=false` to suppress activation and focus. Their default ink is the
theme's accent text color; disabled links use disabled foreground. Underlines
and keyboard-focus outlines follow each visible fragment, including wrapped
and bidirectional ranges. Unrelated text inside a link's overall bounding box
does not activate it. Ellipsis does not create a link target for hidden text.
Links require text semantics and cannot be nested inside another control.
Callbacks decide what activation means; links do not automatically open URLs.

Text and style data are copied when a description is lowered into native
storage. Mutating an original Lua span table after mounting cannot alter the
retained paragraph until a subsequent build reads it. The paragraph retains
font leases, and rejected reloads leave its layout, callbacks and focus intact.
Software and Vulkan rasterize each span's own font, size and color.
Run `examples/rich-text-composition.lua` for mixed styling, wrapped links,
bidirectional text, disabled links, and live width/color updates.

### Text inputs

`ouro.text_input` is a theme-aware Lua recipe over the native `ouro.text_editor`
primitive. Use the recipe for standard fields and the primitive for custom
chrome. Both share the same value, callback, focus, key-binding, and editing
contracts below. Keeping the same key and parent preserves native identity
when switching between them.

`ouro.text_editor` has no default background, border, radius, padding, or fixed
height. Width defaults to `fill`; height is intrinsic unless set to a number or
`'fill'`. It inherits general theme typography and text colors, but not
`theme.controls` or `theme.widgets.text_input`. It accepts explicit `background`,
`foreground`, `font_size`, `border`, `border_width`, `focus`, `radius`, `padding`,
`padding_x`, `padding_y`, and `alignment`, plus `placeholder_color`,
`selection_color`, and `caret_color`. Disabled state prevents editing and focus;
custom compositions choose their own disabled paint. Focus recolors an existing
border and never adds a border to a borderless editor. The editor is a leaf;
compose labels, icons, and buttons around it with ordinary boxes, rows, and
columns. Authentication input is a separate secure capability, not this editor.

```lua
ouro.row {key='search', gap=12, cross_alignment='center',
  ouro.text {key='label', text='Find'},
  ouro.text_editor {key='query', text=query(), on_change=function(v) query:set(v) end,
    flex=1, height=36, padding_x=9, alignment='left',
    border_width=1, border='#8899aa', focus='#3468d4', radius=6},
  ouro.button {key='clear', label='Clear', on_press=function() query:set('') end},
}
```

`ouro.text_input` is single-line by default. Long values scroll horizontally to
keep the focused caret or selection extent visible, including during IME
composition and pointer dragging. Resizing clamps the retained scroll offset.
Enter defaults to a `"submit"` command rather than inserting a newline.

Declared `text` and `default_text`, pasted text, and IME commits/preedit normalize
hard line breaks to spaces: CRLF becomes one space; standalone CR, LF, vertical
tab, form feed, NEL, and Unicode line/paragraph separators each become one space.
Values reported by `on_change` contain the normalized text. Normalizing an
initial or externally supplied value does not itself emit `on_change`.

Set `multiline = true` for a native plain-text editor (default height 160;
set `height` for a different viewport). Hard breaks normalize to LF instead of
spaces. Text wraps at the viewport width; oversized runs gain emergency breaks
between extended graphemes without changing the stored text. A single grapheme
wider than the viewport can still overflow. Enter and Shift+Enter insert a newline. Up/Down move by visual
line, Home/End move to visual line edges, and Ctrl+Home/End move to document
edges; Shift extends selection. Tab still moves focus, rather than inserting
a tab. Existing key-binding overrides take precedence over these defaults.

The multiline viewport scrolls vertically with the wheel or a captured drag
beyond its top/bottom edges. Caret movement and edits reveal the selection
extent; blinking does not undo manual scrolling. IME composition, clipboard,
read-only selection, and undo/redo share the single-line editing machinery.
The development tree reports `multiline`, the vertical `scroll_axis`, and
`scroll_offset`. Editors also report `text_scroll = {x, y}` in local logical
pixels and `caret_bounds` in window logical pixels (after scrolling and paint
transforms, before clipping). Caret geometry is available even when the caret
is hidden, but masked fields expose neither property. Development `text` accepts
LF only in multiline fields and `scroll` targets the editor itself.

By default, Ctrl+Z undoes an edit; Ctrl+Shift+Z or Ctrl+Y redoes it. Each field
retains up to 100 undo steps, including the selection before and after each
edit. Consecutive typing and repeated same-direction character deletions form
a single step. Selection/navigation, focus changes, commands, or a different
edit kind end the group. Grouping uses editing boundaries, not elapsed time.
Paste, cut, and word deletion are separate steps. An IME composition, including
any initial selection replacement, forms one step instead of one per preedit
update.

`begin_undo_group` starts a fresh explicit group; subsequent native edits of
different kinds can share one undo step. `end_undo_group` closes it. Navigation,
selection, focus changes, clipboard/register actions, undo/redo, and disabling
or making the field read-only still close it. A `submit` mode callback and
switching `text_entry` from false to true preserve an explicit group; switching
back to false ends it. Place `begin_undo_group` **after** selection and yank,
before deletion, to group a modal change with its following Insert typing.
This is undo grouping, not rollback: callbacks still observe each edit, and
failure or cancellation does not revert earlier edits. Groups do not nest.

Undo/redo emit the normal `on_change` callback when they restore an edit; an
empty history does nothing. They are unavailable in disabled/read-only fields
and during active IME preedit. Controlled rebuilds that echo the current value
preserve history; a different external `text` value resets it. Uncontrolled
rebuilds preserve history, and unmounting discards it. Editing after undo
discards the redo branch. Changing `multiline` replaces the editing session
from the current declaration, clearing composition and history and clamping
the retained selection, including for uncontrolled fields.

Set `text_entry = false` on `text_editor` or `text_input` to suppress unbound
printable keys and input-method entry without making the document read-only.
Explicit key-binding actions (including undo, deletion, cut, paste, and newline)
still work. This is useful for command modes: set `text_entry = mode == 'insert'`
and supply mode-specific `key_bindings`. Use `read_only` when *all* edits must be
blocked. Switching entry policy retains text, selection and history, ends the
current automatic undo group, and cancels uncommitted IME composition. Explicit
groups survive entry into Insert as described above. Enabled/read-only
guards still take precedence. Development inspection reports `text_entry`;
text injection into a suppressed field returns `DevelopmentTargetTextEntryDisabled`.

For task-driven editing, create `local editor = ouro.editor_controller()` once
and pass `controller = editor` to a `text_editor` or `text_input`. The controller
follows the mounted native session; it does not store a second document. Its
methods are synchronous and run only inside an Ouro task, not during rendering.
They return a value or `nil, {name=..., message=...}`.

- `editor:state()` returns `{token, selection, bytes}` without copying the text.
  Selection contains zero-based UTF-8 `anchor` and `extent` byte offsets and
  `anchor_affinity`/`extent_affinity` (`upstream` or `downstream`).
  Whole-line selections also have `line_caret = {anchor, extent, column}`:
  these are the actual cursor offsets and desired grapheme column, separate
  from the whole-line bounds. Passing it to `select` recomputes those bounds.
  Its optional `anchor_affinity`/`extent_affinity` preserve soft-wrap edges and
  default to downstream.
  Inclusive character selections use `character_caret` with the same fields;
  their bounds include both cursor graphemes. The two metadata fields are mutually exclusive.
- `editor:read(token, start, end)` copies only the half-open range requested.
- `editor:select(token, selection)` preserves direction and affinity (omitted
  affinities default to downstream); it returns the new state, without `on_change`.
- `editor:replace(token, start, end, text)` uses native normalization, caret
  placement, undo and `on_change`, then returns the new state. Invalid UTF-8,
  out-of-range positions, and offsets within a grapheme are rejected before editing.
- `editor:begin_undo_group(token)` and `editor:end_undo_group(token)` return
  the state and use the same grouping rules as native binding actions.

Tokens are opaque and belong to one controller. Text edits, selection movement,
composition changes, external controlled replacements, and unmount/remount
invalidate older tokens. After a yield, use a fresh state and recompute ranges;
`StaleEditorRevision` never applies an edit. Reads and selection are permitted
in read-only fields, but edits/grouping are not. Disabled/hidden editors, masked
fields, active preedit, and pointer selection drags are unavailable. Zero mounts
return `EditorNotMounted`; sharing a controller across multiple mounted fields
returns `EditorControllerAmbiguous`. Unmount and reload release native ownership;
retaining a Lua controller or token cannot keep a retired editor alive.

```lua
-- Inside a task, e.g. a button or command callback:
local s, err = editor:state()
if not s then return nil, err end
local first = math.min(s.selection.anchor, s.selection.extent)
local last = math.max(s.selection.anchor, s.selection.extent)
return editor:replace(s.token, first, last, 'replacement')
```

`caret_shape = 'beam' | 'block' | 'underline'` is available on both controls;
the default is `beam`. Block and underline follow the shaped advance of the next
logical grapheme at the caret's visual position, including proportional and bidi
text. At an empty line, end of line, or upstream wrap edge they use the base
font's shaped `0` advance (at least one logical pixel). Bounded multiline fields
reserve this width for every caret shape so the caret fits at upstream wrap
edges without horizontal scrolling or rewrapping on mode changes. Blocks paint above
selection highlights and behind glyphs with alpha capped at 128, and remain
visible at the active extent of a nonempty selection. Beam and underline carets
remain hidden for nonempty selections; underline thickness uses `caret_width`.
Shape changes do not change wrapping, selection, text, or undo history. Focus,
pointer-drag and IME visibility rules still apply. A shape does not imply an
editing mode or overwrite behavior.

`caret_blink = false` keeps the focused caret steady and schedules no caret-blink
timer. It defaults to `true` on both editor controls; focus and selection still
determine visibility. `Colon` names the colon keysym in key filters and chords;
use `Shift+Colon` on layouts that produce it with Shift.

Additional native binding actions support command-mode applications:

- `collapse_selection` collapses at the active extent, retaining its affinity,
  without moving another grapheme or changing text/history.
- `collapse_selection_start` collapses at the sorted range's start.
- `collapse_selection_anchor` restores the anchor, useful after a backward yank.
- `normalize_caret` collapses at the active cursor and clamps hard-line end to
  its last grapheme (empty lines stay at their start). `move_normal_` plus a
  movement destination applies the same rule; horizontal motions cannot cross LF.
  `append_character` moves to the insertion edge after that grapheme without
  crossing LF. Ordinary `move_`/`select_` insertion-edge behavior is unchanged.
- `select_character_forward`/`select_character_backward` select the current or
  previous grapheme within the hard line. An empty line or backward movement
  at line start yields an empty selection, never a selected LF.
- `select_characters` enters inclusive selection, retaining separate cursor
  endpoints. `select_inclusive_` plus a movement destination extends it with
  Normal cursor rules; `swap_selection` exchanges its active cursor and anchor.
- `select_word_inner` selects the Unicode word segment at the cursor (downstream,
  or the preceding grapheme at hard-line end). `select_word_around` also includes
  trailing spaces/tabs, or leading spaces/tabs if there are none after it.
  Neither crosses a hard newline; empty lines produce an empty selection.
- `move_vim_word_start_next`, `move_vim_word_start_previous`, and
  `move_vim_word_end_next` implement command-mode word motions separately from
  Ctrl+Arrow's Unicode word segmentation. They group letters/numbers/underscore
  versus punctuation, separated by space/tab/LF, preserving grapheme boundaries.
  End motions land on the last grapheme; their `select_` variant includes it.
  `select_vim_word_inner`/`select_vim_word_around` use those same word classes.
  `select_vim_word_forward` includes trailing spaces but stops before the current
  nonempty hard line's LF. `select_vim_change_word` excludes trailing spaces when
  starting on nonblank text, even at its final grapheme. These are fixed word
  classes, not configurable Vim `iskeyword` or its complete Unicode policy.
- `yank` copies selected text to an app-scoped characterwise unnamed register;
  `yank_lines` records whole-line text with a canonical terminating LF. Applications
  select the appropriate range before these actions. Empty characterwise yanks
  preserve the register; an empty linewise yank records one empty line. Both
  also export to the platform clipboard when available. Later clipboard changes
  do not affect the register; ordinary `copy`/`cut`/`paste` do not update it.
  `put_after`/`put_before` insert the register after/before the current grapheme,
  or below/above its hard line for linewise data, as one undoable edit. The
  register survives widget replacement but not app disposal. Secret fields
  cannot access it; read-only fields can yank but cannot put. No named/numbered
  registers or Visual replacement policy is implied.
- `select_paragraph_inner` selects a run of nonempty hard lines, including its
  terminating LF. Whitespace-only lines count as content. On blank lines it
  selects the separator run. `select_paragraph_around` includes following blank
  lines, or preceding blank lines if there are none after the paragraph.
- `select_line` selects the active hard line, including LF. `select_lines_up`,
  `select_lines_down`, `select_lines_start`, `select_lines_end`, and
  `select_lines_paragraph_previous`/`select_lines_paragraph_next` extend whole
  lines from that selection. They retain the original anchor line through
  shrink/reversal and distinguish the trailing empty line from its preceding LF.
- `delete_selection` deletes only the selected range (an empty range is a no-op).
  `delete_line` removes the active hard line; `delete_lines` removes a whole-line
  selection. An unterminated final line also removes its preceding LF, leaving
  the caret at the preceding line's start. `clear_lines` replaces a whole-line
  selection with one empty line. These edits preserve native undo history.
- `move_paragraph_previous`/`move_paragraph_next` and their `select_` variants
  target blank-line boundaries, skipping the current separator run first.
- `move_logical_line_start`, `move_logical_line_end`, and their `select_` variants
  target the extent's hard line, excluding its terminating LF. Existing
  `move_line_start`/`move_line_end` continue to target visual wrapped lines.
- `insert_line_above` and `insert_line_below` insert one LF at the extent's hard
  line boundary and leave the caret on the new empty line. They preserve selected
  text and form one undoable edit, restoring the previous selection on undo and
  the new caret on redo. They are no-ops for single-line or read-only fields.

For example, bind `O` to `{ "insert_line_below", command = "insert" }`, then
declare `insert` in an enclosing box's `commands` table to switch an application
signal to Insert mode. Native edits finish before the named callback runs; the
callback changes mode for the subsequent rebuild. No second key observer is
needed. Keep the editor's key and uncontrolled `default_text` stable so that mode
changes retain its session. These actions do not implement Vim policy.

Text input shortcuts are configurable. `ouro.app.text_input_bindings` supplies
app-wide overrides; `ouro.text_input.key_bindings` overrides those for one field.
Both are tables from key chords to semantic action names:

```lua
return ouro.app {
  id = "dev.example.search",
  text_input_bindings = {
    ["Ctrl+Z"] = false,
    ["Alt+U"] = "undo",
    ["Alt+R"] = "redo",
    ["Ctrl+B"] = "move_word_previous",
    ["Ctrl+Shift+B"] = "select_word_previous",
  },
  run = function() return { windows = {
    ouro.window {
      id = "main", title = "Search",
      content = function()
        return ouro.text_input {
          key = "query", default_text = "",
          key_bindings = { ["Enter"] = false, ["Ctrl+Enter"] = "submit" },
          on_command = function(command) print(command) end,
        }
      end,
    },
  } } end,
}
```

Omitted bindings inherit the app map, then built-in defaults. `false` consumes
that exact chord without performing an action; it does not fall back to typing
or another shortcut. `{ inherit = false, ... }` discards both app and built-in
bindings before adding the listed entries. An empty table inherits unchanged.
Maps are copied during declaration and updated on retained rebuilds, without
resetting the editing session or history. Invalid declarations leave the last
valid map installed. Up to 128 explicit bindings may be retained per field;
built-in fallback entries do not count toward this limit.

Keys can also name up to four whitespace-separated strokes, for example
`["C I W"] = { "select_vim_word_inner", "yank", "delete_selection", "submit" }`.
Values may be a dense array of one to five native actions, executed in order.
An application command or asynchronous `paste` must be last. Recipes are not
transactions: each mutating action retains its native undo and `on_change`
behavior. Use `begin_undo_group` explicitly to join later Insert typing.
A completed sequence may not be a prefix of another explicit binding. Shared
incomplete prefixes are allowed and override built-in single-chord defaults.
Escape cancels a pending sequence; a mismatch discards the prefix and processes
the current key normally. Prefixes have no timeout and cancel on focus change,
pointer press, IME activity, or binding rebuild. Sequences and recipes are not
executed in secret fields or during composition. Auto-repeat never completes a
sequence. Single-key character-delete recipes may repeat when they start with
`select_character_forward`/`select_character_backward` and contain only `yank`,
`delete_selection`, and `normalize_caret` afterward. A repeatable action followed
by `normalize_caret` also retains repetition. Other recipes do not repeat.
Native input draining yields after key-listener,
shortcut, and editor-command callbacks so their synchronous mode/focus updates
can rebuild before subsequent queued keys; ordinary `on_change` typing stays
batched. A callback that yields for asynchronous work does not stall later keys.

Add `command = "name"` to a recipe to finish with a contextual application
command instead of the enumerated `on_command` bridge:

```lua
local insert_mode = ouro.signal(false)
-- Inside content:
return ouro.box {
  key = "document",
  commands = {
    insert = function() insert_mode:set(true) end,
    normal = function() insert_mode:set(false) end,
  },
  ouro.text_editor {
    key = "body", default_text = "", text_entry = insert_mode(),
    key_bindings = insert_mode() and {
      Escape = { "end_undo_group", command = "normal" },
    } or {
      inherit = false,
      I = { command = "insert" },
      ["C W"] = { "select_vim_change_word", "begin_undo_group",
                  "delete_selection", command = "insert" },
    },
  },
}
```

The array holds zero to five synchronous native actions; the named suffix runs
last and cannot be combined with `paste`, `submit`, `cancel`, `previous`, or
`next`. Names are exact, case-sensitive strings of 1–64 bytes, copied natively.
Resolution starts at the editor and walks enclosing input scopes, stopping at
the modal boundary. The nearest eligible box declaring the name wins, whether
or not it also assigns a shortcut. An unresolved name is a consumed no-op;
already executed native edits are not rolled back. Names never resolve external
`app.actions`. The callback receives no arguments and uses the same task dispatch
as shortcuts; native `on_change` notifications queue before it. Its synchronous
mode changes rebuild before the next queued key. Named recipes do not repeat,
and retain the existing sequence cancellation, IME, secret-field and enabled
guards. Read-only still blocks native mutations, but permits commands (for
example, cancel or navigation). Use app policy to disable an unwanted command.
Explicit undo groups can span the suffix and subsequent typing; end them in
the Normal-mode recipe. Keep synchronous mode commands as ordinary functions.

Chord names are case-insensitive and use `Ctrl`, `Shift`, `Alt`, and `Super`
modifiers separated by `+`, followed by a logical key. Supported names are
`A`–`Z`, `0`–`9`, `F1`–`F12`, `Left`, `Right`, `Up`, `Down`, `Home`, `End`,
`PageUp`, `PageDown`, `Backspace`, `Delete`, `Enter`, `Escape`, `Space`, `Tab`,
`Colon`, `Brace_Left`, `Brace_Right`, `Equal`, `Plus`, and `Minus`. Include Shift
for shifted punctuation keysyms on layouts that require it (e.g. `Ctrl+Shift+Plus`
on a US keyboard). Keypad equals, add, and subtract use the same logical names.
Modifiers match exactly: `Ctrl+Z` does not also bind `Ctrl+Shift+Z`; letter case
in the declaration does not imply Shift. Shifted digit keys retain their digit
identity for bindings without changing the character inserted when unbound.
Duplicate normalized chords, unknown keys/actions, and invalid value types
are declaration errors.

Actions are `undo`, `redo`, `select_all`, `insert_newline`, `delete_backward`, `delete_forward`,
`delete_word_backward`, `delete_word_forward`, `copy`, `cut`, `paste`, `submit`,
`cancel`, `previous`, and `next`. Movement actions use `move_` or `select_` plus
one of `visual_left`, `visual_right`, `word_previous`, `word_next`, `line_up`,
`line_down`, `line_start`, `line_end`, `document_start`, or `document_end`.
`insert_newline` only edits multiline fields. For example, `select_line_end` extends
the selection to the line end. Without `on_command`, `previous` and `next` fall
back to line-up/down caret movement. With a handler they are application
commands (for example, search-result navigation); its return value does not
trigger a native fallback. Bind Up/Down to `move_line_up`/`move_line_down` to
keep caret navigation in a single-line command field. Multiline defaults
already use those direct movement actions. `move_word_next` is native
Ctrl+Right movement to the current word's end, not Vim `w` to the next word's
start. Unbound printable keys enter text when `text_entry` is enabled;
unbound Tab/Shift+Tab still traverse focus. Key releases never invoke actions.
Editing/navigation may repeat; clipboard, submit, and cancel actions fire only
on the initial press. Remapping does not bypass enabled/read-only or IME guards.

`select_line` selects whole hard lines while retaining separate anchor and active
cursor positions. `select_lines_up`/`down` move by hard line, preserving the desired
grapheme column through shorter lines. Other `select_lines_` destinations are
`left`, `right`, `line_start`, `line_end`, `word_start_next`, `word_start_previous`,
`word_end_next`, `start`, `end`, `paragraph_previous`, `paragraph_next`, and `swap`.
`swap` exchanges the active cursor and anchor; `select_characters` converts their
inclusive span back to a character selection. `collapse_selection` leaves the
cursor at its active position, not at the end of the whole-line range.

Set `mask = true` for a password field. It is the same single-line editor,
drawing one dot per grapheme; the value is kept in a locked page, copy, cut
and undo are disabled, input methods are never engaged, word movement treats
the value as one word, and Ctrl+U clears. `on_change` and `text` still carry
the value. Binding a PAM `conversation` and `prompt_id` instead sends the text
natively on Enter and never exposes it to Lua; see
[session.md](session.md#asynchronous-authentication).

`ouro.text_input` accepts optional string props `placeholder` and `label`:

```lua
ouro.text_input {
  key = "query", text = query(), label = "Application query",
  placeholder = "Search applications...",
  on_change = function(value) query:set(value) end,
}
```

The placeholder is a single-line display hint, ellipsized to the available width,
using the input typography and inherited `muted_foreground` color. It appears
only for an empty value with no active IME preedit, including in read-only and
disabled fields. It never becomes editable text, selection, clipboard contents,
IME surrounding text, or `on_change` data. Empty or omitted placeholders paint
nothing. The same rules apply to controlled `text` and retained `default_text`.

`label` sets the semantic accessible name independently of the value and hint;
it does not render a visible label. Omission preserves the existing semantic
label derived from the declared value. The semantic snapshot supports headless
assertions and future accessibility protocol translation; this does not add an
OS accessibility bridge. Neither prop changes editing or focus behavior.

`ouro.text_input` accepts `autofocus = true` to focus a newly mounted, enabled
input once (retained rebuilds do not reclaim focus). `on_command(command)` runs
in the owning task scope for bound command actions. Single-line defaults are
unmodified
`Enter` (`"submit"`), `Escape` (`"cancel"`), `Up` (`"previous"`), and `Down`
(`"next"`). Navigation may repeat; submit/cancel only fire on the initial press.
Commands are withheld during IME preedit. `on_command` and `on_change` may be
used together.

To request keyboard focus again without remounting, set `focus_request` to a
changed positive integer. Keep the widget's `key` stable and increment a signal
from an event callback:

```lua
local focus_request = ouro.signal(0)
local function refocus()
  focus_request:set(focus_request() + 1)
end

local function content()
  return ouro.column { key = "launcher",
    ouro.text_input {
      key = "search", default_text = "", autofocus = true,
      focus_request = focus_request(),
    },
    ouro.button { key = "scope", label = "Applications", on_press = refocus },
  }
end
```

The request runs after a successful build commits, including on initial mount.
An unchanged token does not reclaim focus on later rebuilds. Omitted, `nil`, or
zero means no request (not blur); returning from zero to a positive token requests
again. Tokens must be non-negative Lua integers; booleans, strings, fractional
numbers, and negative numbers are errors. Failed builds do not consume requests.
Use a signal read by the content/component that declares the target; writing an
ordinary Lua variable alone does not schedule a rebuild.

`focus_request` works on `text_input`, `button`, `switch`, `checkbox`, `slider`,
`listbox`, `radio_group`, `tab_bar`, `virtual_list` (viewport), and `split_view`
(divider). The standard compositions forward it: `spinbox` to its input,
`select` to its trigger, and `tabs` to its tab bar. Custom components must forward
the prop to their intended focusable child.

Requests obey visibility, enabled state, and the current modal focus boundary;
read-only inputs remain focusable. Rejected requests are consumed, not deferred:
change the token again after making the target eligible. If several widgets
request focus in one build, the last eligible request in declaration order wins.
Explicit requests run after autofocus and dialog focus setup. They only change
focus within that window; they do not activate an OS window or grant keyboard
access to a layer surface. Text, selection, and undo history stay retained with
the widget; normal focus-loss/IME cancellation rules still apply.

Widget defaults override shared controls/typography values. Explicit widget
fields override those defaults; a text node's existing `size` prop takes precedence
over `font_size`. Font sizes and theme heights must be positive; other metrics
are non-negative logical pixels. A zero border width disables the border,
including its focus-color treatment. A theme does not change widget behavior,
container gaps, application layout, or explicit dimensions.

`typography.family` selects a Fontconfig family, including the generic aliases
`sans-serif`, `serif`, and `monospace`. Fontconfig applies the user's substitutions
and supplies ordered missing-character fallbacks. Names and candidate identities
are copied, not retained Lua strings; fallback font files load only when shaping
needs to probe them. Family overrides require a host font service. Omit the family
to retain the host's fonts: both the standard runner and Storybook default to
Fontconfig's `sans-serif`. Production runners require Fontconfig and installed
fonts; they do not embed font families. Snapshots depend on the machine's font
files and Fontconfig configuration.

The app declaration is a fixed default, copied at load/reload. For a reactive
override, return `ouro.theme { key = "local", controls = { radius = radius() },
children = { ... } }` from a content/component function. It affects only its
descendants, including cached component descriptions; changing the theme does
not remount those components. `ouro.theme` paints its resolved background;
themed Box surfaces can select other color roles. App `colors.background`
supplies the window background.

See [the three Contacts themes](../examples/themes/shared.lua): the same content
function, data, and event handlers run with Paper, Terminal, or Candy defaults.

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

Mounted UI builds have a separate language-neutral build-owner registry.
A build owner has keyed identity, parent/child ownership, a resource scope,
and requested/building/built revisions, but no render-object fields. New owners
queue an initial build; later invalidation targets the owner directly instead
of searching the retained tree. Stabilization is bounded by passes rather than
total owner count, so many independent dirty owners remain one pass
while state writes during builds schedule subsequent passes. Descriptor
reconciliation must succeed before the build revision commits. Retiring a
build owner recursively removes pending descendant work and queues its scope for
safe-point cancellation. Production windows retain one native build owner;
generation-owned Lua component readers distinguish dependency sets and cached
render output beneath that owner. This keeps component updates compatible with
whole-window reconciliation and isolated source-reload candidates.

The initial signal primitive is deliberately narrower than a general reactive
runtime. Lua owns each signal value. A bounded native edge table associates
generation-checked signals with reads made by the current owner and component
reader.
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
descendant such as a Text to its owning widget instance and scope, then spawns
its registry-referenced Lua function as an independently yieldable coroutine task.
Bindings use generation-checked instance handles; stale targets are dropped.
The application-facing binding is constructor-specific, currently
`ouro.button { on_press = function() ... end }`; numeric instance IDs and the
compact pointer event ABI are not exposed. Build references commit only after
descriptor reconciliation succeeds; rollback, replacement, removal, and window
teardown release them.

Buttons may supply one `children` description instead of the generated label
text, for example a row containing an icon and text. `label` remains required
as the button's accessible name. The button still owns focus, hover, and
activation over its entire bounds; custom content owns its text styling.

Padding is Box layout policy rather than a wrapper render object. Theme, keyed
identity, focus, shortcuts, and stateful components are instance/widget policy,
not render-object variants. There will be no universal generic node and no
permanent arbitrary table parser based on repeated string `type` dispatch.

The eventual component schema should generate Lua constructors, compact Zig
bindings/decoding into this normalized snapshot, Lua language-server types,
documentation, and cross-language validation. The constructor-specific bridge
proves this route end to end: a protected non-yielding mounted Lua build returns
an opaque description tree. During reconciliation, native lowering traverses
that returned tree in child order and produces typed descriptors in bounded
storage for transactional validation. Constructors do not emit descriptors
during Lua evaluation, and unattached descriptions do not become UI. There is
no generic string `type` parser or application-facing descriptor escape hatch.
During lowering, `ouro.row` and `ouro.column` normalize to Flex,
`ouro.scroll` normalizes to a single-child Scroll viewport, `ouro.text`
normalizes to Text, and `ouro.button` normalizes to Box plus Text or its supplied content. The
single-selection `ouro.listbox` composes a vertical Flex with direct
`ouro.option` Box/Text children. It is one focus stop, uses integer values,
and calls `on_select(value)` on primary-button press or Up/Down/Home/End navigation;
the application remains the source of truth through the `selected` property.
Optional `on_activate(value)` distinguishes pointer/Enter/Space activation from
arrow-key preview; `on_cancel()` receives Escape. `enabled=false` disables the
group. Option values must be unique within the group.
Options are transparent over their containing surface at rest and retain hover
state across reconciliation. Default options use accent steps 3 and 5 for hover
and selection. `appearance = "sidebar"` instead uses gray steps 3 and 5 plus a
medium selected label for navigation catalogs without introducing a separate
widget.

### Drawings are immutable native snapshots

`ouro.drawing` creates a reusable drawing without a native plugin or a paint
callback. Pass it to `ouro.canvas` to place it among ordinary widgets:

```lua
local picture = ouro.drawing {
  width = 180, height = 80,
  rectangles = {
    { x = 0, y = 0, width = 180, height = 80, color = "#182430" },
    { x = 12, y = 16, width = 97, height = 48,
      color = "#39bda4", corner_radius = 8 },
    { x = 73, y = 8, width = 65, height = 40, color = "#e85d7580" },
  },
}

ouro.canvas { key = "preview", drawing = picture, alt = "Overlapping color samples" }
```

The `rectangles` field is a dense array of at most 4096 records; an
empty array is valid. Each record requires `x`, `y`, `width`, `height`, and
`color`; `corner_radius` defaults to zero. Colors use `#RRGGBB` or `#RRGGBBAA`
straight-alpha sRGB, or an immutable `ouro.linear_gradient`. Records paint in array order using linear-light
source-over blending. Coordinates are finite logical-pixel numbers representable
in native `f32`; dimensions and radii must be nonnegative. Negative `x`/`y`
are allowed. Numeric strings, nonfinite values, holes, and overflowing bounds
are errors. Zero dimensions are valid. Fields are read directly from the tables,
not from metatable callbacks.

Construction copies all geometry and colors. Mutating the original tables does
not change the drawing. Store a drawing in Lua to reuse it across renders,
canvases, or windows; construct a replacement when reactive state changes.
Construction is also valid during a render: signal reads used to compute the
geometry subscribe that component as usual. Painting never invokes Lua or reads
signals. The userdata is immutable and has no drawing methods.

The drawing's width and height supply the canvas's preferred size. Parent
constraints can change its allocated box, but the recording is **cropped, not
stretched**. Display scaling still applies. Painting clips to the canvas bounds
and ancestor clips. The canvas is an image-role leaf with optional `alt` text;
wrap it in a focusable/input-handling box for interaction. Lua, prepared builds,
and retained render objects hold independent leases, so failed builds/reloads
cannot invalidate the committed picture. Scenes contain copied paint commands.
Normal scene-capacity and device-coordinate limits still apply when painting.

For ordered rectangles and vector paths, pass `commands` **instead of**
`rectangles`. Exactly one array is required, with at most 4096 paint commands:

```lua
local picture = ouro.drawing {
  width = 160, height = 100,
  commands = {
    { kind = "rectangle", x = 0, y = 0, width = 160, height = 100,
      color = "#182430" },
    { kind = "fill", color = "#39bda480", fill_rule = "even_odd",
      path = {{"move", 12, 12}, {"line", 120, 20}, {"line", 40, 80}, {"close"}} },
    { kind = "stroke", color = "#e85d75", width = 3, cap = "round", join = "round",
      path = {{"move", 16, 70}, {"quadratic", 60, 0, 90, 60},
              {"cubic", 110, 90, 130, 10, 148, 55}} },
  },
}
```

`fill_rule` is `"nonzero"` (default) or `"even_odd"`. Strokes require a positive
finite `width`; `cap` is `"butt"` (default), `"round"`, or `"square"`; `join` is
`"miter"` (default), `"round"`, or `"bevel"`. `miter_limit` defaults to 4 and must
be finite and at least 1. Rectangle commands use the same fields as above.

Each path is a dense array of at most 4096 segment records, with at most 65536
records across one drawing. Records have exactly the positional fields shown:
`{"move", x, y}`, `{"line", x, y}`, `{"quadratic", cx, cy, x, y}`,
`{"cubic", c1x, c1y, c2x, c2y, x, y}`, or `{"close"}`. A contour starts with
`move`; after `close`, another `move` is required. Fills implicitly close open
contours. Empty and move-only paths paint nothing. Geometry and style are copied,
including nested segment arrays. Colors blend once through antialiased A8
coverage in linear light; intersections within a stroke do not add extra alpha.

Each rasterized path is limited to 8192 pixels per axis and 16 Mi pixels,
including conservative stroke/antialiasing padding. The coverage cache is bounded
to 32 MiB; extreme geometry may be accepted at construction but rejected when
painted at a particular display scale. Arcs, dashes, drawing shadows,
arbitrary transforms, and path clips are not implemented. Outset box shadows are
available separately through the `shadow` field on `ouro.box`. The experimental native plugin
ABI still exposes rectangles only; its ABI is unchanged.

See `examples/drawing-composition.lua` for shared, replaced, and constrained
rectangles, and `examples/path-storybook.lua` and `examples/path-composition.lua`
for path styles and retained path drawings.

### Linear-gradient paints

```lua
local ramp = ouro.linear_gradient {
  from = {x = 0, y = 0}, to = {x = 180, y = 90},
  stops = {{offset = 0, color = '#ef5350'},
           {offset = 1, color = '#1976d200'}},
}
ouro.box {width = 180, height = 90, radius = 12, background = ramp}
```

Gradients work as Box `background` and drawing rectangle/fill/stroke `color`.
Endpoints are explicit logical pixels relative to the Box border-box origin or
the **recording origin**, not each drawing primitive. Display scaling and Box
transforms move the endpoints; a constrained canvas crops without stretching the
ramp. Text, borders, and shadows still require solid colors.

The constructor copies the endpoint and stop tables into immutable userdata.
It requires distinct finite endpoints and a dense array of 2–8 stops, with finite
nondecreasing offsets in `[0,1]` and hex colors. Numeric strings are not accepted.
Colors extend constantly beyond the first and last stops. Duplicate stops create
hard edges: the last stop wins exactly at the quantized boundary. Stops and
projection use nearest UNORM16 quantization. Colors interpolate in premultiplied
linear light, so black-to-white has an sRGB midpoint near 188, and transparent
colored stops do not create colored halos. Extreme endpoints or transforms that
cannot support finite device-pixel projection are rejected. Radial and repeating
gradients are not supported.

See `examples/gradient-storybook.lua` and `examples/gradient-composition.lua` for
rounded surfaces, hard stops, transparent ramps, and retained drawing sharing.

### Images and icons load asynchronously

```lua
ouro.image {
  key = "photo",
  src = "assets/photo.webp",
  width = 240,
  height = 160,
  fit = "cover",
  alt = "A mountain lake",
}

ouro.icon { key = "next", src = "assets/arrow.svg" }
```

`src` is a path relative to the application's source/module root. Alternatively,
pass an encoded Lua string as `bytes`; exactly one source is required. Absolute
paths, directory escapes, symlinks, and implicit network access are not supported.
Storybook uses the catalog file's directory as its asset root.

PNG, JPEG, WebP, and static SVG use the same native Image leaf. JPEG orientation
is applied before layout; animated WebP displays only its first frame. SVG is
restricted to self-contained paths and shapes: external references and embedded
images are disabled, and text must be converted to paths. Embedded ICC profiles
are not converted; output is premultiplied encoded sRGB, without HDR/wide gamut.

File reading, decoding, and SVG rasterization run on a worker, never in layout or
paint. A successful build queues work; completions invalidate only subscribed
windows. Pending and failed assets paint nothing but keep declared dimensions.
A host without an image service treats every image as failed rather than
rejecting the build.
Use an enclosing box for a placeholder surface. Missing dimensions use the loaded
intrinsic size; one declared dimension preserves aspect ratio, subject to parent
constraints. Failed sources remain failed until eviction or source reload.

`ouro.image` also accepts `width = "fill"` and `height = "fill"` independently.
Each fills its bounded incoming layout axis, including while loading or failed;
an unbounded fill axis falls back to intrinsic sizing. Two bounded fill axes
occupy the complete available rectangle. Numeric dimensions retain their existing
behavior. Icons keep numeric dimensions and their 24×24 defaults.

Fill is a layout request, not a raster-resolution hint. Numeric dimensions still
provide SVG raster hints; with no numeric dimensions, SVG rasterization uses its
intrinsic viewport times output scale. Resizing a fill image updates its layout
bounds and resamples the cached bitmap, without rerasterizing at every new size.
Use a suitably sized SVG viewport for the intended display range. SVG raster hints
preserve intrinsic aspect ratio; `fit` determines final placement and stretching.

`fit` defaults to `contain` (centered, aspect-preserving). `cover` fills the box
and crops; `fill` stretches. `tint` applies a color through the decoded alpha mask;
without it, images preserve their colors. `ouro.icon` supplies a 24×24 logical size
and the inherited theme foreground tint. Set `width`, `height`, or `tint` to
override those defaults. `alt` supplies the semantic image name.

Decoded assets are cached by source and raster options, including physical size,
scale, and tint. Trees, prepared builds, and frames hold separate pixel leases.
Omitted subscriptions allow eviction; a retiring generation drains its active
worker without blocking input or publishing its result. Source and decoded-memory
budgets are bounded. Both software and Vulkan renderers support the same fitting,
bilinear filtering, clipping, and alpha compositing. Vulkan currently uploads
pixels per submission; persistent GPU texture caching is not implemented.

See `examples/images.lua` for file-backed formats, byte-backed icons, fit modes,
theme inheritance, interaction, and failed assets. Storybook snapshots wait for
asset completion before capturing pixels.
The `stack/vignette-small` and `stack/vignette-large` stories compose a static SVG
opacity fade behind a centered button and replay a click through normal input.

### Asynchronous notification images

`ouro.images.load(options)` yields while importing an image and returns an
owned PNG byte string, or `nil, { code = ..., message = ... }`. Call it from an
Ouro task, not a UI build. Pass either `{ path = absolute_local_path }` or
freedesktop notification image data:

```lua
local bytes, err = ouro.images.load {
  data = pixels, width = width, height = height, rowstride = stride,
  has_alpha = true, bits_per_sample = 8, channels = 4,
}
-- Retain bytes in application state and render with ouro.image { bytes = ... }.
```

Raw data is straight RGB/RGBA8. Row padding is accepted and is optional after
the final row. Alpha and channel count must agree. Paths must be absolute local
paths; URI normalization belongs to the caller. Path imports reject symlinks,
magic links, and non-regular files. Encoded files and raw inputs are limited to
4 MiB; dimensions are at most 1024 per axis and decoded RGBA storage at most
4 MiB. Results are downsampled without upscaling to a longest edge of 128 pixels
and do not retain the source file or input string. At most four imports may be
outstanding in one application generation; excess calls return `ImageImportBusy`.
This explicit import does not change the relative-path restrictions on image `src`.

### XDG named icons use the system icon themes

```lua
ouro.xdg.icon {
  key = "save", name = "document-save-symbolic", theme = "Adwaita",
  width = 24, height = 24, alt = "Save",
}
ouro.icon { key = "folder", name = "folder", theme = "Adwaita" }
```

`ouro.xdg.icon` is the same widget constructor as `ouro.icon`. A named source
uses `name` instead of `src` or `bytes`; exactly one source is required. `theme`
is an icon-theme directory name, not an Ouro color theme. It defaults to
`hicolor`; this first version does not discover the desktop's selected theme.
Names are exact, extensionless icon names, not file paths. No implicit name
shortening or symbolic-to-regular fallback is performed.

Lookup follows the [XDG Icon Theme lookup algorithm](https://specifications.freedesktop.org/icon-theme-spec/latest/):
read the first `index.theme` across search roots, search `Directories` and
`ScaledDirectories` for matching logical size and scale, then choose the closest
physical size within that theme. Any matching name in the selected theme wins
over inherited themes, even when a parent has a closer size. Parents are searched
recursively in order with cycle protection, followed by `hicolor`, then unthemed
icons. PNG precedes SVG within a directory; legacy XPM is not supported.

Search roots are `$HOME/.icons`, `$XDG_DATA_HOME/icons` (default
`$HOME/.local/share/icons`), each `$XDG_DATA_DIRS/icons` (default
`/usr/local/share/icons` and `/usr/share/icons`), then `/usr/share/pixmaps`.
Relative environment paths are ignored. Installed theme symlinks are supported;
the restrictions on application-relative `src` paths are unchanged.

Named icons keep their original colors unless the name ends in `-symbolic`,
which uses the inherited foreground as an alpha-mask tint. Explicit `tint`
overrides either behavior. Symbolic semantic color classes are not interpreted.
The default logical size is 24×24. Lookup uses the larger declared dimension,
rounded up, and output scale rounded up to an integer; SVG rasterization still
uses the actual output scale. Missing icons paint nothing and retain their size.

Resolution, reading, and decoding run on the image worker after build commit.
The cache includes name, theme, lookup size/scale, and raster options. Changing
these properties reconciles normally. Filesystem theme changes are not watched:
cached results, including misses, persist until eviction or application source
reload. No desktop settings subscription or icon-cache binary parsing is included.

Native Zig consumers can use `ourokit.xdg.icons.SearchPaths.init(allocator, environ)`
and `ourokit.xdg.icons.lookup(allocator, io, roots, request)` directly. Lookup is
synchronous and returns an owned path or `null`; callers free the path. The async
image service accepts `.icon = .{ .name = "folder", .theme = "Adwaita" }` as a
source. Set its borrowed `icon_roots` before requesting icons and keep those paths
alive until the service is drained and destroyed. The application and Storybook
runners configure these paths automatically.

See `examples/xdg-icons.lua` for light/dark, color, symbolic, and missing states.
It requires an installed Adwaita theme; icons are not bundled with the example.

### Scrollbars and retained scroll state

Both `ouro.scroll` and `ouro.virtual_list` accept `scrollbar=true`,
`on_scroll=function(metrics) ... end`, and `scroll_to={offset=..., token=...}`.
The native viewport owns the offset; callbacks observe it rather than supplying
a controlled offset on every render.

```lua
local request = ouro.signal(nil)
local position = ouro.signal(0)
local token = 0
-- Inside a content function:
return ouro.column {
  key = "page", gap = 12,
  ouro.button { key = "top", label = "Back to top", on_press = function()
    token = token + 1
    request:set({offset = 0, token = token})
  end },
  ouro.text { key = "position", text = "Offset: " .. position() },
  ouro.scroll {
    key = "results", flex = 1, scrollbar = true,
    scroll_to = request(),
    on_scroll = function(metrics) position:set(metrics.offset) end,
    ouro.column { key = "rows", children = result_rows },
  },
}
```

The optional scrollbar reserves a **12-logical-pixel gutter** on the right
(vertical) or bottom (horizontal), including when content fits. Children receive
the remaining cross-axis constraint, so wrapped text and variable virtual rows
measure at their actual content width. The themed thumb is proportional to the
visible fraction, with a 24-pixel minimum capped at the viewport length; fitting
content has no thumb. Dragging preserves the grab position and captures motion
outside the viewport. Clicking the track pages one viewport. Wheel, finger
momentum, and virtual-list keyboard navigation use the same retained offset.
Paint transforms scale the scrollbar and its input coordinates together.

`on_scroll` receives a new table with `axis` (`"vertical"` or `"horizontal"`),
`offset`, `viewport`, `content`, and `max_offset`. Extents and offset are logical
units along the scrolling axis. It runs at the deferred task safe point after
initial layout and whenever these metrics change, including resize, reveal,
and content shrink. Changes before a safe point may coalesce. An unchanged
rebuild or callback replacement does not notify again; removing and re-adding
the subscription, or accepting a source reload, publishes an initial snapshot.
Mutating the callback table does not change native state. Updating a signal
from the callback is supported, but applications must avoid feedback that
continually changes content size or issues new requests.

`scroll_to` is a one-shot, nonanimated request, applied after layout and clamped
to `0..max_offset`. Supply a finite nonnegative `offset` and a positive integer
`token`; unknown fields are rejected. Change the token to issue another request,
even for the same offset. Keeping a token unchanged does not undo manual
scrolling, even if its offset field changes. Setting the request to `nil` clears
it so it can be issued again. Do not combine it with `ensure_visible`.
Virtual lists mount the requested neighborhood without enumerating all rows;
variable-row extents still use estimates for unmeasured content and retain their
existing anchor correction. These options do not add horizontal virtual lists,
two-axis scrolling, or selection state. Development inspection exposes the same
`scroll_metrics` alongside `scroll_offset`.

See `examples/scroll-storybook.lua` for both axes, request playback, and a
10,000-row virtual viewport.

### Bringing a selection into view

Set `ensure_visible` on a viewport to reveal an application-selected child
without computing offsets or changing keyboard focus:

```lua
ouro.scroll {
  key = "results",
  ensure_visible = "rows/" .. selected_key(),
  ouro.column { key = "rows", gap = 8, children = result_rows },
}
```

For `ouro.scroll`, the target is a slash-separated descendant widget-key path
relative to the scroll (not a window-wide path). Include intermediate container
and component keys, as with other semantic paths. Layout supplies the child's
actual position and size, including padding and gaps. Both vertical and
horizontal scroll axes are supported. Only this viewport scrolls; this is not
a request to reveal through every nested scroll ancestor. A missing target is
a no-op; empty paths/segments, ambiguous paths, and non-string values are errors.

For `ouro.virtual_list`, use a positive **1-based index** or an **item key**.
A key requires `item_index(key)` so revealing an unmounted row never scans the
entire data set. A positive index beyond `item_count`, or a key for which
`item_index` returns `nil`, is a no-op (including an empty list). Zero, negative
or fractional indices, empty keys, and other value types are errors.

Both forms move only far enough to fit the target in the viewport and clamp to
the content bounds. A target larger than the viewport aligns its leading edge.
The request is re-evaluated when the target or its geometry changes, including
viewport resizing; unchanged declarations do not undo manual wheel or keyboard
scrolling. Set `nil` to clear the request. It does not select or focus the row,
and it does not animate. Variable-height virtual rows use estimates to mount
the target, then correct the reveal using measured layout.

A launcher can keep its search field focused, update `selected` from its
Up/Down handler, and render all results through one virtual list:

```lua
local selected = ouro.signal(1)
-- Inside content; results is the application's complete ordered result set.
return ouro.column {
  key = "launcher", gap = 12,
  ouro.text_input { key = "search", default_text = "", placeholder = "Search", autofocus = true },
  ouro.virtual_list {
    key = "results", flex = 1,
    item_count = #results,
    item_key = function(i) return results[i].id end,
    estimated_item_height = 40,
    ensure_visible = selected(),
    render_item = function(i)
      return ouro.text { key = "label", text = results[i].label }
    end,
  },
}
```

The flex layout determines the list's remaining height. No `first`/`capacity`
window or sum of search-field, heading, tab, and gap heights is needed.

### Virtual lists

Large, generic vertical viewports use `ouro.virtual_list`:

```lua
ouro.virtual_list {
  key = "people",
  item_count = 10000,
  item_key = function(index) return "person-" .. index end,
  item_height = 40,
  render_item = function(index)
    return ouro.text { key = "name", text = "Person " .. index }
  end,
}
```

Provide exactly one positive sizing field: `item_height` for fixed rows or
`estimated_item_height` for variable rows. `width` and `height` accept a number
or `"fill"` and default to `"fill"`; `flex` is also supported. Item keys must be
stable, unique, non-empty strings. The list key, item key, and keys within the
returned description form each row's semantic target path.

`item_key` and `render_item` are lazy: builds evaluate the visible rows plus a
two-row buffer on each side, with additional key lookups for the previous
anchor, mounted measurements, focused row, and `ensure_visible` target. A fresh
root render does not scan all items. Fixed-height offsets use arithmetic, not
an item-sized table.
Variable rows use a sparse measurement index; unseen rows use the estimate,
while measured native heights are at least one pixel. Native scrolling retains
offscreen measurements; data/provider or width changes discard them, keeping
mounted heights provisionally until layout measures them again. Measurement
updates are staged so a failed build preserves the committed index.

For insertions or reordering, optionally provide `item_index(key)`, returning
the key's current 1-based integer index, or `nil` if removed. It must agree with
`item_key(index)`. For example, an application model can maintain
`positions[key]` alongside its ordered records:

```lua
item_key = function(index) return records[index].id end,
item_index = function(key) return positions[key] end,
```

The list uses this lookup to preserve a moved scroll anchor and keep a focused
row mounted outside the viewport. Without it, a previous anchor or focused row
is retained only if its key remains at its previous index. A removed focus row
unmounts normally. Signals read by either key provider invalidate the list's
key reader; row-provider signals invalidate its separate row reader.

A clean retained list can reuse its complete plan when its declaration,
enclosing renders, readers, geometry, measurements, and focus pin are unchanged.
Explicit invalidation, changed root arguments or callback, and executed
enclosing renders force bounded provider evaluation even if they return the
same declaration. Fresh closures are not assumed to have unchanged results.

Migration from the eager implementation: add `item_index` if data can move and
must retain anchor/focus identity. Keys must still be globally unique, but
duplicate and invalid keys are checked only among keys visited in a build;
unseen invalid data no longer fails the initial build. Do not rely on providers
running for every item or use them for whole-model validation.

The viewport handles wheel scrolling and Up/Down, Home/End, and Page Up/Page
Down. It is a generic viewport, not a listbox: it has no selection model. Data
providers are synchronous; virtual lists do not perform asynchronous loading.
Rows unmount outside the viewport, so durable per-row state belongs in external
application state keyed by `item_key`, rather than in the row description.
Applications provide stable local keys but no numeric IDs or parent links.
Their visual defaults come from generated Radix-derived semantic tokens and
documented component recipes, with optional inherited Lua theme overrides. Buttons are
intrinsically sized with Radix Themes size-2 geometry: 32-pixel height,
12-pixel horizontal padding, 4-pixel radius, medium label face, the solid accent
recipe unless `variant`/`tone` choose another, and one-line ellipsis. A button can set `height = "auto"` to size to its
content instead of the themed control height. This also works with custom
content and nested buttons: the nearest button handles the click, so a card
can own its background action while a nested dismiss button remains separate.
Set `hover` and `pressed` equal to `background` to keep the surface unchanged
under the pointer; a positive `border_width` and `focus` color retain visible
keyboard focus. Text inputs fill their bounded parent width by
default and use the corresponding 32-pixel height, 8-pixel inset, 4-pixel
radius, surface, and input-border roles; focus replaces that border color with
`ring` rather than adding an outline. The Wayland example exercises this actual
Lua-build path for both windows. Both mounted
window owners also read one shared signal, proving dependency identity across
separate per-window registries sharing one VM.

Boxes and buttons accept `on_interaction_change(active, anchor)`. It reports changes
to the combined pointer-within or keyboard-focus-within state, including
descendants, without taking focus or consuming their clicks. Moving between
children does not toggle the state; losing window keyboard focus stops counting
its retained focus target. Each new observed instance emits its initial state.
Callbacks run as tasks, not during native input dispatch, and retained instance
state survives callback replacement. Use a component-owned signal to reveal
controls while active, with a stable placeholder if layout must not move.
The optional second argument is an opaque native-popup anchor when active and
visible; existing one-argument callbacks are unchanged. It carries geometry
and lifetime identity, not permission to activate a window or grab input.

Buttons also accept `on_cancel()`. Escape from that button or a descendant
invokes the nearest such handler and returns focus to its button before the
callback runs. This lets a disclosure close its child actions without losing
keyboard focus. Text-input command bindings take precedence over ancestor
cancellation. Omitting `on_cancel` leaves Escape unhandled by that button.

For the benchmark slice, `ouro.button` owns composition and input policy while
lowering to only Box and Text render objects. Button is not a render object. Its
stable string key is normalized into domain-separated semantic IDs; duplicate
or colliding IDs are rejected by snapshot validation rather than silently
aliasing instances. A language-neutral widget registry retains enabled,
hovered, pressed, and armed state across reconciliation. Enabled Buttons
activate on left-button press; release clears the pressed visual regardless of
the pointer's current position. CQE and Wayland
dispatch still only enqueue state; callbacks spawn Lua tasks during the task
phase. Text nodes pass valid UTF-8 through paragraph itemization, bidi, fallback
shaping, and width-dependent wrapping.

Instances also retain focusability and deterministic descriptor traversal
order. A window-local focus manager holds only a generation-checked instance
handle. Tab and Shift-Tab move through enabled controls with wrapping during the
input safe point. Pointer presses request logical focus without showing a ring;
keyboard navigation and activation reveal it. Borderless buttons and selection
items draw their ring inside their bounds without changing layout. Text input
focus changes its existing border to the generated focus color without affecting
layout. Inputs with `border_width = 0` remain borderless on focus, allowing an
application-owned outer field to provide the chrome; the caret remains visible.
Enter and Space activate on key press and
enqueue the existing Button callback task;
Wayland dispatch never calls Lua directly.

Actionable widgets invoke their semantic callback on primary-button or
activation-key press, never on release. Release only ends transient pressed,
pointer-capture, or drag state. Low-level pointer bindings remain raw event
streams and therefore receive both press and release events.

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

Printable `wl_keyboard` events also insert text when text-input-v3 is available:
the protocol being advertised does not mean an input method is supplying
commits. Active preedit and command modifiers suppress direct text insertion.

An input-method activation belongs to one retained editor session. Moving focus,
losing keyboard or text-input surface focus, disabling or making the field
read-only, replacing its controlled value, or removing it revokes that ownership.
Uncommitted preedit is discarded, not committed, and its undo group is closed;
cancellation does not alter committed text or erase undo history. Queued batches
cannot follow focus to another field or a later activation of the same field.
Older `done` serials within the current activation still apply edits as required
by text-input-v3, but do not publish new protocol state.

Primary-button text selection stores its bidi-aware anchor in the retained edit
session. The input router keeps delivering motion to the captured instance even
when hover moves over another instance or leaves the window; paragraph hit
testing clamps that motion to a valid line and caret. Release clears the gesture
without changing the selected anchor/extent. Gesture state never enters the
render object or scene.

Double-click selects a Unicode word, whitespace, or punctuation segment;
dragging after it extends by whole segments in either direction. Triple-click
selects the entire single-line value, or a logical hard line (including its LF)
in a multiline field; dragging then extends by whole logical lines. Shift-click
extends from the existing directional anchor. While a captured pointer rests beyond the
viewport, a demand-driven native timer scrolls and extends selection without
requiring more motion events. It stops at the content limit or when selection
ends. Active composition owns selection instead of accepting pointer edits.

Enabled text inputs, including read-only selectable fields, request an I-beam
pointer. Selection dragging retains it until release; other widgets and disabled
inputs request the default pointer. Rebuilds update the shape even without pointer
motion. The Wayland adapter uses `cursor-shape-v1` with the latest pointer-enter
serial and recreates its device when pointer capability returns. Compositors
without this optional protocol keep their existing cursor behavior.

The focused editable caret blinks on monotonic deadlines without triggering Lua
rebuilds. Typing, navigation, pointer selection, and input-method updates restart
the visible phase; unrelated rebuilds do not. Composition keeps its caret steady,
and selection, read-only inputs, or loss of native keyboard focus suspend blink
wakeups. Native keyboard focus loss also hides the caret. Horizontal caret reveal
is independent of blink visibility. `WindowRuntimeConfig.caret_blink_interval_ns`
sets each phase duration (500 ms by default); zero disables blinking.

## Contextual commands and custom input

`ouro.box` is also an input scope. `focusable = true` opts a custom control into
Tab traversal and primary-click focus; `enabled = false` excludes it from focus.
Wrap stock controls in a box to observe or intercept their input. Recipes do not
implicitly forward these properties. Local `commands` are private Lua callbacks;
only `ouro.app.actions` explicitly exposes schema-backed external actions. No
shortcut name resolves into the external action catalog.

```lua
ouro.box {
  key = "workspace", focusable = true,
  commands = {
    save = function() save_document() end,
    comment = function() comment_selection() end,
  },
  shortcuts = { ["Ctrl+S"] = "save", ["Ctrl+K Ctrl+C"] = "comment" },
  on_key = {
    keys = { "Left", "Right" }, states = { "pressed", "repeated" },
    propagate = false,
    handler = function(event) move_custom_selection(event.key) end,
  },
  on_pointer_capture = {
    kinds = { "press" }, button = 272,
    propagate = true,
    handler = function(event) record_click(event.x, event.y) end,
  },
  -- Child descriptions...
}
```

`on_key_capture`, `on_key`, `on_pointer_capture`, and `on_pointer` each accept
one table with a `handler` function and an explicit boolean `propagate`.
**Propagation is declarative, not a callback-return veto.** Native routing
checks filters and the committed `propagate` value without running Lua. A
matching `propagate = false` registration consumes the event; its return value,
error, or yield cannot change that decision. Callback side effects happen later.
Change a signal and rebuild to change future filters or propagation policy.

Keyboard filters are `keys` (1–16 exact logical chords using the editor chord
syntax above) and `states` (`pressed`, `released`, `repeated`). Pointer filters
are `kinds` (`press`, `release`, `motion`, `enter`, `leave`, `axis`) and optional
Linux input-event `button` code. Filters combine with AND; values within an
array combine with OR. Omitted filters match all; an explicit array must be
nonempty and dense. `button` only matches press/release events, never motion.
Unknown filter fields and invalid values reject the build instead of becoming
catch-all handlers. `enter`/`leave` describe hit-target transitions, including
transitions between descendants. Pointer capture after a press retains the
original target through motion and release even when the press was consumed.

`on_pointer_down_outside` is a separate Box hook with required `handler` and
`propagate`, plus an optional `button` filter. It only observes pointer presses,
so it accepts no `kinds`, `keys`, or `states`. Before normal capture/default
dispatch, visible outside listeners run in reverse logical child order, children
before parents. A hit on the listening Box or any logical descendant—including
a floating descendant—is inside and does not invoke it. Modal boundaries limit
eligible listeners to the modal subtree, but those listeners can observe a press
outside the modal. `propagate=false` consumes the press without activating the
underlying control, even if Lua ignores the dismissal request. Dismissal itself
is still a Lua state change; returning a value never closes an overlay.

Each callback receives a fresh, owned event table:

- Keys: `{kind="key", key="Left", state="pressed", phase="bubble",
  modifiers={control=false, shift=false, alt=false, super=false}}`. Key names
  use `A`–`Z`, `F1`–`F12`, `Enter`, etc.; unidentified keys use `""`.
- Pointers: `{kind="press", x=12, y=24, button=272, phase="capture"}`.
  Positions are window-logical coordinates, not target-local. `button` is zero
  when inapplicable. Axis events also include `axis` (`horizontal` or `vertical`)
  and signed logical-pixel `delta`.

There is no text, Unicode value, raw keycode, input serial, or IME payload in
these tables. Use the editor's text callbacks for text. Focused masked/secret
editors and active IME preedit bypass **all** generic key hooks and shortcuts,
including releases and Tab; stock protected editing/navigation still runs.
Repeats and releases of a private press remain withheld if focus or composition
changes before the key is released.

Dispatch order is capture from the outermost scope to the target, shortcut
resolution from the focused target outward, bubble from target outward, then
stock editing/selection/activation. A consumed event skips later phases and
defaults. A nonmatching filter does nothing. Modal focus boundaries fence every
phase: outside ancestors cannot capture or resolve commands. Without focus,
the window's single-child wrapper chain is eligible up to its first branch;
put window-wide shortcuts on the outer content box, not an unfocused sibling.
Native release cleanup always runs even if consumed, so existing buttons and
selection/range/split drags cannot remain pressed.

Shortcut values must name functions in the **same box's** `commands` table.
The nearest eligible scope with a match wins. Exact modifiers matter, and only
initial presses advance sequences or invoke commands. Space-separated sequences
contain at most four strokes. Distinct sequences may share prefixes, but exact
duplicates and a complete shortcut that is also another's prefix in the same
box reject the build. Partial sequences consume their strokes without invoking
a command. Each stroke must be dispatched less than one monotonic second after
the previous stroke; expiry is checked before the next input dispatch. Escape
cancels a pending sequence. A mismatch discards the prefix and retries that key
as fresh input; consumed prefix strokes are not replayed. Focus/modal changes,
keyboard leave, pointer press, IME input, or committed binding replacement
(including reload) reset pending sequences. Repeats do not extend expiry.

Handlers and commands run as ordinary instance-scoped scheduler tasks. They
may yield; later handlers/defaults never wait for them. Initial executions are
queued in routing order; continuations follow ordinary scheduler readiness.
Cancellation and reload use existing callback ownership. Real press provenance
is available only to the callback's first execution; it expires on yield and
is not inherited by spawned tasks. Synthetic development/playback input grants
no real-input capability, and a multi-stroke command uses only the final press.
Local commands are neither discoverable nor invocable through external tools
unless the application separately declares an action.

### Commands that outlive their invoking UI

Declare durable async work once with `ouro.app_command(fn)`. It returns an
ordinary function usable in `commands`, `on_press`, or a palette's selection
callback. Invoking it from a running task starts `fn` in application scope using
`ouro.spawn_app`, forwards all arguments (including nils), and returns nothing:

```lua
local save = ouro.app_command(function()
  palette_open:set(false)
  save_document() -- May yield after the palette's widget scope retires.
end)
-- Reuse save in commands = { save = save }, shortcuts = { ["Ctrl+S"] = "save" },
-- or on_press = save. A palette may simply call its selected command.
```

Create the wrapper during declaration, not on every invocation. Wrapping is not
execution: candidate evaluation may create it but may not invoke it. Work
survives widget/window dismissal, **not source-generation retirement or app
shutdown**. Ordinary callbacks and `ouro.spawn` remain scope-owned and cancel
normally. This is fire-and-forget, not a synchronous function call or a way to
return results; publish results through application state. Arguments are retained
Lua values, not deep copies. Like `spawn_app`, the new task does not inherit real
press provenance or popup/drag input capabilities. Acquire any required input
capability in the originating callback before spawning.

Headless retained layout, software glyph rendering, deterministic scene
logging, Button interaction state tests, and semantic snapshots are available
now. The semantic snapshot is a validated, allocation-free-after-init retained
tree of groups, text, and Buttons. Lua text is copied into an inactive buffer
before another Lua API call can collect it, and the buffer becomes visible only
when the surrounding build transaction commits. A future design-system gallery
will expand this path without requiring Wayland or Vulkan.
