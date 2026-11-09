#!/usr/bin/env python3
"""Owned fixture Linux boundary on native macOS Virtualization.framework.

Uses prepared, separately verified kernel/APK assets and an owned local cross
compiler. No ordinary-project input, host mount, NIC, disk, app integration,
package download or deletion occurs in this runner. Retains every attempt.
"""
import argparse
import base64
import copy
import gzip
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import secrets
import selectors
import shutil
import stat
import subprocess
import sys
import time


def sha(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def bounded_file(path, limit):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or not 0 < info.st_size <= limit:
        raise RuntimeError("owned_ordinary_bounded_asset_required: " + str(path))
    return path.read_bytes()


def capture(argv, environment, timeout, limit=1024*1024, capability=None):
    """Drain both pipes with bounded retention; timeout is never stop proof."""
    started = time.monotonic()
    inherited = ()
    if capability is not None:
        read_fd, write_fd = os.pipe()
        # In a fresh CLI process this is FD 3. Refuse a conflicting host FD;
        # never close or repurpose a descriptor owned by another caller.
        if read_fd != 3:
            os.close(read_fd); os.close(write_fd)
            raise RuntimeError("fixture_fd_three_unavailable")
        os.write(write_fd, capability); os.close(write_fd)
        inherited = (read_fd,)
    try:
        process = subprocess.Popen([str(a) for a in argv], stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, pass_fds=inherited)
    finally:
        if inherited:
            os.close(read_fd)
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    totals = {"stdout": 0, "stderr": 0}
    timed_out = False
    with selectors.DefaultSelector() as selector:
        for stream in buffers:
            selector.register(getattr(process, stream), selectors.EVENT_READ, stream)
        while selector.get_map():
            if time.monotonic() - started > timeout:
                timed_out = True
                process.kill()  # lost native ownership stays UNKNOWN below
                break
            for key, _ in selector.select(0.05):
                data = os.read(key.fd, 16384)
                if not data:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                stream = key.data
                totals[stream] += len(data)
                buffers[stream] += data[:max(0, limit - len(buffers[stream]))]
    for stream in buffers:
        getattr(process, stream).close()
    try:
        code = process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        timed_out = True
        process.kill()
        code = process.wait(timeout=1)
    return {"stdout": bytes(buffers["stdout"]), "stderr": bytes(buffers["stderr"]),
            "exit_code": code, "host_timeout": timed_out,
            "capture_truncated": any(n > limit for n in totals.values()), "observed_bytes": totals}


class Initramfs:
    """Pure newc transformer, bounded at 32 MiB; never mounts an image."""
    def __init__(self):
        self.bytes = bytearray()
        self.names = set()
        self.manifest = {}

    def add(self, name, mode, data=b"", major=0, minor=0):
        if name in self.names or name.startswith("/") or ".." in name.split("/"):
            raise RuntimeError("invalid_or_duplicate_cpio_path")
        self.names.add(name)
        encoded = name.encode() + b"\0"
        fields = [len(self.names), mode, 0, 0, 1, 0, len(data), 0, 0, major, minor, len(encoded), 0]
        self.bytes += b"070701" + "".join(f"{v:08x}" for v in fields).encode() + encoded
        self.bytes += b"\0" * (-len(self.bytes) % 4)
        self.bytes += data
        self.bytes += b"\0" * (-len(self.bytes) % 4)
        if len(self.bytes) > 32 * 1024 * 1024:
            raise RuntimeError("initramfs_byte_limit")
        self.manifest[name] = {"mode": mode, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def main(launch=capture, *, vm_deadline_seconds=15, live_timeout_mode=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--zig", type=Path, required=True)
    parser.add_argument("--preparation-cli", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    out = args.evidence_dir.resolve()
    out.mkdir(mode=0o700)
    repository = Path(__file__).resolve().parent.parent
    source = repository / "scripts/small-boundary"
    receipt = module("receipt", source / "receipt.py")
    pins = json.loads((source / "assets.json").read_text())
    if sha(args.kernel) != pins["kernel"]["sha256"] or sha(args.zig) != pins["zig"]["executable_sha256"]:
        raise RuntimeError("pinned_kernel_or_compiler_mismatch")
    for name, identity in pins["root_files"].items():
        path = args.rootfs / name
        if "symlink" in identity:
            if not path.is_symlink() or os.readlink(path) != identity["symlink"]:
                raise RuntimeError("pinned_library_link_mismatch")
        elif sha(path) != identity["sha256"]:
            raise RuntimeError("pinned_toolchain_file_mismatch")
    native = module("native", repository / "scripts/probe-supported-native-boundary.py")
    original = module("original", repository / "scripts/probe-direct-execution-policy.py")
    nonce = secrets.token_hex(32)
    environment = {"PATH": "/usr/bin:/bin", "LANG": "C"}
    invocations = []

    def command(name, argv, env=None, timeout=90):
        p = capture(argv, env or environment, timeout)
        (out / (name + ".stdout")).write_bytes(p["stdout"])
        (out / (name + ".stderr")).write_bytes(p["stderr"])
        row = {"argv": [str(a) for a in argv], **{k:v for k,v in p.items() if k not in ("stdout", "stderr")}}
        (out / (name + ".invocation.json")).write_text(json.dumps(row, indent=2) + "\n")
        invocations.append(row)
        if p["exit_code"] or p["host_timeout"] or p["capture_truncated"]:
            raise RuntimeError(name + "_failed")
        return p["stdout"]

    stage = out / "staged-project"
    project = repository / "Samples/OfflineProject/project"
    original_message = sha(project / "message.txt")
    staged = json.loads(command("stage", [args.preparation_cli, "stage", project, stage]))
    command("inspect-before", [args.preparation_cli, "inspect", stage, "message.txt"])
    command("search", [args.preparation_cli, "search", stage, "before"])
    prior = next(f for f in staged["files"] if f["path"] == "message.txt")["sha256"]
    command("edit", [args.preparation_cli, "replace", stage, "message.txt", prior, repository / "Samples/OfflineProject/replacement.txt"])
    command("inspect-after", [args.preparation_cli, "inspect", stage, "message.txt"])
    command("export", [args.preparation_cli, "export-input", stage, out / "exported-project"])
    if sha(project / "message.txt") != original_message:
        raise RuntimeError("original_project_changed")
    for filename in ["VMRunner.swift", "guest-suite.c", "receipt.py"]:
        shutil.copyfile(source / filename, out / filename)
    shutil.copyfile(Path(__file__), out / "probe-small-linux-boundary.py")
    (out / "probe.c").write_text(original.PROBE)
    cross = {**os.environ, "ZIG_LOCAL_CACHE_DIR": str(out / "zig-local-cache"),
             "ZIG_GLOBAL_CACHE_DIR": str(out.parent / "owned-zig-cache")}
    command("compile-init", [args.zig, "cc", "-target", "aarch64-linux-musl", "-static", "-Os", out / "guest-suite.c", "-o", out / "init"], cross)
    command("compile-probe", [args.zig, "cc", "-target", "aarch64-linux-musl", "-static", "-Os", out / "probe.c", "-o", out / "probe"], cross)
    (out / "kernel").write_bytes(bounded_file(args.kernel, 64 * 1024 * 1024))

    image = Initramfs()
    for name in ["dev", "bin", "lib", "usr", "usr/bin", "usr/lib", "outside", "sealed", "work"]:
        image.add(name, stat.S_IFDIR | (0o777 if name == "outside" else 0o755))
    image.add("dev/console", stat.S_IFCHR | 0o600, major=5, minor=1)
    image.add("dev/null", stat.S_IFCHR | 0o666, major=1, minor=3)
    image.add("init", stat.S_IFREG | 0o755, bounded_file(out / "init", 2 * 1024 * 1024))
    image.add("probe", stat.S_IFREG | 0o755, bounded_file(out / "probe", 2 * 1024 * 1024))
    image.add("outside/undeclared", stat.S_IFREG | 0o755, bounded_file(out / "probe", 2 * 1024 * 1024))
    image.add("outside/undeclared-dynamic", stat.S_IFREG | 0o755, bounded_file(args.rootfs / "bin/grep", 2 * 1024 * 1024))
    image.add("outside/sentinel.txt", stat.S_IFREG | 0o666, b"owned outside sentinel\n")
    image.add("run-nonce", stat.S_IFREG | 0o600, nonce.encode())
    if live_timeout_mode:
        image.add("live-timeout-fixture", stat.S_IFREG | 0o600, b"owned hold\n")
    image.add("sealed/message.txt", stat.S_IFREG | 0o644, bounded_file(stage / "message.txt", 65536))
    script = bounded_file(stage / "scripts/test.sh", 65536)
    image.add("sealed/test.sh", stat.S_IFREG | 0o755, script)
    image.add("bin/bash", stat.S_IFREG | 0o755, bounded_file(args.rootfs / "bin/bash", 2 * 1024 * 1024))
    image.add("usr/bin/grep", stat.S_IFREG | 0o755, bounded_file(args.rootfs / "bin/grep", 2 * 1024 * 1024))
    # Include the observed shared-library closure only, not Bash's optional
    # loadable builtins or unrelated package payloads.
    for name, identity in pins["root_files"].items():
        if not name.startswith(("lib/", "usr/lib/")):
            continue
        path = args.rootfs / name
        if "symlink" in identity:
            target = os.readlink(path)
            if target.startswith("/") or ".." in target.split("/"):
                raise RuntimeError("library_link_not_local")
            image.add(name, stat.S_IFLNK | 0o777, target.encode())
        else:
            image.add(name, stat.S_IFREG | (0o755 if name == "lib/ld-musl-aarch64.so.1" else 0o644), bounded_file(path, 4 * 1024 * 1024))
    image.add("TRAILER!!!", 0)
    (out / "initrd.cpio.gz").write_bytes(gzip.compress(image.bytes, mtime=0))
    (out / "image-manifest.json").write_text(json.dumps(image.manifest, indent=2) + "\n")
    ticket = json.dumps({"operation": "linux-suite", "nonce": nonce,
                         "kernel_sha256": sha(out / "kernel"), "initrd_sha256": sha(out / "initrd.cpio.gz")}, sort_keys=True).encode()
    (out / "native-ticket.json").write_bytes(ticket)
    (out / "FixtureGate.swift").write_text(
        "let fixtureGrantDigest = " + json.dumps(hashlib.sha256(ticket).hexdigest()) + "\n" +
        "let fixtureClaimPath = " + json.dumps(str(out / "native-launch.claim")) + "\n" +
        "let fixtureDeadlineSeconds: Double = " + str(vm_deadline_seconds) + "\n" +
        "let fixtureTermMode = " + json.dumps(live_timeout_mode or "none") + "\n" +
        "let fixtureNonce = " + json.dumps(nonce) + "\n")
    # Top-level executable code must be in main.swift in a multi-file build.
    shutil.copyfile(out / "VMRunner.swift", out / "main.swift")
    command("compile-runner", ["/usr/bin/swiftc", "-O", "-target", "arm64-apple-macos14.0", "-framework", "Virtualization", out / "main.swift", out / "FixtureGate.swift", "-o", out / "VMRunner"],
            {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"})
    entitlements = out / "virtualization.entitlements"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.virtualization": True}))
    command("sign", ["/usr/bin/codesign", "--force", "--sign", "-", "--entitlements", entitlements, out / "VMRunner"])
    command("verify-signature", ["/usr/bin/codesign", "--verify", "--strict", out / "VMRunner"])
    profile = {"id": "portable-bash-grep-linux-fixture/v1", "cpu": 1, "VM_memory_bytes": 134217728,
               "job_memory_bytes": 33554432, "pids": 16, "cpu_quota": "20000 100000", "wall_ms": 1500,
               "VM_deadline_s": vm_deadline_seconds, "project_bytes": 1048576, "scratch_bytes": 1048576,
               "retained_stream_bytes": 4096, "observed_stream_ceiling": 65536,
               "output_budget_semantics": "kill threshold; pipe/drain overshoot counted, not a hard byte ceiling",
               "network_devices": [], "disks": [], "shares": [], "socket_devices": [],
               "argv": ["/bin/bash", "/work/project/scripts/test.sh", "--jobs", "2"],
               "executable_closure": ["/bin/bash", "/usr/bin/grep", "/lib/ld-musl-aarch64.so.1"],
               "development_probe_executable": "/probe",
               "asset_pins_sha256": sha(source / "assets.json"),
               "check_script_sha256": hashlib.sha256(script).hexdigest()}
    if live_timeout_mode:
        profile["live_timeout_mode"] = live_timeout_mode
    facts = lambda: {"profile": profile, "assets": {name: sha(out / name) for name in ["kernel", "initrd.cpio.gz", "VMRunner"]},
                     "staged_input": sha(stage / "message.txt"), "nonce": nonce}
    authority = native.FixtureAuthority(facts)
    attempts = 0

    def admit(grant, operation):
        nonlocal attempts
        authority.validate(grant, operation)
        attempts += 1

    refusals = []
    valid = authority.issue("linux-suite")
    mutations = [("absent", None), ("forged", {"token": "unissued"}), ("wrong-operation", authority.issue("other"))]
    for name, field in [("wrong-profile", "profile"), ("wrong-asset", "assets"), ("wrong-nonce", "nonce"), ("wrong-input", "staged_input")]:
        bad = copy.deepcopy(valid); bad["facts"][field] = "untrusted"; mutations.append((name, bad))
    for name, grant in mutations:
        before = attempts
        try: admit(grant, "linux-suite"); detail = "unexpected_admission"
        except RuntimeError as error: detail = str(error)
        refusals.append({"name": name, "status": "PASS" if detail.startswith("development_authority_") and attempts == before else "FAIL", "detail": detail, "VM_launches": attempts - before})
    before_bytes = (stage / "message.txt").read_bytes()
    (out / "before-stale-input.txt").write_bytes(before_bytes)
    (stage / "message.txt").write_bytes(b"changed after grant\n")
    try: admit(valid, "linux-suite"); detail = "unexpected_admission"
    except RuntimeError as error: detail = str(error)
    refusals.append({"name": "actual-stale-input", "status": "PASS" if detail == "development_authority_stale" and attempts == 0 else "FAIL", "detail": detail, "VM_launches": attempts})
    (stage / "message.txt").write_bytes(before_bytes)
    (out / "authority-refusals.json").write_text(json.dumps(refusals, indent=2) + "\n")
    if any(r["status"] != "PASS" for r in refusals):
        raise RuntimeError("authority_controls_failed")
    native_refusals = []
    native_argv = [out / "VMRunner", out / "kernel", out / "initrd.cpio.gz", "--fixture-fd=3"]
    for name, argv, capability in [
        ("absent", native_argv[:-1], None),
        ("invalid", native_argv, b"forged"),
        ("changed-assets", [out / "VMRunner", out / "initrd.cpio.gz", out / "kernel", "--fixture-fd=3"], ticket),
    ]:
        observed = capture(argv, environment, 3, capability=capability)
        (out / ("native-refusal-" + name + ".stdout")).write_bytes(observed["stdout"])
        (out / ("native-refusal-" + name + ".stderr")).write_bytes(observed["stderr"])
        events = [json.loads(line) for line in observed["stderr"].splitlines()]
        native_refusals.append({"name": name, "exit_code": observed["exit_code"], "events": events,
            "claim_absent": not (out / "native-launch.claim").exists(),
            "status": "PASS" if observed["exit_code"] == 77 and len(events) == 1 and events[0]["event"] == "authority_refused" and
                not (out / "native-launch.claim").exists() and not observed["stdout"] and not observed["capture_truncated"] and not observed["host_timeout"] else "FAIL"})
    (out / "native-authority-refusals.json").write_text(json.dumps(native_refusals, indent=2) + "\n")
    if any(r["status"] != "PASS" for r in native_refusals):
        raise RuntimeError("native_authority_controls_failed")
    admit(valid, "linux-suite")
    claim = os.open(out / "launch.claim", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.write(claim, nonce.encode()); os.fsync(claim); os.close(claim)
    (out / "GRANT.json").write_text(json.dumps(valid, indent=2) + "\n")
    (out / "PROFILE.json").write_text(json.dumps(profile, indent=2) + "\n")
    start = time.monotonic()
    p = launch(native_argv, environment, 25, 256*1024, capability=ticket)
    if live_timeout_mode:
        observe = module("live_timeout", source / "live_timeout.py")
        return observe.finish(out, live_timeout_mode, nonce, p, receipt, refusals, native_refusals,
                              original_project_unchanged=sha(project / "message.txt") == original_message)
    (out / "serial.stdout").write_bytes(p["stdout"])
    (out / "host.stderr").write_bytes(p["stderr"])
    invocation = {**{k:v for k,v in p.items() if k not in ("stdout", "stderr")}, "wall_s": time.monotonic() - start, "launches": attempts,
                  "initrd_bytes": (out / "initrd.cpio.gz").stat().st_size, "kernel_bytes": (out / "kernel").stat().st_size}
    (out / "VM.invocation.json").write_text(json.dumps(invocation, indent=2) + "\n")
    replay_refusal = {"status": "NOT_RUN", "reason": "native_stop_not_observed"}
    if p["exit_code"] == 0 and b'"event":"guest_stopped"' in p["stderr"]:
        replay = capture(native_argv, environment, 3, capability=ticket)
        (out / "native-replay.stdout").write_bytes(replay["stdout"])
        (out / "native-replay.stderr").write_bytes(replay["stderr"])
        replay_events = [json.loads(line) for line in replay["stderr"].splitlines()]
        replay_refusal = {"exit_code": replay["exit_code"], "events": replay_events,
            "status": "PASS" if replay["exit_code"] == 77 and replay_events == [{"event": "authority_refused", "detail": "fixture_claim_unavailable_or_replay"}] and
                not replay["stdout"] and not replay["host_timeout"] and not replay["capture_truncated"] else "FAIL"}
    result = {"schema": "conduit-small-linux-boundary/v1", "status": "FAIL",
              "invocation": invocation, "profile": profile, "authority_refusals": refusals,
              "native_authority_refusals": native_refusals, "native_replay_refusal": replay_refusal,
              "native_claim_unchanged": (out / "native-launch.claim").read_bytes() == ticket if (out / "native-launch.claim").is_file() else False,
              "original_project_unchanged": sha(project / "message.txt") == original_message,
              "toolchain_scope": "Linux Bash/grep only; native macOS/Xcode equivalence NOT_ESTABLISHED",
              "independent_qualification": "NOT_RUN", "operator_authority": "unchanged"}
    try:
        result.update(receipt.parse(p["stdout"], p["stderr"]))
        receipt.reconcile(result, nonce)
        rows = result["cases"]
        if [r["case"] for r in rows] == list(receipt.CASES):
            for row in rows:
                for stream in ["stdout", "stderr"]:
                    data = bytes.fromhex(row[stream + "_hex"])
                    (out / (row["case"] + "." + stream)).write_bytes(data)
                    row[stream + "_base64"] = base64.b64encode(data).decode()
                    row[stream + "_sha256"] = hashlib.sha256(data).hexdigest()
    except (ValueError, KeyError, TypeError) as error:
        result.update(status="FAIL", ownership="UNKNOWN", reconciliation_error=str(error))
    (out / "RESULT.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": result["status"], "cases": len(result.get("cases", [])),
                      "failures": result.get("failures"), "ownership": result["ownership"]}, indent=2))
    return 0 if result["status"] == "PASS_WITH_BOUNDS" else 2


if __name__ == "__main__":
    sys.exit(main())
