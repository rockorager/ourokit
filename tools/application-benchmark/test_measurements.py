"""Deterministic checks for measurement boundaries; no compositor required."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from run import SwayIpc, WINDOW_EVENT, applications, gpui_build_metadata, idle_delta, process_ticks
from scroll import analyze_run, distribution, summarize
from workload import analyze_run as analyze_workload


class ApplicationTests(unittest.TestCase):
    def test_original_button_defaults_keep_software_and_original_ids(self):
        apps = applications(Path("/binaries"), "button", ["ourokit", "gtk", "qt"], "software")
        self.assertEqual(list(apps), ["Ourokit", "GTK 4", "Qt 6"])
        self.assertEqual(apps["Ourokit"]["binary"], Path("/binaries/ourokit"))
        self.assertEqual(apps["Ourokit"]["app_id"], "dev.ourokit.benchmark.ourokit")
        self.assertTrue(all(app["arguments"] == [] for app in apps.values()))

    def test_gpu_settings_subset_selects_correct_executable_and_arguments(self):
        apps = applications(Path("/binaries"), "settings", ["gpui", "ourokit"], "vulkan")
        self.assertEqual(list(apps), ["GPUI", "Ourokit"])
        self.assertEqual(apps["GPUI"]["binary"], Path("/binaries/gpui"))
        self.assertEqual(apps["GPUI"]["arguments"], ["--settings"])
        self.assertEqual(apps["Ourokit"]["binary"], Path("/binaries/ourokit-settings"))
        self.assertEqual(apps["Ourokit"]["arguments"], ["--vulkan"])
        self.assertEqual(apps["Ourokit"]["app_id"], "dev.ourokit.benchmark.settings.ourokit")
        legacy = applications(Path("/binaries"), "settings", ["gtk", "qt"], "software")
        self.assertTrue(all(app["arguments"] == ["--settings"] for app in legacy.values()))

    def test_provenance_rejects_changed_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "gpui"
            binary.write_bytes(b"verified binary")
            metadata = {"binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest()}
            (binary.parent / "gpui-build.json").write_text(json.dumps(metadata))
            self.assertEqual(gpui_build_metadata(binary), metadata)
            binary.write_bytes(b"another binary")
            with self.assertRaisesRegex(RuntimeError, "does not match"):
                gpui_build_metadata(binary)


class WorkloadTests(unittest.TestCase):
    def records(self, profile="scroll"):
        meta = {"kind": "metadata", "toolkit": "GPUI", "profile": profile, "frames": 4,
                "row_count": 10000 if profile == "scroll" else 1000, "viewport": [640, 720],
                "font": "Source Sans 3", "font_size": 14, "font_weight": 400, "row_padding": 4,
                "line_height": 18.5625, "scale_factor": 1, "active": True}
        samples = [{"kind": "sample", "frame": i, "offset": i * 14 if profile == "scroll" else 0,
                    "row_height": 32 if profile == "relayout" and i % 2 else 28,
                    "build_ns": build * 1_000_000, "submit_ns": submit * 1_000_000,
                    "work_ns": (build + submit) * 1_000_000, "submitted_ns": timestamp * 1_000_000}
                   for i, (build, submit, timestamp) in enumerate([(9, 99, 110), (3, 2, 200), (13, 7, 240), (8, 2, 290)])]
        return [meta, *samples]

    def analyze(self, records, profile="scroll", returncode=0, suffix=""):
        # Sorted JSON deliberately places kind after other keys.
        result = SimpleNamespace(stdout="\n".join(json.dumps(r, sort_keys=True) for r in records),
                                 stderr="adapter diagnostic\n" + suffix, returncode=returncode)
        return analyze_workload(result, "GPUI", profile, 4, 1)

    def test_warmup_excluded_and_frame_cpu_work_is_not_callback_cadence(self):
        run = self.analyze(self.records())
        self.assertEqual(run["status"], "ok")
        self.assertEqual(run["summary"]["work_ms"]["median"], 10)
        self.assertEqual(run["summary"]["work_ms"]["p95"], 20)
        self.assertEqual(run["summary"]["build_ms"]["median"], 8)
        self.assertEqual(run["summary"]["submission_interval_ms"]["median"], 45)
        self.assertEqual(run["summary"]["submission_interval_ms"]["count"], 2)
        self.assertEqual(run["summary"]["cpu_work_over_16_67_ms"], 1)

    def test_rejects_wrong_work_or_missing_frames_without_losing_samples(self):
        for field, value in [("frame", 1), ("offset", 14), ("row_height", 32),
                             ("work_ns", 1), ("build_ns", -1), ("submitted_ns", 1)]:
            records = self.records()
            records[3][field] = value
            run = self.analyze(records)
            self.assertEqual(run["status"], "failed", field)
            self.assertEqual(len(run["samples"]), 4)
        self.assertEqual(self.analyze(self.records()[:-1])["status"], "failed")

    def test_relayout_checks_both_heights_and_rebuild_checks_retained_text(self):
        records = self.records("relayout")
        self.assertEqual(self.analyze(records, "relayout")["status"], "ok")
        records[2]["row_height"] = 28
        self.assertEqual(self.analyze(records, "relayout")["status"], "failed")
        records = self.records("rebuild")
        records[3]["first_value"] = 1  # Generation 2 must not display generation 1.
        self.assertEqual(self.analyze(records, "rebuild")["status"], "failed")

    def test_wrong_font_or_metadata_and_malformed_json_are_failures(self):
        for key, value in [("font", "Host default"), ("font_weight", 500),
                           ("row_padding", 5), ("scale_factor", 2), ("active", False)]:
            records = self.records()
            records[0][key] = value
            self.assertEqual(self.analyze(records)["status"], "failed", key)
        run = self.analyze(self.records(), suffix='{"kind":')
        self.assertEqual(run["status"], "failed")
        self.assertEqual(len(run["samples"]), 4)
        self.assertIn('{"kind":', run["diagnostics"])

    def test_completed_measurement_survives_teardown_failure(self):
        run = self.analyze(self.records(), returncode=1)
        self.assertEqual(run["status"], "measurement_complete_cleanup_failed")
        self.assertEqual(run["summary"]["measured_frames"], 3)


class IdleTests(unittest.TestCase):
    def snapshots(self):
        before = {"at_ns": 1_000_000_000, "read_ns": 100, "process_ticks": 91,
                  "thread_churn": False, "threads": {
                      "10": {"start_ticks": 5, "cpu_ns": 5_000_000, "voluntary": 19, "involuntary": 2},
                      "11": {"start_ticks": 7, "cpu_ns": 9_000_000, "voluntary": 31, "involuntary": 5}}}
        after = copy.deepcopy(before)
        after.update(at_ns=3_000_000_000, process_ticks=94)
        after["threads"]["10"].update(cpu_ns=6_000_000, voluntary=20, involuntary=4)
        after["threads"]["11"].update(cpu_ns=38_000_000, voluntary=37, involuntary=8)
        return before, after

    def test_counts_worker_cpu_and_both_switch_types_over_actual_interval(self):
        value = idle_delta(*self.snapshots(), 100)
        self.assertEqual(value["cpu_ms"], 30)
        self.assertEqual(value["cpu_percent_one_core"], 1.5)
        self.assertEqual(value["voluntary_context_switches"], 7)
        self.assertEqual(value["involuntary_context_switches"], 5)
        self.assertEqual(value["context_switches_per_s"], 6)
        self.assertEqual(value["process_cpu_ticks"], 3)
        self.assertIsNone(value["wakeups"])

    def test_churn_and_tid_reuse_are_not_zero_idle(self):
        for change in ("removed", "reused", "raced"):
            before, after = self.snapshots()
            if change == "removed":
                del after["threads"]["11"]
            elif change == "reused":
                after["threads"]["11"]["start_ticks"] += 1
            else:
                after["thread_churn"] = True
            value = idle_delta(before, after, 100)
            self.assertIsNone(value["cpu_ms"])
            self.assertIsNone(value["context_switches_per_s"])
            self.assertEqual(value["process_cpu_ticks"], 3)

    def test_proc_comm_with_spaces_and_closing_parentheses(self):
        fields = ["S"] + ["0"] * 10 + ["17", "29", "99", "88"]
        self.assertEqual(process_ticks("42 (a name ) too) " + " ".join(fields)), 46)

    def test_rejects_counter_regression_and_empty_interval(self):
        before, after = self.snapshots()
        # A busy worker must not conceal the main thread's regressed counter.
        after["threads"]["10"]["cpu_ns"] = 0
        with self.assertRaises(ValueError):
            idle_delta(before, after, 100)
        with self.assertRaises(ValueError):
            idle_delta(before, before, 100)


class IpcTests(unittest.TestCase):
    def ipc(self):
        ipc = object.__new__(SwayIpc)
        ipc.socket = Mock()
        return ipc

    def test_wait_matches_pid_as_well_as_app_id(self):
        ipc = self.ipc()
        old = {"app_id": "app", "pid": 12}
        new = {"app_id": "app", "pid": 25}
        ipc.receive = Mock(side_effect=[(WINDOW_EVENT, {"change": "new", "container": c}) for c in (old, new)])
        self.assertEqual(ipc.wait_for_app("app", 25, 5), new)
        self.assertEqual(ipc.receive.call_count, 2)

    def test_unrelated_events_do_not_restart_timeout(self):
        ipc = self.ipc()
        ipc.receive = Mock(return_value=(WINDOW_EVENT, {"change": "focus"}))
        with patch("run.time.monotonic", side_effect=[0, 1, 4, 6]):
            with self.assertRaises(TimeoutError):
                ipc.wait_for_app("app", 25, 5)
        self.assertEqual([call.args[0] for call in ipc.socket.settimeout.call_args_list], [4, 1])


class PresentationTests(unittest.TestCase):
    def samples(self):
        return [{"frame": i, "input_ns": t - latency, "submitted_ns": t - 500_000,
                 "presented_ns": t, "feedback_received_ns": t + 2_000_000,
                 "offset": i * 24, "clock_id": 1, "refresh_ns": 10_000_000,
                 "hardware_clock": False, "hardware_completion": False, "vsync": False}
                for i, (t, latency) in enumerate(zip(
                    [10_000_000, 30_000_000, 45_000_000, 65_000_001],
                    [9_000_000, 3_000_000, 5_000_000, 7_000_000]))]

    def test_warmup_excluded_and_feedback_receipt_is_not_presentation(self):
        value = summarize(self.samples(), 1)
        self.assertEqual(value["runtime_input_to_presentation_ms"]["median"], 5)
        self.assertEqual(value["runtime_input_to_submission_ms"]["median"], 4.5)
        self.assertEqual(value["presentation_interval_ms"]["count"], 2)
        self.assertEqual(value["intervals_over_1_5_refresh"], 1)
        self.assertEqual(value["hardware_completion_frames"], 0)

    def test_other_clock_allows_pacing_but_not_cross_clock_latency(self):
        samples = self.samples()
        for sample in samples:
            sample["clock_id"] = 4
            sample["presented_ns"] += 9_000_000_000
        value = summarize(samples, 1)
        self.assertIsNone(value["runtime_input_to_presentation_ms"])
        self.assertEqual(value["presentation_interval_ms"]["min"], 15)

    def test_clock_change_disables_pacing_too(self):
        samples = self.samples()
        samples[2]["clock_id"] = 4
        value = summarize(samples, 1)
        self.assertIsNone(value["presentation_interval_ms"])
        self.assertIsNone(value["runtime_input_to_presentation_ms"])

    def test_bad_correlations_fail_instead_of_reporting_fast_latency(self):
        for field, value in (("frame", 9), ("offset", 24), ("presented_ns", 1), ("input_ns", 999_000_000)):
            samples = self.samples()
            samples[2][field] = value
            with self.assertRaises(ValueError):
                summarize(samples, 1)

    def test_unknown_refresh_is_not_zero_missed_frames(self):
        samples = self.samples()
        for sample in samples:
            sample["refresh_ns"] = 0
        self.assertIsNone(summarize(samples, 1)["intervals_over_1_5_refresh"])

    def test_nearest_rank_tail_and_empty_distribution(self):
        self.assertEqual(distribution(list(range(1, 101)))["p95"], 95)
        self.assertEqual(distribution([2, 100, 7])["p99"], 100)
        self.assertIsNone(distribution([]))

    def test_complete_trace_survives_cleanup_failure_without_hiding_it(self):
        stderr = "info: output\n" + "\n".join(map(json.dumps, self.samples())) + "\nerror: cleanup\n"
        run = analyze_run(SimpleNamespace(stderr=stderr, returncode=1), 4, 1)
        self.assertEqual(run["status"], "measurement_complete_cleanup_failed")
        self.assertEqual(run["returncode"], 1)
        self.assertEqual(run["summary"]["measured_frames"], 3)
        self.assertIn("error: cleanup", run["diagnostics"])
        partial = analyze_run(SimpleNamespace(stderr=stderr, returncode=1), 5, 1)
        self.assertEqual(partial["status"], "failed")
        self.assertNotIn("summary", partial)


if __name__ == "__main__":
    unittest.main()
