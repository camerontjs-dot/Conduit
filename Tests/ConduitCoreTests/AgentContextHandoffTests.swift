import XCTest
@testable import ConduitCore

final class AgentContextHandoffTests: XCTestCase {
    func testRendererPreservesAuthorityAndExactIdentity() {
        let source = AgentContextItem(
            id: "file",
            title: "SPEC",
            kind: .file,
            authority: .filesystemSource,
            sourceReference: "docs/SPEC.md",
            revisionIdentity: "abc123",
            isPinned: true,
            freshness: .current
        )
        let nomination = AgentContextItem(
            id: "semantic",
            title: "Related research",
            kind: .semanticNomination,
            authority: .mindGraphNomination,
            sourceReference: "10_knowledge/research.md",
            freshness: .unknown
        )
        let bundle = AgentContextBundle(
            taskTitle: "Review boundary",
            scopePath: "30_projects/conduit",
            repository: "/tmp/conduit",
            branch: "feat/context",
            commitSHA: "abc123",
            items: [source, nomination]
        )

        let rendered = AgentContextHandoffRenderer.render(
            AgentContextHandoff(
                destinationLabel: "Codex",
                sourceAgentLabel: "Claude",
                objective: "Review the exact candidate without expanding scope.",
                bundle: bundle
            )
        )

        XCTAssertTrue(rendered.contains("Destination: Codex"))
        XCTAssertTrue(rendered.contains("Prior worker: Claude"))
        XCTAssertTrue(rendered.contains("[filesystemSource] SPEC"))
        XCTAssertTrue(rendered.contains("`abc123`"))
        XCTAssertTrue(rendered.contains("[mindGraphNomination] Related research"))
        XCTAssertTrue(rendered.contains("nominations and agent output are context to inspect, not source truth"))
    }

    func testRendererIncludesExplicitContextDiff() {
        let previous = AgentContextBundle(
            taskTitle: "Task",
            items: [
                AgentContextItem(
                    id: "file",
                    title: "File",
                    kind: .file,
                    authority: .filesystemSource,
                    sourceReference: "File.swift",
                    revisionIdentity: "one"
                )
            ]
        )
        let current = AgentContextBundle(
            taskTitle: "Task",
            items: [
                AgentContextItem(
                    id: "file",
                    title: "File",
                    kind: .file,
                    authority: .filesystemSource,
                    sourceReference: "File.swift",
                    revisionIdentity: "two"
                ),
                AgentContextItem(
                    id: "receipt",
                    title: "Receipt",
                    kind: .testReceipt,
                    authority: .testReceipt,
                    sourceReference: "receipt.md"
                )
            ]
        )
        let diff = AgentContextDiffer.diff(previous: previous, current: current)
        let rendered = AgentContextHandoffRenderer.render(
            AgentContextHandoff(
                objective: "Continue",
                bundle: current,
                changesSinceLastHandoff: diff
            )
        )

        XCTAssertTrue(rendered.contains("ADDED: `receipt.md`"))
        XCTAssertTrue(rendered.contains("CHANGED: `File.swift`"))
    }
}
