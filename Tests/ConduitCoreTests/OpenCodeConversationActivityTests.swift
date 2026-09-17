import XCTest
@testable import ConduitCore

final class OpenCodeConversationActivityTests: XCTestCase {
    func testToolActivityUsesProviderIdentityAndStatus() {
        let event = CodexJSON.object([
            "type": .string("message.part.updated"),
            "properties": .object([
                "part": .object([
                    "id": .string("prt_tool_1"),
                    "sessionID": .string("ses_current"),
                    "messageID": .string("msg_asst"),
                    "type": .string("tool"),
                    "tool": .string("read"),
                    "state": .object([
                        "status": .string("running"),
                        "title": .string("Reading ConversationView.swift"),
                        "input": .object([
                            "filePath": .string("Sources/Conduit/ConversationView.swift")
                        ]),
                    ]),
                ])
            ]),
        ])

        XCTAssertEqual(
            OpenCodeConversationActivityExtractor.activity(
                from: event,
                boundSessionID: "ses_current"
            ),
            OpenCodeConversationActivity(
                id: "opencode-tool:prt_tool_1",
                sessionID: "ses_current",
                messageID: "msg_asst",
                kind: .tool,
                state: .running,
                title: "Reading ConversationView.swift",
                toolName: "read",
                paths: ["Sources/Conduit/ConversationView.swift"]
            )
        )
    }

    func testToolActivityDoesNotRetainCompletedOutput() {
        let event = CodexJSON.object([
            "type": .string("message.part.updated"),
            "properties": .object([
                "part": .object([
                    "id": .string("prt_tool_2"),
                    "sessionID": .string("ses_current"),
                    "type": .string("tool"),
                    "tool": .string("bash"),
                    "state": .object([
                        "status": .string("completed"),
                        "title": .string("Run tests"),
                        "input": .object(["command": .string("swift test")]),
                        "output": .string("SECRET-LIKE TOOL OUTPUT MUST NOT ENTER THE CARD"),
                    ]),
                ])
            ]),
        ])

        let activity = OpenCodeConversationActivityExtractor.activity(
            from: event,
            boundSessionID: "ses_current"
        )
        XCTAssertEqual(activity?.state, .completed)
        XCTAssertEqual(activity?.title, "Run tests")
        XCTAssertNil(activity?.detail)
        XCTAssertFalse(activity?.title.contains("SECRET-LIKE") == true)
    }

    func testFailedToolKeepsOnlyBoundedErrorDetail() {
        let event = CodexJSON.object([
            "type": .string("message.part.updated"),
            "properties": .object([
                "part": .object([
                    "id": .string("prt_tool_3"),
                    "sessionID": .string("ses_current"),
                    "type": .string("tool"),
                    "tool": .string("edit"),
                    "state": .object([
                        "status": .string("error"),
                        "error": .string(String(repeating: "x", count: 400)),
                    ]),
                ])
            ]),
        ])

        let activity = OpenCodeConversationActivityExtractor.activity(
            from: event,
            boundSessionID: "ses_current"
        )
        XCTAssertEqual(activity?.state, .failed)
        XCTAssertEqual(activity?.toolName, "edit")
        XCTAssertEqual(activity?.detail?.count, 241)
        XCTAssertTrue(activity?.detail?.hasSuffix("…") == true)
    }

    func testPatchActivityPreservesExactProviderFileList() {
        let event = CodexJSON.object([
            "type": .string("message.part.updated"),
            "properties": .object([
                "part": .object([
                    "id": .string("prt_patch_1"),
                    "sessionID": .string("ses_current"),
                    "messageID": .string("msg_asst"),
                    "type": .string("patch"),
                    "hash": .string("abc123"),
                    "files": .array([
                        .string("Sources/A.swift"),
                        .string("Sources/B.swift"),
                    ]),
                ])
            ]),
        ])

        let activity = OpenCodeConversationActivityExtractor.activity(
            from: event,
            boundSessionID: "ses_current"
        )
        XCTAssertEqual(activity?.kind, .patch)
        XCTAssertEqual(activity?.state, .observed)
        XCTAssertEqual(activity?.title, "Changed 2 files")
        XCTAssertEqual(activity?.paths, ["Sources/A.swift", "Sources/B.swift"])
    }

    func testForeignSessionActivityIsRejected() {
        let event = CodexJSON.object([
            "type": .string("message.part.updated"),
            "properties": .object([
                "part": .object([
                    "id": .string("prt_tool_foreign"),
                    "sessionID": .string("ses_other"),
                    "type": .string("tool"),
                    "tool": .string("read"),
                    "state": .object(["status": .string("completed")]),
                ])
            ]),
        ])

        XCTAssertNil(
            OpenCodeConversationActivityExtractor.activity(
                from: event,
                boundSessionID: "ses_current"
            )
        )
    }

    func testActivityWithoutSessionIdentityIsRejected() {
        let event = CodexJSON.object([
            "type": .string("message.part.updated"),
            "properties": .object([
                "part": .object([
                    "id": .string("prt_tool_unknown"),
                    "type": .string("tool"),
                    "tool": .string("read"),
                    "state": .object(["status": .string("completed")]),
                ])
            ]),
        ])

        XCTAssertNil(
            OpenCodeConversationActivityExtractor.activity(
                from: event,
                boundSessionID: "ses_current"
            )
        )
    }

    func testReasoningAndTextPartsAreNotActivities() {
        for kind in ["reasoning", "text", "step-start", "step-finish"] {
            let event = CodexJSON.object([
                "type": .string("message.part.updated"),
                "properties": .object([
                    "part": .object([
                        "id": .string("prt_\(kind)"),
                        "sessionID": .string("ses_current"),
                        "type": .string(kind),
                    ])
                ]),
            ])
            XCTAssertNil(
                OpenCodeConversationActivityExtractor.activity(
                    from: event,
                    boundSessionID: "ses_current"
                ),
                "\(kind) must not be promoted into tool activity"
            )
        }
    }

    func testActivityRoundTripsWithoutToolOutput() throws {
        let source = OpenCodeConversationActivity(
            id: "opencode-tool:prt_tool_roundtrip",
            sessionID: "ses_current",
            messageID: "msg_asst",
            kind: .tool,
            state: .completed,
            title: "Read source",
            toolName: "read",
            paths: ["Sources/Conduit/ConversationView.swift"]
        )
        let data = try JSONEncoder().encode(source)
        let decoded = try JSONDecoder().decode(
            OpenCodeConversationActivity.self,
            from: data
        )
        XCTAssertEqual(decoded, source)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("output"))
    }
}
