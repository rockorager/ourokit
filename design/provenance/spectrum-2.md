# Spectrum 2 historical provenance

Ourokit's initial token categories were informed by the durable organization
of Adobe Spectrum 2 design data, specifically `@adobe/spectrum-tokens` 14.6.0
from `adobe/spectrum-design-data` (accessed 2026-08-30). That source is offered
under the Apache License 2.0; see
<https://github.com/adobe/spectrum-design-data/blob/main/LICENSE>.

This is a selective, Ouro-owned transformation rather than an import. Ourokit
keeps only a small desktop-oriented foundation and semantic role layer. Names
use the `ouro` namespace, and the current values were independently selected
for this proof. Deprecated, mobile, wireframe, Adobe-product-specific,
premium, and generative-AI token families were not imported. Ourokit does not
use Adobe product marks, Spectrum component names, or Adobe Clean fonts.

The transformation is represented by the canonical JSON under
`design/tokens`; generated Zig data is reproducible through
`tools/design/generate_tokens.py`. Future changes derived from a different
upstream release must update this record and be reviewed rather than silently
absorbing the upstream corpus.

Spectrum 2 is no longer Ourokit's component or token source of truth. The
current direction and source are recorded in `shadcn-ui.md`; this file is
retained to preserve attribution for the project's earlier design work.
