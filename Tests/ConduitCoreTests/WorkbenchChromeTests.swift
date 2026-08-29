import XCTest
@testable import ConduitCore

final class WorkbenchChromeTests: XCTestCase {
    func testCompanionScaleDefaultsFollowDensity() {
        XCTAssertEqual(CompanionScale.defaultFor(density: .focused), .compact)
        XCTAssertEqual(CompanionScale.defaultFor(density: .balanced), .standard)
        XCTAssertEqual(CompanionScale.defaultFor(density: .operator), .expanded)
        XCTAssertGreaterThan(
            CompanionScale.expanded.spriteSide,
            CompanionScale.compact.spriteSide
        )
    }

    func testOperatorPeekDefaultsAreOffExceptOperatorDensity() {
        XCTAssertFalse(OperatorPeekPolicy.defaultEnabled(for: .focused))
        XCTAssertFalse(OperatorPeekPolicy.defaultEnabled(for: .balanced))
        XCTAssertTrue(OperatorPeekPolicy.defaultEnabled(for: .operator))
    }

    func testOperatorPeekCustomizedWinsOverDensity() {
        XCTAssertTrue(
            OperatorPeekPolicy.resolveEnabled(
                customized: true,
                storedEnabled: true,
                density: .focused
            )
        )
        XCTAssertFalse(
            OperatorPeekPolicy.resolveEnabled(
                customized: true,
                storedEnabled: false,
                density: .operator
            )
        )
        XCTAssertFalse(
            OperatorPeekPolicy.resolveEnabled(
                customized: false,
                storedEnabled: true,
                density: .focused
            )
        )
    }

    func testInboxAttentionCountsReconnectableOnlyFromVisibleRows() throws {
        let reconnectable = TaskSessionCatalogRow(
            session: try sampleTask(title: "a", pinned: false),
            availability: .reconnectable
        )
        let running = TaskSessionCatalogRow(
            session: try sampleTask(title: "live", pinned: false),
            availability: .running(RuntimeAttemptID())
        )
        let pinned = TaskSessionCatalogRow(
            session: try sampleTask(title: "pin", pinned: true),
            availability: .reconnectable
        )
        let attention = AgentInboxAttention.from(
            pinned: [pinned],
            active: [reconnectable, running],
            recent: [],
            archived: [],
            discoveredCount: 2
        )
        XCTAssertEqual(attention.pinned, 1)
        XCTAssertEqual(attention.active, 2)
        XCTAssertEqual(attention.reconnectable, 2)
        XCTAssertEqual(attention.needsAttention, 2)
        XCTAssertEqual(attention.discovered, 2)
        XCTAssertTrue(attention.summaryLine.contains("2 reconnectable"))
        XCTAssertTrue(attention.summaryLine.contains("2 active"))
    }

    func testEmptyInboxSummaryIsHonest() {
        let attention = AgentInboxAttention.from(
            pinned: [],
            active: [],
            recent: [],
            archived: [],
            discoveredCount: 0
        )
        XCTAssertEqual(attention.summaryLine, "No tasks in this scope")
        XCTAssertEqual(attention.needsAttention, 0)
    }

    func testNextSafeActionResolution() {
        XCTAssertEqual(
            SessionNextSafeAction.resolve(
                hasSelectedTask: true,
                hasOpenRuntime: true,
                isDetached: false,
                isReconnectableWithoutRuntime: false
            ),
            .openRaw
        )
        XCTAssertEqual(
            SessionNextSafeAction.resolve(
                hasSelectedTask: true,
                hasOpenRuntime: true,
                isDetached: true,
                isReconnectableWithoutRuntime: false
            ),
            .reconnect
        )
        XCTAssertEqual(
            SessionNextSafeAction.resolve(
                hasSelectedTask: true,
                hasOpenRuntime: false,
                isDetached: false,
                isReconnectableWithoutRuntime: true
            ),
            .reconnect
        )
        XCTAssertEqual(
            SessionNextSafeAction.resolve(
                hasSelectedTask: true,
                hasOpenRuntime: false,
                isDetached: false,
                isReconnectableWithoutRuntime: false
            ),
            .newTask
        )
        XCTAssertEqual(
            SessionNextSafeAction.resolve(
                hasSelectedTask: false,
                hasOpenRuntime: false,
                isDetached: false,
                isReconnectableWithoutRuntime: false
            ),
            .selectTask
        )
    }

    func testJuicyFeedbackHonorsReduceMotionAndNeverAnimatesPoses() {
        XCTAssertFalse(JuicyFeedbackPolicy.shouldAnimatePoseChange())
        XCTAssertTrue(
            JuicyFeedbackPolicy.shouldPlayChromeMotion(
                juicyEnabled: true,
                reduceMotion: false
            )
        )
        XCTAssertFalse(
            JuicyFeedbackPolicy.shouldPlayChromeMotion(
                juicyEnabled: true,
                reduceMotion: true
            )
        )
        XCTAssertFalse(
            JuicyFeedbackPolicy.shouldPlayChromeMotion(
                juicyEnabled: false,
                reduceMotion: false
            )
        )
    }

    private func sampleTask(
        title: String,
        pinned: Bool
    ) throws -> TaskSessionSnapshot {
        let id = TaskSessionID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = TaskSessionMetadata(
            workspace: .project(
                ProjectWorkspaceScopeSnapshot(
                    rootURL: URL(fileURLWithPath: "/tmp/mainframe"),
                    projectURL: URL(fileURLWithPath: "/tmp/mainframe/30_projects/conduit"),
                    fallbackTitle: "Conduit",
                    fallbackSlug: "conduit"
                )
            ),
            agentName: "Codex",
            defaultTitle: title
        )
        var events = [
            TaskSessionEvent(
                taskSessionID: id,
                occurredAt: now,
                recordedAt: now,
                authority: .conduitRecorded,
                kind: .created(metadata)
            )
        ]
        if pinned {
            events.append(
                TaskSessionEvent(
                    taskSessionID: id,
                    occurredAt: now.addingTimeInterval(1),
                    recordedAt: now.addingTimeInterval(1),
                    authority: .conduitRecorded,
                    kind: .pinChanged(true)
                )
            )
        }
        let snapshot = TaskSessionProjection.project(taskSessionID: id, events: events)
        return try XCTUnwrap(snapshot)
    }
}
