"""Deterministic checks for measurement boundaries; no compositor required."""
import copy
import json
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from run import SwayIpc, WINDOW_EVENT, idle_delta, process_ticks
from scroll import analyze_run, distribution, summarize


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
