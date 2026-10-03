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
    /// Set only when a failure ends a turn that was still running.
    ///
    /// A `.failed` effect that arrives after the turn already completed does
    /// not un-complete it: interrupting a finished turn makes the provider
    /// report an error, and treating that as a turn failure erases a real
    /// observed completion. `lastError` keeps every error for display; this
    /// field carries only the ones that are the turn's outcome.
    @Published private(set) var turnFailure: String?

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
    private struct PendingObservation {
        let continuation: CheckedContinuation<CodexJSON, Error>
        let timeout: Task<Void, Never>
    }
    private var pendingObservations: [String: PendingObservation] = [:]
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
        resumeProvenance = SessionResumeSemantics.classify(
            requested: resumeThreadID,
            started: liveThreadID,
            attempt: attempt
        )
        isReady = true
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
            send(
                CodexAppServerRequests.turnStart(
                    id: 0,
                    threadID: threadID,
                    text: text
                )
            )
        }
        isTurnActive = true
        // A new turn must not inherit the previous turn's failure. lastError
        // is what marks a turn failed rather than completed, so leaving it set
        // would report every later successful turn on this task as failed.
        lastTurnStatus = nil
        lastError = nil
        turnFailure = nil
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

    /// Existing host only. This accessor never starts, resumes or adopts a thread.
    var metadataObservationHostID: String? {
        guard isReady, let generation = streamGeneration,
              let process, process.isRunning, stdinHandle != nil,
              let host = lifecycleProviderHostIdentifier
        else { return nil }
        return "codex.app-server/\(generation.uuidString.lowercased())/\(host)"
    }

    func observeProviderSessions() async throws -> CodexMetadataInventory {
        guard let hostID = metadataObservationHostID else { throw CodexObservationError.notReady }
        return try await metadataInventory(hostID: hostID, deadline: Date().addingTimeInterval(CodexObservationRPC.inventoryTimeout))
    }

    func observeProviderSession(exactID: String) async throws -> CodexMetadataInventory {
        guard CodexThreadMetadata.isExactIdentity(exactID) else { throw CodexObservationError.invalidMetadata }
        guard let hostID = metadataObservationHostID else { throw CodexObservationError.notReady }
        let deadline = Date().addingTimeInterval(CodexObservationRPC.inventoryTimeout)
        let inventory = try await metadataInventory(hostID: hostID, deadline: deadline)
        // Exact inventory membership, never a prefix or a task/runtime UUID alias.
        guard let listed = inventory.threads.first(where: { $0.id == exactID }) else {
            throw CodexObservationError.unknownSession
        }
        let result = try await metadataRequest(hostID: hostID, deadline: deadline) {
            CodexObservationRPC.read(id: $0, threadID: exactID)
        }
        let read = try CodexThreadMetadata.parseRead(result, exactID: exactID)
        guard read.createdAt == listed.createdAt, read.sessionFamilyID == listed.sessionFamilyID,
              read.updatedAt >= listed.updatedAt else { throw CodexObservationError.staleMetadata }
        return CodexMetadataInventory(
            hostID: hostID, threads: [read], loadedThreadIDs: inventory.loadedThreadIDs, observedAt: Date()
        )
    }

    private func metadataInventory(hostID: String, deadline: Date) async throws -> CodexMetadataInventory {
        var threads = CodexMetadataPages<CodexThreadMetadata>()
        var cursor: String?
        repeat {
            let result = try await metadataRequest(hostID: hostID, deadline: deadline) {
                CodexObservationRPC.list(id: $0, cursor: cursor)
            }
            cursor = try threads.append(result) {
                let thread = try CodexThreadMetadata.parse($0)
                return (thread.id, thread)
            }
        } while cursor != nil
        var loaded = CodexMetadataPages<String>()
        cursor = nil
        repeat {
            let result = try await metadataRequest(hostID: hostID, deadline: deadline) {
                CodexObservationRPC.loadedList(id: $0, cursor: cursor)
            }
            cursor = try loaded.append(result) {
                guard let id = $0.stringValue, CodexThreadMetadata.isExactIdentity(id) else {
                    throw CodexObservationError.invalidMetadata
                }
                return (id, id)
            }
        } while cursor != nil
        guard metadataObservationHostID == hostID else { throw CodexObservationError.hostChanged }
        return CodexMetadataInventory(
            hostID: hostID, threads: threads.elements,
            loadedThreadIDs: Set(loaded.elements), observedAt: Date()
        )
    }

    private func metadataRequest(
        hostID: String,
        deadline: Date,
        payload: (String) -> CodexJSON
    ) async throws -> CodexJSON {
        guard metadataObservationHostID == hostID, let generation = streamGeneration else {
            throw CodexObservationError.hostChanged
        }
        guard !Task.isCancelled else { throw CodexObservationError.cancelled }
        guard pendingObservations.count < CodexObservationRPC.maximumPendingRequests else {
            throw CodexObservationError.tooManyRequests
        }
        let remaining = min(deadline.timeIntervalSinceNow, CodexObservationRPC.requestTimeout)
        guard remaining > 0 else { throw CodexObservationError.timedOut }
        let id = CodexObservationRPC.identifier(hostGeneration: generation)
        let request = payload(id)
        guard let dictionary = request.jsonObject() as? [String: Any] else {
            throw CodexObservationError.invalidMetadata
        }
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CodexJSON, Error>) in
                let timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    catch { return }
                    self?.failObservation(id, error: .timedOut)
                }
                pendingObservations[id] = PendingObservation(continuation: continuation, timeout: timeout)
                send(dictionary)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.failObservation(id, error: .cancelled) }
        }
        guard metadataObservationHostID == hostID else { throw CodexObservationError.hostChanged }
        return result
    }

    private func failObservation(_ id: String, error: CodexObservationError) {
        guard let pending = pendingObservations.removeValue(forKey: id) else { return }
        pending.timeout.cancel()
        pending.continuation.resume(throwing: error)
    }

    private func failObservations() {
        for id in Array(pendingObservations.keys) { failObservation(id, error: .hostChanged) }
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
        failObservations()
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
        failObservations()
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
                if case .string(let observationID) = id,
                   CodexObservationRPC.isObservationReply(id) {
                    if let pending = pendingObservations.removeValue(forKey: observationID) {
                        pending.timeout.cancel()
                        pending.continuation.resume(returning: result)
                    }
                    continue
                }
                if case .number(let number) = id,
                   let continuation = pendingResponses.removeValue(forKey: number) {
                    continuation.resume(returning: result)
                }
            case .error(let id, let message):
                if case .string(let observationID)? = id,
                   CodexObservationRPC.isObservationReply(id) {
                    failObservation(observationID, error: .providerRejected)
                    continue
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
        switch effect {
        case .threadStarted(let id):
            threadID = id
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
        case .failed(let message):
            lastError = message
            if isTurnActive {
                isTurnActive = false
                turnFailure = message
            }
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
