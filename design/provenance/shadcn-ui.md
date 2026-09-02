# shadcn/ui provenance

Ourokit's current semantic color vocabulary and initial Button, Input, and
Sidebar Menu Button recipes are informed by shadcn/ui's `base-nova` style and
neutral theme from the `shadcn-ui/ui` main branch (accessed 2026-09-01):
<https://github.com/shadcn-ui/ui>. The source is offered under the MIT License:
<https://github.com/shadcn-ui/ui/blob/main/LICENSE.md>.

This is an Ouro-owned native implementation, not a source import. Ourokit maps
the reusable shadcn/ui semantic roles into canonical JSON, converts the neutral
theme's OKLCH values to checked-in sRGB RGBA values, and implements selected
component geometry and state recipes with Ourokit's own layout, text, input,
scene, and renderer layers. It does not embed React, Tailwind CSS, Radix UI, or
shadcn/ui component source.

Behavioral semantics are reviewed separately against WAI-ARIA and React Aria.
Ourokit intentionally keeps a smaller widget catalog and records visual or
behavioral departures in `docs/design-system.md` rather than silently copying
the full upstream catalog. Future changes derived from a newer upstream state
must update this record and be reviewed before regenerating tokens.
