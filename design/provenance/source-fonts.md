# Adobe Source fonts

Ourokit bundles unmodified static CFF OpenType fonts from Adobe's release
branches. The exact upstream revisions are:

| Family | Upstream revision |
| --- | --- |
| Source Sans 3 | [87b37a2](https://github.com/adobe-fonts/source-sans/commit/87b37a2daaed80fcb8e8ccb0085c4d72ddade12e) |
| Source Serif 4 | [5f220b1](https://github.com/adobe-fonts/source-serif/commit/5f220b17d27ed64873f22cde0dd593685387bd19) |
| Source Code Pro | [803b7e2](https://github.com/adobe-fonts/source-code-pro/commit/803b7e23ec97ae58b6232ea76519a76d428ba268) |

For each family, `src/text/fonts` contains the upstream `OTF/` files with
suffixes `Regular`, `It`, `Semibold`, `SemiboldIt`, `Bold`, and `BoldIt`.
Source Sans 3 and Source Code Pro also include `Medium` and `MediumIt` from
the same revisions above. Internal versions are Sans 3.052, Serif 4.005,
and Code 2.042 upright / 1.062 italic; all are static CFF outlines.
Source Serif uses the default text optical design, not Caption or Display.
No outlines, names, metadata, hinting, or character coverage have been modified.
Do not regenerate these from TTF, subset them, or substitute variable builds
without reviewing both rendering behavior and the license's reserved-name rules.

The original family-specific `LICENSE.md` files are copied alongside the fonts
as `SourceSans3-LICENSE.md`, `SourceSerif4-LICENSE.md`, and
`SourceCodePro-LICENSE.md`. All three are SIL Open Font License 1.1 with the
reserved font name **Source**. `zig build` installs the notices under
`share/licenses/ourokit`. Redistributors must include the notices with the
embedded fonts, including when distributing an ourokit-based executable alone.
The OFL does not change the license of ourokit or applications using it.

The fonts are embedded by `text.bundled`, so production use does not require a
font download or a system installation. Generic `sans-serif`, `serif`, and
`monospace` requests select these families before system fallback candidates.
Explicit Source family names select the same bundled files. Other installed
family names still resolve through Fontconfig.

Coverage is not identical across faces: Source Code Pro's bundled italic faces
lack Greek and Cyrillic, unlike its upright faces and the bundled Sans/Serif
faces. None of the three families replaces global-script or emoji fallback.
Native API consumers selecting italics must supply suitable fallback candidates.

The current UI distinguishes regular text from emphasized controls; the latter
request Medium (500), matching the system Fontconfig request. Sans and Code
select their authentic Medium faces. Static Source Serif 4 has no Medium:
its 500 request explicitly falls back to Regular (400), preferring 400 before
weights above 500 as in CSS weight matching. This aliases the actual Regular
asset and cache identity, not a relabelled 600 face or a generated instance.
Explicit Semibold (600), Bold (700), and real italics remain available through
`text.bundled.acquire`. This does not add weight/style
properties to Lua widgets. The renderer pairs Adobe's size-dependent CFF stem
darkening with linear-light compositing, preserving A8 masks as coverage and
using high-precision internal buffers. Presentation remains ordinary encoded
sRGB; see [rendering](../../docs/rendering.md) for the color and buffer contract.
