import Foundation
import XCTest
@testable import ConduitCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ConduitFilesystemReadTests: XCTestCase {
    private let fm = FileManager.default

    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(root)
    }

    @discardableResult
    private func write(_ root: URL, _ path: String, _ text: String) throws -> URL {
        let file = root.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    private func observe(_ root: URL?, _ operation: String, _ path: String, _ extra: [String: CodexJSON] = [:]) -> [String: Any] {
        var fields = extra
        fields["operation"] = .string(operation)
        fields["path"] = .string(path)
        return ConduitFilesystemReadTool.observe(arguments: .object(fields), root: root)
    }

    func testListUsesLiveDirectoryAndExplorerHiddenPathPolicy() throws {
        try fixture { root in
            for path in [".agents/rules.md", ".context/rules.md", ".github/workflow.yml", ".git/secret", ".DS_Store", "40_operations/job/README.md"] {
                try write(root, path, "source")
            }
            let result = observe(root, "list", "")
            XCTAssertEqual(result["status"] as? String, "ok")
            XCTAssertEqual(result["truncated"] as? Bool, false)
            let entries = try XCTUnwrap(result["entries"] as? [[String: Any]])
            XCTAssertEqual(Set(entries.compactMap { $0["path"] as? String }), [".agents", ".context", ".github", "40_operations"])
            XCTAssertEqual(observe(root, "read", ".git/secret")["status"] as? String, "excluded_path")
        }
    }

    func testReadsExactSourceBytesAndFreshMetadata() throws {
        try fixture { root in
            let source = "let café = 1\r\n"
            try write(root, "40_operations/job/main.swift", source)
            let result = observe(root, "read", "40_operations/job/main.swift")
            XCTAssertEqual(result["status"] as? String, "ok")
            XCTAssertEqual(result["text"] as? String, source)
            let metadata = try XCTUnwrap(result["metadata"] as? [String: Any])
            XCTAssertEqual(metadata["size_bytes"] as? Int, source.utf8.count)
            XCTAssertEqual(metadata["path"] as? String, "40_operations/job/main.swift")
            XCTAssertNotNil(metadata["modified_at"] as? String)
            XCTAssertEqual(result["verification"] as? String, "unverified_contents")
        }
    }

    func testExactPathRecoveryIgnoresPriorListingAndQuickOpenBounds() throws {
        try fixture { root in
            try write(root, "20_live/old.md", "old")
            XCTAssertEqual(observe(root, "list", "20_live")["returned"] as? Int, 1)
            _ = try MainframeExplorerScanner().buildIndex(root: root, maxEntries: 1)
            let file = try write(root, "20_live/new/nested/status.json", "{\"revision\":1}")
            XCTAssertEqual(observe(root, "stat", "20_live/new/nested/status.json")["status"] as? String, "ok")
            XCTAssertEqual(observe(root, "read", "20_live/new/nested/status.json")["text"] as? String, "{\"revision\":1}")
            try "updated".write(to: file, atomically: true, encoding: .utf8)
            XCTAssertEqual(observe(root, "read", "20_live/new/nested/status.json")["text"] as? String, "updated")
            try fm.removeItem(at: file)
            XCTAssertEqual(observe(root, "stat", "20_live/new/nested/status.json")["status"] as? String, "missing")
        }
    }

    func testRejectsAbsoluteParentRootOverrideAndAmbiguousPaths() throws {
        try fixture { root in
            for path in ["../outside", "safe/../../outside", root.path, "/etc/hosts"] {
                XCTAssertEqual(observe(root, "read", path)["status"] as? String, "outside_root")
            }
            for path in ["a//b", "a/./b", "a/", "a\0b"] {
                XCTAssertEqual(observe(root, "read", path)["status"] as? String, "invalid_arguments")
            }
            XCTAssertEqual(observe(root, "list", "", ["root": .string("/")])["status"] as? String, "invalid_arguments")
            XCTAssertEqual(observe(root, "stat", ".")["status"] as? String, "ok")
            XCTAssertEqual(observe(nil, "stat", "")["status"] as? String, "root_unavailable")
        }
    }

    func testSymlinksAreLeavesEvenForInsideRootAndDanglingTargets() throws {
        try fixture { root in
            try write(root, "real/inside.md", "inside")
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("alias").path, withDestinationPath: "real")
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("dangling").path, withDestinationPath: "absent")
            try fm.createSymbolicLink(atPath: root.appendingPathComponent("outside").path, withDestinationPath: "/etc")
            for name in ["alias", "dangling", "outside"] {
                XCTAssertEqual(observe(root, "stat", name)["status"] as? String, "symbolic_link")
                XCTAssertEqual(observe(root, "read", name)["status"] as? String, "symlink_traversal")
                XCTAssertEqual(observe(root, "list", name)["status"] as? String, "symlink_traversal")
            }
            XCTAssertEqual(observe(root, "read", "alias/inside.md")["status"] as? String, "symlink_traversal")
            XCTAssertEqual(observe(root, "read", "outside/hosts")["status"] as? String, "symlink_traversal")
            // The shared UI reader must enforce the same ancestor policy.
            XCTAssertThrowsError(try MainframeExplorerScanner().readUTF8Text(root: root, file: root.appendingPathComponent("alias/inside.md")))
        }
    }

    func testMissingAndUnreadablePathsAreDistinct() throws {
        try fixture { root in
            for operation in ["read", "list", "stat"] {
                XCTAssertEqual(observe(root, operation, "missing")["status"] as? String, "missing")
            }
            let file = try write(root, "private.txt", "private")
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
            XCTAssertEqual(observe(root, "read", "private.txt")["status"] as? String, "inaccessible")
            XCTAssertEqual(observe(root, "list", "private.txt")["status"] as? String, "not_directory")
        }
    }

    func testBinaryMediaNonUTF8AndSpecialFilesNeverBecomeText() throws {
        try fixture { root in
            try write(root, "looks-valid.pdf", "%PDF-1.7")
            try write(root, "Tests/media.PNG", "not an image")
            try write(root, "binary.txt", "zero\0byte")
            try Data([0xff, 0xfe]).write(to: root.appendingPathComponent("nonutf8.txt"))
            XCTAssertEqual(mkfifo(root.appendingPathComponent("pipe").path, 0o600), 0)
            for path in ["looks-valid.pdf", "Tests/media.PNG", "binary.txt", "nonutf8.txt", "pipe"] {
                let result = observe(root, "read", path)
                XCTAssertEqual(result["status"] as? String, "unsupported", path)
                XCTAssertNil(result["text"])
            }
            try write(root, "extensionless", "plain text\n")
            XCTAssertEqual(observe(root, "read", "extensionless")["text"] as? String, "plain text\n")
        }
    }

    func testBoundedSizeAndListingHaveHonestReceipts() throws {
        try fixture { root in
            try write(root, "a.txt", "12345")
            try write(root, "b.txt", "b")
            XCTAssertEqual(observe(root, "read", "a.txt", ["max_bytes": .number(5)])["text"] as? String, "12345")
            let oversized = observe(root, "read", "a.txt", ["max_bytes": .number(4)])
            XCTAssertEqual(oversized["status"] as? String, "oversized")
            XCTAssertNil(oversized["text"])
            let list = observe(root, "list", "", ["max_entries": .number(1)])
            XCTAssertEqual(list["returned"] as? Int, 1)
            XCTAssertEqual(list["truncated"] as? Bool, true)
            XCTAssertEqual(list["completeness"] as? String, "bounded_subset")
            for value in [CodexJSON.number(0), .number(512_001), .number(1.5), .string("10"), .bool(true)] {
                XCTAssertEqual(observe(root, "read", "a.txt", ["max_bytes": value])["status"] as? String, "invalid_arguments")
            }
            XCTAssertEqual(observe(root, "list", "", ["max_entries": .number(501)])["status"] as? String, "invalid_arguments")
        }
    }

    func testConfiguredAncestorAliasIsPreservedWithoutAdmittingInRootLinks() throws {
        try fixture { base in
            let root = base.appendingPathComponent("physical/root")
            try write(root, "file.txt", "source")
            let alias = base.appendingPathComponent("selected-alias")
            try fm.createSymbolicLink(at: alias, withDestinationURL: root.deletingLastPathComponent())
            let selected = alias.appendingPathComponent("root")
            XCTAssertEqual(observe(selected, "read", "file.txt")["text"] as? String, "source")
            XCTAssertEqual(try MainframeExplorerScanner().readUTF8Text(root: selected, file: root.appendingPathComponent("file.txt")), "source")
            XCTAssertEqual(observe(alias, "list", "")["status"] as? String, "symlink_traversal")
        }
    }

    func testObservationPreservesSourceAndDurableSessionBytes() throws {
        try fixture { root in
            let source = try write(root, "20_live/status.json", "{\"state\":\"unknown\"}")
            let session = try write(root, "20_live/sessions/task.jsonl", "{\"event\":\"recorded\"}\n")
            let before = try [source, session].map { try Data(contentsOf: $0) }
            for operation in ["stat", "read", "list"] {
                _ = observe(root, operation, operation == "list" ? "20_live" : "20_live/status.json")
            }
            XCTAssertEqual(try [source, session].map { try Data(contentsOf: $0) }, before)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.appendingPathComponent("20_live").path).sorted(), ["sessions", "status.json"])
        }
    }
}
