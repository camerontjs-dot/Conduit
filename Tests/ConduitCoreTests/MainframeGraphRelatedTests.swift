import Foundation
import XCTest
@testable import ConduitCore

final class MainframeGraphRelatedTests: XCTestCase {
    private func node(_ id: String) -> MainframeGraphNode {
        MainframeGraphNode(
            id: id,
            label: id,
            path: id,
            kind: .document,
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
        let snapshot = MainframeGraphSnapshot(
            nodes: [node("focus")] + neighbors.map(node),
            edges: neighbors.map { edge("focus", $0) },
            sourceMayBeIncomplete: false
        )

        let related = MainframeGraphQuery.related(snapshot: snapshot, focusNodeID: "focus", maxNodes: 12)
        XCTAssertEqual(related.nodes.count, 12)
        XCTAssertTrue(related.nodes.contains { $0.id == "focus" })
        XCTAssertTrue(related.edges.allSatisfy { edge in
            related.nodes.contains { $0.id == edge.sourceID }
                && related.nodes.contains { $0.id == edge.targetID }
        })
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
}
