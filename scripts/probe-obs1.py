#!/usr/bin/env python3
"""Targeted reproduction probe for OBS-1 (PTY output observation blindness).

OBS-1 was observed 2 of 5 times on installed build f36a7065 (2026-09-04
03:10, Shell adapter): the tmux pane provably ran the objective and produced
output, while `conduit_session_events` reported `last_output_state: none` and
`checkpoint: output_unobserved`. It has not recurred in the 6 Shell runs since.

It was NOT fixed. `git diff fde35c3b..c8e7f5fc -- Sources/` — the range between
the build that failed and the build that stopped failing — does not touch
`noteOutput`, `scheduleTmuxPaneCapture`, `beginAgentOutputCapture`, or any
pane sampling. The defect stopped showing on its own, which means it can come
back, and the standing decision not to patch it blind still holds.

So this probe does not re-run the canary and hope. It varies the ONE thing
the suspected mechanism turns on.

Suspected mechanism, from reading the source: `noteOutput` is the sole caller
of `scheduleTmuxPaneCapture()`, which debounces 0.18s and then samples the
pane ONCE. Every sample is therefore driven by output arriving. A shell that
produces its output in a single burst and then goes idle gets exactly one
sampling opportunity; if that one sample misses, nothing ever re-samples.

The main canary's objective is the shape LEAST likely to expose this: it
emits START, sleeps 25 seconds, then emits END, so output arrives twice and
schedules two independent captures. That is the shape that has passed 6/6.

Variants below, from most fragile to least:

  instant  all output within milliseconds of delivery, then idle forever.
           One burst, and it lands while the runtime is still being wired.
  burst    idle, then all output at once, then idle. One burst, well after
           the runtime is established.
  control  the main canary's shape: two bursts 25s apart. Known to pass.

A variant that goes blind while `control` stays clean localises the defect to
single-sample observation. If nothing goes blind across many runs, that is
also a result: it bounds the rate, and it is recorded as such rather than
being read as "fixed".

Ground truth is the tmux pane's own scrollback, never Conduit's event log.
This script performs Session API writes and refuses to run unless the
operator has already enabled the write gate; it never enables it.
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
RECEIPT_DIR = REPO / "outputs" / "local-acceptance" / "obs1"


def _load_canary():
    """Reuse the canary's client and ground-truth helpers verbatim.

    Importing rather than reimplementing keeps one definition of "what the
    provider actually produced". A second copy could drift into agreeing with
    Conduit, which is the failure this whole apparatus exists to avoid.
    """
    spec = importlib.util.spec_from_file_location("canary_cp", CANARY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


cp = _load_canary()


VARIANTS = {
    # Everything within milliseconds of the PTY host accepting the objective,
    # then silence. The single capture opportunity lands while the runtime is
    # still being wired up.
    "instant": lambda m: f'C={m}; echo "${{C}}_START"; echo "${{C}}_END"',
    # One burst, well after the runtime is established, then silence. Isolates
    # "single sample" from "sample during startup".
    "burst": lambda m: (
        f'C={m}; sleep 6; {{ echo "${{C}}_START"; echo "${{C}}_END"; }}'
    ),
    # The main canary's shape. Two bursts, two capture opportunities.
    "control": lambda m: (
        f'C={m}; echo "${{C}}_START"; sleep 8; echo "${{C}}_END"'
    ),
}


def observe(api, task_id: str) -> dict:
    events = api.call("conduit_session_events", taskSessionID=task_id, limit=50)
    return events.get("observation") or {}


def run_once(api, project: str, variant: str, index: int) -> dict:
    marker = f"OBS1_{variant.upper()}_{index}_{int(time.time())}"
    objective = VARIANTS[variant](marker)
    started = time.time()

    created = api.call(
        "conduit_create_task",
        agent="Shell",
        project_slug=project,
        objective=objective,
        idempotency_key=f"obs1-{marker}",
    )
    task_id = created.get("taskSessionID") or created.get("task_session_id")
    if not task_id:
        raise cp.CanaryError(f"create_task returned no task id: {created}")

    # Let the shell finish, plus room for the 0.18s debounce and one sample.
    # Deliberately no polling loop: polling would drive extra observation and
    # could itself mask the defect.
    time.sleep(20)

    session = cp.find_tmux_session(task_id)
    scrollback = cp.pty_scrollback(session) or "" if session else ""
    ran = f"{marker}_START" in scrollback and f"{marker}_END" in scrollback
    obs = observe(api, task_id)

    blind = bool(
        ran
        and (
            obs.get("last_output_state") == "none"
            or obs.get("checkpoint") == "output_unobserved"
        )
    )

    try:
        api.call("conduit_close_session", taskSessionID=task_id)
    except cp.CanaryError:
        pass

    return {
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "variant": variant,
        "marker": marker,
        "task_id": task_id,
        "tmux_session": session,
        "objective_delivery_state": created.get("objective_delivery_state"),
        "pane_ran_objective": ran,
        "last_output_state": obs.get("last_output_state"),
        "checkpoint": obs.get("checkpoint"),
        "provider_progress": obs.get("provider_progress"),
        "checkpoint_authority": obs.get("checkpoint_authority"),
        "elapsed_s": round(time.time() - started, 1),
        "BLIND": blind,
    }


def write_receipt(pre: dict, rows: list[dict], tally: dict) -> Path:
    RECEIPT_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    path = RECEIPT_DIR / f"{stamp}-obs1-probe.md"
    lines = [
        "# OBS-1 targeted reproduction probe",
        "",
        "Hypothesis under test: `noteOutput` is the sole caller of",
        "`scheduleTmuxPaneCapture()`, which debounces 0.18s and samples once,",
        "so a shell that emits one burst and then idles gets exactly one",
        "sampling opportunity and never re-samples.",
        "",
        "## Object under test",
        "",
        "```",
        *[f"{k}: {v}" for k, v in pre["pin"].items()],
        f"enableSessionAPIWrites: {pre['writes_enabled']}",
        "```",
        "",
        "## Result by variant",
        "",
        "| variant | runs | pane ran | blind | rate |",
        "| --- | --- | --- | --- | --- |",
    ]
    for variant, row in tally.items():
        rate = f"{row['blind']}/{row['runs']}"
        lines.append(
            f"| {variant} | {row['runs']} | {row['ran']} | {row['blind']} | {rate} |"
        )
    lines += ["", "## Runs", "", "```"]
    for row in rows:
        lines.append(json.dumps(row))
    lines += [
        "```",
        "",
        "## Boundary",
        "",
        "Shell adapter only, on one machine, against the installed bundle",
        "pinned above. A variant that never went blind here is not proven",
        "immune; this bounds an observed rate, it does not establish absence.",
        "A blind row is proof the pane produced output the control plane could",
        "not see, because the pane's own scrollback is the witness.",
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
    parser.add_argument("--run", action="store_true", help="execute writes")
    parser.add_argument("--project", default="conduit")
    parser.add_argument("--repeat", type=int, default=6, metavar="N",
                        help="runs per variant (default 6)")
    parser.add_argument("--variants", default="instant,burst,control")
    args = parser.parse_args()

    pre = cp.preflight()
    if not pre["listener_up"]:
        print("REFUSED: Session API listener is down.")
        return 2
    if not pre["writes_enabled"]:
        print("REFUSED: Session API writes are disabled.")
        print("  This probe will not enable them. That switch is the operator's.")
        return 2
    if not args.run:
        print("\nPreflight only. Nothing was written. Re-run with --run.")
        return 0

    api = cp.SessionAPI(cp.load_token())
    api.initialize()

    variants = [v.strip() for v in args.variants.split(",") if v.strip()]
    for variant in variants:
        if variant not in VARIANTS:
            print(f"unknown variant: {variant}")
            return 2

    rows: list[dict] = []
    tally = {v: {"runs": 0, "ran": 0, "blind": 0} for v in variants}
    for index in range(1, args.repeat + 1):
        for variant in variants:
            row = run_once(api, args.project, variant, index)
            rows.append(row)
            tally[variant]["runs"] += 1
            tally[variant]["ran"] += bool(row["pane_ran_objective"])
            tally[variant]["blind"] += bool(row["BLIND"])
            flag = "  ** BLIND **" if row["BLIND"] else ""
            print(
                f"[{index}/{args.repeat}] {variant:8s} "
                f"ran={row['pane_ran_objective']} "
                f"state={row['last_output_state']} "
                f"checkpoint={row['checkpoint']}{flag}"
            )

    path = write_receipt(pre, rows, tally)
    print(f"\nReceipt: {path}")
    total_blind = sum(t["blind"] for t in tally.values())
    for variant, row in tally.items():
        print(f"  {variant:8s} blind {row['blind']}/{row['runs']} "
              f"(pane ran {row['ran']}/{row['runs']})")
    if total_blind:
        print("\nOBS-1 REPRODUCED.")
        return 1
    print("\nOBS-1 not reproduced in this run. That bounds the rate; it does "
          "not mean the defect is gone — nothing has patched the mechanism.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
