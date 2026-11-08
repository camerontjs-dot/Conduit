import Foundation
import XCTest
@testable import ConduitCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ConduitDirectCommandPersistenceFaultTests: XCTestCase {
    private enum Boundary: String, CaseIterable, Equatable {
        case create, write, fileSync, rename, directorySync

        func failWithRealSyscall() -> Int32 {
            switch self {
            case .create:
                return openat(-1, "injected-create", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            case .write:
                var byte: UInt8 = 0
                return withUnsafePointer(to: &byte) { pointer in
                    #if canImport(Darwin)
                    Int32(Darwin.write(-1, pointer, 1))
                    #else
                    Int32(Glibc.write(-1, pointer, 1))
                    #endif
                }
            case .fileSync, .directorySync:
                return fsync(-1)
            case .rename:
                return renameat(-1, "injected-source", -1, "injected-destination")
            }
        }
    }

    private final class FaultWitness {
        private let lock = NSLock()
        private let target: String
        private let boundary: Boundary
        private let occurrence: Int
        private var targetCalls = 0
        private var failedResults: [Int32] = []
        private var capturedErrnos: [Int32] = []

        init(target: String, boundary: Boundary, occurrence: Int) {
            self.target = target
            self.boundary = boundary
            self.occurrence = occurrence
        }

        func perform(point: String, operation: () -> Int32) -> Int32 {
            guard point == target else { return operation() }
            lock.lock()
            targetCalls += 1
            let current = targetCalls
            lock.unlock()
            guard current == occurrence else { return operation() }

            errno = 0
            let result = boundary.failWithRealSyscall()
            let observedErrno = errno
            lock.lock()
            failedResults.append(result)
            capturedErrnos.append(observedErrno)
            lock.unlock()
            return result
        }

        var failures: [(result: Int32, error: Int32)] {
            lock.lock(); defer { lock.unlock() }
            return Array(zip(failedResults, capturedErrnos)).map { (result: $0.0, error: $0.1) }
        }

        var witnessLine: String {
            lock.lock()
            let calls = targetCalls
            let observed = Array(zip(failedResults, capturedErrnos))
            lock.unlock()
            let record: [String: Any] = [
                "event": "FAULT_WITNESS",
                "target": target,
                "occurrence": occurrence,
                "target_calls": calls,
                "hit": observed.count == 1,
                "errno": observed.first.map { NSNumber(value: $0.1) as Any } ?? NSNull(),
            ]
            let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            return "FAULT_WITNESS " + String(decoding: data, as: UTF8.self)
        }
    }

    private enum Scenario: Equatable {
        case reservation
        case queued
        case started
        case running
        case periodicRunning
        case exited
        case cancelRequested

        var receiptPhase: String? {
            switch self {
            case .reservation: return nil
            case .queued: return "queued"
            case .started: return "started"
            case .running, .periodicRunning: return "running"
            case .exited: return "exited"
            case .cancelRequested: return "cancel_requested"
            }
        }

        var expectsCommandEffectBeforeFault: Bool {
            switch self {
            case .running, .periodicRunning, .exited, .cancelRequested: return true
            case .reservation, .queued, .started: return false
            }
        }
    }

    private func assertError(_ code: String, _ body: () throws -> Void,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? ConduitDirectCommandError)?.code, code, file: file, line: line)
        }
    }

    private func awaitReceipt(_ service: ConduitDirectCommandService, id: String, root: URL,
                              timeout: TimeInterval = 5,
                              until predicate: (ConduitDirectCommandReceipt) -> Bool = { $0.phase.isTerminal }) throws -> ConduitDirectCommandReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let receipt = try service.lookup(operationID: id, projectSlug: "fixture", projectRoot: root)
            if predicate(receipt) { return receipt }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        XCTFail("The persistence fixture did not reach its expected observation before the deadline")
        return try service.lookup(operationID: id, projectSlug: "fixture", projectRoot: root)
    }

    private func waitForEffect(_ url: URL, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func exercise(_ scenario: Scenario, boundary: Boundary, occurrence: Int = 1) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-persistence-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project")
        let store = base.appendingPathComponent("receipts")
        let effect = root.appendingPathComponent("effect")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let service = ConduitDirectCommandService(storeDirectory: store,
            disposableFixtureRoot: root, maximumConcurrentOperations: 1)
        let phase = scenario.receiptPhase
        let target = phase.map { "receipt.\($0).\(boundary.rawValue)" } ?? "reservation.\(boundary.rawValue)"
        let witness = FaultWitness(target: target, boundary: boundary, occurrence: occurrence)
        defer { print(witness.witnessLine) }
        service.fixtureIO = { point, operation in
            if point == target, witness.failures.isEmpty,
               scenario.expectsCommandEffectBeforeFault {
                // The observed effect makes post-spawn faults distinct from
                // failures that prevented a command from starting.
                _ = self.waitForEffect(effect)
            }
            return witness.perform(point: point, operation: operation)
        }

        let id = "fault-\(target.replacingOccurrences(of: ".", with: "-"))-\(occurrence)"
        let longCommand = ["/bin/sh", "-c", "printf x >> effect; /bin/sleep 0.4"]
        let argv = scenario == .exited ? ["/bin/sh", "-c", "printf x >> effect"] : longCommand
        let request = ConduitDirectCommandRequest(operationID: id, projectSlug: "fixture",
            argv: argv, timeoutMS: 1_500)

        switch scenario {
        case .reservation:
            let expected = boundary == .create ? "operation_id_reserved" : "receipt_persistence_failed"
            assertError(expected) { _ = try service.submit(request, projectRoot: root) }
            let reserved = FileManager.default.fileExists(atPath: store.appendingPathComponent(id + ".reserved").path)
            XCTAssertEqual(reserved, boundary != .create, "The reservation marker reflects the actual create boundary")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent(id + ".json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path), "A reservation failure cannot launch the payload")

        case .queued:
            assertError("receipt_persistence_failed") { _ = try service.submit(request, projectRoot: root) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(id + ".reserved").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path), "A queued receipt failure cannot launch the payload")
            if boundary == .directorySync {
                let visible = try service.lookup(operationID: id, projectSlug: "fixture", projectRoot: root)
                XCTAssertEqual(visible.phase, .unknown, "A nonterminal receipt without an active owner is an unknown live observation")
                let raw = try JSONDecoder().decode(ConduitDirectCommandReceipt.self,
                    from: Data(contentsOf: store.appendingPathComponent(id + ".json")))
                XCTAssertEqual(raw.phase, .queued, "Rename may expose a valid queued record even when directory sync fails")
            }

        case .started:
            _ = try service.submit(request, projectRoot: root)
            let receipt = try awaitReceipt(service, id: id, root: root)
            XCTAssertEqual(receipt.phase, .unknown)
            XCTAssertNil(receipt.pid, "The started receipt is durable before any payload spawn")
            XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path), "A started receipt failure cannot launch the payload")
            let retry = try service.submit(request, projectRoot: root)
            XCTAssertTrue(retry.idempotentReplay)
            XCTAssertFalse(FileManager.default.fileExists(atPath: effect.path))

        case .running, .periodicRunning:
            _ = try service.submit(request, projectRoot: root)
            let final = try awaitReceipt(service, id: id, root: root)
            XCTAssertEqual(final.phase, .unknown, "A post-spawn receipt failure leaves the outcome unknown")
            XCTAssertNotNil(final.pid)
            XCTAssertEqual(try String(contentsOf: effect, encoding: .utf8), "x", "Retry must not repeat the observed launch effect")
            let retry = try service.submit(request, projectRoot: root)
            XCTAssertTrue(retry.idempotentReplay)
            XCTAssertEqual(try String(contentsOf: effect, encoding: .utf8), "x")

        case .exited:
            _ = try service.submit(request, projectRoot: root)
            let final = try awaitReceipt(service, id: id, root: root)
            XCTAssertEqual(final.phase, .unknown, "A failed final receipt write must not report durable success")
            XCTAssertTrue(final.directChildExitObserved)
            XCTAssertTrue(final.processGroupAbsentObserved)
            XCTAssertFalse(final.executionCapacityReleased, "A final persistence failure retains execution capacity")
            XCTAssertEqual(try String(contentsOf: effect, encoding: .utf8), "x")
            for _ in 0..<5 {
                let retry = try service.submit(request, projectRoot: root)
                XCTAssertTrue(retry.idempotentReplay)
                XCTAssertEqual(retry.phase, .unknown, "Final persistence uncertainty stays sticky across stable-ID retries")
                XCTAssertFalse(retry.executionCapacityReleased)
                XCTAssertEqual(try String(contentsOf: effect, encoding: .utf8), "x", "A lost final response cannot duplicate the command")
            }
            assertError("command_capacity_exhausted") {
                _ = try service.submit(ConduitDirectCommandRequest(operationID: "after-final-fault",
                    projectSlug: "fixture", argv: ["/bin/echo", "must-not-launch"]), projectRoot: root)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("after-final-fault.reserved").path))

        case .cancelRequested:
            _ = try service.submit(request, projectRoot: root)
            let running = try awaitReceipt(service, id: id, root: root, until: { $0.phase == .running })
            XCTAssertNotNil(running.pid)
            XCTAssertTrue(waitForEffect(effect))
            assertError("receipt_persistence_failed") {
                _ = try service.cancel(operationID: id, projectSlug: "fixture", projectRoot: root)
            }
            let final = try awaitReceipt(service, id: id, root: root)
            XCTAssertEqual(final.phase, .exited, "A failed cancel-intent write leaves the original command running naturally")
            XCTAssertFalse(final.transitions.contains(where: { $0.phase == .cancelRequested }))
            XCTAssertEqual(try String(contentsOf: effect, encoding: .utf8), "x")
            let retry = try service.submit(request, projectRoot: root)
            XCTAssertTrue(retry.idempotentReplay)
            XCTAssertEqual(try String(contentsOf: effect, encoding: .utf8), "x")
        }

        let failures = witness.failures
        XCTAssertEqual(failures.count, 1, "Exactly one matching I/O boundary must invoke the failing syscall")
        XCTAssertEqual(failures.first?.result, -1)
        XCTAssertEqual(failures.first?.error, EBADF, "The injected operation must physically fail with EBADF")
    }

    func testReservationAndReceiptPersistenceFaultMatrix() throws {
        for boundary in [Boundary.create, .fileSync, .directorySync] {
            try XCTContext.runActivity(named: "reservation.\(boundary.rawValue)") { _ in
                try exercise(.reservation, boundary: boundary)
            }
        }

        let receiptCases: [(Scenario, Int)] = [
            (.queued, 1),
            (.started, 1),
            (.running, 1),
            (.periodicRunning, 2),
            (.exited, 1),
            (.cancelRequested, 1),
        ]
        for (scenario, occurrence) in receiptCases {
            for boundary in Boundary.allCases {
                try XCTContext.runActivity(named: "\(scenario.receiptPhase ?? "unknown").\(boundary.rawValue).call-\(occurrence)") { _ in
                    try exercise(scenario, boundary: boundary, occurrence: occurrence)
                }
            }
        }
    }

    func testFixedV1ReceiptDecodesAndReplayIsReadOnly() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-v1-replay-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project")
        let store = base.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: base) }

        var rootFacts = stat()
        XCTAssertEqual(lstat(root.path, &rootFacts), 0)
        let identity = "\(rootFacts.st_dev):\(rootFacts.st_ino)"
        let identityJSON = try String(decoding: JSONSerialization.data(withJSONObject: identity, options: [.fragmentsAllowed]), as: UTF8.self)
        let canonicalPointer = try XCTUnwrap(realpath(root.path, nil))
        let canonicalRoot = String(cString: canonicalPointer)
        free(canonicalPointer)
        let rootJSON = String(decoding: try JSONSerialization.data(withJSONObject: canonicalRoot, options: [.fragmentsAllowed]), as: UTF8.self)
        let template = #"{"schemaVersion":"conduit-direct-command/v1","request":{"operationID":"fixed-v1-operation","projectSlug":"fixture","argv":["/bin/echo","must-not-run"],"cwd":".","timeoutMS":1000,"maxOutputBytes":128000},"resolvedProjectRoot":__ROOT__,"resolvedCwd":__ROOT__,"projectRootIdentity":__IDENTITY__,"cwdIdentity":__IDENTITY__,"ownerInstanceID":"fixed-owner","phase":"exited","transitions":[{"phase":"accepted","at":0},{"phase":"queued","at":0},{"phase":"started","at":0},{"phase":"running","at":0},{"phase":"exited","at":0}],"acceptedAt":0,"pid":123,"processGroupID":123,"exitCode":0,"stdout":{"bytes":"","totalBytesObserved":0,"reachedEOF":true},"stderr":{"bytes":"","totalBytesObserved":0,"reachedEOF":true},"directChildExitObserved":true,"processGroupAbsentObserved":true,"executionCapacityReleased":true,"idempotentReplay":false}"#
        let fixtureBytes = Data(template
            .replacingOccurrences(of: "__ROOT__", with: rootJSON)
            .replacingOccurrences(of: "__IDENTITY__", with: identityJSON)
            .utf8)
        let path = store.appendingPathComponent("fixed-v1-operation.json")
        try fixtureBytes.write(to: path)

        let request = ConduitDirectCommandRequest(operationID: "fixed-v1-operation", projectSlug: "fixture",
            argv: ["/bin/echo", "must-not-run"], cwd: ".", timeoutMS: 1_000, maxOutputBytes: 128_000)
        let reader = ConduitDirectCommandService(storeDirectory: store)
        let decoded = try reader.lookup(operationID: request.operationID, projectSlug: request.projectSlug, projectRoot: root)
        XCTAssertEqual(decoded.schemaVersion, "conduit-direct-command/v1")
        XCTAssertEqual(decoded.phase, .exited)
        XCTAssertTrue(decoded.executionCapacityReleased)

        let replay = try reader.submit(request, projectRoot: root)
        XCTAssertTrue(replay.idempotentReplay)
        XCTAssertEqual(replay.phase, .exited)
        XCTAssertEqual(try Data(contentsOf: path), fixtureBytes, "Read and stable-ID replay preserve the literal historical receipt bytes")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), ["fixed-v1-operation.json"],
            "Read-only v1 replay creates no reservation or ownership files")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("effect").path))
    }
}
