import Foundation
import XCTest
@testable import ConduitCore

final class MainframeExplorerTextDocumentTests: XCTestCase {
    private func node(_ name: String, kind: MainframeExplorerNodeKind = .file) -> MainframeExplorerNode {
        MainframeExplorerNode(name: name, relativePath: name, url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name), kind: kind, zone: .system, recordScope: nil)
    }

    func testMarkdownSourceAndConfigurationHaveOneExplicitEligibilityPolicy() throws {
        for name in ["note.md", "main.swift", "config.json", "settings.yaml", ".gitignore"] {
            let document = try MainframeExplorerTextDocument(node: node(name), source: "plain UTF-8\n", isWritable: true)
            XCTAssertFalse(document.hasUnsavedChanges)
        }
        for name in ["image.png", "document.pdf", "archive.zip", "unrecognized.format"] {
            XCTAssertThrowsError(try MainframeExplorerTextDocument(node: node(name), source: "even valid UTF-8", isWritable: true))
        }
        XCTAssertThrowsError(try MainframeExplorerTextDocument(node: node("linked.md", kind: .symbolicLink), source: "source", isWritable: true))
        XCTAssertThrowsError(try MainframeExplorerTextDocument(node: node("locked.md"), source: "source", isWritable: false))
    }

    func testUnsupportedEncodingLineEndingsAndBinaryControlsStayReadOnly() {
        for source in ["\u{FEFF}BOM", "one\r\ntwo\n", "one\rtwo", "binary\0text", "control\u{001B}"] {
            XCTAssertThrowsError(try MainframeExplorerTextDocument(node: node("file.txt"), source: source, isWritable: true))
        }
        XCTAssertThrowsError(try MainframeExplorerTextDocument(node: node("file.txt"), source: String(repeating: "x", count: MainframeExplorerTextDocument.byteLimit + 1), isWritable: true))
    }

    func testCRLFBufferNormalizesInMemoryAndSavePreservesExactLineEndings() throws {
        var document = try MainframeExplorerTextDocument(node: node("config.json"), source: "one\r\ntwo\r\n", isWritable: true)
        XCTAssertEqual(document.lineEnding, .crlf)
        XCTAssertEqual(document.buffer, "one\ntwo\n")
        XCTAssertFalse(document.hasUnsavedChanges)
        document.updateBuffer("one\nchanged\n")
        XCTAssertTrue(document.hasUnsavedChanges)
        XCTAssertEqual(try document.sourceForSave(), "one\r\nchanged\r\n")
    }

    func testNoTrailingNewlineOrUnicodeNormalizationIsInvented() throws {
        var document = try MainframeExplorerTextDocument(node: node("main.py"), source: "caf\u{00E9}", isWritable: true)
        document.updateBuffer("cafe\u{0301}")
        XCTAssertTrue(document.hasUnsavedChanges)
        XCTAssertEqual(Array(try document.sourceForSave().utf8), Array("cafe\u{0301}".utf8))
    }

    func testUndoRedoAndRevertDoNotTouchFilesystem() throws {
        var document = try MainframeExplorerTextDocument(node: node("file.txt"), source: "initial", isWritable: true)
        document.updateBuffer("first")
        document.updateBuffer("second")
        document.undo(); XCTAssertEqual(document.buffer, "first")
        document.undo(); XCTAssertEqual(document.buffer, "initial"); XCTAssertFalse(document.hasUnsavedChanges)
        document.redo(); XCTAssertEqual(document.buffer, "first")
        document.revert(); XCTAssertEqual(document.buffer, "initial")
        XCTAssertEqual(document.baseline, "initial")
    }

    func testReplaceIsLiteralBoundedAtomicAndUndoable() throws {
        var document = try MainframeExplorerTextDocument(node: node("config.txt"), source: "[x] [x] X", isWritable: true)
        XCTAssertEqual(try document.literalMatchCount("[x]"), 2)
        XCTAssertEqual(try document.replaceLiteral("[x]", with: "é", all: true), 2)
        XCTAssertEqual(document.buffer, "é é X")
        document.undo(); XCTAssertEqual(document.buffer, "[x] [x] X")
        XCTAssertEqual(try document.replaceLiteral("[x]", with: "y", all: false), 1)
        XCTAssertEqual(document.buffer, "y [x] X")
        XCTAssertThrowsError(try document.replaceLiteral("", with: "y", all: true))

        var repeated = try MainframeExplorerTextDocument(node: node("file.txt"), source: String(repeating: "a", count: 501), isWritable: true)
        XCTAssertThrowsError(try repeated.replaceLiteral("a", with: "b", all: true))
        XCTAssertEqual(repeated.buffer, String(repeating: "a", count: 501))
    }

    func testOversizedOrBinaryReplacementCannotMutateBuffer() throws {
        var document = try MainframeExplorerTextDocument(node: node("file.txt"), source: "one", isWritable: true)
        XCTAssertThrowsError(try document.replaceLiteral("one", with: String(repeating: "x", count: MainframeExplorerTextDocument.byteLimit + 1), all: true))
        XCTAssertThrowsError(try document.replaceLiteral("one", with: "binary\0", all: true))
        XCTAssertEqual(document.buffer, "one")
        XCTAssertFalse(document.updateBuffer(String(repeating: "x", count: MainframeExplorerTextDocument.byteLimit + 1)))
        XCTAssertEqual(document.buffer, "one")
    }

    func testExactUTF8WriterRejectsCanonicallyEquivalentExternalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file.txt")
        let original = "caf\u{00E9}\n"
        let external = "cafe\u{0301}\n"
        XCTAssertEqual(original, external, "Control requires Swift's semantic equivalence")
        try Data(external.utf8).write(to: file)
        XCTAssertThrowsError(try MainframeTextFileWriter().saveUTF8Text(root: root, file: file, expectedSource: original, newSource: "user edit\n"))
        XCTAssertEqual(try Data(contentsOf: file), Data(external.utf8))
    }
}
