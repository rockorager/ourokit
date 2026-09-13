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
does not repeatedly traverse references. Lua's `ouro.tokens` catalog reflects
the generated Zig data, so token names and values have the same source of truth.

## Lua token catalog

After `local ouro = require('ouro')`, application and Storybook code can use:

| Namespace | Contents |
| --- | --- |
| `ouro.tokens.foundation` | `typography_1`–`9`, `typography_family`, `line_height_1`–`9`, `spacing_1`–`9`, `radius_1`–`6`, `border_width_default`, `border_width_strong` |
| `ouro.tokens.palette` | `black`, `white`, `transparent`; `light` and `dark` color families (including `_alpha` families); `overlay.black` and `overlay.white` |
| `ouro.tokens.light`, `ouro.tokens.dark` | Semantic colors such as `primary`, `foreground`, `background`, and `sidebar` |

Names match the generated Zig API. Each palette family contains `step_1` through
`step_12`, for example `ouro.tokens.palette.dark.indigo.step_9`. Metrics are
numbers in logical pixels, the font family is a string, and colors are
`#RRGGBBAA` strings accepted by existing theme and widget properties.

```lua
local ouro = require('ouro')
local f = ouro.tokens.foundation

return ouro.column { key = 'content', gap = f.spacing_3,
  ouro.text { key = 'heading', text = 'Settings', size = f.typography_5 },
  ouro.button { key = 'save', label = 'Save', radius = f.radius_2 },
}
```

The tables are Lua-owned copies of the fixed catalog, not a live resolved theme
or a way to change native defaults. Treat them as constants. Assigning
`ouro.tokens.light.primary` to a color prop pins that color just like a literal;
it does not follow host appearance or enclosing theme overrides. Omit color
overrides to retain normal theme following. Token exposure does not add new
widget properties: for example, line-height tokens are available as numbers,
but do not introduce a `line_height` text prop. Existing widget defaults remain
unchanged, including 14px button labels and 16px text.

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
The canonical typography family is generic `sans-serif`, backed by bundled
Source Sans 3. Generic `serif` and `monospace` select bundled Source Serif 4
and Source Code Pro. Regular text uses Regular and emphasized controls use
Medium 500 (Source Serif's absent static Medium falls back to Regular 400).
Explicit Semibold 600 remains available. Other explicit family names and missing-character fallback use
Fontconfig on Linux. Source font revisions and licenses are recorded in
`design/provenance/source-fonts.md`. Inter remains a shaping-test fixture;
Noto Sans Arabic supplies deterministic complex-script fallback in snapshots.
Component schemas and constructor generation remain future work.
