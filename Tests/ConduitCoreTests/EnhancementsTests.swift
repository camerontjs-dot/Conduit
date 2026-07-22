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

final class WorkSessionEventTests: XCTestCase {
    private func sampleEvents() -> [WorkSessionEvent] {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            .started(sessionID: "s1", projectSlug: "conduit", projectTitle: "Conduit",
                     projectPath: "/tmp/p", objective: "Test receipts", at: t0),
            .terminalOutcome(agent: "Codex", title: "Build", exitCode: 0,
                             detached: false, live: false, at: t0.addingTimeInterval(1)),
            .gitSnapshot(summary: "branch: agent/test", at: t0.addingTimeInterval(2)),
            .closed(at: t0.addingTimeInterval(3))
        ]
    }

    func testEventLogRoundtripsAndDetectsInterruption() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = WorkSessionEventLog(directory: dir, sessionID: "s1")
        for event in sampleEvents().dropLast() {
            try log.append(event)
        }
        XCTAssertEqual(log.readEvents().count, 3)
        XCTAssertEqual(
            WorkSessionEventLog.interruptedLogs(in: dir).map { $0.url.resolvingSymlinksInPath() },
            [log.url.resolvingSymlinksInPath()]
        )
        try log.append(.closed(at: Date(timeIntervalSince1970: 1_700_000_003)))
        XCTAssertTrue(WorkSessionEventLog.interruptedLogs(in: dir).isEmpty)
    }

    func testRendersAppendOnlyReceiptWithEvidenceBoundary() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("20_live"), withIntermediateDirectories: true)

        let rendered = try XCTUnwrap(WorkSessionReceiptRenderer.render(events: sampleEvents()))
        let writer = WorkSessionReceiptWriter()
        let first = try writer.write(root: root, receipt: rendered)
        let second = try writer.write(root: root, receipt: rendered)

        XCTAssertNotEqual(first, second)
        let content = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(content.contains("observed exit code 0"))
        XCTAssertTrue(content.contains("Terminal prose is not treated as proof"))
        XCTAssertFalse(content.contains("## Recovery note"))
    }

    func testRecoveredReceiptCarriesRecoveryNote() throws {
        let events = sampleEvents().dropLast()
        let rendered = try XCTUnwrap(WorkSessionReceiptRenderer.render(events: Array(events), recovered: true))
        XCTAssertTrue(rendered.markdown.contains("## Recovery note"))
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
