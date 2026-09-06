#!/usr/bin/env python3
"""Check the premise the resume fallback rests on, against the real providers.

Every structured client replaces a refused resume with a new session and, since
D-047, reports that as `restarted` rather than as the resume the caller asked
for. That reporting is only correct if the provider actually *refuses* an id it
no longer owns. If a provider instead answered with a healthy empty thread, the
client would classify it `resumed`, and Conduit would be confidently wrong in
exactly the direction D-047 exists to prevent.

`scripts/test.sh` cannot check this: the branch lives inside a live handshake
with a provider process. So this probe talks to the providers directly, outside
Conduit, and asks one question -- what happens to a well-formed id nobody owns?

Read-only. It starts a provider, asks to resume a random id, and stops. It
creates no Conduit task, sends no prompt, and needs no Session API write gate.

    ./scripts/probe-provider-resume.py [--backend codex|opencode|all]

Exit 0 when every probed provider refuses (the premise holds), 1 when one
accepts (the premise is broken and D-047's `.refused` path is unreachable
there), 2 when nothing could be probed.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import uuid

REFUSED, ACCEPTED, SKIPPED = "REFUSED", "ACCEPTED", "SKIPPED"


def probe_codex() -> tuple[str, str]:
    """codex app-server: thread/resume on an id with no rollout."""
    exe = shutil.which("codex")
    if not exe:
        return SKIPPED, "codex not on PATH"

    proc = subprocess.Popen(
        [exe, "app-server"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )
    replies: list[dict] = []
    answered = threading.Event()

    def read() -> None:
        for line in proc.stdout:  # type: ignore[union-attr]
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            replies.append(msg)
            if msg.get("id") == 1:
                answered.set()

    threading.Thread(target=read, daemon=True).start()

    def send(obj: dict) -> None:
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", **obj}) + "\n")  # type: ignore[union-attr]
        proc.stdin.flush()  # type: ignore[union-attr]

    # Same shape CodexAppServerRequests builds, so the probe exercises the
    # request the client actually sends.
    unknown = str(uuid.uuid4())
    try:
        send({"id": 0, "method": "initialize",
              "params": {"clientInfo": {"name": "conduit", "title": "Conduit",
                                        "version": "1.0"}}})
        send({"method": "initialized", "params": {}})
        send({"id": 1, "method": "thread/resume", "params": {"threadId": unknown}})
        answered.wait(timeout=45)
    finally:
        proc.terminate()

    for msg in replies:
        if msg.get("id") != 1:
            continue
        if "error" in msg:
            return REFUSED, f"{unknown} -> {msg['error'].get('message', '')[:120]}"
        return ACCEPTED, f"{unknown} -> answered with {json.dumps(msg.get('result'))[:120]}"
    return SKIPPED, "no reply to thread/resume within 45s"


def probe_opencode() -> tuple[str, str]:
    """opencode serve: the client gates resume on GET /session/<id>."""
    exe = shutil.which("opencode")
    if not exe:
        return SKIPPED, "opencode not on PATH"

    import urllib.error
    import urllib.request

    port = 18799
    proc = subprocess.Popen(
        [exe, "serve", "--port", str(port)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    base = f"http://127.0.0.1:{port}"
    unknown = f"ses_{uuid.uuid4().hex}"
    try:
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                urllib.request.urlopen(f"{base}/session", timeout=2).read()
                break
            except Exception:
                time.sleep(0.5)
        else:
            return SKIPPED, "opencode serve did not come up within 30s"

        try:
            urllib.request.urlopen(f"{base}/session/{unknown}", timeout=10).read()
            return ACCEPTED, f"{unknown} -> 200; an unknown session read as existing"
        except urllib.error.HTTPError as exc:
            return REFUSED, f"{unknown} -> HTTP {exc.code}"
        except Exception as exc:  # noqa: BLE001
            return SKIPPED, f"{unknown} -> {exc}"
    finally:
        proc.terminate()


PROBES = {"codex": probe_codex, "opencode": probe_opencode}

# Deliberately not probed:
#   acp (Grok, Gemini) -- session/load needs provider credentials; the client
#       catches the failure the same way Codex does, so the shape is shared.
#   structuredCli (Claude, Antigravity) -- StreamJSONClient makes NO start-time
#       check by design. That is why it reports `unverified` rather than
#       `resumed`, and why there is no premise here to test.


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--backend", default="all", choices=[*PROBES, "all"])
    args = ap.parse_args()

    names = list(PROBES) if args.backend == "all" else [args.backend]
    results = {}
    for name in names:
        print(f"=== {name} ===", flush=True)
        verdict, detail = PROBES[name]()
        results[name] = verdict
        print(f"  {verdict}: {detail}", flush=True)

    print()
    if ACCEPTED in results.values():
        bad = [n for n, v in results.items() if v == ACCEPTED]
        print(f"PREMISE BROKEN on {', '.join(bad)}: an unknown id was answered "
              "with a session, so the client would classify it `resumed` and "
              "report continuity it does not have. D-047 needs revisiting.")
        return 1
    if REFUSED not in results.values():
        print("Nothing probed; no provider was reachable.")
        return 2
    ok = [n for n, v in results.items() if v == REFUSED]
    print(f"Premise holds on {', '.join(ok)}: an unknown id is refused, so the "
          "fallback fires exactly when history is gone and `restarted` is the "
          "honest report.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
