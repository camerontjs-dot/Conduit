import Foundation

/// One account rate-limit or budget window reported by a vendor tool.
///
/// Utilization is percent of the vendor window **used** (0–100+), not remaining.
/// Values come from the account/tool itself, never from Conduit PTY observation.
public struct AccountUsageWindow: Equatable, Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let detail: String?

    public init(
        label: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        detail: String? = nil
    ) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.detail = detail
    }

    public var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

/// Snapshot of account-reported usage for one agent identity.
public struct AccountUsageSnapshot: Equatable, Sendable, Identifiable {
    public var id: String { agentName }
    public let agentName: String
    /// Where the numbers came from (for honesty chrome).
    public let sourceLabel: String
    public let windows: [AccountUsageWindow]
    public let notes: [String]
    public let fetchedAt: Date
    public let error: String?

    public init(
        agentName: String,
        sourceLabel: String,
        windows: [AccountUsageWindow] = [],
        notes: [String] = [],
        fetchedAt: Date = Date(),
        error: String? = nil
    ) {
        self.agentName = agentName
        self.sourceLabel = sourceLabel
        self.windows = windows
        self.notes = notes
        self.fetchedAt = fetchedAt
        self.error = error
    }
}

/// Pure parsers for vendor usage payloads (no network / keychain here).
public enum AccountUsageParsing {
    public static func parseClaudeOAuthUsage(
        _ data: Data,
        now: Date = Date()
    ) throws -> AccountUsageSnapshot {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw AccountUsageParseError.invalidJSON
        }
        var windows: [AccountUsageWindow] = []
        if let five = root["five_hour"] as? [String: Any] {
            windows.append(
                window(
                    from: five,
                    label: "5-hour session",
                    fallbackDetail: "Claude Code session window"
                )
            )
        }
        if let week = root["seven_day"] as? [String: Any] {
            windows.append(
                window(
                    from: week,
                    label: "Weekly",
                    fallbackDetail: "Claude Code 7-day window"
                )
            )
        }
        // Optional model-specific windows when present.
        for (key, label) in [
            ("seven_day_opus", "Weekly · Opus"),
            ("seven_day_sonnet", "Weekly · Sonnet"),
        ] {
            if let block = root[key] as? [String: Any] {
                windows.append(window(from: block, label: label, fallbackDetail: nil))
            }
        }
        var notes: [String] = []
        if let extra = root["extra_usage"] as? [String: Any] {
            let enabled = extra["is_enabled"] as? Bool ?? false
            let used = doubleValue(extra["used_credits"]) ?? 0
            let limit = doubleValue(extra["monthly_limit"])
            if enabled, let limit {
                notes.append(
                    String(format: "Extra usage credits: %.0f / %.0f", used, limit)
                )
            } else if let reason = extra["disabled_reason"] as? String, !reason.isEmpty {
                notes.append("Extra usage: \(reason.replacingOccurrences(of: "_", with: " "))")
            }
        }
        if windows.isEmpty {
            throw AccountUsageParseError.missingWindows
        }
        return AccountUsageSnapshot(
            agentName: "Claude",
            sourceLabel: "Anthropic account (Claude Code OAuth)",
            windows: windows,
            notes: notes,
            fetchedAt: now
        )
    }

    public static func parseCodexRateLimits(
        _ data: Data,
        now: Date = Date()
    ) throws -> AccountUsageSnapshot {
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let root = obj as? [String: Any] else {
            throw AccountUsageParseError.invalidJSON
        }
        // Accept either full RPC result or nested rateLimits object.
        let rateLimits: [String: Any]
        if let nested = root["rateLimits"] as? [String: Any] {
            rateLimits = nested
        } else if let result = root["result"] as? [String: Any],
                  let nested = result["rateLimits"] as? [String: Any] {
            rateLimits = nested
        } else {
            rateLimits = root
        }

        var windows: [AccountUsageWindow] = []
        if let primary = rateLimits["primary"] as? [String: Any] {
            windows.append(
                codexWindow(primary, label: "Primary window", now: now)
            )
        }
        if let secondary = rateLimits["secondary"] as? [String: Any] {
            windows.append(
                codexWindow(secondary, label: "Secondary window", now: now)
            )
        }
        var notes: [String] = []
        if let plan = rateLimits["planType"] as? String {
            notes.append("Plan: \(plan)")
        }
        if let credits = rateLimits["credits"] as? [String: Any] {
            if credits["unlimited"] as? Bool == true {
                notes.append("Credits: unlimited")
            } else if let balance = credits["balance"] as? String {
                notes.append("Credits balance: \(balance)")
            }
        }
        if windows.isEmpty {
            throw AccountUsageParseError.missingWindows
        }
        return AccountUsageSnapshot(
            agentName: "Codex",
            sourceLabel: "OpenAI / ChatGPT account (Codex app-server)",
            windows: windows,
            notes: notes,
            fetchedAt: now
        )
    }

    public static func openCodeSnapshot(
        weekTokensIn: Int,
        weekTokensOut: Int,
        weekCost: Double,
        weekSessions: Int,
        allTokensIn: Int,
        allTokensOut: Int,
        allCost: Double,
        allSessions: Int,
        now: Date = Date()
    ) -> AccountUsageSnapshot {
        // Local OpenCode DB has consumption, not remaining subscription pool.
        let weekTotal = weekTokensIn + weekTokensOut
        let notes = [
            String(
                format: "This week: %d sessions · in %@ · out %@ · $%.2f",
                weekSessions,
                formatTokens(weekTokensIn),
                formatTokens(weekTokensOut),
                weekCost
            ),
            String(
                format: "All local sessions: %d · in %@ · out %@ · $%.2f",
                allSessions,
                formatTokens(allTokensIn),
                formatTokens(allTokensOut),
                allCost
            ),
            "OpenCode local DB has usage totals, not remaining Zen/Go pool %.",
        ]
        // Present week token volume as informational bars only when we have data.
        var windows: [AccountUsageWindow] = []
        if weekTotal > 0 {
            // No vendor ceiling — show absolute week activity as a soft bar vs 5M tokens.
            let softCap = 5_000_000.0
            windows.append(
                AccountUsageWindow(
                    label: "Week tokens (local)",
                    usedPercent: min(100, Double(weekTotal) / softCap * 100),
                    resetsAt: nil,
                    detail: "\(formatTokens(weekTotal)) tokens this week (soft scale)"
                )
            )
        }
        return AccountUsageSnapshot(
            agentName: "OpenCode",
            sourceLabel: "OpenCode local database (~/.local/share/opencode)",
            windows: windows,
            notes: notes,
            fetchedAt: now
        )
    }

    public static func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 {
            return String(format: "%.1fM", Double(n) / 1_000_000)
        }
        if n >= 1_000 {
            return String(format: "%.1fK", Double(n) / 1_000)
        }
        return "\(n)"
    }

    private static func window(
        from block: [String: Any],
        label: String,
        fallbackDetail: String?
    ) -> AccountUsageWindow {
        let utilization = doubleValue(block["utilization"]) ?? 0
        // API may report 0–1 or 0–100.
        let percent = utilization <= 1.5 ? utilization * 100 : utilization
        let resets = parseDate(block["resets_at"])
        var detail = fallbackDetail
        if let used = doubleValue(block["used_dollars"]),
           let limit = doubleValue(block["limit_dollars"]) {
            detail = String(format: "$%.2f / $%.2f", used, limit)
        }
        return AccountUsageWindow(
            label: label,
            usedPercent: percent,
            resetsAt: resets,
            detail: detail
        )
    }

    private static func codexWindow(
        _ block: [String: Any],
        label: String,
        now: Date
    ) -> AccountUsageWindow {
        let percent = doubleValue(block["usedPercent"]) ?? 0
        var resets: Date?
        if let ts = doubleValue(block["resetsAt"]) {
            // Codex has used unix seconds.
            resets = Date(timeIntervalSince1970: ts)
        }
        var detail: String?
        if let mins = doubleValue(block["windowDurationMins"]) {
            if mins >= 60 * 24 {
                detail = String(format: "%.0f-day window", mins / (60 * 24))
            } else if mins >= 60 {
                detail = String(format: "%.0f-hour window", mins / 60)
            } else {
                detail = String(format: "%.0f-minute window", mins)
            }
        }
        if let resets {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            detail = [detail, "resets \(formatter.localizedString(for: resets, relativeTo: now))"]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        return AccountUsageWindow(
            label: label,
            usedPercent: percent,
            resetsAt: resets,
            detail: detail
        )
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func parseDate(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }
}

public enum AccountUsageParseError: Error, Equatable {
    case invalidJSON
    case missingWindows
}
