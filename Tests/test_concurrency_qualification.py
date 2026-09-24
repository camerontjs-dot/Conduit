import importlib.util
import unittest
from pathlib import Path

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
