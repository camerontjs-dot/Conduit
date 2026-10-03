#!/usr/bin/env python3
"""Owned stdio fixture; no network, credentials, provider runtime or model calls."""
import json
import os
from pathlib import Path
import signal
import sys
import threading

assert sys.argv[1:] == ["app-server"]
root = Path.cwd()
scenario = (root / "scenario").read_text().strip()
driver = "0192e7f0-0000-7000-8000-000000000001"
external = "0192e7f0-0000-7000-8000-000000000002"
family = "0192e7f0-0000-7000-8000-000000000003"
wire = (root / "wire.jsonl").open("x")
output_lock = threading.Lock()


def emit(payload):
    with output_lock:
        print(json.dumps(payload), flush=True)


def reply(request, result):
    emit({"id": request["id"], "result": result})


def thread(identifier):
    return {
        "id": identifier, "sessionId": family, "cwd": str(root),
        "createdAt": 100, "updatedAt": 200, "cliVersion": "owner-fixture-1",
        "modelProvider": "fake-provider", "model": "fixture-session-model",
        "ephemeral": False, "source": "cli", "status": {"type": "notLoaded"},
        "turns": [], "preview": "fixture-private-preview", "name": "fixture-private-title",
        "path": "fixture-private-rollout", "projectId": None,
    }


def terminate(_signum, _frame):
    (root / "terminated.json").write_text(json.dumps({"pid": os.getpid(), "owned_fixture": True}))
    raise SystemExit(0)


signal.signal(signal.SIGTERM, terminate)
for line in sys.stdin:
    request = json.loads(line)
    wire.write(json.dumps(request) + "\n")
    wire.flush()
    method = request.get("method")
    params = request.get("params", {})
    if method == "initialize":
        reply(request, {"userAgent": "owned-fake"})
    elif method == "initialized":
        pass
    elif method == "thread/start":
        reply(request, {"thread": {"id": driver}})
    elif method == "turn/start":
        reply(request, {"turn": {"id": "fixture-turn-distinct"}})
        emit({"method": "turn/started", "params": {"threadId": driver, "turnId": "fixture-turn-distinct"}})
        emit({"id": 900, "method": "item/commandExecution/requestApproval", "params": {"command": "fixture-only"}})
    elif method == "account/rateLimits/read":
        timer = threading.Timer(2.4, lambda r=request: reply(r, {"rateLimits": {"fixtureOnly": True}}))
        timer.daemon = True
        timer.start()
    elif method == "thread/list":
        assert params["useStateDbOnly"] is True
        assert params["archived"] is False
        assert params["limit"] == 64
        assert "appServer" in params["sourceKinds"] and "subAgentThreadSpawn" in params["sourceKinds"]
        assert params["modelProviders"] == [] and "originators" not in params
        if scenario in ["timeout-control", "cancel", "host-stop", "capacity"]:
            if scenario != "capacity" and scenario != "host-stop":
                delay = 2.3 if scenario == "timeout-control" else 0.3
                timer = threading.Timer(delay, lambda r=request: reply(r, {"data": [thread(external)], "nextCursor": None}))
                timer.daemon = True
                timer.start()
            continue
        if scenario == "wrong-envelope":
            emit({"id": request["id"], "method": "item/commandExecution/requestApproval", "params": {"command": "fixture-private-command"}})
        elif scenario == "rpc-error":
            emit({"id": request["id"], "error": {"code": -32000, "message": "fixture-private-provider-error"}})
        elif scenario == "page-bound":
            index = int(params.get("cursor", "0"))
            reply(request, {"data": [thread("fixture-page-" + str(index))], "nextCursor": str(index + 1)})
        elif scenario == "cursor-cycle":
            identifier = driver if "cursor" not in params else external
            reply(request, {"data": [thread(identifier)], "nextCursor": "cycle"})
        elif scenario == "malformed":
            metadata = thread(external)
            metadata["createdAt"] = 100.5
            reply(request, {"data": [metadata], "nextCursor": None})
        elif "cursor" not in params:
            reply(request, {"data": [thread(driver)], "nextCursor": "second-page"})
        else:
            metadata = thread(driver if scenario == "duplicate" else external)
            reply(request, {"data": [metadata], "nextCursor": None})
    elif method == "thread/loaded/list":
        assert params["limit"] == 64
        data = [driver, driver] if scenario == "loaded-duplicate" else ([123] if scenario == "loaded-malformed" else [driver])
        reply(request, {"data": data, "nextCursor": None})
    elif method == "thread/read":
        assert params["includeTurns"] is False and params["threadId"] == external
        metadata = thread(external)
        if scenario == "unexpected-turns":
            metadata["turns"] = [{"id": "fixture-content-turn"}]
        elif scenario == "wrong-read":
            metadata["id"] = driver
        elif scenario == "stale-read":
            metadata["updatedAt"] = 150
        reply(request, {"thread": metadata})
        # Duplicate, expired and foreign observation IDs are intentional pressure.
        emit({"id": request["id"], "error": {"message": "fixture-private-provider-error"}})
        emit({"id": "conduit.observation.v1/wrong-host/unmatched", "result": {"thread": {"id": "fixture-wrong-driver"}}})
        emit({"id": "conduit.observation.v1/expired/request", "error": {"message": "fixture-private-provider-error"}})
    else:
        raise AssertionError("unexpected fixture method: " + str(method))
