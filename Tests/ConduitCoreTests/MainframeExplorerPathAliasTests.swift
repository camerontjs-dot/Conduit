import Foundation
import XCTest
@testable import ConduitCore

final class MainframeExplorerPathAliasTests: XCTestCase {
    private let fm = FileManager.default

    func testDanglingSymlinkRemainsVisibleAcrossEquivalentRootSpellingsWithoutBroadeningAliases() throws {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let physicalParent = base.appendingPathComponent("physical", isDirectory: true)
        let physicalRoot = physicalParent.appendingPathComponent("fixture", isDirectory: true)
        let physicalKnowledge = physicalRoot.appendingPathComponent("10_knowledge", isDirectory: true)
        let selectedRootAlias = base.appendingPathComponent("selected-root-alias", isDirectory: true)
        let unrelatedAlias = base.appendingPathComponent("unrelated-alias", isDirectory: true)

        try fm.createDirectory(at: physicalKnowledge, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: selectedRootAlias, withDestinationURL: physicalParent)
        try fm.createSymbolicLink(at: unrelatedAlias, withDestinationURL: physicalRoot)
        defer { try? fm.removeItem(at: base) }

        let selectedRoot = selectedRootAlias.appendingPathComponent("fixture", isDirectory: true)
        let missingLink = physicalKnowledge.appendingPathComponent("missing-link.md")
        try fm.createSymbolicLink(
            atPath: missingLink.path,
            withDestinationPath: "missing-target.md"
        )

        let scanner = MainframeExplorerScanner()

        // Foundation may surface children through the resolved spelling of an
        // ancestor even when the operator selected the root through an alias.
        // That equivalent spelling must not make a dangling symlink disappear.
        let children = try scanner.children(root: selectedRoot, directory: physicalKnowledge)
        let node = try XCTUnwrap(children.first(where: { $0.name == "missing-link.md" }))
        XCTAssertEqual(node.kind, .symbolicLink)
        XCTAssertEqual(node.relativePath, "10_knowledge/missing-link.md")

        let inspection = try scanner.inspectSymbolicLink(root: selectedRoot, link: node.url)
        XCTAssertEqual(inspection.linkPath, "10_knowledge/missing-link.md")
        XCTAssertEqual(inspection.rawTarget, "missing-target.md")
        XCTAssertEqual(inspection.location, .missing)
        XCTAssertNil(inspection.relativeTargetPath)

        // Accepting the root's own resolved spelling must not authorize an
        // arbitrary third spelling supplied through a different symlink.
        let unrelatedKnowledge = unrelatedAlias.appendingPathComponent("10_knowledge", isDirectory: true)
        XCTAssertThrowsError(try scanner.children(root: selectedRoot, directory: unrelatedKnowledge)) { error in
            guard case MainframeExplorerError.unsafePath = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}
