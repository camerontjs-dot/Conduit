import Foundation

/// One numbered choice detected in a terminal permission / approval menu.
public struct TerminalMenuOption: Equatable, Sendable, Identifiable {
    public var id: String { key }
    /// Digit or short token sent to the PTY (e.g. "1").
    public let key: String
    /// Human-visible label without the leading number (e.g. "Yes, allow creation").
    public let label: String
    /// True when the line carried a cursor marker such as `>`.
    public let isSelected: Bool
    public let sourceLine: String

    public init(
        key: String,
        label: String,
        isSelected: Bool,
        sourceLine: String
    ) {
        self.key = key
        self.label = label
        self.isSelected = isSelected
        self.sourceLine = sourceLine
    }
}

/// Best-effort detection of interactive numbered menus in rendered terminal text
/// (Antigravity, Claude Code style permission prompts, etc.).
public enum TerminalMenuParser {
    /// Matches optional cursor `>`, optional spaces, a single digit 1–9, then
    /// `.` or `)`, then the label. Examples:
    /// `> 1. Yes, allow creation`
    /// `  2. No, deny creation`
    /// `1) Approve`
    private static let optionPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]*)?([1-9])[.)][ \t]+(.+?)\s*$"#
    )

    public static func options(in text: String) -> [TerminalMenuOption] {
        var found: [TerminalMenuOption] = []
        var seenKeys = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            let ns = line as NSString
            guard let match = optionPattern.firstMatch(
                in: line,
                range: NSRange(location: 0, length: ns.length)
            ),
                match.numberOfRanges >= 3
            else { continue }
            let key = ns.substring(with: match.range(at: 1))
            let label = ns.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seenKeys.insert(key).inserted else { continue }
            let selected = line.trimmingCharacters(in: .whitespaces)
                .hasPrefix(">")
            found.append(
                TerminalMenuOption(
                    key: key,
                    label: label,
                    isSelected: selected,
                    sourceLine: line
                )
            )
        }
        // A single lone numbered line is often a list item, not a menu.
        // Require at least two options or a selected cursor marker.
        if found.count == 1, found[0].isSelected == false {
            return []
        }
        return found
    }

    /// True when the text looks like an interactive permission/menu surface.
    public static func looksLikeInteractiveMenu(_ text: String) -> Bool {
        let options = options(in: text)
        guard !options.isEmpty else { return false }
        let lower = text.lowercased()
        let cues = [
            "allow", "deny", "approve", "reject", "permission",
            "do you want", "proceed", "navigate", "esc to cancel",
            "yes,", "no,", "always allow"
        ]
        if cues.contains(where: { lower.contains($0) }) {
            return true
        }
        return options.count >= 2
    }
}
