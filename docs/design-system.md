# Design system

Canonical Ourokit tokens live in `design/tokens`. They use the `ouro` namespace
and contain a deliberately small desktop-oriented foundation plus light and
dark semantic mappings. The semantic vocabulary follows shadcn/ui: background,
card, popover, primary, secondary, muted, accent, destructive, border, input,
ring, and sidebar roles, including the applicable foreground pairs. Components
consume those roles through explicit recipes rather than embedding raw colors
in Lua or renderer code. Repeated component geometry belongs in the foundation;
component-only opacity and composition remain in the component recipe.

`tools/design/generate_tokens.py` validates document shape, namespace, token
name grammar, allowed types, non-negative dimensions, color encoding,
references, duplicate roles, semantic role parity, and reference type
compatibility. It sorts output by canonical names, so identical input always
produces identical Zig. `zig build tokens` validates and rejects a stale checked
in output; `zig build generate-tokens` updates it.

Runtime theme selection chooses one pre-resolved generated `Theme` value. It
does not repeatedly traverse references. Any future Lua representation must be
generated from the same source rather than manually mirrored.

## Widget design guidance

Before adding a widget state, visual role, or design token, consult the current
shadcn/ui base-nova component and theme for the equivalent control. Prefer its
established recipe over inventing a generic semantic token, and keep Ourokit's
public widget and token vocabulary deliberately smaller than shadcn/ui's full
catalog. shadcn/ui is the visual and token reference, WAI-ARIA and React Aria
inform interaction semantics, and Ourokit retains native layout and rendering.
Record intentional behavioral or visual departures here or in the relevant
widget documentation.

The current Button, TextInput, and ListBox intentionally omit shadcn/ui's
additional focus outline: TextInput focus changes the existing border to the
`ring` color, while Button and ListBox rely on non-outline state styling for
now. Button also omits shadcn/ui's one-pixel active translation until Ourokit
has a justified transform/visual-offset primitive. TextInput remains
transparent in both themes; shadcn/ui's dark-only input tint awaits an explicit
theme-mode component recipe rather than a new semantic color.

Exact source/version/license and transformation details are recorded in
`design/provenance/shadcn-ui.md`. Spectrum 2 informed Ourokit's earlier token
organization and remains attributed in `design/provenance/spectrum-2.md`, but
it is no longer the component or token source of truth.
The canonical typography family is generic `sans-serif`; on Linux the text
service resolves it through Fontconfig so user and system configuration remain
authoritative. Pinned Inter and Noto files are deterministic shaping fixtures,
not production defaults; their source and license provenance are recorded under
`design/provenance`. Component schemas and constructor generation remain future
work.
