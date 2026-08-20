import Foundation

/// Shared Conversation-shaped effects from any structured adapter.
///
/// Codex still has its own `CodexAppServerEffect`. New adapters emit this
/// envelope. TerminalRuntime maps both onto the same Conversation path.
public enum StructuredAdapterEffect: Equatable, Sendable {
    case sessionStarted(id: String)
    case upsertOutput(text: String, state: AgentOutputState)
    case requestApproval(id: String, summary: String)
    case turnCompleted(status: String)
    case failed(String)
}

public struct StructuredAdapterDescriptor: Equatable, Sendable {
    public let match: String
    public let backend: AgentSessionBackend
    public let surface: String
    public let launch: String
    public let resume: String
    public let status: String
    public let ptyFallback: Bool
    public let notes: String

    public init(
        match: String,
        backend: AgentSessionBackend,
        surface: String,
        launch: String,
        resume: String,
        status: String,
        ptyFallback: Bool,
        notes: String
    ) {
        self.match = match
        self.backend = backend
        self.surface = surface
        self.launch = launch
        self.resume = resume
        self.status = status
        self.ptyFallback = ptyFallback
        self.notes = notes
    }

    public var payload: [String: Any] {
        [
            "match": match,
            "backend": backend.workSessionLabel,
            "surface": surface,
            "launch": launch,
            "resume": resume,
            "status": status,
            "pty_fallback": ptyFallback,
            "notes": notes,
        ]
    }
}

/// Static catalog of first-party surfaces Conduit can host. Gemini CLI ACP
/// needs GEMINI_API_KEY; oauth-personal Code Assist stays ineligible.
public enum StructuredAdapterCatalog {
    public static let entries: [StructuredAdapterDescriptor] = [
        StructuredAdapterDescriptor(
            match: "codex",
            backend: .appServer,
            surface: "codex app-server stdio",
            launch: "codex app-server",
            resume: "thread/resume",
            status: "preferred",
            ptyFallback: true,
            notes: "D-038. Unix listen + proxy is experimental."
        ),
        StructuredAdapterDescriptor(
            match: "grok",
            backend: .acp,
            surface: "ACP stdio",
            launch: "grok agent --no-leader stdio",
            resume: "session/load",
            status: "preferred",
            ptyFallback: true,
            notes: "Never pass --always-approve. Isolation is --no-leader."
        ),
        StructuredAdapterDescriptor(
            match: "opencode",
            backend: .httpServer,
            surface: "HTTP + SSE",
            launch: "one leased opencode serve",
            resume: "GET /session/:id",
            status: "preferred",
            ptyFallback: true,
            notes: "Server ≠ session. Gemini and Ollama are model backends."
        ),
        StructuredAdapterDescriptor(
            match: "claude",
            backend: .structuredCli,
            surface: "stream-json print mode",
            launch: "claude -p --output-format stream-json --verbose",
            resume: "claude -r <session_id>",
            status: "preferred",
            ptyFallback: true,
            notes: "--verbose is required. Do not skip permissions."
        ),
        StructuredAdapterDescriptor(
            match: "agy",
            backend: .structuredCli,
            surface: "stream-json print mode",
            launch: "agy -p --output-format stream-json",
            resume: "agy --conversation <id>",
            status: "preferred",
            ptyFallback: true,
            notes: "Antigravity CLI. Disposable process per turn."
        ),
        StructuredAdapterDescriptor(
            match: "gemini",
            backend: .acp,
            surface: "ACP stdio",
            launch: "gemini --acp",
            resume: "session/load",
            status: "preferred",
            ptyFallback: true,
            notes: "Requires GEMINI_API_KEY. oauth-personal Code Assist stays ineligible. Do not pair with agy on the same task."
        ),
        StructuredAdapterDescriptor(
            match: "shell",
            backend: .pty,
            surface: "SwiftTerm PTY",
            launch: "/bin/zsh -l",
            resume: "tmux when restoreSessions",
            status: "pty-only",
            ptyFallback: false,
            notes: "No structured adapter."
        ),
    ]

    public static func backend(for profile: AgentProfile) -> AgentSessionBackend {
        backend(command: profile.commandBasename, name: profile.name)
    }

    public static func backend(command: String, name: String) -> AgentSessionBackend {
        let commandName = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let profileName = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if commandName == "codex" || profileName == "codex" {
            return .appServer
        }
        if commandName == "grok" || profileName == "grok" {
            return .acp
        }
        if commandName == "opencode" || profileName == "opencode" {
            return .httpServer
        }
        if commandName == "claude" || profileName.contains("claude") {
            return .structuredCli
        }
        if commandName == "agy"
            || commandName.contains("antigravity")
            || profileName.contains("antigravity") {
            return .structuredCli
        }
        if commandName == "gemini" || profileName.contains("gemini") {
            return .acp
        }
        return .pty
    }

    public static func descriptor(matching token: String) -> StructuredAdapterDescriptor? {
        let needle = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return entries.first { entry in
            needle == entry.match
                || needle.contains(entry.match)
                || entry.match.contains(needle)
        }
    }
}

public enum StreamJSONFlavor: String, Equatable, Sendable {
    case claude
    case antigravity

    public static func from(profile: AgentProfile) -> StreamJSONFlavor? {
        let commandName = profile.commandBasename
        let profileName = profile.name.lowercased()
        if commandName == "claude" || profileName.contains("claude") {
            return .claude
        }
        if commandName == "agy"
            || commandName.contains("antigravity")
            || profileName.contains("antigravity") {
            return .antigravity
        }
        return nil
    }
}
