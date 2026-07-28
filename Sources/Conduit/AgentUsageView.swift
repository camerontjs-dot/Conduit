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
                ScrollView {
                    // A list, not a table. Fixed-width and Grid columns were
                    // both tried and clipped at both edges; one wrapping
                    // metrics line per agent cannot clip at any sheet width.
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.agent) { row in
                            usageRow(row)
                            Divider().overlay(palette.lineSoft)
                        }
                    }
                }
            }
            Divider().overlay(palette.line)
            footer
        }
        .frame(minWidth: Self.sheetMinWidth, minHeight: 400)
        .background(palette.canvas)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent usage")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Text("Observed by Conduit — not verification of work done")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private func usageRow(_ row: AgentObservedUsage) -> some View {
        let unobserved = row.sessions == 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Accent marks a live session only — it is not a quality or
                // success signal, matching the single-accent rule.
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
                // One honest statement instead of a row of zeros that would
                // read as measured values.
                Text("no sessions observed")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.faint)
            } else {
                Text(Self.metricsLine(row))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 16)
    }

    /// One wrapping line per agent, so no column can be cut off.
    static func metricsLine(_ row: AgentObservedUsage) -> String {
        var parts = [
            row.sessions == 1 ? "1 session" : "\(row.sessions) sessions",
            "\(duration(row.attachedSeconds)) attached",
            "\(bytes(row.outputBytes)) out"
        ]
        if row.promptsDelivered > 0 || row.promptsFailed > 0 {
            var prompts = "\(row.promptsDelivered) prompts"
            if row.promptsFailed > 0 { prompts += " (\(row.promptsFailed) failed)" }
            parts.append(prompts)
        }
        let outcome = outcomes(row)
        if outcome != "—" { parts.append(outcome) }
        return parts.joined(separator: " · ")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Conduit counts sessions, attached wall-clock, delivered prompts, and rendered output bytes it saw itself.")
                .foregroundStyle(palette.dim)
            Text("Tokens, cost, and remaining quota are not shown: each tool counts them differently, and Conduit does not read them.")
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

    /// Generous enough that the content-sized grid never drives the sheet
    /// wider than it, while leaving room for long outcome strings.
    static let sheetMinWidth: CGFloat = 640

    // MARK: - Formatting

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
        if count < 1024 * 1024 { return String(format: "%.0f KB", Double(count) / 1024) }
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
#endif
