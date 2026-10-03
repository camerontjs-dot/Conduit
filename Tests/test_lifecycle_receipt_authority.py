"""Regression guard for stop_provider_host receipt authority.

This test keeps the public/session API authority text aligned with the process-tree
cleanup receipt. It is intentionally source-level; machine-bound qualification
still exercises the real Session API dispatch.
"""

from __future__ import annotations

import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP_MODEL = ROOT / "Sources/Conduit/AppModel.swift"


class LifecycleReceiptAuthorityTests(unittest.TestCase):
    def test_stop_provider_host_authority_does_not_deny_recorded_cleanup(self) -> None:
        source = APP_MODEL.read_text(encoding="utf-8")
        self.assertNotIn("descendants are not inspected or signaled", source)
        receipt_phrase = (
            "Process-tree reconciliation and any bounded owned-descendant cleanup "
            "are reported in process_tree_reconciliation"
        )
        self.assertGreaterEqual(source.count(receipt_phrase), 4)

        cleanup_call = source.index(
            "processTreeReconciliation = sessionAPICleanupOwnedResidualDescendants("
        )
        receipt_field = source.index(
            '"process_tree_reconciliation": sessionAPIJSONObject(',
            cleanup_call,
        )
        pending_direct_pty = source.index(
            'payload["completion"] = "pending_process_observation"',
            receipt_field,
        )
        self.assertLess(cleanup_call, receipt_field)
        self.assertLess(receipt_field, pending_direct_pty)


if __name__ == "__main__":
    unittest.main()
