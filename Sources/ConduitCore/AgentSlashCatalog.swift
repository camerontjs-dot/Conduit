import Foundation

/// Slash / skill command candidates for the Conversation composer.
///
/// These are presentation helpers for agent CLI surfaces (Claude Code, Codex,
/// etc.). Selecting one injects the command into the live PTY the same way Raw
/// typing would — it is not a Conduit host-envelope prompt.
public struct AgentSlashCommand: Equatable, Identifiable, Sendable {
    public var id: String { command }
    public let command: String
    public let summary: String
    public let source: Source

    public enum Source: String, Equatable, Sendable {
        case builtin
        case projectSkill
        case userSkill
    }

    public init(command: String, summary: String, source: Source) {
        self.command = command.hasPrefix("/") ? command : "/\(command)"
        self.summary = summary
        self.source = source
    }
}

public enum AgentSlashCatalog {
    /// Built-in commands common across coding-agent CLIs.
    public static let builtin: [AgentSlashCommand] = [
        .init(command: "/compact", summary: "Compact conversation context", source: .builtin),
        .init(command: "/clear", summary: "Clear session context", source: .builtin),
        .init(command: "/help", summary: "Show CLI help", source: .builtin),
        .init(command: "/model", summary: "Choose model", source: .builtin),
        .init(command: "/cost", summary: "Show usage / cost", source: .builtin),
        .init(command: "/status", summary: "Show session status", source: .builtin),
        .init(command: "/memory", summary: "Memory commands", source: .builtin),
        .init(command: "/init", summary: "Initialize project config", source: .builtin),
        .init(command: "/review", summary: "Review changes", source: .builtin),
        .init(command: "/diff", summary: "Show diff", source: .builtin),
        .init(command: "/commit", summary: "Commit workflow", source: .builtin),
        .init(command: "/pr", summary: "Pull request workflow", source: .builtin),
        .init(command: "/bug", summary: "File a bug / feedback", source: .builtin),
        .init(command: "/doctor", summary: "Diagnostics", source: .builtin),
        .init(command: "/login", summary: "Authenticate", source: .builtin),
        .init(command: "/logout", summary: "Sign out", source: .builtin),
        .init(command: "/vim", summary: "Toggle vim mode", source: .builtin),
        .init(command: "/terminal", summary: "Terminal mode", source: .builtin),
        .init(command: "/exit", summary: "Exit agent", source: .builtin),
    ]

    /// True when the composer text is a slash command (optional args), not prose.
    public static func looksLikeSlashCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return false }
        // First token is /command; allow args after whitespace.
        let first = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? trimmed
        guard first.count > 1 else { return false }
        // Reject paths like "/Users/..." that operators paste as prose.
        if first.hasPrefix("/Users") || first.hasPrefix("/home") || first.hasPrefix("/tmp")
            || first.hasPrefix("/var") || first.hasPrefix("/etc") || first.hasPrefix("/opt")
        {
            return false
        }
        // Command token: /word or /word-word
        return first.range(of: #"^/[A-Za-z][A-Za-z0-9_-]*$"#, options: .regularExpression) != nil
    }

    /// Prefix used for filtering (text from first `/` through first whitespace).
    public static func filterPrefix(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        // Only offer completions for the first token while still on that token
        // (no trailing completed args).
        if trimmed.contains(where: { $0.isWhitespace }) {
            // Allow filtering only when the caret would be on a single token;
            // composer is whole-string for now — hide once args started.
            return nil
        }
        return trimmed
    }

    public static func matches(
        query: String,
        projectPath: URL?,
        homeDirectory: URL = ConduitInstanceConfiguration.current.isQualification ? ConduitInstanceConfiguration.current.stateDirectory : FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [AgentSlashCommand] {
        guard let prefix = filterPrefix(in: query) else { return [] }
        let lowered = prefix.lowercased()
        var seen = Set<String>()
        var results: [AgentSlashCommand] = []

        func add(_ item: AgentSlashCommand) {
            let key = item.command.lowercased()
            guard !seen.contains(key) else { return }
            guard key.hasPrefix(lowered) else { return }
            seen.insert(key)
            results.append(item)
        }

        for item in discoverSkills(
            projectPath: projectPath,
            homeDirectory: homeDirectory,
            fileManager: fileManager
        ) {
            add(item)
        }
        for item in builtin {
            add(item)
        }
        return results.sorted {
            if $0.command.count != $1.command.count {
                return $0.command.count < $1.command.count
            }
            return $0.command.localizedCaseInsensitiveCompare($1.command)
                == .orderedAscending
        }
    }

    /// Discovers skill / command markdown under common agent config layouts.
    public static func discoverSkills(
        projectPath: URL?,
        homeDirectory: URL = ConduitInstanceConfiguration.current.isQualification ? ConduitInstanceConfiguration.current.stateDirectory : FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [AgentSlashCommand] {
        var roots: [(URL, AgentSlashCommand.Source)] = []
        if let projectPath {
            roots.append((
                projectPath.appendingPathComponent(".claude/commands", isDirectory: true),
                .projectSkill
            ))
            roots.append((
                projectPath.appendingPathComponent(".claude/skills", isDirectory: true),
                .projectSkill
            ))
            roots.append((
                projectPath.appendingPathComponent(".agents/skills", isDirectory: true),
                .projectSkill
            ))
        }
        roots.append((
            homeDirectory.appendingPathComponent(".claude/commands", isDirectory: true),
            .userSkill
        ))
        roots.append((
            homeDirectory.appendingPathComponent(".claude/skills", isDirectory: true),
            .userSkill
        ))

        var found: [AgentSlashCommand] = []
        for (root, source) in roots {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir),
                  isDir.boolValue
            else { continue }

            guard let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                if entry.pathExtension.lowercased() == "md" {
                    let name = entry.deletingPathExtension().lastPathComponent
                    guard !name.isEmpty else { continue }
                    found.append(
                        AgentSlashCommand(
                            command: "/\(name)",
                            summary: summary(fromMarkdown: entry, fileManager: fileManager)
                                ?? "Project command",
                            source: source
                        )
                    )
                    continue
                }
                var entryIsDir: ObjCBool = false
                guard fileManager.fileExists(
                    atPath: entry.path,
                    isDirectory: &entryIsDir
                ), entryIsDir.boolValue else { continue }
                let skillFile = entry.appendingPathComponent("SKILL.md")
                let name = entry.lastPathComponent
                guard !name.isEmpty else { continue }
                found.append(
                    AgentSlashCommand(
                        command: "/\(name)",
                        summary: summary(fromMarkdown: skillFile, fileManager: fileManager)
                            ?? "Skill",
                        source: source
                    )
                )
            }
        }
        return found
    }

    private static func summary(
        fromMarkdown url: URL,
        fileManager: FileManager
    ) -> String? {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        // Prefer YAML description: then first markdown heading, then first line.
        if let desc = frontmatterValue(text, key: "description"), !desc.isEmpty {
            return String(desc.prefix(120))
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                let title = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return String(title.prefix(120)) }
            }
            if !trimmed.isEmpty && !trimmed.hasPrefix("---") {
                return String(trimmed.prefix(120))
            }
        }
        return nil
    }

    private static func frontmatterValue(_ text: String, key: String) -> String? {
        guard text.hasPrefix("---") else { return nil }
        let parts = text.split(separator: "---", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        let block = String(parts[1])
        for line in block.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            var value = trimmed.dropFirst(key.count + 1)
                .trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
    }
}
