#if os(macOS)
import ConduitCore
import Foundation

/// Bridges blocking work onto a GCD global queue instead of the Swift
/// concurrency cooperative pool. Subprocess calls can block a thread for the
/// full timeout; parking those on cooperative threads (which are capped at the
/// core count and assume forward progress) can starve all other async work, so
/// every long-running subprocess offload routes through here.
enum BlockingWork {
    static func run<T: Sendable>(qos: DispatchQoS.QoSClass = .userInitiated, _ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: body())
            }
        }
    }
}

/// Runs a subprocess with argv directly (no shell), draining output
/// concurrently so large output cannot deadlock the pipe, and enforcing a
/// timeout so a hung child cannot hang Conduit.
enum SubprocessRunner {
    struct Result: Sendable {
        let status: Int32
        let output: String
        let timedOut: Bool
    }

    /// Writing to a pipe whose read end is gone raises SIGPIPE, which is
    /// process-fatal by default. The timeout path kills a hung child and
    /// closes its read end while the stdin writer may still be mid-write, so
    /// the app must ignore SIGPIPE and let the writer see EPIPE instead.
    static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    static func run(
        _ executable: String,
        _ arguments: [String],
        stdin: Data? = nil,
        currentDirectory: String? = nil,
        timeout: TimeInterval = 10
    ) -> Result {
        _ = ignoreSIGPIPE
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        let inputPipe: Pipe? = stdin != nil ? Pipe() : nil
        if let inputPipe {
            process.standardInput = inputPipe
        }

        let bufferLock = NSLock()
        var buffer = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let handle = output.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                bufferLock.lock()
                buffer.append(chunk)
                bufferLock.unlock()
            }
            readDone.signal()
        }

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
        } catch {
            try? output.fileHandleForWriting.close()
            return Result(status: -1, output: error.localizedDescription, timedOut: false)
        }
        // Close the parent's copy of the write end so EOF can arrive.
        try? output.fileHandleForWriting.close()

        if let inputPipe, let stdin {
            DispatchQueue.global(qos: .utility).async {
                try? inputPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if terminated.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 2)
            }
        }
        _ = readDone.wait(timeout: .now() + 2)

        bufferLock.lock()
        let text = String(decoding: buffer, as: UTF8.self)
        bufferLock.unlock()
        return Result(
            status: timedOut ? -1 : process.terminationStatus,
            output: timedOut ? text + "\n[timed out after \(Int(timeout))s]" : text,
            timedOut: timedOut
        )
    }
}

/// Resolves executable paths without ever spawning a shell on the call path.
///
/// `resolve` is pure file-system checks against the current PATH view, so it is
/// safe to call from the main actor. The one login-shell probe that captures
/// the operator's full interactive PATH happens only in `prewarm` — run once,
/// off the main thread, coalesced so concurrent callers never each spawn their
/// own login shell. Until the cache warms, resolution falls back to the process
/// PATH plus standard directories, which already cover tmux, git, and ollama.
final class EnvironmentResolver: @unchecked Sendable {
    static let shared = EnvironmentResolver()

    private static let defaultDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]

    private let lock = NSLock()
    private var cachedPath: [String]?
    private var prewarmStarted = false

    /// Captures the login-shell PATH once. Idempotent and coalesced: only the
    /// first caller runs the shell; later callers return immediately. Must be
    /// invoked off the main thread.
    func prewarm() {
        lock.lock()
        if prewarmStarted {
            lock.unlock()
            return
        }
        prewarmStarted = true
        lock.unlock()

        var entries: [String] = []
        let probe = SubprocessRunner.run("/bin/zsh", ["-l", "-c", "print -rn -- \"$PATH\""], timeout: 8)
        if probe.status == 0 {
            entries = probe.output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":")
                .map(String.init)
        }
        entries += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        entries += Self.defaultDirectories

        lock.lock()
        cachedPath = Self.dedupe(entries)
        lock.unlock()
    }

    /// The current PATH view. Never spawns a process.
    private func currentEntries() -> [String] {
        lock.lock()
        let cached = cachedPath
        lock.unlock()
        if let cached { return cached }
        var entries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        entries += Self.defaultDirectories
        return Self.dedupe(entries)
    }

    /// Absolute and path-bearing commands are checked directly; bare names are
    /// searched on the current PATH. Returns the executable's absolute path.
    func resolve(_ command: String) -> String? {
        guard !command.isEmpty else { return nil }
        let fileManager = FileManager.default
        if command.hasPrefix("/") {
            return fileManager.isExecutableFile(atPath: command) ? command : nil
        }
        if command.contains("/") {
            let expanded = (command as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for directory in currentEntries() {
            let candidate = directory + "/" + command
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func dedupe(_ entries: [String]) -> [String] {
        var seen = Set<String>()
        return entries.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// Out-of-band tmux control operations targeting named sessions. The attach
/// client inside SwiftTerm stays a plain `tmux attach-session`; every control
/// action (create, detach, paste) goes through the tmux server directly so no
/// keystroke emulation or prefix-key assumption is involved.
struct TmuxDriver: Sendable {
    let tmuxPath: String

    func hasSession(_ name: String) -> Bool {
        SubprocessRunner.run(tmuxPath, ["has-session", "-t", "=\(name)"], timeout: 5).status == 0
    }

    /// Creates the session detached if missing. Returns false when tmux could
    /// not provide the session (caller should fall back to a direct PTY).
    func ensureSession(name: String, directory: String, command: String) -> Bool {
        if hasSession(name) { return true }
        let result = SubprocessRunner.run(
            tmuxPath,
            ["new-session", "-d", "-s", name, "-c", directory, command],
            timeout: 8
        )
        return result.status == 0
    }

    /// Detaches every client attached to the session — deterministic, no
    /// prefix-key emulation, works with any operator tmux configuration.
    func detachClients(session: String) {
        _ = SubprocessRunner.run(tmuxPath, ["detach-client", "-s", "=\(session)"], timeout: 5)
    }

    /// Kills the named session and its processes. Used when the operator wants
    /// a true fresh start rather than durable detach/reconnect.
    func killSession(_ name: String) {
        _ = SubprocessRunner.run(tmuxPath, ["kill-session", "-t", "=\(name)"], timeout: 5)
    }

    /// Delivers text into the session through a tmux buffer. `paste-buffer -p`
    /// honours the foreground application's bracketed-paste mode, so multiline
    /// prompts arrive as one block; the optional Enter is the explicit submit.
    /// Pane targets use the `=name:` form — exact session match, active pane —
    /// because `paste-buffer`/`send-keys` take a target-pane, and a bare
    /// `=name` does not parse as one (verified against tmux 3.6b).
    func paste(session: String, text: String, submit: Bool) -> Bool {
        let paneTarget = "=\(session):"
        let bufferName = "conduit-\(UUID().uuidString.prefix(8))"
        let load = SubprocessRunner.run(
            tmuxPath,
            ["load-buffer", "-b", bufferName, "-"],
            stdin: Data(text.utf8),
            timeout: 5
        )
        guard load.status == 0 else { return false }
        let paste = SubprocessRunner.run(
            tmuxPath,
            ["paste-buffer", "-p", "-d", "-b", bufferName, "-t", paneTarget],
            timeout: 5
        )
        guard paste.status == 0 else { return false }
        if submit {
            return SubprocessRunner.run(tmuxPath, ["send-keys", "-t", paneTarget, "Enter"], timeout: 5).status == 0
        }
        return true
    }
}
#endif
