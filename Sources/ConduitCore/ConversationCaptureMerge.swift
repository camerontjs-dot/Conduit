import Foundation

/// Merges successive Derived-from-Raw projections so ephemeral TUI content
/// (especially thinking/reasoning that vanishes once the final answer paints)
/// can still appear in Conversation.
///
/// Pure presentation hygiene — never invents agent text. Only reuses lines that
/// already appeared in a prior projection for the same prompt capture.
public enum ConversationCaptureMerge {
    public static let thinkingHeader =
        "Thinking (preserved from live terminal; may be incomplete)"

    /// Combine the previous live projection with the newest reduction.
    public static func preservingEphemeral(
        previous: String,
        next: String
    ) -> String {
        let prev = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let fresh = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if prev.isEmpty { return next }
        if fresh.isEmpty { return previous }
        if fresh == prev { return next }
        // Growing / rewritten supersets: prefer the newest full paint.
        if fresh.contains(prev) { return next }

        let prevBody = stripPreservedThinkingWrapper(prev)
        let nextBody = stripPreservedThinkingWrapper(fresh)
        let prevLines = substantiveLines(prevBody)
        let nextLines = substantiveLines(nextBody)
        let nextSet = Set(nextLines.map(normalizeForCompare))

        let orphaned = prevLines.filter { line in
            !nextSet.contains(normalizeForCompare(line))
                && looksLikeEphemeralReasoning(line)
        }
        guard !orphaned.isEmpty else { return next }

        // Avoid double-wrapping if previous already carried a thinking block.
        let thinkingBlock = orphaned.joined(separator: "\n")
        if nextBody.localizedCaseInsensitiveContains(
            String(thinkingBlock.prefix(min(48, thinkingBlock.count)))
        ) {
            return next
        }

        var parts: [String] = [
            thinkingHeader,
            "",
            thinkingBlock,
            "",
            "—",
            "",
            nextBody
        ]
        // Collapse excessive blank runs at the join.
        return parts
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a line looks like intermediate reasoning rather than chrome.
    public static func looksLikeEphemeralReasoning(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 12 else { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix(thinkingHeader.lowercased()) { return false }
        if lower == "—" || lower == "-" { return false }
        // Duration-only thought headers are not content.
        if isThoughtDurationOnly(trimmed) { return false }
        // Keep thought-labeled content and ordinary mid-length prose.
        if lower.hasPrefix("+ thought") || lower.hasPrefix("thought:")
            || lower.hasPrefix("thinking:") || lower.hasPrefix("reasoning:")
        {
            return !isThoughtDurationOnly(trimmed)
        }
        // Generic orphaned prose that is not short chrome.
        if trimmed.count >= 24, !trimmed.hasPrefix("/"), !trimmed.hasPrefix("|") {
            return true
        }
        return false
    }

    public static func isThoughtDurationOnly(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // "+ Thought: 1.0s" / "Thought: 2s" / "thinking… 3s"
        let pattern =
            #"^[\+•\-\s]*(thought|thinking)\s*:?\s*\d+(\.\d+)?\s*s?\s*$"#
        return trimmed.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func stripPreservedThinkingWrapper(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if lines.first?.hasPrefix("Thinking (preserved") == true {
            lines.removeFirst()
            while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeFirst()
            }
            if let sep = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "—"
            }) {
                // Return full text without re-processing nested structure for merge inputs.
                return text
            }
        }
        return text
    }

    private static func substantiveLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeForCompare(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
