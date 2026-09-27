#!/usr/bin/env python3
"""Offline consistency check for the pre-run Luna Max binding, not authorization.

Read only caller-supplied, redacted JSON. Never inspect Codex homes, connect,
launch a process, change configuration, or infer authentication from metadata.
Exit 0: consistent declarations; 1: mismatch; 2: missing/invalid input.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
from datetime import datetime

APPARATUS = "89733c67556bbf1fde7e31edffc229e527321815"
PROTOCOL_SHA256 = "f5ceec61c77e541be507a9d4131e475437d80d6833164c78856dfd71b4c0f1cf"
# Receipt-supplied subject pins. This program does not prove these bytes exist.
RUNTIME = {
    "commit": "60fb71939509ca70dfa67441fdfa50ef11c9e499",
    "tree": "e5c2360c902183e965d57b65b0060ec1c1a6d4a8",
    "binary_sha256": "84bc16f681d340fa6d634f97f47a82f1ecd8e92a8807f613bd21d8bac3c42d07",
}
MODEL, EFFORT = "gpt-6-luna", "max"
PHASES = ["hs-smoke", "hs-pilot-l1", "hs-pilot-f1", "hs-pilot-f2", "hs-pilot-l2"]
CONTROLS = {
    "pilot_order": ["L", "F", "F", "L"], "smoke_tasks": 1, "pilot_tasks": 4,
    "max_turns_per_task": 3, "max_active_turns": 1,
    "turn_observation_seconds": 180, "teardown_observation_seconds": 60,
    "delegation_allowed": False, "fallback_allowed": False,
    "queued_means_no_resend": True, "service_tier_change_allowed": False,
}
MAX_BYTES = 1048576


class InvalidInput(ValueError):
    pass


def require(condition: bool, code: str) -> None:
    if not condition:
        raise InvalidInput(code)


def canonical(value: object) -> str:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def same(left: object, right: object) -> bool:
    # JSON true must not compare equal to the integer 1.
    return canonical(left) == canonical(right)


def decode(data: bytes) -> dict:
    require(len(data) <= MAX_BYTES, "input_too_large")
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate_json_key")
            result[key] = value
        return result
    def constant(_):
        raise InvalidInput("nonfinite_json_number")
    result = json.loads(data, object_pairs_hook=pairs, parse_constant=constant)
    require(isinstance(result, dict), "object_required")
    return result


def read(path: Path) -> tuple[dict, str]:
    require(not path.is_symlink() and path.is_file(), "regular_snapshot_required")
    with path.open("rb") as stream:
        data = stream.read(MAX_BYTES + 1)
    return decode(data), hashlib.sha256(data).hexdigest()


def request_errors(request: dict) -> list[str]:
    expected = {
        "schema_version": "hosted-luna-profile-request-v1",
        "apparatus_commit": APPARATUS, "protocol_sha256": PROTOCOL_SHA256,
        "runtime_subject": RUNTIME, "requested_model": MODEL,
        "requested_reasoning_effort": EFFORT,
        "usage_route": "existing_codex_chatgpt_subscription",
        "controls": CONTROLS,
        "phases": [{"fixture": name, "model": MODEL, "effort": EFFORT} for name in PHASES],
    }
    errors = ["request_keys_differ"] if set(request) != set(expected) else []
    errors.extend("request_" + key + "_differs" for key, value in expected.items()
                  if key not in request or not same(request[key], value))
    return errors


def observation_errors(observation: dict) -> list[str]:
    """Check supplied observations, not their authenticity, freshness or consent."""
    errors = []
    required = {"schema_version", "runtime_subject", "source", "observed_at_utc",
                "cli_sha256", "invocation_scope_sha256", "model_catalog_sha256",
                "effective_config_sha256", "model_catalog", "effective_profile"}
    if set(observation) != required:
        errors.append("observation_keys_differ")
    if observation.get("schema_version") != "hosted-luna-profile-observation-v1":
        errors.append("observation_schema")
    if not same(observation.get("runtime_subject"), RUNTIME):
        errors.append("wrong_runtime_subject")
    if observation.get("source") != "effective_config_readback":
        errors.append("effective_readback_missing")
    try:
        stamp = datetime.fromisoformat(observation["observed_at_utc"].replace("Z", "+00:00"))
        require(stamp.tzinfo is not None, "timestamp_timezone_missing")
    except (KeyError, AttributeError, TypeError, ValueError):
        errors.append("observation_timestamp_missing_or_invalid")
    for key in ("cli_sha256", "invocation_scope_sha256", "model_catalog_sha256", "effective_config_sha256"):
        value = observation.get(key)
        if not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None:
            errors.append(key + "_missing_or_invalid")
    catalog = observation.get("model_catalog")
    if not isinstance(catalog, dict) or "nextCursor" not in catalog or catalog["nextCursor"] is not None:
        errors.append("catalog_not_complete")
    rows = catalog.get("data") if isinstance(catalog, dict) else None
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        errors.append("catalog_rows_invalid")
        rows = []
    selected = [row for row in rows if row.get("model") == MODEL]
    if len(selected) != 1:
        errors.append("requested_model_missing_or_ambiguous")
    else:
        efforts = selected[0].get("supportedReasoningEfforts")
        if not isinstance(efforts, list) or not any(
            isinstance(e, dict) and e.get("reasoningEffort") == EFFORT for e in efforts
        ):
            errors.append("literal_max_not_advertised")
    effective = observation.get("effective_profile")
    keys = {"model", "reasoning_effort", "provider_id", "usage_route",
            "service_tier", "conduit_model_override"}
    if not isinstance(effective, dict) or set(effective) != keys:
        errors.append("effective_profile_missing_or_invalid")
    else:
        for key, expected in (("model", MODEL), ("reasoning_effort", EFFORT),
                              ("provider_id", "openai"),
                              ("usage_route", "existing_codex_chatgpt_subscription")):
            if effective[key] != expected:
                errors.append("effective_" + key + "_differs")
        if effective["service_tier"] not in ("default", "standard"):
            errors.append("service_tier_requires_operator_decision")
        if effective["conduit_model_override"] not in (None, MODEL):
            errors.append("conduit_override_conflicts")
    return errors


def report(errors: list[str], observed: bool) -> dict:
    return {
        "stage": "PROFILE_INPUTS_BLOCKED" if errors else (
            "PROFILE_DECLARATIONS_CONSISTENT" if observed else "PROFILE_REQUEST_CONSISTENT"),
        "errors": errors, "execution_authorized": False,
        "ready_for_hosted_qualification": False,
        "limitation": "Offline declarations only; no authentication, runtime, consent, freshness or byte-provenance verification.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("request", type=Path)
    parser.add_argument("--observation", type=Path)
    args = parser.parse_args()
    try:
        request, request_hash = read(args.request)
        errors = request_errors(request)
        hashes = {"request_sha256": request_hash}
        if args.observation is not None:
            observation, observation_hash = read(args.observation)
            errors.extend(observation_errors(observation))
            hashes["observation_sha256"] = observation_hash
        result = report(errors, args.observation is not None)
        result.update(hashes)
        print(json.dumps(result, indent=2))
        return 1 if errors else 0
    except (InvalidInput, OSError, ValueError, TypeError, RecursionError):
        # Do not echo private paths, malformed data or exception contents.
        print(json.dumps(report(["missing_or_invalid_redacted_input"], False)))
        return 2


if __name__ == "__main__":
    sys.exit(main())
