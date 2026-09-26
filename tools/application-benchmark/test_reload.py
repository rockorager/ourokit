"""Reload measurement logic only; does not exercise the development server."""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from reload import Cli, atomic_edit, measure, semantic_token, source_for, structured, verified_capture, verify_pixels, verify_png


class ReloadTests(unittest.TestCase):
    def test_cli_uses_the_instances_private_runtime_environment(self):
        environment = {"XDG_RUNTIME_DIR": "/private/instance", "WAYLAND_DISPLAY": "/compositor/wayland-0"}
        cli = Cli(Path("/bin/ouroctl"), Path("/private/instance/ourokit/dev/endpoint"), environment)
        with patch("reload.subprocess.run") as run:
            cli.run("inspect", time.monotonic() + 5, {"window": "main"})
        self.assertEqual(run.call_args.kwargs["env"], environment)
        self.assertEqual(run.call_args.args[0][3], "/private/instance/ourokit/dev/endpoint")

    def test_atomic_edit_replaces_inode_and_leaves_open_old_reader_intact(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.lua"
            path.write_text("old source")
            with path.open() as previous:
                before = time.monotonic_ns()
                edited = atomic_edit(path, "new complete source")
                self.assertLessEqual(before, edited)
                self.assertLessEqual(edited, time.monotonic_ns())
                self.assertEqual(previous.read(), "old source")
                self.assertEqual(path.read_text(), "new complete source")
                self.assertFalse(path.with_suffix(".next").exists())

    def test_fixture_has_unique_marker_and_alternating_solid_color(self):
        self.assertIn('"Reload revision 7"', source_for(7))
        self.assertIn('"#0000ff"', source_for(7))
        self.assertIn('"#ff0000"', source_for(8))
        self.assertNotIn("@MARKER@", source_for(8))

    def test_old_marker_or_reused_token_cannot_pass_inspection(self):
        snapshot = {"windows": [{"window": "main", "token": "new", "nodes": [{"label": "Reload revision 9"}]}]}
        self.assertEqual(semantic_token(snapshot, 9, "old"), "new")
        with self.assertRaises(ValueError):
            semantic_token(snapshot, 9, "new")
        with self.assertRaises(ValueError):
            semantic_token(snapshot, 8, "old")

    def test_structured_error_does_not_become_a_success(self):
        data = {"windows": []}
        self.assertEqual(structured(json.dumps(data)), data)
        self.assertEqual(structured(json.dumps({"structuredContent": data})), data)
        with self.assertRaises(ValueError):
            structured('{"isError":true,"structuredContent":{"windows":[]}}')

    def test_retry_reinspects_and_captures_only_the_fresh_token(self):
        cli = Mock()
        cli.json.side_effect = [
            {"windows": [{"window": "main", "token": token, "nodes": [{"label": "Reload revision 9"}]}]}
            for token in ("old", "new")
        ] + [{"token": "new"}]
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "capture.png"
            destination.write_bytes(b"stale file")
            with patch("reload.time.sleep"), patch("reload.verify_png", return_value={}) as verify:
                result = verified_capture(cli, 9, "old", destination, time.monotonic() + 5)
            self.assertFalse(destination.exists(), "stale output must be removed before capture")
            self.assertEqual(result["token"], "new")
            self.assertEqual(len(result["retry_errors"]), 1)
            self.assertEqual([call.args[0] for call in cli.json.call_args_list], ["inspect", "inspect", "capture"])
            self.assertEqual(cli.json.call_args.args[2:], ({"window": "main", "token": "new"}, destination))
            self.assertEqual(verify.call_args.args[2:4], ("new", 9))
            cli.run.assert_not_called()

    def test_pixels_require_correct_large_marker_and_no_old_color(self):
        red, blue, black = b"\xff\x00\x00", b"\x00\x00\xff", b"\x00\x00\x00"
        valid = red * 6000 + black * (128 * 96 - 6000)
        self.assertEqual(verify_pixels(valid, 128, 96, 2)["marker_pixels"], 6000)
        for invalid in (blue * (128 * 96), red * 5999 + black * (128 * 96 - 5999), valid[:-3] + blue):
            with self.assertRaises(ValueError):
                verify_pixels(invalid, 128, 96, 2)
        # These bytes contain 6400 red substrings across pixel boundaries, but
        # every aligned pixel is green or black. A substring counter is wrong.
        crossing = (b"\x00\xff\x00" + black) * 6400
        self.assertEqual(crossing.count(red), 6400)
        with self.assertRaises(ValueError):
            verify_pixels(crossing, 128, 100, 2)

    def test_acknowledgment_is_not_verification_and_reload_is_sent_once(self):
        cli = Mock()
        cli.run.return_value = SimpleNamespace(returncode=0, stdout="generation 9", stderr="")
        with patch("reload.atomic_edit", return_value=100_000_000), \
             patch("reload.time.monotonic_ns", return_value=130_000_000), \
             patch("reload.verified_capture", return_value={"token": "new", "verified_ns": 175_000_000}) as capture:
            sample = measure(cli, Path("unused.lua"), 9, "old", Path("unused.png"), 5)
        self.assertEqual(sample["edit_to_ack_ms"], 30)
        self.assertEqual(sample["edit_to_verified_software_capture_ms"], 75)
        self.assertEqual(cli.run.call_count, 1)
        self.assertEqual(cli.run.call_args.args[0], "reload")
        self.assertEqual(capture.call_args.args[1:3], (9, "old"))
        cli.run.return_value.returncode = 1
        with patch("reload.atomic_edit"), patch("reload.verified_capture") as capture:
            with self.assertRaises(ValueError):
                measure(cli, Path("unused.lua"), 10, "new", Path("unused.png"), 5)
            capture.assert_not_called()

    @unittest.skipUnless(shutil.which("magick"), "PNG verification requires ImageMagick")
    def test_actual_png_decode_and_metadata_correspond_to_inspected_token(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "scene.png"
            subprocess.run(["magick", "-size", "128x96", "xc:red", str(path)], check=True)
            metadata = {"window": "main", "token": "new", "kind": "software_scene_replay",
                        "width": 128, "height": 96, "bytes": path.stat().st_size}
            evidence = verify_png(path, metadata, "new", 2, time.monotonic() + 5)
            self.assertEqual(evidence["marker_pixels"], 128 * 96)
            with self.assertRaises(ValueError):
                verify_png(path, metadata, "old", 2, time.monotonic() + 5)
            with self.assertRaises(ValueError):
                verify_png(path, metadata, "new", 3, time.monotonic() + 5)
            metadata["width"] = 129
            with self.assertRaises(ValueError):
                verify_png(path, metadata, "new", 2, time.monotonic() + 5)


if __name__ == "__main__":
    unittest.main()
