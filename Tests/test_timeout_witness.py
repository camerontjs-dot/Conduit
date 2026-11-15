"""Falsification checks for the no-VM signal oracle; synthetic frames are not runs."""
import copy
import errno
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("timeout_witness", ROOT / "scripts/probe-timeout-witness.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class TimeoutWitnessTests(unittest.TestCase):
    def setUp(self):
        self.nonce = "a" * 64
        self.rows = [
            {"event": "witness_ready", "nonce": self.nonce, "pid": 4242, "pgid": 4242, "no_vm": True},
            {"event": "supervisor_term_received", "nonce": self.nonce, "pid": 4242,
             "pgid": 4242, "state": "-1", "monotonic_ns": 1},
            {"event": "self_signal_requested", "nonce": self.nonce, "pid": 4242, "target_pid": 4242, "signal": 15},
        ]
        self.facts = {"pid": 4242, "pgid": 4242, "parent_term_count": 1,
            "cleanup_kill_count": 0, "raw_wait_status": 15, "exit_code": -15,
            "exact_child_reaped": True, "wait_ownership_lost": False, "host_timeout": False,
            "capture_truncated": False, "reached_eof": {"stdout": True, "stderr": True}}

    def assess(self, rows=None, facts=None, raw=None):
        rows = self.rows if rows is None else rows
        facts = copy.deepcopy(self.facts if facts is None else facts)
        data = raw if raw is not None else b"".join(json.dumps(r).encode() + b"\n" for r in rows)
        facts["observed_bytes"] = {"stdout": 0, "stderr": len(data)}
        return probe.assess(facts, {"stdout": b"", "stderr": data}, self.nonce)

    def test_one_handoff_and_duplicates_are_distinct(self):
        self.assertEqual(self.assess()["status"], "ONE_HANDOFF_SIGNAL15")
        duplicate = self.rows + self.rows[1:]
        self.assertEqual(self.assess(duplicate)["status"], "REPRODUCED_DUPLICATE_HANDOFF")

    def test_missing_reordered_and_disconnected_handoffs_refuse(self):
        for rows in [[], self.rows[1:], self.rows[:-1], self.rows + self.rows[2:],
                     [self.rows[0], self.rows[2], self.rows[1]]]:
            with self.subTest(rows=rows): self.assertEqual(self.assess(rows)["status"], "FAIL")

    def test_claimed_signal_without_raw_signal_wait_refuses(self):
        for key, value in [("raw_wait_status", 0), ("raw_wait_status", None), ("exit_code", 0),
                           ("exact_child_reaped", False), ("wait_ownership_lost", True),
                           ("parent_term_count", 2), ("parent_signal_errno", errno.ESRCH),
                           ("cleanup_kill_count", 1), ("host_timeout", True), ("capture_truncated", True),
                           ("reached_eof", {}), ("reached_eof", {"stdout": True, "stderr": False})]:
            facts = {**self.facts, key: value}
            with self.subTest(key=key, value=value): self.assertEqual(self.assess(facts=facts)["status"], "FAIL")

    def test_wrong_identity_and_VM_claims_refuse(self):
        for index, key, value in [(0, "nonce", "b" * 64), (0, "pid", 99), (0, "no_vm", False),
                                  (1, "pgid", 99), (1, "state", "running"), (2, "target_pid", 99),
                                  (2, "signal", 9), (1, "event", "supervisor_stop_observed")]:
            rows = copy.deepcopy(self.rows); rows[index][key] = value
            with self.subTest(key=key, value=value): self.assertEqual(self.assess(rows)["status"], "FAIL")

    def test_incomplete_untyped_and_invalid_capture_refuses(self):
        valid = b"".join(json.dumps(r).encode() + b"\n" for r in self.rows)
        for raw in [b"", b"\xff\n", b"[]\n", b"null\n", valid[:-1], valid + b"{\n"]:
            with self.subTest(raw=raw): self.assertEqual(self.assess(raw=raw)["status"], "FAIL")

    def test_unavailable_executable_fails_without_witness_execution(self):
        with tempfile.TemporaryDirectory(prefix="conduit-witness-backend-") as owned:
            facts, streams = probe.run_child(Path(owned) / "missing", {"PATH": "/usr/bin:/bin", "LANG": "C"}, self.nonce)
            self.assertEqual(facts["spawn_error"], errno.ENOENT)
            self.assertIsNone(facts["pid"])
            self.assertEqual(facts["parent_term_count"], 0)
            self.assertEqual(probe.assess(facts, streams, self.nonce)["status"], "FAIL")
            self.assertEqual(list(Path(owned).iterdir()), [])

    def test_ambiguous_source_and_missing_registration_seam_refuse(self):
        source = (ROOT / "scripts/small-boundary/VMRunner.swift").read_text()
        template = (ROOT / "scripts/small-boundary/IsolatedTimeoutWitness.swift").read_text()
        self.assertIn("source.setRegistrationHandler", probe.render(source, template))
        for changed in [source.replace("func installTimeoutWitness", "func otherWitness"),
                        source + probe.method(source, "installTimeoutWitness"),
                        source.replace("        source.resume()\n", "")]:
            with self.assertRaises(ValueError): probe.render(changed, template)
