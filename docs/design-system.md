# Design system

Canonical Ourokit tokens live in `design/tokens`. They use the `ouro` namespace
and contain a deliberately small desktop-oriented foundation: spacing,
component heights, radii, borders, focus geometry, workflow icon sizes,
typography sizes, palette values, and light/dark semantic mappings for surface,
content, border, accent, focus, selection, and status roles.
Accent defaults include distinct idle, hovered, and pressed semantic mappings;
widget policy selects among those pre-resolved values rather than embedding
interaction colors in Lua or renderer code.

`tools/design/generate_tokens.py` validates document shape, namespace, token
name grammar, allowed types, non-negative dimensions, color encoding,
references, duplicate roles, semantic role parity, and reference type
compatibility. It sorts output by canonical names, so identical input always
produces identical Zig. `zig build tokens` validates and rejects a stale checked
in output; `zig build generate-tokens` updates it.

Runtime theme selection chooses one pre-resolved generated `Theme` value. It
does not repeatedly traverse references. Any future Lua representation must be
generated from the same source rather than manually mirrored.

Spectrum 2 informed category selection but was not imported wholesale. Exact
source/version/license and exclusions are recorded in
`design/provenance/spectrum-2.md`. Ourokit uses no Adobe marks or Adobe Clean.
The canonical typography family is generic `sans-serif`; on Linux the text
service resolves it through Fontconfig so user and system configuration remain
authoritative. Pinned Inter and Noto files are deterministic shaping fixtures,
not production defaults; their source and license provenance are recorded under
`design/provenance`. Component schemas and constructor generation remain future
work.
