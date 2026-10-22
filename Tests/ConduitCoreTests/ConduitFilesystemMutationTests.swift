import XCTest
import Foundation
import CryptoKit
@testable import ConduitCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ConduitFilesystemMutationTests: XCTestCase {
    private struct Fixture {
        let container: URL
        let root: URL
        let receipts: URL
        var service: ConduitFilesystemMutationService { .init(receiptDirectory: receipts) }
    }

    private func fixture(_ body: (Fixture) throws -> Void) throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-file-tests-" + UUID().uuidString)
        let root = container.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        try body(Fixture(container: container, root: root, receipts: container.appendingPathComponent("receipts")))
    }

    private func hash(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func request(
        _ id: String = "operation-1", path: String = "example.txt", text: String = "new text\n",
        expected: Data? = nil
    ) -> CodexJSON {
        var fields: [String: CodexJSON] = [
            "operation_id": .string(id), "project_slug": .string("test-project"),
            "path": .string(path), "text": .string(text),
        ]
        if let expected { fields["expected_sha256"] = .string(hash(expected)) }
        else { fields["expected_absent"] = .bool(true) }
        return .object(fields)
    }

    private func statusRequest(_ id: String = "operation-1") -> CodexJSON {
        .object(["operation_id": .string(id), "project_slug": .string("test-project")])
    }

    private func status(_ payload: [String: Any]) -> String? { payload["status"] as? String }

    func testLookupAndRefusalsDoNotCreateReceiptStorageOrConsumeAdmission() throws {
        try fixture { fixture in
            let service = fixture.service
            XCTAssertEqual(status(service.lookup(arguments: statusRequest(), root: fixture.root)), "not_found")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipts.path))
            var admissions = 0
            let gate: () -> [String: Any]? = { admissions += 1; return nil }
            XCTAssertEqual(status(service.mutate(arguments: request(path: "../outside.txt"), root: fixture.root, admitWrite: gate)), "outside_root")
            XCTAssertEqual(status(service.mutate(arguments: request(), root: nil, admitWrite: gate)), "project_unavailable")
            let target = fixture.root.appendingPathComponent("example.txt")
            try Data("existing".utf8).write(to: target)
            XCTAssertEqual(status(service.mutate(arguments: request(), root: fixture.root, admitWrite: gate)), "precondition_failed")
            XCTAssertEqual(admissions, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipts.path))
            XCTAssertEqual(try Data(contentsOf: target), Data("existing".utf8))
        }
    }

    func testCreateAndReplayAcrossServiceRestartDoNotWriteAgain() throws {
        try fixture { fixture in
            let input = request(text: "Café\r\n雪\n")
            var admissions = 0
            let created = fixture.service.mutate(arguments: input, root: fixture.root) { admissions += 1; return nil }
            XCTAssertEqual(status(created), "succeeded", "\(created)")
            XCTAssertEqual(created["operation"] as? String, "create")
            let target = fixture.root.appendingPathComponent("example.txt")
            XCTAssertEqual(try Data(contentsOf: target), Data("Café\r\n雪\n".utf8))
            let after = try XCTUnwrap(created["after"] as? [String: Any])
            XCTAssertEqual(after["sha256"] as? String, hash(Data("Café\r\n雪\n".utf8)))
            // A replay is historical. It must not undo a later external edit.
            try Data("external later edit".utf8).write(to: target)
            let replay = fixture.service.mutate(arguments: input, root: fixture.root) { admissions += 1; return nil }
            XCTAssertEqual(status(replay), "succeeded")
            XCTAssertEqual(replay["replayed"] as? Bool, true)
            XCTAssertEqual(admissions, 1)
            XCTAssertEqual(try Data(contentsOf: target), Data("external later edit".utf8))
            XCTAssertEqual(status(fixture.service.lookup(arguments: statusRequest(), root: fixture.root)), "succeeded")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["example.txt"])
        }
    }

    func testReplaceUsesExactRawBytesAndPreservesPreimageAndMode() throws {
        try fixture { fixture in
            let original = Data([0xEF, 0xBB, 0xBF]) + Data("line one\r\nline two\r\n".utf8)
            let target = fixture.root.appendingPathComponent("example.txt")
            let adjacent = fixture.root.appendingPathComponent("adjacent.txt")
            try original.write(to: target)
            try Data("untouched".utf8).write(to: adjacent)
            XCTAssertEqual(chmod(target.path, mode_t(0o640)), 0)
            let result = fixture.service.mutate(arguments: request(text: "replacement\r\n", expected: original), root: fixture.root) { nil }
            XCTAssertEqual(status(result), "succeeded", "\(result)")
            XCTAssertEqual(result["before_bytes_preserved"] as? Bool, true)
            let before = try XCTUnwrap(result["before"] as? [String: Any])
            XCTAssertEqual(before["sha256"] as? String, hash(original))
            let backup = fixture.receipts.appendingPathComponent(hash(Data("operation-1".utf8)) + ".before")
            XCTAssertEqual(try Data(contentsOf: backup), original)
            XCTAssertEqual(try Data(contentsOf: target), Data("replacement\r\n".utf8))
            XCTAssertEqual(try Data(contentsOf: adjacent), Data("untouched".utf8))
            var info = stat()
            XCTAssertEqual(lstat(target.path, &info), 0)
            XCTAssertEqual(info.st_mode & mode_t(0o777), mode_t(0o640))
        }
    }

    func testRefusesNormalizedHashInsteadOfExactRawHash() throws {
        try fixture { fixture in
            let original = Data("line\r\n".utf8)
            let target = fixture.root.appendingPathComponent("example.txt")
            try original.write(to: target)
            var admissions = 0
            let result = fixture.service.mutate(arguments: request(expected: Data("line\n".utf8)), root: fixture.root) { admissions += 1; return nil }
            XCTAssertEqual(status(result), "precondition_failed")
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func testAdmissionRefusalHasNoTargetOrReceiptWrites() throws {
        try fixture { fixture in
            let result = fixture.service.mutate(arguments: request(), root: fixture.root) { ["status": "write_disabled"] }
            XCTAssertEqual(status(result), "admission_refused")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipts.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), [])
        }
    }

    func testExternalEditAtAdmissionIsRefusedBeforeStaging() throws {
        try fixture { fixture in
            let target = fixture.root.appendingPathComponent("example.txt")
            let original = Data("old".utf8)
            try original.write(to: target)
            let result = fixture.service.mutate(arguments: request(expected: original), root: fixture.root) {
                try! Data("outside change".utf8).write(to: target)
                return nil
            }
            XCTAssertEqual(status(result), "precondition_failed", "\(result)")
            XCTAssertEqual(try Data(contentsOf: target), Data("outside change".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["example.txt"])
        }
    }

    func testConcurrentCreatorAtAdmissionIsPreserved() throws {
        try fixture { fixture in
            let target = fixture.root.appendingPathComponent("example.txt")
            let result = fixture.service.mutate(arguments: request(), root: fixture.root) {
                try! Data("winner".utf8).write(to: target)
                return nil
            }
            XCTAssertEqual(status(result), "precondition_failed")
            XCTAssertEqual(try Data(contentsOf: target), Data("winner".utf8))
        }
    }

    func testSymlinkLeafParentAndReplacementParentSwapNeverModifyOutside() throws {
        try fixture { fixture in
            let outside = fixture.container.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
            let outsideFile = outside.appendingPathComponent("item.txt")
            let original = Data("outside".utf8)
            try original.write(to: outsideFile)
            let link = fixture.root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            var admissions = 0
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(path: "link/item.txt", expected: original), root: fixture.root) { admissions += 1; return nil }), "symlink_traversal")
            let leaf = fixture.root.appendingPathComponent("leaf.txt")
            try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: outsideFile)
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(path: "leaf.txt", expected: original), root: fixture.root) { admissions += 1; return nil }), "symlink_traversal")
            XCTAssertEqual(admissions, 0)

            let nested = fixture.root.appendingPathComponent("nested")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try original.write(to: nested.appendingPathComponent("item.txt"))
            let moved = fixture.root.appendingPathComponent("moved")
            let result = fixture.service.mutate(arguments: request(path: "nested/item.txt", expected: original), root: fixture.root) {
                try! FileManager.default.moveItem(at: nested, to: moved)
                try! FileManager.default.createSymbolicLink(at: nested, withDestinationURL: outside)
                return nil
            }
            XCTAssertEqual(status(result), "symlink_traversal")
            XCTAssertEqual(try Data(contentsOf: outsideFile), original)
            XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("item.txt")), original)
        }
    }

    func testProtectedPathsAndMalformedArgumentsRefuseBeforeAdmission() throws {
        try fixture { fixture in
            var admissions = 0
            for path in [".git/config", "src/.env", ".AWS/credentials", "AGENTS.md", "src/agents.MD", "HARNESS.md", "CLAUDE.md"] {
                XCTAssertEqual(status(fixture.service.mutate(arguments: request(path: path), root: fixture.root) { admissions += 1; return nil }), "protected_path", path)
            }
            for path in ["a//b.txt", "a/./b.txt", "", "a/"] {
                XCTAssertEqual(status(fixture.service.mutate(arguments: request(path: path), root: fixture.root) { admissions += 1; return nil }), "invalid_arguments", path)
            }
            var extra: [String: CodexJSON] = ["operation_id": .string("op"), "project_slug": .string("test-project"), "path": .string("x.txt"), "text": .string("x"), "expected_absent": .bool(true), "expected_sha256": .string(String(repeating: "a", count: 64))]
            XCTAssertEqual(status(fixture.service.mutate(arguments: .object(extra), root: fixture.root) { admissions += 1; return nil }), "invalid_arguments")
            extra.removeValue(forKey: "expected_absent")
            extra["expected_sha256"] = .string(String(repeating: "A", count: 64))
            XCTAssertEqual(status(fixture.service.mutate(arguments: .object(extra), root: fixture.root) { admissions += 1; return nil }), "invalid_arguments")
            XCTAssertEqual(status(fixture.service.mutate(arguments: request("operation/1"), root: fixture.root) { admissions += 1; return nil }), "invalid_arguments")
            XCTAssertEqual(admissions, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipts.path))
        }
    }

    func testEntireRootReplacementAtAdmissionRefusesCreateAndReplace() throws {
        for replaceExisting in [false, true] {
            try fixture { fixture in
                let original = Data("original project bytes".utf8)
                let target = fixture.root.appendingPathComponent("example.txt")
                if replaceExisting { try original.write(to: target) }
                let displaced = fixture.container.appendingPathComponent("displaced-project")
                let replacementRootBytes = Data("different project bytes".utf8)
                let result = fixture.service.mutate(
                    arguments: request(expected: replaceExisting ? original : nil), root: fixture.root
                ) {
                    try! FileManager.default.moveItem(at: fixture.root, to: displaced)
                    try! FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
                    try! replacementRootBytes.write(to: target)
                    return nil
                }
                XCTAssertEqual(status(result), "project_changed", "\(result)")
                XCTAssertEqual(result["current_call_mutation_observed"] as? Bool, false)
                XCTAssertEqual(try Data(contentsOf: target), replacementRootBytes)
                let displacedTarget = displaced.appendingPathComponent("example.txt")
                if replaceExisting {
                    XCTAssertEqual(try Data(contentsOf: displacedTarget), original)
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: displacedTarget.path))
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: displaced.path), replaceExisting ? ["example.txt"] : [])
            }
        }
    }

    func testRootSymlinkRemapToSameDirectoryObjectIsRefused() throws {
        try fixture { fixture in
            let original = Data("original".utf8)
            try original.write(to: fixture.root.appendingPathComponent("example.txt"))
            let displaced = fixture.container.appendingPathComponent("displaced-project")
            let result = fixture.service.mutate(arguments: request(expected: original), root: fixture.root) {
                try! FileManager.default.moveItem(at: fixture.root, to: displaced)
                try! FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: displaced)
                return nil
            }
            XCTAssertEqual(status(result), "project_changed", "\(result)")
            XCTAssertEqual(try Data(contentsOf: displaced.appendingPathComponent("example.txt")), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: displaced.path), ["example.txt"])
        }
    }

    func testUnsupportedBinaryOversizedReadonlyHardlinkAndDirectoryRefusals() throws {
        try fixture { fixture in
            let original = Data("old".utf8)
            let target = fixture.root.appendingPathComponent("example.txt")
            var admissions = 0
            let gate: () -> [String: Any]? = { admissions += 1; return nil }
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(path: "image.png"), root: fixture.root, admitWrite: gate)), "unsupported")
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(text: "a\u{0}b"), root: fixture.root, admitWrite: gate)), "unsupported")
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(text: String(repeating: "x", count: 512_001)), root: fixture.root, admitWrite: gate)), "oversized")
            let binary = Data([0xFF, 0xFE, 0x00, 0x01])
            try binary.write(to: target)
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(expected: binary), root: fixture.root, admitWrite: gate)), "unsupported")
            try original.write(to: target)
            XCTAssertEqual(chmod(target.path, mode_t(0o444)), 0)
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(expected: original), root: fixture.root, admitWrite: gate)), "protected_file")
            XCTAssertEqual(chmod(target.path, mode_t(0o600)), 0)
            try FileManager.default.linkItem(at: target, to: fixture.container.appendingPathComponent("hardlink"))
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(expected: original), root: fixture.root, admitWrite: gate)), "protected_file")
            try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("folder"), withIntermediateDirectories: false)
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(path: "folder", expected: original), root: fixture.root, admitWrite: gate)), "unsupported")
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }

    func testConflictingIDAndRootRemappingNeverReexecute() throws {
        try fixture { fixture in
            let first = fixture.service.mutate(arguments: request(), root: fixture.root) { nil }
            XCTAssertEqual(status(first), "succeeded", "\(first)")
            var admissions = 0
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(text: "different"), root: fixture.root) { admissions += 1; return nil }), "idempotency_conflict")
            let another = fixture.container.appendingPathComponent("another")
            try FileManager.default.createDirectory(at: another, withIntermediateDirectories: false)
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(), root: another) { admissions += 1; return nil }), "idempotency_conflict")
            XCTAssertEqual(status(fixture.service.lookup(arguments: statusRequest(), root: another)), "operation_scope_conflict")
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: another.path), [])
        }
    }

    func testInterruptedIntentCorruptAndMissingReceiptNeverReexecute() throws {
        try fixture { fixture in
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(), root: fixture.root) { nil }), "succeeded")
            let receiptFile = fixture.receipts.appendingPathComponent(hash(Data("operation-1".utf8)) + ".json")
            var receipt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptFile)) as? [String: Any])
            receipt["state"] = "intent_recorded"
            receipt["mutationObserved"] = false
            receipt.removeValue(forKey: "finishedAt")
            receipt.removeValue(forKey: "afterSHA256")
            receipt.removeValue(forKey: "afterBytes")
            try JSONSerialization.data(withJSONObject: receipt).write(to: receiptFile)
            let target = fixture.root.appendingPathComponent("example.txt")
            try Data("external".utf8).write(to: target)
            var admissions = 0
            let recovered = fixture.service.mutate(arguments: request(), root: fixture.root) { admissions += 1; return nil }
            XCTAssertEqual(status(recovered), "unknown")
            XCTAssertEqual(recovered["error_code"] as? String, "interrupted_operation")
            XCTAssertTrue(recovered["mutation_observed"] is NSNull)
            try Data("corrupt".utf8).write(to: receiptFile)
            let corrupt = fixture.service.mutate(arguments: request(), root: fixture.root) { admissions += 1; return nil }
            XCTAssertEqual(status(corrupt), "receipt_corrupt")
            XCTAssertTrue(corrupt["mutation_observed"] is NSNull)
            XCTAssertEqual(corrupt["mutation_possible"] as? Bool, true)
            XCTAssertEqual(corrupt["current_call_mutation_observed"] as? Bool, false)
            XCTAssertEqual(corrupt["operation_outcome"] as? String, "unknown")
            try FileManager.default.removeItem(at: receiptFile)
            let missing = fixture.service.mutate(arguments: request(), root: fixture.root) { admissions += 1; return nil }
            XCTAssertEqual(status(missing), "receipt_missing")
            XCTAssertTrue(missing["mutation_observed"] is NSNull)
            XCTAssertEqual(missing["mutation_possible"] as? Bool, true)
            XCTAssertEqual(missing["current_call_mutation_observed"] as? Bool, false)
            let missingLookup = fixture.service.lookup(arguments: statusRequest(), root: fixture.root)
            XCTAssertEqual(status(missingLookup), "receipt_missing")
            XCTAssertTrue(missingLookup["mutation_observed"] is NSNull)
            XCTAssertEqual(missingLookup["operation_id"] as? String, "operation-1")
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(try Data(contentsOf: target), Data("external".utf8))
        }
    }

    func testValidJSONWithInvalidReceiptStateOrOutcomeRefusesAsUnknown() throws {
        try fixture { fixture in
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(), root: fixture.root) { nil }), "succeeded")
            let receiptFile = fixture.receipts.appendingPathComponent(hash(Data("operation-1".utf8)) + ".json")
            let validBytes = try Data(contentsOf: receiptFile)
            let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: validBytes) as? [String: Any])
            let target = fixture.root.appendingPathComponent("example.txt")
            let external = Data("external edit after the operation".utf8)
            try external.write(to: target)
            let corruptions: [(String, (inout [String: Any]) -> Void)] = [
                ("unknown state", { $0["state"] = "succeedXd" }),
                ("missing success hash", { _ = $0.removeValue(forKey: "afterSHA256") }),
                ("missing success byte count", { _ = $0.removeValue(forKey: "afterBytes") }),
                ("missing success finish", { _ = $0.removeValue(forKey: "finishedAt") }),
                ("unobserved success", { $0["mutationObserved"] = false }),
                ("wrong success hash", { $0["afterSHA256"] = String(repeating: "a", count: 64) }),
                ("wrong success bytes", { $0["afterBytes"] = 0 }),
                ("success with error", { $0["errorCode"] = "io_error"; $0["errorMessage"] = "conflicting outcome" }),
                ("negative request bytes", { $0["requestedBytes"] = -1 }),
                ("oversized request bytes", { $0["requestedBytes"] = 512_001 }),
                ("changed request hash", { $0["requestedSHA256"] = String(repeating: "b", count: 64) }),
                ("uppercase hash", { $0["afterSHA256"] = String(repeating: "A", count: 64) }),
                ("create with preimage", { $0["beforeSHA256"] = String(repeating: "c", count: 64); $0["beforeBytes"] = 1 }),
                ("intent with completed outcome", { $0["state"] = "intent_recorded" }),
                ("refusal with observed mutation", { $0["state"] = "refused"; $0["errorCode"] = "io_error"; $0["errorMessage"] = "invalid refusal" }),
                ("unknown without error", { $0["state"] = "unknown" }),
            ]
            var admissions = 0
            for (label, change) in corruptions {
                var invalid = valid
                change(&invalid)
                try JSONSerialization.data(withJSONObject: invalid, options: [.sortedKeys]).write(to: receiptFile)
                let results = [
                    fixture.service.mutate(arguments: request(), root: fixture.root) { admissions += 1; return nil },
                    fixture.service.lookup(arguments: statusRequest(), root: fixture.root),
                ]
                for result in results {
                    XCTAssertEqual(status(result), "receipt_corrupt", "\(label): \(result)")
                    XCTAssertTrue(result["mutation_observed"] is NSNull, label)
                    XCTAssertEqual(result["mutation_possible"] as? Bool, true, label)
                    XCTAssertEqual(result["current_call_mutation_observed"] as? Bool, false, label)
                    XCTAssertEqual(result["operation_outcome"] as? String, "unknown", label)
                }
            }
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(try Data(contentsOf: target), external)
            try validBytes.write(to: receiptFile)
            XCTAssertEqual(status(fixture.service.lookup(arguments: statusRequest(), root: fixture.root)), "succeeded")
        }
    }

    func testOversizedAndNonregularRetainedStateAlwaysReportsUnknownHistory() throws {
        for suffix in ["json", "reserved"] {
            for corruption in ["oversized", "directory", "fifo"] {
                try fixture { fixture in
                    XCTAssertEqual(status(fixture.service.mutate(arguments: request(), root: fixture.root) { nil }), "succeeded")
                    let retained = fixture.receipts.appendingPathComponent(hash(Data("operation-1".utf8)) + "." + suffix)
                    try FileManager.default.removeItem(at: retained)
                    switch corruption {
                    case "oversized":
                        let limit = suffix == "json" ? ConduitFilesystemMutationService.maximumReceiptBytes : 64
                        try Data(repeating: 0x41, count: limit + 1).write(to: retained)
                    case "directory":
                        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: false)
                    case "fifo":
                        // O_NONBLOCK and the regular-file check must make this
                        // a refusal without waiting for a FIFO writer.
                        XCTAssertEqual(mkfifo(retained.path, mode_t(0o600)), 0)
                    default:
                        XCTFail("Unknown retained-state fixture")
                    }
                    let target = fixture.root.appendingPathComponent("example.txt")
                    let external = Data("later external edit".utf8)
                    try external.write(to: target)
                    var admissions = 0
                    let results = [
                        fixture.service.mutate(arguments: request(), root: fixture.root) { admissions += 1; return nil },
                        fixture.service.lookup(arguments: statusRequest(), root: fixture.root),
                    ]
                    for result in results {
                        let context = "\(suffix)/\(corruption): \(result)"
                        XCTAssertEqual(status(result), "receipt_corrupt", context)
                        XCTAssertEqual(result["operation_id"] as? String, "operation-1", context)
                        XCTAssertTrue(result["mutation_observed"] is NSNull, context)
                        XCTAssertEqual(result["mutation_possible"] as? Bool, true, context)
                        XCTAssertEqual(result["current_call_mutation_observed"] as? Bool, false, context)
                        XCTAssertEqual(result["operation_outcome"] as? String, "unknown", context)
                    }
                    XCTAssertEqual(admissions, 0)
                    XCTAssertEqual(try Data(contentsOf: target), external)
                }
            }
        }
    }

    func testUnavailableReceiptStoreDoesNotClaimHistoricalOperationDidNothing() throws {
        try fixture { fixture in
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(), root: fixture.root) { nil }), "succeeded")
            XCTAssertEqual(chmod(fixture.receipts.path, mode_t(0o755)), 0)
            let unavailable = fixture.service.mutate(arguments: request(), root: fixture.root) {
                XCTFail("An unavailable store cannot authorize a retry")
                return nil
            }
            XCTAssertEqual(status(unavailable), "receipt_store_unavailable")
            XCTAssertTrue(unavailable["mutation_observed"] is NSNull)
            XCTAssertEqual(unavailable["mutation_possible"] as? Bool, true)
            XCTAssertEqual(unavailable["current_call_mutation_observed"] as? Bool, false)
            XCTAssertEqual(unavailable["operation_outcome"] as? String, "unknown")
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("example.txt")), Data("new text\n".utf8))
        }
    }

    func testRetentionCapacityRefusesNewOperationsButRetainsReplay() throws {
        try fixture { fixture in
            let service = ConduitFilesystemMutationService(receiptDirectory: fixture.receipts, maximumReceipts: 1)
            XCTAssertEqual(status(service.mutate(arguments: request(), root: fixture.root) { nil }), "succeeded")
            let second = service.mutate(arguments: request("operation-2", path: "second.txt"), root: fixture.root) { nil }
            XCTAssertEqual(status(second), "receipt_capacity")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("second.txt").path))
            XCTAssertEqual(status(service.mutate(arguments: request(), root: fixture.root) { XCTFail("A replay must not be admitted again"); return nil }), "succeeded")
        }
    }

    func testReceiptStoreCannotBeInsideProjectOrFollowSymlink() throws {
        try fixture { fixture in
            let internalService = ConduitFilesystemMutationService(receiptDirectory: fixture.root.appendingPathComponent("receipts"))
            var admissions = 0
            XCTAssertEqual(status(internalService.mutate(arguments: request(), root: fixture.root) { admissions += 1; return nil }), "receipt_store_unavailable")
            XCTAssertEqual(admissions, 0)
            let destination = fixture.container.appendingPathComponent("actual")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(at: fixture.receipts, withDestinationURL: destination)
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(), root: fixture.root) { admissions += 1; return nil }), "receipt_store_unavailable")
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        }
    }

    func testReceiptParentRebindAtAdmissionCannotWriteIntoProject() throws {
        for replaceExisting in [false, true] {
            try fixture { fixture in
                let stateParent = fixture.container.appendingPathComponent("application-state")
                let displacedParent = fixture.container.appendingPathComponent("displaced-state")
                try FileManager.default.createDirectory(at: stateParent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let receipts = stateParent.appendingPathComponent("receipts")
                let service = ConduitFilesystemMutationService(receiptDirectory: receipts)
                let original = Data("original project text".utf8)
                let target = fixture.root.appendingPathComponent("example.txt")
                if replaceExisting { try original.write(to: target) }
                var admissions = 0
                let result = service.mutate(arguments: request(expected: replaceExisting ? original : nil), root: fixture.root) {
                    admissions += 1
                    try! FileManager.default.moveItem(at: stateParent, to: displacedParent)
                    try! FileManager.default.createSymbolicLink(at: stateParent, withDestinationURL: fixture.root)
                    return nil
                }
                XCTAssertEqual(status(result), "receipt_store_unavailable", "\(result)")
                XCTAssertEqual(result["current_call_mutation_observed"] as? Bool, false)
                XCTAssertEqual(admissions, 1)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: displacedParent.path), [])
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), replaceExisting ? ["example.txt"] : [])
                if replaceExisting { XCTAssertEqual(try Data(contentsOf: target), original) }
                else { XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)) }
            }
        }
    }

    func testReceiptDirectoryRebindAtAdmissionCannotSwitchLedgers() throws {
        try fixture { fixture in
            let service = fixture.service
            XCTAssertEqual(status(service.mutate(arguments: request(), root: fixture.root) { nil }), "succeeded")
            let retainedNames = try FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path).sorted()
            let displaced = fixture.container.appendingPathComponent("displaced-receipts")
            var admissions = 0
            let result = service.mutate(arguments: request("operation-2", path: "second.txt"), root: fixture.root) {
                admissions += 1
                try! FileManager.default.moveItem(at: fixture.receipts, to: displaced)
                try! FileManager.default.createDirectory(at: fixture.receipts, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                return nil
            }
            XCTAssertEqual(status(result), "receipt_store_unavailable", "\(result)")
            XCTAssertEqual(admissions, 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path), [])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: displaced.path).sorted(), retainedNames)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["example.txt"])
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("example.txt")), Data("new text\n".utf8))
        }
    }

    func testReceiptParentFlushFailurePrecedesIntentPreimageAndTargetStaging() throws {
        try fixture { fixture in
            let original = Data("old file contents".utf8)
            let target = fixture.root.appendingPathComponent("example.txt")
            try original.write(to: target)
            var parentFlushes = 0
            let service = ConduitFilesystemMutationService(receiptDirectory: fixture.receipts, synchronizeReceiptParent: { parent in
                parentFlushes += 1
                // Verify the production path supplied the actual containing
                // directory, after mkdir but before reserving any operation.
                var observed = stat()
                var expected = stat()
                XCTAssertEqual(fstat(parent, &observed), 0)
                XCTAssertEqual(lstat(fixture.container.path, &expected), 0)
                XCTAssertEqual(observed.st_dev, expected.st_dev)
                XCTAssertEqual(observed.st_ino, expected.st_ino)
                XCTAssertEqual(try! FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path), [])
                errno = EIO
                return -1
            })
            var admissions = 0
            let result = service.mutate(arguments: request(expected: original), root: fixture.root) {
                admissions += 1
                return nil
            }
            XCTAssertEqual(status(result), "receipt_store_unavailable", "\(result)")
            XCTAssertEqual(parentFlushes, 1)
            XCTAssertEqual(admissions, 1)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path), [])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["example.txt"])
            XCTAssertEqual(try Data(contentsOf: target), original)
            // A failure before the durable intent has not reserved this ID.
            let retry = fixture.service.mutate(arguments: request(expected: original), root: fixture.root) { nil }
            XCTAssertEqual(status(retry), "succeeded", "\(retry)")
        }
    }

    func testConcurrentSameIDAcrossInstancesCommitsOnce() throws {
        try fixture { fixture in
            let collectorLock = NSLock()
            var admissions = 0
            var outcomes: [String] = []
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                let result = fixture.service.mutate(arguments: request(), root: fixture.root) {
                    collectorLock.lock(); admissions += 1; collectorLock.unlock()
                    return nil
                }
                collectorLock.lock(); outcomes.append(status(result) ?? "missing"); collectorLock.unlock()
            }
            XCTAssertEqual(admissions, 1)
            XCTAssertEqual(outcomes, Array(repeating: "succeeded", count: 8))
            XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent("example.txt")), Data("new text\n".utf8))
        }
    }

    #if canImport(Darwin)
    private func attributeValue(_ name: String, at url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        let count = fgetxattr(fd, name, nil, 0, 0, 0)
        if count < 0, errno == ENOATTR { return nil }
        guard count >= 0, count <= 4096 else { throw POSIXError(.EIO) }
        var value = Data(count: count)
        let observed = value.withUnsafeMutableBytes {
            fgetxattr(fd, name, $0.baseAddress, count, 0, 0)
        }
        guard observed == count else { throw POSIXError(.EIO) }
        return value
    }

    func testCreatesAndReplacesWhilePreservingOpaqueSystemProvenance() throws {
        try fixture { fixture in
            let target = fixture.root.appendingPathComponent("example.txt")
            let original = Data("original opaque-metadata file".utf8)
            try original.write(to: target)
            let priorProvenance = try attributeValue("com.apple.provenance", at: target)
            let replacement = fixture.service.mutate(arguments: request("replace", text: "replacement text", expected: original), root: fixture.root) { nil }
            XCTAssertEqual(status(replacement), "succeeded", "\(replacement)")
            XCTAssertEqual(try Data(contentsOf: target), Data("replacement text".utf8))
            if let priorProvenance {
                XCTAssertEqual(try attributeValue("com.apple.provenance", at: target), priorProvenance)
            }
            // Older macOS files may lack this attribute. Absence on a source
            // does not require stripping any OS provenance from a new inode.
            let created = fixture.service.mutate(arguments: request("create", path: "created.txt", text: "new file"), root: fixture.root) { nil }
            XCTAssertEqual(status(created), "succeeded", "\(created)")
            let newTarget = fixture.root.appendingPathComponent("created.txt")
            XCTAssertEqual(try Data(contentsOf: newTarget), Data("new file".utf8))
            if let createdProvenance = try attributeValue("com.apple.provenance", at: newTarget) {
                XCTAssertLessThanOrEqual(createdProvenance.count, 4096)
            }
        }
    }

    func testAdditionalMetadataAtAdmissionRefusesWithoutStrippingIt() throws {
        try fixture { fixture in
            let target = fixture.root.appendingPathComponent("example.txt")
            let original = Data("unchanged target".utf8)
            try original.write(to: target)
            let priorProvenance = try attributeValue("com.apple.provenance", at: target)
            let addedMetadata = Data("external metadata at admission".utf8)
            let addedName = "com.conduit.concurrent-metadata"
            var admissions = 0
            let result = fixture.service.mutate(arguments: request(expected: original), root: fixture.root) {
                admissions += 1
                let setResult = addedMetadata.withUnsafeBytes {
                    setxattr(target.path, addedName, $0.baseAddress, addedMetadata.count, 0, 0)
                }
                XCTAssertEqual(setResult, 0)
                return nil
            }
            XCTAssertEqual(status(result), "unsupported_metadata", "\(result)")
            XCTAssertEqual(admissions, 1)
            XCTAssertEqual(result["current_call_mutation_observed"] as? Bool, false)
            XCTAssertEqual(try Data(contentsOf: target), original)
            XCTAssertEqual(try attributeValue(addedName, at: target), addedMetadata)
            XCTAssertEqual(try attributeValue("com.apple.provenance", at: target), priorProvenance)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), ["example.txt"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.receipts.path), [])
        }
    }

    func testExtendedAttributeAndACLRefuseWithoutDiscardingMetadata() throws {
        try fixture { fixture in
            let target = fixture.root.appendingPathComponent("example.txt")
            let original = Data("old".utf8)
            try original.write(to: target)
            let attribute = Data("private metadata".utf8)
            let setResult = attribute.withUnsafeBytes { setxattr(target.path, "com.conduit.test", $0.baseAddress, attribute.count, 0, 0) }
            XCTAssertEqual(setResult, 0)
            var admissions = 0
            XCTAssertEqual(status(fixture.service.mutate(arguments: request(expected: original), root: fixture.root) { admissions += 1; return nil }), "unsupported_metadata")
            XCTAssertEqual(removexattr(target.path, "com.conduit.test", 0), 0)
            let aclText = "!#acl 1\nuser::\(NSUserName()):\(geteuid()):allow:read\n"
            if let acl = acl_from_text(aclText) {
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                XCTAssertEqual(acl_set_file(target.path, ACL_TYPE_EXTENDED, acl), 0)
                XCTAssertEqual(status(fixture.service.mutate(arguments: request(expected: original), root: fixture.root) { admissions += 1; return nil }), "unsupported_metadata")
            } else {
                XCTFail("Could not create the ACL fixture")
            }
            XCTAssertEqual(admissions, 0)
            XCTAssertEqual(try Data(contentsOf: target), original)
        }
    }
    #endif
}
