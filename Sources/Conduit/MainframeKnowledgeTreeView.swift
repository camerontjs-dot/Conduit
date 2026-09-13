#if os(macOS)
import ConduitCore
import SwiftUI

struct MainframeKnowledgeTreeView: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("MainFrame", systemImage: "externaldrive")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Spacer()
                Button {
                    model.collapseAll()
                } label: {
                    Image(systemName: "rectangle.compress.vertical")
                }
                .buttonStyle(.plain)
                .help("Collapse all folders")
                .accessibilityLabel("Collapse all folders")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)

            Divider().overlay(palette.line)

            if let error = model.loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .padding(10)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.rootChildren) { node in
                        MainframeKnowledgeTreeNodeView(model: model, node: node, depth: 0)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(palette.rail)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MainFrame file tree")
    }
}

private struct MainframeKnowledgeTreeNodeView: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel
    let node: MainframeExplorerNode
    let depth: Int
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }
    private var selected: Bool { model.selectedPath == node.relativePath }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if node.kind == .directory {
                    model.toggleDirectory(node)
                }
                model.select(node)
            } label: {
                HStack(spacing: 6) {
                    if node.kind == .directory {
                        Image(systemName: model.isExpanded(node) ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 10)
                            .foregroundStyle(palette.faint)
                    } else {
                        Color.clear.frame(width: 10, height: 1)
                    }

                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                        .frame(width: 16)

                    Text(node.name)
                        .font(.system(size: 12.5))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 4)

                    if let badge = model.authorityBadge(for: node), node.relativePath.split(separator: "/").count == 2 {
                        Text(badge.label)
                            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(badge.label == "UNVERIFIED" ? palette.dim : palette.accent)
                            .help(badge.detail)
                    }
                }
                .padding(.leading, CGFloat(depth) * 13 + 8)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .background(selected ? palette.accent.opacity(0.12) : Color.clear)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .help(node.relativePath)

            if node.kind == .directory, model.isExpanded(node) {
                ForEach(model.children(of: node)) { child in
                    MainframeKnowledgeTreeNodeView(model: model, node: child, depth: depth + 1)
                }
            }
        }
    }

    private var iconName: String {
        switch node.kind {
        case .directory:
            switch node.zone {
            case .inbox: return "tray"
            case .ingest: return "arrow.down.doc"
            case .knowledge: return "books.vertical"
            case .live: return "waveform.path.ecg"
            case .projects: return "hammer"
            case .operations: return "gearshape.2"
            case .archive: return "archivebox"
            case .system: return "folder"
            }
        case .file:
            return node.url.pathExtension.lowercased() == "md" ? "doc.richtext" : "doc.text"
        case .symbolicLink:
            return "link"
        }
    }

    private var iconColor: Color {
        node.kind == .symbolicLink ? palette.faint : palette.dim
    }

    private var accessibilityLabel: String {
        let kind: String
        switch node.kind {
        case .directory: kind = "folder"
        case .file: kind = "file"
        case .symbolicLink: kind = "symbolic link, not followed"
        }
        if let badge = model.authorityBadge(for: node), node.relativePath.split(separator: "/").count == 2 {
            return "\(node.name), \(kind), \(badge.label.lowercased())"
        }
        return "\(node.name), \(kind)"
    }
}
#endif
