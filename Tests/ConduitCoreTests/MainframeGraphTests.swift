import Foundation
import XCTest
@testable import ConduitCore

final class MainframeGraphTests: XCTestCase {
    private func fixture() -> MainframeGraphSnapshot {
        let root = URL(fileURLWithPath: "/mf")
        let a = MainframeMarkdownParser.parse("# A\n[to b](b.md)\n")
        let b = MainframeMarkdownParser.parse("# B\n[to c](c.md)\n")
        let c = MainframeMarkdownParser.parse("# C\n")
        let records = [
            MainframeDocumentRecord(path: "30_projects/demo/a.md", name: "a.md", zone: .projects, recordScope: nil, text: a.source, byteCount: a.source.utf8.count, markdown: a),
            MainframeDocumentRecord(path: "30_projects/demo/b.md", name: "b.md", zone: .projects, recordScope: nil, text: b.source, byteCount: b.source.utf8.count, markdown: b),
            MainframeDocumentRecord(path: "30_projects/demo/c.md", name: "c.md", zone: .projects, recordScope: nil, text: c.source, byteCount: c.source.utf8.count, markdown: c)
        ]
        let content = MainframeContentIndex(records: records, filesystemEntries: [], filesystemIndexTruncated: false, contentTruncated: false, bytesIndexed: 100, skippedNonText: 0, skippedTooLarge: 0)
        let metadata = MainframeLifecycleMetadata(title: "Demo")
        let lifecycleRecord = MainframeLifecycleRecord(
            slug: "demo",
            path: root.appendingPathComponent("30_projects/demo"),
            rootKind: .projects,
            recordType: .project,
            readmePath: root.appendingPathComponent("30_projects/demo/README.md"),
            coordinationPath: nil,
            metadata: metadata,
            coordinationMetadata: nil,
            lifecycleState: "active",
            stateSource: "README.md",
            wipClass: "product",
            issues: []
        )
        let lifecycle = MainframeLifecycleScan(records: [lifecycleRecord], issues: [], rootIssues: [])
        return MainframeGraphBuilder.build(root: root, content: content, lifecycle: lifecycle)
    }

    func testBuildSeparatesAuthoredLinksFromContainment() {
        let snapshot = fixture()
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .authoredLink }.count, 2)
        XCTAssertEqual(snapshot.edges.filter { $0.kind == .containment }.count, 3)
        XCTAssertEqual(snapshot.nodeByID["30_projects/demo"]?.kind, .project)
    }

    func testOrbitIsBoundedByDepth() {
        let snapshot = fixture()
        let one = MainframeGraphQuery.orbit(snapshot: snapshot, focusNodeID: "30_projects/demo/a.md", depth: 1)
        XCTAssertEqual(Set(one.nodes.map(\.id)), Set(["30_projects/demo/a.md", "30_projects/demo/b.md"]))
        let two = MainframeGraphQuery.orbit(snapshot: snapshot, focusNodeID: "30_projects/demo/a.md", depth: 2)
        XCTAssertEqual(Set(two.nodes.map(\.id)), Set(["30_projects/demo/a.md", "30_projects/demo/b.md", "30_projects/demo/c.md"]))
    }

    func testAtlasBoundsTotalNodesPerZoneIncludingWorkRecords() {
        let nodes = (1...3).map { index in
            MainframeGraphNode(
                id: "30_projects/p\(index)",
                label: "P\(index)",
                path: "30_projects/p\(index)",
                kind: .project,
                zone: .projects,
                isAuthoritative: true
            )
        }
        let snapshot = MainframeGraphSnapshot(nodes: nodes, edges: [], sourceMayBeIncomplete: false)
        let atlas = MainframeGraphQuery.atlas(snapshot: snapshot, maxNodesPerZone: 2)
        XCTAssertEqual(atlas.nodes.map(\.id), ["30_projects/p1", "30_projects/p2"])
    }

    func testPathfinderUsesAllowedExplicitEdges() {
        let snapshot = fixture()
        let path = MainframeGraphQuery.shortestPath(snapshot: snapshot, from: "30_projects/demo/a.md", to: "30_projects/demo/c.md")
        XCTAssertEqual(path?.nodes.map(\.id), ["30_projects/demo/a.md", "30_projects/demo/b.md", "30_projects/demo/c.md"])
        XCTAssertTrue(path?.edges.allSatisfy { $0.kind == .authoredLink } == true)
    }

    func testPathfinderHonorsVisitedNodeBoundDuringWideExpansion() {
        let nodes = ["source", "a", "b", "target"].map {
            MainframeGraphNode(id: $0, label: $0, path: $0, kind: .document, zone: .knowledge, isAuthoritative: true)
        }
        let edges = ["a", "b", "target"].map { target in
            MainframeGraphEdge(
                id: "source-\(target)",
                sourceID: "source",
                targetID: target,
                kind: .authoredLink,
                provenance: "fixture",
                isDirected: true
            )
        }
        let snapshot = MainframeGraphSnapshot(nodes: nodes, edges: edges, sourceMayBeIncomplete: false)
        XCTAssertNil(MainframeGraphQuery.shortestPath(snapshot: snapshot, from: "source", to: "target", maxVisited: 2))
        XCTAssertNotNil(MainframeGraphQuery.shortestPath(snapshot: snapshot, from: "source", to: "target", maxVisited: 4))
    }

    func testSemanticNominationsStayDistinctAndNonAuthoritative() {
        let snapshot = fixture()
        let augmented = MainframeGraphBuilder.addingSemanticNominations([
            MainframeSemanticNomination(sourcePath: "30_projects/demo/a.md", targetPath: "10_knowledge/related.md", label: "Related", provenance: "MindGraph nomination")
        ], to: snapshot)
        XCTAssertEqual(augmented.nodeByID["10_knowledge/related.md"]?.isAuthoritative, false)
        XCTAssertTrue(augmented.edges.contains { $0.kind == .semanticNomination && $0.provenance == "MindGraph nomination" })
    }

    func testTaskAssociationRequiresExistingScope() {
        let snapshot = fixture()
        let augmented = MainframeGraphBuilder.addingTaskAssociations([
            MainframeTaskAssociation(taskID: "T1", taskLabel: "Codex", scopePath: "30_projects/demo", provenance: "Conduit task binding")
        ], to: snapshot)
        XCTAssertEqual(augmented.nodeByID["task:T1"]?.kind, .task)
        XCTAssertTrue(augmented.edges.contains { $0.kind == .taskSessionAssociation })
    }
}
