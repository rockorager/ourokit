# Image codecs

`zig build test-image-codecs` tests the isolated codec and native bridges.
`ourokit_ui` never imports their build module and does not need Cargo.

The default full build requires Cargo and Rust **1.85 or newer**, tested with
**1.94.0**. For example, install a minimal 1.94.0 Rust toolchain through rustup
and put `$HOME/.cargo/bin` on PATH. `CARGO` can override the Cargo executable.
The build copies Cargo.toml, Cargo.lock, and lib.rs into the Zig cache and runs
`cargo build --locked --release` there. Dependencies are resolved by the checked-in
lockfile; builds do not modify source files. A first build downloads crates;
offline packagers should prefetch or vendor the locked Cargo dependency graph.

Bundled builds support native Linux GNU and macOS on x86_64/aarch64. Other
targets and cross-compilation fail explicitly rather than linking host code.
Packagers may build `src/image/resvg/Cargo.toml` for their target and use
`-Dresvg-system=true` to link **libourokit_resvg**, the custom bridge ABI 1 from
this repository, not resvg's unrelated C API library. Supply library search
paths with Zig's `--search-prefix` or a `ourokit_resvg.pc` pkg-config file.
No Cargo process is run in system mode. The supplied bridge must retain the
resource restrictions in lib.rs. The bundled static bridge uses Rust's standard
library; Zig's bundled C++/unwind runtime supplies its unwind symbols.

PNG/JPEG use the upstream generated `release/c/wuffs-v0.4.c` from Wuffs commit
0f214ba59c20c0c9c7ba841ecc3683f863965312. WebP uses libwebp 1.6.0's portable,
decoder-only C sources. Both source archives are content-hashed in build.zig.zon.
Static SVG uses resvg exactly 0.48.1 with default features disabled.

## Decode contract and limitations

- Output is tightly packed premultiplied encoded-sRGB RGBA8. ICC conversion is
  not performed. Tint replaces RGB and multiplies source alpha by tint alpha.
- JPEG EXIF orientations 1–8 are applied, including swapped intrinsic dimensions.
- Raster dimensions stay native. Animated WebP returns the first frame on its
  full transparent canvas, including frame offset, and ignores later frames.
- SVG width/height are physical resolution hints, not a fitting rectangle.
  A uniform scale satisfies both when both are supplied; output dimensions are
  rounded up. With neither supplied, `Options.scale` supplies the HiDPI scale.
  Intrinsic dimensions remain the original viewport, rounded up to integers.
- **SVG text and image resources are ignored**, not rendered. Convert text to
  paths. Filesystem and network images, embedded data images, system fonts, and
  SVGZ are unsupported. Local fragment references such as `<use href="#path">`
  are supported. Do not use this decoder as a validator of complete SVG support.
- Dimension and decoded-byte limits are checked before output allocation.
  They are not a total parser/filter/decoder working-memory budget. EXIF
  transformation can temporarily hold two bounded output buffers. Rust standard
  allocations abort on out-of-memory; use process isolation for hostile assets
  requiring a hard total-memory/CPU budget.

Original fixtures are under `src/image/codec_fixtures`; regenerate the binary
fixtures using the pinned Pillow command in `generate_fixtures.py`. Tests compare
against manually specified colors and orientation tables, not codec snapshots.

Preserve THIRD_PARTY_NOTICES.txt and RUST_LIBRARY_LICENSES.html with distributions;
the default install step installs them under `share/licenses/ourokit`. The Rust
notice file covers the tested 1.94.0 standard library; packagers using another
toolchain must preserve that toolchain's applicable runtime notices as well.
