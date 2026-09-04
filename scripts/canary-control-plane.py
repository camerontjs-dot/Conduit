#!/usr/bin/env python3
"""Conduit control-plane write canary.

Executable form of the smallest write-enabled lane set in
docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md:

    L3.3  initial objective delivery      -> discriminates contract §7 A vs B
    L2.5  session event cursor            -> in-place revision visibility
    L3.7  interrupt semantics             -> request vs observed cancellation
    L4.2  explicit leave/detach
    L4.3  reconnect / reconcile

Design constraints, in the project's own terms:

  * This script NEVER enables Session API writes. The operator owns that
    switch. Preflight reports the gate state and stops.
  * The worker is deterministic and filesystem-inert. Shell runs echo/sleep;
    a structured adapter (Codex, OpenCode) is told to emit a token, count, and
    emit a closing token, with tool use refused. No project mutation either way.
  * Evidence is always the PROVIDER's own record - tmux scrollback, Codex
    rollout logs, OpenCode's SQLite store - never Conduit's event log, so the
    canary can tell 'the work happened' apart from 'Conduit saw it happen'.
  * A response is not completion. An interrupt acknowledgement is not observed
    cancellation. Quiet output is not done. The receipt records what was seen
    and labels everything it could not establish.
  * Every result carries an evidence class: OBSERVED / INFERRED / HYPOTHESIS /
    UNKNOWN (test plan §1.2).

Usage:
    scripts/canary-control-plane.py                 # preflight, read-only
    scripts/canary-control-plane.py --run           # execute the write canary
    scripts/canary-control-plane.py --run --agent Codex
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone
from pathlib import Path

HOST = "127.0.0.1"
PORT = 8750
BASE = f"http://{HOST}:{PORT}"
TOKEN_PATH = Path.home() / ".conduit" / "session-api-token"
CLIENT_NAME = "conduit-canary"
CLIENT_VERSION = "1"
REPO = Path(__file__).resolve().parent.parent
RECEIPT_DIR = REPO / "outputs" / "local-acceptance" / "canary"

# Long enough that the turn is reliably active when the interrupt lands,
# short enough that a stuck run self-clears.
BUSY_SECONDS = 25
READY_TIMEOUT = 60
POLL_INTERVAL = 2.0
# A model can spend tens of seconds on context before its first token.
STRUCTURED_OUTPUT_TIMEOUT = 120


class CanaryError(RuntimeError):
    """A refusal or an unrecoverable transport failure."""


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


# ---------------------------------------------------------------- transport


class SessionAPI:
    def __init__(self, token: str) -> None:
        self.token = token
        self._id = 0
        self.calls: list[dict] = []

    def _rpc(self, method: str, params: dict | None = None) -> dict:
        self._id += 1
        payload = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            payload["params"] = params
        body = json.dumps(payload).encode()
        req = urllib.request.Request(
            f"{BASE}/mcp",
            data=body,
            method="POST",
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "Content-Length": str(len(body)),
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read().decode()
        except urllib.error.HTTPError as exc:
            raise CanaryError(
                f"{method} -> HTTP {exc.code} {exc.read().decode()[:200]}"
            ) from exc
        except urllib.error.URLError as exc:
            raise CanaryError(
                f"{method} -> no listener at {BASE}: {exc.reason}. "
                "Is Conduit running with the Session API enabled?"
            ) from exc
        parsed = json.loads(raw)
        self.calls.append({"at": now(), "method": method, "params": params})
        if "error" in parsed:
            raise CanaryError(f"{method} -> {parsed['error']}")
        return parsed.get("result", {})

    def initialize(self) -> dict:
        # Writes fail closed until an initialize is seen: caller identity on
        # this listener is the clientInfo from the most recent initialize.
        return self._rpc(
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": CLIENT_NAME, "version": CLIENT_VERSION},
            },
        )

    def tools(self) -> list[dict]:
        return self._rpc("tools/list").get("tools", [])

    def call(self, name: str, **arguments) -> dict:
        result = self._rpc("tools/call", {"name": name, "arguments": arguments})
        return _unwrap(result)


def _unwrap(result: dict) -> dict:
    """MCP wraps tool output in content blocks; recover the JSON payload."""
    if isinstance(result.get("structuredContent"), dict):
        return result["structuredContent"]
    for block in result.get("content", []) or []:
        if block.get("type") == "text":
            text = block.get("text", "")
            try:
                return json.loads(text)
            except json.JSONDecodeError:
                return {"_text": text}
    return result


# ---------------------------------------------------------------- preflight


def _run(cmd: list[str], cwd: Path | None = None) -> str:
    try:
        out = subprocess.run(
            cmd, cwd=cwd, capture_output=True, text=True, timeout=30
        )
        return (out.stdout or out.stderr).strip()
    except Exception as exc:  # noqa: BLE001 - provenance is best-effort
        return f"<unavailable: {exc}>"


def pty_scrollback(tmux_session: str) -> str | None:
    """Ground truth for a tmux-backed task.

    `capture-pane -p` alone returns only the visible region, which is empty
    once the shell redraws. `-S -` is required to reach scrollback, and
    scrollback is the only durable proof that a command actually ran. This
    deliberately bypasses Conduit so the canary can tell 'the work happened'
    apart from 'Conduit observed the work happening'.
    """
    if not tmux_session:
        return None
    probe = subprocess.run(
        ["tmux", "has-session", "-t", tmux_session],
        capture_output=True, text=True,
    )
    if probe.returncode != 0:
        return None
    out = subprocess.run(
        ["tmux", "capture-pane", "-p", "-S", "-", "-t", tmux_session],
        capture_output=True, text=True,
    )
    return out.stdout if out.returncode == 0 else None


def codex_assistant_text(since: float) -> str:
    """Assistant-authored text from Codex's own rollout logs.

    Independent of Conduit: these are the provider's records. Only
    `role == "assistant"` payloads count. The prompt itself contains the
    marker, so any match in a user/developer message proves the instruction
    was recorded, never that the model produced output.
    """
    root = Path.home() / ".codex" / "sessions"
    if not root.exists():
        return ""
    chunks: list[str] = []
    for path in root.rglob("rollout-*.jsonl"):
        try:
            if path.stat().st_mtime < since - 5:
                continue
            for line in path.read_text(errors="replace").splitlines():
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    continue
                payload = event.get("payload") or {}
                if payload.get("role") != "assistant":
                    continue
                for block in payload.get("content") or []:
                    text = block.get("text")
                    if text:
                        chunks.append(text)
        except OSError:
            continue
    return "\n".join(chunks)


def opencode_assistant_text(since: float) -> str:
    """Assistant-authored text from OpenCode's own SQLite store."""
    db = Path.home() / ".local" / "share" / "opencode" / "opencode.db"
    if not db.exists():
        return ""
    # Read-only URI so a live OpenCode process is never disturbed.
    query = """
        SELECT p.data FROM part p JOIN message m ON p.message_id = m.id
        WHERE p.time_created >= ?
          AND json_extract(m.data, '$.role') = 'assistant'
    """
    out = subprocess.run(
        ["sqlite3", f"file:{db}?mode=ro", query.replace("?", str(int(since * 1000) - 5000))],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        return ""
    chunks = []
    for line in out.stdout.splitlines():
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        if data.get("type") == "text" and data.get("text"):
            chunks.append(data["text"])
    return "\n".join(chunks)


def ground_truth(agent: str, task_id: str, since: float) -> tuple[str, str]:
    """Provider-native evidence that output was really produced.

    Returns (source_label, text). Never consults Conduit's own event log:
    the whole point is to be able to tell 'the work happened' apart from
    'Conduit observed the work happening'.
    """
    name = agent.strip().lower()
    if name == "codex":
        return "codex-rollout", codex_assistant_text(since)
    if name == "opencode":
        return "opencode-db", opencode_assistant_text(since)
    session = find_tmux_session(task_id)
    return f"tmux:{session}", (pty_scrollback(session) or "")


def find_tmux_session(task_id: str) -> str | None:
    """Recover the tmux session name from the durable task-session log."""
    log = Path.home() / ".conduit" / "task-sessions" / f"{task_id}.jsonl"
    if not log.exists():
        return None
    name = None
    for line in log.read_text().splitlines():
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get("kind")
        if isinstance(kind, dict):
            changed = (kind.get("operationalStateChanged") or {}).get("_0") or {}
            prov = (changed.get("runtimeProvisioning") or {})
            if isinstance(prov, dict) and prov.get("tmuxSessionName"):
                name = prov["tmuxSessionName"]
    return name


def pin_object() -> dict:
    """Test plan §1.1 - pin the exact object under test."""
    app = Path("/Applications/Conduit.app/Contents/MacOS/Conduit")
    installed = _run(["shasum", "-a", "256", str(app)]).split()[0] if app.exists() else None
    return {
        "recorded_at": now(),
        "repo_head": _run(["git", "rev-parse", "HEAD"], REPO),
        "repo_branch": _run(["git", "rev-parse", "--abbrev-ref", "HEAD"], REPO),
        "repo_dirty": bool(_run(["git", "status", "--short"], REPO)),
        "installed_app_sha256": installed,
        "installed_app_present": app.exists(),
        "macos": platform.mac_ver()[0] or platform.platform(),
        "arch": platform.machine(),
        "tmux": _run(["tmux", "-V"]),
        "shell": os.environ.get("SHELL", "<unset>"),
        "running_from": "installed app" if app.exists() else "unknown",
    }


def read_gate() -> bool | None:
    config = Path.home() / ".conduit" / "config.json"
    if not config.exists():
        return None
    try:
        return bool(json.loads(config.read_text()).get("enableSessionAPIWrites"))
    except Exception:  # noqa: BLE001
        return None


def health() -> tuple[bool, str]:
    try:
        with urllib.request.urlopen(f"{BASE}/healthz", timeout=5) as resp:
            return resp.status == 200, f"HTTP {resp.status}"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def load_token() -> str:
    if not TOKEN_PATH.exists():
        raise CanaryError(
            f"No token at {TOKEN_PATH}. Enable the Session API in Conduit Settings."
        )
    mode = oct(TOKEN_PATH.stat().st_mode & 0o777)
    if mode != "0o600":
        print(f"  ! token mode is {mode}, expected 0o600 (PR #8 hardening)")
    return TOKEN_PATH.read_text().strip()


def preflight(verbose: bool = True) -> dict:
    pin = pin_object()
    ok, detail = health()
    gate = read_gate()
    surface: dict = {}
    if ok:
        api = SessionAPI(load_token())
        api.initialize()
        tools = api.tools()
        surface = {
            "tool_count": len(tools),
            "read_tools": [
                t["name"] for t in tools
                if (t.get("annotations") or {}).get("readOnlyHint")
            ],
            "write_tools": [
                t["name"] for t in tools
                if not (t.get("annotations") or {}).get("readOnlyHint")
            ],
            "projects": [
                p.get("slug") for p in (api.call("conduit_list_projects").get("projects") or [])
            ],
            "adapters": [
                a.get("name") for a in (api.call("conduit_list_adapters").get("adapters") or [])
            ],
        }
    if verbose:
        print("=== Object under test (plan §1.1) ===")
        for key, value in pin.items():
            print(f"  {key}: {value}")
        print(f"\n=== Listener ===\n  {BASE}/healthz: {'UP' if ok else 'DOWN'} ({detail})")
        print(f"  enableSessionAPIWrites: {gate}")
        if surface:
            print(f"\n=== Surface ===\n  tools: {surface['tool_count']}")
            print(f"  read:  {', '.join(surface['read_tools'])}")
            print(f"  write: {', '.join(surface['write_tools'])}")
            print(f"  projects: {len(surface['projects'])}")
            print(f"  adapters: {', '.join(a for a in surface['adapters'] if a)}")
    return {"pin": pin, "listener_up": ok, "listener_detail": detail,
            "writes_enabled": gate, "surface": surface}


# ------------------------------------------------------------------- canary


def canary(project: str, agent: str) -> dict:
    run_id = uuid.uuid4().hex[:8]
    marker = f"CONDUIT_CANARY_{run_id}"
    structured = agent.strip().lower() in {"codex", "opencode"}

    if structured:
        # An LLM worker needs an instruction, not a shell line. The turn has to
        # last long enough to interrupt, so the count follows the first token.
        # Tool use is refused explicitly: OpenCode's profile runs with
        # permissionMode `acceptEdits`, and this canary must not touch a repo.
        # Echo safety comes from ROLE here, not from string shape - only
        # assistant-authored provider records are searched, so the marker
        # appearing in the recorded user prompt can never count as output.
        objective = (
            f"Output the exact token {marker}_START on its own line. "
            f"Then count from 1 to 400, one number per line. "
            f"Then output the exact token {marker}_END on its own line. "
            "Do not use any tools. Do not read, write, or edit any files. "
            "Do not run any commands. Do not ask questions. Output only the "
            "token, the numbers, and the closing token."
        )
    else:
        # Filesystem-inert: stdout only, bounded, self-clearing.
        #
        # The marker is assembled from a shell variable so the ECHOED COMMAND
        # LINE never contains the literal marker string. A tmux pane holds both
        # the command echo and its output; without this split, searching
        # scrollback for `<marker>_END` matches the echoed `echo <marker>_END`
        # even when the command was cancelled before running. Expansion happens
        # only on execution, so a literal hit is proof of output.
        objective = (
            f'C={marker}; echo "${{C}}_START"; '
            f'sleep {BUSY_SECONDS}; echo "${{C}}_END"'
        )

    started_at = time.time()

    api = SessionAPI(load_token())
    api.initialize()
    lanes: list[dict] = []
    task_id = None

    def lane(test_id, expected, observed, result, evidence, negative="", follow_up=""):
        entry = {
            "test_id": test_id, "at": now(), "expected": expected,
            "observed": observed, "result": result, "evidence": evidence,
            "negative_findings": negative, "follow_up": follow_up,
        }
        lanes.append(entry)
        print(f"  [{result:12}] {test_id}: {observed}")
        return entry

    print(f"\n=== Canary {run_id} — agent={agent} project={project} ===")

    # ---- L3.3 initial objective delivery -----------------------------------
    created = api.call(
        "conduit_create_task",
        agent=agent, project_slug=project, objective=objective,
        idempotency_key=f"canary-{run_id}",
    )
    task_id = created.get("taskSessionID") or created.get("task_session_id")
    delivered = created.get("objective_delivered")
    if not task_id:
        raise CanaryError(f"create_task returned no task id: {created}")
    lane(
        "L3.3-create",
        "task created; objective_delivered reported honestly",
        f"task={task_id} objective_delivered={delivered}",
        "OBSERVED",
        json.dumps(created)[:600],
        negative="Task creation is not objective delivery and not work.",
    )

    # ---- readiness ---------------------------------------------------------
    deadline = time.time() + READY_TIMEOUT
    ready = False
    status: dict = {}
    while time.time() < deadline:
        status = api.call("conduit_session_status", taskSessionID=task_id)
        session = status.get("session") or status
        if session.get("ready") is True:
            ready = True
            break
        time.sleep(POLL_INTERVAL)
    lane(
        "L3.3-ready",
        f"runtime reaches ready within {READY_TIMEOUT}s",
        f"ready={ready} after {'timeout' if not ready else 'poll'}",
        "OBSERVED" if ready else "FAIL",
        json.dumps(status)[:600],
        negative="Local runtime ready is not provider auth or quota eligibility.",
    )

    # ---- L3.3 discriminator: A (durable intent) vs B (two-phase) -----------
    # Contract §7 turns on whether an undelivered objective EVER arrives
    # without a second call.
    #
    # The marker must NOT be looked for in the event JSON. Conduit records the
    # objective as a `user_prompt` event at create time, so the marker is
    # present there whether or not the shell ever ran it. Matching that is a
    # false positive, and it is exactly the "prompt delivered == provider
    # acknowledged" equivalence contract §3 forbids. Ground truth is the PTY
    # scrollback.
    time.sleep(POLL_INTERVAL * 2)
    gt_source, gt_text = ground_truth(agent, task_id, started_at)
    executed = f"{marker}_START" in gt_text
    if structured and not executed:
        # A model may take longer than a shell to emit its first token.
        for _ in range(int(STRUCTURED_OUTPUT_TIMEOUT / POLL_INTERVAL)):
            time.sleep(POLL_INTERVAL)
            gt_source, gt_text = ground_truth(agent, task_id, started_at)
            if f"{marker}_START" in gt_text:
                executed = True
                break
    verdict = "UNKNOWN"
    if executed and not delivered:
        verdict = "candidate-A-observed"
        detail = "objective REACHED THE SHELL without a second call (durable intent)"
    elif executed and delivered:
        verdict = "candidate-A-consistent"
        detail = "objective delivered at create and executed"
    elif not executed and not delivered:
        verdict = "candidate-B-required"
        detail = "objective never reached the shell; an explicit send is required"
    else:
        verdict = "contradiction"
        detail = "create claimed delivery but the shell never ran it"
    lane(
        "L3.3-delivery-semantics",
        "contract §7 Candidate A vs B is discriminated by PTY ground truth, not by Conduit's own record",
        f"{verdict}: {detail}",
        "OBSERVED" if verdict != "contradiction" else "FAIL",
        f"objective_delivered={delivered}; ground_truth={gt_source}; "
        f"marker_in_provider_output={executed}",
        negative="Marker presence in a recorded prompt proves recording, not execution.",
        follow_up="Feed this into PR #6 §7 before the contract is accepted.",
    )

    # Recover the turn if delivery genuinely did not happen.
    if verdict == "candidate-B-required" and ready:
        sent = api.call("conduit_send_prompt", taskSessionID=task_id, text=objective)
        lane(
            "L3.3-recovery",
            "explicit second send delivers the objective",
            f"send_prompt accepted={bool(sent)}",
            "OBSERVED",
            json.dumps(sent)[:400],
            negative="Prompt delivered is not provider acknowledged.",
        )

    # ---- L2.5 cursor / in-place revision -----------------------------------
    # Known bug: polling only from next_cursor can miss an in-place revision
    # under the same event id. Hold the cursor and watch content_digest.
    digests: dict[str, set] = {}
    cursor = None
    for _ in range(6):
        page = api.call(
            "conduit_session_events", taskSessionID=task_id, limit=50,
            **({"cursor": cursor} if cursor else {}),
        )
        for event in page.get("events", []) or []:
            eid = event.get("event_id")
            digest = event.get("content_digest")
            if eid and digest:
                digests.setdefault(eid, set()).add(digest)
        time.sleep(POLL_INTERVAL)
    revised = {k: sorted(v) for k, v in digests.items() if len(v) > 1}
    lane(
        "L2.5-cursor-revision",
        "an in-place revision is visible as a changed content_digest on a stable event_id",
        f"events_tracked={len(digests)} revised_in_place={len(revised)}",
        "OBSERVED",
        json.dumps(revised)[:400] if revised else "no in-place revision seen this run",
        negative="Absence of a revision here does not prove revisions cannot occur.",
        follow_up="Repeat against a structured adapter (Codex); Shell may never revise.",
    )

    # ---- L3.7 interrupt semantics -----------------------------------------
    # Interrupting a turn that has not begun producing tests nothing. A shell
    # echoes within milliseconds; a model can spend tens of seconds loading
    # context before its first token. Wait for real output first, so L3.7
    # measures cancellation rather than a race with startup.
    if structured:
        for _ in range(int(STRUCTURED_OUTPUT_TIMEOUT / POLL_INTERVAL)):
            _, probe = ground_truth(agent, task_id, started_at)
            if f"{marker}_START" in probe:
                break
            time.sleep(POLL_INTERVAL)

    pre = api.call("conduit_session_events", taskSessionID=task_id, limit=10)
    pre_turn = (pre.get("turn") or {}).get("state")
    ack = api.call("conduit_interrupt", taskSessionID=task_id)
    time.sleep(POLL_INTERVAL * 2)
    post = api.call("conduit_session_events", taskSessionID=task_id, limit=10)
    post_turn = (post.get("turn") or {}).get("state")
    claimed = ack.get("interrupted")
    # Ground truth: _START ran, _END did not => the sleep was really cancelled.
    _, gt_after = ground_truth(agent, task_id, started_at)
    really_cancelled = (
        f"{marker}_START" in gt_after and f"{marker}_END" not in gt_after
    )
    lane(
        "L3.7-interrupt",
        "acknowledgement is recorded as a request, never as observed cancellation",
        f"turn {pre_turn} -> ack.interrupted={claimed} -> turn {post_turn}; "
        f"pty_actually_cancelled={really_cancelled}",
        "OBSERVED",
        json.dumps({"ack": ack, "pre": pre_turn, "post": post_turn,
                    "pty_cancelled": really_cancelled})[:500],
        negative="interrupted=true is Conduit's request record, not provider cancellation.",
        follow_up="Compare the PTY truth against what the control plane could see.",
    )

    # ---- observability gap -------------------------------------------------
    # The defect that matters for orchestration: work really happened at the
    # PTY and the control plane could not see it. An orchestrating agent polls
    # the control plane, not tmux, so anything invisible here is invisible to
    # the orchestrator forever.
    observation = post.get("observation") or {}
    provider_events = [
        e for e in (post.get("events") or [])
        if e.get("authority") not in {"conduitRecorded", None}
        or e.get("source") not in {"session", "conduit", "chatgpt", None}
    ]
    pty_produced_output = f"{marker}_START" in gt_after
    blind = pty_produced_output and observation.get("last_output_state") in {"none", None}
    lane(
        "OBS-1-control-plane-visibility",
        "output the runtime really produced is visible through the control plane",
        f"pty_output={pty_produced_output} "
        f"last_output_state={observation.get('last_output_state')} "
        f"checkpoint={observation.get('checkpoint')} "
        f"provider_authored_events={len(provider_events)}"
        + ("  ** CONTROL PLANE BLIND **" if blind else ""),
        "FAIL" if blind else "OBSERVED",
        json.dumps(observation)[:400],
        negative="Conduit's honesty fields are correct here; the gap is observability, not truthfulness.",
        follow_up="An orchestrator cannot close a loop it cannot observe. This gates issue #4 Phase B.",
    )

    # ---- OBS-2: false completion ------------------------------------------
    # The inverse of OBS-1 and the more dangerous direction. OBS-1 asks
    # "did we miss real work?". This asks "did we claim work that never
    # happened?". A turn reported completed while the provider authored
    # nothing is contract §3's forbidden equivalence -- process/turn exit
    # treated as task success -- and an orchestrator acting on it would
    # advance a plan on work that does not exist.
    turn_state = (post.get("turn") or {}).get("state")
    checkpoint = observation.get("checkpoint")
    claims_done = turn_state == "completed" or checkpoint == "structured_completed"
    produced_nothing = (
        not pty_produced_output
        and observation.get("last_output_state") in {"none", None}
    )
    false_completion = claims_done and produced_nothing
    lane(
        "OBS-2-false-completion",
        "a completed turn is never reported for a provider that authored no output",
        f"turn={turn_state} checkpoint={checkpoint} "
        f"last_output_state={observation.get('last_output_state')} "
        f"provider_output={pty_produced_output}"
        + ("  ** COMPLETION CLAIMED WITH NO OUTPUT **" if false_completion else ""),
        "FAIL" if false_completion else "OBSERVED",
        json.dumps({"turn": post.get("turn"), "observation": observation})[:600],
        negative="Provider error termination must not be indistinguishable from success.",
        follow_up="Check the provider's own log for an error at this timestamp before reading it as success.",
    )

    # ---- L4.2 leave / detach ----------------------------------------------
    closed = api.call("conduit_close_session", taskSessionID=task_id)
    after_close = api.call("conduit_session_status", taskSessionID=task_id)
    lane(
        "L4.2-leave",
        "close detaches the runtime and preserves task history",
        f"close={json.dumps(closed)[:120]} lifecycle="
        f"{(after_close.get('session') or after_close).get('lifecycle')}",
        "OBSERVED",
        json.dumps(after_close)[:500],
        negative="Detach is not deletion; history must survive.",
    )

    # ---- L4.3 reconnect ----------------------------------------------------
    # Only attempt reconcile when Conduit still reports the task as
    # recoverable. On a structured backend close_session stops the adapter, so
    # a post-close reconcile cannot succeed AND raises a modal the operator has
    # to dismiss by hand. Re-triggering that on every run would be rude to the
    # machine and adds no evidence beyond the first observation.
    closed_status = after_close.get("session") or after_close
    recoverable = closed_status.get("recoverable")
    if recoverable is False:
        lane(
            "L4.3-reconnect",
            "same task identity recovered AND a live runtime is restored",
            f"not attempted: Conduit reports recoverable=false after close "
            f"(backend={closed_status.get('backend')})",
            "OBSERVED",
            json.dumps(closed_status)[:400],
            negative="close_session detaches durable tmux but STOPS a structured "
                     "adapter; a structured task is not recoverable after close.",
            follow_up="Calling reconcile here returns 'No identity-compatible "
                      "runtime' AND raises a native modal on the operator's Mac.",
        )
        try:
            api.call("conduit_close_session", taskSessionID=task_id)
        except CanaryError:
            pass
        return {"run_id": run_id, "task_id": task_id, "agent": agent,
                "project": project, "marker": marker, "lanes": lanes,
                "call_log": api.calls}

    reconciled = api.call("conduit_reconcile_task", taskSessionID=task_id)
    after_recon = api.call("conduit_session_status", taskSessionID=task_id)
    same_task = (after_recon.get("taskSessionID") or task_id) == task_id
    # Identity preservation alone is not recovery. A reconcile that returns an
    # error recovered nothing, and on a structured backend it also raises a
    # blocking modal on the operator's Mac -- a GUI side effect with no
    # representation in the MCP result an unattended orchestrator can act on.
    recon_error = reconciled.get("error")
    recovered = bool(reconciled.get("reconciled")) and not recon_error
    lane(
        "L4.3-reconnect",
        "same task identity recovered AND a live runtime is restored",
        f"same_task_id={same_task} recovered={recovered} lifecycle="
        f"{(after_recon.get('session') or after_recon).get('lifecycle')}"
        + (f"  ** {recon_error} **" if recon_error else ""),
        "OBSERVED" if (same_task and recovered) else "FAIL",
        json.dumps(reconciled)[:400],
        negative="close_session detaches durable tmux but STOPS a structured adapter; "
                 "after that, reconcile has no runtime to adopt.",
        follow_up="A failed reconcile also raises a native modal. Unattended "
                  "orchestration would strand dialogs on the operator's Mac.",
    )

    # ---- cleanup -----------------------------------------------------------
    try:
        api.call("conduit_close_session", taskSessionID=task_id)
    except CanaryError:
        pass

    return {"run_id": run_id, "task_id": task_id, "agent": agent,
            "project": project, "marker": marker, "lanes": lanes,
            "call_log": api.calls}


# ------------------------------------------------------------------ receipt


def write_receipt(pre: dict, result: dict | None, note: str = "") -> Path:
    RECEIPT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    run_id = result["run_id"] if result else "preflight"
    path = RECEIPT_DIR / f"{stamp}-canary-{run_id}.md"
    pin = pre["pin"]
    lines = [
        f"# Control-plane canary receipt — {run_id}",
        "",
        "Plan provenance: `docs/LOCAL_ACCEPTANCE_AND_CONTROL_PLANE_TEST_PLAN.md`",
        "(L3.3, L2.5, L3.7, L4.2, L4.3). Receipt shape: plan §1.3.",
        "",
        "## Object under test",
        "",
        "```",
        *[f"{k}: {v}" for k, v in pin.items()],
        f"listener: {BASE} up={pre['listener_up']} ({pre['listener_detail']})",
        f"enableSessionAPIWrites: {pre['writes_enabled']}",
        "```",
        "",
    ]
    if note:
        lines += ["## Outcome", "", note, ""]
    if result:
        lines += ["## Lanes", ""]
        for lane in result["lanes"]:
            lines += [
                f"### {lane['test_id']}", "",
                f"- Date/time: {lane['at']}",
                f"- Expected: {lane['expected']}",
                f"- Observed: {lane['observed']}",
                f"- Result: {lane['result']}",
                f"- Evidence: `{lane['evidence']}`",
            ]
            if lane["negative_findings"]:
                lines.append(f"- Negative findings: {lane['negative_findings']}")
            if lane["follow_up"]:
                lines.append(f"- Follow-up: {lane['follow_up']}")
            lines.append("")
        lines += [
            "## Boundary", "",
            "This run exercised one Shell-adapter task with a filesystem-inert",
            "prompt. It does not establish provider conformance for any model",
            "backend, does not prove GUI-termination survival, and does not",
            "verify that any agent did correct work. A response is not",
            "completion; an interrupt acknowledgement is not observed",
            "cancellation; quiet output is not done.",
            "",
        ]
    path.write_text("\n".join(lines))
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true",
                        help="execute the write canary (requires writes already enabled)")
    parser.add_argument("--project", default="conduit", help="project slug (default: conduit)")
    parser.add_argument("--agent", default="Shell", help="adapter name (default: Shell)")
    args = parser.parse_args()

    try:
        pre = preflight()
    except CanaryError as exc:
        print(f"\nREFUSED: {exc}")
        return 2

    if not pre["listener_up"]:
        print("\nREFUSED: Session API listener is down.")
        print("  Launch Conduit.app and enable 'Listen for Session API on loopback'.")
        write_receipt(pre, None, "BLOCKED — listener down; no write attempted.")
        return 2

    if not args.run:
        print("\nPreflight only. Nothing was written.")
        if not pre["writes_enabled"]:
            print("\nTo run the canary, YOU must flip the gate — this script will not:")
            print("  Conduit → Settings → 'Allow ChatGPT to create, send, interrupt,")
            print("  and close sessions' → Save settings.")
            print("Then re-run with --run.")
        else:
            print("\nWrites are ENABLED. Re-run with --run to execute the canary.")
        return 0

    if not pre["writes_enabled"]:
        print("\nREFUSED: Session API writes are disabled.")
        print("  This script will not enable them. That switch is the operator's.")
        print("  Conduit → Settings → 'Allow ChatGPT to create, send, interrupt,")
        print("  and close sessions' → Save settings, then re-run.")
        write_receipt(pre, None, "BLOCKED — write gate disabled; no write attempted.")
        return 3

    projects = pre["surface"].get("projects") or []
    if projects and args.project not in projects:
        print(f"\nREFUSED: project '{args.project}' not in {projects}")
        return 4

    try:
        result = canary(args.project, args.agent)
    except CanaryError as exc:
        print(f"\nCANARY ABORTED: {exc}")
        write_receipt(pre, None, f"ABORTED — {exc}")
        return 5

    path = write_receipt(pre, result)
    failures = [l for l in result["lanes"] if l["result"] == "FAIL"]
    print(f"\nReceipt: {path}")
    print(f"Lanes: {len(result['lanes'])}  FAIL: {len(failures)}")
    for lane in failures:
        print(f"  FAIL {lane['test_id']}: {lane['observed']}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
