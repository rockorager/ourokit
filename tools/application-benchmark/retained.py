#!/usr/bin/env python3
"""Sparse-update and sustained-churn CPU diagnostics, optionally paired with GPUI."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import subprocess
import time
from types import SimpleNamespace

from run import command_output
from scroll import distribution

PROFILES = ("sparse-parent", "sparse-leaf", "sustained-scroll", "keyed-churn")
COUNTERS = ("root_calls", "row_calls", "builds", "paints")
GAUGES = ("lua_heap_bytes", "source_entries", "paragraph_entries", "source_index_capacity",
          "paragraph_index_capacity", "source_slabs", "paragraph_slabs", "retiring_instances")


def expected_position(profile, frame):
    if profile == "sustained-scroll":
        phase = frame % 4800
        offset = min(phase, 4800 - phase) * 112
        return offset, offset // 28 + 1
    if profile == "keyed-churn":
        base = frame // 3 * 8
        return 0, base + (1, 1000, 18)[frame % 3]
    return 0, 1


def summarize_samples(samples, previous, toolkit="Ourokit"):
    phases = {key + "_ms": distribution([s[key + "_ns"] / 1e6 for s in samples])
              for key in ("build", "submit", "work")}
    last = samples[-1]
    if toolkit == "GPUI":
        return {
            "first_frame": samples[0]["frame"], "last_frame": last["frame"], "count": len(samples),
            **phases,
            "counter_deltas": {k: last[k] - previous[k] for k in ("root_calls", "row_calls")},
        }
    for key in ("mutation", "maintenance", "acquisition"):
        phases[key + "_ms"] = distribution([s["retained"][key + "_ns"] / 1e6 for s in samples])
    phases["cycle_work_ms"] = distribution([
        (s["work_ns"] + sum(s["retained"][k + "_ns"] for k in
                           ("mutation", "maintenance", "acquisition"))) / 1e6 for s in samples])
    last = samples[-1]
    return {
        "first_frame": samples[0]["frame"], "last_frame": last["frame"], "count": len(samples),
        **phases,
        "counter_deltas": {k: last["retained"][k] - previous["retained"][k] for k in COUNTERS},
        "layout_phase_delta": last["layouts"] - previous["layouts"],
        "gauges": {k: {"first": samples[0]["retained"][k], "last": last["retained"][k],
                        "min": min(s["retained"][k] for s in samples),
                        "max": max(s["retained"][k] for s in samples)} for k in GAUGES},
        "nodes": {"min": min(s["nodes"] for s in samples), "max": max(s["nodes"] for s in samples)},
    }


def analyze_run(result, profile, frames, warmup_frames, memory=(), window_frames=600, toolkit="Ourokit"):
    run = {"toolkit": toolkit, "profile": profile, "returncode": result.returncode, "status": "failed",
           "metadata": [], "samples": [], "diagnostics": [], "memory": list(memory)}
    try:
        if toolkit not in ("Ourokit", "GPUI") or profile not in PROFILES or not 1 <= warmup_frames < frames - 1 or window_frames < 1:
            raise ValueError("invalid protocol")
        for line in (result.stdout + "\n" + result.stderr).splitlines():
            if not line.startswith("{"):
                if line:
                    run["diagnostics"].append(line)
                continue
            record = json.loads(line)
            if record.get("kind") == "metadata":
                run["metadata"].append(record)
            elif record.get("kind") == "sample":
                run["samples"].append(record)
            else:
                raise ValueError("unknown record kind")
        if len(run["metadata"]) != 1 or len(run["samples"]) != frames:
            raise ValueError("incomplete trace")
        meta = run["metadata"][0]
        expected = {"toolkit": toolkit, "profile": profile, "frames": frames,
                    "row_count": 10000 if profile == "sustained-scroll" else 1000,
                    "viewport": [640, 720], "font": "Source Sans 3", "font_size": 14,
                    "font_weight": 400, "line_height": 18.5625, "row_padding": 4,
                    "active": True, "scale_factor": 1}
        expected.update({"backend": "vulkan_dmabuf"} if toolkit == "Ourokit" else
                        {"completed_frames": frames, "status": "complete"})
        if any(meta.get(k) != v for k, v in expected.items()):
            raise ValueError("metadata mismatch")
        if type(meta["epoch_ns"]) is not int or meta["epoch_ns"] <= 0:
            raise ValueError("invalid epoch")
        for i, sample in enumerate(run["samples"]):
            offset, first_row = expected_position(profile, i)
            if (type(sample["frame"]) is not int or sample["frame"] != i or
                    sample["offset"] != offset or sample["first_row"] != first_row or
                    sample["first_value"] != 0 or sample["row_height"] != 28):
                raise ValueError("wrong generation or retained output")
            counts = ("nodes", "commands", "layouts") if toolkit == "Ourokit" else ()
            for k in ("build_ns", "submit_ns", "work_ns", "submitted_ns", *counts):
                if type(sample[k]) is not int or sample[k] <= 0:
                    raise ValueError("invalid timing or structural count")
            if sample["work_ns"] != sample["build_ns"] + sample["submit_ns"]:
                raise ValueError("phase timings do not add up")
            if toolkit == "GPUI":
                for k in ("root_calls", "row_calls", "row_build_count", "checked_rows", "changed_value"):
                    if type(sample[k]) is not int or sample[k] < 0:
                        raise ValueError("invalid GPUI diagnostic field")
                if sample["changed_value"] != (i if profile.startswith("sparse-") else 0):
                    raise ValueError("stale changed label")
                if profile == "sustained-scroll":
                    ranges = sample["row_build_ranges"]
                    if not ranges or any(len(r) != 2 or any(type(v) is not int for v in r)
                                         or not 0 <= r[0] < r[1] <= 10000 for r in ranges):
                        raise ValueError("invalid virtual-list callback ranges")
                    if not any(a <= first_row - 1 < b for a, b in ranges):
                        raise ValueError("visible row not built")
                    if sample["row_build_count"] != sum(b - a for a, b in ranges):
                        raise ValueError("callback ranges disagree with row count")
                elif sample["checked_rows"] != 1000 or sample["first_row_bounds"] != [0, 0, 640, 28]:
                    raise ValueError("wrong retained row count or geometry")
                if i:
                    previous = run["samples"][i - 1]
                    if sample["submitted_ns"] <= previous["submitted_ns"]:
                        raise ValueError("non-increasing timestamp")
                    if sample["root_calls"] < previous["root_calls"] or sample["row_calls"] - previous["row_calls"] != sample["row_build_count"]:
                        raise ValueError("inconsistent callback counters")
                continue
            extra = sample["retained"]
            for k in (*COUNTERS, *GAUGES, "mutation_ns", "maintenance_ns", "acquisition_ns",
                      "checked_rows", "stable_handles", "changed_value"):
                if type(extra[k]) is not int or extra[k] < 0:
                    raise ValueError("invalid diagnostic field")
            if extra["changed_value"] != (i if profile.startswith("sparse-") else 0):
                raise ValueError("stale changed label")
            if profile != "sustained-scroll":
                stable = 0 if i == 0 else 992 if profile == "keyed-churn" and i % 3 == 0 else 1000
                if extra["checked_rows"] != 1000 or extra["stable_handles"] != stable:
                    raise ValueError("wrong row count or replaced retained identities")
            elif extra["checked_rows"] < 2:
                raise ValueError("empty virtual list")
            if i:
                previous = run["samples"][i - 1]
                if sample["submitted_ns"] <= previous["submitted_ns"] or sample["layouts"] < previous["layouts"]:
                    raise ValueError("non-increasing timestamp or counter")
                if any(extra[k] < previous["retained"][k] for k in COUNTERS):
                    raise ValueError("decreasing callback or phase counter")
        measured = run["samples"][warmup_frames:]
        run["summary"] = summarize_samples(measured, run["samples"][warmup_frames - 1], toolkit)
        run["windows"] = [summarize_samples(run["samples"][start:min(start + window_frames, frames)],
                                            run["samples"][start - 1], toolkit)
                          for start in range(warmup_frames, frames, window_frames)]
        # Both clocks are Linux CLOCK_MONOTONIC. Exclude startup, warmup and
        # post-run JSON serialization; retain the unfiltered observations too.
        tolerance = meta.get("epoch_pair_tolerance_ns", 0)
        if type(tolerance) is not int or tolerance < 0:
            raise ValueError("invalid clock tolerance")
        start = meta["epoch_ns"] + run["samples"][warmup_frames - 1]["submitted_ns"] + tolerance
        end = meta["epoch_ns"] + run["samples"][-1]["submitted_ns"] - tolerance
        run["measured_memory"] = [m for m in memory if start <= m["at_ns"] and m["at_ns"] + m["read_ns"] <= end]
        run["status"] = "ok" if result.returncode == 0 else "measurement_complete_cleanup_failed"
    except (ValueError, KeyError, TypeError, IndexError) as error:
        run["reason"] = str(error)
    return run


def process_memory(pid):
    start = time.monotonic_ns()
    try:
        fields = {}
        for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
            name, _, value = line.partition(":")
            if name in ("Rss", "Pss", "Private_Clean", "Private_Dirty"):
                fields[name] = int(value.split()[0])
        return {"at_ns": start, "read_ns": time.monotonic_ns() - start,
                "rss_kib": fields["Rss"], "pss_kib": fields["Pss"],
                "private_kib": fields["Private_Clean"] + fields["Private_Dirty"]}
    except (FileNotFoundError, ProcessLookupError):
        return None


def measure(binary, profile, frames, timeout, prefix, toolkit="Ourokit"):
    memory = []
    timed_out = False
    with prefix.with_suffix(".stdout").open("w") as stdout, prefix.with_suffix(".stderr").open("w") as stderr:
        args = (["--profile", profile, "--frames", str(frames)] if toolkit == "GPUI" else [profile, str(frames)])
        process = subprocess.Popen([str(binary), *args], stdout=stdout, stderr=stderr)
        deadline = time.monotonic() + timeout
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                try:
                    process.wait(timeout=min(1, remaining))
                    break
                except subprocess.TimeoutExpired:
                    observation = process_memory(process.pid)
                    if observation:
                        memory.append(observation)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
    result = SimpleNamespace(returncode=process.returncode,
                             stdout=prefix.with_suffix(".stdout").read_text(errors="replace"),
                             stderr=prefix.with_suffix(".stderr").read_text(errors="replace"))
    return result, memory, timed_out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--gpui-binary", type=Path, help="run adjacent alternating Ourokit/GPUI pairs")
    parser.add_argument("--gpui-build-info", type=Path, help="defaults to gpui-workload-build.json beside GPUI binary")
    parser.add_argument("--profiles", nargs="+", choices=PROFILES, default=list(PROFILES))
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--sparse-frames", type=int, default=331)
    parser.add_argument("--sustained-frames", type=int, default=9631)
    parser.add_argument("--warmup-frames", type=int, default=31)
    parser.add_argument("--window-frames", type=int, default=600)
    parser.add_argument("--timeout", type=float, default=600)
    parser.add_argument("--environment-description", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if (args.iterations < 1 or args.window_frames < 1 or not math.isfinite(args.timeout) or args.timeout <= 0
            or len(set(args.profiles)) != len(args.profiles)
            or any(not 1 <= args.warmup_frames < n - 1 or n > 10000 for n in (args.sparse_frames, args.sustained_frames))):
        parser.error("invalid protocol")
    if args.output.exists():
        parser.error("output exists; use a new evidence path")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    raw = args.output.parent / (args.output.stem + "-raw")
    raw.mkdir()
    root = Path(__file__).resolve().parents[2]
    paths = ("build.zig", "tools/application-benchmark/workload.zig",
             "tools/application-benchmark/workload.lua", "tools/application-benchmark/retained.py")
    binaries = {"Ourokit": args.binary.resolve()}
    gpui_build = None
    if args.gpui_binary:
        binaries["GPUI"] = args.gpui_binary.resolve()
        gpui_build = json.loads((args.gpui_build_info or args.gpui_binary.parent / "gpui-workload-build.json").read_text())
        if hashlib.sha256(args.gpui_binary.read_bytes()).hexdigest() != gpui_build["binary_sha256"]:
            raise ValueError("GPUI binary does not match build metadata")
        paths += tuple("tools/application-benchmark/gpui/" + p for p in gpui_build["files_sha256"])
        paths += ("src/text/fonts/SourceSans3-Regular.otf",)
        for p, h in gpui_build["files_sha256"].items():
            if hashlib.sha256((root / "tools/application-benchmark/gpui" / p).read_bytes()).hexdigest() != h:
                raise ValueError("GPUI source does not match build metadata: " + p)
        if hashlib.sha256((root / paths[-1]).read_bytes()).hexdigest() != gpui_build["font_sha256"]:
            raise ValueError("GPUI font does not match")
    hashes = {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in paths}
    binary_hashes = {k: hashlib.sha256(p.read_bytes()).hexdigest() for k, p in binaries.items()}
    document = {"schema_version": 1, "protocol": {
        "profiles": args.profiles, "iterations": args.iterations, "sparse_frames": args.sparse_frames,
        "toolkits": list(binaries), "order": "Seeded profile shuffle; adjacent toolkit pairs, reversed each iteration with alternating initial toolkit by profile.",
        "sustained_frames": args.sustained_frames, "warmup_frames": args.warmup_frames,
        "window_frames": args.window_frames, "memory_interval_s": 1,
        "timing": "CPU work=build+submit. cycle_work also includes mutation, cancellation/retirement and acquisition calls, not callback waits or diagnostic validation.",
        "limitations": "Programmatic updates; no GPU/display/input latency. Native acquisition is outside work, GPUI acquisition inside Present. GPUI sparse-leaf uses standard cached Entity rows; root/row callback counts reflect each toolkit's behavior. Native layout counts are whole phases, not node visits. Lua heap/cache gauges have no GPUI equivalent here. Process memory excludes GPU allocations; 1Hz smaps reads and callback counters add diagnostic overhead. No forced GC.",
        "statistics": "Per-process medians/p95/p99 and fixed-frame windows; never pool frames across runs. Memory during startup/warmup/serialization excluded from measured_memory. Finite-run stability is not proof of no leaks.",
    }, "environment": {"description": args.environment_description, "kernel": command_output(["uname", "-srmo"]),
                        "revision": command_output(["git", "-C", str(root), "rev-parse", "HEAD"]),
                        "worktree_status": command_output(["git", "-C", str(root), "status", "--porcelain"]),
                        "affinity": sorted(os.sched_getaffinity(0)), "load_before": os.getloadavg(),
                        "binary_sha256": binary_hashes, "source_sha256": hashes,
                        "gpui_build": gpui_build}, "runs": []}
    randomizer = random.Random(0xC0FFEE)
    try:
        for iteration in range(args.iterations):
            order = list(args.profiles)
            randomizer.shuffle(order)
            for profile in order:
                toolkits = list(binaries)
                if (iteration + args.profiles.index(profile)) % 2:
                    toolkits.reverse()
                for toolkit in toolkits:
                    frames = args.sparse_frames if profile.startswith("sparse-") else args.sustained_frames
                    prefix = raw / f"{iteration + 1}-{profile}-{toolkit.lower()}"
                    result, memory, timed_out = measure(binaries[toolkit], profile, frames, args.timeout, prefix, toolkit)
                    run = analyze_run(result, profile, frames, args.warmup_frames, memory, args.window_frames, toolkit)
                    if timed_out:
                        run["status"] = "timeout"
                    run.update(iteration=iteration + 1, raw_prefix=str(prefix))
                    document["runs"].append(run)
                    args.output.write_text(json.dumps(document, indent=2) + "\n")
                    print(json.dumps({k: v for k, v in run.items() if k in ("toolkit", "profile", "status", "reason", "iteration", "summary")}), flush=True)
                    if run["status"] != "ok":
                        raise RuntimeError(f"{toolkit}/{profile}: {run['status']}; raw evidence preserved")
    finally:
        document["environment"]["load_after"] = os.getloadavg()
        document["source_hashes_unchanged"] = all(hashlib.sha256((root / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
        document["binary_hash_unchanged"] = all(hashlib.sha256(p.read_bytes()).hexdigest() == binary_hashes[k] for k, p in binaries.items())
        args.output.write_text(json.dumps(document, indent=2) + "\n")
    if not document["source_hashes_unchanged"] or not document["binary_hash_unchanged"]:
        raise RuntimeError("sources or binary changed during measurement")


if __name__ == "__main__":
    main()
