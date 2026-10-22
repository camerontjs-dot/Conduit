import Foundation
import XCTest
@testable import ConduitCore

final class ConduitDirectWorkflowTests: XCTestCase {
    private func fixture(_ body: (URL, URL, ConduitDirectCommandService) throws -> Void) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("direct-workflow-\(UUID().uuidString)")
        let root = base.appendingPathComponent("project")
        let store = base.appendingPathComponent("receipts")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try body(root, store, ConduitDirectCommandService(storeDirectory: store, disposableFixtureRoot: root))
    }

    private func call(_ operation: String, _ fields: [String: CodexJSON], root: URL,
                      service: ConduitDirectCommandService, id: String = "check") -> [String: Any] {
        var arguments = fields
        arguments["operation_id"] = .string(id)
        arguments["project_slug"] = .string("fixture")
        return ConduitDirectCommandTool.perform(operation: operation, arguments: .object(arguments),
                                                projectRoot: root, service: service)
    }

    private func start(_ script: String, root: URL, service: ConduitDirectCommandService,
                       timeout: Int = 5_000, prefix: Int = 128_000, tail: Int = 0) throws {
        let result = call("execute", [
            "argv": .array([.string("/bin/sh"), .string("-c"), .string(script)]),
            "timeout_ms": .number(Double(timeout)), "max_output_bytes": .number(Double(prefix)),
            "max_tail_bytes": .number(Double(tail)),
        ], root: root, service: service)
        XCTAssertNil(result["error"], "\(result)")
        _ = try XCTUnwrap(result["receipt"])
    }

    private func wait(_ service: ConduitDirectCommandService, root: URL,
                      until predicate: (ConduitDirectCommandReceipt) -> Bool = { $0.phase.isTerminal }) throws -> ConduitDirectCommandReceipt {
        let deadline = Date().addingTimeInterval(6)
        repeat {
            let receipt = try service.lookup(operationID: "check", projectSlug: "fixture", projectRoot: root)
            if predicate(receipt) { return receipt }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        XCTFail("No expected observation for the exact owned operation")
        return try service.lookup(operationID: "check", projectSlug: "fixture", projectRoot: root)
    }

    private func page(_ result: [String: Any], stream: String = "stdout") throws -> [String: Any] {
        let receipt = try XCTUnwrap(result["receipt"] as? [String: Any])
        return try XCTUnwrap(receipt[stream] as? [String: Any])
    }

    func testBytePagesDoNotRepeatThePrefixOrInventUTF8() throws {
        try fixture { root, _, service in
            try start("printf 'a🙂b'; printf 'err' >&2", root: root, service: service)
            let completed = try wait(service, root: root)
            XCTAssertEqual(completed.phase, .exited)
            var reconstructed = Data()
            for offset in [0, 2, 4] {
                let result = call("status", ["stdout_offset": .number(Double(offset)),
                    "stderr_offset": .number(0), "output_page_bytes": .number(2)], root: root, service: service)
                let output = try page(result)
                let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(output["bytes_base64"] as? String)))
                XCTAssertEqual(bytes.count, 2)
                XCTAssertEqual(output["byte_offset"] as? Int64, Int64(offset))
                XCTAssertEqual(output["next_byte_offset"] as? Int64, Int64(offset + 2))
                XCTAssertNil(output["text"], "Every two-byte slice crosses the emoji encoding")
                reconstructed.append(bytes)
            }
            XCTAssertEqual(reconstructed, Data("a🙂b".utf8))
            let end = try page(call("status", ["stdout_offset": .number(6), "output_page_bytes": .number(2)], root: root, service: service))
            XCTAssertEqual(end["page_status"] as? String, "end")
            XCTAssertEqual(end["returned_bytes"] as? Int, 0)
        }
    }

    func testOverflowRetainsFinalDiagnosticsAndReportsTheExactMissingRange() throws {
        try fixture { root, store, service in
            try start("printf '0123456789abcdefghijklmnopqrstuv'; printf 'FAIL-last' >&2; exit 23",
                      root: root, service: service, prefix: 4, tail: 8)
            let completed = try wait(service, root: root)
            XCTAssertEqual(completed.phase, .nonzero)
            XCTAssertEqual(completed.exitCode, 23)
            let gap = try page(call("status", ["stdout_offset": .number(4), "output_page_bytes": .number(4)], root: root, service: service))
            XCTAssertEqual(gap["page_status"] as? String, "gap")
            XCTAssertEqual(gap["next_byte_offset"] as? Int64, 24)
            XCTAssertEqual(gap["returned_bytes"] as? Int, 0)
            let fresh = ConduitDirectCommandService(storeDirectory: store)
            let tail = try page(call("status", ["stdout_offset": .number(24), "output_page_bytes": .number(8)], root: root, service: fresh))
            XCTAssertEqual(tail["text"] as? String, "opqrstuv")
            XCTAssertEqual(tail["truncated"] as? Bool, true)
            let errorTail = try page(call("status", ["stderr_offset": .number(1), "output_page_bytes": .number(8)], root: root, service: fresh), stream: "stderr")
            // Prefix and suffix overlap: every observed stderr byte is still recoverable.
            XCTAssertEqual(errorTail["next_byte_offset"] as? Int64, 4)
            XCTAssertEqual(errorTail["text"] as? String, "AIL")
            let rest = try page(call("status", ["stderr_offset": .number(4), "output_page_bytes": .number(8)], root: root, service: fresh), stream: "stderr")
            XCTAssertEqual(rest["text"] as? String, "-last")
        }
    }

    func testLongBudgetReturnsWhileRunningAndReconnectedReaderNeverOwnsCancellation() throws {
        try fixture { root, store, service in
            try start("printf started; /bin/sleep 0.5; printf finished", root: root, service: service, timeout: 600_000)
            let running = try wait(service, root: root, until: { $0.phase == .running && $0.stdout.totalBytesObserved > 0 })
            XCTAssertFalse(running.phase.isTerminal)
            let reader = ConduitDirectCommandService(storeDirectory: store)
            let observed = call("status", ["stdout_offset": .number(0), "output_page_bytes": .number(64)], root: root, service: reader)
            XCTAssertEqual(observed["status"] as? String, "unknown")
            XCTAssertEqual(try page(observed)["text"] as? String, "started")
            XCTAssertEqual(call("cancel", [:], root: root, service: reader)["status"] as? String, "process_ownership_unavailable")
            let completed = try wait(service, root: root)
            XCTAssertEqual(completed.stdout.utf8Text, "startedfinished")
            XCTAssertEqual(completed.exitCode, 0)
            XCTAssertEqual(call("status", [:], root: root, service: reader)["status"] as? String, "exited")
        }
    }

    func testContinuousOutputCannotStarveCancellationOrOverflowTheResponsePage() throws {
        try fixture { root, _, service in
            try start("while :; do printf '0123456789abcdef'; printf 'error' >&2; done",
                      root: root, service: service, timeout: 600_000, prefix: 32, tail: 64)
            _ = try wait(service, root: root, until: { $0.stdout.totalBytesObserved > 1_024 })
            XCTAssertEqual(call("cancel", [:], root: root, service: service)["status"] as? String, "cancel_requested")
            let done = try wait(service, root: root)
            XCTAssertEqual(done.phase, .observedCancelled)
            XCTAssertTrue(done.directChildExitObserved && done.processGroupAbsentObserved)
            let result = call("status", ["output_page_bytes": .number(16)], root: root, service: service)
            XCTAssertLessThanOrEqual(try XCTUnwrap(page(result)["returned_bytes"] as? Int), 16)
            XCTAssertEqual(call("cancel", [:], root: root, service: service)["status"] as? String, "observed_cancelled")
        }
    }

    func testPageArgumentsRefuseMalformedOrFutureOffsetsWithoutChangingTheReceipt() throws {
        try fixture { root, store, service in
            try start("printf abc", root: root, service: service)
            _ = try wait(service, root: root)
            let path = store.appendingPathComponent("check.json")
            let before = try Data(contentsOf: path)
            for value: CodexJSON in [.number(-1), .number(0.5), .number(1e100), .null, .string("0")] {
                XCTAssertEqual(call("status", ["stdout_offset": value], root: root, service: service)["status"] as? String, "invalid_arguments")
            }
            XCTAssertEqual(call("status", ["stdout_offset": .number(4)], root: root, service: service)["status"] as? String, "output_offset_out_of_range")
            XCTAssertEqual(try Data(contentsOf: path), before)
        }
    }

    func testExtendedBudgetStillCannotEnableProductionOrInheritAnEnvironment() throws {
        try fixture { root, store, _ in
            let production = ConduitDirectCommandService(storeDirectory: store)
            let fields: [String: CodexJSON] = ["argv": .array([.string("/bin/echo"), .string("unused")]),
                "timeout_ms": .number(600_000), "max_tail_bytes": .number(16_384)]
            XCTAssertEqual(call("execute", fields, root: root, service: production)["status"] as? String, "execution_authority_unavailable")
            var override = fields; override["environment"] = .object(["PATH": .string("/tmp")])
            XCTAssertEqual(call("execute", override, root: root, service: production)["status"] as? String, "invalid_arguments")
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
        }
    }

    func testLegacyReceiptWithoutTailFieldsRemainsReadableAndExactReplayable() throws {
        try fixture { root, store, service in
            let request = ConduitDirectCommandRequest(operationID: "check", projectSlug: "fixture", argv: ["/bin/echo", "legacy"])
            _ = try service.submit(request, projectRoot: root)
            _ = try wait(service, root: root)
            let path = store.appendingPathComponent("check.json")
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
            var oldRequest = try XCTUnwrap(legacy["request"] as? [String: Any])
            oldRequest.removeValue(forKey: "maxTailBytes"); legacy["request"] = oldRequest
            for stream in ["stdout", "stderr"] {
                var oldOutput = try XCTUnwrap(legacy[stream] as? [String: Any])
                oldOutput.removeValue(forKey: "tailBytes"); legacy[stream] = oldOutput
            }
            try JSONSerialization.data(withJSONObject: legacy).write(to: path)
            let reader = ConduitDirectCommandService(storeDirectory: store)
            XCTAssertEqual(try reader.lookup(operationID: "check", projectSlug: "fixture", projectRoot: root).stdout.utf8Text, "legacy\n")
            XCTAssertTrue(try reader.submit(request, projectRoot: root).idempotentReplay)
            var output = try XCTUnwrap(legacy["stdout"] as? [String: Any])
            output["totalBytesObserved"] = -1; legacy["stdout"] = output
            try JSONSerialization.data(withJSONObject: legacy).write(to: path)
            XCTAssertEqual(call("status", ["output_page_bytes": .number(8)], root: root, service: reader)["status"] as? String, "receipt_corrupt")
        }
    }

    func testCommandActuallyOutlivesTwoMinutes() throws {
        guard ProcessInfo.processInfo.environment["CONDUIT_LONG_COMMAND_TEST"] == "1" else {
            throw XCTSkip("Opt-in 121-second real-process fixture; set CONDUIT_LONG_COMMAND_TEST=1")
        }
        try fixture { root, store, service in
            let began = ProcessInfo.processInfo.systemUptime
            try start("printf before; /bin/sleep 121; printf after", root: root, service: service, timeout: 180_000, tail: 32)
            let first = try wait(service, root: root, until: { $0.stdout.totalBytesObserved == 6 })
            XCTAssertEqual(first.phase, .running)
            let reader = ConduitDirectCommandService(storeDirectory: store)
            let deadline = began + 140
            var terminal: ConduitDirectCommandReceipt?
            while ProcessInfo.processInfo.systemUptime < deadline {
                let observed = try service.lookup(operationID: "check", projectSlug: "fixture", projectRoot: root)
                if observed.phase.isTerminal { terminal = observed; break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if terminal == nil {
                _ = try service.cancel(operationID: "check", projectSlug: "fixture", projectRoot: root)
                _ = try wait(service, root: root)
            }
            let done = try XCTUnwrap(terminal)
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - began, 120)
            XCTAssertEqual(done.phase, .exited)
            XCTAssertEqual(done.exitCode, 0)
            XCTAssertEqual(done.stdout.utf8Text, "beforeafter")
            XCTAssertEqual(try page(call("status", ["stdout_offset": .number(6), "output_page_bytes": .number(8)], root: root, service: reader))["text"] as? String, "after")
        }
    }
}
