#if os(macOS)
import ConduitCore
import Darwin
import Foundation

/// Loopback HTTP/MCP listener for D-039 session tools. Off unless enabled.
///
/// Uses a POSIX IPv4 `127.0.0.1` socket so the full HTTP body is written
/// before close. Network.framework's listener was observed dropping bodies.
@MainActor
final class ConduitSessionAPIServer {
    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "dev.camerontjs.conduit.session-api")
    private let token: String
    private let allowWrites: Bool
    private let handle: (ConduitSessionCommand, ConduitSessionCaller) -> [String: Any]

    /// `clientInfo` from the most recent `initialize` on this listener.
    ///
    /// MCP `2024-11-05` over HTTP has no per-request session id, and this
    /// listener closes every connection, so there is nothing else to key a
    /// caller on. Writes fail closed until an `initialize` has been seen.
    private var peerIdentity: String?
    private var peerObservedAt: Date?

    init(
        token: String,
        allowWrites: Bool = false,
        handle: @escaping (ConduitSessionCommand, ConduitSessionCaller) -> [String: Any]
    ) {
        self.token = token
        self.allowWrites = allowWrites
        self.handle = handle
    }

    func start() throws {
        stop()
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(
                domain: "Conduit.SessionAPI",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create loopback socket."]
            )
        }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(ConduitSessionAPI.loopbackPort).bigEndian)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw NSError(
                domain: "Conduit.SessionAPI",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not bind 127.0.0.1:\(ConduitSessionAPI.loopbackPort)."]
            )
        }
        listenFD = fd
        running = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    private func acceptLoop() {
        while running {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                if running { Thread.sleep(forTimeInterval: 0.02) }
                continue
            }
            let request = readRequest(from: client)
            let lock = DispatchSemaphore(value: 0)
            var response = Data()
            DispatchQueue.main.async {
                response = self.response(for: request)
                lock.signal()
            }
            lock.wait()
            response.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    _ = send(client, base, response.count, 0)
                }
            }
            close(client)
        }
    }

    private func readRequest(from client: Int32) -> Data {
        let delimiter = Data("\r\n\r\n".utf8)
        let maxRequestBytes = 1_048_576
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while request.range(of: delimiter) == nil, request.count < maxRequestBytes {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return request }
            request.append(buffer, count: count)
        }

        guard let headerRange = request.range(of: delimiter) else {
            return request
        }
        let headerText = String(decoding: request[..<headerRange.lowerBound], as: UTF8.self)
        let contentLength = headerText
            .split(whereSeparator: \.isNewline)
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line in
                line.split(separator: ":", maxSplits: 1)
                    .last
                    .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            } ?? 0
        let bodyStart = headerRange.upperBound
        let targetSize = min(maxRequestBytes, bodyStart + contentLength)

        while request.count < targetSize {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            request.append(buffer, count: count)
        }
        return request
    }

    static func loadOrCreateToken() -> String {
        let url = AdapterThreadStore.defaultDirectory()
            .appendingPathComponent("session-api-token")
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        let token = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? token.write(to: url, atomically: true, encoding: .utf8)
        return token
    }

    private func response(for request: Data) -> Data {
        let text = String(decoding: request, as: UTF8.self)
        let headerEnd = text.range(of: "\r\n\r\n")?.upperBound
            ?? text.range(of: "\n\n")?.upperBound
        let headers = headerEnd.map { String(text[..<$0]) } ?? text
        let body = headerEnd.map { String(text[$0...]) } ?? ""
        let firstLine = headers.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let isHealth = firstLine.contains("GET /healthz") || firstLine.contains("GET /readyz")
        if isHealth {
            return http(200, body: "ok\n", contentType: "text/plain")
        }
        // This endpoint uses a local bearer token supplied by tunnel-client,
        // not OAuth. A 404 tells no-auth MCP clients that protected-resource
        // metadata is intentionally absent; 405 is treated as malformed
        // metadata and leaves their readiness checks degraded.
        let isProtectedResourceMetadataRequest =
            firstLine.hasPrefix("GET /.well-known/oauth-protected-resource")
        if isProtectedResourceMetadataRequest {
            return http(404, body: "{\"error\":\"not found\"}\n")
        }
        let authorized = headers
            .split(whereSeparator: \.isNewline)
            .contains { line in
                line.lowercased().hasPrefix("authorization:")
                    && line.lowercased().contains("bearer \(token.lowercased())")
            }
        guard authorized else {
            return http(401, body: "{\"error\":\"unauthorized\"}\n")
        }
        guard firstLine.contains("POST ") else {
            return http(405, body: "{\"error\":\"POST /mcp only\"}\n")
        }
        guard let payload = CodexJSON.parseLine(body) else {
            return http(400, body: "{\"error\":\"invalid json\"}\n")
        }
        let reply = mcpReply(payload)
        guard let data = try? JSONSerialization.data(withJSONObject: reply),
              let json = String(data: data, encoding: .utf8)
        else {
            return http(500, body: "{\"error\":\"encode failed\"}\n")
        }
        return http(200, body: json + "\n")
    }

    private func mcpReply(_ payload: CodexJSON) -> [String: Any] {
        let id: Any = {
            switch payload["id"] {
            case .string(let value): return value
            case .number(let value): return Int(value)
            case .bool(let value): return value
            default: return NSNull()
            }
        }()
        let method = payload["method"]?.stringValue ?? ""
        switch method {
        case "initialize":
            let info = payload["params"]?["clientInfo"]
            let clientName = info?["name"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !clientName.isEmpty {
                let version = info?["version"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                peerIdentity = version.isEmpty
                    ? clientName
                    : "\(clientName)/\(version)"
                peerObservedAt = Date()
            }
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "conduit-session", "version": "1.2"],
                ],
            ]
        case "ping":
            return ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
        case "tools/list":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["tools": ConduitSessionToolCatalog.tools()],
            ]
        case "tools/call":
            let name = payload["params"]?["name"]?.stringValue ?? ""
            let args = payload["params"]?["arguments"] ?? .object([:])
            let result = callTool(name: name, arguments: args)
            return ["jsonrpc": "2.0", "id": id, "result": result]
        default:
            return [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": "method not found"],
            ]
        }
    }

    private static func intArgument(_ value: CodexJSON?) -> Int? {
        guard let value else { return nil }
        if case .number(let number) = value { return Int(number) }
        if let raw = value.stringValue { return Int(raw) }
        return nil
    }

    private func callTool(name: String, arguments: CodexJSON) -> [String: Any] {
        let command: ConduitSessionCommand?
        switch name {
        case "conduit_list_projects":
            command = .listProjects
        case "conduit_list_sessions":
            command = .listSessions(
                cursor: arguments["cursor"]?.stringValue,
                limit: Self.intArgument(arguments["limit"])
            )
        case "conduit_list_adapters":
            command = .listAdapters
        case "conduit_session_status":
            if let id = arguments["taskSessionID"]?.stringValue {
                command = .sessionStatus(taskSessionID: id)
            } else {
                command = nil
            }
        case "conduit_session_events":
            if let id = arguments["taskSessionID"]?.stringValue {
                let cursor = arguments["cursor"]?.stringValue
                let limit = Self.intArgument(arguments["limit"])
                command = .sessionEvents(
                    taskSessionID: id,
                    cursor: cursor,
                    limit: limit
                )
            } else {
                command = nil
            }
        case "conduit_query_mindgraph":
            let question = arguments["question"]?.stringValue ?? ""
            let scope = arguments["scope"]?.stringValue ?? ""
            command = .queryMindGraph(question: question, scope: scope)
        case "conduit_create_task":
            let agent = arguments["agent"]?.stringValue ?? ""
            let projectSlug = arguments["project_slug"]?.stringValue
                ?? arguments["projectSlug"]?.stringValue
                ?? ""
            let objective = arguments["objective"]?.stringValue ?? ""
            let idempotencyKey = (
                arguments["idempotency_key"]?.stringValue
                    ?? arguments["idempotencyKey"]?.stringValue
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            if agent.isEmpty || projectSlug.isEmpty {
                command = nil
            } else {
                command = .createTask(
                    agent: agent,
                    projectSlug: projectSlug,
                    objective: objective,
                    idempotencyKey: (idempotencyKey?.isEmpty ?? true)
                        ? nil
                        : idempotencyKey
                )
            }
        case "conduit_reconcile_task":
            if let id = arguments["taskSessionID"]?.stringValue {
                command = .reconcileTask(taskSessionID: id)
            } else {
                command = nil
            }
        case "conduit_send_prompt":
            if let id = arguments["taskSessionID"]?.stringValue,
               let text = arguments["text"]?.stringValue {
                command = .sendPrompt(taskSessionID: id, text: text, origin: .chatgpt)
            } else {
                command = nil
            }
        case "conduit_interrupt":
            if let id = arguments["taskSessionID"]?.stringValue {
                command = .interrupt(taskSessionID: id)
            } else {
                command = nil
            }
        case "conduit_close_session":
            if let id = arguments["taskSessionID"]?.stringValue {
                command = .closeSession(taskSessionID: id)
            } else {
                command = nil
            }
        default:
            command = nil
        }
        guard let command else {
            return [
                "isError": true,
                "content": [["type": "text", "text": "Unknown or incomplete tool: \(name)"]],
            ]
        }
        if ConduitSessionAPI.isWrite(command) && !allowWrites {
            return [
                "isError": true,
                "content": [[
                    "type": "text",
                    "text": "Write tools are disabled. Enable Session API writes in Conduit Settings.",
                ]],
            ]
        }
        let payload = handle(
            command,
            ConduitSessionCaller(
                identity: peerIdentity,
                observedAt: peerObservedAt
            )
        )
        let text = (try? String(
            data: JSONSerialization.data(withJSONObject: payload),
            encoding: .utf8
        )) ?? "{}"
        var result: [String: Any] = [
            "isError": payload["error"] != nil,
            "content": [["type": "text", "text": text]],
        ]
        if name == "conduit_session_events", payload["error"] == nil {
            result["structuredContent"] = payload
        }
        return result
    }

    // These annotations intentionally describe only the current MCP operation.
    // Local read queries neither mutate Conduit nor reach the open web. Lifecycle
    // controls may change a runtime or cause an agent to act in its project, so
    // they remain conservatively destructive until a narrower guarantee exists.
    private static let localReadOnlyAnnotations: [String: Any] = [
        "readOnlyHint": true,
        "openWorldHint": false,
    ]

    private static let stateChangingAnnotations: [String: Any] = [
        "readOnlyHint": false,
        "destructiveHint": true,
    ]

    private static let nonDestructiveStateChangingAnnotations: [String: Any] = [
        "readOnlyHint": false,
        "destructiveHint": false,
        "openWorldHint": false,
    ]

    private static let sessionEventsOutputSchema: [String: Any] = [
        "type": "object",
        "required": [
            "taskSessionID",
            "backend",
            "session",
            "turn",
            "observation",
            "events",
            "next_cursor",
            "has_more",
            "cursor_state",
            "timeline_count",
            "truncated",
            "authority",
        ],
        "properties": [
            "taskSessionID": ["type": "string"],
            "backend": ["type": "string"],
            "session": [
                "type": "object",
                "properties": [
                    "lifecycle": ["type": "string"],
                    "runtime_state": ["type": "string"],
                    "live": ["type": "boolean"],
                    "ready": ["type": "boolean"],
                ],
            ],
            "turn": [
                "type": "object",
                "properties": [
                    "state": [
                        "type": "string",
                        "enum": [
                            "idle",
                            "active",
                            "completed",
                            "awaiting_input",
                            "ambiguous",
                        ],
                    ],
                    "status": ["type": "string"],
                    "honesty": ["type": "string"],
                    "ambiguity": ["type": "string"],
                    "thread_id": ["type": "string"],
                    "thread_id_source": [
                        "type": "string",
                        "enum": ["live", "persisted", "unavailable"],
                    ],
                    "pending_approval": ["type": "boolean"],
                ],
            ],
            "observation": [
                "type": "object",
                "required": [
                    "observed_at",
                    "last_output_state",
                    "checkpoint",
                    "provider_progress",
                    "input_state",
                    "checkpoint_authority",
                ],
                "properties": [
                    "observed_at": ["type": "string"],
                    "last_output_at": ["type": "string"],
                    "last_output_state": [
                        "type": "string",
                        "enum": ["none", "live", "settled", "closed"],
                    ],
                    "checkpoint": [
                        "type": "string",
                        "enum": [
                            "structured_active",
                            "structured_approval",
                            "structured_completed",
                            "structured_idle",
                            "output_live",
                            "output_quiet",
                            "output_unobserved",
                            "capture_closed",
                        ],
                    ],
                    "provider_progress": [
                        "type": "string",
                        "enum": ["structured", "unavailable"],
                    ],
                    "input_state": [
                        "type": "string",
                        "enum": ["approval", "unknown", "none"],
                    ],
                    "input_summary": ["type": "string"],
                    "checkpoint_authority": ["type": "string"],
                ],
            ],
            "runtime_attempt_id": ["type": "string"],
            "events": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "cursor": ["type": "string"],
                        "event_id": ["type": "string"],
                        "occurred_at": ["type": "string"],
                        "kind": ["type": "string"],
                        "authority": ["type": "string"],
                        "source": ["type": "string"],
                        "text": ["type": "string"],
                        "state": ["type": "string"],
                        "truncated": ["type": "boolean"],
                        "redacted": ["type": "boolean"],
                        "prompt_event_id": ["type": "string"],
                        "artifact_refs": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "kind": ["type": "string"],
                                    "path": ["type": "string"],
                                ],
                            ],
                        ],
                        "turn_status": ["type": "string"],
                        "content_digest": ["type": "string"],
                    ],
                ],
            ],
            "next_cursor": ["type": "string"],
            "has_more": ["type": "boolean"],
            "cursor_state": [
                "type": "string",
                "enum": ["ok", "ahead", "invalid"],
            ],
            "timeline_count": ["type": "integer"],
            "truncated": ["type": "boolean"],
            "authority": ["type": "string"],
        ],
    ]

    private static let readTools: [[String: Any]] = [
        [
            "name": "conduit_list_projects",
            "description": "List MainFrame projects Conduit can start work in. Each entry has slug, title, and lifecycle state (active, paused, planned, suspended, shipped, or empty when the project README declares none). The slug is what conduit_create_task takes as project_slug.",
            "annotations": ConduitSessionAPIServer.localReadOnlyAnnotations,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "conduit_list_sessions",
            "description": "List Conduit tasks, newest activity first, with the durable task UUID used by every other task tool. Paged: the response carries total, returned, has_more, and next_cursor, so a truncated page is always visible as one. Default page is 40 and the hard cap is 200. live and ready describe an observed runtime, not agent progress.",
            "annotations": ConduitSessionAPIServer.localReadOnlyAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "cursor": [
                        "type": "string",
                        "description": "Monotonic cursor from a previous next_cursor. Omit or pass empty to start at the newest task. Format v1:<index>.",
                    ],
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 200,
                        "description": "Maximum tasks to return. Default 40, hard cap 200.",
                    ],
                ],
            ],
        ],
        [
            "name": "conduit_list_adapters",
            "description": "List the agent profiles this operator has enabled and the session backend each one prefers (app-server, ACP, OpenCode HTTP, stream-json, or PTY). Use name as the agent argument to conduit_create_task. This is the declared launch surface, not a live health check: a profile listed here can still fail to start.",
            "annotations": ConduitSessionAPIServer.localReadOnlyAnnotations,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "conduit_session_status",
            "description": "Observed status for one existing Conduit task, plus a short redacted tail of its conversation, read from the durable log when no runtime is live. taskSessionID comes from conduit_list_sessions or from a conduit_create_task result. For a full cursor-paged timeline use conduit_session_events. Status is observation, never verification of what an agent did.",
            "annotations": ConduitSessionAPIServer.localReadOnlyAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": [
                        "type": "string",
                        "description": "Task id from conduit_create_task, or the taskSessionID field of any conduit_list_sessions row. Poll this after creating a task: ready turns true when the runtime will accept a prompt.",
                    ]
                ],
                "required": ["taskSessionID"],
            ],
        ],
        [
            "name": "conduit_session_events",
            "description": "Read incremental, bounded Conversation events plus an additive supervisory observation snapshot for one existing Conduit task. Returns cursor state, authority/source labels, provider thread continuity source, runtime-attempt identity when available, bounded output/checkpoint freshness, and structured-approval versus PTY-unknown input state. Codex app-server turns can report structured completion; PTY checkpoints describe rendered output only and never claim turn completion. This is not verification, not a raw transcript dump, and not MindGraph evidence.",
            "annotations": ConduitSessionAPIServer.localReadOnlyAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": [
                        "type": "string",
                        "description": "Durable Conduit task UUID.",
                    ],
                    "cursor": [
                        "type": "string",
                        "description": "Monotonic cursor from a previous next_cursor. Omit or pass empty to start at the beginning. Format v1:<index>.",
                    ],
                    "limit": [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": 50,
                        "description": "Maximum events to return. Default 20, hard cap 50.",
                    ],
                ],
                "required": ["taskSessionID"],
            ],
            "outputSchema": ConduitSessionAPIServer.sessionEventsOutputSchema,
        ],
        [
            "name": "conduit_query_mindgraph",
            "description": "Semantic search over the operator's local MindGraph index. scope selects which index: knowledge searches the 10_knowledge notes, projects searches 30_projects working files. Returns ranked passage nominations, each with the repo-relative path, title, matched text, an rrf_score, and a citation_class. Documents that must not be cited — quarantined, retracted, superseded, or flagged as a fabricated citation — are returned separately under not_citable and never mixed into results, because ranking is trust-blind and such a document can outscore a real one. citation_counts reports the split. These are retrieval candidates for orienting yourself, not evidence that a claim is true, and never a substitute for reading the file.",
            "annotations": ConduitSessionAPIServer.localReadOnlyAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "question": [
                        "type": "string",
                        "description": "Free-text search phrase. Matched both semantically and lexically, so a topic or a whole sentence works better than bare keywords. An empty question is refused.",
                    ],
                    "scope": [
                        "type": "string",
                        "enum": ["knowledge", "projects"],
                        "description": "Which index to search: knowledge for the operator's 10_knowledge notes, projects for 30_projects working files. Required — there is no default, and the two indexes hold different material.",
                    ],
                ],
                "required": ["question", "scope"],
            ],
        ],
    ]

    private static let writeTools: [[String: Any]] = [
        [
            "name": "conduit_create_task",
            "description": "Start a Conduit agent session and return its taskSessionID. Delivery of objective is attempted once, immediately; a runtime that is still starting returns objective_delivered false, and you then send it yourself with conduit_send_prompt once conduit_session_status reports ready. Nothing is delivered later on your behalf. Approvals stay on the Mac.",
            "annotations": ConduitSessionAPIServer.stateChangingAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent": [
                        "type": "string",
                        "description": "Agent profile name, matched case-insensitively against the name or command field of conduit_list_adapters — for example OpenCode, Codex, Claude, Grok, Gemini CLI, Shell. Call conduit_list_adapters first; an unlisted or disabled profile is refused.",
                    ],
                    "project_slug": [
                        "type": "string",
                        "description": "Folder name of a project as returned in the slug field of conduit_list_projects. This is the session working directory, so it must be an existing project, not a new name.",
                    ],
                    "objective": [
                        "type": "string",
                        "description": "Optional first prompt. Delivered only if the runtime is ready the moment the task is created; otherwise the response reports objective_delivered false and it is yours to send. Omit it and send the first prompt explicitly if you want one clear delivery point.",
                    ],
                    "idempotency_key": [
                        "type": "string",
                        "description": "Optional. Pass a stable key to make a retried create safe: an identical repeat returns the original task instead of starting a second one. Use a fresh key when you genuinely want another task.",
                    ],
                ],
                "required": ["agent", "project_slug"],
            ],
        ],
        [
            "name": "conduit_send_prompt",
            "description": "Add and deliver one message to an existing Conduit task. Origin is recorded as ChatGPT. This does not approve agent tools or permissions. The reply is not in this response — read it with conduit_session_events once the agent has produced output.",
            "annotations": ConduitSessionAPIServer.nonDestructiveStateChangingAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": [
                        "type": "string",
                        "description": "Task id from conduit_create_task, or the taskSessionID field of any conduit_list_sessions row.",
                    ],
                    "text": [
                        "type": "string",
                        "description": "Message text delivered to the agent verbatim, as one prompt. Sending a second prompt before the first turn finishes queues it behind that turn rather than interrupting it.",
                    ],
                ],
                "required": ["taskSessionID", "text"],
            ],
        ],
        [
            "name": "conduit_reconcile_task",
            "description": "Reconnect an existing task to its identity-compatible runtime, or retry its recorded provisioning target. Preserves the task ID and never kills, replaces, or deletes a runtime or task history.",
            "annotations": ConduitSessionAPIServer.nonDestructiveStateChangingAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": [
                        "type": "string",
                        "description": "Task id from conduit_create_task, or the taskSessionID field of any conduit_list_sessions row. Use it after a task reports a runtime that is detached, failed to provision, or otherwise not live.",
                    ],
                ],
                "required": ["taskSessionID"],
            ],
        ],
        [
            "name": "conduit_interrupt",
            "description": "Interrupt the live runtime (SIGINT, app-server turn/interrupt, ACP session/cancel, OpenCode abort, or stream-json terminate).",
            "annotations": ConduitSessionAPIServer.stateChangingAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": [
                        "type": "string",
                        "description": "Task id from conduit_create_task, or the taskSessionID field of any conduit_list_sessions row. Interrupting a task with no turn in flight is accepted and does nothing.",
                    ],
                ],
                "required": ["taskSessionID"],
            ],
        ],
        [
            "name": "conduit_close_session",
            "description": "Leave the live runtime (detach durable tmux / stop structured adapter). Does not delete task history.",
            "annotations": ConduitSessionAPIServer.stateChangingAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": [
                        "type": "string",
                        "description": "Task id from conduit_create_task, or the taskSessionID field of any conduit_list_sessions row. Closing frees one slot against the concurrent-task limit; a runtime that dies on its own does not.",
                    ],
                ],
                "required": ["taskSessionID"],
            ],
        ],
    ]

    private func http(_ status: Int, body: String, contentType: String = "application/json") -> Data {
        let phrase = status == 200 ? "OK" : "Error"
        let header =
            "HTTP/1.1 \(status) \(phrase)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(header.utf8) + Data(body.utf8)
    }
}
#endif
