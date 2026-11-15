#!/usr/bin/env python3
"""Run the actual extracted default signal witness in an owned native child.

No VM or confinement result is represented. Registration readiness and
self-signal-request logging are common instrumentation in every variant.
Every source, binary, bounded stream and actual POSIX wait status is retained.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import signal
import subprocess
import time

HERE = Path(__file__).resolve()
LIMIT = 16 * 1024
DEADLINE = 5.0
ENVIRONMENT = {"PATH": "/usr/bin:/bin", "LANG": "C",
               "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def save(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def method(source, name):
    marker = "    func " + name + "("
    starts = [m.start() for m in re.finditer(re.escape(marker), source)]
    if len(starts) != 1:
        raise ValueError("unique_declared_method_required:" + name)
    start = starts[0]
    end = re.search(r"^    }$", source[start:], re.MULTILINE)
    if end is None:
        raise ValueError("declared_method_end_missing:" + name)
    return source[start:start + end.end()] + "\n"


def render(source, template):
    live = method(source, "liveEvent")
    witness = method(source, "installTimeoutWitness")
    resume = "        source.resume()\n"
    if witness.count(resume) != 1:
        raise ValueError("unique_resume_required")
    instrumented = witness.replace(resume,
        "        source.setRegistrationHandler { witnessReady() }\n" + resume)
    for marker in ["    // INSERT_LIVE_EVENT", "    // INSERT_TIMEOUT_WITNESS"]:
        if template.count(marker) != 1:
            raise ValueError("unique_apparatus_marker_required")
    return template.replace("    // INSERT_LIVE_EVENT", live.rstrip()).replace(
        "    // INSERT_TIMEOUT_WITNESS", instrumented.rstrip())


def run_child(executable, environment, nonce):
    started = time.monotonic()
    facts = {"pid": None, "pgid": None, "parent_term_count": 0, "cleanup_kill_count": 0,
             "raw_wait_status": None, "exit_code": None, "wait_ownership_lost": False,
             "host_timeout": False, "capture_truncated": False,
             "reached_eof": {"stdout": False, "stderr": False}}
    buffers = {name: bytearray() for name in ["stdout", "stderr"]}
    totals = {name: 0 for name in buffers}
    try:
        child = subprocess.Popen([str(executable)], env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError as error:
        facts.update(spawn_error=error.errno, wall_seconds=time.monotonic() - started,
                     observed_bytes=totals)
        return facts, {name: b"" for name in buffers}
    facts["pid"] = child.pid
    try:
        facts["pgid"] = os.getpgid(child.pid)
    except ProcessLookupError:
        pass
    reaped = False
    cleaned_at = None
    pending = bytearray()
    with selectors.DefaultSelector() as selector:
        for name in buffers:
            selector.register(getattr(child, name), selectors.EVENT_READ, name)
        while selector.get_map() or not reaped:
            # This loop is the sole waiter. Never signal after reaping or loss.
            if not reaped and not facts["wait_ownership_lost"]:
                try:
                    pid, status = os.waitpid(child.pid, os.WNOHANG)
                    if pid:
                        reaped = True
                        facts["raw_wait_status"] = status
                        facts["exit_code"] = os.waitstatus_to_exitcode(status)
                        child.returncode = facts["exit_code"]
                except ChildProcessError:
                    facts["wait_ownership_lost"] = True
            now = time.monotonic()
            if now - started > DEADLINE and cleaned_at is None:
                facts["host_timeout"] = True
                cleaned_at = now
                if not reaped and not facts["wait_ownership_lost"]:
                    try:
                        os.kill(child.pid, signal.SIGKILL)
                        facts["cleanup_kill_count"] += 1
                    except ProcessLookupError:
                        pass
            if facts["wait_ownership_lost"] or (cleaned_at and now - cleaned_at > 1):
                break
            for key, _ in selector.select(0.01):
                chunk = os.read(key.fd, 4096)
                name = key.data
                if not chunk:
                    selector.unregister(key.fileobj)
                    facts["reached_eof"][name] = True
                    continue
                totals[name] += len(chunk)
                buffers[name].extend(chunk[:max(0, LIMIT - len(buffers[name]))])
                if totals[name] > LIMIT:
                    facts["capture_truncated"] = True
                if (name == "stderr" and not facts["parent_term_count"] and not reaped
                        and not facts["wait_ownership_lost"] and not facts["capture_truncated"]):
                    pending.extend(chunk)
                    while b"\n" in pending:
                        line, _, pending = pending.partition(b"\n")
                        try:
                            row = json.loads(line)
                        except (ValueError, UnicodeError):
                            continue
                        if (isinstance(row, dict) and row.get("event") == "witness_ready" and row.get("nonce") == nonce
                                and row.get("pid") == child.pid and row.get("pgid") == child.pid
                                and row.get("no_vm") is True):
                            facts["parent_term_count"] = 1
                            try:
                                os.kill(child.pid, signal.SIGTERM)
                            except OSError as error:
                                facts["parent_signal_errno"] = error.errno
                            break
            if reaped and not selector.get_map():
                break
    child.stdout.close()
    child.stderr.close()
    facts.update(observed_bytes=totals, exact_child_reaped=reaped,
                 wall_seconds=time.monotonic() - started)
    return facts, {name: bytes(value) for name, value in buffers.items()}


def assess(facts, streams, nonce):
    problems = []
    try:
        rows = [json.loads(line) for line in streams["stderr"].decode("utf-8").splitlines()]
        if not streams["stderr"].endswith(b"\n") or any(not isinstance(row, dict) for row in rows):
            raise ValueError("incomplete_or_untyped_frames")
    except (ValueError, UnicodeError):
        rows = []
        problems.append("invalid_or_incomplete_frames")
    names = [row.get("event") for row in rows]
    ready = [row for row in rows if row.get("event") == "witness_ready"]
    received = [row for row in rows if row.get("event") == "supervisor_term_received"]
    requested = [row for row in rows if row.get("event") == "self_signal_requested"]
    allowed = {"witness_ready", "supervisor_term_received", "self_signal_requested"}
    if any(name not in allowed for name in names): problems.append("undeclared_or_VM_event")
    if len(ready) != 1 or not names or names[0] != "witness_ready": problems.append("registration_readiness_missing")
    if not received or len(received) != len(requested): problems.append("termination_handoff_incomplete")
    if names != ["witness_ready"] + [name for _ in received for name in
                                            ["supervisor_term_received", "self_signal_requested"]]:
        problems.append("event_order")
    if ready and (ready[0].get("no_vm") is not True or ready[0].get("pgid") != facts.get("pid")):
        problems.append("invalid_no_vm_readiness")
    for row in rows:
        if row.get("nonce") != nonce or row.get("pid") != facts.get("pid"):
            problems.append("identity_mismatch")
    for row in requested:
        if row.get("target_pid") != facts.get("pid") or row.get("signal") != signal.SIGTERM:
            problems.append("wrong_self_signal")
    for row in received:
        if (row.get("state") != "-1" or row.get("pgid") != facts.get("pgid")
                or not isinstance(row.get("monotonic_ns"), int) or row["monotonic_ns"] <= 0):
            problems.append("invalid_isolated_witness_identity")
    if facts.get("pgid") != facts.get("pid") or facts.get("parent_term_count") != 1:
        problems.append("parent_or_group_identity")
    status = facts.get("raw_wait_status")
    raw_signal = isinstance(status, int) and os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGTERM
    if (not raw_signal or facts.get("exit_code") != -signal.SIGTERM or not facts.get("exact_child_reaped")
            or facts.get("wait_ownership_lost") or facts.get("host_timeout")
            or facts.get("cleanup_kill_count") or facts.get("capture_truncated")
            or facts.get("parent_signal_errno")
            or facts.get("reached_eof") != {"stdout": True, "stderr": True}
            or any(facts.get("observed_bytes", {}).get(name) != len(data) for name, data in streams.items())
            or streams["stdout"]):
        problems.append("termination_or_capture_incomplete")
    return {"status": "FAIL" if problems else "REPRODUCED_DUPLICATE_HANDOFF" if len(received) > 1 else "ONE_HANDOFF_SIGNAL15",
            "failures": problems, "term_notifications": len(received), "self_signal_requests": len(requested),
            "events": rows, "VM_starts": 0, "evidence_class": "isolated_native_signal_mechanics"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vm-runner", type=Path, required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    args = parser.parse_args()
    source = args.vm_runner.resolve(strict=True)
    directory = args.evidence_dir.resolve()
    directory.mkdir(mode=0o700)
    template = HERE.parent / "small-boundary/IsolatedTimeoutWitness.swift"
    original = source.read_text()
    rendered = render(original, template.read_text())
    nonce = secrets.token_hex(32)
    wrapper = directory / "Witness.swift"
    wrapper.write_text(rendered)
    pins = directory / "Pins.swift"
    pins.write_text('let fixtureTermMode = "default"\nlet fixtureNonce = ' + json.dumps(nonce) + '\n')
    (directory / "VMRunner.source.swift").write_text(original)
    executable = directory / "witness"
    (directory / "tmp").mkdir(mode=0o700)
    environment = {**ENVIRONMENT, "TMPDIR": str(directory / "tmp")}
    sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], env=environment, text=True).strip()
    argv = ["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-target", "arm64-apple-macos13.0",
            "-sdk", sdk, "-module-cache-path", str(directory.parent / "owned-witness-module-cache"),
            str(wrapper), str(pins), "-o", str(executable)]
    save(directory / "INPUTS.json", {"vm_runner_sha256": digest(source.read_bytes()),
        "wrapper_template_sha256": digest(template.read_bytes()), "runner_sha256": digest(HERE.read_bytes()),
        "rendered_sha256": digest(wrapper.read_bytes()), "pins_sha256": digest(pins.read_bytes()),
        "witness_method_sha256": digest(method(original, "installTimeoutWitness").encode()),
        "argv": argv, "deadline_seconds": DEADLINE, "stream_limit": LIMIT,
        "no_VM": True, "common_instrumentation": ["registration_ready", "self_signal_request_before_Darwin_kill"],
        "unavailable_VM_branch": "fails closed with exit126; never claims a machine state or stop"})
    with (directory / "build.stdout").open("xb") as out, (directory / "build.stderr").open("xb") as err:
        try:
            built = subprocess.run(argv, env=environment, stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=75)
        except subprocess.TimeoutExpired:
            save(directory / "build.json", {"exit_code": None, "status": "BUILD_TIMEOUT", "native_children": 0})
            return 2
    save(directory / "build.json", {"exit_code": built.returncode})
    if built.returncode:
        return 2
    facts, streams = run_child(executable, {"PATH": "/usr/bin:/bin", "LANG": "C", "TMPDIR": str(directory / "tmp")}, nonce)
    for name, value in streams.items(): (directory / (name + ".bin")).write_bytes(value)
    result = {**assess(facts, streams, nonce), "process": facts,
        "source_sha256": digest(source.read_bytes()), "binary_sha256": digest(executable.read_bytes()),
        "stdout_sha256": digest(streams["stdout"]), "stderr_sha256": digest(streams["stderr"])}
    save(directory / "RESULT.json", result)
    print(json.dumps({k: result[k] for k in ["status", "failures", "term_notifications", "self_signal_requests", "VM_starts"]}))
    return 2 if result["status"] == "FAIL" else 0


if __name__ == "__main__":
    raise SystemExit(main())
