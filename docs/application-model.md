# Application model

`app` is a small coordinator, not an implementation home. It owns the process
lifetime and orders sibling loop/task/Lua/platform/UI/renderer modules. The
reusable turn coordinator fixes that order in one implementation; current
named no-op UI hooks make the safe-point contract visible without pretending
that retained UI exists.

## Declarative windows

Applications will declare their desired window set rather than imperatively
owning Wayring objects. The intended Lua experience is approximately:

```lua
return ouro.app({
  id = "dev.ouro.example",
  windows = function(context)
    return {
      ouro.window({
        id = "main",
        title = "Example",
        content = view(),
      }),
    }
  end,
})
```

This spelling is illustrative; the cross-language descriptor ABI remains
unfrozen. The native contract is now explicit in `app/windows.zig`:

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

Only mutable native policy is updated in place. Title is the first such field;
initial dimensions apply at creation. A future layer-shell declaration will be
a distinct type rather than a mode bit on an interchangeable generic window.
The concrete reusable multi-window Wayring host now implements this contract.
The example exercises one or two declarative windows without owning protocol
objects itself.

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

Padding, theme, keyed identity, focus, shortcuts, and stateful components are
instance/widget policy, not render-object variants. There will be no universal
generic node and no permanent arbitrary table parser based on repeated string
`type` dispatch.

The eventual component schema should generate Lua constructors, compact Zig
bindings/decoding, Lua language-server types, documentation, and cross-language
validation. The initial milestone deliberately does not freeze that ABI.

Commands live in an authoritative registry independent of the retained render
tree. Entries need stable semantic IDs plus revisioned invocation handles,
scope, title/category/aliases, enabled state and reason, state, argument schema,
shortcut, and destructive/reversible metadata. Contextual widget commands may
register there, but external enumeration never walks render objects.

Headless software rendering and deterministic scene logging are available now.
Semantic snapshots and a future design-system gallery will exercise the same
UI/scene path without Wayland or Vulkan once retained UI exists.
