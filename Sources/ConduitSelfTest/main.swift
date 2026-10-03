// Deterministic local verification for ConduitCore without XCTest, so the
// core can be checked on machines with Command Line Tools only:
//   swift run conduit-selftest
// CI still runs the full XCTest suite with Xcode.

import ConduitCore
import Dispatch
import Foundation

var passed = 0
var failures: [String] = []

func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    if condition() {
        passed += 1
        print("ok   \(name)")
    } else {
        failures.append(name)
        print("FAIL \(name)")
    }
}

func withTempDir(_ body: (URL) throws -> Void) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("conduit-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    do {
        try body(dir)
    } catch {
        failures.append("uncaught error: \(error)")
        print("FAIL uncaught error: \(error)")
    }
}

// MARK: - FrontmatterParser

let frontmatter = FrontmatterParser.parse("""
---
title: "Image Lab"
project_state: "active"
goal: "Build"
next_action: "Test"
tags: ["images", "agents"]
---
# Image Lab
""", fallbackTitle: "Fallback")
check("frontmatter parses title", frontmatter.title == "Image Lab")
check("frontmatter parses state", frontmatter.projectState == "active")
check("frontmatter parses tags", frontmatter.tags == ["images", "agents"])
check("frontmatter falls back to heading",
      FrontmatterParser.parse("# Plain\n", fallbackTitle: "F").title == "Plain")

check("workspace picker keeps Sessions, Explore, Orchestrate order",
      ConduitWorkspace.allCases.map(\.rawValue) == ["sessions", "explore", "orchestrate"])
check("Explore workspace display name",
      ConduitWorkspace.explore.displayName == "Explore")
check("Explore workspace symbol",
      ConduitWorkspace.explore.symbolName == "folder")
check("Sessions workspace presentation remains unchanged",
      ConduitWorkspace.sessions.displayName == "Sessions"
        && ConduitWorkspace.sessions.symbolName == "rectangle.3.group")
check("Orchestrate workspace presentation remains unchanged",
      ConduitWorkspace.orchestrate.displayName == "Orchestrate"
        && ConduitWorkspace.orchestrate.symbolName == "point.3.connected.trianglepath.dotted")

let orchestrationRoot = MainframeProject(
    slug: "mainframe",
    path: URL(fileURLWithPath: "/tmp/MainFrame"),
    readmePath: nil,
    metadata: ProjectMetadata(title: "MainFrame"),
    isMainframeRoot: true
)
check("orchestration selector keeps MainFrame root selectable",
      OrchestrationScopeSelection.selectedProject(
        explicitID: orchestrationRoot.id,
        currentSelection: nil,
        from: OrchestrationScopeSelection.selectableProjects(from: [orchestrationRoot])
      ) == orchestrationRoot)

let navigationProject = MainframeProject(
    slug: "conduit",
    path: URL(fileURLWithPath: "/tmp/MainFrame/30_projects/conduit"),
    readmePath: nil,
    metadata: ProjectMetadata(
        title: "Conduit",
        projectState: "active",
        nextAction: "Finish native smoke",
        tags: ["macOS", "agents"]
    )
)
check("project search uses authority metadata",
      ProjectNavigation.matches(navigationProject, query: "native smoke"))
check("project search is case insensitive",
      ProjectNavigation.matches(navigationProject, query: "MACOS"))
check("project active grouping uses explicit state",
      ProjectNavigation.isActive(navigationProject))
check("project search keyboard selection preserves scanner order",
      ProjectNavigation.firstMatch(
        in: [
            MainframeProject(
                slug: "other",
                path: URL(fileURLWithPath: "/tmp/MainFrame/30_projects/other"),
                readmePath: nil,
                metadata: ProjectMetadata(title: "Other")
            ),
            navigationProject
        ],
        query: "conduit"
      )?.id == navigationProject.id)
check("sprite mapping resolves Codex exactly",
      AgentSpriteResolver.resolve(AgentProfile(name: "Codex", command: "codex"))
        == AgentSpriteResolution(skin: .codex, isExactMatch: true))
check("sprite mapping resolves Claude executable exactly",
      AgentSpriteResolver.resolve(AgentProfile(name: "Claude Code", command: "/opt/bin/claude"))
        == AgentSpriteResolution(skin: .claude, isExactMatch: true))
check("sprite mapping keeps custom profiles generic",
      AgentSpriteResolver.resolve(AgentProfile(name: "Codexish", command: "custom-agent"))
        == AgentSpriteResolution(skin: nil, isExactMatch: false))
check("sprite mapping requires name and executable to agree",
      AgentSpriteResolver.resolve(AgentProfile(name: "Codex", command: "claude"))
        == AgentSpriteResolution(skin: nil, isExactMatch: false))
check("sprite filename contract contains the six canonical poses",
      AgentSpritePose.allCases.map(\.fileName) == [
        "clipboard.png",
        "magnifying-glass.png",
        "pointing-warning.png",
        "skeptical.png",
        "shrug.png",
        "sleeping-coffee.png"
      ])
check("terminal visual states bridge to truth-bound sprite cues",
      TerminalVisualState.allCases.map(\.spriteCue) == [
        .starting,
        .outputActive,
        .runningQuiet,
        .detached,
        .exited,
        .failed
      ])
let codexSpritePaths = AgentSpriteCatalog.requiredRelativePaths(for: .codex)
let completeCodexSprites = AgentSpriteResourceInventory(
    readableRelativePaths: Set(codexSpritePaths),
    manifestHashes: Dictionary(
        uniqueKeysWithValues: codexSpritePaths.map {
            ($0, String(repeating: "a", count: 64))
        }
    ),
    provenanceText: "`codex/`:"
)
check("complete manifested sprite set resolves atomically",
      AgentSpriteCatalog.artworkResolution(
        for: AgentProfile(name: "Codex", command: "codex"),
        inventory: completeCodexSprites
      ) == .dedicated(.codex))
check("partial sprite set falls back atomically",
      AgentSpriteCatalog.artworkResolution(
        for: AgentProfile(name: "Codex", command: "codex"),
        inventory: AgentSpriteResourceInventory(
            readableRelativePaths: Set(codexSpritePaths.dropLast()),
            manifestHashes: completeCodexSprites.manifestHashes,
            provenanceText: completeCodexSprites.provenanceText
        )
      ) == .genericPlaceholder(.incompleteSet))
check("sprite pose swaps stay immediate under Reduce Motion",
      !AgentSpriteMotionPolicy.shouldAnimatePoseChange(reduceMotion: true))
check("companion scale denser in Operator than Focused",
      CompanionScale.defaultFor(density: .operator).spriteSide
        > CompanionScale.defaultFor(density: .focused).spriteSide)
check("operator peek off by default in Focused",
      !OperatorPeekPolicy.defaultEnabled(for: .focused))
check("operator peek on by default in Operator density",
      OperatorPeekPolicy.defaultEnabled(for: .operator))
check("operator peek customized override wins",
      OperatorPeekPolicy.resolveEnabled(
        customized: true,
        storedEnabled: false,
        density: .operator
      ) == false)
check("next safe action open raw when attached runtime",
      SessionNextSafeAction.resolve(
        hasSelectedTask: true,
        hasOpenRuntime: true,
        isDetached: false,
        isReconnectableWithoutRuntime: false
      ) == .openRaw)
check("next safe action reconnect when detached",
      SessionNextSafeAction.resolve(
        hasSelectedTask: true,
        hasOpenRuntime: true,
        isDetached: true,
        isReconnectableWithoutRuntime: false
      ) == .reconnect)
check("juicy chrome respects Reduce Motion",
      !JuicyFeedbackPolicy.shouldPlayChromeMotion(
        juicyEnabled: true,
        reduceMotion: true
      ))
check("juicy chrome never animates poses",
      !JuicyFeedbackPolicy.shouldAnimatePoseChange())
check("empty inbox attention is honest",
      AgentInboxAttention.from(
        pinned: [],
        active: [],
        recent: [],
        archived: [],
        discoveredCount: 0
      ).summaryLine == "No tasks in this scope")
check("companion master resolves OpenCode by name",
      AgentCompanionMaster.resolve(
        for: AgentProfile(name: "OpenCode", command: "opencode")
      ) == .opencode)
check("companion master resolves Shell by executable",
      AgentCompanionMaster.resolve(
        for: AgentProfile(name: "Shell", command: "/bin/zsh", kind: .shell)
      ) == .localShell)
check("mid-session OpenCode opens /models picker sequence", {
    guard case .liveSequence(let steps, _) = AgentMidSessionModelPolicy.applyMode(
        for: AgentProfile(name: "OpenCode", command: "opencode"),
        modelID: "opencode/deepseek-v4-flash-free",
        hasLiveRuntime: true
    ) else { return false }
    // Prefer unique trailing segment as filter token.
    return steps.contains(.slashCommand("/models"))
        && steps.contains(.typeText("deepseek-v4-flash-free"))
}())
check("mid-session Codex opens /model picker when live", {
    guard case .liveSequence(let steps, _) = AgentMidSessionModelPolicy.applyMode(
        for: AgentProfile(name: "Codex", command: "codex"),
        modelID: "gpt-5.6-luna",
        hasLiveRuntime: true
    ) else { return false }
    return steps.contains(.slashCommand("/model"))
        && steps.contains(.typeText("gpt-5.6-luna"))
}())
check("mid-session Grok uses /model id when live", {
    guard case .liveSequence(let steps, _) = AgentMidSessionModelPolicy.applyMode(
        for: AgentProfile(name: "Grok", command: "grok"),
        modelID: "grok-4.5",
        hasLiveRuntime: true
    ) else { return false }
    return steps.contains(.slashCommand("/model grok-4.5"))
}())
check("mid-session Cursor still requires relaunch",
      AgentMidSessionModelPolicy.applyMode(
        for: AgentProfile(name: "Cursor Agent", command: "cursor-agent"),
        modelID: "auto",
        hasLiveRuntime: true
      ) == .liveRequiresRelaunch)
check("capture merge preserves orphaned reasoning", {
    let merged = ConversationCaptureMerge.preservingEphemeral(
        previous: "I should check the project layout before answering.\n\nHello!",
        next: "Hello! What would you like to work on?"
    )
    return merged.contains("I should check the project layout")
        && merged.contains("Hello! What would you like to work on?")
        && merged.contains(ConversationCaptureMerge.thinkingHeader)
}())
check("small-window inspector stays an overlay in Operator density",
      WorkspaceGeometryPolicy.resolve(
        windowWidth: 1_080,
        density: .operator,
        isInspectorPresented: true
      ).inspectorLayout == .overlay)
check("large Focused inspector remains temporary overlay",
      WorkspaceGeometryPolicy.resolve(
        windowWidth: 1_600,
        density: .focused,
        isInspectorPresented: true
      ).inspectorLayout == .overlay)
check("large Balanced inspector pins without changing density",
      WorkspaceGeometryPolicy.resolve(
        windowWidth: 1_440,
        density: .balanced,
        isInspectorPresented: true
      ).inspectorLayout == .pinned)
check("hidden inspector consumes no panel layout",
      WorkspaceGeometryPolicy.resolve(
        windowWidth: 1_600,
        density: .operator,
        isInspectorPresented: false
      ).inspectorLayout == .hidden)
check("inspector preferred width clamps to protect Conversation",
      WorkspaceGeometryPolicy.resolve(
        windowWidth: 1_080,
        density: .operator,
        isInspectorPresented: true,
        preferredInspectorWidth: 420
      ).inspectorWidth == 315)
check("inspector preferred width restores when the window grows",
      WorkspaceGeometryPolicy.resolve(
        windowWidth: 1_600,
        density: .operator,
        isInspectorPresented: true,
        preferredInspectorWidth: 420
      ).inspectorWidth == 420)
check("invalid inspector width restores the responsive default",
      WorkspaceGeometryPolicy.resolve(
        windowWidth: 1_280,
        density: .focused,
        isInspectorPresented: true,
        preferredInspectorWidth: .infinity
      ).inspectorWidth == 312)
check("clamped inspector no-op preserves the wider stored preference",
      !WorkspaceGeometryPolicy.shouldCommitInspectorWidth(
        currentEffectiveWidth: 315,
        proposedWidth: 315
      ))

// MARK: - Conversation-first session presentation

check("conversation is the session-surface default",
      SessionSurface.productDefault == .conversation)
check("raw remains the second first-class session surface",
      SessionSurface.allCases == [.conversation, .raw])
check("session-surface labels are Conversation and Raw",
      SessionSurface.allCases.map(\.displayName) == ["Conversation", "Raw"])
check("prompt handoff label does not imply agent acceptance",
      PromptDeliveryState.delivered.displayName == "Sent to terminal")

let presentationDate = Date(timeIntervalSince1970: 1_800_000_000)
let openingEvent = SessionPresentation.openingEvent(
    .resumed(
        agentName: "Codex",
        tmuxSessionName: "conduit-mainframe-codex",
        attachedElsewhere: true
    ),
    occurredAt: presentationDate
)
check("session opening is Conduit-recorded",
      openingEvent.authority == .conduitRecorded)
check("session opening event round-trips",
      (try? JSONDecoder().decode(
        SessionPresentationEvent.self,
        from: JSONEncoder().encode(openingEvent)
      )) == openingEvent)
let interruptRequestEvent = SessionPresentation.interruptRequestEvent(
    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    occurredAt: presentationDate
)
check("interrupt request is Conduit-recorded and round-trips",
      interruptRequestEvent.authority == .conduitRecorded
        && (try? JSONDecoder().decode(
            SessionPresentationEvent.self,
            from: JSONEncoder().encode(interruptRequestEvent)
        )) == interruptRequestEvent)

let firstPromptEvent = SessionPresentation.promptEvent(
    text: "Review this change",
    attachmentPaths: ["/tmp/example.swift"],
    renderedPayload: "Review this change\n\nAttachments:\n- /tmp/example.swift"
)
let secondPromptEvent = SessionPresentation.promptEvent(
    text: "Keep this queued",
    attachmentPaths: [],
    renderedPayload: "Keep this queued"
)
if case .userPrompt(let submitted) = firstPromptEvent.kind {
    check("prompt event retains human text", submitted.text == "Review this change")
    check("prompt event retains local attachment paths",
          submitted.attachmentPaths == ["/tmp/example.swift"])
    check("prompt event retains exact rendered payload",
          submitted.renderedPayload == "Review this change\n\nAttachments:\n- /tmp/example.swift")
    check("prompt event starts queued", submitted.delivery == .queued)
    check("native composer prompt retains its origin", submitted.origin == .composer)
} else {
    check("prompt event retains human text", false)
    check("prompt event retains local attachment paths", false)
    check("prompt event retains exact rendered payload", false)
    check("prompt event starts queued", false)
    check("native composer prompt retains its origin", false)
}
let forwardedPresentation = SessionPresentation.promptEvent(
    origin: .forwardedTerminalOutput(sourceAgentName: "Claude"),
    text: "selected terminal prose",
    attachmentPaths: [],
    renderedPayload: "Evidence boundary: this is unverified terminal output."
)
if case .userPrompt(let forwardedPrompt) = forwardedPresentation.kind {
    check("forwarded prompt retains unverified terminal origin",
          forwardedPrompt.origin == .forwardedTerminalOutput(sourceAgentName: "Claude")
            && forwardedPrompt.renderedPayload.contains("unverified terminal output"))
} else {
    check("forwarded prompt retains unverified terminal origin", false)
}
let reducedPresentation = SessionPresentation.updatingPromptDelivery(
    in: [openingEvent, firstPromptEvent, secondPromptEvent],
    eventID: firstPromptEvent.id,
    to: .delivered
)
check("delivery reducer preserves opening event",
      reducedPresentation[0] == openingEvent)
check("delivery reducer preserves unrelated prompt",
      reducedPresentation[2] == secondPromptEvent)
if case .userPrompt(let deliveredPrompt) = reducedPresentation[1].kind {
    check("delivery reducer updates matching prompt only",
          deliveredPrompt.delivery == .delivered
            && deliveredPrompt.text == "Review this change")
} else {
    check("delivery reducer updates matching prompt only", false)
}
let visibleOutput = SessionPresentation.agentOutputEvent(
    promptEventID: firstPromptEvent.id,
    text: "Visible terminal response",
    extraction: .renderedBuffer,
    truncated: false
)
let settledOutput = SessionPresentation.agentOutputEvent(
    promptEventID: firstPromptEvent.id,
    text: "Visible terminal response, settled",
    state: .settled,
    extraction: .renderedBuffer,
    truncated: false,
    id: visibleOutput.id,
    occurredAt: visibleOutput.occurredAt
)
let outputProjection = SessionPresentation.upsertingAgentOutput(
    in: [visibleOutput],
    event: settledOutput
)
check("raw-derived output keeps explicit authority",
      settledOutput.authority == .derivedFromRaw)
check("agent-output revision keeps one stable timeline item",
      outputProjection == [settledOutput])
let derivedOutput = RawDerivedOutputReducer.derive(
    baseline: RawDerivedSnapshot(
        text: "Agent\nReady",
        extraction: .renderedBuffer
    ),
    current: RawDerivedSnapshot(
        text: "Agent\nReady\nQuestion\n\nVisible answer",
        extraction: .renderedBuffer
    ),
    promptText: "Question"
)
let derivedOutputMatches: Bool
if case .output(let result) = derivedOutput {
    derivedOutputMatches = result.text == "Visible answer"
        && result.strategy == .appendedSuffix
} else {
    derivedOutputMatches = false
}
check("rendered-buffer reducer removes exact prompt echo",
      derivedOutputMatches)
check("terminal delivery state cannot regress",
      SessionPresentation.updatingPromptDelivery(
        in: reducedPresentation,
        eventID: firstPromptEvent.id,
        to: .failed
      ) == reducedPresentation)

// MARK: - Metadata-only TaskSession continuity and catalog

let taskHistorySessionID = TaskSessionID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
)
let taskHistoryAttemptID = RuntimeAttemptID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
)
check("task and runtime attempt identities stay distinct",
      taskHistorySessionID.rawValue != taskHistoryAttemptID.rawValue)
check("task identity round-trips as one value",
      (try? JSONDecoder().decode(
        TaskSessionID.self,
        from: JSONEncoder().encode(taskHistorySessionID)
      )) == taskHistorySessionID)

let taskHistoryRoot = URL(fileURLWithPath: "/tmp/MainFrame/./")
let taskHistoryProject = URL(
    fileURLWithPath: "/tmp/MainFrame/30_projects/../30_projects/conduit"
)
let taskHistoryScope = WorkspaceScopeSnapshot.project(
    ProjectWorkspaceScopeSnapshot(
        rootURL: taskHistoryRoot,
        projectURL: taskHistoryProject,
        fallbackTitle: "Conduit",
        fallbackSlug: "conduit"
    )
)
check("task workspace root path is standardized",
      taskHistoryScope.rootPath == "/tmp/MainFrame")
check("task project path is standardized",
      taskHistoryScope.projectPath == "/tmp/MainFrame/30_projects/conduit")
check("task workspace keeps fallback title and slug",
      taskHistoryScope.fallbackTitle == "Conduit"
        && taskHistoryScope.fallbackSlug == "conduit")
let taskHistoryUnknownAgent = TaskSessionMetadata(
    workspace: taskHistoryScope,
    agentName: nil,
    defaultTitle: ""
)
let taskHistoryUnknownAgentEvent = TaskSessionEvent(
    taskSessionID: taskHistorySessionID,
    authority: .conduitRecorded,
    kind: .created(taskHistoryUnknownAgent)
)
let taskHistoryUnknownAgentSnapshot = TaskSessionProjection.project(
    taskSessionID: taskHistorySessionID,
    events: [taskHistoryUnknownAgentEvent]
)
check("unknown agent identity stays absent instead of persisting a placeholder",
      taskHistoryUnknownAgentSnapshot?.metadata.agentName == nil
        && taskHistoryUnknownAgentSnapshot?.displayTitle == "Conduit")

let taskHistoryDate = Date(timeIntervalSince1970: 1_800_010_000)
let taskHistoryMetadata = TaskSessionMetadata(
    workspace: taskHistoryScope,
    agentName: "Codex",
    defaultTitle: "Codex · Conduit"
)
let taskHistoryEvents = [
    TaskSessionEvent(
        taskSessionID: taskHistorySessionID,
        occurredAt: taskHistoryDate,
        recordedAt: taskHistoryDate,
        authority: .conduitRecorded,
        kind: .created(taskHistoryMetadata)
    ),
    TaskSessionEvent(
        taskSessionID: taskHistorySessionID,
        occurredAt: taskHistoryDate.addingTimeInterval(1),
        recordedAt: taskHistoryDate.addingTimeInterval(1),
        authority: .operatorAsserted,
        kind: .titleOverridden("  Release review  ")
    ),
    TaskSessionEvent(
        taskSessionID: taskHistorySessionID,
        occurredAt: taskHistoryDate.addingTimeInterval(2),
        recordedAt: taskHistoryDate.addingTimeInterval(2),
        authority: .operatorAsserted,
        kind: .pinChanged(true)
    ),
    TaskSessionEvent(
        taskSessionID: taskHistorySessionID,
        occurredAt: taskHistoryDate.addingTimeInterval(3),
        recordedAt: taskHistoryDate.addingTimeInterval(3),
        authority: .conduitRecorded,
        kind: .operationalStateChanged(.runtimeOpened(taskHistoryAttemptID))
    )
]
let taskHistorySnapshot = TaskSessionProjection.project(
    taskSessionID: taskHistorySessionID,
    events: taskHistoryEvents
)
check("task projection applies an explicit trimmed title",
      taskHistorySnapshot?.displayTitle == "Release review")
check("task projection applies pin and operational metadata",
      taskHistorySnapshot?.isPinned == true
        && taskHistorySnapshot?.operationalState == .runtimeOpened(taskHistoryAttemptID))
check("runtime detach can be Conduit-recorded or process-observed",
      TaskSessionEvent(
        taskSessionID: taskHistorySessionID,
        authority: .conduitRecorded,
        kind: .operationalStateChanged(.runtimeDetached(taskHistoryAttemptID))
      ).hasValidAuthority
        && TaskSessionEvent(
            taskSessionID: taskHistorySessionID,
            authority: .processObserved,
            kind: .operationalStateChanged(.runtimeDetached(taskHistoryAttemptID))
        ).hasValidAuthority)

let taskHistoryResetEvents = taskHistoryEvents + [
    TaskSessionEvent(
        taskSessionID: taskHistorySessionID,
        occurredAt: taskHistoryDate.addingTimeInterval(4),
        recordedAt: taskHistoryDate.addingTimeInterval(4),
        authority: .operatorAsserted,
        kind: .titleReset
    ),
    TaskSessionEvent(
        taskSessionID: taskHistorySessionID,
        occurredAt: taskHistoryDate.addingTimeInterval(5),
        recordedAt: taskHistoryDate.addingTimeInterval(5),
        authority: .operatorAsserted,
        kind: .archiveChanged(true)
    )
]
let taskHistoryReset = TaskSessionProjection.project(
    taskSessionID: taskHistorySessionID,
    events: taskHistoryResetEvents
)
check("task title reset restores deterministic default",
      taskHistoryReset?.displayTitle == "Codex · Conduit")
check("task archive is metadata, not deletion",
      taskHistoryReset?.isArchived == true)
let taskHistoryEncoded = (
    try? String(
        decoding: JSONEncoder().encode(taskHistoryResetEvents),
        as: UTF8.self
    ).lowercased()
) ?? ""
check("task continuity metadata retains no transcript fields",
      !taskHistoryEncoded.contains("prompt")
        && !taskHistoryEncoded.contains("attachment")
        && !taskHistoryEncoded.contains("renderedpayload"))

if let taskHistorySnapshot {
    check("live runtime observation wins availability projection",
          TaskSessionAvailabilityResolver.resolve(
            session: taskHistorySnapshot,
            context: TaskSessionAvailabilityContext(
                liveRuntimeAttempts: [taskHistorySessionID: taskHistoryAttemptID],
                reconnectableTaskSessionIDs: [taskHistorySessionID],
                externalObservation: .succeeded(observedAt: taskHistoryDate)
            )
          ) == .running(taskHistoryAttemptID))
    check("reconnectable observation is distinct from running",
          TaskSessionAvailabilityResolver.resolve(
            session: taskHistorySnapshot,
            context: TaskSessionAvailabilityContext(
                reconnectableTaskSessionIDs: [taskHistorySessionID],
                externalObservation: .succeeded(observedAt: taskHistoryDate)
            )
          ) == .reconnectable)
}

let taskHistorySecondID = TaskSessionID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
)
let taskHistorySecondEvents = [
    TaskSessionEvent(
        taskSessionID: taskHistorySecondID,
        occurredAt: taskHistoryDate.addingTimeInterval(3),
        recordedAt: taskHistoryDate.addingTimeInterval(3),
        authority: .conduitRecorded,
        kind: .created(
            TaskSessionMetadata(
                workspace: taskHistoryScope,
                agentName: "Claude",
                defaultTitle: "Alpha review"
            )
        )
    )
]
let taskHistorySecond = TaskSessionProjection.project(
    taskSessionID: taskHistorySecondID,
    events: taskHistorySecondEvents
)
if let taskHistorySnapshot, let taskHistorySecond {
    let taskHistoryRows = SessionCatalog.rows(
        sessions: [taskHistorySecond, taskHistorySnapshot],
        availabilityContext: TaskSessionAvailabilityContext(),
        query: TaskSessionCatalogQuery(
            workspaceRootURL: taskHistoryRoot,
            projectURL: taskHistoryProject
        )
    )
    check("catalog keeps pinned sessions first",
          taskHistoryRows.first?.id == taskHistorySessionID)
    check("catalog searches title case-insensitively",
          SessionCatalog.rows(
            sessions: [taskHistorySecond, taskHistorySnapshot],
            availabilityContext: TaskSessionAvailabilityContext(),
            query: TaskSessionCatalogQuery(searchText: "ALPHA")
          ).map(\.id) == [taskHistorySecondID])
}

// MARK: - Append-only TaskSession event storage

withTempDir { temporaryDirectory in
    func taskLogID(_ value: String) -> TaskSessionID {
        TaskSessionID(rawValue: UUID(uuidString: value)!)
    }

    func taskLogMetadata(_ title: String) -> TaskSessionMetadata {
        TaskSessionMetadata(
            workspace: taskHistoryScope,
            agentName: "Codex",
            defaultTitle: title
        )
    }

    func taskLogEvent(
        _ taskSessionID: TaskSessionID,
        id: UUID = UUID(),
        at date: Date,
        authority: TaskSessionEventAuthority,
        kind: TaskSessionEventKind
    ) -> TaskSessionEvent {
        TaskSessionEvent(
            id: id,
            taskSessionID: taskSessionID,
            occurredAt: date,
            recordedAt: date,
            authority: authority,
            kind: kind
        )
    }

    func encodedTaskLogEvent(_ event: TaskSessionEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event)
    }

    func appendTaskLogBytes(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func appendTaskLogLines(_ lines: [Data], to url: URL) throws {
        var bytes = Data()
        for line in lines {
            bytes.append(line)
            bytes.append(UInt8(ascii: "\n"))
        }
        try appendTaskLogBytes(bytes, to: url)
    }

    let taskLogDate = Date(timeIntervalSince1970: 1_800_020_000)

    // Canonical append/read/discovery/load, including deterministic UUID order.
    let appendDirectory = temporaryDirectory.appendingPathComponent("append-load")
    let taskLogFirstID = taskLogID(
        "00000000-0000-0000-0000-000000000101"
    )
    let taskLogSecondID = taskLogID(
        "00000000-0000-0000-0000-000000000102"
    )
    let taskLogFirst = TaskSessionEventLog(
        directory: appendDirectory,
        taskSessionID: taskLogFirstID
    )
    let taskLogSecond = TaskSessionEventLog(
        directory: appendDirectory,
        taskSessionID: taskLogSecondID
    )
    let taskLogCreation = taskLogEvent(
        taskLogFirstID,
        at: taskLogDate,
        authority: .conduitRecorded,
        kind: .created(taskLogMetadata("Stored first task"))
    )
    let taskLogPin = taskLogEvent(
        taskLogFirstID,
        at: taskLogDate.addingTimeInterval(1),
        authority: .operatorAsserted,
        kind: .pinChanged(true)
    )
    try taskLogSecond.append(
        taskLogEvent(
            taskLogSecondID,
            at: taskLogDate.addingTimeInterval(2),
            authority: .conduitRecorded,
            kind: .created(taskLogMetadata("Stored second task"))
        )
    )
    try taskLogFirst.append(taskLogCreation)
    try taskLogFirst.append(taskLogPin)
    let taskLogFilenames = try FileManager.default.contentsOfDirectory(
        atPath: appendDirectory.path
    ).sorted()
    check("task log uses one canonical UUID file per task",
          taskLogFilenames == [
            "00000000-0000-0000-0000-000000000101.jsonl",
            "00000000-0000-0000-0000-000000000102.jsonl"
          ])
    let taskLogRead = taskLogFirst.read()
    check("task log append and read retain file order",
          taskLogRead.events == [taskLogCreation, taskLogPin]
            && taskLogRead.diagnostics.isEmpty)
    let taskLogStore = TaskSessionEventStore(directory: appendDirectory)
    check("task log discovery is deterministic",
          taskLogStore.logs().logs.map(\.taskSessionID)
            == [taskLogFirstID, taskLogSecondID])
    let taskLogLoaded = taskLogStore.load()
    check("task log store projects valid snapshots",
          taskLogLoaded.snapshots.map(\.id)
            == [taskLogFirstID, taskLogSecondID]
            && taskLogLoaded.snapshots.first?.isPinned == true
            && taskLogLoaded.diagnostics.isEmpty)

    let conversationDirectory = temporaryDirectory
        .appendingPathComponent("conversations")
    let conversationLog = ConversationEventLog(
        directory: conversationDirectory,
        taskSessionID: taskLogFirstID
    )
    let retainedPrompt = SessionPresentation.promptEvent(
        text: "Retain this locally",
        attachmentPaths: ["/tmp/reference.md"],
        renderedPayload: "Retain this locally\n\nAttachments:\n- /tmp/reference.md",
        occurredAt: taskLogDate
    )
    let retainedDelivery = SessionPresentation.updatingPromptDelivery(
        in: [retainedPrompt],
        eventID: retainedPrompt.id,
        to: .delivered
    )[0]
    try conversationLog.append(retainedPrompt)
    try conversationLog.append(retainedDelivery)
    let retainedConversation = conversationLog.read()
    check("conversation log projects the latest append-only revision",
          retainedConversation.events == [retainedDelivery]
            && retainedConversation.diagnostics.isEmpty)

    // Concurrent writers must retain every whole event. `flock` is the
    // cross-process authority; this in-process pressure check also catches
    // stale-offset overwrites and line interleaving.
    let concurrentDirectory = temporaryDirectory
        .appendingPathComponent("concurrent")
    let concurrentID = taskLogID(
        "00000000-0000-0000-0000-000000000105"
    )
    let concurrentLog = TaskSessionEventLog(
        directory: concurrentDirectory,
        taskSessionID: concurrentID
    )
    let concurrentCreation = taskLogEvent(
        concurrentID,
        at: taskLogDate,
        authority: .conduitRecorded,
        kind: .created(taskLogMetadata("Concurrent task"))
    )
    try concurrentLog.append(concurrentCreation)
    let concurrentEvents = (0..<32).map { index in
        taskLogEvent(
            concurrentID,
            at: taskLogDate.addingTimeInterval(Double(index + 1)),
            authority: .operatorAsserted,
            kind: .pinChanged(index.isMultiple(of: 2))
        )
    }
    let concurrentErrorLock = NSLock()
    var concurrentErrors: [String] = []
    DispatchQueue.concurrentPerform(
        iterations: concurrentEvents.count
    ) { index in
        do {
            try concurrentLog.append(concurrentEvents[index])
        } catch {
            concurrentErrorLock.lock()
            concurrentErrors.append(String(describing: error))
            concurrentErrorLock.unlock()
        }
    }
    let concurrentRead = concurrentLog.read()
    check("task log concurrent appends retain every whole event",
          concurrentErrors.isEmpty
            && concurrentRead.diagnostics.isEmpty
            && concurrentRead.events.count == concurrentEvents.count + 1
            && Set(concurrentRead.events.map(\.id))
                == Set(([concurrentCreation] + concurrentEvents).map(\.id)))

    // A mismatched event cannot create or contaminate another task's file.
    let mismatchExpectedID = taskLogID(
        "00000000-0000-0000-0000-000000000110"
    )
    let mismatchActualID = taskLogID(
        "00000000-0000-0000-0000-000000000111"
    )
    let mismatchLog = TaskSessionEventLog(
        directory: appendDirectory,
        taskSessionID: mismatchExpectedID
    )
    var mismatchRejected = false
    do {
        try mismatchLog.append(
            taskLogEvent(
                mismatchActualID,
                at: taskLogDate,
                authority: .conduitRecorded,
                kind: .created(taskLogMetadata("Wrong task"))
            )
        )
    } catch let error as TaskSessionEventLogError {
        mismatchRejected = error == .mismatchedTaskSessionID(
            expected: mismatchExpectedID,
            actual: mismatchActualID
        )
    }
    check("task log rejects mismatched task identity",
          mismatchRejected
            && !FileManager.default.fileExists(atPath: mismatchLog.url.path))

    // Torn bytes remain visible, while a following append starts a clean line.
    let tornDirectory = temporaryDirectory.appendingPathComponent("torn")
    let tornID = taskLogID("00000000-0000-0000-0000-000000000120")
    let tornLog = TaskSessionEventLog(
        directory: tornDirectory,
        taskSessionID: tornID
    )
    let tornCreation = taskLogEvent(
        tornID,
        at: taskLogDate,
        authority: .conduitRecorded,
        kind: .created(taskLogMetadata("Torn task"))
    )
    let tornPin = taskLogEvent(
        tornID,
        at: taskLogDate.addingTimeInterval(1),
        authority: .operatorAsserted,
        kind: .pinChanged(true)
    )
    try tornLog.append(tornCreation)
    try appendTaskLogBytes(Data("{\"broken\"".utf8), to: tornLog.url)
    try tornLog.append(tornPin)
    let tornBytesBeforeRead = try Data(contentsOf: tornLog.url)
    let tornRead = tornLog.read()
    check("task log heals a torn final line",
          String(decoding: tornBytesBeforeRead, as: UTF8.self)
            .contains("{\"broken\"\n")
            && tornRead.events == [tornCreation, tornPin]
            && tornRead.diagnostics.map(\.kind) == [.malformedLine])
    let tornBytesAfterRead = try Data(contentsOf: tornLog.url)
    check("task log read preserves torn source bytes",
          tornBytesAfterRead == tornBytesBeforeRead)

    // Unsupported, invalid-authority, mismatched, and malformed lines are
    // diagnosed but never rewritten or promoted into a snapshot.
    let corruptDirectory = temporaryDirectory.appendingPathComponent("corrupt")
    let corruptID = taskLogID(
        "00000000-0000-0000-0000-000000000130"
    )
    let corruptOtherID = taskLogID(
        "00000000-0000-0000-0000-000000000131"
    )
    let corruptLog = TaskSessionEventLog(
        directory: corruptDirectory,
        taskSessionID: corruptID
    )
    let corruptCreation = taskLogEvent(
        corruptID,
        at: taskLogDate,
        authority: .conduitRecorded,
        kind: .created(taskLogMetadata("Recoverable task"))
    )
    try corruptLog.append(corruptCreation)
    let unsupported = TaskSessionEvent(
        schemaVersion: TaskSessionEvent.currentSchemaVersion + 1,
        taskSessionID: corruptID,
        occurredAt: taskLogDate.addingTimeInterval(1),
        recordedAt: taskLogDate.addingTimeInterval(1),
        authority: .operatorAsserted,
        kind: .pinChanged(true)
    )
    let invalidAuthority = taskLogEvent(
        corruptID,
        at: taskLogDate.addingTimeInterval(2),
        authority: .conduitRecorded,
        kind: .pinChanged(true)
    )
    let wrongTask = taskLogEvent(
        corruptOtherID,
        at: taskLogDate.addingTimeInterval(3),
        authority: .operatorAsserted,
        kind: .pinChanged(true)
    )
    try appendTaskLogLines(
        [
            try encodedTaskLogEvent(unsupported),
            try encodedTaskLogEvent(invalidAuthority),
            try encodedTaskLogEvent(wrongTask),
            Data("not-json".utf8)
        ],
        to: corruptLog.url
    )
    let corruptBytes = try Data(contentsOf: corruptLog.url)
    let corruptRead = corruptLog.read()
    check("task log diagnoses unsupported and invalid records",
          corruptRead.events == [corruptCreation]
            && corruptRead.diagnostics.map(\.kind) == [
                .unsupportedSchemaVersion,
                .invalidAuthority,
                .mismatchedTaskSessionID,
                .malformedLine
            ])
    let corruptLoad = TaskSessionEventStore(
        directory: corruptDirectory
    ).load()
    check("task store projects valid records around corrupt lines",
          corruptLoad.snapshots.map(\.id) == [corruptID]
            && corruptLoad.diagnostics.map(\.kind)
                == corruptRead.diagnostics.map(\.kind))
    let corruptBytesAfterLoad = try Data(contentsOf: corruptLog.url)
    check("task store load preserves corrupt source bytes",
          corruptBytesAfterLoad == corruptBytes)

    // Duplicate event IDs are retained by the raw read and applied once by
    // projection, so retrying a record is idempotent.
    let duplicateDirectory = temporaryDirectory
        .appendingPathComponent("duplicate")
    let duplicateTaskID = taskLogID(
        "00000000-0000-0000-0000-000000000140"
    )
    let duplicateEventID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000141"
    )!
    let duplicateLog = TaskSessionEventLog(
        directory: duplicateDirectory,
        taskSessionID: duplicateTaskID
    )
    let duplicateEvents = [
        taskLogEvent(
            duplicateTaskID,
            at: taskLogDate,
            authority: .conduitRecorded,
            kind: .created(taskLogMetadata("Idempotent task"))
        ),
        taskLogEvent(
            duplicateTaskID,
            id: duplicateEventID,
            at: taskLogDate.addingTimeInterval(1),
            authority: .operatorAsserted,
            kind: .pinChanged(true)
        ),
        taskLogEvent(
            duplicateTaskID,
            id: duplicateEventID,
            at: taskLogDate.addingTimeInterval(2),
            authority: .operatorAsserted,
            kind: .pinChanged(false)
        )
    ]
    for event in duplicateEvents {
        try duplicateLog.append(event)
    }
    let duplicateStore = TaskSessionEventStore(directory: duplicateDirectory)
    let duplicateFirstLoad = duplicateStore.load()
    check("task log retains duplicate records in file order",
          duplicateLog.read().events == duplicateEvents)
    check("task projection is idempotent across duplicate event IDs",
          duplicateFirstLoad == duplicateStore.load()
            && duplicateFirstLoad.snapshots.first?.isPinned == true)

    let missingDirectory = temporaryDirectory.appendingPathComponent("missing")
    let missingStore = TaskSessionEventStore(directory: missingDirectory)
    check("missing task log directory is clean empty",
          missingStore.logs().logs.isEmpty
            && missingStore.logs().diagnostics.isEmpty
            && missingStore.load().snapshots.isEmpty
            && missingStore.load().diagnostics.isEmpty
            && !FileManager.default.fileExists(atPath: missingDirectory.path))

    let invalidDirectory = temporaryDirectory.appendingPathComponent("invalid")
    let unprojectableID = taskLogID(
        "00000000-0000-0000-0000-000000000150"
    )
    let unprojectableLog = TaskSessionEventLog(
        directory: invalidDirectory,
        taskSessionID: unprojectableID
    )
    try unprojectableLog.append(
        taskLogEvent(
            unprojectableID,
            at: taskLogDate,
            authority: .operatorAsserted,
            kind: .pinChanged(true)
        )
    )
    let invalidFilenameURL = invalidDirectory
        .appendingPathComponent("not-a-task-id.jsonl")
    let invalidFilenameBytes = Data("preserve-invalid-name\n".utf8)
    try invalidFilenameBytes.write(to: invalidFilenameURL)
    let invalidLoad = TaskSessionEventStore(directory: invalidDirectory).load()
    let invalidFilenameBytesAfterLoad = try Data(
        contentsOf: invalidFilenameURL
    )
    check("task store diagnoses invalid and unprojectable logs",
          invalidLoad.snapshots.isEmpty
            && Set(invalidLoad.diagnostics.map(\.kind))
                == Set([.invalidFilename, .unprojectableLog])
            && invalidFilenameBytesAfterLoad
                == invalidFilenameBytes)
}

// MARK: - Density (Focused Flow R2)

check("density case order is focused balanced operator",
      Density.allCases.map(\.rawValue) == ["focused", "balanced", "operator"])
check("density exposes exactly three modes", Density.allCases.count == 3)
check("density product default is Focused",
      Density.productDefault == .focused && Density.allCases.first == .focused)
check("density display labels are Focused Balanced Operator",
      Density.allCases.map(\.displayName) == ["Focused", "Balanced", "Operator"])
check("density recovers valid raw values",
      Density.resolved(fromStored: "focused") == .focused
        && Density.resolved(fromStored: "balanced") == .balanced
        && Density.resolved(fromStored: "operator") == .operator)
check("density invalid and missing fall back to Focused",
      Density.resolved(fromStored: nil) == .focused
        && Density.resolved(fromStored: "") == .focused
        && Density.resolved(fromStored: "compact") == .focused
        && Density.resolved(fromStored: "FOCUSED") == .focused
        && Density.resolved(fromStored: "Operator") == .focused)

// MARK: - PaletteSpec (Focused Flow R2 base lock)

check("palette case order is Harbor Sage Clay Heather Phosphor",
      PaletteID.allCases.map(\.rawValue) == ["harbor", "sage", "clay", "heather", "phosphor"])
check("palette product default is Harbor",
      PaletteID.productDefault == .harbor && PaletteID.allCases.first == .harbor)
check("palette exposes exactly five identifiers", PaletteID.allCases.count == 5)
check("palette exposes exactly ten base variants", PaletteID.allBaseVariants.count == 10)

let harborLight = PaletteID.harbor.baseTokens(variant: .light)
check("Harbor light accent", harborLight.accent == "#456881")
check("Harbor light on-accent", harborLight.onAccent == "#FFFFFF")
check("Harbor light ink", harborLight.ink == "#35566D")
check("Harbor light canvas", harborLight.canvas == "#F2F5F7")
check("Harbor light app", harborLight.app == "#E4E9ED")
check("Harbor light rail", harborLight.rail == "#EBEFF2")
check("Harbor light surface", harborLight.surface == "#FCFDFE")
check("Harbor light sink", harborLight.sink == "#DFE5EA")
check("Harbor light text", harborLight.text == "#232A31")
check("Harbor light dim", harborLight.dim == "#5C6772")
check("Harbor light faint", harborLight.faint == "#93A0AB")
check("Harbor light shade",
      harborLight.shade == PaletteShade(red: 30, green: 48, blue: 62))
check("Harbor light is soft", harborLight.soft)

let harborDark = PaletteID.harbor.baseTokens(variant: .dark)
check("Harbor dark accent", harborDark.accent == "#7FA8C8")
check("Harbor dark on-accent", harborDark.onAccent == "#0D1417")
check("Harbor dark ink", harborDark.ink == "#A3C4DD")
check("Harbor dark canvas", harborDark.canvas == "#0F1417")
check("Harbor dark app", harborDark.app == "#141A1E")
check("Harbor dark rail", harborDark.rail == "#192025")
check("Harbor dark surface", harborDark.surface == "#1E262B")
check("Harbor dark sink", harborDark.sink == "#131A1E")
check("Harbor dark text", harborDark.text == "#E1E6EA")
check("Harbor dark dim", harborDark.dim == "#93A0AA")
check("Harbor dark faint", harborDark.faint == "#64707A")
check("Harbor dark has no shade", harborDark.shade == nil)
check("Harbor dark is soft", harborDark.soft)

let sageLight = PaletteID.sage.baseTokens(variant: .light)
check("Sage light base tokens",
      sageLight.accent == "#4F6B49"
        && sageLight.onAccent == "#FFFFFF"
        && sageLight.ink == "#3F5740"
        && sageLight.canvas == "#F5F3EC"
        && sageLight.app == "#E9EBE2"
        && sageLight.rail == "#EEF0E7"
        && sageLight.surface == "#FCFCF8"
        && sageLight.sink == "#E4E7DC"
        && sageLight.text == "#2A2E27"
        && sageLight.dim == "#626B5D"
        && sageLight.faint == "#98A08D"
        && sageLight.shade == PaletteShade(red: 40, green: 50, blue: 32)
        && sageLight.soft)
let sageDark = PaletteID.sage.baseTokens(variant: .dark)
check("Sage dark base tokens",
      sageDark.accent == "#8FB183"
        && sageDark.onAccent == "#14180F"
        && sageDark.ink == "#A9C99E"
        && sageDark.canvas == "#141A15"
        && sageDark.app == "#191E1A"
        && sageDark.rail == "#1E241F"
        && sageDark.surface == "#232924"
        && sageDark.sink == "#171C18"
        && sageDark.text == "#E4E7DD"
        && sageDark.dim == "#9AA393"
        && sageDark.faint == "#6B7365"
        && sageDark.shade == nil
        && sageDark.soft)

let clayLight = PaletteID.clay.baseTokens(variant: .light)
check("Clay light base tokens",
      clayLight.accent == "#97583E"
        && clayLight.onAccent == "#FFFFFF"
        && clayLight.ink == "#7C4530"
        && clayLight.canvas == "#F5F0E9"
        && clayLight.app == "#EAE1D6"
        && clayLight.rail == "#F0E8DD"
        && clayLight.surface == "#FDFBF7"
        && clayLight.sink == "#E5DBCD"
        && clayLight.text == "#2E2620"
        && clayLight.dim == "#6D6055"
        && clayLight.faint == "#A0917F"
        && clayLight.shade == PaletteShade(red: 60, green: 42, blue: 28)
        && clayLight.soft)
let clayDark = PaletteID.clay.baseTokens(variant: .dark)
check("Clay dark base tokens",
      clayDark.accent == "#CB8A6E"
        && clayDark.onAccent == "#17120E"
        && clayDark.ink == "#E0A888"
        && clayDark.canvas == "#17120E"
        && clayDark.app == "#1D1712"
        && clayDark.rail == "#221B15"
        && clayDark.surface == "#271F18"
        && clayDark.sink == "#1A140F"
        && clayDark.text == "#EAE2D8"
        && clayDark.dim == "#A3958A"
        && clayDark.faint == "#736659"
        && clayDark.shade == nil
        && clayDark.soft)

let heatherLight = PaletteID.heather.baseTokens(variant: .light)
check("Heather light base tokens",
      heatherLight.accent == "#635B8C"
        && heatherLight.onAccent == "#FFFFFF"
        && heatherLight.ink == "#4F4874"
        && heatherLight.canvas == "#F4F3F7"
        && heatherLight.app == "#E7E5EE"
        && heatherLight.rail == "#EDEBF3"
        && heatherLight.surface == "#FCFCFE"
        && heatherLight.sink == "#E2E0EB"
        && heatherLight.text == "#2A2833"
        && heatherLight.dim == "#625D70"
        && heatherLight.faint == "#9A94A8"
        && heatherLight.shade == PaletteShade(red: 40, green: 36, blue: 58)
        && heatherLight.soft)
let heatherDark = PaletteID.heather.baseTokens(variant: .dark)
check("Heather dark base tokens",
      heatherDark.accent == "#A79FCE"
        && heatherDark.onAccent == "#141318"
        && heatherDark.ink == "#C3BCE0"
        && heatherDark.canvas == "#141318"
        && heatherDark.app == "#1A181F"
        && heatherDark.rail == "#201E27"
        && heatherDark.surface == "#26232E"
        && heatherDark.sink == "#18161D"
        && heatherDark.text == "#E5E2EC"
        && heatherDark.dim == "#9D97AC"
        && heatherDark.faint == "#6D6879"
        && heatherDark.shade == nil
        && heatherDark.soft)

let phosphorLight = PaletteID.phosphor.baseTokens(variant: .light)
check("Phosphor light base tokens",
      phosphorLight.accent == "#C97A16"
        && phosphorLight.onAccent == "#241A08"
        && phosphorLight.ink == "#8A5410"
        && phosphorLight.canvas == "#FAF8F4"
        && phosphorLight.app == "#ECE7DE"
        && phosphorLight.rail == "#F4F0E8"
        && phosphorLight.surface == "#FFFFFF"
        && phosphorLight.sink == "#E7E1D6"
        && phosphorLight.text == "#221E18"
        && phosphorLight.dim == "#6C665B"
        && phosphorLight.faint == "#9C9488"
        && phosphorLight.shade == PaletteShade(red: 40, green: 32, blue: 20)
        && phosphorLight.soft == false)
let phosphorDark = PaletteID.phosphor.baseTokens(variant: .dark)
check("Phosphor dark base tokens",
      phosphorDark.accent == "#E8A13B"
        && phosphorDark.onAccent == "#201603"
        && phosphorDark.ink == "#F2BE6E"
        && phosphorDark.canvas == "#0B0E0C"
        && phosphorDark.app == "#101311"
        && phosphorDark.rail == "#181B18"
        && phosphorDark.surface == "#1E221F"
        && phosphorDark.sink == "#121614"
        && phosphorDark.text == "#E7E3DA"
        && phosphorDark.dim == "#9B978C"
        && phosphorDark.faint == "#6B675E"
        && phosphorDark.shade == nil
        && phosphorDark.soft == false)

let softFlags = PaletteID.allBaseVariants.map { ($0.id, $0.tokens.soft) }
check("Phosphor alone is non-soft",
      softFlags.filter { !$0.1 }.map(\.0) == [.phosphor, .phosphor]
        && softFlags.filter { $0.1 }.count == 8)

let lightShades = PaletteID.allCases.compactMap { id -> (PaletteID, PaletteShade?) in
    (id, id.baseTokens(variant: .light).shade)
}
check("every light variant has a shade triple",
      lightShades.allSatisfy { $0.1 != nil })
check("every dark variant has no shade",
      PaletteID.allCases.allSatisfy { $0.baseTokens(variant: .dark).shade == nil })

let hexPattern = #"^#[0-9A-F]{6}$"#
let hexRegex = try! NSRegularExpression(pattern: hexPattern)
func isNormalizedHex(_ value: String) -> Bool {
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return hexRegex.firstMatch(in: value, range: range) != nil
}
var allHexOK = true
for entry in PaletteID.allBaseVariants {
    let t = entry.tokens
    for color in [t.accent, t.onAccent, t.ink, t.canvas, t.app, t.rail, t.surface, t.sink, t.text, t.dim, t.faint] {
        if !isNormalizedHex(color) { allHexOK = false }
    }
}
check("all base color literals are six-digit uppercase hex", allHexOK)

check("mk accent-soft alpha",
      PaletteMkConstants.accentSoftAlphaDark == 0.17
        && PaletteMkConstants.accentSoftAlphaLight == 0.13)
check("mk soft accent-glow",
      PaletteMkConstants.softAccentGlowDark == 0.20
        && PaletteMkConstants.softAccentGlowLight == 0.13)
check("mk non-soft accent-glow",
      PaletteMkConstants.nonSoftAccentGlowDark == 0.42
        && PaletteMkConstants.nonSoftAccentGlowLight == 0.30)
check("mk line",
      PaletteMkConstants.lineDarkWhite == 0.10
        && PaletteMkConstants.lineLightShade == 0.13)
check("mk line-soft",
      PaletteMkConstants.lineSoftDarkWhite == 0.05
        && PaletteMkConstants.lineSoftLightShade == 0.06)
check("mk soft scan",
      PaletteMkConstants.softScanDarkWhite == 0.008
        && PaletteMkConstants.softScanLightShade == 0.006)
check("mk non-soft scan",
      PaletteMkConstants.nonSoftScanDarkWhite == 0.022
        && PaletteMkConstants.nonSoftScanLightShade == 0.015)
check("mk desk darkening",
      PaletteMkConstants.desk1DarkeningDark == 0.35
        && PaletteMkConstants.desk1DarkeningLight == 0.05
        && PaletteMkConstants.desk2DarkeningDark == 0.15
        && PaletteMkConstants.desk2DarkeningLight == 0.13)
check("mk shadow dark string",
      PaletteMkConstants.shadowDark
        == "0 26px 70px -18px rgba(0,0,0,.7),0 2px 10px rgba(0,0,0,.5)")
check("mk shadow light string",
      PaletteMkConstants.shadowLight
        == "0 22px 60px -18px rgba(30,22,10,.3),0 2px 8px rgba(30,22,10,.1)")
check("mk pop-shadow dark string",
      PaletteMkConstants.popShadowDark == "0 18px 46px -8px rgba(0,0,0,.66)")
check("mk pop-shadow light string",
      PaletteMkConstants.popShadowLight == "0 14px 40px -10px rgba(20,15,5,.3)")

// MARK: - PromptEncoder

let multiline = "line one\nline two"
let bracketed = PromptEncoder.encode(text: multiline, bracketedPaste: true, submit: true)
check("bracketed paste starts with ESC[200~",
      Array(bracketed.prefix(6)) == PromptEncoder.bracketedPasteStart)
check("bracketed paste ends with ESC[201~ + CR",
      Array(bracketed.suffix(7)) == PromptEncoder.bracketedPasteEnd + Array("\r".utf8))
check("bracketed payload preserves newline",
      bracketed.contains(UInt8(ascii: "\n")))
let plain = PromptEncoder.encode(text: multiline, bracketedPaste: false, submit: true)
check("plain typing converts newline to CR",
      !plain.contains(UInt8(ascii: "\n")) && plain.filter { $0 == UInt8(ascii: "\r") }.count == 2)
check("no submit means no trailing CR",
      PromptEncoder.encode(text: "hi", bracketedPaste: false, submit: false) == Array("hi".utf8))
check("trailing newlines are normalized away",
      PromptEncoder.normalized("cmd\n\n") == "cmd")
check("empty prompt encodes to nothing",
      PromptEncoder.encode(text: "\n\n", bracketedPaste: true, submit: true).isEmpty)

// MARK: - ArgumentTokenizer

check("tokenizer splits plain args",
      ArgumentTokenizer.tokenize("-l --color auto") == ["-l", "--color", "auto"])
check("tokenizer respects double quotes",
      ArgumentTokenizer.tokenize("--msg \"hello world\" -x") == ["--msg", "hello world", "-x"])
check("tokenizer respects single quotes",
      ArgumentTokenizer.tokenize("-c 'a b'") == ["-c", "a b"])
check("tokenizer keeps empty quoted token",
      ArgumentTokenizer.tokenize("a \"\" b") == ["a", "", "b"])
let roundtrip = ["--message", "hello world", "plain", "it's"]
check("tokenizer joins and reparses",
      ArgumentTokenizer.tokenize(ArgumentTokenizer.join(roundtrip)) == roundtrip)

// MARK: - ShellQuoting

check("shell quote escapes single quotes",
      ShellQuoting.quote("it's") == "'it'\\''s'")
check("command line quotes each part",
      ShellQuoting.commandLine("claude", ["--continue"]) == "'claude' '--continue'")

// MARK: - TmuxSessionNaming

let projectURL = URL(fileURLWithPath: "/tmp/MainFrame/30_projects/conduit")
let nameA = TmuxSessionNaming.sessionName(projectPath: projectURL, agentName: "Claude")
let nameB = TmuxSessionNaming.sessionName(projectPath: projectURL, agentName: "Claude")
let nameC = TmuxSessionNaming.sessionName(projectPath: projectURL, agentName: "Codex")
check("tmux name is deterministic", nameA == nameB)
check("tmux name distinguishes agents", nameA != nameC)
check("tmux name is bounded", nameA.count <= 70)
check("tmux name uses safe characters",
      nameA.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" })

// MARK: - SessionLifecycle

var lifecycle = SessionLifecycle.idle
check("idle cannot jump to running", !lifecycle.transition(to: .running))
check("idle can launch", lifecycle.transition(to: .launching))
check("launching can run", lifecycle.transition(to: .running))
check("running can detach", lifecycle.transition(to: .detached))
check("detached refuses exit-code overwrite",
      !lifecycle.transition(to: .exited(code: 0)) && lifecycle == .detached)
var exiting = SessionLifecycle.running
check("running can exit with code", exiting.transition(to: .exited(code: 3)))
check("exited is terminal", exiting.isTerminal)
check("launching is not terminal", !SessionLifecycle.launching.isTerminal)
check("detached is terminal", SessionLifecycle.detached.isTerminal)

// MARK: - POSIXExitStatus (raw waitpid status decoding)

check("exit 0 decodes to 0", POSIXExitStatus.decode(0) == 0)
check("exit 1 (raw 256) decodes to 1", POSIXExitStatus.decode(256) == 1)
check("exit 3 (raw 768) decodes to 3", POSIXExitStatus.decode(768) == 3)
check("exit 255 (raw 65280) decodes to 255", POSIXExitStatus.decode(65280) == 255)
check("SIGTERM (raw 15) decodes to 143", POSIXExitStatus.decode(15) == 143)
check("SIGKILL (raw 9) decodes to 137", POSIXExitStatus.decode(9) == 137)

// MARK: - Event log + renderer + receipt writer

withTempDir { dir in
    let logDir = dir.appendingPathComponent("worklog")
    let log = WorkSessionEventLog(directory: logDir, sessionID: "s1")
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    try log.append(.started(sessionID: "s1", projectSlug: "conduit", projectTitle: "Conduit",
                            projectPath: "/tmp/p", objective: "Initial objective", at: t0))
    try log.append(.agentLaunched(agent: "Claude", backend: "durable-requested", at: t0.addingTimeInterval(1)))
    try log.append(.objectiveChanged(text: "Refined objective", at: t0.addingTimeInterval(2)))
    try log.append(.terminalOutcome(agent: "Claude", title: "build", exitCode: 0,
                                    detached: false, live: false, at: t0.addingTimeInterval(3)))
    try log.append(.terminalOutcome(agent: "Codex", title: "review", exitCode: nil,
                                    detached: true, live: false, at: t0.addingTimeInterval(4)))

    let beforeClose = log.readEvents()
    check("event log roundtrips events", beforeClose.count == 5)
    // Compare standardized paths: /var vs /private/var on macOS.
    let interrupted = WorkSessionEventLog.interruptedLogs(in: logDir)
    check("interrupted log is detected",
          interrupted.map(\.url.lastPathComponent) == [log.url.lastPathComponent])

    // A torn final line (crash mid-write) must not poison the log.
    let handle = try FileHandle(forWritingTo: log.url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"broken".utf8))
    try handle.close()
    check("torn trailing line is skipped", log.readEvents().count == 5)

    let recovered = WorkSessionReceiptRenderer.render(events: log.readEvents(), recovered: true)
    check("recovered receipt renders", recovered != nil)
    check("recovered receipt is marked",
          recovered?.markdown.contains("## Recovery note") == true)

    try log.append(.gitSnapshot(summary: "branch: main", at: t0.addingTimeInterval(5)))
    try log.append(.closed(at: t0.addingTimeInterval(6)))
    check("closed log is no longer interrupted",
          WorkSessionEventLog.interruptedLogs(in: logDir).isEmpty)

    guard let rendered = WorkSessionReceiptRenderer.render(events: log.readEvents()) else {
        check("closed receipt renders", false)
        return
    }
    check("closed receipt renders", true)
    check("receipt keeps latest objective",
          rendered.markdown.contains("Refined objective") && !rendered.markdown.contains("Initial objective"))
    check("receipt records exit code", rendered.markdown.contains("observed exit code 0"))
    check("receipt records detach",
          rendered.markdown.contains("detached; process continuity delegated to tmux"))
    check("receipt records git snapshot", rendered.markdown.contains("branch: main"))
    check("receipt keeps evidence boundary",
          rendered.markdown.contains("Terminal prose is not treated as proof"))
    check("clean receipt has no recovery note",
          !rendered.markdown.contains("## Recovery note"))
    check("receipt ended-at comes from closed event",
          rendered.endedAt == t0.addingTimeInterval(6))

    // Writer: append-only, collision-safe, requires 20_live.
    let root = dir.appendingPathComponent("root")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("20_live"), withIntermediateDirectories: true)
    let writer = WorkSessionReceiptWriter()
    let first = try writer.write(root: root, receipt: rendered)
    let second = try writer.write(root: root, receipt: rendered)
    check("receipt files never collide", first != second)
    check("receipt lands under 20_live/conduit/sessions",
          first.path.contains("20_live/conduit/sessions"))
    let missingLive = dir.appendingPathComponent("no-live-root")
    try FileManager.default.createDirectory(at: missingLive, withIntermediateDirectories: true)
    check("writer refuses roots without 20_live",
          (try? writer.write(root: missingLive, receipt: rendered)) == nil)
}

// MARK: - Scanner + inbox + prompt assembly

withTempDir { root in
    try FileManager.default.createDirectory(at: root.appendingPathComponent("00_inbox"), withIntermediateDirectories: true)
    let project = root.appendingPathComponent("30_projects/demo")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try "# MainFrame".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "---\ntitle: \"Demo\"\nproject_state: \"active\"\n---\n".write(
        to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

    let projects = try MainframeScanner().scan(root: root)
    check("scanner finds root plus project", projects.count == 2 && projects[0].isMainframeRoot)
    check("scanner reads project metadata", projects[1].metadata.title == "Demo")

    let writer = InboxWriter(now: { Date(timeIntervalSince1970: 1_700_000_000) })
    let capture1 = try writer.capture(root: root, project: projects[1], text: "Remember this", attachments: [])
    let capture2 = try writer.capture(root: root, project: projects[1], text: "Remember this", attachments: [])
    check("inbox capture never overwrites", capture1 != capture2)
    let captureContent = try String(contentsOf: capture1, encoding: .utf8)
    check("inbox capture records provenance",
          captureContent.contains("conduit://project/demo"))

    let assembled = PromptAssembler.assemble(
        text: "Review these",
        attachments: [Attachment(url: URL(fileURLWithPath: "/tmp/a.png"))]
    )
    check("prompt assembler lists attachment paths",
          assembled.contains("Review these") && assembled.contains("/tmp/a.png"))

    let envelope = HostEnvelope.wrap(
        prompt: "say hello",
        context: HostEnvelope.Context(
            taskSessionID: "t1",
            projectPath: "/tmp/MainFrame",
            agentName: "Grok",
            surface: "conversation",
            tmuxSessionName: "conduit-mainframe-grok-1",
            attachmentCount: 0
        )
    )
    check("host envelope wraps CLI prompts",
          envelope.contains("<<CONDUIT_HOST")
            && envelope.contains("agent: Grok")
            && envelope.contains("say hello")
            && envelope.contains("not completion or verification"))
    check("host envelope skips shell agents",
          HostEnvelope.shouldInject(
              for: AgentProfile(name: "Shell", command: "/bin/zsh", kind: .shell)
          ) == false)
    check("host envelope skips Codex app-server",
          HostEnvelope.shouldInject(
              for: AgentProfile(name: "Codex", command: "codex")
          ) == false)
    check("host envelope skips Grok ACP",
          HostEnvelope.shouldInject(
              for: AgentProfile(name: "Grok", command: "grok")
          ) == false)
    check("host envelope still wraps PTY CLIs",
          HostEnvelope.shouldInject(
              for: AgentProfile(name: "Aider", command: "aider")
          ) == true)
    check("display text compacts blank runs",
          ConversationDisplayText.compactDerived("a\n\n\n\nb\n") == "a\n\nb")
    check(
        "workstation derived strips esc chrome",
        !ConversationDisplayText.workstationDerived(
            "Hello world\nesc to interrupt\n"
        ).lowercased().contains("esc to interrupt")
    )
    check(
        "workstation derived keeps prose",
        ConversationDisplayText.workstationDerived(
            "Hello world\nesc to interrupt\n"
        ).contains("Hello world")
    )
    let openCodePaint = """
        | /cost
        + Thought: 1.0s
        I should explain that /cost is built-in.
        /cost is an opencode built-in — token usage.
        Context
        10% used
        Build · Big Pickle · 3.8s
        """
    let openCodeDoc = ConversationDisplayText.workstationDerived(openCodePaint)
    check(
        "workstation derived keeps opencode answer",
        openCodeDoc.contains("opencode built-in")
    )
    check(
        "workstation derived drops opencode side panel",
        !openCodeDoc.contains("10% used")
    )
    check(
        "workstation derived drops duration-only thought chrome",
        !openCodeDoc.lowercased().contains("thought: 1.0s")
    )
    check(
        "workstation derived keeps thought content prose",
        openCodeDoc.contains("I should explain")
    )
    let proseBlocks = ConversationDisplayText.proseBlocks(
        in: "## Title\n\nBody line.\n"
    )
    check("prose blocks parse heading", {
        guard proseBlocks.count >= 2,
              case .heading(let level, let text) = proseBlocks[0]
        else { return false }
        return level == 2 && text == "Title"
    }())
    let turnOpen = SessionPresentation.openingEvent(
        .started(agentName: "A", requestedBackend: "tmux")
    )
    let turnPrompt = SessionPresentation.promptEvent(
        text: "hi",
        attachmentPaths: [],
        renderedPayload: "hi"
    )
    let turnOutput = SessionPresentation.agentOutputEvent(
        promptEventID: turnPrompt.id,
        text: "yo",
        extraction: .tmuxPane,
        truncated: false
    )
    let turns = SessionPresentation.conversationTurns(
        from: [turnOpen, turnPrompt, turnOutput]
    )
    check("conversation turns group prompt+output", turns.count == 2)
    check("slash catalog recognizes /compact",
          AgentSlashCatalog.looksLikeSlashCommand("/compact"))
    check("slash catalog rejects absolute paths",
          AgentSlashCatalog.looksLikeSlashCommand("/Users/admin/x") == false)
    check(
        "slash catalog matches /com to compact",
        AgentSlashCatalog.matches(query: "/com", projectPath: nil)
            .contains(where: { $0.command == "/compact" })
    )

    let agyAuto = AgentProfile(
        name: "Antigravity",
        command: "agy",
        permissionMode: .fullAuto
    )
    check("permission mode injects agy full-auto flag",
          AgentLaunchArguments.resolved(for: agyAuto)
            .contains("--dangerously-skip-permissions"))
    check("shell ignores permission mode flags",
          AgentLaunchArguments.resolved(
              for: AgentProfile(
                  name: "Shell",
                  command: "/bin/zsh",
                  arguments: ["-l"],
                  kind: .shell,
                  permissionMode: .fullAuto
              )
          ) == ["-l"])
    let ollamaModel = AgentProfile(
        name: "Ollama",
        command: "ollama",
        arguments: ["--verbose"],
        model: "qwen3.5:9b",
        modelLaunchStyle: .ollamaRun
    )
    check("ollama model selection uses run positional model",
          AgentLaunchArguments.resolved(for: ollamaModel)
            == ["run", "qwen3.5:9b", "--verbose"])
    let cursorModel = AgentProfile(
        name: "Cursor Agent",
        command: "cursor-agent",
        arguments: ["--model", "old-model"],
        model: "new-model"
    )
    check("model flag selection replaces authored model",
          AgentLaunchArguments.resolved(for: cursorModel)
            == ["--model", "new-model"])
    let geminiModel = AgentProfile(
        name: "Gemini CLI",
        command: "gemini",
        model: "gemini-model"
    )
    check("Gemini CLI model selection uses the common model flag",
          AgentLaunchArguments.resolved(for: geminiModel)
            == ["--model", "gemini-model"])
    let aiderModel = AgentProfile(
        name: "Aider",
        command: "aider",
        model: "ollama/qwen3.5:9b"
    )
    check("Aider model selection uses the common model flag",
          AgentLaunchArguments.resolved(for: aiderModel)
            == ["--model", "ollama/qwen3.5:9b"])
    check("visible context estimator has a positive display estimate",
          VisibleContextEstimator.approximateTokens("visible prompt") > 0)
}

// MARK: - Context bundle + forwarder

withTempDir { dir in
    try "# P\nImportant context".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try "# D\nUse evidence.".write(to: dir.appendingPathComponent("decisions.md"), atomically: true, encoding: .utf8)
    let project = MainframeProject(
        slug: "p", path: dir,
        readmePath: dir.appendingPathComponent("README.md"),
        metadata: ProjectMetadata(title: "P")
    )
    let builder = ContextBundleBuilder()
    let candidates = builder.candidates(for: project)
    check("bundle nominates coordination files", candidates.count == 2)
    let bundle = builder.assemble(documents: candidates)
    check("bundle carries trust labels", bundle.markdown.contains("Trust label"))
    check("bundle is inspection not verification",
          bundle.markdown.contains("not verification"))
    let tiny = builder.assemble(documents: candidates, maximumBytes: 120)
    check("bundle marks truncation", tiny.truncated)
}

let forwarded = TerminalForwarder.prompt(selection: "Done!", sourceAgent: "Claude", destinationAgent: "Codex")
check("forwarder wraps with evidence boundary",
      forwarded.contains("unverified terminal output") && forwarded.contains("Re-run deterministic checks"))
check("forwarder keeps the selection", forwarded.contains("Done!"))

// MARK: - Multi-instance naming and session discovery

let instProject = URL(fileURLWithPath: "/tmp/MainFrame/30_projects/conduit")
let instBase = TmuxSessionNaming.sessionName(projectPath: instProject, agentName: "Claude")

// Instance 1 must keep the historic name, or every session created before
// multi-instance support becomes unreachable.
check("instance 1 keeps the legacy name",
      TmuxSessionNaming.sessionName(projectPath: instProject, agentName: "Claude", instance: 1) == instBase)
check("later instances get distinct names",
      TmuxSessionNaming.sessionName(projectPath: instProject, agentName: "Claude", instance: 2) == "\(instBase)-2")
check("instance names stay unique",
      Set([1, 2, 3].map {
          TmuxSessionNaming.sessionName(projectPath: instProject, agentName: "Claude", instance: $0)
      }).count == 3)
check("next instance is 1 when nothing exists",
      TmuxSessionNaming.nextInstance(projectPath: instProject, agentName: "Claude", existingNames: []) == 1)
check("next instance skips taken names",
      TmuxSessionNaming.nextInstance(
          projectPath: instProject,
          agentName: "Claude",
          existingNames: [instBase, "\(instBase)-2"]
      ) == 3)
// A detached session still occupies its name; reusing it would silently
// reattach to someone else's session instead of opening a new one.
check("next instance avoids a detached session's name",
      TmuxSessionNaming.nextInstance(
          projectPath: instProject,
          agentName: "Claude",
          existingNames: ["\(instBase)-2"]
      ) == 1)

// Parsed against output captured from a real tmux 3.6 server. The identity
// options are unset here — this is exactly the shape a session created before
// they existed produces, and it must survive rather than be dropped.
let sep = TmuxSessionListParser.fieldSeparator
// tmux rewrites control bytes in -F output to "_", which silently merged every
// field into one. The separator must stay printable or discovery goes blind.
check("field separator contains no control characters",
      !sep.unicodeScalars.contains { $0.properties.generalCategory == .control })
check("format uses the separator between all six fields",
      TmuxSessionListParser.format.components(separatedBy: sep).count == 6)
let legacyLine = "conduit-mainframe-shell-39764712\(sep)1785245247\(sep)0\(sep)\(sep)"
let legacyParsed = TmuxSessionListParser.parse(legacyLine + "\n")
check("parses a session with no identity options", legacyParsed.count == 1)
check("keeps the tmux name", legacyParsed.first?.tmuxName == "conduit-mainframe-shell-39764712")
check("reads creation time", legacyParsed.first?.createdAt == Date(timeIntervalSince1970: 1_785_245_247))
check("leaves identity nil rather than inventing it",
      legacyParsed.first?.projectPath == nil && legacyParsed.first?.agentName == nil)
check("unidentified session is not marked identified", legacyParsed.first?.isIdentified == false)
check("legacy five-field discovery has an absent task binding",
      legacyParsed.first?.taskSessionBinding == .absent)

let emptyTaskBindingParsed = TmuxSessionListParser.parse(legacyLine + sep)
check("empty sixth discovery field has an absent task binding",
      emptyTaskBindingParsed.first?.taskSessionBinding == .absent)

let fullLine = "conduit-x\(sep)1785245247\(sep)2\(sep)/tmp/MainFrame/30_projects/conduit\(sep)Claude"
let fullParsed = TmuxSessionListParser.parse(fullLine)
check("reads recorded identity", fullParsed.first?.agentName == "Claude")
check("reads recorded project",
      fullParsed.first?.projectPath?.standardizedFileURL.path == "/tmp/MainFrame/30_projects/conduit")
check("reads attached client count", fullParsed.first?.attachedClients == 2)
check("identified session reports identified", fullParsed.first?.isIdentified == true)

let tmuxBindingTaskID = TaskSessionID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
)
let boundLine = fullLine + sep + tmuxBindingTaskID.rawValue.uuidString.lowercased()
let boundParsed = TmuxSessionListParser.parse(boundLine)
check("reads a valid task-session binding",
      boundParsed.first?.taskSessionBinding == .valid(tmuxBindingTaskID)
        && boundParsed.first?.taskSessionBinding.taskSessionID == tmuxBindingTaskID)

let malformedTaskBinding = "not-a-task-session-uuid"
let malformedBindingLine = fullLine + sep + malformedTaskBinding
let malformedBindingParsed = TmuxSessionListParser.parse(malformedBindingLine)
check("preserves a malformed task-session binding instead of treating it as absent",
      malformedBindingParsed.first?.taskSessionBinding
        == .malformed(rawValue: malformedTaskBinding)
        && malformedBindingParsed.first?.taskSessionBinding.taskSessionID == nil)

check("ignores sessions Conduit did not create",
      TmuxSessionListParser.parse("other-session\(sep)1\(sep)0\(sep)\(sep)").isEmpty)
check("ignores malformed lines",
      TmuxSessionListParser.parse("conduit-broken").isEmpty)
check("parses multiple lines", TmuxSessionListParser.parse("\(legacyLine)\n\(fullLine)\n").count == 2)

// Resuming a session with no recorded identity must not write the display
// placeholder back as if it were known — that would turn a guess into a record.
let unidentifiedResume = SessionDescriptor(
    projectPath: instProject,
    agent: AgentProfile(name: "Unidentified", command: "/bin/zsh", kind: .shell),
    tmuxSessionName: "conduit-legacy",
    recordsIdentity: DiscoveredSession(tmuxName: "conduit-legacy").isIdentified
)
check("resuming an unidentified session records no identity",
      unidentifiedResume.recordsIdentity == false)
let identifiedResume = SessionDescriptor(
    projectPath: instProject,
    agent: AgentProfile(name: "Claude", command: "claude"),
    tmuxSessionName: "conduit-known",
    recordsIdentity: DiscoveredSession(
        tmuxName: "conduit-known", projectPath: instProject, agentName: "Claude"
    ).isIdentified
)
check("resuming a known session keeps recording identity",
      identifiedResume.recordsIdentity == true)
let defaultTaskDescriptor = SessionDescriptor(
    projectPath: instProject,
    agent: AgentProfile(name: "Claude", command: "claude")
)
check("a freshly launched session records identity by default",
      defaultTaskDescriptor.recordsIdentity)
check("session descriptor task identity defaults to absent",
      defaultTaskDescriptor.taskSessionID == nil)
check("session descriptor reconnect safeguards default off",
      defaultTaskDescriptor.adoptsLegacyTaskSession == false
        && defaultTaskDescriptor.requiresExistingTmuxSession == false)

let boundTaskDescriptor = SessionDescriptor(
    projectPath: instProject,
    agent: AgentProfile(name: "Codex", command: "codex"),
    tmuxSessionName: "conduit-bound",
    taskSessionID: tmuxBindingTaskID,
    adoptsLegacyTaskSession: true,
    requiresExistingTmuxSession: true
)
check("session descriptor task identity round-trips",
      (try? JSONDecoder().decode(
        SessionDescriptor.self,
        from: JSONEncoder().encode(boundTaskDescriptor)
      )) == boundTaskDescriptor)

let discEpoch = Date(timeIntervalSince1970: 1_800_000_000)
let discOther = URL(fileURLWithPath: "/tmp/MainFrame/30_projects/other")
let discovered = [
    DiscoveredSession(tmuxName: "conduit-a", projectPath: instProject, agentName: "Claude",
                      createdAt: discEpoch, attachedClients: 0),
    DiscoveredSession(tmuxName: "conduit-b", projectPath: instProject, agentName: "Codex",
                      createdAt: discEpoch.addingTimeInterval(60), attachedClients: 0),
    DiscoveredSession(tmuxName: "conduit-c", projectPath: discOther, agentName: "Grok",
                      createdAt: discEpoch, attachedClients: 1),
    DiscoveredSession(tmuxName: "conduit-legacy", createdAt: nil, attachedClients: 0)
]
let classified = DiscoveredSessionCatalog.classify(
    discovered: discovered,
    selectedProjectPath: instProject,
    openTmuxNames: ["conduit-b"],
    knownProjects: [discOther: "Other Project"]
)
func relation(_ name: String) -> DiscoveredSessionRelation? {
    classified.first { $0.session.tmuxName == name }?.relation
}
check("discovery keeps every session", classified.count == discovered.count)
check("same-project session is resumable here", relation("conduit-a") == .resumableHere)
check("already-open session is marked open", relation("conduit-b") == .alreadyOpen)
check("other project is named", relation("conduit-c") == .otherProject(projectTitle: "Other Project"))
// A session with no recorded identity must stay visible and stay unclaimed —
// hiding it would imply tmux is empty, and guessing would invent an owner.
check("unidentified session is listed, not dropped", relation("conduit-legacy") == .unidentified)
check("unidentified session is not claimed by the selected project",
      relation("conduit-legacy") != .resumableHere)
check("resumable-here sorts first", classified.first?.session.tmuxName == "conduit-a")
check("unidentified sorts last", classified.last?.session.tmuxName == "conduit-legacy")
check("attached-elsewhere is reported, not hidden",
      classified.first { $0.session.tmuxName == "conduit-c" }?.session.attachedClients == 1)

// With no project selected nothing may be claimed as resumable here.
let unscoped = DiscoveredSessionCatalog.classify(
    discovered: discovered,
    selectedProjectPath: nil,
    openTmuxNames: [],
    knownProjects: [:]
)
check("no selected project means nothing is resumable here",
      !unscoped.contains { $0.relation == .resumableHere })

// MARK: - Tier A observed usage

let usageEpoch = Date(timeIntervalSince1970: 1_800_000_000)
func usageRecord(
    _ agent: String,
    seconds: TimeInterval,
    outcome: SessionUsageRecord.Outcome,
    bytes: Int = 0,
    delivered: Int = 0,
    failed: Int = 0
) -> SessionUsageRecord {
    SessionUsageRecord(
        agent: agent,
        projectSlug: "conduit",
        startedAt: usageEpoch,
        endedAt: usageEpoch.addingTimeInterval(seconds),
        outcome: outcome,
        outputBytes: bytes,
        promptsDelivered: delivered,
        promptsFailed: failed
    )
}

let usageRecords = [
    usageRecord("Claude", seconds: 60, outcome: .exitedClean, bytes: 100, delivered: 2),
    usageRecord("Claude", seconds: 30, outcome: .detached, bytes: 50, delivered: 1, failed: 1),
    usageRecord("Grok", seconds: 10, outcome: .exitedFailed, bytes: 7)
]
let usageRoster = ["Shell", "Claude", "Codex", "Antigravity", "Grok", "OpenCode"]
let usageRows = AgentUsageLedger.aggregate(
    records: usageRecords,
    roster: usageRoster,
    now: usageEpoch
)

check("usage keeps one row per configured agent", usageRows.count == usageRoster.count)
check("usage rows follow roster order", usageRows.map(\.agent) == usageRoster)

let claudeUsage = usageRows.first { $0.agent == "Claude" }
check("usage sums sessions per agent", claudeUsage?.sessions == 2)
check("usage sums attached seconds", claudeUsage?.attachedSeconds == 90)
check("usage sums output bytes", claudeUsage?.outputBytes == 150)
check("usage separates delivered from failed prompts",
      claudeUsage?.promptsDelivered == 3 && claudeUsage?.promptsFailed == 1)
check("usage counts outcomes distinctly",
      claudeUsage?.cleanExits == 1 && claudeUsage?.detaches == 1 && claudeUsage?.failedExits == 0)
check("usage records a failed exit as failed",
      usageRows.first { $0.agent == "Grok" }?.failedExits == 1)

// An agent Conduit never ran must read as zero *observed* sessions rather than
// vanish — absence of a row would read as "no data exists anywhere", which is a
// broader claim than Conduit can make.
let antigravityUsage = usageRows.first { $0.agent == "Antigravity" }
check("unused agent still gets a row", antigravityUsage != nil)
check("unused agent reads zero observed sessions", antigravityUsage?.sessions == 0)
check("unused agent reads zero live sessions", antigravityUsage?.liveSessions == 0)

// Live sessions count toward totals but stay separately visible, so the UI can
// never present a still-running session as a completed one.
let liveRows = AgentUsageLedger.aggregate(
    records: usageRecords,
    live: [
        LiveSessionUsage(
            agent: "Codex",
            startedAt: usageEpoch,
            outputBytes: 12,
            promptsDelivered: 1,
            promptsFailed: 0
        )
    ],
    roster: usageRoster,
    now: usageEpoch.addingTimeInterval(45)
)
let codexUsage = liveRows.first { $0.agent == "Codex" }
check("live session counts toward sessions", codexUsage?.sessions == 1)
check("live session stays separately visible", codexUsage?.liveSessions == 1)
check("live session accrues elapsed time", codexUsage?.attachedSeconds == 45)

// A clock adjustment must never bank negative time against an agent.
let skewedRows = AgentUsageLedger.aggregate(
    records: [usageRecord("Claude", seconds: -500, outcome: .exitedClean)],
    roster: ["Claude"],
    now: usageEpoch
)
check("backwards clock never yields negative time",
      skewedRows.first?.attachedSeconds == 0)

// History for an agent no longer in the roster must still be reported.
let retiredRows = AgentUsageLedger.aggregate(
    records: [usageRecord("Gemini", seconds: 20, outcome: .exitedClean)],
    roster: ["Claude"],
    now: usageEpoch
)
check("retired agent history is not dropped",
      retiredRows.contains { $0.agent == "Gemini" && $0.sessions == 1 })

// The log round-trips and heals a torn final line, like the event log.
let usageLogURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("conduit-usage-\(UUID().uuidString)")
    .appendingPathComponent("observed-usage.jsonl")
let usageLog = AgentUsageLog(url: usageLogURL)
do {
    try usageLog.append(usageRecords[0])
    try usageLog.append(usageRecords[1])
    let handle = try FileHandle(forUpdating: usageLogURL)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"partial\":".utf8))
    try handle.close()
    try usageLog.append(usageRecords[2])
    let readBack = usageLog.readRecords()
    check("usage log round-trips records", readBack.count == 3)
    check("usage log preserves values", readBack.first == usageRecords[0])
} catch {
    check("usage log round-trips records", false)
    check("usage log preserves values", false)
}
try? FileManager.default.removeItem(at: usageLogURL.deletingLastPathComponent())

// The root guard mirrors the receipt writer: no 20_live, no writing.
let strayRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("conduit-stray-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: strayRoot, withIntermediateDirectories: true)
check("usage log refuses roots without 20_live", AgentUsageLog(mainframeRoot: strayRoot) == nil)
try? FileManager.default.createDirectory(
    at: strayRoot.appendingPathComponent("20_live"),
    withIntermediateDirectories: true
)
check("usage log accepts a live root", AgentUsageLog(mainframeRoot: strayRoot) != nil)
try? FileManager.default.removeItem(at: strayRoot)

let meterScales = AgentUsageMeters.Scales.from([
    AgentObservedUsage(agent: "A", attachedSeconds: 100, outputBytes: 50, promptsDelivered: 2),
    AgentObservedUsage(agent: "B", attachedSeconds: 50, outputBytes: 200, promptsDelivered: 8),
])
check("usage meters take max attached", meterScales.maxAttachedSeconds == 100)
check("usage meters take max bytes", meterScales.maxOutputBytes == 200)
check(
    "usage meters fraction caps at 1",
    AgentUsageMeters.fraction(150, of: 100) == 1
)
check(
    "usage meters fraction zero when max zero",
    AgentUsageMeters.fraction(10, of: 0) == 0
)

let weekNow = Date(timeIntervalSince1970: 1_800_000_000)
let weekRecord = SessionUsageRecord(
    agent: "Claude",
    projectSlug: "demo",
    startedAt: weekNow.addingTimeInterval(-3600),
    endedAt: weekNow.addingTimeInterval(-1800),
    outcome: .exitedClean,
    outputBytes: 10,
    promptsDelivered: 3,
    promptsFailed: 0
)
let weekLive = LiveSessionUsage(
    agent: "Claude",
    startedAt: weekNow.addingTimeInterval(-600),
    outputBytes: 1,
    promptsDelivered: 1,
    promptsFailed: 0
)
let weekUse = AgentUsageMeters.weekUsage(
    agent: "Claude",
    records: [weekRecord],
    live: [weekLive],
    now: weekNow
)
check("week usage counts session prompts", weekUse.totalPrompts == 4)
check("week usage counts live session prompts", weekUse.liveSessionPrompts == 1)
check(
    "usage budget unset when zeros",
    AgentUsageBudget().hasAnyLimit == false
)
check(
    "usage budget set when weekly prompts",
    AgentUsageBudget(weeklyPromptLimit: 50).hasAnyLimit
)

let claudeUsageJSON = """
{"five_hour":{"utilization":20.0,"resets_at":"2026-08-08T01:00:00Z"},"seven_day":{"utilization":83.0,"resets_at":"2026-08-09T18:00:00Z"}}
""".data(using: .utf8)!
let claudeSnap = try! AccountUsageParsing.parseClaudeOAuthUsage(claudeUsageJSON)
check("claude usage parses two windows", claudeSnap.windows.count == 2)
check(
    "claude usage five hour percent",
    abs((claudeSnap.windows.first?.usedPercent ?? 0) - 20) < 0.01
)
let codexUsageJSON = """
{"result":{"rateLimits":{"primary":{"usedPercent":85,"windowDurationMins":10080,"resetsAt":1786296107},"secondary":null,"planType":"plus"}}}
""".data(using: .utf8)!
let codexSnap = try! AccountUsageParsing.parseCodexRateLimits(codexUsageJSON)
check("codex usage parses primary", codexSnap.windows.first?.usedPercent == 85)
check("codex usage agent name", codexSnap.agentName == "Codex")

let mgJSON = """
[{"doc_id":"d1","chunk_index":0,"display_path":"10_knowledge/x.md","title":"X","chunk_text":"hello","trust_profile":"durable_knowledge","rrf_score":0.03,"signal":"fused"}]
""".data(using: .utf8)!
let mgHits = (try? MindGraphQuerySupport.decodeHits(from: mgJSON, scope: .knowledge)) ?? []
check("mindgraph decodes one hit", mgHits.count == 1 && mgHits.first?.title == "X")
check(
    "mindgraph scope knowledge trust",
    MindGraphScope.knowledge.trustProfile == "durable_knowledge"
)
check(
    "mindgraph scope projects trust",
    MindGraphScope.projects.trustProfile == "project_status"
)

// MARK: - Focus Board (workstation port, pure)

check("focus weekly stale days", FocusBoardConstants.weeklyStaleDays == 8)
check("focus active cap", FocusBoardConstants.activeCap == 10)
check("focus parseJsonl skips bad lines", FocusBoard.parseJsonl("{not json\n{\"a\":1}\n").count == 1)
let missingBoard = FocusBoard.buildFocusBoard(
    FocusBoardInputs(feedsMissing: true, fixture: true)
)
check("focus missing feeds insufficient", missingBoard.insufficient)
check("focus missing feeds not empty success", missingBoard.items.first?.source == .feedsMissing)
check(
    "focus missing feeds title",
    missingBoard.items.first?.title.contains("No truth feeds") == true
)
let wipBoard = FocusBoard.buildFocusBoard(
    FocusBoardInputs(
        scheduleRuns: [
            FocusBoardJSON([
                "fixture": .bool(true),
                "run_id": .string("weekly"),
                "cadence": .string("weekly"),
                "all_passed": .bool(true),
                "finished_at": .string("2026-07-12T10:05:00+00:00"),
            ]),
        ],
        projectIndex: FocusBoardProjectIndexSummary(
            activeCount: 11,
            activeCap: 10,
            problems: [
                FocusBoardProjectProblem(
                    code: "missing_frontmatter",
                    project: "repo-radar",
                    detail: "missing project_state frontmatter"
                ),
            ],
            fixture: true
        ),
        nowMs: 1_783_879_200_000,
        fixture: true
    )
)
check("focus wip first is urgent", wipBoard.items.first?.severity == .urgent)
check("focus wip breach id", wipBoard.items.contains { $0.id == "project-wip-breach" })
let rankedFocus = FocusBoard.rankFocusItems([
    FocusBoardItem(
        id: "i",
        severity: .info,
        title: "i",
        detail: "",
        source: .sessionClose,
        evidencePath: "p",
        asOf: "2026-07-12"
    ),
    FocusBoardItem(
        id: "u",
        severity: .urgent,
        title: "u",
        detail: "",
        source: .sessionClose,
        evidencePath: "p",
        asOf: "2026-07-12"
    ),
    FocusBoardItem(
        id: "w",
        severity: .watch,
        title: "w",
        detail: "",
        source: .sessionClose,
        evidencePath: "p",
        asOf: "2026-07-10"
    ),
])
check("focus rank urgent first", rankedFocus.first?.id == "u")
check("focus bin evidence not viewable", !FocusBoard.isViewableEvidencePath("bin/ingest-status"))
check(
    "focus relative jsonl viewable",
    FocusBoard.isViewableEvidencePath("20_live/workstation/session-close-feed.jsonl")
)

// MARK: - Optional real-tree smoke (set CONDUIT_SMOKE_ROOT=/path/to/MainFrame)

if let smokeRoot = ProcessInfo.processInfo.environment["CONDUIT_SMOKE_ROOT"] {
    let root = URL(fileURLWithPath: smokeRoot)
    do {
        let projects = try MainframeScanner().scan(root: root)
        check("real-tree scan finds the root workspace", projects.first?.isMainframeRoot == true)
        check("real-tree scan discovers projects", projects.count > 1)
        let bundleBuilder = ContextBundleBuilder()
        // Exercise the exact candidate/assemble path the UI's bundle uses.
        var bundleOK = true
        for project in projects.prefix(6) {
            let candidates = bundleBuilder.candidates(for: project)
            let bundle = bundleBuilder.assemble(documents: candidates)
            if !candidates.isEmpty && !bundle.markdown.contains("Trust label") { bundleOK = false }
        }
        check("real-tree context bundles assemble", bundleOK)
        let closeText = try? String(
            contentsOf: root.appendingPathComponent(FocusBoardPaths.sessionClose),
            encoding: .utf8
        )
        let scheduleText = try? String(
            contentsOf: root.appendingPathComponent(FocusBoardPaths.scheduleRuns),
            encoding: .utf8
        )
        let indexText = try? String(
            contentsOf: root.appendingPathComponent(FocusBoardPaths.projectIndex),
            encoding: .utf8
        )
        let liveBoard = FocusBoard.buildFocusBoard(
            FocusBoardInputs(
                sessionCloseRecords: closeText.map { FocusBoard.parseJsonl($0) },
                scheduleRuns: scheduleText.map { FocusBoard.parseJsonl($0) },
                projectIndex: indexText.map {
                    FocusBoard.parseProjectIndexMarkdown($0, asOf: "smoke")
                }
            )
        )
        check(
            "real-tree focus board is a projection",
            !liveBoard.items.isEmpty && liveBoard.items.allSatisfy { !$0.title.isEmpty }
        )
        check(
            "real-tree missing feeds stay honest",
            !liveBoard.insufficient || liveBoard.items.first?.source == .feedsMissing
        )
        print("   ↳ scanned \(projects.count - 1) projects under \(root.lastPathComponent):")
        for project in projects.dropFirst().prefix(8) {
            let state = project.metadata.projectState ?? project.metadata.status ?? "—"
            print("     • \(project.slug)  [\(state)]  \(project.metadata.title)")
        }
    } catch {
        check("real-tree scan (\(error.localizedDescription))", false)
    }
}

// Optional installed-config smoke. This detects schema drift without baking a
// user-specific path into the republishable product.
if let configPath = ProcessInfo.processInfo.environment["CONDUIT_CONFIG_PATH"] {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        let config = try JSONDecoder().decode(ConduitSettings.self, from: data)
        check("saved config decodes", true)
        check("saved config retains MainFrame root", config.mainframeRoot != nil)
    } catch {
        check("saved config decodes (\(error.localizedDescription))", false)
    }
}

// MARK: - Codex app-server mapping (D-038)

var mapper = CodexAppServerMapper()
let mappedDelta = mapper.apply(
    .notification(
        method: "item/agentMessage/delta",
        params: .object(["delta": .string("Hi")])
    )
)
check(
    "app-server mapper grows structured text",
    mappedDelta == [.upsertOutput(text: "Hi", state: .live)]
)
var chromeMapper = CodexAppServerMapper()
let chromeEffects = chromeMapper.apply(
    .notification(
        method: "item/started",
        params: .object([
            "item": .object(["type": .string("userMessage")])
        ])
    )
)
check("app-server mapper skips userMessage chrome", chromeEffects.isEmpty)
if case .object(let object) = CodexJSON.parseLine("{\"id\":1,\"ok\":true}"),
   case .number = object["id"],
   case .bool(true) = object["ok"] {
    check("JSON 1 stays a number, true stays a bool", true)
} else {
    check("JSON 1 stays a number, true stays a bool", false)
}
check(
    "Codex profile prefers app-server",
    AgentProfile(name: "Codex", command: "codex").preferredSessionBackend == .appServer
)
check(
    "Claude profile prefers stream-json",
    AgentProfile(name: "Claude", command: "claude").preferredSessionBackend == .structuredCli
)
check(
    "Grok profile prefers ACP",
    AgentProfile(name: "Grok", command: "grok").preferredSessionBackend == .acp
)
check(
    "OpenCode profile prefers HTTP",
    AgentProfile(name: "OpenCode", command: "opencode").preferredSessionBackend == .httpServer
)
check(
    "Gemini CLI prefers ACP",
    AgentProfile(name: "Gemini CLI", command: "gemini").preferredSessionBackend == .acp
)
check(
    "session API list_adapters is read-only",
    !ConduitSessionAPI.isWrite(.listAdapters)
)
check(
    "session API rejects blended MindGraph scope",
    !ConduitSessionAPI.allowsMindGraphScope("both")
)
check(
    "session API matches Codex by command name",
    ConduitSessionAPI.matchesAgent(
        AgentProfile(name: "Codex", command: "codex"),
        name: "codex"
    )
)
check(
    "session API write flag defaults off",
    ConduitSettings().enableSessionAPIWrites == false
)
check(
    "session events tool is read-only",
    !ConduitSessionAPI.isWrite(
        .sessionEvents(taskSessionID: "t", cursor: "v1:0", limit: 2)
    )
)
check(
    "session API bootstrap keeps reads available",
    ConduitSessionAPI.allowsCommand(
        .listProjects,
        readiness: .bootstrapping
    )
)
check(
    "session API bootstrap blocks writes",
    !ConduitSessionAPI.allowsCommand(
        .createTask(
            agent: "Shell",
            projectSlug: "synthetic",
            objective: "",
            idempotencyKey: nil
        ),
        readiness: .mainframeAuthorizationRequired
    )
)
check(
    "session API ready state allows writes",
    ConduitSessionAPI.allowsCommand(
        .createTask(
            agent: "Shell",
            projectSlug: "synthetic",
            objective: "",
            idempotencyKey: nil
        ),
        readiness: .ready
    )
)
check(
    "session API readyz status is fail-closed before READY",
    ConduitSessionAPIReadiness.mainframeScanFailed.httpStatusCode == 503
        && ConduitSessionAPIReadiness.ready.httpStatusCode == 200
)
do {
    let stamp = Date(timeIntervalSince1970: 1_787_000_000)
    let supervisoryAttemptID = RuntimeAttemptID(
        rawValue: UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
    )
    let prompt = SessionPresentation.promptEvent(
        origin: .chatgpt,
        text: "Use Bearer sk-test-secret-abcdefg",
        attachmentPaths: ["/tmp/a.md"],
        renderedPayload: "hidden",
        occurredAt: stamp
    )
    let output = SessionPresentation.agentOutputEvent(
        promptEventID: prompt.id,
        text: "Pong from adapter",
        state: .closed,
        extraction: .structuredAdapter,
        truncated: false,
        occurredAt: stamp.addingTimeInterval(1)
    )
    let ptyOutput = SessionPresentation.agentOutputEvent(
        promptEventID: prompt.id,
        text: "quiet pane",
        state: .settled,
        extraction: .tmuxPane,
        truncated: false,
        occurredAt: stamp.addingTimeInterval(1)
    )
    let events = (0..<3).map { index in
        SessionPresentation.promptEvent(
            origin: .chatgpt,
            text: "n\(index)",
            attachmentPaths: [],
            renderedPayload: "n\(index)",
            occurredAt: stamp.addingTimeInterval(Double(index))
        )
    }
    let firstPage = ConduitSessionEventExport.page(
        source: ConduitSessionEventSource(
            taskSessionID: "task",
            backend: .pty,
            sessionLifecycle: "running",
            runtimeState: "running",
            live: true,
            ready: true,
            events: events
        ),
        limit: 2
    )
    let latePage = ConduitSessionEventExport.page(
        source: ConduitSessionEventSource(
            taskSessionID: "task",
            backend: .pty,
            sessionLifecycle: "running",
            runtimeState: "running",
            live: true,
            ready: true,
            events: events + [ptyOutput]
        ),
        cursor: firstPage.nextCursor,
        limit: 2
    )
    let stale = ConduitSessionEventExport.page(
        source: ConduitSessionEventSource(
            taskSessionID: "task",
            backend: .pty,
            sessionLifecycle: "running",
            runtimeState: "running",
            live: true,
            ready: true,
            events: events
        ),
        cursor: "v1:9"
    )
    let secretPage = ConduitSessionEventExport.page(
        source: ConduitSessionEventSource(
            taskSessionID: "task",
            backend: .pty,
            sessionLifecycle: "running",
            runtimeState: "running",
            live: true,
            ready: true,
            events: [prompt]
        )
    )
    let codexPage = ConduitSessionEventExport.page(
        source: ConduitSessionEventSource(
            taskSessionID: "task",
            backend: .appServer,
            sessionLifecycle: "running",
            runtimeState: "running",
            live: true,
            ready: true,
            events: [prompt, output],
            adapter: ConduitSessionAdapterSnapshot(
                threadID: "thr",
                lastTurnStatus: "completed"
            ),
            runtimeAttemptID: supervisoryAttemptID,
            observedAt: stamp.addingTimeInterval(2)
        )
    )
    let ptyPage = ConduitSessionEventExport.page(
        source: ConduitSessionEventSource(
            taskSessionID: "task",
            backend: .pty,
            sessionLifecycle: "running",
            runtimeState: "running",
            live: true,
            ready: true,
            events: [prompt, ptyOutput]
        )
    )
    let persistedPage = ConduitSessionEventExport.page(
        source: ConduitSessionEventSource(
            taskSessionID: "task",
            backend: .appServer,
            sessionLifecycle: "runtime_missing",
            runtimeState: "absent",
            live: false,
            ready: false,
            events: [prompt],
            persistedThreadID: "thr_persisted",
            observedAt: stamp.addingTimeInterval(3)
        )
    )
    let approvalPage = ConduitSessionEventExport.page(
        source: ConduitSessionEventSource(
            taskSessionID: "task",
            backend: .appServer,
            sessionLifecycle: "running",
            runtimeState: "running",
            live: true,
            ready: true,
            events: [prompt],
            adapter: ConduitSessionAdapterSnapshot(
                threadID: "thr",
                turnActive: true,
                pendingApproval: true,
                pendingApprovalSummary: "git status"
            )
        )
    )
    check("session events paginate with next cursor", firstPage.nextCursor == "v1:2" && firstPage.hasMore)
    check(
        "session events surface late items after cursor",
        latePage.events.map(\.kind) == ["user_prompt", "agent_output"]
            && latePage.events.last?.text == "quiet pane"
    )
    check("session events mark stale ahead cursor", stale.cursorState == .ahead && stale.events.isEmpty)
    check("session events redact secrets", secretPage.events.first?.redacted == true && secretPage.events.first?.text?.contains("sk-test-secret") != true)
    check("session events keep Codex turn completed distinct from running session", codexPage.turn.state == "completed" && codexPage.session.lifecycle == "running")
    check("session events keep PTY quiet ambiguous", ptyPage.turn.state == "ambiguous" && ptyPage.turn.ambiguity == "pty_output_quiet")
    check("session events label structured Codex output", codexPage.events.last?.authority == "toolReported" && codexPage.events.last?.turnStatus == "completed")
    check("session events expose runtime attempt", codexPage.runtimeAttemptID == supervisoryAttemptID)
    check(
        "session events expose live provider thread",
        codexPage.turn.threadIDSource == ConduitSessionProviderThreadSource.live
    )
    check(
        "session events expose structured checkpoint",
        codexPage.observation.checkpoint == ConduitSessionObservationCheckpoint.structuredCompleted
            && codexPage.observation.providerProgress == ConduitSessionProviderProgress.structured
    )
    check(
        "session events keep PTY checkpoint observational",
        ptyPage.observation.checkpoint == ConduitSessionObservationCheckpoint.outputQuiet
            && ptyPage.observation.providerProgress == ConduitSessionProviderProgress.unavailable
            && ptyPage.observation.inputState == ConduitSessionInputState.unknown
    )
    check(
        "session events expose persisted provider thread",
        persistedPage.turn.threadID == "thr_persisted"
            && persistedPage.turn.threadIDSource == ConduitSessionProviderThreadSource.persisted
            && persistedPage.observation.providerProgress == ConduitSessionProviderProgress.unavailable
    )
    check(
        "session events distinguish structured approval from PTY unknown",
        approvalPage.observation.checkpoint == ConduitSessionObservationCheckpoint.structuredApproval
            && approvalPage.observation.inputState == ConduitSessionInputState.approval
            && approvalPage.observation.inputSummary == "git status"
            && ptyPage.observation.inputState == ConduitSessionInputState.unknown
    )
    check(
        "session events omit missing runtime attempt",
        ptyPage.jsonObject()["runtime_attempt_id"] == nil
    )
}
let adapterEvent = SessionPresentation.agentOutputEvent(
    promptEventID: nil,
    text: "Hi",
    extraction: .structuredAdapter,
    truncated: false
)
check(
    "structured adapter events are toolReported",
    adapterEvent.authority == .toolReported
)
let permissionDecline = CodexAppServerApproval(
    id: "p",
    rpcID: .number(1),
    method: "item/permissions/requestApproval",
    summary: "fs"
)
check(
    "permission deny uses JSON-RPC error",
    permissionDecline.declineUsesRPCError
)
withTempDir { directory in
    let store = AdapterThreadStore(directory: directory)
    let task = TaskSessionID()
    store.save(taskSessionID: task, backend: "app-server", threadID: "thr_x")
    check("adapter thread store remembers thread id", store.threadID(for: task) == "thr_x")

    // A refused resume starts a replacement, and its id arrives here as an
    // ordinary save. Overwriting in place destroyed the only route back to
    // the real thread, so the failed recovery took the history with it.
    store.save(taskSessionID: task, backend: "app-server", threadID: "thr_y")
    check(
        "a replacement thread does not erase the prior pointer",
        store.threadID(for: task) == "thr_y"
            && store.supersededThreadIDs(for: task) == ["thr_x"]
    )
}

// MARK: - Resume provenance
//
// Every structured client substitutes a fresh session when a resume is
// refused, then reports a healthy ready session. Only `resumed` may claim the
// caller's history came back; a client that never checked says so rather than
// guessing in either direction.
do {
    let restarted = SessionResumeSemantics.classify(
        requested: "thr_old", started: "thr_new", attempt: .refused
    )
    check(
        "refused resume reports restarted and names what it displaced",
        restarted.wireValue == "restarted"
            && restarted.supersededID == "thr_old"
            && restarted.historyIsContinuous == false
    )
    check(
        "restarted authority says the session is new and empty",
        SessionResumeSemantics.authority(for: restarted).contains("EMPTY")
    )
    check(
        "accepted resume is the only provenance claiming continuity",
        SessionResumeSemantics.classify(
            requested: "thr_old", started: "thr_old", attempt: .accepted
        ).historyIsContinuous == true
    )
    check(
        "an unchecked resume reports unknown, not success",
        SessionResumeSemantics.classify(
            requested: "c-1", started: "c-1", attempt: .unchecked
        ).historyIsContinuous == nil
    )
}

// A PTY profile has no turn protocol, so an orchestrator that polls one for
// completion waits forever. The catalog is where it learns that in time to
// pick a different agent.
check(
    "list_adapters warns that PTY turn state never completes",
    ConduitSessionToolCatalog.tools()
        .first { $0["name"] as? String == "conduit_list_adapters" }
        .flatMap { $0["description"] as? String }
        .map { $0.contains("never becomes completed") || $0.contains("NEVER becomes completed") }
        == true
)


// MARK: - MCP admission boundary
//
// This boundary had no call sites and no tests before 2026-08-20; it is what
// stands between an external orchestrator and unbounded task spawning, so the
// refusal codes are pinned here rather than assumed.

do {
    let now = Date(timeIntervalSince1970: 1_787_100_000)

    /// Healthy readings for the three metrics Conduit actually samples.
    /// Persistence queue depth has no sensor, so it stays `.unknown` and is
    /// left out of `requiredMetrics` instead of being faked as zero.
    func sampledResources(
        availableBytes: UInt64 = 8_589_934_592,
        ownedRSSBytes: UInt64 = 1_073_741_824,
        promptDepth: UInt64 = 0,
        observedAt: Date = now
    ) -> ConduitResourceSnapshot {
        ConduitResourceSnapshot(
            availablePhysicalMemoryBytes: .known(
                value: availableBytes,
                observedAt: observedAt
            ),
            ownedProcessTreeRSSBytes: .known(
                value: ownedRSSBytes,
                observedAt: observedAt
            ),
            persistenceQueueCount: .unknown,
            persistenceQueueBytes: .unknown,
            promptQueueDepth: .known(value: promptDepth, observedAt: observedAt)
        )
    }

    let sampledMetrics: Set<ConduitResourceMetric> = [
        .availablePhysicalMemoryBytes,
        .ownedProcessTreeRSSBytes,
        .promptQueueDepth,
    ]

    func policy(
        writesEnabled: Bool = true,
        requireCallerIdentity: Bool = true,
        requireCreateIdempotency: Bool = false,
        globalLiveTaskLimit: Int = 4,
        maximumPendingCreateReservations: Int = 2,
        maximumGlobalPromptQueueDepth: Int = 16,
        maximumPromptQueueDepthPerTask: Int = 4,
        perCallerCreateLimit: Int = 64,
        perCallerWriteLimit: Int = 256,
        requiredMetrics: Set<ConduitResourceMetric>? = nil
    ) -> MCPAdmissionPolicy {
        MCPAdmissionPolicy(
            writesEnabled: writesEnabled,
            requireCallerIdentity: requireCallerIdentity,
            requireCreateIdempotency: requireCreateIdempotency,
            globalLiveTaskLimit: globalLiveTaskLimit,
            maximumPendingCreateReservations: maximumPendingCreateReservations,
            maximumGlobalPromptQueueDepth: maximumGlobalPromptQueueDepth,
            maximumPromptQueueDepthPerTask: maximumPromptQueueDepthPerTask,
            perCallerCreateLimit: perCallerCreateLimit,
            perCallerWriteLimit: perCallerWriteLimit,
            resourcePolicy: ConduitResourceCircuitPolicy(
                requiredMetrics: requiredMetrics ?? sampledMetrics
            )
        )
    }

    func create(
        _ controller: MCPAdmissionController,
        caller: String? = "chatgpt-developer-mode/1.0",
        dedupe: MCPCreateDedupeIdentity? = nil,
        resources: ConduitResourceSnapshot? = nil,
        at instant: Date = now
    ) -> MCPAdmissionDecision {
        controller.admitCreate(
            callerIdentity: caller,
            dedupeIdentity: dedupe,
            resources: resources ?? sampledResources(observedAt: instant),
            now: instant
        )
    }

    // --- fail-closed gates -------------------------------------------------

    check(
        "admission refuses every write while writes are disabled",
        create(MCPAdmissionController(policy: policy(writesEnabled: false)))
            .code == .writesDisabled
    )
    check(
        "admission refuses a write with no caller identity",
        create(MCPAdmissionController(policy: policy()), caller: nil)
            .code == .callerIdentityRequired
    )
    check(
        "admission refuses a blank caller identity",
        create(MCPAdmissionController(policy: policy()), caller: "   ")
            .code == .callerIdentityRequired
    )
    check(
        "admission refuses an oversized caller identity",
        create(
            MCPAdmissionController(policy: policy()),
            caller: String(repeating: "c", count: 257)
        ).code == .callerIdentityTooLarge
    )
    check(
        "admission refuses a policy with no required metric",
        create(
            MCPAdmissionController(policy: policy(requiredMetrics: [])),
            resources: sampledResources()
        ).code == .configurationInvalid
    )

    // --- resource circuit --------------------------------------------------

    check(
        "admission refuses when a required metric is unknown",
        create(
            MCPAdmissionController(policy: policy()),
            resources: .unknown
        ).code == .resourceUnknown
    )
    check(
        "admission ignores a metric this host does not sample",
        create(MCPAdmissionController(policy: policy())).outcome == .admitted
    )
    check(
        "admission refuses a stale resource sample",
        create(
            MCPAdmissionController(policy: policy()),
            resources: sampledResources(
                observedAt: now.addingTimeInterval(-45)
            )
        ).code == .resourceStale
    )
    check(
        "admission refuses when free memory is under the floor",
        create(
            MCPAdmissionController(policy: policy()),
            resources: sampledResources(availableBytes: 536_870_912)
        ).code == .resourceLimitExceeded
    )
    check(
        "admission names the metric that opened the circuit",
        create(
            MCPAdmissionController(policy: policy()),
            resources: sampledResources(availableBytes: 536_870_912)
        ).resourceViolations.contains {
            $0.metric == .availablePhysicalMemoryBytes
                && $0.code == .thresholdExceeded
        }
    )
    check(
        "admission refuses when Conduit's own RSS is over the ceiling",
        create(
            MCPAdmissionController(policy: policy()),
            resources: sampledResources(ownedRSSBytes: 8_589_934_592)
        ).code == .resourceLimitExceeded
    )

    // --- capacity ----------------------------------------------------------

    do {
        let controller = MCPAdmissionController(policy: policy(globalLiveTaskLimit: 1))
        let first = create(controller)
        let second = create(controller)
        check(
            "a pending create reserves capacity before it commits",
            first.outcome == .admitted
                && second.code == .globalLiveTaskLimitReached
        )
    }
    do {
        let controller = MCPAdmissionController(
            policy: policy(globalLiveTaskLimit: 8, maximumPendingCreateReservations: 1)
        )
        _ = create(controller)
        check(
            "the pending create queue is bounded on its own",
            create(controller).code == .createReservationQueueFull
        )
    }
    do {
        let controller = MCPAdmissionController(policy: policy(globalLiveTaskLimit: 1))
        let first = create(controller)
        check(
            "cancelling a create returns the reserved slot",
            controller.cancelCreate(reservationID: first.reservationID!)
                && create(controller).outcome == .admitted
        )
    }
    do {
        let controller = MCPAdmissionController(policy: policy(globalLiveTaskLimit: 1))
        let task = TaskSessionID()
        let first = create(controller)
        controller.commitCreate(reservationID: first.reservationID!, taskSessionID: task)
        let blocked = create(controller)
        controller.markTaskEnded(task)
        check(
            "capacity is held until a task is explicitly ended",
            blocked.code == .globalLiveTaskLimitReached
                && create(controller).outcome == .admitted
        )
    }
    do {
        let controller = MCPAdmissionController(policy: policy(globalLiveTaskLimit: 2))
        controller.reconcileLiveTasks(additive: [TaskSessionID(), TaskSessionID()])
        check(
            "restart reconciliation restores occupied capacity",
            create(controller).code == .globalLiveTaskLimitReached
        )
    }

    // --- per-caller rate ---------------------------------------------------

    do {
        let controller = MCPAdmissionController(
            policy: policy(globalLiveTaskLimit: 32, maximumPendingCreateReservations: 32, perCallerCreateLimit: 2)
        )
        _ = create(controller)
        _ = create(controller)
        let refused = create(controller)
        check(
            "a caller's create rate is bounded inside the window",
            refused.code == .callerCreateRateLimited
        )
        check(
            "a rate refusal tells the caller when to retry",
            (refused.retryAfterSeconds ?? 0) > 0
        )
        check(
            "the create-rate window drains",
            create(controller, at: now.addingTimeInterval(61)).outcome == .admitted
        )
    }
    do {
        let controller = MCPAdmissionController(policy: policy(perCallerWriteLimit: 1))
        _ = controller.admitWrite(
            callerIdentity: "chatgpt-developer-mode/1.0",
            resources: sampledResources(),
            now: now
        )
        check(
            "a caller's total write rate is bounded",
            controller.admitWrite(
                callerIdentity: "chatgpt-developer-mode/1.0",
                resources: sampledResources(),
                now: now
            ).code == .callerWriteRateLimited
        )
    }
    do {
        let controller = MCPAdmissionController(policy: policy(perCallerCreateLimit: 1))
        _ = create(controller, caller: "chatgpt-developer-mode/1.0")
        check(
            "rate budget is tracked per caller identity",
            create(controller, caller: "conduit-preflight/1.0").outcome == .admitted
        )
    }

    // --- idempotency -------------------------------------------------------

    do {
        let fingerprint = MCPCreateDedupeIdentity.fingerprint(
            canonicalComponents: ["conduit_create_task", "Shell", "conduit", "digest"]
        )
        let identity = MCPCreateDedupeIdentity(
            idempotencyKey: "retry-1",
            requestFingerprint: fingerprint
        )
        let controller = MCPAdmissionController(policy: policy())
        let first = create(controller, dedupe: identity)
        let repeated = create(controller, dedupe: identity)
        check(
            "an identical create retried while pending is deduplicated",
            repeated.outcome == .deduplicated
                && repeated.code == .duplicatePending
        )
        let task = TaskSessionID()
        controller.commitCreate(reservationID: first.reservationID!, taskSessionID: task)
        let afterCommit = create(controller, dedupe: identity)
        check(
            "an identical create retried after commit returns the original task",
            afterCommit.code == .duplicateCompleted
                && afterCommit.taskSessionID == task
        )
        check(
            "a deduplicated create is satisfied without executing",
            afterCommit.isRequestSatisfied && !afterCommit.shouldExecute
        )
        let conflicting = MCPCreateDedupeIdentity(
            idempotencyKey: "retry-1",
            requestFingerprint: MCPCreateDedupeIdentity.fingerprint(
                canonicalComponents: ["conduit_create_task", "Codex", "conduit", "digest"]
            )
        )
        check(
            "reusing a key for a different request is refused, not silently reused",
            create(controller, dedupe: conflicting).code == .idempotencyConflict
        )
    }
    check(
        "create fingerprints separate different components",
        MCPCreateDedupeIdentity.fingerprint(canonicalComponents: ["ab", "c"])
            != MCPCreateDedupeIdentity.fingerprint(canonicalComponents: ["a", "bc"])
    )
    check(
        "an objective digest is stable",
        ConduitSafetyHash.digest(namespace: "mcp-create-objective", text: "reply pong")
            == ConduitSafetyHash.digest(namespace: "mcp-create-objective", text: "reply pong")
    )
    check(
        "create demands an idempotency key when the policy requires one",
        create(
            MCPAdmissionController(policy: policy(requireCreateIdempotency: true))
        ).code == .invalidIdempotency
    )

    // --- prompt queue ------------------------------------------------------

    do {
        let controller = MCPAdmissionController(
            policy: policy(maximumPromptQueueDepthPerTask: 2)
        )
        let task = TaskSessionID()
        _ = controller.admitPrompt(
            callerIdentity: "chatgpt-developer-mode/1.0",
            taskSessionID: task,
            resources: sampledResources(),
            now: now
        )
        _ = controller.admitPrompt(
            callerIdentity: "chatgpt-developer-mode/1.0",
            taskSessionID: task,
            resources: sampledResources(),
            now: now
        )
        check(
            "one task's prompt queue is bounded",
            controller.admitPrompt(
                callerIdentity: "chatgpt-developer-mode/1.0",
                taskSessionID: task,
                resources: sampledResources(),
                now: now
            ).code == .taskPromptQueueFull
        )
        check(
            "another task is unaffected by the first task's queue",
            controller.admitPrompt(
                callerIdentity: "chatgpt-developer-mode/1.0",
                taskSessionID: TaskSessionID(),
                resources: sampledResources(),
                now: now
            ).outcome == .admitted
        )
    }
    do {
        let controller = MCPAdmissionController(
            policy: policy(maximumGlobalPromptQueueDepth: 2)
        )
        check(
            "a runtime's own observed queue depth can refuse a prompt",
            controller.admitPrompt(
                callerIdentity: "chatgpt-developer-mode/1.0",
                taskSessionID: TaskSessionID(),
                resources: sampledResources(promptDepth: 2),
                now: now
            ).code == .globalPromptQueueFull
        )
    }
    do {
        let controller = MCPAdmissionController(
            policy: policy(maximumPromptQueueDepthPerTask: 1)
        )
        let task = TaskSessionID()
        check(
            "a runtime's own per-task depth can refuse a prompt",
            controller.admitPrompt(
                callerIdentity: "chatgpt-developer-mode/1.0",
                taskSessionID: task,
                observedTaskQueueDepth: 1,
                resources: sampledResources(),
                now: now
            ).code == .taskPromptQueueFull
        )
    }
    do {
        let controller = MCPAdmissionController(
            policy: policy(maximumPromptQueueDepthPerTask: 1)
        )
        let task = TaskSessionID()
        let admitted = controller.admitPrompt(
            callerIdentity: "chatgpt-developer-mode/1.0",
            taskSessionID: task,
            resources: sampledResources(),
            now: now
        )
        check(
            "finishing a prompt returns its queue slot",
            controller.markPromptFinished(reservationID: admitted.reservationID!)
                && controller.admitPrompt(
                    callerIdentity: "chatgpt-developer-mode/1.0",
                    taskSessionID: task,
                    resources: sampledResources(),
                    now: now
                ).outcome == .admitted
        )
    }

    // --- the policy Conduit actually ships ---------------------------------
    //
    // Pinned so that loosening a limit is a deliberate edit with a failing
    // test, not a quiet drift.

    do {
        let shipped = MCPAdmissionPolicy.conduitSessionAPI(writesEnabled: true)
        check(
            "shipped policy caps the live fleet at four tasks",
            shipped.globalLiveTaskLimit == 4
        )
        check(
            "shipped create rate lets one caller fill the fleet in a burst",
            shipped.perCallerCreateLimit >= shipped.globalLiveTaskLimit
        )
        check(
            "shipped write rate leaves headroom beyond the creates it allows",
            shipped.perCallerWriteLimit > shipped.perCallerCreateLimit
        )
        check(
            "shipped policy still demands a caller identity",
            shipped.requireCallerIdentity
        )
        check(
            "shipped policy keeps idempotency opt-in",
            !shipped.requireCreateIdempotency
        )
        check(
            "shipped policy requires only the metrics Conduit samples",
            shipped.resourcePolicy.requiredMetrics == [
                .availablePhysicalMemoryBytes,
                .ownedProcessTreeRSSBytes,
                .promptQueueDepth,
            ]
        )
        check(
            "shipped policy never reports a persistence queue it cannot measure",
            !shipped.resourcePolicy.requiredMetrics.contains(.persistenceQueueCount)
                && !shipped.resourcePolicy.requiredMetrics.contains(.persistenceQueueBytes)
        )
        check(
            "shipped policy is off until the operator enables writes",
            !MCPAdmissionPolicy.conduitSessionAPI(writesEnabled: false).writesEnabled
        )
        check("shipped policy is internally valid", shipped.isValid)
    }

    // --- observability -----------------------------------------------------

    do {
        let controller = MCPAdmissionController(policy: policy())
        let task = TaskSessionID()
        let decision = create(controller)
        controller.commitCreate(reservationID: decision.reservationID!, taskSessionID: task)
        let snapshot = controller.stateSnapshot()
        check(
            "the admission snapshot reports committed capacity",
            snapshot.liveTaskSessionIDs == [task]
                && snapshot.pendingCreateReservationCount == 0
        )
    }
}


// MARK: - Session list paging and MindGraph output
//
// conduit_list_sessions used to return a bare first-40 slice with no total and
// no cursor, so a truncated inventory was indistinguishable from a complete
// one. These pin the window maths that replaced it.

do {
    let full = ConduitSessionListPage.window(total: 12, cursor: nil, limit: 40)
    check(
        "a short inventory returns whole and says so",
        full.startIndex == 0 && full.endIndex == 12 && !full.hasMore
            && full.cursorState == .ok
    )
    let first = ConduitSessionListPage.window(total: 64, cursor: nil, limit: 40)
    check(
        "a long inventory pages and admits there is more",
        first.count == 40 && first.hasMore && first.nextCursor == "v1:40"
    )
    let second = ConduitSessionListPage.window(
        total: 64,
        cursor: first.nextCursor,
        limit: 40
    )
    check(
        "the next cursor reaches the remainder exactly",
        second.startIndex == 40 && second.count == 24 && !second.hasMore
    )
    check(
        "paging covers the inventory with no gap or overlap",
        first.count + second.count == 64 && first.endIndex == second.startIndex
    )
    check(
        "a cursor past the end is stale, not an error",
        ConduitSessionListPage.window(total: 64, cursor: "v1:999").cursorState == .ahead
    )
    check(
        "a stale cursor returns nothing rather than wrapping around",
        ConduitSessionListPage.window(total: 64, cursor: "v1:999").count == 0
    )
    check(
        "an unparseable cursor restarts and says it was invalid",
        ConduitSessionListPage.window(total: 64, cursor: "nonsense").cursorState == .invalid
            && ConduitSessionListPage.window(total: 64, cursor: "nonsense").startIndex == 0
    )
    check(
        "an empty inventory is not an error",
        ConduitSessionListPage.window(total: 0).count == 0
            && !ConduitSessionListPage.window(total: 0).hasMore
    )
    check(
        "list limits clamp instead of failing",
        ConduitSessionListPage.clampLimit(nil) == 40
            && ConduitSessionListPage.clampLimit(0) == 40
            && ConduitSessionListPage.clampLimit(-5) == 40
            && ConduitSessionListPage.clampLimit(5) == 5
            && ConduitSessionListPage.clampLimit(9_999) == 200
    )
}

do {
    let noisy = """
    08:29:04 INFO    mindgraph | Loading embedding model (all-MiniLM-L6-v2)...
    08:29:06 INFO    mindgraph | Ready
    [
      {"doc_id": "abc", "score": 0.4}
    ]
    """
    check(
        "MindGraph results are separated from the progress log",
        MindGraphOutput.jsonPayload(in: noisy)?.hasPrefix("[") == true
    )
    check(
        "the progress log is kept, not glued to the results",
        MindGraphOutput.logPreamble(in: noisy).contains("Loading embedding model")
            && MindGraphOutput.logPreamble(in: noisy).contains("[") == false
    )
    check(
        "a bracket inside a log message does not look like the payload",
        MindGraphOutput.jsonPayload(in: """
        08:29:04 INFO mindgraph | scanning [30_projects] now
        [{"doc_id": "x"}]
        """)?.hasPrefix("[{") == true
    )
    check(
        "output with no payload reports none rather than guessing",
        MindGraphOutput.jsonPayload(in: "08:29:04 INFO mindgraph | no results") == nil
    )
    check(
        "a bare payload with no log still parses",
        MindGraphOutput.jsonPayload(in: "[{\"doc_id\":\"x\"}]")?.hasPrefix("[") == true
    )
}


do {
    // A row shaped like MindGraph's real output, including the absolute host
    // path that must never reach an external orchestrator.
    let row: [String: Any] = [
        "path": "30_projects/conduit/log.md",
        "title": "Conduit log",
        "chunk_text": String(repeating: "x", count: 900),
        "rrf_score": 0.031754,
        "doc_type": "project",
        "domain": "agent-operations",
        "status": "active",
        "trust_profile": "project_status",
        "weak_fit": false,
        "provenance_warning": NSNull(),
        "source_root": "/Users/someone/Desktop/MainFrame/30_projects/conduit",
        "content_hash": "40e9aa82",
        "doc_id": "829fd037c29e0ecd",
        "semantic_distance": 0.98747,
        "index_id": "mainframe-projects",
    ]
    let projected = MindGraphOutput.projectResult(row)
    check(
        "the absolute host path never reaches the caller",
        projected["source_root"] == nil
    )
    check(
        "retrieval mechanics are dropped",
        projected["content_hash"] == nil && projected["doc_id"] == nil
            && projected["semantic_distance"] == nil && projected["index_id"] == nil
    )
    check(
        "a caller still gets what it can act on",
        projected["path"] != nil && projected["title"] != nil
            && projected["chunk_text"] != nil && projected["rrf_score"] != nil
    )
    check(
        "weak-fit and trust signals survive projection",
        projected["weak_fit"] != nil && projected["trust_profile"] != nil
    )
    check(
        "null warnings are omitted rather than sent as nulls",
        projected["provenance_warning"] == nil
    )
    check(
        "matched text is bounded and admits truncation",
        (projected["chunk_text"] as? String)?.count == 600
            && projected["chunk_text_truncated"] as? Bool == true
    )
    check(
        "short text is not marked truncated",
        MindGraphOutput.projectResult(["chunk_text": "short"])["chunk_text_truncated"] == nil
    )
    check(
        "projection is an allowlist, so an unknown field cannot leak",
        MindGraphOutput.projectResult(["some_future_absolute_path": "/Users/someone/x"]).isEmpty
    )

    // Trust partition. Ranking is trust-blind: on 2026-08-20 a quarantined
    // document from the fabricated-citations incident was the highest-scoring
    // hit for a research question, carrying only a prose warning.
    let ranked: [[String: Any]] = [
        ["path": "a.md", "citation_class": "not_citable", "rrf_score": 0.0325],
        ["path": "b.md", "citation_class": "citable", "rrf_score": 0.0283],
        ["path": "c.md", "citation_class": "unverified", "rrf_score": 0.0266],
        ["path": "d.md", "citation_class": "not_citable", "rrf_score": 0.0161],
    ]
    let split = MindGraphOutput.partitionByCitation(ranked)
    check(
        "a top-ranked non-citable hit does not lead the usable results",
        (split.citable.first?["path"] as? String) == "b.md"
    )
    check(
        "non-citable results are separated, not dropped",
        split.citable.count == 2 && split.notCitable.count == 2
    )
    check(
        "unverified stays usable, because it is a nomination not a bar",
        split.citable.contains { ($0["path"] as? String) == "c.md" }
    )
    check(
        "partition preserves rank order inside each bucket",
        (split.notCitable.first?["path"] as? String) == "a.md"
    )
    check(
        "counts report all three classes",
        MindGraphOutput.citationCounts(ranked)
            == ["citable": 1, "unverified": 1, "not_citable": 2]
    )
    check(
        "a row with no citation_class counts as citable",
        MindGraphOutput.citationCounts([["path": "x.md"]])["citable"] == 1
    )
    check(
        "citation_class survives the projection allowlist",
        MindGraphOutput.projectResult(
            ["path": "a.md", "citation_class": "not_citable"]
        )["citation_class"] as? String == "not_citable"
    )
}

do {
    let plannerContext = OrchestrationContextPacket(
        projectID: "conduit",
        generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        entries: [
            OrchestrationContextEntry(
                id: "knowledge-planner",
                scope: .knowledge,
                displayPath: "10_knowledge/agents/planner.md",
                citationClass: .citable,
                excerpt: "Nominations are not proof.",
                tokenEstimate: 30,
                selectedByOperator: true
            ),
            OrchestrationContextEntry(
                id: "project-conduit",
                scope: .projects,
                displayPath: "30_projects/conduit/README.md",
                citationClass: .citable,
                excerpt: "Conduit owns execution state.",
                tokenEstimate: 30,
                selectedByOperator: true
            )
        ]
    )
    let plannerProposal = OrchestrationProposal(
        objective: "Add one bounded proposal contract.",
        projectID: "conduit",
        suggestedAgent: "OpenCode Local Planner",
        scopeAllowlist: ["Sources/ConduitCore/"],
        deliverables: ["Core types and tests"],
        verificationSteps: ["Run the focused XCTest suite."],
        risks: ["Planner prose is not verification."],
        nonGoals: ["No worker fan-out."]
    )
    let plannerPolicy = OrchestrationProposalPolicy(
        allowedAgentNames: ["OpenCode Local Planner"]
    )
    check(
        "planner context preserves scope labels and its token budget",
        plannerContext.validationReasons(maximumTokens: 100).isEmpty
            && plannerContext.entries.map(\.scope) == [.knowledge, .projects]
    )
    check(
        "planner proposal is valid only as an approval candidate",
        plannerPolicy.validate(
            proposal: plannerProposal,
            selectedProjectID: "conduit",
            contextPacket: plannerContext,
            workerAlreadyActive: false
        ) == .valid
    )
    check(
        "planner refuses an absolute scope before approval",
        {
            let absoluteScope = OrchestrationProposal(
                objective: plannerProposal.objective,
                projectID: plannerProposal.projectID,
                suggestedAgent: plannerProposal.suggestedAgent,
                scopeAllowlist: ["/policies/local_planner.yaml"],
                deliverables: plannerProposal.deliverables,
                verificationSteps: plannerProposal.verificationSteps,
                risks: plannerProposal.risks,
                nonGoals: plannerProposal.nonGoals
            )
            guard case .refused = plannerPolicy.validate(
                proposal: absoluteScope,
                selectedProjectID: "conduit",
                contextPacket: plannerContext,
                workerAlreadyActive: false
            ) else { return false }
            return true
        }()
    )
    let plannerApproval = OrchestrationApprovalToken(proposal: plannerProposal)
    let approvalState = OrchestrationRunReducer.reduce(
        .proposalReady(plannerProposal),
        event: .requestApproval
    )
    let launchState = OrchestrationRunReducer.reduce(
        approvalState,
        event: .beginLaunch(plannerApproval, selectedProjectID: "conduit")
    )
    check(
        "planner approval needs an exact current proposal before launch",
        launchState == .launching(plannerProposal, plannerApproval)
            && !plannerApproval.matches(
                OrchestrationProposal(
                    objective: "A changed proposal.",
                    projectID: "conduit",
                    suggestedAgent: "OpenCode Local Planner",
                    scopeAllowlist: ["Sources/ConduitCore/"],
                    deliverables: ["Core types and tests"],
                    verificationSteps: ["Run the focused XCTest suite."],
                    risks: ["Planner prose is not verification."],
                    nonGoals: ["No worker fan-out."]
                ),
                selectedProjectID: "conduit"
            )
    )
    check(
        "launched identifies task creation rather than completion",
        OrchestrationRunReducer.reduce(
            launchState,
            event: .recordLaunch(taskSessionID: "task-proposal-test")
        ) == .launched(taskSessionID: "task-proposal-test")
    )
}

// MARK: - Provider orchestration state boundary (#53)

let orchestrationObservation = SupervisionObservationStamp(
    authority: .providerObserved,
    freshness: .current,
    observedAt: .known(Date(timeIntervalSince1970: 1_799_956_800))
)
let orchestrationUnknownWorkspace = WorkerWorkspaceLineage(
    projectSlug: .unknown,
    cwd: .unknown,
    repositoryRoot: .unknown,
    worktree: .unknown
)
let orchestrationUnknownProcess = WorkerProcessLineage(
    launcherPID: .unknown,
    processGroupID: .unknown,
    parentPID: .unknown
)
let orchestrationUnfinished = WorkerTerminalState(
    receipt: .unknown,
    verification: .notPerformed,
    objectiveAcceptance: .pending
)
let discoveredExternalWorker = WorkerLineage(
    conduitTaskID: .unknown,
    runtimeAttemptID: .unknown,
    runtime: .known("OpenCode"),
    adapter: .known("http-server"),
    providerHostID: .unknown,
    providerSessionID: .known("ses_external_fixture"),
    turns: [],
    workspace: orchestrationUnknownWorkspace,
    process: orchestrationUnknownProcess,
    origin: .externalProviderClient,
    relationship: .discovered,
    writerControllerID: .unknown,
    terminal: orchestrationUnfinished,
    observation: orchestrationObservation,
    providerSpecific: .known(
        ProviderSpecificPayload(
            namespace: "opencode",
            value: .object([
                "status": .string("historical"),
                "active": .bool(false),
            ])
        )
    )
)
check(
    "discovered provider session does not invent a Conduit binding",
    discoveredExternalWorker.providerSessionID.value == "ses_external_fixture"
        && discoveredExternalWorker.conduitTaskID.state == .unknown
        && discoveredExternalWorker.runtimeAttemptID.state == .unknown
        && discoveredExternalWorker.relationship == .discovered
)
let firstProviderTurn = ProviderTurnLineage(
    turnID: .known("turn-1"),
    state: .completed,
    model: .known(
        ProviderModelIdentity(providerID: "xai", modelID: "grok-fixture")
    ),
    observation: orchestrationObservation
)
let secondProviderTurn = ProviderTurnLineage(
    turnID: .known("turn-2"),
    state: .active,
    model: .known(
        ProviderModelIdentity(providerID: "opencode", modelID: "muse-fixture")
    ),
    observation: orchestrationObservation
)
check(
    "provider model identity remains turn-scoped",
    firstProviderTurn.model.value?.providerID == "xai"
        && secondProviderTurn.model.value?.providerID == "opencode"
        && firstProviderTurn.model != secondProviderTurn.model
)
let unknownOrchestrationValue: OrchestrationValue<String> = .unknown
let unknownOrchestrationData = try! JSONEncoder().encode(unknownOrchestrationValue)
check(
    "orchestration UNKNOWN survives serialization",
    (try? JSONDecoder().decode(
        OrchestrationValue<String>.self,
        from: unknownOrchestrationData
    )) == unknownOrchestrationValue
)
let shellInputDelivery = PromptDeliveryRecord(
    eventID: .known("shell-event"),
    transport: .shellStdin,
    state: .accepted,
    contentDigest: .known("a"),
    queuedBehindActiveTurn: .known(false),
    providerTurnID: .unknown
)
let queuedAgentDelivery = PromptDeliveryRecord(
    eventID: .known("agent-event"),
    transport: .agentPrompt,
    state: .queued,
    contentDigest: .known("b"),
    queuedBehindActiveTurn: .known(true),
    providerTurnID: .unknown
)
check(
    "shell stdin stays distinct from queued agent prompt delivery",
    shellInputDelivery.transport == .shellStdin
        && queuedAgentDelivery.transport == .agentPrompt
        && queuedAgentDelivery.state == .queued
        && queuedAgentDelivery.queuedBehindActiveTurn.value == true
)
let completedProviderTurn = ProviderTurnLineage(
    turnID: .known("turn-complete"),
    state: .completed,
    model: .unknown,
    observation: orchestrationObservation
)
check(
    "provider completion does not imply objective acceptance",
    completedProviderTurn.state == .completed
        && orchestrationUnfinished.objectiveAcceptance == .pending
        && orchestrationUnfinished.verification == .notPerformed
)
let unsupportedRelease = LifecyclePreflight(
    operation: .releaseSupervision,
    target: LifecycleTarget(
        kind: .session,
        identifier: .known("ses-provider")
    ),
    support: .unsupported,
    willStopProvider: .unknown,
    willReleaseSlot: .unknown,
    recoverableAfterward: .unknown,
    exactResumeHandle: .known("ses-provider"),
    expectedProcessScope: .unknown,
    knownDescendantPIDs: .unknown,
    sideEffects: .unknown,
    unsupportedConsequences: .known([
        "provider does not expose release-with-host-continuing"
    ]),
    observation: orchestrationObservation
)
check(
    "unsupported lifecycle consequence remains explicit",
    unsupportedRelease.support == .unsupported
        && unsupportedRelease.willStopProvider.state == .unknown
        && unsupportedRelease.unsupportedConsequences.value?.count == 1
)
let shellTaskSessionID = TaskSessionID(
    rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
)
let shellRuntimeAttemptID = "00000000-0000-0000-0000-000000000012"
let shellExecutionID = "00000000-0000-0000-0000-000000000013"
let shellObservedAt = Date(timeIntervalSince1970: 1_799_956_800)
let shellProcessStamp = SupervisionObservationStamp(
    authority: .processObserved,
    freshness: .current,
    observedAt: .known(shellObservedAt)
)
let shellProviderStamp = SupervisionObservationStamp(
    authority: .providerObserved,
    freshness: .current,
    observedAt: .known(shellObservedAt)
)
let shellLauncher = ProcessNodeObservation(
    pid: 400,
    parentPID: .known(300),
    processGroupID: .known(400),
    startIdentity: .known(
        ProcessStartIdentity(startTime: .known(shellObservedAt))
    ),
    commandName: .known("zsh"),
    ownership: .taskCreated,
    ownershipBasis: .launcherIdentity,
    liveness: .live,
    observation: shellProcessStamp
)
let shellProviderProcess = ProcessNodeObservation(
    pid: 401,
    parentPID: .known(400),
    processGroupID: .known(400),
    startIdentity: .known(
        ProcessStartIdentity(startTime: .known(shellObservedAt.addingTimeInterval(1)))
    ),
    commandName: .known("opencode"),
    ownership: .taskCreated,
    ownershipBasis: .descendantObservedAfterLauncher,
    liveness: .live,
    observation: shellProcessStamp
)
let shellProcessTree = ProcessTreeObservation(
    taskSessionID: shellTaskSessionID.rawValue.uuidString,
    runtimeAttemptID: .known(shellRuntimeAttemptID),
    providerTurnID: .unknown,
    launcher: .known(shellLauncher),
    descendants: [shellProviderProcess],
    coverage: .complete,
    observation: shellProcessStamp
)
let shellExactCorrelation = ShellProviderCorrelationResolver.resolve(
    taskSessionID: shellTaskSessionID.rawValue.uuidString,
    runtimeAttemptID: shellRuntimeAttemptID,
    shellExecutionID: shellExecutionID,
    processCandidates: [
        ShellOpenCodeProcessCandidate(
            node: shellProviderProcess,
            arguments: ["/opt/homebrew/bin/opencode", "run", "--session", "ses_shell_exact"]
        )
    ],
    processTree: shellProcessTree,
    providerSessionIDs: .known(["ses_shell_exact"]),
    providerObservation: shellProviderStamp
)
check(
    "Shell correlation requires the owned process and exact persisted provider session",
    shellExactCorrelation.kind == .exact
        && shellExactCorrelation.providerSessionID.value == "ses_shell_exact"
        && shellExactCorrelation.commandID.state == .unknown
)
let shellCoverageExpectations: [
    (ProcessTreeObservationCoverage, ShellProviderCorrelationKind)
] = [
    (.complete, .exact),
    (.partial, .candidate),
    (.ambiguous, .ambiguous),
    (.unavailable, .unknown),
]
let shellCoverageIsFailClosed = shellCoverageExpectations.allSatisfy { entry in
    let (coverage, expectedKind) = entry
    var tree = shellProcessTree
    tree.coverage = coverage
    return ShellProviderCorrelationResolver.resolve(
        taskSessionID: shellTaskSessionID.rawValue.uuidString,
        runtimeAttemptID: shellRuntimeAttemptID,
        shellExecutionID: shellExecutionID,
        processCandidates: [
            ShellOpenCodeProcessCandidate(
                node: shellProviderProcess,
                arguments: [
                    "/opt/homebrew/bin/opencode",
                    "run",
                    "--session",
                    "ses_shell_exact",
                ]
            )
        ],
        processTree: tree,
        providerSessionIDs: .known(["ses_shell_exact"]),
        providerObservation: shellProviderStamp
    ).kind == expectedKind
}
check(
    "Shell exact correlation requires complete process-tree coverage",
    shellCoverageIsFailClosed
)
let shellUnrelatedProcess = ProcessNodeObservation(
    pid: 402,
    parentPID: .known(300),
    processGroupID: .known(402),
    startIdentity: .known(
        ProcessStartIdentity(startTime: .known(shellObservedAt.addingTimeInterval(-1)))
    ),
    commandName: .known("opencode"),
    ownership: .preExisting,
    ownershipBasis: .preExistingObservation,
    liveness: .live,
    observation: shellProcessStamp
)
let shellUnrelatedCorrelation = ShellProviderCorrelationResolver.resolve(
    taskSessionID: shellTaskSessionID.rawValue.uuidString,
    runtimeAttemptID: shellRuntimeAttemptID,
    shellExecutionID: shellExecutionID,
    processCandidates: [
        ShellOpenCodeProcessCandidate(
            node: shellUnrelatedProcess,
            arguments: ["/opt/homebrew/bin/opencode", "--session", "ses_shell_unrelated"]
        )
    ],
    processTree: shellProcessTree,
    providerSessionIDs: .known(["ses_shell_unrelated"]),
    providerObservation: shellProviderStamp
)
check(
    "Shell correlation leaves unrelated provider sessions UNKNOWN",
    shellUnrelatedCorrelation.kind == .unknown
        && shellUnrelatedCorrelation.providerSessionID.state == .unknown
)
let shellTelemetryEvent = ShellTelemetryEvent(
    shellExecutionID: shellExecutionID,
    runtimeAttemptID: shellRuntimeAttemptID,
    phase: .commandExited,
    commandID: "\(shellExecutionID):1",
    commandSequence: 1,
    shellPID: shellLauncher.pid,
    processGroupID: shellLauncher.processGroupID,
    workingDirectory: .known("/tmp/shell-project"),
    exitStatus: .known(0),
    deliveryTransport: .known(.shellStdin),
    observation: SupervisionObservationStamp(
        authority: .shellHookObserved,
        freshness: .current,
        observedAt: .known(shellObservedAt)
    )
)
let shellTaskEvents = [
    TaskSessionEvent(
        taskSessionID: shellTaskSessionID,
        occurredAt: shellObservedAt,
        recordedAt: shellObservedAt,
        authority: .shellHookObserved,
        kind: .shellTelemetryRecorded(shellTelemetryEvent)
    ),
    TaskSessionEvent(
        taskSessionID: shellTaskSessionID,
        occurredAt: shellObservedAt,
        recordedAt: shellObservedAt,
        authority: .processObserved,
        kind: .shellProcessObservationRecorded(shellProcessTree)
    ),
]
let shellTelemetryProjection = ShellTelemetryProjection.latest(
    taskSessionID: shellTaskSessionID,
    events: shellTaskEvents
)
check(
    "Shell command exit stays independent from live child process state",
    shellTelemetryProjection?.commandState(liveRuntimeAttemptID: shellRuntimeAttemptID) == .exited
        && shellTelemetryProjection?.processObservation?.descendants.first?.liveness == .live
)

// MARK: - ChatGPT tunnel ownership

let tunnelReady = ChatGPTTunnelPrerequisites(
    sessionAPIListening: true,
    tunnelClientAvailable: true,
    profilePresent: true,
    tunnelIDPresent: true,
    controlPlaneKeyPresent: true,
    sessionTokenPresent: true
)
check(
    "ChatGPT tunnel starts only when owned launch is requested and prerequisites are ready",
    ChatGPTTunnelControlPolicy.action(
        desiredRunning: true,
        ownsRunningProcess: false,
        healthReachable: false,
        prerequisites: tunnelReady
    ) == .startOwned
)
check(
    "ChatGPT tunnel never adopts a healthy external process",
    ChatGPTTunnelControlPolicy.action(
        desiredRunning: true,
        ownsRunningProcess: false,
        healthReachable: true,
        prerequisites: tunnelReady
    ) == .observeExternal
)
check(
    "ChatGPT tunnel off switch stops only an owned process",
    ChatGPTTunnelControlPolicy.action(
        desiredRunning: false,
        ownsRunningProcess: true,
        healthReachable: true,
        prerequisites: tunnelReady
    ) == .stopOwned
)

// MARK: - Codex metadata observation (D070 proposal; #53 Slice 2)

let codexObservationID = CodexObservationRPC.identifier(hostGeneration: UUID())
let codexObservationList = CodexObservationRPC.list(id: codexObservationID, cursor: nil)
check("Codex metadata list explicitly disables rollout repair",
      codexObservationList["params"]?["useStateDbOnly"] == .bool(true)
        && codexObservationList["params"]?["archived"] == .bool(false))
check("Codex metadata source selection includes app-server and subagents",
      (codexObservationList["params"]?["sourceKinds"]?.jsonObject() as? [String])?.contains("appServer") == true
        && (codexObservationList["params"]?["sourceKinds"]?.jsonObject() as? [String])?.contains("subAgent") == true)
check("Codex metadata read explicitly excludes turns",
      CodexObservationRPC.read(id: codexObservationID, threadID: "provider-full")["params"]?["includeTurns"] == .bool(false))
check("Codex observation namespace remains separate from numeric driving IDs",
      CodexObservationRPC.isObservationReply(.string(codexObservationID))
        && !CodexObservationRPC.isObservationReply(.number(1)))
let codexMetadata: CodexJSON = .object([
    "id": .string("provider-full"), "sessionId": .string("family-distinct"),
    "cwd": .string("/qualification-owned"), "createdAt": .number(100), "updatedAt": .number(200),
    "cliVersion": .string("fixture"), "modelProvider": .string("fixture"),
    "ephemeral": .bool(false), "model": .string("configured-only"), "source": .string("cli"),
    "status": .object(["type": .string("notLoaded")]), "turns": .array([]),
    "preview": .string("private-preview"), "name": .string("private-title"), "path": .string("private-rollout"),
])
if let parsed = try? CodexThreadMetadata.parse(codexMetadata) {
    let worker = parsed.worker(hostID: "host-only", loadedOnHost: false, binding: nil, observedAt: Date())
    let bytes = (try? JSONEncoder().encode(worker)) ?? Data()
    let text = String(decoding: bytes, as: UTF8.self)
    check("Codex metadata content is withheld from canonical projection",
          !text.contains("private-preview") && !text.contains("private-title") && !text.contains("private-rollout"))
    check("Codex session model never becomes a turn or acceptance",
          worker.turns.isEmpty && worker.terminal.objectiveAcceptance == .unknown
            && text.contains("configured_or_persisted_model") && text.contains("per-turn model and entitlement UNKNOWN"))
    check("Codex host, thread, writer and task axes remain separate",
          !worker.providerHostID.isKnown && text.contains("observation_host_id") && text.contains("host-only")
            && worker.providerSessionID.value == "provider-full"
            && !worker.conduitTaskID.isKnown && !worker.writerControllerID.isKnown && worker.origin == .unknown)
    let bound = parsed.worker(hostID: "host-only", loadedOnHost: true,
                             binding: ProviderObservationBinding(conduitTaskID: "task-only", runtimeAttemptID: "attempt-only"), observedAt: Date())
    check("Codex exact task binding does not adopt or claim writer authority",
          bound.conduitTaskID.value == "task-only" && bound.runtimeAttemptID.value == "attempt-only"
            && bound.providerHostID.value == "host-only"
            && bound.relationship == .discovered && !bound.writerControllerID.isKnown)
} else { check("Codex valid metadata parses", false) }
check("Codex read refuses shortened or wrong-axis identity",
      (try? CodexThreadMetadata.parseRead(.object(["thread": codexMetadata]), exactID: "provider")) == nil
        && (try? CodexThreadMetadata.parseRead(.object(["thread": codexMetadata]), exactID: "task-only")) == nil)
if case .object(var content) = codexMetadata {
    content["turns"] = .array([.object(["id": .string("unexpected-turn")])])
    check("Codex includeTurns false boundary rejects unexpected turns", (try? CodexThreadMetadata.parse(.object(content))) == nil)
    content["turns"] = .array([])
    content["updatedAt"] = .number(1.5)
    check("Codex malformed fractional metadata timestamp is refused", (try? CodexThreadMetadata.parse(.object(content))) == nil)
}
func codexMetadataSelfTestPage(_ id: String, cursor: String?) -> CodexJSON {
    .object(["data": .array([.string(id)]), "nextCursor": cursor.map(CodexJSON.string) ?? .null])
}
func codexMetadataSelfTestID(_ json: CodexJSON) throws -> (String, String) {
    guard let id = json.stringValue else { throw CodexObservationError.invalidMetadata }; return (id, id)
}
func codexMetadataSelfTestRefuses(_ body: () throws -> String?) -> Bool {
    do { _ = try body(); return false } catch { return true }
}
do {
    var pages = CodexMetadataPages<String>()
    _ = try pages.append(codexMetadataSelfTestPage("one", cursor: "next"), parse: codexMetadataSelfTestID)
    check("Codex duplicate metadata identity rejects the page without partial append",
          codexMetadataSelfTestRefuses { try pages.append(codexMetadataSelfTestPage("one", cursor: nil), parse: codexMetadataSelfTestID) } && pages.elements == ["one"])
    check("Codex repeated pagination cursor refuses partial inventory",
          codexMetadataSelfTestRefuses { try pages.append(codexMetadataSelfTestPage("two", cursor: "next"), parse: codexMetadataSelfTestID) } && pages.elements == ["one"])
    _ = try pages.append(codexMetadataSelfTestPage("two", cursor: nil), parse: codexMetadataSelfTestID)
    check("Codex complete pagination preserves provider identity order", pages.elements == ["one", "two"])
    var bounded = CodexMetadataPages<String>()
    for index in 0..<3 { _ = try bounded.append(codexMetadataSelfTestPage("id-\(index)", cursor: "next-\(index)"), parse: codexMetadataSelfTestID) }
    check("Codex page bound rejects a fifth page instead of returning partial inventory",
          codexMetadataSelfTestRefuses { try bounded.append(codexMetadataSelfTestPage("four", cursor: "five"), parse: codexMetadataSelfTestID) } && bounded.elements.count == 3)
} catch { check("Codex metadata page apparatus", false) }
final class CodexMetadataSelfTestRecorder: @unchecked Sendable {
    let lock = NSLock()
    let marker = DispatchSemaphore(value: 0)
    var values: [CodexAppServerDelivery] = []
    func record(_ batch: [CodexAppServerDelivery]) {
        lock.lock(); values.append(contentsOf: batch); lock.unlock()
        if batch.contains(.effect(.turnCompleted(status: "metadata-marker"))) { marker.signal() }
    }
}
let codexMetadataRecorder = CodexMetadataSelfTestRecorder()
let codexMetadataPump = CodexAppServerStreamPump(
    configuration: .init(deliveryCoalescingInterval: 0), deliveryQueue: DispatchQueue(label: "selftest.codex.metadata"),
    onDelivery: { codexMetadataRecorder.record($0) }, onFailure: { _ in codexMetadataRecorder.marker.signal() }
)
codexMetadataPump.ingest(Data((
    #"{"id":"conduit.observation.v1/expired/request","result":{"thread":{"id":"external"}}}"# + "\n"
    + #"{"id":"conduit.observation.v1/expired/request","error":{"message":"private"}}"# + "\n"
    + #"{"id":"conduit.observation.v1/expired/request","method":"item/commandExecution/requestApproval","params":{"command":"private"}}"# + "\n"
    + #"{"method":"turn/completed","params":{"turn":{"status":"metadata-marker"}}}"# + "\n"
).utf8))
let codexMetadataMarker = codexMetadataRecorder.marker.wait(timeout: .now() + 2) == .success
codexMetadataRecorder.lock.lock()
let codexMetadataEffects = codexMetadataRecorder.values.filter { if case .effect = $0 { return true }; return false }
codexMetadataRecorder.lock.unlock()
check("Codex expired, repeated and error metadata replies cannot drive runtime effects",
      codexMetadataMarker && codexMetadataEffects == [.effect(.turnCompleted(status: "metadata-marker"))])
codexMetadataPump.cancel()

// MARK: - Summary

print("\n\(passed) passed, \(failures.count) failed")
if !failures.isEmpty {
    print("failures:")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(1)
}
