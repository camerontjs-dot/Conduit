#!/usr/bin/env python3
"""One-time, byte-guarded source-record renewal for Conduit PR #91.

Not a general hash updater. No network, credentials, app or provider control.
Dry-run by default; --apply requires a clean, exact, separately owned kit head.
The unchanged provider validator must accept the proposed matrix before writes.
"""
from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

BASE = "61349887dcf5d562ee3bfd96acfd443e63191c3f"
CANDIDATE = "3e557adb98bdf32c7c3e39e2c3d215b24ea1ef4e"
APP = "Sources/Conduit/AppModel.swift"
MATRIX = "docs/qualification/provider-conformance-v1.json"
REVIEW = "docs/qualification/source91-renewal-receipt.json"
SCRIPT = "scripts/renew-source91-evidence.py"
TESTS = "Tests/test_source91_evidence.py"
GUIDE = "docs/qualification/SOURCE91_RENEWAL.md"
KIT_FILES = {SCRIPT, TESTS, GUIDE}
BASE_BLOB = "5cbb6b3379465cafd7844cf2d35e1222ee2a723a"
APP_BLOB = "a90a8b77efae10cf5a16ae56483e06884a5b518b"
MATRIX_BLOB = "4e4077c49c97d702b98f8e4c9abb2c757a9b60fc"
VALIDATOR = "scripts/provider-conformance.py"
VALIDATOR_BLOB = "fa7851d397a0f289c88286ce8f48c828294b2f3a"
CATALOG = "Sources/ConduitCore/ConduitSessionToolCatalog.swift"
CATALOG_BLOB = "d21b716a6ab8fbe5f3a48e366646adaeb28d063f"
OLD_SHA256 = "461014a17d5cd519cea1b211728cb0bae8fd930d10138a83bae0dd7218cc5a9c"

OLD_STARTUP = r'''    func syncSessionAPI() {
        sessionAPIServer?.stop()
        sessionAPIServer = nil
        sessionAPIAddress = nil
        guard settings.enableSessionAPI else { return }
        let token = ConduitSessionAPIServer.loadOrCreateToken()
        rebuildMCPAdmission()
        let server = ConduitSessionAPIServer(
            token: token,
            allowWrites: settings.enableSessionAPIWrites
        ) { [weak self] command, caller in
            self?.sessionAPIPayload(command, caller: caller)
                ?? ["error": "Conduit is not ready."]
        }
        do {
            try server.start()
            server.setReadiness(sessionAPIReadiness)
            sessionAPIServer = server
            sessionAPIAddress =
                "http://127.0.0.1:\(ConduitSessionAPI.loopbackPort)\(ConduitSessionAPI.loopbackPath)"
            statusMessage = "Session API listening on \(sessionAPIAddress ?? "")."
        } catch {
            errorMessage = "Session API failed to start: \(error.localizedDescription)"
        }
    }
'''.encode()
NEW_STARTUP = r'''    func syncSessionAPI() {
        sessionAPIServer?.stop()
        sessionAPIServer = nil
        sessionAPIAddress = nil
        guard settings.enableSessionAPI else { return }
        do {
            let port = try SessionAPIListenPort.resolved()
            let token = ConduitSessionAPIServer.loadOrCreateToken()
            rebuildMCPAdmission()
            let server = ConduitSessionAPIServer(
                port: port,
                token: token,
                allowWrites: settings.enableSessionAPIWrites
            ) { [weak self] command, caller in
                self?.sessionAPIPayload(command, caller: caller)
                    ?? ["error": "Conduit is not ready."]
            }
            try server.start()
            server.setReadiness(sessionAPIReadiness)
            sessionAPIServer = server
            sessionAPIAddress =
                "http://127.0.0.1:\(port)\(ConduitSessionAPI.loopbackPath)"
            statusMessage = "Session API listening on \(sessionAPIAddress ?? "")."
        } catch {
            errorMessage = "Session API failed to start: \(error.localizedDescription)"
        }
    }
'''.encode()


class Refused(ValueError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise Refused(message)


def blob(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def strict_json(data: bytes) -> dict:
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f"duplicate JSON key: {key}")
            result[key] = value
        return result
    value = json.loads(data, object_pairs_hook=pairs)
    require(isinstance(value, dict), "JSON root must be an object")
    return value


def reviewed_postimage(base: bytes, candidate: bytes) -> None:
    require(base.count(OLD_STARTUP) == 1, "base startup anchor must occur exactly once")
    require(base.replace(OLD_STARTUP, NEW_STARTUP, 1) == candidate,
            "AppModel differs outside the exact reviewed startup replacement")


def plan(base: bytes, candidate: bytes, matrix: bytes, observed_at: str) -> tuple[bytes, dict]:
    require(blob(base) == BASE_BLOB, "wrong base AppModel blob")
    require(blob(candidate) == APP_BLOB, "wrong candidate AppModel blob")
    require(blob(matrix) == MATRIX_BLOB, "wrong predecessor matrix blob")
    require(digest(base) == OLD_SHA256, "base does not match the historical source pin")
    reviewed_postimage(base, candidate)
    document = strict_json(matrix)
    prior = document["evidence_catalog"]["CONDUIT-API-SCOPE"]
    require(prior["kind"] == "source_test", "refuse to renew a runtime receipt")
    require(prior["artifact"] == {"path": APP, "sha256": OLD_SHA256}, "unexpected source record")
    renewed = copy.deepcopy(prior)
    renewed["artifact"]["sha256"] = digest(candidate)
    renewed["observed_at_utc"] = observed_at
    renewed["authority"] = "Exact source blobs plus full-file reviewed startup-delta check; no provider operation"
    renewed["freshness"] = "PR #91 source-only renewal; historical provider observations retain their original dates"
    renewed["procedure_id"] = "conduit-api-scope-port-only-review-v1"
    renewed["identity"].update({"source_commit": CANDIDATE, "predecessor_commit": BASE,
                                "source_review": REVIEW})
    renewed["limitation"] = prior["limitation"] + (
        " Only listener startup changed in AppModel. This is not current provider "
        "conformance, a full test-suite pass, or hosted qualification.")
    start_marker = b'    "CONDUIT-API-SCOPE": {\n'
    end_marker = b'    "CONFORMANCE-HARNESS": {\n'
    require(matrix.count(start_marker) == matrix.count(end_marker) == 1, "matrix anchors are not unique")
    start, end = matrix.index(start_marker), matrix.index(end_marker)
    require(end > start, "matrix anchors out of order")
    block = ('    "CONDUIT-API-SCOPE": ' +
             json.dumps(renewed, indent=2, sort_keys=True).replace("\n", "\n    ") + ",\n").encode()
    proposed = matrix[:start] + block + matrix[end:]
    expected = copy.deepcopy(document)
    expected["evidence_catalog"]["CONDUIT-API-SCOPE"] = renewed
    require(strict_json(proposed) == expected, "renewal changed another matrix field")
    receipt = {
        "schema_version": "source91-renewal-v1", "stage": "SOURCE_RECORD_RENEWED_NOT_RUNTIME_QUALIFIED",
        "observed_at_utc": observed_at, "predecessor_commit": CANDIDATE,
        "source_base_commit": BASE, "base_app_blob": blob(base), "candidate_app_blob": blob(candidate),
        "base_app_sha256": digest(base), "candidate_app_sha256": digest(candidate),
        "predecessor_matrix_blob": blob(matrix), "renewed_matrix_sha256": digest(proposed),
        "prior_source_record": prior, "renewed_source_record": renewed,
        "reviewed_delta": "syncSessionAPI exact startup replacement only; all other AppModel bytes identical",
        "provider_outcomes_changed": False, "historical_receipts_changed": False,
        "full_wrapper": "NOT_RUN", "hosted_journey": "NOT_RUN",
    }
    return proposed, receipt


def git(root: Path, *args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(root), *args], stderr=subprocess.PIPE)


def local_path(root: Path, relative: str) -> Path:
    path = root
    for part in Path(relative).parts:
        require(part not in ("..", "/"), "unsafe path")
        path /= part
        require(not path.is_symlink(), f"symlink refused: {relative}")
    return path


def check_checkout(root: Path, expected_head: str) -> None:
    require(re.fullmatch(r"[0-9a-f]{40}", expected_head) is not None, "expected head must be a full SHA")
    require(expected_head not in {BASE, CANDIDATE}, "do not assemble in a preserved predecessor")
    require(git(root, "rev-parse", "HEAD").decode().strip() == expected_head, "checkout head moved")
    require(not git(root, "status", "--porcelain", "--untracked-files=all"), "checkout must be clean")
    require(git(root, "show", "-s", "--format=%P", "HEAD").decode().strip() == CANDIDATE,
            "kit must be a direct child of preserved #91")
    changes = set(git(root, "diff", "--name-only", CANDIDATE, expected_head).decode().splitlines())
    require(changes == KIT_FILES, "kit delta is not the three reviewed preparation files")
    branch = git(root, "branch", "--show-current").decode().strip()
    require(branch not in {"main", "codex/issue87-session-api-port", "research-infra/hosted-supervisor-v1-20260926"},
            "protected branch")
    for path, expected in ((APP, APP_BLOB), (MATRIX, MATRIX_BLOB),
                           (VALIDATOR, VALIDATOR_BLOB), (CATALOG, CATALOG_BLOB)):
        require(blob(local_path(root, path).read_bytes()) == expected, f"unexpected bytes: {path}")
    require(not local_path(root, REVIEW).exists(), "renewal receipt already exists")


def validate_proposal(root: Path, proposed: bytes) -> dict:
    # Only the existing offline validation subcommand is allowed here.
    with tempfile.TemporaryDirectory(prefix="conduit-source91-check-") as directory:
        path = Path(directory) / "matrix.json"
        path.write_bytes(proposed)
        proc = subprocess.run([sys.executable, str(root / VALIDATOR), "validate-matrix", "--matrix", str(path)],
                              capture_output=True, timeout=60)
    result = strict_json(proc.stdout)
    require(proc.returncode == 0 and result.get("valid") is True and result.get("errors") == [],
            "unchanged provider validator rejected proposed matrix: " + json.dumps(result))
    return result


def apply_outputs(root: Path, original: bytes, proposed: bytes, receipt: dict) -> None:
    target, record = local_path(root, MATRIX), local_path(root, REVIEW)
    require(target.read_bytes() == original, "matrix changed before write")
    require(not record.exists(), "refuse to overwrite a receipt")
    # Prepare the replacement before creating either final output.
    fd, temporary = tempfile.mkstemp(prefix=".source91-", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(proposed)
        os.chmod(temporary, target.stat().st_mode & 0o777)
        created = False
        try:
            with record.open("xb") as stream:
                created = True
                stream.write((json.dumps(receipt, indent=2, sort_keys=True) + "\n").encode())
            os.replace(temporary, target)
        except BaseException:
            if created:
                record.unlink()
            raise
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        check_checkout(root, args.expected_head)
        base = git(root, "show", f"{BASE}:{APP}")
        candidate = local_path(root, APP).read_bytes()
        original = local_path(root, MATRIX).read_bytes()
        proposed, receipt = plan(base, candidate, original, datetime.now(timezone.utc).isoformat())
        receipt["kit_head"] = args.expected_head
        receipt["offline_validator"] = validate_proposal(root, proposed)
        check_checkout(root, args.expected_head)
        if args.apply:
            apply_outputs(root, original, proposed, receipt)
        print(json.dumps({"stage": "ASSEMBLED_UNCOMMITTED" if args.apply else "DRY_RUN_PASS",
                          "candidate_source": CANDIDATE, "matrix_sha256": digest(proposed),
                          "outputs": [MATRIX, REVIEW], "full_wrapper": "NOT_RUN",
                          "hosted_journey": "NOT_RUN"}, indent=2))
        return 0
    except (Refused, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print(json.dumps({"stage": "BLOCKED_SOURCE_RENEWAL", "reason": str(error)}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
