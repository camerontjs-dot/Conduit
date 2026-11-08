import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ConduitCore

/// Synthetic retained evidence only; no helper or payload is needed by these cases.
final class ConduitSupervisorRecoveryTests: XCTestCase {
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-offline-recovery-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project")
        let store = base.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { preserveAndClean(base) }
        try body(root.resolvingSymlinksInPath(), store.resolvingSymlinksInPath())
    }

    private func preserveAndClean(_ base: URL) {
        if let path = ProcessInfo.processInfo.environment["CONDUIT_D2_TEST_EVIDENCE"] {
            do {
                let target = URL(fileURLWithPath: path).appendingPathComponent(name).appendingPathComponent(base.lastPathComponent)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: base, to: target)
            } catch { XCTFail("Could not preserve recovery fixture: \(error)"); return }
        }
        try? FileManager.default.removeItem(at: base)
    }

    private func request(_ id: String) -> ConduitDirectCommandRequest {
        .init(operationID: id, projectSlug: "fixture", argv: ["/usr/bin/true"], timeoutMS: 1_000, maxOutputBytes: 32)
    }

    private func expect(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? ConduitDirectCommandError)?.code, code, file: file, line: line)
        }
    }

    private func snapshot(_ store: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: store.path)
            .filter { $0 != ".command-owner.lock" }
            .map { ($0, try Data(contentsOf: store.appendingPathComponent($0))) })
    }

    private func historicalReceipt(_ root: URL, capacityReleased: Bool) throws -> ConduitDirectCommandReceipt {
        guard let physical = realpath(root.path, nil) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let physicalRoot = URL(fileURLWithPath: String(cString: physical)); free(physical)
        var facts = stat()
        guard stat(root.path, &facts) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let identity = "\(facts.st_dev):\(facts.st_ino)"
        let supervision = try JSONDecoder().decode(ConduitCommandSupervision.self, from: Data("""
        {"protocolVersion":"CDS1","attemptNonce":"0123456789abcdef0123456789abcdef",
         "helperIdentity":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
         "lastEventRevision":5,"goCommitted":true,"rootExitObserved":true,
         "controlClosed":true,"finalFrameObserved":true,"cleanupCause":0,
         "cleanupScope":"original_process_group","descendantContainment":"not_provided"}
        """.utf8))
        let now = Date()
        var receipt = ConduitDirectCommandReceipt(
            schemaVersion: "conduit-direct-command/v2", request: request("history"),
            resolvedProjectRoot: physicalRoot.path, resolvedCwd: physicalRoot.path,
            projectRootIdentity: identity, cwdIdentity: identity, ownerInstanceID: "synthetic-former-owner",
            phase: .exited, transitions: [.init(phase: .exited, at: now)], acceptedAt: now
        )
        receipt.endedAt = now
        receipt.exitCode = 0
        receipt.directChildExitObserved = true
        receipt.processGroupAbsentObserved = true
        receipt.executionCapacityReleased = capacityReleased
        receipt.supervision = supervision
        return receipt
    }

    func testLegacyFixtureExecutorRefusesEveryPriorClaimWithoutChangingEvidence() throws {
        for bytes in [Data(), Data("not-a-nonce\n".utf8), Data("0123456789abcdef0123456789abcdef\n".utf8)] {
            try fixture { root, store in
                try bytes.write(to: store.appendingPathComponent("history.launch-claim"))
                let before = try snapshot(store)
                let legacy = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: root)
                expect("supervisor_recovery_required") { _ = try legacy.submit(request("new"), projectRoot: root) }
                XCTAssertEqual(try snapshot(store), before)
                XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("new.reserved").path))
            }
        }
    }

    func testInconsistentV2CapacityCannotBeReadReplayedCancelledOrUsedForAdmission() throws {
        try fixture { root, store in
            let path = store.appendingPathComponent("history.json")
            // A valid false acknowledgment remains observable without a claim.
            var historical = try historicalReceipt(root, capacityReleased: false)
            try JSONEncoder().encode(historical).write(to: path)
            let reader = ConduitDirectCommandService(storeDirectory: store)
            XCTAssertFalse(try reader.lookup(operationID: "history", projectSlug: "fixture", projectRoot: root).executionCapacityReleased)
            // Change only the acknowledgment; this is an inconsistent disk snapshot,
            // not a crash experiment or evidence about currently running processes.
            historical.executionCapacityReleased = true
            try JSONEncoder().encode(historical).write(to: path)
            let before = try snapshot(store)
            var admissions = 0
            expect("receipt_corrupt") { _ = try reader.lookup(operationID: "history", projectSlug: "fixture", projectRoot: root) }
            expect("receipt_corrupt") { _ = try reader.submit(request("history"), projectRoot: root) { admissions += 1 } }
            expect("receipt_corrupt") { _ = try reader.cancel(operationID: "history", projectSlug: "fixture", projectRoot: root) { admissions += 1 } }
            XCTAssertEqual(admissions, 0)
            let legacy = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: root)
            expect("receipt_corrupt") { _ = try legacy.submit(request("new"), projectRoot: root) }
            XCTAssertEqual(try snapshot(store), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("history.launch-claim").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("new.reserved").path))
        }
    }

    func testPublicExecutorStillRefusesNewWorkWithoutCreatingStorage() throws {
        try fixture { root, store in
            try FileManager.default.removeItem(at: store)
            let reader = ConduitDirectCommandService(storeDirectory: store)
            var admissions = 0
            expect("execution_authority_unavailable") { _ = try reader.submit(request("new"), projectRoot: root) { admissions += 1 } }
            XCTAssertEqual(admissions, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        }
    }
}
