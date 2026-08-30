# Application model

`app` is a small coordinator, not an implementation home. It owns the process
lifetime and orders sibling loop/task/Lua/platform/UI/renderer modules. Current
named no-op UI phases make the safe-point contract visible without pretending
that retained UI exists.

Future applications declare windows and widget composition in Lua. Normalized
descriptors cross into instance construction; instances own identity,
lifecycle, state, focus, command contribution, and reconciliation. A small
closed render-object set (Box, Flex, Stack, Text, Image, Scroll, TextInput, and
Canvas only when their distinct behavior is demonstrated) owns layout, paint,
clip, and hit testing. Scenes are immutable backend-neutral output.

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
