#if os(macOS)
import ConduitCore
import Foundation
import Security

/// One Conduit-owned `opencode serve` plus per-task HTTP sessions (D-040).
@MainActor
final class OpenCodeServeLease {
    static let shared = OpenCodeServeLease()

    private var process: Process?
    private var record: OpenCodeServeLeaseRecord?
    private var retainCount = 0
    /// The most recent in-flight resolve. Each new acquire waits for it, so
    /// only one caller can be between the record check and the assignment.
    private var resolveChain: Task<OpenCodeServeLeaseRecord, Error>?

    private var leaseURL: URL {
        AdapterThreadStore.defaultDirectory().appendingPathComponent(
            OpenCodeHTTPContract.leaseFileName
        )
    }

    /// Resolve the shared server, one caller at a time.
    ///
    /// `@MainActor` serialises statements, not `await`s. The previous version
    /// checked `record`, awaited a health probe, awaited `load()`'s probe, and
    /// only then awaited `spawn` — three suspension points before anything was
    /// assigned. Concurrent `conduit_create_task` calls therefore all saw a nil
    /// record and all spawned: observed 2026-09-05 with three simultaneous
    /// OpenCode creates, which left `opencode serve` running on ports
    /// 18752/18753/18754. Only the last one is reachable through `process`, so
    /// `shutdownIfIdle` could never terminate the others, and the finite port
    /// range leaks one entry per concurrent create for the life of the app.
    ///
    /// Chaining each resolve behind the previous one means the second caller
    /// runs its check after the first has assigned `record`, finds it healthy,
    /// and reuses it — which is what the retain count always assumed.
    func acquire(executable: String) async throws -> OpenCodeServeLeaseRecord {
        let previous = resolveChain
        let task = Task { [weak self] () async throws -> OpenCodeServeLeaseRecord in
            // A previous failure must not poison this caller's attempt; it
            // only has to finish before this one looks at the record.
            _ = try? await previous?.value
            guard let self else {
                throw OpenCodeHTTPClient.ClientError.protocolError(
                    "OpenCode lease was torn down."
                )
            }
            return try await self.resolve(executable: executable)
        }
        resolveChain = task
        // The retain is taken only on success. Incrementing first meant a
        // failed spawn left the count permanently above zero, so a later
        // release could never reach idle and shut the server down.
        let record = try await task.value
        retainCount += 1
        return record
    }

    private func resolve(
        executable: String
    ) async throws -> OpenCodeServeLeaseRecord {
        if let record, await health(record) {
            return record
        }
        if let disk = load(), await health(disk) {
            record = disk
            return disk
        }
        return try await spawn(executable: executable)
    }

    func release() {
        retainCount = max(0, retainCount - 1)
        if retainCount == 0 {
            shutdownIfIdle()
        }
    }

    /// Read-only lifecycle fact for one client release.
    ///
    /// A task-local OpenCode stop releases exactly one lease. It stops the
    /// shared provider host only when this is the last retained client and the
    /// host process is owned by this Conduit process.
    func willStopOwnedHostAfterReleasingOneLease() -> Bool {
        retainCount == 1 && process?.isRunning == true
    }

    func shutdownIfIdle() {
        guard retainCount == 0 else { return }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        record = nil
        try? FileManager.default.removeItem(at: leaseURL)
    }

    private func spawn(executable: String) async throws -> OpenCodeServeLeaseRecord {
        let password = Self.randomPassword()
        var lastError = "opencode serve did not become healthy."
        for port in OpenCodeHTTPContract.portRange {
            let url = "http://127.0.0.1:\(port)"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [
                "serve",
                "--hostname", "127.0.0.1",
                "--port", "\(port)",
            ]
            var environment = ProcessInfo.processInfo.environment
            environment["OPENCODE_SERVER_PASSWORD"] = password
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                lastError = error.localizedDescription
                continue
            }
            self.process = process
            let record = OpenCodeServeLeaseRecord(
                pid: process.processIdentifier,
                url: url,
                password: password,
                ownedByConduit: true
            )
            persist(record)
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                if await health(record) {
                    self.record = record
                    return record
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            process.terminate()
            self.process = nil
            lastError = "opencode serve did not become healthy on \(url)."
        }
        throw OpenCodeHTTPClient.ClientError.protocolError(lastError)
    }

    private func health(_ record: OpenCodeServeLeaseRecord) async -> Bool {
        guard let base = record.baseURL else { return false }
        var request = URLRequest(url: OpenCodeHTTPContract.healthURL(base: base))
        request.timeoutInterval = 2
        Self.applyAuth(&request, password: record.password)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return false
            }
            if let json = CodexJSON.parse(data) {
                return OpenCodeHTTPContract.isHealthy(json)
            }
            return true
        } catch {
            return false
        }
    }

    private func load() -> OpenCodeServeLeaseRecord? {
        guard let data = try? Data(contentsOf: leaseURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OpenCodeServeLeaseRecord.self, from: data)
    }

    private func persist(_ record: OpenCodeServeLeaseRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(
            at: leaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: leaseURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: leaseURL.path
        )
    }

    static func applyAuth(_ request: inout URLRequest, password: String) {
        guard !password.isEmpty else { return }
        let raw = "opencode:\(password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "A")
            .replacingOccurrences(of: "/", with: "B")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// HTTP + SSE client for one OpenCode session on the leased server.
@MainActor
final class OpenCodeHTTPClient: ObservableObject {
    enum ClientError: Error, LocalizedError {
        case executableMissing
        case notReady
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .executableMissing:
                return "opencode is not on PATH."
            case .notReady:
                return "OpenCode HTTP session is not ready."
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
    /// Provider-reported tool/patch activity for the current OpenCode turn.
    /// This intentionally excludes arbitrary tool output and does not claim
    /// that an operation succeeded beyond the provider status that was emitted.
    @Published private(set) var conversationActivities: [OpenCodeConversationActivity] = []
    /// Set only when a failure ends a turn that was still running.
    ///
    /// A `.failed` effect that arrives after the turn already completed does
    /// not un-complete it: interrupting a finished turn makes the provider
    /// report an error, and treating that as a turn failure erases a real
    /// observed completion. `lastError` keeps every error for display; this
    /// field carries only the ones that are the turn's outcome.
    @Published private(set) var turnFailure: String?
    @Published var pendingApprovalID: String?
    @Published var pendingApprovalSummary: String?

    /// Where the session this client is driving came from.
    ///
    /// Set once the handshake settles. A refused resume is silently replaced
    /// with a fresh session below, so without this the caller cannot tell a
    /// recovered task from an empty one wearing its name.
    private(set) var resumeProvenance: SessionResumeSemantics.Provenance?

    var onEffect: ((StructuredAdapterEffect) -> Void)?
    /// Optional presentation-only observation channel for structured activity.
    /// Runtime semantics do not depend on this callback.
    var onConversationActivity: ((OpenCodeConversationActivity) -> Void)?
    /// Fired once the host can accept a turn.
    ///
    /// Conduit holds a prompt that arrives before this point rather than
    /// refusing it, so something has to say when the wait is over.
    var onReady: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onExited: (() -> Void)?

    private let cwd: URL
    private let model: String?
    private let resumeSessionID: String?
    private var lease: OpenCodeServeLeaseRecord?
    private var mapper = OpenCodeEventMapper()
    private var activityIndexByID: [String: Int] = [:]
    private var sseTask: Task<Void, Never>?
    private var stopped = false

    /// Exact observed host identity when the lease record carries one.
    var lifecycleProviderHostIdentifier: String? {
        lease.map { "pid:\($0.pid)" }
    }

    /// Whether calling stop() on this client is presently known to stop the
    /// shared OpenCode provider host rather than only releasing this client.
    var lifecycleStopWillStopProviderHost: Bool {
        OpenCodeServeLease.shared.willStopOwnedHostAfterReleasingOneLease()
    }

    init(cwd: URL, model: String?, resumeSessionID: String? = nil) {
        self.cwd = cwd
        self.model = model
        self.resumeSessionID = resumeSessionID
    }

    func start(executable: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ClientError.executableMissing
        }
        stopped = false
        let lease = try await OpenCodeServeLease.shared.acquire(executable: executable)
        self.lease = lease
        guard let base = lease.baseURL else {
            throw ClientError.protocolError("OpenCode lease URL is invalid.")
        }
        var attempt: SessionResumeSemantics.Attempt = .notRequested
        let askedToResume = !(resumeSessionID ?? "").isEmpty
        if let resumeSessionID, !resumeSessionID.isEmpty,
           await sessionExists(base: base, id: resumeSessionID, password: lease.password) {
            sessionID = resumeSessionID
            mapper.sessionID = resumeSessionID
            attempt = .accepted
        } else {
            // Unlike the ACP and app-server clients this one checks first, so
            // a miss here is a definite refusal rather than a swallowed error
            // but the session it creates is just as empty.
            if askedToResume { attempt = .refused }
            let created = try await createSession(base: base, password: lease.password)
            guard let sessionID = OpenCodeHTTPContract.sessionID(in: created) else {
                throw ClientError.protocolError("OpenCode POST /session did not return an id.")
            }
            self.sessionID = sessionID
            mapper.sessionID = sessionID
        }
        if let sessionID {
            resumeProvenance = SessionResumeSemantics.classify(
                requested: resumeSessionID,
                started: sessionID,
                attempt: attempt
            )
            emit(.sessionStarted(id: sessionID))
        }
        isReady = true
        onReady?()
        startSSE(base: base, password: lease.password)
    }

    func sendTurn(text: String) throws {
        guard isReady, let sessionID, let lease, let base = lease.baseURL else {
            throw ClientError.notReady
        }
        mapper.resetTurn()
        conversationActivities.removeAll(keepingCapacity: true)
        activityIndexByID.removeAll(keepingCapacity: true)
        isTurnActive = true
        // A new turn must not inherit the previous turn's failure. lastError
        // is what marks a turn failed rather than completed, so leaving it set
        // would report every later successful turn on this task as failed.
        lastTurnStatus = nil
        lastError = nil
        turnFailure = nil
        let split = OpenCodeHTTPContract.splitModel(model)
        let body = OpenCodeHTTPContract.promptBody(
            text: text,
            providerID: split?.providerID,
            modelID: split?.modelID
        )
        Task { [weak self] in
            do {
                _ = try await self?.postJSON(
                    OpenCodeHTTPContract.messageURL(base: base, sessionID: sessionID),
                    password: lease.password,
                    body: body
                )
            } catch {
                self?.emit(.failed(error.localizedDescription))
            }
        }
    }

    func interrupt() {
        guard let sessionID, let lease, let base = lease.baseURL else { return }
        Task {
            _ = try? await postJSON(
                OpenCodeHTTPContract.abortURL(base: base, sessionID: sessionID),
                password: lease.password,
                body: [String: Any]()
            )
        }
    }

    func respondToApproval(accept: Bool) {
        guard let sessionID, let lease, let base = lease.baseURL,
              let permissionID = pendingApprovalID else { return }
        pendingApprovalID = nil
        pendingApprovalSummary = nil
        Task {
            _ = try? await postJSON(
                OpenCodeHTTPContract.permissionURL(
                    base: base,
                    sessionID: sessionID,
                    permissionID: permissionID
                ),
                password: lease.password,
                body: OpenCodeHTTPContract.permissionReplyBody(accept: accept)
            )
        }
    }

    func stop() {
        stopped = true
        sseTask?.cancel()
        sseTask = nil
        isReady = false
        isTurnActive = false
        OpenCodeServeLease.shared.release()
        lease = nil
    }

    private func createSession(base: URL, password: String) async throws -> CodexJSON {
        try await postJSON(
            OpenCodeHTTPContract.sessionCollectionURL(base: base),
            password: password,
            body: OpenCodeHTTPContract.sessionCreateBody(
                directory: cwd.path,
                title: "conduit"
            )
        )
    }

    private func sessionExists(base: URL, id: String, password: String) async -> Bool {
        var request = URLRequest(url: OpenCodeHTTPContract.sessionURL(base: base, id: id))
        request.timeoutInterval = 3
        OpenCodeServeLease.applyAuth(&request, password: password)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func startSSE(base: URL, password: String) {
        sseTask?.cancel()
        sseTask = Task { [weak self] in
            var request = URLRequest(url: OpenCodeHTTPContract.eventURL(base: base))
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            OpenCodeServeLease.applyAuth(&request, password: password)
            do {
                let (bytes, _) = try await URLSession.shared.bytes(for: request)
                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    let json: CodexJSON?
                    if line.hasPrefix("data:") {
                        json = OpenCodeEventMapper.parseSSELine(line)
                    } else {
                        json = OpenCodeEventMapper.parseSSELine("data: \(line)")
                            ?? CodexJSON.parseLine(line)
                    }
                    guard let json else { continue }
                    await MainActor.run {
                        self?.handleEvent(json)
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self?.onExited?()
                }
            }
        }
    }

    private func handleEvent(_ json: CodexJSON) {
        if let sessionID,
           let activity = OpenCodeConversationActivityExtractor.activity(
                from: json,
                boundSessionID: sessionID
           ) {
            upsertConversationActivity(activity)
        }
        for effect in mapper.apply(json) {
            emit(effect)
        }
    }

    private func upsertConversationActivity(
        _ activity: OpenCodeConversationActivity
    ) {
        if let index = activityIndexByID[activity.id] {
            conversationActivities[index] = activity
        } else {
            activityIndexByID[activity.id] = conversationActivities.count
            conversationActivities.append(activity)
        }
        onConversationActivity?(activity)
    }

    private func emit(_ effect: StructuredAdapterEffect) {
        switch effect {
        case .sessionStarted(let id):
            sessionID = id
        case .upsertOutput:
            isTurnActive = true
        case .requestApproval(let id, let summary):
            pendingApprovalID = id
            pendingApprovalSummary = summary
        case .turnCompleted(let status):
            isTurnActive = false
            lastTurnStatus = status
        case .failed(let message):
            lastError = message
            if isTurnActive {
                isTurnActive = false
                turnFailure = message
            }
            onFailed?(message)
        }
        onEffect?(effect)
    }

    private func postJSON(
        _ url: URL,
        password: String,
        body: [String: Any]
    ) async throws -> CodexJSON {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        OpenCodeServeLease.applyAuth(&request, password: password)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw ClientError.protocolError("OpenCode HTTP \(http.statusCode): \(snippet.prefix(240))")
        }
        return CodexJSON.parse(data) ?? .object([:])
    }
}
#endif
