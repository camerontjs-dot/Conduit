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
    @State private var hits: [MindGraphHit] = []
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
        } else if hits.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 28))
                    .foregroundStyle(palette.faint)
                Text(lastQueryLabel == nil
                    ? "Query knowledge, project or operations context"
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
                    ForEach(hits) { hit in
                        hitCard(hit)
                    }
                }
                .padding(12)
            }
        }
    }

    private func hitCard(_ hit: MindGraphHit) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(hit.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                Spacer(minLength: 4)
                Text(hit.scope.displayName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(palette.accentSoft)
                    .clipShape(Capsule())
            }
            Text(hit.displayPath)
                .font(.caption2.monospaced())
                .foregroundStyle(palette.dim)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(hit.chunkText.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.caption)
                .foregroundStyle(palette.text)
                .lineLimit(8)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text("trust: \(hit.trustProfile)")
                if let indexID = hit.indexID {
                    Text("index: \(indexID)")
                }
                if let score = hit.rrfScore {
                    Text(String(format: "rrf %.3f", score))
                }
                if let signal = hit.signal {
                    Text(signal)
                }
                Spacer()
                if let onOpenPath {
                    Button {
                        onOpenPath(hit.displayPath)
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
                            nonEffect: "Does not make the MindGraph nomination an authored link or verified fact.",
                            target: hit.displayPath,
                            authority: "Semantic nomination routed to filesystem lookup"
                        )
                    )
                }
            }
            .font(.caption2)
            .foregroundStyle(palette.faint)
            ForEach(hit.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
            }
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
            Text("Uses ~/.mindgraph indexes via bin/mindgraph. Knowledge, Projects and Operations stay separate. Results are nominations, not verified claims.")
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
        hits = []
        lastQueryLabel = "\(scope.displayName) · top \(topK) · \(q)"
        Task {
            let result = await model.queryMindGraph(
                question: q,
                scope: scope,
                topK: topK
            )
            await MainActor.run {
                isRunning = false
                switch result {
                case .success(let rows):
                    hits = rows
                    onResults?(rows)
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
