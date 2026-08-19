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
    private let handle: (ConduitSessionCommand) -> [String: Any]

    init(
        token: String,
        allowWrites: Bool = false,
        handle: @escaping (ConduitSessionCommand) -> [String: Any]
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
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "conduit-session", "version": "1.1"],
                ],
            ]
        case "ping":
            return ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
        case "tools/list":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["tools": allowWrites ? Self.readTools + Self.writeTools : Self.readTools],
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

    private func callTool(name: String, arguments: CodexJSON) -> [String: Any] {
        let command: ConduitSessionCommand?
        switch name {
        case "conduit_list_projects":
            command = .listProjects
        case "conduit_list_sessions":
            command = .listSessions
        case "conduit_session_status":
            if let id = arguments["taskSessionID"]?.stringValue {
                command = .sessionStatus(taskSessionID: id)
            } else {
                command = nil
            }
        case "conduit_session_events":
            if let id = arguments["taskSessionID"]?.stringValue {
                let cursor = arguments["cursor"]?.stringValue
                let limit = arguments["limit"].flatMap { value -> Int? in
                    if case .number(let number) = value { return Int(number) }
                    if let raw = value.stringValue { return Int(raw) }
                    return nil
                }
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
            if agent.isEmpty || projectSlug.isEmpty {
                command = nil
            } else {
                command = .createTask(
                    agent: agent,
                    projectSlug: projectSlug,
                    objective: objective
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
        let payload = handle(command)
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
                    "pending_approval": ["type": "boolean"],
                ],
            ],
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
            "description": "List scanned MainFrame projects from README frontmatter.",
            "annotations": ConduitSessionAPIServer.localReadOnlyAnnotations,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "conduit_list_sessions",
            "description": "List Conduit tasks and live runtimes.",
            "annotations": ConduitSessionAPIServer.localReadOnlyAnnotations,
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "conduit_session_status",
            "description": "Observed status plus last redacted conversation events.",
            "annotations": ConduitSessionAPIServer.localReadOnlyAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": ["type": "string"]
                ],
                "required": ["taskSessionID"],
            ],
        ],
        [
            "name": "conduit_session_events",
            "description": "Read incremental, bounded Conversation events and observed turn state for one existing Conduit task. Returns a cursor page, authority/source labels, truncation/redaction flags, artifact path refs without file contents, and enough state to distinguish session lifecycle from turn active/completed/awaiting-input. Codex app-server turns can report structured completion and complete bounded assistant messages. PTY output is observation only and stays explicitly ambiguous. This is not verification, not a raw transcript dump, and not MindGraph evidence.",
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
            "description": "Query MindGraph. scope must be knowledge or projects.",
            "annotations": ConduitSessionAPIServer.localReadOnlyAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "question": ["type": "string"],
                    "scope": ["type": "string", "enum": ["knowledge", "projects"]],
                ],
                "required": ["question", "scope"],
            ],
        ],
    ]

    private static let writeTools: [[String: Any]] = [
        [
            "name": "conduit_create_task",
            "description": "Start a Conduit agent session. agent is a profile name (Codex, Claude, Grok, …). project_slug is a 30_projects folder name. objective is sent as the first prompt when the runtime is ready. Approvals stay on the Mac.",
            "annotations": ConduitSessionAPIServer.stateChangingAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "agent": ["type": "string"],
                    "project_slug": ["type": "string"],
                    "objective": ["type": "string"],
                ],
                "required": ["agent", "project_slug"],
            ],
        ],
        [
            "name": "conduit_send_prompt",
            "description": "Add and deliver one message to an existing Conduit task. Origin is recorded as ChatGPT. This does not approve agent tools or permissions.",
            "annotations": ConduitSessionAPIServer.nonDestructiveStateChangingAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": ["type": "string"],
                    "text": ["type": "string"],
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
                    "taskSessionID": ["type": "string"],
                ],
                "required": ["taskSessionID"],
            ],
        ],
        [
            "name": "conduit_interrupt",
            "description": "Interrupt the live runtime (SIGINT or app-server turn/interrupt).",
            "annotations": ConduitSessionAPIServer.stateChangingAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": ["type": "string"],
                ],
                "required": ["taskSessionID"],
            ],
        ],
        [
            "name": "conduit_close_session",
            "description": "Leave the live runtime (detach durable tmux / stop app-server). Does not delete task history.",
            "annotations": ConduitSessionAPIServer.stateChangingAnnotations,
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": ["type": "string"],
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
