#if os(macOS)
import ConduitCore
import Foundation
import SwiftUI

/// Workspace-local state for the read-only MainFrame Explorer shell.
///
/// This deliberately does not live in AppModel: selecting/expanding files is
/// transient navigation state and must not become task/runtime authority.
@MainActor
final class MainframeExplorerWorkspaceModel: ObservableObject {
    struct VisibleRow: Identifiable {
        let node: MainframeExplorerNode
        let depth: Int
        var id: String { node.id }
    }

    struct ScopePresentation: Equatable {
        let label: String
        let isAuthoritative: Bool
    }

    @Published private(set) var root: URL?
    @Published private(set) var rootNodes: [MainframeExplorerNode] = []
    @Published private(set) var childrenByDirectory: [String: [MainframeExplorerNode]] = [:]
    @Published private(set) var expandedPaths = Set<String>()
    @Published private(set) var selectedNode: MainframeExplorerNode?
    @Published private(set) var documentText: String?
    @Published private(set) var documentMessage: String?
    @Published private(set) var rootError: String?
    @Published private(set) var lifecycleMessage: String?
    @Published private(set) var quickOpenEntries: [MainframeExplorerNode] = []
    @Published private(set) var quickOpenTruncated = false
    @Published private(set) var isIndexing = false
    @Published var quickOpenQuery = ""
    @Published var isQuickOpenPresented = false
    @Published private(set) var navigationRevision = 0

    private var nodesByPath: [String: MainframeExplorerNode] = [:]
    private var lifecycleScan: MainframeLifecycleScan?
    private var history = MainframeNavigationHistory()
    private let scanner = MainframeExplorerScanner()
    private let lifecycleScanner = MainframeLifecycleScanner()
    private var indexGeneration = UUID()

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    var lifecycleRootRows: [VisibleRow] {
        visibleRows(
            from: orderedRootNodes.filter {
                Self.lifecycleRootOrder.contains($0.name)
            }
        )
    }

    var systemRootRows: [VisibleRow] {
        visibleRows(
            from: orderedRootNodes.filter {
                !Self.lifecycleRootOrder.contains($0.name)
            }
        )
    }

    var quickOpenMatches: [MainframeExplorerNode] {
        MainframeQuickOpen.matches(
            quickOpenEntries,
            query: quickOpenQuery,
            limit: 80
        )
    }

    var breadcrumbPaths: [String] {
        guard let path = selectedNode?.relativePath else { return [""] }
        let parts = Self.pathParts(path)
        var result = [""]
        var current: [String] = []
        for part in parts {
            current.append(part)
            result.append(current.joined(separator: "/"))
        }
        return result
    }

    func configure(root newRoot: URL) {
        let normalized = newRoot.standardizedFileURL
        if root?.standardizedFileURL == normalized { return }

        indexGeneration = UUID()
        root = normalized
        rootNodes = []
        childrenByDirectory = [:]
        expandedPaths = []
        selectedNode = nil
        documentText = nil
        documentMessage = nil
        rootError = nil
        lifecycleMessage = nil
        quickOpenEntries = []
        quickOpenTruncated = false
        isIndexing = false
        quickOpenQuery = ""
        history = MainframeNavigationHistory()
        navigationRevision += 1
        nodesByPath = [:]
        lifecycleScan = nil

        do {
            let nodes = try scanner.rootChildren(root: normalized)
            cache(nodes, forDirectoryPath: "")
            rootNodes = nodes
        } catch {
            rootError = error.localizedDescription
            return
        }

        do {
            lifecycleScan = try lifecycleScanner.scan(root: normalized)
            if let issues = lifecycleScan?.issues, !issues.isEmpty {
                lifecycleMessage = "Lifecycle authority reported \(issues.count) issue\(issues.count == 1 ? "" : "s"). Invalid records remain unverified."
            }
        } catch {
            lifecycleMessage = "Lifecycle authority unavailable: \(error.localizedDescription)"
        }

        buildQuickOpenIndex(root: normalized)
    }

    func toggle(_ node: MainframeExplorerNode) {
        switch node.kind {
        case .directory:
            select(node, recordHistory: true)
            if expandedPaths.contains(node.relativePath) {
                expandedPaths.remove(node.relativePath)
            } else {
                loadChildrenIfNeeded(for: node)
                expandedPaths.insert(node.relativePath)
            }
        case .file, .symbolicLink:
            select(node, recordHistory: true)
        }
    }

    func select(_ node: MainframeExplorerNode, recordHistory: Bool = true) {
        selectedNode = node
        if recordHistory {
            history.visit(node.relativePath)
            navigationRevision += 1
        }
        documentText = nil
        documentMessage = nil

        guard let root else {
            documentMessage = "No MainFrame root is selected."
            return
        }

        switch node.kind {
        case .directory:
            documentMessage = "Directory · read-only"
        case .symbolicLink:
            documentMessage = "Symbolic link · Explorer does not follow links."
        case .file:
            do {
                documentText = try scanner.readUTF8Text(root: root, file: node.url)
            } catch {
                documentMessage = error.localizedDescription
            }
        }
    }

    func goBack() {
        guard let path = history.goBack() else { return }
        navigationRevision += 1
        revealAndSelect(relativePath: path, recordHistory: false)
    }

    func goForward() {
        guard let path = history.goForward() else { return }
        navigationRevision += 1
        revealAndSelect(relativePath: path, recordHistory: false)
    }

    func revealAndSelect(_ node: MainframeExplorerNode) {
        revealAndSelect(relativePath: node.relativePath, recordHistory: true)
    }

    func selectBreadcrumb(_ relativePath: String) {
        if relativePath.isEmpty {
            selectedNode = nil
            documentText = nil
            documentMessage = "MainFrame root · read-only"
            return
        }
        revealAndSelect(relativePath: relativePath, recordHistory: true)
    }

    func scopePresentation(for node: MainframeExplorerNode) -> ScopePresentation? {
        guard let scope = node.recordScope else { return nil }
        let pathLabel = scope.recordType == .project ? "PROJECT PATH" : "OPERATION PATH"
        guard let scan = lifecycleScan else {
            return ScopePresentation(label: "UNVERIFIED \(pathLabel)", isAuthoritative: false)
        }
        let matches = scan.bySlug[scope.slug] ?? []
        guard matches.count == 1, let record = matches.first, record.isValid else {
            return ScopePresentation(label: "UNVERIFIED \(pathLabel)", isAuthoritative: false)
        }
        let expected: MainframeLifecycleRecordType = scope.recordType == .project ? .project : .operation
        guard record.recordType == expected else {
            return ScopePresentation(label: "UNVERIFIED \(pathLabel)", isAuthoritative: false)
        }
        return ScopePresentation(
            label: expected == .project ? "PROJECT" : "OPERATION",
            isAuthoritative: true
        )
    }

    func breadcrumbLabel(for relativePath: String) -> String {
        guard !relativePath.isEmpty else { return "MainFrame" }
        return relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    }

    private func revealAndSelect(relativePath: String, recordHistory: Bool) {
        guard let root else { return }
        if let known = nodesByPath[relativePath] {
            expandAncestors(of: relativePath, root: root)
            select(known, recordHistory: recordHistory)
            return
        }

        expandAncestors(of: relativePath, root: root)
        if let discovered = nodesByPath[relativePath] {
            select(discovered, recordHistory: recordHistory)
        } else {
            documentText = nil
            documentMessage = "The previously visited path is no longer present in the current read-only scan."
        }
    }

    private func expandAncestors(of relativePath: String, root: URL) {
        let parts = Self.pathParts(relativePath)
        guard parts.count > 1 else { return }
        var parentPath = ""

        for component in parts.dropLast() {
            let currentPath = parentPath.isEmpty ? component : "\(parentPath)/\(component)"
            if nodesByPath[currentPath] == nil {
                loadDirectory(path: parentPath, root: root)
            }
            if let node = nodesByPath[currentPath], node.kind == .directory {
                loadChildrenIfNeeded(for: node)
                expandedPaths.insert(currentPath)
            }
            parentPath = currentPath
        }
    }

    private func loadDirectory(path: String, root: URL) {
        if path.isEmpty {
            if childrenByDirectory[""] == nil {
                do {
                    let nodes = try scanner.rootChildren(root: root)
                    cache(nodes, forDirectoryPath: "")
                    rootNodes = nodes
                } catch {
                    rootError = error.localizedDescription
                }
            }
            return
        }
        guard let node = nodesByPath[path], node.kind == .directory else { return }
        loadChildrenIfNeeded(for: node)
    }

    private func loadChildrenIfNeeded(for node: MainframeExplorerNode) {
        guard childrenByDirectory[node.relativePath] == nil, let root else { return }
        do {
            let nodes = try scanner.children(root: root, directory: node.url)
            cache(nodes, forDirectoryPath: node.relativePath)
        } catch {
            documentText = nil
            documentMessage = error.localizedDescription
        }
    }

    private func cache(_ nodes: [MainframeExplorerNode], forDirectoryPath path: String) {
        childrenByDirectory[path] = nodes
        for node in nodes {
            nodesByPath[node.relativePath] = node
        }
    }

    private func buildQuickOpenIndex(root: URL) {
        let generation = UUID()
        indexGeneration = generation
        isIndexing = true

        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    try MainframeExplorerScanner().buildIndex(root: root, maxEntries: 20_000)
                }.value
                guard let self, self.indexGeneration == generation else { return }
                self.quickOpenEntries = result.entries
                self.quickOpenTruncated = result.truncated
                self.isIndexing = false
            } catch {
                guard let self, self.indexGeneration == generation else { return }
                self.isIndexing = false
                self.lifecycleMessage = [
                    self.lifecycleMessage,
                    "Quick Open index unavailable: \(error.localizedDescription)"
                ].compactMap { $0 }.joined(separator: " ")
            }
        }
    }

    private var orderedRootNodes: [MainframeExplorerNode] {
        let rank = Dictionary(
            uniqueKeysWithValues: Self.lifecycleRootOrder.enumerated().map { ($0.element, $0.offset) }
        )
        return rootNodes.sorted { lhs, rhs in
            let leftRank = rank[lhs.name]
            let rightRank = rank[rhs.name]
            switch (leftRank, rightRank) {
            case let (.some(left), .some(right)):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func visibleRows(from roots: [MainframeExplorerNode]) -> [VisibleRow] {
        var rows: [VisibleRow] = []
        for node in roots {
            appendVisible(node, depth: 0, to: &rows)
        }
        return rows
    }

    private func appendVisible(
        _ node: MainframeExplorerNode,
        depth: Int,
        to rows: inout [VisibleRow]
    ) {
        rows.append(VisibleRow(node: node, depth: depth))
        guard node.kind == .directory, expandedPaths.contains(node.relativePath) else { return }
        for child in childrenByDirectory[node.relativePath] ?? [] {
            appendVisible(child, depth: depth + 1, to: &rows)
        }
    }

    private static let lifecycleRootOrder = [
        "00_inbox", "01_ingest", "10_knowledge", "20_live",
        "30_projects", "40_operations", "90_archive"
    ]

    private static func pathParts(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

/// Self-contained v0 shell. RootView only needs to route the Explore workspace
/// here; no task/runtime model is mutated or remounted.
struct MainframeExplorerWorkspaceView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let root: URL
    @StateObject private var explorer = MainframeExplorerWorkspaceModel()

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
            reader
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.app)
        .task(id: root.standardizedFileURL.path) {
            explorer.configure(root: root)
        }
        .sheet(isPresented: $explorer.isQuickOpenPresented) {
            quickOpenSheet
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MainFrame Explorer")
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EXPLORE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(palette.faint)
                    Text("MainFrame · read-only")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                }
                Spacer()
                Button {
                    explorer.isQuickOpenPresented = true
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("p", modifiers: [.command])
                .help("Quick Open (Command-P)")
                .accessibilityLabel("Quick Open")
            }
            .padding(12)

            Divider().overlay(palette.line)

            if let rootError = explorer.rootError {
                explorerError(rootError)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        sectionLabel("LIFECYCLE")
                        ForEach(explorer.lifecycleRootRows) { row in
                            treeRow(row)
                        }

                        if !explorer.systemRootRows.isEmpty {
                            sectionLabel("SYSTEM")
                                .padding(.top, 8)
                            ForEach(explorer.systemRootRows) { row in
                                treeRow(row)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            if let message = explorer.lifecycleMessage {
                Divider().overlay(palette.line)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .accessibilityLabel("Explorer authority note")
            }
        }
        .background(palette.rail)
    }

    private var reader: some View {
        VStack(spacing: 0) {
            readerToolbar
            Divider().overlay(palette.line)
            readerContent
        }
        .background(palette.sink)
    }

    private var readerToolbar: some View {
        HStack(spacing: 8) {
            Button(action: explorer.goBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .disabled(!explorer.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")

            Button(action: explorer.goForward) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!explorer.canGoForward)
            .help("Forward")
            .accessibilityLabel("Forward")

            Divider().frame(height: 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(explorer.breadcrumbPaths, id: \.self) { path in
                        Button(explorer.breadcrumbLabel(for: path)) {
                            explorer.selectBreadcrumb(path)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                        if path != explorer.breadcrumbPaths.last {
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(palette.faint)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }

            Spacer(minLength: 8)

            if let selected = explorer.selectedNode,
               let scope = explorer.scopePresentation(for: selected) {
                Text(scope.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(scope.isAuthoritative ? palette.dim : palette.faint)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .overlay(
                        Capsule().strokeBorder(palette.line, lineWidth: 1)
                    )
                    .accessibilityLabel(scope.label)
            }

            Text("READ ONLY")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(palette.faint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface)
    }

    @ViewBuilder
    private var readerContent: some View {
        if let text = explorer.documentText, let selected = explorer.selectedNode {
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(18)
            }
            .accessibilityLabel("Read-only source for \(selected.name)")
        } else if let selected = explorer.selectedNode {
            VStack(alignment: .leading, spacing: 12) {
                Label(selected.name, systemImage: symbol(for: selected))
                    .font(.title2.bold())
                    .foregroundStyle(palette.text)
                Text(selected.relativePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.dim)
                    .textSelection(.enabled)
                if let message = explorer.documentMessage {
                    Text(message)
                        .foregroundStyle(palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 42))
                    .foregroundStyle(palette.dim)
                Text("Browse MainFrame")
                    .font(.title2.bold())
                    .foregroundStyle(palette.text)
                Text("Choose a file in the read-only tree, or use Command-P for bounded Quick Open. Explorer follows the filesystem; lifecycle validity remains a separate authority check.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: 520)
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var quickOpenSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Quick Open", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                if explorer.isIndexing {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)

            TextField("Path or file name", text: $explorer.quickOpenQuery)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            if explorer.quickOpenTruncated {
                Text("Bounded index: results may be incomplete because the 20,000-entry limit was reached.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider().overlay(palette.line)

            List(explorer.quickOpenMatches) { node in
                Button {
                    explorer.revealAndSelect(node)
                    explorer.isQuickOpenPresented = false
                    explorer.quickOpenQuery = ""
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: symbol(for: node))
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
                    }
                }
                .buttonStyle(.plain)
            }
            .scrollContentBackground(.hidden)
        }
        .background(palette.app)
        .frame(width: 680, height: 520)
    }

    private func treeRow(_ row: MainframeExplorerWorkspaceModel.VisibleRow) -> some View {
        let selected = explorer.selectedNode?.id == row.node.id
        return Button {
            explorer.toggle(row.node)
        } label: {
            HStack(spacing: 6) {
                if row.node.kind == .directory {
                    Image(systemName: explorer.expandedPaths.contains(row.node.relativePath)
                        ? "chevron.down"
                        : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.faint)
                        .frame(width: 10)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Image(systemName: symbol(for: row.node))
                    .foregroundStyle(palette.dim)
                    .frame(width: 16)
                Text(rootDisplayName(row.node))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(row.depth) * 14 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(selected ? palette.accent.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(row.node.relativePath)
        .accessibilityLabel("\(row.node.name), \(row.node.kind.rawValue)")
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.0)
            .foregroundStyle(palette.faint)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
    }

    private func explorerError(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Explorer unavailable", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(palette.text)
            Text(text)
                .font(.caption)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func rootDisplayName(_ node: MainframeExplorerNode) -> String {
        guard !node.relativePath.contains("/") else { return node.name }
        switch node.name {
        case "00_inbox": return "Inbox"
        case "01_ingest": return "Ingest"
        case "10_knowledge": return "Knowledge"
        case "20_live": return "Live"
        case "30_projects": return "Projects"
        case "40_operations": return "Operations"
        case "90_archive": return "Archive"
        default: return node.name
        }
    }

    private func symbol(for node: MainframeExplorerNode) -> String {
        if !node.relativePath.contains("/") {
            switch node.zone {
            case .inbox: return "tray"
            case .ingest: return "arrow.down.doc"
            case .knowledge: return "books.vertical"
            case .live: return "dot.radiowaves.left.and.right"
            case .projects: return "hammer"
            case .operations: return "gearshape.2"
            case .archive: return "archivebox"
            case .system: break
            }
        }
        switch node.kind {
        case .directory: return "folder"
        case .file: return "doc.text"
        case .symbolicLink: return "link"
        }
    }
}
#endif
