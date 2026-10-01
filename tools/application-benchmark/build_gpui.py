#!/usr/bin/env python3
"""Build the optional pinned GPUI fixture and retain its build identity."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tomllib


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--workload", action="store_true", help="build the opt-in profiled frame workload")
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("jobs must be positive")
    root = Path(__file__).resolve().parents[2]
    source = root / "tools/application-benchmark/gpui"
    target = root / "zig-out/gpui-target"
    out = root / "zig-out/benchmark-apps"
    name = "gpui-workload" if args.workload else "gpui"
    crate_binary = "ourokit-gpui-workload" if args.workload else "ourokit-gpui-benchmark"
    features = ["--features", "workload"] if args.workload else []
    subprocess.run(["cargo", "build", "--locked", "--release", "--jobs", str(args.jobs),
                    "--target-dir", str(target), "--bin", crate_binary, *features], cwd=source, check=True)
    out.mkdir(parents=True, exist_ok=True)
    binary = out / name
    shutil.copy2(target / "release" / crate_binary, binary)
    manifest = tomllib.loads((source / "Cargo.toml").read_text())
    entry = "src/bin/workload.rs" if args.workload else "src/main.rs"
    metadata = {
        "upstream_revision": manifest["dependencies"]["gpui"]["rev"],
        "rustc": subprocess.check_output(["rustc", "--version", "--verbose"], cwd=source, text=True).strip(),
        "cargo": subprocess.check_output(["cargo", "--version"], cwd=source, text=True).strip(),
        "profile": "release (debug=0, strip=true)",
        "features": ["workload"] if args.workload else [],
        "files_sha256": {name: hashlib.sha256((source / name).read_bytes()).hexdigest()
                         for name in ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml", entry)},
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    }
    if args.workload:
        metadata["font_sha256"] = hashlib.sha256((root / "src/text/fonts/SourceSans3-Regular.otf").read_bytes()).hexdigest()
    (out / f"{name}-build.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Built {binary}; SHA256 {metadata['binary_sha256']}")


if __name__ == "__main__":
    main()
