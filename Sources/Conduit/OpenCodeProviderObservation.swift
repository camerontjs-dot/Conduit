#if os(macOS)
import ConduitCore
import Darwin
import Foundation

/// OpenCode persistence transport for provider-session observation.
///
/// This transport launches only bounded read commands. It never starts
/// `opencode serve`, never resumes a provider session, and has no prompt,
/// interrupt, adoption, or lifecycle-mutation verb.
struct OpenCodeCLIObservationTransport: OpenCodeProviderObservationTransport {
    enum TransportError: Error, LocalizedError {
        case commandFailed(String)
        case timedOut(String)
        case invalidJSON(String)

        var errorDescription: String? {
            switch self {
            case .commandFailed(let message): return message
            case .timedOut(let message): return message
            case .invalidJSON(let message): return message
            }
        }
    }

    let executableURL: URL
    var timeout: TimeInterval = 15

    func listSessionsJSON() throws -> CodexJSON {
        let result = try run(["session", "list", "--format", "json"])
        let trimmed = result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if trimmed.isEmpty {
            return .array([])
        }
        guard let json = CodexJSON.parse(Data(trimmed.utf8)) else {
            throw TransportError.invalidJSON(
                "OpenCode session list did not return JSON."
            )
        }
        return json
    }

    func exportSessionJSON(providerSessionID: String) throws -> CodexJSON {
        // OpenCode 1.x exposes `opencode export <id>`. Newer CLI builds also
        // expose `opencode session export <id>`. Both are read-only; the
        // fallback keeps observation compatible without starting a server.
        let first = try runAllowingFailure([
            "export", providerSessionID, "--sanitize",
        ])
        let result: CommandResult
        if first.status == 0 {
            result = first
        } else {
            let fallback = try runAllowingFailure([
                "session", "export", providerSessionID, "--sanitize",
            ])
            guard fallback.status == 0 else {
                throw TransportError.commandFailed(
                    Self.failureMessage(
                        label: "OpenCode export",
                        result: fallback,
                        prior: first
                    )
                )
            }
            result = fallback
        }

        let trimmed = result.stdout.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty,
              let json = CodexJSON.parse(Data(trimmed.utf8))
        else {
            throw TransportError.invalidJSON(
                "OpenCode export did not return JSON."
            )
        }
        return json
    }

    private struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    private func run(_ arguments: [String]) throws -> CommandResult {
        let result = try runAllowingFailure(arguments)
        guard result.status == 0 else {
            throw TransportError.commandFailed(
                Self.failureMessage(
                    label: "OpenCode observation",
                    result: result,
                    prior: nil
                )
            )
        }
        return result
    }

    private func runAllowingFailure(
        _ arguments: [String]
    ) throws -> CommandResult {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "conduit-opencode-observation-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }

        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }

        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw TransportError.timedOut(
                "OpenCode observation command exceeded \(Int(timeout)) seconds."
            )
        }

        process.waitUntilExit()
        try? stdoutHandle.synchronize()
        try? stderrHandle.synchronize()

        let stdout = (try? String(
            contentsOf: stdoutURL,
            encoding: .utf8
        )) ?? ""
        let stderr = (try? String(
            contentsOf: stderrURL,
            encoding: .utf8
        )) ?? ""
        return CommandResult(
            status: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    private static func failureMessage(
        label: String,
        result: CommandResult,
        prior: CommandResult?
    ) -> String {
        let current = result.stderr
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let earlier = prior?.stderr
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = [earlier, current]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return String(value.prefix(480))
            }
            .joined(separator: " | ")
        return detail.isEmpty
            ? "\(label) failed with exit \(result.status)."
            : "\(label) failed with exit \(result.status): \(detail)"
    }
}
#endif
