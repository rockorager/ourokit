#!/usr/bin/env python3
"""Measure matched Ourokit, GTK, and Qt Wayland applications.

Startup ends at Sway's `window::new` event. That event is emitted when an
xdg-toplevel maps with its first buffer, giving all three applications one
compositor-observed boundary rather than toolkit-specific readiness hooks.
"""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import random
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import time


MAGIC = b"i3-ipc"
SUBSCRIBE = 2
WINDOW_EVENT = 0x80000003


class SwayIpc:
    def __init__(self):
        path = os.environ.get("SWAYSOCK")
        if not path:
            raise RuntimeError("SWAYSOCK is not set; run the benchmark inside Sway")
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.connect(path)

    def close(self):
        self.socket.close()

    def send(self, message_type, payload):
        data = payload.encode()
        self.socket.sendall(struct.pack("=6sII", MAGIC, len(data), message_type) + data)

    def receive(self):
        header = self._read_exact(14)
        magic, length, message_type = struct.unpack("=6sII", header)
        if magic != MAGIC:
            raise RuntimeError("invalid Sway IPC response")
        return message_type, json.loads(self._read_exact(length))

    def subscribe_windows(self):
        self.send(SUBSCRIBE, '["window"]')
        message_type, payload = self.receive()
        if message_type != SUBSCRIBE or not payload.get("success"):
            raise RuntimeError("Sway rejected window subscription")

    def wait_for_app(self, app_id, pid, timeout):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("application did not map before the deadline")
            self.socket.settimeout(remaining)
            message_type, payload = self.receive()
            if message_type != WINDOW_EVENT or payload.get("change") != "new":
                continue
            container = payload.get("container", {})
            if container.get("app_id") == app_id and container.get("pid") == pid:
                return container

    def _read_exact(self, count):
        chunks = []
        remaining = count
        while remaining:
            chunk = self.socket.recv(remaining)
            if not chunk:
                raise RuntimeError("Sway IPC connection closed")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)


def memory_kib(pid):
    status = parse_kib(Path(f"/proc/{pid}/status"))
    rollup = parse_kib(Path(f"/proc/{pid}/smaps_rollup"))
    return {
        "rss_kib": status["VmRSS"],
        "pss_kib": rollup["Pss"],
        "private_kib": rollup.get("Private_Clean", 0) + rollup.get("Private_Dirty", 0),
    }


def parse_kib(path):
    values = {}
    for line in path.read_text().splitlines():
        key, separator, value = line.partition(":")
        if separator and value.strip().endswith("kB"):
            values[key] = int(value.split()[0])
    return values


def process_ticks(stat):
    # comm can contain spaces and ')'. Fields after the last ')' begin at 3.
    fields = stat.rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])


def activity_snapshot(pid, proc=Path("/proc")):
    started = time.monotonic_ns()
    base = proc / str(pid)
    threads = {}
    churn = False
    for task in (base / "task").iterdir():
        try:
            status = dict(line.split(":", 1) for line in (task / "status").read_text().splitlines())
            threads[task.name] = {
                "cpu_ns": int((task / "schedstat").read_text().split()[0]),
                "voluntary": int(status["voluntary_ctxt_switches"]),
                "involuntary": int(status["nonvoluntary_ctxt_switches"]),
                "start_ticks": int((task / "stat").read_text().rsplit(")", 1)[1].split()[19]),
            }
        except FileNotFoundError:
            churn = True
    ticks = process_ticks((base / "stat").read_text())
    ended = time.monotonic_ns()
    return {"at_ns": (started + ended) // 2, "read_ns": ended - started,
            "process_ticks": ticks, "threads": threads, "thread_churn": churn}


def idle_delta(before, after, ticks_per_second):
    seconds = (after["at_ns"] - before["at_ns"]) / 1e9
    if seconds <= 0:
        raise ValueError("idle measurement interval must be positive")
    stable = (not before["thread_churn"] and not after["thread_churn"] and
              before["threads"].keys() == after["threads"].keys() and
              all(before["threads"][tid]["start_ticks"] == after["threads"][tid]["start_ticks"]
                  for tid in before["threads"]))
    if stable and any(after["threads"][tid][key] < before["threads"][tid][key]
                      for tid in before["threads"] for key in ("cpu_ns", "voluntary", "involuntary")):
        raise ValueError("per-thread counters regressed")
    deltas = {key: sum(after["threads"][tid][key] - before["threads"][tid][key]
                       for tid in before["threads"]) if stable else None
              for key in ("cpu_ns", "voluntary", "involuntary")}
    return {
        "duration_s": seconds,
        "cpu_ms": deltas["cpu_ns"] / 1e6 if stable else None,
        "cpu_percent_one_core": deltas["cpu_ns"] / (seconds * 1e7) if stable else None,
        "process_cpu_ticks": after["process_ticks"] - before["process_ticks"],
        "process_cpu_tick_ms": 1000 / ticks_per_second,
        "voluntary_context_switches": deltas["voluntary"],
        "involuntary_context_switches": deltas["involuntary"],
        "context_switches_per_s": (deltas["voluntary"] + deltas["involuntary"]) / seconds if stable else None,
        "thread_set_stable_at_boundaries": stable,
        "wakeups": None,
        "wakeups_status": "not measured; context switches are not scheduler wakeups",
        "before": before,
        "after": after,
    }


def containers(tree):
    yield tree
    for child in tree.get("nodes", []) + tree.get("floating_nodes", []):
        yield from containers(child)


def run_once(name, app, settle_seconds, timeout, idle_seconds):
    ipc = SwayIpc()
    ipc.subscribe_windows()
    environment = os.environ.copy()
    environment["GDK_BACKEND"] = "wayland"
    environment["GSK_RENDERER"] = "cairo"
    environment["QT_QPA_PLATFORM"] = "wayland"
    errors = tempfile.TemporaryFile()
    process = None
    try:
        started = time.perf_counter_ns()
        process = subprocess.Popen(
            [str(app["binary"]), *app.get("arguments", [])],
            env=environment, stdout=subprocess.DEVNULL, stderr=errors,
        )
        ipc.wait_for_app(app["app_id"], process.pid, timeout)
        mapped = time.perf_counter_ns()
        time.sleep(settle_seconds)
        tree = json.loads(command_output(["swaymsg", "-t", "get_tree", "-r"]))
        container = next(c for c in containers(tree) if c.get("pid") == process.pid and c.get("app_id") == app["app_id"])
        if not container.get("visible"):
            raise RuntimeError("benchmark window must remain visible")
        before = activity_snapshot(process.pid)
        result = {
            "name": name,
            "startup_ms": (mapped - started) / 1_000_000.0,
            "cpu_ms": before["process_ticks"] * 1000 / os.sysconf("SC_CLK_TCK"),
            "settled_geometry": {key: container.get(key) for key in ("rect", "window_rect", "geometry")},
            **memory_kib(process.pid),
        }
        time.sleep(idle_seconds)
        result["idle"] = idle_delta(before, activity_snapshot(process.pid), os.sysconf("SC_CLK_TCK"))
    except Exception as error:
        errors.seek(0)
        diagnostic = errors.read(8192).decode(errors="replace")
        raise RuntimeError(f"{name}: {error}\n{diagnostic}") from error
    finally:
        ipc.close()
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        errors.close()
    if process.returncode not in (0, -15):
        raise RuntimeError(f"{name} exited with status {process.returncode}")
    return result


def median(values, field):
    return statistics.median(value[field] for value in values)


def command_output(arguments):
    return subprocess.check_output(arguments, text=True).strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--warmups", type=int, default=3)
    parser.add_argument("--settle-ms", type=int, default=250)
    parser.add_argument("--idle-seconds", type=float, default=5.0)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--profile", choices=("button", "settings"), default="button")
    args = parser.parse_args()
    if args.iterations < 1 or args.warmups < 0 or args.settle_ms < 0:
        parser.error("iteration counts and settle time must be non-negative")
    if any(not math.isfinite(value) or value <= 0 for value in (args.idle_seconds, args.timeout)):
        parser.error("idle duration and timeout must be finite and positive")

    root = Path(__file__).resolve().parents[2]
    binaries = root / "zig-out" / "benchmark-apps"
    apps = {
        "Ourokit": {
            "binary": binaries / "ourokit",
            "app_id": "dev.ourokit.benchmark.ourokit",
        },
        "GTK 4": {
            "binary": binaries / "gtk",
            "app_id": "dev.ourokit.benchmark.gtk",
        },
        "Qt 6": {
            "binary": binaries / "qt",
            "app_id": "dev.ourokit.benchmark.qt",
        },
    }
    if args.profile == "settings":
        apps = {
            "Ourokit": {
                "binary": binaries / "ourokit-settings",
                "app_id": "dev.ourokit.benchmark.settings.ourokit",
            },
            "GTK 4": {
                "binary": binaries / "gtk",
                "app_id": "dev.ourokit.benchmark.gtk",
                "arguments": ["--settings"],
            },
            "Qt 6": {
                "binary": binaries / "qt",
                "app_id": "dev.ourokit.benchmark.qt",
                "arguments": ["--settings"],
            },
        }
    missing = [str(app["binary"]) for app in apps.values() if not app["binary"].is_file()]
    if missing:
        raise RuntimeError("build benchmarks first; missing: " + ", ".join(missing))

    randomizer = random.Random(0x0A0B0C)
    samples = {name: [] for name in apps}
    for round_index in range(args.warmups + args.iterations):
        order = list(apps)
        randomizer.shuffle(order)
        measured = round_index >= args.warmups
        for name in order:
            sample = run_once(name, apps[name], args.settle_ms / 1000.0, args.timeout, args.idle_seconds)
            if measured:
                samples[name].append(sample)
        print(
            f"{'measure' if measured else 'warmup'} "
            f"{round_index + 1}/{args.warmups + args.iterations}",
            flush=True,
        )

    print("\nMedian of warm-cache launches (lower is better)")
    print(f"{'application':<12} {'startup ms':>11} {'CPU ms':>9} {'RSS MiB':>9} {'PSS MiB':>9} {'private MiB':>12}")
    for name, values in samples.items():
        print(
            f"{name:<12} "
            f"{median(values, 'startup_ms'):>11.2f} "
            f"{median(values, 'cpu_ms'):>9.2f} "
            f"{median(values, 'rss_kib') / 1024:>9.2f} "
            f"{median(values, 'pss_kib') / 1024:>9.2f} "
            f"{median(values, 'private_kib') / 1024:>12.2f}"
        )
        valid = [value["idle"] for value in values if value["idle"]["cpu_ms"] is not None]
        if valid:
            print(f"  idle: {median(valid, 'cpu_percent_one_core'):.4f}% of one core, "
                  f"{median(valid, 'context_switches_per_s'):.3f} context switches/s "
                  f"({len(valid)}/{len(values)} stable-thread samples; NOT wakeups)")

    if args.output:
        document = {
            "schema_version": 2,
            "environment": {
                "platform": sys.platform,
                "kernel": command_output(["uname", "-srmo"]),
                "sway": command_output(["sway", "--version"]),
                "gtk": command_output(["pkg-config", "--modversion", "gtk4"]),
                "qt": command_output(["pkg-config", "--modversion", "Qt6Widgets"]),
                "cpu": next(line.split(":", 1)[1].strip() for line in Path("/proc/cpuinfo").read_text().splitlines() if line.startswith("model name")),
                "affinity": sorted(os.sched_getaffinity(0)),
                "load_average": os.getloadavg(),
                "outputs": json.loads(command_output(["swaymsg", "-t", "get_outputs", "-r"])),
                "revision": command_output(["git", "-C", str(root), "rev-parse", "HEAD"]),
                "binaries_sha256": {name: hashlib.sha256(app["binary"].read_bytes()).hexdigest() for name, app in apps.items()},
            },
            "protocol": {
                "startup_boundary": "process launch to Sway window::new",
                "settle_ms": args.settle_ms,
                "idle_seconds": args.idle_seconds,
                "ourokit_renderer": "software explicitly selected; no Vulkan initialization",
                "cpu_boundary": "process launch through settle; process utime+stime, includes all threads; tick resolution",
                "idle_boundary": "two /proc snapshots after settle; sum schedstat runtime and status context switches over live tasks",
                "idle_limitations": "boundary-stable tasks only; threads born and exited between snapshots are invisible to schedstat/status, but included in process CPU ticks; child processes and compositor excluded",
                "warmups": args.warmups,
                "iterations": args.iterations,
                "gtk_renderer": "cairo",
                "qt_platform": "wayland QWidget raster backing store",
                "profile": args.profile,
            },
            "samples": samples,
        }
        args.output.write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    main()
