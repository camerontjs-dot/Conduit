"""Disposable Git fixtures only; no Conduit build, app, provider or runtime."""

import base64
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/qualification/verify_frozen_source.py"
GIT = Path(shutil.which("git") or "/git-unavailable").resolve()


@unittest.skipUnless(os.name == "posix" and GIT.is_file(), "POSIX and Git are required")
class FrozenSourcePreflightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="source-custody-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repository"
        self.repo.mkdir()
        self.git("init", "--quiet")
        self.git("config", "user.name", "Custody Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.repo / "tracked.txt").write_bytes(b"original\n")
        self.git("add", "tracked.txt")
        self.git("commit", "--quiet", "-m", "fixture")
        self.lock = self.root / "candidate-lock.json"
        self.output = self.root / "receipt.json"
        self.write_lock()

    def git(self, *args):
        environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        return subprocess.run([str(GIT), "-c", "core.hooksPath=" + os.devnull, "-C", str(self.repo), *args],
                              env=environment, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=15).stdout

    def write_lock(self, **overrides):
        candidate = {"id": "123", "head": self.git("rev-parse", "HEAD").decode().strip(),
                     "tree": self.git("rev-parse", "HEAD^{tree}").decode().strip()}
        candidate.update(overrides)
        self.lock.write_text(json.dumps({"schema": "conduit-frozen-candidate-lock/v1",
                                        "repository": "camerontjs-dot/Conduit", "candidates": [candidate]}))

    def invoke(self, git=None, extra=()):
        result = subprocess.run([sys.executable, str(SCRIPT), "--candidate", "123", "--repo", str(self.repo),
                                 "--git", str(git or GIT), "--lock", str(self.lock),
                                 "--output", str(self.output), *extra],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        receipt = json.loads(self.output.read_text()) if self.output.exists() else None
        return result, receipt

    def test_clean_fixture_matches_and_records_completed_git_commands(self):
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(receipt["status"], "SOURCE_MATCH")
        self.assertTrue(receipt["inspection_complete"])
        self.assertEqual(receipt["tracked_files_inspected"], 1)
        self.assertTrue(all(c["completed"] and c["exit_code"] == 0 for c in receipt["commands"]))
        self.assertTrue(all(len(c["stdout_sha256"]) == 64 for c in receipt["commands"]))
        self.assertEqual(self.git("status", "--porcelain"), b"")

    def test_wrong_head_is_mismatch_without_repair(self):
        self.write_lock(head="0" * 40)
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt["status"], "SOURCE_MISMATCH")
        self.assertIn("GIT_IDENTITY_MISMATCH_BEFORE", receipt["problems"])

    def test_wrong_tree_is_mismatch(self):
        self.write_lock(tree="0" * 40)
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt["status"], "SOURCE_MISMATCH")

    def test_additional_exact_locked_candidate_can_be_selected(self):
        self.write_lock(id="151")
        result, receipt = self.invoke(extra=("--candidate", "151"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(receipt["candidate"], "151")

    def test_unlisted_candidate_is_blocked_before_git(self):
        result, receipt = self.invoke(extra=("--candidate", "151"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("CANDIDATE_NOT_UNIQUELY_LOCKED", receipt["problems"])
        self.assertEqual(receipt["commands"], [])

    def test_assume_unchanged_does_not_hide_physical_edit(self):
        self.git("update-index", "--assume-unchanged", "tracked.txt")
        (self.repo / "tracked.txt").write_bytes(b"different physical bytes\n")
        self.assertEqual(self.git("status", "--porcelain"), b"")
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt["observed"]["status_before"], [])
        self.assertFalse(receipt["files"][0]["matches"])
        self.assertNotEqual(receipt["files"][0]["actual_blob"], receipt["files"][0]["expected_blob"])

    def test_untracked_nul_status_preserves_filename_bytes(self):
        name = b"untracked-newline\nentry"
        with open(os.fsencode(self.repo) + b"/" + name, "wb") as stream:
            stream.write(b"untracked")
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 1)
        rows = receipt["observed"]["status_before"]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["xy"], "??")
        self.assertEqual(base64.b64decode(rows[0]["path_b64"]), name)

    def test_tracked_non_utf8_newline_filename_matches(self):
        name = b"tracked-\xff\nentry"
        try:
            with open(os.fsencode(self.repo) + b"/" + name, "wb") as stream:
                stream.write(b"tracked bytes\n")
        except OSError as error:
            if error.errno in (errno.EILSEQ, errno.EINVAL):
                self.skipTest("Filesystem refuses this non-UTF8 filename; newline status control remains separate")
            raise
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", "byte filename")
        self.write_lock()
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(name, [base64.b64decode(f["path_b64"]) for f in receipt["files"]])

    def shim(self, body):
        script = self.root / "git-shim"
        script.write_text("#!" + sys.executable + "\nimport os, sys, time\n" + body +
                          "\nos.execv(" + repr(str(GIT)) + ", [" + repr(str(GIT)) + "] + sys.argv[1:])\n")
        script.chmod(0o755)
        return script

    def test_nonzero_status_is_blocked_never_assumed_clean(self):
        shim = self.shim("if 'status' in sys.argv[1:]:\n    sys.stderr.write('synthetic status refusal')\n    sys.exit(17)")
        result, receipt = self.invoke(git=shim)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(receipt["status"], "BLOCKED")
        self.assertIn("GIT_COMMAND_FAILED", receipt["problems"])
        self.assertEqual(receipt["commands"][-1]["exit_code"], 17)
        self.assertTrue(receipt["commands"][-1]["completed"])
        self.assertNotIn("status_before", receipt["observed"])

    def test_timeout_is_blocked_with_incomplete_command_record(self):
        shim = self.shim("if 'status' in sys.argv[1:]:\n    time.sleep(5)")
        result, receipt = self.invoke(git=shim, extra=("--git-timeout", "0.2"))
        self.assertEqual(result.returncode, 2)
        self.assertIn("GIT_COMMAND_TIMED_OUT", receipt["problems"])
        self.assertTrue(receipt["commands"][-1]["timed_out"])
        self.assertFalse(receipt["commands"][-1]["completed"])

    def test_executable_mode_checked_when_git_ignores_it(self):
        file = self.repo / "tracked.txt"
        file.chmod(0o755)
        self.git("add", "tracked.txt")
        self.git("commit", "--quiet", "-m", "executable")
        self.write_lock()
        self.git("config", "core.fileMode", "false")
        file.chmod(0o644)
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(receipt["files"][0]["expected_mode"], "100755")
        self.assertEqual(receipt["files"][0]["actual_mode"], "100644")

    def test_symlink_bytes_are_compared_without_opening_target(self):
        link = self.repo / "link"
        os.symlink(b"outside-target\n", os.fsencode(link))
        self.git("add", "link")
        self.git("commit", "--quiet", "-m", "symlink")
        self.write_lock()
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        recorded = next(f for f in receipt["files"] if f["path_display"] == "link")
        self.assertEqual(recorded["actual_mode"], "120000")
        self.output.unlink()
        link.unlink()
        os.symlink("different-target", link)
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 1)
        self.assertFalse(next(f for f in receipt["files"] if f["path_display"] == "link")["matches"])

    def test_fifo_replacement_is_blocked_without_reading_it(self):
        file = self.repo / "tracked.txt"
        file.unlink()
        os.mkfifo(file)
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(receipt["files"][0]["problem"], "NONREGULAR_WORKING_FILE_UNSUPPORTED")
        self.assertFalse(receipt["inspection_complete"])

    def test_submodule_entry_is_blocked(self):
        head = self.git("rev-parse", "HEAD").decode().strip()
        self.git("update-index", "--add", "--cacheinfo", "160000," + head + ",submodule")
        self.git("commit", "--quiet", "-m", "gitlink")
        self.write_lock()
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertIn("UNSUPPORTED_TREE_ENTRY_OR_SUBMODULE", receipt["problems"])

    def test_existing_receipt_is_never_overwritten(self):
        self.output.write_bytes(b"preserved receipt")
        result = subprocess.run([sys.executable, str(SCRIPT), "--candidate", "123", "--repo", str(self.repo),
                                 "--git", str(GIT), "--lock", str(self.lock), "--output", str(self.output)],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.output.read_bytes(), b"preserved receipt")

    def test_output_inside_checkout_is_refused_before_write(self):
        self.output = self.repo / "must-not-create.json"
        result, receipt = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(receipt)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
