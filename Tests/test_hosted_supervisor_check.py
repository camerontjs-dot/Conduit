"""Synthetic apparatus controls, not Conduit/provider qualification."""
import contextlib
import copy
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "hosted-supervisor-check.py"
SPEC = importlib.util.spec_from_file_location("hosted_supervisor_check", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def catalog():
    return {"tools": [{"name": "read_task", "description": "Observe only.",
                       "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": True}},
                      {"name": "create_task", "description": "Queued means do not resend.",
                       "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": False}}]}


class HostedSupervisorCheckTests(unittest.TestCase):
    def test_identical_catalog(self):
        self.assertEqual(CHECK.compare_catalogs(catalog(), catalog())["disposition"], "CATALOG_METADATA_MATCH")

    def test_order_invariance(self):
        other = catalog()
        other["tools"].reverse()
        self.assertEqual(CHECK.compare_catalogs(catalog(), other)["disposition"], "CATALOG_METADATA_MATCH")

    def test_missing_tool(self):
        other = catalog()
        other["tools"].pop()
        self.assertEqual(CHECK.compare_catalogs(catalog(), other)["missing_from_hosted"], ["create_task"])

    def test_stale_resend_guidance(self):
        other = catalog()
        other["tools"][1]["description"] = "Immediate delivery failed; resend."
        self.assertEqual(CHECK.compare_catalogs(catalog(), other)["changed_fields"], {"create_task": ["description"]})

    def test_annotation_and_schema_changes(self):
        other = catalog()
        other["tools"][1]["annotations"]["readOnlyHint"] = True
        other["tools"][1]["inputSchema"]["required"] = ["agent"]
        self.assertEqual(CHECK.compare_catalogs(catalog(), other)["changed_fields"]["create_task"], ["inputSchema", "annotations"])

    def test_duplicate_tools_rejected(self):
        other = catalog()
        other["tools"].append(copy.deepcopy(other["tools"][0]))
        with self.assertRaises(ValueError):
            CHECK.catalog_tools(other)

    def test_missing_annotations_not_invented(self):
        other = catalog()
        del other["tools"][0]["annotations"]
        with self.assertRaises(ValueError):
            CHECK.catalog_tools(other)

    def test_empty_and_rpc_error_rejected(self):
        for other in [{"tools": []}, {"result": catalog(), "error": {"code": -1}}]:
            with self.assertRaises(ValueError):
                CHECK.catalog_tools(other)

    def test_artifact_positive_and_wrong_total(self):
        source = CHECK.fixture_input()
        result = {"schema": "conduit-supervisor-result-v1", "nonce": source["nonce"],
                  "accepted_ids": ["alpha", "bravo", "delta"], "total": 13}
        self.assertTrue(CHECK.verify_result(source, result))
        result["total"] = 1013
        self.assertFalse(CHECK.verify_result(source, result))

    def test_stale_nonce_false_pass_and_extra_fields(self):
        source = CHECK.fixture_input()
        for key, value in [("nonce", "stale"), ("total", True), ("approved", True)]:
            result = CHECK.expected_result(source)
            result[key] = value
            self.assertFalse(CHECK.verify_result(source, result))

    def test_disabled_row_invariance(self):
        source = CHECK.fixture_input()
        expected = CHECK.expected_result(source)
        source["rows"][2]["value"] = -9999
        self.assertEqual(CHECK.expected_result(source), expected)

    def test_enabled_row_sensitivity(self):
        source = CHECK.fixture_input()
        result = CHECK.expected_result(source)
        source["rows"][0]["value"] += 1
        self.assertFalse(CHECK.verify_result(source, result))

    def test_input_types_and_duplicate_ids(self):
        for key, value in [("enabled", "true"), ("value", True), ("id", "alpha")]:
            source = CHECK.fixture_input()
            source["rows"][0][key] = value
            with self.assertRaises(ValueError):
                CHECK.expected_result(source)

    def test_fixture_no_overwrite(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "case"
            CHECK.create_fixture(root)
            before = (root / "input.json").read_bytes()
            with self.assertRaises(FileExistsError):
                CHECK.create_fixture(root)
            self.assertEqual((root / "input.json").read_bytes(), before)
            self.assertFalse((root / "result.json").exists())

    def test_duplicate_json_keys_rejected(self):
        with tempfile.TemporaryDirectory() as parent:
            path = Path(parent) / "bad.json"
            path.write_text('{"tools": [], "tools": []}')
            with self.assertRaises(ValueError):
                CHECK.read_json(path)

    def test_cli_missing_artifact_fails_closed(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "case"
            CHECK.create_fixture(root)
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = CHECK.main(["verify", str(root)])
            self.assertEqual(code, 2)
            self.assertEqual(json.loads(output.getvalue())["disposition"], "INVALID_OR_UNAVAILABLE")

    def test_cli_positive_and_negative(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "case"
            CHECK.create_fixture(root)
            source, _ = CHECK.read_json(root / "input.json")
            actual = CHECK.expected_result(source)
            for wanted in [0, 1]:
                (root / "result.json").write_text(json.dumps(actual))
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(CHECK.main(["verify", str(root)]), wanted)
                actual["total"] += 1

    def test_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as parent:
            target = Path(parent) / "target.json"
            target.write_text('{}')
            link = Path(parent) / "link.json"
            link.symlink_to(target)
            with self.assertRaises(ValueError):
                CHECK.read_json(link)


if __name__ == "__main__":
    unittest.main()
