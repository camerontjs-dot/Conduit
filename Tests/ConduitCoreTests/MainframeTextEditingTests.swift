import Foundation
import XCTest
@testable import ConduitCore

final class MainframeTextEditingTests: XCTestCase {
    private let fm = FileManager.default

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(root)
    }

    private func write(_ root: URL, _ path: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSaveReplacesOnlyExactFileWhenBaselineStillMatches() throws {
        try withRoot { root in
            let target = try write(root, "30_projects/demo/README.md", "# Old\n")
            let adjacent = try write(root, "30_projects/demo/notes.md", "keep me\n")

            try MainframeTextFileWriter().saveUTF8Text(
                root: root,
                file: target,
                expectedSource: "# Old\n",
                newSource: "# New\n"
            )

            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# New\n")
            XCTAssertEqual(try String(contentsOf: adjacent, encoding: .utf8), "keep me\n")
        }
    }

    func testExternalChangeProducesConflictAndPreservesExternalContent() throws {
        try withRoot { root in
            let target = try write(root, "10_knowledge/note.md", "baseline\n")
            try "external change\n".write(to: target, atomically: true, encoding: .utf8)

            XCTAssertThrowsError(
                try MainframeTextFileWriter().saveUTF8Text(
                    root: root,
                    file: target,
                    expectedSource: "baseline\n",
                    newSource: "my edit\n"
                )
            ) { error in
                guard case MainframeTextEditError.conflict = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

            XCTAssertEqual(
                try String(contentsOf: target, encoding: .utf8),
                "external change\n"
            )
        }
    }

    func testOversizedEditIsRejectedBeforeMutation() throws {
        try withRoot { root in
            let target = try write(root, "10_knowledge/note.md", "small")

            XCTAssertThrowsError(
                try MainframeTextFileWriter().saveUTF8Text(
                    root: root,
                    file: target,
                    expectedSource: "small",
                    newSource: "0123456789",
                    maxBytes: 4
                )
            ) { error in
                guard case MainframeTextEditError.newContentTooLarge = error else {
                    return XCTFail("unexpected error: \(error)")
                }
            }

            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "small")
        }
    }

    func testWriterRejectsSymlinkTargetAndDoesNotMutateDestination() throws {
        try withRoot { root in
            let destination = try write(root, "10_knowledge/real.md", "real\n")
            let link = root.appendingPathComponent("10_knowledge/link.md")
            try fm.createSymbolicLink(at: link, withDestinationURL: destination)

            XCTAssertThrowsError(
                try MainframeTextFileWriter().saveUTF8Text(
                    root: root,
                    file: link,
                    expectedSource: "real\n",
                    newSource: "changed\n"
                )
            )

            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "real\n")
        }
    }
}
