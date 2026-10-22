#!/usr/bin/env python3
"""Read-only hosted admission probe; never installs or launches the candidate.

Public output is an allowlisted measurement, not raw UI, credentials or trial
responses. This is apparatus, not an execution profile or acceptance runner.
"""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import pwd
import re
import socket
import subprocess
import sys
import tempfile
import zipfile

REPO = "camerontjs-dot/Conduit"
R3 = "382290bded447ea805ac71ed7d57bebeaf65f471"
R3_TREE = "0f9f7c174665a09eb0c6fc213d893e3be3111b79"
ARTIFACT = 12427346536
BUILD_RUN = 39781169211
ENVELOPE = "de59581a3b7899859a71a337583d7d67b4f90d20bb15d8b33b29a3bb6b3be552"
APP_ZIP = "b9711d6827699f82ca92ac1cc3d340457f6042241361b3bc2eb86c3197a18106"
BINARY = "35a3b0f18afe99ed1b1d93bac628f9fdbf2f78a2c0169d49c274eb93233022c9"
ALLOWED_DIFF = {
    ".github/workflows/r3-guest-probe.yml", "EXPERIMENT.json",
    "docs/qualification/r3-github-guest-probe.md",
    "scripts/r3-guest-probe.py", "scripts/test-r3-guest-probe.py",
}


class ProbeFailure(Exception):
    """Contains a fixed public-safe reason code only."""


def require(condition, code):
    if not condition:
        raise ProbeFailure(code)


def run(argv, *, input=None, timeout=60, check=True):
    p = subprocess.run(argv, input=input, capture_output=True, text=True,
                       timeout=timeout)
    if check:
        require(p.returncode == 0, "COMMAND_FAILED")
    return p


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def verify_metadata(value):
    require(value.get("id") == ARTIFACT, "ARTIFACT_ID_MISMATCH")
    require(value.get("name") == "conduit-macos-arm64", "ARTIFACT_NAME_MISMATCH")
    require(value.get("expired") is False, "ARTIFACT_EXPIRED_OR_UNKNOWN")
    require(value.get("digest") == "sha256:" + ENVELOPE, "ARTIFACT_DIGEST_MISMATCH")
    require(value.get("workflow_run", {}).get("id") == BUILD_RUN,
            "ARTIFACT_RUN_MISMATCH")
    require(value.get("workflow_run", {}).get("head_sha") == R3,
            "ARTIFACT_SOURCE_MISMATCH")


def check_zip(path):
    with zipfile.ZipFile(path) as archive:
        require(len(archive.infolist()) <= 10000, "ARCHIVE_ENTRY_LIMIT")
        require(sum(i.file_size for i in archive.infolist()) <= 128 * 1024 * 1024,
                "ARCHIVE_SIZE_LIMIT")
        for info in archive.infolist():
            name = PurePosixPath(info.filename)
            require(not name.is_absolute() and ".." not in name.parts,
                    "ARCHIVE_PATH_ESCAPE")


def admission_blockers(env, artifact_verified):
    blockers = []
    for ok, reason in [
        (env.get("os") == "15.7.9" and env.get("build") == "24G830"
         and env.get("architecture") == "arm64", "EXACT_OS_REQUIRED"),
        (env.get("trial_user") is True and env.get("admin_member") is False
         and env.get("uid", 0) > 0, "STANDARD_TRIAL_USER_REQUIRED"),
        (env.get("gui", {}).get("on_console") is True
         and env.get("gui", {}).get("login_done") is True,
         "LOGGED_IN_GUI_REQUIRED"),
        (artifact_verified is True, "ARTIFACT_VERIFICATION_REQUIRED"),
    ]:
        if not ok:
            blockers.append(reason)
    # This probe deliberately has no client or human-observation authority.
    # Neither a GUI boolean nor a CI pass can discharge these requirements.
    blockers += ["PRIVATE_TRIAL_RECEIPT_EXPORT_NOT_PROVISIONED",
                 "DEDICATED_TRANSPORT_NOT_PROVISIONED",
                 "HUMAN_OBSERVATION_NOT_CALIBRATED",
                 "FRESH_CHATGPT_DISCOVERY_NOT_RUN"]
    return blockers


def observe_environment(scratch):
    user = pwd.getpwuid(os.getuid()).pw_name
    member = run(["/usr/bin/dsmemberutil", "checkmembership", "-U", user,
                  "-G", "admin"], check=False)
    member_text = member.stdout.strip().lower()
    admin = (False if "is not a member" in member_text else
             True if "is a member" in member_text else None)
    env = {
        "os": run(["/usr/bin/sw_vers", "-productVersion"]).stdout.strip(),
        "build": run(["/usr/bin/sw_vers", "-buildVersion"]).stdout.strip(),
        "architecture": platform.machine(), "uid": os.getuid(),
        "trial_user": user == "conduittrial", "admin_member": admin,
        "console_user_is_self": Path("/dev/console").stat().st_uid == os.getuid(),
    }
    source = scratch / "session.swift"
    source.write_text('''import AppKit
import ApplicationServices
import CoreGraphics
let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
let v: [String: Any] = [
    "on_console": d["kCGSessionOnConsoleKey"] as? Bool ?? false,
    "login_done": d["kCGSessionLoginDoneKey"] as? Bool ?? false,
    "display_count": NSScreen.screens.count,
    "accessibility_trusted": AXIsProcessTrusted(),
    "screen_capture_preflight": CGPreflightScreenCaptureAccess()
]
let data = try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
''')
    gui = run(["/usr/bin/swift", str(source)], timeout=120, check=False)
    env["gui_probe_exit"] = gui.returncode
    if gui.returncode == 0:
        env["gui"] = json.loads(gui.stdout)
    # Preflight calls above never request permission or capture screen pixels.
    gatekeeper = run(["/usr/sbin/spctl", "--status"], check=False)
    env["gatekeeper_assessments_enabled"] = (
        True if "assessments enabled" in gatekeeper.stdout else
        False if "assessments disabled" in gatekeeper.stdout else None)
    with socket.socket() as sock:
        sock.settimeout(2)
        env["port_8750_accepts_connection"] = sock.connect_ex(("127.0.0.1", 8750)) == 0
    return env


def download(url, destination):
    token = os.environ.get("GH_TOKEN", "")
    require(re.fullmatch(r"[A-Za-z0-9_]+", token) is not None, "GITHUB_TOKEN_MISSING")
    # curl drops Authorization on cross-host redirects. No signed URL, token,
    # config stdin or raw error text is printed or placed in the receipt.
    run(["/usr/bin/curl", "--config", "-", "--fail", "--silent", "--show-error",
         "--location", "--proto", "=https", "--proto-redir", "=https",
         "--max-time", "120", "--max-filesize", "16777216", "--output",
         str(destination), url], input='header = "Authorization: Bearer ' + token + '"\n',
        timeout=130)


def inspect_artifact(scratch):
    base = "https://api.github.com/repos/" + REPO + "/actions/artifacts/" + str(ARTIFACT)
    metadata = scratch / "artifact.json"
    download(base, metadata)
    verify_metadata(json.loads(metadata.read_text()))
    envelope = scratch / "envelope.zip"
    download(base + "/zip", envelope)
    require(digest(envelope) == ENVELOPE, "ENVELOPE_HASH_MISMATCH")
    check_zip(envelope)
    inner = scratch / "app.zip"
    with zipfile.ZipFile(envelope) as archive:
        require(archive.namelist() == ["Conduit-macOS-arm64.zip"], "ENVELOPE_CONTENT_MISMATCH")
        inner.write_bytes(archive.read("Conduit-macOS-arm64.zip"))
    require(digest(inner) == APP_ZIP, "APP_ZIP_HASH_MISMATCH")
    check_zip(inner)
    unpacked = scratch / "unpacked"
    run(["/usr/bin/ditto", "-x", "-k", str(inner), str(unpacked)])
    app = unpacked / "Conduit.app"
    require(digest(app / "Contents/MacOS/Conduit") == BINARY, "BINARY_HASH_MISMATCH")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require([info.get(k) for k in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"]]
            == ["dev.camerontjs.conduit", "0.3.0", "3"], "BUNDLE_IDENTITY_MISMATCH")
    signature = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=False)
    require(signature.returncode == 0, "SIGNATURE_VERIFICATION_FAILED")
    return {"artifact_id": ARTIFACT, "build_run": BUILD_RUN,
            "envelope_sha256": ENVELOPE, "app_zip_sha256": APP_ZIP,
            "binary_sha256": BINARY, "signature_exit": signature.returncode,
            "installed": False, "launched": False}


def main():
    require(os.environ.get("GITHUB_ACTIONS") == "true", "GITHUB_ONLY")
    require(os.environ.get("GITHUB_REPOSITORY") == REPO, "REPOSITORY_MISMATCH")
    require(platform.system() == "Darwin", "MACOS_REQUIRED")
    root = Path(__file__).resolve().parent.parent
    os.chdir(root)
    require(run(["git", "rev-parse", R3 + "^{tree}"]).stdout.strip() == R3_TREE,
            "FROZEN_TREE_MISMATCH")
    changed = set(run(["git", "diff", "--name-only", R3, "HEAD"]).stdout.splitlines())
    require(changed <= ALLOWED_DIFF, "PRODUCT_DIFF_NOT_ALLOWED")
    receipt = {
        "schema": "conduit-r3-github-admission/v1", "evidence_layer": "HOSTED_PREFLIGHT_ONLY",
        "checkout_commit": run(["git", "rev-parse", "HEAD"]).stdout.strip(),
        "checkout_tree": run(["git", "rev-parse", "HEAD^{tree}"]).stdout.strip(),
        "frozen_r3_commit": R3, "frozen_r3_tree": R3_TREE,
        "candidate_relationship": "apparatus-only additive diff; product bytes unchanged",
        "changed_paths": sorted(changed), "run_id": os.environ.get("GITHUB_RUN_ID"),
        "image_version": os.environ.get("ImageVersion"),
        "app_installed": False, "app_launched": False, "tunnel_created": False,
        "permissions_requested": False, "privileged_commands_used": False,
        "trial_cases": "A01-A06_NOT_RUN; B01-B10_BLOCKED_PROFILE_MISSING",
    }
    scratch = None
    try:
        with tempfile.TemporaryDirectory(prefix="conduit-r3-admission-") as directory:
            scratch = Path(directory)
            receipt["environment"] = observe_environment(scratch)
            receipt["artifact"] = inspect_artifact(scratch)
            receipt["blockers"] = admission_blockers(receipt["environment"], True)
            receipt["result"] = "PROBE_COMPLETE_TRIAL_BLOCKED"
    except Exception as exc:
        receipt["result"] = "PROBE_FAILED_TRIAL_NOT_RUN"
        receipt["failure"] = str(exc) if isinstance(exc, ProbeFailure) else type(exc).__name__
    finally:
        receipt["temporary_files_removed"] = scratch is not None and not scratch.exists()
        receipt["guest_disposal"] = "provider lifecycle; job completion checked separately"
        print("R3_ADMISSION_RECEIPT=" + json.dumps(receipt, sort_keys=True))
    return 0 if receipt["result"] == "PROBE_COMPLETE_TRIAL_BLOCKED" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ProbeFailure as error:
        print("R3_ADMISSION_START_REFUSED=" + str(error))
        sys.exit(1)
