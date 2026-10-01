import copy
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from retained import analyze_run, expected_position, process_memory


class RetainedTests(unittest.TestCase):
    def records(self, profile="sparse-leaf"):
        metadata = {"kind": "metadata", "toolkit": "Ourokit", "profile": profile, "frames": 4,
                    "row_count": 10000 if profile == "sustained-scroll" else 1000,
                    "viewport": [640, 720], "font": "Source Sans 3", "font_size": 14,
                    "font_weight": 400, "line_height": 18.5625, "row_padding": 4,
                    "active": True, "scale_factor": 1, "backend": "vulkan_dmabuf", "epoch_ns": 1000}
        samples = []
        for i, (build, submit) in enumerate(((999, 999), (2, 3), (11, 7), (5, 1))):
            offset, first = ((0, 1), (0, 1000), (0, 18), (0, 9))[i] if profile == "keyed-churn" else (0, 1)
            if profile == "sustained-scroll":
                offset, first = ((0, 1), (112, 5), (224, 9), (336, 13))[i]
            samples.append({"kind": "sample", "frame": i, "offset": offset, "first_row": first,
                            "first_value": 0, "row_height": 28, "build_ns": build * 1_000_000,
                            "submit_ns": submit * 1_000_000, "work_ns": (build + submit) * 1_000_000,
                            "submitted_ns": (i + 1) * 100, "nodes": 2004, "commands": 4005,
                            "layouts": i + 1, "retained": {
                                "mutation_ns": i * 1_000_000, "maintenance_ns": 2_000_000,
                                "acquisition_ns": 3_000_000, "root_calls": 1,
                                "row_calls": 1000 + i, "builds": i + 1, "paints": i + 1,
                                "lua_heap_bytes": (100, 900, 250, 800)[i],
                                "source_entries": 1000, "paragraph_entries": 1000,
                                "source_index_capacity": 2048, "paragraph_index_capacity": 2048,
                                "source_slabs": 63, "paragraph_slabs": 63, "retiring_instances": 0,
                                "checked_rows": 30 if profile == "sustained-scroll" else 1000,
                                "changed_value": i if profile.startswith("sparse-") else 0,
                                "stable_handles": 0 if i == 0 else 992 if profile == "keyed-churn" and i == 3 else 1000}})
        return [metadata, *samples]

    def analyze(self, records, profile="sparse-leaf", memory=(), code=0):
        result = SimpleNamespace(returncode=code, stdout="", stderr="\n".join(json.dumps(r) for r in records))
        return analyze_run(result, profile, 4, 1, memory, window_frames=2)

    def test_phases_counter_deltas_and_partial_windows_exclude_warmup(self):
        run = self.analyze(self.records())
        self.assertEqual(run["status"], "ok")
        summary = run["summary"]
        self.assertEqual(summary["work_ms"]["median"], 6)
        self.assertEqual(summary["work_ms"]["p95"], 18)
        self.assertEqual(summary["cycle_work_ms"]["median"], 14)  # 11, 25, 14 ms.
        self.assertEqual(summary["counter_deltas"]["root_calls"], 0)
        self.assertEqual(summary["counter_deltas"]["row_calls"], 3)
        self.assertEqual(summary["layout_phase_delta"], 3)
        self.assertEqual(summary["gauges"]["lua_heap_bytes"], {"first": 900, "last": 800, "min": 250, "max": 900})
        self.assertEqual([w["count"] for w in run["windows"]], [2, 1])
        self.assertEqual([w["counter_deltas"]["row_calls"] for w in run["windows"]], [2, 1])

    def test_scroll_reversal_and_churn_boundaries(self):
        for frame, expected in [(2399, (268688, 9597)), (2400, (268800, 9601)),
                                (2401, (268688, 9597)), (4799, (112, 5)),
                                (4800, (0, 1)), (4801, (112, 5))]:
            self.assertEqual(expected_position("sustained-scroll", frame), expected)
        for frame, first in [(0, 1), (1, 1000), (2, 18), (3, 9), (4, 1008), (5, 26), (6, 17)]:
            self.assertEqual(expected_position("keyed-churn", frame), (0, first))
        for profile in ("keyed-churn", "sustained-scroll", "sparse-parent"):
            self.assertEqual(self.analyze(self.records(profile), profile)["status"], "ok")

    def test_rejects_stale_values_missing_rows_and_identity_replacements(self):
        for key, value in [("changed_value", 0), ("checked_rows", 999), ("stable_handles", 999),
                           ("row_calls", 2), ("lua_heap_bytes", -1), ("maintenance_ns", float("nan"))]:
            records = self.records()
            records[3]["retained"][key] = value
            run = self.analyze(records)
            self.assertEqual(run["status"], "failed", key)
            self.assertEqual(len(run["samples"]), 4)
        records = self.records("keyed-churn")
        records[4]["retained"]["stable_handles"] = 1000
        self.assertEqual(self.analyze(records, "keyed-churn")["status"], "failed")
        records = self.records()
        records[3]["work_ns"] += 1
        self.assertEqual(self.analyze(records)["status"], "failed")
        self.assertEqual(self.analyze(self.records()[:-1])["status"], "failed")

    def test_memory_excludes_startup_warmup_serialization_and_straddling_reads(self):
        observations = [{"at_ns": t, "read_ns": 10} for t in (900, 1099, 1100, 1390, 1391, 1500)]
        run = self.analyze(self.records(), memory=observations)
        self.assertEqual([m["at_ns"] for m in run["measured_memory"]], [1100, 1390])
        self.assertEqual(run["memory"], observations)

    def test_metadata_and_teardown_failures_are_not_success(self):
        records = self.records()
        for key, value in [("active", False), ("backend", "software"), ("font_size", 15)]:
            changed = copy.deepcopy(records)
            changed[0][key] = value
            self.assertEqual(self.analyze(changed)["status"], "failed")
        self.assertEqual(self.analyze(records, code=1)["status"], "measurement_complete_cleanup_failed")

    def test_process_memory_is_not_gpu_or_shared_memory_double_counting(self):
        with patch("retained.Path.read_text", return_value="Rss: 210 kB\nPss: 120 kB\nPrivate_Clean: 12 kB\nPrivate_Dirty: 80 kB\nShared_Clean: 118 kB\n"):
            result = process_memory(123)
        self.assertEqual((result["rss_kib"], result["pss_kib"], result["private_kib"]), (210, 120, 92))

    def test_gpui_sparse_comparison_checks_output_and_actual_callbacks(self):
        records = self.records()
        records[0].update(toolkit="GPUI", completed_frames=4, status="complete")
        for i, s in enumerate(records[1:]):
            s.update(root_calls=i + 1, row_calls=1000 + i, row_build_count=1,
                     checked_rows=1000, changed_value=i, first_row_bounds=[0, 0, 640, 28])
            del s["retained"]
        def analyze(values):
            result = SimpleNamespace(returncode=0, stdout="\n".join(map(json.dumps, values)), stderr="")
            return analyze_run(result, "sparse-leaf", 4, 1, toolkit="GPUI")
        run = analyze(records)
        self.assertEqual(run["status"], "ok")
        self.assertEqual(run["summary"]["work_ms"]["median"], 6)
        self.assertEqual(run["summary"]["counter_deltas"], {"root_calls": 3, "row_calls": 3})
        for key, value in [("changed_value", 0), ("row_build_count", 1000),
                           ("first_row_bounds", [0, 0, 640, 32]), ("checked_rows", 999)]:
            bad = copy.deepcopy(records)
            bad[3][key] = value
            self.assertEqual(analyze(bad)["status"], "failed", key)

    def test_gpui_scroll_rejects_ranges_that_miss_visible_row(self):
        records = self.records("sustained-scroll")
        records[0].update(toolkit="GPUI", completed_frames=4, status="complete")
        for i, s in enumerate(records[1:]):
            s.update(root_calls=i + 1, row_calls=(i + 1) * 26, row_build_count=26,
                     checked_rows=0, changed_value=0, row_build_ranges=[[i * 4, i * 4 + 26]])
        result = lambda: SimpleNamespace(returncode=0, stdout="\n".join(map(json.dumps, records)), stderr="")
        self.assertEqual(analyze_run(result(), "sustained-scroll", 4, 1, toolkit="GPUI")["status"], "ok")
        records[3]["row_build_ranges"] = [[9, 35]]  # First visible index is 8, not 9.
        self.assertEqual(analyze_run(result(), "sustained-scroll", 4, 1, toolkit="GPUI")["status"], "failed")


if __name__ == "__main__":
    unittest.main()
