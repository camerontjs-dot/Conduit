#if os(macOS)
import ConduitCore
import Foundation

/// Long-lived `grok agent --no-leader stdio` ACP client (D-040).
@MainActor
final class GrokACPClient: ObservableObject {
    enum ClientError: Error, LocalizedError {
        case executableMissing
        case notReady
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .executableMissing:
                return "ACP executable is not on PATH."
            case .notReady:
                return "ACP has not finished initialize/session start."
            case .protocolError(let message):
                return message
            }
        }
    }

    @Published private(set) var sessionID: String?
    @Published private(set) var isReady = false
    @Published private(set) var isTurnActive = false
    @Published private(set) var lastTurnStatus: String?
    @Published private(set) var lastError: String?
    /// Set only when a failure ends a turn that was still running.
    ///
    /// A `.failed` effect that arrives after the turn already completed does
    /// not un-complete it: interrupting a finished turn makes the provider
    /// report an error, and treating that as a turn failure erases a real
    /// observed completion. `lastError` keeps every error for display; this
    /// field carries only the ones that are the turn's outcome.
    @Published private(set) var turnFailure: String?
    @Published var pendingPermission: ACPPendingPermission?

    /// Where the session this client is driving came from.
    ///
    /// Set once the handshake settles. A refused resume is silently replaced
    /// with a fresh session below, so without this the caller cannot tell a
    /// recovered task from an empty one wearing its name.
    private(set) var resumeProvenance: SessionResumeSemantics.Provenance?

    var onEffect: ((StructuredAdapterEffect) -> Void)?
    /// Fired once the host can accept a turn.
    ///
    /// Conduit holds a prompt that arrives before this point rather than
    /// refusing it, so something has to say when the wait is over.
    var onReady: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onExited: (() -> Void)?

    var pendingApprovalSummary: String? { pendingPermission?.summary }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var streamGeneration: UUID?
    private var stdoutBuffer = Data()
    private var nextID = 1
    private var pendingResponses: [Int: CheckedContinuation<CodexJSON, Error>] = [:]
    private var mapper = ACPSessionMapper()
    private let cwd: URL
    private let resumeSessionID: String?
    private let launchArguments: [String]
    private let authenticateMethodID: String?
    private let extraEnvironment: [String: String]

    init(
        cwd: URL,
        resumeSessionID: String? = nil,
        launchArguments: [String] = ["agent", "--no-leader", "stdio"],
        authenticateMethodID: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) {
        self.cwd = cwd
        self.resumeSessionID = resumeSessionID
        self.launchArguments = launchArguments
        self.authenticateMethodID = authenticateMethodID
        self.extraEnvironment = extraEnvironment
    }

    static func environmentFromDotEnv(relativePath: String) -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        var env: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq])
            var value = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2 {
                let first = value.first
                let last = value.last
                if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
                    value = String(value.dropFirst().dropLast())
                }
            }
            env[key] = value
        }
        return env
    }

    func start(executable: String) async throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ClientError.executableMissing
        }
        try spawn(executable: executable)
        do {
            try await handshake()
        } catch {
            lastError = error.localizedDescription
            stop()
            throw error
        }
    }

    func sendTurn(text: String) throws {
        guard isReady, let sessionID else { throw ClientError.notReady }
        mapper.resetTurn()
        send(ACPRequests.sessionPrompt(id: 0, sessionID: sessionID, text: text))
        isTurnActive = true
        // A new turn must not inherit the previous turn's failure. lastError
        // is what marks a turn failed rather than completed, so leaving it set
        // would report every later successful turn on this task as failed.
        lastTurnStatus = nil
        lastError = nil
        turnFailure = nil
    }

    func interrupt() {
        guard let sessionID else { return }
        send(ACPRequests.sessionCancel(sessionID: sessionID))
    }

    func respondToApproval(accept: Bool) {
        guard let permission = pendingPermission else { return }
        pendingPermission = nil
        if accept {
            send(ACPRequests.permissionAllow(id: permission.rpcID, optionID: permission.allowOptionID))
        } else {
            send(ACPRequests.permissionDeny(id: permission.rpcID))
        }
    }

    func stop() {
        stopProcess()
        failPending("Grok ACP stopped.")
        isReady = false
        isTurnActive = false
    }

    private func spawn(executable: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = launchArguments
        process.currentDirectoryURL = cwd
        if !extraEnvironment.isEmpty {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in extraEnvironment {
                environment[key] = value
            }
            process.environment = environment
        }
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let generation = UUID()
        streamGeneration = generation
        stdoutHandle = stdout.fileHandleForReading
        stdinHandle = stdin.fileHandleForWriting
        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                self?.ingest(data, generation: generation)
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.handleExit(generation: generation)
            }
        }
        try process.run()
        self.process = process
    }

    private func handshake() async throws {
        _ = try await request(ACPRequests.initialize(id: 0))
        send(ACPRequests.initialized())
        if let authenticateMethodID, !authenticateMethodID.isEmpty {
            _ = try await request(
                ACPRequests.authenticate(id: 0, methodID: authenticateMethodID)
            )
        }
        let started: CodexJSON
        var attempt: SessionResumeSemantics.Attempt = .notRequested
        if let resumeSessionID, !resumeSessionID.isEmpty {
            do {
                started = try await request(
                    ACPRequests.sessionLoad(
                        id: 0,
                        sessionID: resumeSessionID,
                        cwd: cwd.path
                    )
                )
                attempt = .accepted
            } catch {
                // session/new answers with a NEW, EMPTY session. Falling back
                // is right; passing it off as the requested one is not.
                attempt = .refused
                started = try await request(
                    ACPRequests.sessionNew(id: 0, cwd: cwd.path)
                )
            }
        } else {
            started = try await request(
                ACPRequests.sessionNew(id: 0, cwd: cwd.path)
            )
        }
        if let sessionID = ACPSessionMapper.sessionID(in: started) ?? resumeSessionID {
            self.sessionID = sessionID
            mapper.sessionID = sessionID
        }
        guard let liveSessionID = self.sessionID else {
            throw ClientError.protocolError("ACP session/new did not return a session id.")
        }
        resumeProvenance = SessionResumeSemantics.classify(
            requested: resumeSessionID,
            started: liveSessionID,
            attempt: attempt
        )
        isReady = true
        onReady?()
    }

    private func ingest(_ data: Data, generation: UUID) {
        guard streamGeneration == generation else { return }
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let range = stdoutBuffer.range(of: Data([0x0a])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            handleLine(line, generation: generation)
        }
    }

    private func handleLine(_ line: String, generation: UUID) {
        guard streamGeneration == generation else { return }
        guard let message = CodexJSONRPCMessage.parseLine(line) else { return }
        switch message {
        case .response(let id, let result):
            if case .number(let number) = id,
               let continuation = pendingResponses.removeValue(forKey: number) {
                continuation.resume(returning: result)
            }
        case .error(let id, let message):
            if case .number(let number)? = id,
               let continuation = pendingResponses.removeValue(forKey: number) {
                continuation.resume(throwing: ClientError.protocolError(message))
            } else {
                emit(.failed(message))
            }
        case .request(let id, let method, let params):
            if method == "session/request_permission" || method.hasSuffix("/request_permission") {
                let permission = ACPSessionMapper.pendingPermission(rpcID: id, params: params)
                pendingPermission = permission
                emit(.requestApproval(id: permission.id, summary: permission.summary))
                return
            }
        case .notification:
            break
        }
        for effect in mapper.apply(message) {
            emit(effect)
        }
    }

    private func emit(_ effect: StructuredAdapterEffect) {
        switch effect {
        case .sessionStarted(let id):
            sessionID = id
        case .upsertOutput:
            isTurnActive = true
        case .requestApproval:
            break
        case .turnCompleted(let status):
            isTurnActive = false
            lastTurnStatus = status
        case .failed(let message):
            lastError = message
            if isTurnActive {
                isTurnActive = false
                turnFailure = message
            }
        }
        onEffect?(effect)
    }

    private func handleExit(generation: UUID) {
        guard streamGeneration == generation else { return }
        process = nil
        stdinHandle = nil
        isReady = false
        isTurnActive = false
        failPending("Grok ACP exited.")
        onExited?()
    }

    private func stopProcess() {
        streamGeneration = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stdinHandle = nil
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func request(_ payload: [String: Any]) async throws -> CodexJSON {
        try await withThrowingTaskGroup(of: CodexJSON.self) { group in
            group.addTask { @MainActor in
                try await self.requestOnce(payload)
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: 20_000_000_000)
                self.failPending("ACP request timed out")
                throw ClientError.protocolError("ACP request timed out")
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw ClientError.protocolError("ACP request aborted")
            }
            return value
        }
    }

    private func requestOnce(_ payload: [String: Any]) async throws -> CodexJSON {
        try await withCheckedThrowingContinuation { continuation in
            let id = nextID
            nextID += 1
            var payload = payload
            payload["id"] = id
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
