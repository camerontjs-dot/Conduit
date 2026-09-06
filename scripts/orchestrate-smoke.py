#!/usr/bin/env python3
"""Exercise the control plane the way an orchestrating agent would use it.

Every canary lane so far has driven ONE task at a time through one linear
sequence. That is not how an orchestrator behaves, and it is not where a
control plane breaks. This exercises the primitives that have never been
tested together:

  fan-out    several live tasks at once, each given its objective at create
             time. Concurrency is where the new deliver-on-ready hold either
             holds up or crosses prompts between runtimes.
  ceiling    the admission cap refuses the task that would exceed it, and
             says so, rather than starting a runtime it cannot admit.
  observe    each task is followed to completion independently, and the
             answers are read from the PROVIDER's own store.
  chain      one task's real answer becomes the next task's objective. This
             is the whole orchestration premise: an agent acting on what
             another agent produced.
  release    every task is closed and reports what closing cost.

Ground truth is OpenCode's SQLite, never Conduit's event log. An answer that
appears only in Conduit's record proves recording, not work.

The objectives are small and deterministic on purpose. The question here is
whether the control plane can carry work between agents, not whether a model
can do hard work; a wrong answer from the model is reported as a wrong answer
and does not become a control-plane pass.

Writes require the operator's Session API gate. This script never enables it.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CANARY = REPO / "scripts" / "canary-control-plane.py"
RECEIPT_DIR = REPO / "outputs" / "local-acceptance" / "orchestration"

spec = importlib.util.spec_from_file_location("canary_cp", CANARY)
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

TURN_TIMEOUT = 180
POLL = 4.0


def lane(rows, test_id, expected, observed, ok, evidence="", negative=""):
    rows.append({
        "test_id": test_id,
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "expected": expected,
        "observed": observed,
        "result": "OBSERVED" if ok else "FAIL",
        "evidence": str(evidence)[:400],
        "negative": negative,
    })
    flag = "" if ok else "   ** FAIL **"
    print(f"  [{'OBSERVED' if ok else 'FAIL':8s}] {test_id}: {observed}{flag}")
    return rows[-1]


def create(api, agent, project, objective, key):
    return api.call(
        "conduit_create_task",
        agent=agent, project_slug=project, objective=objective,
        idempotency_key=key,
    )


def turn_state(api, task_id):
    events = api.call("conduit_session_events", taskSessionID=task_id, limit=50)
    return (
        (events.get("turn") or {}).get("state"),
        (events.get("observation") or {}).get("checkpoint"),
        events,
    )


def await_turn(api, task_id, deadline):
    """Follow one task to a terminal turn state."""
    last = (None, None, {})
    while time.time() < deadline:
        last = turn_state(api, task_id)
        if last[0] in {"completed", "failed"}:
            return last
        time.sleep(POLL)
    return last


def objective_for(agent: str, token: str, word: str) -> str:
    """One assertion shape across backends that answer very differently.

    A Shell is not an agent and cannot be asked to reason, but the control
    plane still has to carry work to it. Giving it a command that produces the
    same `TOKEN-n` line means a single ground-truth check covers every backend
    in a mixed fan-out.
    """
    if agent.strip().lower() == "shell":
        return f'T={token}; echo "${{T}}-{len(word)}"'
    return (
        f"Reply with exactly one line: {token}-<n> where <n> is the number of "
        f"letters in the word {word}. No other text. Do not use any tools."
    )


def run(project: str, agents: list[str]) -> dict:
    api = cp.SessionAPI(cp.load_token())
    api.initialize()
    rows: list[dict] = []
    stamp = int(time.time())
    since = time.time() - 30
    tasks: dict[str, dict] = {}

    # ---- fan-out ----------------------------------------------------------
    print(f"\n-- fan-out: 3 concurrent tasks across {agents} --")
    words = {"alpha": ("ALPHA", "orchestration"),
             "bravo": ("BRAVO", "conduit"),
             "charlie": ("CHARLIE", "agent")}
    plan = {}
    for index, (name, (token, word)) in enumerate(words.items()):
        # Round-robin so a single-agent list behaves exactly as before and a
        # mixed list puts each task on a different backend.
        assigned = agents[index % len(agents)]
        plan[name] = (token, objective_for(assigned, token, word), assigned)

    for name, (token, objective, assigned) in plan.items():
        created = create(api, assigned, project, objective, f"orch-{stamp}-{name}")
        tid = created.get("taskSessionID")
        tasks[name] = {"id": tid, "token": token, "created": created,
                       "agent": assigned}
        state = created.get("objective_delivery_state")
        lane(
            rows, f"ORCH-1-create-{name}",
            "objective is accepted at create; Conduit owns delivery",
            f"agent={assigned} task={tid} delivery_state={state} "
            f"resend_required={created.get('objective_resend_required')}",
            state in {"queued", "delivered"}
            and not created.get("objective_resend_required"),
            json.dumps(created)[:400],
            negative="Accepting an objective is not running it.",
        )

    live_ids = [t["id"] for t in tasks.values() if t["id"]]
    lane(
        rows, "ORCH-2-concurrent-live",
        "all three tasks exist concurrently with distinct ids",
        f"distinct_ids={len(set(live_ids))} of {len(live_ids)}",
        len(set(live_ids)) == len(live_ids) == 3,
        json.dumps(live_ids),
    )

    # ---- ceiling ----------------------------------------------------------
    print("\n-- ceiling: the task that would exceed the live cap --")
    overflow = []
    refusal = None
    for extra in range(1, 4):
        created = create(
            api, agents[0], project,
            objective_for(agents[0], "OVERFLOW", "x"),
            f"orch-{stamp}-overflow{extra}",
        )
        overflow.append(created)
        if created.get("error") or created.get("refused"):
            refusal = created
            break
        if created.get("taskSessionID"):
            tasks[f"overflow{extra}"] = {
                "id": created["taskSessionID"], "token": "OVERFLOW",
                "created": created,
            }
    lane(
        rows, "ORCH-3-admission-ceiling",
        "the create beyond the live-task cap is refused with a reason",
        (f"refused after {len(overflow)} extra creates: "
         f"{(refusal or {}).get('error') or (refusal or {}).get('reason')}")
        if refusal else
        f"no refusal after {len(overflow)} extra creates",
        refusal is not None,
        json.dumps(refusal or overflow[-1])[:400],
        negative="A cap that never refuses is not a cap.",
    )

    # ---- observe ----------------------------------------------------------
    print("\n-- observe: follow each task, then read the PROVIDER's own store --")
    deadline = time.time() + TURN_TIMEOUT
    answers: dict[str, str] = {}
    for name in plan:
        tid = tasks[name]["id"]
        if not tid:
            continue
        assigned = plan[name][2]
        is_pty = assigned.strip().lower() == "shell"
        state, checkpoint, _ = await_turn(api, tid, deadline)
        tasks[name]["turn"] = state
        if is_pty:
            # A PTY has no turn to report. Conduit says `ambiguous`, which is
            # the honest answer and also a hard limit on orchestration: there
            # is no terminal turn state coming, so an orchestrator that polls
            # for one waits forever. Work on a PTY can only be confirmed out
            # of band, from the pane itself. Recorded as its own lane rather
            # than folded into a pass, because it changes what an orchestrator
            # may rely on.
            lane(
                rows, f"ORCH-4-turn-{name}",
                "a PTY reports ambiguity rather than inventing a turn result",
                f"agent={assigned} turn={state} checkpoint={checkpoint}",
                state in {"ambiguous", "idle", "completed"},
                negative="ambiguous is honest, not terminal. An orchestrator "
                         "cannot detect PTY completion through the control "
                         "plane and must not poll for a state that never "
                         "arrives; confirm PTY work from the pane, or "
                         "orchestrate through a structured backend.",
            )
        else:
            lane(
                rows, f"ORCH-4-turn-{name}",
                "the turn reaches a terminal state the caller can branch on",
                f"agent={assigned} turn={state} checkpoint={checkpoint}",
                state in {"completed", "failed"},
                negative="A terminal turn is not a correct answer.",
            )

    # Each task is checked against ITS OWN provider's store — Codex rollout
    # JSONL, OpenCode SQLite, or the tmux pane. A mixed fan-out is only
    # meaningful if each backend is witnessed by itself.
    for name, (token, _, assigned) in plan.items():
        tid = tasks[name]["id"]
        source, text = cp.ground_truth(assigned, tid, since) if tid else ("none", "")
        hit = [line for line in text.splitlines() if token + "-" in line]
        answers[name] = hit[0].strip() if hit else ""
        tasks[name]["truth_source"] = source
        lane(
            rows, f"ORCH-5-ground-truth-{name}",
            "the answer exists in the provider's own store, not only in Conduit",
            f"agent={assigned} source={source} "
            f"provider_answer={answers[name] or '(absent)'}",
            bool(answers[name]),
            negative="An answer only Conduit recorded proves recording, not work.",
        )

    # ---- chain ------------------------------------------------------------
    print("\n-- chain: one agent acts on what another agent produced --")
    source = answers.get("alpha") or ""
    chained = None
    if source:
        # Free a slot first: the chain is a real dependent task, and an
        # orchestrator that cannot release capacity cannot chain.
        for name in ("bravo", "charlie"):
            tid = tasks[name]["id"]
            if tid:
                try:
                    api.call("conduit_close_session", taskSessionID=tid)
                    tasks[name]["closed"] = True
                except cp.CanaryError:
                    pass
        time.sleep(2)
        since_chain = time.time() - 5
        # Run the dependent task on a DIFFERENT backend from the one that
        # produced the answer wherever the run has more than one. Chaining a
        # backend to itself never leaves the provider, so it cannot show that
        # the control plane is what carried the value between agents.
        source_agent = plan["alpha"][2]
        chain_agent = next(
            (a for a in agents if a != source_agent), source_agent
        )
        chained = create(
            api, chain_agent, project,
            objective_for(chain_agent, "ECHO", source)
            if chain_agent.strip().lower() == "shell"
            else (f"Another agent produced this line: {source}. "
                  f"Reply with exactly one line: ECHO-{source}. "
                  "No other text. Do not use any tools."),
            f"orch-{stamp}-chain",
        )
        tid = chained.get("taskSessionID")
        if tid:
            tasks["chain"] = {"id": tid, "token": "ECHO", "created": chained,
                              "agent": chain_agent}
            state, checkpoint, _ = await_turn(
                api, tid, time.time() + TURN_TIMEOUT
            )
            _, text = cp.ground_truth(chain_agent, tid, since_chain)
            carried = source in text and "ECHO" in text
            lane(
                rows, "ORCH-6-chain",
                "a dependent task on another backend receives and acts on the "
                "first task's real output",
                f"{source_agent} -> {chain_agent}: turn={state} "
                f"carried_prior_answer={carried} source={source!r}",
                carried,
                evidence=text[-300:],
                negative="Carrying a value is not understanding it.",
            )
        else:
            lane(rows, "ORCH-6-chain",
                 "a dependent task receives the first task's real output",
                 f"chain create failed: {chained.get('error')}", False,
                 json.dumps(chained)[:400])
    else:
        lane(rows, "ORCH-6-chain",
             "a dependent task receives the first task's real output",
             "not attempted: no ground-truth answer to chain from", False)

    # ---- release ----------------------------------------------------------
    print("\n-- release --")
    outcomes = {}
    for name, task in tasks.items():
        tid = task.get("id")
        if not tid or task.get("closed"):
            continue
        try:
            closed = api.call("conduit_close_session", taskSessionID=tid)
            outcomes[name] = closed.get("close_outcome")
        except cp.CanaryError as exc:
            outcomes[name] = f"error: {exc}"
    lane(
        rows, "ORCH-7-release",
        "every close states what it cost",
        f"outcomes={outcomes}",
        bool(outcomes) and all(v == "stopped" for v in outcomes.values()),
        json.dumps(outcomes),
        negative="close_outcome stopped means these tasks are not recoverable.",
    )

    return {"rows": rows, "tasks": tasks, "answers": answers,
            "agent": ",".join(agents), "agents": agents,
            "project": project, "stamp": stamp}


def write_receipt(pre: dict, result: dict) -> Path:
    RECEIPT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    path = RECEIPT_DIR / f"{stamp}-orchestration.md"
    fails = [r for r in result["rows"] if r["result"] == "FAIL"]
    lines = [
        "# Control-plane orchestration exercise", "",
        "Fan-out, admission ceiling, independent observation, a chained",
        "dependent task, and release — the primitives an orchestrating agent",
        "needs, which the single-task canary lanes never exercise together.",
        "", "## Object under test", "", "```",
        *[f"{k}: {v}" for k, v in pre["pin"].items()],
        f"agent: {result['agent']}",
        f"enableSessionAPIWrites: {pre['writes_enabled']}",
        "```", "",
        f"## Result: {len(result['rows']) - len(fails)} observed, {len(fails)} failed",
        "",
    ]
    for row in result["rows"]:
        lines += [
            f"### {row['test_id']}", "",
            f"- Date/time: {row['at']}",
            f"- Expected: {row['expected']}",
            f"- Observed: {row['observed']}",
            f"- Result: {row['result']}",
        ]
        if row["evidence"]:
            lines.append(f"- Evidence: `{row['evidence']}`")
        if row["negative"]:
            lines.append(f"- Negative findings: {row['negative']}")
        lines.append("")
    lines += [
        "## Boundary", "",
        f"One machine, one project, adapters: {result['agent']}. Small",
        "deterministic objectives. This establishes that the control plane can",
        "carry work between agents; it establishes nothing about how well any",
        "agent does the work. A model that answers wrongly still produces a",
        "green transport lane, and the answers are recorded above so that",
        "distinction stays visible.",
        "",
    ]
    path.write_text("\n".join(lines))
    return path


def main() -> int:
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except AttributeError:
        pass
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--project", default="conduit")
    parser.add_argument(
        "--agents", default="OpenCode",
        help="comma-separated adapters, assigned round-robin to the fan-out. "
             "A mixed list (Codex,OpenCode,Shell) exercises heterogeneous "
             "backends concurrently and chains across them.",
    )
    args = parser.parse_args()

    pre = cp.preflight()
    if not pre["listener_up"]:
        print("REFUSED: listener down.")
        return 2
    if not pre["writes_enabled"]:
        print("REFUSED: Session API writes are disabled. That switch is the "
              "operator's; this script will not flip it.")
        return 2
    if not args.run:
        print("\nPreflight only. Nothing was written. Re-run with --run.")
        return 0

    agents = [a.strip() for a in args.agents.split(",") if a.strip()]
    if not agents:
        print("REFUSED: no agents given.")
        return 2
    result = run(args.project, agents)
    path = write_receipt(pre, result)
    fails = [r for r in result["rows"] if r["result"] == "FAIL"]
    print(f"\nReceipt: {path}")
    print(f"Lanes: {len(result['rows'])}  FAIL: {len(fails)}")
    for row in fails:
        print(f"  FAIL {row['test_id']}: {row['observed']}")
    print(f"Answers from the provider's own store: {result['answers']}")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
