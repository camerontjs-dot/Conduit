import Foundation
import XCTest
@testable import ConduitCore
#if canImport(Darwin)
import Darwin
#endif

final class ConduitCommandSupervisorTests: XCTestCase {
    private func fixture(_ body: (URL, URL, ConduitDirectCommandService) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-supervisor-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project"), store = base.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = repo.appendingPathComponent(".build/debug/conduit-command-supervisor")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw ConduitDirectCommandError(code: "helper_not_built", detail: "Build conduit-command-supervisor before this development suite")
        }
        defer { try? FileManager.default.removeItem(at: base) }
        let service = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: root,
                                                 maximumConcurrentOperations: 1, supervisorExecutable: helper)
        try body(root, store, service)
    }

    private func observe(_ service: ConduitDirectCommandService, _ request: ConduitDirectCommandRequest,
                         _ root: URL, until predicate: (ConduitDirectCommandReceipt) -> Bool = { $0.phase.isTerminal }) throws -> ConduitDirectCommandReceipt {
        let deadline = ProcessInfo.processInfo.systemUptime + 9
        repeat {
            let value = try service.lookup(operationID: request.operationID, projectSlug: "fixture", projectRoot: root)
            if predicate(value) { return value }
            Thread.sleep(forTimeInterval: 0.005)
        } while ProcessInfo.processInfo.systemUptime < deadline
        XCTFail("Bounded supervisor condition not observed")
        return try service.lookup(operationID: request.operationID, projectSlug: "fixture", projectRoot: root)
    }

    private func request(_ id: String, _ script: String, timeout: Int = 3_000, output: Int = 1_024, tail: Int? = nil) -> ConduitDirectCommandRequest {
        .init(operationID: id, projectSlug: "fixture", argv: ["/bin/sh", "-c", script], timeoutMS: timeout,
              maxOutputBytes: output, maxTailBytes: tail)
    }

    func testSupervisorLiteralOutputStableRetryAndRootStatus() throws {
        try fixture { root, store, service in
            let req = request("one-effect", "printf x >> effect; printf 'root-out'; printf 'root-err' >&2; exit 7")
            _ = try service.submit(req, projectRoot: root)
            let end = try observe(service, req, root)
            XCTAssertEqual(end.phase, .nonzero, end.note ?? "")
            XCTAssertEqual(end.exitCode, 7)
            XCTAssertEqual(end.stdout.utf8Text, "root-out"); XCTAssertEqual(end.stderr.utf8Text, "root-err")
            XCTAssertEqual(end.schemaVersion, "conduit-direct-command/v2")
            XCTAssertTrue(end.supervision?.goCommitted == true)
            XCTAssertTrue(end.supervision?.finalFrameObserved == true)
            XCTAssertTrue(end.supervision?.controlClosed == true)
            XCTAssertTrue(end.executionCapacityReleased)
            for _ in 0..<4 { XCTAssertTrue(try service.submit(req, projectRoot: root).idempotentReplay) }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("effect")), "x")
            let reader = ConduitDirectCommandService(storeDirectory: store)
            let replay = try reader.submit(req, projectRoot: root)
            XCTAssertTrue(replay.idempotentReplay)
            XCTAssertEqual(replay.exitCode, 7)
            XCTAssertFalse(replay.executionCapacityReleased, "Historical v2 records cannot restore this owner's capacity acknowledgement")
        }
    }

    func testBoundedLateCancellationAfterNaturalRootExitPreservesCode() throws {
        try fixture { root, _, service in
            let req = request("late-root", "(trap '' TERM; /bin/sleep 4) >/dev/null 2>&1 & printf '%s' \"$!\" > child; exit 7")
            _ = try service.submit(req, projectRoot: root)
            let observed = try observe(service, req, root, until: { $0.supervision?.rootExitObserved == true || $0.phase.isTerminal })
            XCTAssertFalse(observed.phase.isTerminal, "Root must remain cancellable for the bounded window")
            XCTAssertEqual(observed.exitCode, 7)
            _ = try service.cancel(operationID: req.operationID, projectSlug: "fixture", projectRoot: root)
            let end = try observe(service, req, root)
            XCTAssertEqual(end.phase, .observedCancelled, end.note ?? "")
            XCTAssertEqual(end.exitCode, 7); XCTAssertNil(end.terminationSignal)
            XCTAssertTrue(end.supervision?.cancellationAccepted == true)
            XCTAssertTrue(end.directChildExitObserved && end.processGroupAbsentObserved)
            XCTAssertTrue(end.executionCapacityReleased)
            print("SUPERVISOR_LATE root=\(end.exitCode ?? -1) accepted=\(end.supervision?.cancellationAccepted == true) group_absent=\(end.processGroupAbsentObserved)")
        }
    }

    func testTimeoutControlsTermIgnoringOriginalGroup() throws {
        try fixture { root, _, service in
            let req = request("timeout", "(trap '' TERM; /bin/sleep 4) >/dev/null 2>&1 & wait", timeout: 300)
            _ = try service.submit(req, projectRoot: root)
            let end = try observe(service, req, root)
            XCTAssertEqual(end.phase, .timedOut, end.note ?? "")
            XCTAssertEqual(end.terminationSignal, SIGTERM)
            XCTAssertTrue(end.processGroupAbsentObserved && end.executionCapacityReleased)
        }
    }

    func testOutputBoundsRemainSeparateFromSuccessfulCompletion() throws {
        try fixture { root, _, service in
            let req = request("flood", "i=0; while [ $i -lt 10000 ]; do printf abcdefgh; i=$((i+1)); done; printf TAIL", output: 32, tail: 16)
            _ = try service.submit(req, projectRoot: root)
            let end = try observe(service, req, root)
            XCTAssertEqual(end.phase, .exited, end.note ?? "")
            XCTAssertEqual(end.stdout.totalBytesObserved, 80_004)
            XCTAssertEqual(end.stdout.bytes.count, 32)
            XCTAssertEqual(end.stdout.tailBytes?.suffix(4), Data("TAIL".utf8))
            XCTAssertTrue(end.stdout.truncated && end.stdout.reachedEOF)
        }
    }

    func testExistingImmutableLaunchClaimPreventsPayload() throws {
        try fixture { root, store, service in
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try Data("prior-attempt\n".utf8).write(to: store.appendingPathComponent("blocked.launch-claim"))
            let req = request("blocked", "printf x >> effect")
            XCTAssertThrowsError(try service.submit(req, projectRoot: root)) { error in
                XCTAssertEqual((error as? ConduitDirectCommandError)?.code, "operation_receipt_missing")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
        }
    }

    func testFinalPersistenceFailureQuarantinesSuccessfulSupervisorCleanup() throws {
        try fixture { root, _, service in
            var hits = 0
            service.fixtureIO = { point, perform in
                if point == "receipt.exited.directorySync" { hits += 1; return fsync(-1) }
                return perform()
            }
            let req = request("final-fault", "printf x >> effect")
            _ = try service.submit(req, projectRoot: root)
            let end = try observe(service, req, root)
            XCTAssertEqual(hits, 1)
            XCTAssertEqual(end.phase, .unknown)
            XCTAssertFalse(end.executionCapacityReleased)
            XCTAssertTrue(end.directChildExitObserved && end.processGroupAbsentObserved)
            XCTAssertThrowsError(try service.submit(request("other", "printf bad >> effect"), projectRoot: root)) { error in
                XCTAssertEqual((error as? ConduitDirectCommandError)?.code, "command_capacity_exhausted")
            }
            XCTAssertTrue(try service.submit(req, projectRoot: root).idempotentReplay)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("effect")), "x")
        }
    }

    func testCancellationAfterClosedWindowCannotReopenAuthority() throws {
        try fixture { root, _, service in
            let req = request("closed", "printf x >> effect")
            _ = try service.submit(req, projectRoot: root)
            let end = try observe(service, req, root)
            for _ in 0..<3 {
                let after = try service.cancel(operationID: req.operationID, projectSlug: "fixture", projectRoot: root)
                XCTAssertEqual(after.supervision?.lastEventRevision, end.supervision?.lastEventRevision)
                XCTAssertEqual(after.exitCode, end.exitCode)
                XCTAssertNil(after.supervision?.cancellationAccepted)
            }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("effect")), "x")
        }
    }

    func testGuardAndSupervisorFixtureLimitRemainClosed() throws {
        try fixture { root, store, service in
            let publicService = ConduitDirectCommandService(storeDirectory: store)
            XCTAssertThrowsError(try publicService.submit(request("guard", "printf bad > effect"), projectRoot: root)) { error in
                XCTAssertEqual((error as? ConduitDirectCommandError)?.code, "execution_authority_unavailable")
            }
            XCTAssertThrowsError(try service.submit(request("limit", "printf bad > effect", timeout: 6_000), projectRoot: root)) { error in
                XCTAssertEqual((error as? ConduitDirectCommandError)?.code, "supervisor_fixture_limit")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        }
    }
}
