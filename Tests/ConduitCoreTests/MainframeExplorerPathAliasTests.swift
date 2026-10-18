import Foundation
import XCTest
@testable import ConduitCore

final class MainframeExplorerPathAliasTests: XCTestCase {
    private let fm = FileManager.default

    func testDeletedLeafMatchesAcrossConfiguredAncestorAlias() throws {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let physicalParent = base.appendingPathComponent("physical", isDirectory: true)
        let physicalRoot = physicalParent.appendingPathComponent("root", isDirectory: true)
        let directory = physicalRoot.appendingPathComponent("nested", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let alias = base.appendingPathComponent("selected-alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: physicalParent)
        let selectedRoot = alias.appendingPathComponent("root", isDirectory: true)
        let file = directory.appendingPathComponent("deleted.txt")
        try Data("source".utf8).write(to: file)
        let scanner = MainframeExplorerScanner()
        for spelling in [physicalRoot, selectedRoot] {
            XCTAssertEqual(try scanner.readUTF8Text(root: selectedRoot, file: spelling.appendingPathComponent("nested/deleted.txt")), "source")
        }
        try fm.removeItem(at: file)
        XCTAssertTrue(fm.fileExists(atPath: directory.path))
        for spelling in [physicalRoot, selectedRoot] {
            XCTAssertThrowsError(try scanner.fileFacts(root: selectedRoot, item: spelling.appendingPathComponent("nested/deleted.txt"))) { error in
                XCTAssertEqual(error as? MainframeExplorerError, .missingPath("nested/deleted.txt"))
            }
        }
    }

    func testMacOSTemporaryRootSpellingsKeepMissingAndSymlinkBoundariesDistinct() throws {
        #if canImport(Darwin)
        let name = "conduit-alias-boundary-\(UUID().uuidString)"
        let physicalBase = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(name)
        let lexicalBase = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(name)
        let physicalRoot = physicalBase.appendingPathComponent("root", isDirectory: true)
        let lexicalRoot = lexicalBase.appendingPathComponent("root", isDirectory: true)
        let directory = physicalRoot.appendingPathComponent("20_live/new/nested", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: physicalBase) }
        let path = "20_live/new/nested/recovery.json"
        let file = physicalRoot.appendingPathComponent(path)
        try Data("source\r\n".utf8).write(to: file)
        let scanner = MainframeExplorerScanner()
        for root in [physicalRoot, lexicalRoot] {
            for spelling in [physicalRoot, lexicalRoot] {
                XCTAssertEqual(try scanner.fileFacts(root: root, item: spelling.appendingPathComponent(path)).relativePath, path)
                XCTAssertEqual(try scanner.readUTF8Text(root: root, file: spelling.appendingPathComponent(path)), "source\r\n")
            }
        }
        try fm.removeItem(at: file)
        XCTAssertTrue(fm.fileExists(atPath: directory.path))
        XCTAssertTrue(fm.fileExists(atPath: physicalRoot.path))
        try fm.createSymbolicLink(atPath: physicalRoot.appendingPathComponent("dangling").path, withDestinationPath: path)
        try fm.createSymbolicLink(atPath: physicalRoot.appendingPathComponent("inside").path, withDestinationPath: "20_live")
        let outside = physicalBase.appendingPathComponent("root-neighbor", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: physicalRoot.appendingPathComponent("outside"), withDestinationURL: outside)
        for root in [physicalRoot, lexicalRoot] {
            for spelling in [physicalRoot, lexicalRoot] {
                XCTAssertThrowsError(try scanner.fileFacts(root: root, item: spelling.appendingPathComponent(path))) { error in
                    XCTAssertEqual(error as? MainframeExplorerError, .missingPath(path))
                }
                for link in ["dangling", "inside", "outside"] {
                    let item = spelling.appendingPathComponent(link)
                    XCTAssertEqual(try scanner.fileFacts(root: root, item: item).kind, .symbolicLink)
                    XCTAssertThrowsError(try scanner.readUTF8Text(root: root, file: item)) { error in
                        XCTAssertEqual(error as? MainframeExplorerError, .symbolicLinkTraversal(link))
                    }
                    XCTAssertThrowsError(try scanner.children(root: root, directory: item)) { error in
                        XCTAssertEqual(error as? MainframeExplorerError, .symbolicLinkTraversal(link))
                    }
                    XCTAssertThrowsError(try scanner.fileFacts(root: root, item: item.appendingPathComponent("missing"))) { error in
                        XCTAssertEqual(error as? MainframeExplorerError, .symbolicLinkTraversal(link + "/missing"))
                    }
                }
            }
            XCTAssertThrowsError(try scanner.fileFacts(root: root, item: outside.appendingPathComponent("missing"))) { error in
                guard case MainframeExplorerError.unsafePath = error else {
                    return XCTFail("outside path was not refused: \(error)")
                }
            }
            let escape = ConduitFilesystemReadTool.observe(arguments: .object([
                "operation": .string("stat"), "path": .string("../root-neighbor/missing")
            ]), root: root)
            XCTAssertEqual(escape["status"] as? String, "outside_root")
            XCTAssertNil(escape["text"])
        }
        #else
        throw XCTSkip("Requires macOS /private/tmp and /tmp aliases")
        #endif
    }

    func testDanglingSymlinkRemainsVisibleAcrossCanonicalRootSpellingsAndOutsidePathsStayRejected() throws {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let physicalParent = base.appendingPathComponent("physical", isDirectory: true)
        let physicalRoot = physicalParent.appendingPathComponent("fixture", isDirectory: true)
        let physicalKnowledge = physicalRoot.appendingPathComponent("10_knowledge", isDirectory: true)
        let selectedRootAlias = base.appendingPathComponent("selected-root-alias", isDirectory: true)
        let outsideDirectory = base.appendingPathComponent("outside", isDirectory: true)

        try fm.createDirectory(at: physicalKnowledge, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: selectedRootAlias, withDestinationURL: physicalParent)
        defer { try? fm.removeItem(at: base) }

        let selectedRoot = selectedRootAlias.appendingPathComponent("fixture", isDirectory: true)
        let missingLink = physicalKnowledge.appendingPathComponent("missing-link.md")
        try fm.createSymbolicLink(
            atPath: missingLink.path,
            withDestinationPath: "missing-target.md"
        )
        let outsideLink = physicalKnowledge.appendingPathComponent("outside-link")
        try fm.createSymbolicLink(at: outsideLink, withDestinationURL: outsideDirectory)

        let scanner = MainframeExplorerScanner()

        // The selected root and a listed child may arrive with different path
        // spellings for the same physical ancestors. Canonicalize the existing
        // parent, but preserve the dangling link itself as an untraversed leaf.
        let children = try scanner.children(root: selectedRoot, directory: physicalKnowledge)
        let missingNode = try XCTUnwrap(children.first(where: { $0.name == "missing-link.md" }))
        XCTAssertEqual(missingNode.kind, .symbolicLink)
        XCTAssertEqual(missingNode.relativePath, "10_knowledge/missing-link.md")

        let missingInspection = try scanner.inspectSymbolicLink(root: selectedRoot, link: missingNode.url)
        XCTAssertEqual(missingInspection.linkPath, "10_knowledge/missing-link.md")
        XCTAssertEqual(missingInspection.rawTarget, "missing-target.md")
        XCTAssertEqual(missingInspection.location, .missing)
        XCTAssertNil(missingInspection.relativeTargetPath)

        let outsideNode = try XCTUnwrap(children.first(where: { $0.name == "outside-link" }))
        XCTAssertEqual(outsideNode.kind, .symbolicLink)
        let outsideInspection = try scanner.inspectSymbolicLink(root: selectedRoot, link: outsideNode.url)
        XCTAssertEqual(outsideInspection.location, .outsideRoot)
        XCTAssertNil(outsideInspection.relativeTargetPath)
        XCTAssertThrowsError(try scanner.children(root: selectedRoot, directory: outsideNode.url)) { error in
            guard case MainframeExplorerError.symbolicLinkTraversal = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        // Canonical equivalence must not broaden the content boundary itself.
        XCTAssertThrowsError(try scanner.children(root: selectedRoot, directory: outsideDirectory)) { error in
            guard case MainframeExplorerError.unsafePath = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
