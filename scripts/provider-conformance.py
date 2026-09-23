#!/usr/bin/env python3
"""Bounded provider inventory and isolated Conduit conformance probes.

The probes create only qualification-owned state. They never list provider
sessions without an exact workspace filter, never read transcript text, and
write JSON receipts with protocol event names and exact created identities.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import pathlib
import plistlib
import queue
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_RECEIPTS = ROOT / "docs/qualification/receipts"
SCHEMA_VERSION = "1.0.0"
RESULT_STATES = {"supported", "unsupported", "unknown", "unavailable"}
RUNTIME_IDS = {
    "opencode", "codex_app_server", "claude", "grok_acp",
    "gemini_acp", "antigravity", "shell_fallback",
}
CAPABILITY_IDS = {
    "external_discovery",
    "resumable",
    "adoptable_connectable",
    "cancel_active_turn",
    "release_supervision_with_provider_continuing",
    "provider_host_stop",
    "permission_approval_awareness",
    "event_streaming",
    "process_tree_visibility",
    "diff_artifact_telemetry",
    "exact_session_thread_identity",
    "current_turn_state_visibility",
    "writer_controller_collision_visibility",
}


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def write_receipt(kind: str, payload: dict[str, Any], out_dir: pathlib.Path) -> pathlib.Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    payload["receipt_type"] = kind
    payload["schema_version"] = SCHEMA_VERSION
    payload["observed_at_utc"] = payload.get("observed_at_utc", now())
    path = out_dir / f"{kind}-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')}.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def run_capture(args: list[str], timeout: int = 8) -> dict[str, Any]:
    try:
        completed = subprocess.run(
            args,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"available": False, "reason": type(error).__name__}
    return {"available": True, "exit_code": completed.returncode, "stdout": completed.stdout[:4000]}


def readiness_capture(args: list[str], timeout: int = 8) -> tuple[int | None, str]:
    """Read transient auth status without returning provider/account text."""
    try:
        completed = subprocess.run(
            args,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, type(error).__name__
    return completed.returncode, completed.stdout + "\n" + completed.stderr


def cli_version(name: str, args: list[str]) -> dict[str, Any]:
    executable = shutil.which(name)
    if not executable:
        return {"installed": False, "version": None}
    result = run_capture([executable, *args])
    first_line = next((line.strip() for line in result.get("stdout", "").splitlines() if line.strip()), None)
    return {
        "installed": True,
        "version": first_line,
        "version_probe_exit_code": result.get("exit_code"),
        "version_probe": " ".join([name, *args]),
    }


def app_version(path: str) -> dict[str, Any]:
    info = pathlib.Path(path) / "Contents/Info.plist"
    if not info.is_file():
        return {"installed": False, "version": None}
    try:
        data = plistlib.loads(info.read_bytes())
        return {
            "installed": True,
            "version": data.get("CFBundleShortVersionString"),
            "build": data.get("CFBundleVersion"),
        }
    except Exception as error:  # noqa: BLE001 - bounded inventory result
        return {"installed": True, "version": None, "read_error": type(error).__name__}


def dotenv_key_present(path: pathlib.Path, key: str) -> bool:
    """Check only whether a non-empty key is configured; never return its value."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return False
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        candidate, value = stripped.split("=", 1)
        if candidate.strip() == key and value.strip().strip("\"'"):
            return True
    return False


def inventory(out_dir: pathlib.Path) -> pathlib.Path:
    entries: dict[str, Any] = {
        "opencode": cli_version("opencode", ["--version"]),
        "codex_app_server": cli_version("codex", ["--version"]),
        "claude": cli_version("claude", ["--version"]),
        "grok_acp": cli_version("grok", ["--version"]),
        "gemini_acp": cli_version("gemini", ["--version"]),
        "antigravity": cli_version("agy", ["--version"]),
        "shell": {"installed": True, "version": None, "interface": "direct PTY/process"},
    }
    entries["desktop_apps"] = {
        "OpenCode": app_version("/Applications/OpenCode.app"),
        "Codex": app_version("/Applications/Codex.app"),
        "Claude": app_version("/Applications/Claude.app"),
        "Grok": app_version("/Applications/Grok Bot.app"),
        "Gemini": app_version("/Applications/Gemini.app"),
        "Antigravity": app_version("/Applications/Antigravity.app"),
        "Antigravity IDE": app_version("/Applications/Antigravity IDE.app"),
    }

    codex = shutil.which("codex")
    if codex:
        exit_code, status_text = readiness_capture([codex, "login", "status"])
        normalized = status_text.lower()
        entries["codex_app_server"]["readiness"] = (
            "authenticated" if exit_code == 0 and "logged in" in normalized
            else "unavailable" if exit_code == 0 and "not logged in" in normalized
            else "unknown"
        )
        entries["codex_app_server"]["readiness_basis"] = "codex login status exit and status text; account identifiers and credential values are not recorded"
    else:
        entries["codex_app_server"]["readiness"] = "unavailable"

    claude = shutil.which("claude")
    if claude:
        output = run_capture([claude, "auth", "status", "--json"])
        try:
            status = json.loads(output.get("stdout", "{}"))
            entries["claude"]["readiness"] = "authenticated" if status.get("loggedIn") is True else "unavailable"
            entries["claude"]["readiness_basis"] = {
                "logged_in": status.get("loggedIn") is True,
                "auth_method": status.get("authMethod") if isinstance(status.get("authMethod"), str) else None,
                "provider_account_details_recorded": False,
            }
        except json.JSONDecodeError:
            entries["claude"]["readiness"] = "unknown"
    else:
        entries["claude"]["readiness"] = "unavailable"

    opencode = shutil.which("opencode")
    if opencode:
        output = run_capture([opencode, "auth", "list"])
        configured = []
        for line in output.get("stdout", "").splitlines():
            line = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", line)
            match = re.search(r"(?:●|•)\s*(.*?)\s+(?:api(?:\s+key)?|oauth)\b", line, re.IGNORECASE)
            if match:
                configured.append(match.group(1).strip())
        entries["opencode"]["configured_providers"] = sorted(set(configured))
        entries["opencode"]["readiness"] = "configured_unverified" if configured else "unknown"
    else:
        entries["opencode"]["readiness"] = "unavailable"

    shell_path = os.environ.get("SHELL") or shutil.which("zsh") or "/bin/sh"
    shell_result = run_capture([shell_path, "--version"])
    shell_lines = [line.strip() for line in shell_result.get("stdout", "").splitlines() if line.strip()]
    entries["shell"]["version"] = shell_lines[0] if shell_lines else pathlib.Path(shell_path).name
    entries["shell"]["executable"] = shell_path
    entries["shell"]["tmux"] = cli_version("tmux", ["-V"])

    gemini_dotenv = pathlib.Path.home() / ".gemini/.env"
    entries["gemini_acp"]["api_key_present"] = bool(os.environ.get("GEMINI_API_KEY")) or dotenv_key_present(
        gemini_dotenv, "GEMINI_API_KEY"
    )
    entries["gemini_acp"]["readiness"] = (
        "configured_unverified" if entries["gemini_acp"]["api_key_present"] else "unknown"
    )
    entries["gemini_acp"]["readiness_basis"] = (
        "GEMINI_API_KEY presence checked in process environment and the same ~/.gemini/.env path Conduit reads; value not recorded. ACP initialize advertised additional auth methods, but no authentication was attempted."
    )
    gemini_help = run_capture([shutil.which("gemini") or "gemini", "--help"])
    gemini_help_text = gemini_help.get("stdout", "")
    entries["gemini_acp"]["cli_interface"] = {
        "acp_flag": "--acp" in gemini_help_text,
        "resume_flag": "--resume" in gemini_help_text,
        "list_sessions_flag": "--list-sessions" in gemini_help_text,
        "delete_session_flag": "--delete-session" in gemini_help_text,
    }
    entries["gemini_acp"]["conduit_auth_method"] = "gemini-api-key"
    for key, cli in (("grok_acp", "grok"), ("antigravity", "agy")):
        executable = shutil.which(cli)
        if not executable:
            entries[key]["readiness"] = "unavailable"
            continue
        model_result = run_capture([executable, "models"])
        entries[key]["catalog_probe_exit_code"] = model_result.get("exit_code")
        entries[key]["readiness"] = "unknown"  # a model catalog is not an auth or session probe
        if key == "antigravity":
            _, help_text = readiness_capture([executable, "--help"])
            entries[key]["cli_interface"] = {
                "print_mode": "--print" in help_text,
                "stream_json": "stream-json" in help_text,
                "conversation_resume": "--conversation" in help_text,
                "session_delete_flag": "--delete-session" in help_text,
                "auth_status_subcommand_exposed": bool(re.search(r"^\s+auth\s", help_text, re.MULTILINE)),
            }
            entries[key]["readiness_basis"] = "model catalog succeeds; CLI help exposes no auth status or session deletion operation; no conversation was started"
    return write_receipt("provider-inventory-v1", {
        "state": "pass",
        "host_platform": sys.platform,
        "adapter_inventory": {
            "codex_app_server": "codex app-server; JSON-RPC stdio",
            "opencode": "one OpenCode HTTP server lease; HTTP + SSE",
            "grok_acp": "grok agent --no-leader stdio; ACP JSON-RPC",
            "gemini_acp": "gemini --acp; ACP JSON-RPC; API-key interface only",
            "claude": "claude -p --output-format stream-json",
            "antigravity": "agy -p --output-format stream-json",
            "shell": "SwiftTerm PTY / process tree",
        },
        "runtimes": entries,
        "credential_values_recorded": False,
        "session_content_read": False,
    }, out_dir)


def process_group_members(pgid: int) -> list[dict[str, Any]]:
    result = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,pgid=,comm="],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    members: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        try:
            pid, ppid, group = map(int, fields[:3])
        except ValueError:
            continue
        if group == pgid:
            process_name = pathlib.PurePath(fields[3].split()[0]).name
            members.append({"pid": pid, "ppid": ppid, "process_name": process_name})
    return sorted(members, key=lambda item: item["pid"])


def stop_group(process: subprocess.Popen[Any]) -> dict[str, Any]:
    before = process_group_members(process.pid)
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=5)
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline and process_group_members(process.pid):
        time.sleep(0.05)
    after = process_group_members(process.pid)
    return {"before": before, "exit_code": process.returncode, "remaining": after, "stopped": not after}


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def http_request(
    base: str,
    path: str,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    password: str | None = None,
    timeout: float = 5,
) -> tuple[int, Any, dict[str, str]]:
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    if password is not None:
        raw = base64.b64encode(f"opencode:{password}".encode()).decode()
        headers["Authorization"] = f"Basic {raw}"
    request = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read(2_000_000)
            try:
                parsed: Any = json.loads(payload) if payload else None
            except json.JSONDecodeError:
                parsed = {"body_bytes": len(payload)}
            return response.status, parsed, dict(response.headers.items())
    except urllib.error.HTTPError as error:
        return error.code, None, dict(error.headers.items())


class OpenCodeSSEProbe:
    """Read event names and exact-session state only; discard event text."""

    def __init__(self, response: Any, session_id: str):
        self.response = response
        self.session_id = session_id
        self.events: queue.Queue[dict[str, Any]] = queue.Queue()
        self.stop_requested = threading.Event()
        self.worker = threading.Thread(target=self._read, daemon=True)
        self.worker.start()

    def _read(self) -> None:
        data_lines: list[str] = []
        try:
            for raw in self.response:
                if self.stop_requested.is_set():
                    return
                line = raw.decode("utf-8", "replace").strip()
                if line.startswith("data:"):
                    data_lines.append(line[5:].strip())
                    continue
                if line:
                    continue
                if not data_lines:
                    continue
                raw_payload = "\n".join(data_lines)
                data_lines = []
                try:
                    event = json.loads(raw_payload)
                except json.JSONDecodeError:
                    continue
                if not isinstance(event, dict):
                    continue
                properties = event.get("properties", {})
                properties = properties if isinstance(properties, dict) else {}
                info = properties.get("info", {})
                info = info if isinstance(info, dict) else {}
                observed_session = properties.get("sessionID") or info.get("sessionID")
                event_type = event.get("type")
                if observed_session != self.session_id and event_type != "server.connected":
                    continue
                observed_status = properties.get("status", {})
                if not isinstance(observed_status, dict):
                    observed_status = {}
                message_status = info.get("status", {})
                if not isinstance(message_status, dict):
                    message_status = {}
                summary = {"type": event_type, "provider_session_id": observed_session}
                status = observed_status.get("type") or message_status.get("type")
                if isinstance(status, str):
                    summary["status"] = status
                if isinstance(info.get("id"), str):
                    summary["provider_message_id"] = info["id"]
                self.events.put(summary)
        except (OSError, ValueError, AttributeError, TypeError):
            return

    def next(self, timeout: float) -> dict[str, Any] | None:
        try:
            return self.events.get(timeout=timeout)
        except queue.Empty:
            return None

    def drain(self) -> list[dict[str, Any]]:
        drained: list[dict[str, Any]] = []
        while True:
            try:
                drained.append(self.events.get_nowait())
            except queue.Empty:
                return drained

    def wait_for(self, predicate: Any, timeout: float) -> dict[str, Any] | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            event = self.next(max(0.0, deadline - time.monotonic()))
            if event is None:
                return None
            if predicate(event):
                return event
        return None

    def close(self) -> None:
        self.stop_requested.set()
        self.response.close()
        self.worker.join(timeout=1)


def start_opencode(executable: str, workspace: pathlib.Path, password: str) -> tuple[subprocess.Popen[Any], str]:
    port = free_port()
    env = os.environ.copy()
    env["OPENCODE_SERVER_PASSWORD"] = password
    process = subprocess.Popen(
        [executable, "serve", "--hostname", "127.0.0.1", "--port", str(port)],
        cwd=workspace,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    base = f"http://127.0.0.1:{port}"
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("qualification-owned OpenCode server exited before health check")
        try:
            status, payload, _ = http_request(base, "/global/health", password=password, timeout=1)
            if status == 200 and isinstance(payload, dict) and payload.get("healthy") is True:
                return process, base
        except Exception:  # noqa: BLE001 - retry until bounded deadline
            pass
        time.sleep(0.1)
    stop_group(process)
    raise TimeoutError("qualification-owned OpenCode server did not become healthy")


def probe_opencode(out_dir: pathlib.Path) -> pathlib.Path:
    executable = shutil.which("opencode")
    if not executable:
        return write_receipt("opencode-runtime-probe-v1", {
            "state": "unavailable", "reason": "OpenCode CLI is not installed", "cleanup": "not_needed"
        }, out_dir)

    root = pathlib.Path(tempfile.mkdtemp(prefix="conduit-slice10-opencode-", dir="/private/tmp"))
    workspace = root / "workspace"
    workspace.mkdir()
    password = uuid.uuid4().hex + uuid.uuid4().hex
    process: subprocess.Popen[Any] | None = None
    stream_probe: OpenCodeSSEProbe | None = None
    session_id: str | None = None
    base: str | None = None
    turn_may_be_active = False
    payload: dict[str, Any] = {
        "state": "started",
        "procedure_id": "opencode-http-session-v1",
        "authority": "qualification-owned OpenCode server process, random loopback port, exact unique workspace filter; no global session list or transcript reads",
        "identity": {"qualification_id": str(uuid.uuid4()), "workspace_label": root.name},
        "observations": {},
        "cleanup": {},
    }
    try:
        process, base = start_opencode(executable, workspace, password)
        payload["identity"]["provider_host_pid"] = process.pid
        payload["observations"]["health"] = {"status": 200, "healthy": True}
        status, doc, _ = http_request(base, "/doc", password=password)
        paths = doc.get("paths", {}) if isinstance(doc, dict) else {}
        list_get = paths.get("/session", {}).get("get", {})
        list_filters = [p.get("name") for p in list_get.get("parameters", [])]
        required_paths = [
            "/session/{sessionID}",
            "/session/{sessionID}/diff",
            "/session/{sessionID}/prompt_async",
        ]
        if status != 200 or "directory" not in list_filters or any(path not in paths for path in required_paths):
            raise RuntimeError("installed OpenCode OpenAPI omitted the required scoped session contract")
        payload["observations"]["installed_openapi"] = {
            "status": status,
            "scoped_list_filter": "directory",
            "exact_session_read": "/session/{sessionID}",
            "session_diff": "/session/{sessionID}/diff",
            "event_stream": "/event",
        }

        status, created, _ = http_request(
            base, "/session", method="POST",
            body={"directory": str(workspace), "title": "Conduit Slice 10 qualification"},
            password=password,
        )
        if status not in (200, 201) or not isinstance(created, dict):
            raise RuntimeError(f"qualification-owned OpenCode session creation returned HTTP {status}")
        session_id = created.get("id") or created.get("sessionID")
        if not isinstance(session_id, str) or not session_id:
            raise RuntimeError("OpenCode did not return the created qualification session ID")
        payload["identity"]["provider_session_id"] = session_id
        payload["observations"]["session_created"] = {"status": status, "exact_id_returned": True}

        query = urllib.parse.urlencode({"directory": str(workspace)})
        status, sessions, _ = http_request(base, f"/session?{query}", password=password)
        session_ids = [item.get("id") for item in sessions if isinstance(item, dict)] if isinstance(sessions, list) else []
        payload["observations"]["scoped_discovery"] = {
            "status": status,
            "filter": "directory",
            "count": len(session_ids),
            "qualification_session_present": session_id in session_ids,
            "returned_ids": session_ids,
        }
        if status != 200 or session_ids != [session_id]:
            raise RuntimeError("directory-scoped OpenCode listing did not isolate the qualification session")

        status, observed, _ = http_request(
            base, f"/session/{urllib.parse.quote(session_id, safe='')}?{query}", password=password
        )
        payload["observations"]["exact_session_read"] = {
            "status": status,
            "identity_matches": isinstance(observed, dict) and observed.get("id") == session_id,
        }
        if status != 200 or not payload["observations"]["exact_session_read"]["identity_matches"]:
            raise RuntimeError("exact OpenCode session read failed identity comparison")

        # Subscribe before the one-turn prompt. This server process is
        # qualification-owned; only event names/status and exact-session IDs
        # are retained, and no tool or permission request is auto-approved.
        event_request = urllib.request.Request(base + "/event", headers={
            "Accept": "text/event-stream",
            "Authorization": "Basic " + base64.b64encode(f"opencode:{password}".encode()).decode(),
        })
        event_response = urllib.request.urlopen(event_request, timeout=4)
        stream_probe = OpenCodeSSEProbe(event_response, session_id)
        connected = stream_probe.wait_for(lambda event: event.get("type") == "server.connected", timeout=2)
        probe_prompt = "Wait before answering, then reply with exactly ready. Do not use tools or access files."
        prompt_status, _, _ = http_request(
            base,
            f"/session/{urllib.parse.quote(session_id, safe='')}/prompt_async?{query}",
            method="POST",
            body={
                "parts": [{"type": "text", "text": probe_prompt}],
                "model": {
                    "providerID": "xai",
                    "modelID": "grok-4.20-0309-non-reasoning",
                },
            },
            password=password,
            timeout=8,
        )
        accepted = 200 <= prompt_status < 300
        turn_may_be_active = accepted
        busy = stream_probe.wait_for(
            lambda event: event.get("type") == "session.status" and event.get("status") == "busy",
            timeout=12 if accepted else 0.1,
        )
        abort_status: int | None = None
        if busy is not None:
            abort_status, _, _ = http_request(
                base,
                f"/session/{urllib.parse.quote(session_id, safe='')}/abort?{query}",
                method="POST",
                body={},
                password=password,
                timeout=8,
            )
        terminal = stream_probe.wait_for(
            lambda event: (
                event.get("type") == "session.status" and event.get("status") == "idle"
            ) or event.get("status") in {"interrupted", "aborted", "completed", "error"},
            timeout=15 if accepted else 0.1,
        )
        turn_may_be_active = accepted and terminal is None
        payload["observations"]["turn_probe"] = {
            "prompt_sha256": sha256_text(probe_prompt),
            "model": "xai/grok-4.20-0309-non-reasoning",
            "prompt_http_status": prompt_status,
            "accepted": accepted,
            "active_session_status_observed": busy,
            "abort_http_status": abort_status,
            "terminal_session_or_message_event": terminal,
            "event_stream_opened": True,
            "initial_server_connected_event_observed": connected is not None,
        }
        payload["observations"]["event_stream"] = {
            "http_status": 200,
            "content_type": event_response.headers.get("content-type"),
            "events": stream_probe.drain(),
        }

        message_status, messages, _ = http_request(
            base,
            f"/session/{urllib.parse.quote(session_id, safe='')}/message?{query}",
            password=password,
        )
        message_summaries = []
        if isinstance(messages, list):
            for message in messages:
                if not isinstance(message, dict):
                    continue
                info = message.get("info", {})
                info = info if isinstance(info, dict) else {}
                if info.get("role") != "assistant":
                    continue
                status_data = info.get("status", {})
                message_summaries.append({
                    "provider_message_id": info.get("id"),
                    "status": status_data.get("type") if isinstance(status_data, dict) else None,
                })
        payload["observations"]["message_state_readback"] = {
            "status": message_status,
            "assistant_message_states": message_summaries,
            "content_read_or_recorded": False,
        }
        final_message_status = next(
            (item.get("status") for item in reversed(message_summaries) if item.get("status")),
            None,
        )
        if final_message_status in {"complete", "completed", "aborted", "interrupted", "error", "failed"}:
            turn_may_be_active = False
        elif final_message_status in {"streaming", "busy"}:
            turn_may_be_active = True

        status, diff, _ = http_request(
            base, f"/session/{urllib.parse.quote(session_id, safe='')}/diff?{query}", password=password
        )
        payload["observations"]["diff_surface"] = {
            "status": status,
            "response_type": type(diff).__name__,
            "entry_count": len(diff) if isinstance(diff, list) else None,
            "nonempty_artifact_observed": bool(diff) if isinstance(diff, list) else False,
        }

        stream_probe.close()
        stream_probe = None

        first_stop = stop_group(process)
        payload["cleanup"]["first_host_stop"] = first_stop
        process = None
        if not first_stop["stopped"]:
            raise RuntimeError("qualification-owned OpenCode server process group remained after stop")

        process, base = start_opencode(executable, workspace, password)
        payload["identity"]["resumed_host_pid"] = process.pid
        status, resumed, _ = http_request(
            base, f"/session/{urllib.parse.quote(session_id, safe='')}?{query}", password=password
        )
        payload["observations"]["exact_resume_after_host_restart"] = {
            "status": status,
            "identity_matches": isinstance(resumed, dict) and resumed.get("id") == session_id,
        }
        if status != 200 or not payload["observations"]["exact_resume_after_host_restart"]["identity_matches"]:
            raise RuntimeError("OpenCode did not resolve the same exact session after host restart")

        status, _, _ = http_request(
            base, f"/session/{urllib.parse.quote(session_id, safe='')}?{query}",
            method="DELETE", password=password,
        )
        post_status, _, _ = http_request(
            base, f"/session/{urllib.parse.quote(session_id, safe='')}?{query}", password=password
        )
        payload["cleanup"]["session_delete"] = {
            "delete_status": status,
            "post_delete_read_status": post_status,
            "verified_absent": post_status == 404,
            "provider_session_id": session_id,
        }
        if status not in (200, 204) or post_status != 404:
            raise RuntimeError("OpenCode qualification session cleanup was not verified")
    except Exception as error:  # noqa: BLE001 - preserve bounded failure and cleanup
        payload["state"] = "inconclusive"
        payload["failure"] = {"type": type(error).__name__, "message": str(error)[:300]}
    else:
        payload["state"] = "pass"
    finally:
        if stream_probe is not None:
            stream_probe.close()
        if turn_may_be_active and session_id is not None and base is not None:
            query = urllib.parse.urlencode({"directory": str(workspace)})
            abort_status, _, _ = http_request(
                base,
                f"/session/{urllib.parse.quote(session_id, safe='')}/abort?{query}",
                method="POST",
                body={},
                password=password,
            )
            payload["cleanup"]["recovery_abort"] = {
                "status": abort_status,
                "provider_session_id": session_id,
            }
        if session_id is not None and base is not None and "session_delete" not in payload["cleanup"]:
            query = urllib.parse.urlencode({"directory": str(workspace)})
            delete_status, _, _ = http_request(
                base, f"/session/{urllib.parse.quote(session_id, safe='')}?{query}",
                method="DELETE", password=password,
            )
            verify_status, _, _ = http_request(
                base, f"/session/{urllib.parse.quote(session_id, safe='')}?{query}", password=password
            )
            payload["cleanup"]["recovery_session_delete"] = {
                "delete_status": delete_status,
                "post_delete_read_status": verify_status,
                "verified_absent": verify_status == 404,
                "provider_session_id": session_id,
            }
        if process is not None:
            payload["cleanup"]["final_host_stop"] = stop_group(process)
        shutil.rmtree(root, ignore_errors=True)
        payload["cleanup"]["qualification_workspace_removed"] = not root.exists()
        if session_id is not None:
            payload["cleanup"].setdefault("provider_session_id", session_id)
    return write_receipt("opencode-runtime-probe-v1", payload, out_dir)


class ACPProcess:
    def __init__(self, executable: str, cwd: pathlib.Path, argv: list[str] | None = None):
        self.cwd = cwd
        self.process = subprocess.Popen(
            [executable, *(argv or ["agent", "--no-leader", "stdio"])],
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        self.next_id = 1
        self.events: list[dict[str, Any]] = []

    def _send(self, message: dict[str, Any]) -> None:
        if self.process.stdin is None:
            raise RuntimeError("ACP process stdin is unavailable")
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def _read(self, timeout: float) -> dict[str, Any] | None:
        if self.process.stdout is None:
            raise RuntimeError("ACP process stdout is unavailable")
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            return None
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("ACP process closed its protocol stream")
        return json.loads(line)

    @staticmethod
    def event_summary(message: dict[str, Any]) -> dict[str, Any]:
        params = message.get("params", {})
        update = params.get("update", {}) if isinstance(params, dict) else {}
        summary: dict[str, Any] = {"method": message.get("method")}
        if isinstance(params, dict) and isinstance(params.get("sessionId"), str):
            summary["provider_session_id"] = params["sessionId"]
        if isinstance(update, dict):
            for key in ("sessionUpdate", "stopReason", "status"):
                value = update.get(key)
                if isinstance(value, str):
                    summary[key] = value
        return summary

    def notification(self, method: str, params: dict[str, Any]) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method: str, params: dict[str, Any], timeout: float = 20) -> Any:
        request_id = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self._read(max(0.0, deadline - time.monotonic()))
            if message is None:
                break
            if "method" in message:
                summary = self.event_summary(message)
                if str(summary.get("method", "")).startswith("session/"):
                    self.events.append(summary)
                continue
            if message.get("id") == request_id:
                if "error" in message:
                    error = message["error"]
                    raise RuntimeError(f"ACP {method} failed: {error.get('message', 'RPC error')}")
                return message.get("result")
        raise TimeoutError(f"ACP {method} timed out")

    def prompt_and_cancel(self, session_id: str, text: str, delay: float = 0.08) -> Any:
        request_id = self.next_id
        self.next_id += 1
        self._send({
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "session/prompt",
            "params": {
                "sessionId": session_id,
                "prompt": [{"type": "text", "text": text}],
            },
        })
        time.sleep(delay)
        self.notification("session/cancel", {"sessionId": session_id})
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            message = self._read(max(0.0, deadline - time.monotonic()))
            if message is None:
                break
            if "method" in message:
                summary = self.event_summary(message)
                if str(summary.get("method", "")).startswith("session/"):
                    self.events.append(summary)
                continue
            if message.get("id") == request_id:
                if "error" in message:
                    error = message["error"]
                    raise RuntimeError(f"ACP session/prompt failed: {error.get('message', 'RPC error')}")
                return message.get("result")
        raise TimeoutError("ACP session/prompt timed out after session/cancel notification")


def acp_initialize(client: ACPProcess) -> dict[str, Any]:
    result = client.request("initialize", {
        "protocolVersion": 1,
        "clientInfo": {"name": "conduit-slice10", "version": "1"},
        "clientCapabilities": {"terminal": True},
    })
    client.notification("initialized", {})
    return result if isinstance(result, dict) else {}


def probe_grok(out_dir: pathlib.Path) -> pathlib.Path:
    executable = shutil.which("grok")
    if not executable:
        return write_receipt("grok-acp-probe-v1", {
            "state": "unavailable", "reason": "Grok CLI is not installed", "cleanup": "not_needed"
        }, out_dir)
    root = pathlib.Path(tempfile.mkdtemp(prefix="conduit-slice10-grok-", dir="/private/tmp"))
    workspace = root / "workspace"
    workspace.mkdir()
    client: ACPProcess | None = None
    session_id: str | None = None
    payload: dict[str, Any] = {
        "state": "started",
        "procedure_id": "grok-acp-session-v1",
        "authority": "Grok ACP stdio launched with --no-leader in a unique empty cwd; exact session/load and exact-session delete only",
        "identity": {"qualification_id": str(uuid.uuid4()), "workspace_label": root.name},
        "observations": {},
        "events": [],
        "cleanup": {},
    }
    try:
        client = ACPProcess(executable, workspace)
        payload["identity"]["provider_host_pid"] = client.process.pid
        initialization = acp_initialize(client)
        payload["observations"]["initialize"] = {
            "ok": True,
            "protocol_version": initialization.get("protocolVersion"),
            "capability_keys": sorted(initialization.get("agentCapabilities", {}).keys()) if isinstance(initialization.get("agentCapabilities"), dict) else [],
            "authentication_methods_advertised": bool(initialization.get("authMethods")),
        }
        created = client.request("session/new", {"cwd": str(workspace), "mcpServers": []}, timeout=20)
        session_id = created.get("sessionId") if isinstance(created, dict) else None
        if not isinstance(session_id, str) or not session_id:
            raise RuntimeError("Grok ACP did not return the qualification session ID")
        payload["identity"]["provider_session_id"] = session_id
        payload["observations"]["session_new"] = {"provider_session_id_returned": True}

        prompt = "Wait before replying. Do not use tools or access files. Then reply with exactly ready."
        payload["observations"]["prompt_sha256"] = sha256_text(prompt)
        try:
            result = client.prompt_and_cancel(session_id, prompt)
            stop_reason = result.get("stopReason") if isinstance(result, dict) else None
            payload["observations"]["turn_probe"] = {
                "cancel_notification_sent": True,
                "prompt_completed": True,
                "stop_reason": stop_reason,
                "provider_cancel_observed": stop_reason == "cancelled",
                "provider_turn_id": result.get("turnId") if isinstance(result, dict) else None,
            }
        except Exception as error:  # noqa: BLE001 - preserve provider refusal
            payload["observations"]["turn_probe"] = {
                "cancel_notification_sent": True,
                "state": "inconclusive",
                "error_type": type(error).__name__,
                "message": str(error)[:240],
            }
        payload["events"] = client.events

        first_stop = stop_group(client.process)
        payload["cleanup"]["first_host_stop"] = first_stop
        client = None
        if not first_stop["stopped"]:
            raise RuntimeError("qualification-owned Grok ACP process group remained after stop")

        client = ACPProcess(executable, workspace)
        payload["identity"]["resumed_host_pid"] = client.process.pid
        acp_initialize(client)
        loaded = client.request("session/load", {
            "sessionId": session_id,
            "cwd": str(workspace),
            "mcpServers": [],
        }, timeout=20)
        echoed_id = loaded.get("sessionId") if isinstance(loaded, dict) else None
        loaded_id = echoed_id if isinstance(echoed_id, str) else session_id
        payload["observations"]["exact_resume_after_host_restart"] = {
            "provider_session_id": loaded_id,
            "identity_matches": loaded_id == session_id,
            "provider_echoed_identity": isinstance(echoed_id, str),
            "identity_basis": "session/load was accepted for the exact requested sessionId; ACP response may omit an echoed ID",
        }
        if loaded_id != session_id:
            raise RuntimeError("Grok ACP did not load the same exact provider session")
    except Exception as error:  # noqa: BLE001 - preserve bounded failure and cleanup
        payload["state"] = "inconclusive"
        payload["failure"] = {"type": type(error).__name__, "message": str(error)[:300]}
    else:
        payload["state"] = "pass"
    finally:
        if client is not None:
            payload["events"] = client.events
            payload["cleanup"]["final_host_stop"] = stop_group(client.process)
        if session_id is not None:
            deletion = run_capture([executable, "sessions", "delete", session_id], timeout=15)
            deleted = deletion.get("exit_code") == 0
            verify_client: ACPProcess | None = None
            load_refused = False
            if deleted:
                try:
                    verify_client = ACPProcess(executable, workspace)
                    acp_initialize(verify_client)
                    verify_client.request("session/load", {
                        "sessionId": session_id,
                        "cwd": str(workspace),
                        "mcpServers": [],
                    }, timeout=12)
                except Exception as error:  # noqa: BLE001 - classify exact-resource refusal only
                    load_refused = isinstance(error, RuntimeError) and "not found" in str(error).lower()
                finally:
                    if verify_client is not None:
                        verify_stop = stop_group(verify_client.process)
                        payload["cleanup"]["delete_verification_host_stop"] = verify_stop
            payload["cleanup"]["provider_session_delete"] = {
                "provider_session_id": session_id,
                "delete_exit_code": deletion.get("exit_code"),
                "exact_load_refused_after_delete": load_refused,
                "verified_absent": deleted and load_refused,
                "verification_limit": "The exact ACP load must report not found; auth, protocol, or host failures are not counted as absence.",
            }
        shutil.rmtree(root, ignore_errors=True)
        payload["cleanup"]["qualification_workspace_removed"] = not root.exists()
        if session_id is not None:
            payload["cleanup"].setdefault("provider_session_id", session_id)
    return write_receipt("grok-acp-probe-v1", payload, out_dir)


def probe_gemini(out_dir: pathlib.Path) -> pathlib.Path:
    executable = shutil.which("gemini")
    if not executable:
        return write_receipt("gemini-acp-probe-v1", {
            "state": "unavailable", "reason": "Gemini CLI is not installed", "cleanup": "not_needed"
        }, out_dir)
    root = pathlib.Path(tempfile.mkdtemp(prefix="conduit-slice10-gemini-", dir="/private/tmp"))
    client: ACPProcess | None = None
    payload: dict[str, Any] = {
        "state": "started",
        "procedure_id": "gemini-acp-initialize-only-v1",
        "authority": "Gemini CLI ACP stdio in a unique empty cwd; initialize only; no authenticate, session, prompt, account, or operator-session operations",
        "identity": {"qualification_id": str(uuid.uuid4()), "workspace_label": root.name},
        "observations": {},
        "cleanup": {},
    }
    try:
        client = ACPProcess(executable, root, ["--acp"])
        payload["identity"]["provider_host_pid"] = client.process.pid
        initialized = acp_initialize(client)
        auth_methods = initialized.get("authMethods", [])
        payload["observations"]["initialize"] = {
            "ok": True,
            "protocol_version": initialized.get("protocolVersion"),
            "capability_keys": sorted(initialized.get("agentCapabilities", {}).keys())
            if isinstance(initialized.get("agentCapabilities"), dict) else [],
            "authentication_method_count": len(auth_methods) if isinstance(auth_methods, list) else None,
            "authentication_method_ids": sorted(
                str(item.get("id")) for item in auth_methods
                if isinstance(item, dict) and isinstance(item.get("id"), str)
            ) if isinstance(auth_methods, list) else [],
            "session_or_prompt_started": False,
        }
        payload["state"] = "pass"
    except Exception as error:  # noqa: BLE001 - preserve unavailable protocol boundary
        payload["state"] = "inconclusive"
        payload["failure"] = {"type": type(error).__name__, "message": str(error)[:240]}
    finally:
        if client is not None:
            payload["cleanup"]["host_stop"] = stop_group(client.process)
        shutil.rmtree(root, ignore_errors=True)
        payload["cleanup"]["qualification_workspace_removed"] = not root.exists()
    return write_receipt("gemini-acp-probe-v1", payload, out_dir)


def probe_shell(out_dir: pathlib.Path) -> pathlib.Path:
    shell_path = os.environ.get("SHELL") or shutil.which("zsh") or "/bin/sh"
    root = pathlib.Path(tempfile.mkdtemp(prefix="conduit-slice10-shell-", dir="/private/tmp"))
    master_fd, slave_fd = os.openpty()
    process: subprocess.Popen[Any] | None = None
    payload: dict[str, Any] = {
        "state": "started",
        "procedure_id": "shell-process-tree-v1",
        "authority": "Qualification-owned direct PTY and OS process group; no provider session or operator shell reused",
        "identity": {"qualification_id": str(uuid.uuid4()), "workspace_label": root.name},
        "observations": {},
        "cleanup": {},
    }
    try:
        process = subprocess.Popen(
            [shell_path, "-f", "-c", "sleep 60 & wait"],
            cwd=root,
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
            start_new_session=True,
            close_fds=True,
        )
        os.close(slave_fd)
        slave_fd = -1
        payload["identity"]["shell_pid"] = process.pid
        payload["identity"]["process_group_id"] = process.pid
        time.sleep(0.2)
        members = process_group_members(process.pid)
        payload["observations"]["owned_process_group_visible"] = {
            "process_group_id": process.pid,
            "member_pids": [member["pid"] for member in members],
            "process_names": sorted({member["process_name"] for member in members}),
            "contains_shell_pid": any(member["pid"] == process.pid for member in members),
            "contains_child": any(member["ppid"] == process.pid for member in members),
        }
        stopped = stop_group(process)
        payload["cleanup"]["owned_process_group_stop"] = stopped
        process = None
        if not stopped["stopped"]:
            raise RuntimeError("qualification-owned shell process group remained after stop")
        payload["state"] = "pass"
    except Exception as error:  # noqa: BLE001 - preserve bounded failure and cleanup
        payload["state"] = "inconclusive"
        payload["failure"] = {"type": type(error).__name__, "message": str(error)[:240]}
    finally:
        if process is not None:
            payload["cleanup"]["final_process_group_stop"] = stop_group(process)
        if slave_fd >= 0:
            os.close(slave_fd)
        os.close(master_fd)
        shutil.rmtree(root, ignore_errors=True)
        payload["cleanup"]["qualification_workspace_removed"] = not root.exists()
    return write_receipt("shell-process-probe-v1", payload, out_dir)


class CodexAppServer:
    def __init__(self, executable: str, cwd: pathlib.Path):
        self.cwd = cwd
        self.process = subprocess.Popen(
            [executable, "app-server"],
            cwd=cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
        self.next_id = 1
        self.events: list[dict[str, Any]] = []

    def _send(self, message: dict[str, Any]) -> None:
        if self.process.stdin is None:
            raise RuntimeError("Codex App Server stdin is unavailable")
        self.process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def _read(self, timeout: float) -> dict[str, Any] | None:
        if self.process.stdout is None:
            raise RuntimeError("Codex App Server stdout is unavailable")
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            return None
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError("Codex App Server closed its protocol stream")
        return json.loads(line)

    def request(self, method: str, params: dict[str, Any], timeout: float = 20) -> Any:
        request_id = self.next_id
        self.next_id += 1
        self._send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self._read(max(0.0, deadline - time.monotonic()))
            if message is None:
                break
            if "method" in message:
                summary = self._event_summary(message)
                event_method = str(summary.get("method", ""))
                if event_method.startswith(("thread/", "turn/", "item/")) or event_method == "error":
                    self.events.append(summary)
                continue
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(f"Codex App Server {method} failed: {message['error'].get('message', 'RPC error')}")
                return message.get("result")
        raise TimeoutError(f"Codex App Server {method} timed out")

    def notification(self, method: str, params: dict[str, Any] | None = None) -> None:
        self._send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    @staticmethod
    def _event_summary(message: dict[str, Any]) -> dict[str, Any]:
        params = message.get("params", {})
        turn = params.get("turn", {}) if isinstance(params, dict) else {}
        item = params.get("item", {}) if isinstance(params, dict) else {}
        summary = {"method": message.get("method")}
        thread = params.get("thread", {}) if isinstance(params, dict) else {}
        if isinstance(params, dict) and isinstance(params.get("threadId"), str):
            summary["provider_thread_id"] = params["threadId"]
        elif isinstance(thread, dict) and isinstance(thread.get("id"), str):
            summary["provider_thread_id"] = thread["id"]
        if isinstance(turn, dict):
            if isinstance(turn.get("id"), str):
                summary["provider_turn_id"] = turn["id"]
            if isinstance(turn.get("status"), str):
                summary["turn_status"] = turn["status"]
        if isinstance(item, dict) and isinstance(item.get("type"), str):
            summary["item_type"] = item["type"]
        return summary

    def wait_for_event(self, method: str, timeout: float = 10) -> dict[str, Any] | None:
        for event in reversed(self.events):
            if event.get("method") == method:
                return event
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            message = self._read(max(0.0, deadline - time.monotonic()))
            if message is None:
                return None
            if "method" not in message:
                continue
            summary = self._event_summary(message)
            event_method = str(summary.get("method", ""))
            if event_method.startswith(("thread/", "turn/", "item/")) or event_method == "error":
                self.events.append(summary)
            if summary.get("method") == method:
                return summary
        return None

    def initialize(self) -> dict[str, Any]:
        result = self.request("initialize", {"clientInfo": {"name": "conduit-slice10", "title": "Conduit Slice 10", "version": "1"}})
        self.notification("initialized")
        return result if isinstance(result, dict) else {}


def stop_codex(server: CodexAppServer) -> dict[str, Any]:
    return stop_group(server.process)


def probe_codex(out_dir: pathlib.Path) -> pathlib.Path:
    executable = shutil.which("codex")
    if not executable:
        return write_receipt("codex-app-server-probe-v1", {
            "state": "unavailable", "reason": "Codex CLI is not installed", "cleanup": "not_needed"
        }, out_dir)
    root = pathlib.Path(tempfile.mkdtemp(prefix="conduit-slice10-codex-", dir="/private/tmp"))
    workspace = root / "workspace"
    workspace.mkdir()
    thread_id: str | None = None
    server: CodexAppServer | None = None
    payload: dict[str, Any] = {
        "state": "started",
        "procedure_id": "codex-app-server-isolated-thread-v1",
        "authority": "authenticated Codex App Server stdio; unique empty cwd; thread/list uses exact cwd filter; only newly created thread is resumed/archived",
        "identity": {"qualification_id": str(uuid.uuid4()), "workspace_label": root.name},
        "observations": {},
        "events": [],
        "cleanup": {},
    }
    try:
        server = CodexAppServer(executable, workspace)
        payload["identity"]["provider_host_pid"] = server.process.pid
        initialized = server.initialize()
        payload["observations"]["initialize"] = {
            "ok": True,
            "server_info": initialized.get("serverInfo"),
            "capability_keys": sorted(initialized.get("capabilities", {}).keys()) if isinstance(initialized.get("capabilities"), dict) else [],
        }
        started = server.request("thread/start", {"cwd": str(workspace), "serviceName": "conduit-slice10"})
        thread = started.get("thread", {}) if isinstance(started, dict) else {}
        thread_id = thread.get("id") if isinstance(thread, dict) else None
        if not isinstance(thread_id, str) or not thread_id:
            raise RuntimeError("Codex App Server did not return a provider thread ID")
        payload["identity"]["provider_thread_id"] = thread_id
        payload["observations"]["thread_start"] = {"provider_thread_id_returned": True}

        pre_turn = server.request("thread/list", {"cwd": str(workspace), "limit": 20})
        pre_turn_rows = pre_turn.get("data", []) if isinstance(pre_turn, dict) else []
        pre_turn_ids = [row.get("id") for row in pre_turn_rows if isinstance(row, dict)]
        payload["observations"]["pre_turn_discovery"] = {
            "filter": "cwd",
            "count": len(pre_turn_ids),
            "thread_present_before_first_turn": thread_id in pre_turn_ids,
            "note": "the exact-cwd listing did not return this thread before its first turn; persistence timing remains provider-specific",
        }

        prompt = "For this qualification-owned session, count internally to 1000 before replying with only the word ready. Do not use tools or access files."
        payload["observations"]["prompt_sha256"] = sha256_text(prompt)
        try:
            started_turn = server.request("turn/start", {
                "threadId": thread_id,
                "input": [{"type": "text", "text": prompt}],
            }, timeout=30)
            turn = started_turn.get("turn", {}) if isinstance(started_turn, dict) else {}
            turn_id = turn.get("id") if isinstance(turn, dict) else None
            if isinstance(turn_id, str):
                payload["identity"]["provider_turn_id"] = turn_id
            payload["observations"]["turn_start"] = {
                "acknowledged": True,
                "provider_turn_id_returned": isinstance(turn_id, str),
                "initial_status": turn.get("status") if isinstance(turn, dict) else None,
            }
            started_event = server.wait_for_event("turn/started", timeout=2)
            payload["observations"]["turn_started_event"] = started_event or {"observed": False}
            if not isinstance(turn_id, str) or not turn_id:
                raise RuntimeError("Codex turn/start did not return the exact provider turn ID")
            interrupt_result = server.request(
                "turn/interrupt",
                {"threadId": thread_id, "turnId": turn_id},
                timeout=10,
            )
            payload["observations"]["turn_interrupt"] = {
                "acknowledged": True,
                "provider_thread_id": thread_id,
                "provider_turn_id": turn_id,
                "result_type": type(interrupt_result).__name__,
            }
            completed = server.wait_for_event("turn/completed", timeout=20)
            payload["observations"]["turn_completion_after_interrupt"] = completed or {"observed": False}
        except Exception as error:  # noqa: BLE001 - preserve live provider refusal
            payload["observations"]["turn_probe"] = {"state": "inconclusive", "error_type": type(error).__name__, "message": str(error)[:240]}
        listed = server.request("thread/list", {"cwd": str(workspace), "limit": 20})
        rows = listed.get("data", []) if isinstance(listed, dict) else []
        ids = [row.get("id") for row in rows if isinstance(row, dict)]
        payload["observations"]["scoped_discovery"] = {
            "filter": "cwd",
            "count": len(ids),
            "qualification_thread_present": thread_id in ids,
            "returned_ids": ids,
            "status": "observed" if thread_id in ids else "unknown",
            "note": "an empty exact-cwd result is preserved as unknown; no account-wide listing was attempted",
        }
        payload["events"] = server.events

        first_stop = stop_codex(server)
        payload["cleanup"]["first_host_stop"] = first_stop
        server = None
        if not first_stop["stopped"]:
            raise RuntimeError("qualification-owned Codex App Server process group remained after stop")

        server = CodexAppServer(executable, workspace)
        payload["identity"]["resumed_host_pid"] = server.process.pid
        server.initialize()
        resumed = server.request("thread/resume", {"threadId": thread_id})
        resumed_thread = resumed.get("thread", {}) if isinstance(resumed, dict) else {}
        resumed_id = resumed_thread.get("id") if isinstance(resumed_thread, dict) else None
        payload["observations"]["exact_resume_after_host_restart"] = {
            "provider_thread_id": resumed_id,
            "identity_matches": resumed_id == thread_id,
        }
        if resumed_id != thread_id:
            raise RuntimeError("Codex App Server did not resume the same exact provider thread")

        archive = server.request("thread/archive", {"threadId": thread_id})
        archived_list = server.request("thread/list", {"cwd": str(workspace), "limit": 20, "archived": True})
        archived_rows = archived_list.get("data", []) if isinstance(archived_list, dict) else []
        archived_ids = [row.get("id") for row in archived_rows if isinstance(row, dict)]
        archive_result = {
            "acknowledged": True,
            "provider_thread_id": thread_id,
            "result_type": type(archive).__name__,
            "verified_in_archived_cwd_scoped_list": thread_id in archived_ids,
            "deletion_claimed": False,
        }
        try:
            server.request("thread/resume", {"threadId": thread_id})
            archive_result["resume_refused_as_archived"] = False
        except RuntimeError as error:
            archive_result["resume_refused_as_archived"] = "archived" in str(error).lower()
        archive_result["verified_archived"] = (
            thread_id in archived_ids or archive_result["resume_refused_as_archived"] is True
        )
        payload["cleanup"]["provider_thread_archive"] = archive_result
        if not archive_result["verified_archived"]:
            raise RuntimeError("Codex App Server archive could not be verified by scoped list or exact resume refusal")
    except Exception as error:  # noqa: BLE001 - preserve bounded failure and cleanup
        payload["state"] = "inconclusive"
        payload["failure"] = {"type": type(error).__name__, "message": str(error)[:300]}
    else:
        payload["state"] = "pass"
    finally:
        if server is not None:
            payload["events"] = server.events
            payload["cleanup"]["final_host_stop"] = stop_codex(server)
        shutil.rmtree(root, ignore_errors=True)
        payload["cleanup"]["qualification_workspace_removed"] = not root.exists()
        if thread_id is not None:
            payload["cleanup"].setdefault("provider_thread_id", thread_id)
    return write_receipt("codex-app-server-probe-v1", payload, out_dir)


def validate_receipt(path: pathlib.Path) -> tuple[bool, list[str]]:
    errors: list[str] = []
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return False, [f"cannot read JSON receipt: {type(error).__name__}"]
    if document.get("schema_version") != SCHEMA_VERSION:
        errors.append("schema_version must be 1.0.0")
    if not isinstance(document.get("receipt_type"), str):
        errors.append("receipt_type is required")
    if not isinstance(document.get("observed_at_utc"), str):
        errors.append("observed_at_utc is required")
    state = document.get("state")
    if state not in {"started", "inconclusive", "unavailable", "pass", "fail"}:
        errors.append("state must be an explicit bounded result")
    if document.get("credential_values_recorded") is True or document.get("session_content_read") is True:
        errors.append("receipts must not contain credential values or session content")
    return not errors, errors


def validate_matrix(path: pathlib.Path) -> tuple[bool, list[str]]:
    errors: list[str] = []
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        return False, [f"cannot read conformance JSON: {type(error).__name__}"]
    if document.get("schema_version") != SCHEMA_VERSION:
        errors.append("schema_version must be 1.0.0")
    if document.get("credential_values_recorded") is not False:
        errors.append("credential_values_recorded must be false")
    if document.get("session_content_read") is not False:
        errors.append("session_content_read must be false")
    runtimes = document.get("runtimes")
    if not isinstance(runtimes, dict) or set(runtimes) != RUNTIME_IDS:
        errors.append("runtimes must contain exactly the seven Slice 10 runtime ids")
        runtimes = runtimes if isinstance(runtimes, dict) else {}
    evidence = document.get("evidence_catalog")
    if not isinstance(evidence, dict):
        errors.append("evidence_catalog must be an object")
        evidence = {}
    for evidence_id, entry in evidence.items():
        artifact = entry.get("artifact") if isinstance(entry, dict) else None
        if not isinstance(artifact, dict) or not artifact.get("path"):
            continue
        artifact_path = ROOT / artifact["path"]
        expected_sha = artifact.get("sha256")
        if not isinstance(expected_sha, str) or not expected_sha:
            errors.append(f"evidence_catalog.{evidence_id}.artifact.sha256 is required for local artifacts")
            continue
        try:
            actual_sha = hashlib.sha256(artifact_path.read_bytes()).hexdigest()
        except OSError:
            errors.append(f"evidence_catalog.{evidence_id}.artifact.path is missing or unreadable")
            continue
        if actual_sha != expected_sha:
            errors.append(f"evidence_catalog.{evidence_id}.artifact.sha256 does not match local bytes")
    if document.get("inventory_ref") not in evidence:
        errors.append("inventory_ref must resolve in evidence_catalog")
    for control_id, control in (document.get("controls") or {}).items():
        if not isinstance(control, dict):
            errors.append(f"controls.{control_id} must be an object")
            continue
        refs = control.get("evidence_refs")
        if not isinstance(refs, list) or not refs or any(ref not in evidence for ref in refs):
            errors.append(f"controls.{control_id}.evidence_refs must resolve")
    for index, item in enumerate(document.get("preserved_runs", [])):
        if not isinstance(item, dict) or item.get("evidence_ref") not in evidence:
            errors.append(f"preserved_runs[{index}].evidence_ref must resolve")
    for runtime_id, runtime in runtimes.items():
        if not isinstance(runtime, dict):
            errors.append(f"{runtime_id} must be an object")
            continue
        capabilities = runtime.get("capabilities")
        if not isinstance(capabilities, dict) or set(capabilities) != CAPABILITY_IDS:
            errors.append(f"{runtime_id} must report all 13 capability ids")
            continue
        for capability_id, capability in capabilities.items():
            if not isinstance(capability, dict):
                errors.append(f"{runtime_id}.{capability_id} must be an object")
                continue
            for layer in ("provider", "conduit"):
                outcome = capability.get(layer)
                if not isinstance(outcome, dict):
                    errors.append(f"{runtime_id}.{capability_id}.{layer} is required")
                    continue
                if outcome.get("status") not in RESULT_STATES:
                    errors.append(f"{runtime_id}.{capability_id}.{layer}.status is invalid")
                if not isinstance(outcome.get("note"), str) or not outcome.get("note", "").strip():
                    errors.append(f"{runtime_id}.{capability_id}.{layer}.note is required")
                refs = outcome.get("evidence_refs")
                if not isinstance(refs, list) or any(ref not in evidence for ref in refs):
                    errors.append(f"{runtime_id}.{capability_id}.{layer}.evidence_refs must resolve")
                if outcome.get("status") in {"supported", "unsupported", "unavailable"} and not refs:
                    errors.append(f"{runtime_id}.{capability_id}.{layer} requires direct or bounded evidence")
    return not errors, errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("inventory", "opencode", "codex", "grok", "gemini", "shell", "validate", "validate-matrix"))
    parser.add_argument("--out-dir", type=pathlib.Path, default=DEFAULT_RECEIPTS)
    parser.add_argument("--receipt", type=pathlib.Path)
    parser.add_argument("--matrix", type=pathlib.Path)
    args = parser.parse_args()
    if args.command == "inventory":
        result = inventory(args.out_dir)
    elif args.command == "opencode":
        result = probe_opencode(args.out_dir)
    elif args.command == "codex":
        result = probe_codex(args.out_dir)
    elif args.command == "grok":
        result = probe_grok(args.out_dir)
    elif args.command == "gemini":
        result = probe_gemini(args.out_dir)
    elif args.command == "shell":
        result = probe_shell(args.out_dir)
    elif args.command == "validate-matrix":
        if args.matrix is None:
            parser.error("validate-matrix requires --matrix PATH")
        valid, errors = validate_matrix(args.matrix)
        print(json.dumps({"valid": valid, "errors": errors}, indent=2))
        return 0 if valid else 1
    elif args.command == "validate":
        if args.receipt is None:
            parser.error("validate requires --receipt PATH")
        valid, errors = validate_receipt(args.receipt)
        print(json.dumps({"valid": valid, "errors": errors}, indent=2))
        return 0 if valid else 1
    valid, errors = validate_receipt(result)
    print(json.dumps({"receipt": str(result.relative_to(ROOT)) if result.is_relative_to(ROOT) else result.name, "valid": valid, "errors": errors}, indent=2))
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
