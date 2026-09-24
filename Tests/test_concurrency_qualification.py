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


def snapshot(limit=4, used=0, active_total=0, active_unknown=0):
    return {
        "observed_at": "2026-09-24T16:00:00Z",
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

    def test_clean_baseline_rejects_unknown_provider_activity(self):
        with self.assertRaises(cq.QualificationBlocked):
            cq.require_declared_tier(
                snapshot(limit=4, active_total=0, active_unknown=1),
                4,
            )

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
