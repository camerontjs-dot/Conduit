#!/usr/bin/env python3
"""Owned native offline integration; preparation/oracles remain unchanged.

Python prepares and observes this fixture. The executed supervisor root and
VM owner are native binaries. No operator authority or installation is used.
All generated pins, issuer keys and raw evidence belong in private storage.
"""
import argparse
import base64
import json
from pathlib import Path
import secrets
import sys
import time

HERE = Path(__file__).resolve()
import importlib.util
spec = importlib.util.spec_from_file_location("supervised_fixture", HERE.with_name("probe-supervised-small-boundary.py"))
previous = importlib.util.module_from_spec(spec)
spec.loader.exec_module(previous)
d6, oracle, live, stop_ack = previous.d6, previous.oracle, previous.live, previous.stop_ack
save = previous.save

# Core independently compares every decoded field with its own fixed v1.
# An edited description cannot grant authority or change launcher policy.
PROFILE = {
    "profileID": "conduit-portable-offline-check/v1", "checkID": "bash-grep-fixture/v1",
    "argv": ["/bin/bash", "/work/project/scripts/test.sh", "--jobs", "2"],
    "environment": {"PATH": "/usr/bin:/bin", "LANG": "C", "HOME": "/work/scratch", "TMPDIR": "/work/scratch"},
    "hostEnvironment": {"PATH": "/usr/bin:/bin", "LANG": "C"},
    "cpuCount": 1, "memoryBytes": 134217728, "jobMemoryBytes": 33554432,
    "maximumTasks": 16, "cpuQuota": "20000 100000", "projectBytes": 1048576, "scratchBytes": 1048576,
    "jobDeadlineMS": 1500, "hostDeadlineMS": 5000, "maximumStreamBytes": 4096,
    "maximumNativeCaptureBytes": 262144,
    "scriptSHA256": "4dd35505ff40e03a07f3320c95a97c1034558d49122e0b75384d4e8883b728c4",
}


def blob(value):
    return 'Data(base64Encoded: ' + json.dumps(base64.b64encode(value).decode()) + ')!'


def directory_fact(path):
    info = path.lstat()
    return {"path": str(path), "identity": str(info.st_dev) + ":" + str(info.st_ino)}


def asset(path):
    return {"path": str(path), "sha256": d6.sha(path), "byteCount": path.stat().st_size}


def main():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--core-build", type=Path, required=True)
    parser.add_argument("--supervisor-helper", type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--live-timeout", choices=live.MODES)
    modes.add_argument("--check-blocked-guest-slot", action="store_true")
    parser.add_argument("--shared-guest-slot", action="store_true")
    parser.add_argument("--stop-ack-matrix", action="store_true")
    options, remaining = parser.parse_known_args()
    if options.check_blocked_guest_slot and not options.shared_guest_slot:
        parser.error("blocked-slot observation requires the shared fixture slot")
    if options.shared_guest_slot and not (options.live_timeout or options.check_blocked_guest_slot):
        parser.error("shared-slot checks require a live timeout or blocked-slot observation")
    if options.stop_ack_matrix and not (options.shared_guest_slot and options.live_timeout == "cooperative"):
        parser.error("stop-ack matrix requires a shared slot and cooperative timeout")
    core = options.core_build.resolve(strict=True)
    helper = options.supervisor_helper.resolve(strict=True)
    source = HERE.parent / "small-boundary"
    mode = options.live_timeout or "complete"
    sys.argv = [sys.argv[0], *remaining]
    matrix_directory = None

    def launch(argv, environment, timeout, limit, capability=None):
        nonlocal matrix_directory
        directory = argv[0].parent
        if capability != d6.bounded_file(directory / "native-ticket.json", 16384):
            raise RuntimeError("native_handoff_capability_changed")
        objects = sorted((core / "ConduitCore.build").glob("*.o"))
        if not objects:
            raise RuntimeError("owned_core_build_unavailable")
        build_environment = {**environment, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}

        def build(name, arguments):
            result = d6.capture(arguments, build_environment, 75)
            for stream in ("stdout", "stderr"):
                (directory / (name + "." + stream)).write_bytes(result.pop(stream))
            save(directory / (name + ".invocation.json"), result)
            if result["exit_code"] or result["host_timeout"] or result["capture_truncated"]:
                raise RuntimeError(name + "_failed")

        ticket = json.loads(capability)
        issued = time.time()
        binding = {
            "profile": PROFILE, "operationID": ticket.get("fixture_operation_id", "portable-check"),
            "nonce": ticket["nonce"], "fixtureRoot": directory_fact(directory),
            "projectRoot": directory_fact(directory / "staged-project"),
            "manifestSHA256": json.loads((directory / "export.stdout").read_text())["sha256"],
            "nativeTicketSHA256": d6.sha(directory / "native-ticket.json"),
            "nativeExecutable": asset(argv[0]), "kernel": asset(directory / "kernel"),
            "initramfs": asset(directory / "initrd.cpio.gz"), "supervisor": asset(helper),
            "slot": directory_fact(directory.parent / "guest-slot") if options.shared_guest_slot else None,
            "expectedCases": list(oracle.CASES), "mode": mode,
            "issuedAtUnixSeconds": issued, "expiresAtUnixSeconds": issued + 240,
        }
        encoded = json.dumps(binding, sort_keys=True, separators=(",", ":")).encode()
        key = secrets.token_bytes(32)
        worker_pins = directory / "NativeOfflineWorkerPins.swift"
        with worker_pins.open("x") as stream:
            stream.write("import Foundation\nlet portableFixtureBindingData = " + blob(encoded) + "\n")
            stream.write("let portableFixtureAuthorityKey = " + blob(key) + "\n")
        worker = directory / "native-offline-worker"
        support = directory / "native-offline-support.o"
        build("native-support-build", ["/usr/bin/xcrun", "--sdk", "macosx", "clang", "-Wall", "-Wextra", "-Werror",
            "-target", "arm64-apple-macos13.0", "-c", source / "NativeOfflineWorkerSupport.c", "-o", support])
        build("native-bridge-build", ["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library",
            "-target", "arm64-apple-macos13.0", "-I", core / "Modules", "-import-objc-header",
            source / "NativeOfflineWorkerSupport.h", source / "NativeOfflineWorker.swift", worker_pins,
            *objects, support, "-o", worker])

        refusals = []
        for name in ("absent", "forged"):
            if name == "forged":
                save(directory / "native-permit.json", {"payload": base64.b64encode(b"{}").decode(),
                     "mac": base64.b64encode(bytes(32)).decode()})
            observed = d6.capture([worker], environment, 3, limit)
            for stream in ("stdout", "stderr"):
                (directory / ("bridge-refusal-" + name + "." + stream)).write_bytes(observed[stream])
            untouched = not any((directory / item).exists() for item in
                ("native-bridge.claim", "bridge-entries", "native-launch.claim", "supervisor-store",
                 "supervised-serial.stdout", "supervised-host.stderr"))
            passed = observed["exit_code"] == 77 and untouched and not observed["stdout"] and not observed["host_timeout"] and not observed["capture_truncated"]
            refusals.append({"case": name, "refused_before_effects": passed})
            if name == "forged":
                (directory / "native-permit.json").rename(directory / "refused-native-permit.json")
        save(directory / "native-bridge-authority-refusals.json", refusals)
        if not all(row["refused_before_effects"] for row in refusals):
            raise RuntimeError("native_bridge_authority_refusal_failed")

        pins = directory / "SupervisorFixturePins.swift"
        constants = {"fixtureRunPath": str(directory), "fixtureMode": mode,
            "fixtureSupervisorPath": str(helper), "fixtureTicketDigest": d6.sha(directory / "native-ticket.json"),
            "fixtureOperationID": binding["operationID"], "fixtureNativeLauncherPath": str(worker),
            "fixtureNativeLauncherSHA256": d6.sha(worker)}
        executables = [worker, helper, argv[0], HERE, source / "NativeOfflineWorker.swift",
            source / "NativeOfflineWorkerSupport.h", source / "NativeOfflineWorkerSupport.c",
            HERE.with_name("probe-small-linux-boundary.py"), source / "receipt.py", source / "live_timeout.py",
            source / "stop_ack_probe.py", source / "guest_slot_probe.py"]
        with pins.open("x") as stream:
            stream.write("import Foundation\n")
            for name, value in constants.items():
                stream.write("let " + name + " = " + json.dumps(value) + "\n")
            stream.write("let fixtureNativeLauncherBytes: UInt64 = " + str(worker.stat().st_size) + "\n")
            stream.write("let fixturePortableBindingData = " + blob(encoded) + "\n")
            stream.write("let fixturePortableAuthorityKey = " + blob(key) + "\n")
            entries = [json.dumps(str(path)) + ": " + json.dumps(d6.sha(path)) for path in executables]
            stream.write("let fixtureExecutablePins = [" + ", ".join(entries) + "]\n")
            stream.write("let fixtureHostTimeoutMS = 5000\n")
            stream.write("let fixtureSharedGuestSlot = " + ("true" if options.shared_guest_slot else "false") + "\n")
        driver = directory / "supervisor-fixture"
        build("supervisor-build", ["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library",
            "-D", "CONDUIT_NATIVE_OFFLINE_BRIDGE", "-target", "arm64-apple-macos13.0", "-I", core / "Modules",
            source / "SupervisorFixture.swift", pins, *objects, "-o", driver])
        save(directory / "native-integration-build.json", {"binding": binding, "worker": asset(worker),
            "driver": asset(driver), "core_objects": [asset(path) for path in objects],
            "executed_bridge": "native", "python_role": "preparation_and_external_oracle_only"})
        refusals = []
        for name, ticket_bytes, reason in (("absent", None, b"fixture_capability_required"),
                                          ("invalid", b"forged", b"fixture_capability_invalid")):
            observed = d6.capture([driver], environment, 3, limit, capability=ticket_bytes)
            (directory / ("supervisor-refusal-" + name + ".stderr")).write_bytes(observed["stderr"])
            untouched = not any((directory / item).exists() for item in ("native-permit.json", "native-bridge.claim",
                "supervisor-store", "bridge-entries", "native-launch.claim"))
            passed = (observed["exit_code"] == 2 and reason in observed["stderr"] and untouched and
                      not observed["stdout"] and not observed["host_timeout"] and not observed["capture_truncated"])
            refusals.append({"case": name, "refused_before_effects": passed})
        save(directory / "supervisor-authority-refusals.json", refusals)
        if not all(row["refused_before_effects"] for row in refusals):
            raise RuntimeError("supervisor_fixture_refusal_failed")
        if options.stop_ack_matrix:
            stop_ack.before_launch(directory, argv, capability, d6.capture, environment)
            matrix_directory = directory
        invocation = d6.capture([driver], environment, 12, limit, capability=capability)
        for stream in ("stdout", "stderr"):
            (directory / ("supervisor-driver." + stream)).write_bytes(invocation.pop(stream))
        invocation.update(mode=mode, driver_sha256=d6.sha(driver), helper_sha256=d6.sha(helper), bridge_sha256=d6.sha(worker))
        save(directory / "supervisor-driver.invocation.json", invocation)
        if invocation["exit_code"] or invocation["host_timeout"] or invocation["capture_truncated"]:
            raise RuntimeError("native_supervisor_fixture_failed_see_preserved_receipts")
        if options.live_timeout:
            return live.streams(directory)
        observed = json.loads((directory / "supervised-vm-capture.json").read_text())
        observed["stdout"] = (directory / "supervised-serial.stdout").read_bytes()
        observed["stderr"] = (directory / "supervised-host.stderr").read_bytes()
        return observed

    live_mode = options.live_timeout or ("default" if options.check_blocked_guest_slot else None)
    result = d6.main(launch=launch, vm_deadline_seconds=live.VM_WATCHDOG_SECONDS if live_mode else 4,
        live_timeout_mode=live_mode, shared_guest_slot=options.shared_guest_slot,
        observe_blocked_slot=options.check_blocked_guest_slot)
    if options.stop_ack_matrix and result == 0:
        stop_ack.after_launch(matrix_directory)
    return result


if __name__ == "__main__":
    sys.exit(main())
