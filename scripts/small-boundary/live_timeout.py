"""Capture the owned guest while its host bridge is subject to the CDS1 deadline."""
import json
import os
import resource
import subprocess


MODES = ("cooperative", "default")
HOST_TIMEOUT_MS = 5000
VM_WATCHDOG_SECONDS = 5.75
STREAM_LIMIT = 256 * 1024


def run_native(directory, environment, ticket):
    # The ticket pipe is opened first so the native gate receives FD 3.
    read_fd, write_fd = os.pipe()
    if read_fd != 3:
        os.close(read_fd)
        os.close(write_fd)
        raise RuntimeError("native_capability_pipe_unavailable")
    try:
        if os.write(write_fd, ticket) != len(ticket):
            raise RuntimeError("native_capability_pipe_unavailable")
    finally:
        os.close(write_fd)
    resource.setrlimit(resource.RLIMIT_FSIZE, (STREAM_LIMIT, STREAM_LIMIT))
    try:
        with (directory / "supervised-serial.stdout").open("xb") as serial, \
                (directory / "supervised-host.stderr").open("xb") as host:
            native = subprocess.Popen(
                [str(directory / "VMRunner"), str(directory / "kernel"), str(directory / "initrd.cpio.gz"), "--fixture-fd=3"],
                env=environment, stdin=subprocess.DEVNULL, stdout=serial, stderr=host, pass_fds=(read_fd,))
    finally:
        os.close(read_fd)
    save(directory / "live-native-child.json", {"pid": native.pid, "pgid": os.getpgid(native.pid)})
    try:
        # Ordinarily CDS1 signals this bridge and its native child first.
        code = native.wait(timeout=7)
    except subprocess.TimeoutExpired:
        native.terminate()
        try:
            code = native.wait(timeout=1)
        except subprocess.TimeoutExpired:
            native.kill()
            code = native.wait(timeout=1)
    save(directory / "live-native-child-return.json", {"exit_code": code})
    return 125  # A natural bridge exit cannot establish the host timeout.


def save(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def streams(directory):
    values = {}
    for stream, filename in (("stdout", "supervised-serial.stdout"), ("stderr", "supervised-host.stderr")):
        with (directory / filename).open("rb") as file:
            values[stream] = file.read(STREAM_LIMIT + 1)
        if len(values[stream]) >= STREAM_LIMIT:
            raise RuntimeError("live_capture_exceeded_bound")
    return values


def finish(directory, mode, nonce, captured, oracle, authority, native_authority, *, original_project_unchanged):
    host = json.loads((directory / "supervisor-final.json").read_text())
    child = json.loads((directory / "live-native-child.json").read_text())
    result = oracle.parse(captured["stdout"], captured["stderr"])
    failures = oracle.check_guest(result, nonce)

    def require(value, reason):
        if not value:
            failures.append(reason)

    require(original_project_unchanged, "original_project_changed")
    require(result["done_nonces"] == [nonce] and not result["fatal"], "fixed_guest_suite_incomplete")
    require(len(authority) == 8 and all(x["status"] == "PASS" for x in authority), "host_authority")
    require(len(native_authority) == 3 and all(x["status"] == "PASS" for x in native_authority), "native_authority")
    require((directory / "native-launch.claim").read_bytes() == (directory / "native-ticket.json").read_bytes(),
            "native_claim_mismatch")
    require((directory / "bridge-entries").read_bytes() == b"entered\n", "bridge_launch_count")
    require(host["phase"] == "timed_out" and host.get("exitCode") is None and host["terminationSignal"] == 15
            and host["request"]["timeoutMS"] == HOST_TIMEOUT_MS and host["supervision"]["cleanupCause"] == 2
            and host["supervision"]["finalFrameObserved"] and host["directChildExitObserved"]
            and host["processGroupAbsentObserved"], "host_timeout_or_cleanup_unconfirmed")
    witnesses = [json.loads(line.removeprefix("M2_LIVE ")) for line in captured["stdout"].decode().splitlines()
                 if line.startswith("M2_LIVE ")]
    require(witnesses and all(x["nonce"] == nonce and x["job_pids"] == 1 and 0 <= x["job_wall_ms"] < 3000
                              and x["child_pid"] == witnesses[0]["child_pid"] for x in witnesses), "live_job_unobserved")
    events = result["native_events"]
    expected = ["configuration_validated", "guest_started", "supervisor_term_received"]
    if mode == "cooperative":
        expected.append("supervisor_stop_observed")
    require([x["event"] for x in events] == expected, "unexpected_native_lifecycle")
    term = next((x for x in events if x["event"] == "supervisor_term_received"), {})
    stop = next((x for x in events if x["event"] == "supervisor_stop_observed"), {})
    require(term.get("state") == "running" and term.get("nonce") == nonce and term.get("pid") == child["pid"]
            and term.get("pgid") == child["pgid"] == host["processGroupID"], "running_vm_at_term_unconfirmed")
    stop_observed = bool(stop and stop["state"] == "stopped" and stop["pid"] == term.get("pid")
                         and stop["pgid"] == term.get("pgid") and stop["nonce"] == nonce
                         and stop["monotonic_ns"] >= term.get("monotonic_ns", stop["monotonic_ns"] + 1))
    if mode == "cooperative":
        require(stop_observed, "explicit_native_stop_unobserved")
    status = ("FAIL" if failures else "STOP_OBSERVED_WITH_BOUNDS" if stop_observed else
              "HOST_TIMEOUT_GUEST_STOP_UNKNOWN")
    result.update(schema="conduit-live-guest-timeout/v1", status=status, failures=failures, mode=mode,
                  authority_refusals=authority, native_authority_refusals=native_authority,
                  supervisor_phase=host["phase"], host_group_absent=host["processGroupAbsentObserved"],
                  guest_stop="STOP_OBSERVED" if stop_observed else "UNKNOWN",
                  final_guest_job_reaping="UNOBSERVED", replay="NOT_RUN",
                  witnesses=witnesses, native_child=child)
    save(directory / "RESULT.json", result)
    print(json.dumps({"status": status, "guest_conditions": len(result["cases"]), "live_witnesses": len(witnesses),
                      "guest_stop": result["guest_stop"], "failures": failures}, indent=2))
    return 2 if failures else 0
