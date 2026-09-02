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
analysis, script analysis, and their combined paragraph itemization on Latin,
mixed-script, isolate, and multi-paragraph workloads. The same command measures
complete wrapped and ellipsized paragraph cache misses using pinned Latin and
Arabic fonts, keeping finalization independently profileable without Wayland or
a renderer. It also measures
UAX #14 discovery, shaped-cluster measurement, greedy selection, and selected-
line bidi independently. Final positioned assembly is likewise a separate,
headless API with deterministic mixed-script and allocation-failure tests. The
stages remain separately callable rather than being hidden inside one opaque
text API.

`text.analyzeScripts` is the pure headless script stage. It uses uucode's Unicode
17 Script property and extended-grapheme boundaries together with exact
Unicode 17 `ScriptExtensions.txt` and `PropertyValueAliases.txt` data fetched as
a content-hashed Zig dependency. A deterministic build generator emits the
compact lookup and ISO 15924 mapping. Itemization never splits an extended
grapheme cluster, resolves Common and Inherited text against compatible
surrounding scripts, honors Script_Extensions sets such as Hiragana/Katakana
U+30FC and Arabic U+060C, and keeps paired brackets in the enclosing script.
The owned runs contain original UTF-8 byte ranges and explicit HarfBuzz scripts.
The source is Unicode 17.0.0 `UCD.zip`, hash
`N-V-__8AAHZAeQLsPIh95xxx7tkREQSrzi8mFSkX7Bv6MwQQ`, under the Unicode Terms of
Use included in that archive.

`text.itemizeParagraphs` intersects the bidi and script boundaries into maximal
logical runs with explicit level, direction, script, and original byte range.
Script context resets at each paragraph. Paragraph separators remain explicit
metadata and are not emitted as shaping runs. `ItemizedRun.runSpec` converts a
document-relative run into the paragraph-relative contract consumed by the
existing HarfBuzz fallback shaper; tests shape mixed Latin/Arabic itemized runs
through real pinned fonts. Language remains caller-supplied rather than guessed
from script.

Unicode 17 UAX #14 default opportunities are now a separate pure
`text.analyzeLineBreaks` stage. Ourokit extends uucode through its supported
custom build configuration with the missing `Line_Break` field, so uucode's
generated compressed tables also hold General_Category, East_Asian_Width, and
Extended_Pictographic inputs needed by revision 55. The scanner reports UTF-8
byte offsets and distinguishes allowed from mandatory breaks. It passes every
one of the 19,338 official Unicode 17 `LineBreakTest.txt` cases. Its ordered
rule implementation was informed by `cto-af/linebreak` commit
`088ff02569c5f213951e819a0578f164455f1075`; that MIT reference license is
retained under `docs/licenses`.

Opportunity discovery and line selection are intentionally separate. The first
`text.wrap.greedy` selector consumes measured advances between opportunities in
linear time and never invents a prohibited break. Wrap strategies live as
sibling modules rather than behind renderer or widget switches. A future
Knuth-Plass implementation will consume a real box/glue/penalty projection from
the same Unicode opportunities and shaped metrics; Ourokit does not expose a
fake "optimal" mode before that representation exists.

`text.shapeItemizedParagraphs` shapes every logical itemized run with full
paragraph context. `text.measureBreakSegments` projects monotone HarfBuzz
clusters onto the shared UAX #14 opportunities in O(glyphs + opportunities)
time. It preserves `HB_GLYPH_FLAG_UNSAFE_TO_BREAK`: a selected unsafe boundary
marks both adjacent lines for reshaping instead of silently reusing invalid
glyph output. `text.selectGreedyLines` then selects logical ranges and asks
SheenBidi to apply UAX #9 L1-L2 for each actual line, including line-local
trailing-whitespace reset and visual left-to-right level-run order. UTF-8 byte
ranges remain logical source ranges throughout.

`text.positionLines` completes the headless pipeline. It intersects visual bidi
runs with itemized and fallback-font spans, emits renderer-neutral positioned
glyph spans in visual left-to-right traversal order, and preserves logical byte
ranges for future caret mapping. Safe boundaries slice the whole-paragraph
shape result. A line touching either side of an unsafe HarfBuzz boundary is
conservatively reshaped with the original paragraph context. If that changes
the provisional line advance, assembly returns `error.ReflowRequired` rather
than emitting glyphs for stale greedy choices. Any unexpected mismatch at a
safe boundary is rejected as invalid measurement.

The output remains text-owned rather than being squeezed into the current
single-`ShapeHandle` scene command: wrapped mixed-direction text can contain
several visual and fallback-font spans. Scene resource leases and Label/render-
object lowering are the next integration boundary. Empty/newline-only line
metrics also require an explicit line-style policy; they currently remain zero
instead of silently selecting an arbitrary font. Dictionary/locale tailoring
and hyphenation remain explicit later stages rather than being misrepresented
as default UAX #14 behavior.

## Unicode boundaries

Pinned `jacobsandlund/uucode` supplies Unicode 17 extended-grapheme iteration.
Ourokit validates UTF-8 before using it and preserves byte boundaries for future
cursoring and selection. A grapheme is not a HarfBuzz cluster: one grapheme can
produce several glyphs, and substitutions can combine several source positions
into one shaping cluster.

uucode intentionally tailors isolated emoji modifiers relative to default UAX
#29 grapheme breaking. Ourokit currently exposes that behavior explicitly.
uucode provides useful Unicode properties but does not implement UAX #9 bidi,
UAX #14 line breaking, UAX #15 normalization, or UAX #29 word breaking.
Ourokit adds Unicode 17 `Word_Break` through uucode's custom table generator
and implements default word boundaries in the shared text layer. All 1,944
official `WordBreakTest.txt` cases run in the deterministic test suite. The
same generated Unicode source, rather than ASCII character classes, drives
word-wise editor navigation and deletion.

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

`ParagraphCache` applies the complete itemize → fallback-shape → Unicode line-
break → measure → greedy-select → line-bidi → position pipeline and owns the
result in separate generation-checked slots. Its key includes the paragraph,
base direction, language, logical size, finite maximum width, ordered candidate
fonts, and font-configuration revision. Repeated identical requests deduplicate;
final release destroys positioned storage and releases every candidate font.
The cache is width-specific by design: wrapping remains text policy rather than
a renderer operation.

## Retained labels

`ParagraphSourceCache` owns and deduplicates width-independent UTF-8, base
direction, language, logical size, ordered fallback fonts, and font-
configuration revision behind generation-checked handles. A retained Label
stores only this source identity and color. Its render-tree slot derives a
width-specific `ParagraphHandle` when text/style or box constraints change,
releasing the previous layout only after replacement succeeds. The normal
unchanged-constraint fast path returns before cache acquisition, shaping, or
allocation.

Label layout uses the positioned paragraph's finite dimensions and emits a
renderer-neutral paragraph scene command. Lua Labels therefore use the shared
itemization, fallback, bidi, wrapping, and positioning pipeline rather than a
guessed single LTR run. A button remains composition: a padded Box containing a
Label, with pointer/focus/command behavior owned by the instance layer.
Under loose width constraints, Label reports the longest visible shaped line
rather than reserving the parent's entire maximum width; a second cached layout
at that fitted width resolves center/end alignment correctly. Tight constraints
still force the Label to fill the width selected by its parent.

Paragraph presentation is also text-owned. Each positioned line stores a
physical offset resolved from its UAX #9 base level, so `start` and `end` follow
the line direction while `center` remains physical center. A finite layout width
is part of paragraph cache identity. Optional `max_lines` truncates only at
selected line boundaries and records whether content was omitted; Labels clip
the resulting paragraph to their layout bounds. Lua exposes these as typed
`alignment = "start" | "end" | "center" | "justify"`, positive `max_lines`, and
`overflow = "clip" | "ellipsis"` fields. Ellipsis requires `max_lines`. It
finalizes at the latest fitting UAX #14 opportunity, synthesizes U+2026 at that
source boundary, and reruns itemization, fallback shaping, wrapping, line bidi,
and positioning. Synthetic glyphs explicitly map to a zero-length source
boundary, preserving the source-cluster contract for future selection APIs.
Contextual reshaping that changes fit retreats to the preceding legal break;
renderers never inject or position the ellipsis themselves.

Justification is likewise finalized before rendering. Non-final soft-wrapped
lines distribute remaining width across Unicode line-break class `SP` glyphs
that have visible content on both physical sides. Positioned glyphs are already
in left-to-right visual order, so expansion is one linear pass independent of
logical bidi order; span and line advances include the added width. Final lines,
mandatory breaks, unbounded paragraphs, and lines without eligible inter-word
spaces remain start-aligned. Arabic inter-word spacing is supported without
disturbing joining. Kashida insertion and CJK inter-character expansion require
separate script-aware policies and are not implied by `justify` yet.

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

Borrowed display lists can render text handles synchronously. Owned async
`scene.Frame.initWithResources` construction copies scene storage and retains
every referenced shape and paragraph layout until frame destruction. Plain
`Frame.init` rejects text commands rather than silently copying unleased
handles. Paragraph, shape, and font caches are application-owned and must
outlive all frames that lease their entries.

## Work not yet frozen

- logical/visual caret and selection maps;
- language inheritance across itemized runs;
- async font-file loading and safe-point Fontconfig refresh/invalidation;
- Knuth-Plass selection, dictionary tailoring, and hyphenation;
- empty-line metrics and inherited line-style policy;
- normalization policy (shaping does not imply mutating application text);
- variable-font axis selection and cache identity;
- kashida and CJK inter-character justification, plus optional grapheme-level
  rather than line-break-level ellipsis refinement;
- cache eviction, LCD/subpixel policy, and backend glyph-cache budgets.
