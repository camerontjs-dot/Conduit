#if os(macOS)
import Foundation
import XCTest
import ConduitCore
@testable import Conduit

final class MindGraphPopulatedInspectionTests: XCTestCase {
    @MainActor
    func testRealInspectionPreservesPopulatedContextAndRecordedTask() async throws {
        guard ProcessInfo.processInfo.environment["CONDUIT_REPAIR88_APP_TESTS"] == "1" else {
            throw XCTSkip("Opt-in isolated-home AppModel test. Not a passing runtime qualification.")
        }
        // Check before AppModel initializes UserDefaults or other local state.
        let home = try AppModel.repair88RequireIsolatedHome()
        let root = home.appendingPathComponent("MainFrame")
        let projectPath = root.appendingPathComponent("30_projects/fixture")
        let project = MainframeProject(
            slug: "fixture", path: projectPath,
            readmePath: projectPath.appendingPathComponent("README.md"),
            metadata: ProjectMetadata(title: "Qualification fixture")
        )
        let first = ContextDocument(url: projectPath.appendingPathComponent("README.md"), label: "Pinned source", trustLabel: "fixture source")
        let extra = ContextDocument(url: projectPath.appendingPathComponent("AGENTS.md"), label: "Canary source", trustLabel: "fixture instruction")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.url.path))
        let model = AppModel()
        model.settings.mainframeRoot = root
        model.projects = [project]
        model.selectedProjectID = project.id
        model.contextCandidates = [first, extra]
        model.selectedContextIDs = [first.id]
        model.contextPreview = "Existing prepared handoff must survive inspection."
        model.composerText = "Existing unsent worker prompt."
        try model.repair88SeedRecordedTask(root: root)
        let baseline = try model.repair88ContextState()
        XCTAssertEqual(model.taskSessions.count, 1)
        XCTAssertFalse(model.selectedContextIDs.isEmpty)

        // Sensitivity control mutates the real context selection. It does not
        // send input, start a worker or mutate a disconnected test-only list.
        model.selectedContextIDs.insert(extra.id)
        XCTAssertNotEqual(try model.repair88ContextState(), baseline)
        model.selectedContextIDs.remove(extra.id)
        XCTAssertEqual(try model.repair88ContextState(), baseline)

        for _ in 0..<2 {
            let rows = try await model.inspectMindGraph(question: "binding fixture", scope: .knowledge, topK: 5).get()
            XCTAssertFalse(rows.isEmpty)
            XCTAssertTrue(rows.allSatisfy { $0.expansion != nil })
            XCTAssertEqual(try model.repair88ContextState(), baseline)
        }
        // The owned fixture wrapper calls the real candidate CLI normally.
        // This marker selects an exit-0 malformed producer response only for
        // expansion, exercising containment in the actual AppModel pipeline.
        let failure = home.appendingPathComponent(".repair88-fail-expansion")
        try Data("controlled defective producer".utf8).write(to: failure)
        defer { try? FileManager.default.removeItem(at: failure) }
        let failed = try await model.inspectMindGraph(question: "binding fixture", scope: .knowledge, topK: 5).get()
        XCTAssertFalse(failed.isEmpty)
        XCTAssertTrue(failed.allSatisfy { $0.expansion == nil && $0.expansionError != nil })
        XCTAssertEqual(try model.repair88ContextState(), baseline)
        XCTAssertTrue(model.sessions.isEmpty)
        // This test covers populated model context and a recorded task, not a
        // live provider's delivery queue, permissions or actual token usage.
    }
}
#endif
