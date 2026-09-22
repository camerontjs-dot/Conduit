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
        XCTAssertFalse(
            ConduitSessionAPI.isWrite(
                .listProviderSessions(provider: "opencode")
            )
        )
        XCTAssertFalse(
            ConduitSessionAPI.isWrite(
                .observeWorker(
                    provider: "opencode",
                    providerSessionID: "ses_external"
                )
            )
        )
        XCTAssertTrue(
            ConduitSessionAPI.isWrite(
                .adoptProviderSession(
                    provider: "opencode",
                    providerSessionID: "ses_external",
                    controllerID: "supervisor-a"
                )
            )
        )
        XCTAssertFalse(ConduitSessionAPI.isWrite(.listSessions(cursor: nil, limit: nil)))
        XCTAssertFalse(
            ConduitSessionAPI.isWrite(
                .lifecyclePreflight(
                    taskSessionID: "task",
                    operation: .stopProviderHost
                )
            )
        )
        XCTAssertTrue(
            ConduitSessionAPI.isWrite(
                .lifecycleOperation(
                    taskSessionID: "task",
                    operation: .stopProviderHost
                )
            )
        )
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

    func testACPExcludesThoughtAndUserChunksFromAnswer() {
        var mapper = ACPSessionMapper()
        _ = mapper.apply(
            .response(id: .number(2), result: .object(["sessionId": .string("ses-1")]))
        )
        func update(_ kind: String, _ text: String) -> [StructuredAdapterEffect] {
            mapper.apply(
                .notification(
                    method: "session/update",
                    params: .object([
                        "update": .object([
                            "sessionUpdate": .string(kind),
                            "content": .object([
                                "type": .string("text"),
                                "text": .string(text),
                            ]),
                        ])
                    ])
                )
            )
        }
        // Gemini emits a thought chunk on ordinary turns; the operator's own
        // prompt can come back as a user chunk. Neither is the answer.
        XCTAssertTrue(update("agent_thought_chunk", "**Initiating System Integration**").isEmpty)
        XCTAssertTrue(update("user_message_chunk", "Reply with exactly READY.").isEmpty)
        let answer = update("agent_message_chunk", "READY")
        XCTAssertEqual(answer, [.upsertOutput(text: "READY", state: .live)])
        XCTAssertEqual(mapper.accumulatedText, "READY")
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

    /// Replays the real OpenCode stream captured on 2026-08-20 for a one-word
    /// reply. Before the fix this produced `"Say PONG only.PONGPONG"` three
    /// times over: the operator's prompt was accumulated as agent output, the
    /// snapshot and delta channels were both appended, and every completion
    /// signal appended another finished copy.
    private func replayCapturedPongTurn() -> (OpenCodeEventMapper, [StructuredAdapterEffect]) {
        var mapper = OpenCodeEventMapper()
        mapper.sessionID = "ses_fnHzVi"
        var effects: [StructuredAdapterEffect] = []
        let events: [CodexJSON] = [
            .object([
                "type": .string("message.updated"),
                "properties": .object([
                    "info": .object([
                        "id": .string("msg_user_KcZQQ2"),
                        "role": .string("user"),
                    ])
                ]),
            ]),
            .object([
                "type": .string("message.part.updated"),
                "properties": .object([
                    "part": .object([
                        "id": .string("prt_user_1"),
                        "messageID": .string("msg_user_KcZQQ2"),
                        "type": .string("text"),
                        "text": .string("Say PONG only."),
                    ])
                ]),
            ]),
            .object([
                "type": .string("message.updated"),
                "properties": .object([
                    "info": .object([
                        "id": .string("msg_asst_6nkayH"),
                        "role": .string("assistant"),
                    ])
                ]),
            ]),
            .object([
                "type": .string("message.part.updated"),
                "properties": .object([
                    "part": .object([
                        "id": .string("prt_asst_1"),
                        "messageID": .string("msg_asst_6nkayH"),
                        "type": .string("text"),
                        "text": .string(""),
                    ])
                ]),
            ]),
            .object([
                "type": .string("message.part.delta"),
                "properties": .object([
                    "field": .string("text"),
                    "partID": .string("prt_asst_1"),
                    "messageID": .string("msg_asst_6nkayH"),
                    "delta": .string("P"),
                ]),
            ]),
            .object([
                "type": .string("message.part.delta"),
                "properties": .object([
                    "field": .string("text"),
                    "partID": .string("prt_asst_1"),
                    "messageID": .string("msg_asst_6nkayH"),
                    "delta": .string("ONG"),
                ]),
            ]),
            .object([
                "type": .string("message.part.updated"),
                "properties": .object([
                    "part": .object([
                        "id": .string("prt_asst_1"),
                        "messageID": .string("msg_asst_6nkayH"),
                        "type": .string("text"),
                        "text": .string("PONG"),
                    ])
                ]),
            ]),
            .object([
                "type": .string("message.updated"),
                "properties": .object([
                    "info": .object([
                        "id": .string("msg_asst_6nkayH"),
                        "role": .string("assistant"),
                        "time": .object(["completed": .number(1)]),
                    ])
                ]),
            ]),
            .object([
                "type": .string("session.idle"),
                "properties": .object(["sessionID": .string("ses_fnHzVi")]),
            ]),
        ]
        for event in events {
            effects.append(contentsOf: mapper.apply(event))
        }
        return (mapper, effects)
    }

    func testOpenCodeDoesNotEchoOperatorPromptAsAgentOutput() {
        let (mapper, _) = replayCapturedPongTurn()
        XCTAssertEqual(mapper.accumulatedText, "PONG")
        XCTAssertFalse(mapper.accumulatedText.contains("Say PONG only."))
    }

    func testOpenCodeSnapshotAndDeltaDoNotDoubleCount() {
        let (mapper, _) = replayCapturedPongTurn()
        // "P" + "ONG" as deltas, then "PONG" as a snapshot of the same part.
        XCTAssertEqual(mapper.accumulatedText, "PONG")
    }

    func testOpenCodeClosesTurnExactlyOnce() {
        let (_, effects) = replayCapturedPongTurn()
        let closed = effects.filter {
            if case .upsertOutput(_, let state) = $0 { return state == .closed }
            return false
        }
        let completions = effects.filter {
            if case .turnCompleted = $0 { return true }
            return false
        }
        XCTAssertEqual(closed.count, 1, "one finished output per turn")
        XCTAssertEqual(completions.count, 1, "one completion per turn")
        XCTAssertEqual(closed.first, .upsertOutput(text: "PONG", state: .closed))
    }

    func testOpenCodeResetTurnClearsAccumulatedText() {
        var (mapper, _) = replayCapturedPongTurn()
        mapper.resetTurn()
        XCTAssertEqual(mapper.accumulatedText, "")
        XCTAssertFalse(mapper.turnActive)
    }

    func testOpenCodeExcludesReasoningPartFromAnswer() {
        // Replays the qwen3.5 stream captured on 2026-08-20. The reasoning part
        // announces its kind once, on a snapshot, and then streams as deltas
        // carrying `field: "text"` exactly like the answer does.
        var mapper = OpenCodeEventMapper()
        mapper.sessionID = "ses_local"
        func snapshot(_ partID: String, _ kind: String, _ text: String?) {
            var part: [String: CodexJSON] = [
                "id": .string(partID),
                "messageID": .string("msg_asst"),
                "type": .string(kind),
            ]
            if let text { part["text"] = .string(text) }
            _ = mapper.apply(
                .object([
                    "type": .string("message.part.updated"),
                    "properties": .object(["part": .object(part)]),
                ])
            )
        }
        func delta(_ partID: String, _ text: String) {
            _ = mapper.apply(
                .object([
                    "type": .string("message.part.delta"),
                    "properties": .object([
                        "field": .string("text"),
                        "partID": .string(partID),
                        "messageID": .string("msg_asst"),
                        "delta": .string(text),
                    ]),
                ])
            )
        }
        snapshot("prt_step", "step-start", nil)
        snapshot("prt_reason", "reasoning", "")
        delta("prt_reason", "The user is asking me to respond with ")
        delta("prt_reason", "exactly the word \"PONG\" only.")
        snapshot("prt_reason", "reasoning", "The user is asking me to respond with exactly the word \"PONG\" only.")
        snapshot("prt_answer", "text", "")
        delta("prt_answer", "P")
        delta("prt_answer", "ONG")
        snapshot("prt_answer", "text", "PONG")
        XCTAssertEqual(mapper.accumulatedText, "PONG")
        XCTAssertFalse(mapper.accumulatedText.contains("The user is asking"))
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
