#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
zig=${ZIG:-zig}
out="$repo/zig-out/benchmark-apps"

"$zig" build build-application-benchmark -Doptimize=ReleaseFast
mkdir -p "$out"

cc -O2 -DNDEBUG -Wall -Wextra \
    $(pkg-config --cflags gtk4) \
    "$repo/tools/application-benchmark/gtk.c" \
    -o "$out/gtk" \
    $(pkg-config --libs gtk4)

c++ -O2 -DNDEBUG -Wall -Wextra \
    $(pkg-config --cflags Qt6Widgets) \
    "$repo/tools/application-benchmark/qt.cpp" \
    -o "$out/qt" \
    $(pkg-config --libs Qt6Widgets)

strip "$out/ourokit" "$out/ourokit-settings" "$out/gtk" "$out/qt"

printf 'Built application benchmarks in %s\n' "$out"
