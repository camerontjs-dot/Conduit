#!/usr/bin/env python3
"""Fixture-only offline command boundary, with real macOS denial controls.

Creates its own project, scratch, grants and endpoints in a NEW directory.
No arbitrary project/command/grant option and no app/API integration exists.
Reuses the CDS1 driver and the earlier native policy probe. sandbox-exec is
deprecated: these receipts are development evidence, never production support
or independent qualification. All original attempts stay in their directories.
"""
from __future__ import annotations

import argparse
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import secrets
import shlex
import socket
import subprocess
import sys
import time


def load(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


driver = load("cds1_driver", "test-supervisor-protocol.py")
policy_probe = load("native_policy_probe", "probe-direct-execution-policy.py")
ENVIRONMENT = {"PATH": "/usr/bin:/bin", "LANG": "C"}
BUDGETS = {"wall_ms": 4000, "cpu_seconds_per_process": 2,
           "bytes_per_file": 1048576, "descriptors_per_process": 64,
           "retained_bytes_per_stream": 4096, "concurrent_operations": 1}
PROFILE = '''(version 1)
(deny default)
(allow process-fork)
(allow process-exec (literal (param "PROBE")) (literal "/bin/bash") (literal "/bin/echo"))
(allow sysctl-read)
(allow file-read-metadata)
(allow file-read-data
  (literal "/") (subpath "/System") (subpath "/usr/lib")
  (literal (param "PROBE")) (literal "/bin/bash") (literal "/bin/echo")
  (subpath (param "PROJECT")) (subpath (param "SCRATCH")))
(allow file-write* (subpath (param "SCRATCH")))
'''


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def identity(path: Path) -> list[int]:
    facts = path.stat()
    return [facts.st_dev, facts.st_ino]


def snapshot(roots: list[Path]) -> dict:
    result = {}
    for root in roots:
        for path in sorted(root.rglob("*")):
            key = str(path)
            if path.is_symlink():
                result[key] = {"symlink": os.readlink(path)}
            elif path.is_file():
                result[key] = {"sha256": sha(path), "mode": path.stat().st_mode}
    return result


class Refusal(RuntimeError):
    pass


class FixtureAuthority:
    """In-memory owner authority; caller JSON cannot mint a trusted grant.

    Same-user hostile interference and atomic executable replacement are outside
    this trusted-fixture probe. The production service never constructs this.
    """
    def __init__(self, out: Path, helper: Path, probe: Path, launcher: Path, policy: Path):
        self.out, self.helper, self.probe, self.launcher, self.policy = out, helper, probe, launcher, policy
        self.project, self.scratch, self.ledger = [out / p for p in ("project", "scratch", "ledger")]
        self.issued: dict[str, dict] = {}

    def facts(self, operation: str, script: Path) -> dict:
        return {
            "schema": "conduit-owned-development-grant/v1", "operation_id": operation,
            "profile": "offline-posix-development-v1", "policy_sha256": sha(self.policy),
            "project": str(self.project), "project_identity": identity(self.project),
            "project_inputs": snapshot([self.project]),
            "scratch": str(self.scratch), "scratch_identity": identity(self.scratch),
            "ledger_identity": identity(self.ledger), "script": str(script), "script_sha256": sha(script),
            "argv": ["/bin/bash", "--noprofile", "--norc", "--posix", str(script)], "environment": ENVIRONMENT,
            "budgets": BUDGETS, "network": "deny_all",
            "executables": {str(p): sha(p) for p in
                            [self.helper, self.launcher, self.probe, Path("/bin/bash"), Path("/bin/echo"), Path("/usr/bin/sandbox-exec")]},
            "host": platform.platform(),
        }

    def issue(self, operation: str, script: Path) -> dict:
        token = secrets.token_hex(32)
        grant = {"token": token, **self.facts(operation, script)}
        self.issued[token] = copy.deepcopy(grant)
        return grant

    def validate(self, grant: dict | None, operation: str, script: Path) -> None:
        # All authority/freshness checks precede Case construction, ledger or spawn effects.
        if not isinstance(grant, dict) or not isinstance(grant.get("token"), str):
            raise Refusal("development_authority_absent")
        trusted = self.issued.get(grant["token"])
        if trusted is None or grant != trusted:
            raise Refusal("development_authority_invalid")
        if script.is_symlink() or script.parent != self.project / "checks":
            raise Refusal("development_check_scope_invalid")
        if {k: v for k, v in trusted.items() if k != "token"} != self.facts(operation, script):
            raise Refusal("development_authority_stale")


class BoundedCapture:
    def __init__(self, file):
        self.file, self.total, self.retained = file, 0, 0

    def write(self, data):
        self.total += len(data)
        kept = data[:max(0, BUDGETS["retained_bytes_per_stream"] - self.retained)]
        self.retained += len(kept)
        return self.file.write(kept)

    def flush(self): self.file.flush()
    def close(self): self.file.close()


def run_job(authority: FixtureAuthority, operation: str, script: Path, grant: dict | None) -> dict:
    authority.validate(grant, operation, script)
    case = driver.Case(operation, authority.out / operation, authority.helper, authority.launcher)
    case.stdout_file = BoundedCapture(case.stdout_file)
    case.stderr_file = BoundedCapture(case.stderr_file)
    result = {"operation_id": operation, "grant": grant, "phase": "unknown"}
    try:
        argv = ["--", "/usr/bin/sandbox-exec", "-f", str(authority.policy),
                "-D", f"PROBE={authority.probe}", "-D", f"PROJECT={authority.project}",
                "-D", f"SCRATCH={authority.scratch}", *grant["argv"]]
        case.start(argv, cwd=authority.project, store=authority.ledger, environment=ENVIRONMENT)
        pid, pgid, sid = case.ready()
        if pid != pgid or sid != case.spawned_pid:
            raise RuntimeError("CDS1 READY ownership mismatch")
        driver.send_go(case)
        fields = driver.frame_fields(case.wait_frame("FINAL"), "FINAL")
        if len(fields) != 10:
            raise RuntimeError("Malformed FINAL")
        observed, reaped, absent, cause, code, term_signal = map(int, fields[4:])
        wait_status = case.finish_supervisor()
        case.finish_outputs()
        complete = (observed, reaped, absent, cause, term_signal) == (1, 1, 1, 0, 0)
        complete = complete and os.WIFEXITED(wait_status) and os.WEXITSTATUS(wait_status) == 0
        complete = complete and case.stdout_fd is None and case.stderr_fd is None
        errors = [f for f in case.frames if " ERROR " in f]
        if errors: complete = False
        result.update({"phase": ("exited" if code == 0 else "nonzero") if complete else "unknown",
                       "exit_code": code if observed and code >= 0 else None,
                       "termination_signal": term_signal or None, "root_pid": pid, "pgid": pgid,
                       "supervisor_sid": sid, "root_observed": bool(observed), "root_reaped": bool(reaped),
                       "original_group_absent": bool(absent), "cleanup_cause": cause,
                       "helper_wait_status": wait_status, "errors": errors,
                       "stdout_eof": case.stdout_fd is None, "stderr_eof": case.stderr_fd is None})
    except Exception as error:
        result["error"] = str(error)
        case.close_control("development_error_disconnect")
        if case.spawned_pid is not None:
            try: case.finish_supervisor()
            except Exception: case.emergency_reap_supervisor_only()
        case.finish_outputs()
    finally:
        case.close_control("development_close")
        case.close_status("development_close")
        for name in ("stdout", "stderr"):
            capture = getattr(case, name + "_file")
            capture.flush()
            raw = (case.directory / (name + ".bin")).read_bytes()
            result[name] = {"base64": base64.b64encode(raw).decode("ascii"),
                            "sha256": hashlib.sha256(raw).hexdigest(), "retained_bytes": len(raw),
                            "total_bytes_observed": capture.total, "truncated": capture.total > len(raw)}
        case.close_files()
        result["frames"] = case.frames
        (case.directory / "receipt.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--supervisor", type=Path, required=True)
    args = parser.parse_args()
    out = args.output_directory.absolute()
    if out.is_symlink() or out.exists(): parser.error("output directory must be new")
    out.mkdir(mode=0o700)
    out = out.resolve(strict=True)
    result = {"schema": "conduit-offline-development-probe/v1", "status": "BLOCKED",
              "evidence_layer": "source_exposed_development", "backend": "deprecated_sandbox_exec",
              "production_support": "UNRESOLVED", "installed_acceptance": "NOT_RUN",
              "degraded": True, "boundary_warning": "deprecated_backend_no_production_fallback",
              "host": platform.platform(), "started_at_epoch": time.time(), "cases": [],
              "planned_native_cases": ["allowed", "controlled_nonzero", "ambient_read", "ambient_write", "ambient_exec",
                                       "outside_write", "traversal", "symlink", "project_write", "outside_read",
                                       "unapproved_executable", "approved_executable", "detached_descendant", "ambient_network", "network"]}
    try:
        if sys.platform != "darwin" or not Path("/usr/bin/sandbox-exec").is_file():
            raise RuntimeError("macOS development boundary unavailable; no unconfined fallback")
        helper = args.supervisor.resolve(strict=True)
        for name in ("project", "scratch", "outside", "ledger"):
            (out / name).mkdir(mode=0o700)
        project, scratch, outside = [out / p for p in ("project", "scratch", "outside")]
        (project / "checks").mkdir()
        value = project / "value.txt"
        value.write_bytes(b"before\n")
        (outside / "secret.txt").write_bytes(b"owned outside sentinel\n")
        (project / "outside-link").symlink_to(outside, target_is_directory=True)
        source, probe, launcher, policy = [out / p for p in ("probe.c", "probe", "budget-launcher", "policy.sb")]
        # Reuse the earlier probe, adding cooperative expiry for the owned native fixture.
        source.write_text(policy_probe.PROBE.replace('if (argc < 3) return 64;', 'alarm(4); if (argc < 3) return 64;'))
        developer = Path("/Applications/Xcode.app/Contents/Developer")
        compiler = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
        sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"],
                                      env={**ENVIRONMENT, "DEVELOPER_DIR": str(developer)}, timeout=10).decode().strip()
        launcher_source = Path(__file__).parent.parent / "Tests/SupervisorFixtures/offline-budget-launcher.c"
        for label, input_path, executable in [("probe", source, probe), ("launcher", launcher_source, launcher)]:
            run = subprocess.run([str(compiler), "-isysroot", sdk, "-Wall", "-Wextra", "-Werror", str(input_path), "-o", str(executable)],
                                 env=ENVIRONMENT, capture_output=True, timeout=60)
            (out / f"compile-{label}.stdout").write_bytes(run.stdout)
            (out / f"compile-{label}.stderr").write_bytes(run.stderr)
            if run.returncode: raise RuntimeError(f"Native {label} compilation failed")
        policy.write_text(PROFILE)
        authority = FixtureAuthority(out, helper, probe, launcher, policy)
        result["inputs"] = {str(p): sha(p) for p in [Path(__file__), Path(driver.__file__), Path(policy_probe.__file__),
                                                     launcher_source, helper, compiler, policy, probe, launcher]}
        result["sdk"] = sdk
        result["budgets"] = BUDGETS
        result["unprovided_limits"] = ["aggregate_memory", "aggregate_disk", "aggregate_cpu", "hostile_same_user", "task_process_count"]

        # Native inspect/search/edit preparation, entirely within this owned project.
        before = value.read_bytes()
        before_hash = sha(value)
        if b"before" not in before: raise RuntimeError("Search missed declared input")
        if hashlib.sha256(before).hexdigest() != before_hash: raise RuntimeError("Stale preparation")
        value.write_bytes(b"after\n")
        result["file_preparation"] = {"before_base64": base64.b64encode(before).decode(), "before_sha256": before_hash,
                                      "search_hits": ["value.txt"], "after_sha256": sha(value),
                                      "evidence_layer": "native_fixture_preparation_not_product_file_API"}
        script = project / "checks/allowed.sh"
        script.write_text('IFS= read -r value < value.txt\n[ "$value" = after ] || exit 23\n'
                          'printf "checked\\n"\nprintf "diagnostic\\n" >&2\n'
                          f'printf "artifact\\n" > {shlex.quote(str(scratch / "result.txt"))}\n')
        granted = authority.issue("allowed", script)
        baseline = snapshot([project, scratch, out / "ledger"])
        variants = [("absent", None), ("unknown", {**granted, "token": "unissued"})]
        for key, val in [("project", str(outside)), ("network", "allow"), ("argv", ["/usr/bin/true"]),
                         ("environment", {"DYLD_INSERT_LIBRARIES": "unapproved"}),
                         ("budgets", {**BUDGETS, "wall_ms": 5000}), ("policy_sha256", "0" * 64)]:
            variants.append((key, {**granted, key: val}))
        for label, grant in variants:
            try: run_job(authority, "allowed", script, grant)
            except Refusal as refusal:
                passed = baseline == snapshot([project, scratch, out / "ledger"]) and not (out / "allowed").exists()
                result["cases"].append({"id": "authority_" + label, "status": "PASS" if passed else "FAIL",
                                        "layer": "application_refusal", "code": str(refusal), "no_operation_effects": passed})
                if not passed: raise RuntimeError("Authority refusal changed fixture effects")
            else: raise RuntimeError("Invalid authority reached launcher")
        # Freshness is checked against bytes at admission, not only grant fields.
        script.write_text(script.read_text() + "# changed after grant\n")
        changed_snapshot = snapshot([project, scratch, out / "ledger"])
        try: run_job(authority, "allowed", script, granted)
        except Refusal as refusal:
            if str(refusal) != "development_authority_stale" or changed_snapshot != snapshot([project, scratch, out / "ledger"]):
                raise RuntimeError("Stale grant refusal was not effect-free")
            result["cases"].append({"id": "authority_stale_script", "status": "PASS", "layer": "application_refusal",
                                    "code": str(refusal), "no_operation_effects": not (out / "allowed").exists()})
        else: raise RuntimeError("Stale script reached launcher")

        def case(name: str, text: str, exit_code: int, stdout: bytes, stderr: bytes = b"", absent: Path | None = None):
            path = project / "checks" / (name + ".sh")
            if path != script: path.write_text(text)
            receipt = run_job(authority, name, path, authority.issue(name, path))
            passed = receipt["phase"] == ("exited" if exit_code == 0 else "nonzero") and receipt["exit_code"] == exit_code
            passed = passed and base64.b64decode(receipt["stdout"]["base64"]) == stdout and base64.b64decode(receipt["stderr"]["base64"]) == stderr
            passed = passed and (absent is None or not absent.exists())
            row = {"id": name, "status": "PASS" if passed else "FAIL", "layer": "native_OS_boundary",
                   "receipt": str(out / name / "receipt.json"), "exit_code": receipt.get("exit_code"), "phase": receipt["phase"]}
            result["cases"].append(row)
            if not passed: raise RuntimeError("First adverse native condition: " + name)

        case("allowed", "", 0, b"checked\n", b"diagnostic\n")
        if (scratch / "result.txt").read_bytes() != b"artifact\n": raise RuntimeError("Declared artifact missing")
        result["inspected_result"] = {"source_sha256": sha(value), "artifact_sha256": sha(scratch / "result.txt")}
        case("controlled_nonzero", 'printf "failure\\n" >&2\nexit 23\n', 23, b"", b"failure\n")
        command = lambda mode, target: "exec " + shlex.join([str(probe), mode, str(target)]) + "\n"
        # Ambient controls demonstrate accessible sentinels before OS refusal is attributed.
        for mode, target in [("read", outside / "secret.txt"), ("write", outside / "ambient.txt"), ("exec", "/usr/bin/true")]:
            run = subprocess.run([str(probe), mode, str(target)], env=ENVIRONMENT, capture_output=True, timeout=6)
            result["cases"].append({"id": "ambient_" + mode, "status": "PASS" if run.returncode == 0 else "FAIL",
                                    "layer": "unconfined_owned_control", "exit_code": run.returncode})
            if run.returncode: raise RuntimeError("Ambient positive control failed")
        for name, target in [("outside_write", outside / "denied.txt"),
                             ("traversal", project / ".." / "outside/traversal.txt"),
                             ("symlink", project / "outside-link/link.txt"),
                             ("project_write", project / "check-must-not-edit.txt")]:
            case(name, command("write", target), 13, b"open_errno=1\n", absent=target)
        case("outside_read", command("read", outside / "secret.txt"), 13, b"open_errno=1\n")
        case("unapproved_executable", command("exec", "/usr/bin/true"), 126, b"exec_errno=1\n")
        case("approved_executable", command("exec", "/bin/echo"), 0, b"allowed\n")
        case("detached_descendant", command("detached-write", outside / "detached.txt"), 13,
             b"setsid_ok\nopen_errno=1\n", absent=outside / "detached.txt")
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0)); listener.listen(2); listener.settimeout(1)
            port = listener.getsockname()[1]
            run = subprocess.run([str(probe), "connect", str(port)], env=ENVIRONMENT, capture_output=True, timeout=6)
            peer, _ = listener.accept(); peer.close()
            if run.returncode != 0: raise RuntimeError("Owned network positive control failed")
            result["cases"].append({"id": "ambient_network", "status": "PASS", "layer": "unconfined_owned_control"})
            case("network", command("connect", port), 21, b"connect_errno=1\n")
            listener.setblocking(False)
            try:
                peer, _ = listener.accept(); peer.close()
            except BlockingIOError: pass
            else: raise RuntimeError("Denied request reached owned endpoint")
        if (outside / "secret.txt").read_bytes() != b"owned outside sentinel\n": raise RuntimeError("Outside sentinel changed")
        result["status"] = "PASS_DEVELOPMENT_ONLY"
    except Exception as error:
        result["error"] = str(error)
        if result["cases"]: result["status"] = "FAIL_PRESERVED"
    result["ended_at_epoch"] = time.time()
    observed = {row["id"] for row in result["cases"]}
    result["not_run"] = [name for name in result["planned_native_cases"] if name not in observed]
    (out / "RESULT.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"status": result["status"], "cases": len(result["cases"]), "result": str(out / "RESULT.json")}))
    if result["status"] == "PASS_DEVELOPMENT_ONLY": return 0
    return 2 if result["status"] == "BLOCKED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
