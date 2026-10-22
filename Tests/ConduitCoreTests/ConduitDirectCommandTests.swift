import Foundation
import XCTest
@testable import ConduitCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ConduitDirectCommandTests: XCTestCase {
    private func fixture(_ body: (URL, URL, ConduitDirectCommandService) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-command-\(UUID().uuidString)")
        let project = base.appendingPathComponent("project")
        let store = base.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let service = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: project)
        try body(project, store, service)
    }

    private func request(_ argv: [String], cwd: String = ".", timeout: Int = 2_000,
                         output: Int = 128_000) -> ConduitDirectCommandRequest {
        request(UUID().uuidString, argv, cwd: cwd, timeout: timeout, output: output)
    }

    private func request(_ id: String, _ argv: [String], cwd: String = ".",
                         timeout: Int = 2_000, output: Int = 128_000) -> ConduitDirectCommandRequest {
        .init(operationID: id, projectSlug: "fixture", argv: argv, cwd: cwd,
              timeoutMS: timeout, maxOutputBytes: output)
    }

    private func awaitReceipt(_ service: ConduitDirectCommandService, _ id: String, root: URL,
                              timeout: TimeInterval = 5,
                              until predicate: (ConduitDirectCommandReceipt) -> Bool = { $0.phase.isTerminal }) throws -> ConduitDirectCommandReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let receipt = try service.lookup(operationID: id, projectSlug: "fixture", projectRoot: root)
            if predicate(receipt) { return receipt }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        XCTFail("The exact command receipt did not reach the expected observation before the test deadline")
        return try service.lookup(operationID: id, projectSlug: "fixture", projectRoot: root)
    }

    private func assertError(_ code: String, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as? ConduitDirectCommandError)?.code, code, file: file, line: line)
        }
    }

    func testLiteralArgvExitAndIndependentOutputStreams() throws {
        try fixture { root, _, service in
            let literal = "$(touch marker); * 'quoted'\nsecond line"
            let req = request(["/usr/bin/printf", "%s", literal])
            _ = try service.submit(req, projectRoot: root)
            let receipt = try awaitReceipt(service, req.operationID, root: root)
            XCTAssertEqual(receipt.phase, .exited)
            XCTAssertEqual(receipt.exitCode, 0)
            XCTAssertEqual(receipt.stdout.utf8Text, literal)
            XCTAssertEqual(receipt.stderr.utf8Text, "")
            XCTAssertTrue(receipt.stdout.reachedEOF)
            XCTAssertTrue(receipt.directChildExitObserved)
            XCTAssertTrue(receipt.processGroupAbsentObserved)
            XCTAssertTrue(receipt.executionCapacityReleased)
            XCTAssertNotNil(receipt.pid)
            XCTAssertEqual(receipt.pid, receipt.processGroupID)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
            XCTAssertEqual(receipt.transitions.map(\.phase), [.accepted, .queued, .started, .running, .exited])

            let failing = request(["/bin/sh", "-c", "printf 'out'; printf 'err' >&2; exit 7"])
            _ = try service.submit(failing, projectRoot: root)
            let failed = try awaitReceipt(service, failing.operationID, root: root)
            XCTAssertEqual(failed.phase, .nonzero)
            XCTAssertEqual(failed.exitCode, 7)
            XCTAssertEqual(failed.stdout.utf8Text, "out")
            XCTAssertEqual(failed.stderr.utf8Text, "err")
        }
    }

    func testBoundedOutputPreservesBinaryAndDrainsOverflow() throws {
        try fixture { root, _, service in
            let req = request(["/bin/sh", "-c", "printf '\\377\\000ABCDEF'; printf '123456789' >&2"], output: 4)
            _ = try service.submit(req, projectRoot: root)
            let receipt = try awaitReceipt(service, req.operationID, root: root)
            XCTAssertEqual(receipt.phase, .exited)
            XCTAssertEqual(receipt.stdout.bytes, Data([255, 0, 65, 66]))
            XCTAssertNil(receipt.stdout.utf8Text)
            XCTAssertEqual(receipt.stdout.totalBytesObserved, 8)
            XCTAssertTrue(receipt.stdout.truncated)
            XCTAssertEqual(receipt.stderr.utf8Text, "1234")
            XCTAssertEqual(receipt.stderr.totalBytesObserved, 9)
            XCTAssertTrue(receipt.stderr.truncated)
            XCTAssertTrue(receipt.stdout.reachedEOF && receipt.stderr.reachedEOF)

            let flood = request(["/bin/sh", "-c", "i=0; while [ $i -lt 20000 ]; do printf 'xxxxxxxx'; printf 'yyyyyyyy' >&2; i=$((i+1)); done"], timeout: 5_000, output: 64)
            _ = try service.submit(flood, projectRoot: root)
            let flooded = try awaitReceipt(service, flood.operationID, root: root)
            XCTAssertEqual(flooded.phase, .exited)
            XCTAssertEqual(flooded.stdout.bytes.count, 64)
            XCTAssertEqual(flooded.stderr.bytes.count, 64)
            XCTAssertEqual(flooded.stdout.totalBytesObserved, 160_000)
            XCTAssertEqual(flooded.stderr.totalBytesObserved, 160_000)
        }
    }

    func testTimeoutAndCancellationObserveExitRatherThanGuessSuccess() throws {
        try fixture { root, _, service in
            let timeout = request(["/bin/sleep", "5"], timeout: 50)
            _ = try service.submit(timeout, projectRoot: root)
            let expired = try awaitReceipt(service, timeout.operationID, root: root)
            XCTAssertEqual(expired.phase, .timedOut)
            XCTAssertNil(expired.exitCode)
            XCTAssertNotNil(expired.terminationSignal)
            XCTAssertTrue(expired.directChildExitObserved)

            let cancel = request(["/bin/sleep", "5"])
            _ = try service.submit(cancel, projectRoot: root)
            _ = try awaitReceipt(service, cancel.operationID, root: root, until: { $0.phase == .running })
            let requested = try service.cancel(operationID: cancel.operationID, projectSlug: "fixture", projectRoot: root)
            XCTAssertEqual(requested.phase, .cancelRequested)
            let cancelled = try awaitReceipt(service, cancel.operationID, root: root)
            XCTAssertEqual(cancelled.phase, .observedCancelled)
            XCTAssertTrue(cancelled.directChildExitObserved)
            XCTAssertTrue(cancelled.executionCapacityReleased)
            var gateCalls = 0
            _ = try service.cancel(operationID: cancel.operationID, projectSlug: "fixture", projectRoot: root) { gateCalls += 1 }
            XCTAssertEqual(gateCalls, 0, "A terminal cancellation replay consumes no write admission")
        }
    }

    func testRefusalsPrecedeProcessReceiptAndWriteBudgetSideEffects() throws {
        try fixture { root, store, _ in
            let service = ConduitDirectCommandService(storeDirectory: store)
            var gateCalls = 0
            assertError("execution_authority_unavailable") {
                _ = try service.submit(self.request(["/bin/sh", "-c", "touch marker"]), projectRoot: root) { gateCalls += 1 }
            }
            XCTAssertEqual(gateCalls, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
            assertError("operation_not_found") { _ = try service.lookup(operationID: "absent", projectSlug: "fixture", projectRoot: root) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path), "A status read creates no store")
            for invalid in [
                self.request(["echo", "x"]), self.request(["/bin/echo", "bad\0arg"]),
                self.request(["/bin/echo"], cwd: "../outside"), self.request(["/bin/echo"], cwd: ".git"),
                self.request(["/bin/echo"], timeout: 0), self.request(["/bin/echo"], output: 524_289),
            ] {
                assertError("invalid_arguments") { _ = try service.submit(invalid, projectRoot: root) }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        }
        try fixture { root, store, service in
            assertError("write_denied") {
                _ = try service.submit(self.request(["/bin/sh", "-c", "touch marker"]), projectRoot: root) {
                    throw ConduitDirectCommandError(code: "write_denied", detail: "Fixture admission denied")
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("marker").path))
        }
    }

    func testRetryAndConcurrentSameIDLaunchOnlyOnce() throws {
        try fixture { root, _, service in
            let req = request("same-operation", ["/bin/sh", "-c", "printf 'x' >> marker; sleep 0.1"])
            let resultsLock = NSLock()
            var errors: [Error] = []
            var replies: [ConduitDirectCommandReceipt] = []
            DispatchQueue.concurrentPerform(iterations: 12) { _ in
                do {
                    let reply = try service.submit(req, projectRoot: root)
                    resultsLock.lock(); replies.append(reply); resultsLock.unlock()
                } catch {
                    resultsLock.lock(); errors.append(error); resultsLock.unlock()
                }
            }
            XCTAssertTrue(errors.isEmpty)
            XCTAssertEqual(replies.count, 12)
            XCTAssertEqual(replies.filter { !$0.idempotentReplay }.count, 1)
            let completed = try awaitReceipt(service, req.operationID, root: root)
            XCTAssertEqual(completed.phase, .exited)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("marker")), "x")
            var gateCalls = 0
            _ = try service.submit(req, projectRoot: root) { gateCalls += 1 }
            XCTAssertEqual(gateCalls, 0)
            assertError("operation_id_conflict") {
                _ = try service.submit(self.request("same-operation", ["/bin/echo", "changed"]), projectRoot: root)
            }
            assertError("operation_not_found") { _ = try service.lookup(operationID: req.operationID, projectSlug: "other", projectRoot: root) }
        }
    }

    func testExactDirectoryIdentityAndSymlinkReplacementRefuseReplay() throws {
        try fixture { root, _, service in
            let work = root.appendingPathComponent("work")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let req = request(["/bin/pwd"], cwd: "work")
            _ = try service.submit(req, projectRoot: root)
            let completed = try awaitReceipt(service, req.operationID, root: root)
            let physicalPath = try XCTUnwrap(work.path.withCString { realpath($0, nil) })
            defer { free(physicalPath) }
            XCTAssertEqual(completed.stdout.utf8Text?.trimmingCharacters(in: .whitespacesAndNewlines), String(cString: physicalPath))
            try FileManager.default.moveItem(at: work, to: root.appendingPathComponent("prior-work"))
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            assertError("operation_target_changed") { _ = try service.submit(req, projectRoot: root) }
            try FileManager.default.removeItem(at: work)
            try FileManager.default.createSymbolicLink(atPath: work.path, withDestinationPath: "prior-work")
            assertError("operation_target_changed") { _ = try service.submit(req, projectRoot: root) }
            XCTAssertEqual(try service.lookup(operationID: req.operationID, projectSlug: "fixture", projectRoot: root).cwdIdentity, completed.cwdIdentity)
        }
    }

    func testCapacityAndSecondWriterRefuseWithoutCreatingAnOperation() throws {
        try fixture { root, store, _ in
            let service = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: root, maximumConcurrentOperations: 1)
            let req = request(["/bin/sleep", "0.3"])
            _ = try service.submit(req, projectRoot: root)
            var gateCalls = 0
            assertError("command_capacity_exhausted") {
                _ = try service.submit(self.request("overflow", ["/bin/echo"]), projectRoot: root) { gateCalls += 1 }
            }
            XCTAssertEqual(gateCalls, 0)
            let other = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: root)
            assertError("receipt_store_busy") { _ = try other.submit(self.request("other-writer", ["/bin/echo"]), projectRoot: root) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("overflow.json").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("other-writer.json").path))
            _ = try awaitReceipt(service, req.operationID, root: root)
        }
    }

    func testDurableTerminalAndIncompleteReceiptsSurviveFreshService() throws {
        try fixture { root, store, service in
            let req = request(["/bin/sh", "-c", "printf 'once' >> marker"])
            _ = try service.submit(req, projectRoot: root)
            let complete = try awaitReceipt(service, req.operationID, root: root)
            let fresh = ConduitDirectCommandService(storeDirectory: store)
            let loaded = try fresh.lookup(operationID: req.operationID, projectSlug: "fixture", projectRoot: root)
            XCTAssertEqual(loaded.exitCode, complete.exitCode)
            XCTAssertEqual(loaded.phase, .exited)
            XCTAssertTrue(try fresh.submit(req, projectRoot: root).idempotentReplay)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("marker")), "once")

            let running = request(["/bin/sleep", "0.3"])
            _ = try service.submit(running, projectRoot: root)
            _ = try awaitReceipt(service, running.operationID, root: root, until: { $0.phase == .running })
            let snapshotStore = store.deletingLastPathComponent().appendingPathComponent("receipt-snapshot")
            try FileManager.default.createDirectory(at: snapshotStore, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = snapshotStore.appendingPathComponent(running.operationID + ".json")
            let before = try Data(contentsOf: store.appendingPathComponent(running.operationID + ".json"))
            try before.write(to: path)
            let snapshotReader = ConduitDirectCommandService(storeDirectory: snapshotStore)
            XCTAssertEqual(try snapshotReader.lookup(operationID: running.operationID, projectSlug: "fixture", projectRoot: root).phase, .unknown)
            assertError("process_ownership_unavailable") { _ = try snapshotReader.cancel(operationID: running.operationID, projectSlug: "fixture", projectRoot: root) }
            XCTAssertEqual(try Data(contentsOf: path), before, "Read-only recovery does not rewrite the stored receipt")
            _ = try awaitReceipt(service, running.operationID, root: root)
        }
    }

    func testCorruptReceiptAndFailedLaunchNeverReuseOperationID() throws {
        try fixture { root, store, service in
            let missing = request("missing-executable", [root.appendingPathComponent("does-not-exist").path])
            _ = try service.submit(missing, projectRoot: root)
            let failed = try awaitReceipt(service, missing.operationID, root: root)
            XCTAssertEqual(failed.phase, .launchFailed)
            XCTAssertNil(failed.pid)
            XCTAssertTrue(failed.executionCapacityReleased)
            XCTAssertTrue(try service.submit(missing, projectRoot: root).idempotentReplay)
            let corrupt = store.appendingPathComponent("corrupt.json")
            try Data("not-json".utf8).write(to: corrupt)
            assertError("receipt_corrupt") { _ = try service.submit(self.request("corrupt", ["/bin/echo"]), projectRoot: root) }
            XCTAssertEqual(try String(contentsOf: corrupt), "not-json")
            XCTAssertEqual(mkfifo(store.appendingPathComponent("fifo.json").path, 0o600), 0)
            assertError("receipt_unavailable") { _ = try service.submit(self.request("fifo", ["/bin/echo"]), projectRoot: root) }
        }
    }

    func testToolOperationIsServerBoundAndOutcomesAreNotTransportErrors() throws {
        try fixture { root, _, service in
            let arguments: CodexJSON = .object([
                "operation_id": .string("tool-operation"), "project_slug": .string("fixture"),
                "argv": .array([.string("/bin/sh"), .string("-c"), .string("exit 9")]),
            ])
            let accepted = ConduitDirectCommandTool.call(operation: "execute", arguments: arguments, projectRoot: root, service: service)
            XCTAssertEqual(accepted["isError"] as? Bool, false)
            _ = try awaitReceipt(service, "tool-operation", root: root)
            let status = ConduitDirectCommandTool.call(operation: "status", arguments: .object([
                "operation_id": .string("tool-operation"), "project_slug": .string("fixture"),
            ]), projectRoot: root, service: service)
            XCTAssertEqual(status["isError"] as? Bool, false)
            XCTAssertEqual((status["structuredContent"] as? [String: Any])?["status"] as? String, "nonzero")
            let injection = ConduitDirectCommandTool.perform(operation: "status", arguments: arguments, projectRoot: root, service: service)
            XCTAssertEqual(injection["status"] as? String, "invalid_arguments")
        }
    }

    func testProjectRemappingCannotObserveOrCancelOriginalReceiptButMovedCwdCanBeStopped() throws {
        try fixture { root, _, service in
            let work = root.appendingPathComponent("work")
            let other = root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let req = request(["/bin/sleep", "5"], cwd: "work")
            _ = try service.submit(req, projectRoot: root)
            _ = try awaitReceipt(service, req.operationID, root: root, until: { $0.phase == .running })
            assertError("operation_project_changed") {
                _ = try service.lookup(operationID: req.operationID, projectSlug: "fixture", projectRoot: other)
            }
            var gateCalls = 0
            assertError("operation_project_changed") {
                _ = try service.cancel(operationID: req.operationID, projectSlug: "fixture", projectRoot: other) { gateCalls += 1 }
            }
            XCTAssertEqual(gateCalls, 0)
            try FileManager.default.moveItem(at: work, to: root.appendingPathComponent("moved-work"))
            _ = try service.cancel(operationID: req.operationID, projectSlug: "fixture", projectRoot: root)
            XCTAssertEqual(try awaitReceipt(service, req.operationID, root: root).phase, .observedCancelled)
        }
    }

    func testReservedIDSurvivesMissingReceiptAndStorageHasGlobalByteLimit() throws {
        try fixture { root, store, service in
            let req = request(["/bin/echo", "once"])
            _ = try service.submit(req, projectRoot: root)
            _ = try awaitReceipt(service, req.operationID, root: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.appendingPathComponent(req.operationID + ".reserved").path))
            try FileManager.default.removeItem(at: store.appendingPathComponent(req.operationID + ".json"))
            let restarted = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: root)
            assertError("operation_receipt_missing") { _ = try restarted.submit(req, projectRoot: root) }
            assertError("operation_receipt_missing") {
                _ = try restarted.lookup(operationID: req.operationID, projectSlug: "fixture", projectRoot: root)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent(req.operationID + ".json").path))
        }
        try fixture { root, store, service in
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let padding = store.appendingPathComponent("quota-fixture")
            XCTAssertTrue(FileManager.default.createFile(atPath: padding.path, contents: nil))
            let file = try FileHandle(forWritingTo: padding)
            try file.truncate(atOffset: UInt64(ConduitDirectCommandService.maximumRetainedBytes))
            try file.close()
            assertError("receipt_capacity_exhausted") {
                _ = try service.submit(self.request("over-quota", ["/bin/echo"]), projectRoot: root)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("over-quota.reserved").path))
        }
    }

    func testActualOwnerProcessRestartDoesNotReplayOrAdoptPID() throws {
        #if canImport(Darwin)
        let key = "CONDUIT_COMMAND_OWNER_RESTART_FIXTURE"
        if let path = ProcessInfo.processInfo.environment[key] {
            let base = URL(fileURLWithPath: path)
            let root = base.appendingPathComponent("project")
            let service = ConduitDirectCommandService(storeDirectory: base.appendingPathComponent("receipts"), disposableFixtureRoot: root)
            _ = try service.submit(request("owner-restart", ["/bin/sleep", "1"]), projectRoot: root)
            _ = try awaitReceipt(service, "owner-restart", root: root, until: { $0.phase == .running })
            // The parent owns this test host and deliberately kills it. Its
            // harmless native sleep is allowed to exit naturally, never adopted.
            Thread.sleep(forTimeInterval: 5)
            return
        }
        try fixture { root, store, _ in
            let host = Process()
            host.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            host.arguments = ["-XCTest", "ConduitCoreTests.ConduitDirectCommandTests/testActualOwnerProcessRestartDoesNotReplayOrAdoptPID", Bundle(for: Self.self).bundleURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment[key] = root.deletingLastPathComponent().path
            host.environment = environment
            host.standardOutput = FileHandle.nullDevice; host.standardError = FileHandle.nullDevice
            try host.run()
            defer {
                if host.isRunning { _ = kill(host.processIdentifier, SIGKILL) }
                host.waitUntilExit()
            }
            let path = store.appendingPathComponent("owner-restart.json")
            let deadline = Date().addingTimeInterval(5)
            var original: ConduitDirectCommandReceipt?
            while Date() < deadline, host.isRunning {
                if let data = try? Data(contentsOf: path),
                   let receipt = try? JSONDecoder().decode(ConduitDirectCommandReceipt.self, from: data),
                   receipt.phase == .running {
                    original = receipt; break
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            let owned = try XCTUnwrap(original, "Child XCTest host did not establish a running native command; restart experiment was not established")
            _ = kill(host.processIdentifier, SIGKILL)
            host.waitUntilExit()
            let before = try Data(contentsOf: path)
            let restarted = ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: root)
            let observation = try restarted.lookup(operationID: "owner-restart", projectSlug: "fixture", projectRoot: root)
            XCTAssertEqual(observation.phase, .unknown)
            XCTAssertEqual(observation.pid, owned.pid)
            let replay = try restarted.submit(owned.request, projectRoot: root)
            XCTAssertEqual(replay.phase, .unknown)
            XCTAssertTrue(replay.idempotentReplay)
            assertError("process_ownership_unavailable") { _ = try restarted.cancel(operationID: "owner-restart", projectSlug: "fixture", projectRoot: root) }
            assertError("unresolved_command_ownership") {
                _ = try restarted.submit(self.request("new-after-restart", ["/bin/echo", "must-not-launch"]), projectRoot: root)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.appendingPathComponent("new-after-restart.reserved").path))
            XCTAssertEqual(try Data(contentsOf: path), before)
            Thread.sleep(forTimeInterval: 1.1)
            XCTAssertEqual(try restarted.lookup(operationID: "owner-restart", projectSlug: "fixture", projectRoot: root).phase, .unknown,
                           "Later process disappearance cannot invent the missing original exit status")
            assertError("unresolved_command_ownership") {
                _ = try restarted.submit(self.request("later-after-restart", ["/bin/echo", "must-not-launch"]), projectRoot: root)
            }
        }
        #else
        throw XCTSkip("Actual test-host restart fixture uses the macOS XCTest host contract")
        #endif
    }

    func testReceiptCreationRequiresExistingExternalParentAndRefusesParentRedirect() throws {
        try fixture { root, store, _ in
            let missing = store.deletingLastPathComponent().appendingPathComponent("missing-parent")
            let unavailable = ConduitDirectCommandService(storeDirectory: missing.appendingPathComponent("receipts"), disposableFixtureRoot: root)
            assertError("receipt_store_unavailable") {
                _ = try unavailable.submit(self.request(["/bin/echo"]), projectRoot: root)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path), "Receipt creation never recursively creates an application parent")
            let inside = ConduitDirectCommandService(storeDirectory: root.appendingPathComponent("receipts"), disposableFixtureRoot: root)
            assertError("receipt_store_scope_conflict") {
                _ = try inside.submit(self.request(["/bin/echo"]), projectRoot: root)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("receipts").path))

            let parent = store.deletingLastPathComponent().appendingPathComponent("application-state")
            let retainedParent = store.deletingLastPathComponent().appendingPathComponent("retained-state")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let service = ConduitDirectCommandService(storeDirectory: parent.appendingPathComponent("receipts"), disposableFixtureRoot: root)
            let req = request(["/bin/sleep", "0.3"])
            _ = try service.submit(req, projectRoot: root)
            _ = try awaitReceipt(service, req.operationID, root: root, until: { $0.phase == .running })
            try FileManager.default.moveItem(at: parent, to: retainedParent)
            try FileManager.default.createSymbolicLink(atPath: parent.path, withDestinationPath: root.path)
            var gateCalls = 0
            assertError("receipt_store_changed") {
                _ = try service.submit(self.request("redirected", ["/bin/echo"]), projectRoot: root) { gateCalls += 1 }
            }
            XCTAssertEqual(gateCalls, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("receipts").path))
            try FileManager.default.removeItem(at: parent)
            try FileManager.default.moveItem(at: retainedParent, to: parent)
            XCTAssertEqual(try awaitReceipt(service, req.operationID, root: root).phase, .exited)
        }
    }
}
