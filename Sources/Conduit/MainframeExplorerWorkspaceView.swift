#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

/// The application-level NavigationSplitView owns this rail. Explore therefore
/// replaces the task/session rail instead of nesting a second primary sidebar
/// inside the detail pane.
struct MainframeExplorerSidebarView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let root: URL
    @ObservedObject var explorer: MainframeExplorerWorkspaceModel

    @State private var focusedScopePath: String?
    @State private var showingFocusedScope = false
    @State private var treeFilter = ""
    @State private var showMindGraph = false

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var focusedScopeNode: MainframeExplorerNode? {
        guard let focusedScopePath else { return nil }
        return explorer.quickOpenEntries.first(where: { $0.relativePath == focusedScopePath })
            ?? explorer.allRootRows.first(where: { $0.node.relativePath == focusedScopePath })?.node
    }

    private var focusedScopeRows: [MainframeExplorerWorkspaceModel.VisibleRow] {
        guard let focusedScopePath else { return [] }
        var rows: [MainframeExplorerWorkspaceModel.VisibleRow] = []
        for child in explorer.childrenByDirectory[focusedScopePath] ?? [] {
            appendFocused(child, depth: 0, to: &rows)
        }
        return rows
    }

    private var filterMatches: [MainframeExplorerNode] {
        explorer.filterMatches(treeFilter)
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
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
                TextField("Filter files", text: $treeFilter)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !treeFilter.isEmpty {
                    Button {
                        treeFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(palette.faint)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear file filter")
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(palette.surface.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            Divider().overlay(palette.line)

            if let rootError = explorer.rootError {
                explorerError(rootError)
            } else if !treeFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                filteredFileList
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            sectionLabel(showingFocusedScope ? "CURRENT SCOPE" : "ALL FILES")
                            Spacer()
                            if let focusedScopeNode {
                                Button(showingFocusedScope ? "All Files" : "Scope") {
                                    showingFocusedScope.toggle()
                                }
                                .buttonStyle(.borderless)
                                .font(.caption2.weight(.semibold))
                                .help(showingFocusedScope
                                    ? "Return to the complete MainFrame tree"
                                    : "Temporarily focus \(focusedScopeNode.name)")
                            }
                        }
                        .padding(.trailing, 8)

                        if showingFocusedScope, let focusedScopeNode {
                            focusedScopeHeader(focusedScopeNode)
                            if focusedScopeRows.isEmpty {
                                Text("This scope has no loaded children.")
                                    .font(.caption2)
                                    .foregroundStyle(palette.faint)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(focusedScopeRows) { row in
                                    treeRow(row)
                                }
                            }
                        } else {
                            ForEach(explorer.allRootRows) { row in
                                treeRow(row)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            if let message = explorer.filesystemMessage {
                Divider().overlay(palette.line)
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .accessibilityLabel("Explorer filesystem refresh note")
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

    private var filteredFileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                HStack {
                    sectionLabel("FILTERED FILES")
                    Spacer()
                    if explorer.isIndexing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("\(filterMatches.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(palette.faint)
                            .padding(.trailing, 10)
                    }
                }

                if explorer.quickOpenTruncated {
                    Text(explorer.quickOpenStatus)
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                }

                if !explorer.isIndexing && filterMatches.isEmpty {
                    Text("No observed path or filename match in the current search snapshot.")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                        .padding(12)
                } else {
                    ForEach(filterMatches) { node in
                        filterRow(node)
                    }
                }
            }
            .padding(.vertical, 8)
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

            searchIndexControls
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            Divider().overlay(palette.line)

            List(explorer.quickOpenMatches) { node in
                Button {
                    explorer.revealAndSelect(node)
                    explorer.isQuickOpenPresented = false
                    explorer.quickOpenQuery = ""
                    showingFocusedScope = false
                    treeFilter = ""
                } label: {
                    HStack(spacing: 9) {
                        pixelGlyph(for: node)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(node.name)
                                .foregroundStyle(rowTextColor(for: node))
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

    private var searchIndexControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Refresh Search Index", action: explorer.refreshQuickOpenIndex)
                    .accessibilityIdentifier("explorer.search.refresh")
                if explorer.isIndexing {
                    Button("Stop", action: explorer.cancelQuickOpenIndex)
                        .accessibilityIdentifier("explorer.search.stop")
                }
                Spacer()
                Toggle("Include generated/cache descendants", isOn: Binding(
                    get: { explorer.includesGeneratedSearchDescendants },
                    set: { explorer.setIncludesGeneratedSearchDescendants($0) }
                ))
                .toggleStyle(.checkbox)
                .help("Applies to recursive search only: node_modules, .build, .venv, venv, __pycache__, .cache, DerivedData, build and dist. Ordinary tree browsing retains these files.")
                .accessibilityIdentifier("explorer.search.include-generated")
            }
            .font(.caption)
            Text(explorer.quickOpenStatus)
                .font(.caption)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("explorer.search.status")
            if let receipt = explorer.quickOpenReceipt {
                DisclosureGroup("Index details") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Observed \(receipt.observedAt.formatted()) · \(receipt.scannedDirectories) directories · \(receipt.examinedEntries) examined entries")
                            ForEach(receipt.excludedDirectorySample, id: \.self) { path in
                                Text("Skipped descendants: \(path)")
                            }
                            ForEach(Array(receipt.issueSample.enumerated()), id: \.offset) { _, issue in
                                Text("\(issue.relativePath.isEmpty ? "Selected root" : issue.relativePath): \(issue.reason)")
                            }
                            if receipt.excludedDirectoryCount > receipt.excludedDirectorySample.count || receipt.issueCount > receipt.issueSample.count {
                                Text("Diagnostic samples are bounded to 40 paths per category; the counts above include every observed omission.")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                    .frame(maxHeight: 110)
                }
                .font(.caption)
                .foregroundStyle(palette.dim)
            }
        }
    }

    private func filterRow(_ node: MainframeExplorerNode) -> some View {
        Button {
            showingFocusedScope = false
            explorer.revealAndSelect(node)
        } label: {
            HStack(spacing: 7) {
                Color.clear.frame(width: 10, height: 1)
                pixelGlyph(for: node)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rootDisplayName(node))
                        .font(.caption)
                        .foregroundStyle(rowTextColor(for: node))
                        .lineLimit(1)
                    Text(node.relativePath)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(node.relativePath)
        .contextMenu {
            pathContextMenu(node)
        }
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
                pixelGlyph(for: row.node)
                Text(rootDisplayName(row.node))
                    .foregroundStyle(rowTextColor(for: row.node))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if isValidatedWorkRecord(row),
                   let scope = explorer.scopePresentation(for: row.node),
                   scope.isAuthoritative {
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
                Button("Focus Scope") {
                    if !explorer.expandedPaths.contains(row.node.relativePath) {
                        explorer.toggle(row.node)
                    }
                    focusedScopePath = row.node.relativePath
                    showingFocusedScope = true
                }
            }
            pathContextMenu(row.node)
        }
        .accessibilityLabel("\(row.node.name), \(row.node.kind.rawValue)")
    }

    @ViewBuilder
    private func pathContextMenu(_ node: MainframeExplorerNode) -> some View {
        Button("Copy MainFrame-relative Path") {
            copyToPasteboard(node.relativePath)
        }
        Button("Copy Absolute Path") {
            copyToPasteboard(node.url.path)
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([node.url])
        }
    }

    private func focusedScopeHeader(_ node: MainframeExplorerNode) -> some View {
        HStack(spacing: 6) {
            pixelGlyph(for: node)
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
                showingFocusedScope = false
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(palette.faint)
            }
            .buttonStyle(.borderless)
            .help("Return to All Files")
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
        let parts = row.node.relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2,
              row.node.kind == .directory,
              let first = parts.first,
              first == "30_projects" || first == "40_operations",
              let scope = explorer.scopePresentation(for: row.node) else { return false }
        return scope.isAuthoritative
    }

    private func pixelGlyph(for node: MainframeExplorerNode) -> some View {
        let kind = MainframeExplorerVisualClassifier.classify(node)
        return MainframePixelGlyph(
            kind: kind,
            primary: kind.isDeemphasized ? palette.faint : palette.dim,
            accent: kind.isDeemphasized ? palette.faint : palette.accent
        )
        .frame(width: 17)
    }

    private func rowTextColor(for node: MainframeExplorerNode) -> Color {
        MainframeExplorerVisualClassifier.classify(node).isDeemphasized
            ? palette.dim
            : palette.text
    }

    private func revealMindGraphPath(_ displayPath: String) {
        let trimmed = displayPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let direct = explorer.quickOpenEntries.first(where: { $0.relativePath == trimmed }) {
            showingFocusedScope = false
            explorer.revealAndSelect(direct)
            return
        }
        let absolute = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        if let direct = explorer.quickOpenEntries.first(where: {
            $0.url.standardizedFileURL.path == absolute
        }) {
            showingFocusedScope = false
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
}

private enum MainframeExploreSurface: String, CaseIterable {
    case files
    case graph
    case workstation

    var displayName: String {
        switch self {
        case .files: return "Files"
        case .graph: return "Related"
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
    @ObservedObject private var editor: MainframeExplorerTextEditingSession
    @StateObject private var projection = MainframeKnowledgeProjectionModel()

    @State private var surface: MainframeExploreSurface = .files
    @State private var openTabs: [MainframeExplorerTab] = []
    @State private var readerModes: [String: MainframeReaderMode] = [:]
    @State private var showFind = false
    @State private var showMindGraph = false
    @State private var showLinks = false
    @State private var findQuery = ""
    @State private var replacement = ""
    @State private var findRevision = 0
    @State private var showComparison = false

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
        return readerModes[selectedPath] ?? (isSelectedMarkdown ? .rendered : .source)
    }

    private var readerModeBinding: Binding<MainframeReaderMode> {
        Binding(
            get: { currentReaderMode },
            set: { value in
                guard let selectedPath, value != .edit || isSelectedEditableText else { return }
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
        .alert("Unsaved changes", isPresented: $explorer.isDirtyNavigationPresented) {
            Button("Save") { explorer.resolveDirtyNavigation(.save) }
            Button("Discard", role: .destructive) { explorer.resolveDirtyNavigation(.discard) }
            Button("Cancel", role: .cancel) { explorer.resolveDirtyNavigation(.cancel) }
        } message: {
            Text("\(editor.relativePath ?? "Current file") has unsaved changes. \(explorer.pendingNavigationDescription).")
        }
        .sheet(isPresented: $showComparison) {
            conflictComparison
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
                                Text(tab.title + (active && editor.hasUnsavedChanges ? " •" : ""))
                                    .font(.caption)
                                    .lineLimit(1)
                                if active && editor.hasConflict {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                }
                            }
                            .foregroundStyle(active ? palette.text : palette.dim)
                            .accessibilityValue(active ? (editor.hasConflict ? "Conflict" : editor.hasUnsavedChanges ? "Unsaved" : "Clean") : "Inactive; disk state is checked when opened")
                        }
                        .buttonStyle(.plain)
                        .help(tab.path)

                        if !tab.path.isEmpty {
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
            if let status = editor.statusMessage {
                editStatusBanner(status)
                Divider().overlay(palette.line)
            }
            if currentReaderMode == .edit, editor.isEditable {
                textEditTools
                Divider().overlay(palette.line)
            }
            if let reason = editor.readOnlyReason {
                Text(reason).font(.caption).foregroundStyle(palette.dim).padding(8)
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
            .disabled(!explorer.canGoBack)
            .help("Back; unsaved changes require Save, Discard or Cancel")
            .accessibilityLabel("Back")

            Button(action: explorer.goForward) {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(!explorer.canGoForward)
            .help("Forward; unsaved changes require Save, Discard or Cancel")
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
                        .accessibilityIdentifier("explorer.breadcrumb.\(path)")
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

            if (explorer.documentText != nil && explorer.previewRoute == .text) || (editor.hasUnsavedChanges && editor.relativePath == selectedPath) {
                Picker("Reader mode", selection: readerModeBinding) {
                    if isSelectedMarkdown { Text("Read").tag(MainframeReaderMode.rendered) }
                    Text("Source").tag(MainframeReaderMode.source)
                    if isSelectedEditableText { Text("Edit").tag(MainframeReaderMode.edit) }
                }
                .labelsHidden().pickerStyle(.segmented).frame(width:190)
                .accessibilityLabel("Text reader mode")
                .accessibilityIdentifier("explorer.text.mode")
            }
            if editor.relativePath == selectedPath {
                if editor.hasUnsavedChanges {
                    Button("Save") { explorer.saveEdits() }
                        .buttonStyle(.borderedProminent).keyboardShortcut("s",modifiers:[.command])
                        .accessibilityIdentifier("explorer.text.save")
                    Button("Revert") { explorer.discardEdits() }
                        .accessibilityIdentifier("explorer.text.revert")
                }
                if editor.hasConflict {
                    Button("Compare") {
                        if let root=explorer.root { editor.compareWithDisk(root:root) }
                        showComparison = editor.diskComparison != nil
                    }.accessibilityIdentifier("explorer.text.compare")
                    Button("Reload from Disk") {
                        explorer.performNavigation("Reload from disk and discard this buffer") { explorer.reloadSelectedFileDiscardingBuffer() }
                    }.accessibilityIdentifier("explorer.text.reload")
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

            if isSelectedEditableText, currentReaderMode == .edit {
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
        if let selected = explorer.selectedNode, editor.hasUnsavedChanges, editor.relativePath == selected.relativePath {
            if currentReaderMode == .edit {
                textEditor(selected)
            } else if isMarkdown(selected), currentReaderMode == .rendered {
                MainframeMarkdownReaderView(source: editor.buffer, mode: currentReaderMode, palette: palette)
                    .accessibilityLabel("Unsaved buffer for \(selected.relativePath)")
            } else {
                plainTextReader(editor.buffer, selected: selected)
                    .accessibilityLabel("Unsaved buffer for \(selected.relativePath)")
            }
        } else if let selected = explorer.selectedNode, selected.kind == .file {
            switch explorer.previewRoute {
            case .image:
                nativeImagePreview(selected)
                    .id(explorer.previewRevision)
            case .pdf:
                nativePDFPreview(selected)
                    .id(explorer.previewRevision)
            case .text:
                if currentReaderMode == .edit, editor.isEditable {
                    textEditor(selected)
                } else if let text = explorer.documentText {
                    if isMarkdown(selected) {
                        if currentReaderMode == .edit {
                            textEditor(selected)
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
                } else {
                    selectedNodeDetail(selected)
                }
            case .unsupportedBinary, .none:
                selectedNodeDetail(selected)
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

    @ViewBuilder
    private func nativeImagePreview(_ selected: MainframeExplorerNode) -> some View {
        if let data = explorer.previewData {
            VStack(spacing: 0) {
                previewPathHeader(selected).padding(12)
                MainframeExplorerImagePreview(data: data, name: selected.name)
                externalPreviewActions(selected).padding(8)
            }
        } else {
            selectedNodeDetail(selected)
        }
    }

    @ViewBuilder
    private func nativePDFPreview(_ selected: MainframeExplorerNode) -> some View {
        if let data = explorer.previewData {
            VStack(alignment: .leading, spacing: 0) {
                previewPathHeader(selected).padding(12)
                MainframeExplorerPDFPreview(data: data, name: selected.name)
                externalPreviewActions(selected).padding(8)
            }
        } else {
            selectedNodeDetail(selected)
        }
    }

    private func previewPathHeader(_ selected: MainframeExplorerNode) -> some View {
        HStack(spacing: 8) {
            Image(systemName: explorer.previewRoute == .pdf ? "doc.richtext" : "photo")
                .foregroundStyle(palette.faint)
            Text(selected.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(palette.dim)
                .textSelection(.enabled)
            Spacer()
            Text(explorer.previewRoute.rawValue.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.faint)
        }
    }

    private func textEditor(_ selected: MainframeExplorerNode) -> some View {
        MainframeExplorerTextEditor(text:$editor.buffer,findQuery:findQuery,findRevision:findRevision,onUndo:editor.undo,onRedo:editor.redo,canUndo:editor.canUndo,canRedo:editor.canRedo,foreground:NSColor(palette.text),background:NSColor(palette.sink))
            .background(palette.sink)
            .accessibilityLabel("Edit UTF-8 text for \(selected.relativePath)")
            .accessibilityIdentifier("explorer.text.buffer")
    }

    private var textEditTools: some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Button("Undo",action:editor.undo).disabled(!editor.canUndo).keyboardShortcut("z",modifiers:[.command]).accessibilityIdentifier("explorer.text.undo")
                Button("Redo",action:editor.redo).disabled(!editor.canRedo).keyboardShortcut("z",modifiers:[.command,.shift]).accessibilityIdentifier("explorer.text.redo")
                Spacer()
                Text("UTF-8 · \(editor.document?.lineEnding.rawValue ?? "UNKNOWN") · No autosave").font(.caption).foregroundStyle(palette.dim)
            }
            HStack {
                TextField("Literal find",text:$findQuery).textFieldStyle(.roundedBorder).accessibilityIdentifier("explorer.text.find")
                Button("Find Next") {findRevision += 1}.disabled(findQuery.isEmpty).accessibilityIdentifier("explorer.text.find-next")
                TextField("Replace with",text:$replacement).textFieldStyle(.roundedBorder).accessibilityIdentifier("explorer.text.replacement")
                Button("Replace First") {editor.replace(findQuery,with:replacement,all:false)}.disabled(findQuery.isEmpty).accessibilityIdentifier("explorer.text.replace-first")
                Button("Replace All") {editor.replace(findQuery,with:replacement,all:true)}.disabled(findQuery.isEmpty).accessibilityIdentifier("explorer.text.replace-all")
            }
            Text(editor.matchCount(findQuery)).font(.caption).foregroundStyle(palette.dim)
        }.padding(8)
    }

    private var conflictComparison: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Text(editor.relativePath ?? "Text comparison").font(.headline)
                Spacer()
                Button("Done") {showComparison=false}
            }
            Text("Read-only comparison. Reload and Save remain explicit actions.").font(.caption)
            HStack(alignment:.top) {
                VStack(alignment:.leading) {
                    Text("Your buffer").font(.headline)
                    ScrollView {Text(editor.buffer).font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                }
                Divider()
                VStack(alignment:.leading) {
                    Text("Current disk version").font(.headline)
                    ScrollView {Text(editor.diskComparison ?? "Unavailable").font(.system(.body,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
                }
            }
        }.padding(20).frame(minWidth:700,minHeight:400)
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
            externalPreviewActions(selected)
            Spacer()
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func externalPreviewActions(_ selected: MainframeExplorerNode) -> some View {
        if let bytes = explorer.previewByteCount {
            HStack {
                Text("Extension: \(selected.url.pathExtension.isEmpty ? "none" : selected.url.pathExtension.uppercased()) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) · Read-only preview")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                Spacer()
                Button("Open Externally") {
                    do {
                        _ = try MainframeExplorerPreviewLoader().byteCount(root: root, node: selected)
                        if !NSWorkspace.shared.open(selected.url) {
                            explorer.reportPreviewOpenFailure("macOS could not open the selected file externally.")
                        }
                    } catch {
                        explorer.reportPreviewOpenFailure(error.localizedDescription)
                    }
                }
                .accessibilityIdentifier("explorer.preview.open-externally")
            }
        }
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

    private var isSelectedEditableText: Bool {
        if editor.hasUnsavedChanges, editor.relativePath == selectedPath { return editor.isEditable }
        guard let selected=explorer.selectedNode,selected.kind == .file else{return false}
        return explorer.previewRoute == .text && editor.isEditable && editor.relativePath == selected.relativePath
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
            readerModes[selected.relativePath] = isMarkdown(selected) ? .rendered : .source
        }
    }

    private func closeTab(_ tab: MainframeExplorerTab) {
        if tab.path == selectedPath {
            explorer.performNavigation("Close \(tab.path)") { removeTab(tab) }
        } else { removeTab(tab) }
    }

    private func removeTab(_ tab: MainframeExplorerTab) {
        let active=tab.path == selectedPath
        guard let index=openTabs.firstIndex(of:tab) else{return}
        openTabs.remove(at:index)
        readerModes[tab.path]=nil
        if active {
            if openTabs.isEmpty { explorer.selectBreadcrumb("") }
            else { explorer.reveal(relativePath:openTabs[min(index,openTabs.count-1)].path) }
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
