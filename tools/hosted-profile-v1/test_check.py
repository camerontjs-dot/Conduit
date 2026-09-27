"""Synthetic profile consistency controls; no live provider or credential access."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("profile_check", ROOT / "check.py")
C = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(C)


def request():
    return json.loads((ROOT / "request.json").read_text())


def observation():
    return {
        "schema_version": "hosted-luna-profile-observation-v1",
        "runtime_subject": copy.deepcopy(request()["runtime_subject"]),
        "source": "effective_config_readback", "observed_at_utc": "2026-09-27T05:00:00Z",
        "cli_sha256": "a" * 64, "invocation_scope_sha256": "b" * 64,
        "model_catalog_sha256": "c" * 64, "effective_config_sha256": "d" * 64,
        "model_catalog": {"data": [{"model": "gpt-6-luna", "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [{"reasoningEffort": "medium"}, {"reasoningEffort": "max"}]}],
            "nextCursor": None},
        "effective_profile": {"model": "gpt-6-luna", "reasoning_effort": "max", "provider_id": "openai",
            "usage_route": "existing_codex_chatgpt_subscription", "service_tier": "default",
            "conduit_model_override": None},
    }


class ProfileTests(unittest.TestCase):
    def test_request_preserves_literal_protocol_bounds(self):
        r = request()
        self.assertEqual(C.request_errors(r), [])
        self.assertEqual(r["requested_model"], "gpt-6-luna")
        self.assertEqual(r["requested_reasoning_effort"], "max")
        self.assertEqual(r["controls"]["pilot_order"], ["L", "F", "F", "L"])
        self.assertEqual(r["controls"]["max_turns_per_task"], 3)
        self.assertEqual(r["controls"]["turn_observation_seconds"], 180)
        self.assertEqual(r["controls"]["teardown_observation_seconds"], 60)
        self.assertEqual(len(r["phases"]), 5)

    def test_request_pass_does_not_authorize_execution(self):
        result = C.report([], False)
        self.assertFalse(result["execution_authorized"])
        self.assertFalse(result["ready_for_hosted_qualification"])
        self.assertEqual(result["stage"], "PROFILE_REQUEST_CONSISTENT")

    def test_complete_synthetic_observation_is_consistent_not_live_proof(self):
        self.assertEqual(C.observation_errors(observation()), [])
        self.assertFalse(C.report([], True)["ready_for_hosted_qualification"])

    def test_null_observations_do_not_match(self):
        self.assertTrue(C.observation_errors({}))

    def test_sol_is_not_luna(self):
        o = observation(); o["effective_profile"]["model"] = "gpt-6-sol"
        self.assertIn("effective_model_differs", C.observation_errors(o))

    def test_xhigh_is_not_max(self):
        o = observation(); o["effective_profile"]["reasoning_effort"] = "xhigh"
        self.assertIn("effective_reasoning_effort_differs", C.observation_errors(o))

    def test_default_medium_is_not_effective_max(self):
        o = observation(); o["effective_profile"]["reasoning_effort"] = "medium"
        self.assertTrue(C.observation_errors(o))

    def test_display_label_alone_cannot_resolve_model(self):
        o = observation(); o["model_catalog"]["data"] = [{"displayName": "Luna Max"}]
        self.assertIn("requested_model_missing_or_ambiguous", C.observation_errors(o))

    def test_duplicate_selected_model_is_ambiguous(self):
        o = observation(); o["model_catalog"]["data"] *= 2
        self.assertIn("requested_model_missing_or_ambiguous", C.observation_errors(o))

    def test_incomplete_or_omitted_catalog_cursor_is_not_complete(self):
        for value in ["next-page", 0]:
            o = observation(); o["model_catalog"]["nextCursor"] = value
            self.assertIn("catalog_not_complete", C.observation_errors(o))
        o = observation(); del o["model_catalog"]["nextCursor"]
        self.assertIn("catalog_not_complete", C.observation_errors(o))

    def test_missing_max_never_chooses_highest_advertised(self):
        o = observation(); o["model_catalog"]["data"][0]["supportedReasoningEfforts"] = [{"reasoningEffort": "xhigh"}]
        self.assertIn("literal_max_not_advertised", C.observation_errors(o))

    def test_static_config_text_is_not_effective_readback(self):
        o = observation(); o["source"] = "config_text"
        self.assertIn("effective_readback_missing", C.observation_errors(o))

    def test_wrong_runtime_or_missing_capture_identity_fails(self):
        o = observation(); o["runtime_subject"]["commit"] = "3e557adb98bdf32c7c3e39e2c3d215b24ea1ef4e"
        self.assertIn("wrong_runtime_subject", C.observation_errors(o))
        o = observation(); o["cli_sha256"] = None
        self.assertIn("cli_sha256_missing_or_invalid", C.observation_errors(o))

    def test_conduit_model_override_must_not_conflict(self):
        o = observation(); o["effective_profile"]["conduit_model_override"] = "gpt-6-sol"
        self.assertIn("conduit_override_conflicts", C.observation_errors(o))
        o["effective_profile"]["conduit_model_override"] = "gpt-6-luna"
        self.assertEqual(C.observation_errors(o), [])

    def test_paid_route_or_tier_cannot_sneak_in(self):
        for field, value in [("usage_route", "api_key"), ("service_tier", "fast"),
                             ("service_tier", "priority"), ("provider_id", "other")]:
            o = observation(); o["effective_profile"][field] = value
            self.assertTrue(C.observation_errors(o), field)

    def test_phase_drift_or_reorder_is_rejected(self):
        r = request(); r["phases"][2]["effort"] = "medium"
        self.assertTrue(C.request_errors(r))
        r = request(); r["phases"].reverse()
        self.assertTrue(C.request_errors(r))

    def test_delegation_concurrency_retry_and_timing_changes_rejected(self):
        for field, value in [("delegation_allowed", True), ("max_active_turns", 4),
                             ("fallback_allowed", True), ("queued_means_no_resend", False),
                             ("turn_observation_seconds", 3600), ("service_tier_change_allowed", True)]:
            r = request(); r["controls"][field] = value
            self.assertTrue(C.request_errors(r), field)

    def test_booleans_do_not_pass_as_integer_limits(self):
        r = request(); r["controls"]["max_active_turns"] = True
        self.assertTrue(C.request_errors(r))

    def test_malformed_timestamp_and_missing_effective_field_fail(self):
        o = observation(); o["observed_at_utc"] = "2026-09-27T05:00:00"
        self.assertTrue(C.observation_errors(o))
        o = observation(); del o["effective_profile"]["conduit_model_override"]
        self.assertTrue(C.observation_errors(o))

    def test_key_order_and_unrelated_catalog_model_are_invariant(self):
        o = observation(); o["model_catalog"]["data"].append({"model": "unselected-model"})
        o = dict(reversed(list(o.items())))
        self.assertEqual(C.observation_errors(o), [])

    def test_duplicate_keys_and_nonfinite_json_refused(self):
        for raw in [b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":Infinity}', b'[]']:
            with self.assertRaises((ValueError, C.InvalidInput)):
                C.decode(raw)

    def test_oversize_and_symlink_refused(self):
        with self.assertRaises(C.InvalidInput):
            C.decode(b" " * (C.MAX_BYTES + 1))
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "link.json"; path.symlink_to(ROOT / "request.json")
            with self.assertRaises(C.InvalidInput):
                C.read(path)

    def test_cli_only_reads_snapshots_and_returns_false_readiness(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "observation.json"
            path.write_text(json.dumps(observation()))
            before = path.read_bytes()
            p = subprocess.run([sys.executable, str(ROOT / "check.py"), str(ROOT / "request.json"),
                                "--observation", str(path)], capture_output=True, text=True,
                               env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, timeout=10)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertFalse(json.loads(p.stdout)["ready_for_hosted_qualification"])
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual([v.name for v in Path(temp).iterdir()], ["observation.json"])

    def test_cli_refusal_does_not_echo_private_input(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "secret-label.json"; path.write_text('{"credential":"do-not-echo"')
            p = subprocess.run([sys.executable, str(ROOT / "check.py"), str(path)],
                               capture_output=True, text=True, timeout=10)
            self.assertEqual(p.returncode, 2)
            self.assertNotIn("secret-label", p.stdout + p.stderr)
            self.assertNotIn("do-not-echo", p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
