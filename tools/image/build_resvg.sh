#!/bin/sh
# Called only by build steps linking the full ourokit module. A packager can
# build/install this same bridge and use -Dresvg-system=true instead of Cargo.
set -eu
manifest=$1
output=$2
target=$3
native=$4
if [ "$native" != true ]; then
    echo 'Bundled resvg cross-compilation is unsupported; build the bridge for the target and use -Dresvg-system=true.' >&2
    exit 1
fi
case "$target" in
    x86_64-linux-gnu) rust_target=x86_64-unknown-linux-gnu ;;
    aarch64-linux-gnu) rust_target=aarch64-unknown-linux-gnu ;;
    x86_64-macos-none) rust_target=x86_64-apple-darwin ;;
    aarch64-macos-none) rust_target=aarch64-apple-darwin ;;
    *) echo "Bundled resvg does not support $target; use a target-built -Dresvg-system=true bridge." >&2; exit 1 ;;
esac
cargo=${CARGO:-cargo}
if ! command -v "$cargo" >/dev/null 2>&1; then
    echo 'Cargo is required for bundled resvg (Rust >=1.85). Add it to PATH or set CARGO; alternatively use -Dresvg-system=true.' >&2
    exit 1
fi
"$cargo" build --locked --release --manifest-path "$manifest" --target "$rust_target" --target-dir "$output/cargo"
cp "$output/cargo/$rust_target/release/libourokit_resvg.a" "$output/libourokit_resvg.a"
