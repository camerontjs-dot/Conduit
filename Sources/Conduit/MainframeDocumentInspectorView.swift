#if os(macOS)
import ConduitCore
import SwiftUI

private enum MainframeDocumentInspectorTab: String, CaseIterable, Identifiable {
    case outline
    case links
    case related
    case document

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct MainframeDocumentInspectorView: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel
    @Binding var headingTarget: String?
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: MainframeDocumentInspectorTab = .outline
    @State private var relatedScope: MindGraphScope = .knowledge

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Document inspector", selection: $tab) {
                ForEach(MainframeDocumentInspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(9)

            Divider().overlay(palette.line)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .outline: outline
                    case .links: links
                    case .related: related
                    case .document: documentFacts
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .background(palette.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Explorer document inspector")
    }

    @ViewBuilder
    private var outline: some View {
        if let document = model.selectedDocument, !document.headings.isEmpty {
            Text("Outline")
                .font(.headline)
                .foregroundStyle(palette.text)
            ForEach(document.headings) { heading in
                Button {
                    headingTarget = heading.id
                    model.readerMode = .rendered
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("H\(heading.level)")
                            .font(.caption2.monospaced().weight(.bold))
                            .foregroundStyle(palette.faint)
                        Text(heading.text)
                            .font(.caption)
                            .foregroundStyle(palette.text)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(max(0, heading.level - 1)) * 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Heading level \(heading.level), \(heading.text)")
            }
        } else {
            empty("No Markdown outline for this selection.")
        }
    }

    @ViewBuilder
    private var links: some View {
        if model.selectedOutgoingLinks.isEmpty && model.selectedBacklinks.isEmpty {
            empty("No indexed Markdown links for this selection.")
        } else {
            if !model.selectedOutgoingLinks.isEmpty {
                sectionTitle("Outgoing")
                ForEach(model.selectedOutgoingLinks) { record in
                    linkRow(record)
                }
            }
            if !model.selectedBacklinks.isEmpty {
                sectionTitle("Backlinks")
                ForEach(model.selectedBacklinks) { record in
                    Button {
                        model.open(relativePath: record.sourcePath)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.sourcePath)
                                .font(.caption)
                                .foregroundStyle(palette.text)
                                .lineLimit(2)
                            Text("Authored link at line \(record.link.line)")
                                .font(.caption2)
                                .foregroundStyle(palette.faint)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func linkRow(_ record: MainframeDocumentLinkRecord) -> some View {
        switch record.resolution {
        case .local(let path, let anchor):
            Button {
                model.open(relativePath: path)
                if let anchor { headingTarget = anchor }
            } label: {
                linkLabel(
                    title: record.link.label.isEmpty ? path : record.link.label,
                    detail: anchor.map { "\(path)#\($0)" } ?? path,
                    symbol: record.link.isImage ? "photo" : "arrow.turn.down.right"
                )
            }
            .buttonStyle(.plain)
        case .sameDocumentAnchor(let anchor):
            Button {
                headingTarget = anchor
                model.readerMode = .rendered
            } label: {
                linkLabel(title: record.link.label, detail: "#\(anchor)", symbol: "number")
            }
            .buttonStyle(.plain)
        case .external(let raw):
            if let url = URL(string: raw) {
                Link(destination: url) {
                    linkLabel(title: record.link.label.isEmpty ? raw : record.link.label, detail: raw, symbol: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
            } else {
                linkLabel(title: record.link.label, detail: raw, symbol: "questionmark.circle")
            }
        case .unresolved(let reason):
            VStack(alignment: .leading, spacing: 2) {
                Label(record.link.label.isEmpty ? record.link.target : record.link.label, systemImage: "exclamationmark.link")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                Text(record.link.target)
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.faint)
                    .textSelection(.enabled)
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
        }
    }

    private var related: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Related")
                .font(.headline)
                .foregroundStyle(palette.text)
            Text("MindGraph nominations are separate from deterministic Find. They do not become authored links or verified relationships.")
                .font(.caption)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            Picker("MindGraph scope", selection: $relatedScope) {
                ForEach(MindGraphScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            TextField("Question or concept", text: $model.radarQuestion)
                .textFieldStyle(.roundedBorder)

            Button {
                runRelatedQuery()
            } label: {
                if model.isRadarLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Find related", systemImage: "sparkle.magnifyingglass")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRadarLoading || relatedQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let error = model.radarError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }

            if !model.radarHits.isEmpty {
                sectionTitle("Nominations")
                ForEach(model.radarHits) { hit in
                    Button {
                        model.open(relativePath: hit.displayPath)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.text)
                                .multilineTextAlignment(.leading)
                            Text(hit.displayPath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(palette.faint)
                                .lineLimit(2)
                            HStack(spacing: 5) {
                                Text(hit.scope.displayName)
                                Text("·")
                                Text(hit.trustProfile)
                                if let score = hit.rrfScore {
                                    Text("· rrf \(score, format: .number.precision(.fractionLength(3)))")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(palette.dim)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var documentFacts: some View {
        if let node = model.selectedNode {
            sectionTitle("Document")
            fact("Path", node.relativePath)
            fact("Kind", node.kind.rawValue)
            fact("Region", node.zone.rawValue)
            if let record = model.contentIndex?.records.first(where: { $0.path == node.relativePath }) {
                fact("Indexed bytes", "\(record.byteCount)")
            }
            if let badge = model.authorityBadge(for: node) {
                fact("Lifecycle", badge.label)
                Text(badge.detail)
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            if let document = model.selectedDocument {
                fact("Headings", "\(document.headings.count)")
                fact("Authored links", "\(document.links.count)")
            }
            let checklist = model.selectedChecklist
            if checklist.hasLiteralDenominator {
                sectionTitle("Literal checklist")
                Text("\(checklist.completedCount) of \(checklist.totalCount) checked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text("This count exists only because the source contains an explicit task-list denominator. It is not project progress.")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                ForEach(checklist.items) { item in
                    Label(item.text, systemImage: item.isChecked ? "checkmark.square" : "square")
                        .font(.caption)
                        .foregroundStyle(item.isChecked ? palette.dim : palette.text)
                }
            }
        } else {
            empty("Select a file or folder to inspect its direct facts.")
        }
    }

    private var relatedQuestion: String {
        let explicit = model.radarQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        return model.selectedTitle
    }

    private func runRelatedQuery() {
        let question = relatedQuestion
        model.radarQuestion = question
        let scope = relatedScope
        model.beginRadarQuery(scope: scope)
        Task {
            let result = await appModel.queryMindGraph(question: question, scope: scope, topK: 12)
            model.applyRadarResult(result, scope: scope)
        }
    }

    private func linkLabel(title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(palette.dim)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(palette.text)
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.faint)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.faint)
            Text(value)
                .font(.caption)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.dim)
            .textCase(.uppercase)
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(palette.faint)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
