#if os(macOS)
import AppKit
import ConduitCore
import Foundation
import SwiftUI

/// Workspace-local state for MainFrame Explorer.
///
/// Navigation and edit-buffer state deliberately do not live in AppModel:
/// selecting files and holding an unsaved draft must not become task/runtime
/// authority.
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
    @Published private(set) var symlinkInspection: MainframeSymlinkInspection?
    @Published private(set) var rootError: String?
    @Published private(set) var lifecycleMessage: String?
    @Published private(set) var quickOpenEntries: [MainframeExplorerNode] = []
    @Published private(set) var quickOpenTruncated = false
    @Published private(set) var isIndexing = false
    @Published var quickOpenQuery = ""
    @Published var isQuickOpenPresented = false
    @Published private(set) var navigationRevision = 0

    let editor = MainframeMarkdownEditingSession()

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
        symlinkInspection = nil
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
        editor.clear()

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
        guard navigationAllowed(to: node.relativePath) else { return }
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
            if selectedNode?.id == node.id { return }
            select(node, recordHistory: true)
        }
    }

    func select(_ node: MainframeExplorerNode, recordHistory: Bool = true) {
        guard navigationAllowed(to: node.relativePath) else { return }
        selectedNode = node
        if recordHistory {
            history.visit(node.relativePath)
            navigationRevision += 1
        }
        documentText = nil
        documentMessage = nil
        symlinkInspection = nil

        guard let root else {
            documentMessage = "No MainFrame root is selected."
            editor.clear()
            return
        }

        switch node.kind {
        case .directory:
            editor.clear()
            documentMessage = "Directory · read-only"
        case .symbolicLink:
            editor.clear()
            do {
                symlinkInspection = try scanner.inspectSymbolicLink(root: root, link: node.url)
                documentMessage = "Symbolic link · shown as a leaf; Explorer does not traverse links during scans."
            } catch {
                documentMessage = error.localizedDescription
            }
        case .file:
            do {
                let text = try scanner.readUTF8Text(root: root, file: node.url)
                documentText = text
                if Self.isMarkdown(node) {
                    editor.load(
                        relativePath: node.relativePath,
                        absolutePath: node.url.standardizedFileURL.path,
                        source: text
                    )
                } else {
                    editor.clear()
                }
            } catch {
                editor.clear()
                documentMessage = error.localizedDescription
            }
        }
    }

    func saveEdits() {
        guard let root,
              let selectedNode,
              selectedNode.kind == .file,
              Self.isMarkdown(selectedNode) else {
            editor.noteNavigationBlocked()
            return
        }
        if editor.save(root: root, file: selectedNode.url) {
            documentText = editor.buffer
            documentMessage = nil
        }
    }

    func discardEdits() {
        editor.discard()
    }

    func reloadSelectedFileDiscardingBuffer() {
        guard let root,
              let selectedNode,
              selectedNode.kind == .file,
              Self.isMarkdown(selectedNode) else { return }
        do {
            let text = try scanner.readUTF8Text(root: root, file: selectedNode.url)
            documentText = text
            documentMessage = nil
            editor.load(
                relativePath: selectedNode.relativePath,
                absolutePath: selectedNode.url.standardizedFileURL.path,
                source: text
            )
        } catch {
            documentMessage = error.localizedDescription
        }
    }

    func goBack() {
        guard navigationAllowed(to: nil) else { return }
        guard let path = history.goBack() else { return }
        navigationRevision += 1
        revealAndSelect(relativePath: path, recordHistory: false)
    }

    func goForward() {
        guard navigationAllowed(to: nil) else { return }
        guard let path = history.goForward() else { return }
        navigationRevision += 1
        revealAndSelect(relativePath: path, recordHistory: false)
    }

    func revealAndSelect(_ node: MainframeExplorerNode) {
        revealAndSelect(relativePath: node.relativePath, recordHistory: true)
    }

    func reveal(relativePath: String) {
        revealAndSelect(relativePath: relativePath, recordHistory: true)
    }

    func selectBreadcrumb(_ relativePath: String) {
        guard navigationAllowed(to: relativePath) else { return }
        if relativePath.isEmpty {
            selectedNode = nil
            documentText = nil
            documentMessage = "MainFrame root · read-only"
            symlinkInspection = nil
            editor.clear()
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

    private func navigationAllowed(to relativePath: String?) -> Bool {
        guard editor.hasUnsavedChanges else { return true }
        if let relativePath, relativePath == selectedNode?.relativePath {
            return true
        }
        editor.noteNavigationBlocked()
        return false
    }

    private func revealAndSelect(relativePath: String, recordHistory: Bool) {
        guard navigationAllowed(to: relativePath) else { return }
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
            symlinkInspection = nil
            documentMessage = "The requested path is no longer present in the current scan."
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
            symlinkInspection = nil
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

    private static func isMarkdown(_ node: MainframeExplorerNode) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(node.url.pathExtension.lowercased())
    }
}

/// The application-level NavigationSplitView owns this rail. Explore therefore
/// replaces the task/session rail instead of nesting a second primary sidebar
/// inside the detail pane.
struct MainframeExplorerSidebarView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let root: URL
    @ObservedObject var explorer: MainframeExplorerWorkspaceModel

    @State private var systemExpanded = false
    @State private var focusedScopePath: String?
    @State private var showMindGraph = false

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var primaryLifecycleRows: [MainframeExplorerWorkspaceModel.VisibleRow] {
        explorer.lifecycleRootRows.filter { row in
            let parts = row.node.relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = parts.first else { return true }
            if first == "30_projects" || first == "40_operations" {
                return row.depth <= 1
            }
            return true
        }
    }

    private var focusedScopeNode: MainframeExplorerNode? {
        guard let focusedScopePath else { return nil }
        return explorer.lifecycleRootRows
            .first(where: { $0.node.relativePath == focusedScopePath })?
            .node
    }

    private var focusedScopeRows: [MainframeExplorerWorkspaceModel.VisibleRow] {
        guard let focusedScopePath else { return [] }
        var rows: [MainframeExplorerWorkspaceModel.VisibleRow] = []
        for child in explorer.childrenByDirectory[focusedScopePath] ?? [] {
            appendFocused(child, depth: 0, to: &rows)
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("EXPLORE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(palette.faint)
                    Text("MainFrame")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                }
                Spacer()
                Button {
                    showMindGraph = true
                } label: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.borderless)
                .help("MindGraph related-material query")
                .accessibilityLabel("MindGraph query")

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
                        ForEach(primaryLifecycleRows) { row in
                            treeRow(row, canEnterScope: true)
                        }

                        if let focusedScopeNode {
                            focusedScopeHeader(focusedScopeNode)
                                .padding(.top, 10)
                            if focusedScopeRows.isEmpty {
                                Text("Open the scope to browse its files.")
                                    .font(.caption2)
                                    .foregroundStyle(palette.faint)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(focusedScopeRows) { row in
                                    treeRow(row, canEnterScope: false)
                                }
                            }
                        }

                        if !explorer.systemRootRows.isEmpty {
                            Button {
                                systemExpanded.toggle()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: systemExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(palette.faint)
                                    Text("SYSTEM FILES")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .tracking(1.0)
                                        .foregroundStyle(palette.faint)
                                    Spacer()
                                    Text("\(explorer.systemRootRows.filter { $0.depth == 0 }.count)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(palette.faint)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 8)
                            .help("System/configuration files remain available but are collapsed by default")

                            if systemExpanded {
                                ForEach(explorer.systemRootRows) { row in
                                    treeRow(row, canEnterScope: false)
                                }
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
        .task(id: root.standardizedFileURL.path) {
            explorer.configure(root: root)
        }
        .sheet(isPresented: $explorer.isQuickOpenPresented) {
            quickOpenSheet
        }
        .sheet(isPresented: $showMindGraph) {
            MindGraphQueryView(onOpenPath: revealMindGraphPath)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MainFrame Explorer sidebar")
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

    private func treeRow(
        _ row: MainframeExplorerWorkspaceModel.VisibleRow,
        canEnterScope: Bool
    ) -> some View {
        let selected = explorer.selectedNode?.id == row.node.id
        return Button {
            if canEnterScope && isValidatedWorkRecord(row) {
                explorer.toggle(row.node)
                focusedScopePath = row.node.relativePath
            } else {
                explorer.toggle(row.node)
            }
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
                if canEnterScope,
                   let scope = explorer.scopePresentation(for: row.node),
                   scope.isAuthoritative,
                   row.depth == 1 {
                    Text(scope.label)
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                }
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
        .contextMenu {
            if isValidatedWorkRecord(row) {
                Button("Focus Scope in Sidebar") {
                    explorer.toggle(row.node)
                    focusedScopePath = row.node.relativePath
                }
            }
            Button("Copy MainFrame-relative Path") {
                copyToPasteboard(row.node.relativePath)
            }
            Button("Copy Absolute Path") {
                copyToPasteboard(row.node.url.path)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([row.node.url])
            }
        }
        .accessibilityLabel("\(row.node.name), \(row.node.kind.rawValue)")
    }

    private func focusedScopeHeader(_ node: MainframeExplorerNode) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(explorer.scopePresentation(for: node)?.label ?? "CURRENT SCOPE")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(palette.faint)
                Text(node.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                focusedScopePath = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(palette.faint)
            }
            .buttonStyle(.borderless)
            .help("Close focused scope")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(palette.surface.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 6)
    }

    private func appendFocused(
        _ node: MainframeExplorerNode,
        depth: Int,
        to rows: inout [MainframeExplorerWorkspaceModel.VisibleRow]
    ) {
        rows.append(.init(node: node, depth: depth))
        guard node.kind == .directory,
              explorer.expandedPaths.contains(node.relativePath) else { return }
        for child in explorer.childrenByDirectory[node.relativePath] ?? [] {
            appendFocused(child, depth: depth + 1, to: &rows)
        }
    }

    private func isValidatedWorkRecord(_ row: MainframeExplorerWorkspaceModel.VisibleRow) -> Bool {
        guard row.depth == 1,
              row.node.kind == .directory,
              let scope = explorer.scopePresentation(for: row.node) else { return false }
        return scope.isAuthoritative
    }

    private func revealMindGraphPath(_ displayPath: String) {
        let trimmed = displayPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let direct = explorer.quickOpenEntries.first(where: { $0.relativePath == trimmed }) {
            explorer.revealAndSelect(direct)
            return
        }
        let absolute = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        if let direct = explorer.quickOpenEntries.first(where: {
            $0.url.standardizedFileURL.path == absolute
        }) {
            explorer.revealAndSelect(direct)
        }
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
        explorerSymbol(for: node)
    }
}

private enum MainframeExploreSurface: String, CaseIterable {
    case files
    case graph
    case workstation

    var displayName: String {
        switch self {
        case .files: return "Files"
        case .graph: return "Graph"
        case .workstation: return "Workstation"
        }
    }

    var symbol: String {
        switch self {
        case .files: return "doc.text"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .workstation: return "square.grid.2x2"
        }
    }
}

private struct MainframeExplorerTab: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let title: String
}

/// Reader/detail surface for the application-level Explore workspace. The file
/// tree is intentionally not rendered here; RootView owns the primary sidebar.
struct MainframeExplorerWorkspaceView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let root: URL
    @ObservedObject var explorer: MainframeExplorerWorkspaceModel
    @ObservedObject private var editor: MainframeMarkdownEditingSession
    @StateObject private var projection = MainframeKnowledgeProjectionModel()

    @State private var surface: MainframeExploreSurface = .files
    @State private var openTabs: [MainframeExplorerTab] = []
    @State private var readerModes: [String: MainframeReaderMode] = [:]
    @State private var showFind = false
    @State private var showMindGraph = false
    @State private var showLinks = false

    init(root: URL, explorer: MainframeExplorerWorkspaceModel) {
        self.root = root
        self._explorer = ObservedObject(wrappedValue: explorer)
        self._editor = ObservedObject(wrappedValue: explorer.editor)
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var selectedPath: String? { explorer.selectedNode?.relativePath }

    private var currentReaderMode: MainframeReaderMode {
        guard let selectedPath else { return .rendered }
        return readerModes[selectedPath] ?? .rendered
    }

    private var readerModeBinding: Binding<MainframeReaderMode> {
        Binding(
            get: { currentReaderMode },
            set: { value in
                guard let selectedPath else { return }
                readerModes[selectedPath] = value
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            experienceToolbar
            Divider().overlay(palette.line)

            if surface == .files, !openTabs.isEmpty {
                tabStrip
                Divider().overlay(palette.line)
            }

            switch surface {
            case .files:
                reader
            case .graph:
                MainframeGraphSurfaceView(
                    root: root,
                    selectedPath: selectedPath,
                    projection: projection,
                    onOpenPath: openPathInFiles
                )
            case .workstation:
                MainframeWorkstationSurfaceView(
                    root: root,
                    projection: projection,
                    onOpenPath: openPathInFiles
                )
            }
        }
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.app)
        .task(id: root.standardizedFileURL.path) {
            explorer.configure(root: root)
        }
        .onChange(of: explorer.selectedNode?.id) { _ in
            noteSelectedTab()
        }
        .onChange(of: surface) { newSurface in
            if newSurface != .files {
                projection.ensureLoaded(root: root)
            }
        }
        .sheet(isPresented: $showFind) {
            MainframeFindSheet(
                root: root,
                projection: projection,
                onOpenPath: openPathInFiles
            )
        }
        .sheet(isPresented: $showMindGraph) {
            MindGraphQueryView(onOpenPath: { path in
                openMindGraphPath(path)
            })
        }
        .popover(isPresented: $showLinks, arrowEdge: .top) {
            linksPopover
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MainFrame Explorer")
    }

    private var experienceToolbar: some View {
        HStack(spacing: 10) {
            Picker("Explore surface", selection: $surface) {
                ForEach(MainframeExploreSurface.allCases, id: \.self) { item in
                    Label(item.displayName, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 330)
            .accessibilityLabel("MainFrame surface")

            Spacer()

            Button {
                projection.ensureLoaded(root: root)
                showFind = true
            } label: {
                Label("Find", systemImage: "text.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .help("Deterministic full-text Find (Command-Shift-F)")

            Button {
                showMindGraph = true
            } label: {
                Label("MindGraph", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.bordered)
            .help("Semantic related-material nominations; separate from deterministic Find")

            if isSelectedMarkdown {
                Button {
                    projection.ensureLoaded(root: root)
                    showLinks = true
                } label: {
                    Label("Links", systemImage: "link")
                }
                .buttonStyle(.bordered)
                .help("Incoming and outgoing authored links for the selected Markdown document")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(openTabs) { tab in
                    let active = tab.path == selectedPath
                    HStack(spacing: 5) {
                        Button {
                            surface = .files
                            explorer.reveal(relativePath: tab.path)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.text")
                                    .font(.caption2)
                                Text(tab.title)
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .foregroundStyle(active ? palette.text : palette.dim)
                        }
                        .buttonStyle(.plain)
                        .help(tab.path)

                        if openTabs.count > 1 || !active {
                            Button {
                                closeTab(tab)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(palette.faint)
                            }
                            .buttonStyle(.borderless)
                            .help(active && editor.hasUnsavedChanges
                                ? "Save or discard before closing this tab"
                                : "Close tab")
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(active ? palette.accentSoft : palette.surface.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(active ? palette.accent.opacity(0.5) : palette.line, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(palette.rail)
        .accessibilityLabel("Open document tabs")
    }

    private var reader: some View {
        VStack(spacing: 0) {
            readerToolbar
            Divider().overlay(palette.line)
            if let status = editor.statusMessage, isSelectedMarkdown {
                editStatusBanner(status)
                Divider().overlay(palette.line)
            }
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
            .disabled(!explorer.canGoBack || editor.hasUnsavedChanges)
            .help(editor.hasUnsavedChanges ? "Save or discard edits before navigating" : "Back")
            .accessibilityLabel("Back")

            Button(action: explorer.goForward) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!explorer.canGoForward || editor.hasUnsavedChanges)
            .help(editor.hasUnsavedChanges ? "Save or discard edits before navigating" : "Forward")
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
                        .disabled(editor.hasUnsavedChanges && path != explorer.selectedNode?.relativePath)
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

            if isSelectedMarkdown, explorer.documentText != nil {
                Picker("Reader mode", selection: readerModeBinding) {
                    ForEach(MainframeReaderMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 190)
                .accessibilityLabel("Markdown reader mode")

                if editor.hasUnsavedChanges {
                    Button("Save") {
                        explorer.saveEdits()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: [.command])
                    .help("Save Markdown (Command-S)")

                    Button("Discard") {
                        explorer.discardEdits()
                    }
                    .buttonStyle(.bordered)
                    .help("Discard unsaved buffer changes")
                }

                if editor.hasConflict {
                    Button("Reload from Disk") {
                        explorer.reloadSelectedFileDiscardingBuffer()
                    }
                    .buttonStyle(.bordered)
                    .help("Discard the current buffer and load the changed file from disk")
                }
            }

            if let selected = explorer.selectedNode {
                Menu {
                    Button("Copy MainFrame-relative Path") {
                        copyToPasteboard(selected.relativePath)
                    }
                    Button("Copy Absolute Path") {
                        copyToPasteboard(selected.url.path)
                    }
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([selected.url])
                    }
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .menuStyle(.borderlessButton)
                .help("Path actions")
                .accessibilityLabel("Path actions")
            }

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

            if isSelectedMarkdown, currentReaderMode == .edit {
                Text(editor.hasUnsavedChanges ? "UNSAVED" : "EDIT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(editor.hasUnsavedChanges ? palette.accent : palette.faint)
            } else {
                Text("READ")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(palette.faint)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface)
    }

    @ViewBuilder
    private var readerContent: some View {
        if let text = explorer.documentText, let selected = explorer.selectedNode {
            if isMarkdown(selected) {
                if currentReaderMode == .edit {
                    markdownEditor(selected)
                } else {
                    MainframeMarkdownReaderView(
                        source: editor.hasUnsavedChanges ? editor.buffer : text,
                        mode: currentReaderMode,
                        palette: palette
                    )
                    .accessibilityLabel("\(currentReaderMode.displayName) view for \(selected.name)")
                }
            } else {
                plainTextReader(text, selected: selected)
            }
        } else if let selected = explorer.selectedNode {
            if selected.kind == .symbolicLink,
               let inspection = explorer.symlinkInspection {
                symlinkDetail(selected: selected, inspection: inspection)
            } else {
                selectedNodeDetail(selected)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 42))
                    .foregroundStyle(palette.dim)
                Text("Browse MainFrame")
                    .font(.title2.bold())
                    .foregroundStyle(palette.text)
                Text("Choose a file in the Explorer sidebar, use Command-P for bounded Quick Open, Command-Shift-F for deterministic full-text Find, or query MindGraph for explicitly labelled semantic nominations.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: 560)
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func markdownEditor(_ selected: MainframeExplorerNode) -> some View {
        TextEditor(text: $editor.buffer)
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(palette.text)
            .scrollContentBackground(.hidden)
            .background(palette.sink)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .accessibilityLabel("Edit Markdown source for \(selected.name)")
    }

    private func editStatusBanner(_ status: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: editor.hasConflict ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(editor.hasConflict ? Color.orange : palette.dim)
            Text(status)
                .font(.caption)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(palette.surface.opacity(0.72))
        .accessibilityLabel("Editor status: \(status)")
    }

    private func plainTextReader(_ text: String, selected: MainframeExplorerNode) -> some View {
        ScrollView(.vertical) {
            Text(text)
                .font(plainTextFont(for: selected))
                .foregroundStyle(palette.text)
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 980, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityLabel("Read-only text for \(selected.name)")
    }

    private func selectedNodeDetail(_ selected: MainframeExplorerNode) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(selected.name, systemImage: explorerSymbol(for: selected))
                .font(.title2.bold())
                .foregroundStyle(palette.text)
            Text(selected.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(palette.dim)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copy MainFrame-relative Path") {
                        copyToPasteboard(selected.relativePath)
                    }
                    Button("Copy Absolute Path") {
                        copyToPasteboard(selected.url.path)
                    }
                }
            if let message = explorer.documentMessage {
                Text(message)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func symlinkDetail(
        selected: MainframeExplorerNode,
        inspection: MainframeSymlinkInspection
    ) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 16) {
                Label(selected.name, systemImage: "link")
                    .font(.title2.bold())
                    .foregroundStyle(palette.text)

                Text(selected.relativePath)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.dim)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text(symlinkStatusLabel(inspection.location))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(palette.dim)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(palette.line, lineWidth: 1))
                    Text("Explorer will not traverse this link during ordinary scans.")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                }

                symlinkFact("Link target", inspection.rawTarget)
                symlinkFact("Resolved target", inspection.resolvedTargetPath)

                if let target = inspection.relativeTargetPath {
                    Button {
                        explorer.reveal(relativePath: target)
                    } label: {
                        Label("Open Target in MainFrame", systemImage: "arrow.forward.square")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Navigate explicitly to the resolved target inside the selected MainFrame root")
                }

                if let message = explorer.documentMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private var linksPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Authored Links", systemImage: "link")
                    .font(.headline)
                Spacer()
                if projection.isLoading { ProgressView().controlSize(.small) }
            }

            if let selectedPath {
                let outgoing = projection.outgoingLinks(for: selectedPath)
                let incoming = projection.incomingLinks(for: selectedPath)

                linkSection("OUTGOING", outgoing.map { record in
                    switch record.resolution {
                    case .local(let path, _): return (path, record.link.label)
                    case .sameDocumentAnchor(let anchor): return (selectedPath, "#\(anchor)")
                    case .external(let url): return (url, record.link.label)
                    case .unresolved(let reason): return ("Unresolved", "\(record.link.target) · \(reason)")
                    }
                })

                linkSection("BACKLINKS", incoming.map { ($0.sourcePath, $0.link.label) })
            } else {
                Text("Select a Markdown document to inspect links.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }

            Text("Authored links and MindGraph nominations remain separate evidence classes.")
                .font(.caption2)
                .foregroundStyle(palette.faint)
        }
        .padding(14)
        .frame(width: 420, height: 420, alignment: .topLeading)
        .background(palette.app)
        .task { projection.ensureLoaded(root: root) }
    }

    @ViewBuilder
    private func linkSection(_ title: String, _ rows: [(String, String)]) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(palette.faint)
        if rows.isEmpty {
            Text("None in the current bounded index.")
                .font(.caption)
                .foregroundStyle(palette.dim)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        if projection.contentIndex?.filesystemEntries.contains(where: { $0.relativePath == row.0 }) == true {
                            Button {
                                openPathInFiles(row.0)
                                showLinks = false
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.1.isEmpty ? row.0 : row.1)
                                        .font(.caption)
                                        .foregroundStyle(palette.text)
                                    Text(row.0)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(palette.faint)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.1.isEmpty ? row.0 : row.1)
                                    .font(.caption)
                                    .foregroundStyle(palette.dim)
                                Text(row.0)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(palette.faint)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 120)
        }
    }

    private func symlinkFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(palette.faint)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func symlinkStatusLabel(_ location: MainframeSymlinkTargetLocation) -> String {
        switch location {
        case .insideRoot: return "TARGET INSIDE MAINFRAME"
        case .outsideRoot: return "TARGET OUTSIDE MAINFRAME"
        case .missing: return "TARGET MISSING"
        }
    }

    private var isSelectedMarkdown: Bool {
        guard let selected = explorer.selectedNode else { return false }
        return isMarkdown(selected)
    }

    private func isMarkdown(_ node: MainframeExplorerNode) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(node.url.pathExtension.lowercased())
    }

    private func plainTextFont(for node: MainframeExplorerNode) -> Font {
        let ext = node.url.pathExtension.lowercased()
        let monospacedExtensions: Set<String> = [
            "swift", "py", "js", "ts", "tsx", "jsx", "json", "yaml", "yml",
            "toml", "sh", "zsh", "bash", "sql", "css", "html", "xml", "csv"
        ]
        return monospacedExtensions.contains(ext)
            ? .system(.body, design: .monospaced)
            : .body
    }

    private func noteSelectedTab() {
        guard let selected = explorer.selectedNode,
              selected.kind == .file else { return }
        if !openTabs.contains(where: { $0.path == selected.relativePath }) {
            openTabs.append(.init(path: selected.relativePath, title: selected.name))
        }
        if readerModes[selected.relativePath] == nil {
            readerModes[selected.relativePath] = .rendered
        }
    }

    private func closeTab(_ tab: MainframeExplorerTab) {
        let isActive = tab.path == selectedPath
        if isActive && editor.hasUnsavedChanges {
            editor.noteNavigationBlocked()
            return
        }
        guard openTabs.count > 1 || !isActive else { return }
        guard let index = openTabs.firstIndex(of: tab) else { return }
        openTabs.remove(at: index)
        readerModes[tab.path] = nil
        if isActive, !openTabs.isEmpty {
            let nextIndex = min(index, openTabs.count - 1)
            explorer.reveal(relativePath: openTabs[nextIndex].path)
        }
    }

    private func openPathInFiles(_ path: String) {
        surface = .files
        explorer.reveal(relativePath: path)
    }

    private func openMindGraphPath(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let direct = explorer.quickOpenEntries.first(where: { $0.relativePath == trimmed }) {
            surface = .files
            explorer.revealAndSelect(direct)
            return
        }
        let absolute = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        if let direct = explorer.quickOpenEntries.first(where: {
            $0.url.standardizedFileURL.path == absolute
        }) {
            surface = .files
            explorer.revealAndSelect(direct)
        }
    }
}

private func explorerSymbol(for node: MainframeExplorerNode) -> String {
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

private func copyToPasteboard(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
}
#endif
