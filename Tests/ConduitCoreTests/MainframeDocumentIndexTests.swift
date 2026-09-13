import Foundation
import XCTest
@testable import ConduitCore

final class MainframeDocumentIndexTests: XCTestCase {
    func testMarkdownParserBuildsHeadingsBlocksLinksAndFrontmatter() {
        let source = """
        ---
        title: Demo
        status: active
        ---
        # Hello World

        Paragraph with [local](notes/next.md#target).

        ## Target
        ## Target

        > quoted

        - alpha
        - beta

        | A | B |
        | --- | :---: |
        | x | y |

        ```swift
        [ignored](inside-code.md)
        ```
        """
        let document = MainframeMarkdownParser.parse(source)
        XCTAssertEqual(document.frontmatter["title"], "Demo")
        XCTAssertEqual(document.headings.map(\.id), ["hello-world", "target", "target-2"])
        XCTAssertEqual(document.links.map(\.target), ["notes/next.md#target"])
        XCTAssertTrue(document.blocks.contains { if case .table = $0 { return true }; return false })
        XCTAssertTrue(document.blocks.contains { if case .fencedCode(let language, _) = $0 { return language == "swift" }; return false })
    }

    func testLinkResolverRefusesEscapesAndMissingAnchorsWithoutGuessing() {
        let source = MainframeMarkdownParser.parse("# Source\n")
        let target = MainframeMarkdownParser.parse("# Target\n")
        let documents = [
            "30_projects/demo/README.md": source,
            "30_projects/demo/notes/target.md": target
        ]
        let known = Set(documents.keys)

        XCTAssertEqual(
            MainframeLinkResolver.resolve(
                sourcePath: "30_projects/demo/README.md",
                target: "notes/target.md#target",
                documents: documents,
                knownPaths: known
            ),
            .local(path: "30_projects/demo/notes/target.md", anchor: "target")
        )
        XCTAssertEqual(
            MainframeLinkResolver.resolve(
                sourcePath: "README.md",
                target: "../outside.md",
                documents: documents,
                knownPaths: known
            ),
            .unresolved("target escapes MainFrame root")
        )
        XCTAssertEqual(
            MainframeLinkResolver.resolve(
                sourcePath: "30_projects/demo/README.md",
                target: "notes/target.md#missing",
                documents: documents,
                knownPaths: known
            ),
            .unresolved("target heading anchor not found")
        )
    }

    func testLinkIndexKeepsIncomingOutgoingAndUnresolvedSeparate() {
        let source = MainframeMarkdownParser.parse("[good](b.md) [bad](missing.md)\n")
        let target = MainframeMarkdownParser.parse("# B\n")
        let index = MainframeLinkIndex.build(documents: ["a.md": source, "b.md": target])
        XCTAssertEqual(index.outgoing["a.md"]?.count, 2)
        XCTAssertEqual(index.incoming["b.md"]?.count, 1)
        XCTAssertEqual(index.unresolved.count, 1)
    }

    func testTextSearchIsDeterministicAndPreservesIncompleteReceipt() {
        let document = MainframeMarkdownParser.parse("# Needle Heading\nneedle body\n")
        let record = MainframeDocumentRecord(
            path: "10_knowledge/demo.md",
            name: "demo.md",
            zone: .knowledge,
            recordScope: nil,
            text: document.source,
            byteCount: document.source.utf8.count,
            markdown: document
        )
        let index = MainframeContentIndex(
            records: [record],
            filesystemEntries: [],
            filesystemIndexTruncated: false,
            contentTruncated: true,
            bytesIndexed: record.byteCount,
            skippedNonText: 0,
            skippedTooLarge: 0
        )
        let result = MainframeTextSearch.search(index, query: "needle")
        XCTAssertEqual(result.hits.first?.kind, .heading)
        XCTAssertTrue(result.mayBeIncomplete)
    }

    func testContentIndexerIsBoundedReadOnlyAndSkipsSymlinksAndBinary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-doc-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let knowledge = root.appendingPathComponent("10_knowledge")
        try FileManager.default.createDirectory(at: knowledge, withIntermediateDirectories: true)
        try "# Demo\nneedle\n".write(to: knowledge.appendingPathComponent("demo.md"), atomically: true, encoding: .utf8)
        try Data([0xff, 0xfe, 0xfd]).write(to: knowledge.appendingPathComponent("binary.bin"))
        try FileManager.default.createSymbolicLink(
            at: knowledge.appendingPathComponent("escape-link"),
            withDestinationURL: URL(fileURLWithPath: "/tmp")
        )

        let index = try MainframeContentIndexer(maxEntries: 50, maxFileBytes: 32_000, maxTotalBytes: 64_000).build(root: root)
        XCTAssertEqual(index.records.map(\.path), ["10_knowledge/demo.md"])
        XCTAssertEqual(index.skippedNonText, 1)
        XCTAssertTrue(index.filesystemEntries.contains { $0.kind == .symbolicLink })
    }

    func testRecentNavigationIsUniqueAndBounded() {
        var recent = MainframeRecentNavigation(limit: 2)
        recent.note("a")
        recent.note("b")
        recent.note("a")
        recent.note("c")
        XCTAssertEqual(recent.paths, ["c", "a"])
    }
}
