#!/usr/bin/env python3
"""Validate redacted invocation/readback declarations, without running Codex.

Never reads a Codex home, starts a process, connects, or changes configuration.
A match is scoped metadata consistency, not authentication or runtime proof.
"""
from __future__ import annotations
import json
import re
import sys
from datetime import datetime

MODEL, EFFORT = "gpt-6-luna", "max"
SUBJECT = {
    "commit": "60fb71939509ca70dfa67441fdfa50ef11c9e499",
    "tree": "e5c2360c902183e965d57b65b0060ec1c1a6d4a8",
    "binary_sha256": "84bc16f681d340fa6d634f97f47a82f1ecd8e92a8807f613bd21d8bac3c42d07",
}
DIGESTS = {"cli_sha256", "cwd_sha256", "codex_home_sha256",
           "environment_scope_sha256", "config_context_sha256"}
MAX_BYTES = 1024 * 1024


class Rejected(ValueError):
    pass


def require(ok, code):
    if not ok:
        raise Rejected(code)


def decode(data):
    require(len(data) <= MAX_BYTES, "input_size")
    def pairs(items):
        out = {}
        for key, value in items:
            require(key not in out, "duplicate_json_key")
            out[key] = value
        return out
    def constant(_):
        raise Rejected("nonfinite_json")
    value = json.loads(data, object_pairs_hook=pairs, parse_constant=constant)
    require(type(value) is dict, "object_required")
    return value


def keys(value, expected, code):
    require(type(value) is dict and set(value) == set(expected), code)


def same(left, right):
    return json.dumps(left, sort_keys=True, allow_nan=False) == json.dumps(right, sort_keys=True, allow_nan=False)


def digest(value):
    return type(value) is str and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def inspect(record):
    keys(record, {"schema_version", "runtime_subject", "observed_at_utc",
                  "planned_scope", "probe_scope", "conduit_model_override",
                  "exchanges", "owned_probe_exited"}, "record_shape")
    require(record["schema_version"] == "hosted-profile-route-v1", "schema")
    require(record["runtime_subject"] == SUBJECT, "runtime_subject")
    stamp = datetime.fromisoformat(record["observed_at_utc"].replace("Z", "+00:00"))
    require(stamp.utcoffset() is not None, "timezone_required")
    for name in ("planned_scope", "probe_scope"):
        scope = record[name]
        keys(scope, DIGESTS | {"argv", "transport"}, "scope_shape")
        require(all(digest(scope[key]) for key in DIGESTS), "scope_digest")
        require(scope["argv"] == ["app-server"] and scope["transport"] == "stdio",
                "probe_override_or_unreviewed_launch")
    require(record["planned_scope"] == record["probe_scope"], "scope_mismatch")
    require(record["conduit_model_override"] in (None, MODEL), "conduit_model_conflict")
    require(record["owned_probe_exited"] is True, "probe_exit_unobserved")
    exchanges = record["exchanges"]
    require(type(exchanges) is list and 3 <= len(exchanges) <= 12, "exchange_bound")
    ids, phase, cursor, rows = set(), "initialize", None, []
    cursors = set()
    config_seen = False
    for entry in exchanges:
        keys(entry, {"method", "id", "params", "response"}, "exchange_shape")
        method, ident, params, response = (entry[k] for k in ("method", "id", "params", "response"))
        require(type(ident) is int and ident not in ids, "rpc_id")
        ids.add(ident)
        keys(response, {"id", "result"}, "response_shape_or_error")
        require(type(response["id"]) is int and response["id"] == ident, "response_id")
        result = response["result"]
        require(type(result) is dict, "result_shape")
        if phase == "initialize":
            require(method == "initialize" and params == {
                "clientInfo": {"name": "conduit", "title": "Conduit", "version": "1.0"}
            }, "initialize_contract")
            keys(result, {"initialized_notification_sent"}, "initialize_projection")
            require(result["initialized_notification_sent"] is True, "initialize_barrier")
            phase = "models"
        elif method == "model/list" and phase == "models":
            expected = {"limit": 100, "includeHidden": True}
            if cursor is not None:
                expected["cursor"] = cursor
            require(same(params, expected), "model_pagination_request")
            keys(result, {"data", "nextCursor"}, "model_projection")
            require(type(result["data"]) is list, "model_rows")
            for row in result["data"]:
                keys(row, {"model", "supportedReasoningEfforts"}, "model_row_projection")
                require(type(row["model"]) is str, "model_name")
                efforts = row["supportedReasoningEfforts"]
                require(type(efforts) is list, "efforts_shape")
                for effort in efforts:
                    keys(effort, {"reasoningEffort"}, "effort_projection")
                    require(type(effort["reasoningEffort"]) is str, "effort_type")
                rows.append(row)
            next_cursor = result["nextCursor"]
            require(next_cursor is None or (type(next_cursor) is str and next_cursor and next_cursor not in cursors),
                    "model_cursor")
            cursor = next_cursor
            if cursor is not None:
                cursors.add(cursor)
            if cursor is None:
                phase = "config"
        elif method == "config/read" and phase == "config":
            # cwd is a digest in the redacted record; the actual RPC sends the path.
            require(same(params, {"cwd_sha256": record["probe_scope"]["cwd_sha256"],
                               "includeLayers": False}), "config_cwd_or_override")
            keys(result, {"config"}, "config_projection")
            keys(result["config"], {"model", "model_reasoning_effort"}, "config_keys")
            require(result["config"] == {"model": MODEL, "model_reasoning_effort": EFFORT},
                    "effective_model_or_effort_not_requested")
            config_seen, phase = True, "done"
        else:
            raise Rejected("unpermitted_method_or_sequence")
    require(config_seen, "effective_config_missing_or_partial_catalog")
    selected = [row for row in rows if row["model"] == MODEL]
    require(len(selected) == 1, "model_missing_or_ambiguous")
    require({"reasoningEffort": EFFORT} in selected[0]["supportedReasoningEfforts"], "max_not_advertised")
    return "INVOCATION_EQUIVALENT_METADATA_DECLARED"


def evaluate(record):
    try:
        stage, errors = inspect(record), []
    except (Rejected, ValueError, TypeError, AttributeError, KeyError, RecursionError) as error:
        stage = "READBACK_NOT_ESTABLISHED"
        errors = [str(error) if isinstance(error, Rejected) else "invalid_input"]
    return {"stage": stage, "errors": errors, "grants_authority": False,
            "candidate_runtime_verified": False, "authentication_verified": False,
            "ready_for_hosted_qualification": False,
            "limits": "Declarations only. Hash authenticity, freshness, signing, ownership, billing and actual Conduit invocation are separate checks."}


def main():
    try:
        data = sys.stdin.buffer.read(MAX_BYTES + 1)
        result = evaluate(decode(data))
    except (ValueError, TypeError, RecursionError):
        result = evaluate(None)
    print(json.dumps(result, sort_keys=True))
    return 1 if result["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
