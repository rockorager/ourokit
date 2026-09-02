# Design system

Canonical Ourokit tokens live in `design/tokens`. They use the `ouro` namespace
and have three deliberate layers: Radix Themes spacing, radius, and typography
foundations; the complete sRGB Radix Colors light, dark, and alpha scales; and
Ourokit semantic light/dark mappings. Components consume semantic roles through
explicit recipes rather than embedding raw colors in Lua or renderer code. The
raw `palette` namespace is an escape hatch for application-specific graphics,
status presentation, and other cases that do not have a reusable semantic role.
Component recipes must not use it to bypass semantic theming.

`tools/design/generate_tokens.py` validates document shape, namespace, token
name grammar, allowed types, non-negative dimensions, color encoding,
references, duplicate roles, semantic role parity, and reference type
compatibility. It sorts output by canonical names, so identical input always
produces identical Zig. `zig build tokens` validates and rejects a stale checked
in output; `zig build generate-tokens` updates it.

`tools/design/import_radix_colors.py <package-directory>` reproducibly imports
the pinned `@radix-ui/colors` package into `palette.json`. Display-P3 values are
excluded until Ourokit has an explicit wide-gamut color pipeline; native sRGB
values are preserved directly rather than converted from P3.

Runtime theme selection chooses one pre-resolved generated `Theme` value. It
does not repeatedly traverse references. Any future Lua representation must be
generated from the same source rather than manually mirrored.

## Widget design guidance

Before adding a widget state, visual role, or design token, consult the current
Radix Themes component and token source for the equivalent control. Prefer its
established recipe over inventing a generic semantic token, and keep Ourokit's
public widget vocabulary deliberately smaller than Radix Themes' catalog.
Radix Themes is the visual reference, WAI-ARIA and React Aria inform interaction
semantics, and Ourokit retains native layout and rendering. Record intentional
departures here or in the relevant widget documentation.

The current Button and TextInput use Radix Themes' default size-2 geometry and
medium radius. TextInput focus intentionally changes its existing border to the
`ring` color instead of adding Radix Themes' inset outline; Button and ListBox
also omit extra focus outlines for now. Button pressed state uses the Radix
hover color but omits its brightness/saturation filter until Ourokit has a
justified color-filter primitive.

Radix Themes has no vertical sidebar row. Ourokit's sidebar ListBox is a
documented adaptation of Radix scale semantics: transparent idle rows, gray
step 3 for hover, gray step 5 plus medium text for selection, and no border.

Exact source/version/license and transformation details are recorded in
`design/provenance/radix.md`. Spectrum 2 and shadcn/ui informed earlier design
iterations and remain attributed under `design/provenance`, but neither is the
current source of truth.
The canonical typography family is generic `sans-serif`; on Linux the text
service resolves it through Fontconfig so user and system configuration remain
authoritative. Pinned Inter and Noto files are deterministic shaping fixtures,
not production defaults; their source and license provenance are recorded under
`design/provenance`. Component schemas and constructor generation remain future
work.
