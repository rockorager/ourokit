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

### Deriving a color with alpha

Use `ouro.color.with_alpha(color, alpha)` instead of slicing or appending to a
token string:

```lua
local tint = ouro.color.with_alpha(ouro.tokens.dark.background, 0.3)
return ouro.box { key = 'tint', background = tint, width = 'fill', height = 'fill' }
```

The helper accepts the same `#RRGGBB` or `#RRGGBBAA` colors as theme and widget
properties (hex digits are case-insensitive). It returns a lowercase
`#rrggbbaa` string, preserving straight-alpha sRGB channels and **replacing**
any existing alpha, not multiplying it. `alpha` must be a finite Lua number
from 0 (transparent) to 1 (opaque). It is rounded to the nearest 8-bit value,
with half steps rounded up: `0.3` becomes `4d`, and `0.5` becomes `80`.
Invalid colors, alpha values, or argument counts raise a Lua error; values are
not clamped and numeric strings are not coerced.

The result is a new color value accepted anywhere a color string is accepted.
The source token is unchanged, and the derived value remains fixed rather than
following later theme changes. This changes a color's alpha, not the opacity
of a widget subtree.

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
`ring` color instead of adding Radix Themes' inset outline. Borderless buttons
and selection items use a 2-pixel keyboard focus ring on their inner edge, so it
does not bleed into surrounding padding or get clipped at pane edges. Pointer
focus does not show this ring. Button pressed state uses the Radix
hover color but omits its brightness/saturation filter until Ourokit has a
justified color-filter primitive.

Buttons support Radix Themes' solid, soft, surface, and ghost variants in
accent, neutral, and destructive tones. Outline and classic are omitted to
keep the vocabulary small; surface covers the bordered case. The recipes use
these semantic roles:

| Tone | Solid (idle, hover) | Soft/ghost steps (3, 4, 5) | Text | Surface border |
| --- | --- | --- | --- | --- |
| Accent | `primary`, `primary_hover` | `accent`, `accent_hover`, `accent_selected` | `accent_text` | `accent_border` |
| Neutral | `foreground`, `muted_foreground` | `secondary`, `secondary_hover`, `secondary_selected` | `secondary_foreground` | `input` |
| Destructive | `destructive`, `destructive_hover` | `destructive_subtle`, `destructive_subtle_hover`, `destructive_subtle_selected` | `destructive_text` | `destructive_border` |

Soft uses steps 3/4/5 for idle, hover, and pressed. Ghost is transparent and
uses steps 3/4 for hover and pressed. Surface sits on the `surface` role with a
1-pixel step 7 border, and uses steps 3/4 for hover and pressed. Retained
button state recolors only the background, so surface hover departs from
Radix: Radix strengthens the border from step 7 to 8 instead. Surface uses the
`surface` background for every tone rather than per-accent surface colors.
Neutral solid is Radix's high-contrast gray: step 12 fill, step 11 hover, and
background-colored text. Neutral soft and surface text also use high-contrast
step 12 so secondary actions such as Cancel stay readable. Neutral ghost keeps
Radix's step 11 text for low-emphasis chrome such as tab close buttons. The
accent and destructive soft steps are opaque for accent (the existing roles)
and alpha for destructive (new roles), matching their Radix scales on the
default background.

Theme-wide `widgets.button` colors apply only to solid accent, the original
default. This keeps an app's primary-button styling from recoloring neutral
chrome. Custom button content inherits the variant foreground and label size,
so icons and text follow enabled, disabled, and tone changes.

Tabs follow Radix Themes' base tab list at size 2: 40-pixel intrinsic
triggers, gray step 11 idle text, step 12 hover and active text, medium
active weight, and a 2-pixel accent indicator (`primary`, Radix
`accent-indicator`) at the trigger's bottom edge. The list's gray step 5 inset
shadow becomes a `separator` using `border` (step 6) under a horizontal scroll
strip. Hover fills the whole trigger with `secondary` rather than Radix's
inset inner pill, because retained option state recolors the trigger box.

The Select trigger is a neutral surface button with a left-aligned value and a
trailing 16-pixel chevron icon, matching Radix's surface select trigger.
Spinbox steppers are square neutral soft buttons. Tab close buttons are
24-pixel neutral ghost buttons with a 14-pixel cross icon. The built-in icons
are path-only SVGs tinted by the button foreground.

Disabled buttons use opaque Slate step 5 backgrounds and Slate step 11 text
instead of faint alpha colors. This keeps button labels readable (at least
4.5:1 contrast in both default themes) while the neutral fill distinguishes
them from enabled primary buttons. The shared `disabled` and
`disabled_foreground` roles also style disabled switch tracks and input text;
application and widget overrides still take precedence. Soft buttons share the
solid disabled fill. Disabled ghost buttons stay transparent, and disabled
surface buttons use `muted` with a `border` edge, like Radix's step 2 fill and
step 6 border.

Switch uses the Radix Themes size-2 surface recipe: a 35×20 logical-pixel
track, 18×18 thumb, 1-pixel inset, and pill radius. Geometry derives from
`spacing_5` and border-width foundations; `controls.radius` can override the
radius, but shared button/input height and border-width defaults do not resize
the switch. The native recipe composes root, track, and thumb Boxes and shares
the retained button press/focus policy without adding a render-object kind.

`switch_track` and `switch_border` map to Slate alpha steps 5 and 8 in light
mode, and 3 and 5 in dark mode. The stronger light-mode values compensate for
the absence of Radix's thumb shadow and keep the off state visible on white.
`switch_thumb` is white and `switch_disabled_thumb` is Slate step 2. Checked
tracks use `primary`, disabled tracks use `disabled`, and focus uses `ring`.
Disabled track outlines retain `switch_border` rather than fading into the fill.
All are inherited semantic colors, including app and nested theme overrides.
The 43×28 hit bounds reserve space for a 2-pixel focus ring and 2-pixel gap,
so parent clips cannot cut off the ring. Focus changes only the root border
color, not layout. A 1-pixel `switch_border` thumb edge replaces shadows and
keeps disabled thumb positions discernible in light mode.
Unlike Radix's focus-visible selector, Ourokit shows it for pointer focus too.
State changes are immediate: this first native recipe omits Radix's animation,
thumb shadows, blend modes, and active filters. Enabled checked borders use `primary`
rather than compositing Radix's gray inset shadow over the accent track.

Radix Themes has no vertical sidebar row. Ourokit's sidebar ListBox is a
documented adaptation of Radix scale semantics: transparent idle rows, gray
step 3 for hover, gray step 5 plus medium text for selection, and no border.

Exact source/version/license and transformation details are recorded in
`design/provenance/radix.md`. Spectrum 2 and shadcn/ui informed earlier design
iterations and remain attributed under `design/provenance`, but neither is the
current source of truth.
The canonical typography family is generic `sans-serif`, resolved through
Fontconfig alongside `serif`, `monospace`, and explicit installed family names.
Regular text requests Regular and emphasized controls request Medium; the user's
Fontconfig configuration chooses the actual faces and fallback order. Production
runners embed no font families. Source CFF, Inter, and Noto Sans Arabic files
remain deterministic test fixtures, with provenance under `design/provenance`.
Component schemas and constructor generation remain future work.
