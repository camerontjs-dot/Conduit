import Foundation

/// Operator-selected permission posture for an installed CLI agent profile.
///
/// Conduit does not implement agent policy itself. It only injects well-known
/// launch flags so daily-driver sessions are less interrupted by per-tool
/// prompts. Live sessions are unaffected until the next launch/reconnect that
/// creates a fresh process.
public enum AgentPermissionMode: String, Codable, CaseIterable, Sendable {
    /// Launch with the profile's explicit arguments only.
    case agentDefault
    /// Prefer auto-accepting edit/write tools when the CLI supports it.
    case acceptEdits
    /// Auto-approve tool permissions when the CLI offers a skip/yolo mode.
    case fullAuto
    /// Prefer read-only / plan mode when the CLI supports it.
    case plan

    public var displayName: String {
        switch self {
        case .agentDefault: return "Agent default"
        case .acceptEdits: return "Accept edits"
        case .fullAuto: return "Full auto"
        case .plan: return "Plan / read-only"
        }
    }

    public var shortLabel: String {
        switch self {
        case .agentDefault: return "Default"
        case .acceptEdits: return "Edits"
        case .fullAuto: return "Auto"
        case .plan: return "Plan"
        }
    }

    public var help: String {
        switch self {
        case .agentDefault:
            return "No Conduit-injected permission flags. Use the agent CLI’s own defaults and allowlists."
        case .acceptEdits:
            return "Ask less for file edits when the agent supports it. Shell/commands may still prompt."
        case .fullAuto:
            return "Skip tool permission prompts when the agent supports it. Powerful and risky."
        case .plan:
            return "Prefer plan or read-only mode when the agent supports it."
        }
    }
}

/// Resolves profile arguments plus Conduit permission-mode flags for launch.
public enum AgentLaunchArguments {
    /// Effective argv after applying ``AgentProfile/permissionMode``.
    public static func resolved(for profile: AgentProfile) -> [String] {
        merge(base: profile.arguments, extra: flags(for: profile))
    }

    /// Command line tokens Conduit injects for the selected permission mode.
    public static func flags(for profile: AgentProfile) -> [String] {
        guard profile.kind != .shell else { return [] }
        let executable = normalizedExecutable(profile.command)
        switch profile.permissionMode {
        case .agentDefault:
            return []
        case .acceptEdits:
            return acceptEditsFlags(for: executable)
        case .fullAuto:
            return fullAutoFlags(for: executable)
        case .plan:
            return planFlags(for: executable)
        }
    }

    public static func supportsPermissionModes(_ profile: AgentProfile) -> Bool {
        guard profile.kind != .shell else { return false }
        switch normalizedExecutable(profile.command) {
        case "agy", "antigravity", "claude", "gemini", "codex":
            return true
        default:
            return false
        }
    }

    private static func acceptEditsFlags(for executable: String) -> [String] {
        switch executable {
        case "agy", "antigravity":
            return ["--mode", "accept-edits"]
        case "claude":
            return ["--permission-mode", "acceptEdits"]
        case "gemini":
            return ["--approval-mode", "auto_edit"]
        case "codex":
            return ["--full-auto"]
        default:
            return []
        }
    }

    private static func fullAutoFlags(for executable: String) -> [String] {
        switch executable {
        case "agy", "antigravity":
            return ["--dangerously-skip-permissions"]
        case "claude":
            return ["--permission-mode", "bypassPermissions"]
        case "gemini":
            return ["--yolo"]
        case "codex":
            return ["--full-auto"]
        default:
            return []
        }
    }

    private static func planFlags(for executable: String) -> [String] {
        switch executable {
        case "agy", "antigravity":
            return ["--mode", "plan"]
        case "claude":
            return ["--permission-mode", "plan"]
        case "gemini":
            return ["--approval-mode", "plan"]
        default:
            return []
        }
    }

    private static func normalizedExecutable(_ command: String) -> String {
        URL(fileURLWithPath: command).lastPathComponent.lowercased()
    }

    /// Appends extra tokens without duplicating exact consecutive pairs already
    /// present in the base profile arguments.
    private static func merge(base: [String], extra: [String]) -> [String] {
        guard !extra.isEmpty else { return base }
        if extra.count == 2,
           let index = base.firstIndex(of: extra[0]),
           index + 1 < base.count,
           base[index + 1] == extra[1] {
            return base
        }
        if extra.count == 1, base.contains(extra[0]) {
            return base
        }
        return base + extra
    }
}
