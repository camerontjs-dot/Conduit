import Foundation
import XCTest
@testable import ConduitCore

final class MainframeExplorerPresentationTests: XCTestCase {
    private func node(
        _ path: String,
        kind: MainframeExplorerNodeKind,
        zone: MainframeExplorerZone? = nil
    ) -> MainframeExplorerNode {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let resolvedZone = zone ?? MainframeExplorerZone.classify(relativePath: path)
        return MainframeExplorerNode(
            name: name,
            relativePath: path,
            url: URL(fileURLWithPath: "/mf").appendingPathComponent(path),
            kind: kind,
            zone: resolvedZone,
            recordScope: MainframeExplorerRecordScope.derive(relativePath: path)
        )
    }

    func testLifecycleAndScopeFoldersReceiveDistinctPresentationKinds() {
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects", kind: .directory)), .projectsFolder)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("40_operations", kind: .directory)), .operationsFolder)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo", kind: .directory)), .projectFolder)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("40_operations/weekly", kind: .directory)), .operationFolder)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("10_knowledge", kind: .directory)), .knowledgeFolder)
    }

    func testCommonProjectFoldersAreClassifiedWithoutImplyingAuthority() {
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/Sources", kind: .directory)), .sourceFolder)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/Tests", kind: .directory)), .testFolder)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/docs", kind: .directory)), .documentationFolder)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/Resources", kind: .directory)), .assetFolder)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/.build", kind: .directory)), .generatedFolder)
        XCTAssertTrue(MainframeExplorerVisualKind.generatedFolder.isDeemphasized)
    }

    func testSourceTestConfigurationAndUnknownFilesStayDistinct() {
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/Sources/App.swift", kind: .file)), .sourceFile)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/Tests/AppTests.swift", kind: .file)), .testFile)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/config/settings.yaml", kind: .file)), .configurationFile)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/README.md", kind: .file)), .markdownFile)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/.gitignore", kind: .file)), .gitFile)
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/blob.xyz", kind: .file)), .unknownFile)
    }

    func testSymbolicLinkGetsPresentationKindWithoutTraversalMeaning() {
        XCTAssertEqual(MainframeExplorerVisualClassifier.classify(node("30_projects/demo/current", kind: .symbolicLink)), .symbolicLink)
    }

    func testTreeFilterMatchesNameOrPathDeterministically() {
        let entries = [
            node("30_projects/demo/Sources/App.swift", kind: .file),
            node("30_projects/demo/Tests/AppTests.swift", kind: .file),
            node("10_knowledge/notes.md", kind: .file),
        ]
        XCTAssertEqual(
            MainframeExplorerTreeFilter.matches(entries, query: "sources").map(\.relativePath),
            ["30_projects/demo/Sources/App.swift"]
        )
        XCTAssertEqual(
            MainframeExplorerTreeFilter.matches(entries, query: "App.swift").map(\.relativePath),
            ["30_projects/demo/Sources/App.swift"]
        )
        XCTAssertTrue(MainframeExplorerTreeFilter.matches(entries[2], query: "KNOWLEDGE"))
    }
}
