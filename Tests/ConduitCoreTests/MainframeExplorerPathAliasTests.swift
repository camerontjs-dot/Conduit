import Foundation
import XCTest
@testable import ConduitCore

final class MainframeExplorerPathAliasTests: XCTestCase {
    private let fm = FileManager.default

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
