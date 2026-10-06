#!/usr/bin/env python3
"""Offline helpers for hosted-supervisor-v1. No network or runtime control.

Catalogue equality is metadata evidence, not authorization or successful dispatch.
Fixture verification checks the artifact, not the producing agent's explanation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import secrets
import sys
from pathlib import Path
from typing import Any

MAX_BYTES = 1_048_576
FIELDS = ("description", "inputSchema", "annotations", "outputSchema")


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path: Path) -> tuple[Any, str]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"regular non-symlink file required: {path.name}")
    with path.open("rb") as handle:
        raw = handle.read(MAX_BYTES + 1)
    if len(raw) > MAX_BYTES:
        raise ValueError(f"input exceeds {MAX_BYTES} bytes")
    return json.loads(raw, object_pairs_hook=unique_object), digest(raw)


def catalog_tools(value: Any) -> dict[str, dict[str, Any]]:
    if isinstance(value, dict) and "result" in value:
        if "error" in value:
            raise ValueError("RPC error is not a catalogue")
        value = value["result"]
    if not isinstance(value, dict) or not isinstance(value.get("tools"), list):
        raise ValueError("expected a complete tools/list result with tools array")
    result: dict[str, dict[str, Any]] = {}
    for tool in value["tools"]:
        if not isinstance(tool, dict):
            raise ValueError("tool must be an object")
        name = tool.get("name")
        if not isinstance(name, str) or not name or name in result:
            raise ValueError("tool name missing, invalid, or duplicated")
        if not isinstance(tool.get("description"), str):
            raise ValueError(f"{name}: missing description")
        schema = tool.get("inputSchema")
        if not isinstance(schema, dict) or schema.get("type") != "object":
            raise ValueError(f"{name}: missing object inputSchema")
        annotations = tool.get("annotations")
        if not isinstance(annotations, dict) or type(annotations.get("readOnlyHint")) is not bool:
            raise ValueError(f"{name}: readOnlyHint not observed")
        if "outputSchema" in tool and not isinstance(tool["outputSchema"], dict):
            raise ValueError(f"{name}: invalid outputSchema")
        result[name] = {key: tool[key] for key in FIELDS if key in tool}
    if not result:
        raise ValueError("empty catalogue cannot qualify this workflow")
    return result


def compare_catalogs(local: Any, hosted: Any) -> dict[str, Any]:
    a, b = catalog_tools(local), catalog_tools(hosted)
    changed = {
        name: [key for key in FIELDS if (key in a[name]) != (key in b[name]) or a[name].get(key) != b[name].get(key)]
        for name in sorted(a.keys() & b.keys()) if a[name] != b[name]
    }
    missing, extra = sorted(a.keys() - b.keys()), sorted(b.keys() - a.keys())
    return {
        "disposition": "CATALOG_METADATA_MATCH" if not (missing or extra or changed) else "CATALOG_METADATA_MISMATCH",
        "local_count": len(a), "hosted_count": len(b),
        "missing_from_hosted": missing, "extra_in_hosted": extra,
        "changed_fields": changed,
        "non_claim": "Does not verify source provenance, permissions, dispatch, or description truth.",
    }


def fixture_input() -> dict[str, Any]:
    return {
        "schema": "conduit-supervisor-input-v1", "nonce": secrets.token_hex(16),
        "rows": [
            {"id": "delta", "enabled": True, "value": -4},
            {"id": "alpha", "enabled": True, "value": 17},
            {"id": "charlie", "enabled": False, "value": 1000},
            {"id": "bravo", "enabled": True, "value": 0},
        ],
    }


def expected_result(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"schema", "nonce", "rows"}:
        raise ValueError("invalid input shape")
    if value["schema"] != "conduit-supervisor-input-v1":
        raise ValueError("unsupported input schema")
    nonce = value["nonce"]
    if not isinstance(nonce, str) or not nonce:
        raise ValueError("missing nonce")
    if not isinstance(value["rows"], list):
        raise ValueError("rows must be a list")
    ids: set[str] = set()
    selected: list[str] = []
    total = 0
    for row in value["rows"]:
        if not isinstance(row, dict) or set(row) != {"id", "enabled", "value"}:
            raise ValueError("invalid row shape")
        key = row["id"]
        if not isinstance(key, str) or not key or key in ids:
            raise ValueError("row ID missing or duplicated")
        if type(row["enabled"]) is not bool or type(row["value"]) is not int:
            raise ValueError("row enabled/value types invalid")
        ids.add(key)
        if row["enabled"]:
            selected.append(key)
            total += row["value"]
    return {
        "schema": "conduit-supervisor-result-v1", "nonce": nonce,
        "accepted_ids": sorted(selected), "total": total,
    }


def verify_result(source: Any, actual: Any) -> bool:
    expected = expected_result(source)
    if not isinstance(actual, dict) or set(actual) != set(expected):
        return False
    if type(actual.get("total")) is not int:
        return False
    return actual == expected


def create_fixture(root: Path) -> dict[str, Any]:
    # Caller chooses the path; existing paths are never repurposed.
    if not root.parent.is_dir():
        raise ValueError("fixture parent must already exist")
    root.mkdir(mode=0o700, exist_ok=False)
    value = fixture_input()
    raw = (json.dumps(value, indent=2) + "\n").encode()
    with (root / "input.json").open("xb") as handle:
        handle.write(raw)
    with (root / "AGENTS.md").open("x") as handle:
        handle.write(
            "# Disposable supervisor fixture\n\n"
            "Read only input.json and the result.json produced by this task. "
            "Write only result.json when instructed. Do not inspect parent directories, "
            "credentials, external repositories, networks, or provider history. "
            "No package installs, subprocess trees, or delegation. Report an unavailable "
            "input rather than inventing it. This file is a task scope, not a security sandbox.\n"
        )
    return {"disposition": "FIXTURE_CREATED", "input_sha256": digest(raw), "nonce": value["nonce"]}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    cat = commands.add_parser("catalog")
    cat.add_argument("local", type=Path)
    cat.add_argument("hosted", type=Path)
    fixture = commands.add_parser("fixture")
    fixture.add_argument("directory", type=Path)
    verify = commands.add_parser("verify")
    verify.add_argument("directory", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "catalog":
            local, lh = read_json(args.local)
            hosted, hh = read_json(args.hosted)
            result = compare_catalogs(local, hosted)
            result.update(local_sha256=lh, hosted_sha256=hh)
            passed = result["disposition"] == "CATALOG_METADATA_MATCH"
        elif args.command == "fixture":
            result = create_fixture(args.directory)
            passed = True
        else:
            if args.directory.is_symlink():
                raise ValueError("fixture directory must not be a symlink")
            source, sh = read_json(args.directory / "input.json")
            actual, ah = read_json(args.directory / "result.json")
            passed = verify_result(source, actual)
            result = {"disposition": "ARTIFACT_MATCH" if passed else "ARTIFACT_MISMATCH",
                      "input_sha256": sh, "result_sha256": ah,
                      "non_claim": "Caller must separately verify input pin, scope, lineage, and independent evidence."}
        print(json.dumps(result, sort_keys=True, indent=2))
        return 0 if passed else 1
    except (OSError, ValueError, TypeError, RecursionError) as exc:
        print(json.dumps({"disposition": "INVALID_OR_UNAVAILABLE", "error": str(exc)}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
