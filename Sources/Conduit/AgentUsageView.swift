#if os(macOS)
import ConduitCore
import SwiftUI

/// Tier A usage surface: **only what Conduit observed.**
///
/// Deliberately carries no token or cost column. Those are reported by each
/// CLI's own records, are counted differently by each vendor, and are not read
/// here — showing a blank or zero for them would read as "none used", which is
/// a claim Conduit cannot make.
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
                let scales = AgentUsageMeters.Scales.from(rows)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.agent) { row in
                            usageRow(row, scales: scales)
                            Divider().overlay(palette.lineSoft)
                        }
                    }
                }
            }
            Divider().overlay(palette.line)
            footer
        }
        .frame(minWidth: Self.sheetMinWidth, minHeight: 420)
        .background(palette.canvas)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent usage")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Text("Observed by Conduit — meters are relative across agents")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func usageRow(
        _ row: AgentObservedUsage,
        scales: AgentUsageMeters.Scales
    ) -> some View {
        let unobserved = row.sessions == 0
        return VStack(alignment: .leading, spacing: 6) {
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
            if unobserved {
                Text("no sessions observed")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.faint)
            } else {
                meter(
                    label: "Attached",
                    value: AgentUsageSheet.duration(row.attachedSeconds),
                    fraction: AgentUsageMeters.fraction(
                        row.attachedSeconds,
                        of: scales.maxAttachedSeconds
                    ),
                    tint: palette.ink
                )
                meter(
                    label: "Output",
                    value: AgentUsageSheet.bytes(row.outputBytes),
                    fraction: AgentUsageMeters.fraction(
                        Double(row.outputBytes),
                        of: Double(scales.maxOutputBytes)
                    ),
                    tint: palette.dim
                )
                meter(
                    label: "Prompts",
                    value: {
                        var s = "\(row.promptsDelivered)"
                        if row.promptsFailed > 0 {
                            s += " · \(row.promptsFailed) failed"
                        }
                        return s
                    }(),
                    fraction: AgentUsageMeters.fraction(
                        Double(row.promptsDelivered + row.promptsFailed),
                        of: Double(scales.maxPrompts)
                    ),
                    tint: palette.accent.opacity(0.75)
                )
                Text(Self.metricsLine(row))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    private func meter(
        label: String,
        value: String,
        fraction: Double,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.faint)
                    .frame(width: 56, alignment: .leading)
                Text(value)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.dim)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(palette.lineSoft)
                    Capsule()
                        .fill(tint)
                        .frame(
                            width: max(0, geo.size.width * CGFloat(fraction))
                        )
                }
            }
            .frame(height: 5)
            .accessibilityLabel("\(label) \(value)")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent of max among agents")
        }
    }

    static func metricsLine(_ row: AgentObservedUsage) -> String {
        var parts = [
            row.sessions == 1 ? "1 session" : "\(row.sessions) sessions",
        ]
        let outcome = outcomes(row)
        if outcome != "—" { parts.append(outcome) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Meters scale relative to the busiest agent Conduit observed — not a vendor quota.")
                .foregroundStyle(palette.dim)
            Text("Tokens, cost, and remaining quota are not shown: each tool counts them differently.")
                .foregroundStyle(palette.faint)
            Text("Attached time for a detached session is time Conduit was attached, not time the agent worked.")
                .foregroundStyle(palette.faint)
        }
        .font(.caption2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.rail)
    }

    static let sheetMinWidth: CGFloat = 520

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

/// Compact always-on usage meters for the inspector.
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
            let scales = AgentUsageMeters.Scales.from(rows)
            let active = rows.filter { $0.sessions > 0 }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Observed usage")
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
                if active.isEmpty {
                    Text("No agent sessions observed yet.")
                        .font(.caption)
                        .foregroundStyle(palette.faint)
                } else {
                    ForEach(active, id: \.agent) { row in
                        compactRow(row, scales: scales)
                    }
                }
                Text("Relative meters · not tokens or cost")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
        }
    }

    private func compactRow(
        _ row: AgentObservedUsage,
        scales: AgentUsageMeters.Scales
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(row.liveSessions > 0 ? palette.accent : palette.faint.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(row.agent)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.text)
                Spacer()
                Text(AgentUsageSheet.duration(row.attachedSeconds))
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.dim)
            }
            compactBar(
                fraction: AgentUsageMeters.fraction(
                    row.attachedSeconds,
                    of: scales.maxAttachedSeconds
                ),
                tint: palette.ink
            )
            compactBar(
                fraction: AgentUsageMeters.fraction(
                    Double(row.outputBytes),
                    of: Double(scales.maxOutputBytes)
                ),
                tint: palette.dim
            )
        }
        .padding(.vertical, 2)
    }

    private func compactBar(fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.lineSoft)
                Capsule()
                    .fill(tint.opacity(0.85))
                    .frame(width: max(0, geo.size.width * CGFloat(fraction)))
            }
        }
        .frame(height: 4)
    }
}
#endif
