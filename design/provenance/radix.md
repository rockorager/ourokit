# Radix design provenance

Ourokit's current visual foundation and component recipes are informed by
Radix Themes 3.3.0, tag `v3.3.0`, accessed 2026-09-01:
<https://github.com/radix-ui/themes/tree/v3.3.0>. Radix Themes is offered under
the MIT License:
<https://github.com/radix-ui/themes/blob/v3.3.0/LICENSE>. Ourokit uses its
default 100% spacing, medium radius,
typography, Indigo accent, and Slate gray conventions as an Ouro-owned native
implementation rather than importing React or CSS component source.

The raw palette is imported from `@radix-ui/colors` 3.0.0. The pinned npm
tarball has SHA-512
`1543ac181907ad827009212d5910887d06d91bbab57ba0e0c4220e7b54944330deffbad75de038eecf320a7e9fb93350023d59ab8a13162f588e9df0cc495cc6`
and is offered under the MIT License:
<https://github.com/radix-ui/colors/blob/8a03dad3bc93ea4ed48ce2b70847a3538097e02f/LICENSE>.
`tools/design/import_radix_colors.py`
accepts its extracted package directory and preserves every public sRGB light,
dark, and alpha scale in `design/tokens/palette.json`. Display-P3 variants are
excluded until Ourokit has an explicit wide-gamut rendering contract.

Generated semantic themes map reusable roles onto those raw scales. Components
consume semantic roles; the raw palette remains an explicit escape hatch for
application-specific color. Behavioral semantics are reviewed separately
against WAI-ARIA and React Aria, and Ourokit retains its own layout, text,
input, scene, and renderer implementations.
