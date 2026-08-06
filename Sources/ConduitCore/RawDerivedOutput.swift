import Foundation

/// How Conduit obtained the text shown in one raw-derived conversation block.
///
/// None of these strategies identifies an assistant message, approval, or
/// completion boundary. They describe only a deterministic comparison between
/// two terminal renderings.
public enum RawDerivedOutputStrategy: String, Codable, Equatable, Sendable {
    /// The current rendering retained every baseline line in the same order
    /// and added lines after it.
    case appendedSuffix
    /// A line diff removed unchanged screen chrome and retained changed lines.
    case screenDelta
}

/// One already-rendered terminal snapshot and the surface that produced it.
///
/// Carrying the extraction with the text makes the baseline/current comparison
/// boundary explicit. A tmux pane and SwiftTerm's outer rendered buffer are
/// different sources even when they happen to display similar text.
public struct RawDerivedSnapshot: Equatable, Sendable {
    public let text: String
    public let extraction: AgentOutputExtraction

    public init(
        text: String,
        extraction: AgentOutputExtraction
    ) {
        self.text = text
        self.extraction = extraction
    }
}

/// Why the terminal controller could not provide a rendered snapshot that is
/// safe to compare at a prompt boundary.
public enum RawDerivedCaptureUnavailableReason:
    String,
    Codable,
    Equatable,
    Sendable
{
    /// `tmux capture-pane` failed or timed out.
    case tmuxPaneCaptureFailed
    /// SwiftTerm's active buffer could include scrollback, so it was not used as
    /// a fallback for a tmux pane.
    case renderedFallbackMayIncludeHistory
    /// The terminal had no rendered snapshot available at the boundary.
    case terminalSnapshotUnavailable

    /// Short operator-facing label for Conversation notices.
    public var displayName: String {
        switch self {
        case .tmuxPaneCaptureFailed:
            return "tmux pane capture failed"
        case .renderedFallbackMayIncludeHistory:
            return "rendered fallback may include history"
        case .terminalSnapshotUnavailable:
            return "terminal snapshot unavailable"
        }
    }
}

/// A terminal-controller observation delivered to the Conversation projector.
///
/// Unavailability is first-class: callers must not substitute an empty
/// baseline or silently compare snapshots from different extraction surfaces.
public enum RawDerivedCapture: Equatable, Sendable {
    case available(RawDerivedSnapshot)
    case unavailable(RawDerivedCaptureUnavailableReason)
}

/// Why two rendered snapshots cannot safely produce a derived output block.
public enum RawDerivedOutputUnavailableReason:
    String,
    Codable,
    Equatable,
    Sendable
{
    /// The rendered baseline was empty, so the current screen cannot be
    /// distinguished from content that predated the prompt.
    case baselineUnavailable
    /// The baseline and current snapshot came from different rendered surfaces.
    case extractionChanged
    /// At least one rendering exceeded the reducer's bounded comparison size.
    case comparisonTooLarge
    /// A repaint shared too little stable structure to identify only new lines.
    case noStableAnchor

    /// Short operator-facing label for Conversation notices.
    public var displayName: String {
        switch self {
        case .baselineUnavailable:
            return "empty baseline at prompt boundary"
        case .extractionChanged:
            return "capture surface changed mid-prompt"
        case .comparisonTooLarge:
            return "rendered comparison too large"
        case .noStableAnchor:
            return "no stable screen anchor"
        }
    }
}

/// A strict reduction either yields bounded derived text or declines to make a
/// projection. It never returns the whole current screen as a fallback.
public enum RawDerivedOutputReduction: Equatable, Sendable {
    case output(RawDerivedOutputResult)
    case unavailable(RawDerivedOutputUnavailableReason)
}

public struct RawDerivedOutputResult: Codable, Equatable, Sendable {
    public let text: String
    public let strategy: RawDerivedOutputStrategy
    public let truncated: Bool

    public init(
        text: String,
        strategy: RawDerivedOutputStrategy,
        truncated: Bool
    ) {
        self.text = text
        self.strategy = strategy
        self.truncated = truncated
    }
}

/// Produces conservative, presentation-only text from two rendered terminal
/// buffers.
///
/// Inputs must already be terminal renderings (for example, a SwiftTerm buffer
/// or `tmux capture-pane` result). This reducer deliberately does not parse ANSI
/// or raw PTY byte chunks.
public enum RawDerivedOutputReducer {
    /// Keeps a conversation block compact enough for responsive display and
    /// bounded local persistence while retaining substantial recent output.
    public static let defaultMaximumCharacters = 16_000

    public static let minimumMaximumCharacters = 64

    public static let truncationMarker =
        "[Earlier raw-derived output truncated]\n\n"

    /// Derives the most useful conservative text from a baseline and current
    /// rendered terminal buffer.
    ///
    /// - Parameters:
    ///   - baseline: Rendering captured before prompt delivery.
    ///   - current: Most recent rendering after observed output.
    ///   - promptText: Optional exact prompt text. A complete, line-for-line
    ///     occurrence is removed as terminal echo; partial and wrapped matches
    ///     are left untouched.
    ///   - maximumCharacters: Hard limit, including the truncation marker.
    ///     Must be at least ``minimumMaximumCharacters``.
    public static func derive(
        baseline: RawDerivedSnapshot,
        current: RawDerivedSnapshot,
        promptText: String? = nil,
        maximumCharacters: Int = defaultMaximumCharacters
    ) -> RawDerivedOutputReduction {
        precondition(
            maximumCharacters >= minimumMaximumCharacters,
            "maximumCharacters must be at least \(minimumMaximumCharacters)"
        )

        guard baseline.extraction == current.extraction else {
            return .unavailable(.extractionChanged)
        }

        let baselineLines = canonicalLines(baseline.text)
        let currentLines = canonicalLines(current.text)
        guard !baselineLines.isEmpty else {
            return .unavailable(.baselineUnavailable)
        }

        let candidate: [String]
        let strategy: RawDerivedOutputStrategy

        if hasPrefix(currentLines, baselineLines) {
            candidate = Array(currentLines.dropFirst(baselineLines.count))
            strategy = .appendedSuffix
        } else {
            switch stableScreenDelta(
                baseline: baselineLines,
                current: currentLines
            ) {
            case .available(let delta):
                candidate = delta
                strategy = .screenDelta
            case .unavailable(let reason):
                return .unavailable(reason)
            }
        }

        let withoutEcho = removingExactPromptEcho(
            from: candidate,
            promptText: promptText
        )
        let unbounded = trimBlankEdges(withoutEcho).joined(separator: "\n")
        let bounded = bound(unbounded, maximumCharacters: maximumCharacters)

        return .output(
            RawDerivedOutputResult(
                text: bounded.text,
                strategy: strategy,
                truncated: bounded.truncated
            )
        )
    }

    // A normal SwiftTerm buffer is currently bounded to roughly 500 scrollback
    // rows. Refusing quadratic LCS work beyond this generous ceiling keeps this
    // pure helper predictable for malformed or unexpected input.
    private static let maximumDiffLines = 700

    private enum ScreenDelta {
        case available([String])
        case unavailable(RawDerivedOutputUnavailableReason)
    }

    private static func stableScreenDelta(
        baseline: [String],
        current: [String]
    ) -> ScreenDelta {
        guard baseline.count <= maximumDiffLines,
              current.count <= maximumDiffLines else {
            return .unavailable(.comparisonTooLarge)
        }

        let matches = longestCommonSubsequenceMatches(
            baseline: baseline,
            current: current
        )
        guard !matches.isEmpty else {
            return .unavailable(.noStableAnchor)
        }

        let matchedCurrentIndexes = Set(matches.map(\.current))
        let changed = current.enumerated().compactMap { index, line in
            matchedCurrentIndexes.contains(index) ? nil : line
        }

        // Blank rows alone are not stable chrome. Require a meaningful
        // non-empty anchor, and reject a single incidental match when nearly
        // the whole screen changed.
        let nonEmptyAnchors = matches.reduce(into: 0) { count, match in
            if !current[match.current].isEmpty {
                count += 1
            }
        }
        guard nonEmptyAnchors > 0 else {
            return .unavailable(.noStableAnchor)
        }

        let nonEmptyBaseline = baseline.reduce(into: 0) {
            if !$1.isEmpty { $0 += 1 }
        }
        let nonEmptyCurrent = current.reduce(into: 0) {
            if !$1.isEmpty { $0 += 1 }
        }
        let comparisonSize = max(max(nonEmptyBaseline, nonEmptyCurrent), 1)
        let anchorRatio = Double(nonEmptyAnchors) / Double(comparisonSize)
        guard nonEmptyAnchors >= 2 || anchorRatio >= 0.25 else {
            return .unavailable(.noStableAnchor)
        }

        return .available(changed)
    }

    private struct LineMatch {
        let baseline: Int
        let current: Int
    }

    /// Returns one deterministic longest common subsequence. On equal choices,
    /// advancing the baseline first keeps the result stable around duplicate
    /// status and blank lines.
    private static func longestCommonSubsequenceMatches(
        baseline: [String],
        current: [String]
    ) -> [LineMatch] {
        let rowWidth = current.count + 1
        var lengths = Array(
            repeating: 0,
            count: (baseline.count + 1) * rowWidth
        )

        func index(_ baselineIndex: Int, _ currentIndex: Int) -> Int {
            baselineIndex * rowWidth + currentIndex
        }

        if !baseline.isEmpty, !current.isEmpty {
            for baselineIndex in baseline.indices.reversed() {
                for currentIndex in current.indices.reversed() {
                    if baseline[baselineIndex] == current[currentIndex] {
                        lengths[index(baselineIndex, currentIndex)] =
                            lengths[index(baselineIndex + 1, currentIndex + 1)] + 1
                    } else {
                        lengths[index(baselineIndex, currentIndex)] = max(
                            lengths[index(baselineIndex + 1, currentIndex)],
                            lengths[index(baselineIndex, currentIndex + 1)]
                        )
                    }
                }
            }
        }

        var matches: [LineMatch] = []
        var baselineIndex = 0
        var currentIndex = 0
        while baselineIndex < baseline.count,
              currentIndex < current.count {
            if baseline[baselineIndex] == current[currentIndex] {
                matches.append(
                    LineMatch(
                        baseline: baselineIndex,
                        current: currentIndex
                    )
                )
                baselineIndex += 1
                currentIndex += 1
            } else if lengths[index(baselineIndex + 1, currentIndex)]
                        >= lengths[index(baselineIndex, currentIndex + 1)] {
                baselineIndex += 1
            } else {
                currentIndex += 1
            }
        }
        return matches
    }

    private static func canonicalLines(_ value: String) -> [String] {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.isEmpty else { return [] }

        var lines = normalized
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { trimTrailingHorizontalWhitespace(String($0)) }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        return lines
    }

    private static func trimTrailingHorizontalWhitespace(
        _ value: String
    ) -> String {
        var end = value.endIndex
        while end > value.startIndex {
            let prior = value.index(before: end)
            let character = value[prior]
            guard character == " " || character == "\t" else { break }
            end = prior
        }
        return String(value[..<end])
    }

    private static func hasPrefix(
        _ value: [String],
        _ prefix: [String]
    ) -> Bool {
        guard prefix.count <= value.count else { return false }
        for (index, line) in prefix.enumerated()
        where value[index] != line {
            return false
        }
        return true
    }

    /// Removes only one exact whole-line prompt occurrence. This intentionally
    /// declines to guess through terminal prefixes, wrapping, or cursor redraws.
    private static func removingExactPromptEcho(
        from lines: [String],
        promptText: String?
    ) -> [String] {
        guard let promptText else { return lines }
        let promptLines = trimBlankEdges(canonicalLines(promptText))
        guard !promptLines.isEmpty,
              promptLines.count <= lines.count else {
            return lines
        }

        let lastStart = lines.count - promptLines.count
        for start in 0...lastStart {
            let end = start + promptLines.count
            guard Array(lines[start..<end]) == promptLines else { continue }
            var result = lines
            result.removeSubrange(start..<end)
            // Remove one separator row left directly beside the echo; preserve
            // all other paragraph spacing from the rendered response.
            if start < result.count, result[start].isEmpty {
                result.remove(at: start)
            } else if start > 0, result[start - 1].isEmpty {
                result.remove(at: start - 1)
            }
            return result
        }
        return lines
    }

    private static func trimBlankEdges(_ lines: [String]) -> [String] {
        var start = 0
        var end = lines.count
        while start < end, lines[start].isEmpty {
            start += 1
        }
        while end > start, lines[end - 1].isEmpty {
            end -= 1
        }
        return Array(lines[start..<end])
    }

    private static func bound(
        _ text: String,
        maximumCharacters: Int
    ) -> (text: String, truncated: Bool) {
        guard text.count > maximumCharacters else {
            return (text, false)
        }
        let retainedCount = maximumCharacters - truncationMarker.count
        return (
            truncationMarker + String(text.suffix(retainedCount)),
            true
        )
    }
}
