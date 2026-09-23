import Foundation
import XCTest
@testable import ConduitCore

final class ShellTelemetryTests: XCTestCase {
    private let taskID = TaskSessionID(
        rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )
    private let runtimeID = "00000000-0000-0000-0000-000000000002"
    private let executionID = "00000000-0000-0000-0000-000000000003"
    private let observedAt = Date(timeIntervalSince1970: 1_790_000_000)

    func testShellCommandExitDoesNotProjectProviderCompletion() throws {
        let started = event(.commandStarted, commandID: 1)
        let exited = event(.commandExited, commandID: 1, exitStatus: 0)
        let aliveChild = processTree(childPID: 501, childLiveness: .live)
        let processEvent = TaskSessionEvent(
            taskSessionID: taskID,
            occurredAt: observedAt.addingTimeInterval(2),
            recordedAt: observedAt.addingTimeInterval(2),
            authority: .processObserved,
            kind: .shellProcessObservationRecorded(aliveChild)
        )
        let projection = try XCTUnwrap(
            ShellTelemetryProjection.latest(
                taskSessionID: taskID,
                events: [taskEvent(started), taskEvent(exited), processEvent]
            )
        )

        XCTAssertEqual(projection.commandState(liveRuntimeAttemptID: nil), .exited)
        XCTAssertEqual(projection.latestCommandEvent?.exitStatus.value, 0)
        XCTAssertEqual(
            projection.processObservation?.descendants.first?.liveness,
            .live
        )
        XCTAssertEqual(
            projection.processObservation?.descendants.first?.commandName.value,
            "opencode"
        )
        XCTAssertEqual(
            projection.observationStamp(liveRuntimeAttemptID: nil).freshness,
            .stale
        )
        XCTAssertEqual(
            projection.observationStamp(liveRuntimeAttemptID: runtimeID).freshness,
            .current
        )
    }

    func testFreshEventLogReconstructionPreservesBoundariesWithoutRewritingSource() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-telemetry-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = TaskSessionEventLog(directory: directory, taskSessionID: taskID)
        let childAlive = processTree(childPID: 502, childLiveness: .live)
        try log.append(taskEvent(event(.executionStarted)))
        try log.append(taskEvent(event(.commandStarted, commandID: 4)))
        try log.append(taskEvent(event(.commandExited, commandID: 4, exitStatus: 0)))
        try log.append(
            TaskSessionEvent(
                taskSessionID: taskID,
                occurredAt: observedAt.addingTimeInterval(3),
                recordedAt: observedAt.addingTimeInterval(3),
                authority: .processObserved,
                kind: .shellProcessObservationRecorded(childAlive)
            )
        )
        let originalBytes = try Data(contentsOf: log.url)

        let freshLog = TaskSessionEventLog(directory: directory, taskSessionID: taskID)
        let read = freshLog.read()
        let reconstructed = try XCTUnwrap(
            ShellTelemetryProjection.latest(taskSessionID: taskID, events: read.events)
        )

        XCTAssertTrue(read.diagnostics.isEmpty)
        XCTAssertEqual(reconstructed.shellExecutionID, executionID)
        XCTAssertEqual(reconstructed.latestCommandEvent?.commandID, commandID(4))
        XCTAssertEqual(reconstructed.commandState(liveRuntimeAttemptID: nil), .exited)
        XCTAssertEqual(reconstructed.processObservation?.descendants.first?.liveness, .live)
        XCTAssertEqual(
            reconstructed.observationStamp(liveRuntimeAttemptID: nil).freshness,
            .stale
        )
        XCTAssertEqual(try Data(contentsOf: freshLog.url), originalBytes)
    }

    func testUnmatchedCommandStartRequiresCurrentHookRuntimeAndShellStillAlive() throws {
        let start = event(.commandStarted, commandID: 9)
        let active = try XCTUnwrap(
            ShellTelemetryProjection.latest(
                taskSessionID: taskID,
                events: [taskEvent(event(.executionStarted)), taskEvent(start)]
            )
        )
        XCTAssertEqual(active.commandState(liveRuntimeAttemptID: runtimeID), .active)
        XCTAssertEqual(active.commandState(liveRuntimeAttemptID: nil), .unknown)

        let exitedShell = try XCTUnwrap(
            ShellTelemetryProjection.latest(
                taskSessionID: taskID,
                events: [
                    taskEvent(event(.executionStarted)),
                    taskEvent(start),
                    taskEvent(event(.shellExited)),
                ]
            )
        )
        XCTAssertEqual(exitedShell.commandState(liveRuntimeAttemptID: runtimeID), .unknown)
    }

    func testFleetKeepsQuietCaptureSeparateFromExitedCommandAndLiveChild() throws {
        let aliveChild = processTree(childPID: 503, childLiveness: .live)
        let snapshot = FleetShellTelemetrySnapshot(
            runtimeAttemptID: .known(runtimeID),
            shellExecutionID: .known(executionID),
            phase: .known(.commandExited),
            commandID: .known(commandID(5)),
            commandState: .known(.exited),
            shellPID: .known(400),
            processGroupID: .known(400),
            workingDirectory: .known("/tmp/qualification"),
            exitStatus: .known(0),
            deliveryTransport: .known(.shellStdin),
            ptyCaptureQuiet: .unknown,
            launcherLiveness: .known(.live),
            processObservation: .known(aliveChild),
            observation: processStamp
        )
        let decoded = try JSONDecoder().decode(
            FleetShellTelemetrySnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded.commandState.value, .exited)
        XCTAssertEqual(decoded.ptyCaptureQuiet.state, .unknown)
        XCTAssertEqual(decoded.processObservation.value?.descendants.first?.liveness, .live)
    }

    func testKnownPTYQuietnessDoesNotOverrideActiveShellProcessOrExactSession() throws {
        let tree = processTree(childPID: 504, childLiveness: .live)
        let provider = try XCTUnwrap(tree.descendants.first)
        let correlation = ShellProviderCorrelationResolver.resolve(
            taskSessionID: taskID.rawValue.uuidString,
            runtimeAttemptID: runtimeID,
            shellExecutionID: executionID,
            processCandidates: [
                ShellOpenCodeProcessCandidate(
                    node: provider,
                    arguments: ["/opt/homebrew/bin/opencode", "--session", "ses_active"]
                )
            ],
            processTree: tree,
            providerSessionIDs: .known(["ses_active"]),
            providerObservation: providerStamp
        )
        let snapshot = FleetShellTelemetrySnapshot(
            runtimeAttemptID: .known(runtimeID),
            shellExecutionID: .known(executionID),
            phase: .known(.commandStarted),
            commandID: .known(commandID(6)),
            commandState: .known(.active),
            shellPID: .known(400),
            processGroupID: .known(400),
            workingDirectory: .known("/tmp/qualification"),
            deliveryTransport: .known(.shellStdin),
            ptyCaptureQuiet: .known(true),
            launcherLiveness: .known(.live),
            processObservation: .known(tree),
            observation: processStamp
        )

        XCTAssertEqual(snapshot.ptyCaptureQuiet.value, true)
        XCTAssertEqual(snapshot.commandState.value, .active)
        XCTAssertEqual(snapshot.processObservation.value?.descendants.first?.liveness, .live)
        XCTAssertEqual(correlation.kind, .exact)
        XCTAssertEqual(correlation.providerSessionID.value, "ses_active")
    }

    func testNonProviderCommandAndUnrelatedProcessDoNotCorrelate() throws {
        var tree = processTree(childPID: 511, childLiveness: .live)
        var nonProvider = try XCTUnwrap(tree.descendants.first)
        nonProvider.commandName = .known("python3")
        tree.descendants = [nonProvider]
        let unrelated = processNode(
            pid: 510,
            commandName: "opencode",
            ownership: .preExisting,
            basis: .preExistingObservation
        )
        let result = ShellProviderCorrelationResolver.resolve(
            taskSessionID: taskID.rawValue.uuidString,
            runtimeAttemptID: runtimeID,
            shellExecutionID: executionID,
            processCandidates: [
                ShellOpenCodeProcessCandidate(
                    node: unrelated,
                    arguments: ["/opt/homebrew/bin/opencode", "--session", "ses_unrelated"]
                ),
                ShellOpenCodeProcessCandidate(
                    node: nonProvider,
                    arguments: ["python3", "-c", "print('safe')"]
                ),
            ],
            processTree: tree,
            providerSessionIDs: .known(["ses_unrelated"]),
            providerObservation: providerStamp
        )

        XCTAssertEqual(result.kind, .unknown)
        XCTAssertNil(result.providerSessionID.value)
        XCTAssertTrue(result.candidateSessionIDs.isEmpty)
    }

    func testExactCorrelationRequiresOwnedProcessExactSessionAndProviderPersistence() throws {
        let tree = processTree(childPID: 520, childLiveness: .live)
        let owned = try XCTUnwrap(tree.descendants.first)
        let args = ["/opt/homebrew/bin/opencode", "run", "--session", "ses_exact"]

        let exact = ShellProviderCorrelationResolver.resolve(
            taskSessionID: taskID.rawValue.uuidString,
            runtimeAttemptID: runtimeID,
            shellExecutionID: executionID,
            processCandidates: [ShellOpenCodeProcessCandidate(node: owned, arguments: args)],
            processTree: tree,
            providerSessionIDs: .known(["ses_exact", "ses_other"]),
            providerObservation: providerStamp
        )
        XCTAssertEqual(exact.kind, .exact)
        XCTAssertEqual(exact.providerSessionID.value, "ses_exact")
        XCTAssertEqual(exact.processPID.value, 520)
        XCTAssertEqual(exact.runtimeAttemptID.value, runtimeID)
        XCTAssertNil(exact.commandID.value)

        var bunNamedExecutable = owned
        bunNamedExecutable.commandName = .known("opencode.exe")
        var bunNamedTree = tree
        bunNamedTree.descendants = [bunNamedExecutable]
        let executableAlias = ShellProviderCorrelationResolver.resolve(
            taskSessionID: taskID.rawValue.uuidString,
            runtimeAttemptID: runtimeID,
            shellExecutionID: executionID,
            processCandidates: [
                ShellOpenCodeProcessCandidate(
                    node: bunNamedExecutable,
                    arguments: ["/opt/homebrew/bin/opencode.exe", "--session", "ses_exact"]
                )
            ],
            processTree: bunNamedTree,
            providerSessionIDs: .known(["ses_exact"]),
            providerObservation: providerStamp
        )
        XCTAssertEqual(executableAlias.kind, .exact)
        XCTAssertEqual(executableAlias.providerSessionID.value, "ses_exact")

        let unconfirmed = ShellProviderCorrelationResolver.resolve(
            taskSessionID: taskID.rawValue.uuidString,
            runtimeAttemptID: runtimeID,
            shellExecutionID: executionID,
            processCandidates: [ShellOpenCodeProcessCandidate(node: owned, arguments: args)],
            processTree: tree,
            providerSessionIDs: .unknown,
            providerObservation: unknownProviderStamp
        )
        XCTAssertEqual(unconfirmed.kind, .candidate)
        XCTAssertEqual(unconfirmed.providerSessionID.value, "ses_exact")
    }

    func testMissingOrAmbiguousSessionArgumentStaysUnknownOrAmbiguous() throws {
        let tree = processTree(childPID: 530, childLiveness: .live)
        let owned = try XCTUnwrap(tree.descendants.first)
        let missing = ShellProviderCorrelationResolver.resolve(
            taskSessionID: taskID.rawValue.uuidString,
            runtimeAttemptID: runtimeID,
            shellExecutionID: executionID,
            processCandidates: [
                ShellOpenCodeProcessCandidate(
                    node: owned,
                    arguments: ["/opt/homebrew/bin/opencode", "run"]
                )
            ],
            processTree: tree,
            providerSessionIDs: .known(["ses_plausible"]),
            providerObservation: providerStamp
        )
        XCTAssertEqual(missing.kind, .unknown)

        let ambiguous = ShellProviderCorrelationResolver.resolve(
            taskSessionID: taskID.rawValue.uuidString,
            runtimeAttemptID: runtimeID,
            shellExecutionID: executionID,
            processCandidates: [
                ShellOpenCodeProcessCandidate(
                    node: owned,
                    arguments: [
                        "/opt/homebrew/bin/opencode",
                        "--session",
                        "ses_one",
                        "-s",
                        "ses_two",
                    ]
                )
            ],
            processTree: tree,
            providerSessionIDs: .known(["ses_one", "ses_two"]),
            providerObservation: providerStamp
        )
        XCTAssertEqual(ambiguous.kind, .ambiguous)
        XCTAssertEqual(ambiguous.candidateSessionIDs, ["ses_one", "ses_two"])

        var staleNode = owned
        staleNode.observation.freshness = .stale
        var staleTree = tree
        staleTree.observation.freshness = .stale
        staleTree.descendants = [staleNode]
        let staleProcess = ShellProviderCorrelationResolver.resolve(
            taskSessionID: taskID.rawValue.uuidString,
            runtimeAttemptID: runtimeID,
            shellExecutionID: executionID,
            processCandidates: [
                ShellOpenCodeProcessCandidate(
                    node: staleNode,
                    arguments: ["/opt/homebrew/bin/opencode", "-s", "ses_one"]
                )
            ],
            processTree: staleTree,
            providerSessionIDs: .known(["ses_one"]),
            providerObservation: providerStamp
        )
        XCTAssertEqual(staleProcess.kind, .unknown)
    }

    func testTelemetryAuthorityAndPersistenceExcludeCommandText() throws {
        let valid = event(.commandStarted, commandID: 12)
        let invalid = TaskSessionEvent(
            taskSessionID: taskID,
            occurredAt: observedAt,
            recordedAt: observedAt,
            authority: .operatorAsserted,
            kind: .shellTelemetryRecorded(valid)
        )
        XCTAssertTrue(taskEvent(valid).hasValidAuthority)
        XCTAssertFalse(invalid.hasValidAuthority)

        let encoded = String(
            decoding: try JSONEncoder().encode(taskEvent(valid)),
            as: UTF8.self
        )
        XCTAssertTrue(encoded.contains("shell_stdin"))
        XCTAssertTrue(encoded.contains(commandID(12)))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("secret-command"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("terminal output"))
    }

    private func event(
        _ phase: ShellTelemetryPhase,
        commandID sequence: Int? = nil,
        exitStatus: Int32? = nil
    ) -> ShellTelemetryEvent {
        ShellTelemetryEvent(
            shellExecutionID: executionID,
            runtimeAttemptID: runtimeID,
            phase: phase,
            commandID: sequence.map { commandID($0) },
            commandSequence: sequence,
            shellPID: 400,
            processGroupID: .known(400),
            workingDirectory: .known("/tmp/qualification"),
            exitStatus: exitStatus.map(OrchestrationValue.known) ?? .unknown,
            deliveryTransport: sequence.map { _ in .known(.shellStdin) } ?? .unknown,
            observation: SupervisionObservationStamp(
                authority: .shellHookObserved,
                freshness: .current,
                observedAt: .known(observedAt)
            )
        )
    }

    private func taskEvent(_ telemetry: ShellTelemetryEvent) -> TaskSessionEvent {
        TaskSessionEvent(
            taskSessionID: taskID,
            occurredAt: observedAt,
            recordedAt: observedAt,
            authority: .shellHookObserved,
            kind: .shellTelemetryRecorded(telemetry)
        )
    }

    private func commandID(_ sequence: Int) -> String {
        "\(executionID):\(sequence)"
    }

    private var processStamp: SupervisionObservationStamp {
        SupervisionObservationStamp(
            authority: .processObserved,
            freshness: .current,
            observedAt: .known(observedAt)
        )
    }

    private var providerStamp: SupervisionObservationStamp {
        SupervisionObservationStamp(
            authority: .providerObserved,
            freshness: .current,
            observedAt: .known(observedAt)
        )
    }

    private var unknownProviderStamp: SupervisionObservationStamp {
        SupervisionObservationStamp(
            authority: .unknown,
            freshness: .unknown,
            observedAt: .unknown
        )
    }

    private func processNode(
        pid: Int32,
        commandName: String,
        ownership: ProcessOwnership = .taskCreated,
        basis: ProcessOwnershipBasis = .descendantObservedAfterLauncher
    ) -> ProcessNodeObservation {
        ProcessNodeObservation(
            pid: pid,
            parentPID: .known(400),
            processGroupID: .known(400),
            startIdentity: .known(
                ProcessStartIdentity(startTime: .known(observedAt))
            ),
            commandName: .known(commandName),
            ownership: ownership,
            ownershipBasis: basis,
            liveness: .live,
            observation: processStamp
        )
    }

    private func processTree(
        childPID: Int32,
        childLiveness: ProcessLiveness
    ) -> ProcessTreeObservation {
        ProcessTreeObservation(
            taskSessionID: taskID.rawValue.uuidString,
            runtimeAttemptID: .known(runtimeID),
            providerTurnID: .unknown,
            launcher: .known(processNode(
                pid: 400,
                commandName: "zsh",
                ownership: .taskCreated,
                basis: .launcherIdentity
            )),
            descendants: [
                ProcessNodeObservation(
                    pid: childPID,
                    parentPID: .known(400),
                    processGroupID: .known(400),
                    startIdentity: .known(
                        ProcessStartIdentity(startTime: .known(observedAt))
                    ),
                    commandName: .known("opencode"),
                    ownership: .taskCreated,
                    ownershipBasis: .descendantObservedAfterLauncher,
                    liveness: childLiveness,
                    observation: processStamp
                )
            ],
            coverage: .complete,
            observation: processStamp
        )
    }
}
