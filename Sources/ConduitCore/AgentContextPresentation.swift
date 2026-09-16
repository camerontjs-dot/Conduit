import Foundation

public extension AgentContextItemChange {
    /// Presentation-friendly aliases for before/after context identities.
    var previous: AgentContextItem { before }
    var current: AgentContextItem { after }
}

public struct AgentContextHandoff: Equatable, Sendable {
    public let recipe: AgentContextRecipe
    public let destinationLabel: String?
    public let sourceAgentLabel: String?
    public let objective: String
    public let bundle: AgentContextBundle
    public let changesSinceLastHandoff: AgentContextDiff?

    public init(
        recipe: AgentContextRecipe = .agentHandoff,
        destinationLabel: String? = nil,
        sourceAgentLabel: String? = nil,
        objective: String,
        bundle: AgentContextBundle,
        changesSinceLastHandoff: AgentContextDiff? = nil
    ) {
        self.recipe = recipe
        self.destinationLabel = destinationLabel
        self.sourceAgentLabel = sourceAgentLabel
        self.objective = objective
        self.bundle = bundle
        self.changesSinceLastHandoff = changesSinceLastHandoff
    }
}

/// Renders an inspectable handoff prompt without claiming that every nominated
/// context item is source truth. The rendered text is a draft. Sending remains
/// an explicit UI/operator action.
public enum AgentContextHandoffRenderer {
    public static func render(_ handoff: AgentContextHandoff) -> String {
        var lines: [String] = []
        lines.append("# Agent context handoff")
        lines.append("")
        if let destination = handoff.destinationLabel, !destination.isEmpty {
            lines.append("Destination: \(destination)")
        }
        if let source = handoff.sourceAgentLabel, !source.isEmpty {
            lines.append("Prior worker: \(source)")
        }
        lines.append("Recipe: \(handoff.recipe.rawValue)")
        lines.append("Objective: \(handoff.objective)")
        lines.append("")
        lines.append("## Exact scope")
        if let scope = handoff.bundle.scopePath { lines.append("- Scope: `\(scope)`") }
        if let repository = handoff.bundle.repository { lines.append("- Repository: `\(repository)`") }
        if let branch = handoff.bundle.branch { lines.append("- Branch: `\(branch)`") }
        if let commit = handoff.bundle.commitSHA { lines.append("- Commit: `\(commit)`") }
        lines.append("")
        lines.append("## Authority boundary")
        lines.append("Treat each item according to its listed authority. MindGraph nominations and agent output are context to inspect, not source truth. Re-check mutable repository/runtime facts before relying on them.")
        lines.append("")
        lines.append("## Context items")
        if handoff.bundle.items.isEmpty {
            lines.append("- none")
        } else {
            for item in handoff.bundle.items {
                var row = "- [\(item.authority.rawValue)] \(item.title) — `\(item.locationLabel)`"
                if let identity = item.revisionIdentity, !identity.isEmpty {
                    row += " @ `\(identity)`"
                }
                if item.isPinned { row += " [operator-pinned]" }
                switch item.freshness {
                case .current:
                    row += " [current]"
                case .stale(let reason):
                    row += " [STALE: \(reason)]"
                case .unknown:
                    row += " [freshness unknown]"
                }
                lines.append(row)
            }
        }

        if let diff = handoff.changesSinceLastHandoff {
            lines.append("")
            lines.append("## Changes since previous context snapshot")
            if diff.isEmpty {
                lines.append("- No context-item identity changes detected.")
            } else {
                for item in diff.added {
                    lines.append("- ADDED: `\(item.locationLabel)`")
                }
                for item in diff.removed {
                    lines.append("- REMOVED: `\(item.locationLabel)`")
                }
                for change in diff.changed {
                    lines.append("- CHANGED: `\(change.after.locationLabel)`")
                }
            }
        }

        lines.append("")
        lines.append("Inspect the actual files, Git state, receipts, and runtime evidence before making consequential claims. Preserve failures and uncertainty.")
        return lines.joined(separator: "\n")
    }
}
