import Foundation
import XCTest
@testable import ConduitCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ConduitDirectCommandCancellationTests: XCTestCase {
    private func fixture(_ body: (URL, URL, ConduitDirectCommandService) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-cancel-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project"), store = base.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(root, store, ConduitDirectCommandService(storeDirectory: store,
            disposableFixtureRoot: root, maximumConcurrentOperations: 1))
    }

    private func receipt(_ service: ConduitDirectCommandService, _ id: String, _ root: URL,
                         until predicate: (ConduitDirectCommandReceipt) -> Bool = { $0.phase.isTerminal }) throws -> ConduitDirectCommandReceipt {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let value = try service.lookup(operationID: id, projectSlug: "fixture", projectRoot: root)
            if predicate(value) { return value }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        XCTFail("Owned fixture did not reach its expected state")
        return try service.lookup(operationID: id, projectSlug: "fixture", projectRoot: root)
    }

    private func waitForFile(_ file: URL) throws {
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    private func exerciseTermIgnoringDescendant(cancel: Bool) throws {
        try fixture { root, _, service in
            let keepalive = root.appendingPathComponent("keepalive")
            try Data().write(to: keepalive)
            // The child confirms TERM is ignored before the parent test cancels.
            // An owned file and a ten-second limit also stop the fixture on a
            // failed assertion, without signalling any recovered PID.
            let script = "(trap '' TERM; printf ready > descendant-ready; i=0; while [ -f keepalive ] && [ $i -lt 200 ]; do /bin/sleep 0.05; i=$((i+1)); done) >/dev/null 2>&1 & printf '%s' \"$!\" > descendant.pid; wait"
            let request = ConduitDirectCommandRequest(operationID: cancel ? "cancel-tree" : "timeout-tree",
                projectSlug: "fixture", argv: ["/bin/sh", "-c", script], timeoutMS: cancel ? 5_000 : 1_000)
            _ = try service.submit(request, projectRoot: root)
            try waitForFile(root.appendingPathComponent("descendant-ready"))
            try waitForFile(root.appendingPathComponent("descendant.pid"))
            let descendant = try XCTUnwrap(Int32(String(contentsOf: root.appendingPathComponent("descendant.pid"))))
            defer {
                try? FileManager.default.removeItem(at: keepalive)
                let deadline = Date().addingTimeInterval(2)
                while kill(descendant, 0) == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            }
            let running = try receipt(service, request.operationID, root, until: { $0.phase == .running })
            XCTAssertEqual(getpgid(descendant), running.processGroupID)
            if cancel {
                var admissions = 0
                for _ in 0..<5 {
                    _ = try service.cancel(operationID: request.operationID, projectSlug: "fixture", projectRoot: root) { admissions += 1 }
                }
                XCTAssertEqual(admissions, 1, "Cancellation retries consume admission once")
            }
            let final = try receipt(service, request.operationID, root)
            let descendantAlive = kill(descendant, 0) == 0
            print("DESCENDANT_REGRESSION cancel=\(cancel) phase=\(final.phase.rawValue) signal=\(final.terminationSignal ?? -1) group_absent=\(final.processGroupAbsentObserved) capacity_released=\(final.executionCapacityReleased) descendant_alive=\(descendantAlive)")
            XCTAssertEqual(final.phase, cancel ? .observedCancelled : .timedOut)
            XCTAssertEqual(final.terminationSignal, SIGTERM, "Retain the direct child's actual outcome, even when its descendant needs KILL")
            XCTAssertTrue(final.directChildExitObserved)
            XCTAssertTrue(final.processGroupAbsentObserved)
            XCTAssertTrue(final.executionCapacityReleased)
            XCTAssertFalse(descendantAlive)
            let replay = try service.submit(request, projectRoot: root) { XCTFail("Retry must not spend admission") }
            XCTAssertTrue(replay.idempotentReplay)
            XCTAssertEqual(replay.pid, final.pid)
            if final.executionCapacityReleased {
                let next = ConduitDirectCommandRequest(operationID: "after-cleanup", projectSlug: "fixture", argv: ["/bin/echo", "ready"])
                _ = try service.submit(next, projectRoot: root)
                XCTAssertEqual(try receipt(service, next.operationID, root).exitCode, 0)
            }
        }
    }

    func testCancellationCleansSameGroupDescendantAfterLeaderExits() throws {
        try exerciseTermIgnoringDescendant(cancel: true)
    }

    func testTimeoutCleansSameGroupDescendantAfterLeaderExits() throws {
        try exerciseTermIgnoringDescendant(cancel: false)
    }

    func testConcurrentRetriesAndCancellationKeepOneEffectAndDurableIdentity() throws {
        try fixture { root, store, service in
            let request = ConduitDirectCommandRequest(operationID: "concurrent-cancel", projectSlug: "fixture",
                argv: ["/bin/sh", "-c", "printf x >> marker; /bin/sleep 5"], timeoutMS: 5_000)
            _ = try service.submit(request, projectRoot: root)
            try waitForFile(root.appendingPathComponent("marker"))
            let resultLock = NSLock()
            var errors: [Error] = [], admissions = 0
            DispatchQueue.concurrentPerform(iterations: 20) { index in
                do {
                    if index.isMultiple(of: 2) {
                        _ = try service.cancel(operationID: request.operationID, projectSlug: "fixture", projectRoot: root) {
                            resultLock.lock(); admissions += 1; resultLock.unlock()
                        }
                    } else {
                        let replay = try service.submit(request, projectRoot: root) { XCTFail("Retry admission") }
                        XCTAssertTrue(replay.idempotentReplay)
                    }
                } catch { resultLock.lock(); errors.append(error); resultLock.unlock() }
            }
            XCTAssertTrue(errors.isEmpty, "\(errors)")
            XCTAssertEqual(admissions, 1)
            let final = try receipt(service, request.operationID, root)
            XCTAssertEqual(final.phase, .observedCancelled)
            XCTAssertEqual(final.transitions.filter { $0.phase == .cancelRequested }.count, 1)
            XCTAssertTrue(final.executionCapacityReleased)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("marker")), "x")
            let reader = ConduitDirectCommandService(storeDirectory: store)
            let recovered = try reader.submit(request, projectRoot: root) { XCTFail("Durable replay admission") }
            XCTAssertTrue(recovered.idempotentReplay)
            XCTAssertEqual(recovered.pid, final.pid)
            XCTAssertEqual(recovered.phase, .observedCancelled)
            _ = try reader.cancel(operationID: request.operationID, projectSlug: "fixture", projectRoot: root) { XCTFail("Terminal cancel admission") }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("marker")), "x")
        }
    }
}
