#!/usr/bin/env python3
"""Native preparation controls; retained owned fixtures, never a VM trial.

Requires an already built development CLI. Only its private fixture copy is
signed. --observe-latest contacts Apple's restore metadata service and issues
an Apple HTTPS HEAD request; it never downloads an IPSW or allocates a disk.
RESULT.json distinguishes application refusals, native parser evidence and
blocked observations. These controls do not establish guest confinement.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True, help="absent directory in an owned private parent")
    parser.add_argument("--observe-latest", action="store_true")
    args = parser.parse_args()
    try:
        source = args.binary.resolve(strict=True)
    except OSError as error:
        raise SystemExit("BLOCKED: built development CLI unavailable: " + str(error))
    if not source.is_file() or source.stat().st_uid != os.geteuid():
        raise SystemExit("BLOCKED: an owned built development CLI is required")
    parent = args.evidence_dir.parent.resolve(strict=True)
    if parent.stat().st_uid != os.geteuid() or parent.stat().st_mode & 0o022:
        raise SystemExit("BLOCKED: evidence parent must be owned and unshared")
    root = parent / args.evidence_dir.name
    root.mkdir(mode=0o700)  # Never overwrite a previous attempt.
    binary = root / "conduit-offline-sample"
    shutil.copyfile(source, binary)
    binary.chmod(0o700)
    repository = Path(__file__).resolve().parent.parent
    entitlement = repository / "Samples/OfflineProject/virtualization-metadata.entitlements"
    signed = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", str(entitlement), str(binary)], capture_output=True)
    (root / "codesign.stdout").write_bytes(signed.stdout)
    (root / "codesign.stderr").write_bytes(signed.stderr)
    if signed.returncode:
        raise SystemExit("BLOCKED: fixture signing failed; receipts retained")
    inspected = subprocess.run(["/usr/bin/codesign", "-d", "--entitlements", "-", str(binary)], capture_output=True)
    (root / "entitlements.txt").write_bytes(inspected.stdout + inspected.stderr)
    results = []

    def invoke(name, argv):
        command = [str(binary)] + [str(value) for value in argv]
        timed_out = False
        try:
            p = subprocess.run(command, capture_output=True, timeout=55, env={"PATH": "/usr/bin:/bin", "LANG": "C"})
            code, stdout, stderr = p.returncode, p.stdout, p.stderr
        except subprocess.TimeoutExpired as error:
            code, stdout, stderr = None, error.stdout or b"", error.stderr or b""
            timed_out = True
        (root / (name + ".stdout.json")).write_bytes(stdout)
        (root / (name + ".stderr.json")).write_bytes(stderr)
        (root / (name + ".invocation.json")).write_text(json.dumps({"argv": command, "exit_code": code, "timed_out": timed_out}, indent=2) + "\n")
        def decode(data):
            try:
                return json.loads(data)
            except (ValueError, UnicodeDecodeError):
                return {}
        return code, decode(stdout), decode(stderr)

    def check(name, condition, boundary):
        results.append({"name": name, "status": "PASS" if condition else "FAIL", "boundary": boundary})

    code, output, _ = invoke("capabilities", ["host-capabilities"])
    check("actual_host_capabilities", code == 2 and output.get("status") == "host_observation_only" and output.get("execution_admitted") == "false", "native_framework_observation")
    code, output, _ = invoke("capacity", ["host-preparation", root])
    check("capacity_observation_never_admits", code == 2 and output.get("imageAllocationAdmitted") is False and output.get("executionAdmitted") is False and "storage_not_reserved" in output.get("blockers", []), "application_refusal")
    invalid = root / "invalid.ipsw"
    invalid.write_bytes(b"owned invalid restore-image sentinel\n")
    invalid_hash = sha(invalid)
    packet = root / "invalid-packet"
    code, _, error = invoke("invalid-image", ["prepare-image", invalid, root, packet])
    check("real_native_parser_rejects_invalid_image", code == 2 and error.get("status") == "sample_failed" and error.get("error_domain") == "VZErrorDomain" and not packet.exists() and sha(invalid) == invalid_hash, "native_framework_parser")

    alias = root / "symlink.ipsw"
    alias.symlink_to(invalid)
    code, _, error = invoke("symlink-image", ["prepare-image", alias, root, root / "symlink-packet"])
    check("symlink_image_refuses_before_parser", code == 2 and error.get("status") == "unsafe_or_missing_path" and not (root / "symlink-packet").exists(), "application_refusal")
    hardlink = root / "hardlink.ipsw"
    os.link(invalid, hardlink)
    code, _, error = invoke("hardlink-image", ["prepare-image", hardlink, root, root / "hardlink-packet"])
    check("hardlink_image_refuses_before_parser", code == 2 and error.get("status") == "ordinary_owned_file_required" and not (root / "hardlink-packet").exists(), "application_refusal")
    hardlink.unlink()  # Owned alias only; restore sentinel to one link.
    linked_parent = root / "linked-parent"
    linked_parent.symlink_to(root, target_is_directory=True)
    code, _, error = invoke("linked-parent", ["prepare-image", invalid, root, linked_parent / "escaped-packet"])
    check("linked_parent_refuses_before_parser", code == 2 and error.get("status") == "unsafe_or_missing_path" and not (root / "escaped-packet").exists(), "application_refusal")
    existing = root / "existing-packet"
    existing.mkdir(mode=0o700)
    sentinel = existing / "sentinel"
    sentinel.write_bytes(b"preserve existing packet\n")
    sentinel_hash = sha(sentinel)
    code, _, error = invoke("existing-packet", ["prepare-image", invalid, root, existing])
    check("existing_packet_refuses_before_parser", code == 2 and error.get("status") == "packet_must_be_absent" and sha(sentinel) == sentinel_hash and list(existing.iterdir()) == [sentinel], "application_refusal")
    before = set(root.iterdir())
    code, _, error = invoke("run", ["run"])
    added = set(root.iterdir()) - before
    check("run_has_no_actuator", code == 2 and error.get("status") == "guest_runtime_not_in_preparation_slice" and added == {root / "run.stdout.json", root / "run.stderr.json", root / "run.invocation.json"}, "application_refusal")

    stage = root / "stage"
    project = repository / "Samples/OfflineProject/project"
    original_hash = sha(project / "message.txt")
    code, manifest, _ = invoke("stage", ["stage", project, stage])
    check("owned_project_stages", code == 0 and bool(manifest.get("sha256")), "application_workflow")
    code, output, _ = invoke("inspect-before", ["inspect", stage, "message.txt"])
    code2, search, _ = invoke("search", ["search", stage, "before"])
    check("inspect_and_search_staged_copy", code == 0 and "before" in output.get("text", "") and code2 == 0 and "message.txt" in search, "application_workflow")
    note = next(item for item in manifest["files"] if item["path"] == "message.txt")
    code, changed, _ = invoke("replace", ["replace", stage, "message.txt", note["sha256"], repository / "Samples/OfflineProject/replacement.txt"])
    code2, after, _ = invoke("inspect-after", ["inspect", stage, "message.txt"])
    check("scoped_edit_preserves_original", code == 0 and code2 == 0 and "after" in after.get("text", "") and changed.get("sha256") != manifest.get("sha256") and sha(project / "message.txt") == original_hash, "application_workflow")
    code, _, error = invoke("traversal", ["inspect", stage, "../invalid.ipsw"])
    check("staged_traversal_refuses", code == 2 and error.get("status") == "unsafe_path", "application_refusal")

    if args.observe_latest:
        destination = root / "platform-packet"
        code, hashes, error = invoke("latest", ["prepare-latest", root, destination])
        if code == 2 and destination.is_dir():
            report = json.loads((destination / "PREPARATION.json").read_bytes())
            names = {"PREPARATION.json", "hardware-model.bin", "machine-identifier.bin"}
            valid = set(hashes) == names and {p.name for p in destination.iterdir()} == names and all(sha(destination / n) == hashes[n] for n in names)
            valid = valid and report["restore"]["hardwareModelSHA256"] == hashes["hardware-model.bin"] and not report["executionAdmitted"] and not report["imageAllocationAdmitted"]
            check("actual_apple_platform_packet", valid, "native_framework_and_apple_https_metadata")
        else:
            results.append({"name": "actual_apple_platform_packet", "status": "BLOCKED", "boundary": "native_metadata_dependency", "detail": error})
    else:
        results.append({"name": "actual_apple_platform_packet", "status": "NOT_RUN", "boundary": "explicit_network_observation_not_selected"})
    status = "FAIL" if any(r["status"] == "FAIL" for r in results) else "BLOCKED" if any(r["status"] == "BLOCKED" for r in results) else "PASS_WITH_BOUNDS"
    report = {"schema": "conduit-offline-preparation-probe/v1", "status": status, "source_binary_sha256": sha(source), "signed_binary_sha256": sha(binary), "entitlements_sha256": sha(entitlement), "results": results, "guest_execution": "NOT_RUN", "confinement": "NOT_ESTABLISHED"}
    (root / "RESULT.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 1 if status == "FAIL" else 2 if status == "BLOCKED" else 0


if __name__ == "__main__":
    sys.exit(main())
