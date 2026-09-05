#if os(macOS)
import ConduitCore
import Foundation

/// Disposable Claude / Antigravity print-mode stream-json worker (D-040).
///
/// One process per turn. Session/conversation ids are persisted so the next
/// turn can `-r` / `--conversation` in a new process.
@MainActor
final class StreamJSONClient: ObservableObject {
    enum ClientError: Error, LocalizedError {
        case executableMissing
        case notReady
        case protocolError(String)

        var errorDescription: String? {
            switch self {
            case .executableMissing:
                return "stream-json CLI is not on PATH."
            case .notReady:
                return "stream-json adapter is not ready."
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
    var pendingApprovalSummary: String? { nil }

    var onEffect: ((StructuredAdapterEffect) -> Void)?
    /// Fired once the host can accept a turn.
    ///
    /// Conduit holds a prompt that arrives before this point rather than
    /// refusing it, so something has to say when the wait is over.
    var onReady: (() -> Void)?
    var onFailed: ((String) -> Void)?
    var onExited: (() -> Void)?

    private let flavor: StreamJSONFlavor
    private let cwd: URL
    private let resumeSessionID: String?
    private var executable: String?
    private var process: Process?
    private var stdoutHandle: FileHandle?
    private var streamGeneration: UUID?
    private var stdoutBuffer = Data()
    private var mapper: StreamJSONMapper

    init(flavor: StreamJSONFlavor, cwd: URL, resumeSessionID: String? = nil) {
        self.flavor = flavor
        self.cwd = cwd
        self.resumeSessionID = resumeSessionID
        self.mapper = StreamJSONMapper(flavor: flavor)
        self.sessionID = resumeSessionID
    }

    func start(executable: String) async throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ClientError.executableMissing
        }
        self.executable = executable
        if let resumeSessionID, !resumeSessionID.isEmpty {
            sessionID = resumeSessionID
            mapper.sessionID = resumeSessionID
            emit(.sessionStarted(id: resumeSessionID))
        }
        isReady = true
        onReady?()
    }

    func sendTurn(text: String) throws {
        guard isReady, let executable else { throw ClientError.notReady }
        if process?.isRunning == true {
            throw ClientError.protocolError("a stream-json turn is already running")
        }
        mapper.resetTurn()
        isTurnActive = true
        // A new turn must not inherit the previous turn's failure. lastError
        // is what marks a turn failed rather than completed, so leaving it set
        // would report every later successful turn on this task as failed.
        lastTurnStatus = nil
        lastError = nil
        turnFailure = nil
        try spawnTurn(executable: executable, prompt: text)
    }

    func interrupt() {
        process?.terminate()
    }

    func respondToApproval(accept: Bool) {
        _ = accept
    }

    func stop() {
        streamGeneration = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        isReady = false
        isTurnActive = false
    }

    private func spawnTurn(executable: String, prompt: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(prompt: prompt)
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let generation = UUID()
        streamGeneration = generation
        stdoutHandle = stdout.fileHandleForReading
        stdoutHandle?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                self?.ingest(data, generation: generation)
            }
        }
        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                self?.handleExit(generation: generation, status: proc.terminationStatus)
            }
        }
        try process.run()
        self.process = process
    }

    private func arguments(prompt: String) -> [String] {
        switch flavor {
        case .claude:
            return StreamJSONMapper.claudeArguments(
                resumeSessionID: sessionID,
                prompt: prompt
            )
        case .antigravity:
            return StreamJSONMapper.antigravityArguments(
                resumeSessionID: sessionID,
                prompt: prompt
            )
        }
    }

    private func ingest(_ data: Data, generation: UUID) {
        guard streamGeneration == generation else { return }
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let range = stdoutBuffer.range(of: Data([0x0a])) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            for effect in mapper.applyLine(line) {
                emit(effect)
            }
        }
    }

    private func handleExit(generation: UUID, status: Int32) {
        guard streamGeneration == generation else { return }
        if !stdoutBuffer.isEmpty,
           let line = String(data: stdoutBuffer, encoding: .utf8) {
            stdoutBuffer.removeAll()
            for effect in mapper.applyLine(line) {
                emit(effect)
            }
        }
        process = nil
        stdoutHandle?.readabilityHandler = nil
        stdoutHandle = nil
        isTurnActive = false
        if lastTurnStatus == nil {
            if status == 0 {
                emit(.turnCompleted(status: "exited"))
            } else {
                emit(.failed("stream-json exited \(status)"))
            }
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
            onFailed?(message)
        }
        onEffect?(effect)
    }
}
#endif
