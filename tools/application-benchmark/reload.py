#!/usr/bin/env python3
"""Measure atomic edit completion -> verified software-scene capture.

Requires the integrated `ouroctl dev` CLI, a Wayland compositor and ImageMagick.
CLI startup, inspect/capture retries, PNG copying/decoding and pixel verification
are included. This is not compositor-visible or presentation latency. Only a
temporary benchmark fixture is edited; a private --dev instance is launched.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import time

from scroll import distribution


def marker(revision):
    return f"Reload revision {revision}"


def source_for(revision):
    template = Path(__file__).with_suffix(".lua").read_text()
    return template.replace("@MARKER@", marker(revision)).replace(
        "@COLOR@", "#ff0000" if revision % 2 == 0 else "#0000ff")


def atomic_edit(path, source):
    replacement = path.with_suffix(".next")
    with replacement.open("w") as stream:
        stream.write(source)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(replacement, path)
    return time.monotonic_ns()


def remaining(deadline):
    seconds = deadline - time.monotonic()
    if seconds <= 0:
        raise TimeoutError("edit/capture deadline expired")
    return seconds


def structured(stdout):
    value = json.loads(stdout)
    if not isinstance(value, dict):
        return value
    if value.get("isError") or "error" in value:
        raise ValueError(f"development operation failed: {value}")
    # Both a CLI structured object and a complete MCP tool-result wrapper have
    # explicit shapes; never interpret a text-content fallback as success.
    return value.get("structuredContent", value)


class Cli:
    def __init__(self, binary, endpoint, environment):
        self.binary, self.endpoint = str(binary), str(endpoint)
        self.environment = environment

    def run(self, operation, deadline, arguments=None, output=None):
        command = [self.binary, "dev", operation, self.endpoint]
        if arguments is not None:
            command.append(json.dumps(arguments))
        if output is not None:
            command.extend(["--output", str(output)])
        return subprocess.run(command, env=self.environment, capture_output=True, text=True, timeout=remaining(deadline))

    def json(self, operation, deadline, arguments=None, output=None):
        result = self.run(operation, deadline, arguments, output)
        if result.returncode:
            raise ValueError(f"{operation}: {result.stderr.strip()} {result.stdout.strip()}")
        return structured(result.stdout)


def semantic_token(snapshot, revision, previous_token):
    windows = [window for window in snapshot["windows"] if window["window"] == "main"]
    if len(windows) != 1:
        raise ValueError("expected exactly one main window")
    window = windows[0]
    token = window["token"]
    if not isinstance(token, str) or not token or token == previous_token:
        raise ValueError("missing or stale inspection token")
    if not any(node.get("label") == marker(revision) for node in window["nodes"]):
        raise ValueError("new semantic marker has not appeared")
    return token


def verify_pixels(rgb, width, height, revision):
    if width < 128 or height < 96 or len(rgb) != width * height * 3:
        raise ValueError("unexpected capture dimensions or RGB byte count")
    expected = b"\xff\x00\x00" if revision % 2 == 0 else b"\x00\x00\xff"
    old = b"\x00\x00\xff" if revision % 2 == 0 else b"\xff\x00\x00"
    # Count aligned pixels, not byte substrings spanning pixel boundaries.
    pixels = memoryview(rgb).cast("B")
    matches = sum(pixels[i:i + 3] == expected for i in range(0, len(rgb), 3))
    stale = sum(pixels[i:i + 3] == old for i in range(0, len(rgb), 3))
    if matches < 6000 or stale:
        raise ValueError(f"wrong color marker: expected {matches} pixels, stale {stale}")
    return {"marker_pixels": matches, "rgb_sha256": hashlib.sha256(rgb).hexdigest()}


def verify_png(path, capture, token, revision, deadline):
    if capture["window"] != "main" or capture["token"] != token or capture["kind"] != "software_scene_replay":
        raise ValueError("capture does not match inspected software scene")
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("capture is not a PNG")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height, len(data)) != (capture["width"], capture["height"], capture["bytes"]):
        raise ValueError("PNG dimensions/size differ from capture metadata")
    rgb = subprocess.check_output(["magick", str(path), "-depth", "8", "rgb:-"], timeout=remaining(deadline))
    evidence = verify_pixels(rgb, width, height, revision)
    remaining(deadline)
    return {**evidence, "png_sha256": hashlib.sha256(data).hexdigest(), "copy": str(path)}


def verified_capture(cli, revision, previous_token, destination, deadline):
    failures = []
    while True:
        remaining(deadline)
        try:
            snapshot = cli.json("inspect", deadline, {"window": "main"})
            token = semantic_token(snapshot, revision, previous_token)
            inspected = time.monotonic_ns()
            destination.unlink(missing_ok=True)
            capture = cli.json("capture", deadline, {"window": "main", "token": token}, destination)
            captured = time.monotonic_ns()
            evidence = verify_png(destination, capture, token, revision, deadline)
            return {"token": token, "inspected_ns": inspected, "captured_ns": captured,
                    "verified_ns": time.monotonic_ns(), "capture": capture,
                    "evidence": evidence, "retry_errors": failures}
        except (ValueError, KeyError) as error:
            # Only read-only inspect/capture operations are retried. Reload is
            # issued exactly once. Count all retry/poll overhead in the result.
            failures.append(str(error))
            if deadline - time.monotonic() <= .01:
                raise TimeoutError(f"capture verification failed: {failures[-1]}") from error
            time.sleep(.01)


def measure(cli, source, revision, previous_token, destination, timeout):
    edited = atomic_edit(source, source_for(revision))
    deadline = time.monotonic() + timeout
    result = cli.run("reload", deadline)
    acknowledged = time.monotonic_ns()
    if result.returncode:
        raise ValueError(f"reload failed: {result.stderr} {result.stdout}")
    capture = verified_capture(cli, revision, previous_token, destination, deadline)
    return {"revision": revision, "edited_ns": edited, "acknowledged_ns": acknowledged,
            "reload_ack": result.stdout.strip(), **capture,
            "edit_to_ack_ms": (acknowledged - edited) / 1e6,
            "edit_to_verified_software_capture_ms": (capture["verified_ns"] - edited) / 1e6}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[2]
    parser.add_argument("--binary", type=Path, default=root / "zig-out/bin/ouroctl")
    parser.add_argument("--iterations", type=int, default=5)
    parser.add_argument("--warmups", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--environment-description", required=True, help="build mode and compositor version/backend/output")
    args = parser.parse_args()
    if args.iterations < 1 or args.warmups < 0 or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("invalid iterations, warmups, or timeout")
    binary = args.binary.resolve(strict=True)
    display = Path(os.environ.get("WAYLAND_DISPLAY", "wayland-0"))
    if not display.is_absolute():
        display = Path(os.environ["XDG_RUNTIME_DIR"]) / display
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    captures = output.parent / (output.stem + "-captures")
    captures.mkdir(exist_ok=True)
    document = {"schema_version": 1, "status": "failed", "samples": [], "warmups": [],
                "environment": {"description": args.environment_description,
                                "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                                "kernel": os.uname().release, "affinity": sorted(os.sched_getaffinity(0))},
                "protocol": {"iterations": args.iterations, "warmups": args.warmups, "timeout_s": args.timeout,
                             "boundary": "atomic source replacement completed to verified copied software-scene PNG",
                             "includes": "reload CLI, inspect/capture CLI, retries, PNG copy, decode and pixel verification",
                             "presentation_latency": None, "presentation_status": "not measured"}}
    with tempfile.TemporaryDirectory(prefix="ouro-reload-") as directory:
        directory = Path(directory)
        source = directory / "app.lua"
        atomic_edit(source, source_for(0))
        env = dict(os.environ, XDG_RUNTIME_DIR=str(directory), WAYLAND_DISPLAY=str(display))
        for name in ("LISTEN_PID", "LISTEN_FDS", "LISTEN_FDNAMES", "WAYLAND_SOCKET"):
            env.pop(name, None)
        log = directory / "application.log"
        process = None
        try:
            with log.open("wb") as stream:
                process = subprocess.Popen([str(binary), "run", str(source), "--software", "--dev"], env=env,
                                           stdout=stream, stderr=subprocess.STDOUT)
            deadline = time.monotonic() + args.timeout
            endpoint = None
            while endpoint is None:
                remaining(deadline)
                if process.poll() is not None:
                    raise RuntimeError("development instance exited before publishing an endpoint")
                for line in log.read_text().splitlines():
                    if "development socket: " in line:
                        endpoint = Path(line.split("development socket: ", 1)[1].strip())
                if endpoint is None:
                    time.sleep(.01)
            if not endpoint.is_relative_to(directory):
                raise ValueError("development endpoint escaped private runtime directory")
            cli = Cli(binary, endpoint, env)
            current = verified_capture(cli, 0, None, captures / "initial.png", deadline)
            for revision in range(1, args.warmups + args.iterations + 1):
                current = measure(cli, source, revision, current["token"], captures / f"{revision:04}.png", args.timeout)
                document["warmups" if revision <= args.warmups else "samples"].append(current)
                print(f"revision {revision}: {current['edit_to_verified_software_capture_ms']:.3f} ms", flush=True)
            # Rejected source is not a successful latency sample. Verify that
            # last-good semantic AND raster content remain available afterward.
            atomic_edit(source, "return ouro.app {\n")
            deadline = time.monotonic() + args.timeout
            rejected = cli.run("reload", deadline)
            if rejected.returncode == 0:
                raise ValueError("invalid source reload unexpectedly succeeded")
            preserved = verified_capture(cli, revision, None, captures / "rejected.png", deadline)
            if preserved["evidence"]["rgb_sha256"] != current["evidence"]["rgb_sha256"]:
                raise ValueError("rejected source changed last-good raster content")
            document["rejected_edit"] = {"reload_returncode": rejected.returncode,
                                         "stdout": rejected.stdout, "stderr": rejected.stderr,
                                         "diagnostics": cli.json("diagnostics", deadline), "preserved": preserved}
            document["summary"] = {field: distribution([sample[field] for sample in document["samples"]])
                                   for field in ("edit_to_ack_ms", "edit_to_verified_software_capture_ms")}
            document["status"] = "ok"
        except Exception as error:
            document["error"] = str(error)
        finally:
            if process is not None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                document["application_exit"] = process.returncode
                # The runner handles SIGTERM, drains ownership, and returns 143.
                if document["status"] == "ok" and process.returncode not in (0, -15, 143):
                    document.update(status="measurement_complete_cleanup_failed",
                                    error=f"application exited with {process.returncode}")
            document["application_log"] = log.read_text() if log.exists() else ""
    output.write_text(json.dumps(document, indent=2) + "\n")
    if document["status"] != "ok":
        raise SystemExit(f"Reload measurement failed; see {output}: {document.get('error')}")


if __name__ == "__main__":
    main()
