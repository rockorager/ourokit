#!/usr/bin/env python3
"""Run the software Wayland virtual-list probe and retain raw feedback."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import statistics
import subprocess
import time

from run import command_output


def distribution(values):
    if not values:
        return None
    ordered = sorted(values)
    return {"count": len(values), "min": ordered[0], "median": statistics.median(ordered),
            "p95": ordered[math.ceil(len(ordered) * .95) - 1],
            "p99": ordered[math.ceil(len(ordered) * .99) - 1], "max": ordered[-1]}


def summarize(samples, warmup_frames):
    if warmup_frames < 1 or len(samples) <= warmup_frames + 1:
        raise ValueError("need initial frame, warmups, and at least two measured frames")
    for index, sample in enumerate(samples):
        if sample["frame"] != index:
            raise ValueError("missing or out-of-order frame")
        if index and (sample["input_ns"] <= 0 or sample["submitted_ns"] < sample["input_ns"]):
            raise ValueError("invalid input/submission timestamps")
        if index and sample["offset"] == samples[index - 1]["offset"]:
            raise ValueError("scroll did not change the viewport")
    measured = samples[warmup_frames:]
    clocks = {sample["clock_id"] for sample in samples}
    same_clock = len(clocks) == 1
    if same_clock and any(b["presented_ns"] <= a["presented_ns"] for a, b in zip(samples, samples[1:])):
        raise ValueError("non-increasing presentation timestamps")
    intervals = [(b["presented_ns"] - a["presented_ns"]) / 1e6
                 for a, b in zip(measured, measured[1:])] if same_clock else []
    # Input uses Linux CLOCK_MONOTONIC (1). Never subtract unrelated clocks.
    comparable = clocks == {1}
    if comparable and any(not s["input_ns"] <= s["presented_ns"] <= s["feedback_received_ns"] for s in measured):
        raise ValueError("presentation timestamp outside input/feedback bounds")
    latency = [(s["presented_ns"] - s["input_ns"]) / 1e6 for s in measured] if comparable else []
    long_intervals = [b["presented_ns"] - a["presented_ns"] > b["refresh_ns"] * 1.5
                      for a, b in zip(measured, measured[1:]) if b["refresh_ns"] > 0] if same_clock else []
    return {
        "measured_frames": len(measured),
        "presentation_interval_ms": distribution(intervals),
        "runtime_input_to_presentation_ms": distribution(latency),
        "latency_status": "measured, synthetic runtime input" if comparable else "unavailable: presentation clock is not CLOCK_MONOTONIC",
        "runtime_input_to_submission_ms": distribution([(s["submitted_ns"] - s["input_ns"]) / 1e6 for s in measured]),
        "intervals_over_1_5_refresh": sum(long_intervals) if long_intervals else None,
        "intervals_with_known_refresh": len(long_intervals),
        "hardware_clock_frames": sum(s["hardware_clock"] for s in measured),
        "hardware_completion_frames": sum(s["hardware_completion"] for s in measured),
        "vsync_frames": sum(s["vsync"] for s in measured),
    }


def analyze_run(result, frames, warmup_frames):
    diagnostics = [line for line in result.stderr.splitlines() if not line.startswith("{")]
    samples = [json.loads(line) for line in result.stderr.splitlines() if line.startswith("{")]
    run = {"status": "failed", "returncode": result.returncode,
           "diagnostics": diagnostics, "samples": samples}
    if len(samples) != frames:
        run["reason"] = "incomplete presentation trace"
        return run
    try:
        run["summary"] = summarize(samples, warmup_frames)
    except ValueError as error:
        run["reason"] = str(error)
        return run
    run["status"] = "ok" if result.returncode == 0 else "measurement_complete_cleanup_failed"
    return run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--frames", type=int, default=301)
    parser.add_argument("--warmup-frames", type=int, default=31,
                        help="includes initial non-input frame; excluded per process")
    parser.add_argument("--story", choices=("fixed/initial", "variable/initial", "variable/narrow"), default="variable/initial")
    parser.add_argument("--timeout", type=float, default=30)
    parser.add_argument("--compositor-description", required=True,
                        help="compositor version, backend, renderer and output mode; retained verbatim")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if (args.iterations < 1 or not 1 <= args.warmup_frames < args.frames - 1 or
            args.frames > 10000 or not math.isfinite(args.timeout) or args.timeout <= 0):
        parser.error("invalid iteration, frame, warmup, or timeout count")
    root = Path(__file__).resolve().parents[2]
    binary = root / "zig-out/benchmark-apps/ourokit-scroll"
    runs = []
    for _ in range(args.iterations):
        started = time.monotonic()
        try:
            result = subprocess.run([str(binary), args.story, str(args.frames)],
                                    capture_output=True, text=True, timeout=args.timeout)
        except subprocess.TimeoutExpired:
            runs.append({"status": "timeout", "reason": "no complete trace; feedback may be missing/discarded or window occluded"})
            break
        run = analyze_run(result, args.frames, args.warmup_frames)
        run["elapsed_s"] = time.monotonic() - started
        runs.append(run)
        print(json.dumps({key: value for key, value in run.items() if key != "samples"}), flush=True)
        if run["status"] == "failed":
            break
    document = {
        "schema_version": 1,
        "environment": {
            "kernel": command_output(["uname", "-srmo"]),
            "cpu": next(line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")),
            "affinity": sorted(os.sched_getaffinity(0)), "load_average": os.getloadavg(),
            "compositor_description": args.compositor_description,
            "sway_outputs": json.loads(command_output(["swaymsg", "-t", "get_outputs", "-r"])) if os.environ.get("SWAYSOCK") else None,
            "revision": command_output(["git", "-C", str(root), "rev-parse", "HEAD"]),
            "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        },
        "protocol": {"story": args.story, "frames": args.frames, "warmup_frames": args.warmup_frames,
                     "iterations": args.iterations, "renderer": "software shared memory, Source Sans 3 Regular",
                     "input": "runtime routed wheel axis, 24 logical pixels, reverse every 120 events",
                     "pacing": "closed loop: acquire next buffer after previous presentation feedback; one frame in flight",
                     "boundary": "CLOCK_MONOTONIC before routePointer(axis) to wp_presentation timestamp for that commit",
                     "limitations": "not hardware input, not open-loop input pressure, not full app runner or GTK/Qt comparison; headless feedback is not physical display presentation",
                     "percentiles": "nearest rank per run; no pooled frames across runs"},
        "runs": runs,
    }
    args.output.write_text(json.dumps(document, indent=2) + "\n")
    if any(run["status"] != "ok" for run in runs):
        raise SystemExit("Run or cleanup failure; inspect retained measurements in " + str(args.output))


if __name__ == "__main__":
    main()
