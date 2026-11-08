import Foundation
import XCTest
@testable import ConduitCore

/// Source-development checks, using only disposable native fixtures.
final class ConduitSupervisorSuccessorTests: XCTestCase {
    private func fixture(_ body: (URL, URL, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-d2-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project"), store = base.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = repo.appendingPathComponent(".build/debug/conduit-command-supervisor")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ConduitDirectCommandError(code: "helper_not_built", detail: "Build conduit-command-supervisor before this development suite")
        }
        defer {
            // Retain real fixture bytes when the development run requests evidence.
            // This path selects evidence storage, never execution authority.
            if let path = ProcessInfo.processInfo.environment["CONDUIT_D2_TEST_EVIDENCE"] {
                do {
                    let destination = URL(fileURLWithPath: path).appendingPathComponent(name).appendingPathComponent(base.lastPathComponent)
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: base, to: destination)
                    print("D2_FIXTURE_EVIDENCE \(destination.path)")
                    try FileManager.default.removeItem(at: base)
                } catch { XCTFail("Fixture evidence could not be retained: \(error)") }
            } else { try? FileManager.default.removeItem(at: base) }
        }
        try body(root, store, helper)
    }

    private func owner(_ store: URL, _ root: URL, _ helper: URL) -> ConduitDirectCommandService {
        ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: root,
                                    maximumConcurrentOperations: 1, supervisorExecutable: helper)
    }

    private func request(_ id: String, _ script: String = "printf x >> effect", timeout: Int = 3_000) -> ConduitDirectCommandRequest {
        .init(operationID: id, projectSlug: "fixture", argv: ["/bin/sh", "-c", script], timeoutMS: timeout, maxOutputBytes: 1_024)
    }

    private func observe(_ service: ConduitDirectCommandService, _ request: ConduitDirectCommandRequest, _ root: URL,
                         until predicate: (ConduitDirectCommandReceipt) -> Bool = { $0.phase.isTerminal }) throws -> ConduitDirectCommandReceipt {
        let deadline = ProcessInfo.processInfo.systemUptime + 9
        repeat {
            let receipt = try service.lookup(operationID: request.operationID, projectSlug: "fixture", projectRoot: root)
            if predicate(receipt) { return receipt }
            Thread.sleep(forTimeInterval: 0.002)
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("Bounded supervisor condition not observed")
        return try service.lookup(operationID: request.operationID, projectSlug: "fixture", projectRoot: root)
    }

    private func expect(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? ConduitDirectCommandError)?.code, code, file: file, line: line)
        }
    }

    private func snapshot(_ store: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: store.path).map {
            ($0, try Data(contentsOf: store.appendingPathComponent($0)))
        })
    }

    private func completed(_ root: URL, _ store: URL, _ helper: URL) throws -> ConduitDirectCommandReceipt {
        var service: ConduitDirectCommandService? = owner(store, root, helper)
        weak var released = service
        let req = request("history")
        _ = try service!.submit(req, projectRoot: root)
        let end = try observe(service!, req, root)
        XCTAssertEqual(end.phase, .exited, end.note ?? "")
        XCTAssertTrue(end.executionCapacityReleased)
        service = nil
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while released != nil && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.002) }
        XCTAssertNil(released, "Fresh-owner checks require release of the original service and lock")
        return end
    }

    func testNaturalRootExitBeforeDeadlineIsNotTimedOutByObservationWindow() throws {
        for code in [0, 7] {
            try fixture { root, store, helper in
                let service = owner(store, root, helper)
                let req = request("early-\(code)", "exit \(code)", timeout: 200)
                let start = ProcessInfo.processInfo.systemUptime
                _ = try service.submit(req, projectRoot: root)
                let rootSeen = try observe(service, req, root, until: { $0.supervision?.rootExitObserved == true || $0.phase.isTerminal })
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                XCTAssertTrue(rootSeen.supervision?.rootExitObserved == true)
                XCTAssertFalse(rootSeen.phase.isTerminal)
                XCTAssertLessThan(elapsed, 0.2, "Precondition: root exit was observed before even the submit-relative deadline")
                let end = try observe(service, req, root)
                print("D2_DEADLINE exit=\(code) root_seen_seconds=\(elapsed) phase=\(end.phase.rawValue) cause=\(String(describing: end.supervision?.cleanupCause))")
                XCTAssertEqual(end.phase, code == 0 ? .exited : .nonzero, end.note ?? "")
                XCTAssertEqual(end.exitCode, Int32(code))
                XCTAssertNil(end.terminationSignal)
                XCTAssertEqual(end.supervision?.cleanupCause, 0)
                XCTAssertNil(end.supervision?.cancellationAccepted)
                XCTAssertTrue(end.directChildExitObserved && end.processGroupAbsentObserved && end.executionCapacityReleased)
            }
        }
    }

    func testMissingOutcomeMarkersAreUnresolvedAndReadOnly() throws {
        for suffix in ["reserved", "launch-claim"] {
            try fixture { root, store, _ in
                try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Data("preserved-ambiguous-attempt\n".utf8).write(to: store.appendingPathComponent("history.\(suffix)"))
                let before = try snapshot(store)
                let reader = ConduitDirectCommandService(storeDirectory: store)
                var admissions = 0
                expect("operation_receipt_missing") { _ = try reader.lookup(operationID: "history", projectSlug: "fixture", projectRoot: root) }
                expect("operation_receipt_missing") { _ = try reader.submit(request("history"), projectRoot: root) { admissions += 1 } }
                XCTAssertEqual(admissions, 0)
                XCTAssertEqual(try snapshot(store), before)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
            }
        }
    }

    func testNaturalExitWithUnresolvedOriginalGroupDoesNotReleaseCapacity() throws {
        try fixture { root, store, helper in
            let service = owner(store, root, helper)
            let req = request("lingering", "(/bin/sleep 3) >/dev/null 2>&1 & exit 7", timeout: 200)
            let start = ProcessInfo.processInfo.systemUptime
            _ = try service.submit(req, projectRoot: root)
            let end = try observe(service, req, root)
            XCTAssertEqual(end.phase, .unknown)
            XCTAssertEqual(end.exitCode, 7)
            XCTAssertEqual(end.supervision?.cleanupCause, 0)
            XCTAssertTrue(end.directChildExitObserved)
            XCTAssertFalse(end.processGroupAbsentObserved || end.executionCapacityReleased)
            expect("command_capacity_exhausted") { _ = try service.submit(request("new"), projectRoot: root) }
            // Let the cooperative fixture self-expire; no recovered PID is signalled.
            let remaining = 3.5 - (ProcessInfo.processInfo.systemUptime - start)
            if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        }
    }

    func testFreshReaderRetainsHistoryWithoutRecoveringExecution() throws {
        try fixture { root, store, helper in
            let end = try completed(root, store, helper)
            let before = try snapshot(store)
            let reader = ConduitDirectCommandService(storeDirectory: store)
            var admissions = 0
            let lookup = try reader.lookup(operationID: "history", projectSlug: "fixture", projectRoot: root)
            let replay = try reader.submit(request("history"), projectRoot: root) { admissions += 1 }
            let cancel = try reader.cancel(operationID: "history", projectSlug: "fixture", projectRoot: root) { admissions += 1 }
            for value in [lookup, replay, cancel] {
                XCTAssertEqual(value.phase, .exited)
                XCTAssertEqual(value.exitCode, end.exitCode)
                XCTAssertEqual(value.transitions, end.transitions)
                XCTAssertEqual(value.ownerInstanceID, end.ownerInstanceID)
                XCTAssertEqual(value.supervision?.attemptNonce, end.supervision?.attemptNonce)
                XCTAssertTrue(value.supervision?.finalFrameObserved == true && value.supervision?.controlClosed == true)
                XCTAssertFalse(value.executionCapacityReleased)
            }
            XCTAssertTrue(replay.idempotentReplay)
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(try snapshot(store), before)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("effect")), "x")

            let freshOwner = owner(store, root, helper)
            expect("supervisor_recovery_required") { _ = try freshOwner.submit(request("new"), projectRoot: root) }
            XCTAssertEqual(try snapshot(store), before, "Existing lock may be synchronized, but no operation artifact may be added")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("effect")), "x")
        }
    }

    func testRecoveredNonterminalSnapshotDoesNotAuthorizeCancellation() throws {
        try fixture { root, store, helper in
            var historical = try completed(root, store, helper)
            // Declared synthetic nonterminal snapshot, not a crash experiment.
            historical.phase = .running
            historical.transitions.removeAll { $0.phase.isTerminal }
            historical.endedAt = nil
            historical.executionCapacityReleased = false
            try JSONEncoder().encode(historical).write(to: store.appendingPathComponent("history.json"))
            let before = try snapshot(store)
            let reader = ConduitDirectCommandService(storeDirectory: store)
            var admissions = 0
            let observed = try reader.lookup(operationID: "history", projectSlug: "fixture", projectRoot: root)
            let replay = try reader.submit(request("history"), projectRoot: root) { admissions += 1 }
            for value in [observed, replay] {
                XCTAssertEqual(value.phase, .unknown)
                XCTAssertEqual(value.transitions, historical.transitions)
                XCTAssertEqual(value.pid, historical.pid)
                XCTAssertEqual(value.ownerInstanceID, historical.ownerInstanceID)
                XCTAssertEqual(value.supervision?.attemptNonce, historical.supervision?.attemptNonce)
                XCTAssertFalse(value.executionCapacityReleased)
            }
            expect("process_ownership_unavailable") { _ = try reader.cancel(operationID: "history", projectSlug: "fixture", projectRoot: root) { admissions += 1 } }
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(try snapshot(store), before)
        }
    }

    func testAmbiguousClaimsAndMissingClaimsNeverReleaseHistoricalCapacity() throws {
        for body in ["", "not-a-nonce\n", "0123456789abcdef0123456789abcdef\n"] {
            try fixture { root, store, helper in
                try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let claim = store.appendingPathComponent("history.launch-claim")
                try Data(body.utf8).write(to: claim)
                let service = owner(store, root, helper)
                expect("supervisor_recovery_required") { _ = try service.submit(request("new"), projectRoot: root) }
                XCTAssertEqual(try Data(contentsOf: claim), Data(body.utf8))
                XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("new.reserved").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
            }
        }
        try fixture { root, store, helper in
            _ = try completed(root, store, helper)
            // Remove only a disposable fixture marker to model incomplete custody.
            try FileManager.default.removeItem(at: store.appendingPathComponent("history.launch-claim"))
            let before = try snapshot(store)
            let service = owner(store, root, helper)
            XCTAssertFalse(try service.submit(request("history"), projectRoot: root).executionCapacityReleased)
            expect("unresolved_command_ownership") { _ = try service.submit(request("new"), projectRoot: root) }
            XCTAssertEqual(try snapshot(store), before)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("effect")), "x")
        }
    }

    func testReplayIdentityConflictsAndCorruptReceiptNeverFallThrough() throws {
        try fixture { root, store, helper in
            _ = try completed(root, store, helper)
            let original = request("history")
            let variants = [
                request("history", "printf bad >> effect"),
                ConduitDirectCommandRequest(operationID: "history", projectSlug: "other", argv: original.argv, timeoutMS: 3_000, maxOutputBytes: 1_024),
                ConduitDirectCommandRequest(operationID: "history", projectSlug: "fixture", argv: original.argv, cwd: "sub", timeoutMS: 3_000, maxOutputBytes: 1_024),
                request("history", timeout: 2_999),
                ConduitDirectCommandRequest(operationID: "history", projectSlug: "fixture", argv: original.argv, timeoutMS: 3_000, maxOutputBytes: 1_023),
                ConduitDirectCommandRequest(operationID: "history", projectSlug: "fixture", argv: original.argv, timeoutMS: 3_000, maxOutputBytes: 1_024, maxTailBytes: 0),
            ]
            let before = try snapshot(store)
            let reader = ConduitDirectCommandService(storeDirectory: store)
            var admissions = 0
            for variant in variants {
                expect("operation_id_conflict") { _ = try reader.submit(variant, projectRoot: root) { admissions += 1 } }
            }
            XCTAssertEqual(try snapshot(store), before)
            let corrupt = Data("{unreadable historical outcome".utf8)
            try corrupt.write(to: store.appendingPathComponent("history.json"))
            expect("receipt_corrupt") { _ = try reader.lookup(operationID: "history", projectSlug: "fixture", projectRoot: root) }
            expect("receipt_corrupt") { _ = try reader.submit(original, projectRoot: root) { admissions += 1 } }
            XCTAssertEqual(try Data(contentsOf: store.appendingPathComponent("history.json")), corrupt)
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("effect")), "x")
        }
    }
}
