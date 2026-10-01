#!/usr/bin/env python3
"""Compare matched Vulkan list/rebuild CPU frame work; not display latency."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import subprocess
import time

from run import command_output
from scroll import distribution


def analyze_run(result, toolkit, profile, frames, warmup_frames):
    records, diagnostics = [], []
    parse_error = None
    for line in (result.stdout + "\n" + result.stderr).splitlines():
        if line.startswith("{"):
            try:
                record = json.loads(line)
                if record.get("kind") not in ("metadata", "sample"):
                    raise ValueError("unknown record kind")
                records.append(record)
            except ValueError as error:
                parse_error = str(error)
                diagnostics.append(line)
        elif line:
            diagnostics.append(line)
    metadata = [r for r in records if r.get("kind") == "metadata"]
    samples = [r for r in records if r.get("kind") == "sample"]
    run = {"toolkit": toolkit, "profile": profile, "returncode": result.returncode,
           "status": "failed", "metadata": metadata, "samples": samples, "diagnostics": diagnostics}
    try:
        if parse_error:
            raise ValueError(f"invalid JSON record: {parse_error}")
        if len(metadata) != 1:
            raise ValueError("expected one metadata record")
        meta = metadata[0]
        expected = {"toolkit": toolkit, "profile": profile, "frames": frames,
                    "row_count": 10000 if profile == "scroll" else 1000,
                    "viewport": [640, 720], "font": "Source Sans 3", "font_size": 14,
                    "font_weight": 400, "row_padding": 4, "line_height": 18.5625,
                    "scale_factor": 1, "active": True}
        if any(meta.get(k) != v for k, v in expected.items()):
            raise ValueError("workload metadata mismatch")
        if len(samples) != frames or not 1 <= warmup_frames < frames - 1:
            raise ValueError("incomplete trace or invalid warmup count")
        for i, sample in enumerate(samples):
            if type(sample["frame"]) is not int or sample["frame"] != i:
                raise ValueError("missing or duplicate generation")
            if sample["offset"] != (i * 14 if profile == "scroll" else 0):
                raise ValueError("wrong scroll offset")
            if sample["row_height"] != (32 if profile == "relayout" and i % 2 else 28):
                raise ValueError("wrong row height")
            if "first_row" in sample and sample["first_row"] != 1 + (i // 2 if profile == "scroll" else 0):
                raise ValueError("wrong visible row")
            if "first_value" in sample and sample["first_value"] != (i if profile == "rebuild" else 0):
                raise ValueError("stale visible text")
            for key in ("build_ns", "submit_ns", "work_ns", "submitted_ns"):
                if type(sample[key]) is not int or sample[key] <= 0:
                    raise ValueError("invalid timing")
            if sample["work_ns"] != sample["build_ns"] + sample["submit_ns"]:
                raise ValueError("phase timings do not add up")
            if i and sample["submitted_ns"] <= samples[i - 1]["submitted_ns"]:
                raise ValueError("non-increasing submission times")
        measured = samples[warmup_frames:]
        run["summary"] = {key.removesuffix("_ns") + "_ms": distribution([r[key] / 1e6 for r in measured])
                          for key in ("build_ns", "submit_ns", "work_ns")}
        run["summary"].update(
            measured_frames=len(measured),
            submission_interval_ms=distribution([(b["submitted_ns"] - a["submitted_ns"]) / 1e6
                                                 for a, b in zip(measured, measured[1:])]),
            cpu_work_over_16_67_ms=sum(r["work_ns"] > 1e9 / 60 for r in measured),
        )
        run["status"] = "ok" if result.returncode == 0 else "measurement_complete_cleanup_failed"
    except (ValueError, KeyError, TypeError) as error:
        run["reason"] = str(error)
    return run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--frames", type=int, default=331)
    parser.add_argument("--warmup-frames", type=int, default=31)
    parser.add_argument("--profiles", nargs="+", choices=("scroll", "rebuild", "relayout"),
                        default=["scroll", "rebuild", "relayout"])
    parser.add_argument("--timeout", type=float, default=180)
    parser.add_argument("--environment-description", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if (args.iterations < 1 or not 1 <= args.warmup_frames < args.frames - 1 or args.frames > 10000
            or not math.isfinite(args.timeout) or args.timeout <= 0 or len(set(args.profiles)) != len(args.profiles)):
        parser.error("invalid iterations, frame counts, profiles, or timeout")
    root = Path(__file__).resolve().parents[2]
    binaries = {"Ourokit": root / "zig-out/benchmark-apps/ourokit-workload",
                "GPUI": root / "zig-out/benchmark-apps/gpui-workload"}
    build = json.loads((binaries["GPUI"].parent / "gpui-workload-build.json").read_text())
    if hashlib.sha256(binaries["GPUI"].read_bytes()).hexdigest() != build["binary_sha256"]:
        raise RuntimeError("GPUI workload binary does not match build metadata")
    font_hash = hashlib.sha256((root / "src/text/fonts/SourceSans3-Regular.otf").read_bytes()).hexdigest()
    if font_hash != build["font_sha256"]:
        raise RuntimeError("GPUI workload font does not match this checkout")
    document = {
        "schema_version": 1,
        "environment": {
            "description": args.environment_description,
            "kernel": command_output(["uname", "-srmo"]),
            "cpu": next(line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")),
            "affinity": sorted(os.sched_getaffinity(0)), "load_average": os.getloadavg(),
            "sway": command_output(["sway", "--version"]),
            "outputs": json.loads(command_output(["swaymsg", "-t", "get_outputs", "-r"])),
            "revision": command_output(["git", "-C", str(root), "rev-parse", "HEAD"]),
            "worktree_status": command_output(["git", "-C", str(root), "status", "--porcelain"]),
            "binary_sha256": {name: hashlib.sha256(p.read_bytes()).hexdigest() for name, p in binaries.items()},
            "source_sha256": {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in (
                "build.zig", "tools/application-benchmark/workload.zig",
                "tools/application-benchmark/workload.lua", "tools/application-benchmark/workload.py")},
            "font_sha256": font_hash, "gpui_build": build,
        },
        "protocol": {
            "profiles": args.profiles, "frames": args.frames, "warmup_frames": args.warmup_frames,
            "iterations": args.iterations, "order_seed": 0xC0FFEE,
            "state": "Programmatic generation changes; no physical input. Stable row keys. All frames must be accounted for.",
            "timing": "CPU-side wall work: build/layout/paint scene plus synchronous platform submission. Excludes state mutation, pacing wait and initialization.",
            "pacing": "Wayland frame callbacks; submission intervals are not compositor presentation timestamps.",
            "acquisition": "Ourokit reusable-buffer acquisition is outside its submit span; GPUI surface-texture acquisition is inside its platform Present span.",
            "limitations": "Not GPU execution time, input latency, physical display latency, or uncapped throughput. CPU work >16.67ms is not a dropped-frame count. Instrumentation differs: native timestamps vs GPUI public profiler.",
            "statistics": "Nearest-rank percentiles per process after warmup; do not pool frames across independent runs.",
        },
        "runs": [],
    }
    randomizer = random.Random(0xC0FFEE)
    try:
        for iteration in range(args.iterations):
            order = [(profile, name) for profile in args.profiles for name in binaries]
            randomizer.shuffle(order)
            for profile, name in order:
                started = time.monotonic()
                arguments = (["--profile", profile, "--frames", str(args.frames)] if name == "GPUI"
                             else [profile, str(args.frames)])
                try:
                    result = subprocess.run([str(binaries[name]), *arguments],
                                            capture_output=True, text=True, timeout=args.timeout)
                    run = analyze_run(result, name, profile, args.frames, args.warmup_frames)
                except subprocess.TimeoutExpired as error:
                    run = {"status": "timeout", "toolkit": name, "profile": profile,
                           "stdout": (error.stdout or b"").decode(errors="replace"),
                           "stderr": (error.stderr or b"").decode(errors="replace")}
                run.update(iteration=iteration, elapsed_s=time.monotonic() - started)
                document["runs"].append(run)
                args.output.write_text(json.dumps(document, indent=2) + "\n")
                print(json.dumps({k: v for k, v in run.items() if k not in ("samples", "diagnostics", "stdout", "stderr")}), flush=True)
                if run["status"] != "ok":
                    raise RuntimeError(f"{name}/{profile}: {run['status']}; raw result preserved")
    finally:
        args.output.write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    main()
