#!/usr/bin/env python3
"""Run the fixed D6 fixture through the real development supervisor service.

The native gate and guest suite still supply the isolation evidence. A host
deadline or process-group observation never supplies a missing guest stop.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import time

HERE = Path(__file__).resolve()
spec = importlib.util.spec_from_file_location("d6", HERE.with_name("probe-small-linux-boundary.py"))
d6 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d6)
oracle = d6.module("receipt", HERE.parent / "small-boundary/receipt.py")
live = d6.module("live_timeout", HERE.parent / "small-boundary/live_timeout.py")
ENVIRONMENT = {"PATH": "/usr/bin:/bin", "LANG": "C"}


def save(path, data):
    with path.open("x") as stream:
        json.dump(data, stream, indent=2)
        stream.write("\n")


def bridge(directory, mode):
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise RuntimeError("owned_private_fixture_required")
    ticket = d6.bounded_file(directory / "native-ticket.json", 16384)
    nonce = json.loads(ticket)["nonce"]
    if d6.bounded_file(directory / "launch.claim", 128) != nonce.encode():
        raise RuntimeError("missing_host_fixture_admission")
    fd = os.open(directory / "bridge-entries", os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    try:
        os.write(fd, b"entered\n")
        os.fsync(fd)
    finally:
        os.close(fd)
    if mode in live.MODES:
        return live.run_native(directory, ENVIRONMENT, ticket)
    start = time.monotonic()
    capture = d6.capture([directory / "VMRunner", directory / "kernel", directory / "initrd.cpio.gz", "--fixture-fd=3"],
                         ENVIRONMENT, 4.75, 256 * 1024, capability=ticket)
    capture["native_wall_s"] = time.monotonic() - start
    for source, filename in (("stdout", "supervised-serial.stdout"), ("stderr", "supervised-host.stderr")):
        with (directory / filename).open("xb") as stream:
            stream.write(capture.pop(source))
    save(directory / "supervised-vm-capture.json", capture)
    observed = oracle.parse((directory / "supervised-serial.stdout").read_bytes(),
                            (directory / "supervised-host.stderr").read_bytes())
    events = [row["event"] for row in observed["native_events"]]
    if (capture["exit_code"] != 0 or capture["host_timeout"] or capture["capture_truncated"] or
            events != ["configuration_validated", "guest_started", "guest_stopped"] or
            observed["done_nonces"] != [nonce] or observed["fatal"]):
        raise RuntimeError("complete_guest_stop_and_result_required")
    rows = [row for row in observed["cases"] if row["case"] == "permitted-check"]
    if len(rows) != 1:
        raise RuntimeError("unique_fixed_check_required")
    check = rows[0]
    if (check["nonce"] != nonce or not check["confined"] or not check["root_observed"] or
            check["job_pids"] != 0 or check["signal"] or check["deadline"] or check["output_limit"] or
            not 0 <= check["exit_code"] <= 125):
        raise RuntimeError("guest_command_exit_or_cleanup_unobserved")
    streams = {}
    for stream in ("stdout", "stderr"):
        value = bytes.fromhex(check[stream + "_hex"])
        if not check[stream + "_eof"] or len(value) != check[stream + "_bytes"] or len(value) > 4096:
            raise RuntimeError("guest_command_stream_incomplete")
        streams[stream] = value
    save(directory / "supervised-command.json",
         {"exit_code": check["exit_code"], "guest_stop": "OBSERVED", "mode": mode,
          "stdout_bytes": len(streams["stdout"]), "stderr_bytes": len(streams["stderr"])})
    for stream, value in streams.items():
        handle = getattr(sys, stream).buffer
        handle.write(value)
        handle.flush()
    if mode == "timeout-after-stop":
        save(directory / "timeout-control.json", {"guest_stop_observed_before_hold": True, "hold_seconds": 6})
        time.sleep(6)
        return 125  # Reached only if the supervisor missed its declared deadline.
    return check["exit_code"]


def main():
    if sys.argv[1:2] == ["--owned-bridge"]:
        if len(sys.argv) != 4 or sys.argv[3] not in ("complete", "timeout-after-stop", *live.MODES):
            raise RuntimeError("fixed_owned_bridge_arguments_required")
        return bridge(Path(sys.argv[2]), sys.argv[3])

    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--core-build", type=Path, required=True,
                        help="Owned SwiftPM debug build directory for this exact ConduitCore source")
    parser.add_argument("--supervisor-helper", type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--timeout-after-stop", action="store_true")
    modes.add_argument("--live-timeout", choices=live.MODES)
    modes.add_argument("--check-blocked-guest-slot", action="store_true")
    parser.add_argument("--shared-guest-slot", action="store_true",
                        help="Use the pre-created private guest-slot directory in the evidence parent")
    options, remaining = parser.parse_known_args()
    if options.check_blocked_guest_slot and not options.shared_guest_slot:
        parser.error("blocked-slot observation requires the shared fixture slot")
    if options.shared_guest_slot and not (options.live_timeout or options.check_blocked_guest_slot):
        parser.error("shared-slot checks require a live timeout mode or blocked-slot observation")
    core = options.core_build.resolve(strict=True)
    helper = options.supervisor_helper.resolve(strict=True)
    mode = options.live_timeout or ("timeout-after-stop" if options.timeout_after_stop else "complete")
    sys.argv = [sys.argv[0], *remaining]

    def launch(argv, environment, timeout, limit, capability=None):
        directory = argv[0].parent
        if capability != d6.bounded_file(directory / "native-ticket.json", 16384):
            raise RuntimeError("supervisor_handoff_capability_changed")
        python = Path(sys.executable).resolve()
        pins = directory / "SupervisorFixturePins.swift"
        constants = {"fixtureRunPath": str(directory), "fixtureMode": mode, "fixturePythonPath": str(python),
                     "fixtureBridgePath": str(HERE), "fixtureSupervisorPath": str(helper),
                     "fixtureTicketDigest": hashlib.sha256(capability).hexdigest(),
                     "fixtureOperationID": json.loads(capability).get("fixture_operation_id", "portable-check")}
        executables = [python, HERE, helper, argv[0], HERE.with_name("probe-small-linux-boundary.py"),
                       HERE.parent / "small-boundary/receipt.py", HERE.parent / "small-boundary/live_timeout.py"]
        with pins.open("x") as stream:
            for name, value in constants.items():
                stream.write("let " + name + " = " + json.dumps(value) + "\n")
            entries = [json.dumps(str(path)) + ": " + json.dumps(d6.sha(path)) for path in executables]
            stream.write("let fixtureExecutablePins = [" + ", ".join(entries) + "]\n")
            stream.write("let fixtureHostTimeoutMS = " + str(live.HOST_TIMEOUT_MS if options.live_timeout else 5000) + "\n")
            stream.write("let fixtureSharedGuestSlot = " + ("true" if options.shared_guest_slot else "false") + "\n")
        driver = directory / "supervisor-fixture"
        objects = sorted((core / "ConduitCore.build").glob("*.o"))
        if not objects:
            raise RuntimeError("owned_core_build_unavailable")
        build_environment = {**environment, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
        build = d6.capture(["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library",
                            "-target", "arm64-apple-macos13.0", "-I", core / "Modules",
                            HERE.parent / "small-boundary/SupervisorFixture.swift", pins, *objects, "-o", driver],
                           build_environment, 75)
        for stream in ("stdout", "stderr"):
            (directory / ("supervisor-build." + stream)).write_bytes(build.pop(stream))
        save(directory / "supervisor-build.invocation.json", build)
        if build["exit_code"] or build["host_timeout"] or build["capture_truncated"]:
            raise RuntimeError("pinned_supervisor_driver_build_failed")
        refusals = []
        for name, ticket, reason in (("absent", None, b"fixture_capability_required"),
                                      ("invalid", b"forged", b"fixture_capability_invalid")):
            refusal = d6.capture([driver], environment, 3, limit, capability=ticket)
            (directory / ("supervisor-refusal-" + name + ".stderr")).write_bytes(refusal["stderr"])
            untouched = not any((directory / item).exists() for item in ("supervisor-store", "bridge-entries", "native-launch.claim"))
            passed = (refusal["exit_code"] == 2 and reason in refusal["stderr"] and untouched and
                      not refusal["stdout"] and not refusal["host_timeout"] and not refusal["capture_truncated"])
            refusals.append({"case": name, "refused_before_effects": passed})
        save(directory / "supervisor-authority-refusals.json", refusals)
        if not all(case["refused_before_effects"] for case in refusals):
            raise RuntimeError("supervisor_fixture_refusal_failed")
        invocation = d6.capture([driver], environment, 12, limit, capability=capability)
        for stream in ("stdout", "stderr"):
            (directory / ("supervisor-driver." + stream)).write_bytes(invocation.pop(stream))
        command_result = directory / "supervised-command.json"
        invocation.update(mode=mode, guest_stop="OBSERVED" if command_result.is_file() else "UNKNOWN",
                          driver_sha256=d6.sha(driver), helper_sha256=d6.sha(helper), bridge_sha256=d6.sha(HERE))
        save(directory / "supervisor-driver.invocation.json", invocation)
        if invocation["exit_code"] != 0 or invocation["host_timeout"] or invocation["capture_truncated"]:
            raise RuntimeError("supervisor_fixture_failed_see_preserved_receipts")
        if options.live_timeout:
            return live.streams(directory)
        observed = json.loads((directory / "supervised-vm-capture.json").read_text())
        observed["stdout"] = (directory / "supervised-serial.stdout").read_bytes()
        observed["stderr"] = (directory / "supervised-host.stderr").read_bytes()
        return observed

    live_mode = options.live_timeout or ("default" if options.check_blocked_guest_slot else None)
    return d6.main(launch=launch, vm_deadline_seconds=live.VM_WATCHDOG_SECONDS if live_mode else 4,
                   live_timeout_mode=live_mode, shared_guest_slot=options.shared_guest_slot,
                   observe_blocked_slot=options.check_blocked_guest_slot)


if __name__ == "__main__":
    sys.exit(main())
