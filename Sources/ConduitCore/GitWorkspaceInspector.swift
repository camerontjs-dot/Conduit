import Foundation

public enum GitWorkspaceInspectorError: LocalizedError, Equatable {
    case gitUnavailable(String)
    case notRepository(String)
    case commandFailed(arguments: [String], status: Int32, stderr: String)
    case timedOut(arguments: [String])

    public var errorDescription: String? {
        switch self {
        case .gitUnavailable(let detail):
            return "Git is unavailable: \(detail)"
        case .notRepository(let path):
            return "No Git repository contains \(path)"
        case .commandFailed(let arguments, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "git \(arguments.joined(separator: " ")) failed with status \(status)\(detail.isEmpty ? "" : ": \(detail)")"
        case .timedOut(let arguments):
            return "git \(arguments.joined(separator: " ")) exceeded the bounded inspection timeout"
        }
    }
}

public struct GitWorkspaceStatusEntry: Identifiable, Equatable, Sendable {
    public var id: String { "\(indexStatus)\(workTreeStatus):\(path):\(originalPath ?? "")" }

    public let indexStatus: Character
    public let workTreeStatus: Character
    public let path: String
    public let originalPath: String?

    public init(
        indexStatus: Character,
        workTreeStatus: Character,
        path: String,
        originalPath: String? = nil
    ) {
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
        self.path = path
        self.originalPath = originalPath
    }

    public var isUntracked: Bool {
        indexStatus == "?" && workTreeStatus == "?"
    }

    public var hasIndexChange: Bool {
        indexStatus != " " && indexStatus != "?" && indexStatus != "!"
    }

    public var hasWorkTreeChange: Bool {
        workTreeStatus != " " && workTreeStatus != "?" && workTreeStatus != "!"
    }

    public var statusLabel: String {
        if isUntracked { return "untracked" }
        if indexStatus == "!" && workTreeStatus == "!" { return "ignored" }
        switch (hasIndexChange, hasWorkTreeChange) {
        case (true, true): return "staged + working tree"
        case (true, false): return "staged"
        case (false, true): return "working tree"
        case (false, false): return "clean"
        }
    }
}

public struct GitWorkspaceSnapshot: Equatable, Sendable {
    public let repositoryRoot: String
    public let branch: String?
    public let headSHA: String
    public let isDetached: Bool
    public let status: [GitWorkspaceStatusEntry]
    public let statusWasTruncated: Bool

    public init(
        repositoryRoot: String,
        branch: String?,
        headSHA: String,
        isDetached: Bool,
        status: [GitWorkspaceStatusEntry],
        statusWasTruncated: Bool
    ) {
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.headSHA = headSHA
        self.isDetached = isDetached
        self.status = status
        self.statusWasTruncated = statusWasTruncated
    }

    public var isDirty: Bool { !status.isEmpty }

    public func statusEntry(for relativePath: String) -> GitWorkspaceStatusEntry? {
        status.first { $0.path == relativePath || $0.originalPath == relativePath }
    }
}

public enum GitWorkspaceDiffBasis: String, Sendable {
    case workingTree
    case staged
}

public struct GitWorkspaceDiff: Equatable, Sendable {
    public let path: String
    public let basis: GitWorkspaceDiffBasis
    public let text: String
    public let wasTruncated: Bool

    public init(path: String, basis: GitWorkspaceDiffBasis, text: String, wasTruncated: Bool) {
        self.path = path
        self.basis = basis
        self.text = text
        self.wasTruncated = wasTruncated
    }
}

public struct GitWorkspaceBlame: Equatable, Sendable {
    public let path: String
    public let line: Int
    public let commitSHA: String
    public let author: String?
    public let authorTime: Date?
    public let summary: String?

    public init(
        path: String,
        line: Int,
        commitSHA: String,
        author: String?,
        authorTime: Date?,
        summary: String?
    ) {
        self.path = path
        self.line = line
        self.commitSHA = commitSHA
        self.author = author
        self.authorTime = authorTime
        self.summary = summary
    }
}

/// Bounded, read-only Git inspection for the Context IDE.
///
/// This type intentionally exposes only fixed read commands. It does not accept
/// arbitrary Git arguments and therefore cannot commit, checkout, reset, add,
/// clean, stash, merge, rebase, or otherwise mutate repository state.
public struct GitWorkspaceInspector: @unchecked Sendable {
    private let fileManager: FileManager
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int

    public init(
        fileManager: FileManager = .default,
        timeout: TimeInterval = 5,
        maximumOutputBytes: Int = 512_000
    ) {
        self.fileManager = fileManager
        self.timeout = max(0.1, timeout)
        self.maximumOutputBytes = max(4_096, maximumOutputBytes)
    }

    public func snapshot(startingAt location: URL) throws -> GitWorkspaceSnapshot {
        let workingDirectory = directoryForInspection(location)
        let rootResult = try run(
            in: workingDirectory,
            arguments: ["rev-parse", "--show-toplevel"],
            allowNotRepository: true
        )
        guard rootResult.status == 0 else {
            throw GitWorkspaceInspectorError.notRepository(workingDirectory.path)
        }

        let root = rootResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !root.isEmpty else {
            throw GitWorkspaceInspectorError.notRepository(workingDirectory.path)
        }
        let rootURL = URL(fileURLWithPath: root, isDirectory: true)

        let headArguments = ["rev-parse", "HEAD"]
        let head = try successful(
            run(in: rootURL, arguments: headArguments),
            arguments: headArguments
        ).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let branchResult = try run(
            in: rootURL,
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"]
        )
        let detached = branchResult.status != 0
        let branch = detached
            ? nil
            : branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        let statusArguments = ["status", "--porcelain=v1", "-z", "--untracked-files=normal"]
        let statusResult = try successful(
            run(in: rootURL, arguments: statusArguments),
            arguments: statusArguments
        )

        return GitWorkspaceSnapshot(
            repositoryRoot: rootURL.standardizedFileURL.path,
            branch: branch?.isEmpty == true ? nil : branch,
            headSHA: head,
            isDetached: detached,
            status: Self.parsePorcelainV1Z(statusResult.stdoutData),
            statusWasTruncated: statusResult.stdoutWasTruncated
        )
    }

    public func diff(
        startingAt location: URL,
        relativePath: String,
        basis: GitWorkspaceDiffBasis = .workingTree
    ) throws -> GitWorkspaceDiff {
        let snapshot = try snapshot(startingAt: location)
        let root = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
        let normalizedPath = try Self.validateRelativePath(relativePath)

        var arguments = ["diff", "--no-ext-diff", "--no-color", "--unified=3"]
        if basis == .staged { arguments.append("--cached") }
        arguments += ["--", normalizedPath]

        let result = try successful(
            run(in: root, arguments: arguments),
            arguments: arguments
        )
        return GitWorkspaceDiff(
            path: normalizedPath,
            basis: basis,
            text: result.stdout,
            wasTruncated: result.stdoutWasTruncated
        )
    }

    public func fileHistory(
        startingAt location: URL,
        relativePath: String,
        limit: Int = 20
    ) throws -> [String] {
        let snapshot = try snapshot(startingAt: location)
        let root = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
        let normalizedPath = try Self.validateRelativePath(relativePath)
        let boundedLimit = min(max(limit, 1), 100)
        let arguments = [
            "log", "--no-color", "--date=iso-strict",
            "--format=%H%x09%ad%x09%s", "-n", "\(boundedLimit)", "--", normalizedPath
        ]
        let result = try successful(run(in: root, arguments: arguments), arguments: arguments)
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    /// Returns the exact blob identity for `HEAD:path`, or nil when that path is
    /// not represented by a blob at HEAD. Callers must still check working-tree
    /// status before using this as the identity of the current on-disk content.
    public func headBlobIdentity(
        startingAt location: URL,
        relativePath: String
    ) throws -> String? {
        let snapshot = try snapshot(startingAt: location)
        let root = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
        let normalizedPath = try Self.validateRelativePath(relativePath)
        guard snapshot.statusEntry(for: normalizedPath) == nil else { return nil }

        let arguments = ["rev-parse", "HEAD:\(normalizedPath)"]
        let result = try run(in: root, arguments: arguments)
        guard result.status == 0 else { return nil }
        let identity = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return identity.isEmpty ? nil : identity
    }

    public func blame(
        startingAt location: URL,
        relativePath: String,
        line: Int
    ) throws -> GitWorkspaceBlame? {
        guard line > 0 else { return nil }
        let snapshot = try snapshot(startingAt: location)
        let root = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
        let normalizedPath = try Self.validateRelativePath(relativePath)
        let arguments = [
            "blame", "--porcelain", "-L", "\(line),\(line)", "--", normalizedPath
        ]
        let result = try run(in: root, arguments: arguments)
        guard result.status == 0 else { return nil }
        return Self.parseBlamePorcelain(
            result.stdout,
            path: normalizedPath,
            requestedLine: line
        )
    }

    private func directoryForInspection(_ location: URL) -> URL {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: location.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            return location.deletingLastPathComponent().standardizedFileURL
        }
        return location.standardizedFileURL
    }

    private static func validateRelativePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.split(separator: "/").contains("..") else {
            throw GitWorkspaceInspectorError.gitUnavailable("Refusing non-relative inspection path: \(path)")
        }
        return trimmed
    }

    private struct CommandResult {
        let status: Int32
        let stdoutData: Data
        let stderrData: Data
        let stdoutWasTruncated: Bool

        var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
        var stderr: String { String(decoding: stderrData, as: UTF8.self) }
    }

    /// Retains at most `limit` bytes while callers continue draining the pipe to
    /// EOF. Keeping the drain separate from retention avoids the classic pipe
    /// deadlock without letting an unexpectedly large diff/status grow memory
    /// without bound.
    private final class BoundedDataBox: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var value = Data()
        private var wasTruncated = false

        init(limit: Int) {
            self.limit = max(0, limit)
        }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }

            let remaining = max(0, limit - value.count)
            if remaining > 0 {
                value.append(contentsOf: chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                wasTruncated = true
            }
        }

        func snapshot() -> (data: Data, wasTruncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (value, wasTruncated)
        }
    }

    private static func drain(_ handle: FileHandle, into box: BoundedDataBox) {
        while true {
            let chunk = handle.readData(ofLength: 64 * 1024)
            guard !chunk.isEmpty else { return }
            box.append(chunk)
        }
    }

    private func run(
        in workingDirectory: URL,
        arguments: [String],
        allowNotRepository: Bool = false
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", workingDirectory.path] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging([
            "LC_ALL": "C",
            "LANG": "C",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0"
        ]) { _, new in new }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBox = BoundedDataBox(limit: maximumOutputBytes)
        let stderrBox = BoundedDataBox(limit: min(maximumOutputBytes, 64_000))
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            Self.drain(stdoutPipe.fileHandleForReading, into: stdoutBox)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            Self.drain(stderrPipe.fileHandleForReading, into: stderrBox)
            group.leave()
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForWriting.closeFile()
            stderrPipe.fileHandleForWriting.closeFile()
            group.wait()
            throw GitWorkspaceInspectorError.gitUnavailable(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                process.interrupt()
            }
            process.waitUntilExit()
            group.wait()
            throw GitWorkspaceInspectorError.timedOut(arguments: arguments)
        }

        process.waitUntilExit()
        group.wait()

        let stdout = stdoutBox.snapshot()
        let stderr = stderrBox.snapshot()
        let result = CommandResult(
            status: process.terminationStatus,
            stdoutData: stdout.data,
            stderrData: stderr.data,
            stdoutWasTruncated: stdout.wasTruncated
        )

        if allowNotRepository { return result }
        return result
    }

    private func successful(_ result: CommandResult, arguments: [String]) throws -> CommandResult {
        guard result.status == 0 else {
            throw GitWorkspaceInspectorError.commandFailed(
                arguments: arguments,
                status: result.status,
                stderr: result.stderr
            )
        }
        return result
    }

    static func parsePorcelainV1Z(_ data: Data) -> [GitWorkspaceStatusEntry] {
        let tokens = nullSeparatedFields(data)
        var rows: [GitWorkspaceStatusEntry] = []
        var index = 0

        while index < tokens.count {
            let record = String(decoding: tokens[index], as: UTF8.self)
            index += 1
            guard record.count >= 3 else { continue }

            let chars = Array(record)
            let indexStatus = chars[0]
            let workTreeStatus = chars[1]
            let path = String(record.dropFirst(3))
            guard !path.isEmpty else { continue }

            var originalPath: String?
            if indexStatus == "R" || indexStatus == "C" || workTreeStatus == "R" || workTreeStatus == "C" {
                if index < tokens.count {
                    originalPath = String(decoding: tokens[index], as: UTF8.self)
                    index += 1
                }
            }

            rows.append(
                GitWorkspaceStatusEntry(
                    indexStatus: indexStatus,
                    workTreeStatus: workTreeStatus,
                    path: path,
                    originalPath: originalPath
                )
            )
        }
        return rows
    }

    /// Foundation's `Data` conforms to both `Sequence` and `Collection`. Swift
    /// 6.3 can therefore consider both generic `split` overloads equally valid
    /// for a NUL-delimited byte buffer. Parse bytes directly so this protocol
    /// representation detail cannot become a compiler-version compatibility
    /// boundary for porcelain-v1 `-z` status output.
    private static func nullSeparatedFields(_ data: Data) -> [Data] {
        var fields: [Data] = []
        var current: [UInt8] = []
        current.reserveCapacity(min(data.count, 256))

        for byte in data {
            if byte == 0 {
                if !current.isEmpty {
                    fields.append(Data(current))
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty {
            fields.append(Data(current))
        }
        return fields
    }

    static func parseBlamePorcelain(
        _ text: String,
        path: String,
        requestedLine: Int
    ) -> GitWorkspaceBlame? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first else { return nil }
        let headerParts = header.split(separator: " ")
        guard let shaPart = headerParts.first else { return nil }
        let sha = String(shaPart)
        guard sha.count >= 7 else { return nil }

        var author: String?
        var authorTime: Date?
        var summary: String?
        for line in lines.dropFirst() {
            if line.hasPrefix("author ") {
                author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time "),
                      let seconds = TimeInterval(line.dropFirst("author-time ".count)) {
                authorTime = Date(timeIntervalSince1970: seconds)
            } else if line.hasPrefix("summary ") {
                summary = String(line.dropFirst("summary ".count))
            }
        }

        return GitWorkspaceBlame(
            path: path,
            line: requestedLine,
            commitSHA: sha,
            author: author,
            authorTime: authorTime,
            summary: summary
        )
    }
}
