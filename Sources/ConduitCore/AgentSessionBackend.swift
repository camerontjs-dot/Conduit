import Foundation

/// How Conduit hosts one agent session.
///
/// PTY is the compatibility host for TUI CLIs. Structured cases bind the
/// richest first-party surface that agent already exposes (D-038, D-040).
public enum AgentSessionBackend: String, Codable, Equatable, Sendable {
    case pty
    case appServer
    case acp
    case httpServer
    case structuredCli

    public var displayName: String {
        switch self {
        case .pty: return "PTY"
        case .appServer: return "app-server"
        case .acp: return "ACP"
        case .httpServer: return "HTTP server"
        case .structuredCli: return "stream-json"
        }
    }

    public var workSessionLabel: String {
        switch self {
        case .pty: return "pty"
        case .appServer: return "app-server"
        case .acp: return "acp"
        case .httpServer: return "http-server"
        case .structuredCli: return "structured-cli"
        }
    }

    public var isStructured: Bool {
        self != .pty
    }

    public var requestedBackendDescription: String {
        switch self {
        case .pty: return "direct PTY"
        case .appServer: return "codex app-server"
        case .acp: return "ACP stdio"
        case .httpServer: return "opencode serve HTTP"
        case .structuredCli: return "stream-json CLI"
        }
    }

    public var surfaceDescription: String {
        switch self {
        case .pty: return "SwiftTerm PTY / tmux"
        case .appServer: return "codex app-server JSON-RPC (stdio)"
        case .acp: return "Agent Client Protocol stdio"
        case .httpServer: return "OpenCode HTTP + SSE"
        case .structuredCli: return "CLI --output-format stream-json"
        }
    }
}

public extension AgentProfile {
    /// Basename of the configured executable, lowercased.
    var commandBasename: String {
        URL(fileURLWithPath: command).lastPathComponent.lowercased()
    }

    /// Codex prefers app-server. Grok, OpenCode, Claude, and Antigravity bind
    /// their probed first-party surfaces (D-040). Everyone else stays PTY.
    var preferredSessionBackend: AgentSessionBackend {
        StructuredAdapterCatalog.backend(for: self)
    }

    var prefersStructuredHost: Bool {
        preferredSessionBackend.isStructured
    }
}
