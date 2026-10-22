#!/usr/bin/env python3
"""Adversarial admission controls; never execute the hosted collector locally."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("probe", Path(__file__).with_name("r3-guest-probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class AdmissionTests(unittest.TestCase):
    def test_wrong_or_missing_artifact_identity_refused(self):
        good = {"id": probe.ARTIFACT, "name": "conduit-macos-arm64", "expired": False,
                "digest": "sha256:" + probe.ENVELOPE,
                "workflow_run": {"id": probe.BUILD_RUN, "head_sha": probe.R3}}
        probe.verify_metadata(good)
        for path, bad in [("id", 1), ("name", "other"), ("expired", True),
                          ("expired", None), ("digest", "sha256:wrong"),
                          ("workflow_run", {}), ("workflow_run", {"id": probe.BUILD_RUN, "head_sha": "wrong"})]:
            with self.subTest(path=path, bad=bad):
                altered = copy.deepcopy(good)
                altered[path] = bad
                with self.assertRaises(probe.ProbeFailure):
                    probe.verify_metadata(altered)

    def test_missing_evidence_cannot_admit(self):
        b = probe.admission_blockers({}, False)
        self.assertIn("EXACT_OS_REQUIRED", b)
        self.assertIn("STANDARD_TRIAL_USER_REQUIRED", b)
        self.assertIn("LOGGED_IN_GUI_REQUIRED", b)
        self.assertIn("ARTIFACT_VERIFICATION_REQUIRED", b)

    def test_admin_or_wrong_os_cannot_pass(self):
        e = {"os": "15.7.9", "build": "24G830", "architecture": "arm64",
             "trial_user": True, "admin_member": False, "uid": 502,
             "gui": {"on_console": True, "login_done": True}}
        for key, value, reason in [("admin_member", True, "STANDARD_TRIAL_USER_REQUIRED"),
                                   ("admin_member", None, "STANDARD_TRIAL_USER_REQUIRED"),
                                   ("uid", 0, "STANDARD_TRIAL_USER_REQUIRED"),
                                   ("trial_user", False, "STANDARD_TRIAL_USER_REQUIRED"),
                                   ("build", "different", "EXACT_OS_REQUIRED")]:
            with self.subTest(key=key, value=value):
                altered = copy.deepcopy(e)
                altered[key] = value
                self.assertIn(reason, probe.admission_blockers(altered, True))
        self.assertEqual(probe.admission_blockers(e, True), [
            "PRIVATE_TRIAL_RECEIPT_EXPORT_NOT_PROVISIONED", "DEDICATED_TRANSPORT_NOT_PROVISIONED",
            "HUMAN_OBSERVATION_NOT_CALIBRATED", "FRESH_CHATGPT_DISCOVERY_NOT_RUN"])

    def test_archive_traversal_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            p = Path(directory) / "fixture.zip"
            for name in ["../outside", "/absolute", "safe/../../outside"]:
                with self.subTest(name=name):
                    with zipfile.ZipFile(p, "w") as z:
                        z.writestr(name, "fixture")
                    with self.assertRaises(probe.ProbeFailure):
                        probe.check_zip(p)
            with zipfile.ZipFile(p, "w") as z:
                z.writestr("safe/fixture", "fixture")
            probe.check_zip(p)

    def test_collector_refuses_non_github_host(self):
        from unittest.mock import patch
        with patch.dict(probe.os.environ, {}, clear=True):
            with self.assertRaisesRegex(probe.ProbeFailure, "GITHUB_ONLY"):
                probe.main()


if __name__ == "__main__":
    unittest.main()
