import Foundation

/// How Conduit hosts one agent session.
///
/// PTY is the compatibility host for TUI CLIs. `appServer` is the Codex-only
/// official rich-client transport (D-038).
public enum AgentSessionBackend: String, Codable, Equatable, Sendable {
    case pty
    case appServer

    public var displayName: String {
        switch self {
        case .pty: return "PTY"
        case .appServer: return "app-server"
        }
    }

    public var workSessionLabel: String {
        switch self {
        case .pty: return "pty"
        case .appServer: return "app-server"
        }
    }
}

public extension AgentProfile {
    /// Codex prefers app-server. Every other profile stays PTY-primary.
    var preferredSessionBackend: AgentSessionBackend {
        let commandName = URL(fileURLWithPath: command).lastPathComponent
            .lowercased()
        let profileName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if commandName == "codex" || profileName == "codex" {
            return .appServer
        }
        return .pty
    }
}
