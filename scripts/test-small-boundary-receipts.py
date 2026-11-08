#!/usr/bin/env python3
"""Oracle regressions; these are never substitutes for actual native VM tests."""
import argparse
import copy
import importlib.util
import json
from pathlib import Path
import unittest
import sys

SOURCE = Path(__file__).with_name("small-boundary")
spec = importlib.util.spec_from_file_location("receipt", SOURCE / "receipt.py")
receipt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        # Consume only a locally retained owned run. Never publish raw frames.
        self.result = copy.deepcopy(REFERENCE)
        self.nonce = self.result["done_nonces"][0]

    def passes(self):
        return receipt.reconcile(self.result, self.nonce)

    def test_complete_observations_pass(self):
        self.assertTrue(self.passes())

    def test_missing_duplicate_and_foreign_cases_fail(self):
        original = copy.deepcopy(self.result)
        for mutation in (lambda r: r["cases"].pop(),
                         lambda r: r["cases"].append(copy.deepcopy(r["cases"][0])),
                         lambda r: r["cases"][0].update(case="../../untrusted")):
            with self.subTest(mutation=mutation):
                self.result = copy.deepcopy(original)
                mutation(self.result)
                self.assertFalse(self.passes())

    def test_positive_control_failure_is_not_confinement(self):
        self.result["cases"][0]["exit_code"] = 126
        self.assertFalse(self.passes())

    def test_escape_success_fails(self):
        self.result["cases"][3].update(exit_code=0, stdout_hex=b"ok\n".hex(), stdout_bytes=3)
        self.assertFalse(self.passes())

    def test_missing_stop_stays_unknown(self):
        self.result["native_events"].pop()
        self.assertFalse(self.passes())
        self.assertEqual(self.result["ownership"], "UNKNOWN")

    def test_lost_descendant_or_stream_ownership_fails(self):
        original = copy.deepcopy(self.result)
        for field, value in (("job_pids", 1), ("stdout_eof", False), ("root_observed", False)):
            with self.subTest(field=field):
                self.result = copy.deepcopy(original)
                self.result["cases"][0][field] = value
                self.assertFalse(self.passes())

    def test_foreign_nonce_fails(self):
        self.result["cases"][0]["nonce"] = "foreign"
        self.assertFalse(self.passes())

    def test_truncated_capture_fails(self):
        self.result["invocation"]["capture_truncated"] = True
        self.assertFalse(self.passes())

    def test_missing_kernel_budget_event_fails(self):
        original = copy.deepcopy(self.result)
        for name, field in (("memory-budget", "oom_kill_delta"),
                            ("process-budget", "pids_max_delta"), ("cpu-budget", "throttled_delta")):
            with self.subTest(case=name):
                self.result = copy.deepcopy(original)
                next(row for row in self.result["cases"] if row["case"] == name)[field] = 0
                self.assertFalse(self.passes())

    def test_refusal_that_launched_a_vm_fails(self):
        self.result["authority_refusals"][0]["VM_launches"] = 1
        self.assertFalse(self.passes())

    def test_native_admission_and_replay_gaps_fail(self):
        original = copy.deepcopy(self.result)
        for mutation in (lambda r: r["native_authority_refusals"].pop(),
                         lambda r: r["native_replay_refusal"].update(status="NOT_RUN"),
                         lambda r: r.update(native_claim_unchanged=False)):
            with self.subTest(mutation=mutation):
                self.result = copy.deepcopy(original)
                mutation(self.result)
                self.assertFalse(self.passes())

    def test_guest_fatal_cannot_be_pass(self):
        self.result["fatal"].append({"where": "job_ownership_unknown"})
        self.assertFalse(self.passes())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    args, remaining = parser.parse_known_args()
    REFERENCE = json.loads(args.receipt.read_text())
    unittest.main(argv=[sys.argv[0], *remaining])
