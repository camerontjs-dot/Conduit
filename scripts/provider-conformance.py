#!/usr/bin/env python3
"""Safely inventory installed Conduit runtimes and probe owned provider state.

The live probes use temporary homes and project directories. They never read
an existing provider session, send a prompt, or reuse account credentials.
Provider-owned sessions created by a probe are scoped to the temporary home,
then the home and every probe-owned process are removed.

    python3 scripts/provider-conformance.py inventory --output inventory.json
    python3 scripts/provider-conformance.py probe --output probe-receipt.json
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import pty
import queue
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

CAPABILITIES = (
    "external_discovery",
    "resumability",
    "adoption_connectability",
    "active_turn_cancellation",
    "release_supervision_provider_continues",
    "provider_host_stop",
    "permission_approval_awareness",
    "event_streaming",
    "process_tree_visibility",
    "diff_artifact_telemetry",
    "exact_session_thread_identity",
    "current_turn_state_visibility",
    "writer_controller_collision_visibility",
)
RESULT_STATES = ("supported", "unsupported", "unknown", "unavailable")

RUNTIMES = (
    ("opencode", "opencode", "OpenCode HTTP + SSE", ["serve", "--help"], ("starts a headless opencode server", "--port")),
    ("codex_app_server", "codex", "Codex App Server stdio", ["app-server", "--help"], ("stdio://", "app server")),
    ("claude", "claude", "Claude Code stream-json CLI", ["--help"], ("stream-json", "--resume")),
    ("grok_acp", "grok", "Grok ACP stdio", ["agent", "--help"], ("stdio", "run grok")),
    ("gemini_acp", "gemini", "Gemini ACP stdio", ["--help"], ("--acp", "--resume")),
    ("antigravity", "agy", "Antigravity stream-json CLI", ["--help"], ("stream-json", "--conversation")),
    ("shell", "zsh", "Shell fallback PTY / optional tmux", ["--version"], ("zsh",)),
)


def now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def short_output(value: str, limit: int = 180) -> str:
    return " ".join(value.split())[:limit]


def run_bounded(argv: list[str], *, env: dict[str, str] | None = None,
                cwd: Path | None = None, timeout: float = 10) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv, cwd=cwd, env=env, text=True, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout,
        check=False,
    )


def version_for(binary: str, path: str) -> str | None:
    flags = ["--version"]
    if binary == "grok":
        flags = ["--version"]
    try:
        result = run_bounded([path, *flags], timeout=8)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode != 0:
        return short_output(result.stdout) or f"version command exited {result.returncode}"
    return short_output(result.stdout) or None


def auth_signal(path: str | None, args: list[str], *, positive: tuple[str, ...],
                negative: tuple[str, ...]) -> str:
    if not path:
        return "unavailable"
    try:
        result = run_bounded([path, *args], timeout=8)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    try:
        parsed = json.loads(result.stdout)
        if isinstance(parsed, dict):
            for key in ("loggedIn", "authenticated"):
                if parsed.get(key) is True:
                    return "authenticated_status_reported"
                if parsed.get(key) is False:
                    return "not_authenticated"
    except json.JSONDecodeError:
        pass
    output = result.stdout.lower()
    if any(phrase in output for phrase in negative):
        return "not_authenticated"
    if any(phrase in output for phrase in positive):
        return "authenticated_status_reported"
    return "unknown"


def inventory() -> dict[str, Any]:
    rows: list[dict[str, Any]] = []
    for runtime, binary, interface, help_args, needles in RUNTIMES:
        path = shutil.which(binary)
        if runtime == "shell":
            path = path or ("/bin/zsh" if Path("/bin/zsh").exists() else None)
        interface_available = False
        if path:
            try:
                help_output = run_bounded([path, *help_args], timeout=8)
                lower = help_output.stdout.lower()
                interface_available = all(needle.lower() in lower for needle in needles)
            except (OSError, subprocess.TimeoutExpired):
                pass
        rows.append({
            "runtime": runtime,
            "binary": binary,
            "installed": path is not None,
            "version": version_for(binary, path) if path else None,
            "interface": interface,
            "interfaceAvailable": interface_available,
            "interfaceAuthority": f"{binary} {' '.join(help_args)} on the observed installation",
        })
    tmux = shutil.which("tmux")
    if tmux:
        try:
            tmux_version = short_output(run_bounded([tmux, "-V"]).stdout)
        except (OSError, subprocess.TimeoutExpired):
            tmux_version = None
    else:
        tmux_version = None
    binary_paths = {runtime: shutil.which(binary) for runtime, binary, _, _, _ in RUNTIMES}
    conduit_app = Path("/Applications/Conduit.app/Contents/Info.plist")
    conduit_version = None
    if conduit_app.is_file():
        try:
            with conduit_app.open("rb") as handle:
                conduit_version = plistlib.load(handle).get("CFBundleShortVersionString")
        except (OSError, plistlib.InvalidFileException):
            pass
    return {
        "observedAt": now(),
        "runtimes": rows,
        "conduitApp": {"installed": conduit_version is not None, "version": conduit_version},
        "supportingTools": {"tmux": {"installed": tmux is not None, "version": tmux_version}},
        "readiness": {
            "geminiApiKeyPresent": bool(os.environ.get("GEMINI_API_KEY")),
            "claudeAuth": auth_signal(
                binary_paths["claude"], ["auth", "status"],
                positive=("logged in", "authenticated"), negative=("not logged in", "not authenticated"),
            ),
            "grokAuth": "not inspected",
            "antigravityAuth": "not inspected",
            "opencodeProviderEntries": (
                "entries_present_unvalidated"
                if binary_paths["opencode"] and _opencode_auth_entries(binary_paths["opencode"])
                else "none_or_unavailable"
            ),
            "codexAuth": auth_signal(
                binary_paths["codex_app_server"], ["login", "status"],
                positive=("logged in", "authenticated"), negative=("not logged in", "not authenticated"),
            ),
        },
        "privacy": "Authentication commands discard account details and record only a sanitized state; no credential values or existing session content are recorded.",
    }


def _opencode_auth_entries(path: str) -> bool:
    try:
        output = run_bounded([path, "auth", "list"], timeout=8).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False
    return any(line.strip() and "no auth" not in line.lower() for line in output.splitlines()[1:])


def owned_process_tree(root_pid: int) -> list[dict[str, Any]]:
    """Return only a qualification-owned root and its observed descendants."""
    pending = [root_pid]
    seen: set[int] = set()
    rows: list[dict[str, Any]] = []
    while pending and len(seen) < 64:
        pid = pending.pop(0)
        if pid in seen:
            continue
        seen.add(pid)
        try:
            ps = run_bounded(["ps", "-p", str(pid), "-o", "pid=,ppid=,comm="], timeout=3)
        except (OSError, subprocess.TimeoutExpired):
            continue
        fields = ps.stdout.strip().split(None, 2)
        if ps.returncode != 0 or len(fields) < 2:
            continue
        row: dict[str, Any] = {"pid": int(fields[0]), "parentPid": int(fields[1])}
        if len(fields) == 3:
            row["command"] = Path(fields[2]).name
        rows.append(row)
        try:
            children = run_bounded(["pgrep", "-P", str(pid)], timeout=3)
            pending.extend(int(value.strip()) for value in children.stdout.splitlines() if value.strip().isdigit())
        except (OSError, subprocess.TimeoutExpired):
            pass
    return rows


def _process_matches(row: dict[str, Any]) -> bool:
    try:
        ps = run_bounded(["ps", "-p", str(row["pid"]), "-o", "pid=,comm="], timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return False
    fields = ps.stdout.strip().split(None, 1)
    return len(fields) == 2 and int(fields[0]) == int(row["pid"]) and Path(fields[1]).name == row.get("command")


def stop_provider_process(proc: subprocess.Popen[str], tree: list[dict[str, Any]]) -> None:
    """Stop one owned host, then any still-present descendants recorded under it."""
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=4)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=4)
    for row in reversed(tree[1:]):
        if not _process_matches(row):
            continue
        pid = int(row["pid"])
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.1)
            if _process_matches(row):
                os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


class JSONLineProcess:
    """Small request/response helper for qualification-owned stdio processes."""

    def __init__(self, argv: list[str], env: dict[str, str], cwd: Path):
        self.argv = argv
        self.proc = subprocess.Popen(
            argv, cwd=cwd, env=env, text=True, bufsize=1,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        self.messages: queue.Queue[dict[str, Any] | BaseException] = queue.Queue()
        self.seen: list[dict[str, Any]] = []
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self) -> None:
        assert self.proc.stdout is not None
        try:
            for line in self.proc.stdout:
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(value, dict):
                    self.messages.put(value)
        except BaseException as exc:  # surfaced as a bounded probe failure
            self.messages.put(exc)

    def notify(self, method: str, params: dict[str, Any] | None = None,
               *, jsonrpc: bool = False) -> None:
        message: dict[str, Any] = {"method": method, "params": params or {}}
        if jsonrpc:
            message = {"jsonrpc": "2.0", **message}
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def request(self, request_id: int, method: str, params: dict[str, Any],
                *, jsonrpc: bool = False, timeout: float = 20) -> dict[str, Any]:
        message: dict[str, Any] = {"id": request_id, "method": method, "params": params}
        if jsonrpc:
            message = {"jsonrpc": "2.0", **message}
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                value = self.messages.get(timeout=max(0.1, deadline - time.monotonic()))
            except queue.Empty:
                break
            if isinstance(value, BaseException):
                raise RuntimeError(str(value))
            self.seen.append(value)
            if value.get("id") == request_id:
                return value
        raise TimeoutError(f"{method} did not return within {timeout:g}s")

    def close_stdin(self) -> None:
        if self.proc.stdin and not self.proc.stdin.closed:
            self.proc.stdin.close()

    def exit_on_eof(self, grace: float = 3) -> bool:
        self.close_stdin()
        try:
            self.proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            return False
        return True

    def stop(self, grace: float = 3) -> bool:
        self.close_stdin()
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.proc.wait(timeout=grace)
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        return self.proc.poll() is not None


def isolated_env(root: Path, *, scrub: tuple[str, ...] = ()) -> dict[str, str]:
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(root / "home"),
        "XDG_CONFIG_HOME": str(root / "xdg-config"),
        "XDG_DATA_HOME": str(root / "xdg-data"),
        "XDG_STATE_HOME": str(root / "xdg-state"),
        "TMPDIR": str(root / "tmp"),
    }
    for key in ("home", "xdg-config", "xdg-data", "xdg-state", "tmp"):
        (root / key).mkdir(parents=True, exist_ok=True)
    for key in scrub:
        env.pop(key, None)
    return env


def codex_init(client: JSONLineProcess) -> dict[str, Any]:
    return client.request(0, "initialize", {
        "clientInfo": {"name": "conduit-slice10-qualification", "title": "Conduit Slice 10", "version": "1"},
    })


def probe_codex(path: str) -> dict[str, Any]:
    result: dict[str, Any] = {
        "provider": "codex_app_server",
        "interface": "codex app-server stdio JSON-RPC",
        "procedure": "S10-CODEX-OWNED-THREAD-001",
        "observedAt": now(),
        "actions": [],
        "identity": {},
        "cleanup": {},
    }
    with tempfile.TemporaryDirectory(prefix="conduit-s10-codex-") as raw_root:
        root = Path(raw_root)
        cwd = root / "project"
        cwd.mkdir()
        env = isolated_env(root, scrub=("OPENAI_API_KEY", "CODEX_API_KEY"))
        env["CODEX_HOME"] = str(root / "codex-home")
        Path(env["CODEX_HOME"]).mkdir()
        first: JSONLineProcess | None = None
        second: JSONLineProcess | None = None
        clients: list[JSONLineProcess] = []
        owned_pids: set[int] = set()
        thread_id: str | None = None
        try:
            first = JSONLineProcess([path, "app-server"], env, cwd)
            clients.append(first)
            initialized = codex_init(first)
            result["actions"].append({"action": "initialize", "result": "response" if "result" in initialized else "error"})
            first.notify("initialized")
            first_tree = owned_process_tree(first.proc.pid)
            result["identity"]["hostProcessTree"] = first_tree
            owned_pids.update(int(row["pid"]) for row in first_tree)
            started = first.request(1, "thread/start", {
                "cwd": str(cwd), "serviceName": "conduit-slice10-qualification",
            }, timeout=30)
            if "error" in started:
                result["actions"].append({"action": "thread/start", "result": "refused", "reason": short_output(json.dumps(started["error"]))})
            else:
                body = started.get("result") or {}
                thread_id = (body.get("thread") or {}).get("id") or body.get("threadId")
                result["actions"].append({"action": "thread/start", "result": "observed", "threadIdReturned": bool(thread_id)})
                result["identity"]["threadId"] = thread_id
                exited_on_eof = first.exit_on_eof(grace=4)
                first.stop(grace=4)
                result["actions"].append({"action": "stdio-client-release", "result": "provider_process_exited" if exited_on_eof else "process_remained"})
                first = None
                if thread_id:
                    second = JSONLineProcess([path, "app-server"], env, cwd)
                    clients.append(second)
                    codex_init(second)
                    second_tree = owned_process_tree(second.proc.pid)
                    owned_pids.update(int(row["pid"]) for row in second_tree)
                    resumed = second.request(1, "thread/resume", {"threadId": thread_id}, timeout=30)
                    result["actions"].append({
                        "action": "thread/resume",
                        "result": "observed" if "error" not in resumed else "refused",
                        "threadIdMatched": thread_id,
                        **({"reason": short_output(json.dumps(resumed["error"]))} if "error" in resumed else {}),
                    })
        except Exception as exc:  # provider failures remain receipts, not fabricated success
            result["probeError"] = short_output(f"{type(exc).__name__}: {exc}")
        finally:
            for client in clients:
                client.stop()
            result["cleanup"]["qualificationProcessesExited"] = all(client.proc.poll() is not None for client in clients)
            result["cleanup"]["ownedProcessIdsExited"] = all(
                not run_bounded(["ps", "-p", str(pid), "-o", "pid="], timeout=3).stdout.strip()
                for pid in owned_pids
            )
    result["cleanup"]["temporaryHomeRemoved"] = not Path(raw_root).exists()
    return result


def reserve_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def http_json(url: str, method: str = "GET", body: dict[str, Any] | None = None,
              timeout: float = 6) -> tuple[int, Any]:
    data = json.dumps(body).encode() if body is not None else None
    request = Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    try:
        with urlopen(request, timeout=timeout) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except HTTPError as exc:
        return exc.code, None


def wait_open_code(path: str, port: int, env: dict[str, str], cwd: Path) -> tuple[subprocess.Popen[str], str]:
    proc = subprocess.Popen(
        [path, "serve", "--hostname", "127.0.0.1", "--port", str(port), "--pure"],
        cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        text=True, start_new_session=True,
    )
    base = f"http://127.0.0.1:{port}"
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline and proc.poll() is None:
        try:
            code, _ = http_json(base + "/global/health", timeout=1)
            if code == 200:
                return proc, base
        except (URLError, TimeoutError, OSError):
            pass
        time.sleep(0.25)
    if proc.poll() is None:
        proc.terminate()
        proc.wait(timeout=4)
    raise RuntimeError("OpenCode serve did not expose /global/health within 25s")


class SSECapture:
    def __init__(self, url: str):
        self.url = url
        self.opened = threading.Event()
        self.done = threading.Event()
        self.events: list[str] = []
        self.response = None
        self.thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self.thread.start()
        self.opened.wait(timeout=8)

    def _run(self) -> None:
        try:
            self.response = urlopen(Request(self.url, headers={"Accept": "text/event-stream"}), timeout=10)
            self.opened.set()
            current_event = ""
            for raw in self.response:
                line = raw.decode("utf-8", errors="replace").strip()
                if line.startswith("event:"):
                    current_event = short_output(line[6:].strip(), 80)
                elif line.startswith("data:"):
                    payload = line[5:].strip()
                    event_name = current_event
                    try:
                        message = json.loads(payload)
                        event_name = short_output(str(message.get("type") or message.get("event") or event_name), 80)
                    except (json.JSONDecodeError, AttributeError):
                        pass
                    if event_name or payload:
                        self.events.append(event_name or "data")
                    current_event = ""
        except (URLError, OSError, ValueError):
            pass
        except Exception:
            # Closing an SSE response from the owning thread can interrupt
            # http.client's buffered read. It is expected during cleanup.
            pass
        finally:
            self.opened.set()
            self.done.set()

    def close(self) -> None:
        if self.response is not None:
            self.response.close()
        self.done.wait(timeout=2)


def probe_opencode(path: str) -> dict[str, Any]:
    result: dict[str, Any] = {
        "provider": "opencode",
        "interface": "OpenCode serve HTTP + SSE",
        "procedure": "S10-OPENCODE-OWNED-SESSION-001",
        "observedAt": now(),
        "actions": [],
        "identity": {},
        "cleanup": {},
    }
    raw_root: str | None = None
    processes: list[subprocess.Popen[str]] = []
    process_trees: dict[int, list[dict[str, Any]]] = {}
    sse_events: list[str] = []
    owned_pids: set[int] = set()
    with tempfile.TemporaryDirectory(prefix="conduit-s10-opencode-") as temp:
        raw_root = temp
        root = Path(temp)
        cwd = root / "project"
        cwd.mkdir()
        env = isolated_env(root, scrub=("OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "XAI_API_KEY", "OPENCODE_SERVER_PASSWORD"))
        session_id: str | None = None
        first: subprocess.Popen[str] | None = None
        second: subprocess.Popen[str] | None = None
        stream: SSECapture | None = None
        try:
            port = reserve_port()
            first, base = wait_open_code(path, port, env, cwd)
            processes.append(first)
            first_tree = owned_process_tree(first.pid)
            result["identity"]["firstHostProcessTree"] = first_tree
            process_trees[first.pid] = first_tree
            owned_pids.update(int(row["pid"]) for row in first_tree)
            result["actions"].append({"action": "health", "result": "observed"})
            stream = SSECapture(base + "/event")
            stream.start()
            if stream.opened.is_set():
                result["actions"].append({"action": "event-stream-connect", "result": "opened"})
            else:
                result["actions"].append({"action": "event-stream-connect", "result": "timeout"})
            code, created = http_json(base + "/session", method="POST", body={
                "directory": str(cwd), "title": "Conduit Slice 10 qualification",
            })
            session_id = (created or {}).get("id") if isinstance(created, dict) else None
            result["actions"].append({"action": "session-create", "result": "observed" if code == 200 and session_id else f"http_{code}"})
            if session_id:
                result["identity"]["sessionId"] = session_id
                list_code, sessions = http_json(base + "/session")
                discovered = list_code == 200 and isinstance(sessions, list) and any(item.get("id") == session_id for item in sessions if isinstance(item, dict))
                get_code, exact = http_json(base + f"/session/{session_id}")
                exact_ok = get_code == 200 and isinstance(exact, dict) and exact.get("id") == session_id
                result["actions"].append({"action": "session-list-discovery", "result": "observed" if discovered else f"http_{list_code}"})
                result["actions"].append({"action": "exact-session-read", "result": "observed" if exact_ok else f"http_{get_code}"})
                stream.close()
                provider_events = list(stream.events)
                sse_events.extend(provider_events)
                stream = None
                still_healthy, _ = http_json(base + "/global/health")
                result["actions"].append({"action": "observer-release-host-liveness", "result": "host_continued" if still_healthy == 200 else f"http_{still_healthy}"})
                result["actions"].append({
                    "action": "sse-provider-events",
                    "result": "observed" if provider_events else "connected_without_event",
                    "eventTypes": list(dict.fromkeys(provider_events))[:8],
                })
            if first is not None:
                stop_provider_process(first, process_trees.get(first.pid, []))
                result["actions"].append({"action": "host-stop", "result": "process_exited" if first.poll() is not None else "unknown"})
            if session_id:
                port2 = reserve_port()
                second, base2 = wait_open_code(path, port2, env, cwd)
                processes.append(second)
                second_tree = owned_process_tree(second.pid)
                result["identity"]["secondHostProcessTree"] = second_tree
                process_trees[second.pid] = second_tree
                owned_pids.update(int(row["pid"]) for row in second_tree)
                exact_code, exact_after_restart = http_json(base2 + f"/session/{session_id}")
                resumed = exact_code == 200 and isinstance(exact_after_restart, dict) and exact_after_restart.get("id") == session_id
                result["actions"].append({"action": "session-read-after-host-restart", "result": "observed" if resumed else f"http_{exact_code}"})
                delete_code, _ = http_json(base2 + f"/session/{session_id}", method="DELETE")
                if delete_code not in (200, 204):
                    try:
                        delete = run_bounded([path, "session", "delete", session_id], cwd=cwd, env=env, timeout=15)
                        delete_code = 200 if delete.returncode == 0 else delete.returncode
                    except (OSError, subprocess.TimeoutExpired):
                        pass
                verify_code, _ = http_json(base2 + f"/session/{session_id}")
                result["actions"].append({"action": "owned-session-delete", "result": "deleted" if verify_code == 404 else f"verification_http_{verify_code}", "deleteOperation": delete_code})
                stop_provider_process(second, process_trees.get(second.pid, []))
        except Exception as exc:
            result["probeError"] = short_output(f"{type(exc).__name__}: {exc}")
        finally:
            if stream is not None:
                stream.close()
            for proc in processes:
                stop_provider_process(proc, process_trees.get(proc.pid, []))
            result["cleanup"]["qualificationProcessesExited"] = all(proc.poll() is not None for proc in processes)
            result["cleanup"]["ownedProcessIdsExited"] = all(
                not run_bounded(["ps", "-p", str(pid), "-o", "pid="], timeout=3).stdout.strip()
                for pid in owned_pids
            )
            result["cleanup"]["sessionId"] = session_id
            result["cleanup"]["providerSessionDeletedAndVerified"] = any(
                row.get("action") == "owned-session-delete" and row.get("result") == "deleted"
                for row in result["actions"]
            )
            if stream is not None:
                sse_events.extend(stream.events)
            result["cleanup"]["eventTypes"] = list(dict.fromkeys(sse_events))[:8]
    result["cleanup"]["temporaryHomeRemoved"] = bool(raw_root and not Path(raw_root).exists())
    return result


def probe_grok(path: str) -> dict[str, Any]:
    result: dict[str, Any] = {
        "provider": "grok_acp",
        "interface": "Grok ACP stdio",
        "procedure": "S10-GROK-ACP-INITIALIZE-001",
        "observedAt": now(),
        "actions": [],
        "identity": {},
        "cleanup": {},
    }
    with tempfile.TemporaryDirectory(prefix="conduit-s10-grok-") as raw_root:
        root = Path(raw_root)
        cwd = root / "project"
        cwd.mkdir()
        env = isolated_env(root, scrub=("XAI_API_KEY", "GROK_API_KEY"))
        client: JSONLineProcess | None = None
        owned_pids: set[int] = set()
        try:
            client = JSONLineProcess([path, "agent", "--no-leader", "stdio"], env, cwd)
            initialized = client.request(0, "initialize", {
                "protocolVersion": 1,
                "clientInfo": {"name": "conduit-slice10-qualification", "title": "Conduit Slice 10", "version": "1"},
                "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
            }, jsonrpc=True, timeout=20)
            result["actions"].append({
                "action": "acp-initialize",
                "result": "observed" if "error" not in initialized else "refused",
                "protocolVersion": ((initialized.get("result") or {}).get("protocolVersion")),
            })
            client.notify("initialized", jsonrpc=True)
            host_tree = owned_process_tree(client.proc.pid)
            result["identity"]["hostProcessTree"] = host_tree
            owned_pids.update(int(row["pid"]) for row in host_tree)
        except Exception as exc:
            result["probeError"] = short_output(f"{type(exc).__name__}: {exc}")
        finally:
            if client is not None:
                exited_on_eof = client.exit_on_eof()
                client.stop()
                exited = client.proc.poll() is not None
                result["actions"].append({"action": "stdio-client-release", "result": "provider_process_exited_on_eof" if exited_on_eof else ("process_stopped_by_cleanup" if exited else "process_remained")})
                result["cleanup"]["qualificationProcessExited"] = client.proc.poll() is not None
                result["cleanup"]["ownedProcessIdsExited"] = all(
                    not run_bounded(["ps", "-p", str(pid), "-o", "pid="], timeout=3).stdout.strip()
                    for pid in owned_pids
                )
    result["cleanup"]["temporaryHomeRemoved"] = not Path(raw_root).exists()
    return result


def probe_shell(tmux: str) -> dict[str, Any]:
    result: dict[str, Any] = {
        "provider": "shell",
        "interface": "zsh process under an isolated tmux server",
        "procedure": "S10-SHELL-TMUX-OWNED-SESSION-001",
        "observedAt": now(),
        "actions": [],
        "identity": {},
        "cleanup": {},
    }
    with tempfile.TemporaryDirectory(prefix="conduit-s10-shell-") as raw_root:
        root = Path(raw_root)
        socket_path = root / "tmux.sock"
        session_name = "conduit-s10-" + uuid.uuid4().hex[:8]
        server = [tmux, "-S", str(socket_path), "-f", "/dev/null"]
        owned_pids: set[int] = set()
        client: subprocess.Popen[bytes] | None = None
        master_fd: int | None = None
        slave_fd: int | None = None
        tmux_server_pid: int | None = None
        try:
            created = run_bounded(
                server + ["new-session", "-d", "-s", session_name, "/bin/zsh -c 'printf CONDUIT_S10_STREAM; sleep 60'"],
                timeout=8,
            )
            if created.returncode != 0:
                raise RuntimeError("isolated tmux session could not be created")
            listed = run_bounded(server + ["list-sessions", "-F", "#{session_name}"], timeout=5)
            visible = session_name in listed.stdout.splitlines()
            pane = run_bounded(server + ["list-panes", "-t", session_name, "-F", "#{pane_pid}"], timeout=5)
            pane_pid = int(pane.stdout.strip().splitlines()[0]) if pane.returncode == 0 and pane.stdout.strip() else None
            if pane_pid:
                process_tree = owned_process_tree(pane_pid)
                result["identity"]["processTree"] = process_tree
                owned_pids.update(int(row["pid"]) for row in process_tree)
            server_pid_output = run_bounded(server + ["display-message", "-p", "-t", session_name, "#{pid}"], timeout=5)
            if server_pid_output.returncode == 0 and server_pid_output.stdout.strip().isdigit():
                tmux_server_pid = int(server_pid_output.stdout.strip())
                owned_pids.add(tmux_server_pid)
            result["identity"].update({"tmuxSession": session_name, "panePid": pane_pid, "tmuxServerPid": tmux_server_pid})
            result["actions"].append({"action": "tmux-session-discovery", "result": "observed" if visible else "missing"})

            master_fd, slave_fd = pty.openpty()
            client_env = isolated_env(root)
            client_env["TERM"] = "xterm-256color"
            client = subprocess.Popen(
                server + ["attach-session", "-t", session_name],
                stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, env=client_env,
                start_new_session=True, close_fds=True,
            )
            os.close(slave_fd)
            slave_fd = None
            client_tty: str | None = None
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and client.poll() is None:
                clients = run_bounded(server + ["list-clients", "-F", "#{client_tty} #{session_name}"], timeout=3)
                for line in clients.stdout.splitlines():
                    fields = line.split()
                    if len(fields) == 2 and fields[1] == session_name:
                        client_tty = fields[0]
                        break
                if client_tty:
                    break
                time.sleep(0.1)
            result["identity"].update({"supervisorClientPid": client.pid, "supervisorClientTty": client_tty})
            owned_pids.add(client.pid)
            result["actions"].append({"action": "supervisor-client-attach", "result": "observed" if client_tty else "not_observed"})

            detached = False
            if client_tty:
                release = run_bounded(server + ["detach-client", "-t", client_tty], timeout=5)
                if release.returncode == 0:
                    try:
                        client.wait(timeout=4)
                    except subprocess.TimeoutExpired:
                        pass
                    remaining_session = run_bounded(server + ["list-sessions", "-F", "#{session_name}"], timeout=5)
                    remaining_clients = run_bounded(server + ["list-clients", "-F", "#{session_name}"], timeout=5)
                    process_alive = any(
                        run_bounded(["ps", "-p", str(pid), "-o", "pid="], timeout=3).stdout.strip()
                        for pid in owned_pids
                        if pid not in {client.pid, tmux_server_pid}
                    )
                    detached = (
                        client.poll() is not None
                        and session_name in remaining_session.stdout.splitlines()
                        and session_name not in remaining_clients.stdout.splitlines()
                        and process_alive
                    )
            result["actions"].append({"action": "release-supervision", "result": "detached_session_continued" if detached else "not_verified"})
            alive = any(
                run_bounded(["ps", "-p", str(pid), "-o", "pid="], timeout=3).stdout.strip()
                for pid in owned_pids
                if pid not in {client.pid, tmux_server_pid}
            )
            result["actions"].append({"action": "detached-command-liveness", "result": "observed" if visible and alive else "missing"})
            captured = run_bounded(server + ["capture-pane", "-p", "-t", session_name, "-S", "-5"], timeout=5)
            stream_observed = "CONDUIT_S10_STREAM" in captured.stdout
            result["actions"].append({"action": "pty-byte-stream", "result": "observed" if stream_observed else "not_observed"})
            stopped = run_bounded(server + ["kill-session", "-t", session_name], timeout=5)
            time.sleep(0.2)
            remaining = [
                pid for pid in owned_pids
                if pid != tmux_server_pid
                and run_bounded(["ps", "-p", str(pid), "-o", "pid="], timeout=3).stdout.strip()
            ]
            result["actions"].append({"action": "owned-host-stop", "result": "processes_exited" if stopped.returncode == 0 and not remaining else "not_verified"})
        except Exception as exc:
            result["probeError"] = short_output(f"{type(exc).__name__}: {exc}")
        finally:
            if client is not None and client.poll() is None:
                try:
                    client.terminate()
                    client.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait(timeout=2)
            if slave_fd is not None:
                os.close(slave_fd)
            if master_fd is not None:
                os.close(master_fd)
            try:
                run_bounded(server + ["kill-server"], timeout=5)
            except (OSError, subprocess.TimeoutExpired):
                pass
            if socket_path.exists():
                socket_path.unlink()
            result["cleanup"]["ownedPidsExited"] = all(
                not run_bounded(["ps", "-p", str(pid), "-o", "pid="], timeout=3).stdout.strip()
                for pid in owned_pids
            )
            result["cleanup"]["supervisorClientExited"] = client is None or client.poll() is not None
            result["cleanup"]["tmuxServerExited"] = (
                tmux_server_pid is None
                or not run_bounded(["ps", "-p", str(tmux_server_pid), "-o", "pid="], timeout=3).stdout.strip()
            )
            result["cleanup"]["tmuxSocketRemovedBeforeTemporaryDirectoryRemoval"] = not socket_path.exists()
    result["cleanup"]["temporaryHomeRemoved"] = not Path(raw_root).exists()
    result["cleanup"]["tmuxSocketRemoved"] = not socket_path.exists()
    return result


def probe_all() -> dict[str, Any]:
    inv = inventory()
    by_runtime = {row["runtime"]: row for row in inv["runtimes"]}
    receipts: list[dict[str, Any]] = []
    for runtime, function in (
        ("opencode", probe_opencode),
        ("codex_app_server", probe_codex),
        ("grok_acp", probe_grok),
    ):
        row = by_runtime[runtime]
        if row["installed"]:
            try:
                receipts.append(function(shutil.which(row["binary"]) or row["binary"]))
            except Exception as exc:
                receipts.append({
                    "provider": runtime, "observedAt": now(),
                    "probeError": short_output(f"{type(exc).__name__}: {exc}"),
                })
    tmux_path = shutil.which("tmux")
    if by_runtime["shell"]["installed"] and tmux_path:
        receipts.append(probe_shell(tmux_path))
    return {
        "receiptVersion": 1,
        "observedAt": now(),
        "inventory": inv,
        "probeReceipts": receipts,
        "scope": "qualification-owned temporary homes/sessions/processes only; no prompts, unrelated sessions, or account authentication",
    }


def validate_conformance(document: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if document.get("schemaVersion") != "1.0.0":
        errors.append("schemaVersion must be 1.0.0")
    qualification = document.get("qualification")
    if not isinstance(qualification, dict):
        errors.append("qualification metadata is required")
    else:
        for field in ("repository", "issue", "sourceMain", "sourceTree", "observedAt", "claimBoundary"):
            if field not in qualification:
                errors.append(f"qualification.{field} is required")
    adapters = document.get("conduitAdapters")
    if not isinstance(adapters, dict) or not isinstance(adapters.get("liveCatalog"), dict):
        errors.append("conduitAdapters.liveCatalog is required")
    ci = document.get("hostedCI")
    if not isinstance(ci, dict) or ci.get("state") not in ("green", "failed", "blocked", "not_run", "unknown"):
        errors.append("hostedCI must preserve an explicit state")
    expected = {runtime for runtime, _, _, _, _ in RUNTIMES}
    providers = document.get("providers")
    if not isinstance(providers, list):
        return ["providers must be an array"]
    actual = [row.get("runtime") for row in providers if isinstance(row, dict)]
    if set(actual) != expected or len(actual) != len(expected):
        errors.append("providers must contain each target runtime exactly once")
    for row in providers:
        if not isinstance(row, dict):
            errors.append("provider entries must be objects")
            continue
        runtime = row.get("runtime", "<missing>")
        capabilities = row.get("capabilities")
        if not isinstance(capabilities, list):
            errors.append(f"{runtime}: capabilities must be an array")
            continue
        names = [item.get("capability") for item in capabilities if isinstance(item, dict)]
        if set(names) != set(CAPABILITIES) or len(names) != len(CAPABILITIES):
            errors.append(f"{runtime}: each capability must appear exactly once")
        for field in ("installedVersion", "interface", "adapterStatus", "authReadiness", "authority", "observedAt", "freshness", "procedure", "receipt"):
            if not isinstance(row.get(field), str) or not row[field].strip():
                errors.append(f"{runtime}: {field} is required")
        for item in capabilities:
            if not isinstance(item, dict):
                errors.append(f"{runtime}: capability entries must be objects")
                continue
            name = item.get("capability", "<missing>")
            if item.get("result") not in RESULT_STATES:
                errors.append(f"{runtime}.{name}: invalid result state")
            if not isinstance(item.get("evidenceRef"), str) or not item["evidenceRef"].strip():
                errors.append(f"{runtime}.{name}: evidenceRef is required")
            if item.get("result") in ("unknown", "unavailable") and not item.get("limitation"):
                errors.append(f"{runtime}.{name}: bounded reason required for {item.get('result')}")
    provider_by_name = {
        row.get("runtime"): {
            item.get("capability"): item.get("result")
            for item in row.get("capabilities", [])
            if isinstance(item, dict)
        }
        for row in providers
        if isinstance(row, dict)
    }
    controls = document.get("controls")
    if not isinstance(controls, list):
        errors.append("controls must be an array")
    else:
        control_types = {row.get("type") for row in controls if isinstance(row, dict)}
        if not {"positive_observation", "explicit_unsupported", "unavailable_runtime", "unknown_authority", "semantic_difference"}.issubset(control_types):
            errors.append("controls must exercise positive, unsupported, unavailable, unknown, and semantic-difference cases")
        for control in controls:
            if not isinstance(control, dict):
                errors.append("control entries must be objects")
                continue
            observed = provider_by_name.get(control.get("provider"), {}).get(control.get("capability"))
            if observed != control.get("result"):
                errors.append(f"control {control.get('id')}: result does not match the matrix cell")
            if control.get("result") in ("unknown", "unavailable") and not control.get("limitation"):
                errors.append(f"control {control.get('id')}: bounded reason required for {control.get('result')}")
            comparison = control.get("comparison")
            if control.get("type") == "semantic_difference":
                if not isinstance(comparison, dict):
                    errors.append(f"control {control.get('id')}: semantic difference requires a comparison cell")
                else:
                    compared = provider_by_name.get(comparison.get("provider"), {}).get(comparison.get("capability"))
                    if compared != comparison.get("result"):
                        errors.append(f"control {control.get('id')}: comparison result does not match its matrix cell")
                    left_observation = control.get("observation")
                    right_observation = comparison.get("observation")
                    if not isinstance(left_observation, str) or not left_observation.strip():
                        errors.append(f"control {control.get('id')}: observed semantics are required")
                    if not isinstance(right_observation, str) or not right_observation.strip():
                        errors.append(f"control {control.get('id')}: comparison semantics are required")
                    if left_observation == right_observation:
                        errors.append(f"control {control.get('id')}: provider semantic observations must differ")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    inv = sub.add_parser("inventory", help="record installed CLI versions and safe readiness signals")
    inv.add_argument("--output", required=True)
    probe = sub.add_parser("probe", help="run bounded owned-state probes for structured providers and Shell")
    probe.add_argument("--output", required=True)
    validate = sub.add_parser("validate", help="validate a versioned provider capability matrix")
    validate.add_argument("--input", required=True)
    args = parser.parse_args()
    if args.command == "validate":
        try:
            document = json.loads(Path(args.input).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            print(json.dumps({"valid": False, "error": short_output(str(exc))}))
            return 1
        errors = validate_conformance(document)
        print(json.dumps({"valid": not errors, "errors": errors}, sort_keys=True))
        return 1 if errors else 0
    document = inventory() if args.command == "inventory" else probe_all()
    target = Path(args.output)
    if target.exists():
        print(json.dumps({"output": str(target), "error": "receipt output already exists; choose a new path"}))
        return 2
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps({"output": str(target), "observedAt": document["observedAt"]}, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
