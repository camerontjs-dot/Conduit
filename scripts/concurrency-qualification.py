#!/usr/bin/env python3
"""Slice 11 capacity/concurrency qualification for Conduit.

This is research infrastructure. It does not choose or change Conduit's shipped
live-task limit.

One invocation qualifies one declared tier (4, 6, or 8). The Conduit app must
already be running with Session API writes enabled. For tiers above the shipped
limit, launch the exact candidate with:

    CONDUIT_QUALIFICATION_MODE=1 \
    CONDUIT_QUALIFICATION_LIVE_TASK_LIMIT=6 \
    <path-to-Conduit-executable>

or the same with 8.

The runner fails closed unless the Fleet snapshot reports exactly the requested
effective task-control limit and a clean active-turn baseline. It creates only
qualification-owned tasks, records bounded observations, closes those tasks,
and verifies that Conduit task-control occupancy returns to baseline.

Provider completion is not task/objective acceptance. Fleet active-turn counts
are provider observations, not a provider-neutral execution-slot authority.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parent.parent
CANARY = REPO / "scripts" / "canary-control-plane.py"
RECEIPT_DIR = REPO / "outputs" / "local-acceptance" / "concurrency"
SUPPORTED_TIERS = (4, 6, 8)

spec = importlib.util.spec_from_file_location("canary_cp", CANARY)
cp = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(cp)


class QualificationBlocked(RuntimeError):
    """The requested tier cannot be measured without changing the experiment."""


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def iso_now() -> str:
    return utc_now().isoformat(timespec="milliseconds").replace("+00:00", "Z")


def known_value(field: Any) -> Any | None:
    if not isinstance(field, dict) or field.get("state") != "known":
        return None
    return field.get("value")


def capacity_summary(snapshot: dict[str, Any]) -> dict[str, Any]:
    capacity = snapshot.get("capacity") or {}
    slots = capacity.get("task_control_slots") or {}

    def count(name: str) -> dict[str, Any]:
        row = capacity.get(name) or {}
        return {
            "known_count": row.get("known_count"),
            "unknown_count": row.get("unknown_count"),
            "total": known_value(row.get("total")),
            "total_state": (row.get("total") or {}).get("state"),
            "basis": row.get("basis"),
        }

    resources = capacity.get("resources") or {}
    return {
        "task_slots": {
            "used": known_value(slots.get("used")),
            "used_state": (slots.get("used") or {}).get("state"),
            "limit": known_value(slots.get("limit")),
            "limit_state": (slots.get("limit") or {}).get("state"),
            "pending_create_reservations": known_value(
                slots.get("pending_create_reservations")
            ),
            "queued_prompt_reservations": known_value(
                slots.get("queued_prompt_reservations")
            ),
        },
        "discovered_provider_sessions": count("discovered_provider_sessions"),
        "supervised_provider_sessions": count("supervised_provider_sessions"),
        "provider_reported_active_turns": count("provider_reported_active_turns"),
        "provider_hosts": count("provider_hosts"),
        "observed_child_processes": count("observed_child_processes"),
        "actual_execution_slot_occupancy": known_value(
            capacity.get("actual_execution_slot_occupancy")
        ),
        "actual_execution_slot_state": (
            capacity.get("actual_execution_slot_occupancy") or {}
        ).get("state"),
        "actual_execution_slot_basis": capacity.get("actual_execution_slot_basis"),
        "resources": resources,
    }


def snapshot_age_ms(snapshot: dict[str, Any]) -> float | None:
    raw = snapshot.get("observed_at")
    if not isinstance(raw, str):
        return None
    try:
        observed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None
    return max(0.0, (utc_now() - observed).total_seconds() * 1000.0)


def require_declared_tier(
    snapshot: dict[str, Any],
    target: int,
    *,
    require_clean_baseline: bool = True,
) -> dict[str, Any]:
    summary = capacity_summary(snapshot)
    slots = summary["task_slots"]
    if slots["limit"] != target:
        raise QualificationBlocked(
            f"requested tier {target}, but Fleet reports task-control limit "
            f"{slots['limit']!r} ({slots['limit_state']}); relaunch the exact "
            "candidate with the qualification aperture rather than changing "
            "the shipped policy"
        )
    if require_clean_baseline:
        if slots["used"] != 0:
            raise QualificationBlocked(
                f"clean baseline required; Fleet reports {slots['used']!r} "
                "Conduit task-control slots already used"
            )
        active = summary["provider_reported_active_turns"]
        if active["total_state"] == "known" and active["total"] != 0:
            raise QualificationBlocked(
                "background provider activity is already known at baseline: "
                f"total={active['total']!r}"
            )
        summary["background_provider_activity_baseline"] = (
            "known_zero" if active["total_state"] == "known" else "unknown"
        )
    return summary


def fleet_snapshot(api: Any) -> tuple[dict[str, Any], float]:
    started = time.perf_counter()
    snapshot = api.call("conduit_fleet_snapshot", limit=200)
    latency_ms = (time.perf_counter() - started) * 1000.0
    if snapshot.get("error"):
        raise QualificationBlocked(f"Fleet snapshot failed: {snapshot['error']}")
    return snapshot, latency_ms


def qualification_task_provider_states(
    snapshot: dict[str, Any],
    task_ids: list[str],
) -> dict[str, Any]:
    wanted = {task_id.lower(): task_id for task_id in task_ids}
    rows: dict[str, dict[str, Any]] = {}
    duplicates: list[str] = []

    for item in (snapshot.get("provider_sessions") or {}).get("items") or []:
        association = item.get("task_association") or {}
        if association.get("kind") != "exact":
            continue
        task_id = known_value(association.get("task_session_id"))
        if not isinstance(task_id, str):
            continue
        key = task_id.lower()
        if key not in wanted:
            continue

        worker = item.get("worker") or {}
        reconciliation = worker.get("runtime_reconciliation") or {}
        row = {
            "task_session_id": wanted[key],
            "provider_session_id": known_value(worker.get("provider_session_id")),
            "provider_reported_state": reconciliation.get(
                "provider_reported_state", "unknown"
            ),
            "reconciliation_disposition": reconciliation.get("disposition"),
            "provider_observation": reconciliation.get("provider_observation"),
        }
        if key in rows:
            duplicates.append(wanted[key])
        rows[key] = row

    missing = [
        original for key, original in wanted.items()
        if key not in rows
    ]
    states = [row["provider_reported_state"] for row in rows.values()]
    return {
        "rows": list(rows.values()),
        "missing_task_session_ids": missing,
        "duplicate_task_session_ids": sorted(set(duplicates)),
        "active_count": sum(state == "active" for state in states),
        "inactive_count": sum(state == "inactive" for state in states),
        "unknown_count": sum(state not in {"active", "inactive"} for state in states),
        "provider_session_ids": sorted(
            {
                row["provider_session_id"]
                for row in rows.values()
                if isinstance(row.get("provider_session_id"), str)
            }
        ),
        "all_exact_active": (
            len(rows) == len(wanted)
            and not missing
            and not duplicates
            and len(
                {
                    row["provider_session_id"]
                    for row in rows.values()
                    if isinstance(row.get("provider_session_id"), str)
                }
            ) == len(wanted)
            and all(state == "active" for state in states)
        ),
    }


def observe_provider_sessions(
    api: Any,
    provider_session_ids: list[str],
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for provider_session_id in provider_session_ids:
        try:
            observed = api.call(
                "conduit_observe_worker",
                provider="opencode",
                provider_session_id=provider_session_id,
            )
            worker = observed.get("worker") or {}
            reconciliation = worker.get("runtime_reconciliation") or {}
            rows.append(
                {
                    "provider_session_id": provider_session_id,
                    "provider_reported_state": reconciliation.get(
                        "provider_reported_state", "unknown"
                    ),
                    "reconciliation_disposition": reconciliation.get("disposition"),
                    "error": observed.get("error"),
                }
            )
        except Exception as exc:
            rows.append(
                {
                    "provider_session_id": provider_session_id,
                    "provider_reported_state": "unknown",
                    "error": str(exc),
                }
            )
    return rows


def conduit_process_sample() -> dict[str, Any]:
    probe = subprocess.run(
        ["pgrep", "-x", "Conduit"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    pids = [p for p in probe.stdout.split() if p.isdigit()]
    if len(pids) != 1:
        return {
            "state": "unknown",
            "reason": f"expected one Conduit process, observed {len(pids)}",
            "pids": pids,
        }
    pid = pids[0]
    ps = subprocess.run(
        ["ps", "-p", pid, "-o", "pid=,%cpu=,rss=,etime="],
        capture_output=True,
        text=True,
        timeout=5,
    )
    fields = ps.stdout.split()
    if ps.returncode != 0 or len(fields) < 4:
        return {
            "state": "unknown",
            "pid": int(pid),
            "reason": (ps.stderr or ps.stdout or "ps sample unavailable").strip(),
        }
    try:
        return {
            "state": "known",
            "pid": int(fields[0]),
            "process_cpu_percent": float(fields[1]),
            "rss_kib": int(fields[2]),
            "elapsed": fields[3],
            "main_thread_cpu_percent": None,
            "main_thread_cpu_state": "unknown",
            "basis": (
                "macOS ps process CPU/RSS; this is whole-process CPU, not "
                "main-thread CPU"
            ),
        }
    except ValueError:
        return {
            "state": "unknown",
            "pid": int(pid),
            "reason": f"unexpected ps output: {ps.stdout.strip()}",
        }


def hold_objective(token: str, hold_seconds: int, output_lines: int) -> str:
    return (
        "Qualification task. Do not modify project files. Use the shell tool to "
        f"run sleep {hold_seconds} exactly once. After it exits, use no more "
        f"tools and emit exactly {output_lines} newline-separated lines. Prefix "
        f"every line with {token}- followed by a four-digit line number. Do not "
        "add prose before or after the numbered lines."
    )


def create_task(
    api: Any,
    *,
    agent: str,
    project: str,
    target: int,
    index: int,
    hold_seconds: int,
    output_lines: int,
    stamp: str,
) -> dict[str, Any]:
    token = f"CONDUIT-S11-{target}-{index}-{stamp}"
    started = time.perf_counter()
    result = api.call(
        "conduit_create_task",
        agent=agent,
        project_slug=project,
        objective=hold_objective(token, hold_seconds, output_lines),
        idempotency_key=f"slice11-{target}-{index}-{stamp}",
    )
    return {
        "index": index,
        "token": token,
        "latency_ms": (time.perf_counter() - started) * 1000.0,
        "result": result,
        "task_session_id": result.get("taskSessionID"),
    }


def sample_once(
    api: Any,
    task_ids: list[str] | None = None,
) -> dict[str, Any]:
    snapshot, latency_ms = fleet_snapshot(api)
    return {
        "at": iso_now(),
        "fleet_rpc_latency_ms": latency_ms,
        "fleet_snapshot_age_ms": snapshot_age_ms(snapshot),
        "capacity": capacity_summary(snapshot),
        "qualification_tasks": qualification_task_provider_states(
            snapshot, task_ids or []
        ),
        "conduit_process": conduit_process_sample(),
    }


def wait_for_active_tier(
    api: Any,
    task_ids: list[str],
    timeout_seconds: int,
    poll_seconds: float,
    samples: list[dict[str, Any]],
    *,
    sample_cpu_threshold: float,
    sample_artifact_path: Path,
    sample_capture: dict[str, Any],
) -> dict[str, Any] | None:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        sample = sample_once(api, task_ids)
        record_sample(
            samples,
            sample,
            threshold=sample_cpu_threshold,
            artifact_path=sample_artifact_path,
            capture=sample_capture,
            phase="active_acquisition",
        )
        if sample["qualification_tasks"]["all_exact_active"]:
            return sample
        time.sleep(poll_seconds)
    return None


def close_tasks(api: Any, task_ids: list[str]) -> list[dict[str, Any]]:
    results = []
    for task_id in task_ids:
        started = time.perf_counter()
        try:
            result = api.call("conduit_close_session", taskSessionID=task_id)
            results.append(
                {
                    "task_session_id": task_id,
                    "latency_ms": (time.perf_counter() - started) * 1000.0,
                    "result": result,
                }
            )
        except Exception as exc:
            results.append(
                {
                    "task_session_id": task_id,
                    "latency_ms": (time.perf_counter() - started) * 1000.0,
                    "error": str(exc),
                }
            )
    return results


def provider_sessions_inactive(
    provider_rows: list[dict[str, Any]],
    expected_provider_sessions: int,
) -> bool:
    return (
        len(provider_rows) == expected_provider_sessions
        and all(
            row.get("provider_reported_state") == "inactive"
            and not row.get("error")
            for row in provider_rows
        )
    )


def wait_for_provider_completion(
    api: Any,
    task_ids: list[str],
    provider_session_ids: list[str],
    timeout_seconds: int,
    poll_seconds: float,
    samples: list[dict[str, Any]],
    *,
    sample_cpu_threshold: float,
    sample_artifact_path: Path,
    sample_capture: dict[str, Any],
) -> bool:
    if len(provider_session_ids) != len(task_ids) or not provider_session_ids:
        return False
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        sample = sample_once(api, task_ids)
        provider_rows = observe_provider_sessions(api, provider_session_ids)
        sample["qualification_provider_completion"] = provider_rows
        record_sample(
            samples,
            sample,
            threshold=sample_cpu_threshold,
            artifact_path=sample_artifact_path,
            capture=sample_capture,
            phase="natural_completion",
        )
        if provider_sessions_inactive(provider_rows, len(provider_session_ids)):
            return True
        time.sleep(poll_seconds)
    return False


def cleanup_reconciled(
    sample: dict[str, Any],
    provider_rows: list[dict[str, Any]],
    expected_provider_sessions: int,
) -> bool:
    if sample["capacity"]["task_slots"]["used"] != 0:
        return False
    if len(provider_rows) != expected_provider_sessions:
        return False
    return provider_sessions_inactive(provider_rows, expected_provider_sessions)


def wait_for_cleanup_reconciliation(
    api: Any,
    task_ids: list[str],
    provider_session_ids: list[str],
    timeout_seconds: int,
    poll_seconds: float,
    samples: list[dict[str, Any]],
    *,
    sample_cpu_threshold: float,
    sample_artifact_path: Path,
    sample_capture: dict[str, Any],
) -> bool:
    deadline = time.monotonic() + timeout_seconds
    expected = len(provider_session_ids)
    if expected == 0 and task_ids:
        return False
    while time.monotonic() < deadline:
        sample = sample_once(api, task_ids)
        provider_rows = observe_provider_sessions(api, provider_session_ids)
        sample["qualification_provider_cleanup"] = provider_rows
        record_sample(
            samples,
            sample,
            threshold=sample_cpu_threshold,
            artifact_path=sample_artifact_path,
            capture=sample_capture,
            phase="cleanup",
        )
        if cleanup_reconciled(sample, provider_rows, expected):
            return True
        time.sleep(poll_seconds)
    return False


def numeric_peak(samples: list[dict[str, Any]], path: tuple[str, ...]) -> float | None:
    values: list[float] = []
    for sample in samples:
        current: Any = sample
        for key in path:
            if not isinstance(current, dict):
                current = None
                break
            current = current.get(key)
        if isinstance(current, (int, float)) and math.isfinite(float(current)):
            values.append(float(current))
    return max(values) if values else None


def maybe_capture_sample_if_hot(
    sample: dict[str, Any],
    threshold: float,
    artifact_path: Path,
    capture: dict[str, Any],
    phase: str,
) -> None:
    if capture.get("attempted"):
        return
    process = sample.get("conduit_process") or {}
    cpu = process.get("process_cpu_percent")
    pid = process.get("pid")
    if (
        process.get("state") != "known"
        or not isinstance(cpu, (int, float))
        or not math.isfinite(float(cpu))
        or float(cpu) < threshold
    ):
        return

    capture.update(
        {
            "attempted": True,
            "captured": False,
            "triggered_at": sample.get("at"),
            "trigger_phase": phase,
            "trigger_cpu_percent": float(cpu),
            "pid": pid,
            "artifact_path": str(artifact_path),
            "basis": (
                "Triggered immediately from a live Conduit process CPU sample "
                "before qualification teardown. Inspect the macOS sample for "
                "the main-thread stack; process CPU is not main-thread CPU."
            ),
        }
    )
    if not isinstance(pid, int):
        capture["error"] = "Conduit PID unavailable at threshold crossing"
        return

    cmd = ["sample", str(pid), "2", "1", "-file", str(artifact_path)]
    capture["command"] = cmd
    try:
        run = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        capture["exit_code"] = run.returncode
        capture["stderr"] = run.stderr[-1000:]
        capture["captured"] = run.returncode == 0
        if run.returncode != 0:
            capture["error"] = "macOS sample command failed"
    except Exception as exc:
        capture["error"] = str(exc)


def record_sample(
    samples: list[dict[str, Any]],
    sample: dict[str, Any],
    *,
    threshold: float,
    artifact_path: Path,
    capture: dict[str, Any],
    phase: str,
) -> None:
    samples.append(sample)
    maybe_capture_sample_if_hot(
        sample,
        threshold,
        artifact_path,
        capture,
        phase,
    )


def receipt_path_for(target_tier: int, requested_path: Path | None) -> Path:
    RECEIPT_DIR.mkdir(parents=True, exist_ok=True)
    if requested_path is not None:
        requested_path.parent.mkdir(parents=True, exist_ok=True)
        return requested_path
    stamp = utc_now().strftime("%Y%m%dT%H%M%SZ")
    return RECEIPT_DIR / f"slice11-concurrency-{target_tier}-{stamp}.json"


def write_receipt(receipt: dict[str, Any], path: Path) -> Path:
    path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    return path


def run(args: argparse.Namespace) -> tuple[dict[str, Any], Path]:
    if args.target not in SUPPORTED_TIERS:
        raise QualificationBlocked(
            f"target must be one of {SUPPORTED_TIERS}, got {args.target}"
        )

    api = cp.SessionAPI(cp.load_token())
    api.initialize()

    baseline_snapshot, baseline_latency = fleet_snapshot(api)
    baseline = require_declared_tier(baseline_snapshot, args.target)
    receipt_path = receipt_path_for(args.target, args.output)
    sample_artifact_path = receipt_path.with_suffix(".sample.txt")
    sample_capture: dict[str, Any] = {
        "attempted": False,
        "captured": False,
        "threshold_cpu_percent": args.sample_cpu_threshold,
        "artifact_path": str(sample_artifact_path),
        "basis": (
            "Capture is triggered from the live observation loop at the first "
            "known Conduit process CPU sample meeting the threshold. It is not "
            "deferred until teardown."
        ),
    }
    stamp = str(int(time.time()))
    tasks: list[dict[str, Any]] = []
    samples: list[dict[str, Any]] = []
    cleanup: list[dict[str, Any]] = []
    active_tier_observed = False
    natural_completion_observed = False
    cleanup_reconciled_ok = False
    provider_session_ids: list[str] = []
    failure: str | None = None

    receipt: dict[str, Any] = {
        "schema": "conduit-slice11-concurrency-qualification-v1",
        "started_at": iso_now(),
        "target_tier": args.target,
        "agent": args.agent,
        "project": args.project,
        "hold_seconds": args.hold_seconds,
        "output_lines": args.output_lines,
        "sample_seconds": args.sample_seconds,
        "completion_timeout": args.completion_timeout,
        "poll_seconds": args.poll_seconds,
        "baseline_fleet_rpc_latency_ms": baseline_latency,
        "baseline": baseline,
        "tasks": tasks,
        "samples": samples,
        "cleanup": cleanup,
        "active_tier_observed": False,
        "natural_completion_observed": False,
        "cleanup_reconciled": False,
        "ui_responsiveness": {
            "state": "unknown",
            "basis": "not measured automatically by this runner; record manual GUI observation in the qualification receipt",
        },
        "main_thread_cpu_percent": {
            "state": "unknown",
            "basis": "whole-process CPU is sampled; a macOS sample is captured on a high-CPU trigger for main-thread stack inspection",
        },
        "non_claims": [
            "provider-reported active turns are not provider-neutral execution-slot occupancy",
            "provider completion is not task completion, verification, or objective acceptance",
            "whole-process CPU is not main-thread CPU",
            "Session API latency is control-plane responsiveness, not GUI responsiveness",
        ],
    }

    try:
        for index in range(args.target):
            task = create_task(
                api,
                agent=args.agent,
                project=args.project,
                target=args.target,
                index=index + 1,
                hold_seconds=args.hold_seconds,
                output_lines=args.output_lines,
                stamp=stamp,
            )
            tasks.append(task)
            if not task["task_session_id"]:
                raise QualificationBlocked(
                    f"create {index + 1}/{args.target} did not return a taskSessionID: "
                    f"{task['result']}"
                )

        task_ids = [
            row["task_session_id"]
            for row in tasks
            if isinstance(row.get("task_session_id"), str)
        ]
        active_sample = wait_for_active_tier(
            api,
            task_ids,
            args.active_timeout,
            args.poll_seconds,
            samples,
            sample_cpu_threshold=args.sample_cpu_threshold,
            sample_artifact_path=sample_artifact_path,
            sample_capture=sample_capture,
        )
        active_tier_observed = active_sample is not None
        if active_sample is not None:
            provider_session_ids = active_sample[
                "qualification_tasks"
            ]["provider_session_ids"]
            end = time.monotonic() + args.sample_seconds
            while time.monotonic() < end:
                sample = sample_once(api, task_ids)
                record_sample(
                    samples,
                    sample,
                    threshold=args.sample_cpu_threshold,
                    artifact_path=sample_artifact_path,
                    capture=sample_capture,
                    phase="active_overlap",
                )
                time.sleep(args.poll_seconds)
            natural_completion_observed = wait_for_provider_completion(
                api,
                task_ids,
                provider_session_ids,
                args.completion_timeout,
                args.poll_seconds,
                samples,
                sample_cpu_threshold=args.sample_cpu_threshold,
                sample_artifact_path=sample_artifact_path,
                sample_capture=sample_capture,
            )
            if not natural_completion_observed:
                failure = (
                    "qualification-owned provider sessions did not all reach "
                    "provider-reported inactive state before the completion timeout"
                )
        else:
            failure = (
                "qualification-owned provider sessions never all reached "
                f"provider-reported active state for tier {args.target}"
            )
    except Exception as exc:
        failure = str(exc)
    finally:
        task_ids = [
            row["task_session_id"]
            for row in tasks
            if isinstance(row.get("task_session_id"), str)
        ]
        if not provider_session_ids:
            provider_session_ids = sorted(
                {
                    provider_session_id
                    for sample in samples
                    for provider_session_id in (
                        sample.get("qualification_tasks") or {}
                    ).get("provider_session_ids", [])
                }
            )
        cleanup.extend(close_tasks(api, task_ids))
        cleanup_reconciled_ok = wait_for_cleanup_reconciliation(
            api,
            task_ids,
            provider_session_ids,
            args.cleanup_timeout,
            args.poll_seconds,
            samples,
            sample_cpu_threshold=args.sample_cpu_threshold,
            sample_artifact_path=sample_artifact_path,
            sample_capture=sample_capture,
        )

    receipt["finished_at"] = iso_now()
    receipt["active_tier_observed"] = active_tier_observed
    receipt["natural_completion_observed"] = natural_completion_observed
    receipt["provider_session_ids"] = provider_session_ids
    receipt["cleanup_reconciled"] = cleanup_reconciled_ok
    receipt["failure"] = failure
    receipt["summary"] = {
        "create_attempts": len(tasks),
        "successful_creates": sum(
            1 for task in tasks if isinstance(task.get("task_session_id"), str)
        ),
        "create_failures": sum(
            1 for task in tasks if not isinstance(task.get("task_session_id"), str)
        ),
        "active_tier_timeout": not active_tier_observed,
        "natural_completion_timeout": (
            active_tier_observed and not natural_completion_observed
        ),
        "cleanup_reconciled": cleanup_reconciled_ok,
        "peak_fleet_rpc_latency_ms": numeric_peak(
            samples, ("fleet_rpc_latency_ms",)
        ),
        "peak_fleet_snapshot_age_ms": numeric_peak(
            samples, ("fleet_snapshot_age_ms",)
        ),
        "peak_conduit_process_cpu_percent": numeric_peak(
            samples, ("conduit_process", "process_cpu_percent")
        ),
        "peak_conduit_rss_kib": numeric_peak(
            samples, ("conduit_process", "rss_kib")
        ),
        "maximum_global_provider_reported_active_turns": numeric_peak(
            samples, ("capacity", "provider_reported_active_turns", "total")
        ),
        "maximum_qualification_owned_active_turns": numeric_peak(
            samples, ("qualification_tasks", "active_count")
        ),
        "maximum_provider_hosts": numeric_peak(
            samples, ("capacity", "provider_hosts", "total")
        ),
        "maximum_observed_child_processes": numeric_peak(
            samples, ("capacity", "observed_child_processes", "total")
        ),
        "actual_execution_slot_occupancy_state": (
            samples[-1]["capacity"]["actual_execution_slot_state"]
            if samples
            else baseline["actual_execution_slot_state"]
        ),
    }

    if not sample_capture.get("attempted"):
        peak = numeric_peak(samples, ("conduit_process", "process_cpu_percent"))
        sample_capture["reason"] = (
            f"no known Conduit process CPU sample met threshold "
            f"{args.sample_cpu_threshold}; observed peak={peak!r}"
        )
    elif not sample_capture.get("captured") and failure is None:
        failure = "high-CPU threshold crossed but macOS sample capture failed"
        receipt["failure"] = failure

    receipt["high_cpu_sample"] = sample_capture
    receipt["disposition"] = (
        "PASS_FOR_TIER_OBSERVATION"
        if (
            active_tier_observed
            and natural_completion_observed
            and cleanup_reconciled_ok
            and failure is None
        )
        else "FAIL_OR_INCONCLUSIVE"
    )
    write_receipt(receipt, receipt_path)
    return receipt, receipt_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", type=int, required=True, choices=SUPPORTED_TIERS)
    parser.add_argument("--agent", default="OpenCode")
    parser.add_argument("--project", required=True)
    parser.add_argument("--hold-seconds", type=int, default=45)
    parser.add_argument("--output-lines", type=int, default=160)
    parser.add_argument("--sample-seconds", type=int, default=15)
    parser.add_argument("--active-timeout", type=int, default=75)
    parser.add_argument("--completion-timeout", type=int, default=240)
    parser.add_argument("--cleanup-timeout", type=int, default=45)
    parser.add_argument("--poll-seconds", type=float, default=2.0)
    parser.add_argument("--sample-cpu-threshold", type=float, default=80.0)
    parser.add_argument("--output", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        receipt, path = run(args)
    except QualificationBlocked as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(receipt["summary"], indent=2, sort_keys=True))
    print(f"receipt: {path}")
    return 0 if receipt["disposition"] == "PASS_FOR_TIER_OBSERVATION" else 1


if __name__ == "__main__":
    raise SystemExit(main())
