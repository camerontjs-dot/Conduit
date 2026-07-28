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

    func testFirstMatchPreservesScannerOrderForKeyboardSelection() {
        let first = project(title: "Conduit Alpha", slug: "conduit-alpha")
        let second = project(title: "Conduit Beta", slug: "conduit-beta")
        let unrelated = project(title: "Image Lab", slug: "image-lab")

        XCTAssertEqual(
            ProjectNavigation.firstMatch(
                in: [unrelated, first, second],
                query: "conduit"
            )?.id,
            first.id
        )
        XCTAssertNil(
            ProjectNavigation.firstMatch(
                in: [unrelated, first, second],
                query: "finance"
            )
        )
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
            AgentProfile(name: "Antigravity", command: "agy"),
            AgentProfile(name: "Grok", command: "grok"),
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

final class PaletteSpecTests: XCTestCase {
    func testCaseOrderAndProductDefault() {
        XCTAssertEqual(
            PaletteID.allCases.map(\.rawValue),
            ["harbor", "sage", "clay", "heather", "phosphor"]
        )
        XCTAssertEqual(PaletteID.allCases.count, 5)
        XCTAssertEqual(PaletteID.productDefault, .harbor)
        XCTAssertEqual(PaletteID.allCases.first, .harbor)
        XCTAssertEqual(PaletteID.allBaseVariants.count, 10)
    }

    func testAllTenBaseVariantsMatchSignedOffTable() {
        let expected: [(PaletteID, PaletteVariant, PaletteBaseTokens)] = [
            (.harbor, .light, PaletteBaseTokens(
                accent: "#456881", onAccent: "#FFFFFF", ink: "#35566D",
                canvas: "#F2F5F7", app: "#E4E9ED", rail: "#EBEFF2",
                surface: "#FCFDFE", sink: "#DFE5EA", text: "#232A31",
                dim: "#5C6772", faint: "#93A0AB",
                shade: PaletteShade(red: 30, green: 48, blue: 62), soft: true
            )),
            (.harbor, .dark, PaletteBaseTokens(
                accent: "#7FA8C8", onAccent: "#0D1417", ink: "#A3C4DD",
                canvas: "#0F1417", app: "#141A1E", rail: "#192025",
                surface: "#1E262B", sink: "#131A1E", text: "#E1E6EA",
                dim: "#93A0AA", faint: "#64707A", shade: nil, soft: true
            )),
            (.sage, .light, PaletteBaseTokens(
                accent: "#4F6B49", onAccent: "#FFFFFF", ink: "#3F5740",
                canvas: "#F5F3EC", app: "#E9EBE2", rail: "#EEF0E7",
                surface: "#FCFCF8", sink: "#E4E7DC", text: "#2A2E27",
                dim: "#626B5D", faint: "#98A08D",
                shade: PaletteShade(red: 40, green: 50, blue: 32), soft: true
            )),
            (.sage, .dark, PaletteBaseTokens(
                accent: "#8FB183", onAccent: "#14180F", ink: "#A9C99E",
                canvas: "#141A15", app: "#191E1A", rail: "#1E241F",
                surface: "#232924", sink: "#171C18", text: "#E4E7DD",
                dim: "#9AA393", faint: "#6B7365", shade: nil, soft: true
            )),
            (.clay, .light, PaletteBaseTokens(
                accent: "#97583E", onAccent: "#FFFFFF", ink: "#7C4530",
                canvas: "#F5F0E9", app: "#EAE1D6", rail: "#F0E8DD",
                surface: "#FDFBF7", sink: "#E5DBCD", text: "#2E2620",
                dim: "#6D6055", faint: "#A0917F",
                shade: PaletteShade(red: 60, green: 42, blue: 28), soft: true
            )),
            (.clay, .dark, PaletteBaseTokens(
                accent: "#CB8A6E", onAccent: "#17120E", ink: "#E0A888",
                canvas: "#17120E", app: "#1D1712", rail: "#221B15",
                surface: "#271F18", sink: "#1A140F", text: "#EAE2D8",
                dim: "#A3958A", faint: "#736659", shade: nil, soft: true
            )),
            (.heather, .light, PaletteBaseTokens(
                accent: "#635B8C", onAccent: "#FFFFFF", ink: "#4F4874",
                canvas: "#F4F3F7", app: "#E7E5EE", rail: "#EDEBF3",
                surface: "#FCFCFE", sink: "#E2E0EB", text: "#2A2833",
                dim: "#625D70", faint: "#9A94A8",
                shade: PaletteShade(red: 40, green: 36, blue: 58), soft: true
            )),
            (.heather, .dark, PaletteBaseTokens(
                accent: "#A79FCE", onAccent: "#141318", ink: "#C3BCE0",
                canvas: "#141318", app: "#1A181F", rail: "#201E27",
                surface: "#26232E", sink: "#18161D", text: "#E5E2EC",
                dim: "#9D97AC", faint: "#6D6879", shade: nil, soft: true
            )),
            (.phosphor, .light, PaletteBaseTokens(
                accent: "#C97A16", onAccent: "#241A08", ink: "#8A5410",
                canvas: "#FAF8F4", app: "#ECE7DE", rail: "#F4F0E8",
                surface: "#FFFFFF", sink: "#E7E1D6", text: "#221E18",
                dim: "#6C665B", faint: "#9C9488",
                shade: PaletteShade(red: 40, green: 32, blue: 20), soft: false
            )),
            (.phosphor, .dark, PaletteBaseTokens(
                accent: "#E8A13B", onAccent: "#201603", ink: "#F2BE6E",
                canvas: "#0B0E0C", app: "#101311", rail: "#181B18",
                surface: "#1E221F", sink: "#121614", text: "#E7E3DA",
                dim: "#9B978C", faint: "#6B675E", shade: nil, soft: false
            )),
        ]

        for (id, variant, tokens) in expected {
            XCTAssertEqual(
                id.baseTokens(variant: variant),
                tokens,
                "\(id.rawValue) \(variant.rawValue)"
            )
        }
    }

    func testPhosphorAloneIsNonSoftAndShadePresence() {
        for id in PaletteID.allCases {
            let light = id.baseTokens(variant: .light)
            let dark = id.baseTokens(variant: .dark)
            XCTAssertNotNil(light.shade, "\(id.rawValue) light must carry shade")
            XCTAssertNil(dark.shade, "\(id.rawValue) dark must not carry shade")
            if id == .phosphor {
                XCTAssertFalse(light.soft)
                XCTAssertFalse(dark.soft)
            } else {
                XCTAssertTrue(light.soft)
                XCTAssertTrue(dark.soft)
            }
        }
    }

    func testMkDerivationAndShadowConstants() {
        XCTAssertEqual(PaletteMkConstants.accentSoftAlphaDark, 0.17)
        XCTAssertEqual(PaletteMkConstants.accentSoftAlphaLight, 0.13)
        XCTAssertEqual(PaletteMkConstants.softAccentGlowDark, 0.20)
        XCTAssertEqual(PaletteMkConstants.softAccentGlowLight, 0.13)
        XCTAssertEqual(PaletteMkConstants.nonSoftAccentGlowDark, 0.42)
        XCTAssertEqual(PaletteMkConstants.nonSoftAccentGlowLight, 0.30)
        XCTAssertEqual(PaletteMkConstants.lineDarkWhite, 0.10)
        XCTAssertEqual(PaletteMkConstants.lineLightShade, 0.13)
        XCTAssertEqual(PaletteMkConstants.lineSoftDarkWhite, 0.05)
        XCTAssertEqual(PaletteMkConstants.lineSoftLightShade, 0.06)
        XCTAssertEqual(PaletteMkConstants.softScanDarkWhite, 0.008)
        XCTAssertEqual(PaletteMkConstants.softScanLightShade, 0.006)
        XCTAssertEqual(PaletteMkConstants.nonSoftScanDarkWhite, 0.022)
        XCTAssertEqual(PaletteMkConstants.nonSoftScanLightShade, 0.015)
        XCTAssertEqual(PaletteMkConstants.desk1DarkeningDark, 0.35)
        XCTAssertEqual(PaletteMkConstants.desk1DarkeningLight, 0.05)
        XCTAssertEqual(PaletteMkConstants.desk2DarkeningDark, 0.15)
        XCTAssertEqual(PaletteMkConstants.desk2DarkeningLight, 0.13)
        XCTAssertEqual(
            PaletteMkConstants.shadowDark,
            "0 26px 70px -18px rgba(0,0,0,.7),0 2px 10px rgba(0,0,0,.5)"
        )
        XCTAssertEqual(
            PaletteMkConstants.shadowLight,
            "0 22px 60px -18px rgba(30,22,10,.3),0 2px 8px rgba(30,22,10,.1)"
        )
        XCTAssertEqual(
            PaletteMkConstants.popShadowDark,
            "0 18px 46px -8px rgba(0,0,0,.66)"
        )
        XCTAssertEqual(
            PaletteMkConstants.popShadowLight,
            "0 14px 40px -10px rgba(20,15,5,.3)"
        )
    }

    func testColorLiteralsAreNormalizedSixDigitHex() {
        let pattern = #"^#[0-9A-F]{6}$"#
        for entry in PaletteID.allBaseVariants {
            let t = entry.tokens
            for color in [
                t.accent, t.onAccent, t.ink, t.canvas, t.app,
                t.rail, t.surface, t.sink, t.text, t.dim, t.faint
            ] {
                XCTAssertNotNil(
                    color.range(of: pattern, options: .regularExpression),
                    "\(entry.id.rawValue) \(entry.variant.rawValue) color \(color)"
                )
            }
        }
    }
}
