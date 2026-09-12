# Application model

`app` is a small coordinator, not an implementation home. It owns the process
lifetime and orders sibling loop/task/Lua/platform/UI/renderer modules. The
reusable turn coordinator fixes that order in one implementation. The retained
UI and Wayland example now exercise reconciliation, layout/scene construction,
and frame submission as distinct phases; the general `App` host hooks remain
the integration seam rather than absorbing those implementations.

## Declarative surfaces

Applications declare their desired window set rather than imperatively owning
Wayring objects. The first working application-facing surface is:

```lua
local ouro = require("ouro")

return ouro.app {
  id = "dev.ouro.example",
  actions = {
    Ping = {
      description = "Return a greeting without opening the UI.",
      inputSchema = { type = "object", additionalProperties = false },
      outputSchema = {
        type = "object", properties = { reply = { type = "string" } },
        required = { "reply" }, additionalProperties = false,
      },
      handler = function() return { reply = "pong" } end,
    },
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
Evaluation and parsing failures retain the last valid list. `outputs = "all"` still
expands to stable per-output IDs. Source reload currently requires the same
window ID set, so dismiss transient windows before reloading a source whose
initial state does not declare them.

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
Event handlers such as `on_press` and `on_select` remain callbacks. Ordinary
Lua rendering helpers can return descriptions without owning state. Use
`ouro.component` when a reusable component needs its own mounted state and
signal dependencies:

```lua
local Counter = ouro.component(function(props)
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
clean components reuse their retained descriptions. Native lowering and
reconciliation still consume a complete window snapshot. This is component-level
Lua rebuilding, not property-level bindings or partial native-tree updates.

Children supplied to a component are available as `props.children`. A wrapper
can forward them to a native container without knowing their widget types:

```lua
local Card = ouro.component(function(props)
  return function()
    return ouro.box {
      key = "body",
      padding = 16,
      children = props.children,
    }
  end
end)
```

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

Namespace, output, and surface role are immutable for a retained ID, while
size, layer, anchors, exclusive zone and edge, margins, and keyboard
interactivity update transactionally.

## Application lifetime and UI activation

An application can run without windows. Its entry module declares shared state,
the optional MCP tools and action handlers. `run(context)` initializes
the UI only when requested. Actions and window callbacks share the same Lua VM
and closures; invoking a method never implicitly initializes Wayland.

Omitting `actions` (or using nil) starts no server. `actions = {}` enables
`runtime.status`, `runtime.reload`, `runtime.activate`, `server/discover`, and
`tools/list`. Each action has a description, `inputSchema`, `outputSchema`, and
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

Service applications use `$XDG_RUNTIME_DIR/ourokit/apps/<application-id>`.
Systemd socket activation (`Accept=no`, `FileDescriptorName=mcp`) passes an
already-listening socket through `LISTEN_FDS`. Ourokit loads only the application
declaration and serves requests until `Activate` asks for UI. It never unlinks
the systemd-owned socket. With no connections or tasks, the headless service
exits after 30 seconds; systemd retains the socket for the next request.

Direct `ouroctl run` launches the UI. For a manifest whose well-known socket
already exists, it forwards `Activate` to the owner instead. `ouroctl activate
<application-id>` explicitly activates an installed socket-backed application.
Activation can carry a Wayland activation token; focus remains compositor policy.
Repeated activation does not rerun the UI factory or create duplicate windows.
Closing the last window drains accepted calls/output and exits. Explicit
`ouro.exit(code)` drains stdio output, cancels remaining tasks and exits.
Lua state is process-local, not persistent storage.

Ctrl+C (`SIGINT`) and `SIGTERM` request shutdown through the event loop, cancel
remaining tasks, and remove only the runtime socket owned by the application.
`ouroctl run` exits with status 130 or 143 respectively. Inherited systemd sockets
remain in place. `SIGKILL` and crashes cannot run cleanup; any orphaned socket
still requires explicit removal after confirming no listener owns it.
Native hosts must enter the application runner before starting other threads
so worker threads inherit its signal mask. The runner restores the calling
thread's previous mask after teardown and preserves ignored signal dispositions.

Headless reload validates a fresh declaration without invoking `run`. UI reload
prepares a fresh UI in a candidate source generation and atomically replaces the
active generation only after its windows, schemas and handlers validate.
Reload resets Lua state. Server enablement remains restart-only.

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
small closed render-object set (Box, Flex, Stack, Text, Image, Scroll,
TextInput, and Canvas only when their distinct behavior is demonstrated) owns
layout, paint, clip, and hit testing. Scenes are immutable backend-neutral
output.

The implemented headless render-tree kernel starts with Box, Flex, Stack, and a
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
a direct row or column child. `cross_alignment = "start" | "center" | "end" |
"stretch"` controls the container's cross axis; flex children use tight fitting
and divide the remaining bounded main-axis space according to their factors.
Boxes may opt into generated theme surfaces with `surface = "background" |
"card" | "popover" | "sidebar"`; omitting it leaves the Box transparent.
`width` and `height` accept a non-negative number or `"fill"`; omitted values
remain intrinsic. Optional `min_width` and `min_height` participate in the same
one-way constraints and yield when a parent supplies a tighter maximum.

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
  windows = { ouro.window {
    id = "main", title = "Example",
    content = function()
      return ouro.button { key = "save", label = "Save" }
    end,
  } },
}
```

Resolution order is host appearance → app theme → enclosing `ouro.theme`
overrides → explicit widget props. Nested tables merge field by field; missing
fields inherit. `color_scheme = "light" | "dark"` replaces the inherited color
palette, then explicit `colors` apply; it does not reset typography or metrics.
Colors use the generated semantic token names and `#RRGGBB` or `#RRGGBBAA`.
Unknown theme fields and invalid colors/metrics are errors, not ignored typos.

The standard runner follows [ourosettings](https://github.com/rockorager/ourosettings)'
`appearance.color_scheme` automatically. Omit `theme.color_scheme` to follow the
system; typography, metrics, and individual color overrides still apply. Set
`color_scheme = "light"` or `"dark"` on the app or a nested `ouro.theme` to pin
that palette. Explicit colors remain explicit even when they match the previous
system default.

Startup never waits for the settings daemon. The initial fallback and the
`"default"` preference use the light palette. Changes invalidate existing windows
without remounting their components. New windows and reloaded Lua inherit the
latest snapshot. A daemon disconnect keeps the last known preference and retries
with bounded backoff; no Lua subscription is needed for ordinary theme following.
See [system-appearance.lua](../examples/system-appearance.lua) for a following
window with an explicitly light section.

Native hosts can use `app.appearance.Store`: `current` is a typed `Snapshot`,
`update(snapshot)` publishes changes, and `takeEvent()` returns
`.appearance_changed` with the newest snapshot. Equal updates are suppressed and
multiple pending changes coalesce. `Snapshot.color_scheme` is `.default`,
`.light`, or `.dark`. Pass a process-lifetime store as `app.WaylandRunOptions.appearance`
to supply appearance instead of connecting to ourosettings. The store is not
thread-safe: update it on the owning event-loop thread and wake that loop. The
runner consumes its events at the UI safe point. Its built-in ourosettings
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

`ouro.text_input` accepts `autofocus = true` to focus a newly mounted, enabled
input once (retained rebuilds do not reclaim focus). `on_command(command)` runs
in the owning task scope for unmodified `Enter` (`"submit"`), `Escape`
(`"cancel"`), `ArrowUp` (`"previous"`), and `ArrowDown` (`"next"`). Navigation
may repeat; submit/cancel only fire on the initial press. Commands are withheld
during IME preedit. `on_command` and `on_change` may be used together.

Widget defaults override shared controls/typography values. Explicit widget
fields override those defaults; a text node's existing `size` prop takes precedence
over `font_size`. Font sizes and theme heights must be positive; other metrics
are non-negative logical pixels. A zero border width disables the border,
including its focus-color treatment. A theme does not change widget behavior,
container gaps, application layout, or explicit dimensions.

`typography.family` selects bundled Source Sans 3 (`sans-serif`), Source Serif 4
(`serif`), or Source Code Pro (`monospace`). Exact Source family names also work.
These families do not require Fontconfig. Other names select installed families
through Fontconfig, which also supplies missing-character fallbacks when enabled.
Names are copied, not retained Lua strings; the host caches loaded candidates.
Family overrides require a host font service. Omit the family to retain the
host's fonts: the standard runner defaults to Source Sans 3 with system fallback,
and Storybook uses Source Sans 3 with pinned Noto Sans Arabic fallback.
Explicit-family snapshots can depend on system fonts for fallback characters
or non-bundled families.

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
Options are transparent over their containing surface at rest and retain hover
state across reconciliation. Default options use accent steps 3 and 5 for hover
and selection. `appearance = "sidebar"` instead uses gray steps 3 and 5 plus a
medium selected label for navigation catalogs without introducing a separate
widget.

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
Use an enclosing box for a placeholder surface. Missing dimensions use the loaded
intrinsic size; one declared dimension preserves aspect ratio, subject to parent
constraints. Failed sources remain failed until eviction or source reload.

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

Each build evaluates `item_key` for all items and retains O(N) key and provider
metadata, but calls `render_item` and mounts native nodes only for the visible
rows plus a two-row buffer on each side. Variable rows replace their estimate
with measured native height (at least one pixel), preserving the scroll anchor
by item key as measurements or width change. A focused row remains mounted even
when it moves outside that range.

The viewport handles wheel scrolling and Up/Down, Home/End, and Page Up/Page
Down. It is a generic viewport, not a listbox: it has no selection model. Data
providers are synchronous; virtual lists do not perform asynchronous loading.
Rows unmount outside the viewport, so durable per-row state belongs in external
application state keyed by `item_key`, rather than in the row description.
Applications provide stable local keys but no numeric IDs or parent links.
Their visual defaults come from generated Radix-derived semantic tokens and
documented component recipes, with optional inherited Lua theme overrides. Buttons are
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
input safe point, pointer presses request focus through the same policy, and
Controls currently add no visual focus outline. Text input focus changes its
existing one-pixel border to the generated focus color without affecting layout,
and remains visible through its caret. Enter and Space activate on key press and
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
tree of groups, text, and Buttons. Lua text is copied into an inactive buffer
before another Lua API call can collect it, and the buffer becomes visible only
when the surrounding build transaction commits. A future design-system gallery
will expand this path without requiring Wayland or Vulkan.
