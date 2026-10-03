"""Pure checks for tools/list and runtime MCP contract metadata.

This module reads no files, credentials or network state. Alignment covers the
supplied catalogue and runtime metadata; it cannot prove a hosted client refreshed
its cached tools or authorize a write.
"""

from __future__ import annotations

import re


CATALOG_MARKER = re.compile(r"\[Conduit MCP catalog ([A-Za-z0-9][A-Za-z0-9._-]*)\]\Z")
CATALOG_IDENTITY = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
OBJECTIVE_DELIVERY_CONTRACT = "delivered=no-resend;queued=no-resend;failed=resend-required"


def catalog_alignment(tools: object, runtime_contract: object, server_info: object) -> dict:
    """Refuse missing, malformed or contradictory catalogue observations."""
    issues: list[str] = []
    markers: set[str] = set()
    names: list[str] = []
    write_names: list[str] = []
    marked_count = 0

    def issue(code: str) -> None:
        if code not in issues:
            issues.append(code)

    if not isinstance(tools, list) or not tools:
        issue("catalogue_missing_or_malformed")
        tools = []

    for tool in tools:
        if not isinstance(tool, dict):
            issue("tool_malformed")
            continue
        name = tool.get("name")
        if not isinstance(name, str) or not name or name.strip() != name:
            issue("tool_name_missing_or_malformed")
        elif name in names:
            issue("tool_name_duplicate")
        else:
            names.append(name)
        annotations = tool.get("annotations")
        read_only = annotations.get("readOnlyHint") if isinstance(annotations, dict) else None
        if type(read_only) is not bool:
            issue("tool_read_write_classification_missing_or_malformed")
        elif not read_only and isinstance(name, str):
            write_names.append(name)
        description = tool.get("description")
        match = CATALOG_MARKER.search(description) if isinstance(description, str) else None
        if match is None or description.count("[Conduit MCP catalog ") != 1:
            issue("tool_marker_missing_or_malformed")
        else:
            markers.add(match.group(1))
            marked_count += 1

    if len(markers) != 1:
        issue("catalogue_identity_missing_or_mixed")

    contract = runtime_contract if isinstance(runtime_contract, dict) else {}
    identity = contract.get("catalog_identity")
    if not isinstance(identity, str) or CATALOG_IDENTITY.fullmatch(identity) is None:
        issue("runtime_identity_missing_or_malformed")
    elif markers != {identity}:
        issue("catalogue_runtime_identity_mismatch")

    def declared_names(key: str, allow_empty: bool = False) -> list[str] | None:
        value = contract.get(key)
        if (
            not isinstance(value, list)
            or (not value and not allow_empty)
            or any(not isinstance(name, str) or not name or name.strip() != name for name in value)
            or len(set(value)) != len(value)
        ):
            issue(f"runtime_{key}_missing_or_malformed")
            return None
        return value

    declared_tools = declared_names("tool_names")
    declared_writes = declared_names("write_tool_names", allow_empty=True)
    if declared_tools is not None and set(names) != set(declared_tools):
        issue("catalogue_runtime_tool_set_mismatch")
    if declared_writes is not None and set(write_names) != set(declared_writes):
        issue("catalogue_runtime_write_set_mismatch")
    if declared_tools is not None and declared_writes is not None:
        if not set(declared_writes).issubset(declared_tools):
            issue("runtime_write_set_outside_catalogue")

    version = contract.get("server_version")
    observed_version = server_info.get("version") if isinstance(server_info, dict) else None
    if not isinstance(version, str) or not version:
        issue("runtime_server_version_missing_or_malformed")
    elif observed_version != version:
        issue("initialize_runtime_server_version_mismatch")
    if contract.get("create_task_objective_delivery") != OBJECTIVE_DELIVERY_CONTRACT:
        issue("runtime_objective_delivery_contract_missing_or_unknown")

    return {
        "catalog_aligned": not issues,
        "catalog_markers": sorted(markers),
        "tool_count": len(tools),
        "marked_tool_count": marked_count,
        "catalog_alignment_issues": issues,
    }
