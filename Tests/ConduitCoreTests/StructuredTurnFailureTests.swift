import XCTest
@testable import ConduitCore

/// Regression coverage for OBS-2: provider error termination reported as
/// successful completion.
///
/// Observed 2026-09-04. OpenCode died with
/// `ProviderModelNotFoundError: Model not found: opencode/deepseek-v4-flash-free`
/// and authored no assistant output. Sixteen seconds later the control plane
/// reported `turn.state: completed`, `checkpoint: structured_completed`,
/// `checkpoint_authority: toolReported`.
///
/// Contract §3 forbids equating turn exit with task success. This is the
/// direction an orchestrator acts on wrongly: it advances a plan on work that
/// never happened.
final class StructuredTurnFailureTests: XCTestCase {

    private func source(
        adapter: ConduitSessionAdapterSnapshot?,
        backend: AgentSessionBackend = .appServer
    ) -> ConduitSessionEventSource {
        ConduitSessionEventSource(
            taskSessionID: "TASK",
            backend: backend,
            sessionLifecycle: "running",
            runtimeState: "running",
            live: true,
            ready: true,
            events: [],
            adapter: adapter
        )
    }

    // MARK: - The defect

    func testProviderFailureIsNotReportedAsCompleted() {
        // The exact shape of the OpenCode failure: the adapter reported a
        // terminal status AND a provider error.
        let snapshot = ConduitSessionEventExport.turnSnapshot(
            source: source(
                adapter: ConduitSessionAdapterSnapshot(
                    threadID: "ses_f958a07f",
                    turnActive: false,
                    lastTurnStatus: "completed",
                    lastError: "ProviderModelNotFoundError: Model not found"
                )
            )
        )
        XCTAssertEqual(
            snapshot.state,
            "failed",
            "A turn that died in the provider is not a completed turn."
        )
        XCTAssertTrue(
            (snapshot.honesty ?? "").lowercased().contains("not completion"),
            "The honesty line must say plainly that this is not completion; "
                + "it is what a human reads when the machine state is ambiguous."
        )
    }

    func testProviderFailureCheckpointIsNotStructuredCompleted() {
        let observation = ConduitSessionEventExport.observationSnapshot(
            source: source(
                adapter: ConduitSessionAdapterSnapshot(
                    turnActive: false,
                    lastTurnStatus: "completed",
                    lastError: "ProviderModelNotFoundError: Model not found"
                )
            )
        )
        XCTAssertEqual(observation.checkpoint, .structuredFailed)
        XCTAssertNotEqual(
            observation.checkpoint,
            .structuredCompleted,
            "This is the reading that told an orchestrator the work was done."
        )
    }

    func testFailureIsDetectedFromTheProviderSignalNotStatusText() {
        // No lexical inference: a status that merely *says* something is not
        // what decides this. Only the adapter's own .failed signal does.
        let looksBadButDidNotFail = ConduitSessionEventExport.turnSnapshot(
            source: source(
                adapter: ConduitSessionAdapterSnapshot(
                    turnActive: false,
                    lastTurnStatus: "wrote error-handling for the failed login path",
                    lastError: nil
                )
            )
        )
        XCTAssertEqual(
            looksBadButDidNotFail.state,
            "completed",
            "A status string mentioning failure is not a provider failure."
        )
    }

    // MARK: - Ordering and boundaries

    func testFailureOutranksATerminalStatus() {
        // The completion branch used to fire on any non-nil lastTurnStatus, so
        // the failure check has to come first.
        let snapshot = ConduitSessionEventExport.turnSnapshot(
            source: source(
                adapter: ConduitSessionAdapterSnapshot(
                    turnActive: false,
                    lastTurnStatus: "done",
                    lastError: "connection reset"
                )
            )
        )
        XCTAssertEqual(snapshot.state, "failed")
        XCTAssertEqual(snapshot.status, "done", "The raw status is preserved.")
    }

    func testAnActiveTurnStillReadsActiveEvenWithAStaleError() {
        // A prior turn's error must not mark a running turn as failed.
        let snapshot = ConduitSessionEventExport.turnSnapshot(
            source: source(
                adapter: ConduitSessionAdapterSnapshot(
                    turnActive: true,
                    lastError: "earlier failure"
                )
            )
        )
        XCTAssertEqual(snapshot.state, "active")
    }

    func testPendingApprovalOutranksAStaleError() {
        let snapshot = ConduitSessionEventExport.turnSnapshot(
            source: source(
                adapter: ConduitSessionAdapterSnapshot(
                    turnActive: false,
                    pendingApproval: true,
                    lastError: "earlier failure"
                )
            )
        )
        XCTAssertEqual(snapshot.state, "awaiting_input")
    }

    func testEmptyErrorStringIsNotAFailure() {
        let snapshot = ConduitSessionEventExport.turnSnapshot(
            source: source(
                adapter: ConduitSessionAdapterSnapshot(
                    turnActive: false,
                    lastTurnStatus: "completed",
                    lastError: ""
                )
            )
        )
        XCTAssertEqual(snapshot.state, "completed")
    }

    func testCleanCompletionIsUnchanged() {
        let snapshot = ConduitSessionEventExport.turnSnapshot(
            source: source(
                adapter: ConduitSessionAdapterSnapshot(
                    turnActive: false,
                    lastTurnStatus: "completed"
                )
            )
        )
        XCTAssertEqual(snapshot.state, "completed")
        XCTAssertEqual(
            ConduitSessionEventExport.observationSnapshot(
                source: source(
                    adapter: ConduitSessionAdapterSnapshot(
                        turnActive: false,
                        lastTurnStatus: "completed"
                    )
                )
            ).checkpoint,
            .structuredCompleted
        )
    }

    // MARK: - Published contract

    func testCatalogPublishesBothNewValues() {
        // A client that snapshots tools/list must be able to see the states it
        // is told to branch on.
        guard let tool = ConduitSessionToolCatalog.tool(named: "conduit_session_events"),
              let schema = tool["outputSchema"] as? [String: Any],
              let props = schema["properties"] as? [String: Any],
              let turn = props["turn"] as? [String: Any],
              let turnProps = turn["properties"] as? [String: Any],
              let state = turnProps["state"] as? [String: Any],
              let states = state["enum"] as? [String]
        else { return XCTFail("turn.state enum missing from published schema") }
        XCTAssertTrue(states.contains("failed"))

        guard let observation = props["observation"] as? [String: Any],
              let obsProps = observation["properties"] as? [String: Any],
              let checkpoint = obsProps["checkpoint"] as? [String: Any],
              let checkpoints = checkpoint["enum"] as? [String]
        else { return XCTFail("checkpoint enum missing from published schema") }
        XCTAssertTrue(checkpoints.contains("structured_failed"))
    }

    func testCloseDescriptionDisclosesTheAsymmetry() {
        // close_session stops a structured adapter but only detaches tmux, and
        // the structured task cannot be reconciled afterwards. Saying only
        // "this does not delete task history" understated that.
        let tool = ConduitSessionToolCatalog.tool(named: "conduit_close_session")
        let description = tool?["description"] as? String ?? ""
        XCTAssertTrue(description.contains("recoverable"))
        XCTAssertTrue(description.lowercased().contains("not recoverable"))
    }
}
