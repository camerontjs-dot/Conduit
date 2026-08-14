#if os(macOS)
import ConduitCore
import Darwin
import Foundation

/// Loopback HTTP/MCP listener for D-039 read tools. Off unless enabled.
///
/// Uses a POSIX IPv4 `127.0.0.1` socket so the full HTTP body is written
/// before close. Network.framework's listener was observed dropping bodies.
@MainActor
final class ConduitSessionAPIServer {
    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "dev.camerontjs.conduit.session-api")
    private let token: String
    private let handle: (ConduitSessionCommand) -> [String: Any]

    init(token: String, handle: @escaping (ConduitSessionCommand) -> [String: Any]) {
        self.token = token
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
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = recv(client, &buffer, buffer.count, 0)
            let request = Data(buffer.prefix(max(0, Int(count))))
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
        let header =
            "HTTP/1.1 \(status) \(phrase)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(header.utf8) + Data(body.utf8)
    }
}
#endif
