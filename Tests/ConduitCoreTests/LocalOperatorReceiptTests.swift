import Darwin
import Foundation
import XCTest
@testable import ConduitCore

final class LocalOperatorReceiptTests: XCTestCase {
    private func temp(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("local-operator-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func boundary(_ root: URL, mode: LocalOperatorAuthorityMode = .boundedWrite,
                          paths: [String] = ["file.txt"], protected: [String] = []) throws -> LocalOperatorBoundary {
        try LocalOperatorBoundary(taskSessionID: TaskSessionID(), runtimeAttemptID: RuntimeAttemptID(),
            projectSlug: "fixture", workingDirectory: root, objective: "Bounded fixture operation",
            acceptanceCondition: "Observe the declared file and retain exact state", authorityMode: mode,
            relativePaths: paths, protectedRelativePaths: protected)
    }

    private func unknown(_ b: LocalOperatorBoundary) -> ProcessTreeObservation {
        .unavailable(taskSessionID: b.taskSessionID.rawValue.uuidString,
            runtimeAttemptID: .known(b.runtimeAttemptID.rawValue.uuidString), providerTurnID: .unknown,
            reason: "No process lifecycle claim in this fixture")
    }

    private func snapshot(_ b: LocalOperatorBoundary, process: ProcessTreeObservation? = nil,
                          maxBytes: Int = 1_048_576) throws -> LocalOperatorSnapshot {
        try LocalOperatorInspector(maximumFileBytes: maxBytes).snapshot(boundary: b, processes: process ?? unknown(b))
    }

    private func git(_ root: URL, _ arguments: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-C", root.path] + arguments
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0)
    }

    func testAuthorityModesRemainDistinct() {
        XCTAssertEqual(LocalOperatorAuthorityMode.allCases.map(\.rawValue),
            ["OBSERVE", "BOUNDED_WRITE", "CONSEQUENT_LOCAL_CHANGE"])
    }

    func testInvalidBoundariesRejectAbsoluteTraversalNULAndDuplicatePaths() throws {
        try temp { root in
            for paths in [["/outside"], ["../outside"], ["a/../b"], ["a//b"], ["file\0bad"], ["same", "same"], [], Array(repeating: "x", count: 65)] {
                XCTAssertThrowsError(try boundary(root, paths: paths))
            }
            XCTAssertThrowsError(try LocalOperatorBoundary(taskSessionID: TaskSessionID(), runtimeAttemptID: RuntimeAttemptID(),
                projectSlug: "fixture", workingDirectory: root, objective: " ", acceptanceCondition: "x",
                authorityMode: .observe, relativePaths: ["x"]))
        }
    }

    func testActualReadOnlyPreflightDoesNotMutateNominatedFile() throws {
        try temp { root in
            let file = root.appendingPathComponent("file.txt"); let bytes = Data("read-only bytes".utf8)
            try bytes.write(to: file)
            let b = try boundary(root, mode: .observe); let before = try snapshot(b); let after = try snapshot(b)
            let r = LocalOperatorReceiptBuilder.checkpoint(previous: .initForTest(b, before), snapshot: after, terminal: true)
            XCTAssertEqual(r.disposition, .terminal); XCTAssertTrue(r.changes.isEmpty)
            XCTAssertEqual(try Data(contentsOf: file), bytes); XCTAssertEqual(r.acceptance, "NOT_ESTABLISHED")
            XCTAssertTrue(r.isValid)
        }
    }

    func testPhysicalCreatedModifiedDeletedArtifactsRetainDigests() throws {
        try temp { root in
            try Data("old".utf8).write(to: root.appendingPathComponent("file.txt"))
            try Data("deleted".utf8).write(to: root.appendingPathComponent("delete.txt"))
            let b = try boundary(root, paths: ["file.txt", "delete.txt", "new artifact.txt"])
            let before = try snapshot(b)
            try Data("new".utf8).write(to: root.appendingPathComponent("file.txt"))
            try FileManager.default.removeItem(at: root.appendingPathComponent("delete.txt"))
            try Data([0, 1, 255]).write(to: root.appendingPathComponent("new artifact.txt"))
            let receipt = LocalOperatorReceiptBuilder.checkpoint(previous: .initForTest(b, before), snapshot: try snapshot(b), terminal: true)
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: receipt.changes.map { ($0.relativePath, $0.kind) }),
                ["file.txt": .modified, "delete.txt": .deleted, "new artifact.txt": .created])
            XCTAssertTrue(receipt.changes.allSatisfy { $0.attribution == "OBSERVED_ONLY_AUTHOR_UNKNOWN" })
            XCTAssertEqual(receipt.observation.files.first { $0.relativePath == "new artifact.txt" }?.sha256?.count, 64)
        }
    }

    func testGitBeforeAfterKeepsPreexistingDirtyStateAndExactPath() throws {
        try temp { root in
            try git(root, ["init"]); try Data("tracked".utf8).write(to: root.appendingPathComponent("file.txt"))
            try git(root, ["add", "file.txt"])
            try git(root, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"])
            try Data("unrelated preexisting".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
            let b = try boundary(root, paths: ["file.txt", "line\nbreak.txt"]); let before = try snapshot(b)
            try Data("changed".utf8).write(to: root.appendingPathComponent("file.txt"))
            try Data("artifact".utf8).write(to: root.appendingPathComponent("line\nbreak.txt"))
            let after = try snapshot(b)
            XCTAssertEqual(before.repository.headSHA, after.repository.headSHA)
            XCTAssertNotNil(before.repository.branch)
            XCTAssertEqual(before.repository.paths.map(\.path), ["unrelated.txt"])
            XCTAssertEqual(Set(after.repository.paths.map(\.path)), Set(["file.txt", "line\nbreak.txt", "unrelated.txt"]))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("unrelated.txt")), "unrelated preexisting")
        }
    }

    func testExternalUnnominatedGitChangeCannotBeAdoptedByCheckpoint() throws {
        try temp { root in
            try git(root, ["init"]); try Data("before".utf8).write(to: root.appendingPathComponent("file.txt"))
            try git(root, ["add", "file.txt"])
            try git(root, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture"])
            let b = try boundary(root); let before = try snapshot(b)
            let first = LocalOperatorReceipt.initForTest(b, before)
            try Data("bounded change".utf8).write(to: root.appendingPathComponent("file.txt"))
            XCTAssertEqual(LocalOperatorReceiptBuilder.checkpoint(previous: first, snapshot: try snapshot(b)).disposition, .continuing)
            try Data("outside scope".utf8).write(to: root.appendingPathComponent("unrelated.txt"))
            let conflict = LocalOperatorReceiptBuilder.checkpoint(previous: first, snapshot: try snapshot(b))
            XCTAssertEqual(conflict.disposition, .blocked)
            XCTAssertTrue(conflict.diagnostics.contains { $0.contains("outside the nominated") })
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("unrelated.txt")), "outside scope")
        }
    }

    func testExplicitProtectedScopeDoesNotChangeWhenDirtyPathsAreAdded() throws {
        try temp { root in
            let b = try LocalOperatorBoundary(taskSessionID: TaskSessionID(), runtimeAttemptID: RuntimeAttemptID(),
                projectSlug: "fixture", workingDirectory: root, objective: "Bounded change", acceptanceCondition: "Readback",
                authorityMode: .boundedWrite, relativePaths: ["file.txt"], protectedRelativePaths: ["keep.txt"],
                preexistingDirtyRelativePaths: ["dirty.txt", "keep.txt"])
            XCTAssertEqual(b.declaredProtectedRelativePaths, ["keep.txt"])
            XCTAssertEqual(b.protectedRelativePaths, ["dirty.txt", "keep.txt"])
        }
    }

    func testUnbornGitRepositoryIsUnknownRatherThanCleanNonRepository() throws {
        try temp { root in
            try git(root, ["init"]); let b = try boundary(root); let s = try snapshot(b)
            XCTAssertFalse(s.repository.complete); XCTAssertFalse(s.repository.notRepository)
            XCTAssertEqual(LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: s).disposition, .blocked)
        }
    }

    func testNonGitWorkspaceHasExplicitNonRepositoryDisposition() throws {
        try temp { root in
            let b = try boundary(root); let s = try snapshot(b)
            XCTAssertTrue(s.repository.notRepository); XCTAssertNil(s.repository.headSHA)
            XCTAssertEqual(LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: s).disposition, .continuing)
        }
    }

    func testLeafSymlinkCannotReadOutsideBytes() throws {
        try temp { root in
            let outside = root.appendingPathComponent("outside"); try Data("secret-negative-control".utf8).write(to: outside)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file.txt"), withDestinationURL: outside)
            let b = try boundary(root); let s = try snapshot(b)
            XCTAssertEqual(s.files.first?.state, .unavailable); XCTAssertNil(s.files.first?.sha256)
            XCTAssertEqual(LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: s).disposition, .blocked)
        }
    }

    func testParentSymlinkCannotTraverseOutsideScope() throws {
        try temp { root in
            let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("outside bytes".utf8).write(to: outside.appendingPathComponent("file.txt"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
            let b = try boundary(root, paths: ["link/file.txt"])
            XCTAssertEqual(try snapshot(b).files.first?.state, .unavailable)
        }
    }

    func testByteBoundAndNonregularFileRemainUnavailable() throws {
        try temp { root in
            try Data(repeating: 7, count: 65).write(to: root.appendingPathComponent("file.txt"))
            let b = try boundary(root); XCTAssertEqual(try snapshot(b, maxBytes: 64).files.first?.state, .unavailable)
            let folder = root.appendingPathComponent("folder"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            XCTAssertEqual(try snapshot(boundary(root, paths: ["folder"])).files.first?.state, .unavailable)
        }
    }

    func testProtectedFileChangeBlocksWhilePreservingNegativeReceipt() throws {
        try temp { root in
            let file = root.appendingPathComponent("file.txt"); try Data("protected".utf8).write(to: file)
            let b = try boundary(root, protected: ["file.txt"]); let prior = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            try Data("outside change".utf8).write(to: file)
            let r = LocalOperatorReceiptBuilder.checkpoint(previous: prior, snapshot: try snapshot(b))
            XCTAssertEqual(r.disposition, .blocked); XCTAssertTrue(r.changes.first?.protected == true)
        }
    }

    func testObserveMutationBlocksAndDoesNotInventAuthorship() throws {
        try temp { root in
            let b = try boundary(root, mode: .observe); let before = try snapshot(b)
            try Data("external".utf8).write(to: root.appendingPathComponent("file.txt"))
            let r = LocalOperatorReceiptBuilder.checkpoint(previous: .initForTest(b, before), snapshot: try snapshot(b))
            XCTAssertEqual(r.disposition, .blocked); XCTAssertEqual(r.changes.first?.attribution, "OBSERVED_ONLY_AUTHOR_UNKNOWN")
        }
    }

    func testConsequentChangeRequiresActualOperatorDecision() throws {
        try temp { root in
            let b = try boundary(root, mode: .consequentLocalChange)
            let r = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            XCTAssertEqual(r.disposition, .operatorDecisionRequired)
            XCTAssertEqual(r.authorization.effectiveAuthority(for: b.authorityMode), "NO_CONSEQUENT_GRANT")
        }
    }

    func testRequestedBoundedModeDoesNotSupplyItsOwnWriteGateAuthorizer() throws {
        try temp { root in
            let b = try boundary(root); let s = try snapshot(b)
            let unobserved = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: s)
            XCTAssertFalse(unobserved.authorization.localWriteGateObserved)
            XCTAssertEqual(unobserved.authorization.effectiveAuthority(for: b.authorityMode), "LOCAL_API_GATE_NOT_OBSERVED")
            XCTAssertTrue(LocalOperatorReceiptBuilder.deliveryRefusal(receipt: unobserved, current: s,
                taskSessionID: b.taskSessionID, runtimeAttemptID: b.runtimeAttemptID)?.contains("authorizer") == true)
            let observed = LocalOperatorAuthorizationObservation(localWriteGateObserved: true, nominalCallerIdentity: "nominal fixture")
            XCTAssertEqual(observed.callerIdentityAuthority, "NOMINAL_INITIALIZE_CLIENT_INFO_NOT_SCOPED_PRINCIPAL")
            XCTAssertEqual(observed.effectiveAuthority(for: .consequentLocalChange), "NO_CONSEQUENT_GRANT")
        }
    }

    func testActualShellCwdMustMatchOperationAndExactAttempt() throws {
        try temp { root in
            let b = try boundary(root); let s = try snapshot(b); let receipt = LocalOperatorReceipt.initForTest(b, s)
            func hook(_ cwd: OrchestrationValue<String>, attempt: String? = nil, phase: ShellTelemetryPhase = .directoryChanged) -> ShellTelemetryEvent {
                ShellTelemetryEvent(shellExecutionID: UUID().uuidString, runtimeAttemptID: attempt ?? b.runtimeAttemptID.rawValue.uuidString,
                    phase: phase, shellPID: getpid(), workingDirectory: cwd,
                    observation: .init(authority: .shellHookObserved, freshness: .current, observedAt: .known(Date())))
            }
            XCTAssertNil(LocalOperatorReceiptBuilder.shellWorkingDirectoryRefusal(receipt: receipt, telemetry: hook(.known(root.path))))
            for event in [hook(.unknown), hook(.known(root.deletingLastPathComponent().path)),
                          hook(.known(root.path), attempt: UUID().uuidString), hook(.known(root.path), phase: .shellExited)] {
                XCTAssertNotNil(LocalOperatorReceiptBuilder.shellWorkingDirectoryRefusal(receipt: receipt, telemetry: event))
            }
            XCTAssertNotNil(LocalOperatorReceiptBuilder.shellWorkingDirectoryRefusal(receipt: receipt, telemetry: nil))
        }
    }

    func testFleetWireReadbackPreservesCanonicalIdentityAndRejectsMalformedLinks() throws {
        let task = TaskSessionID(); let attempt = RuntimeAttemptID()
        let process = SupervisionObservationStamp(authority: .processObserved, freshness: .current,
            observedAt: .known(Date(timeIntervalSince1970: 1_800_000_000)))
        let provider = SupervisionObservationStamp(authority: .providerObserved, freshness: .current, observedAt: process.observedAt)
        let link = ShellProviderCorrelation(kind: .exact, taskSessionID: .known(task.rawValue.uuidString),
            runtimeAttemptID: .known(attempt.rawValue.uuidString), shellExecutionID: .known(UUID().uuidString),
            processPID: .known(123), providerSessionID: .known("ses_fixture"), candidateSessionIDs: ["ses_fixture"],
            processObservation: process, providerObservation: provider)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try JSONSerialization.jsonObject(with: encoder.encode(link))
        let fleet: [String: Any] = ["provider_sessions": ["items": [["shell_correlation": object]]]]
        let data = try JSONSerialization.data(withJSONObject: fleet)
        XCTAssertEqual(try LocalOperatorFleetLinkReader.read(data, taskSessionID: task, runtimeAttemptID: attempt), [link])
        XCTAssertTrue(try LocalOperatorFleetLinkReader.read(data, taskSessionID: TaskSessionID(), runtimeAttemptID: attempt).isEmpty)
        let malformed = try JSONSerialization.data(withJSONObject: ["provider_sessions": ["items": [["shell_correlation": ["kind": "exact"]]]]])
        XCTAssertThrowsError(try LocalOperatorFleetLinkReader.read(malformed, taskSessionID: task, runtimeAttemptID: attempt))
        XCTAssertThrowsError(try LocalOperatorFleetLinkReader.read(Data("{}".utf8), taskSessionID: task, runtimeAttemptID: attempt))
    }

    func testStrictLocalToolParsingRejectsDroppedPathsModesAndFractionalRevision() {
        let task = UUID().uuidString; let operation = UUID().uuidString
        var args: [String: CodexJSON] = ["taskSessionID": .string(task), "operation_id": .string(operation),
            "objective": .string("A bounded change"), "acceptance_condition": .string("Actual readback"),
            "mode": .string("BOUNDED_WRITE"), "relative_paths": .array([.string("file.txt")])]
        XCTAssertNotNil(LocalOperatorToolParser.command(named: "conduit_local_begin", arguments: args))
        let invalidPaths: [CodexJSON] = [.array([.string("file.txt"), .number(1)]), .array([.string("../outside")]), .null]
        for value in invalidPaths {
            args["relative_paths"] = value
            XCTAssertNil(LocalOperatorToolParser.command(named: "conduit_local_begin", arguments: args))
        }
        args["relative_paths"] = .array([.string("file.txt")]); args["mode"] = .string("ADMIN")
        XCTAssertNil(LocalOperatorToolParser.command(named: "conduit_local_begin", arguments: args))
        args["expected_revision"] = .number(0.5)
        XCTAssertNil(LocalOperatorToolParser.command(named: "conduit_local_checkpoint", arguments: args))
        args["expected_revision"] = .number(0); args["terminal"] = .string("true")
        XCTAssertNil(LocalOperatorToolParser.command(named: "conduit_local_checkpoint", arguments: args))
        args["terminal"] = .bool(false)
        XCTAssertNotNil(LocalOperatorToolParser.command(named: "conduit_local_checkpoint", arguments: args))
        XCTAssertTrue(LocalOperatorToolParser.isValidOptionalOperationID(nil))
        XCTAssertTrue(LocalOperatorToolParser.isValidOptionalOperationID(.string(operation)))
        let invalidIDs: [CodexJSON] = [.null, .number(0), .string(""), .string("bad-id")]
        for value in invalidIDs {
            XCTAssertFalse(LocalOperatorToolParser.isValidOptionalOperationID(value))
        }
        XCTAssertFalse(ConduitSessionAPI.isWrite(.localPreflight(taskSessionID: task, relativePaths: ["file.txt"])))
        XCTAssertTrue(ConduitSessionAPI.isWrite(.localCheckpoint(taskSessionID: task, operationID: operation, expectedRevision: 0, terminal: false)))
    }

    func testLocalOperationIDsRejectShortenedAndWrongAxisValues() throws {
        try temp { root in
            let task = TaskSessionID(); let attempt = RuntimeAttemptID()
            for operation in [task.rawValue, attempt.rawValue] {
                XCTAssertThrowsError(try LocalOperatorBoundary(taskSessionID: task, runtimeAttemptID: attempt,
                    operationID: operation, projectSlug: "fixture", workingDirectory: root,
                    objective: "Bounded change", acceptanceCondition: "Readback", authorityMode: .boundedWrite,
                    relativePaths: ["file.txt"]))
            }
            let args: [String: CodexJSON] = ["taskSessionID": .string(task.rawValue.uuidString),
                "operation_id": .string(task.rawValue.uuidString), "objective": .string("A bounded change"),
                "acceptance_condition": .string("Readback"), "mode": .string("BOUNDED_WRITE"),
                "relative_paths": .array([.string("file.txt")])]
            XCTAssertNil(LocalOperatorToolParser.command(named: "conduit_local_begin", arguments: args))
            XCTAssertNil(LocalOperatorToolParser.command(named: "conduit_local_preflight", arguments: [
                "taskSessionID": .string(String(task.rawValue.uuidString.prefix(8))), "relative_paths": .array([.string("file.txt")])]))
        }
    }

    func testTerminalAndBlockedOperationsCannotBeReopened() throws {
        try temp { root in
            let b = try boundary(root); let s = try snapshot(b)
            let ended = LocalOperatorReceiptBuilder.checkpoint(previous: .initForTest(b, s), snapshot: s, terminal: true)
            XCTAssertEqual(LocalOperatorReceiptBuilder.checkpoint(previous: ended, snapshot: s).disposition, .terminal)
            let observe = try boundary(root, mode: .observe); let original = try snapshot(observe)
            try Data("changed".utf8).write(to: root.appendingPathComponent("file.txt"))
            let blocked = LocalOperatorReceiptBuilder.checkpoint(previous: .initForTest(observe, original), snapshot: try snapshot(observe))
            XCTAssertEqual(LocalOperatorReceiptBuilder.checkpoint(previous: blocked, snapshot: original).disposition, .blocked)
        }
    }

    func testPhysicalOwnedProcessIdentityAllowsBoundedDeliveryPreflight() throws {
        try temp { root in
            let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["60"]
            try child.run(); defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
            let b = try boundary(root)
            let beforeTree = MacOSProcessTreeObserver.observe(rootPID: child.processIdentifier,
                taskSessionID: b.taskSessionID.rawValue.uuidString, runtimeAttemptID: b.runtimeAttemptID.rawValue.uuidString,
                rootOwnership: .taskCreated)
            let before = try snapshot(b, process: beforeTree)
            let afterTree = MacOSProcessTreeObserver.observe(rootPID: child.processIdentifier,
                taskSessionID: b.taskSessionID.rawValue.uuidString, runtimeAttemptID: b.runtimeAttemptID.rawValue.uuidString,
                rootOwnership: .taskCreated, prior: beforeTree)
            let current = try snapshot(b, process: afterTree)
            XCTAssertNil(LocalOperatorReceiptBuilder.deliveryRefusal(receipt: .initForTest(b, before), current: current,
                taskSessionID: b.taskSessionID, runtimeAttemptID: b.runtimeAttemptID))
            XCTAssertEqual(current.processes.launcher.value?.pid, child.processIdentifier)
            XCTAssertTrue(current.processes.launcher.value?.startIdentity.isKnown == true)
        }
    }

    func testExternalChangeRefusesBeforeAnyShellDelivery() throws {
        try temp { root in
            let b = try boundary(root); let before = try snapshot(b)
            try Data("external bytes".utf8).write(to: root.appendingPathComponent("file.txt"))
            let refusal = LocalOperatorReceiptBuilder.deliveryRefusal(receipt: .initForTest(b, before), current: try snapshot(b),
                taskSessionID: b.taskSessionID, runtimeAttemptID: b.runtimeAttemptID)
            XCTAssertTrue(refusal?.contains("External") == true)
        }
    }

    func testWrongRuntimeAttemptCannotUseAnotherOperation() throws {
        try temp { root in
            let b = try boundary(root); let s = try snapshot(b)
            XCTAssertEqual(LocalOperatorReceiptBuilder.deliveryRefusal(receipt: .initForTest(b, s), current: s,
                taskSessionID: b.taskSessionID, runtimeAttemptID: RuntimeAttemptID()), "Task/runtime attempt changed.")
        }
    }

    func testUnavailableProcessEvidenceCannotGrantDelivery() throws {
        try temp { root in
            let b = try boundary(root); let s = try snapshot(b)
            XCTAssertTrue(LocalOperatorReceiptBuilder.deliveryRefusal(receipt: .initForTest(b, s), current: s,
                taskSessionID: b.taskSessionID, runtimeAttemptID: b.runtimeAttemptID)?.contains("launcher") == true)
        }
    }

    func testObserveModeNeverAuthorizesArbitraryShellInput() throws {
        try temp { root in
            let b = try boundary(root, mode: .observe); let s = try snapshot(b)
            XCTAssertTrue(LocalOperatorReceiptBuilder.deliveryRefusal(receipt: .initForTest(b, s), current: s,
                taskSessionID: b.taskSessionID, runtimeAttemptID: b.runtimeAttemptID)?.contains("OBSERVE") == true)
        }
    }

    func testWrongTaskProcessEvidenceStaysUnavailable() throws {
        try temp { root in
            let b = try boundary(root); let another = try boundary(root)
            let s = try snapshot(b, process: unknown(another))
            XCTAssertEqual(s.processes.coverage, .unavailable)
            XCTAssertEqual(s.processes.taskSessionID, b.taskSessionID.rawValue.uuidString)
        }
    }

    func testStoreRecoveryAndReadNeverRewriteImmutableBytes() throws {
        try temp { root in
            let b = try boundary(root); let s = try snapshot(b)
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records"))
            let first = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: s); try store.append(first, expectedRevision: nil)
            let initialURL = store.directory.appendingPathComponent("\(b.taskSessionID.rawValue.uuidString).\(b.operationID.uuidString).000.json")
            let bytes = try Data(contentsOf: initialURL)
            let second = LocalOperatorReceiptBuilder.checkpoint(previous: first, snapshot: s, terminal: true)
            try store.append(second, expectedRevision: 0)
            let recovered = try LocalOperatorRecordStore(directory: store.directory).records(taskSessionID: b.taskSessionID, operationID: b.operationID)
            XCTAssertEqual(recovered, [first, second]); XCTAssertEqual(try Data(contentsOf: initialURL), bytes)
            let mode = try FileManager.default.attributesOfItem(atPath: initialURL.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
    }

    func testDuplicateOrStaleWriterCannotReplaceARecord() throws {
        try temp { root in
            let b = try boundary(root); let r = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records"))
            try store.append(r, expectedRevision: nil)
            XCTAssertThrowsError(try store.append(r, expectedRevision: nil)) { XCTAssertEqual($0 as? LocalOperatorError, .staleRevision) }
            XCTAssertEqual(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID), [r])
        }
    }

    func testPartialCorruptHistoryFailsClosedWithoutRepair() throws {
        try temp { root in
            let b = try boundary(root); let r = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records")); try store.append(r, expectedRevision: nil)
            let url = store.directory.appendingPathComponent("\(b.taskSessionID.rawValue.uuidString).\(b.operationID.uuidString).001.json")
            let torn = Data("{\"partial\":".utf8); try torn.write(to: url)
            XCTAssertThrowsError(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID))
            XCTAssertEqual(try Data(contentsOf: url), torn)
        }
    }

    func testMissingHistoryRevisionIsNotAnEmptySuccessfulRecord() throws {
        try temp { root in
            let b = try boundary(root); let r = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records")); try store.append(r, expectedRevision: nil)
            let old = store.directory.appendingPathComponent("\(b.taskSessionID.rawValue.uuidString).\(b.operationID.uuidString).000.json")
            let moved = store.directory.appendingPathComponent("\(b.taskSessionID.rawValue.uuidString).\(b.operationID.uuidString).001.json")
            try FileManager.default.moveItem(at: old, to: moved)
            XCTAssertThrowsError(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID))
        }
    }

    func testReadonlyMissingStoreDoesNotCreateAStore() throws {
        try temp { root in
            let b = try boundary(root); let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("absent"))
            XCTAssertThrowsError(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        }
    }

    func testMalformedLockObjectsRefuseReadAndAppendWithoutRepair() throws {
        for kind in ["fifo", "directory", "symlink", "hardlink", "public-permissions"] {
            try temp { root in
                let b = try boundary(root)
                let r = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
                let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records"))
                try store.append(r, expectedRevision: nil)
                let record = store.directory.appendingPathComponent("\(b.taskSessionID.rawValue.uuidString).\(b.operationID.uuidString).000.json")
                let bytes = try Data(contentsOf: record)
                let lock = store.directory.appendingPathComponent(".writer.lock")
                if kind == "hardlink" {
                    XCTAssertEqual(Darwin.link(lock.path, root.appendingPathComponent("other-link").path), 0)
                } else if kind == "public-permissions" {
                    XCTAssertEqual(Darwin.chmod(lock.path, 0o644), 0)
                } else {
                    try FileManager.default.removeItem(at: lock)
                    if kind == "fifo" { XCTAssertEqual(Darwin.mkfifo(lock.path, 0o600), 0) }
                    if kind == "directory" {
                        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
                    }
                    if kind == "symlink" {
                        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: record)
                    }
                }
                var before = stat(); XCTAssertEqual(Darwin.lstat(lock.path, &before), 0)
                let start = Date()
                XCTAssertThrowsError(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID)) {
                    XCTAssertEqual($0 as? LocalOperatorError, .unavailableStore, kind)
                }
                XCTAssertThrowsError(try store.append(r, expectedRevision: nil)) {
                    XCTAssertEqual($0 as? LocalOperatorError, .unavailableStore, kind)
                }
                XCTAssertLessThan(Date().timeIntervalSince(start), 1, kind)
                var after = stat(); XCTAssertEqual(Darwin.lstat(lock.path, &after), 0)
                XCTAssertEqual(before.st_ino, after.st_ino, kind)
                XCTAssertEqual(before.st_mode, after.st_mode, kind)
                XCTAssertEqual(before.st_nlink, after.st_nlink, kind)
                XCTAssertEqual(try Data(contentsOf: record), bytes, kind)
            }
        }
    }

    func testReadonlyMissingLockDoesNotCreateOrRepairIt() throws {
        try temp { root in
            let b = try boundary(root)
            let directory = root.appendingPathComponent("empty-records")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let store = LocalOperatorRecordStore(directory: directory)
            XCTAssertThrowsError(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID)) {
                XCTAssertEqual($0 as? LocalOperatorError, .unavailableStore)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testLockContentionIsBoundedAndRecoveryPreservesRevisionRules() throws {
        try temp { root in
            let b = try boundary(root); let s = try snapshot(b)
            let first = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: s)
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records"))
            try store.append(first, expectedRevision: nil)
            let lock = Darwin.open(store.directory.appendingPathComponent(".writer.lock").path,
                O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(lock, 0); defer { Darwin.close(lock) }
            XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
            XCTAssertThrowsError(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID))
            XCTAssertThrowsError(try store.append(first, expectedRevision: nil))
            XCTAssertEqual(flock(lock, LOCK_UN), 0)
            XCTAssertEqual(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID), [first])
            XCTAssertThrowsError(try store.append(first, expectedRevision: nil)) {
                XCTAssertEqual($0 as? LocalOperatorError, .staleRevision)
            }
            let second = LocalOperatorReceiptBuilder.checkpoint(previous: first, snapshot: s, terminal: true)
            try store.append(second, expectedRevision: 0)
            XCTAssertEqual(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID), [first, second])
        }
    }

    func testSharedReaderLockDoesNotBecomeWriterAuthority() throws {
        try temp { root in
            let b = try boundary(root); let r = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records"))
            try store.append(r, expectedRevision: nil)
            let lock = Darwin.open(store.directory.appendingPathComponent(".writer.lock").path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(lock, 0); defer { Darwin.close(lock) }
            XCTAssertEqual(flock(lock, LOCK_SH | LOCK_NB), 0); defer { _ = flock(lock, LOCK_UN) }
            XCTAssertEqual(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID), [r])
            XCTAssertThrowsError(try store.append(r, expectedRevision: nil)) {
                XCTAssertEqual($0 as? LocalOperatorError, .unavailableStore)
            }
        }
    }

    func testGroupAccessibleDirectoryRefusesWithoutChangingPermissions() throws {
        try temp { root in
            let b = try boundary(root); let r = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records"))
            try store.append(r, expectedRevision: nil)
            XCTAssertEqual(Darwin.chmod(store.directory.path, 0o750), 0)
            XCTAssertThrowsError(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID))
            XCTAssertThrowsError(try store.append(r, expectedRevision: nil))
            var s = stat(); XCTAssertEqual(Darwin.lstat(store.directory.path, &s), 0)
            XCTAssertEqual(s.st_mode & 0o777, 0o750)
        }
    }

    func testHeldLockInodeReplacementIsRefused() throws {
        try temp { root in
            let b = try boundary(root); let r = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records"))
            try store.append(r, expectedRevision: nil)
            let fd = Darwin.open(store.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let lock = Darwin.openat(fd, ".writer.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertGreaterThanOrEqual(lock, 0)
            defer { Darwin.close(lock); Darwin.close(fd) }
            XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0); defer { _ = flock(lock, LOCK_UN) }
            try store.validateLockEnvelope(directoryFD: fd, lockFD: lock)
            let named = store.directory.appendingPathComponent(".writer.lock")
            try FileManager.default.moveItem(at: named, to: store.directory.appendingPathComponent("old-lock"))
            XCTAssertTrue(FileManager.default.createFile(atPath: named.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
            XCTAssertThrowsError(try store.validateLockEnvelope(directoryFD: fd, lockFD: lock)) {
                XCTAssertEqual($0 as? LocalOperatorError, .unavailableStore)
            }
        }
    }

    func testOpenedDirectoryReplacementIsRefused() throws {
        try temp { root in
            let b = try boundary(root); let r = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records"))
            try store.append(r, expectedRevision: nil)
            let fd = Darwin.open(store.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let lock = Darwin.openat(fd, ".writer.lock", O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(fd, 0); XCTAssertGreaterThanOrEqual(lock, 0)
            defer { Darwin.close(lock); Darwin.close(fd) }
            XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0); defer { _ = flock(lock, LOCK_UN) }
            try store.validateLockEnvelope(directoryFD: fd, lockFD: lock)
            try FileManager.default.moveItem(at: store.directory, to: root.appendingPathComponent("moved-records"))
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            XCTAssertThrowsError(try store.validateLockEnvelope(directoryFD: fd, lockFD: lock)) {
                XCTAssertEqual($0 as? LocalOperatorError, .unavailableStore)
            }
        }
    }

    func testSemanticTamperingCannotHideFileChangeOrGrantConsequentAuthority() throws {
        try temp { root in
            let b = try boundary(root, mode: .consequentLocalChange)
            let r = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records")); try store.append(r, expectedRevision: nil)
            let url = store.directory.appendingPathComponent("\(b.taskSessionID.rawValue.uuidString).\(b.operationID.uuidString).000.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["disposition"] = "CONTINUING"
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
            XCTAssertThrowsError(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID))
        }
        try temp { root in
            let b = try boundary(root, mode: .observe); let first = LocalOperatorReceiptBuilder.begin(boundary: b, snapshot: try snapshot(b))
            try Data("changed".utf8).write(to: root.appendingPathComponent("file.txt"))
            let r = LocalOperatorReceiptBuilder.checkpoint(previous: first, snapshot: try snapshot(b))
            let store = LocalOperatorRecordStore(directory: root.appendingPathComponent("records")); try store.append(first, expectedRevision: nil); try store.append(r, expectedRevision: 0)
            let url = store.directory.appendingPathComponent("\(b.taskSessionID.rawValue.uuidString).\(b.operationID.uuidString).001.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            object["changes"] = []; object["disposition"] = "CONTINUING"
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
            XCTAssertThrowsError(try store.records(taskSessionID: b.taskSessionID, operationID: b.operationID))
        }
    }
}

private extension LocalOperatorReceipt {
    static func initForTest(_ boundary: LocalOperatorBoundary, _ snapshot: LocalOperatorSnapshot) -> Self {
        LocalOperatorReceiptBuilder.begin(boundary: boundary, snapshot: snapshot,
            authorization: .init(localWriteGateObserved: true))
    }
}
