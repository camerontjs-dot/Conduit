import Foundation
import XCTest
@testable import ConduitCore

final class ContextBundleBuilderTests: XCTestCase {
    func testBuildsLabeledBundleFromProjectFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plans"), withIntermediateDirectories: true)
        let readme = root.appendingPathComponent("README.md")
        try "# Project\nImportant context".write(to: readme, atomically: true, encoding: .utf8)
        try "# Decisions\nUse evidence.".write(to: root.appendingPathComponent("decisions.md"), atomically: true, encoding: .utf8)
        let project = MainframeProject(slug: "project", path: root, readmePath: readme, metadata: ProjectMetadata(title: "Project"))

        let builder = ContextBundleBuilder()
        let candidates = builder.candidates(for: project)
        let bundle = builder.assemble(documents: candidates)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(bundle.markdown.contains("Trust label"))
        XCTAssertTrue(bundle.markdown.contains("Important context"))
        XCTAssertTrue(bundle.markdown.contains("Use evidence"))
    }
}

final class WorkSessionReceiptWriterTests: XCTestCase {
    func testWritesAppendOnlyReceiptWithEvidenceBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("20_live"), withIntermediateDirectories: true)
        let project = MainframeProject(slug: "conduit", path: root, readmePath: nil, metadata: ProjectMetadata(title: "Conduit"))
        let receipt = WorkSessionReceipt(
            project: project,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_100),
            objective: "Test receipts",
            outcomes: [SessionOutcome(agentName: "Codex", terminalTitle: "Build", exitCode: 0, detached: false)],
            gitSummary: "branch: agent/test",
            operatorNotes: "Manual review still required."
        )
        let writer = WorkSessionReceiptWriter()
        let first = try writer.write(root: root, receipt: receipt)
        let second = try writer.write(root: root, receipt: receipt)

        XCTAssertNotEqual(first, second)
        let content = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(content.contains("observed exit code 0"))
        XCTAssertTrue(content.contains("Terminal prose is not treated as proof"))
    }
}

final class TerminalForwarderTests: XCTestCase {
    func testWrapsSelectionWithVerificationBoundary() {
        let prompt = TerminalForwarder.prompt(selection: "Done!", sourceAgent: "Claude", destinationAgent: "Codex")
        XCTAssertTrue(prompt.contains("unverified terminal output"))
        XCTAssertTrue(prompt.contains("Re-run deterministic checks"))
        XCTAssertTrue(prompt.contains("Done!"))
    }
}
