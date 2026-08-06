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
}
