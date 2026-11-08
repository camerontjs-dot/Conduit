#!/usr/bin/env python3
"""Bounded black-box probes for the internal CDS1 supervisor protocol."""

from __future__ import annotations

import argparse
import errno
import fcntl
import json
import os
import select
import signal
import sys
import time
from pathlib import Path
from typing import Any


CASE_TIMEOUT_SECONDS = 15.0
NONCE = "0123456789abcdef0123456789abcdef"


class ProbeFailure(RuntimeError):
    pass


class Case:
    def __init__(self, name: str, directory: Path, helper: Path, fixture: Path):
        self.name = name
        self.directory = directory
        self.directory.mkdir(mode=0o700)
        self.helper = helper
        self.fixture = fixture
        self.started = time.monotonic()
        self.deadline = self.started + CASE_TIMEOUT_SECONDS
        self.events: list[dict[str, Any]] = []
        self.frames: list[str] = []
        self.control_bytes = bytearray()
        self.status_bytes = bytearray()
        self.status_buffer = bytearray()
        self.spawned_pid: int | None = None
        self.root_pid: int | None = None
        self.control_fd: int | None = None
        self.status_fd: int | None = None
        self.stdout_fd: int | None = None
        self.stderr_fd: int | None = None
        self.status_file = (directory / "status.bin").open("xb")
        self.stdout_file = (directory / "stdout.bin").open("xb")
        self.stderr_file = (directory / "stderr.bin").open("xb")
        self.events_file = directory / "events.json"
        self.error: str | None = None
        self.details: dict[str, Any] = {}

    def event(self, stage: str, **values: Any) -> None:
        self.events.append({"stage": stage, "elapsed_seconds": round(time.monotonic() - self.started, 6), **values})

    def remaining(self) -> float:
        left = self.deadline - time.monotonic()
        if left <= 0:
            raise ProbeFailure(f"case exceeded {CASE_TIMEOUT_SECONDS:g}s bound")
        return left

    def start(self, payload_args: list[str], *, cwd: Path | None = None,
              store: Path | None = None, environment: dict[str, str] | None = None) -> None:
        # Optional owned paths let development profiles reuse the CDS1 driver.
        # They grant no authority; the caller must admit its fixture first.
        if store is None:
            store = self.directory / "store"
            store.mkdir(mode=0o700)
        if cwd is None:
            cwd = self.directory / "cwd"
            cwd.mkdir(mode=0o700)
        (self.directory / "claim.expected").write_text(f"{NONCE}\n", encoding="ascii")

        control_read, control_write = os.pipe()
        status_read, status_write = os.pipe()
        stdout_read, stdout_write = os.pipe()
        stderr_read, stderr_write = os.pipe()
        devnull = os.open("/dev/null", os.O_RDONLY)
        store_fd = os.open(store, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        cwd_fd = os.open(cwd, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        child_sources = [devnull, stdout_write, stderr_write, control_read, status_write, store_fd, cwd_fd]
        high_sources: list[int] = []
        try:
            for fd in child_sources:
                high_sources.append(fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 20))
            file_actions: list[tuple[int, ...]] = []
            for source, target in zip(high_sources, range(7)):
                file_actions.append((os.POSIX_SPAWN_DUP2, source, target))
            for fd in high_sources:
                file_actions.append((os.POSIX_SPAWN_CLOSE, fd))
            argv = [
                str(self.helper), "--supervise", NONCE, self.name.replace("-", "_"), "4000", "--",
                str(self.fixture), *payload_args,
            ]
            self.event("spawn_helper", helper=str(self.helper), argv=argv)
            self.spawned_pid = os.posix_spawn(str(self.helper), argv,
                                             os.environ.copy() if environment is None else environment,
                                             file_actions=file_actions)
        finally:
            for fd in high_sources:
                os.close(fd)
            for fd in child_sources:
                os.close(fd)
        self.control_fd = control_write
        self.status_fd = status_read
        self.stdout_fd = stdout_read
        self.stderr_fd = stderr_read
        for fd in (control_write, status_read, stdout_read, stderr_read):
            os.set_blocking(fd, False)
        self.event("helper_spawned", pid=self.spawned_pid)

    def send_control(self, data: bytes, stage: str) -> None:
        if self.control_fd is None:
            raise ProbeFailure("control writer is closed")
        view = memoryview(data)
        while view:
            try:
                count = os.write(self.control_fd, view)
            except InterruptedError:
                continue
            except BlockingIOError:
                select.select([], [self.control_fd], [], min(0.05, self.remaining()))
                continue
            if count <= 0:
                raise ProbeFailure("control pipe closed during write")
            view = view[count:]
        self.control_bytes.extend(data)
        self.event(stage, bytes=len(data), data=data.decode("ascii", "backslashreplace"))

    def close_control(self, stage: str) -> None:
        if self.control_fd is not None:
            os.close(self.control_fd)
            self.control_fd = None
            self.event(stage)

    def close_status(self, stage: str) -> None:
        if self.status_fd is not None:
            os.close(self.status_fd)
            self.status_fd = None
            self.event(stage)

    def _consume_status(self, data: bytes) -> None:
        self.status_bytes.extend(data)
        self.status_file.write(data)
        self.status_file.flush()
        self.status_buffer.extend(data)
        while b"\n" in self.status_buffer:
            line, _, rest = self.status_buffer.partition(b"\n")
            self.status_buffer[:] = rest
            rendered = (line + b"\n").decode("ascii", "backslashreplace")
            self.frames.append(rendered)
            fields = rendered.rstrip("\n").split()
            self.event("status_frame", raw=rendered)
            if len(fields) >= 6 and fields[0] == "CDS1" and fields[1] == NONCE and fields[3] == "READY":
                try:
                    self.root_pid = int(fields[4])
                except ValueError:
                    pass

    def wait_frame(self, kind: str) -> str:
        for frame in self.frames:
            fields = frame.rstrip("\n").split()
            if len(fields) >= 4 and fields[0] == "CDS1" and fields[3] == kind:
                return frame
        if self.status_fd is None:
            raise ProbeFailure(f"status reader closed before {kind}")
        while True:
            left = self.remaining()
            readable, _, _ = select.select([self.status_fd], [], [], min(left, 0.1))
            if not readable:
                self.check_child_alive()
                continue
            try:
                data = os.read(self.status_fd, 4096)
            except InterruptedError:
                continue
            except BlockingIOError:
                continue
            if not data:
                raise ProbeFailure(f"status EOF before {kind}")
            self._consume_status(data)
            for frame in self.frames:
                fields = frame.rstrip("\n").split()
                if len(fields) >= 4 and fields[0] == "CDS1" and fields[3] == kind:
                    return frame

    def check_child_alive(self) -> None:
        if self.spawned_pid is None:
            return
        result, status = os.waitpid(self.spawned_pid, os.WNOHANG)
        if result == self.spawned_pid:
            self.spawned_pid = None
            raise ProbeFailure(f"supervisor exited before expected protocol event (wait status {status})")

    def ready(self) -> tuple[int, int, int]:
        frame = self.wait_frame("READY")
        fields = frame.rstrip("\n").split()
        if len(fields) != 7:
            raise ProbeFailure(f"malformed READY frame: {frame!r}")
        pid, pgid, sid = map(int, fields[4:7])
        self.root_pid = pid
        self.event("ready_validated", pid=pid, pgid=pgid, sid=sid)
        return pid, pgid, sid

    def finish_supervisor(self) -> int:
        if self.spawned_pid is None:
            return 0
        pid = self.spawned_pid
        while True:
            left = self.remaining()
            result, status = os.waitpid(pid, os.WNOHANG)
            if result == pid:
                self.spawned_pid = None
                self.event("supervisor_reaped", pid=pid, wait_status=status)
                return status
            time.sleep(min(0.01, left))

    def emergency_reap_supervisor_only(self) -> None:
        if self.spawned_pid is None:
            return
        pid = self.spawned_pid
        self.event("timeout_cleanup_exact_supervisor", pid=pid)
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            _, status = os.waitpid(pid, 0)
            self.event("supervisor_reaped_after_timeout", pid=pid, wait_status=status)
        except ChildProcessError:
            pass
        self.spawned_pid = None

    def _drain_one(self, fd_name: str, output_file: Any) -> None:
        fd = getattr(self, fd_name)
        if fd is None:
            return
        while True:
            try:
                chunk = os.read(fd, 65536)
            except InterruptedError:
                continue
            except BlockingIOError:
                break
            if not chunk:
                os.close(fd)
                setattr(self, fd_name, None)
                break
            output_file.write(chunk)
        output_file.flush()

    def finish_outputs(self) -> None:
        # Output is intentionally not drained while the payload runs. Once S exits, its owned R
        # has either exited or been terminated; drain only the app-facing pipe readers here.
        self._drain_one("stdout_fd", self.stdout_file)
        self._drain_one("stderr_fd", self.stderr_file)

    def close_files(self) -> None:
        self.status_file.flush()
        self.status_file.close()
        self.stdout_file.flush()
        self.stdout_file.close()
        self.stderr_file.flush()
        self.stderr_file.close()
        (self.directory / "control.bin").write_bytes(bytes(self.control_bytes))
        self.events_file.write_text(json.dumps(self.events, indent=2) + "\n", encoding="utf-8")

    def result(self, passed: bool) -> dict[str, Any]:
        self.details.update({
            "name": self.name,
            "passed": passed,
            "elapsed_seconds": round(time.monotonic() - self.started, 6),
            "rawframes": self.frames,
            "events": self.events,
            "error": self.error,
            "evidence_directory": str(self.directory),
        })
        return self.details


def frame_fields(frame: str, kind: str) -> list[str]:
    fields = frame.rstrip("\n").split()
    if len(fields) < 4 or fields[0] != "CDS1" or fields[1] != NONCE or fields[3] != kind:
        raise ProbeFailure(f"invalid {kind} frame: {frame!r}")
    return fields


def send_go(case: Case) -> None:
    case.send_control(f"CDS1 {NONCE} 1 GO\n".encode("ascii"), "send_go")


def run_case(name: str, output: Path, helper: Path, fixture: Path) -> dict[str, Any]:
    case_dir = output / name
    case = Case(name, case_dir, helper, fixture)
    passed = False
    try:
        if name == "waiter-echild-for-root":
            case.start(["--effect", str(case_dir / "effect.marker"), "100"])
            root_pid, _, _ = case.ready()
            try:
                os.waitpid(root_pid, os.WNOHANG)
                raise ProbeFailure("controller unexpectedly reaped supervisor's root child")
            except ChildProcessError:
                case.event("root_wait_refused", pid=root_pid, errno=errno.ECHILD)
            send_go(case)
            frame_fields(case.wait_frame("GO"), "GO")
            frame_fields(case.wait_frame("FINAL"), "FINAL")
            case.finish_supervisor()
            marker = case_dir / "effect.marker"
            if not marker.exists() or marker.read_bytes() != b"effect\n":
                raise ProbeFailure("payload effect marker missing or not exactly one effect")
            case.details["root_pid"] = root_pid
            case.details["effect_bytes"] = marker.read_text(encoding="ascii")

        elif name == "outside-session-owned-peer-refused":
            case.start(["--effect", str(case_dir / "effect.marker"), "100"])
            root_pid, root_pgid, root_sid = case.ready()
            peer_pid, peer_output = spawn_peer(case, case_dir, root_pgid)
            case.details["peer_pid"] = peer_pid
            case.details["root_pid"] = root_pid
            case.details["root_pgid"] = root_pgid
            case.details["root_sid"] = root_sid
            peer_fields = peer_output.split()
            if int(peer_fields[5]) != -1 or int(peer_fields[6]) != errno.EPERM:
                raise ProbeFailure(f"peer's own setpgid must fail EPERM: {peer_output}")
            if int(peer_fields[3]) == root_sid:
                raise ProbeFailure("peer was not outside the private session")
            case.event("outside_session_join_refused", peer_pid=peer_pid, target_pgid=root_pgid, errno=int(peer_fields[6]))
            send_go(case)
            frame_fields(case.wait_frame("FINAL"), "FINAL")
            case.finish_supervisor()
            if not (case_dir / "effect.marker").exists():
                raise ProbeFailure("expected payload did not run after isolated peer check")
            peer_status = wait_exact(peer_pid, time.monotonic() + 5.0)
            case.event("peer_self_expired_and_reaped", pid=peer_pid, wait_status=peer_status)
            case.details["peer_output"] = peer_output

        elif name == "disconnect-before-go-no-effect":
            case.start(["--effect", str(case_dir / "effect.marker"), "100"])
            case.ready()
            case.close_control("disconnect_before_go")
            frame_fields(case.wait_frame("FINAL"), "FINAL")
            case.finish_supervisor()
            if (case_dir / "effect.marker").exists():
                raise ProbeFailure("payload effect occurred after disconnect before GO")

        elif name == "disconnect-after-go-status-reader-closed":
            case.start(["--effect", str(case_dir / "effect.marker"), "3000"])
            case.ready()
            send_go(case)
            frame_fields(case.wait_frame("GO"), "GO")
            case.close_status("close_status_reader_after_go")
            case.close_control("disconnect_control_after_go")
            wait_status = case.finish_supervisor()
            if os.WIFSIGNALED(wait_status):
                raise ProbeFailure(f"supervisor died by signal {os.WTERMSIG(wait_status)}")
            try:
                os.kill(case.root_pid, 0)  # Read-only observation of this fixture's root.
            except ProcessLookupError:
                case.event("owned_root_absent_after_disconnect")
            else:
                raise ProbeFailure("root survived supervisor disconnect cleanup")
            marker = case_dir / "effect.marker"
            case.details["effect_observed"] = marker.exists()
            case.event("supervisor_exit_after_status_loss")

        elif name == "malformed-nonce":
            case.start(["--effect", str(case_dir / "effect.marker"), "100"])
            case.ready()
            bad = "f" * 32
            case.send_control(f"CDS1 {bad} 1 GO\n".encode("ascii"), "send_malformed_nonce")
            error_frame = case.wait_frame("ERROR")
            error_fields = frame_fields(error_frame, "ERROR")
            frame_fields(case.wait_frame("FINAL"), "FINAL")
            case.finish_supervisor()
            if int(error_fields[4]) == 0:
                raise ProbeFailure("protocol ERROR omitted a positive errno")
            if (case_dir / "effect.marker").exists():
                raise ProbeFailure("payload effect occurred on malformed nonce")

        elif name == "oversize-control-line":
            case.start(["--effect", str(case_dir / "effect.marker"), "100"])
            case.ready()
            case.send_control(b"x" * 256 + b"\n", "send_oversize_control")
            frame_fields(case.wait_frame("ERROR"), "ERROR")
            frame_fields(case.wait_frame("FINAL"), "FINAL")
            case.finish_supervisor()
            if (case_dir / "effect.marker").exists():
                raise ProbeFailure("payload effect occurred on oversized control frame")

        elif name == "output-backpressure-cancel-responsive":
            case.start(["--flood"])
            case.ready()
            send_go(case)
            go_fields = frame_fields(case.wait_frame("GO"), "GO")
            if len(go_fields) != 5 or go_fields[4] != "1":
                raise ProbeFailure(f"GO did not report committed disposition: {go_fields!r}")
            time.sleep(0.1)  # Keep both payload output pipes unread while the bounded fixture writes.
            case.send_control(f"CDS1 {NONCE} 2 CANCEL\n".encode("ascii"), "send_cancel_under_output_backpressure")
            cancel_fields = frame_fields(case.wait_frame("CANCEL"), "CANCEL")
            if len(cancel_fields) != 5 or cancel_fields[4] != "1":
                raise ProbeFailure(f"CANCEL was not accepted under payload backpressure: {cancel_fields!r}")
            frame_fields(case.wait_frame("FINAL"), "FINAL")
            case.finish_supervisor()

        elif name == "duplicate-go-one-effect":
            case.start(["--effect", str(case_dir / "effect.marker"), "250"])
            case.ready()
            go = f"CDS1 {NONCE} 1 GO\n".encode("ascii")
            case.send_control(go + go, "send_duplicate_go")
            frame_fields(case.wait_frame("FINAL"), "FINAL")
            case.finish_supervisor()
            marker = case_dir / "effect.marker"
            actual = marker.read_bytes() if marker.exists() else b""
            if actual != b"effect\n":
                raise ProbeFailure(f"duplicate GO effect count was not one; marker={actual!r}")
            go_replies = [frame for frame in case.frames if len(frame.rstrip("\n").split()) >= 5 and frame.rstrip("\n").split()[3] == "GO"]
            if len(go_replies) != 2 or any(frame_fields(frame, "GO")[4] != "1" for frame in go_replies):
                raise ProbeFailure(f"expected two committed GO dispositions, got {go_replies!r}")
            case.details["effect_marker_bytes"] = actual.decode("ascii")

        else:
            raise ProbeFailure(f"unknown case {name}")
        passed = True
        case.event("case_passed")
    except BaseException as exc:  # Preserve evidence and terminate only the exact direct S child on timeout.
        case.error = f"{type(exc).__name__}: {exc}"
        case.event("case_failed", error=case.error)
        case.emergency_reap_supervisor_only()
    finally:
        try:
            case.finish_outputs()
        except OSError as exc:
            case.event("output_drain_error", errno=exc.errno, error=str(exc))
        for field in ("control_fd", "status_fd", "stdout_fd", "stderr_fd"):
            fd = getattr(case, field)
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
                setattr(case, field, None)
        case.close_files()
    return case.result(passed)


def wait_exact(pid: int, deadline: float) -> int:
    while time.monotonic() < deadline:
        result, status = os.waitpid(pid, os.WNOHANG)
        if result == pid:
            return status
        time.sleep(0.01)
    raise ProbeFailure(f"owned peer {pid} did not self-expire within its bound")


def spawn_peer(case: Case, directory: Path, target_pgid: int) -> tuple[int, str]:
    read_fd, write_fd = os.pipe()
    devnull = os.open("/dev/null", os.O_RDONLY)
    sources = [fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 20) for fd in (write_fd, devnull)]
    actions = [
        (os.POSIX_SPAWN_DUP2, sources[1], 0),
        (os.POSIX_SPAWN_DUP2, sources[0], 1),
        (os.POSIX_SPAWN_DUP2, sources[1], 2),
        (os.POSIX_SPAWN_CLOSE, read_fd),
        (os.POSIX_SPAWN_CLOSE, write_fd),
        (os.POSIX_SPAWN_CLOSE, devnull),
        (os.POSIX_SPAWN_CLOSE, sources[0]),
        (os.POSIX_SPAWN_CLOSE, sources[1]),
    ]
    try:
        pid = os.posix_spawn(str(case.fixture), [str(case.fixture), "--peer", str(target_pgid)], os.environ.copy(), file_actions=actions)
    finally:
        for fd in (write_fd, devnull, *sources):
            os.close(fd)
    os.set_blocking(read_fd, False)
    case.event("spawn_owned_peer_same_app_session", pid=pid)
    data = bytearray()
    deadline = min(case.deadline, time.monotonic() + 2.0)
    while b"\n" not in data:
        left = deadline - time.monotonic()
        if left <= 0:
            os.close(read_fd)
            raise ProbeFailure("owned peer did not report session identity")
        readable, _, _ = select.select([read_fd], [], [], left)
        if not readable:
            continue
        chunk = os.read(read_fd, 256)
        if not chunk:
            os.close(read_fd)
            raise ProbeFailure("owned peer output closed before identity report")
        data.extend(chunk)
    os.close(read_fd)
    line = bytes(data).split(b"\n", 1)[0].decode("ascii", "strict")
    fields = line.split()
    if len(fields) != 7 or fields[0] != "PEER" or fields[4] != "JOIN":
        raise ProbeFailure(f"malformed peer identity: {line!r}")
    reported_pid, pgid, sid = map(int, fields[1:4])
    if reported_pid != pid:
        raise ProbeFailure("owned peer reported a different PID")
    if pid <= 0 or pgid != pid or sid == 0:
        raise ProbeFailure(f"unexpected peer identity values: {fields!r}")
    return pid, line


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", required=True, type=Path, help="absolute path to the compiled supervisor")
    parser.add_argument("--fixture", required=True, type=Path, help="absolute path to the compiled fixture executable")
    parser.add_argument("--output", required=True, type=Path, help="new evidence directory; existing paths are refused")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("the CDS1 development controller is macOS-only")
    for name, path in (("helper", args.helper), ("fixture", args.fixture)):
        if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
            parser.error(f"--{name} must name an existing absolute executable file")
    if not args.output.is_absolute():
        parser.error("--output must be an absolute path")
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = {
        "protocol": "CDS1",
        "scope": "local synthetic protocol probes only",
        "helper": str(args.helper),
        "fixture": str(args.fixture),
        "started_utc_epoch": time.time(),
        "case_timeout_seconds": CASE_TIMEOUT_SECONDS,
        "cases": [],
    }
    case_names = [
        "waiter-echild-for-root",
        "outside-session-owned-peer-refused",
        "disconnect-before-go-no-effect",
        "disconnect-after-go-status-reader-closed",
        "malformed-nonce",
        "oversize-control-line",
        "output-backpressure-cancel-responsive",
        "duplicate-go-one-effect",
    ]
    for name in case_names:
        manifest["cases"].append(run_case(name, args.output, args.helper, args.fixture))
        if not manifest["cases"][-1]["passed"]:
            # Preserve the first adverse result. All fixture roles self-expire;
            # do not overlap another case with potentially surviving work.
            time.sleep(4.1)
            manifest["not_run"] = case_names[len(manifest["cases"]):]
            break
    manifest["finished_utc_epoch"] = time.time()
    manifest["passed"] = all(case["passed"] for case in manifest["cases"])
    result_path = args.output / "result.json"
    result_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"result": str(result_path), "passed": manifest["passed"], "cases": [
        {"name": case["name"], "passed": case["passed"], "elapsed_seconds": case["elapsed_seconds"], "error": case["error"]}
        for case in manifest["cases"]
    ]}, indent=2))
    return 0 if manifest["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
