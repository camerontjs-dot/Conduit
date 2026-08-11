#if os(macOS)
import ConduitCore
import SwiftUI

/// Account-reported limits (Claude/Codex/OpenCode) plus optional operator budgets.
struct AgentUsageSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    accountSection
                    Divider().overlay(palette.lineSoft)
                    observedSection
                }
                .padding(14)
            }
            Divider().overlay(palette.line)
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .background(palette.canvas)
    }

    private var header: some View {
        ConduitSheetHeader(
            title: "Account usage",
            subtitle: "Live limits from Claude / Codex / OpenCode accounts",
            systemImage: "chart.bar.fill",
            trailing: {
                Button {
                    model.refreshAccountUsage()
                } label: {
                    if model.accountUsageRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.accountUsageRefreshing)
                .help("Refresh optional account meters without requesting interactive Claude Keychain access")
            }
        )
    }

    // MARK: - Account (vendor)

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FROM YOUR ACCOUNTS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(palette.dim)

            if model.accountUsageRefreshing && model.accountUsage.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading account usage…")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                }
            }

            ForEach(model.accountUsage) { snap in
                accountCard(snap)
            }

            if model.accountUsage.isEmpty, !model.accountUsageRefreshing {
                Text("No account data loaded. Refresh is optional; Claude credentials are read only when already available without a macOS prompt.")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            }
        }
    }

    private func accountCard(_ snap: AccountUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snap.agentName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                Spacer()
                Text(snap.sourceLabel)
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
            }
            if let error = snap.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.orange.opacity(0.9))
            } else {
                ForEach(snap.windows) { window in
                    accountWindowMeter(window)
                }
                ForEach(snap.notes, id: \.self) { note in
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Fetched \(snap.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func accountWindowMeter(_ window: AccountUsageWindow) -> some View {
        let fraction = min(1, max(0, window.usedPercent / 100))
        let tint: Color = {
            if fraction >= 0.95 { return Color.red.opacity(0.8) }
            if fraction >= 0.80 { return Color.orange.opacity(0.85) }
            return palette.accent.opacity(0.9)
        }()
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.text)
                Spacer()
                Text(String(format: "%.0f%% used · %.0f%% left", window.usedPercent, window.remainingPercent))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(palette.dim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.lineSoft)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: 7)
            if let detail = window.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            if let resets = window.resetsAt {
                Text("Resets \(resets.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(window.label), \(Int(window.usedPercent)) percent used")
    }

    // MARK: - Observed (local)

    private var observedSection: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let rows = model.observedUsageRows(at: context.date)
            VStack(alignment: .leading, spacing: 10) {
                Text("CONDUIT-OBSERVED (local)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(palette.dim)
                Text("Attach time and prompts Conduit delivered — not account pool.")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)

                ForEach(rows.filter { $0.sessions > 0 || hasBudget($0.agent) }, id: \.agent) { row in
                    observedRow(row, at: context.date)
                }
            }
        }
    }

    private func hasBudget(_ agent: String) -> Bool {
        model.settings.agents.first { $0.name == agent }?.usageBudget.hasAnyLimit ?? false
    }

    private func observedRow(_ row: AgentObservedUsage, at date: Date) -> some View {
        let budget = model.settings.agents.first { $0.name == row.agent }?.usageBudget
            ?? AgentUsageBudget()
        let week = model.weekUsage(for: row.agent, at: date)
        return VStack(alignment: .leading, spacing: 5) {
            Text(row.agent)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.text)
            if budget.weeklyPromptLimit > 0 {
                limitLine(
                    "Week prompts",
                    "\(week.totalPrompts) / \(budget.weeklyPromptLimit)",
                    AgentUsageMeters.fraction(
                        Double(week.totalPrompts),
                        of: Double(budget.weeklyPromptLimit)
                    )
                )
            }
            if budget.weeklyAttachedMinutesLimit > 0 {
                let used = Int(week.attachedSeconds / 60)
                limitLine(
                    "Week attached",
                    "\(used) / \(budget.weeklyAttachedMinutesLimit) min",
                    AgentUsageMeters.fraction(
                        Double(used),
                        of: Double(budget.weeklyAttachedMinutesLimit)
                    )
                )
            }
            Text(
                "\(row.sessions) sessions · \(AgentUsageSheet.duration(row.attachedSeconds)) attached · \(AgentUsageSheet.bytes(row.outputBytes)) out"
            )
            .font(.caption2.monospaced())
            .foregroundStyle(palette.faint)
        }
        .padding(.vertical, 4)
    }

    private func limitLine(_ label: String, _ value: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2).foregroundStyle(palette.faint)
                Spacer()
                Text(value).font(.caption2.monospaced()).foregroundStyle(palette.dim)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.lineSoft)
                    Capsule()
                        .fill(fraction >= 1 ? Color.red.opacity(0.75) : palette.dim.opacity(0.7))
                        .frame(width: max(0, geo.size.width * CGFloat(min(1, fraction))))
                }
            }
            .frame(height: 4)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Account meters load only after Refresh. Conduit does not request interactive Claude Keychain access or place credentials in its settings, logs, or snapshots.")
                .foregroundStyle(palette.dim)
            Text("Claude: 5h + weekly utilization. Codex: ChatGPT plan windows. OpenCode: local session tokens (not Zen pool %).")
                .foregroundStyle(palette.faint)
        }
        .font(.caption2)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.rail)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(total)s"
    }

    static func bytes(_ count: Int) -> String {
        if count < 1024 { return "\(count) B" }
        if count < 1_048_576 { return String(format: "%.0f KB", Double(count) / 1024) }
        return String(format: "%.1f MB", Double(count) / 1_048_576)
    }
}

/// Compact inspector panel focused on account windows.
struct AgentUsageMeterPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Account limits")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.dim)
                Spacer()
                Button("Refresh") { model.refreshAccountUsage() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(palette.accent)
                    .disabled(model.accountUsageRefreshing)
                    .help("Refresh optional account meters without requesting interactive Claude Keychain access")
                Button("Details") { model.showAgentUsage = true }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .foregroundStyle(palette.accent)
            }

            if model.accountUsage.isEmpty {
                Text(model.accountUsageRefreshing ? "Loading…" : "Optional · Refresh account meters manually.")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            } else {
                ForEach(model.accountUsage) { snap in
                    compactAccount(snap)
                }
            }
        }
    }

    private func compactAccount(_ snap: AccountUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snap.agentName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.text)
            if let error = snap.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Color.orange.opacity(0.85))
                    .lineLimit(2)
            } else {
                ForEach(snap.windows.prefix(2)) { w in
                    HStack {
                        Text(w.label)
                            .font(.caption2)
                            .foregroundStyle(palette.faint)
                        Spacer()
                        Text(String(format: "%.0f%%", w.usedPercent))
                            .font(.caption2.monospaced())
                            .foregroundStyle(palette.dim)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(palette.lineSoft)
                            Capsule()
                                .fill(
                                    w.usedPercent >= 90
                                        ? Color.red.opacity(0.75)
                                        : palette.accent.opacity(0.85)
                                )
                                .frame(
                                    width: max(
                                        0,
                                        geo.size.width * CGFloat(min(1, w.usedPercent / 100))
                                    )
                                )
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
#endif
