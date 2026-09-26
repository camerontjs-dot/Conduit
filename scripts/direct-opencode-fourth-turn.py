#!/usr/bin/env python3
"""Direct OpenCode arm for the Slice 11 fourth-turn comparison.

This research harness removes Conduit as scheduler while keeping the frozen
four-session workload. It owns one temporary ``opencode serve`` process, four
provider sessions, and no other session or process. Provider activity comes
from OpenCode's own ``/session/status`` and SSE event surfaces; process
existence is never promoted to provider-active work.

The target is deliberately fixed at four. This harness cannot run tiers 6/8 or
change Conduit's shipped task limit.
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import hashlib
import json
import os
import platform
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


TARGET = 4
HOLD_SECONDS = 45
OUTPUT_LINES = 160
ACTIVE_TIMEOUT_SECONDS = 75
OVERLAP_SECONDS = 15
COMPLETION_TIMEOUT_SECONDS = 240
POST_COMPLETION_SECONDS = 15
CLEANUP_TIMEOUT_SECONDS = 45
POLL_SECONDS = 2.0
EXPECTED_OPENCODE_VERSION = "1.18.30"
DEFAULT_MODEL = "opencode/muse-spark-1.3-contributor-free"
REPO = Path(__file__).resolve().parent.parent
SCRIPT = Path(__file__).resolve()

# Exact v1.18.30 sources behind the status-map and prompt-acceptance semantics.
STATUS_SOURCE = {
    "tag": "v1.18.30",
    "path": "packages/opencode/src/session/status.ts",
    "blob": "11140acfeef55bfbc46ea342752f71dc353ecc96",
    "semantics": (
        "busy is stored; setting idle publishes session.idle and removes the "
        "session from the status map; get() defaults an absent session to idle"
    ),
}
HTTP_SOURCE = {
    "tag": "v1.18.30",
    "path": (
        "packages/opencode/src/server/routes/instance/httpapi/groups/session.ts"
    ),
    "blob": "959a303dc964e97c02056ea634213b39d9da3f08",
    "semantics": "POST /session/:id/prompt_async returns after prompt acceptance",
}


class HarnessError(RuntimeError):
    """The direct arm cannot produce a bounded observation."""


def iso_now() -> str:
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace(
        "+00:00", "Z"
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def run_capture(arguments: list[str], *, cwd: Path | None = None) -> str:
    result = subprocess.run(
        arguments,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=20,
        check=False,
    )
    if result.returncode != 0:
        raise HarnessError(
            f"command failed ({result.returncode}): {arguments!r}: "
            f"{(result.stderr or result.stdout).strip()[:500]}"
        )
    return result.stdout.strip()


def git_identity(path: Path) -> dict[str, Any]:
    try:
        root = Path(run_capture(["git", "-C", str(path), "rev-parse", "--show-toplevel"]))
        status = subprocess.run(
            ["git", "-C", str(root), "status", "--porcelain=v1", "-z"],
            capture_output=True,
            timeout=20,
            check=False,
        )
        if status.returncode != 0:
            raise HarnessError(status.stderr.decode("utf-8", "replace")[:500])
        raw = status.stdout
        return {
            "state": "known",
            "root": str(root),
            "head": run_capture(["git", "-C", str(root), "rev-parse", "HEAD"]),
            "tree": run_capture(
                ["git", "-C", str(root), "rev-parse", "HEAD^{tree}"]
            ),
            "dirty": bool(raw),
            "status_sha256": hashlib.sha256(raw).hexdigest(),
            "status_byte_count": len(raw),
        }
    except Exception as exc:
        return {"state": "unknown", "reason": str(exc)}


def hold_objective(token: str) -> str:
    return (
        "Qualification task. Do not modify project files. Use the shell tool to "
        f"run sleep {HOLD_SECONDS} exactly once. After it exits, use no more "
        f"tools and emit exactly {OUTPUT_LINES} newline-separated lines. Prefix "
        f"every line with {token}- followed by a four-digit line number. Do not "
        "add prose before or after the numbered lines."
    )


def split_model(model: str) -> tuple[str, str]:
    provider, separator, model_id = model.partition("/")
    if not separator or not provider or not model_id:
        raise HarnessError("model must use provider/model form")
    return provider, model_id


def prompt_payload(model: str, objective: str) -> dict[str, Any]:
    provider, model_id = split_model(model)
    return {
        "model": {"providerID": provider, "modelID": model_id},
        "parts": [{"type": "text", "text": objective}],
    }


def _status_type(value: Any) -> str | None:
    if isinstance(value, str):
        return value.lower()
    if isinstance(value, dict):
        raw = value.get("type") or value.get("status") or value.get("state")
        if isinstance(raw, str):
            return raw.lower()
    return None


def status_rows(payload: Any, session_ids: list[str]) -> dict[str, Any]:
    """Project the exact v1.18.30 provider status map for owned sessions.

    In this exact OpenCode version, an idle session is removed from the map and
    ``get`` defaults absence to idle. Absence is therefore provider-defined
    inactive state, not an inference from a missing process.
    """

    if not isinstance(payload, dict):
        return {
            "rows": [
                {
                    "provider_session_id": session_id,
                    "provider_state": "unknown",
                    "reported_type": None,
                    "basis": "malformed /session/status response",
                }
                for session_id in session_ids
            ],
            "active_count": 0,
            "unknown_count": len(session_ids),
            "unrelated_status_id_hashes": [],
        }

    rows: list[dict[str, Any]] = []
    for session_id in session_ids:
        if session_id not in payload:
            rows.append(
                {
                    "provider_session_id": session_id,
                    "provider_state": "inactive",
                    "reported_type": "idle",
                    "basis": (
                        "OpenCode v1.18.30 status service removes idle entries "
                        "and defaults absent sessions to idle"
                    ),
                }
            )
            continue
        reported = _status_type(payload.get(session_id))
        if reported == "busy":
            state = "active"
        elif reported == "idle":
            state = "inactive"
        elif reported == "retry":
            state = "retry"
        else:
            state = "unknown"
        rows.append(
            {
                "provider_session_id": session_id,
                "provider_state": state,
                "reported_type": reported,
                "basis": "OpenCode /session/status",
            }
        )

    owned = set(session_ids)
    unrelated = sorted(str(key) for key in payload if key not in owned)
    return {
        "rows": rows,
        "active_count": sum(row["provider_state"] == "active" for row in rows),
        "unknown_count": sum(row["provider_state"] == "unknown" for row in rows),
        "retry_count": sum(row["provider_state"] == "retry" for row in rows),
        "unrelated_status_id_hashes": [sha256_text(value)[:16] for value in unrelated],
    }


def event_session_id(event: dict[str, Any]) -> str | None:
    properties = event.get("properties")
    if not isinstance(properties, dict):
        properties = event
    candidates: list[Any] = [
        properties.get("sessionID"),
        properties.get("sessionId"),
    ]
    for key in ("info", "part", "session"):
        nested = properties.get(key)
        if isinstance(nested, dict):
            candidates.extend([nested.get("sessionID"), nested.get("sessionId")])
            if key == "session":
                candidates.append(nested.get("id"))
    for candidate in candidates:
        if isinstance(candidate, str) and candidate:
            return candidate
    return None


def event_type(event: dict[str, Any]) -> str:
    value = event.get("type") or event.get("event")
    return value if isinstance(value, str) else ""


def unwrap_event(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    payload = value.get("payload")
    if isinstance(payload, dict) and (payload.get("type") or payload.get("event")):
        return payload
    return value


class EventTracker:
    """Thread-safe, text-free projection of exact owned-session events."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._owned: set[str] = set()
        self._timeline: dict[str, dict[str, Any]] = {}
        self._message_roles: dict[str, str] = {}
        self._events: list[dict[str, Any]] = []
        self.errors: list[dict[str, str]] = []

    def register(self, session_ids: list[str]) -> None:
        with self._lock:
            self._owned.update(session_ids)
            for session_id in session_ids:
                self._timeline.setdefault(
                    session_id,
                    {
                        "first_assistant_activity_at": None,
                        "first_busy_at": None,
                        "first_tool_running_at": None,
                        "completion_at": None,
                        "idle_at": None,
                        "last_provider_state": "unknown",
                        "idle_basis": None,
                        "errors": [],
                    },
                )

    def note_status(self, rows: list[dict[str, Any]], observed_at: str) -> None:
        with self._lock:
            for row in rows:
                session_id = row["provider_session_id"]
                timeline = self._timeline.get(session_id)
                if timeline is None:
                    continue
                state = row["provider_state"]
                previous = timeline["last_provider_state"]
                timeline["last_provider_state"] = state
                if state == "active" and timeline["first_busy_at"] is None:
                    timeline["first_busy_at"] = observed_at
                if (
                    state == "inactive"
                    and previous in {"active", "retry"}
                    and timeline["idle_at"] is None
                ):
                    timeline["idle_at"] = observed_at
                    timeline["idle_basis"] = row["basis"]

    def apply(self, raw: Any, observed_at: str | None = None) -> None:
        event = unwrap_event(raw)
        if event is None:
            return
        observed_at = observed_at or iso_now()
        kind = event_type(event)
        session_id = event_session_id(event)
        if not session_id:
            return
        properties = event.get("properties")
        if not isinstance(properties, dict):
            properties = event

        with self._lock:
            if session_id not in self._owned:
                return
            timeline = self._timeline[session_id]
            record: dict[str, Any] | None = None

            if kind == "message.updated":
                info = properties.get("info")
                if not isinstance(info, dict):
                    info = {}
                message_id = info.get("id")
                role = info.get("role")
                if isinstance(message_id, str) and isinstance(role, str):
                    self._message_roles[message_id] = role
                if role == "assistant":
                    if timeline["first_assistant_activity_at"] is None:
                        timeline["first_assistant_activity_at"] = observed_at
                    completed = (info.get("time") or {}).get("completed")
                    if completed is not None and timeline["completion_at"] is None:
                        timeline["completion_at"] = observed_at
                    record = {
                        "at": observed_at,
                        "type": kind,
                        "provider_session_id": session_id,
                        "message_id": message_id,
                        "role": role,
                        "completed": completed is not None,
                    }
            elif kind == "session.status":
                reported = _status_type(properties.get("status"))
                if reported == "busy":
                    timeline["last_provider_state"] = "active"
                    if timeline["first_busy_at"] is None:
                        timeline["first_busy_at"] = observed_at
                elif reported == "idle":
                    timeline["last_provider_state"] = "inactive"
                    if timeline["idle_at"] is None:
                        timeline["idle_at"] = observed_at
                        timeline["idle_basis"] = "OpenCode session.status SSE"
                elif reported == "retry":
                    timeline["last_provider_state"] = "retry"
                else:
                    timeline["last_provider_state"] = "unknown"
                record = {
                    "at": observed_at,
                    "type": kind,
                    "provider_session_id": session_id,
                    "reported_type": reported,
                }
            elif kind == "session.idle":
                timeline["last_provider_state"] = "inactive"
                if timeline["idle_at"] is None:
                    timeline["idle_at"] = observed_at
                    timeline["idle_basis"] = "OpenCode session.idle SSE"
                record = {
                    "at": observed_at,
                    "type": kind,
                    "provider_session_id": session_id,
                }
            elif kind == "session.error":
                timeline["errors"].append("provider session.error event")
                record = {
                    "at": observed_at,
                    "type": kind,
                    "provider_session_id": session_id,
                }
            elif kind == "message.part.updated":
                part = properties.get("part")
                if not isinstance(part, dict):
                    part = {}
                message_id = part.get("messageID") or properties.get("messageID")
                role = self._message_roles.get(str(message_id))
                if role == "assistant" and timeline["first_assistant_activity_at"] is None:
                    timeline["first_assistant_activity_at"] = observed_at
                state = part.get("state")
                state_status = state.get("status") if isinstance(state, dict) else None
                if part.get("type") == "tool" and state_status == "running":
                    if timeline["first_tool_running_at"] is None:
                        timeline["first_tool_running_at"] = observed_at
                    record = {
                        "at": observed_at,
                        "type": kind,
                        "provider_session_id": session_id,
                        "message_id": message_id,
                        "part_id": part.get("id"),
                        "part_type": "tool",
                        "tool": part.get("tool"),
                        "tool_status": "running",
                    }

            if record is not None:
                self._events.append(record)

    def add_error(self, message: str) -> None:
        with self._lock:
            self.errors.append({"at": iso_now(), "message": message})

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "sessions": json.loads(json.dumps(self._timeline)),
                "events": json.loads(json.dumps(self._events)),
                "stream_errors": json.loads(json.dumps(self.errors)),
            }


class OpenCodeHTTP:
    def __init__(self, base_url: str, password: str, directory: Path) -> None:
        self.base_url = base_url.rstrip("/")
        self.directory = str(directory)
        token = base64.b64encode(f"opencode:{password}".encode()).decode()
        self.headers = {"Authorization": f"Basic {token}"}

    def _url(self, path: str, *, directory_query: bool = True) -> str:
        url = self.base_url + path
        if directory_query:
            url += "?" + urllib.parse.urlencode({"directory": self.directory})
        return url

    def request(
        self,
        method: str,
        path: str,
        *,
        body: dict[str, Any] | None = None,
        timeout: float = 15,
        directory_query: bool = True,
    ) -> tuple[int, Any]:
        headers = dict(self.headers)
        headers["Accept"] = "application/json"
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self._url(path, directory_query=directory_query),
            data=data,
            method=method,
            headers=headers,
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                payload = response.read()
                if not payload:
                    return response.status, None
                try:
                    return response.status, json.loads(payload)
                except json.JSONDecodeError:
                    return response.status, payload.decode("utf-8", "replace")[:1000]
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:1000]
            raise HarnessError(f"OpenCode HTTP {exc.code} {path}: {detail}") from exc

    def health(self) -> Any:
        _, payload = self.request(
            "GET", "/global/health", timeout=3, directory_query=False
        )
        return payload

    def create_session(self, title: str) -> dict[str, Any]:
        _, payload = self.request(
            "POST",
            "/session",
            body={"directory": self.directory, "title": title},
        )
        if not isinstance(payload, dict) or not isinstance(payload.get("id"), str):
            raise HarnessError(f"session create returned no exact id: {payload!r}")
        return payload

    def prompt_async(self, session_id: str, payload: dict[str, Any]) -> int:
        status, _ = self.request(
            "POST", f"/session/{session_id}/prompt_async", body=payload
        )
        return status

    def statuses(self) -> Any:
        _, payload = self.request("GET", "/session/status", timeout=5)
        return payload

    def abort(self, session_id: str) -> tuple[int, Any]:
        return self.request("POST", f"/session/{session_id}/abort", body={})

    def event_request(self) -> urllib.request.Request:
        headers = dict(self.headers)
        headers["Accept"] = "text/event-stream"
        return urllib.request.Request(self._url("/event"), headers=headers)


class EventStream(threading.Thread):
    def __init__(self, client: OpenCodeHTTP, tracker: EventTracker) -> None:
        super().__init__(name="opencode-event-stream", daemon=True)
        self.client = client
        self.tracker = tracker
        self.stop_requested = threading.Event()

    def run(self) -> None:
        while not self.stop_requested.is_set():
            try:
                with urllib.request.urlopen(
                    self.client.event_request(), timeout=5
                ) as response:
                    for raw_line in response:
                        if self.stop_requested.is_set():
                            return
                        line = raw_line.decode("utf-8", "replace").strip()
                        if not line.startswith("data:"):
                            continue
                        try:
                            value = json.loads(line[5:].strip())
                        except json.JSONDecodeError:
                            continue
                        self.tracker.apply(value)
            except Exception as exc:
                if self.stop_requested.is_set():
                    return
                self.tracker.add_error(f"event stream reconnect: {exc}")
                time.sleep(0.2)

    def stop(self) -> None:
        self.stop_requested.set()


def opencode_db_path() -> Path:
    configured = os.environ.get("OPENCODE_DB")
    data_root = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share"))
    if configured:
        candidate = Path(configured)
        return candidate if candidate.is_absolute() else data_root / "opencode" / candidate
    return data_root / "opencode/opencode.db"


def database_snapshot() -> dict[str, Any]:
    path = opencode_db_path()
    if not path.exists():
        return {"state": "unknown", "reason": "OpenCode database unavailable"}
    try:
        uri = f"file:{urllib.parse.quote(str(path))}?mode=ro"
        connection = sqlite3.connect(uri, uri=True, timeout=3)
        try:
            row = connection.execute(
                "SELECT COALESCE(MAX(time_updated), 0), COUNT(*) FROM session"
            ).fetchone()
        finally:
            connection.close()
        stat = path.stat()
        return {
            "state": "known",
            "path": str(path),
            "maximum_session_updated_ms": int(row[0]),
            "session_count": int(row[1]),
            "database_size": stat.st_size,
            "database_mtime_ns": stat.st_mtime_ns,
            "coverage": (
                "OpenCode CLI SQLite persistence only; the separately running "
                "OpenCode Desktop 2.x service may use additional state"
            ),
        }
    except Exception as exc:
        return {"state": "unknown", "reason": str(exc), "path": str(path)}


def unrelated_database_updates(
    baseline: dict[str, Any], owned_session_ids: list[str]
) -> dict[str, Any]:
    if baseline.get("state") != "known":
        return {"state": "unknown", "reason": "baseline database snapshot unavailable"}
    path = Path(str(baseline["path"]))
    try:
        uri = f"file:{urllib.parse.quote(str(path))}?mode=ro"
        connection = sqlite3.connect(uri, uri=True, timeout=3)
        try:
            rows = connection.execute(
                "SELECT id, time_updated FROM session WHERE time_updated > ? "
                "ORDER BY time_updated, id",
                (baseline["maximum_session_updated_ms"],),
            ).fetchall()
        finally:
            connection.close()
        owned = set(owned_session_ids)
        unrelated = [(str(session_id), int(updated)) for session_id, updated in rows if session_id not in owned]
        return {
            "state": "known",
            "count": len(unrelated),
            "session_id_hashes": [sha256_text(row[0])[:16] for row in unrelated],
            "updated_ms": [row[1] for row in unrelated],
            "basis": "session rows updated after the pre-arm SQLite high-water mark",
        }
    except Exception as exc:
        return {"state": "unknown", "reason": str(exc)}


def ensure_port_free(port: int) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind(("127.0.0.1", port))
        except OSError as exc:
            raise HarnessError(f"qualification port {port} is already in use") from exc


def wait_for_health(client: OpenCodeHTTP, process: subprocess.Popen[Any]) -> Any:
    deadline = time.monotonic() + 12
    last_error = "health not attempted"
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise HarnessError(
                f"qualification OpenCode server exited early with {process.returncode}"
            )
        try:
            return client.health()
        except Exception as exc:
            last_error = str(exc)
            time.sleep(0.15)
    raise HarnessError(f"qualification OpenCode server did not become healthy: {last_error}")


def sample_status(
    client: OpenCodeHTTP,
    tracker: EventTracker,
    session_ids: list[str],
    phase: str,
) -> dict[str, Any]:
    observed_at = iso_now()
    try:
        projected = status_rows(client.statuses(), session_ids)
    except Exception as exc:
        projected = status_rows(None, session_ids)
        projected["error"] = str(exc)
    projected["at"] = observed_at
    projected["phase"] = phase
    tracker.note_status(projected["rows"], observed_at)
    return projected


def all_provider_idle(tracker: EventTracker, session_ids: list[str]) -> bool:
    sessions = tracker.snapshot()["sessions"]
    return all((sessions.get(session_id) or {}).get("idle_at") for session_id in session_ids)


def stop_process_group(process: subprocess.Popen[Any]) -> dict[str, Any]:
    result: dict[str, Any] = {"requested_at": iso_now(), "pid": process.pid}
    if process.poll() is not None:
        result.update({"action": "already_exited", "returncode": process.returncode})
        return result
    try:
        os.killpg(process.pid, signal.SIGTERM)
        result["action"] = "SIGTERM_process_group"
        process.wait(timeout=8)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        result["action"] = "SIGKILL_process_group_after_timeout"
        process.wait(timeout=3)
    result["returncode"] = process.returncode
    result["observed_at"] = iso_now()
    return result


def write_receipt(receipt: dict[str, Any], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def execute(args: argparse.Namespace) -> tuple[dict[str, Any], int]:
    directory = args.directory.resolve()
    output = args.output.resolve()
    if not directory.is_dir():
        raise HarnessError(f"directory does not exist: {directory}")
    opencode = Path(args.opencode).resolve()
    if not opencode.is_file() or not os.access(opencode, os.X_OK):
        raise HarnessError(f"OpenCode executable unavailable: {opencode}")
    version = run_capture([str(opencode), "--version"])
    if version != EXPECTED_OPENCODE_VERSION:
        raise HarnessError(
            f"expected OpenCode {EXPECTED_OPENCODE_VERSION}, observed {version}; "
            "freeze a successor apparatus rather than silently changing versions"
        )
    ensure_port_free(args.port)

    run_id = f"{int(time.time())}-{secrets.token_hex(4)}"
    server_log = output.with_suffix(".server.log")
    password = secrets.token_urlsafe(24)
    base_url = f"http://127.0.0.1:{args.port}"
    client = OpenCodeHTTP(base_url, password, directory)
    tracker = EventTracker()
    stream: EventStream | None = None
    server: subprocess.Popen[Any] | None = None
    server_log_handle: Any = None
    session_ids: list[str] = []
    samples: list[dict[str, Any]] = []
    aborts: list[dict[str, Any]] = []
    failure: str | None = None

    apparatus_before = git_identity(REPO)
    project_before = git_identity(directory)
    database_before = database_snapshot()
    receipt: dict[str, Any] = {
        "schema": "conduit-slice11-direct-opencode-fourth-turn-v1",
        "arm": "B_direct_opencode",
        "started_at": iso_now(),
        "run_id": run_id,
        "protocol": {
            "target": TARGET,
            "hold_seconds": HOLD_SECONDS,
            "output_lines": OUTPUT_LINES,
            "active_timeout_seconds": ACTIVE_TIMEOUT_SECONDS,
            "overlap_seconds": OVERLAP_SECONDS,
            "completion_timeout_seconds": COMPLETION_TIMEOUT_SECONDS,
            "post_completion_seconds": POST_COMPLETION_SECONDS,
            "cleanup_timeout_seconds": CLEANUP_TIMEOUT_SECONDS,
            "poll_seconds": POLL_SECONDS,
        },
        "apparatus": {
            "git": apparatus_before,
            "script": str(SCRIPT.relative_to(REPO)),
            "script_sha256": sha256_file(SCRIPT),
        },
        "environment": {
            "platform": platform.platform(),
            "machine": platform.machine(),
            "python": sys.version,
            "opencode_executable": str(opencode),
            "opencode_version": version,
            "model": args.model,
            "provider": split_model(args.model)[0],
            "directory": str(directory),
            "server_url": base_url,
            "status_authority_source": STATUS_SOURCE,
            "http_authority_source": HTTP_SOURCE,
        },
        "project_git_before": project_before,
        "provider_database_before": database_before,
        "sessions": [],
        "prompt_submissions": [],
        "status_samples": samples,
        "cleanup": {"aborts": aborts, "provider_records_preserved": True},
        "non_claims": [
            "provider completion is not task completion or objective acceptance",
            "process existence is not provider-active authority",
            "this arm does not measure Conduit scheduling",
            "this arm does not authorize a shipped concurrency-limit change",
        ],
    }

    try:
        server_log.parent.mkdir(parents=True, exist_ok=True)
        server_log_handle = server_log.open("wb")
        environment = dict(os.environ)
        environment["OPENCODE_SERVER_PASSWORD"] = password
        server = subprocess.Popen(
            [
                str(opencode),
                "serve",
                "--hostname",
                "127.0.0.1",
                "--port",
                str(args.port),
                "--print-logs",
                "--log-level",
                "INFO",
            ],
            cwd=directory,
            env=environment,
            stdout=server_log_handle,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        receipt["server"] = {
            "pid": server.pid,
            "process_group_id": server.pid,
            "health": wait_for_health(client, server),
            "log": str(server_log),
        }
        stream = EventStream(client, tracker)
        stream.start()

        for index in range(1, TARGET + 1):
            requested_at = iso_now()
            created = client.create_session(
                f"slice11-direct-fourth-turn-{run_id}-{index}"
            )
            observed_at = iso_now()
            session_id = created["id"]
            session_ids.append(session_id)
            receipt["sessions"].append(
                {
                    "index": index,
                    "provider_session_id": session_id,
                    "create_requested_at": requested_at,
                    "created_at": observed_at,
                    "title": f"slice11-direct-fourth-turn-{run_id}-{index}",
                }
            )
        if len(session_ids) != TARGET or len(set(session_ids)) != TARGET:
            raise HarnessError("did not create four distinct provider sessions")
        tracker.register(session_ids)
        samples.append(sample_status(client, tracker, session_ids, "pre_prompt"))

        barrier = threading.Barrier(TARGET)

        def submit(index: int, session_id: str) -> dict[str, Any]:
            token = f"DIRECT-S11-{TARGET}-{index}-{run_id}"
            objective = hold_objective(token)
            barrier.wait(timeout=10)
            requested_at = iso_now()
            try:
                status = client.prompt_async(
                    session_id, prompt_payload(args.model, objective)
                )
                return {
                    "index": index,
                    "provider_session_id": session_id,
                    "token": token,
                    "requested_at": requested_at,
                    "accepted_at": iso_now(),
                    "http_status": status,
                    "accepted": 200 <= status < 300,
                    "objective_sha256": sha256_text(objective),
                }
            except Exception as exc:
                return {
                    "index": index,
                    "provider_session_id": session_id,
                    "token": token,
                    "requested_at": requested_at,
                    "accepted_at": None,
                    "accepted": False,
                    "error": str(exc),
                    "objective_sha256": sha256_text(objective),
                }

        with concurrent.futures.ThreadPoolExecutor(max_workers=TARGET) as executor:
            futures = [
                executor.submit(submit, index, session_id)
                for index, session_id in enumerate(session_ids, start=1)
            ]
            submissions = [future.result() for future in futures]
        submissions.sort(key=lambda row: row["index"])
        receipt["prompt_submissions"] = submissions
        if sum(row["accepted"] for row in submissions) != TARGET:
            raise HarnessError("not all four direct prompts were accepted")

        maximum_active = 0
        reached_four_at: str | None = None
        acquisition_deadline = time.monotonic() + ACTIVE_TIMEOUT_SECONDS
        while time.monotonic() < acquisition_deadline:
            sample = sample_status(client, tracker, session_ids, "active_acquisition")
            samples.append(sample)
            maximum_active = max(maximum_active, sample["active_count"])
            if sample["active_count"] == TARGET and sample["unknown_count"] == 0:
                reached_four_at = sample["at"]
                break
            time.sleep(POLL_SECONDS)

        overlap_complete = False
        if reached_four_at is not None:
            overlap_deadline = time.monotonic() + OVERLAP_SECONDS
            overlap_complete = True
            while time.monotonic() < overlap_deadline:
                sample = sample_status(client, tracker, session_ids, "active_overlap")
                samples.append(sample)
                maximum_active = max(maximum_active, sample["active_count"])
                if sample["unknown_count"]:
                    overlap_complete = False
                time.sleep(POLL_SECONDS)

        completion_deadline = time.monotonic() + COMPLETION_TIMEOUT_SECONDS
        while time.monotonic() < completion_deadline and not all_provider_idle(
            tracker, session_ids
        ):
            sample = sample_status(client, tracker, session_ids, "natural_completion")
            samples.append(sample)
            maximum_active = max(maximum_active, sample["active_count"])
            time.sleep(POLL_SECONDS)
        natural_idle_observed = all_provider_idle(tracker, session_ids)

        post_completion_observed = False
        if natural_idle_observed:
            post_completion_observed = True
            post_deadline = time.monotonic() + POST_COMPLETION_SECONDS
            while time.monotonic() < post_deadline:
                sample = sample_status(
                    client, tracker, session_ids, "post_completion"
                )
                samples.append(sample)
                if any(
                    row["provider_state"] != "inactive" for row in sample["rows"]
                ):
                    post_completion_observed = False
                time.sleep(POLL_SECONDS)

        receipt["observation"] = {
            "reached_four_at": reached_four_at,
            "maximum_exact_simultaneous_provider_active": maximum_active,
            "active_acquisition_completed": reached_four_at is not None,
            "overlap_window_observed": overlap_complete,
            "natural_idle_observed": natural_idle_observed,
            "post_completion_window_observed": post_completion_observed,
        }
    except Exception as exc:
        failure = str(exc)
    finally:
        if session_ids and client:
            timeline = tracker.snapshot()["sessions"]
            for session_id in session_ids:
                if (timeline.get(session_id) or {}).get("idle_at"):
                    aborts.append(
                        {
                            "provider_session_id": session_id,
                            "action": "not_required_provider_idle_observed",
                            "at": iso_now(),
                        }
                    )
                    continue
                requested_at = iso_now()
                try:
                    status, payload = client.abort(session_id)
                    aborts.append(
                        {
                            "provider_session_id": session_id,
                            "action": "abort",
                            "requested_at": requested_at,
                            "observed_at": iso_now(),
                            "http_status": status,
                            "response": payload,
                        }
                    )
                except Exception as exc:
                    aborts.append(
                        {
                            "provider_session_id": session_id,
                            "action": "abort_failed",
                            "requested_at": requested_at,
                            "error": str(exc),
                        }
                    )

            cleanup_deadline = time.monotonic() + CLEANUP_TIMEOUT_SECONDS
            while time.monotonic() < cleanup_deadline and not all_provider_idle(
                tracker, session_ids
            ):
                samples.append(sample_status(client, tracker, session_ids, "cleanup"))
                time.sleep(POLL_SECONDS)

        receipt["timeline"] = tracker.snapshot()
        receipt["cleanup"]["all_provider_idle_observed"] = all_provider_idle(
            tracker, session_ids
        )
        if server is not None:
            receipt["cleanup"]["server_process"] = stop_process_group(server)
        if stream is not None:
            stream.stop()
            stream.join(timeout=6)
        if server_log_handle is not None:
            server_log_handle.close()

    apparatus_after = git_identity(REPO)
    project_after = git_identity(directory)
    unrelated_updates = unrelated_database_updates(database_before, session_ids)
    receipt["apparatus"]["git_after"] = apparatus_after
    receipt["project_git_after"] = project_after
    receipt["project_git_unchanged"] = project_before == project_after
    receipt["unrelated_provider_activity"] = unrelated_updates
    receipt["finished_at"] = iso_now()
    receipt["failure"] = failure

    observation = receipt.get("observation") or {}
    status_unknown = any(sample.get("unknown_count", 0) for sample in samples)
    unrelated_status = any(
        sample.get("unrelated_status_id_hashes") for sample in samples
    )
    contaminated = (
        unrelated_updates.get("state") == "known"
        and unrelated_updates.get("count", 0) > 0
    ) or unrelated_status
    cleanup_ok = bool(receipt["cleanup"].get("all_provider_idle_observed"))
    apparatus_unchanged = apparatus_before == apparatus_after
    project_unchanged = receipt["project_git_unchanged"]

    if contaminated:
        arm_result = "CONTAMINATED"
    elif failure or status_unknown:
        arm_result = "INCONCLUSIVE"
    elif observation.get("maximum_exact_simultaneous_provider_active") == TARGET:
        arm_result = "REACHED_FOUR"
    else:
        arm_result = "DID_NOT_REACH_FOUR"
    receipt["summary"] = {
        "arm_result": arm_result,
        "maximum_exact_simultaneous_provider_active": observation.get(
            "maximum_exact_simultaneous_provider_active"
        ),
        "exact_provider_session_count": len(session_ids),
        "prompt_acceptance_count": sum(
            bool(row.get("accepted")) for row in receipt["prompt_submissions"]
        ),
        "provider_state_unknown_observed": status_unknown,
        "contaminated": contaminated,
        "cleanup_observed": cleanup_ok,
        "apparatus_unchanged": apparatus_unchanged,
        "project_git_unchanged": project_unchanged,
    }
    receipt["server_log_sha256"] = (
        sha256_file(server_log) if server_log.exists() else None
    )
    write_receipt(receipt, output)
    return receipt, 0 if arm_result in {"REACHED_FOUR", "DID_NOT_REACH_FOUR"} else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--opencode", default=shutil.which("opencode") or "opencode")
    parser.add_argument("--port", type=int, default=18760)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not args.execute:
        parser.error("--execute is required for the four-session provider mutation")
    return args


def main() -> int:
    try:
        args = parse_args()
        receipt, code = execute(args)
    except HarnessError as exc:
        print(f"BLOCKED: {exc}", file=sys.stderr)
        return 2
    print(json.dumps(receipt["summary"], indent=2, sort_keys=True))
    print(f"receipt: {args.output.resolve()}")
    print(f"receipt_sha256: {sha256_file(args.output.resolve())}")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
