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
        !openCodeDoc.contains("10% used") && !openCodeDoc.contains("Thought")
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

// MARK: - Summary

print("\n\(passed) passed, \(failures.count) failed")
if !failures.isEmpty {
    print("failures:")
    for failure in failures {
        print("  - \(failure)")
    }
    exit(1)
}
