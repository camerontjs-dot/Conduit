#!/usr/bin/env python3
"""Owned native App Sandbox falsification; no product grant or custom SBPL.

The macOS grep control is a feasibility control, not execution of D3's
guest-path script. All fixtures/results are retained. Never delete an old run.
"""
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import secrets
import socket
import subprocess
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class FixtureAuthority:
    """Trusted in-memory fixture grants only; never exposed by the product."""
    def __init__(self, observe):
        self.observe = observe
        self.issued = {}

    def issue(self, operation):
        grant = {"token": secrets.token_hex(32), "operation": operation, "facts": self.observe()}
        self.issued[grant["token"]] = copy.deepcopy(grant)
        return grant

    def validate(self, grant, operation):
        if not isinstance(grant, dict) or not isinstance(grant.get("token"), str):
            raise RuntimeError("development_authority_absent")
        trusted = self.issued.get(grant["token"])
        if trusted is None or grant != trusted or grant["operation"] != operation:
            raise RuntimeError("development_authority_invalid")
        if grant["facts"] != self.observe():
            raise RuntimeError("development_authority_stale")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    root = args.evidence_dir.resolve()
    root.mkdir(mode=0o700)  # absent owned run only
    if sys.platform != "darwin":
        raise SystemExit("BLOCKED: native macOS required")
    project, scratch, outside = [root / n for n in ("project", "scratch", "outside")]
    for directory in (project, scratch, outside):
        directory.mkdir(mode=0o700)
    note = project / "message.txt"
    note.write_bytes(b"after\n")
    sentinel = outside / "sentinel.txt"
    sentinel.write_bytes(b"owned outside sentinel\n")
    (project / "outside-link").symlink_to(outside, target_is_directory=True)
    spec = importlib.util.spec_from_file_location("native_probe", Path(__file__).with_name("probe-direct-execution-policy.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source = root / "probe.c"
    source.write_text(module.PROBE)  # exact existing native syscall probe
    probe = project / "native-probe"
    wrapper_source = root / "app-sandbox-launcher.c"
    wrapper_source.write_text('#include <unistd.h>\n#include <stdio.h>\nint main(int n,char **v){if(n<2)return 64;execv(v[1],v+1);perror("execv");return 126;}\n')
    identifier = "local.conduit.m2.native-" + secrets.token_hex(8)
    bundle = root / "NativeBoundaryProbe.app"
    executable_dir = bundle / "Contents/MacOS"
    executable_dir.mkdir(parents=True)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundleExecutable": "app-sandbox-launcher",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "LSBackgroundOnly": True}))
    wrapper = executable_dir / "app-sandbox-launcher"
    for name, src, dest in [("probe", source, probe), ("launcher", wrapper_source, wrapper)]:
        p = subprocess.run(["/usr/bin/clang", str(src), "-o", str(dest)], capture_output=True)
        (root / (name + ".compile.stdout")).write_bytes(p.stdout)
        (root / (name + ".compile.stderr")).write_bytes(p.stderr)
        if p.returncode:
            raise SystemExit("BLOCKED: native compile failed")
    entitlement = root / "fixture.entitlements"
    entitlement.write_bytes(plistlib.dumps({
        "com.apple.security.app-sandbox": True,
        "com.apple.security.temporary-exception.files.absolute-path.read-only": [str(project) + "/"],
        "com.apple.security.temporary-exception.files.absolute-path.read-write": [str(scratch) + "/"],
    }))
    p = subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", identifier,
                        "--entitlements", str(entitlement), str(bundle)], capture_output=True)
    (root / "codesign.stdout").write_bytes(p.stdout)
    (root / "codesign.stderr").write_bytes(p.stderr)
    if p.returncode:
        raise SystemExit("BLOCKED: owned signing failed")
    authority = FixtureAuthority(lambda: {"profile": "native-app-sandbox-feasibility/v1", "launcher": sha(wrapper),
        "entitlements": sha(entitlement), "probe": sha(probe), "input": sha(note),
        "project_identity": [project.stat().st_dev, project.stat().st_ino],
        "scratch_identity": [scratch.stat().st_dev, scratch.stat().st_ino],
        "declared_executables": ["/bin/bash", "/usr/bin/grep", str(probe)], "network": "deny"})
    launches = 0
    cases = []

    def run(name, argv, grant, confined=True):
        nonlocal launches
        authority.validate(grant, name)  # before invocation receipt or payload spawn
        launches += 1
        command = ([str(wrapper)] if confined else []) + [str(v) for v in argv]
        p = subprocess.run(command, capture_output=True, timeout=10,
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "HOME": str(scratch), "TMPDIR": str(scratch)})
        (root / (name + ".stdout")).write_bytes(p.stdout)
        (root / (name + ".stderr")).write_bytes(p.stderr)
        row = {"name": name, "argv": command, "exit_code": p.returncode,
               "stdout": p.stdout.decode(errors="replace"), "stderr": p.stderr.decode(errors="replace"),
               "boundary": "App Sandbox" if confined else "ambient owned control"}
        (root / (name + ".json")).write_text(json.dumps(row, indent=2) + "\n")
        return row

    for name, grant in [("absent", None), ("forged", {"token": "unissued"}),
                        ("wrong-operation", authority.issue("other-operation"))]:
        prior = launches
        try:
            run(name, ["/bin/bash", "-c", "exit 0"], grant)
            code = "unexpected_launch"
        except RuntimeError as error:
            code = str(error)
        cases.append({"name": name, "status": "PASS" if code.startswith("development_authority_") and launches == prior else "FAIL",
                      "boundary": "application refusal", "detail": code, "launches": launches - prior})
    argv = ["/bin/bash", "--noprofile", "--norc", "-c", '/usr/bin/grep -qx after "$1/message.txt" && printf "sample check passed\\n"', "fixture", project]
    row = run("permitted-native-grep-control", argv, authority.issue("permitted-native-grep-control"))
    row["status"] = "PASS" if row["exit_code"] == 0 and row["stdout"] == "sample check passed\n" else "BLOCKED"
    cases.append(row)
    if row["status"] == "PASS":
        paths = [("outside-read", "read", sentinel), ("outside-write", "write", outside / "write"),
                 ("traversal", "write", project / ".." / "outside" / "traversal"),
                 ("symlink", "write", project / "outside-link" / "symlink"),
                 ("detached-write", "detached-write", outside / "detached")]
        for name, mode, target in paths:
            row = run(name, [probe, mode, target], authority.issue(name))
            row["status"] = "PASS" if row["exit_code"] == 13 and (mode == "read" or not target.exists()) else "FAIL"
            cases.append(row)
        name = "undeclared-executable"
        row = run(name, [probe, "exec", "/usr/bin/true"], authority.issue(name))
        row["status"] = "PASS" if row["exit_code"] == 126 else "FAIL"
        cases.append(row)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0)); listener.listen(2)
            name = "ambient-network-control"
            row = run(name, [probe, "connect", listener.getsockname()[1]], authority.issue(name), confined=False)
            row["status"] = "PASS" if row["exit_code"] == 0 else "BLOCKED"
            cases.append(row)
            if row["status"] == "PASS":
                name = "network-denied"
                row = run(name, [probe, "connect", listener.getsockname()[1]], authority.issue(name))
                row["status"] = "PASS" if row["exit_code"] in (20, 21) else "FAIL"
                cases.append(row)
    result = {"schema": "conduit-native-supported-boundary-probe/v1", "status": "REJECTED" if any(c["status"] == "FAIL" for c in cases) else "BLOCKED" if any(c["status"] == "BLOCKED" for c in cases) else "PASS_WITH_BOUNDS",
              "cases": cases, "launcher_sha256": sha(wrapper), "entitlements_sha256": sha(entitlement),
              "probe_sha256": sha(probe), "source_probe_sha256": sha(source),
              "outside_sentinel_unchanged": sentinel.read_bytes() == b"owned outside sentinel\n",
              "fixed_guest_path_script": "NOT_RUN: native feasibility control only", "independent_qualification": "NOT_RUN"}
    (root / "RESULT.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": result["status"], "cases": [{"name": c["name"], "status": c["status"], "exit": c.get("exit_code")} for c in cases]}, indent=2))
    return 1 if result["status"] == "REJECTED" else 2 if result["status"] == "BLOCKED" else 0


if __name__ == "__main__":
    sys.exit(main())
