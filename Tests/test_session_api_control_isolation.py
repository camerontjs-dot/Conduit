from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Sources" / "Conduit" / "AppModel.swift"
SERVICES = ROOT / "Sources" / "Conduit" / "Services.swift"


def region(source: str, beginning: str, ending: str) -> str:
    start = source.index(beginning)
    finish = source.index(ending, start)
    return source[start:finish]


class HostedControlPresentationContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = APP.read_text(encoding="utf-8")

    def test_create_uses_hosted_origin_and_keeps_operator_selection(self):
        dispatch = region(
            self.source,
            "private func sessionAPICreateTask(",
            "private func sessionAPIReconcileTask(",
        )
        create = region(
            self.source,
            "private func createTask(\n        agent:",
            "    func renameTask(",
        )
        start = region(
            self.source,
            "    private func start(\n",
            "    // MARK: - Durable session discovery",
        )

        self.assertIn("origin: .sessionAPI", dispatch)
        self.assertIn("if origin.updatesOperatorPresentation {\n            selectProject(scannedProject)", create)
        self.assertIn("if runtime != nil, origin.updatesOperatorPresentation", create)
        self.assertIn("if origin.updatesOperatorPresentation {\n            _ = selectSession(runtime)", start)
        self.assertNotIn("UserDefaults.standard.set(scannedProject.id", create)
        self.assertNotIn("showNewTask = false", start)

    def test_reconcile_preserves_origin_across_deferred_history_load(self):
        dispatch = region(
            self.source,
            "private func sessionAPIReconcileTask(",
            "private func sessionAPISendPrompt(",
        )
        reconcile = region(
            self.source,
            "private func reconcileTask(\n",
            "    private func agentProfile(",
        )
        history = region(
            self.source,
            "    private func loadConversationHistory(",
            "    private func recordConversationRevision(",
        )

        self.assertIn("reconcileTask(taskID, origin: .sessionAPI)", dispatch)
        self.assertIn("reconcileAfterHistoryLoad[id] = origin", reconcile)
        self.assertIn("resume(discovered, adoptingInto: project(for: task), origin: origin)", reconcile)
        self.assertIn("origin: origin", reconcile)
        self.assertIn("reconcileTask(taskSessionID, origin: origin)", history)

    def test_lifecycle_and_close_route_through_hosted_control_helpers(self):
        lifecycle = region(
            self.source,
            "private func sessionAPILifecycleOperation(",
            "private func sessionAPIInterrupt(",
        )
        close = region(
            self.source,
            "private func sessionAPIClose(",
            "    func saveSettings(",
        )
        leave = region(
            self.source,
            "    private func leaveTask(\n",
            "    func endTask(",
        )
        close_runtime = region(
            self.source,
            "    private func closeSession(\n",
            "    func leaveActiveSession(",
        )
        end_runtime = region(
            self.source,
            "    private func endSession(\n",
            "    /// End the current runtime",
        )
        remove = region(
            self.source,
            "    private func removeSessionTab(",
            "    func sendComposer(",
        )

        self.assertIn("leaveTask(taskID, origin: .sessionAPI)", lifecycle)
        self.assertIn("endSession(runtime, origin: .sessionAPI)", lifecycle)
        self.assertIn("leaveTask(taskID, origin: .sessionAPI)", close)
        self.assertIn("closeSession(runtime, origin: origin)", leave)
        self.assertIn("removeSessionTab(runtime, origin: origin)", close_runtime + end_runtime)
        self.assertIn("if origin.updatesOperatorPresentation", remove)
        self.assertIn("lastSelectedSessionIDByProject[projectID] = nil", remove)
        self.assertIn("activeSessionID = nil", remove)

    def test_session_api_reconnect_and_send_do_not_select_or_switch_presentation(self):
        send = region(
            self.source,
            "private func sessionAPISendPrompt(",
            "private func sessionAPIDeliver(",
        )
        deliver = region(
            self.source,
            "private func sessionAPIDeliver(",
            "private func sessionAPILifecycleSnapshot(",
        )
        reconnect = region(
            self.source,
            "    private func reconnectTask(\n",
            "    /// Explicit MCP recovery",
        )

        self.assertIn("reconnectTask(taskID, origin: .sessionAPI)", send)
        self.assertIn("if origin.updatesOperatorPresentation", reconnect)
        self.assertNotIn("selectSession(", deliver)
        self.assertNotIn("runtime.selectedSurface = .conversation", deliver)

    def test_hosted_status_and_error_sinks_are_scoped(self):
        status = region(
            self.source,
            "    private func reportControlStatus(",
            "    @Published var isDropTargeted = false",
        )
        self.assertIn("guard origin.updatesOperatorPresentation else { return }", status)
        self.assertIn("origin.updatesOperatorPresentation || sessionAPIServingDepth > 0", status)
        self.assertIn("sessionAPIServingDepth > 0\n            ? .sessionAPI", self.source)

    def test_late_hosted_runtime_feedback_uses_the_hosted_sink(self):
        usage = region(
            self.source,
            "    private func handleUsageRecord(",
            "    /// Rows for every configured agent",
        )
        self.assertIn("runtimeControlOrigins.removeValue(forKey: runtimeAttemptID) ?? origin", usage)
        self.assertIn("bankObservedUsage(record, origin: effectiveOrigin)", usage)
        self.assertIn("origin: effectiveOrigin", usage)

    def test_prompt_feedback_follows_exact_events_in_a_shared_runtime(self):
        start = region(
            self.source,
            "    private func start(\n",
            "    // MARK: - Durable session discovery",
        )
        runtime = self.source[self.source.index("    private func recordPresentationRevision("):]
        deliver = region(
            self.source,
            "    private func sessionAPIDeliver(",
            "    private func sessionAPILifecycleSnapshot(",
        )

        self.assertIn("recordEventRevision: { [weak self] event, eventOrigin in", start)
        self.assertIn("origin: eventOrigin", start)
        self.assertIn("controlOrigin: .sessionAPI", deliver)
        self.assertIn("controlOrigin: SessionControlOrigin = .operatorUI", runtime)
        self.assertIn("controlFeedback.record(eventID: event.id, origin: controlOrigin)", runtime)
        self.assertEqual(self.source.count("recordEventRevision?("), 1)
        self.assertIn("recordEventRevision?(event, controlFeedback.origin(for: event))", runtime)

    def test_hosted_history_reload_cannot_clear_the_operator_task_selection(self):
        load = region(
            self.source,
            "    private func applyTaskSessionLoad(",
            "    private func loadConversationHistory(",
        )
        append = region(
            self.source,
            "    private func appendTaskEvent(",
            "    private func recordShellTelemetry(",
        )
        telemetry = region(
            self.source,
            "    private func recordShellTelemetry(",
            "    private func workspaceSnapshot(",
        )
        self.assertIn("if origin.updatesOperatorPresentation,", load)
        self.assertIn("applyTaskSessionLoad(taskSessionStore.load(), origin: origin)", append)
        self.assertEqual(telemetry.count("origin: origin"), 2)

    def test_hosted_slash_delivery_reuses_its_event_and_preserves_the_operator_draft(self):
        deliver = region(
            self.source,
            "    private func sessionAPIDeliver(",
            "    private func sessionAPILifecycleSnapshot(",
        )
        slash = region(
            self.source,
            "    private func sendSlashCommand(",
            "    /// Builds the terminal delivery string.",
        )
        presentation = region(
            slash,
            "        if origin.updatesOperatorPresentation {",
            "\n    }\n",
        )
        delivery_without_presentation = slash.replace(presentation, "")

        # Follow the transitive helper: checking only sessionAPIDeliver misses
        # UI mutations and duplicate prompt creation in a shared helper.
        self.assertEqual(deliver.count("runtime.recordPrompt("), 1)
        self.assertIn("origin: .sessionAPI,\n                existingEventID: eventID", deliver)
        self.assertIn("existingEventID ?? runtime.recordPrompt(", slash)
        for mutation in (
            "runtime.selectedSurface =",
            "composerText =",
            "attachments =",
            "noteComposerSendFlash()",
            "statusMessage =",
        ):
            self.assertIn(mutation, presentation)
            self.assertNotIn(mutation, delivery_without_presentation)
        self.assertIn("injectSlashCommand(trimmed) { [weak runtime] delivered in", slash)
        self.assertIn("to: delivered ? .delivered : .failed", slash)
        self.assertNotIn("updatePromptDelivery(eventID: eventID, to: .delivered)", slash)

    def test_delayed_slash_write_reports_runtime_loss_before_delivery(self):
        injection = region(
            SERVICES.read_text(encoding="utf-8"),
            "    func injectSlashCommand(",
            "    /// Runs a multi-step model-switch sequence",
        )
        delayed = injection[injection.index("DispatchQueue.main.asyncAfter("):]
        self.assertIn("self.lifecycle == .running || self.lifecycle == .launching", delayed)
        self.assertLess(delayed.index("completion?(false)"), delayed.index("self.injectControlInput("))
        self.assertLess(delayed.index("self.injectControlKey(.enter)"), delayed.index("completion?(true)"))


if __name__ == "__main__":
    unittest.main()
