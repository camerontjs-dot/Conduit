"""Standard-library contract tests for the versioned Slice 10 result."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT_PATH = ROOT / "scripts/provider-conformance.py"
MATRIX_PATH = ROOT / "docs/qualification/provider-conformance-v1.json"
SPEC = importlib.util.spec_from_file_location("provider_conformance", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
provider_conformance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provider_conformance)


class ProviderConformanceResultTests(unittest.TestCase):
    def read_matrix(self) -> dict[str, object]:
        return json.loads(MATRIX_PATH.read_text(encoding="utf-8"))

    def validate_document(self, document: dict[str, object]) -> tuple[bool, list[str]]:
        with tempfile.TemporaryDirectory(prefix="conduit-matrix-test-") as directory:
            path = pathlib.Path(directory) / "matrix.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            return provider_conformance.validate_matrix(path)

    def test_committed_matrix_has_explicit_states_for_every_runtime_capability(self) -> None:
        valid, errors = provider_conformance.validate_matrix(MATRIX_PATH)
        self.assertTrue(valid, errors)
        document = self.read_matrix()
        self.assertEqual(set(document["runtimes"]), provider_conformance.RUNTIME_IDS)
        for runtime in document["runtimes"].values():
            self.assertEqual(set(runtime["capabilities"]), provider_conformance.CAPABILITY_IDS)

    def test_missing_capability_fails_closed(self) -> None:
        document = self.read_matrix()
        del document["runtimes"]["opencode"]["capabilities"]["event_streaming"]
        valid, errors = self.validate_document(document)
        self.assertFalse(valid)
        self.assertTrue(any("all 13 capability ids" in error for error in errors))

    def test_unknown_is_preserved_as_a_bounded_result(self) -> None:
        document = self.read_matrix()
        document["runtimes"]["antigravity"]["capabilities"]["resumable"]["provider"]["status"] = "unknown"
        valid, errors = self.validate_document(document)
        self.assertTrue(valid, errors)

    def test_controls_cover_positive_unsupported_unavailable_and_unknown(self) -> None:
        document = self.read_matrix()
        controls = document["controls"]
        self.assertEqual(controls["positive_observation"]["result"], "supported")
        self.assertEqual(controls["explicitly_unsupported"]["result"], "unsupported")
        self.assertEqual(controls["unavailable_runtime"]["result"], "unavailable")
        self.assertEqual(controls["unknown_authority"]["result"], "unknown")
        observed = {
            outcome["status"]
            for runtime in document["runtimes"].values()
            for capability in runtime["capabilities"].values()
            for outcome in capability.values()
        }
        self.assertTrue({"supported", "unsupported", "unknown", "unavailable"} <= observed)
        self.assertEqual(
            document["controls"]["provider_semantic_difference"]["result"],
            "provider_specific",
        )

    def test_opencode_cancel_active_turn_preserves_observed_limit(self) -> None:
        document = self.read_matrix()
        evidence = document["evidence_catalog"]["OPENCODE-NATIVE"]["artifact"]
        receipt = json.loads((ROOT / evidence["path"]).read_text(encoding="utf-8"))
        turn_probe = receipt["observations"]["turn_probe"]

        self.assertTrue(turn_probe["accepted"])
        self.assertEqual(turn_probe["abort_http_status"], 200)
        self.assertEqual(turn_probe["active_session_status_observed"]["status"], "busy")
        self.assertEqual(turn_probe["terminal_session_or_message_event"]["status"], "idle")
        self.assertIsNone(
            receipt["observations"]["message_state_readback"]["assistant_message_states"][0]["status"]
        )
        self.assertIn(
            "session.idle",
            [event["type"] for event in receipt["observations"]["event_stream"]["events"]],
        )

        expected_note = (
            "OpenCode accepted the qualification-owned abort request (HTTP 200); "
            "the observed session moved busy to idle and emitted session.idle, while "
            "assistant message status remained null. The tested interface exposed no exact "
            "turn ID or explicit terminal cancellation reason. Provider host stop and task "
            "completion are separate."
        )
        for layer in ("provider", "conduit"):
            outcome = document["runtimes"]["opencode"]["capabilities"]["cancel_active_turn"][layer]
            self.assertEqual(outcome["status"], "supported")
            self.assertEqual(outcome["note"], expected_note)
            self.assertNotIn("cancelled/interrupted outcome", outcome["note"])


    def test_invalid_status_is_rejected(self) -> None:
        document = self.read_matrix()
        document["runtimes"]["opencode"]["capabilities"]["event_streaming"]["provider"]["status"] = "maybe"
        valid, errors = self.validate_document(document)
        self.assertFalse(valid)
        self.assertTrue(any("status is invalid" in error for error in errors))

    def test_unsupported_result_requires_a_receipt(self) -> None:
        document = self.read_matrix()
        result = document["runtimes"]["shell_fallback"]["capabilities"]["cancel_active_turn"]["provider"]
        result["evidence_refs"] = []
        valid, errors = self.validate_document(document)
        self.assertFalse(valid)
        self.assertTrue(any("requires direct or bounded evidence" in error for error in errors))

    def test_unresolved_evidence_reference_is_rejected(self) -> None:
        document = self.read_matrix()
        result = document["runtimes"]["opencode"]["capabilities"]["external_discovery"]["provider"]
        result["evidence_refs"] = ["missing-receipt"]
        valid, errors = self.validate_document(document)
        self.assertFalse(valid)
        self.assertTrue(any("evidence_refs must resolve" in error for error in errors))

    def test_stale_local_evidence_hash_is_rejected(self) -> None:
        document = self.read_matrix()
        document["evidence_catalog"]["CODEX-ADAPTER"]["artifact"]["sha256"] = "0" * 64
        valid, errors = self.validate_document(document)
        self.assertFalse(valid)
        self.assertTrue(any("does not match local bytes" in error for error in errors))

    def test_receipt_validator_rejects_credential_or_transcript_claims(self) -> None:
        receipt = {
            "schema_version": "1.0.0",
            "receipt_type": "unit-fixture",
            "observed_at_utc": "2026-09-23T00:00:00Z",
            "state": "pass",
            "credential_values_recorded": True,
        }
        with tempfile.TemporaryDirectory(prefix="conduit-receipt-test-") as directory:
            path = pathlib.Path(directory) / "receipt.json"
            path.write_text(json.dumps(receipt), encoding="utf-8")
            valid, errors = provider_conformance.validate_receipt(path)
        self.assertFalse(valid)
        self.assertTrue(any("credential values" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
