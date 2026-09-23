#!/usr/bin/env python3
"""Deterministic schema and control checks for the Slice 10 result model."""
from __future__ import annotations

import copy
import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "provider-conformance.py"
MATRIX = ROOT / "docs" / "qualification" / "provider-conformance-v1.json"
SPEC = importlib.util.spec_from_file_location("provider_conformance", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
provider_conformance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provider_conformance)


def matrix() -> dict:
    return json.loads(MATRIX.read_text(encoding="utf-8"))


def dereference(reference: str):
    path, separator, pointer = reference.partition("#")
    value = json.loads((ROOT / path).read_text(encoding="utf-8"))
    if not separator or not pointer:
        return value
    for token in pointer.lstrip("/").split("/"):
        token = token.replace("~1", "/").replace("~0", "~")
        value = value[token] if isinstance(value, dict) else value[int(token)]
    return value


class ProviderConformanceResultTests(unittest.TestCase):
    def test_committed_matrix_is_valid(self) -> None:
        self.assertEqual(provider_conformance.validate_conformance(matrix()), [])

    def test_every_target_runtime_has_every_capability_once(self) -> None:
        document = matrix()
        expected = set(provider_conformance.CAPABILITIES)
        for provider in document["providers"]:
            names = [row["capability"] for row in provider["capabilities"]]
            self.assertEqual(set(names), expected, provider["runtime"])
            self.assertEqual(len(names), len(expected), provider["runtime"])

    def test_unknown_and_unavailable_keep_bounded_reasons(self) -> None:
        document = matrix()
        for provider in document["providers"]:
            for capability in provider["capabilities"]:
                if capability["result"] in ("unknown", "unavailable"):
                    self.assertTrue(capability.get("limitation"), capability)

    def test_receipt_and_identity_pointers_resolve(self) -> None:
        document = matrix()
        references = [
            provider["receipt"]
            for provider in document["providers"]
        ]
        references.extend(
            reference
            for provider in document["providers"]
            for cell in provider["capabilities"]
            for reference in (cell.get("evidenceRef"), cell.get("identityRef"))
            if reference
        )
        references.extend(control["receipt"] for control in document["controls"])
        for reference in references:
            with self.subTest(reference=reference):
                self.assertIsNotNone(dereference(reference))

    def test_control_result_must_match_its_cell(self) -> None:
        document = matrix()
        changed = copy.deepcopy(document)
        changed["controls"][0]["result"] = "unknown"
        errors = provider_conformance.validate_conformance(changed)
        self.assertTrue(any("result does not match" in item for item in errors))

    def test_semantic_difference_requires_distinct_observations(self) -> None:
        document = matrix()
        changed = copy.deepcopy(document)
        control = next(row for row in changed["controls"] if row["type"] == "semantic_difference")
        control["comparison"]["observation"] = control["observation"]
        errors = provider_conformance.validate_conformance(changed)
        self.assertTrue(any("semantic observations must differ" in item for item in errors))

    def test_semantic_comparison_result_must_match_its_cell(self) -> None:
        document = matrix()
        changed = copy.deepcopy(document)
        control = next(row for row in changed["controls"] if row["type"] == "semantic_difference")
        control["comparison"]["result"] = "supported"
        errors = provider_conformance.validate_conformance(changed)
        self.assertTrue(any("comparison result does not match its matrix cell" in item for item in errors))


if __name__ == "__main__":
    unittest.main(verbosity=2)
