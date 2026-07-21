#if os(macOS)
import AppKit
import AVFoundation
import ConduitCore
import Foundation
import Speech
import SwiftUI

enum TerminalVisualState: String {
    case working
    case running
    case detached
    case exited
    case failed

    var label: String {
        switch self {
        case .working: return "working"
        case .running: return "ready"
        case .detached: return "detached"
        case .exited: return "exited"
        case .failed: return "failed"
        }
    }

    var indicatorColor: Color {
        switch self {
        case .working: return .green
        case .running: return .accentColor
        case .detached: return .orange
        case .exited: return .secondary
        case .failed: return .red
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

struct ActiveWorkSession: Sendable {
    let project: MainframeProject
    let startedAt: Date
}

enum ShellProbe {
    struct Result: Sendable {
        let status: Int32
        let output: String
    }

    static func run(_ command: String) -> Result {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return Result(status: -1, output: error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func resolve(_ command: String) -> String? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        let result = run("command -v \(quote(command))")
        guard result.status == 0 else { return nil }
        let value = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct AgentHealthChecker {
    func check(agents: [AgentProfile], mainframeRoot: URL?) async -> [AgentHealthResult] {
        let commandResults = await Task.detached(priority: .utility) {
            var results: [AgentHealthResult] = []
            for agent in agents {
                if let path = ShellProbe.resolve(agent.command) {
                    let version = ShellProbe.run("\(ShellProbe.quote(path)) --version 2>&1 | head -n 1")
                    let detail = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    results.append(AgentHealthResult(
                        id: "agent-\(agent.id.uuidString)",
                        name: agent.name,
                        state: .ready,
                        detail: detail.isEmpty ? path : "\(path) · \(detail)"
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

            if let tmux = ShellProbe.resolve("tmux") {
                let version = ShellProbe.run("\(ShellProbe.quote(tmux)) -V")
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
        }.value

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
        await Task.detached(priority: .utility) {
            let totalBytes = ProcessInfo.processInfo.physicalMemory
            let vm = ShellProbe.run("/usr/bin/vm_stat").output
            let availableBytes = Self.parseAvailableMemory(vm)
            let usedBytes = totalBytes > availableBytes ? totalBytes - availableBytes : 0

            let processOutput = ShellProbe.run("ps -axo pid=,rss=,comm= | sort -nrk2 | head -n 8").output
            let rows = processOutput.split(separator: "\n").compactMap { line -> ResourceProcessRow? in
                let parts = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count == 3, let pid = Int32(parts[0]), let rss = Double(parts[1]) else { return nil }
                return ResourceProcessRow(id: pid, residentMegabytes: rss / 1024.0, command: String(parts[2]))
            }

            var models: [String] = []
            if ShellProbe.resolve("ollama") != nil {
                let lines = ShellProbe.run("ollama ps").output.split(separator: "\n").dropFirst()
                models = lines.compactMap { $0.split(separator: " ").first.map(String.init) }
            }

            return ResourceSnapshot(
                capturedAt: Date(),
                totalMemoryGB: Double(totalBytes) / 1_073_741_824.0,
                usedMemoryGB: Double(usedBytes) / 1_073_741_824.0,
                topProcesses: rows,
                ollamaModels: models
            )
        }.value
    }

    func unloadOllamaModels(_ models: [String]) async -> [String] {
        await Task.detached(priority: .utility) {
            models.compactMap { model in
                let result = ShellProbe.run("ollama stop \(ShellProbe.quote(model))")
                return result.status == 0 ? nil : "\(model): \(result.output)"
            }
        }.value
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

struct SystemSnapshotService {
    static func gitSummary(at directory: URL) -> String {
        let path = ShellProbe.quote(directory.path)
        let branch = ShellProbe.run("git -C \(path) branch --show-current").output.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = ShellProbe.run("git -C \(path) status --short").output.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = ShellProbe.run("git -C \(path) log -1 --oneline").output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !branch.isEmpty || !status.isEmpty || !head.isEmpty else { return "Not a Git repository, or Git state unavailable." }
        return "branch: \(branch.isEmpty ? "detached/unknown" : branch)\nhead: \(head.isEmpty ? "unavailable" : head)\nchanges:\n\(status.isEmpty ? "clean" : status)"
    }
}

#endif
