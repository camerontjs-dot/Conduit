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

final class SessionPresentationTests: XCTestCase {
    func testConversationIsTheDefaultAndRawRemainsAvailable() {
        XCTAssertEqual(SessionSurface.productDefault, .conversation)
        XCTAssertEqual(SessionSurface.allCases, [.conversation, .raw])
        XCTAssertEqual(SessionSurface.allCases.map(\.displayName), ["Conversation", "Raw"])
        XCTAssertEqual(
            PromptDeliveryState.delivered.displayName,
            "Sent to terminal"
        )
    }

    func testOpeningEventIsConduitRecordedAndRoundTrips() throws {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let event = SessionPresentation.openingEvent(
            .resumed(
                agentName: "Codex",
                tmuxSessionName: "conduit-mainframe-codex",
                attachedElsewhere: true
            ),
            id: id,
            occurredAt: date
        )

        XCTAssertEqual(event.authority, .conduitRecorded)
        XCTAssertEqual(event.id, id)
        let data = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(SessionPresentationEvent.self, from: data), event)
    }

    func testPromptRetainsExactIngredientsAndStartsQueued() {
        let event = SessionPresentation.promptEvent(
            text: "Review this change",
            attachmentPaths: ["/tmp/example.swift"],
            renderedPayload: "Review this change\n\nAttachments:\n- /tmp/example.swift"
        )

        guard case .userPrompt(let prompt) = event.kind else {
            return XCTFail("Expected a user prompt event")
        }
        XCTAssertEqual(prompt.text, "Review this change")
        XCTAssertEqual(prompt.attachmentPaths, ["/tmp/example.swift"])
        XCTAssertEqual(
            prompt.renderedPayload,
            "Review this change\n\nAttachments:\n- /tmp/example.swift"
        )
        XCTAssertEqual(prompt.delivery, .queued)
        XCTAssertEqual(prompt.origin, .composer)
        XCTAssertEqual(event.authority, .conduitRecorded)
    }

    func testForwardedPromptPreservesUnverifiedTerminalOrigin() {
        let event = SessionPresentation.promptEvent(
            origin: .forwardedTerminalOutput(sourceAgentName: "Claude"),
            text: "selected terminal prose",
            attachmentPaths: [],
            renderedPayload: "Evidence boundary: this is unverified terminal output."
        )

        guard case .userPrompt(let prompt) = event.kind else {
            return XCTFail("Expected a user prompt event")
        }
        XCTAssertEqual(
            prompt.origin,
            .forwardedTerminalOutput(sourceAgentName: "Claude")
        )
        XCTAssertTrue(prompt.renderedPayload.contains("unverified terminal output"))
    }

    func testDeliveryReducerChangesOnlyMatchingPrompt() {
        let opened = SessionPresentation.openingEvent(
            .started(agentName: "Claude", requestedBackend: "direct PTY")
        )
        let first = SessionPresentation.promptEvent(
            text: "First",
            attachmentPaths: [],
            renderedPayload: "First"
        )
        let second = SessionPresentation.promptEvent(
            text: "Second",
            attachmentPaths: [],
            renderedPayload: "Second"
        )

        let updated = SessionPresentation.updatingPromptDelivery(
            in: [opened, first, second],
            eventID: first.id,
            to: .failed
        )

        XCTAssertEqual(updated[0], opened)
        XCTAssertEqual(updated[2], second)
        guard case .userPrompt(let prompt) = updated[1].kind else {
            return XCTFail("Expected the matching prompt to remain a prompt")
        }
        XCTAssertEqual(prompt.text, "First")
        XCTAssertEqual(prompt.delivery, .failed)

        let terminal = SessionPresentation.updatingPromptDelivery(
            in: updated,
            eventID: first.id,
            to: .delivered
        )
        XCTAssertEqual(terminal, updated, "A failed delivery must not later become delivered")
    }

    func testAgentOutputKeepsRawDerivedAuthorityAndStableTimelinePosition() {
        let promptID = UUID()
        let first = SessionPresentation.agentOutputEvent(
            promptEventID: promptID,
            text: "Working…",
            extraction: .renderedBuffer,
            truncated: false
        )
        let revised = SessionPresentation.agentOutputEvent(
            promptEventID: promptID,
            text: "Visible response",
            state: .settled,
            extraction: .renderedBuffer,
            truncated: false,
            id: first.id,
            occurredAt: first.occurredAt
        )

        let projected = SessionPresentation.upsertingAgentOutput(
            in: [first],
            event: revised
        )

        XCTAssertEqual(projected, [revised])
        XCTAssertEqual(revised.authority, .derivedFromRaw)
        guard case .agentOutput(let output) = revised.kind else {
            return XCTFail("Expected agent output")
        }
        XCTAssertEqual(output.promptEventID, promptID)
        XCTAssertEqual(output.state, .settled)
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

final class HostEnvelopeTests: XCTestCase {
    func testWrapPrependsHostBlockWithoutDroppingPrompt() {
        let wrapped = HostEnvelope.wrap(
            prompt: "say hello",
            context: HostEnvelope.Context(
                taskSessionID: "TASK-1",
                projectPath: "/Users/admin/Desktop/MainFrame",
                agentName: "Grok",
                surface: "conversation",
                tmuxSessionName: "conduit-mainframe-grok-1",
                attachmentCount: 1
            )
        )
        XCTAssertTrue(wrapped.hasPrefix("<<CONDUIT_HOST\n"))
        XCTAssertTrue(wrapped.contains("task: TASK-1"))
        XCTAssertTrue(wrapped.contains("agent: Grok"))
        XCTAssertTrue(wrapped.contains("attachments: 1"))
        XCTAssertTrue(wrapped.contains("not completion or verification"))
        XCTAssertTrue(wrapped.hasSuffix("say hello"))
    }

    func testShellAgentsDoNotInject() {
        let shell = AgentProfile(name: "Shell", command: "/bin/zsh", kind: .shell)
        let cli = AgentProfile(name: "Grok", command: "grok", kind: .cli)
        XCTAssertFalse(HostEnvelope.shouldInject(for: shell))
        XCTAssertTrue(HostEnvelope.shouldInject(for: cli))
    }
}

final class ConversationDisplayTextTests: XCTestCase {
    func testCompactDerivedCollapsesBlankRunsAndTrimsEdges() {
        let raw = "\n\n  line one  \n\n\n\nline two\n\n"
        let compact = ConversationDisplayText.compactDerived(raw)
        // Leading indentation is kept (TUI alignment); trailing spaces and
        // edge blank lines are removed; internal blank runs collapse to one.
        XCTAssertEqual(compact, "  line one\n\nline two")
    }

    func testWorkstationDerivedStripsSpinnerAndEscChrome() {
        let raw = """
        The framing that matters most.

        ⠋ Thinking…
        esc to interrupt
        ────────────
        ## Heading
        - bullet one
        """
        let text = ConversationDisplayText.workstationDerived(raw)
        XCTAssertTrue(text.contains("The framing that matters most."))
        XCTAssertTrue(text.contains("## Heading"))
        XCTAssertTrue(text.contains("- bullet one"))
        XCTAssertFalse(text.lowercased().contains("esc to interrupt"))
        XCTAssertFalse(text.contains("Thinking"))
    }

    func testWorkstationDerivedStripsOpenCodeSidePanelAndKeepsAnswer() {
        let raw = """
        | /cost
        |
        + Thought: 1.0s
        /cost is an opencode built-in — it displays this session's token usage and
        spend. There's no tool-side action needed from me; the command runs in the
        CLI interface.        Context
        20,926 tokens
        10% used
        $0.00 spent
        LSP
        LSPs are disabled
        Build · Big Pickle · 3.8s
        /Users/admin/Desktop/MainFrame
        """
        let text = ConversationDisplayText.workstationDerived(raw)
        XCTAssertTrue(text.contains("opencode built-in"))
        XCTAssertTrue(text.contains("CLI interface"))
        XCTAssertFalse(text.contains("Thought"))
        XCTAssertFalse(text.contains("LSPs are disabled"))
        XCTAssertFalse(text.contains("20,926"))
        XCTAssertFalse(text.contains("Build ·"))
        // Lone command echo dropped; answer prose kept.
        XCTAssertFalse(text.split(separator: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "/cost"
        }))
    }

    func testWorkstationDerivedFallsBackWhenOnlyChrome() {
        let raw = "esc to interrupt\n⠋ Working…"
        let text = ConversationDisplayText.workstationDerived(raw)
        // Avoid empty hole — compact form retained when scrub would erase all.
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testProseBlocksParseHeadingsBulletsAndCode() {
        let raw = """
        ## Title
        Intro paragraph.

        - one
        - two

        ```swift
        let x = 1
        ```
        """
        let blocks = ConversationDisplayText.proseBlocks(in: raw)
        XCTAssertEqual(blocks.count, 4)
        guard case .heading(let level, let title) = blocks[0] else {
            return XCTFail("expected heading")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(title, "Title")
        guard case .paragraph(let para) = blocks[1] else {
            return XCTFail("expected paragraph")
        }
        XCTAssertEqual(para, "Intro paragraph.")
        guard case .bullets(let items) = blocks[2] else {
            return XCTFail("expected bullets")
        }
        XCTAssertEqual(items, ["one", "two"])
        guard case .code(let language, let body) = blocks[3] else {
            return XCTFail("expected code")
        }
        XCTAssertEqual(language, "swift")
        XCTAssertEqual(body, "let x = 1")
    }
}

final class AgentSlashCatalogTests: XCTestCase {
    func testLooksLikeSlashCommandAcceptsCompact() {
        XCTAssertTrue(AgentSlashCatalog.looksLikeSlashCommand("/compact"))
        XCTAssertTrue(AgentSlashCatalog.looksLikeSlashCommand("  /model opus  "))
        XCTAssertFalse(AgentSlashCatalog.looksLikeSlashCommand("/Users/admin/file"))
        XCTAssertFalse(AgentSlashCatalog.looksLikeSlashCommand("hello"))
        XCTAssertFalse(AgentSlashCatalog.looksLikeSlashCommand("/"))
    }

    func testMatchesFiltersBuiltinByPrefix() {
        let hits = AgentSlashCatalog.matches(
            query: "/com",
            projectPath: nil
        )
        XCTAssertTrue(hits.contains(where: { $0.command == "/compact" }))
        XCTAssertFalse(hits.contains(where: { $0.command == "/help" }))
    }

    func testDiscoverSkillsFromMarkdownCommands() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-slash-\(UUID().uuidString)", isDirectory: true)
        let commands = dir.appendingPathComponent(".claude/commands", isDirectory: true)
        try FileManager.default.createDirectory(at: commands, withIntermediateDirectories: true)
        try "# My Skill\nDoes a thing.".write(
            to: commands.appendingPathComponent("my-skill.md"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let hits = AgentSlashCatalog.matches(
            query: "/my",
            projectPath: dir
        )
        XCTAssertTrue(hits.contains(where: { $0.command == "/my-skill" }))
    }
}

final class ConversationTurnGroupingTests: XCTestCase {
    func testGroupsPromptWithFollowingOutputs() {
        let open = SessionPresentation.openingEvent(
            .started(agentName: "Claude", requestedBackend: "tmux")
        )
        let prompt = SessionPresentation.promptEvent(
            text: "hello",
            attachmentPaths: [],
            renderedPayload: "hello"
        )
        let output = SessionPresentation.agentOutputEvent(
            promptEventID: prompt.id,
            text: "hi there",
            extraction: .tmuxPane,
            truncated: false
        )
        let turns = SessionPresentation.conversationTurns(
            from: [open, prompt, output]
        )
        XCTAssertEqual(turns.count, 2)
        guard case .boundary = turns[0].kind else {
            return XCTFail("expected boundary")
        }
        guard case .exchange(let user, let outputs) = turns[1].kind else {
            return XCTFail("expected exchange")
        }
        XCTAssertEqual(user?.id, prompt.id)
        XCTAssertEqual(outputs.count, 1)
        XCTAssertEqual(outputs[0].id, output.id)
    }
}

final class TerminalMenuParserTests: XCTestCase {
    func testParsesAntigravityStylePermissionMenu() {
        let text = """
        Allow creation of this file?
        > 1. Yes, allow creation
          2. No, deny creation
        ↑/↓ Navigate · tab Amend · f full diff
        esc to cancel
        """
        let options = TerminalMenuParser.options(in: text)
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0].key, "1")
        XCTAssertTrue(options[0].isSelected)
        XCTAssertEqual(options[0].label, "Yes, allow creation")
        XCTAssertEqual(options[1].key, "2")
        XCTAssertFalse(options[1].isSelected)
        XCTAssertTrue(TerminalMenuParser.looksLikeInteractiveMenu(text))
    }

    func testIgnoresSingleNumberedListItemWithoutMenuCues() {
        let text = "Notes:\n1. First point only"
        XCTAssertTrue(TerminalMenuParser.options(in: text).isEmpty)
    }
}

final class GitReviewParserTests: XCTestCase {
    func testParsesPorcelainRowsAndRenames() {
        let text = """
        M  Sources/App.swift
        ?? new.txt
        R  old.md -> docs/new.md
        """
        let entries = GitReviewParser.parsePorcelain(text)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].path, "Sources/App.swift")
        XCTAssertEqual(entries[1].path, "new.txt")
        XCTAssertEqual(entries[2].path, "docs/new.md")
    }

    func testDetectsAbsolutePaths() {
        let text = "Wrote /Users/admin/Desktop/MainFrame/00_inbox/note.md and ignored relative paths."
        let paths = ProjectedPathDetector.detectAbsolutePaths(in: text)
        XCTAssertTrue(paths.contains("/Users/admin/Desktop/MainFrame/00_inbox/note.md"))
    }
}

final class AgentPermissionModeTests: XCTestCase {
    func testAntigravityFullAutoInjectsSkipFlag() {
        let profile = AgentProfile(
            name: "Antigravity",
            command: "agy",
            permissionMode: .fullAuto
        )
        let args = AgentLaunchArguments.resolved(for: profile)
        XCTAssertTrue(args.contains("--dangerously-skip-permissions"))
    }

    func testAcceptEditsMergesModePairWithoutDuplicating() {
        let profile = AgentProfile(
            name: "Antigravity",
            command: "agy",
            arguments: ["--mode", "accept-edits"],
            permissionMode: .acceptEdits
        )
        let args = AgentLaunchArguments.resolved(for: profile)
        XCTAssertEqual(args.filter { $0 == "--mode" }.count, 1)
        XCTAssertEqual(args, ["--mode", "accept-edits"])
    }

    func testShellIgnoresPermissionModes() {
        let profile = AgentProfile(
            name: "Shell",
            command: "/bin/zsh",
            arguments: ["-l"],
            kind: .shell,
            permissionMode: .fullAuto
        )
        XCTAssertEqual(AgentLaunchArguments.resolved(for: profile), ["-l"])
        XCTAssertFalse(AgentLaunchArguments.supportsPermissionModes(profile))
    }

    func testLegacyAgentProfileJSONDecodesWithoutPermissionMode() throws {
        let json = """
        {"id":"1AF1D4E0-0000-4000-8000-0000000000A6","name":"Antigravity","command":"agy","arguments":[],"kind":"cli","enabled":true}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AgentProfile.self, from: json)
        XCTAssertEqual(profile.permissionMode, .agentDefault)
        XCTAssertEqual(profile.name, "Antigravity")
    }
}

final class AgentModelTests: XCTestCase {
    func testOllamaSelectionUsesRunAndPositionalModel() {
        let profile = AgentProfile(
            name: "Ollama",
            command: "ollama",
            arguments: ["--verbose"],
            model: "qwen3.5:9b",
            modelLaunchStyle: .ollamaRun
        )
        XCTAssertEqual(
            AgentLaunchArguments.resolved(for: profile),
            ["run", "qwen3.5:9b", "--verbose"]
        )
    }

    func testModelFlagReplacesAuthoredModelPair() {
        let profile = AgentProfile(
            name: "Cursor Agent",
            command: "cursor-agent",
            arguments: ["--model", "old-model", "--sandbox"],
            model: "new-model"
        )
        XCTAssertEqual(
            AgentLaunchArguments.resolved(for: profile),
            ["--sandbox", "--model", "new-model"]
        )
    }

    func testResearchBackedModelFlagProfilesResolveModel() {
        for (name, command) in [("Gemini CLI", "gemini"), ("Aider", "aider")] {
            let profile = AgentProfile(name: name, command: command, model: "model-id")
            XCTAssertEqual(
                AgentLaunchArguments.resolved(for: profile),
                ["--model", "model-id"],
                "\(name) should use the common model flag contract"
            )
        }
    }

    func testRecommendedProfilesContainResearchBackedCLIs() {
        XCTAssertEqual(
            Set(AgentProfile.recommendedCLIProfiles.map(\.command)),
            Set(["ollama", "cursor-agent", "gemini", "aider"])
        )
    }

    func testLegacyProfileRoundTripsWithUnknownModelFields() throws {
        let json = """
        {"id":"1AF1D4E0-0000-4000-8000-0000000000A6","name":"OpenCode","command":"opencode","arguments":[],"kind":"cli","enabled":true}
        """.data(using: .utf8)!
        let profile = try JSONDecoder().decode(AgentProfile.self, from: json)
        XCTAssertNil(profile.model)
        XCTAssertEqual(profile.modelLaunchStyle, .auto)
        XCTAssertNil(profile.contextWindowTokens)
    }

    func testVisibleContextEstimatorCountsComposerAndConversation() {
        let prompt = SessionPresentation.promptEvent(
            text: "Review the patch",
            attachmentPaths: ["/tmp/example.swift"],
            renderedPayload: "Review the patch"
        )
        let output = SessionPresentation.agentOutputEvent(
            promptEventID: prompt.id,
            text: "The visible response",
            extraction: .tmuxPane,
            truncated: false
        )
        let tokens = VisibleContextEstimator.visibleTokens(
            events: [prompt, output],
            composerText: "Next question"
        )
        XCTAssertGreaterThan(tokens, 0)
        XCTAssertEqual(
            VisibleContextEstimator.approximateTokens("1234"),
            1
        )
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
