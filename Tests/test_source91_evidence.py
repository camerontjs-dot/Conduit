"""Portable synthetic controls for source91 renewal, not provider qualification."""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("source91", ROOT / "scripts/renew-source91-evidence.py")
assert SPEC and SPEC.loader
S = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(S)


class SourceRenewalTests(unittest.TestCase):
    def setUp(self):
        self.base = b'provider_guard = "opencode-only"\n' + S.OLD_STARTUP + b'queued = "no-resend"\n'
        self.current = self.base.replace(S.OLD_STARTUP, S.NEW_STARTUP)
        self.doc = {
            "evidence_catalog": {
                "CONDUIT-API-SCOPE": {
                    "artifact": {"path": S.APP, "sha256": S.digest(self.base)},
                    "kind": "source_test", "identity": {"path": S.APP},
                    "observed_at_utc": "2026-09-23T00:00:00Z", "authority": "old review",
                    "freshness": "historical source snapshot", "procedure_id": "old-procedure",
                    "limitation": "OpenCode-only; source does not prove provider behavior.",
                },
                "CONFORMANCE-HARNESS": {"artifact": {"path": "unmodified-checker", "sha256": "a" * 64}},
                "PROVIDER": {"kind": "runtime_probe", "observed_at_utc": "2026-09-23T00:00:00Z"},
            },
            "runtimes": {"codex": {"supported": False}, "opencode": {"supported": True}},
            "controls": {"unknown": "unknown"},
        }
        self.matrix = self.encode(self.doc)
        self.pins = patch.multiple(S, BASE_BLOB=S.blob(self.base), APP_BLOB=S.blob(self.current),
                                   MATRIX_BLOB=S.blob(self.matrix), OLD_SHA256=S.digest(self.base))
        self.pins.start()
        self.addCleanup(self.pins.stop)

    @staticmethod
    def encode(value):
        return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()

    def plan(self, **overrides):
        values = dict(base=self.base, candidate=self.current, matrix=self.matrix,
                      observed_at="2026-09-27T00:00:00+00:00")
        values.update(overrides)
        return S.plan(**values)

    def test_exact_reviewed_change_renews_only_source_record(self):
        proposed, receipt = self.plan()
        result = S.strict_json(proposed)
        result["evidence_catalog"]["CONDUIT-API-SCOPE"] = self.doc["evidence_catalog"]["CONDUIT-API-SCOPE"]
        self.assertEqual(result, self.doc)
        self.assertEqual(receipt["prior_source_record"], self.doc["evidence_catalog"]["CONDUIT-API-SCOPE"])
        self.assertFalse(receipt["provider_outcomes_changed"])
        self.assertEqual(receipt["full_wrapper"], "NOT_RUN")

    def test_prefix_and_suffix_bytes_unchanged(self):
        proposed, _ = self.plan()
        prefix = b'    "CONDUIT-API-SCOPE": {\n'
        suffix = b'    "CONFORMANCE-HARNESS": {\n'
        self.assertEqual(proposed.split(prefix)[0], self.matrix.split(prefix)[0])
        self.assertEqual(proposed.split(suffix)[1], self.matrix.split(suffix)[1])

    def test_changed_candidate_blob_rejected(self):
        with self.assertRaisesRegex(S.Refused, "wrong candidate"):
            self.plan(candidate=self.current + b"\n")

    def test_hash_refresh_cannot_hide_provider_guard_mutation(self):
        bad = self.current.replace(b'opencode-only', b'all-providers')
        with patch.object(S, "APP_BLOB", S.blob(bad)):
            with self.assertRaisesRegex(S.Refused, "outside the exact reviewed"):
                self.plan(candidate=bad)

    def test_hash_refresh_cannot_hide_delivery_semantic_mutation(self):
        bad = self.current.replace(b'no-resend', b'resend-now')
        with patch.object(S, "APP_BLOB", S.blob(bad)):
            with self.assertRaisesRegex(S.Refused, "outside the exact reviewed"):
                self.plan(candidate=bad)

    def test_startup_change_beyond_review_is_refused(self):
        bad = self.current.replace(b'allowWrites: settings.enableSessionAPIWrites', b'allowWrites: true')
        with patch.object(S, "APP_BLOB", S.blob(bad)):
            with self.assertRaisesRegex(S.Refused, "outside the exact reviewed"):
                self.plan(candidate=bad)

    def test_missing_and_duplicate_startup_anchor_are_refused(self):
        for base in (b"no anchor", self.base + S.OLD_STARTUP):
            with self.subTest(base_length=len(base)):
                with self.assertRaisesRegex(S.Refused, "exactly once"):
                    S.reviewed_postimage(base, self.current)

    def test_matrix_tampering_is_refused(self):
        changed = copy.deepcopy(self.doc)
        changed["runtimes"]["codex"]["supported"] = True
        with self.assertRaisesRegex(S.Refused, "wrong predecessor matrix"):
            self.plan(matrix=self.encode(changed))

    def test_blind_source_pin_refresh_is_refused(self):
        changed = copy.deepcopy(self.doc)
        changed["evidence_catalog"]["CONDUIT-API-SCOPE"]["artifact"]["sha256"] = S.digest(self.current)
        raw = self.encode(changed)
        with patch.object(S, "MATRIX_BLOB", S.blob(raw)):
            with self.assertRaisesRegex(S.Refused, "unexpected source record"):
                self.plan(matrix=raw)

    def test_runtime_record_cannot_be_renewed(self):
        changed = copy.deepcopy(self.doc)
        changed["evidence_catalog"]["CONDUIT-API-SCOPE"]["kind"] = "runtime_probe"
        raw = self.encode(changed)
        with patch.object(S, "MATRIX_BLOB", S.blob(raw)):
            with self.assertRaisesRegex(S.Refused, "runtime receipt"):
                self.plan(matrix=raw)

    def test_wrong_base_pin_is_refused(self):
        with self.assertRaisesRegex(S.Refused, "wrong base"):
            self.plan(base=self.base + b"unreviewed")

    def test_duplicate_json_keys_and_nonobject_are_refused(self):
        for raw in (b'{"x":1,"x":2}', b'[]'):
            with self.subTest(raw=raw):
                with self.assertRaises(S.Refused):
                    S.strict_json(raw)

    def test_unsupported_matrix_layout_is_refused(self):
        raw = self.matrix.replace(b'    "CONFORMANCE-HARNESS": {', b'    "OTHER": {')
        with patch.object(S, "MATRIX_BLOB", S.blob(raw)):
            with self.assertRaisesRegex(S.Refused, "anchors"):
                self.plan(matrix=raw)

    def test_apply_outputs_and_no_receipt_overwrite(self):
        proposed, receipt = self.plan()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / S.MATRIX
            target.parent.mkdir(parents=True)
            target.write_bytes(self.matrix)
            S.apply_outputs(root, self.matrix, proposed, receipt)
            self.assertEqual(target.read_bytes(), proposed)
            record = (root / S.REVIEW).read_bytes()
            with self.assertRaises(S.Refused):
                S.apply_outputs(root, proposed, proposed, receipt)
            self.assertEqual((root / S.REVIEW).read_bytes(), record)

    def test_changed_prewrite_matrix_is_refused(self):
        proposed, receipt = self.plan()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / S.MATRIX
            target.parent.mkdir(parents=True)
            target.write_bytes(self.matrix + b"\n")
            with self.assertRaisesRegex(S.Refused, "changed before write"):
                S.apply_outputs(root, self.matrix, proposed, receipt)
            self.assertFalse((root / S.REVIEW).exists())

    def test_failed_replacement_rolls_back_created_receipt(self):
        proposed, receipt = self.plan()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / S.MATRIX
            target.parent.mkdir(parents=True)
            target.write_bytes(self.matrix)
            with patch.object(S.os, "replace", side_effect=OSError("simulated replace failure")):
                with self.assertRaises(OSError):
                    S.apply_outputs(root, self.matrix, proposed, receipt)
            self.assertEqual(target.read_bytes(), self.matrix)
            self.assertFalse((root / S.REVIEW).exists())
            self.assertEqual(list(target.parent.iterdir()), [target])

    def test_symlink_and_parent_path_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "link").symlink_to(root, target_is_directory=True)
            for path in ("link/file", "../outside", "/absolute"):
                with self.subTest(path=path):
                    with self.assertRaises(S.Refused):
                        S.local_path(root, path)

    def test_dirty_checkout_and_protected_predecessor_are_refused(self):
        expected = "1" * 40
        with patch.object(S, "git", side_effect=[(expected + "\n").encode(), b" M tracked\n"]):
            with self.assertRaisesRegex(S.Refused, "clean"):
                S.check_checkout(ROOT, expected)
        for expected in (S.BASE, S.CANDIDATE, "short"):
            with self.subTest(expected=expected):
                with self.assertRaises(S.Refused):
                    S.check_checkout(ROOT, expected)

    def test_extra_kit_changes_are_refused(self):
        expected = "1" * 40
        replies = [(expected + "\n").encode(), b"", (S.CANDIDATE + "\n").encode(), b"wrong-file\n"]
        with patch.object(S, "git", side_effect=replies):
            with self.assertRaisesRegex(S.Refused, "kit delta"):
                S.check_checkout(ROOT, expected)

    def test_existing_validator_must_pass_without_waiver(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake = type("Result", (), {"returncode": 1, "stdout": b'{"valid":false,"errors":["scope"]}'})()
            with patch.object(S.subprocess, "run", return_value=fake) as run:
                with self.assertRaisesRegex(S.Refused, "unchanged provider validator rejected"):
                    S.validate_proposal(root, self.matrix)
                self.assertIn("validate-matrix", run.call_args.args[0])
                self.assertNotIn("codex", run.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
