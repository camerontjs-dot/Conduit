import Foundation
import XCTest
@testable import ConduitCore

final class TaskSessionTmuxBindingTests: XCTestCase {
    private let separator = TmuxSessionListParser.fieldSeparator

    func testParserTreatsLegacyFiveFieldOutputAsAbsentTaskBinding() throws {
        let line = [
            "conduit-legacy",
            "1800000000",
            "0",
            "/tmp/MainFrame/30_projects/conduit",
            "Claude"
        ].joined(separator: separator)

        let session = try XCTUnwrap(TmuxSessionListParser.parse(line).first)
        XCTAssertEqual(session.taskSessionBinding, .absent)
        XCTAssertNil(session.taskSessionBinding.taskSessionID)
        XCTAssertEqual(
            TmuxSessionListParser.format
                .components(separatedBy: separator)
                .count,
            6
        )
    }

    func testParserReadsValidTaskBindingFromSixthField() throws {
        let taskSessionID = TaskSessionID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000123"
            )!
        )
        let line = [
            "conduit-bound",
            "1800000000",
            "1",
            "/tmp/MainFrame/30_projects/conduit",
            "Codex",
            taskSessionID.rawValue.uuidString.lowercased()
        ].joined(separator: separator)

        let session = try XCTUnwrap(TmuxSessionListParser.parse(line).first)
        XCTAssertEqual(
            session.taskSessionBinding,
            .valid(taskSessionID)
        )
        XCTAssertEqual(
            session.taskSessionBinding.taskSessionID,
            taskSessionID
        )
    }

    func testParserPreservesMalformedTaskBindingInsteadOfTreatingItAsAbsent() throws {
        let malformed = "not-a-task-session-uuid"
        let line = [
            "conduit-malformed",
            "1800000000",
            "0",
            "",
            "",
            malformed
        ].joined(separator: separator)

        let session = try XCTUnwrap(TmuxSessionListParser.parse(line).first)
        XCTAssertEqual(
            session.taskSessionBinding,
            .malformed(rawValue: malformed)
        )
        XCTAssertNil(session.taskSessionBinding.taskSessionID)
    }

    func testParserTreatsEmptySixthFieldAsAbsent() throws {
        let line = [
            "conduit-unbound",
            "1800000000",
            "0",
            "",
            "",
            ""
        ].joined(separator: separator)

        let session = try XCTUnwrap(TmuxSessionListParser.parse(line).first)
        XCTAssertEqual(session.taskSessionBinding, .absent)
    }

    func testSessionDescriptorDefaultsToNoTaskBindingAndDecodesLegacyPayload() throws {
        let descriptor = SessionDescriptor(
            id: UUID(
                uuidString: "00000000-0000-0000-0000-000000000201"
            )!,
            projectPath: URL(
                fileURLWithPath: "/tmp/MainFrame/30_projects/conduit"
            ),
            agent: AgentProfile(
                id: UUID(
                    uuidString: "00000000-0000-0000-0000-000000000202"
                )!,
                name: "Codex",
                command: "codex"
            ),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        XCTAssertNil(descriptor.taskSessionID)
        XCTAssertEqual(descriptor.adoptsLegacyTaskSession, false)
        XCTAssertEqual(descriptor.requiresExistingTmuxSession, false)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(descriptor)
            ) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "taskSessionID")
        legacyObject.removeValue(forKey: "adoptsLegacyTaskSession")
        legacyObject.removeValue(forKey: "requiresExistingTmuxSession")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let decoded = try JSONDecoder().decode(
            SessionDescriptor.self,
            from: legacyData
        )

        XCTAssertNil(decoded.taskSessionID)
        XCTAssertNil(decoded.adoptsLegacyTaskSession)
        XCTAssertNil(decoded.requiresExistingTmuxSession)
        XCTAssertEqual(decoded.projectPath, descriptor.projectPath)
        XCTAssertEqual(decoded.agent, descriptor.agent)
    }

    func testSessionDescriptorRoundTripsTaskBinding() throws {
        let taskSessionID = TaskSessionID(
            rawValue: UUID(
                uuidString: "00000000-0000-0000-0000-000000000203"
            )!
        )
        let descriptor = SessionDescriptor(
            projectPath: URL(
                fileURLWithPath: "/tmp/MainFrame/30_projects/conduit"
            ),
            agent: AgentProfile(name: "Claude", command: "claude"),
            tmuxSessionName: "conduit-bound",
            taskSessionID: taskSessionID,
            adoptsLegacyTaskSession: true,
            requiresExistingTmuxSession: true
        )

        let decoded = try JSONDecoder().decode(
            SessionDescriptor.self,
            from: JSONEncoder().encode(descriptor)
        )
        XCTAssertEqual(decoded, descriptor)
        XCTAssertEqual(decoded.taskSessionID, taskSessionID)
        XCTAssertEqual(decoded.adoptsLegacyTaskSession, true)
        XCTAssertEqual(decoded.requiresExistingTmuxSession, true)
    }

    func testRestartReconcilerExemptsExactDiscoveredTaskBinding() throws {
        let taskID = taskID(301)
        let attemptID = attemptID(401)
        let task = try openedTask(taskID, attemptID: attemptID)
        let discovered = DiscoveredSession(
            tmuxName: "conduit-bound",
            projectPath: URL(fileURLWithPath: "/tmp/OtherProject"),
            agentName: "Different Agent",
            taskSessionBinding: .valid(taskID)
        )

        XCTAssertEqual(
            TaskSessionRestartReconciler.interruptionCandidates(
                taskSessions: [task],
                liveTaskIDs: [],
                discoveredSessions: [discovered]
            ),
            []
        )
    }

    func testRestartReconcilerMarksOpenedTaskMissingFromCompleteDiscovery() throws {
        let taskID = taskID(302)
        let attemptID = attemptID(402)
        let task = try openedTask(taskID, attemptID: attemptID)

        XCTAssertEqual(
            TaskSessionRestartReconciler.interruptionCandidates(
                taskSessions: [task],
                liveTaskIDs: [],
                discoveredSessions: []
            ),
            [
                TaskSessionInterruptionCandidate(
                    taskSessionID: taskID,
                    runtimeAttemptID: attemptID
                )
            ]
        )
    }

    func testRestartReconcilerDoesNotLetUnrelatedBindingProtectMissingTask() throws {
        let targetTaskID = taskID(303)
        let attemptID = attemptID(403)
        let task = try openedTask(targetTaskID, attemptID: attemptID)
        let discovered = DiscoveredSession(
            tmuxName: "conduit-other",
            taskSessionBinding: .valid(taskID(304))
        )

        XCTAssertEqual(
            TaskSessionRestartReconciler.interruptionCandidates(
                taskSessions: [task],
                liveTaskIDs: [],
                discoveredSessions: [discovered]
            ).map(\.taskSessionID),
            [targetTaskID]
        )
    }

    func testRestartReconcilerExemptsInProcessTask() throws {
        let taskID = taskID(305)
        let task = try openedTask(taskID, attemptID: attemptID(405))

        XCTAssertEqual(
            TaskSessionRestartReconciler.interruptionCandidates(
                taskSessions: [task],
                liveTaskIDs: [taskID],
                discoveredSessions: []
            ),
            []
        )
    }

    func testRestartReconcilerSuppressesAllNegativeInferenceForMalformedBinding() throws {
        let taskID = taskID(306)
        let task = try openedTask(taskID, attemptID: attemptID(406))
        let malformed = DiscoveredSession(
            tmuxName: "conduit-malformed",
            taskSessionBinding: .malformed(rawValue: "not-a-task-id")
        )

        XCTAssertEqual(
            TaskSessionRestartReconciler.interruptionCandidates(
                taskSessions: [task],
                liveTaskIDs: [],
                discoveredSessions: [malformed]
            ),
            []
        )
    }

    private func openedTask(
        _ taskID: TaskSessionID,
        attemptID: RuntimeAttemptID
    ) throws -> TaskSessionSnapshot {
        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let metadata = TaskSessionMetadata(
            workspace: .project(
                ProjectWorkspaceScopeSnapshot(
                    rootURL: URL(fileURLWithPath: "/tmp/MainFrame"),
                    projectURL: URL(
                        fileURLWithPath: "/tmp/MainFrame/30_projects/conduit"
                    ),
                    fallbackTitle: "Conduit",
                    fallbackSlug: "conduit"
                )
            ),
            agentName: "Shell",
            defaultTitle: "Shell · Conduit"
        )
        return try XCTUnwrap(
            TaskSessionProjection.project(
                taskSessionID: taskID,
                events: [
                    TaskSessionEvent(
                        taskSessionID: taskID,
                        occurredAt: time,
                        recordedAt: time,
                        authority: .conduitRecorded,
                        kind: .created(metadata)
                    ),
                    TaskSessionEvent(
                        taskSessionID: taskID,
                        occurredAt: time.addingTimeInterval(1),
                        recordedAt: time.addingTimeInterval(1),
                        authority: .conduitRecorded,
                        kind: .operationalStateChanged(
                            .runtimeOpened(attemptID)
                        )
                    )
                ]
            )
        )
    }

    private func taskID(_ suffix: Int) -> TaskSessionID {
        TaskSessionID(
            rawValue: UUID(
                uuidString: String(
                    format: "00000000-0000-0000-0000-%012d",
                    suffix
                )
            )!
        )
    }

    private func attemptID(_ suffix: Int) -> RuntimeAttemptID {
        RuntimeAttemptID(
            rawValue: UUID(
                uuidString: String(
                    format: "10000000-0000-0000-0000-%012d",
                    suffix
                )
            )!
        )
    }
}
