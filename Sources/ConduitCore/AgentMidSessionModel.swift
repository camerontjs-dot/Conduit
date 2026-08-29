import Foundation

/// One step in a best-effort live model switch sequence.
public enum AgentModelSwitchStep: Equatable, Sendable {
    /// Type a slash command and press Enter (clears buffer first).
    case slashCommand(String)
    /// Type plain text without Enter (picker filter, etc.).
    case typeText(String)
    /// Press Enter alone.
    case enter
    /// Wait before the next step (seconds).
    case wait(Double)
}

/// How Conduit can apply a model choice relative to a live runtime.
public enum AgentModelApplyMode: Equatable, Sendable {
    /// No open runtime for this agent — config only for next launch.
    case nextLaunchOnly
    /// Live session can receive a typed switch sequence.
    case liveSequence([AgentModelSwitchStep], operatorNote: String)
    /// Live session exists but this CLI has no known mid-session switch.
    case liveRequiresRelaunch
}

/// Resolves whether a model pick can affect the current PTY or only the next launch.
public enum AgentMidSessionModelPolicy {
    public static func applyMode(
        for profile: AgentProfile,
        modelID: String?,
        hasLiveRuntime: Bool
    ) -> AgentModelApplyMode {
        guard hasLiveRuntime else { return .nextLaunchOnly }
        guard profile.kind != .shell else { return .nextLaunchOnly }

        let executable = URL(fileURLWithPath: profile.command)
            .lastPathComponent
            .lowercased()
        let trimmed = modelID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (trimmed?.isEmpty == false) ? trimmed! : nil

        switch executable {
        case "opencode":
            // OpenCode's slash is `/models` (alias `/mo`), which opens a
            // filterable picker — not `/model <id>`. Best-effort: open picker,
            // type the model id (or unique suffix) to filter, Enter to select.
            if let model {
                let filter = openCodeFilterToken(for: model)
                return .liveSequence(
                    [
                        .slashCommand("/models"),
                        .wait(0.55),
                        .typeText(filter),
                        .wait(0.35),
                        .enter
                    ],
                    operatorNote:
                        "OpenCode: opened /models and filtered to \(filter). Confirm footer model in Raw."
                )
            }
            return .liveSequence(
                [.slashCommand("/models")],
                operatorNote:
                    "OpenCode: opened model picker. Choose a model in Raw/TUI."
            )

        case "claude":
            if let model {
                return .liveSequence(
                    [.slashCommand("/model \(model)")],
                    operatorNote:
                        "Claude: sent /model \(model). Confirm in Raw if accepted."
                )
            }
            return .liveSequence(
                [.slashCommand("/model")],
                operatorNote: "Claude: opened /model. Confirm selection in Raw."
            )

        case "grok":
            // Grok documents `/model <name>` (alias `/m`) for mid-session switch.
            if let model {
                return .liveSequence(
                    [.slashCommand("/model \(model)")],
                    operatorNote:
                        "Grok: sent /model \(model). Confirm in Raw if accepted."
                )
            }
            return .liveSequence(
                [.slashCommand("/model")],
                operatorNote: "Grok: opened /model picker. Confirm in Raw."
            )

        case "gemini":
            // Gemini CLI exposes `/model` as a picker command. Passing an id is
            // best-effort; relaunch still applies the --model flag reliably.
            if let model {
                return .liveSequence(
                    [
                        .slashCommand("/model"),
                        .wait(0.4),
                        .typeText(model),
                        .wait(0.25),
                        .enter
                    ],
                    operatorNote:
                        "Gemini: opened /model and typed \(model). Confirm in Raw; relaunch if unchanged."
                )
            }
            return .liveSequence(
                [.slashCommand("/model")],
                operatorNote: "Gemini: opened /model. Confirm selection in Raw."
            )

        case "codex":
            // Codex TUI uses `/model` to open the model picker.
            if let model {
                return .liveSequence(
                    [
                        .slashCommand("/model"),
                        .wait(0.45),
                        .typeText(model),
                        .wait(0.25),
                        .enter
                    ],
                    operatorNote:
                        "Codex: opened /model and filtered to \(model). Confirm in Raw; relaunch if unchanged."
                )
            }
            return .liveSequence(
                [.slashCommand("/model")],
                operatorNote: "Codex: opened /model picker. Confirm in Raw."
            )

        case "agy":
            if let model {
                return .liveSequence(
                    [.slashCommand("/model \(model)")],
                    operatorNote:
                        "Antigravity: sent /model \(model). Confirm in Raw; relaunch if unchanged."
                )
            }
            return .liveSequence(
                [.slashCommand("/model")],
                operatorNote: "Antigravity: opened /model. Confirm in Raw."
            )

        case "cursor-agent", "agent", "aider", "ollama":
            return .liveRequiresRelaunch

        default:
            if let model {
                return .liveSequence(
                    [.slashCommand("/model \(model)")],
                    operatorNote:
                        "Sent /model \(model) as a best-effort switch. Confirm in Raw."
                )
            }
            return .liveRequiresRelaunch
        }
    }

    /// OpenCode filter boxes match substrings; prefer the unique trailing
    /// segment when the id is `provider/name` so typing is short and reliable.
    private static func openCodeFilterToken(for model: String) -> String {
        if let slash = model.lastIndex(of: "/") {
            let tail = String(model[model.index(after: slash)...])
            if !tail.isEmpty, tail.count >= 4 { return tail }
        }
        return model
    }
}
