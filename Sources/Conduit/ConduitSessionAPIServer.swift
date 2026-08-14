#if os(macOS)
import ConduitCore
import Foundation
import Network

/// Loopback HTTP/MCP listener for D-039 read tools. Off unless enabled.
@MainActor
final class ConduitSessionAPIServer {
    private var listener: NWListener?
    private let token: String
    private let handle: (ConduitSessionCommand) -> [String: Any]

    init(token: String, handle: @escaping (ConduitSessionCommand) -> [String: Any]) {
        self.token = token
        self.handle = handle
    }

    func start() throws {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = true
        let port = NWEndpoint.Port(rawValue: UInt16(ConduitSessionAPI.loopbackPort))!
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            Task { @MainActor in
                self?.serve(connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
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

    private func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64_000) { [weak self] data, _, _, error in
            guard let data, error == nil else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                let response = self.response(for: data)
                connection.send(
                    content: response,
                    completion: .contentProcessed { _ in
                        connection.cancel()
                    }
                )
            }
        }
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
        let id: Any = payload["id"]?.stringValue
            ?? (payload["id"] != nil ? payload["id"]!.jsonObject() : NSNull())
        let method = payload["method"]?.stringValue ?? ""
        switch method {
        case "initialize":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "conduit-session", "version": "1.0"],
                ],
            ]
        case "ping":
            return ["jsonrpc": "2.0", "id": id, "result": [String: Any]()]
        case "tools/list":
            return [
                "jsonrpc": "2.0",
                "id": id,
                "result": ["tools": Self.readTools],
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
        case "conduit_query_mindgraph":
            let question = arguments["question"]?.stringValue ?? ""
            let scope = arguments["scope"]?.stringValue ?? ""
            command = .queryMindGraph(question: question, scope: scope)
        default:
            command = nil
        }
        guard let command, !ConduitSessionAPI.isWrite(command) else {
            return [
                "isError": true,
                "content": [["type": "text", "text": "Unknown or write tool: \(name)"]],
            ]
        }
        let payload = handle(command)
        let text = (try? String(
            data: JSONSerialization.data(withJSONObject: payload),
            encoding: .utf8
        )) ?? "{}"
        return [
            "isError": payload["error"] != nil,
            "content": [["type": "text", "text": text]],
        ]
    }

    private static let readTools: [[String: Any]] = [
        [
            "name": "conduit_list_projects",
            "description": "List scanned MainFrame projects from README frontmatter.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "conduit_list_sessions",
            "description": "List Conduit tasks and live runtimes.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "conduit_session_status",
            "description": "Observed status plus last redacted conversation events.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "taskSessionID": ["type": "string"]
                ],
                "required": ["taskSessionID"],
            ],
        ],
        [
            "name": "conduit_query_mindgraph",
            "description": "Query MindGraph. scope must be knowledge or projects.",
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

    private func http(_ status: Int, body: String, contentType: String = "application/json") -> Data {
        let phrase = status == 200 ? "OK" : "Error"
        let header = """
        HTTP/1.1 \(status) \(phrase)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        """
        return Data(header.utf8) + Data(body.utf8)
    }
}
#endif
