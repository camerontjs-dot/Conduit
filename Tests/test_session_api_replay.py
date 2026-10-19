"""Source contracts only: these do not establish mounted runtime behavior."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / 'Sources/Conduit/AppModel.swift').read_text()

def section(start, end):
    return APP[APP.index(start):APP.index(end, APP.index(start))]

class SessionAPIReplayContract(unittest.TestCase):
    def test_send_refuses_before_admission_without_deferred_start(self):
        body = section('private func sessionAPISendPrompt(', 'private func sessionAPIDeliver(')
        self.assertIn('reconcile first with conduit_reconcile_task', body)
        self.assertLess(body.index('guard let runtime'), body.index('admission.admitPrompt'))
        for forbidden in ['reconnectTask(', 'reconcileTask(', 'loadConversationHistory(', 'DispatchQueue', 'Task {']:
            self.assertNotIn(forbidden, body)

    def test_boundary_journals_before_dispatch_and_admission_has_no_memory_dedupe(self):
        boundary = section('private func sessionAPIPayload(', 'private func sessionAPIExecute(')
        self.assertIn('sessionAPIReplayJournal!.perform(caller: caller.identity', boundary)
        self.assertIn('self.sessionAPIExecute(command, caller: caller)', boundary)
        self.assertIn('?.path.path', boundary)
        create = section('private func sessionAPICreateTask(', 'private func sessionAPIReconcileTask(')
        self.assertIn('dedupeIdentity: nil', create)
        self.assertLess(create.index('admission.admitCreate'), create.index('guard let runtime = createTask'))

    def test_ancillary_warning_does_not_use_authoritative_error_or_ui_modal(self):
        begin = section('private func beginWorkSessionIfNeeded(', 'func isReceiptWritePending(')
        self.assertIn('if origin == .sessionAPI', begin)
        self.assertIn('sessionAPIAncillaryWarnings.append(warning)', begin)
        self.assertNotIn('reportControlError(', begin)
        self.assertNotIn('errorMessage =', begin)
        execute = section('private func sessionAPIExecute(', 'private func sessionAPIDispatch(')
        self.assertIn('payload["ancillary_warnings"] = sessionAPIAncillaryWarnings', execute)
        self.assertIn('payload["error"] = raised', execute)  # authoritative errors survive
