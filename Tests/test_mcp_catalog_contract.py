"""Offline catalogue pressure controls; no canary or listener is invoked."""

import copy
import importlib.util
from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "scripts" / "mcp_catalog_contract.py"
SPEC = importlib.util.spec_from_file_location("mcp_catalog_contract", SOURCE)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class MCPCatalogContractTests(unittest.TestCase):
    def setUp(self):
        self.identity = "2026-10-03.1"
        self.tools = [
            {"name": name, "description": f"Description. [Conduit MCP catalog {self.identity}]",
             "annotations": {"readOnlyHint": read_only}}
            for name, read_only in [
                ("conduit_list_projects", True),
                ("conduit_create_task", False),
                ("conduit_adopt_provider_session", False),
            ]
        ]
        self.contract = {
            "catalog_identity": self.identity,
            "server_version": "1.3",
            "create_task_objective_delivery": MODULE.OBJECTIVE_DELIVERY_CONTRACT,
            "tool_names": [tool["name"] for tool in self.tools],
            "write_tool_names": [tool["name"] for tool in self.tools if not tool["annotations"]["readOnlyHint"]],
        }
        self.server = {"name": "conduit-session", "version": "1.3"}

    def check(self, tools=None, contract=None, server=None):
        return MODULE.catalog_alignment(
            self.tools if tools is None else tools,
            self.contract if contract is None else contract,
            self.server if server is None else server,
        )

    def assert_refused(self, expected_issue):
        result = self.check()
        self.assertFalse(result["catalog_aligned"])
        self.assertIn(expected_issue, result["catalog_alignment_issues"])

    def test_official_suffix_compiles_and_complete_fixture_aligns(self):
        match = MODULE.CATALOG_MARKER.search(self.tools[0]["description"])
        self.assertEqual(match.group(1), self.identity)
        result = self.check()
        self.assertTrue(result["catalog_aligned"])
        self.assertEqual(result["marked_tool_count"], len(self.tools))
        self.assertEqual(result["catalog_alignment_issues"], [])

    def test_unmarked_tool_refuses_partial_catalogue(self):
        self.tools[1]["description"] = "Unmarked tool"
        self.assert_refused("tool_marker_missing_or_malformed")

    def test_missing_tool_refuses_truncated_catalogue(self):
        self.tools.pop()
        self.assert_refused("catalogue_runtime_tool_set_mismatch")

    def test_unknown_tool_refuses_expanded_catalogue(self):
        tool = copy.deepcopy(self.tools[0])
        tool["name"] = "conduit_unknown"
        self.tools.append(tool)
        self.assert_refused("catalogue_runtime_tool_set_mismatch")

    def test_mixed_markers_refuse(self):
        self.tools[1]["description"] = "Description. [Conduit MCP catalog stale.1]"
        self.assert_refused("catalogue_identity_missing_or_mixed")

    def test_uniform_stale_marker_refuses_runtime_mismatch(self):
        for tool in self.tools:
            tool["description"] = "Description. [Conduit MCP catalog stale.1]"
        self.assert_refused("catalogue_runtime_identity_mismatch")

    def test_duplicate_tool_name_refuses(self):
        self.tools.append(copy.deepcopy(self.tools[0]))
        self.assert_refused("tool_name_duplicate")

    def test_wrong_prefix_empty_identity_trailing_prose_and_newline_refuse(self):
        for description in [
            "[Other MCP catalog 2026-10-03.1]",
            "[Conduit MCP catalog ]",
            "[Conduit MCP catalog 2026-10-03.1] trailing",
            "[Conduit MCP catalog 2026-10-03.1]\n",
            "[Conduit MCP catalog 2026-10-03.1][Conduit MCP catalog 2026-10-03.1]",
            "[Conduit MCP catalog 2026-10-03.1",
        ]:
            with self.subTest(description=description):
                self.tools[0]["description"] = description
                self.assert_refused("tool_marker_missing_or_malformed")

    def test_non_objects_and_non_strings_refuse_without_exception(self):
        for tools in [[], {}, "tools", [None], [{"name": 7, "description": [], "annotations": {}}]]:
            with self.subTest(tools=tools):
                self.assertFalse(self.check(tools=tools)["catalog_aligned"])

    def test_missing_runtime_metadata_refuses(self):
        self.assertFalse(self.check(contract={})["catalog_aligned"])
        self.assertFalse(MODULE.catalog_alignment(self.tools, None, self.server)["catalog_aligned"])

    def test_invalid_runtime_footprints_refuse_without_exception(self):
        for value in [None, "tool", [None], [[]], ["a", "a"], [" "]]:
            with self.subTest(value=value):
                self.contract["tool_names"] = value
                self.assert_refused("runtime_tool_names_missing_or_malformed")

    def test_changed_read_write_classification_refuses(self):
        self.tools[0]["annotations"]["readOnlyHint"] = False
        self.assert_refused("catalogue_runtime_write_set_mismatch")

    def test_non_boolean_classification_refuses(self):
        self.tools[0]["annotations"]["readOnlyHint"] = 1
        self.assert_refused("tool_read_write_classification_missing_or_malformed")

    def test_runtime_write_outside_catalogue_refuses(self):
        self.contract["write_tool_names"].append("unknown")
        self.assert_refused("runtime_write_set_outside_catalogue")

    def test_initialize_server_version_mismatch_refuses(self):
        self.server["version"] = "stale"
        self.assert_refused("initialize_runtime_server_version_mismatch")

    def test_unknown_retry_contract_refuses(self):
        self.contract["create_task_objective_delivery"] = "queued=resend"
        self.assert_refused("runtime_objective_delivery_contract_missing_or_unknown")


if __name__ == "__main__":
    unittest.main()
