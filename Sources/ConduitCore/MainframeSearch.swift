import Foundation

public enum MainframeSearchHitKind: String, Sendable {
    case path
    case heading
    case content
}

public struct MainframeSearchHit: Identifiable, Equatable, Sendable {
    public var id: String { "\(path):\(kind.rawValue):\(line):\(excerpt)" }
    public let path: String
    public let line: Int
    public let excerpt: String
    public let kind: MainframeSearchHitKind
    public let score: Int

    public init(path: String, line: Int, excerpt: String, kind: MainframeSearchHitKind, score: Int) {
        self.path = path
        self.line = line
        self.excerpt = excerpt
        self.kind = kind
        self.score = score
    }
}

public struct MainframeSearchResult: Sendable {
    public let hits: [MainframeSearchHit]
    public let mayBeIncomplete: Bool

    public init(hits: [MainframeSearchHit], mayBeIncomplete: Bool) {
        self.hits = hits
        self.mayBeIncomplete = mayBeIncomplete
    }
}

public enum MainframeTextSearch {
    public static func search(_ index: MainframeContentIndex, query: String, limit: Int = 200) -> MainframeSearchResult {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return MainframeSearchResult(hits: [], mayBeIncomplete: index.mayBeIncomplete) }
        let lowered = needle.lowercased()
        var hits: [MainframeSearchHit] = []

        for record in index.records {
            let lowerName = record.name.lowercased()
            let lowerPath = record.path.lowercased()
            if lowerName == lowered {
                hits.append(MainframeSearchHit(path: record.path, line: 0, excerpt: record.path, kind: .path, score: 0))
            } else if lowerName.contains(lowered) || lowerPath.contains(lowered) {
                hits.append(MainframeSearchHit(path: record.path, line: 0, excerpt: record.path, kind: .path, score: 10))
            }

            if let markdown = record.markdown {
                for heading in markdown.headings where heading.text.localizedCaseInsensitiveContains(needle) {
                    hits.append(MainframeSearchHit(path: record.path, line: heading.line, excerpt: heading.text, kind: .heading, score: 20))
                }
            }

            var contentHits = 0
            let lines = record.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, rawLine) in lines.enumerated() {
                guard contentHits < 3 else { break }
                let line = String(rawLine)
                if line.localizedCaseInsensitiveContains(needle) {
                    let excerpt = compactExcerpt(line, needle: needle)
                    hits.append(MainframeSearchHit(path: record.path, line: offset + 1, excerpt: excerpt, kind: .content, score: 30))
                    contentHits += 1
                }
            }
        }

        let sorted = hits.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            if $0.path != $1.path { return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            if $0.line != $1.line { return $0.line < $1.line }
            return $0.excerpt < $1.excerpt
        }
        return MainframeSearchResult(hits: Array(sorted.prefix(max(1, limit))), mayBeIncomplete: index.mayBeIncomplete)
    }

    private static func compactExcerpt(_ line: String, needle: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 180 else { return trimmed }
        let lower = trimmed.lowercased()
        guard let range = lower.range(of: needle.lowercased()) else { return String(trimmed.prefix(180)) + "…" }
        let distance = lower.distance(from: lower.startIndex, to: range.lowerBound)
        let start = max(0, distance - 60)
        let end = min(trimmed.count, start + 180)
        let startIndex = trimmed.index(trimmed.startIndex, offsetBy: start)
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: end)
        return (start > 0 ? "…" : "") + String(trimmed[startIndex..<endIndex]) + (end < trimmed.count ? "…" : "")
    }
}

public struct MainframeRecentNavigation: Equatable, Sendable {
    public private(set) var paths: [String] = []
    public let limit: Int

    public init(limit: Int = 20) {
        self.limit = max(1, limit)
    }

    public mutating func note(_ path: String) {
        guard !path.isEmpty else { return }
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > limit { paths.removeLast(paths.count - limit) }
    }
}
