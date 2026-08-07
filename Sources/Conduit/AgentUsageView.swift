#if os(macOS)
import ConduitCore
import SwiftUI

/// Tier A usage surface: Conduit-observed activity plus **operator-set**
/// weekly/session budgets (not vendor token quotas).
struct AgentUsageSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.line)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let rows = model.observedUsageRows(at: context.date)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.agent) { row in
                            usageRow(row, at: context.date)
                            Divider().overlay(palette.lineSoft)
                        }
                    }
                }
            }
            Divider().overlay(palette.line)
            footer
        }
        .frame(minWidth: Self.sheetMinWidth, minHeight: 440)
        .background(palette.canvas)
    }

    private var header: some View {
        ConduitSheetHeader(
            title: "Agent usage",
            subtitle: "Weekly / session limits you set · observed by Conduit",
            systemImage: "chart.bar"
        )
    }

    private func usageRow(_ row: AgentObservedUsage, at date: Date) -> some View {
        let profile = model.settings.agents.first { $0.name == row.agent }
        let budget = profile?.usageBudget ?? AgentUsageBudget()
        let week = model.weekUsage(for: row.agent, at: date)
        let unobserved = row.sessions == 0

        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.liveSessions > 0 ? palette.accent : Color.clear)
                    .frame(width: 6, height: 6)
                Text(row.agent)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(unobserved ? palette.dim : palette.text)
                Spacer(minLength: 8)
                if row.liveSessions > 0 {
                    Text("\(row.liveSessions) live")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(palette.accent)
                }
            }

            if unobserved && !budget.hasAnyLimit {
                Text("no sessions observed · set limits in Settings → Agents")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.faint)
            } else {
                if budget.weeklyPromptLimit > 0 {
                    limitMeter(
                        label: "Week prompts",
                        usedLabel: "\(week.totalPrompts) / \(budget.weeklyPromptLimit)",
                        fraction: AgentUsageMeters.fraction(
                            Double(week.totalPrompts),
                            of: Double(budget.weeklyPromptLimit)
                        )
                    )
                }
                if budget.weeklyAttachedMinutesLimit > 0 {
                    let usedMin = Int(week.attachedSeconds / 60)
                    limitMeter(
                        label: "Week attached",
                        usedLabel: "\(usedMin) / \(budget.weeklyAttachedMinutesLimit) min",
                        fraction: AgentUsageMeters.fraction(
                            Double(usedMin),
                            of: Double(budget.weeklyAttachedMinutesLimit)
                        )
                    )
                }
                if budget.sessionPromptLimit > 0 {
                    limitMeter(
                        label: "This session",
                        usedLabel: "\(week.liveSessionPrompts) / \(budget.sessionPromptLimit) prompts",
                        fraction: AgentUsageMeters.fraction(
                            Double(week.liveSessionPrompts),
                            of: Double(budget.sessionPromptLimit)
                        )
                    )
                }
                if !budget.hasAnyLimit {
                    Text("No weekly/session limits set — relative activity only")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.faint)
                    relativeFallback(row)
                }
                Text(Self.metricsLine(row, week: week))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    private func relativeFallback(_ row: AgentObservedUsage) -> some View {
        let scales = AgentUsageMeters.Scales.from(
            model.observedUsageRows(at: Date())
        )
        return VStack(alignment: .leading, spacing: 4) {
            limitMeter(
                label: "Attached (vs peers)",
                usedLabel: Self.duration(row.attachedSeconds),
                fraction: AgentUsageMeters.fraction(
                    row.attachedSeconds,
                    of: scales.maxAttachedSeconds
                ),
                muted: true
            )
            limitMeter(
                label: "Output (vs peers)",
                usedLabel: Self.bytes(row.outputBytes),
                fraction: AgentUsageMeters.fraction(
                    Double(row.outputBytes),
                    of: Double(scales.maxOutputBytes)
                ),
                muted: true
            )
        }
    }

    private func limitMeter(
        label: String,
        usedLabel: String,
        fraction: Double,
        muted: Bool = false
    ) -> some View {
        let tint: Color = {
            if muted { return palette.dim.opacity(0.7) }
            if fraction >= 1 { return Color.red.opacity(0.75) }
            if fraction >= 0.85 { return Color.orange.opacity(0.85) }
            return palette.accent.opacity(0.85)
        }()
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.faint)
                    .frame(minWidth: 100, alignment: .leading)
                Text(usedLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.dim)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.lineSoft)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, geo.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: 6)
            .accessibilityLabel("\(label) \(usedLabel)")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent of limit")
        }
    }

    static func metricsLine(
        _ row: AgentObservedUsage,
        week: AgentUsageMeters.WeekWindowUsage
    ) -> String {
        var parts = [
            row.sessions == 1 ? "1 session all-time" : "\(row.sessions) sessions all-time",
            "\(week.sessions) this week",
            "\(Self.bytes(row.outputBytes)) out",
        ]
        let outcome = outcomes(row)
        if outcome != "—" { parts.append(outcome) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Limits are operator budgets on Conduit-observed prompts and attach time — not Claude/OpenAI weekly token quotas.")
                .foregroundStyle(palette.dim)
            Text("Set caps under Settings → Agents. Week resets at the local calendar week start.")
                .foregroundStyle(palette.faint)
            Text("Vendor remaining-quota APIs are not read; this is local self-tracking.")
                .foregroundStyle(palette.faint)
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.rail)
    }

    static let sheetMinWidth: CGFloat = 540

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(total % 60)s" }
        return "\(total)s"
    }

    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1024 * 1024 {
            return String(format: "%.0f KB", Double(count) / 1024)
        }
        return String(format: "%.1f MB", Double(count) / (1024 * 1024))
    }

    static func outcomes(_ row: AgentObservedUsage) -> String {
        var parts: [String] = []
        if row.cleanExits > 0 { parts.append("\(row.cleanExits) clean") }
        if row.failedExits > 0 { parts.append("\(row.failedExits) failed") }
        if row.detaches > 0 { parts.append("\(row.detaches) detached") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}

/// Compact always-on usage + budget meters for the inspector.
struct AgentUsageMeterPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let rows = model.observedUsageRows(at: context.date)
            let interesting = rows.filter { row in
                row.sessions > 0
                    || (model.settings.agents.first { $0.name == row.agent }?
                        .usageBudget.hasAnyLimit ?? false)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Limits & usage")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.dim)
                    Spacer()
                    Button("Full sheet") {
                        model.showAgentUsage = true
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(palette.accent)
                }
                if interesting.isEmpty {
                    Text("No observed sessions and no limits set.")
                        .font(.caption)
                        .foregroundStyle(palette.faint)
                    Text("Add weekly caps in Settings → Agents.")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                } else {
                    ForEach(interesting, id: \.agent) { row in
                        compactRow(row, at: context.date)
                    }
                }
            }
        }
    }

    private func compactRow(_ row: AgentObservedUsage, at date: Date) -> some View {
        let budget = model.settings.agents.first { $0.name == row.agent }?
            .usageBudget ?? AgentUsageBudget()
        let week = model.weekUsage(for: row.agent, at: date)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.liveSessions > 0 ? palette.accent : palette.faint.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(row.agent)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.text)
                Spacer()
                if budget.weeklyPromptLimit > 0 {
                    Text("\(week.totalPrompts)/\(budget.weeklyPromptLimit)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.dim)
                } else {
                    Text(AgentUsageSheet.duration(row.attachedSeconds))
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.dim)
                }
            }
            if budget.weeklyPromptLimit > 0 {
                compactBar(
                    fraction: AgentUsageMeters.fraction(
                        Double(week.totalPrompts),
                        of: Double(budget.weeklyPromptLimit)
                    ),
                    hot: week.totalPrompts >= budget.weeklyPromptLimit
                )
            }
            if budget.weeklyAttachedMinutesLimit > 0 {
                let usedMin = Int(week.attachedSeconds / 60)
                compactBar(
                    fraction: AgentUsageMeters.fraction(
                        Double(usedMin),
                        of: Double(budget.weeklyAttachedMinutesLimit)
                    ),
                    hot: usedMin >= budget.weeklyAttachedMinutesLimit
                )
            }
            if budget.sessionPromptLimit > 0 {
                compactBar(
                    fraction: AgentUsageMeters.fraction(
                        Double(week.liveSessionPrompts),
                        of: Double(budget.sessionPromptLimit)
                    ),
                    hot: week.liveSessionPrompts >= budget.sessionPromptLimit
                )
            }
            if !budget.hasAnyLimit, row.sessions > 0 {
                Text("No limit · \(week.totalPrompts) prompts this week")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
        }
        .padding(.vertical, 2)
    }

    private func compactBar(fraction: Double, hot: Bool) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.lineSoft)
                Capsule()
                    .fill(hot ? Color.red.opacity(0.75) : palette.accent.opacity(0.85))
                    .frame(width: max(0, geo.size.width * CGFloat(fraction)))
            }
        }
        .frame(height: 4)
    }
}
#endif
