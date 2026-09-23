#if os(macOS)
import Darwin
import Foundation

/// A per-runtime, private Unix socket for lifecycle-only zsh hook messages.
/// The shell sends no terminal bytes or command text. Peer PID, runtime nonce,
/// and exact task/runtime identities are checked before a receipt is emitted.
public final class ShellTelemetrySocketServer {
    public struct LaunchConfiguration {
        public let environment: [String]
        public let executionID: String
    }

    private struct WireMessage: Decodable {
        let token: String
        let taskSessionID: String
        let runtimeAttemptID: String
        let shellExecutionID: String
        let phase: String
        let shellPID: Int32
        let workingDirectory: String
        let commandSequence: Int?
        let exitStatus: Int32?
    }

    private let taskSessionID: TaskSessionID
    private let runtimeAttemptID: RuntimeAttemptID
    private let executionID = UUID().uuidString.lowercased()
    private let token = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
    private let onEvent: (ShellTelemetryEvent) -> Void
    private let originalZdotdirOverride: String?
    private let queue = DispatchQueue(label: "dev.camerontjs.conduit.shell-telemetry")
    private let clientQueue = DispatchQueue(label: "dev.camerontjs.conduit.shell-telemetry-clients")
    private let stateLock = NSLock()
    private var listener: DispatchSourceRead?
    private var listenerFD: Int32 = -1
    private var directoryURL: URL?
    private var socketPath: String?
    private var shellPID: Int32?
    private var executionStarted = false
    private var shellExited = false
    private var activeCommandSequence: Int?
    private var lastCommandSequence = 0
    private var stopped = false

    public init(
        taskSessionID: TaskSessionID,
        runtimeAttemptID: RuntimeAttemptID,
        originalZdotdir: String? = nil,
        onEvent: @escaping (ShellTelemetryEvent) -> Void
    ) {
        self.taskSessionID = taskSessionID
        self.runtimeAttemptID = runtimeAttemptID
        self.originalZdotdirOverride = originalZdotdir
        self.onEvent = onEvent
    }

    public func start() throws -> LaunchConfiguration {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cs-\(UUID().uuidString.prefix(10).lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        directoryURL = directory

        let socket = directory.appendingPathComponent("s").path
        do {
            try startListener(at: socket)
            try writeZshProfile(into: directory, socketPath: socket)
        } catch {
            stop()
            throw error
        }
        return LaunchConfiguration(
            environment: ["ZDOTDIR=\(directory.path)"],
            executionID: executionID
        )
    }

    public func stop() {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        stateLock.unlock()

        listener?.cancel()
        listener = nil
        if let socketPath { unlink(socketPath) }
        if let directoryURL {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    deinit {
        stop()
    }

    private func startListener(at path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count + 1 < pathCapacity else {
            throw ShellTelemetrySocketError.socketPathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { storage in
            storage.initializeMemory(as: UInt8.self, repeating: 0)
            storage.copyBytes(from: pathBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sa_family_t>.size + pathBytes.count + 1)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ShellTelemetrySocketError.posix("socket", errno) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ShellTelemetrySocketError.posix("bind", code)
        }
        guard chmod(path, mode_t(0o600)) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw ShellTelemetrySocketError.posix("chmod socket", code)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            unlink(path)
            throw ShellTelemetrySocketError.posix("listen", code)
        }
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        listenerFD = fd
        socketPath = path

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections() }
        source.setCancelHandler { Darwin.close(fd) }
        listener = source
        source.resume()
    }

    private func acceptConnections() {
        while true {
            let client = Darwin.accept(listenerFD, nil, nil)
            guard client >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                return
            }
            let clientFlags = fcntl(client, F_GETFL, 0)
            guard clientFlags >= 0,
                  fcntl(client, F_SETFL, clientFlags & ~O_NONBLOCK) == 0
            else {
                Darwin.close(client)
                continue
            }
            clientQueue.async { [weak self] in
                self?.readMessage(from: client)
            }
        }
    }

    private func readMessage(from client: Int32) {
        defer { Darwin.close(client) }
        var peerPID: pid_t = 0
        var peerSize = socklen_t(MemoryLayout<pid_t>.size)
        let peerResult = getsockopt(
            client,
            SOL_LOCAL,
            LOCAL_PEERPID,
            &peerPID,
            &peerSize
        )
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        guard peerResult == 0, peerPID > 0 else {
            acknowledge(false, to: client)
            return
        }

        var bytes = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while bytes.count < 16_384 {
            let count = chunk.withUnsafeMutableBytes { storage in
                recv(client, storage.baseAddress, storage.count, 0)
            }
            guard count > 0 else { break }
            bytes.append(contentsOf: chunk.prefix(count))
            if bytes.contains(0x0A) { break }
        }
        guard let newline = bytes.firstIndex(of: 0x0A) else {
            acknowledge(false, to: client)
            return
        }
        let frame = bytes[..<newline]
        guard let wire = decodeWireMessage(Data(frame)) else {
            acknowledge(false, to: client)
            return
        }
        guard wire.token == token,
              wire.taskSessionID == taskSessionID.rawValue.uuidString,
              wire.runtimeAttemptID == runtimeAttemptID.rawValue.uuidString,
              wire.shellExecutionID == executionID,
              wire.shellPID == peerPID,
              wire.workingDirectory.hasPrefix("/"),
              wire.workingDirectory.utf8.count <= 4096,
              let phase = ShellTelemetryPhase(rawValue: wire.phase)
        else {
            acknowledge(false, to: client)
            return
        }

        let now = Date()
        let group = getpgid(peerPID)
        let processGroup: OrchestrationValue<Int32> = group > 0
            ? .known(group) : .unknown
        let sequence = wire.commandSequence
        let event = ShellTelemetryEvent(
            shellExecutionID: executionID,
            runtimeAttemptID: runtimeAttemptID.rawValue.uuidString,
            phase: phase,
            commandID: sequence.map { "\(executionID):\($0)" },
            commandSequence: sequence,
            shellPID: peerPID,
            processGroupID: processGroup,
            workingDirectory: .known(wire.workingDirectory),
            exitStatus: wire.exitStatus.map(OrchestrationValue.known) ?? .unknown,
            deliveryTransport: sequence.map { _ in .known(.shellStdin) } ?? .unknown,
            observation: SupervisionObservationStamp(
                authority: .shellHookObserved,
                freshness: .current,
                observedAt: .known(now)
            )
        )
        guard event.hasValidIdentity else {
            acknowledge(false, to: client)
            return
        }

        stateLock.lock()
        guard !stopped,
              shellPID == nil || shellPID == peerPID,
              accept(phase: phase, sequence: wire.commandSequence)
        else {
            stateLock.unlock()
            acknowledge(false, to: client)
            return
        }
        if shellPID == nil { shellPID = peerPID }
        stateLock.unlock()

        DispatchQueue.main.async { [onEvent] in onEvent(event) }
        acknowledge(true, to: client)
    }

    private func acknowledge(_ accepted: Bool, to client: Int32) {
        let bytes: [UInt8] = accepted ? [0x31, 0x0A] : [0x30, 0x0A]
        _ = bytes.withUnsafeBytes { buffer in
            Darwin.send(client, buffer.baseAddress, buffer.count, 0)
        }
    }

    private func decodeWireMessage(_ data: Data) -> WireMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return nil }
        let required: Set<String> = [
            "token", "taskSessionID", "runtimeAttemptID", "shellExecutionID",
            "phase", "shellPID", "workingDirectory",
        ]
        let optional: Set<String> = ["commandSequence", "exitStatus"]
        let keys = Set(dictionary.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional))
        else { return nil }
        return try? JSONDecoder().decode(WireMessage.self, from: data)
    }

    private func accept(phase: ShellTelemetryPhase, sequence: Int?) -> Bool {
        guard !shellExited else { return false }
        switch phase {
        case .executionStarted:
            guard !executionStarted, sequence == nil else { return false }
            executionStarted = true
            return true
        case .commandStarted:
            guard executionStarted,
                  let sequence,
                  sequence == lastCommandSequence + 1,
                  activeCommandSequence == nil
            else { return false }
            lastCommandSequence = sequence
            activeCommandSequence = sequence
            return true
        case .commandExited:
            guard let sequence, activeCommandSequence == sequence else { return false }
            activeCommandSequence = nil
            return true
        case .directoryChanged, .shellExited:
            guard executionStarted, sequence == nil else { return false }
            if phase == .shellExited {
                guard activeCommandSequence == nil else { return false }
                shellExited = true
            }
            return true
        }
    }

    private func writeZshProfile(into directory: URL, socketPath: String) throws {
        let environment = ProcessInfo.processInfo.environment
        let originalZdotdir = originalZdotdirOverride
            ?? environment["ZDOTDIR"]
            ?? environment["HOME"]
            ?? NSHomeDirectory()
        let files = ShellTelemetryZshProfile.files(
            taskSessionID: taskSessionID.rawValue.uuidString,
            runtimeAttemptID: runtimeAttemptID.rawValue.uuidString,
            shellExecutionID: executionID,
            token: token,
            socketPath: socketPath,
            originalZdotdir: originalZdotdir
        )
        for (name, contents) in files {
            let file = directory.appendingPathComponent(name)
            guard FileManager.default.createFile(
                atPath: file.path,
                contents: Data(contents.utf8),
                attributes: [.posixPermissions: 0o600]
            ) else { throw ShellTelemetrySocketError.profileWriteFailed(name) }
        }
    }
}

enum ShellTelemetrySocketError: Error, LocalizedError {
    case socketPathTooLong
    case profileWriteFailed(String)
    case posix(String, Int32)

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong:
            return "The private Shell telemetry socket path exceeds the macOS limit."
        case .profileWriteFailed(let name):
            return "Could not write the private zsh startup file \(name)."
        case .posix(let operation, let code):
            return "Shell telemetry \(operation) failed: \(String(cString: strerror(code)))."
        }
    }
}
#endif
