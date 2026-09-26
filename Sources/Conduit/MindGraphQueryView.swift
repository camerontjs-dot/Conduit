#if os(macOS)
import ConduitCore
import SwiftUI

/// Operator-facing MindGraph query station inside Conduit.
///
/// Runs `bin/mindgraph query` against one scope at a time (knowledge or
/// projects). Results are nominations for inspection — not verified claims.
struct MindGraphQueryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private let onOpenPath: ((String) -> Void)?
    private let onResults: (([MindGraphHit]) -> Void)?

    @State private var question: String
    @State private var scope: MindGraphScope = .knowledge
    @State private var topK = 8
    @State private var isRunning = false
    @State private var inspectionItems: [MindGraphInspectionItem] = []
    @State private var errorText: String?
    @State private var lastQueryLabel: String?

    init(
        initialQuestion: String? = nil,
        onOpenPath: ((String) -> Void)? = nil,
        onResults: (([MindGraphHit]) -> Void)? = nil
    ) {
        self.onOpenPath = onOpenPath
        self.onResults = onResults
        _question = State(initialValue: initialQuestion ?? "")
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.line)
            queryBar
            Divider().overlay(palette.line)
            results
            Divider().overlay(palette.line)
            footer
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(palette.canvas)
        .onAppear {
            if question.isEmpty, let selected = model.selectedProject {
                question = selected.metadata.title
            }
        }
    }

    private var header: some View {
        ConduitSheetHeader(
            title: "MindGraph",
            subtitle: "Local dual-index retrieval · one scope per query",
            systemImage: "point.3.connected.trianglepath.dotted"
        )
    }

    private var queryBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Scope", selection: $scope) {
                    ForEach(MindGraphScope.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .actionExplainer(
                    ActionExplainerSpec(
                        title: "MindGraph scope",
                        summary: scope.help,
                        effect: "Chooses which local MindGraph index this query searches.",
                        nonEffect: "Does not merge Knowledge and Projects or change MainFrame files.",
                        target: scope.displayName,
                        authority: "Semantic retrieval nomination"
                    )
                )

                Stepper("Top \(topK)", value: $topK, in: 3...20)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .actionExplainer(
                        ActionExplainerSpec(
                            title: "Result limit",
                            summary: "Caps the number of semantic nominations returned by this query.",
                            effect: "Changes only the bounded retrieval request.",
                            nonEffect: "Does not change ranking authority or verify any returned claim.",
                            target: "Top \(topK)"
                        )
                    )

                Spacer()

                Button {
                    runQuery()
                } label: {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Query", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRunning || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
                .actionExplainer(
                    ActionExplainerSpec(
                        title: "Query MindGraph",
                        summary: "Searches the selected semantic index for related material.",
                        effect: "Returns provenance-labelled retrieval nominations for inspection.",
                        nonEffect: "Does not modify MainFrame and does not make returned material verified or authored relationships.",
                        target: scope.displayName,
                        authority: "MindGraph retrieval",
                        shortcut: "Return"
                    )
                )
            }

            TextField(
                "Ask MindGraph…",
                text: $question,
                axis: .vertical
            )
            .lineLimit(2...4)
            .textFieldStyle(.roundedBorder)
            .onSubmit(runQuery)

            Text(scope.help)
                .font(.caption2)
                .foregroundStyle(palette.faint)
        }
        .padding(12)
        .background(palette.rail)
    }

    @ViewBuilder
    private var results: some View {
        if let errorText {
            VStack(alignment: .leading, spacing: 8) {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(palette.dim)
                    .font(.callout)
                Text("Results are nominations for inspection, not verified claims.")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if inspectionItems.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28))
                    .foregroundStyle(palette.faint)
                Text(lastQueryLabel == nil
                    ? "Query knowledge or project context"
                    : "No hits for that query")
                    .font(.callout)
                    .foregroundStyle(palette.dim)
                if let lastQueryLabel {
                    Text(lastQueryLabel)
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let lastQueryLabel {
                        Text(lastQueryLabel)
                            .font(.caption2)
                            .foregroundStyle(palette.faint)
                    }
                    Text("Operator inspection view. Expanded source is visible here without being admitted to an agent context.")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                    ForEach(inspectionItems) { item in
                        inspectionCard(item)
                    }
                }
                .padding(12)
            }
        }
    }

    private func inspectionCard(_ item: MindGraphInspectionItem) -> some View {
        let nomination = item.nomination
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(nomination.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(nomination.scope.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.accentSoft)
                    .clipShape(Capsule())
            }

            Text(nomination.displayPath)
                .font(.caption2.monospaced())
                .foregroundStyle(palette.dim)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text("trust: \(nomination.trustProfile)")
                Text("freshness: \(nomination.freshness.lowercased())")
                Text(nomination.citationClass.replacingOccurrences(of: "_", with: " "))
                if nomination.weakFit {
                    Text("weak fit")
                }
            }
            .font(.caption2)
            .foregroundStyle(palette.faint)

            if !nomination.retrievalReasons.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WHY NOMINATED")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                    Text(
                        nomination.retrievalReasons
                            .map { $0.replacingOccurrences(of: "_", with: " ") }
                            .joined(separator: " · ")
                    )
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
                    .textSelection(.enabled)
                }
            }

            if !nomination.preview.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("COMPACT AGENT PREVIEW")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                    Text(nomination.preview)
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                        .textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.rail.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            if let expansion = item.expansion {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("FULL RETRIEVED CHUNK")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(palette.faint)
                        Spacer()
                        Text("operator inspection only")
                            .font(.caption2)
                            .foregroundStyle(palette.accent)
                    }
                    Text(expansion.chunkText.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.caption)
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Visible in Conduit; not admitted to an agent context by inspection alone.")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(palette.line, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
            } else if let expansionError = item.expansionError {
                Label(
                    "Expansion unavailable: \(expansionError)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(palette.dim)
                .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if let signal = nomination.signal {
                    Text(signal)
                }
                if let score = nomination.rrfScore {
                    Text(String(format: "rrf %.3f", score))
                }
                Spacer()
                if let onOpenPath {
                    Button {
                        onOpenPath(nomination.displayPath)
                        dismiss()
                    } label: {
                        Label("Open in Explorer", systemImage: "arrow.forward.square")
                    }
                    .buttonStyle(.bordered)
                    .actionExplainer(
                        ActionExplainerSpec(
                            title: "Open nominated source",
                            summary: "Attempts to reveal this nominated path in the current MainFrame Explorer.",
                            effect: "Opens only when the path resolves inside the current bounded MainFrame index.",
                            nonEffect: "Does not admit the source to agent context or make the nomination a verified fact.",
                            target: nomination.displayPath,
                            authority: "MindGraph nomination routed to filesystem lookup"
                        )
                    )
                }
            }
            .font(.caption2)
            .foregroundStyle(palette.faint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Text("One MindGraph retrieval, two projections: compact nominations for agents; expanded source here for operator inspection. Inspection does not attach source to a worker.")
                .font(.caption2)
                .foregroundStyle(palette.faint)
            Spacer()
            if isRunning {
                Text("Querying…")
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(12)
        .background(palette.rail)
    }

    private func runQuery() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        isRunning = true
        errorText = nil
        inspectionItems = []
        lastQueryLabel = "\(scope.displayName) · top \(topK) · \(q)"
        Task {
            let result = await model.inspectMindGraph(
                question: q,
                scope: scope,
                topK: topK
            )
            await MainActor.run {
                isRunning = false
                switch result {
                case .success(let rows):
                    inspectionItems = rows
                    onResults?(rows.compactMap(\.expandedHit))
                    if rows.isEmpty {
                        errorText = nil
                    }
                case .failure(let error):
                    errorText = error.displayMessage
                }
            }
        }
    }
}
#endif
