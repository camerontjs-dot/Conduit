#if os(macOS)
import ConduitCore
import SwiftUI

struct MainframeQuickOpenSheet: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(palette.dim)
                TextField("Quick Open", text: $model.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { openFirst() }
                Button("Done") { dismiss() }
            }
            .padding(12)

            if model.indexMayBeIncomplete {
                Label("Bounded index: matching files may exist beyond the current 20,000-entry/content bounds.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(palette.line)

            List(model.quickOpenMatches) { node in
                Button {
                    model.open(relativePath: node.relativePath)
                    dismiss()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: nodeSymbol(node))
                            .foregroundStyle(palette.dim)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                                .foregroundStyle(palette.text)
                            Text(node.relativePath)
                                .font(.caption2.monospaced())
                                .foregroundStyle(palette.faint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(palette.surface)
            }
            .scrollContentBackground(.hidden)
        }
        .background(palette.app)
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand { dismiss() }
    }

    private func openFirst() {
        guard let first = model.quickOpenMatches.first else { return }
        model.open(relativePath: first.relativePath)
        dismiss()
    }

    private func nodeSymbol(_ node: MainframeExplorerNode) -> String {
        switch node.kind {
        case .directory: return "folder"
        case .file: return "doc.text"
        case .symbolicLink: return "link"
        }
    }
}

struct MainframeSearchSheet: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel
    @Binding var headingTarget: String?
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }
    private var result: MainframeSearchResult { model.searchResult }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.dim)
                TextField("Find exact text, headings, metadata, tags, names, or paths", text: $model.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                Button("Done") { dismiss() }
            }
            .padding(12)

            HStack {
                Text("Deterministic Find · no semantic inference")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                Spacer()
                if !model.searchQuery.isEmpty {
                    Text("\(result.hits.count) shown")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.faint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            if result.mayBeIncomplete {
                Label("Search corpus is bounded; additional matches may exist outside the indexed filesystem/content limits.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(palette.line)

            if model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 34))
                        .foregroundStyle(palette.dim)
                    Text("Search the bounded MainFrame corpus")
                        .font(.headline)
                        .foregroundStyle(palette.text)
                    Text("Find matches path/name, Markdown headings, frontmatter metadata/tags, and exact file content. Related semantic retrieval is separate in the Reader inspector and Radar.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(palette.dim)
                        .frame(maxWidth: 500)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if result.hits.isEmpty {
                Text("No deterministic matches in the indexed corpus.")
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(result.hits) { hit in
                    Button {
                        model.open(relativePath: hit.path)
                        if hit.kind == .heading,
                           let document = model.selectedDocument,
                           let heading = document.headings.first(where: { $0.line == hit.line }) {
                            headingTarget = heading.id
                            model.readerMode = .rendered
                        }
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: hitSymbol(hit.kind))
                                .foregroundStyle(palette.dim)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(hit.path)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(palette.text)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Text(hit.kind.rawValue.uppercased())
                                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                                        .foregroundStyle(palette.faint)
                                }
                                if !hit.excerpt.isEmpty {
                                    Text(hit.excerpt)
                                        .font(.caption)
                                        .foregroundStyle(palette.dim)
                                        .lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                }
                                if hit.line > 0 {
                                    Text("line \(hit.line)")
                                        .font(.caption2)
                                        .foregroundStyle(palette.faint)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(palette.surface)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .background(palette.app)
        .frame(minWidth: 760, minHeight: 600)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand { dismiss() }
    }

    private func hitSymbol(_ kind: MainframeSearchHitKind) -> String {
        switch kind {
        case .path: return "folder.badge.questionmark"
        case .heading: return "textformat.size"
        case .metadata: return "tag"
        case .content: return "text.magnifyingglass"
        }
    }
}

struct MainframeRecentMenuContent: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel

    var body: some View {
        if model.recent.paths.isEmpty {
            Text("No recent files")
        } else {
            ForEach(model.recent.paths, id: \.self) { path in
                Button(URL(fileURLWithPath: path).lastPathComponent) {
                    model.open(relativePath: path)
                }
                .help(path)
            }
        }
    }
}
#endif
