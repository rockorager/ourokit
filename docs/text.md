# Text shaping

## Established boundary

Text shaping and measurement are shared application-platform services above UI
layout, scenes, and both renderers. Ourokit embeds pinned HarfBuzz 14.3.1's core
OpenType implementation from its Zig dependency. It does not use a one-glyph-
per-code-point approximation. HarfBuzz has no FreeType, GLib, or ICU integration.
Native Linux builds separately link the system Fontconfig package and its
platform dependencies only for discovery. Software glyph rasterization is a
separate optional system FreeType capability; `-Dfreetype=false` removes it
from software-only/headless or cross builds that do not draw text.

`text.Font.shape` accepts one already-itemized UTF-8 run with:

- the complete logical-order paragraph and a code-point-aligned byte range;
- explicit direction, ISO 15924 script, and BCP 47 language;
- an explicit font face and positive finite logical size.

Passing the complete paragraph gives HarfBuzz context around the run while its
clusters remain byte offsets into the original paragraph. RTL input is not
manually reversed. The buffer uses monotone-character cluster level, native
OpenType font functions, default OpenType shaping features, and a 26.6 logical
scale. The owned result carries glyph IDs, clusters, advances, offsets,
unsafe-break flags, aggregate advance, and font extents. Layout can consume
these metrics without calling a renderer.

HarfBuzz shapes only a uniform run. It does not perform bidi resolution, script
itemization, font fallback, normalization, line breaking, hyphenation, or
grapheme cursoring. Ourokit will not use `hb_buffer_guess_segment_properties`
to conceal those missing paragraph stages.

## Paragraph analysis

Pinned SheenBidi 3.0.0 provides Unicode 17 UAX #9 paragraph boundaries,
embedding levels, isolate handling, and paired-bracket handling.
It is fetched as a Zig dependency and compiled from its unity source under the
Apache-2.0 license. Ourokit defines `SB_CONFIG_DISABLE_SCRATCH_MEMORY`: the
release's native scratch pool is process-global, while paragraph analysis must
remain safe to call from independent threads.

`text.analyzeBidi` is a pure headless stage. It accepts valid UTF-8 plus explicit
or P2/P3-derived base direction and returns owned flattened paragraph metadata,
per-byte levels, and logical level runs whose ranges index the original UTF-8.
It owns no fonts, Fontconfig state, UI nodes, renderer resources, Wayland
objects, or Lua state. Invalid UTF-8 is rejected before entering C. Empty input
has one explicitly defined empty paragraph instead of relying on a dependency
edge case.

This separation is intentional for testing and profiling. Unit tests exercise
mixed direction, CRLF paragraph boundaries, explicit direction, malformed
input, and every caller-owned allocation failure. `zig build bench-paragraph
-Doptimize=ReleaseFast -Dfontconfig=false -Dfreetype=false` measures bidi
analysis independently on Latin, mixed-script, isolate, and multi-paragraph
workloads. Later itemization, shaping, line breaking, and layout stages remain
separately callable rather than being hidden inside one opaque text API.

These logical runs are not yet a paragraph layout. Script itemization must
intersect them before HarfBuzz shaping. UAX #14 opportunities and actual line
boundaries must be resolved before line-specific UAX #9 L1/L2 reordering;
exposing SheenBidi's visual line runs at this stage would make wrapped text
incorrect. Ourokit has not selected a line-breaking dependency yet:
libgrapheme 3.0.0 has Unicode 17 data but known conformance failures, while
libunibreak 7.0 remains on older Unicode line rules. Neither is accepted merely
to fill the API.

## Unicode boundaries

Pinned `jacobsandlund/uucode` supplies Unicode 17 extended-grapheme iteration.
Ourokit validates UTF-8 before using it and preserves byte boundaries for future
cursoring and selection. A grapheme is not a HarfBuzz cluster: one grapheme can
produce several glyphs, and substitutions can combine several source positions
into one shaping cluster.

uucode intentionally tailors isolated emoji modifiers relative to default UAX
#29. Ourokit currently exposes that behavior explicitly. uucode provides useful
Unicode properties but does not implement UAX #9 bidi, UAX #14 line breaking,
UAX #15 normalization, word breaking, or script-extension run resolution.

## Fonts and fallback

The canonical UI request is generic `sans-serif`, not a hard-coded face.
Fontconfig applies the user's configured aliases and substitutions and returns
an ordered, coverage-trimmed fallback candidate set. Ourokit copies each
candidate's family, file, complete face/named-instance index, variable-font
metadata, variation string, and charset coverage out of Fontconfig-owned
patterns. The database is an explicit application-owned configuration snapshot;
refresh and dependent cache invalidation happen only at a safe point.

Fontconfig charset coverage is a fast prefilter, not proof that a face can shape
a cluster correctly. `shapeWithFallback` verifies candidates through actual
HarfBuzz output. It prefers one face for the complete itemized run. If that is
impossible, it chooses at uucode extended-grapheme boundaries, merges adjacent
equal-face choices, and performs final shaping with complete paragraph context.
Arabic joining context and combining/emoji sequences therefore survive a
necessary face boundary. An unresolved grapheme is retained as the primary
face's `.notdef` and reported rather than silently omitted.

Zig fetches exact Inter 4.1 and Noto Sans Arabic 2.013 releases only for
deterministic Latin and complex-script shaping tests; normal library artifacts
do not embed them. Their source, version, and SIL Open Font License provenance
are under `design/provenance`.

The `Font` API owns a copied font blob and exposes nominal cmap coverage.
Fontconfig's full index is preserved for collection/named-instance selection;
its special variable-face sentinel is stripped before HarfBuzz interprets it,
and `FC_FONT_VARIATIONS` assignments override named-instance defaults. Fallback
inputs carry cache-owned font pointers only for the duration of shaping; output
retains generation-checked font handles.

`FontCache` owns initialized HarfBuzz faces in growable stable-address slabs.
It does not open Fontconfig paths itself: the Ouro I/O layer supplies bytes, so
font loading can join the same raw `io_uring` scheduler rather than introducing
blocking text-library calls. File, full index, variations, and a caller-provided
source revision form the identity. Repeated acquisition deduplicates that key;
retain/release controls lifetime; final release increments the slot generation
before reuse. Resolving a valid handle is O(1), while dedupe remains a cold-path
linear scan until benchmark evidence warrants another index.

Fallback probing allocates temporary shaped runs and now sits behind an
application-owned `ShapeCache`. Its immutable entries live in growable
stable-address slabs and are addressed by a dedicated generation-checked
`ShapeHandle`. A collision-safe hash index keys the complete paragraph,
normalized run range, direction, script, language, exact logical-size bits,
ordered font handles, and a caller-supplied Fontconfig configuration revision.
The first acquisition performs fallback shaping; unchanged acquisitions retain
the same entry without probing HarfBuzz again.

Each entry owns copies of its variable-length key data and retains every
candidate font handle, including candidates not selected in the final spans.
This keeps output font identities valid until the shaped entry's final release.
Final release removes the hash entry, destroys all shaped spans, releases those
fonts, and increments the shape-slot generation. `FontCache` therefore outlives
`ShapeCache` in the application scope. Fontconfig refresh happens at a safe
point and changes the configuration revision rather than mutating live entries.

## Initial label slice

The first retained text render object is deliberately a single, already-
itemized label for benchmark UI. Its public constructor accepts only valid
UTF-8 whose uucode Script values are Latin, Common, or Inherited, and shapes it
as one LTR Latin run. Other scripts are rejected instead of being assigned a
false script or direction. Full paragraph bidi and itemization remain deferred.

The Label render object stores only a generation-checked `ShapeHandle` and
color. It takes intrinsic width and line height from the immutable shaped result
and emits a renderer-neutral glyph-run scene command with a baseline and output
scale. A button remains composition: a padded Box containing a Label, with
pointer/focus/command behavior owned by the instance layer.

Each renderer owns FreeType faces and grayscale glyph masks keyed by font
generation, glyph ID, and exact 26.6 device size. Cached faces retain their font
handles, use the exact collection/named-instance index selected for HarfBuzz,
and apply the same variable-axis assignments. The Vulkan backend additionally
packs masks into an application-lifetime atlas, stages cache misses into device-
local storage, reads that atlas from compute for exact headless output, and
blends atlas quads directly into dma-buf presentation images. Glyph masks are
blended as premultiplied source-over without exposing FreeType, masks, stride,
Vulkan resources, or pixel formats to text, scenes, or render objects. Cache
eviction remains deferred until benchmark data establishes a budget.

Borrowed display lists can render glyph handles synchronously. Owned async
`scene.Frame` construction currently rejects glyph commands because frame-level
resource leases are not implemented; it does not silently copy handles without
retaining them.

## Work not yet frozen

- full UAX #9 paragraph levels, visual ordering, and logical/visual index maps;
- script-extension-aware itemization and language inheritance;
- async font-file loading and safe-point Fontconfig refresh/invalidation;
- UAX #14 line opportunities, reshaping at safe breaks, and hyphenation;
- normalization policy (shaping does not imply mutating application text);
- variable-font axis selection and cache identity;
- renderer-neutral frame resource leases for positioned glyph runs;
- cache eviction, LCD/subpixel policy, and backend glyph-cache budgets.
