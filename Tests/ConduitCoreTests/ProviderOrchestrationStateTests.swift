import Foundation
import XCTest
@testable import ConduitCore

final class ProviderOrchestrationStateTests: XCTestCase {
    private let observed = SupervisionObservationStamp(
        authority: .providerObserved,
        freshness: .current,
        observedAt: .known(Date(timeIntervalSince1970: 1_799_956_800))
    )

    private let unknownProcess = WorkerProcessLineage(
        launcherPID: .unknown,
        processGroupID: .unknown,
        parentPID: .unknown
    )

    private let unknownWorkspace = WorkerWorkspaceLineage(
        projectSlug: .unknown,
        cwd: .unknown,
        repositoryRoot: .unknown,
        worktree: .unknown
    )

    private let unfinished = WorkerTerminalState(
        receipt: .unknown,
        verification: .notPerformed,
        objectiveAcceptance: .pending
    )

    func testDiscoveredExternalOpenCodeSessionKeepsExactProviderIdentityWithoutInventingConduitBinding() {
        // Static fixture derived from #52's externally controlled-session shape.
        // It deliberately does not depend on any live provider session.
        let lineage = WorkerLineage(
            conduitTaskID: .unknown,
            runtimeAttemptID: .unknown,
            runtime: .known("OpenCode"),
            adapter: .known("http-server"),
            providerHostID: .unknown,
            providerSessionID: .known("ses_external_fixture"),
            turns: [],
            workspace: unknownWorkspace,
            process: unknownProcess,
            origin: .externalProviderClient,
            relationship: .discovered,
            writerControllerID: .unknown,
            terminal: unfinished,
            observation: observed,
            providerSpecific: .unknown
        )

        XCTAssertEqual(lineage.schemaVersion, 3)
        XCTAssertEqual(lineage.providerSessionID.value, "ses_external_fixture")
        XCTAssertEqual(lineage.relationship, .discovered)
        XCTAssertEqual(lineage.conduitTaskID.state, .unknown)
        XCTAssertEqual(lineage.runtimeAttemptID.state, .unknown)
        XCTAssertEqual(lineage.writerControllerID.state, .unknown)
    }

    func testWorkerLineageV2PayloadDecodesWithoutExecutionWorkspaceBinding() throws {
        let lineage = WorkerLineage(
            schemaVersion: 2,
            conduitTaskID: .known("task-legacy"),
            runtimeAttemptID: .known("attempt-legacy"),
            runtime: .known("OpenCode"),
            adapter: .known("http-server"),
            providerHostID: .known("host-legacy"),
            providerSessionID: .known("ses-legacy"),
            turns: [],
            workspace: unknownWorkspace,
            process: unknownProcess,
            origin: .conduit,
            relationship: .owned,
            writerControllerID: .known("controller-legacy"),
            terminal: unfinished,
            observation: observed,
            providerSpecific: .unknown
        )
        let encoded = try JSONEncoder().encode(lineage)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "executionWorkspace")
        let v2Data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(WorkerLineage.self, from: v2Data)

        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertNil(decoded.executionWorkspace)
        XCTAssertEqual(decoded.providerSessionID.value, "ses-legacy")
        XCTAssertEqual(decoded.workspace, unknownWorkspace)
    }

    func testModelIdentityIsTurnScopedAndCanChangeInsideOneProviderSession() {
        let first = ProviderTurnLineage(
            turnID: .known("turn-1"),
            state: .completed,
            model: .known(
                ProviderModelIdentity(
                    providerID: "xai",
                    modelID: "grok-fixture"
                )
            ),
            observation: observed
        )
        let second = ProviderTurnLineage(
            turnID: .known("turn-2"),
            state: .active,
            model: .known(
                ProviderModelIdentity(
                    providerID: "opencode",
                    modelID: "muse-fixture"
                )
            ),
            observation: observed
        )

        let lineage = WorkerLineage(
            conduitTaskID: .known("task-1"),
            runtimeAttemptID: .known("attempt-1"),
            runtime: .known("OpenCode"),
            adapter: .known("http-server"),
            providerHostID: .known("host-1"),
            providerSessionID: .known("ses-shared"),
            turns: [first, second],
            workspace: unknownWorkspace,
            process: unknownProcess,
            origin: .conduit,
            relationship: .owned,
            writerControllerID: .known("controller-1"),
            terminal: unfinished,
            observation: observed,
            providerSpecific: .known(
                ProviderSpecificPayload(
                    namespace: "opencode",
                    value: .object([
                        "provider_status": .string("running"),
                        "cost": .number(0),
                        "permission_pending": .bool(false),
                    ])
                )
            )
        )

        XCTAssertEqual(lineage.turns[0].model.value?.providerID, "xai")
        XCTAssertEqual(lineage.turns[0].model.value?.modelID, "grok-fixture")
        XCTAssertEqual(lineage.turns[1].model.value?.providerID, "opencode")
        XCTAssertEqual(lineage.turns[1].model.value?.modelID, "muse-fixture")
    }

    func testProviderSpecificPayloadPreservesNamespaceTypesAndNesting() throws {
        let payload = ProviderSpecificPayload(
            namespace: "opencode",
            schemaVersion: 3,
            value: .object([
                "status": .string("running"),
                "cost": .number(1.25),
                "flags": .array([.bool(true), .null]),
            ])
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(
            ProviderSpecificPayload.self,
            from: data
        )

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.namespace, "opencode")
        XCTAssertEqual(decoded.schemaVersion, 3)
    }

    func testUnknownSurvivesJSONRoundTripAsExplicitState() throws {
        let value: OrchestrationValue<String> = .unknown
        let data = try JSONEncoder().encode(value)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(#""state":"unknown""#))
        XCTAssertFalse(json.contains(#""value""#))
        XCTAssertEqual(
            try JSONDecoder().decode(
                OrchestrationValue<String>.self,
                from: data
            ),
            value
        )
    }

    func testUnknownDecoderRejectsSmuggledValue() {
        let data = Data(#"{"state":"unknown","value":"should-not-exist"}"#.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                OrchestrationValue<String>.self,
                from: data
            )
        )
    }

    func testTypedDeliveryDoesNotCollapseShellInputIntoAgentPrompt() {
        let shell = PromptDeliveryRecord(
            eventID: .known("event-shell"),
            transport: .shellStdin,
            state: .accepted,
            contentDigest: .known("aaa"),
            queuedBehindActiveTurn: .known(false),
            providerTurnID: .unknown
        )
        let agent = PromptDeliveryRecord(
            eventID: .known("event-agent"),
            transport: .agentPrompt,
            state: .queued,
            contentDigest: .known("bbb"),
            queuedBehindActiveTurn: .known(true),
            providerTurnID: .unknown
        )

        XCTAssertEqual(shell.transport, .shellStdin)
        XCTAssertEqual(agent.transport, .agentPrompt)
        XCTAssertEqual(agent.state, .queued)
        XCTAssertEqual(agent.queuedBehindActiveTurn.value, true)
        XCTAssertNotEqual(shell.transport, agent.transport)
    }

    func testProviderTurnStateCoversEveryDeclaredLifecycleCase() throws {
        let states: [ProviderTurnState] = [
            .queued,
            .accepted,
            .active,
            .awaitingInput,
            .completed,
            .cancelled,
            .failed,
            .ambiguous,
        ]

        XCTAssertEqual(states.count, 8)
        XCTAssertEqual(Set(states.map(\.rawValue)).count, 8)

        for state in states {
            let data = try JSONEncoder().encode(state)
            XCTAssertEqual(try JSONDecoder().decode(ProviderTurnState.self, from: data), state)
        }
    }

    func testProviderCompletionAndObjectiveAcceptanceRemainIndependent() {
        let turn = ProviderTurnLineage(
            turnID: .known("turn-1"),
            state: .completed,
            model: .unknown,
            observation: observed
        )
        let terminal = WorkerTerminalState(
            receipt: .present,
            verification: .notPerformed,
            objectiveAcceptance: .pending
        )

        XCTAssertEqual(turn.state, .completed)
        XCTAssertEqual(terminal.objectiveAcceptance, .pending)
        XCTAssertEqual(terminal.verification, .notPerformed)
    }

    func testLifecyclePreflightCanRepresentStructuredStopAndPTYDetachWithoutFlatteningThem() {
        let structured = LifecyclePreflight(
            operation: .stopProviderHost,
            target: LifecycleTarget(
                kind: .providerHost,
                identifier: .known("opencode-host-1")
            ),
            support: .supported,
            willStopProvider: .known(true),
            willReleaseSlot: .known(true),
            recoverableAfterward: .known(false),
            exactResumeHandle: .unknown,
            expectedProcessScope: .known(.providerHost),
            knownDescendantPIDs: .unknown,
            sideEffects: .known(["provider host stops"]),
            unsupportedConsequences: .known([]),
            observation: observed
        )
        let ptyDetach = LifecyclePreflight(
            operation: .releaseSupervision,
            target: LifecycleTarget(
                kind: .session,
                identifier: .known("tmux-session-1")
            ),
            support: .supported,
            willStopProvider: .known(false),
            willReleaseSlot: .known(true),
            recoverableAfterward: .known(true),
            exactResumeHandle: .known("tmux-session-1"),
            expectedProcessScope: .known(.none),
            knownDescendantPIDs: .unknown,
            sideEffects: .known(["Conduit supervision detaches"]),
            unsupportedConsequences: .known([]),
            observation: observed
        )

        XCTAssertEqual(structured.willStopProvider.value, true)
        XCTAssertEqual(structured.recoverableAfterward.value, false)
        XCTAssertEqual(ptyDetach.willStopProvider.value, false)
        XCTAssertEqual(ptyDetach.recoverableAfterward.value, true)
        XCTAssertEqual(ptyDetach.exactResumeHandle.value, "tmux-session-1")
    }

    func testLifecyclePreflightV1PayloadDecodesWithUnknownNewConsequences() throws {
        let legacy = LifecyclePreflight(
            schemaVersion: 1,
            operation: .releaseSupervision,
            target: LifecycleTarget(
                kind: .session,
                identifier: .known("tmux-legacy")
            ),
            support: .supported,
            willStopProvider: .known(false),
            willReleaseSlot: .known(true),
            recoverableAfterward: .known(true),
            exactResumeHandle: .known("tmux-legacy"),
            expectedProcessScope: .known(.none),
            knownDescendantPIDs: .unknown,
            sideEffects: .known(["detach"]),
            unsupportedConsequences: .known([]),
            unknownConsequences: .known(["new-field-placeholder"]),
            observation: observed
        )
        let encoded = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "unknownConsequences")
        let v1Data = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(
            LifecyclePreflight.self,
            from: v1Data
        )

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.unknownConsequences.state, .unknown)
        XCTAssertEqual(decoded.operation, .releaseSupervision)
    }

    func testUnsupportedLifecycleOperationStaysUnsupportedInsteadOfMappingToStop() {
        let preflight = LifecyclePreflight(
            operation: .releaseSupervision,
            target: LifecycleTarget(
                kind: .session,
                identifier: .known("ses-provider")
            ),
            support: .unsupported,
            willStopProvider: .unknown,
            willReleaseSlot: .unknown,
            recoverableAfterward: .unknown,
            exactResumeHandle: .known("ses-provider"),
            expectedProcessScope: .unknown,
            knownDescendantPIDs: .unknown,
            sideEffects: .unknown,
            unsupportedConsequences: .known([
                "provider does not expose release-with-host-continuing"
            ]),
            observation: SupervisionObservationStamp(
                authority: .providerObserved,
                freshness: .current,
                observedAt: .unknown
            )
        )

        XCTAssertEqual(preflight.support, .unsupported)
        XCTAssertEqual(preflight.willStopProvider.state, .unknown)
        XCTAssertEqual(preflight.unsupportedConsequences.value?.count, 1)
    }
}
