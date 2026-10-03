import Foundation

/// How Conduit passes a selected model to an agent CLI at process launch.
///
/// ``auto`` keeps the profile generic while still supporting the common
/// ``--model <id>`` convention. Ollama is the one deliberate exception: its
/// model is a positional argument to ``ollama run``.
public enum AgentModelLaunchStyle: String, Codable, CaseIterable, Sendable {
    case auto
    case modelFlag
    case ollamaRun
    case none

    public var displayName: String {
        switch self {
        case .auto: return "Automatic"
        case .modelFlag: return "--model flag"
        case .ollamaRun: return "Ollama run model"
        case .none: return "No model selection"
        }
    }
}

/// One model discovered from an agent's own CLI or configured provider.
///
/// The context limit is optional because many CLIs expose model IDs without
/// exposing their limits. Conduit must show that uncertainty instead of
/// inventing a quota or context size.
public struct AgentModelOption: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let detail: String?
    public let contextWindowTokens: Int?

    public init(
        id: String,
        displayName: String? = nil,
        detail: String? = nil,
        contextWindowTokens: Int? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.detail = detail
        self.contextWindowTokens = contextWindowTokens
    }
}

/// A small, deliberately approximate visible-context budget estimate.
///
/// This counts text Conduit can see in its retained Conversation projection
/// and the current composer. It is not provider token accounting: hidden system
/// prompts, tool payloads, cache rules, and TUI-only state remain unknown.
public enum VisibleContextEstimator {
    public static func approximateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        // Four UTF-8 bytes is a conservative, provider-neutral display scale;
        // the UI labels the result as an estimate rather than a token count.
        return max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
    }

    public static func visibleTokens(
        events: [SessionPresentationEvent],
        composerText: String
    ) -> Int {
        var visibleText = composerText
        for event in events {
            switch event.kind {
            case .sessionOpened, .interruptRequested, .providerTurnFailed:
                break
            case .userPrompt(let prompt):
                visibleText.append("\n")
                visibleText.append(prompt.text)
                if !prompt.attachmentPaths.isEmpty {
                    visibleText.append("\n")
                    visibleText.append(prompt.attachmentPaths.joined(separator: "\n"))
                }
            case .agentOutput(let output):
                visibleText.append("\n")
                visibleText.append(output.text)
            }
        }
        return approximateTokens(visibleText)
    }
}
