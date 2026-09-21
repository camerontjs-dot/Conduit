#if os(macOS)
import ConduitCore
import Darwin
import Foundation

/// Holds only the listener file descriptor and lifecycle flag shared with the
/// blocking accept loop. The owner remains `ConduitSessionAPIServer` on the
/// main actor; this box avoids reading its actor-isolated state from a socket
/// worker.
private final class SessionAPIListenerState: @unchecked Sendable {
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false

    func start(listeningOn fd: Int32) {
        lock.lock()
        listenFD = fd
        running = true
        lock.unlock()
    }

    func stop() -> Int32 {
        lock.lock()
        let fd = listenFD
        listenFD = -1
        running = false
        lock.unlock()
        return fd
    }

    func activeFileDescriptor() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return running && listenFD >= 0 ? listenFD : nil
    }

    func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }
}

/// Loopback HTTP/MCP listener for D-039 session tools. Off unless enabled.
///
/// Uses a POSIX IPv4 `127.0.0.1` socket so the full HTTP body is written
/// before close. Network.framework's listener was observed dropping bodies.
@MainActor
final class ConduitSessionAPIServer {
    private let acceptQueue = DispatchQueue(label: "dev.camerontjs.conduit.session-api")
    private nonisolated let listenerState = SessionAPIListenerState()
    private nonisolated let connectionQueue = DispatchQueue(
        label: "dev.camerontjs.conduit.session-api.connections",
        attributes: .concurrent
    )
    private nonisolated let connectionSlots = DispatchSemaphore(value: 8)
    private let token: String
    private let allowWrites: Bool
    private let handle: (ConduitSessionCommand, ConduitSessionCaller) -> [String: Any]
    private nonisolated static let maximumHeaderBytes = 16_384
    private nonisolated static let maximumBodyBytes = 1_048_576
    private nonisolated static let readTimeoutSeconds: Int = 2
    private nonisolated static let busyResponseDrainMicroseconds: Int32 = 50_000

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
        listenerState.start(listeningOn: fd)
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        let fd = listenerState.stop()
        if fd >= 0 {
            close(fd)
        }
    }

    private enum RequestReadResult {
        case request(Data)
        case rejected(status: Int, body: String)
    }

    private nonisolated func acceptLoop() {
        while let listenFD = listenerState.activeFileDescriptor() {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else {
                if listenerState.isRunning() { Thread.sleep(forTimeInterval: 0.02) }
                continue
            }

            guard connectionSlots.wait(timeout: .now()) == .success else {
                Self.rejectBusyConnection(client)
                continue
            }

            let slots = connectionSlots
            connectionQueue.async { [weak self] in
                guard let self else {
                    close(client)
                    slots.signal()
                    return
                }
                self.serve(client) {
                    slots.signal()
                }
            }
        }
    }

    private nonisolated func serve(
        _ client: Int32,
        finished: @escaping () -> Void
    ) {
        switch Self.readRequest(from: client) {
        case .request(let request):
            DispatchQueue.main.async { [weak self] in
                defer {
                    close(client)
                    finished()
                }
                guard let self else {
                    Self.send(
                        Self.http(503, body: "{\"error\":\"server stopped\"}\n"),
                        to: client
                    )
                    return
                }
                Self.send(self.response(for: request), to: client)
            }
        case .rejected(let status, let body):
            Self.send(Self.http(status, body: body), to: client)
            close(client)
            finished()
        }
    }

    private nonisolated static func readRequest(from client: Int32) -> RequestReadResult {
        var timeout = timeval(
            tv_sec: readTimeoutSeconds,
            tv_usec: 0
        )
        guard setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else {
            return .rejected(
                status: 500,
                body: "{\"error\":\"read timeout unavailable\"}\n"
            )
        }

        let delimiter = Data("\r\n\r\n".utf8)
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while request.range(of: delimiter) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else {
                return .rejected(
                    status: count == 0 ? 400 : 408,
                    body: "{\"error\":\"incomplete request\"}\n"
                )
            }
            request.append(buffer, count: count)
            if request.count > maximumHeaderBytes {
                return .rejected(
                    status: 413,
                    body: "{\"error\":\"request headers too large\"}\n"
                )
            }
        }

        guard let headerRange = request.range(of: delimiter) else {
            return .rejected(
                status: 400,
                body: "{\"error\":\"invalid request\"}\n"
            )
        }
        guard let headerText = String(
            data: request[..<headerRange.lowerBound],
            encoding: .utf8
        ) else {
            return .rejected(
                status: 400,
                body: "{\"error\":\"invalid request headers\"}\n"
            )
        }
        let headerLines = headerText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard !SessionAPITransportSecurity.hasTransferEncoding(
            headerLines: headerLines
        ) else {
            return .rejected(
                status: 400,
                body: "{\"error\":\"transfer encoding unsupported\"}\n"
            )
        }
        let contentLength: Int
        switch SessionAPITransportSecurity.contentLength(
            headerLines: headerLines,
            maximum: maximumBodyBytes
        ) {
        case .absent:
            contentLength = 0
        case .valid(let length):
            contentLength = length
        case .invalid:
            return .rejected(
                status: 400,
                body: "{\"error\":\"invalid content length\"}\n"
            )
        }
        let bodyStart = headerRange.upperBound
        let targetSize = bodyStart + contentLength
        guard request.count <= targetSize else {
            return .rejected(
                status: 400,
                body: "{\"error\":\"invalid request framing\"}\n"
            )
        }

        while request.count < targetSize {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else {
                return .rejected(
                    status: count == 0 ? 400 : 408,
                    body: "{\"error\":\"incomplete request body\"}\n"
                )
            }
            request.append(buffer, count: count)
            guard request.count <= targetSize else {
                return .rejected(
                    status: 400,
                    body: "{\"error\":\"invalid request framing\"}\n"
                )
            }
        }
        return .request(request)
    }

    static func loadOrCreateToken() -> String {
        let url = AdapterThreadStore.defaultDirectory()
            .appendingPathComponent("session-api-token")
        return (try? SessionAPITransportSecurity.loadOrCreateToken(at: url))
            ?? UUID().uuidString.lowercased()
    }

    private func response(for request: Data) -> Data {
        let text = String(decoding: request, as: UTF8.self)
        let headerEnd = text.range(of: "\r\n\r\n")?.upperBound
            ?? text.range(of: "\n\n")?.upperBound
        let headers = headerEnd.map { String(text[..<$0]) } ?? text
        let body = headerEnd.map { String(text[$0...]) } ?? ""
        let headerLines = headers
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let firstLine = headerLines.first ?? ""
        let isHealth = firstLine.contains("GET /healthz") || firstLine.contains("GET /readyz")
        if isHealth {
            return Self.http(200, body: "ok\n", contentType: "text/plain")
        }
        // This endpoint uses a local bearer token supplied by tunnel-client,
        // not OAuth. A 404 tells no-auth MCP clients that protected-resource
        // metadata is intentionally absent; 405 is treated as malformed
        // metadata and leaves their readiness checks degraded.
        let isProtectedResourceMetadataRequest =
            firstLine.hasPrefix("GET /.well-known/oauth-protected-resource")
        if isProtectedResourceMetadataRequest {
            return Self.http(404, body: "{\"error\":\"not found\"}\n")
        }
        let authorized = SessionAPITransportSecurity.exactBearerAuthorization(
            headerLines: headerLines,
            token: token
        )
        guard authorized else {
            return Self.http(401, body: "{\"error\":\"unauthorized\"}\n")
        }
        guard firstLine.contains("POST ") else {
            return Self.http(405, body: "{\"error\":\"POST /mcp only\"}\n")
        }
        guard let payload = CodexJSON.parseLine(body) else {
            return Self.http(400, body: "{\"error\":\"invalid json\"}\n")
        }
        let reply = mcpReply(payload)
        guard let data = try? JSONSerialization.data(withJSONObject: reply),
              let json = String(data: data, encoding: .utf8)
        else {
            return Self.http(500, body: "{\"error\":\"encode failed\"}\n")
        }
        return Self.http(200, body: json + "\n")
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
        case "conduit_list_provider_sessions":
            let provider = arguments["provider"]?.stringValue ?? ""
            command = provider.isEmpty
                ? nil
                : .listProviderSessions(provider: provider)
        case "conduit_observe_worker":
            let provider = arguments["provider"]?.stringValue ?? ""
            let providerSessionID = arguments["provider_session_id"]?.stringValue
                ?? arguments["providerSessionID"]?.stringValue
                ?? ""
            command = provider.isEmpty || providerSessionID.isEmpty
                ? nil
                : .observeWorker(
                    provider: provider,
                    providerSessionID: providerSessionID
                )
        case "conduit_adopt_provider_session":
            let provider = arguments["provider"]?.stringValue ?? ""
            let providerSessionID = arguments["provider_session_id"]?.stringValue
                ?? arguments["providerSessionID"]?.stringValue
                ?? ""
            let controllerID = arguments["controller_id"]?.stringValue
                ?? arguments["controllerID"]?.stringValue
                ?? ""
            command = provider.isEmpty
                    || providerSessionID.isEmpty
                    || controllerID.isEmpty
                ? nil
                : .adoptProviderSession(
                    provider: provider,
                    providerSessionID: providerSessionID,
                    controllerID: controllerID
                )
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
        if [
            "conduit_session_events",
            "conduit_list_provider_sessions",
            "conduit_observe_worker",
            "conduit_adopt_provider_session",
        ].contains(name), payload["error"] == nil {
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
            "description": "Start a Conduit agent session and return its taskSessionID. Delivery of objective is attempted once, immediately, and the response reports objective_delivery_state: delivered (it reached the runtime), queued (Conduit accepted it and will finish delivering it without another call - do not resend, or the objective runs twice), or failed (the runtime refused it; objective_resend_required is true, so wait for conduit_session_status to report ready and send it with conduit_send_prompt). Approvals stay on the Mac.",
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
                        "description": "Optional first prompt. A structured runtime that is still starting refuses it and hands the retry back to you; a PTY runtime accepts it and writes asynchronously. Check objective_delivery_state to tell those apart. Omit it and send the first prompt explicitly if you want one clear delivery point.",
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

    private nonisolated static func send(_ response: Data, to client: Int32) {
        response.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < response.count {
                let count = Darwin.send(
                    client,
                    base.advanced(by: sent),
                    response.count - sent,
                    0
                )
                guard count > 0 else { return }
                sent += count
            }
        }
    }

    private nonisolated static func rejectBusyConnection(_ client: Int32) {
        // The listener has not read this connection. Discard its inbound bytes
        // before closing so the kernel can deliver the small 503 response
        // rather than resetting the peer because unread data remains.
        drainAvailableInput(from: client)
        Self.send(Self.http(503, body: "{\"error\":\"server busy\"}\n"), to: client)
        _ = Darwin.shutdown(client, SHUT_WR)
        close(client)
    }

    private nonisolated static func drainAvailableInput(from client: Int32) {
        var timeout = timeval(
            tv_sec: 0,
            tv_usec: busyResponseDrainMicroseconds
        )
        guard setsockopt(
            client,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        ) == 0
        else {
            return
        }

        var remaining = maximumHeaderBytes
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let initialCount = Darwin.recv(
            client,
            &buffer,
            min(buffer.count, remaining),
            0
        )
        guard initialCount > 0 else { return }
        remaining -= initialCount

        let originalFlags = Darwin.fcntl(client, F_GETFL)
        guard originalFlags >= 0,
              Darwin.fcntl(client, F_SETFL, originalFlags | O_NONBLOCK) == 0
        else {
            return
        }
        defer { _ = Darwin.fcntl(client, F_SETFL, originalFlags) }

        while remaining > 0 {
            let count = Darwin.recv(
                client,
                &buffer,
                min(buffer.count, remaining),
                0
            )
            guard count > 0 else { return }
            remaining -= count
        }
    }

    private nonisolated static func http(
        _ status: Int,
        body: String,
        contentType: String = "application/json"
    ) -> Data {
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
