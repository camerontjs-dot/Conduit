"""Strict development oracle for PID-1 frames and native launcher observations.

No receipt is execution authority. Missing, duplicate, foreign, truncated or
unsuccessful observations fail closed. A missing native stop leaves ownership
UNKNOWN even when the host process has exited.
"""
import json
import re


CASES = (
    "permitted-check", "permitted-scratch", "outside-read", "outside-write",
    "traversal", "symlink-read", "symlink-write", "project-write",
    "undeclared-executable", "project-executable", "scratch-executable",
    "loader-outside", "loader-project", "loader-scratch",
    "project-mmap-executable", "scratch-mmap-executable", "network-denied",
    "detached-orphan", "process-budget", "cpu-budget", "memory-budget",
    "wall-budget", "output-budget", "scratch-budget", "ambient-outside-read",
    "ambient-outside-write", "ambient-executable", "ambient-loader", "ambient-network",
)


def parse(serial, host):
    groups = {"M2_RESULT": [], "M2_META": [], "M2_INSPECT": [], "M2_FATAL": []}
    done = []
    for line in serial.decode("utf-8", errors="strict").replace("\r", "").splitlines():
        prefix, _, payload = line.partition(" ")
        if prefix in groups:
            groups[prefix].append(json.loads(payload))
        elif prefix == "M2_DONE":
            done.append(payload)
    events = [json.loads(line) for line in host.decode("utf-8", errors="strict").splitlines()]
    return {"cases": groups["M2_RESULT"], "metadata": groups["M2_META"],
            "inspection": groups["M2_INSPECT"], "fatal": groups["M2_FATAL"],
            "done_nonces": done, "native_events": events}


def reconcile(result, nonce):
    failures = []

    def require(value, detail):
        if not value:
            failures.append(detail)

    invocation = result["invocation"]
    require(invocation["exit_code"] == 0 and invocation["launches"] == 1, "native_invocation")
    require(not invocation.get("capture_truncated") and not invocation.get("host_timeout"), "host_capture")
    events = [event["event"] for event in result["native_events"]]
    require(events == ["configuration_validated", "guest_started", "guest_stopped"], "native_lifecycle")
    require(result["done_nonces"] == [nonce], "completion_nonce")
    require(not result["fatal"], "guest_setup_or_ownership_failure")
    require(result["original_project_unchanged"], "original_project_changed")
    require(len(result["authority_refusals"]) == 8 and all(
        r["status"] == "PASS" and r["VM_launches"] == 0 for r in result["authority_refusals"]), "authority_refusals")
    require(len(result["native_authority_refusals"]) == 3 and all(
        r["status"] == "PASS" and r["claim_absent"] for r in result["native_authority_refusals"]), "native_authority_refusals")
    require(result["native_replay_refusal"]["status"] == "PASS" and result["native_claim_unchanged"], "native_replay_refusal")
    require(len(result["metadata"]) == 1, "metadata_count")
    if len(result["metadata"]) == 1:
        meta = result["metadata"][0]
        require(meta["nonce"] == nonce and meta["landlock_abi"] >= 3 and
                meta["project_readonly_noexec"] and meta["scratch_bytes"] == 1048576 and
                meta["job_memory_bytes"] == 33554432 and meta["job_pids_max"] == 16 and
                meta["job_cpu_quota"] == "20000 100000", "effective_guest_profile")
    rows = result["cases"]
    require([r["case"] for r in rows] == list(CASES), "missing_duplicate_foreign_or_reordered_case")
    for row in rows:
        name = row["case"]
        if name not in CASES:
            continue
        before = len(failures)
        stdout, stderr = [bytes.fromhex(row[s + "_hex"]) for s in ("stdout", "stderr")]
        require(row["nonce"] == nonce and row["root_observed"] and row["job_pids"] == 0 and
                row["stdout_eof"] and row["stderr_eof"], name + ":ownership_or_nonce")
        require(row["confined"] == (not name.startswith("ambient-")), name + ":confinement_mode")
        for stream, data in (("stdout", stdout), ("stderr", stderr)):
            require(len(data) == min(4096, row[stream + "_bytes"]), name + ":stream_prefix")
            if name != "output-budget":
                require(row[stream + "_bytes"] <= 4096, name + ":unexpected_truncation")
        require(row["deadline"] == (name == "wall-budget"), name + ":deadline")
        require(row["output_limit"] == (name == "output-budget"), name + ":output_limit")
        if name in ("memory-budget", "wall-budget", "output-budget"):
            require(row["signal"] == 9 and row["exit_code"] == -1, name + ":kill_evidence")
            require(not stderr, name + ":stderr")
            if name == "memory-budget":
                require(row["oom_kill_delta"] > 0, name + ":missing_kernel_oom")
            if name == "output-budget":
                require(row["stdout_bytes"] > 65536 and stdout == b"x" * 4096, name + ":output_accounting")
        else:
            require(row["signal"] == 0, name + ":unexpected_signal")
            if name.startswith("loader-"):
                require(row["exit_code"] == 1 and not stdout and
                        (b"Permission denied" in stderr if name == "loader-outside" else b"Not a valid dynamic program" in stderr), name + ":loader_escape")
            else:
                require(not stderr, name + ":stderr")
                expected = {
                    "permitted-check": (0, b"sample check passed\n"), "permitted-scratch": (0, b"ok\n"),
                    "project-write": (13, b"open_errno=30\n"), "network-denied": (20, b"socket_errno=1\n"),
                    "ambient-outside-read": (0, b"ok\n"), "ambient-outside-write": (0, b"ok\n"),
                    "ambient-executable": (64, b""), "ambient-loader": (0, b""), "ambient-network": (0, b"connected\n"),
                }
                if name in ("outside-read", "outside-write", "traversal", "symlink-read", "symlink-write"):
                    expected[name] = (13, b"open_errno=13\n")
                if name in ("undeclared-executable", "project-executable", "scratch-executable"):
                    expected[name] = (126, b"exec_errno=13\n")
                if name in ("project-mmap-executable", "scratch-mmap-executable"):
                    expected[name] = (13, b"mmap_exec_errno=1\n")
                if name in expected:
                    require((row["exit_code"], stdout) == expected[name], name + ":exit_or_stdout")
                elif name == "detached-orphan":
                    require(row["exit_code"] == 0 and row["extra_reaped"] == 1 and row["orphan_exit"] == 13 and
                            re.fullmatch(rb"orphan_ppid=1 setsid=[1-9][0-9]* open_errno=13\n", stdout), name + ":orphan_escape")
                elif name == "process-budget":
                    require(row["exit_code"] == 0 and stdout == b"fork_count=15 fork_errno=11\n" and row["pids_max_delta"] > 0, name + ":kernel_pids_limit")
                elif name == "cpu-budget":
                    require(row["exit_code"] == 0 and re.fullmatch(rb"cpu_ns=[0-9]+\n", stdout) and row["throttled_delta"] > 0, name + ":kernel_cpu_limit")
                elif name == "scratch-budget":
                    match = re.fullmatch(rb"written=([0-9]+) write_errno=28\n", stdout)
                    require(row["exit_code"] == 0 and match and 0 < int(match[1]) <= 1048576, name + ":scratch_limit")
        row["status"] = "PASS" if len(failures) == before else "FAIL"
    require(len(result["inspection"]) == 1, "inspection_count")
    if len(result["inspection"]) == 1:
        require(result["inspection"][0] == {"nonce": nonce, "message_hex": b"after\n".hex(),
                "artifact_hex": b"fixture".hex(), "escaped_file_exists": False}, "inspection_changed_or_escaped")
    result["failures"] = failures
    result["ownership"] = "STOP_OBSERVED" if "guest_stopped" in events else "UNKNOWN"
    result["status"] = "PASS_WITH_BOUNDS" if not failures else "FAIL"
    return not failures
