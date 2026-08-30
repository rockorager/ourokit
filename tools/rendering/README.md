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
