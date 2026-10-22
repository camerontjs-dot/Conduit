import Foundation
import XCTest
import CryptoKit
@testable import ConduitCore

final class ConduitFilesystemSearchTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @discardableResult
    private func write(_ root: URL, _ path: String, _ text: String) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    private func search(_ root: URL?, _ query: String = "needle", _ extra: [String: CodexJSON] = [:]) -> [String: Any] {
        var fields: [String: CodexJSON] = ["project_slug": .string("fixture"), "query": .string(query)]
        fields.merge(extra) { _, new in new }
        return ConduitFilesystemSearchTool.observe(arguments: .object(fields), root: root)
    }

    func testLiteralCaseSensitiveSearchReportsLiveByteIdentityAndCRLFPositions() throws {
        try fixture { root in
            let text = "first\r\ncafé needle needle\r\nNEEDLE\r\n"
            let file = try write(root, "nested/source.txt", text)
            try write(root, "regex.txt", "a.b\naXb\n")
            let before = try Data(contentsOf: file)
            let result = search(root)
            XCTAssertEqual(result["status"] as? String, "ok")
            let matches = try XCTUnwrap(result["matches"] as? [[String: Any]])
            XCTAssertEqual(matches.count, 1)
            XCTAssertEqual(matches[0]["path"] as? String, "nested/source.txt")
            XCTAssertEqual(matches[0]["line"] as? Int, 2)
            XCTAssertEqual(matches[0]["column_bytes"] as? Int, 7)
            XCTAssertEqual(matches[0]["byte_offset"] as? Int, 13)
            XCTAssertEqual(matches[0]["text"] as? String, "café needle needle")
            XCTAssertEqual(matches[0]["sha256"] as? String, SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(search(root, "a.b")["returned"] as? Int, 1)
            XCTAssertEqual(try Data(contentsOf: file), before)

            try Data("changed needle\n".utf8).write(to: file)
            let fresh = try XCTUnwrap(search(root)["matches"] as? [[String: Any]])
            XCTAssertNotEqual(fresh.first?["sha256"] as? String, matches[0]["sha256"] as? String)
            XCTAssertEqual(fresh.first?["text"] as? String, "changed needle")
        }
    }

    func testLinksExcludedMetadataAndBinaryFilesNeverBecomeSearchContents() throws {
        try fixture { root in
            try write(root, ".git/private.txt", "needle should stay excluded")
            try write(root, "ordinary.txt", "needle")
            let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try Data("needle outside".utf8).write(to: outside)
            defer { try? FileManager.default.removeItem(at: outside) }
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.txt"), withDestinationURL: outside)
            try Data([0, 110, 101, 101, 100, 108, 101]).write(to: root.appendingPathComponent("binary.bin"))
            let result = search(root)
            let matches = try XCTUnwrap(result["matches"] as? [[String: Any]])
            XCTAssertEqual(matches.compactMap { $0["path"] as? String }, ["ordinary.txt"])
            XCTAssertEqual((result["skipped"] as? [String: Int])?["symbolic_link"], 1)
            XCTAssertEqual((result["skipped"] as? [String: Int])?["unsupported"], 1)
            XCTAssertEqual(search(root, "needle", ["path": .string(".git")])["status"] as? String, "excluded_path")
            XCTAssertEqual(search(root, "needle", ["path": .string("link.txt")])["status"] as? String, "symlink_traversal")
            XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "needle outside")
        }
    }

    func testUTF8BOMKeepsRawFileHashAndByteOffsetAcrossReadAndSearch() throws {
        try fixture { root in
            let bytes = Data([0xEF, 0xBB, 0xBF]) + Data("needle\r\n".utf8)
            try bytes.write(to: root.appendingPathComponent("bom.txt"))
            let expectedHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let match = try XCTUnwrap((search(root)["matches"] as? [[String: Any]])?.first)
            XCTAssertEqual(match["sha256"] as? String, expectedHash)
            XCTAssertEqual(match["byte_offset"] as? Int, 3)
            let read = ConduitFilesystemReadTool.observe(arguments: .object([
                "operation": .string("read"), "path": .string("bom.txt"),
            ]), root: root)
            XCTAssertEqual(read["sha256"] as? String, expectedHash)
            XCTAssertEqual(read["hash_scope"] as? String, "exact_observed_file_bytes")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("bom.txt")), bytes)
        }
    }

    func testEveryTraversalAndOutputLimitReportsPartialObservation() throws {
        try fixture { root in
            try write(root, "a.txt", "needle\nneedle\n")
            try write(root, "b.txt", "needle\n")
            try write(root, "nested/c.txt", "needle\n")
            for extra: [String: CodexJSON] in [
                ["max_results": .number(1)],
                ["max_entries": .number(1)],
                ["max_files": .number(1)],
                ["max_depth": .number(0)],
                ["max_file_bytes": .number(5)],
                ["max_total_bytes": .number(10)],
            ] {
                let result = search(root, "needle", extra)
                XCTAssertEqual(result["status"] as? String, "partial", "\(extra)")
                XCTAssertEqual(result["truncated"] as? Bool, true)
                XCTAssertFalse(try XCTUnwrap(result["partial_reasons"] as? [String]).isEmpty)
            }
            XCTAssertEqual(search(root, "needle", ["max_results": .number(1)])["returned"] as? Int, 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(search(root, "needle", ["max_entries": .number(1)])["entries_visited"] as? Int), 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(search(root, "needle", ["max_files": .number(1)])["files_considered"] as? Int), 1)
            XCTAssertLessThanOrEqual(try XCTUnwrap(search(root, "needle", ["max_total_bytes": .number(10)])["read_budget_charged_bytes"] as? Int), 10)
        }
    }

    func testLongLineSnippetIncludesMatchAndRespectsUTF8ByteBound() throws {
        try fixture { root in
            try write(root, "long.txt", String(repeating: "é", count: 1_000) + "needle" + String(repeating: "界", count: 1_000))
            let result = search(root)
            let match = try XCTUnwrap((result["matches"] as? [[String: Any]])?.first)
            let text = try XCTUnwrap(match["text"] as? String)
            XCTAssertTrue(text.contains("needle"))
            XCTAssertFalse(text.contains("\u{FFFD}"))
            XCTAssertLessThanOrEqual(text.utf8.count, ConduitFilesystemSearchTool.maximumSnippetBytes)
            XCTAssertEqual(match["text_truncated"] as? Bool, true)
            XCTAssertEqual(match["byte_offset"] as? Int, 2_000)
        }
    }

    func testInvalidInputsRefuseBeforeAnyFilesystemObservation() throws {
        try fixture { root in
            let file = try write(root, "source.txt", "needle")
            let before = try Data(contentsOf: file)
            for query in ["", "a\nb", "a\rb", "a\0b", String(repeating: "x", count: 257)] {
                XCTAssertEqual(search(root, query)["status"] as? String, "invalid_arguments")
            }
            for path in ["/etc", "../neighbor", "nested/../../neighbor"] {
                XCTAssertEqual(search(root, "needle", ["path": .string(path)])["status"] as? String, "outside_root")
            }
            for path in ["nested//file", "nested/./file", "nested/"] {
                XCTAssertEqual(search(root, "needle", ["path": .string(path)])["status"] as? String, "invalid_arguments")
            }
            for extra: [String: CodexJSON] in [
                ["root": .string("/")],
                ["max_results": .number(1e100)],
                ["max_files": .number(1.5)],
                ["max_depth": .number(-1)],
                ["max_total_bytes": .number(1)],
                ["path": .number(1)],
            ] {
                XCTAssertEqual(search(root, "needle", extra)["status"] as? String, "invalid_arguments")
            }
            XCTAssertEqual(search(nil)["status"] as? String, "project_unavailable")
            XCTAssertEqual(try Data(contentsOf: file), before)
        }
    }

    func testTransportWrapperRetainsTypedPartialAndFailurePayloads() throws {
        try fixture { root in
            try write(root, "source.txt", "needle\nneedle\n")
            let partial = ConduitFilesystemSearchTool.call(arguments: .object([
                "project_slug": .string("fixture"), "query": .string("needle"), "max_results": .number(1),
            ]), root: root)
            XCTAssertEqual(partial["isError"] as? Bool, false)
            XCTAssertEqual((partial["structuredContent"] as? [String: Any])?["status"] as? String, "partial")
            let invalid = ConduitFilesystemSearchTool.call(arguments: .object([:]), root: root)
            XCTAssertEqual(invalid["isError"] as? Bool, true)
            XCTAssertEqual((invalid["structuredContent"] as? [String: Any])?["status"] as? String, "invalid_arguments")
        }
    }
}
