import Foundation
import XCTest
@testable import ConduitCore

final class MainframeGraphRelatedTests: XCTestCase {
    private func node(
        _ id: String,
        kind: MainframeGraphNodeKind = .document,
        path: String? = nil
    ) -> MainframeGraphNode {
        MainframeGraphNode(
            id: id,
            label: id,
            path: path ?? id,
            kind: kind,
            zone: .projects,
            isAuthoritative: true
        )
    }

    private func edge(_ source: String, _ target: String, kind: MainframeGraphEdgeKind = .authoredLink) -> MainframeGraphEdge {
        MainframeGraphEdge(
            id: "\(kind.rawValue):\(source)->\(target)",
            sourceID: source,
            targetID: target,
            kind: kind,
            provenance: "fixture",
            isDirected: kind == .authoredLink
        )
    }

    func testRelatedIsOneHopEvenWhenSecondHopExists() {
        let snapshot = MainframeGraphSnapshot(
            nodes: [node("focus"), node("one"), node("two")],
            edges: [edge("focus", "one"), edge("one", "two")],
            sourceMayBeIncomplete: false
        )

        let related = MainframeGraphQuery.related(snapshot: snapshot, focusNodeID: "focus")
        XCTAssertEqual(Set(related.nodes.map(\.id)), Set(["focus", "one"]))
        XCTAssertEqual(related.focusNodeID, "focus")
    }

    func testRelatedCapsVisibleNodes() {
        let neighbors = (0..<40).map { "n\($0)" }
        let neighborNodes = neighbors.map { id in node(id) }
        let snapshot = MainframeGraphSnapshot(
            nodes: [node("focus")] + neighborNodes,
            edges: neighbors.map { edge("focus", $0) },
            sourceMayBeIncomplete: false
        )

        let related = MainframeGraphQuery.related(snapshot: snapshot, focusNodeID: "focus", maxNodes: 12)
        let relatedNodeIDs = Set(related.nodes.map(\.id))
        XCTAssertEqual(related.nodes.count, 12)
        XCTAssertTrue(relatedNodeIDs.contains("focus"))
        XCTAssertTrue(related.edges.allSatisfy { edge in
            relatedNodeIDs.contains(edge.sourceID)
                && relatedNodeIDs.contains(edge.targetID)
        })
    }

    func testRelatedDefaultIncludesContainmentAndTaskAssociationsButNotSemanticNominations() {
        let snapshot = MainframeGraphSnapshot(
            nodes: [node("focus"), node("authored"), node("parent"), node("task"), node("semantic")],
            edges: [
                edge("focus", "authored"),
                edge("focus", "parent", kind: .containment),
                edge("focus", "task", kind: .taskSessionAssociation),
                edge("focus", "semantic", kind: .semanticNomination),
            ],
            sourceMayBeIncomplete: false
        )

        let related = MainframeGraphQuery.related(snapshot: snapshot, focusNodeID: "focus")
        XCTAssertEqual(Set(related.nodes.map(\.id)), Set(["focus", "authored", "parent", "task"]))
        XCTAssertEqual(
            Set(related.edges.map(\.kind)),
            Set([.authoredLink, .containment, .taskSessionAssociation])
        )
    }

    func testRelatedUsesExplicitRelationshipClassesOnly() {
        let snapshot = MainframeGraphSnapshot(
            nodes: [node("focus"), node("authored"), node("semantic")],
            edges: [
                edge("focus", "authored"),
                edge("focus", "semantic", kind: .semanticNomination),
            ],
            sourceMayBeIncomplete: false
        )

        let defaultRelated = MainframeGraphQuery.related(snapshot: snapshot, focusNodeID: "focus")
        XCTAssertFalse(defaultRelated.nodes.contains { $0.id == "semantic" })

        let semanticRelated = MainframeGraphQuery.related(
            snapshot: snapshot,
            focusNodeID: "focus",
            allowedKinds: [.authoredLink, .semanticNomination]
        )
        XCTAssertTrue(semanticRelated.nodes.contains { $0.id == "semantic" })
    }

    func testSceneSignatureIgnoresInputOrderingButChangesWithRelationships() {
        let first = MainframeGraphScene(
            mode: .orbit,
            nodes: [node("b"), node("a")],
            edges: [edge("a", "b")],
            focusNodeID: "a",
            sourceMayBeIncomplete: false
        )
        let reordered = MainframeGraphScene(
            mode: .orbit,
            nodes: [node("a"), node("b")],
            edges: [edge("a", "b")],
            focusNodeID: "a",
            sourceMayBeIncomplete: false
        )
        XCTAssertEqual(MainframeGraphSceneSignature(scene: first), MainframeGraphSceneSignature(scene: reordered))

        let changed = MainframeGraphScene(
            mode: .orbit,
            nodes: [node("a"), node("b")],
            edges: [],
            focusNodeID: "a",
            sourceMayBeIncomplete: false
        )
        XCTAssertNotEqual(MainframeGraphSceneSignature(scene: first), MainframeGraphSceneSignature(scene: changed))
    }

    func testFocusResolverPrefersExactSourceBackedNode() {
        let snapshot = MainframeGraphSnapshot(
            nodes: [
                node("30_projects/demo", kind: .project),
                node("30_projects/demo/Sources/App.swift"),
            ],
            edges: [],
            sourceMayBeIncomplete: false
        )

        XCTAssertEqual(
            MainframeGraphFocusResolver.focusNodeID(
                selectedPath: "30_projects/demo/Sources/App.swift",
                snapshot: snapshot
            ),
            "30_projects/demo/Sources/App.swift"
        )
    }

    func testFocusResolverFallsBackToNearestContainingWorkScope() {
        let snapshot = MainframeGraphSnapshot(
            nodes: [
                node("30_projects", kind: .project, path: "30_projects"),
                node("30_projects/demo", kind: .project, path: "30_projects/demo"),
                node("30_projects/demo/subscope", kind: .operation, path: "30_projects/demo/subscope"),
            ],
            edges: [],
            sourceMayBeIncomplete: true
        )

        XCTAssertEqual(
            MainframeGraphFocusResolver.focusNodeID(
                selectedPath: "30_projects/demo/subscope/Sources/Skipped.swift",
                snapshot: snapshot
            ),
            "30_projects/demo/subscope"
        )
    }

    func testFocusResolverReturnsNilWhenSelectionHasNoGraphOrScopeIdentity() {
        let snapshot = MainframeGraphSnapshot(
            nodes: [node("30_projects/demo", kind: .project)],
            edges: [],
            sourceMayBeIncomplete: false
        )

        XCTAssertNil(
            MainframeGraphFocusResolver.focusNodeID(
                selectedPath: "10_knowledge/unindexed.bin",
                snapshot: snapshot
            )
        )
    }
}
