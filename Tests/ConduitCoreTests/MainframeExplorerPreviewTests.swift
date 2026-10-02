import XCTest
@testable import ConduitCore

final class MainframeExplorerPreviewTests: XCTestCase {
    func testPreviewRouterClassifiesNativeAndTextFormats() {
        XCTAssertEqual(route("notes.md"), .text)
        XCTAssertEqual(route("data.json"), .text)
        XCTAssertEqual(route("README"), .text)
        XCTAssertEqual(route("figure.png"), .image)
        XCTAssertEqual(route("photo.JPEG"), .image)
        XCTAssertEqual(route("paper.pdf"), .pdf)
        XCTAssertEqual(route("archive.zip"), .unsupportedBinary)
        XCTAssertEqual(route("notes.mdown"), .text)
        XCTAssertEqual(route("notes.mkd"), .text)
        XCTAssertEqual(route(".gitignore"), .text)
        XCTAssertEqual(route("animation.gif"), .image)
        XCTAssertEqual(route("photo.webp"), .image)
    }

    func testReadReturnsExactBytesForTheScannerNodeAndReportsMetadata() throws {
        try fixture { root in
            let data = Data([0, 255, 42, 7])
            try data.write(to: root.appendingPathComponent("figure.png"))
            let node = try XCTUnwrap(MainframeExplorerScanner().rootChildren(root: root).first)
            XCTAssertEqual(try MainframeExplorerPreviewLoader().read(root: root, node: node), data)
            XCTAssertEqual(try MainframeExplorerPreviewLoader().byteCount(root: root, node: node), 4)
        }
    }

    func testURLCannotSubstituteAnotherFileForTheSelectedRelativePath() throws {
        try fixture { root in
            try Data("first".utf8).write(to: root.appendingPathComponent("a.txt"))
            try Data("second".utf8).write(to: root.appendingPathComponent("b.txt"))
            let node = makeNode(root: root, path: "a.txt", url: root.appendingPathComponent("b.txt"))
            XCTAssertThrowsError(try MainframeExplorerPreviewLoader().read(root: root, node: node)) {
                XCTAssertEqual($0 as? MainframeExplorerPreviewError, .pathIdentityMismatch("a.txt"))
            }
        }
    }

    func testCachedFileReplacedBySymlinkIsRejectedAtReadTime() throws {
        try fixture { root in
            let file = root.appendingPathComponent("figure.png")
            try Data([1, 2]).write(to: file)
            let node = try XCTUnwrap(MainframeExplorerScanner().rootChildren(root: root).first)
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("other.png"))
            XCTAssertThrowsError(try MainframeExplorerPreviewLoader().read(root: root, node: node)) {
                XCTAssertEqual($0 as? MainframeExplorerError, .symbolicLinkTraversal("figure.png"))
            }
        }
    }

    func testIntermediateSymlinkIsRejectedEvenWhenItsTargetIsInsideRoot() throws {
        try fixture { root in
            let real = root.appendingPathComponent("real")
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
            try Data([1, 2]).write(to: real.appendingPathComponent("figure.png"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: real)
            let node = makeNode(root: root, path: "linked/figure.png")
            XCTAssertThrowsError(try MainframeExplorerPreviewLoader().read(root: root, node: node)) {
                XCTAssertEqual($0 as? MainframeExplorerError, .symbolicLinkTraversal("linked/figure.png"))
            }
        }
    }

    func testOutsideRootURLAndTraversalRelativePathAreRejected() throws {
        try fixture { root in
            let outside = root.deletingLastPathComponent().appendingPathComponent("figure.png")
            XCTAssertThrowsError(try MainframeExplorerPreviewLoader().read(root: root, node: makeNode(root: root, path: "figure.png", url: outside)))
            XCTAssertThrowsError(try MainframeExplorerPreviewLoader().read(root: root, node: makeNode(root: root, path: "../figure.png"))) {
                XCTAssertEqual($0 as? MainframeExplorerError, .unsafePath("../figure.png"))
            }
        }
    }

    func testMissingFileIsUnavailableAndDirectoryCannotBeDecodedAsFile() throws {
        try fixture { root in
            let loader = MainframeExplorerPreviewLoader()
            XCTAssertThrowsError(try loader.read(root: root, node: makeNode(root: root, path: "missing.pdf"))) {
                guard case .unavailable? = $0 as? MainframeExplorerPreviewError else { return XCTFail("Missing file must be unavailable") }
            }
            try FileManager.default.createDirectory(at: root.appendingPathComponent("folder.pdf"), withIntermediateDirectories: false)
            XCTAssertThrowsError(try loader.read(root: root, node: makeNode(root: root, path: "folder.pdf"))) {
                XCTAssertEqual($0 as? MainframeExplorerError, .notFile("folder.pdf"))
            }
        }
    }

    func testReadLimitAllowsExactLimitAndRejectsOneExtraByte() throws {
        try fixture { root in
            try Data([1, 2, 3, 4]).write(to: root.appendingPathComponent("figure.png"))
            let node = makeNode(root: root, path: "figure.png")
            let loader = MainframeExplorerPreviewLoader()
            XCTAssertEqual(try loader.read(root: root, node: node, maxBytes: 4).count, 4)
            XCTAssertThrowsError(try loader.read(root: root, node: node, maxBytes: 3)) {
                XCTAssertEqual($0 as? MainframeExplorerError, .fileTooLarge(path: "figure.png", bytes: 4, limit: 3))
            }
        }
    }

    func testBinaryUnderTextExtensionCannotBecomeGarbageText() throws {
        try fixture { root in
            let node = makeNode(root: root, path: "payload.txt")
            try Data([65, 0, 66]).write(to: node.url)
            XCTAssertThrowsError(try MainframeExplorerPreviewLoader().readUTF8Text(root: root, node: node)) {
                XCTAssertEqual($0 as? MainframeExplorerPreviewError, .binaryText("payload.txt"))
            }
            try Data([255, 254]).write(to: node.url)
            XCTAssertThrowsError(try MainframeExplorerPreviewLoader().readUTF8Text(root: root, node: node)) {
                XCTAssertEqual($0 as? MainframeExplorerError, .nonUTF8("payload.txt"))
            }
        }
    }

    func testOrdinaryUnicodeTextRetainsItsExactLineEndings() throws {
        try fixture { root in
            let text = "# Héllo\r\n\t世界\n"
            let node = makeNode(root: root, path: "notes.md")
            try Data(text.utf8).write(to: node.url)
            XCTAssertEqual(try MainframeExplorerPreviewLoader().readUTF8Text(root: root, node: node), text)
        }
    }

    func testSymlinkRootIsRejected() throws {
        try fixture { root in
            let alias = root.appendingPathComponent("root-link")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            XCTAssertThrowsError(try MainframeExplorerPreviewLoader().read(root: alias, node: makeNode(root: alias, path: "missing.pdf"))) {
                XCTAssertEqual($0 as? MainframeExplorerError, .symbolicLinkTraversal(alias.path))
            }
        }
    }

    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-preview-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func makeNode(root: URL, path: String, url: URL? = nil) -> MainframeExplorerNode {
        MainframeExplorerNode(name: URL(fileURLWithPath: path).lastPathComponent, relativePath: path,
            url: url ?? root.appendingPathComponent(path), kind: .file, zone: .system, recordScope: nil)
    }

    func testDirectoriesAndSymlinksDoNotBecomePreviewRoutes() {
        let directory = MainframeExplorerNode(
            name: "artifacts",
            relativePath: "artifacts",
            url: URL(fileURLWithPath: "/tmp/artifacts"),
            kind: .directory,
            zone: .system,
            recordScope: nil
        )
        let link = MainframeExplorerNode(
            name: "linked.pdf",
            relativePath: "linked.pdf",
            url: URL(fileURLWithPath: "/tmp/linked.pdf"),
            kind: .symbolicLink,
            zone: .system,
            recordScope: nil
        )

        XCTAssertEqual(MainframeExplorerPreviewRouter.route(for: directory), .none)
        XCTAssertEqual(MainframeExplorerPreviewRouter.route(for: link), .none)
    }

    private func route(_ name: String) -> MainframeExplorerPreviewRoute {
        MainframeExplorerPreviewRouter.route(
            for: MainframeExplorerNode(
                name: name,
                relativePath: "artifacts/\(name)",
                url: URL(fileURLWithPath: "/tmp").appendingPathComponent(name),
                kind: .file,
                zone: .system,
                recordScope: nil
            )
        )
    }
}
