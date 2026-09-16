#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

/// Read-only presentation of an explicit agent context bundle. Context may be
/// inspected, snapshotted, or turned into a draft handoff, but this surface does
/// not itself send anything to an agent.
struct ContextStackView: View {
    let bundle: AgentContextBundle
    var title: String = "CONTEXT STACK"

    @State private var showOnlyPinned = false
    @State private var showHandoff = false

    private var visibleItems: [AgentContextItem] {
        showOnlyPinned ? bundle.pinnedItems : bundle.items
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            scopeSummary
            Divider()
            itemList
            Divider()
            footer
        }
        .frame(minWidth: 360, minHeight: 340)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent context stack")
        .sheet(isPresented: $showHandoff) {
            ContextHandoffView(bundle: bundle)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
                Text(bundle.taskTitle)
                    .font(.headline)
                    .lineLimit(2)
            }
            Spacer()
            if !bundle.staleItems.isEmpty {
                Label("\(bundle.staleItems.count) stale", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Menu {
                Toggle("Pinned only", isOn: $showOnlyPinned)
                Divider()
                Button("Copy Context Summary") { copySummary() }
                Button("Copy Agent Handoff Draft") { copyHandoff() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .actionExplainer(
                ActionExplainerSpec(
                    title: "Context options",
                    summary: "Filter this preview or copy provenance-labelled context text.",
                    effect: "Changes only local presentation or the pasteboard.",
                    nonEffect: "Does not send context to an agent or modify MainFrame."
                )
            )
        }
        .padding(12)
    }

    private var scopeSummary: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let scopePath = bundle.scopePath {
                summaryRow("SCOPE", scopePath, monospaced: true)
            }
            if let repository = bundle.repository {
                summaryRow("REPO", repository, monospaced: true)
            }
            if let branch = bundle.branch {
                summaryRow("BRANCH", branch, monospaced: true)
            }
            if let commit = bundle.commitSHA {
                summaryRow("COMMIT", commit, monospaced: true)
            }
            summaryRow("ITEMS", "\(bundle.items.count)")
            if bundle.estimatedTokenTotal > 0 {
                summaryRow("EST. TOKENS", "\(bundle.estimatedTokenTotal)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if visibleItems.isEmpty {
                    Text(showOnlyPinned ? "No pinned context items." : "No context items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(14)
                } else {
                    ForEach(visibleItems) { item in
                        ContextStackItemRow(item: item)
                    }
                }
            }
            .padding(10)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label("Preview only", systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !bundle.nominationItems.isEmpty {
                Text("\(bundle.nominationItems.count) semantic nomination\(bundle.nominationItems.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Draft Handoff") {
                showHandoff = true
            }
            .buttonStyle(.bordered)
            .disabled(bundle.items.isEmpty)
            .actionExplainer(
                ActionExplainerSpec(
                    title: "Draft Agent Handoff",
                    summary: "Turn this exact typed context into an inspectable agent handoff draft.",
                    effect: "Opens a draft where you can choose a recipe, objective, and destination.",
                    nonEffect: "Does not send, launch, or authorize any agent action.",
                    target: bundle.scopePath,
                    authority: "Operator-reviewed context"
                )
            )
        }
        .padding(10)
    }

    private func summaryRow(
        _ label: String,
        _ value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(ContextStackSummary.render(bundle), forType: .string)
    }

    private func copyHandoff() {
        let handoff = AgentContextHandoff(
            objective: bundle.taskTitle,
            bundle: bundle
        )
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(AgentContextHandoffRenderer.render(handoff), forType: .string)
    }
}

private struct ContextStackItemRow: View {
    let item: AgentContextItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                    Spacer(minLength: 0)
                    authorityBadge
                }

                Text(item.locationLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    freshnessLabel
                    if let identity = item.revisionIdentity, !identity.isEmpty {
                        Text(identity)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let tokens = item.estimatedTokens {
                        Text("~\(tokens) tok")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(9)
        .background(Color.secondary.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .actionExplainer(
            ActionExplainerSpec(
                title: item.title,
                summary: "Context item from \(authorityLabel.lowercased()).",
                effect: "Makes provenance and exact identity inspectable in the proposed context bundle.",
                nonEffect: item.authority.isSourceBacked
                    ? "Does not itself send, edit, or verify the source."
                    : "Does not become source truth merely because it appears in context.",
                target: item.locationLabel,
                authority: authorityLabel
            )
        )
    }

    private var authorityBadge: some View {
        Text(authorityLabel.uppercased())
            .font(.system(size: 7, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(
                Capsule().strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var freshnessLabel: some View {
        switch item.freshness {
        case .current:
            Label("current", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .stale(let reason):
            Label("stale", systemImage: "clock.badge.exclamationmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help(reason)
        case .unknown:
            Label("freshness unknown", systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var authorityLabel: String {
        switch item.authority {
        case .filesystemSource: return "Filesystem source"
        case .gitCommit: return "Git identity"
        case .gitWorkingTree: return "Git observation"
        case .operatorPinned: return "Operator input"
        case .lifecycleRecord: return "Lifecycle record"
        case .testReceipt: return "Test receipt"
        case .terminalObservation: return "Terminal observation"
        case .taskHistory: return "Task history"
        case .pullRequest: return "Pull request"
        case .issue: return "Issue"
        case .mindGraphNomination: return "MindGraph nomination"
        case .agentOutput: return "Agent output"
        }
    }

    private var symbol: String {
        switch item.kind {
        case .file: return "doc.text"
        case .selection: return "selection.pin.in.out"
        case .gitDiff: return "arrow.left.arrow.right"
        case .commit: return "point.topleft.down.to.point.bottomright.curvepath"
        case .task: return "checklist"
        case .terminal: return "terminal"
        case .testReceipt: return "checkmark.seal"
        case .pullRequest: return "arrow.triangle.pull"
        case .issue: return "exclamationmark.bubble"
        case .semanticNomination: return "point.3.connected.trianglepath.dotted"
        case .agentOutput: return "bubble.left.and.text.bubble.right"
        case .note: return "note.text"
        }
    }
}

enum ContextStackSummary {
    static func render(_ bundle: AgentContextBundle) -> String {
        var lines: [String] = ["Context: \(bundle.taskTitle)"]
        if let scope = bundle.scopePath { lines.append("Scope: \(scope)") }
        if let repository = bundle.repository { lines.append("Repository: \(repository)") }
        if let branch = bundle.branch { lines.append("Branch: \(branch)") }
        if let commit = bundle.commitSHA { lines.append("Commit: \(commit)") }
        lines.append("")
        for item in bundle.items {
            let pin = item.isPinned ? " [pinned]" : ""
            let identity = item.revisionIdentity.map { " @ \($0)" } ?? ""
            lines.append("- \(item.title)\(pin) — \(item.authority.rawValue) — \(item.locationLabel)\(identity)")
        }
        return lines.joined(separator: "\n")
    }
}
#endif
