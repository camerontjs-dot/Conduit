import XCTest
@testable import ConduitCore

final class StructuredAdapterTests: XCTestCase {
    func testPreferredBackends() {
        XCTAssertEqual(
            AgentProfile(name: "Codex", command: "codex").preferredSessionBackend,
            .appServer
        )
        XCTAssertEqual(
            AgentProfile(name: "Grok", command: "grok").preferredSessionBackend,
            .acp
        )
        XCTAssertEqual(
            AgentProfile(name: "OpenCode", command: "opencode").preferredSessionBackend,
            .httpServer
        )
        XCTAssertEqual(
            AgentProfile(name: "Claude", command: "claude").preferredSessionBackend,
            .structuredCli
        )
        XCTAssertEqual(
            AgentProfile(name: "Antigravity", command: "agy").preferredSessionBackend,
            .structuredCli
        )
        XCTAssertEqual(
            AgentProfile(name: "Gemini CLI", command: "gemini").preferredSessionBackend,
            .acp
        )
        XCTAssertEqual(
            AgentProfile(name: "Shell", command: "/bin/zsh", kind: .shell).preferredSessionBackend,
            .pty
        )
        XCTAssertTrue(AgentProfile(name: "Grok", command: "grok").prefersStructuredHost)
        XCTAssertTrue(AgentProfile(name: "Gemini CLI", command: "gemini").prefersStructuredHost)
    }

    func testHostEnvelopeSkipsStructuredHosts() {
        XCTAssertFalse(
            HostEnvelope.shouldInject(for: AgentProfile(name: "Grok", command: "grok"))
        )
        XCTAssertFalse(
            HostEnvelope.shouldInject(for: AgentProfile(name: "OpenCode", command: "opencode"))
        )
        XCTAssertFalse(
            HostEnvelope.shouldInject(for: AgentProfile(name: "Claude", command: "claude"))
        )
        XCTAssertTrue(
            HostEnvelope.shouldInject(for: AgentProfile(name: "Aider", command: "aider"))
        )
    }

    func testSessionAPIListAdaptersIsReadOnly() {
        XCTAssertFalse(ConduitSessionAPI.isWrite(.listAdapters))
        XCTAssertFalse(ConduitSessionAPI.isWrite(.listSessions(cursor: nil, limit: nil)))
    }

    func testACPPromptCompletion() {
        var mapper = ACPSessionMapper()
        let session = mapper.apply(
            .response(
                id: .number(2),
                result: .object(["sessionId": .string("ses-1")])
            )
        )
        XCTAssertEqual(session, [.sessionStarted(id: "ses-1")])
        let chunks = mapper.apply(
            .notification(
                method: "session/update",
                params: .object([
                    "update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object([
                            "type": .string("text"),
                            "text": .string("PING"),
                        ]),
                    ])
                ])
            )
        )
        XCTAssertEqual(chunks, [.upsertOutput(text: "PING", state: .live)])
        let done = mapper.apply(
            .response(
                id: .number(3),
                result: .object(["stopReason": .string("end_turn")])
            )
        )
        XCTAssertEqual(
            done,
            [
                .upsertOutput(text: "PING", state: .closed),
                .turnCompleted(status: "end_turn"),
            ]
        )
    }

    func testACPPermissionOptions() {
        let params = CodexJSON.object([
            "title": .string("Run git status"),
            "options": .array([
                .object([
                    "optionId": .string("allow-once"),
                    "kind": .string("allow_once"),
                ]),
                .object([
                    "optionId": .string("reject"),
                    "kind": .string("reject"),
                ]),
            ]),
        ])
        XCTAssertEqual(ACPSessionMapper.allowOptionID(params), "allow-once")
        XCTAssertEqual(ACPSessionMapper.permissionSummary(params), "Run git status")
    }

    func testOpenCodePromptBodySplitsGoogleModel() {
        let split = OpenCodeHTTPContract.splitModel("google/gemini-2.5-flash")
        XCTAssertEqual(split?.providerID, "google")
        XCTAssertEqual(split?.modelID, "gemini-2.5-flash")
        let body = OpenCodeHTTPContract.promptBody(
            text: "PING",
            providerID: split?.providerID,
            modelID: split?.modelID
        )
        XCTAssertEqual((body["model"] as? [String: String])?["providerID"], "google")
        XCTAssertTrue(OpenCodeHTTPContract.isHealthy(.object(["healthy": .bool(true)])))
    }

    func testOpenCodeSSEIgnoresOtherSessions() {
        var mapper = OpenCodeEventMapper()
        mapper.sessionID = "ses_abc"
        let foreign = mapper.apply(
            .object([
                "type": .string("message.part.updated"),
                "properties": .object([
                    "sessionID": .string("ses_other"),
                    "part": .object(["text": .string("nope")]),
                ]),
            ])
        )
        XCTAssertTrue(foreign.isEmpty)
        XCTAssertEqual(mapper.accumulatedText, "")
    }

    func testOpenCodeSSECompletion() {
        var mapper = OpenCodeEventMapper()
        let started = mapper.apply(
            .object([
                "type": .string("session.created"),
                "properties": .object(["id": .string("ses_abc")]),
            ])
        )
        XCTAssertEqual(started, [.sessionStarted(id: "ses_abc")])
        _ = mapper.apply(
            .object([
                "type": .string("message.part.updated"),
                "properties": .object([
                    "part": .object(["text": .string("hello")]),
                ]),
            ])
        )
        let done = mapper.apply(
            .object(["type": .string("session.idle")])
        )
        XCTAssertTrue(done.contains(.turnCompleted(status: "completed")))
    }

    func testOpenCodeSSELineParse() {
        let json = OpenCodeEventMapper.parseSSELine(
            "data: {\"type\":\"server.connected\",\"properties\":{}}"
        )
        XCTAssertEqual(json?["type"]?.stringValue, "server.connected")
    }

    func testClaudeStreamJSON() {
        var mapper = StreamJSONMapper(flavor: .claude)
        let initEffects = mapper.applyLine(
            #"{"type":"system","subtype":"init","session_id":"c-1"}"#
        )
        XCTAssertEqual(initEffects, [.sessionStarted(id: "c-1")])
        _ = mapper.applyLine(
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"PING"}]}}"#
        )
        let result = mapper.applyLine(
            #"{"type":"result","subtype":"success","is_error":false,"session_id":"c-1","result":"PING"}"#
        )
        XCTAssertTrue(result.contains(.turnCompleted(status: "success")))
        XCTAssertEqual(
            StreamJSONMapper.claudeArguments(resumeSessionID: "c-1", prompt: "hi").contains("-r"),
            true
        )
    }

    func testAntigravityStreamJSON() {
        var mapper = StreamJSONMapper(flavor: .antigravity)
        _ = mapper.applyLine(
            #"{"event":"init","conversation_id":"agy-1"}"#
        )
        XCTAssertEqual(mapper.sessionID, "agy-1")
        let result = mapper.applyLine(
            #"{"event":"result","result":{"status":"SUCCESS","response":"PONG","conversation_id":"agy-1"}}"#
        )
        XCTAssertTrue(result.contains(.turnCompleted(status: "SUCCESS")))
        XCTAssertTrue(
            StreamJSONMapper.antigravityArguments(
                resumeSessionID: "agy-1",
                prompt: "hi"
            ).contains("--conversation")
        )
    }

    func testCatalogGeminiPrefersACP() {
        let gemini = StructuredAdapterCatalog.descriptor(matching: "gemini")
        XCTAssertEqual(gemini?.backend, .acp)
        XCTAssertEqual(gemini?.status, "preferred")
    }
}
