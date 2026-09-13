#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

struct MainframeMarkdownReaderView: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel
    @Binding var headingTarget: String?
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            readerHeader
            Divider().overlay(palette.line)
            content
        }
        .background(palette.app)
    }

    private var readerHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedTitle)
                    .font(.headline)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(model.selectedPath ?? "Select a file or folder")
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if model.selectedDocument != nil {
                Picker("Reader mode", selection: $model.readerMode) {
                    ForEach(MainframeReaderMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                .accessibilityLabel("Markdown reader mode")
            }
            Label("Read only", systemImage: "lock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.dim)
                .accessibilityLabel("Read-only file viewer")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.readError {
            readerMessage(title: "Cannot open this item", detail: error, symbol: "exclamationmark.triangle")
        } else if model.selectedNode?.kind == .symbolicLink {
            readerMessage(
                title: "Symbolic link",
                detail: "Explorer shows symbolic links as leaves and does not traverse them.",
                symbol: "link"
            )
        } else if model.selectedNode?.kind == .directory {
            folderSummary
        } else if let document = model.selectedDocument, model.readerMode == .rendered {
            rendered(document)
        } else if let text = model.selectedText {
            source(text)
        } else {
            readerMessage(
                title: "Read MainFrame",
                detail: "Choose a file in the tree, use Quick Open, Search, Graph, or Workstation to navigate here.",
                symbol: "doc.text.magnifyingglass"
            )
        }
    }

    private func source(_ text: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(18)
        }
        .background(palette.sink)
        .accessibilityLabel("Read-only source")
    }

    private func rendered(_ document: MainframeMarkdownDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !document.frontmatter.isEmpty {
                        frontmatterCard(document.frontmatter)
                    }
                    ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                        markdownBlock(block)
                    }
                    localImages(document)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(palette.app)
            .onChange(of: headingTarget) { target in
                guard let target else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                DispatchQueue.main.async { headingTarget = nil }
            }
        }
        .accessibilityLabel("Rendered Markdown, read only")
    }

    @ViewBuilder
    private func markdownBlock(_ block: MainframeMarkdownBlock) -> some View {
        switch block {
        case .heading(let heading):
            Text(heading.text)
                .font(headingFont(heading.level))
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .id(heading.id)
                .padding(.top, heading.level <= 2 ? 8 : 2)
        case .paragraph(let text):
            inlineMarkdown(text)
                .font(.body)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(palette.dim)
                        inlineMarkdown(item).textSelection(.enabled)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(palette.dim)
                            .frame(minWidth: 24, alignment: .trailing)
                        inlineMarkdown(item).textSelection(.enabled)
                    }
                }
            }
        case .blockquote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(palette.accent.opacity(0.6))
                    .frame(width: 3)
                inlineMarkdown(text)
                    .foregroundStyle(palette.dim)
                    .italic()
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        case .fencedCode(let language, let text):
            VStack(alignment: .leading, spacing: 7) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(palette.faint)
                }
                ScrollView(.horizontal) {
                    Text(text)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .background(palette.sink)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .table(let table):
            markdownTable(table)
        case .horizontalRule:
            Divider().overlay(palette.line)
        }
    }

    private func markdownTable(_ table: MainframeMarkdownTable) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                        inlineMarkdown(header)
                            .font(.caption.weight(.semibold))
                            .padding(8)
                            .frame(minWidth: 110, alignment: .leading)
                    }
                }
                .background(palette.surface)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inlineMarkdown(cell)
                                .font(.caption)
                                .padding(8)
                                .frame(minWidth: 110, alignment: .leading)
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder
    private func localImages(_ document: MainframeMarkdownDocument) -> some View {
        let images = model.selectedOutgoingLinks.filter { $0.link.isImage }
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Local images")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                ForEach(images) { record in
                    switch record.resolution {
                    case .local(let path, _):
                        if let image = safeImage(relativePath: path) {
                            VStack(alignment: .leading, spacing: 5) {
                                Image(nsImage: image)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 640, maxHeight: 480, alignment: .leading)
                                    .accessibilityLabel(record.link.label.isEmpty ? "Local image" : record.link.label)
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(palette.faint)
                            }
                        }
                    default:
                        EmptyView()
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    private func safeImage(relativePath: String) -> NSImage? {
        let ext = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "gif", "tiff", "heic", "webp"].contains(ext) else { return nil }
        let url = model.root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = model.root.standardizedFileURL.path
        guard url.path == rootPath || url.path.hasPrefix(rootPath + "/") else { return nil }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { return nil }
        return NSImage(contentsOf: url)
    }

    private func frontmatterCard(_ values: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Document metadata")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.dim)
            ForEach(values.keys.sorted(), id: \.self) { key in
                HStack(alignment: .firstTextBaseline) {
                    Text(key)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.faint)
                        .frame(width: 110, alignment: .leading)
                    Text(values[key] ?? "")
                        .font(.caption)
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                }
            }
            Text("Display metadata only · lifecycle authority is validated separately")
                .font(.caption2)
                .foregroundStyle(palette.faint)
                .padding(.top, 3)
        }
        .padding(12)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var folderSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 32))
                .foregroundStyle(palette.dim)
            Text(model.selectedTitle)
                .font(.title2.bold())
                .foregroundStyle(palette.text)
            if let node = model.selectedNode, let badge = model.authorityBadge(for: node) {
                Label(badge.label, systemImage: badge.label == "UNVERIFIED" ? "questionmark.circle" : "checkmark.seal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badge.label == "UNVERIFIED" ? palette.dim : palette.accent)
                Text(badge.detail)
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            }
            Text("Expand this folder in the tree or use Search and Graph to navigate its contents.")
                .foregroundStyle(palette.dim)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func readerMessage(title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(palette.dim)
            Text(title).font(.title3.bold()).foregroundStyle(palette.text)
            Text(detail)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.dim)
                .frame(maxWidth: 480)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .largeTitle.bold()
        case 2: return .title.bold()
        case 3: return .title2.bold()
        case 4: return .title3.bold()
        default: return .headline
        }
    }

    private func inlineMarkdown(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) {
            return Text(attributed)
        }
        return Text(text)
    }
}
#endif
