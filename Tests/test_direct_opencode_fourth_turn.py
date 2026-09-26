import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "direct-opencode-fourth-turn.py"
SPEC = importlib.util.spec_from_file_location("direct_opencode_fourth_turn", SCRIPT)
HARNESS = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(HARNESS)


class DirectOpenCodeFourthTurnTests(unittest.TestCase):
    def test_target_and_workload_are_frozen_at_protocol_values(self):
        self.assertEqual(HARNESS.TARGET, 4)
        self.assertEqual(HARNESS.HOLD_SECONDS, 45)
        self.assertEqual(HARNESS.OUTPUT_LINES, 160)
        self.assertEqual(HARNESS.ACTIVE_TIMEOUT_SECONDS, 75)
        self.assertEqual(HARNESS.OVERLAP_SECONDS, 15)
        self.assertEqual(HARNESS.POLL_SECONDS, 2.0)

        objective = HARNESS.hold_objective("DIRECT-S11-4-1-fixture")
        self.assertIn("run sleep 45 exactly once", objective)
        self.assertIn("exactly 160 newline-separated lines", objective)
        self.assertIn("Do not modify project files", objective)

    def test_prompt_payload_keeps_exact_provider_model_and_text_part(self):
        payload = HARNESS.prompt_payload(
            "opencode/muse-spark-1.3-contributor-free", "fixture objective"
        )
        self.assertEqual(
            payload["model"],
            {
                "providerID": "opencode",
                "modelID": "muse-spark-1.3-contributor-free",
            },
        )
        self.assertEqual(
            payload["parts"], [{"type": "text", "text": "fixture objective"}]
        )

    def test_status_projection_uses_exact_v11830_idle_semantics(self):
        projected = HARNESS.status_rows(
            {
                "ses-a": {"type": "busy"},
                "ses-b": {"type": "retry", "attempt": 1},
                "unrelated": {"type": "busy"},
            },
            ["ses-a", "ses-b", "ses-c", "ses-d"],
        )
        self.assertEqual(projected["active_count"], 1)
        self.assertEqual(projected["retry_count"], 1)
        self.assertEqual(projected["unknown_count"], 0)
        self.assertEqual(projected["rows"][2]["provider_state"], "inactive")
        self.assertEqual(projected["rows"][2]["reported_type"], "idle")
        self.assertEqual(len(projected["unrelated_status_id_hashes"]), 1)

    def test_malformed_status_preserves_unknown(self):
        projected = HARNESS.status_rows([], ["ses-a", "ses-b"])
        self.assertEqual(projected["active_count"], 0)
        self.assertEqual(projected["unknown_count"], 2)
        self.assertTrue(
            all(row["provider_state"] == "unknown" for row in projected["rows"])
        )

    def test_event_tracker_records_authority_without_output_text(self):
        tracker = HARNESS.EventTracker()
        tracker.register(["ses-a"])
        tracker.apply(
            {
                "type": "session.status",
                "properties": {
                    "sessionID": "ses-a",
                    "status": {"type": "busy"},
                },
            },
            "2026-09-26T12:00:00.000Z",
        )
        tracker.apply(
            {
                "type": "message.updated",
                "properties": {
                    "info": {
                        "id": "msg-a",
                        "sessionID": "ses-a",
                        "role": "assistant",
                        "time": {"created": 1},
                    }
                },
            },
            "2026-09-26T12:00:01.000Z",
        )
        tracker.apply(
            {
                "type": "message.part.updated",
                "properties": {
                    "part": {
                        "id": "part-a",
                        "messageID": "msg-a",
                        "sessionID": "ses-a",
                        "type": "tool",
                        "tool": "bash",
                        "state": {"status": "running", "input": "SECRET"},
                    }
                },
            },
            "2026-09-26T12:00:02.000Z",
        )
        tracker.apply(
            {
                "type": "session.idle",
                "properties": {"sessionID": "ses-a"},
            },
            "2026-09-26T12:00:03.000Z",
        )

        snapshot = tracker.snapshot()
        timeline = snapshot["sessions"]["ses-a"]
        self.assertEqual(timeline["first_busy_at"], "2026-09-26T12:00:00.000Z")
        self.assertEqual(
            timeline["first_assistant_activity_at"], "2026-09-26T12:00:01.000Z"
        )
        self.assertEqual(
            timeline["first_tool_running_at"], "2026-09-26T12:00:02.000Z"
        )
        self.assertEqual(timeline["idle_at"], "2026-09-26T12:00:03.000Z")
        serialized = str(snapshot)
        self.assertNotIn("SECRET", serialized)
        self.assertIn("bash", serialized)


if __name__ == "__main__":
    unittest.main()
