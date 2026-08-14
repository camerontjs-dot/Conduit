#if os(macOS)
import ConduitCore
import Foundation

/// Long-lived `codex app-server` JSON-RPC client (D-038).
///
/// Not the account-usage probe: this process stays up for the task and feeds
/// Conversation through `CodexAppServerMapper`.
@MainActor
final class CodexAppServerClient: ObservableObject {
    enum ClientError: Error, LocalizedError {
        case executableMissing
        case notRunning
        case notReady
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .executableMissing:
                return "codex is not on PATH."
            case .notRunning:
                return "Codex app-server is not running."
            case .notReady:
                return "Codex app-server has not finished initialize/thread start."
            case .protocolError(let message):
                return message
            }
        }
    }

    @Published private(set) var threadID: String?
    @Published private(set) var isReady = false
    @Published private(set) var isTurnActive = false
    @Published var pendingApproval: CodexAppServerApproval?
    @Published private(set) var lastError: String?

    var onEffect: ((CodexAppServerEffect) -> Void)?
    var onReady: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onExited: (() -> Void)?

    private var process: Process?
    private var serverProcess: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var mapper = CodexAppServerMapper()
    private var pendingResponses: [Int: CheckedContinuation<CodexJSON, Error>] = [:]
    private let cwd: URL
    private let model: String?
    private let resumeThreadID: String?
    private(set) var socketPath: String?

    init(cwd: URL, model: String?, resumeThreadID: String? = nil) {
        self.cwd = cwd
        self.model = model
        self.resumeThreadID = resumeThreadID
    }

    func start(executable: String) async throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ClientError.executableMissing
        }

        do {
            try startUnixHost(executable: executable)
        } catch {
            stopProcesses()
            socketPath = nil
            try startStdioHost(executable: executable)
        }

        do {
            try await handshake()
        } catch {
            lastError = error.localizedDescription
            stop()
            throw error
        }
    }

    private func startUnixHost(executable: String) throws {
        let directory = AdapterThreadStore.defaultDirectory()
            .appendingPathComponent("codex-sockets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let socket = directory
            .appendingPathComponent("\(UUID().uuidString).sock")
            .path
        let server = Process()
        server.executableURL = URL(fileURLWithPath: executable)
        server.arguments = ["app-server", "--listen", "unix://\(socket)"]
        server.currentDirectoryURL = cwd
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = Pipe()
        server.standardError = Pipe()
        try server.run()
        serverProcess = server

        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socket) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard FileManager.default.fileExists(atPath: socket) else {
            throw ClientError.protocolError("app-server unix socket did not appear.")
        }
        socketPath = socket
        try spawnRPCProcess(
            executable: executable,
            arguments: ["app-server", "proxy", "--sock", socket]
        )
    }

    private func startStdioHost(executable: String) throws {
        try spawnRPCProcess(executable: executable, arguments: ["app-server"])
    }

    private func spawnRPCProcess(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleExit()
            }
        }
        try process.run()
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            Task { @MainActor in
                self?.ingest(chunk)
            }
        }
    }

    private func handshake() async throws {
        _ = try await request(CodexAppServerRequests.initialize(id: 0))
        send(CodexAppServerRequests.initialized())
        var started: CodexJSON
        if let resumeThreadID, !resumeThreadID.isEmpty {
            do {
                started = try await request(
                    CodexAppServerRequests.threadResume(id: 0, threadID: resumeThreadID)
                )
            } catch {
                started = try await request(
                    CodexAppServerRequests.threadStart(
                        id: 0,
                        cwd: cwd.path,
                        model: model
                    )
                )
            }
        } else {
            started = try await request(
                CodexAppServerRequests.threadStart(
                    id: 0,
                    cwd: cwd.path,
                    model: model
                )
            )
        }
        if let threadID = started["thread"]?["id"]?.stringValue
            ?? started["threadId"]?.stringValue
            ?? resumeThreadID {
            self.threadID = threadID
            mapper.threadID = threadID
        }
        guard self.threadID != nil else {
            throw ClientError.protocolError("thread start/resume did not return a thread id.")
        }
        isReady = true
        onReady?()
    }

    func sendTurn(text: String) throws {
        guard isReady, let threadID else { throw ClientError.notReady }
        if mapper.turnActive {
            send(
                CodexAppServerRequests.turnSteer(
                    id: 0,
                    threadID: threadID,
                    text: text
                )
            )
        } else {
            mapper.resetTurn()
            send(
                CodexAppServerRequests.turnStart(
                    id: 0,
                    threadID: threadID,
                    text: text
                )
            )
        }
        isTurnActive = true
    }

    func interrupt() {
        guard let threadID else { return }
        send(CodexAppServerRequests.turnInterrupt(id: 0, threadID: threadID))
    }

    func respondToApproval(accept: Bool) {
        guard let approval = pendingApproval else { return }
        pendingApproval = nil
        if !accept && approval.declineUsesRPCError {
            send([
                "id": approval.rpcID.jsonObject,
                "error": [
                    "code": -32003,
                    "message": "operator declined",
                ] as [String: Any],
            ])
            return
        }
        send([
            "id": approval.rpcID.jsonObject,
            "result": accept ? approval.acceptResult : approval.declineResult
        ])
    }

    func readRateLimits() async throws -> Data {
        let result = try await request(CodexAppServerRequests.rateLimitsRead(id: 0))
        let payload: [String: Any] = ["result": result.jsonObject()]
        return try JSONSerialization.data(withJSONObject: payload)
    }

    func stop() {
        stopProcesses()
        failPending("Codex app-server stopped.")
        isReady = false
        isTurnActive = false
        socketPath = nil
    }

    private func stopProcesses() {
        stdinHandle = nil
        process?.terminationHandler = nil
        serverProcess?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        if let serverProcess, serverProcess.isRunning { serverProcess.terminate() }
        process = nil
        serverProcess = nil
        if let socketPath {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
    }

    private func handleExit() {
        process = nil
        stdinHandle = nil
        isReady = false
        isTurnActive = false
        failPending("Codex app-server exited.")
        onExited?()
    }

    private func ingest(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8),
                  let message = CodexJSONRPCMessage.parseLine(line)
            else { continue }
            handle(message)
        }
    }

    private func handle(_ message: CodexJSONRPCMessage) {
        if case .response(let id, let result) = message,
           case .number(let number) = id,
           let continuation = pendingResponses.removeValue(forKey: number) {
            continuation.resume(returning: result)
        } else if case .error(let id, let message) = message,
                  case .number(let number)? = id,
                  let continuation = pendingResponses.removeValue(forKey: number) {
            continuation.resume(throwing: ClientError.protocolError(message))
        }

        let effects = mapper.apply(message)
        for effect in effects {
            apply(effect)
        }
    }

    private func apply(_ effect: CodexAppServerEffect) {
        switch effect {
        case .threadStarted(let id):
            threadID = id
        case .upsertOutput:
            isTurnActive = true
        case .requestApproval(let approval):
            pendingApproval = approval
        case .turnCompleted:
            isTurnActive = false
        case .failed(let message):
            lastError = message
        }
        onEffect?(effect)
    }

    private func request(_ payload: [String: Any]) async throws -> CodexJSON {
        let id = nextID
        nextID += 1
        var payload = payload
        payload["id"] = id
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            send(payload)
        }
    }

    private func send(_ payload: [String: Any]) {
        var payload = payload
        if payload["id"] as? Int == 0 {
            payload["id"] = nextID
            nextID += 1
        }
        guard let stdinHandle,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)
        else { return }
        line += "\n"
        stdinHandle.write(Data(line.utf8))
    }

    private func failPending(_ message: String) {
        let pending = pendingResponses
        pendingResponses.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: ClientError.protocolError(message))
        }
    }
}
#endif
