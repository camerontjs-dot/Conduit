#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

/// Compact inspector pane for the Attention card.
struct FocusBoardPanel: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            banner
            itemList(limit: 5)
            feedChips
            proposalLine
            Button("Open full Attention board…") {
                model.showFocusBoardSheet = true
            }
            .buttonStyle(.borderedProminent)
            Text("Projection of recorded MainFrame feeds only. This is not agent-inbox reconnect counts and not Doctor health.")
                .font(.caption2)
                .foregroundStyle(palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            // Operator (and persisted expand) open this card already-expanded, so
            // InspectorView's expand onChange never fires. Load once, no poller.
            if model.focusBoard == nil, !model.focusBoardRefreshing {
                model.refreshFocusBoard()
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("projection only")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(palette.faint)
                if let asOf = model.focusBoard?.asOf {
                    Text("as of \(asOf.prefix(19))")
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                }
            }
            Spacer()
            Button {
                model.refreshFocusBoard()
            } label: {
                if model.focusBoardRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Refresh")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption2)
            .disabled(model.focusBoardRefreshing)
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let error = model.focusBoardError {
            Text("Focus Board unavailable — \(error). This is a read failure, not an all-clear.")
                .font(.caption)
                .foregroundStyle(Color.orange.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
        } else if model.focusBoardRefreshing && model.focusBoard == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading truth feeds…")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
        } else if let board = model.focusBoard, board.isFeedsMissing {
            Text("No truth feeds recorded — this is not an all-clear.")
                .font(.caption)
                .foregroundStyle(Color.orange.opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func itemList(limit: Int?) -> some View {
        if let board = model.focusBoard, !board.isFeedsMissing {
            let items = limit.map { Array(board.items.prefix($0)) } ?? board.items
            if items.isEmpty {
                Text("No attention items projected from recorded feeds. Empty list is not inventing health — check feed metadata.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        FocusBoardItemRow(item: item, compact: limit != nil)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var feedChips: some View {
        if let feeds = model.focusBoard?.feeds, !feeds.isEmpty {
            FlowFeedChips(feeds: feeds, palette: palette)
        }
    }

    @ViewBuilder
    private var proposalLine: some View {
        if let proposal = model.focusBoard?.weeklyFocusProposal {
            let approved = model.focusBoard?.approvedFocus
            let status: String = {
                if proposal.status == "available" {
                    if approved?.reviewStatus == "past_due" {
                        return "Proposal available · approved focus review due"
                    }
                    return "Proposal available · nomination only"
                }
                return "Proposal unavailable"
            }()
            Text(status)
                .font(.caption2)
                .foregroundStyle(palette.dim)
        }
    }
}

/// Full Attention board sheet (Usage-style).
struct FocusBoardSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConduitSheetHeader(
                title: "Attention",
                subtitle: "MainFrame Focus Board · read-only",
                systemImage: "bell.badge",
                onClose: { model.showFocusBoardSheet = false },
                trailing: {
                    Button {
                        model.refreshFocusBoard()
                    } label: {
                        if model.focusBoardRefreshing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.focusBoardRefreshing)
                    .help("Reload recorded truth feeds. This never writes focus authority.")
                }
            )
            Divider().overlay(palette.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.focusBoardError {
                        banner(
                            "Focus Board unavailable — \(error). This is a read failure, not an all-clear.",
                            tone: .unavailable
                        )
                    } else if model.focusBoardRefreshing && model.focusBoard == nil {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Reading truth feeds…")
                                .font(.caption)
                                .foregroundStyle(palette.dim)
                        }
                    } else if let board = model.focusBoard {
                        if board.fixture {
                            banner("FIXTURE/DEMO — labeled fixture data, not live truth feeds", tone: .info)
                        }
                        planningSection(board)
                        if board.isFeedsMissing {
                            banner(
                                "\(board.items.first?.title ?? "No truth feeds recorded") — \(board.items.first?.detail ?? "This is not an all-clear.")",
                                tone: .empty
                            )
                        } else if board.items.isEmpty {
                            banner(
                                "No attention items projected from recorded feeds. Empty list is not inventing health — check feed metadata below.",
                                tone: .empty
                            )
                        } else {
                            rankedSection(board.items)
                        }
                        if !board.parseErrors.isEmpty {
                            notesSection(title: "Feed notes", lines: board.parseErrors)
                        }
                        if !board.feedNotes.isEmpty {
                            notesSection(title: "Projection notes", lines: board.feedNotes)
                        }
                        feedMeta(board.feeds)
                    }
                }
                .padding(14)
            }
            Divider().overlay(palette.line)
            Text("Read-only projection. Conduit cannot approve weekly proposals or write 20_live/focus/current.yaml.")
                .font(.caption2)
                .foregroundStyle(palette.faint)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(palette.canvas)
        .onAppear {
            if model.focusBoard == nil, !model.focusBoardRefreshing {
                model.refreshFocusBoard()
            }
        }
    }

    private enum BannerTone { case unavailable, empty, info }

    private func banner(_ text: String, tone: BannerTone) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tone == .info ? palette.dim : Color.orange.opacity(0.95))
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.sink)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func planningSection(_ board: FocusBoardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PLANNING")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(palette.dim)
                    Text("Weekly focus proposal")
                        .font(.headline)
                        .foregroundStyle(palette.text)
                }
                Spacer()
                if let proposal = board.weeklyFocusProposal, proposal.status == "available" {
                    Text("proposed — approval required")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.accent)
                    if let asOf = proposal.asOf {
                        Text("as of \(asOf)")
                            .font(.caption2)
                            .foregroundStyle(palette.faint)
                    }
                } else {
                    Text("not available")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(palette.dim)
                }
            }

            if let proposal = board.weeklyFocusProposal, proposal.status == "available" {
                Text("This is a read-only nomination. It does not write focus authority, project state, STATE.md, or external systems.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(proposal.slots) { slot in
                        proposalSlot(slot)
                    }
                }

                approvedBlock(board.approvedFocus)

                Text(
                    "Approval receipt: \(proposal.approvalApproved ? "recorded" : "none recorded"). This panel cannot approve or promote the proposal."
                )
                .font(.caption2)
                .foregroundStyle(palette.faint)

                if proposal.intentStatus == "not_used" {
                    Text("Intent graph: not consulted for this proposal; direct authority files remain the inputs.")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
                ForEach(proposal.warnings, id: \.self) { warning in
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(Color.orange.opacity(0.9))
                }
                if let path = proposal.artifactPath {
                    evidenceLink(path, label: "Artifact: \(path)")
                }
            } else {
                let proposal = board.weeklyFocusProposal
                Text("\(proposal?.error ?? "No dated proposal artifact found") — \(proposal?.detail ?? "run bin/propose-weekly-focus --write")")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
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

    private func proposalSlot(_ slot: FocusBoardProposalSlot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(slot.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.dim)
                Spacer()
                Text(slot.status.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            Text(slot.project ?? "unassigned — operator input required")
                .font(.callout.weight(.semibold))
                .foregroundStyle(palette.text)
            Text(slot.action)
                .font(.caption)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(slot.evidenceRefs.prefix(4), id: \.self) { ref in
                evidenceLink(ref.components(separatedBy: "#").first ?? ref, label: ref)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.sink.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func approvedBlock(_ approved: FocusBoardApprovedFocus?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Approved focus (read-only)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.text)
                if approved?.reviewStatus == "past_due" {
                    Text("review due")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.orange)
                }
            }
            if approved?.status == "available" {
                Text("\(approved?.primary.project ?? "no primary project") — \(approved?.primary.desiredOutcome ?? "no desired outcome recorded")")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("decision \(approved?.decisionID ?? "unknown") · revision \(approved?.revision ?? "unknown") · \(approved?.sourcePath ?? FocusBoardPaths.approvedFocus)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.faint)
                    .textSelection(.enabled)
            } else {
                Text("Approved focus unavailable — this is not permission to infer a focus.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.accentSoft.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func rankedSection(_ items: [FocusBoardItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RANKED ATTENTION")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(palette.dim)
            ForEach(items) { item in
                FocusBoardItemRow(item: item, compact: false)
            }
        }
    }

    private func notesSection(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(palette.dim)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
            }
        }
    }

    private func feedMeta(_ feeds: [FocusBoardFeedMeta]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FEED PRESENCE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(palette.dim)
            FlowFeedChips(feeds: feeds, palette: palette)
            ForEach(feeds) { feed in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(feed.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.text)
                    Text(feed.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let count = feed.recordCount {
                        Text("\(count)")
                            .font(.caption2)
                            .foregroundStyle(palette.dim)
                    }
                    if let error = feed.error {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(Color.orange.opacity(0.9))
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func evidenceLink(_ path: String, label: String) -> some View {
        if FocusBoard.isViewableEvidencePath(path) {
            Button(label) {
                model.revealFocusBoardEvidence(path)
            }
            .buttonStyle(.plain)
            .font(.caption2.monospaced())
            .foregroundStyle(palette.accent)
            .help("Reveal under the MainFrame root in Finder")
        } else {
            Text(label)
                .font(.caption2.monospaced())
                .foregroundStyle(palette.faint)
                .textSelection(.enabled)
        }
    }
}

private struct FocusBoardItemRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let item: FocusBoardItem
    var compact: Bool

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                severityChip
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !compact || !item.detail.isEmpty {
                Text(item.detail)
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(compact ? 3 : 8)
            }
            HStack(spacing: 8) {
                Text(item.source.rawValue)
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.faint)
                if FocusBoard.isViewableEvidencePath(item.evidencePath) {
                    Button(item.evidencePath) {
                        model.revealFocusBoardEvidence(item.evidencePath)
                    }
                    .buttonStyle(.plain)
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                } else {
                    Text(item.evidencePath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let asOf = item.asOf {
                    Text(String(asOf.prefix(19)))
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
            }
        }
        .padding(compact ? 6 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(chipColor.opacity(0.45), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.severity.displayLabel), \(item.title)")
    }

    private var severityChip: some View {
        Text(item.severity.displayLabel)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(chipColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(chipColor.opacity(0.15))
            .clipShape(Capsule())
    }

    private var chipColor: Color {
        switch item.severity {
        case .urgent: return Color.red.opacity(0.9)
        case .actionRequired: return Color.orange.opacity(0.95)
        case .watch: return Color.yellow.opacity(0.85)
        case .info: return palette.dim
        }
    }
}

private struct FlowFeedChips: View {
    let feeds: [FocusBoardFeedMeta]
    let palette: ConduitPalette

    var body: some View {
        HStack(spacing: 6) {
            ForEach(feeds) { feed in
                let tone: Color = {
                    if !feed.present { return palette.faint }
                    if feed.error != nil { return Color.orange.opacity(0.9) }
                    return palette.accent
                }()
                let count = feed.recordCount.map { " · \($0)" } ?? ""
                Text("\(feed.id)\(count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(tone)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(tone.opacity(0.12))
                    .clipShape(Capsule())
                    .help(feed.error ?? feed.path)
            }
        }
    }
}
#endif
