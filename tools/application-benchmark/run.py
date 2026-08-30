#!/usr/bin/env python3
"""Measure matched Ourokit, GTK, and Qt Wayland applications.

Startup ends at Sway's `window::new` event. That event is emitted when an
xdg-toplevel maps with its first buffer, giving all three applications one
compositor-observed boundary rather than toolkit-specific readiness hooks.
"""

import argparse
import json
import os
from pathlib import Path
import random
import socket
import statistics
import struct
import subprocess
import sys
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

    def wait_for_app(self, app_id, timeout):
        self.socket.settimeout(timeout)
        while True:
            message_type, payload = self.receive()
            if message_type != WINDOW_EVENT or payload.get("change") != "new":
                continue
            if payload.get("container", {}).get("app_id") == app_id:
                return

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


def cpu_milliseconds(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().split()
    ticks = int(fields[13]) + int(fields[14])
    return ticks * 1000.0 / os.sysconf("SC_CLK_TCK")


def run_once(name, app, settle_seconds, timeout):
    ipc = SwayIpc()
    ipc.subscribe_windows()
    environment = os.environ.copy()
    environment["GDK_BACKEND"] = "wayland"
    environment["GSK_RENDERER"] = "cairo"
    environment["QT_QPA_PLATFORM"] = "wayland"
    started = time.perf_counter_ns()
    process = subprocess.Popen(
        [str(app["binary"])],
        env=environment,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        ipc.wait_for_app(app["app_id"], timeout)
        mapped = time.perf_counter_ns()
        time.sleep(settle_seconds)
        result = {
            "name": name,
            "startup_ms": (mapped - started) / 1_000_000.0,
            "cpu_ms": cpu_milliseconds(process.pid),
            **memory_kib(process.pid),
        }
    finally:
        ipc.close()
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
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
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.iterations < 1 or args.warmups < 0 or args.settle_ms < 0:
        parser.error("iteration counts and settle time must be non-negative")

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
            sample = run_once(name, apps[name], args.settle_ms / 1000.0, args.timeout)
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

    if args.output:
        document = {
            "environment": {
                "platform": sys.platform,
                "kernel": command_output(["uname", "-srmo"]),
                "sway": command_output(["sway", "--version"]),
                "gtk": command_output(["pkg-config", "--modversion", "gtk4"]),
                "qt": command_output(["pkg-config", "--modversion", "Qt6Widgets"]),
            },
            "protocol": {
                "startup_boundary": "process launch to Sway window::new",
                "settle_ms": args.settle_ms,
                "warmups": args.warmups,
                "iterations": args.iterations,
                "gtk_renderer": "cairo",
                "qt_platform": "wayland QWidget raster backing store",
            },
            "samples": samples,
        }
        args.output.write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    main()
