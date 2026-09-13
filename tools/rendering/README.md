# Rendering benchmark tooling

`zig build bench-renderers -Doptimize=ReleaseFast` builds the current Ourokit
software renderer and Pixman 0.46.4 against the same 1920×1080 opaque and
translucent rectangle workload. It verifies every output byte before timing.

Pixman is fetched from its official release archive through the lazy
`build.zig.zon` dependency and compiled with its portable sources plus x86-64
MMX/SSE2/SSSE3 or AArch64 NEON paths. Default builds do not fetch or link it.
The local configuration headers apply only to this pinned benchmark build.

Pixman is MIT licensed. Its source remains an external Zig dependency and is
not vendored or installed as part of Ourokit. Benchmark results depend on CPU,
memory, target, compiler mode, workload, and system load; record that context
before using numbers to change backend policy.

## Adobe outline comparisons

`font_comparison.zig` builds a fixed GUI scene through the production paragraph
and renderer APIs, without a compositor. It uses the exact bundled Source Sans
3, Source Serif 4, and Source Code Pro OTF files, at explicit Regular 400,
Semibold 600, Bold 700, and true italic styles. Arabic uses the pinned Noto Sans
Arabic 2.013 fallback; Code italics' missing Greek/Cyrillic use bundled Sans.
It never reads theme Medium, so the Medium weight correction does not change
these raster comparisons. Logical sizes include 13.25, 14.25, and 16.25;
fractional origins and 150%/200% scales exercise device-space raster phases.

```sh
zig build compare-fonts -Doptimize=ReleaseFast -- .amp/in/artifacts/fonts/B
```

Each invocation writes light/dark PNGs for software and Vulkan compute and
requires their RGBA bytes to match exactly. Vulkan must be available (Lavapipe
is sufficient); this is not a screenshot of dma-buf presentation. The renderer
tests additionally exercise the RGBA16F graphics path with its existing ±1
encoded-channel tolerance. The PNG encoder is intentionally uncompressed;
lossless PNG compression is safe for review, but do not resample glyph crops.

Comparison A was captured from the untouched published renderer at
[`a8086e5`](https://github.com/rockorager/ourokit/commit/a8086e591b6971a446bc98670a51b2a0856ba9f1),
with only this harness and its build target added: native/default hinting,
Adobe darkening, integer-rounded origins. To reproduce A, apply only the
harness/build-target additions to that revision before the renderer edits.
Historical A/B/C/D screenshots remain review evidence: **A vs B changes
positioning and load flags; B vs C isolates hinting; C vs D isolates Adobe
darkening.** B is now the sole rendering policy: fractional positioning,
light hinting, and Adobe darkening with grayscale normal rasterization.
The experimental C/D build options have been removed; this harness renders
only B. The selected policy retains the same color pipeline.

For theme weight review, capture the existing `text/bundled-fonts-light` and
`text/bundled-fonts-dark` stories at their declared 200% snapshot scale before
and after changing `ThemeFonts`, with the same raster build (B):

```sh
zig build -Doptimize=ReleaseFast
zig-out/bin/ouroctl storybook snapshot examples/storybook.lua \
  --story text/bundled-fonts-light --output .amp/in/artifacts/fonts/medium-after
```

The button label is “Medium control” in both review captures. Only font
selection changes: Sans/Code 600→500, Serif 600→400 (documented absent-500
fallback). Explicit Semibold in the raster harness remains 600. Judge PNGs
at native pixels: browser/image-viewer scaling and the absence of a calibrated
physical high-DPI display limit perceived sharpness and weight comparisons.
