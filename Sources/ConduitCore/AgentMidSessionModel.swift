import Foundation

/// How Conduit can apply a model choice relative to a live runtime.
public enum AgentModelApplyMode: Equatable, Sendable {
    /// No open runtime for this agent — config only for next launch.
    case nextLaunchOnly
    /// Live session can receive a slash command to switch models.
    case liveSlash(String)
    /// Live session exists but this CLI has no known mid-session switch.
    case liveRequiresRelaunch
}

/// Resolves whether a model pick can affect the current PTY or only the next launch.
public enum AgentMidSessionModelPolicy {
    /// Slash command to switch models in a live TUI, when known.
    public static func slashCommand(
        for profile: AgentProfile,
        modelID: String?
    ) -> String? {
        guard profile.kind != .shell else { return nil }
        let executable = URL(fileURLWithPath: profile.command)
            .lastPathComponent
            .lowercased()
        let trimmed = modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (trimmed?.isEmpty == false) ? trimmed : nil

        switch executable {
        case "opencode":
            // OpenCode TUI: `/model provider/model` (or bare `/model` for picker).
            if let model { return "/model \(model)" }
            return "/model"
        case "claude":
            // Claude Code: `/model <id>` when supported by the installed CLI.
            if let model { return "/model \(model)" }
            return "/model"
        case "codex", "gemini", "cursor-agent", "aider", "grok", "agy", "ollama":
            // No reliable mid-session switch known; launch flags only.
            return nil
        default:
            // Conservative try for other agent TUIs that share the /model builtin.
            if let model { return "/model \(model)" }
            return nil
        }
    }

    public static func applyMode(
        for profile: AgentProfile,
        modelID: String?,
        hasLiveRuntime: Bool
    ) -> AgentModelApplyMode {
        guard hasLiveRuntime else { return .nextLaunchOnly }
        if let command = slashCommand(for: profile, modelID: modelID) {
            return .liveSlash(command)
        }
        return .liveRequiresRelaunch
    }
}
