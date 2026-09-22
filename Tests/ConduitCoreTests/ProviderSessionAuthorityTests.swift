import XCTest
@testable import ConduitCore

final class ProviderSessionAuthorityTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_797_000_000)

    private final class FakeObserver: ProviderSessionObserving {
        let providerID = "fixture"
        var listedSessionID = "ses_existing"
        var observedSessionID = "ses_existing"
        var listCalls = 0
        var observeCalls = 0

        func listSessions(
            bindingResolver: ((String) -> ProviderObservationBinding?)?
        ) throws -> [WorkerLineage] {
            listCalls += 1
            return [
                makeWorker(
                    sessionID: listedSessionID,
                    binding: bindingResolver?(listedSessionID)
                )
            ]
        }

        func observeSession(
            providerSessionID: String,
            binding: ProviderObservationBinding?
        ) throws -> WorkerLineage {
            observeCalls += 1
            return makeWorker(
                sessionID: observedSessionID,
                binding: binding
            )
        }

        private func makeWorker(
            sessionID: String,
            binding: ProviderObservationBinding?
        ) -> WorkerLineage {
            let observed = SupervisionObservationStamp(
                authority: .providerObserved,
                freshness: .unknown,
                observedAt: .known(
                    Date(timeIntervalSince1970: 1_797_000_000)
                )
            )
            return WorkerLineage(
                conduitTaskID: binding.map {
                    .known($0.conduitTaskID)
                } ?? .unknown,
                runtimeAttemptID: binding?.runtimeAttemptID.map {
                    .known($0)
                } ?? .unknown,
                runtime: .known("fixture"),
                adapter: .known("fixture_read_only"),
                providerHostID: .unknown,
                providerSessionID: .known(sessionID),
                turns: [
                    ProviderTurnLineage(
                        turnID: .known("turn-1"),
                        state: .completed,
                        model: .known(
                            ProviderModelIdentity(
                                providerID: "fixture-model-provider",
                                modelID: "fixture-model"
                            )
                        ),
                        observation: observed
                    )
                ],
                workspace: WorkerWorkspaceLineage(
                    projectSlug: .unknown,
                    cwd: .known("/tmp/fixture"),
                    repositoryRoot: .unknown,
                    worktree: .unknown
                ),
                process: WorkerProcessLineage(
                    launcherPID: .unknown,
                    processGroupID: .unknown,
                    parentPID: .unknown
                ),
                origin: .unknown,
                relationship: .discovered,
                writerControllerID: .unknown,
                terminal: WorkerTerminalState(
                    receipt: .unknown,
                    verification: .unknown,
                    objectiveAcceptance: .unknown
                ),
                observation: observed,
                providerSpecific: .unknown
            )
        }
    }

    private func coordinator(
        observer: FakeObserver,
        registry: ProviderSessionAuthorityRegistry? = nil
    ) -> ProviderSessionAuthorityCoordinator {
        ProviderSessionAuthorityCoordinator(
            observer: observer,
            registry: registry ?? ProviderSessionAuthorityRegistry(
                now: { self.fixedDate }
            )
        )
    }

    private func assertStableLineageSemantics(
        _ lhs: WorkerLineage,
        _ rhs: WorkerLineage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.schemaVersion, rhs.schemaVersion, file: file, line: line)
        XCTAssertEqual(lhs.conduitTaskID, rhs.conduitTaskID, file: file, line: line)
        XCTAssertEqual(lhs.runtimeAttemptID, rhs.runtimeAttemptID, file: file, line: line)
        XCTAssertEqual(lhs.runtime, rhs.runtime, file: file, line: line)
        XCTAssertEqual(lhs.adapter, rhs.adapter, file: file, line: line)
        XCTAssertEqual(lhs.providerHostID, rhs.providerHostID, file: file, line: line)
        XCTAssertEqual(lhs.providerSessionID, rhs.providerSessionID, file: file, line: line)
        XCTAssertEqual(lhs.workspace, rhs.workspace, file: file, line: line)
        XCTAssertEqual(lhs.process, rhs.process, file: file, line: line)
        XCTAssertEqual(lhs.origin, rhs.origin, file: file, line: line)
        XCTAssertEqual(lhs.relationship, rhs.relationship, file: file, line: line)
        XCTAssertEqual(lhs.writerControllerID, rhs.writerControllerID, file: file, line: line)
        XCTAssertEqual(lhs.terminal, rhs.terminal, file: file, line: line)
        XCTAssertEqual(lhs.providerSpecific, rhs.providerSpecific, file: file, line: line)
        XCTAssertEqual(
            lhs.observation.authority,
            rhs.observation.authority,
            file: file,
            line: line
        )
        XCTAssertEqual(
            lhs.observation.freshness,
            rhs.observation.freshness,
            file: file,
            line: line
        )
        XCTAssertEqual(lhs.turns.count, rhs.turns.count, file: file, line: line)

        for (left, right) in zip(lhs.turns, rhs.turns) {
            XCTAssertEqual(left.turnID, right.turnID, file: file, line: line)
            XCTAssertEqual(left.state, right.state, file: file, line: line)
            XCTAssertEqual(left.model, right.model, file: file, line: line)
            XCTAssertEqual(left.delivery, right.delivery, file: file, line: line)
            XCTAssertEqual(
                left.observation.authority,
                right.observation.authority,
                file: file,
                line: line
            )
            XCTAssertEqual(
                left.observation.freshness,
                right.observation.freshness,
                file: file,
                line: line
            )
        }
    }

    func testMultipleObserversDoNotAcquireWriterAuthority() throws {
        let observer = FakeObserver()
        let coordinator = coordinator(observer: observer)

        let first = try coordinator.observeSession(
            providerSessionID: "ses_existing"
        )
        let second = try coordinator.observeSession(
            providerSessionID: "ses_existing"
        )

        XCTAssertEqual(observer.observeCalls, 2)
        XCTAssertEqual(first.worker.providerSessionID.value, "ses_existing")
        XCTAssertEqual(second.worker.providerSessionID.value, "ses_existing")
        XCTAssertEqual(first.worker.relationship, .discovered)
        XCTAssertEqual(second.worker.relationship, .discovered)
        XCTAssertEqual(first.worker.writerControllerID.state, .unknown)
        XCTAssertEqual(second.worker.writerControllerID.state, .unknown)
        XCTAssertEqual(first.authority.conduitWriterState, .unclaimed)
        XCTAssertEqual(second.authority.conduitWriterState, .unclaimed)
        XCTAssertEqual(first.authority.externalWriterState, .unknown)
        XCTAssertEqual(second.authority.externalWriterState, .unknown)
    }

    func testFirstAdoptionPreservesExactSessionIdentityAndHistory() throws {
        let observer = FakeObserver()
        let coordinator = coordinator(observer: observer)

        let result = try coordinator.adoptSession(
            providerSessionID: "ses_existing",
            controllerID: "supervisor-a"
        )

        XCTAssertEqual(observer.observeCalls, 1)
        XCTAssertEqual(result.receipt.disposition, .adopted)
        XCTAssertEqual(result.receipt.providerSessionID, "ses_existing")
        XCTAssertEqual(
            result.receipt.recognizedControllerID.value,
            "supervisor-a"
        )
        XCTAssertEqual(
            result.observation.worker.providerSessionID.value,
            "ses_existing"
        )
        XCTAssertEqual(
            result.observation.worker.writerControllerID.value,
            "supervisor-a"
        )
        XCTAssertEqual(result.observation.worker.relationship, .adopted)
        XCTAssertEqual(result.observation.worker.turns.count, 1)
        XCTAssertEqual(
            result.observation.worker.turns.first?.turnID.value,
            "turn-1"
        )
        XCTAssertEqual(
            result.observation.worker.turns.first?.state,
            .completed
        )
        XCTAssertEqual(
            result.observation.worker.terminal.objectiveAcceptance,
            .unknown
        )
        XCTAssertEqual(result.receipt.externalWriterState, .unknown)
    }

    func testSameControllerClaimIsIdempotent() throws {
        let observer = FakeObserver()
        let registry = ProviderSessionAuthorityRegistry(
            now: { self.fixedDate }
        )
        let coordinator = coordinator(
            observer: observer,
            registry: registry
        )

        let first = try coordinator.adoptSession(
            providerSessionID: "ses_existing",
            controllerID: "supervisor-a"
        )
        let second = try coordinator.adoptSession(
            providerSessionID: "ses_existing",
            controllerID: "supervisor-a"
        )

        XCTAssertEqual(first.receipt.disposition, .adopted)
        XCTAssertEqual(second.receipt.disposition, .alreadyControlled)
        XCTAssertEqual(
            second.receipt.recognizedControllerID.value,
            "supervisor-a"
        )
        XCTAssertEqual(
            try registry.snapshot(
                providerID: "fixture",
                providerSessionID: "ses_existing"
            ).writerControllerID.value,
            "supervisor-a"
        )
    }

    func testCompetingWriterFailsClosedWithoutReplacingSessionOrHistory() throws {
        let observer = FakeObserver()
        let registry = ProviderSessionAuthorityRegistry(
            now: { self.fixedDate }
        )
        let coordinator = coordinator(
            observer: observer,
            registry: registry
        )

        let accepted = try coordinator.adoptSession(
            providerSessionID: "ses_existing",
            controllerID: "supervisor-a"
        )
        let collision = try coordinator.adoptSession(
            providerSessionID: "ses_existing",
            controllerID: "supervisor-b"
        )

        XCTAssertEqual(accepted.receipt.disposition, .adopted)
        XCTAssertEqual(collision.receipt.disposition, .writerCollision)
        XCTAssertEqual(
            collision.receipt.recognizedControllerID.value,
            "supervisor-a"
        )
        XCTAssertEqual(
            collision.observation.worker.providerSessionID.value,
            "ses_existing"
        )
        XCTAssertEqual(
            collision.observation.worker.writerControllerID.value,
            "supervisor-a"
        )
        XCTAssertEqual(collision.observation.worker.turns.count, 1)
        XCTAssertEqual(
            collision.observation.worker.turns.first?.turnID.value,
            "turn-1"
        )
        XCTAssertEqual(
            collision.observation.worker.turns.first?.state,
            .completed
        )

        let after = try registry.snapshot(
            providerID: "fixture",
            providerSessionID: "ses_existing"
        )
        XCTAssertEqual(after.conduitWriterState, .controlled)
        XCTAssertEqual(after.writerControllerID.value, "supervisor-a")
        XCTAssertEqual(observer.observeCalls, 2)
    }

    func testCollisionIsNotReportedAsProviderSessionAbsence() throws {
        let observer = FakeObserver()
        let registry = ProviderSessionAuthorityRegistry(
            now: { self.fixedDate }
        )
        let coordinator = coordinator(
            observer: observer,
            registry: registry
        )

        _ = try coordinator.adoptSession(
            providerSessionID: "ses_existing",
            controllerID: "supervisor-a"
        )
        let collision = try coordinator.adoptSession(
            providerSessionID: "ses_existing",
            controllerID: "supervisor-b"
        )

        XCTAssertEqual(collision.receipt.disposition, .writerCollision)
        XCTAssertEqual(
            collision.observation.worker.providerSessionID.value,
            "ses_existing"
        )
        XCTAssertEqual(
            collision.observation.authority.providerSessionID,
            "ses_existing"
        )
    }

    func testObservationAfterAdoptionDoesNotTransferAuthority() throws {
        let observer = FakeObserver()
        let registry = ProviderSessionAuthorityRegistry(
            now: { self.fixedDate }
        )
        let coordinator = coordinator(
            observer: observer,
            registry: registry
        )

        _ = try coordinator.adoptSession(
            providerSessionID: "ses_existing",
            controllerID: "supervisor-a"
        )
        let observed = try coordinator.observeSession(
            providerSessionID: "ses_existing"
        )

        XCTAssertEqual(observed.worker.relationship, .adopted)
        XCTAssertEqual(
            observed.worker.writerControllerID.value,
            "supervisor-a"
        )
        XCTAssertEqual(
            observed.authority.writerControllerID.value,
            "supervisor-a"
        )
        XCTAssertEqual(observed.authority.externalWriterState, .unknown)
    }

    func testIdentityMismatchFailsBeforeAuthorityClaim() throws {
        let observer = FakeObserver()
        observer.observedSessionID = "ses_other"
        let registry = ProviderSessionAuthorityRegistry(
            now: { self.fixedDate }
        )
        let coordinator = coordinator(
            observer: observer,
            registry: registry
        )

        XCTAssertThrowsError(
            try coordinator.adoptSession(
                providerSessionID: "ses_existing",
                controllerID: "supervisor-a"
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderSessionObservationError,
                .identityMismatch(
                    expected: "ses_existing",
                    observed: "ses_other"
                )
            )
        }

        let snapshot = try registry.snapshot(
            providerID: "fixture",
            providerSessionID: "ses_existing"
        )
        XCTAssertEqual(snapshot.conduitWriterState, .unclaimed)
        XCTAssertEqual(snapshot.writerControllerID.state, .unknown)
    }

    func testBlankControllerFailsWithoutChangingAuthority() throws {
        let observer = FakeObserver()
        let registry = ProviderSessionAuthorityRegistry(
            now: { self.fixedDate }
        )
        let coordinator = coordinator(
            observer: observer,
            registry: registry
        )

        XCTAssertThrowsError(
            try coordinator.adoptSession(
                providerSessionID: "ses_existing",
                controllerID: "   "
            )
        ) { error in
            XCTAssertEqual(
                error as? ProviderSessionAuthorityError,
                .emptyControllerID
            )
        }

        let snapshot = try registry.snapshot(
            providerID: "fixture",
            providerSessionID: "ses_existing"
        )
        XCTAssertEqual(snapshot.conduitWriterState, .unclaimed)
        XCTAssertEqual(snapshot.writerControllerID.state, .unknown)
    }

    func testAuthorityStateAndCollisionReceiptRoundTrip() throws {
        let registry = ProviderSessionAuthorityRegistry(
            now: { self.fixedDate }
        )
        _ = try registry.claimWriter(
            providerID: "fixture",
            providerSessionID: "ses_existing",
            controllerID: "supervisor-a"
        )
        let collision = try registry.claimWriter(
            providerID: "fixture",
            providerSessionID: "ses_existing",
            controllerID: "supervisor-b"
        )
        let snapshot = try registry.snapshot(
            providerID: "fixture",
            providerSessionID: "ses_existing"
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(
            try decoder.decode(
                ProviderSessionAuthorityReceipt.self,
                from: encoder.encode(collision)
            ),
            collision
        )
        XCTAssertEqual(
            try decoder.decode(
                ProviderSessionAuthoritySnapshot.self,
                from: encoder.encode(snapshot)
            ),
            snapshot
        )
        XCTAssertEqual(collision.disposition.rawValue, "writer_collision")
        XCTAssertEqual(collision.externalWriterState, .unknown)
    }

    func testInstalledOpenCodeAuthorityJourneyWhenExplicitlyRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CONDUIT_OPENCODE_AUTHORITY_QUALIFICATION"] == "1" else {
            throw XCTSkip(
                "Set CONDUIT_OPENCODE_AUTHORITY_QUALIFICATION=1 with DB/session variables for installed qualification."
            )
        }
        guard let databasePath = environment[
            "CONDUIT_OPENCODE_QUALIFICATION_DB"
        ],
        !databasePath.isEmpty,
        let sessionID = environment[
            "CONDUIT_OPENCODE_QUALIFICATION_SESSION_ID"
        ],
        !sessionID.isEmpty
        else {
            return XCTFail(
                "Installed authority qualification requires CONDUIT_OPENCODE_QUALIFICATION_DB and CONDUIT_OPENCODE_QUALIFICATION_SESSION_ID."
            )
        }

        let database = URL(fileURLWithPath: databasePath)
        let observer = OpenCodeProviderSessionObserver(
            transport: OpenCodeSQLiteObservationTransport(
                environment: ["OPENCODE_DB": database.path],
                homeDirectory: database.deletingLastPathComponent(),
                timeout: 30
            )
        )
        let registry = ProviderSessionAuthorityRegistry(
            now: { self.fixedDate }
        )
        let coordinator = ProviderSessionAuthorityCoordinator(
            observer: observer,
            registry: registry
        )

        let firstObservation = try coordinator.observeSession(
            providerSessionID: sessionID
        )
        let secondObservation = try coordinator.observeSession(
            providerSessionID: sessionID
        )
        assertStableLineageSemantics(
            firstObservation.worker,
            secondObservation.worker
        )
        XCTAssertEqual(
            firstObservation.authority.conduitWriterState,
            .unclaimed
        )
        XCTAssertEqual(
            secondObservation.authority.conduitWriterState,
            .unclaimed
        )

        let accepted = try coordinator.adoptSession(
            providerSessionID: sessionID,
            controllerID: "qualification-controller-a"
        )
        let collision = try coordinator.adoptSession(
            providerSessionID: sessionID,
            controllerID: "qualification-controller-b"
        )

        XCTAssertEqual(accepted.receipt.disposition, .adopted)
        XCTAssertEqual(collision.receipt.disposition, .writerCollision)
        XCTAssertEqual(
            accepted.observation.worker.providerSessionID.value,
            sessionID
        )
        XCTAssertEqual(
            collision.observation.worker.providerSessionID.value,
            sessionID
        )
        XCTAssertEqual(
            collision.receipt.recognizedControllerID.value,
            "qualification-controller-a"
        )
        assertStableLineageSemantics(
            accepted.observation.worker,
            collision.observation.worker
        )
        XCTAssertEqual(
            collision.observation.worker.terminal.objectiveAcceptance,
            .unknown
        )
        XCTAssertEqual(collision.receipt.externalWriterState, .unknown)

        print(
            "INSTALLED_OPENCODE_AUTHORITY "
                + "session=\(sessionID) "
                + "turns=\(collision.observation.worker.turns.count) "
                + "first=\(accepted.receipt.disposition.rawValue) "
                + "second=\(collision.receipt.disposition.rawValue) "
                + "controller=\(collision.receipt.recognizedControllerID.value ?? "unknown")"
        )
    }
}
