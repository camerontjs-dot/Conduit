#if os(macOS)
import AppKit
import AVFoundation
import ConduitCore
import Foundation
import Speech
import SwiftUI

enum TerminalVisualState: String {
    case launching
    case working
    case running
    case detached
    case exited
    case failed

    var label: String {
        switch self {
        case .launching: return "starting"
        case .working: return "output active"
        case .running: return "ready"
        case .detached: return "detached"
        case .exited: return "exited"
        case .failed: return "failed"
        }
    }
}

enum AgentHealthState: String, Sendable {
    case ready
    case warning
    case unavailable

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .unavailable: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .warning: return .orange
        case .unavailable: return .red
        }
    }
}

struct AgentHealthResult: Identifiable, Sendable {
    let id: String
    let name: String
    let state: AgentHealthState
    let detail: String
}

struct ResourceProcessRow: Identifiable, Sendable {
    let id: Int32
    let residentMegabytes: Double
    let command: String
}

struct ResourceSnapshot: Sendable {
    let capturedAt: Date
    let totalMemoryGB: Double
    let usedMemoryGB: Double
    let topProcesses: [ResourceProcessRow]
    let ollamaModels: [String]

    static let empty = ResourceSnapshot(
        capturedAt: .distantPast,
        totalMemoryGB: 0,
        usedMemoryGB: 0,
        topProcesses: [],
        ollamaModels: []
    )
}

struct AgentHealthChecker {
    func check(agents: [AgentProfile], mainframeRoot: URL?) async -> [AgentHealthResult] {
        let commandResults = await BlockingWork.run {
            let resolver = EnvironmentResolver.shared
            resolver.prewarm()
            var results: [AgentHealthResult] = []
            for agent in agents {
                if let path = resolver.resolve(agent.command) {
                    let version = SubprocessRunner.run(path, ["--version"], timeout: 10)
                    let firstLine = version.output
                        .split(separator: "\n", omittingEmptySubsequences: true)
                        .first
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                    let detail = version.timedOut || version.status != 0 || firstLine.isEmpty
                        ? path
                        : "\(path) · \(firstLine)"
                    results.append(AgentHealthResult(
                        id: "agent-\(agent.id.uuidString)",
                        name: agent.name,
                        state: .ready,
                        detail: detail
                    ))
                } else {
                    results.append(AgentHealthResult(
                        id: "agent-\(agent.id.uuidString)",
                        name: agent.name,
                        state: .unavailable,
                        detail: "Command not found: \(agent.command)"
                    ))
                }
            }

            if let tmux = resolver.resolve("tmux") {
                let version = SubprocessRunner.run(tmux, ["-V"], timeout: 5)
                results.append(AgentHealthResult(
                    id: "tmux",
                    name: "Durable sessions",
                    state: .ready,
                    detail: version.output.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            } else {
                results.append(AgentHealthResult(
                    id: "tmux",
                    name: "Durable sessions",
                    state: .warning,
                    detail: "tmux is not installed; Conduit will use direct PTYs."
                ))
            }
            return results
        }

        var results = commandResults
        if let root = mainframeRoot {
            let required = ["00_inbox", "20_live", "30_projects"]
            let missing = required.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
            results.append(AgentHealthResult(
                id: "mainframe",
                name: "MainFrame",
                state: missing.isEmpty ? .ready : .warning,
                detail: missing.isEmpty ? root.path : "Missing: \(missing.joined(separator: ", "))"
            ))
        } else {
            results.append(AgentHealthResult(id: "mainframe", name: "MainFrame", state: .unavailable, detail: "Root not configured"))
        }

        let speech = SFSpeechRecognizer.authorizationStatus()
        results.append(AgentHealthResult(
            id: "speech",
            name: "Speech recognition",
            state: speech == .authorized ? .ready : .warning,
            detail: permissionLabel(speech)
        ))
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        results.append(AgentHealthResult(
            id: "microphone",
            name: "Microphone",
            state: microphone == .authorized ? .ready : .warning,
            detail: permissionLabel(microphone)
        ))
        return results
    }

    private func permissionLabel(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Authorized"
        case .denied: return "Denied in System Settings"
        case .restricted: return "Restricted"
        case .notDetermined: return "Permission will be requested on first use"
        @unknown default: return "Unknown permission state"
        }
    }

    private func permissionLabel(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Authorized"
        case .denied: return "Denied in System Settings"
        case .restricted: return "Restricted"
        case .notDetermined: return "Permission will be requested on first use"
        @unknown default: return "Unknown permission state"
        }
    }
}

struct ResourceService {
    func snapshot() async -> ResourceSnapshot {
        await BlockingWork.run {
            let totalBytes = ProcessInfo.processInfo.physicalMemory
            let vm = SubprocessRunner.run("/usr/bin/vm_stat", [], timeout: 5).output
            let availableBytes = Self.parseAvailableMemory(vm)
            let usedBytes = totalBytes > availableBytes ? totalBytes - availableBytes : 0

            let processOutput = SubprocessRunner.run("/bin/ps", ["-axo", "pid=,rss=,comm="], timeout: 5).output
            let rows = processOutput.split(separator: "\n").compactMap { line -> ResourceProcessRow? in
                let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 3, let pid = Int32(parts[0]), let rss = Double(parts[1]) else { return nil }
                return ResourceProcessRow(id: pid, residentMegabytes: rss / 1024.0, command: String(parts[2]))
            }
            .sorted { $0.residentMegabytes > $1.residentMegabytes }
            .prefix(8)

            var models: [String] = []
            if let ollama = EnvironmentResolver.shared.resolve("ollama") {
                let lines = SubprocessRunner.run(ollama, ["ps"], timeout: 8).output
                    .split(separator: "\n")
                    .dropFirst()
                models = lines.compactMap { $0.split(separator: " ").first.map(String.init) }
            }

            return ResourceSnapshot(
                capturedAt: Date(),
                totalMemoryGB: Double(totalBytes) / 1_073_741_824.0,
                usedMemoryGB: Double(usedBytes) / 1_073_741_824.0,
                topProcesses: Array(rows),
                ollamaModels: models
            )
        }
    }

    func unloadOllamaModels(_ models: [String]) async -> [String] {
        await BlockingWork.run {
            guard let ollama = EnvironmentResolver.shared.resolve("ollama") else {
                return models.isEmpty ? [] : ["ollama executable not found"]
            }
            return models.compactMap { model in
                let result = SubprocessRunner.run(ollama, ["stop", model], timeout: 20)
                return result.status == 0 ? nil : "\(model): \(result.output)"
            }
        }
    }

    private static func parseAvailableMemory(_ output: String) -> UInt64 {
        let pageSize: UInt64 = {
            guard let range = output.range(of: #"page size of ([0-9]+) bytes"#, options: .regularExpression) else { return 4096 }
            let fragment = output[range]
            return UInt64(fragment.split(separator: " ").first(where: { UInt64($0) != nil }) ?? "4096") ?? 4096
        }()
        let availableKeys = ["Pages free", "Pages inactive", "Pages speculative", "Pages purgeable"]
        var pages: UInt64 = 0
        for line in output.split(separator: "\n") {
            guard availableKeys.contains(where: { line.hasPrefix($0) }) else { continue }
            let digits = line.filter(\.isNumber)
            pages += UInt64(digits) ?? 0
        }
        return pages * pageSize
    }
}

/// Captures the Git snapshot for receipts. Runs subprocesses; call it from a
/// background task, never from the main actor.
struct SystemSnapshotService {
    static func gitSummary(at directory: URL) -> String {
        guard let git = EnvironmentResolver.shared.resolve("git") else {
            return "Git executable not found."
        }
        let path = directory.path
        func run(_ arguments: [String]) -> String {
            SubprocessRunner.run(git, ["-C", path] + arguments, timeout: 10)
                .output
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let branch = run(["branch", "--show-current"])
        let status = run(["status", "--short"])
        let head = run(["log", "-1", "--oneline"])
        guard !branch.isEmpty || !status.isEmpty || !head.isEmpty else {
            return "Not a Git repository, or Git state unavailable."
        }
        return "branch: \(branch.isEmpty ? "detached/unknown" : branch)\nhead: \(head.isEmpty ? "unavailable" : head)\nchanges:\n\(status.isEmpty ? "clean" : status)"
    }
}

#endif
