import Foundation
import XCTest
@testable import ConduitCore

final class TaskSessionModelTests: XCTestCase {
    private let rootURL = URL(fileURLWithPath: "/tmp/MainFrame/./")
    private let projectURL = URL(
        fileURLWithPath: "/tmp/MainFrame/30_projects/../30_projects/conduit"
    )

    func testTaskAndRuntimeIdentitiesAreDistinctAndRoundTrip() throws {
        let task = TaskSessionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        let runtime = RuntimeAttemptID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )

        XCTAssertNotEqual(task.rawValue, runtime.rawValue)
        XCTAssertEqual(
            try JSONDecoder().decode(
                TaskSessionID.self,
                from: JSONEncoder().encode(task)
            ),
            task
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RuntimeAttemptID.self,
                from: JSONEncoder().encode(runtime)
            ),
            runtime
        )
    }

    func testWorkspaceSnapshotsStandardizePathsAndRetainFallbacks() {
        let root = WorkspaceScopeSnapshot.root(
            RootWorkspaceScopeSnapshot(
                rootURL: rootURL,
                fallbackTitle: "MainFrame",
                fallbackSlug: "mainframe"
            )
        )
        let project = WorkspaceScopeSnapshot.project(
            ProjectWorkspaceScopeSnapshot(
                rootURL: rootURL,
                projectURL: projectURL,
                fallbackTitle: "Conduit",
                fallbackSlug: "conduit"
            )
        )

        XCTAssertEqual(root.rootPath, "/tmp/MainFrame")
        XCTAssertNil(root.projectPath)
        XCTAssertEqual(root.fallbackTitle, "MainFrame")
        XCTAssertEqual(root.fallbackSlug, "mainframe")
        XCTAssertEqual(project.rootPath, "/tmp/MainFrame")
        XCTAssertEqual(project.projectPath, "/tmp/MainFrame/30_projects/conduit")
        XCTAssertEqual(project.fallbackTitle, "Conduit")
        XCTAssertEqual(project.fallbackSlug, "conduit")
    }

    func testProjectionAppliesMetadataChangesWithoutReplacingCreation() throws {
        let sessionID = TaskSessionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        )
        let attemptID = RuntimeAttemptID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        )
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = TaskSessionMetadata(
            workspace: .project(
                ProjectWorkspaceScopeSnapshot(
                    rootURL: rootURL,
                    projectURL: projectURL,
                    fallbackTitle: "Conduit",
                    fallbackSlug: "conduit"
                )
            ),
            agentName: "Codex",
            defaultTitle: "Codex · Conduit"
        )
        let duplicateID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000099"
        )!
        let events = [
            // Pre-creation metadata cannot create or mutate a task.
            event(
                sessionID,
                at: t0.addingTimeInterval(-1),
                authority: .operatorAsserted,
                kind: .pinChanged(true)
            ),
            event(
                sessionID,
                at: t0,
                authority: .conduitRecorded,
                kind: .created(metadata)
            ),
            // Invalid authority is ignored.
            event(
                sessionID,
                at: t0.addingTimeInterval(1),
                authority: .conduitRecorded,
                kind: .titleOverridden("Wrong authority")
            ),
            event(
                sessionID,
                at: t0.addingTimeInterval(2),
                authority: .operatorAsserted,
                kind: .titleOverridden("  Release review  ")
            ),
            event(
                sessionID,
                id: duplicateID,
                at: t0.addingTimeInterval(3),
                authority: .operatorAsserted,
                kind: .pinChanged(true)
            ),
            // Duplicate event identity is idempotent.
            event(
                sessionID,
                id: duplicateID,
                at: t0.addingTimeInterval(4),
                authority: .operatorAsserted,
                kind: .pinChanged(false)
            ),
            event(
                sessionID,
                at: t0.addingTimeInterval(5),
                authority: .conduitRecorded,
                kind: .operationalStateChanged(.runtimeOpened(attemptID))
            )
        ]

        let titled = try XCTUnwrap(
            TaskSessionProjection.project(taskSessionID: sessionID, events: events)
        )
        XCTAssertEqual(titled.displayTitle, "Release review")
        XCTAssertEqual(titled.titleOverride, "Release review")
        XCTAssertTrue(titled.isPinned)
        XCTAssertFalse(titled.isArchived)
        XCTAssertEqual(titled.operationalState, .runtimeOpened(attemptID))
        XCTAssertEqual(titled.createdAt, t0)

        let resetAndArchived = events + [
            event(
                sessionID,
                at: t0.addingTimeInterval(6),
                authority: .operatorAsserted,
                kind: .titleReset
            ),
            event(
                sessionID,
                at: t0.addingTimeInterval(7),
                authority: .operatorAsserted,
                kind: .archiveChanged(true)
            )
        ]
        let final = try XCTUnwrap(
            TaskSessionProjection.project(
                taskSessionID: sessionID,
                events: resetAndArchived
            )
        )
        XCTAssertNil(final.titleOverride)
        XCTAssertEqual(final.displayTitle, "Codex · Conduit")
        XCTAssertTrue(final.isArchived)
        XCTAssertEqual(final.lastActivityAt, t0.addingTimeInterval(7))

        let encoded = String(
            decoding: try JSONEncoder().encode(resetAndArchived),
            as: UTF8.self
        ).lowercased()
        XCTAssertFalse(encoded.contains("prompt"))
        XCTAssertFalse(encoded.contains("attachment"))
        XCTAssertFalse(encoded.contains("renderedpayload"))
        XCTAssertFalse(encoded.contains("terminal transcript"))
    }

    func testProjectionRequiresSupportedCreationEvent() {
        let sessionID = TaskSessionID()
        let unsupported = TaskSessionEvent(
            schemaVersion: 2,
            taskSessionID: sessionID,
            authority: .conduitRecorded,
            kind: .created(
                TaskSessionMetadata(
                    workspace: .root(
                        RootWorkspaceScopeSnapshot(rootURL: rootURL)
                    ),
                    agentName: "Shell",
                    defaultTitle: "Shell"
                )
            )
        )

        XCTAssertNil(
            TaskSessionProjection.project(
                taskSessionID: sessionID,
                events: [unsupported]
            )
        )
    }

    func testProvisioningFailureIsDurableAndKeepsTargetForRecovery() throws {
        let sessionID = TaskSessionID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        )
        let attemptID = RuntimeAttemptID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000031")!
        )
        let metadata = TaskSessionMetadata(
            workspace: .project(
                ProjectWorkspaceScopeSnapshot(
                    rootURL: rootURL,
                    projectURL: projectURL,
                    fallbackTitle: "Conduit",
                    fallbackSlug: "conduit"
                )
            ),
            agentName: "Claude",
            defaultTitle: "Claude · Conduit"
        )
        let target = "conduit-conduit-claude-deadbeef"
        let events = [
            event(
                sessionID,
                at: Date(timeIntervalSince1970: 1_800_000_000),
                authority: .conduitRecorded,
                kind: .created(metadata)
            ),
            event(
                sessionID,
                at: Date(timeIntervalSince1970: 1_800_000_001),
                authority: .conduitRecorded,
                kind: .operationalStateChanged(
                    .runtimeProvisioning(
                        attemptID,
                        backend: "tmux",
                        tmuxSessionName: target
                    )
                )
            ),
            event(
                sessionID,
                at: Date(timeIntervalSince1970: 1_800_000_002),
                authority: .conduitRecorded,
                kind: .operationalStateChanged(
                    .runtimeProvisioningFailed(
                        attemptID,
                        tmuxSessionName: target,
                        reason: "tmux identity inspection was inconclusive",
                        recoverable: true
                    )
                )
            )
        ]

        let snapshot = try XCTUnwrap(
            TaskSessionProjection.project(taskSessionID: sessionID, events: events)
        )
        XCTAssertEqual(
            snapshot.operationalState,
            .runtimeProvisioningFailed(
                attemptID,
                tmuxSessionName: target,
                reason: "tmux identity inspection was inconclusive",
                recoverable: true
            )
        )
        XCTAssertEqual(
            TaskSessionAvailabilityResolver.resolve(
                session: snapshot,
                context: TaskSessionAvailabilityContext()
            ),
            .interrupted
        )
        let encoded = String(
            decoding: try JSONEncoder().encode(events),
            as: UTF8.self
        )
        XCTAssertTrue(encoded.contains(target))
        XCTAssertTrue(encoded.contains("identity inspection was inconclusive"))
    }

    func testUnknownAgentIdentityDoesNotRequirePersistingAPlaceholder() throws {
        let sessionID = TaskSessionID()
        let metadata = TaskSessionMetadata(
            workspace: .project(
                ProjectWorkspaceScopeSnapshot(
                    rootURL: rootURL,
                    projectURL: projectURL,
                    fallbackTitle: "Conduit",
                    fallbackSlug: "conduit"
                )
            ),
            agentName: nil,
            defaultTitle: ""
        )
        let snapshot = try XCTUnwrap(
            TaskSessionProjection.project(
                taskSessionID: sessionID,
                events: [
                    event(
                        sessionID,
                        at: Date(timeIntervalSince1970: 1_800_000_200),
                        authority: .conduitRecorded,
                        kind: .created(metadata)
                    )
                ]
            )
        )

        XCTAssertNil(snapshot.metadata.agentName)
        XCTAssertEqual(snapshot.displayTitle, "Conduit")
        let encoded = String(
            decoding: try JSONEncoder().encode(snapshot),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.contains("Unidentified"))
    }

    func testRuntimeDetachMayBeRecordedOrProcessObserved() {
        let taskID = TaskSessionID()
        let attemptID = RuntimeAttemptID()
        let recorded = TaskSessionEvent(
            taskSessionID: taskID,
            authority: .conduitRecorded,
            kind: .operationalStateChanged(.runtimeDetached(attemptID))
        )
        let observed = TaskSessionEvent(
            taskSessionID: taskID,
            authority: .processObserved,
            kind: .operationalStateChanged(.runtimeDetached(attemptID))
        )

        XCTAssertTrue(recorded.hasValidAuthority)
        XCTAssertTrue(observed.hasValidAuthority)
    }

    func testConversationActivityIsContentFreeAndAdvancesRecency() throws {
        let taskID = TaskSessionID()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_300)
        let activityAt = createdAt.addingTimeInterval(40)
        let metadata = TaskSessionMetadata(
            workspace: .root(
                RootWorkspaceScopeSnapshot(rootURL: rootURL)
            ),
            agentName: "Codex",
            defaultTitle: "Content-free activity"
        )
        let creation = event(
            taskID,
            at: createdAt,
            authority: .conduitRecorded,
            kind: .created(metadata)
        )
        let activity = TaskSessionEvent.conversationActivity(
            taskSessionID: taskID,
            at: activityAt
        )
        let invalidLaterActivity = event(
            taskID,
            at: activityAt.addingTimeInterval(20),
            authority: .operatorAsserted,
            kind: .conversationActivityRecorded
        )

        XCTAssertEqual(activity.authority, .conduitRecorded)
        XCTAssertEqual(activity.occurredAt, activityAt)
        XCTAssertEqual(activity.recordedAt, activityAt)
        XCTAssertTrue(activity.hasValidAuthority)
        XCTAssertFalse(invalidLaterActivity.hasValidAuthority)

        let snapshot = try XCTUnwrap(
            TaskSessionProjection.project(
                taskSessionID: taskID,
                events: [creation, activity, invalidLaterActivity]
            )
        )
        XCTAssertEqual(snapshot.lastConversationActivityAt, activityAt)
        XCTAssertEqual(snapshot.lastActivityAt, activityAt)

        let encoded = String(
            decoding: try JSONEncoder().encode(activity),
            as: UTF8.self
        ).lowercased()
        XCTAssertTrue(encoded.contains("conversationactivityrecorded"))
        XCTAssertFalse(encoded.contains("prompt text"))
        XCTAssertFalse(encoded.contains("output text"))
        XCTAssertFalse(encoded.contains("attachment"))
        XCTAssertFalse(encoded.contains("renderedpayload"))
    }

    func testConversationRetentionMarkerDistinguishesLegacyWithoutAdvancingRecency() throws {
        let taskID = TaskSessionID()
        let createdAt = Date(timeIntervalSince1970: 1_800_000_400)
        let enabledAt = createdAt.addingTimeInterval(80)
        let metadata = TaskSessionMetadata(
            workspace: .root(
                RootWorkspaceScopeSnapshot(rootURL: rootURL)
            ),
            agentName: "Codex",
            defaultTitle: "Retention marker"
        )
        let creation = event(
            taskID,
            at: createdAt,
            authority: .conduitRecorded,
            kind: .created(metadata)
        )
        let legacy = try XCTUnwrap(
            TaskSessionProjection.project(
                taskSessionID: taskID,
                events: [creation]
            )
        )
        let enabled = TaskSessionEvent.conversationRetentionEnabled(
            taskSessionID: taskID,
            at: enabledAt
        )
        let invalidMarker = event(
            taskID,
            at: enabledAt.addingTimeInterval(20),
            authority: .operatorAsserted,
            kind: .conversationRetentionEnabled
        )

        XCTAssertFalse(legacy.conversationRetentionEnabled)
        XCTAssertTrue(enabled.hasValidAuthority)
        XCTAssertFalse(invalidMarker.hasValidAuthority)

        let retained = try XCTUnwrap(
            TaskSessionProjection.project(
                taskSessionID: taskID,
                events: [creation, enabled, invalidMarker]
            )
        )
        XCTAssertTrue(retained.conversationRetentionEnabled)
        XCTAssertEqual(retained.lastActivityAt, createdAt)
        XCTAssertNil(retained.lastConversationActivityAt)

        let encoded = String(
            decoding: try JSONEncoder().encode(enabled),
            as: UTF8.self
        ).lowercased()
        XCTAssertTrue(encoded.contains("conversationretentionenabled"))
        XCTAssertFalse(encoded.contains("prompt"))
        XCTAssertFalse(encoded.contains("output text"))
        XCTAssertFalse(encoded.contains("attachment"))
        XCTAssertFalse(encoded.contains("renderedpayload"))
    }

    private func event(
        _ sessionID: TaskSessionID,
        id: UUID = UUID(),
        at: Date,
        authority: TaskSessionEventAuthority,
        kind: TaskSessionEventKind
    ) -> TaskSessionEvent {
        TaskSessionEvent(
            id: id,
            taskSessionID: sessionID,
            occurredAt: at,
            recordedAt: at,
            authority: authority,
            kind: kind
        )
    }
}

final class SessionCatalogTests: XCTestCase {
    private let rootURL = URL(fileURLWithPath: "/tmp/MainFrame")
    private let projectURL = URL(
        fileURLWithPath: "/tmp/MainFrame/30_projects/conduit"
    )

    func testAvailabilityUsesCurrentObservationsWithoutInferringSuccess() throws {
        let closed = try makeSnapshot(
            id: "00000000-0000-0000-0000-000000000020",
            title: "Closed",
            at: 1_800_000_000,
            operationalState: .closed(.runtimeEnded),
            operationalAuthority: .processObserved
        )
        let liveAttempt = RuntimeAttemptID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
        )

        XCTAssertEqual(
            TaskSessionAvailabilityResolver.resolve(
                session: closed,
                context: TaskSessionAvailabilityContext(
                    liveRuntimeAttempts: [closed.id: liveAttempt],
                    reconnectableTaskSessionIDs: [closed.id],
                    externalObservation: .succeeded(observedAt: Date())
                )
            ),
            .running(liveAttempt)
        )
        XCTAssertEqual(
            TaskSessionAvailabilityResolver.resolve(
                session: closed,
                context: TaskSessionAvailabilityContext(
                    reconnectableTaskSessionIDs: [closed.id],
                    externalObservation: .succeeded(observedAt: Date())
                )
            ),
            .reconnectable
        )
        guard case .recentClosed(_, .runtimeEnded) =
            TaskSessionAvailabilityResolver.resolve(
                session: closed,
                context: TaskSessionAvailabilityContext(
                    externalObservation: .succeeded(observedAt: Date())
                )
            )
        else {
            return XCTFail("Expected an operationally closed session")
        }

        let detached = try makeSnapshot(
            id: "00000000-0000-0000-0000-000000000022",
            title: "Detached",
            at: 1_800_000_100,
            operationalState: .runtimeDetached(liveAttempt),
            operationalAuthority: .conduitRecorded
        )
        XCTAssertEqual(
            TaskSessionAvailabilityResolver.resolve(
                session: detached,
                context: TaskSessionAvailabilityContext(
                    externalObservation: .failed(observedAt: Date())
                )
            ),
            .unknown
        )
        XCTAssertEqual(
            TaskSessionAvailabilityResolver.resolve(
                session: detached,
                context: TaskSessionAvailabilityContext(
                    externalObservation: .succeeded(observedAt: Date())
                )
            ),
            .unavailable
        )

        let names = [
            TaskSessionAvailabilityKind.running.rawValue,
            TaskSessionAvailabilityKind.reconnectable.rawValue,
            TaskSessionAvailabilityKind.recentClosed.rawValue,
            TaskSessionAvailabilityKind.interrupted.rawValue,
            TaskSessionAvailabilityKind.unavailable.rawValue,
            TaskSessionAvailabilityKind.unknown.rawValue
        ].joined(separator: " ")
        XCTAssertFalse(names.contains("complete"))
        XCTAssertFalse(names.contains("success"))
        XCTAssertFalse(names.contains("verified"))
    }

    func testCatalogFiltersSearchesAndUsesStableIDTieBreak() throws {
        let sameTime: TimeInterval = 1_800_001_000
        let beta = try makeSnapshot(
            id: "00000000-0000-0000-0000-000000000001",
            title: "Beta review",
            at: sameTime
        )
        let alpha = try makeSnapshot(
            id: "00000000-0000-0000-0000-000000000002",
            title: "Alpha review",
            at: sameTime
        )
        let pinned = try makeSnapshot(
            id: "00000000-0000-0000-0000-000000000003",
            title: "Pinned task",
            at: sameTime - 100,
            pinned: true
        )
        let archived = try makeSnapshot(
            id: "00000000-0000-0000-0000-000000000004",
            title: "Archived task",
            at: sameTime + 100,
            archived: true
        )
        let context = TaskSessionAvailabilityContext()

        let defaultRows = SessionCatalog.rows(
            sessions: [alpha, archived, pinned, beta],
            availabilityContext: context
        )
        XCTAssertEqual(defaultRows.map(\.id), [pinned.id, beta.id, alpha.id])

        let searchRows = SessionCatalog.rows(
            sessions: [alpha, pinned, beta],
            availabilityContext: context,
            query: TaskSessionCatalogQuery(searchText: "ALPHA")
        )
        XCTAssertEqual(searchRows.map(\.id), [alpha.id])

        let projectRows = SessionCatalog.rows(
            sessions: [alpha, pinned, beta],
            availabilityContext: context,
            query: TaskSessionCatalogQuery(
                workspaceRootURL: rootURL,
                projectURL: projectURL
            )
        )
        XCTAssertEqual(projectRows.count, 3)

        let titleRows = SessionCatalog.rows(
            sessions: [alpha, pinned, beta],
            availabilityContext: context,
            query: TaskSessionCatalogQuery(
                includeArchived: true,
                sort: .title
            )
        )
        XCTAssertEqual(
            titleRows.map(\.session.displayTitle),
            ["Alpha review", "Beta review", "Pinned task"]
        )
    }

    func testCatalogRecentOrderingAdvancesWithConversationActivity() throws {
        let originallyOlder = try makeSnapshot(
            id: "00000000-0000-0000-0000-000000000011",
            title: "Older task with new conversation",
            at: 1_800_001_000,
            conversationActivityAt: 1_800_001_300
        )
        let originallyNewer = try makeSnapshot(
            id: "00000000-0000-0000-0000-000000000012",
            title: "Newer task without conversation",
            at: 1_800_001_200
        )

        let rows = SessionCatalog.rows(
            sessions: [originallyNewer, originallyOlder],
            availabilityContext: TaskSessionAvailabilityContext(),
            query: TaskSessionCatalogQuery(sort: .recentFirst)
        )

        XCTAssertEqual(rows.map(\.id), [originallyOlder.id, originallyNewer.id])
        XCTAssertEqual(
            originallyOlder.lastConversationActivityAt,
            Date(timeIntervalSince1970: 1_800_001_300)
        )
        XCTAssertEqual(
            originallyOlder.lastActivityAt,
            Date(timeIntervalSince1970: 1_800_001_300)
        )
    }

    private func makeSnapshot(
        id: String,
        title: String,
        at: TimeInterval,
        pinned: Bool = false,
        archived: Bool = false,
        conversationActivityAt: TimeInterval? = nil,
        operationalState: TaskSessionOperationalState? = nil,
        operationalAuthority: TaskSessionEventAuthority = .conduitRecorded
    ) throws -> TaskSessionSnapshot {
        let sessionID = TaskSessionID(rawValue: UUID(uuidString: id)!)
        let date = Date(timeIntervalSince1970: at)
        let metadata = TaskSessionMetadata(
            workspace: .project(
                ProjectWorkspaceScopeSnapshot(
                    rootURL: rootURL,
                    projectURL: projectURL,
                    fallbackTitle: "Conduit",
                    fallbackSlug: "conduit"
                )
            ),
            agentName: "Codex",
            defaultTitle: title
        )
        var events = [
            TaskSessionEvent(
                taskSessionID: sessionID,
                occurredAt: date,
                recordedAt: date,
                authority: .conduitRecorded,
                kind: .created(metadata)
            )
        ]
        if pinned {
            events.append(
                TaskSessionEvent(
                    taskSessionID: sessionID,
                    occurredAt: date,
                    recordedAt: date,
                    authority: .operatorAsserted,
                    kind: .pinChanged(true)
                )
            )
        }
        if archived {
            events.append(
                TaskSessionEvent(
                    taskSessionID: sessionID,
                    occurredAt: date,
                    recordedAt: date,
                    authority: .operatorAsserted,
                    kind: .archiveChanged(true)
                )
            )
        }
        if let conversationActivityAt {
            events.append(
                .conversationActivity(
                    taskSessionID: sessionID,
                    at: Date(timeIntervalSince1970: conversationActivityAt)
                )
            )
        }
        if let operationalState {
            events.append(
                TaskSessionEvent(
                    taskSessionID: sessionID,
                    occurredAt: date,
                    recordedAt: date,
                    authority: operationalAuthority,
                    kind: .operationalStateChanged(operationalState)
                )
            )
        }
        return try XCTUnwrap(
            TaskSessionProjection.project(
                taskSessionID: sessionID,
                events: events
            )
        )
    }
}
