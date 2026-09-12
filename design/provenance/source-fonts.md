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
use the bundled Semibold face. The native text API additionally exposes Bold
and real italics through `text.bundled.acquire`. This does not add weight/style
properties to Lua widgets. Bundling these fonts does not enable stem darkening
or change the renderer's encoded-sRGB blending contract; those changes must be
implemented and evaluated together.
