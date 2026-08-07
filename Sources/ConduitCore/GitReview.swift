import Foundation

/// One row from `git status --porcelain`.
public struct GitStatusEntry: Equatable, Sendable, Identifiable {
    public var id: String { path + "|" + code }
    public let code: String
    public let path: String

    public init(code: String, path: String) {
        self.code = code
        self.path = path
    }

    public var displayLabel: String {
        switch code.trimmingCharacters(in: .whitespaces) {
        case "M", "MM", "AM": return "modified"
        case "A", "??": return code.contains("?") ? "untracked" : "added"
        case "D": return "deleted"
        case "R": return "renamed"
        default: return code
        }
    }
}

public enum GitReviewParser {
    /// Parses porcelain v1 lines into path entries.
    public static func parsePorcelain(_ text: String) -> [GitStatusEntry] {
        text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> GitStatusEntry? in
                let raw = String(line)
                guard raw.count >= 4 else { return nil }
                let code = String(raw.prefix(2))
                var path = String(raw.dropFirst(3))
                if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
                    path = String(path.dropFirst().dropLast())
                }
                // rename: "old -> new"
                if let arrow = path.range(of: " -> ") {
                    path = String(path[arrow.upperBound...])
                }
                path = path.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { return nil }
                return GitStatusEntry(code: code, path: path)
            }
    }
}

/// Detects absolute file paths in projected terminal text (best-effort).
public enum ProjectedPathDetector {
    public static func detectAbsolutePaths(
        in text: String,
        limit: Int = 24
    ) -> [String] {
        // Conservative: POSIX absolute paths under /Users or /tmp etc.
        let pattern = #"(?<![A-Za-z0-9_])(/Users/[^\s\"'<>|]+|/tmp/[^\s\"'<>|]+|/var/[^\s\"'<>|]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let ns = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: ns.length)
        )
        var seen = Set<String>()
        var out: [String] = []
        for match in matches {
            guard match.numberOfRanges > 0 else { continue }
            var path = ns.substring(with: match.range(at: 1))
            // Trim trailing punctuation common in prose.
            while let last = path.last, ".,);:]".contains(last) {
                path.removeLast()
            }
            if seen.insert(path).inserted {
                out.append(path)
                if out.count >= limit { break }
            }
        }
        return out
    }
}
