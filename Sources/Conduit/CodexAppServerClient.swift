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
    @Published private(set) var activeTurnID: String?
    @Published private(set) var isReady = false
    @Published private(set) var isTurnActive = false
    @Published private(set) var lastTurnStatus: String?
    @Published var pendingApproval: CodexAppServerApproval?
    @Published private(set) var lastError: String?
    /// Set only by a correlated terminal provider result. Diagnostics and
    /// transport loss remain independent of the turn's outcome.
    @Published private(set) var turnFailure: String?
    @Published private(set) var terminalFailureReceipt: ProviderTurnFailureReceipt?
    private var pendingTurnStartID: Int?
    private var effectiveModel: String?

    /// Where the session this client is driving came from.
    ///
    /// Set once the handshake settles. A refused resume is silently replaced
    /// with a fresh session below, so without this the caller cannot tell a
    /// recovered task from an empty one wearing its name.
    private(set) var resumeProvenance: SessionResumeSemantics.Provenance?

    var onEffect: ((CodexAppServerEffect) -> Void)?

    /// Exact in-process host identity available to lifecycle preflight.
    ///
    /// Socket-proxy mode can own two processes, so preserve both PIDs rather
    /// than pretending one is the whole host.
    var lifecycleProviderHostIdentifier: String? {
        var identifiers: [String] = []
        if let process, process.isRunning {
            identifiers.append("pid:\(process.processIdentifier)")
        }
        if let serverProcess, serverProcess.isRunning {
            identifiers.append("pid:\(serverProcess.processIdentifier)")
        }
        return identifiers.isEmpty ? nil : identifiers.joined(separator: ",")
    }

    /// Fired once the host can accept a turn.
    ///
    /// Conduit holds a prompt that arrives before this point rather than
    /// refusing it, so something has to say when the wait is over.
    var onReady: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onExited: (() -> Void)?

    private var process: Process?
    private var serverProcess: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var streamPump: CodexAppServerStreamPump?
    private var stderrTail: CodexAppServerStderrTail?
    private var streamGeneration: UUID?
    private var nextID = 1
    private var pendingResponses: [Int: CheckedContinuation<CodexJSON, Error>] = [:]
    private let cwd: URL
    private let model: String?
    private let resumeThreadID: String?
    private(set) var socketPath: String?
    private var ignoreProcessExit = false

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

        // Unix listen + `app-server proxy` hangs on initialize (2026-08-15
        // smoke). Stdio is the proven host. Opt into the hanging path with
        // CONDUIT_CODEX_UNIX=1 only when debugging Raw --remote.
        let preferUnix = ProcessInfo.processInfo.environment["CONDUIT_CODEX_UNIX"] == "1"
        if preferUnix {
            do {
                try startUnixHost(executable: executable)
                try await handshake()
                return
            } catch {
                ignoreProcessExit = true
                stopProcesses()
                ignoreProcessExit = false
                socketPath = nil
            }
        }
        do {
            try startStdioHost(executable: executable)
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
        // The RPC proxy owns the protocol stream. Discard the unix host's
        // diagnostics so an unread Pipe cannot stall the host process.
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
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
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let generation = UUID()
        let stderrTail = CodexAppServerStderrTail()
        let pump = CodexAppServerStreamPump(
            deliveryQueue: .main,
            onDelivery: { [weak self] deliveries in
                MainActor.assumeIsolated {
                    self?.handle(deliveries, generation: generation)
                }
            },
            onFailure: { [weak self] error in
                MainActor.assumeIsolated {
                    self?.handleStreamFailure(error, generation: generation)
                }
            }
        )
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleExit(generation: generation)
            }
        }
        try process.run()
        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading
        self.streamPump = pump
        self.stderrTail = stderrTail
        self.streamGeneration = generation
        stdout.fileHandleForReading.readabilityHandler = { [weak pump] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                pump?.finish()
            } else {
                pump?.ingest(chunk)
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak stderrTail] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrTail?.append(chunk)
            }
        }
    }

    private func handshake() async throws {
        _ = try await request(CodexAppServerRequests.initialize(id: 0))
        send(CodexAppServerRequests.initialized())
        var started: CodexJSON
        var attempt: SessionResumeSemantics.Attempt = .notRequested
        if let resumeThreadID, !resumeThreadID.isEmpty {
            do {
                started = try await request(
                    CodexAppServerRequests.threadResume(id: 0, threadID: resumeThreadID)
                )
                attempt = .accepted
            } catch {
                let message = error.localizedDescription
                if CodexThreadWriterCollisionMapper.isActiveWriterConflict(
                    message
                ) {
                    // A single-writer collision proves the requested thread
                    // still exists under another writer. Replacing it would
                    // fork history precisely when continuity remains present.
                    throw ClientError.protocolError(
                        ProviderSessionAuthorityFailure.writerCollision(
                            providerID: "codex",
                            providerSessionID: resumeThreadID,
                            detail: message
                        )
                    )
                }

                // Ordinary refused/missing resume remains recoverable with a
                // fresh thread. The replacement is explicitly recorded as
                // restarted so callers do not mistake it for continuity.
                attempt = .refused
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
            streamPump?.setThreadID(threadID)
        }
        guard let liveThreadID = self.threadID else {
            throw ClientError.protocolError("thread start/resume did not return a thread id.")
        }
        effectiveModel = started["model"]?.stringValue ?? model
        resumeProvenance = SessionResumeSemantics.classify(
            requested: resumeThreadID,
            started: liveThreadID,
            attempt: attempt
        )
        isReady = true
        // This receipt belongs to the correlated handshake, before a queued
        // input may arrive. A later malformed stream can discard queued mapper
        // deliveries, so persistence must not depend on that incidental queue.
        onEffect?(.threadStarted(id: liveThreadID))
        onReady?()
    }

    func sendTurn(text: String) throws {
        guard isReady, let threadID else { throw ClientError.notReady }
        if isTurnActive {
            send(
                CodexAppServerRequests.turnSteer(
                    id: 0,
                    threadID: threadID,
                    text: text
                )
            )
        } else {
            streamPump?.resetTurn()
            activeTurnID = nil
            pendingTurnStartID = send(
                CodexAppServerRequests.turnStart(
                    id: 0,
                    threadID: threadID,
                    text: text
                )
            )
        }
        isTurnActive = true
        // A new turn must not inherit the previous turn's failure.
        lastTurnStatus = nil
        lastError = nil
        turnFailure = nil
        terminalFailureReceipt = nil
    }

    func interrupt() {
        guard let threadID, let activeTurnID else { return }
        send(
            CodexAppServerRequests.turnInterrupt(
                id: 0,
                threadID: threadID,
                turnID: activeTurnID
            )
        )
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
        activeTurnID = nil
        lastTurnStatus = nil
        socketPath = nil
    }

    private func stopProcesses() {
        streamGeneration = nil
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        streamPump?.cancel()
        stdoutHandle = nil
        stderrHandle = nil
        streamPump = nil
        stderrTail = nil
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

    private func handleExit(generation: UUID) {
        guard streamGeneration == generation else { return }
        process = nil
        stdinHandle = nil
        if ignoreProcessExit { return }
        isReady = false
        isTurnActive = false
        activeTurnID = nil
        failPending("Codex app-server exited.")
        onExited?()
    }

    private func handle(
        _ deliveries: [CodexAppServerDelivery],
        generation: UUID
    ) {
        guard streamGeneration == generation else { return }
        for delivery in deliveries {
            switch delivery {
            case .response(let id, let result):
                if case .number(let number) = id, number == pendingTurnStartID {
                    pendingTurnStartID = nil
                }
                if case .number(let number) = id,
                   let continuation = pendingResponses.removeValue(forKey: number) {
                    continuation.resume(returning: result)
                }
            case .error(let id, let message, let code):
                if case .number(let number)? = id, number == pendingTurnStartID,
                   let code, let threadID, isTurnActive {
                    // Request correlation is necessary but not sufficient.
                    // Only a parser-validated JSON-RPC Error object carries
                    // rejection authority for terminalizing this provider turn.
                    pendingTurnStartID = nil
                    apply(.turnFailed(.codex(
                        threadID: threadID, turnID: activeTurnID, requestID: number,
                        source: "turn/start.jsonrpc_error",
                        error: .object(["message": .string(message)]), rpcErrorCode: code
                    )))
                }
                if case .number(let number)? = id,
                   let continuation = pendingResponses.removeValue(forKey: number) {
                    continuation.resume(throwing: ClientError.protocolError(message))
                }
            case .effect(let effect):
                apply(effect)
            }
        }
    }

    private func handleStreamFailure(
        _ error: CodexAppServerStreamError,
        generation: UUID
    ) {
        guard streamGeneration == generation else { return }
        let message = error.localizedDescription
        lastError = message
        failPending(message)
        isReady = false
        isTurnActive = false
        activeTurnID = nil
        onFailed?(message)
        stopProcesses()
    }

    private func apply(_ effect: CodexAppServerEffect) {
        // A matching turn/start RPC rejection can arrive without a turn id,
        // outside the notification mapper. Only an explicit new send clears
        // that terminal receipt; late presentation effects cannot reopen it.
        if terminalFailureReceipt != nil {
            switch effect {
            case .turnStarted, .upsertOutput, .requestApproval, .turnCompleted, .turnFailed:
                return
            default:
                break
            }
        }
        switch effect {
        case .threadStarted:
            // Handshake owns this client's thread identity and its one receipt.
            // Mapper notifications/responses cannot publish another identity.
            return
        case .turnStarted(let id):
            activeTurnID = id
            isTurnActive = true
        case .upsertOutput:
            isTurnActive = true
        case .requestApproval(let approval):
            pendingApproval = approval
        case .turnCompleted(let status):
            isTurnActive = false
            activeTurnID = nil
            lastTurnStatus = status
        case .turnFailed(var receipt):
            guard receipt.threadID == threadID,
                  receipt.turnID == nil || activeTurnID == nil || receipt.turnID == activeTurnID
            else { return }
            receipt.modelID = effectiveModel
            isTurnActive = false
            activeTurnID = nil
            pendingTurnStartID = nil
            pendingApproval = nil
            lastTurnStatus = "failed"
            turnFailure = receipt.reason
            terminalFailureReceipt = receipt
            lastError = receipt.reason
            onEffect?(.turnFailed(receipt))
            return
        case .failed(let message):
            lastError = message
            // RPC diagnostics and transport trouble do not establish that a
            // provider turn failed. Only correlated terminal protocol facts do.
        }
        onEffect?(effect)
    }

    private func request(_ payload: [String: Any]) async throws -> CodexJSON {
        try await withThrowingTaskGroup(of: CodexJSON.self) { group in
            group.addTask { @MainActor in
                try await self.requestOnce(payload)
            }
            group.addTask { @MainActor in
                try await Task.sleep(nanoseconds: 6_000_000_000)
                self.failPending("app-server request timed out")
                throw ClientError.protocolError("app-server request timed out")
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else {
                throw ClientError.protocolError("app-server request aborted")
            }
            return value
        }
    }

    private func requestOnce(_ payload: [String: Any]) async throws -> CodexJSON {
        let id = nextID
        nextID += 1
        var payload = payload
        payload["id"] = id
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            if let method = payload["method"] as? String,
               method == "thread/start" || method == "thread/resume" {
                streamPump?.expectThreadResponse(.number(id))
            }
            send(payload)
        }
    }

    @discardableResult
    private func send(_ payload: [String: Any]) -> Int? {
        var payload = payload
        if payload["id"] as? Int == 0 {
            payload["id"] = nextID
            nextID += 1
        }
        guard let stdinHandle,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              var line = String(data: data, encoding: .utf8)
        else { return nil }
        line += "\n"
        stdinHandle.write(Data(line.utf8))
        return payload["id"] as? Int
    }

    private func failPending(_ message: String) {
        streamPump?.cancelThreadResponseExpectation()
        let pending = pendingResponses
        pendingResponses.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: ClientError.protocolError(message))
        }
    }
}
#endif
