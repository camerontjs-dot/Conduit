import Darwin
import XCTest
@testable import ConduitCore

final class OrchestrationRunJournalTests: XCTestCase {
    private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", n))! }
    private var runID: OrchestrationRunID { OrchestrationRunID(rawValue: uuid(1)) }
    private var firstID: OrchestrationStepID { OrchestrationStepID(rawValue: uuid(2)) }
    private var secondID: OrchestrationStepID { OrchestrationStepID(rawValue: uuid(3)) }
    private let date = Date(timeIntervalSince1970: 1_780_000_000)
    private func proposal(scope: [String] = ["notes.txt"]) -> OrchestrationProposal {
        OrchestrationProposal(objective: "Bounded logical work", projectID: "fixture", suggestedAgent: "Shell",
            scopeAllowlist: scope, deliverables: ["receipt"], verificationSteps: ["external verification"],
            risks: ["Runtime UNKNOWN"], nonGoals: ["No launch"])
    }
    private func run(steps: [OrchestrationStep]? = nil) -> OrchestrationRun {
        OrchestrationRun(id: runID, proposal: proposal(), planVersion: "plan-v1", policyVersion: "policy-v1",
            steps: steps ?? [OrchestrationStep(id: firstID, runID: runID, objective: "First", dependencies: []),
                            OrchestrationStep(id: secondID, runID: runID, objective: "Second", dependencies: [firstID])])
    }
    private func evidence(authority: SupervisionObservationAuthority = .conduitRecorded,
                          freshness: SupervisionObservationFreshness = .current,
                          observedAt: OrchestrationValue<Date>? = nil) -> OrchestrationEvidenceReference {
        OrchestrationEvidenceReference(sourceID: "fixture:receipt", revision: "receipt-v1",
            observation: SupervisionObservationStamp(authority: authority, freshness: freshness,
                observedAt: observedAt ?? .known(date)))
    }
    private func worker(attempt: Int = 5) -> OrchestrationWorkerReference {
        OrchestrationWorkerReference(taskSessionID: TaskSessionID(rawValue: uuid(4)),
            runtimeAttemptID: RuntimeAttemptID(rawValue: uuid(attempt)), providerID: .unknown,
            providerSessionID: .unknown, providerTurnID: .unknown, workspaceID: .unknown, evidence: evidence())
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-run-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func journal(create: Bool = true) throws -> OrchestrationRunJournal {
        let journal = OrchestrationRunJournal(directory: try directory(), runID: runID)
        if create { _ = try append(journal, id: 10, revision: 0, action: .create(run())) }
        return journal
    }
    @discardableResult
    private func append(_ journal: OrchestrationRunJournal, id: Int, revision: Int,
                        action: OrchestrationJournalAction) throws -> OrchestrationJournalAppendReceipt {
        try journal.append(OrchestrationJournalCommand(id: uuid(id), runID: runID,
            expectedRevision: revision, action: action), eventID: uuid(id + 10_000), recordedAt: date)
    }
    private func assertRefusedWithoutWrite(_ journal: OrchestrationRunJournal,
                                          file: StaticString = #filePath, line: UInt = #line,
                                          _ action: () throws -> Void) throws {
        let before = try Data(contentsOf: journal.journalURL)
        XCTAssertThrowsError(try action(), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: journal.journalURL), before, file: file, line: line)
    }
    private func completeFirst(_ journal: OrchestrationRunJournal) throws {
        try append(journal, id: 11, revision: 1, action: .linkWorker(stepID: firstID, worker: worker()))
        try append(journal, id: 12, revision: 2, action: .progress(stepID: firstID, value: .running, evidence: evidence()))
        try append(journal, id: 13, revision: 3, action: .progress(stepID: firstID, value: .completionReported, evidence: evidence()))
    }

    func testMissingRecoveryDoesNotCreateHistory() throws {
        let journal = try journal(create: false)
        XCTAssertThrowsError(try journal.recover()) { XCTAssertEqual($0 as? OrchestrationJournalError, .missing) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: journal.directory.path).isEmpty)
    }
    func testRunRoundTripPreservesIndependentLogicalAndExecutionIDs() throws {
        let journal = try journal(); try append(journal, id: 11, revision: 1, action: .linkWorker(stepID: firstID, worker: worker()))
        let recovered = try OrchestrationRunJournal(directory: journal.directory, runID: runID).recover()
        XCTAssertEqual(recovered.snapshot.run, run()); XCTAssertEqual(recovered.snapshot.steps[0].worker, worker())
        XCTAssertEqual(recovered.snapshot.steps[0].worker?.providerTurnID, .unknown)
        XCTAssertEqual(recovered.snapshot.acceptance, .unknown)
    }
    func testStoringBroadProposalDoesNotBypassExistingPolicy() throws {
        let broad = proposal(scope: ["*"])
        let staged = OrchestrationRun(id: runID, proposal: broad, planVersion: "plan-v1", policyVersion: "policy-v1", steps: run().steps)
        let journal = try journal(create: false); try append(journal, id: 10, revision: 0, action: .create(staged))
        let policy = OrchestrationProposalPolicy(allowedAgentNames: ["Shell"])
        let packet = OrchestrationContextPacket(projectID: "fixture", generatedAt: date, entries: [])
        guard case .refused = policy.validate(proposal: broad, selectedProjectID: "fixture", contextPacket: packet, workerAlreadyActive: false) else {
            return XCTFail("A recorded run is not policy authority.")
        }
        XCTAssertEqual(OrchestrationRunReducer.reduce(.proposalReady(broad), event: .requestApproval),
                       .approvalRequired(broad, OrchestrationApprovalToken(proposal: broad)))
    }
    func testInvalidInitialPlanDoesNotCreateFile() throws {
        let journal = try journal(create: false)
        let invalid = run(steps: [OrchestrationStep(id: firstID, runID: runID, objective: "", dependencies: [])])
        XCTAssertThrowsError(try append(journal, id: 10, revision: 0, action: .create(invalid)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.journalURL.path))
    }
    func testOversizedInitialRunDoesNotCreateEmptyJournal() throws {
        let journal = try journal(create: false)
        let large = OrchestrationProposal(objective: String(repeating: "x", count: OrchestrationRunJournal.maximumRecordBytes),
            projectID: "fixture", suggestedAgent: "Shell", scopeAllowlist: ["notes.txt"], deliverables: ["receipt"],
            verificationSteps: ["external verification"], risks: [], nonGoals: ["No launch"])
        let oversized = OrchestrationRun(id: runID, proposal: large, planVersion: "plan-v1", policyVersion: "policy-v1", steps: run().steps)
        XCTAssertThrowsError(try append(journal, id: 10, revision: 0, action: .create(oversized))) {
            XCTAssertEqual($0 as? OrchestrationJournalError, .boundExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.journalURL.path))
    }
    func testDuplicateAndForwardStepReferencesAreRefused() throws {
        let journal = try journal(create: false)
        let step = OrchestrationStep(id: firstID, runID: runID, objective: "First", dependencies: [])
        XCTAssertThrowsError(try append(journal, id: 10, revision: 0, action: .create(run(steps: [step, step]))))
        let forward = OrchestrationStep(id: firstID, runID: runID, objective: "First", dependencies: [secondID])
        XCTAssertThrowsError(try append(journal, id: 10, revision: 0, action: .create(run(steps: [forward, run().steps[1]]))))
    }
    func testRetryReturnsOriginalEventAfterJournalAdvances() throws {
        let journal = try journal(); try append(journal, id: 11, revision: 1,
            action: .condition(OrchestrationCondition(stepID: nil, kind: .routeReady, value: .unknown, evidence: evidence())))
        let before = try Data(contentsOf: journal.journalURL)
        let retried = try journal.append(OrchestrationJournalCommand(id: uuid(10), runID: runID,
            expectedRevision: 0, action: .create(run())), eventID: uuid(999), recordedAt: date.addingTimeInterval(10))
        XCTAssertFalse(retried.appended); XCTAssertEqual(retried.event.sequence, 1); XCTAssertEqual(retried.event.id, uuid(10_010))
        XCTAssertEqual(try Data(contentsOf: journal.journalURL), before)
    }
    func testConflictingCommandIdentityIsRefused() throws {
        let journal = try journal(); try append(journal, id: 11, revision: 1, action: .progress(stepID: firstID, value: .blocked, evidence: evidence()))
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 11, revision: 1, action: .progress(stepID: firstID, value: .unknown, evidence: evidence())) }
    }
    func testEventIdentityCannotBeReusedForAnotherCommand() throws {
        let journal = try journal()
        try assertRefusedWithoutWrite(journal) {
            _ = try journal.append(OrchestrationJournalCommand(id: uuid(11), runID: runID, expectedRevision: 1,
                action: .progress(stepID: firstID, value: .blocked, evidence: evidence())), eventID: uuid(10_010), recordedAt: date)
        }
    }
    func testStaleRevisionIsRefusedWithoutWrite() throws {
        let journal = try journal()
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 11, revision: 0, action: .progress(stepID: firstID, value: .blocked, evidence: evidence())) }
    }
    func testWrongRunCommandIsRefusedWithoutWrite() throws {
        let journal = try journal()
        try assertRefusedWithoutWrite(journal) {
            _ = try journal.append(OrchestrationJournalCommand(id: uuid(11), runID: OrchestrationRunID(rawValue: uuid(99)),
                expectedRevision: 1, action: .progress(stepID: firstID, value: .blocked, evidence: evidence())), eventID: uuid(999), recordedAt: date)
        }
    }
    func testUnlinkedProgressAndUnknownStepAreRefused() throws {
        let journal = try journal()
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 11, revision: 1, action: .progress(stepID: firstID, value: .running, evidence: evidence())) }
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 11, revision: 1, action: .progress(stepID: OrchestrationStepID(rawValue: uuid(99)), value: .blocked, evidence: evidence())) }
    }
    func testReplacementNeedsExactReleaseAndKeepsStepIdentity() throws {
        let journal = try journal(); try append(journal, id: 11, revision: 1, action: .linkWorker(stepID: firstID, worker: worker()))
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 12, revision: 2, action: .linkWorker(stepID: firstID, worker: worker(attempt: 6))) }
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 12, revision: 2, action: .releaseWorker(stepID: firstID, expected: worker(attempt: 6))) }
        try append(journal, id: 12, revision: 2, action: .releaseWorker(stepID: firstID, expected: worker()))
        try append(journal, id: 13, revision: 3, action: .linkWorker(stepID: firstID, worker: worker(attempt: 6)))
        XCTAssertEqual(try journal.recover().snapshot.steps[0].step.id, firstID)
        XCTAssertEqual(try journal.recover().snapshot.steps[0].worker?.runtimeAttemptID, RuntimeAttemptID(rawValue: uuid(6)))
    }
    func testCompletionReportDoesNotSetVerificationAcceptanceOrTerminalState() throws {
        let journal = try journal(); try completeFirst(journal); let snapshot = try journal.recover().snapshot
        XCTAssertEqual(snapshot.steps[0].progress, .completionReported); XCTAssertTrue(snapshot.steps[0].hasCompletionReport)
        XCTAssertEqual(snapshot.steps[0].verification, .unknown); XCTAssertEqual(snapshot.steps[0].acceptance, .unknown)
        XCTAssertEqual(snapshot.verification, .unknown); XCTAssertEqual(snapshot.acceptance, .unknown); XCTAssertNil(snapshot.disposition)
    }
    func testCompletedStepCannotBeResurrectedThroughUnknownObservation() throws {
        let journal = try journal(); try completeFirst(journal)
        try append(journal, id: 14, revision: 4, action: .progress(stepID: firstID, value: .unknown, evidence: evidence()))
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 15, revision: 5, action: .progress(stepID: firstID, value: .queued, evidence: evidence())) }
        XCTAssertTrue(try journal.recover().snapshot.steps[0].hasCompletionReport)
    }
    func testSequentialDependencyRequiresBothVerificationAndAcceptance() throws {
        let journal = try journal(); try completeFirst(journal)
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 14, revision: 4, action: .progress(stepID: secondID, value: .queued, evidence: evidence())) }
        try append(journal, id: 14, revision: 4, action: .verification(stepID: firstID, value: .passed, evidence: evidence()))
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 15, revision: 5, action: .progress(stepID: secondID, value: .queued, evidence: evidence())) }
        try append(journal, id: 15, revision: 5, action: .acceptance(stepID: firstID, value: .accepted, evidence: evidence()))
        try append(journal, id: 16, revision: 6, action: .progress(stepID: secondID, value: .queued, evidence: evidence()))
        XCTAssertEqual(try journal.recover().snapshot.steps[1].progress, .queued)
    }
    func testProviderObservationCannotRecordVerificationOrExternalAcceptance() throws {
        let journal = try journal(); let provider = evidence(authority: .providerObserved)
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 11, revision: 1, action: .verification(stepID: nil, value: .passed, evidence: provider)) }
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 11, revision: 1, action: .acceptance(stepID: nil, value: .accepted, evidence: provider)) }
    }
    func testRepositoryObservationCannotRecordWorkerRunning() throws {
        let journal = try journal(); try append(journal, id: 11, revision: 1, action: .linkWorker(stepID: firstID, worker: worker()))
        try assertRefusedWithoutWrite(journal) {
            try append(journal, id: 12, revision: 2, action: .progress(stepID: firstID, value: .running,
                evidence: evidence(authority: .repositoryObserved)))
        }
    }
    func testWrongProviderTurnCannotReleaseSameTaskAttempt() throws {
        let journal = try journal(); try append(journal, id: 11, revision: 1, action: .linkWorker(stepID: firstID, worker: worker()))
        let mismatched = OrchestrationWorkerReference(taskSessionID: worker().taskSessionID,
            runtimeAttemptID: worker().runtimeAttemptID, providerID: .unknown, providerSessionID: .unknown,
            providerTurnID: .known("another-turn"), workspaceID: .unknown, evidence: evidence())
        try assertRefusedWithoutWrite(journal) {
            try append(journal, id: 12, revision: 2, action: .releaseWorker(stepID: firstID, expected: mismatched))
        }
    }
    func testStaleUnknownAndMissingTimeDoNotRecordAcceptance() throws {
        let journal = try journal()
        for stamp in [evidence(freshness: .stale), evidence(authority: .unknown), evidence(observedAt: .unknown)] {
            try assertRefusedWithoutWrite(journal) { try append(journal, id: 11, revision: 1, action: .acceptance(stepID: nil, value: .accepted, evidence: stamp)) }
        }
    }
    func testUnknownConditionRemainsUnknownAndDoesNotSelectRoute() throws {
        let journal = try journal(); let condition = OrchestrationCondition(stepID: nil, kind: .routeReady, value: .unknown, evidence: evidence())
        try append(journal, id: 11, revision: 1, action: .condition(condition)); let snapshot = try journal.recover().snapshot
        XCTAssertEqual(snapshot.conditions, [condition]); XCTAssertEqual(snapshot.acceptance, .unknown); XCTAssertNil(snapshot.steps[0].worker)
    }
    func testArtifactCollisionIsRefused() throws {
        let journal = try journal(); try append(journal, id: 11, revision: 1, action: .artifact(stepID: firstID, artifactID: "artifact", evidence: evidence()))
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 12, revision: 2, action: .artifact(stepID: secondID, artifactID: "artifact", evidence: evidence())) }
    }
    func testRunCompletionNeedsSeparateRunAndStepDecisions() throws {
        let journal = try journal(); try completeFirst(journal)
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 14, revision: 4, action: .terminal(value: .completed, supersededBy: nil, evidence: evidence())) }
    }
    func testFailureRemainsNonSuccessfulAndTerminalMutationIsRefused() throws {
        let journal = try journal(); try append(journal, id: 11, revision: 1, action: .terminal(value: .failed, supersededBy: nil, evidence: evidence()))
        let snapshot = try journal.recover().snapshot; XCTAssertEqual(snapshot.disposition, .failed); XCTAssertEqual(snapshot.acceptance, .unknown)
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 12, revision: 2, action: .progress(stepID: firstID, value: .queued, evidence: evidence())) }
    }
    func testSupersessionRequiresDifferentExplicitRunIdentity() throws {
        let journal = try journal()
        try assertRefusedWithoutWrite(journal) { try append(journal, id: 11, revision: 1, action: .terminal(value: .superseded, supersededBy: runID, evidence: evidence())) }
        let successor = OrchestrationRunID(rawValue: uuid(99)); try append(journal, id: 11, revision: 1, action: .terminal(value: .superseded, supersededBy: successor, evidence: evidence()))
        XCTAssertEqual(try journal.recover().snapshot.supersededBy, successor)
    }
    func testPartialAndEmptyJournalCannotBeRepairedByReadOrAppend() throws {
        let journal = try journal(); let original = try Data(contentsOf: journal.journalURL)
        for corrupt in [original + Data("{".utf8), Data()] {
            try corrupt.write(to: journal.journalURL)
            XCTAssertThrowsError(try journal.recover())
            try assertRefusedWithoutWrite(journal) { try append(journal, id: 11, revision: 1, action: .progress(stepID: firstID, value: .blocked, evidence: evidence())) }
            XCTAssertEqual(try Data(contentsOf: journal.journalURL), corrupt)
        }
    }
    func testDuplicateRecordCannotBecomeFreshEvent() throws {
        let journal = try journal(); let data = try Data(contentsOf: journal.journalURL); try (data + data).write(to: journal.journalURL)
        XCTAssertThrowsError(try journal.recover()); XCTAssertEqual(try Data(contentsOf: journal.journalURL), data + data)
    }
    func testUnknownJournalFieldsAndSequenceGapsAreRefused() throws {
        let journal = try journal(); let data = try Data(contentsOf: journal.journalURL)
        for change in ["approved", "sequence"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            object[change] = change == "sequence" ? 2 : true
            let corrupt = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) + Data([10])
            try corrupt.write(to: journal.journalURL); XCTAssertThrowsError(try journal.recover())
        }
    }
    func testCheckpointIsImmutableAndValidatesAgainstJournalPrefix() throws {
        let journal = try journal(); let cp = try journal.checkpoint(id: uuid(99), expectedRevision: 1)
        let bytes = try Data(contentsOf: journal.checkpointURL(id: uuid(99)))
        XCTAssertEqual(try journal.checkpoint(id: uuid(99), expectedRevision: 1), cp)
        try append(journal, id: 11, revision: 1, action: .progress(stepID: firstID, value: .blocked, evidence: evidence()))
        XCTAssertEqual(try journal.recover(checkpointID: uuid(99)).snapshot, try journal.recover().snapshot)
        XCTAssertThrowsError(try journal.checkpoint(id: uuid(99), expectedRevision: 2))
        XCTAssertEqual(try Data(contentsOf: journal.checkpointURL(id: uuid(99))), bytes)
    }
    func testCheckpointCannotForgeAcceptance() throws {
        let journal = try journal(); try journal.checkpoint(id: uuid(99), expectedRevision: 1)
        let url = journal.checkpointURL(id: uuid(99)); var checkpoint = try OrchestrationJournalCodec.decode(OrchestrationRunCheckpoint.self, data: Data(contentsOf: url))
        var snapshot = checkpoint.snapshot; snapshot.acceptance = .accepted
        checkpoint = OrchestrationRunCheckpoint(id: checkpoint.id, runID: runID, journalDigest: checkpoint.journalDigest, snapshot: snapshot)
        try OrchestrationJournalCodec.encode(checkpoint).write(to: url)
        XCTAssertThrowsError(try journal.recover(checkpointID: uuid(99))); XCTAssertEqual(try journal.recover().snapshot.acceptance, .unknown)
    }
    func testMissingCheckpointDoesNotFallBackOrCreateFile() throws {
        let journal = try journal(); XCTAssertThrowsError(try journal.recover(checkpointID: uuid(99)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.checkpointURL(id: uuid(99)).path))
    }
    func testNonprivateDirectoryIsRefusedWithoutModeRepair() throws {
        let journal = try journal(); try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: journal.directory.path)
        XCTAssertThrowsError(try journal.recover())
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: journal.directory.path)[.posixPermissions] as? Int, 0o755)
    }
    func testSymlinkAndHardlinkedJournalAreRefused() throws {
        let journal = try journal(); let other = try directory().appendingPathComponent("foreign")
        try FileManager.default.linkItem(at: journal.journalURL, to: other); XCTAssertThrowsError(try journal.recover())
        try FileManager.default.removeItem(at: other)
        let target = try directory().appendingPathComponent("saved")
        try FileManager.default.moveItem(at: journal.journalURL, to: target)
        try FileManager.default.createSymbolicLink(at: journal.journalURL, withDestinationURL: target)
        XCTAssertThrowsError(try journal.recover())
    }
    func testNonblockingFileLockReportsBusyThenRecovers() throws {
        let journal = try journal(); let descriptor = Darwin.open(journal.journalURL.path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0); defer { _ = Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try journal.recover()) { XCTAssertEqual($0 as? OrchestrationJournalError, .busy) }
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0); XCTAssertEqual(try journal.recover().snapshot.revision, 1)
    }
    func testFIFOJournalReturnsPromptRefusal() throws {
        let journal = try journal(create: false); XCTAssertEqual(mkfifo(journal.journalURL.path, 0o600), 0)
        XCTAssertThrowsError(try journal.recover()); XCTAssertThrowsError(try append(journal, id: 10, revision: 0, action: .create(run())))
    }
    func testNonfiniteRecordTimeCannotCreateFile() throws {
        let journal = try journal(create: false)
        XCTAssertThrowsError(try journal.append(OrchestrationJournalCommand(id: uuid(10), runID: runID, expectedRevision: 0, action: .create(run())),
            eventID: uuid(11), recordedAt: Date(timeIntervalSince1970: .infinity)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.journalURL.path))
    }
    func testRepeatedRecoveryHasIdenticalCanonicalSnapshotBytes() throws {
        let journal = try journal(); try completeFirst(journal)
        XCTAssertEqual(try OrchestrationJournalCodec.encode(journal.recover().snapshot),
                       try OrchestrationJournalCodec.encode(journal.recover().snapshot))
    }
}
