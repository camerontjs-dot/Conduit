import Foundation
import XCTest
@testable import ConduitCore

final class MainframeWorkstationTests: XCTestCase {
    func testProjectionUsesDirectLifecycleFieldsAndObservedFactsOnly() throws {
        let root = URL(fileURLWithPath: "/mf")
        let metadata = MainframeLifecycleMetadata(
            title: "Demo",
            goal: "Ship reader",
            nextAction: "Test UI",
            updated: "2026-09-13",
            wipClass: "product",
            tags: ["swift", "ui"]
        )
        let record = MainframeLifecycleRecord(
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
        let scan = MainframeLifecycleScan(records: [record], issues: [], rootIssues: [])
        let fact = MainframeObservedWorkFact(scopePath: "30_projects/demo", kind: .taskCount, label: "Open tasks", value: "2", sourcePath: nil, authority: .observedRuntime)
        let projection = MainframeWorkstationBuilder.build(root: root, lifecycle: scan, observedFacts: [fact])
        let station = try XCTUnwrap(projection.projects.first)
        XCTAssertTrue(station.isAuthoritative)
        XCTAssertTrue(station.signals.contains { $0.kind == .lifecycleState && $0.authority == .lifecycleFile })
        XCTAssertTrue(station.signals.contains { $0.kind == .taskCount && $0.authority == .observedRuntime })
        XCTAssertFalse(station.signals.contains { $0.label == "Progress" })
    }

    func testChecklistCountsOnlyLiteralTaskItemsOutsideCodeFences() {
        let checklist = MainframeChecklistProjection.parse(markdown: """
        - [x] A
        - [ ] B
        ```md
        - [x] ignored
        ```
        * [X] C
        """)
        XCTAssertEqual(checklist.totalCount, 3)
        XCTAssertEqual(checklist.completedCount, 2)
        XCTAssertTrue(checklist.hasLiteralDenominator)
    }

    func testEvidenceTrailUsesObservedDatesWithoutInventingMissingDates() {
        let early = MainframeEvidenceEvent(id: "early", kind: .objective, title: "Objective", detail: nil, observedAt: Date(timeIntervalSince1970: 100), sourceLabel: "README", sourcePath: "README.md")
        let late = MainframeEvidenceEvent(id: "late", kind: .test, title: "Test", detail: nil, observedAt: Date(timeIntervalSince1970: 200), sourceLabel: "receipt", sourcePath: "receipt.md")
        let unknown = MainframeEvidenceEvent(id: "unknown", kind: .other, title: "Unknown time", detail: nil, observedAt: nil, sourceLabel: "source", sourcePath: nil)
        XCTAssertEqual(MainframeEvidenceTrail(events: [late, unknown, early]).events.map(\.id), ["early", "late", "unknown"])
    }

    func testAttentionProjectionMeansNavigationOnly() {
        let items = MainframeAttentionProjection.build(
            navigationPaths: ["30_projects/demo/a.md", "30_projects/demo/b.md", "10_knowledge/x.md"],
            scopePaths: ["30_projects/demo", "10_knowledge"],
            currentPath: "30_projects/demo/b.md",
            pinnedScopes: ["10_knowledge"]
        )
        XCTAssertEqual(items.first?.scopePath, "30_projects/demo")
        XCTAssertEqual(items.first?.visitCount, 2)
        XCTAssertEqual(items.first(where: { $0.scopePath == "10_knowledge" })?.isPinned, true)
    }
}
