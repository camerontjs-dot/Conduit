import Foundation
import XCTest
@testable import ConduitCore

final class FrontmatterParserTests: XCTestCase {
    func testParsesMainframeProjectMetadata() {
        let markdown = """
        ---
        title: "Image Generation Lab"
        domain: "creative systems"
        type: "project"
        status: "active"
        project_state: "active"
        goal: "Build a local image workflow"
        next_action: "Test memory governor"
        updated: "2026-07-20"
        tags: ["images", "agents"]
        ---
        # Image Generation Lab
        """

        let result = FrontmatterParser.parse(markdown, fallbackTitle: "Fallback")
        XCTAssertEqual(result.title, "Image Generation Lab")
        XCTAssertEqual(result.projectState, "active")
        XCTAssertEqual(result.nextAction, "Test memory governor")
        XCTAssertEqual(result.tags, ["images", "agents"])
    }

    func testFallsBackToHeading() {
        let result = FrontmatterParser.parse("# A Plain Project\n", fallbackTitle: "Fallback")
        XCTAssertEqual(result.title, "A Plain Project")
    }
}

final class ProjectNavigationTests: XCTestCase {
    private func project(
        title: String = "Conduit",
        slug: String = "conduit",
        state: String? = "active",
        nextAction: String? = "Finish native smoke",
        isRoot: Bool = false
    ) -> MainframeProject {
        MainframeProject(
            slug: slug,
            path: URL(fileURLWithPath: isRoot ? "/tmp/MainFrame" : "/tmp/MainFrame/30_projects/\(slug)"),
            readmePath: nil,
            metadata: ProjectMetadata(
                title: title,
                projectState: state,
                nextAction: nextAction,
                tags: ["macOS", "agents"]
            ),
            isMainframeRoot: isRoot
        )
    }

    func testSearchUsesAuthorityMetadataWithoutMutatingIt() {
        let value = project()
        XCTAssertTrue(ProjectNavigation.matches(value, query: "native smoke"))
        XCTAssertTrue(ProjectNavigation.matches(value, query: "MACOS"))
        XCTAssertFalse(ProjectNavigation.matches(value, query: "finance"))
        XCTAssertEqual(value.metadata.projectState, "active")
    }

    func testActiveGroupingRecognizesExplicitStatesOnly() {
        XCTAssertTrue(ProjectNavigation.isActive(project(state: "in_progress")))
        XCTAssertFalse(ProjectNavigation.isActive(project(state: "parked")))
        XCTAssertFalse(ProjectNavigation.isActive(project(state: "active", isRoot: true)))
    }
}

final class SettingsStoreTests: XCTestCase {
    func testSnapshotLoadsPersistedRootWithoutActorHop() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let directory = home.appendingPathComponent(".conduit")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = home.appendingPathComponent("Desktop/MainFrame")
        let bookmark = Data([0x43, 0x4E, 0x44, 0x54])
        let settings = ConduitSettings(
            mainframeRoot: root,
            mainframeRootBookmark: bookmark,
            showContextByDefault: false
        )
        try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("config.json"))

        let loaded = SettingsStore.loadSnapshot(home: home)
        XCTAssertEqual(loaded.mainframeRoot, root)
        XCTAssertEqual(loaded.mainframeRootBookmark, bookmark)
        XCTAssertFalse(loaded.showContextByDefault)
    }
}

final class AgentSpriteResolverTests: XCTestCase {
    func testResolvesOnlyKnownCopiedIdentities() {
        XCTAssertEqual(
            AgentSpriteResolver.resolve(AgentProfile(name: "Codex", command: "codex")),
            AgentSpriteResolution(skin: .codex, isExactMatch: true)
        )
        XCTAssertEqual(
            AgentSpriteResolver.resolve(AgentProfile(name: "Claude Code", command: "/opt/bin/claude")),
            AgentSpriteResolution(skin: .claude, isExactMatch: true)
        )
    }

    func testUnmatchedProfilesReceiveHonestGenericFallback() {
        for profile in [
            AgentProfile(name: "Shell", command: "/bin/zsh", kind: .shell),
            AgentProfile(name: "Gemini", command: "gemini"),
            AgentProfile(name: "Codexish", command: "custom-agent")
        ] {
            XCTAssertEqual(
                AgentSpriteResolver.resolve(profile),
                AgentSpriteResolution(skin: nil, isExactMatch: false)
            )
        }
    }
}

final class MainframeScannerTests: XCTestCase {
    func testDiscoversRootAndProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("00_inbox"), withIntermediateDirectories: true)
        let project = root.appendingPathComponent("30_projects/conduit")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "# MainFrame".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try """
        ---
        title: "Conduit"
        project_state: "active"
        goal: "Operate MainFrame"
        next_action: "Build"
        ---
        """.write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let projects = try MainframeScanner().scan(root: root)
        XCTAssertEqual(projects.count, 2)
        XCTAssertTrue(projects[0].isMainframeRoot)
        XCTAssertEqual(projects[1].metadata.title, "Conduit")
    }
}

final class InboxWriterTests: XCTestCase {
    func testCaptureIsNonDestructiveAndIncludesProjectProvenance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("00_inbox"), withIntermediateDirectories: true)

        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let writer = InboxWriter(now: { fixed })
        let project = MainframeProject(
            slug: "conduit",
            path: root.appendingPathComponent("30_projects/conduit"),
            readmePath: nil,
            metadata: ProjectMetadata(title: "Conduit")
        )

        let first = try writer.capture(root: root, project: project, text: "Remember this decision", attachments: [])
        let second = try writer.capture(root: root, project: project, text: "Remember this decision", attachments: [])
        XCTAssertNotEqual(first, second)
        let content = try String(contentsOf: first)
        XCTAssertTrue(content.contains("conduit://project/conduit"))
        XCTAssertTrue(content.contains("Remember this decision"))
    }
}

final class PromptAssemblerTests: XCTestCase {
    func testAddsAttachmentPathsWithoutChangingFiles() {
        let attachments = [
            Attachment(url: URL(fileURLWithPath: "/tmp/diagram.png")),
            Attachment(url: URL(fileURLWithPath: "/tmp/design.md"))
        ]
        let result = PromptAssembler.assemble(text: "Review these", attachments: attachments)
        XCTAssertTrue(result.contains("Review these"))
        XCTAssertTrue(result.contains("/tmp/diagram.png"))
        XCTAssertTrue(result.contains("/tmp/design.md"))
    }
}
