import importlib.util
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "concurrency-qualification.py"

spec = importlib.util.spec_from_file_location("concurrency_qualification", SCRIPT)
cq = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(cq)


def known(value):
    return {"state": "known", "value": value}


def provider_row(task_id, provider_session_id, state="active"):
    return {
        "task_association": {
            "kind": "exact",
            "task_session_id": known(task_id),
        },
        "worker": {
            "provider_session_id": known(provider_session_id),
            "runtime_reconciliation": {
                "provider_reported_state": state,
                "disposition": (
                    "consistent_active" if state == "active" else "consistent_inactive"
                ),
            },
        },
    }


def snapshot(limit=4, used=0, active_total=0, active_unknown=0):
    return {
        "observed_at": "2026-09-24T16:00:00Z",
        "provider_sessions": {"items": []},
        "capacity": {
            "task_control_slots": {
                "used": known(used),
                "limit": known(limit),
                "pending_create_reservations": known(0),
                "queued_prompt_reservations": known(0),
            },
            "discovered_provider_sessions": {
                "known_count": 0,
                "unknown_count": 0,
                "total": known(0),
                "basis": "fixture",
            },
            "supervised_provider_sessions": {
                "known_count": 0,
                "unknown_count": 0,
                "total": known(0),
                "basis": "fixture",
            },
            "provider_reported_active_turns": {
                "known_count": active_total,
                "unknown_count": active_unknown,
                "total": known(active_total) if active_unknown == 0 else {"state": "unknown"},
                "basis": "fixture",
            },
            "provider_hosts": {
                "known_count": 0,
                "unknown_count": 0,
                "total": known(0),
                "basis": "fixture",
            },
            "observed_child_processes": {
                "known_count": 0,
                "unknown_count": 0,
                "total": known(0),
                "basis": "fixture",
            },
            "actual_execution_slot_occupancy": {"state": "unknown"},
            "actual_execution_slot_basis": "no provider-neutral authority",
            "resources": {},
        },
    }


class ConcurrencyQualificationTests(unittest.TestCase):
    def test_known_value_preserves_unknown(self):
        self.assertEqual(cq.known_value(known(6)), 6)
        self.assertIsNone(cq.known_value({"state": "unknown"}))
        self.assertIsNone(cq.known_value(None))

    def test_capacity_summary_keeps_authorities_separate(self):
        summary = cq.capacity_summary(snapshot(limit=6, active_total=4))
        self.assertEqual(summary["task_slots"]["limit"], 6)
        self.assertEqual(summary["provider_reported_active_turns"]["total"], 4)
        self.assertEqual(summary["actual_execution_slot_state"], "unknown")
        self.assertIsNone(summary["actual_execution_slot_occupancy"])

    def test_declared_tier_requires_exact_effective_limit(self):
        summary = cq.require_declared_tier(snapshot(limit=6), 6)
        self.assertEqual(summary["task_slots"]["limit"], 6)
        with self.assertRaises(cq.QualificationBlocked):
            cq.require_declared_tier(snapshot(limit=8), 6)

    def test_clean_baseline_rejects_existing_conduit_task(self):
        with self.assertRaises(cq.QualificationBlocked):
            cq.require_declared_tier(snapshot(limit=4, used=1), 4)

    def test_clean_baseline_preserves_unknown_background_provider_activity(self):
        summary = cq.require_declared_tier(
            snapshot(limit=4, active_total=0, active_unknown=1),
            4,
        )
        self.assertEqual(summary["background_provider_activity_baseline"], "unknown")

    def test_clean_baseline_rejects_known_background_provider_activity(self):
        with self.assertRaises(cq.QualificationBlocked):
            cq.require_declared_tier(snapshot(limit=4, active_total=1), 4)

    def test_owned_active_tier_requires_exact_task_associations(self):
        fixture = snapshot(limit=6, used=2, active_unknown=1)
        fixture["provider_sessions"]["items"] = [
            provider_row("TASK-A", "ses-a", "active"),
            provider_row("TASK-B", "ses-b", "active"),
        ]
        observed = cq.qualification_task_provider_states(
            fixture,
            ["task-a", "task-b"],
        )
        self.assertTrue(observed["all_exact_active"])
        self.assertEqual(observed["active_count"], 2)
        self.assertEqual(observed["provider_session_ids"], ["ses-a", "ses-b"])

        missing = cq.qualification_task_provider_states(fixture, ["task-a", "task-c"])
        self.assertFalse(missing["all_exact_active"])
        self.assertEqual(missing["missing_task_session_ids"], ["task-c"])

    def test_active_samples_preserve_exact_provider_and_task_turn_evidence(self):
        fixture = snapshot(limit=4, used=1)
        provider = provider_row("task-a", "ses-a", "unknown")
        provider["worker"]["runtime_reconciliation"].update(
            {
                "latest_provider_turn_id": known("message-7"),
                "provider_activities": known(
                    [
                        {
                            "part_id": known("part-2"),
                            "message_id": known("message-7"),
                            "call_id": known("call-3"),
                            "kind": known("tool"),
                            "tool_name": known("shell"),
                            "reported_status": known("running"),
                        }
                    ]
                ),
                "process_observation": known({"coverage": "complete"}),
                "diagnostics": ["latest assistant message is not complete"],
            }
        )
        provider["worker"]["turns"] = [
            {"turn_id": known("message-7"), "state": "active"}
        ]
        fixture["provider_sessions"]["items"] = [provider]
        fixture["tasks"] = {
            "items": [
                {
                    "task": {"id": "TASK-A"},
                    "runtime_attempt_id": known("attempt-a"),
                    "lifecycle": known("running"),
                    "provider_session_id": known("ses-a"),
                    "turn": {
                        "turn": known(
                            {"state": "active", "status": "running"}
                        ),
                        "last_prompt_delivery": known("delivered"),
                        "pending_input": known("none"),
                        "observation": {"authority": "conduit_recorded"},
                    },
                    "process_observation": known({"coverage": "complete"}),
                }
            ]
        }

        provider_states = cq.qualification_task_provider_states(
            fixture, ["task-a"]
        )
        task_states = cq.qualification_task_observations(fixture, ["task-a"])
        provider_state = provider_states["rows"][0]
        task_state = task_states["rows"][0]

        self.assertEqual(
            provider_state["provider_runtime_reconciliation"][
                "latest_provider_turn_id"
            ],
            known("message-7"),
        )
        self.assertEqual(
            provider_state["provider_runtime_reconciliation"][
                "provider_activities"
            ]["value"][0]["reported_status"],
            known("running"),
        )
        self.assertEqual(provider_state["provider_turns"][0]["state"], "active")
        self.assertEqual(
            task_state["turn_observation"]["last_prompt_delivery"],
            known("delivered"),
        )
        self.assertEqual(
            task_state["turn_observation"]["turn"]["value"]["state"],
            "active",
        )
        self.assertEqual(task_state["provider_session_id"], known("ses-a"))

    def test_observe_provider_sessions_preserves_top_level_error_reconciliation(self):
        reconciliation = {
            "provider_reported_state": "unknown",
            "disposition": "insufficient_observation",
            "diagnostics": ["OpenCode persistence was unavailable: database is locked"],
            "process_observation": known({"coverage": "complete", "pids": []}),
        }
        api = mock.Mock()
        api.call.return_value = {
            "error": "database is locked",
            "provider": "opencode",
            "provider_session_id": "ses-a",
            "authority": "provider persistence unavailable",
            "reconciliation": reconciliation,
        }

        rows = cq.observe_provider_sessions(api, ["ses-a"])

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["provider_reported_state"], "unknown")
        self.assertEqual(
            rows[0]["reconciliation_disposition"], "insufficient_observation"
        )
        self.assertEqual(rows[0]["reconciliation_source"], "reconciliation")
        self.assertEqual(
            rows[0]["response_class"], "tool_error_with_top_level_reconciliation"
        )
        self.assertEqual(
            rows[0]["observation_error_class"], "persistence_unavailable"
        )
        self.assertEqual(rows[0]["error"], "database is locked")
        self.assertEqual(rows[0]["observed_provider"], "opencode")
        self.assertEqual(rows[0]["observed_provider_session_id"], "ses-a")
        self.assertEqual(rows[0]["top_level_reconciliation"], reconciliation)
        self.assertIsNone(rows[0]["worker_runtime_reconciliation"])
        self.assertEqual(
            rows[0]["top_level_reconciliation"]["process_observation"],
            known({"coverage": "complete", "pids": []}),
        )
        self.assertFalse(cq.provider_sessions_inactive(rows, 1))

    def test_observe_provider_sessions_keeps_worker_reconciliation_and_unknown(self):
        reconciliation = {
            "provider_reported_state": "unknown",
            "disposition": "insufficient_observation",
            "diagnostics": ["provider turn state remains ambiguous"],
        }
        api = mock.Mock()
        api.call.return_value = {
            "worker": {
                "runtime_reconciliation": reconciliation,
                "turns": [{"turn_id": known("message-1"), "state": "ambiguous"}],
            }
        }

        rows = cq.observe_provider_sessions(api, ["ses-a"])

        self.assertEqual(rows[0]["provider_reported_state"], "unknown")
        self.assertEqual(
            rows[0]["reconciliation_source"], "worker.runtime_reconciliation"
        )
        self.assertEqual(rows[0]["response_class"], "worker_reconciliation")
        self.assertEqual(rows[0]["worker_runtime_reconciliation"], reconciliation)
        self.assertEqual(rows[0]["provider_turns"][0]["state"], "ambiguous")
        self.assertIsNone(rows[0]["error"])

    def test_observe_provider_sessions_marks_missing_reconciliation_malformed(self):
        api = mock.Mock()
        api.call.return_value = {"worker": {"provider_session_id": known("ses-a")}}

        rows = cq.observe_provider_sessions(api, ["ses-a"])

        self.assertEqual(rows[0]["provider_reported_state"], "unknown")
        self.assertIsNone(rows[0]["reconciliation_source"])
        self.assertEqual(rows[0]["response_class"], "worker_missing_reconciliation")
        self.assertEqual(
            rows[0]["observation_error_class"], "malformed_observation"
        )
        self.assertIsNone(rows[0]["error"])
        self.assertFalse(cq.provider_sessions_inactive(rows, 1))

    def test_observe_provider_sessions_marks_explicit_provider_ambiguity(self):
        api = mock.Mock()
        api.call.return_value = {
            "worker": {
                "runtime_reconciliation": {
                    "provider_reported_state": "unknown",
                    "disposition": "insufficient_observation",
                    "diagnostics": [
                        "Persisted provider state is ambiguous while a tool part is running."
                    ],
                }
            }
        }

        rows = cq.observe_provider_sessions(api, ["ses-a"])

        self.assertEqual(rows[0]["provider_reported_state"], "unknown")
        self.assertEqual(
            rows[0]["observation_error_class"], "provider_state_ambiguous"
        )
        self.assertFalse(cq.provider_sessions_inactive(rows, 1))

    def test_observe_provider_sessions_distinguishes_provider_error_classes(self):
        unknown = {
            "provider_reported_state": "unknown",
            "disposition": "insufficient_observation",
            "diagnostics": [],
        }
        api = mock.Mock()
        api.call.side_effect = [
            {
                "error": "OpenCode provider session not found in persistence: ses-a",
                "reconciliation": unknown,
            },
            {
                "error": "provider snapshot changed during read",
                "reconciliation": unknown,
            },
            {"error": "unexpected provider observer failure"},
        ]

        rows = cq.observe_provider_sessions(api, ["ses-a", "ses-b", "ses-c"])

        self.assertEqual(
            [row["observation_error_class"] for row in rows],
            [
                "session_not_found",
                "snapshot_changed_during_read",
                "provider_observation_error",
            ],
        )
        self.assertTrue(
            all(row["provider_reported_state"] == "unknown" for row in rows)
        )
        self.assertTrue(
            all(not cq.provider_sessions_inactive([row], 1) for row in rows)
        )

    def test_cleanup_requires_slots_and_exact_provider_sessions_inactive(self):
        clean = {"capacity": cq.capacity_summary(snapshot(limit=4, used=0))}
        inactive = [
            {"provider_session_id": "ses-a", "provider_reported_state": "inactive", "error": None},
            {"provider_session_id": "ses-b", "provider_reported_state": "inactive", "error": None},
        ]
        self.assertTrue(cq.cleanup_reconciled(clean, inactive, 2))

        active = [
            {"provider_session_id": "ses-a", "provider_reported_state": "active", "error": None},
            {"provider_session_id": "ses-b", "provider_reported_state": "inactive", "error": None},
        ]
        self.assertFalse(cq.cleanup_reconciled(clean, active, 2))

        occupied = {"capacity": cq.capacity_summary(snapshot(limit=4, used=1))}
        self.assertFalse(cq.cleanup_reconciled(occupied, inactive, 2))
        self.assertFalse(cq.cleanup_reconciled(clean, inactive[:1], 2))

    def test_hot_cpu_capture_runs_immediately_with_phase(self):
        sample = {
            "at": "2026-09-24T16:00:00Z",
            "conduit_process": {
                "state": "known",
                "pid": 4321,
                "process_cpu_percent": 95.0,
            },
        }
        capture = {"attempted": False, "captured": False}
        completed = type(
            "Completed",
            (),
            {"returncode": 0, "stderr": ""},
        )()
        with mock.patch.object(cq.subprocess, "run", return_value=completed) as run:
            cq.maybe_capture_sample_if_hot(
                sample,
                80.0,
                Path("/tmp/slice11.sample.txt"),
                capture,
                "natural_completion",
            )

        self.assertTrue(capture["attempted"])
        self.assertTrue(capture["captured"])
        self.assertEqual(capture["trigger_phase"], "natural_completion")
        self.assertEqual(capture["trigger_cpu_percent"], 95.0)
        run.assert_called_once()
        self.assertEqual(
            run.call_args.args[0],
            ["sample", "4321", "2", "1", "-file", "/tmp/slice11.sample.txt"],
        )

    def test_below_threshold_does_not_capture(self):
        sample = {
            "at": "2026-09-24T16:00:00Z",
            "conduit_process": {
                "state": "known",
                "pid": 4321,
                "process_cpu_percent": 79.9,
            },
        }
        capture = {"attempted": False, "captured": False}
        with mock.patch.object(cq.subprocess, "run") as run:
            cq.maybe_capture_sample_if_hot(
                sample,
                80.0,
                Path("/tmp/slice11.sample.txt"),
                capture,
                "active_overlap",
            )

        self.assertFalse(capture["attempted"])
        self.assertFalse(capture["captured"])
        run.assert_not_called()

    def test_post_completion_window_observes_before_teardown(self):
        sample = {
            "at": "2026-09-24T16:00:00Z",
            "capacity": cq.capacity_summary(snapshot(limit=4, used=4)),
            "qualification_tasks": {},
            "conduit_process": {
                "state": "known",
                "pid": 4321,
                "process_cpu_percent": 10.0,
            },
        }
        inactive = [
            {
                "provider_session_id": "ses-a",
                "provider_reported_state": "inactive",
                "error": None,
            }
        ]
        samples = []
        capture = {"attempted": False, "captured": False}

        with mock.patch.object(cq, "sample_once", return_value=sample), \
             mock.patch.object(cq, "observe_provider_sessions", return_value=inactive), \
             mock.patch.object(cq.time, "monotonic", side_effect=[0.0, 0.0, 2.0]), \
             mock.patch.object(cq.time, "sleep"):
            observed = cq.observe_post_completion_window(
                object(),
                ["task-a"],
                ["ses-a"],
                1,
                0,
                samples,
                sample_cpu_threshold=80.0,
                sample_artifact_path=Path("/tmp/slice11.sample.txt"),
                sample_capture=capture,
            )

        self.assertTrue(observed)
        self.assertEqual(len(samples), 1)
        self.assertEqual(
            samples[0]["qualification_provider_post_completion"],
            inactive,
        )

    def test_cleanup_polling_does_not_trigger_pre_teardown_sample(self):
        sample = {
            "at": "2026-09-24T16:00:00Z",
            "capacity": cq.capacity_summary(snapshot(limit=4, used=0)),
            "qualification_tasks": {},
            "conduit_process": {
                "state": "known",
                "pid": 4321,
                "process_cpu_percent": 99.0,
            },
        }
        inactive = [
            {
                "provider_session_id": "ses-a",
                "provider_reported_state": "inactive",
                "error": None,
            }
        ]
        samples = []
        capture = {"attempted": False, "captured": False}

        with mock.patch.object(cq, "sample_once", return_value=sample), \
             mock.patch.object(cq, "observe_provider_sessions", return_value=inactive), \
             mock.patch.object(cq.time, "monotonic", side_effect=[0.0, 0.0, 2.0]), \
             mock.patch.object(cq.time, "sleep"):
            reconciled = cq.wait_for_cleanup_reconciliation(
                object(),
                ["task-a"],
                ["ses-a"],
                1,
                0,
                samples,
                sample_cpu_threshold=80.0,
                sample_artifact_path=Path("/tmp/slice11.sample.txt"),
                sample_capture=capture,
            )

        self.assertTrue(reconciled)
        self.assertEqual(len(samples), 1)
        self.assertFalse(capture["attempted"])
        self.assertFalse(capture["captured"])

    def test_numeric_peak_ignores_unknowns(self):
        samples = [
            {"capacity": {"x": {"total": None}}},
            {"capacity": {"x": {"total": 4}}},
            {"capacity": {"x": {"total": 8}}},
        ]
        self.assertEqual(
            cq.numeric_peak(samples, ("capacity", "x", "total")),
            8.0,
        )


if __name__ == "__main__":
    unittest.main()
