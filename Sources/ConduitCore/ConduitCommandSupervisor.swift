import Foundation
#if canImport(Darwin)
import Darwin
import CryptoKit
#endif

/// Observations, never recovered signalling authority. Absent from v1 records.
public struct ConduitCommandSupervision: Codable {
    public let protocolVersion: String
    public let attemptNonce: String
    public let helperIdentity: String
    public internal(set) var lastEventRevision: UInt64 = 0
    public internal(set) var goCommitted = false
    public internal(set) var cancellationAccepted: Bool?
    public internal(set) var rootExitObserved = false
    public internal(set) var controlClosed = false
    public internal(set) var finalFrameObserved = false
    public internal(set) var cleanupCause: Int?
    public let cleanupScope: String
    public let descendantContainment: String

    internal init(helper: URL) throws {
        protocolVersion = "CDS1"
        cleanupScope = "original_process_group"
        descendantContainment = "not_provided"
        attemptNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        #if canImport(Darwin)
        helperIdentity = SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined()
        #else
        throw ConduitDirectCommandError(code: "supervisor_unavailable", detail: "This development supervisor requires macOS.")
        #endif
    }
}

internal struct SupervisorEvent {
    let revision: UInt64
    let kind: String
    let values: [Int32]
}

/// App-side pipe adapter. Only S is our child; this object never signals R or S.
internal final class ConduitSupervisorChannel {
    let pid: Int32
    let stdoutFD: Int32
    let stderrFD: Int32
    private var controlFD: Int32
    private let eventFD: Int32
    private let nonce: String
    private var pending = Data()
    private var input = Data()
    private var revision: UInt64 = 0
    private(set) var eof = false
    private(set) var helperExited = false

    private init(pid: Int32, stdout: Int32, stderr: Int32, control: Int32, events: Int32, nonce: String) {
        self.pid = pid; stdoutFD = stdout; stderrFD = stderr
        controlFD = control; eventFD = events; self.nonce = nonce
    }

    deinit {
        disconnect()
        for fd in [stdoutFD, stderrFD, eventFD] { _ = close(fd) }
        // Do not wait indefinitely, or transfer any payload signalling authority.
        if !helperExited {
            let child = pid
            DispatchQueue.global(qos: .utility).async {
                var status: Int32 = 0
                // Exact direct-child reaping only. S has finite control deadlines.
                while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            }
        }
    }

    func disconnect() {
        if controlFD >= 0 { _ = close(controlFD); controlFD = -1 }
        pending.removeAll()
    }

    func send(_ kind: String) throws {
        let sequence: Int
        switch kind { case "GO": sequence = 1; case "CANCEL": sequence = 2; case "OBSERVE": sequence = 3
        default: throw Self.failure("Unknown internal control command") }
        guard controlFD >= 0, pending.count < 512 else { throw Self.failure("Control channel unavailable") }
        pending.append(Data("CDS1 \(nonce) \(sequence) \(kind)\n".utf8))
        try flush()
    }

    func flush() throws {
        guard !pending.isEmpty else { return }
        let count = pending.withUnsafeBytes { write(controlFD, $0.baseAddress, $0.count) }
        if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
        guard count > 0 else { disconnect(); throw Self.failure("Control write failed") }
        pending.removeFirst(count)
    }

    func poll() throws -> [SupervisorEvent] {
        try flush()
        var buffer = [UInt8](repeating: 0, count: 512)
        var events: [SupervisorEvent] = []
        for _ in 0..<8 {
            let count = read(eventFD, &buffer, buffer.count)
            if count == 0 { eof = true; break }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { break }
            guard count > 0 else { throw Self.failure("Status read failed") }
            input.append(contentsOf: buffer.prefix(count))
            while let end = input.firstIndex(of: 10) {
                let line = input.prefix(upTo: end)
                guard line.count < 256, let text = String(data: line, encoding: .ascii), !line.contains(0) else {
                    throw Self.failure("Malformed status frame")
                }
                let fields = text.split(separator: " ", omittingEmptySubsequences: false)
                guard fields.count >= 4, fields[0] == "CDS1", fields[1] == Substring(nonce),
                      let next = UInt64(fields[2]), revision < UInt64.max, next == revision + 1 else { throw Self.failure("Status identity/revision mismatch") }
                let kind = String(fields[3])
                let lengths = ["READY": 3, "GO": 1, "CANCEL": 1, "ROOT": 2, "CLOSED": 0, "FINAL": 6, "ERROR": 1]
                guard let size = lengths[kind], fields.count == size + 4 else { throw Self.failure("Status type/length mismatch") }
                let values = fields.dropFirst(4).compactMap { Int32($0) }
                guard values.count == size else { throw Self.failure("Invalid status integer") }
                revision = next
                events.append(.init(revision: next, kind: kind, values: values))
                input.removeSubrange(...end)
            }
            guard input.count < 256 else { throw Self.failure("Oversized status frame") }
        }
        if eof && !input.isEmpty { throw Self.failure("Status channel ended mid-frame") }
        var status: Int32 = 0
        if !helperExited {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno == ECHILD) { helperExited = true }
        }
        return events
    }

    func drain(_ fd: Int32, into output: inout ConduitDirectCommandOutput, limit: Int, tail: Int) {
        guard !output.reachedEOF else { return }
        var bytes = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            let n = read(fd, &bytes, bytes.count)
            if n == 0 { output.reachedEOF = true; return }
            if n < 0 { return }
            output.append(Data(bytes.prefix(n)), limit: limit, tailLimit: tail)
        }
    }

    static func spawn(helper: URL, request: ConduitDirectCommandRequest, receipt: ConduitDirectCommandReceipt,
                      storeFD: Int32) throws -> ConduitSupervisorChannel {
        #if canImport(Darwin)
        guard let supervision = receipt.supervision, request.timeoutMS <= 5_000 else {
            throw failure("Supervisor fixture timeout must not exceed five seconds")
        }
        let actual = SHA256.hash(data: try Data(contentsOf: helper)).map { String(format: "%02x", $0) }.joined()
        guard actual == supervision.helperIdentity else { throw failure("Helper identity changed before spawn") }
        var owned: [Int32] = []
        func high(_ fd: Int32) throws -> Int32 {
            guard fd >= 0 else { throw failure("Descriptor creation failed") }
            defer { _ = close(fd) }
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 10)
            guard copy >= 0 else { throw failure("Descriptor isolation failed") }
            owned.append(copy); return copy
        }
        func pipePair() throws -> [Int32] {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw failure("Pipe creation failed") }
            let reader: Int32
            do { reader = try high(pair[0]) } catch { _ = close(pair[1]); throw error }
            return [reader, try high(pair[1])]
        }
        var transferred = Set<Int32>()
        defer { for fd in owned where !transferred.contains(fd) { _ = close(fd) } }
        let control = try pipePair(), events = try pipePair(), out = try pipePair(), err = try pipePair()
        let store = try high(dup(storeFD))
        let cwd = try high(open(receipt.resolvedCwd, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        var facts = stat()
        guard fstat(cwd, &facts) == 0, "\(facts.st_dev):\(facts.st_ino)" == receipt.cwdIdentity else {
            throw failure("Fixture cwd identity changed")
        }
        // Per-descriptor suppression: never change the app's process-wide SIGPIPE policy.
        guard fcntl(control[1], F_SETNOSIGPIPE, 1) == 0 else { throw failure("Safe pipe-write policy unavailable") }
        for fd in [control[1], events[0], out[0], err[0]] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw failure("Nonblocking pipe setup failed") }
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw failure("Spawn actions unavailable") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw failure("Spawn attributes unavailable") }
        defer { posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGCHLD, SIGPIPE, SIGINT, SIGTERM] { sigaddset(&defaults, signal) }
        var errors = [
            posix_spawnattr_setsigmask(&attributes, &mask), posix_spawnattr_setsigdefault(&attributes, &defaults),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)),
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        ]
        for (src, dst) in [(out[1], 1), (err[1], 2), (control[0], 3), (events[1], 4), (store, 5), (cwd, 6)] {
            errors.append(posix_spawn_file_actions_adddup2(&actions, src, Int32(dst)))
        }
        guard errors.allSatisfy({ $0 == 0 }) else { throw failure("Spawn descriptor preparation failed") }
        let argumentStrings = [helper.path, "--supervise", supervision.attemptNonce, request.operationID, String(request.timeoutMS), "--"] + request.argv
        let environmentStrings: [String] = ["PATH=/usr/bin:/bin", "LANG=C"]
        var args: [UnsafeMutablePointer<CChar>?] = argumentStrings.map { value in value.withCString { strdup($0) } }
        var env: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { value in value.withCString { strdup($0) } }
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        guard args.allSatisfy({ $0 != nil }), env.allSatisfy({ $0 != nil }) else { throw failure("Argument allocation failed") }
        args.append(nil); env.append(nil)
        var child: pid_t = 0
        guard posix_spawn(&child, helper.path, &actions, &attributes, &args, &env) == 0 else { throw failure("Supervisor spawn failed") }
        transferred = Set([control[1], events[0], out[0], err[0]])
        return .init(pid: child, stdout: out[0], stderr: err[0], control: control[1], events: events[0], nonce: supervision.attemptNonce)
        #else
        throw failure("The supervisor fixture adapter requires macOS")
        #endif
    }

    private static func failure(_ message: String) -> ConduitDirectCommandError {
        .init(code: "supervisor_unavailable", detail: message)
    }
}
