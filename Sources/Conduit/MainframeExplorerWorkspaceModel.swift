#if os(macOS)
import AppKit
import ConduitCore
import Darwin
import Dispatch
import Foundation
import Combine

private final class MainframeExplorerDirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, onChange: @escaping @Sendable () -> Void) {
        let descriptor = url.standardizedFileURL.path.withCString { path in
            Darwin.open(path, O_EVTONLY)
        }
        guard descriptor >= 0 else { return nil }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend, .link, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler(handler: onChange)
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    deinit {
        source.cancel()
    }
}

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
    @Published private(set) var previewRoute: MainframeExplorerPreviewRoute = .none
    @Published private(set) var previewRevision = 0
    @Published private(set) var previewData: Data?
    @Published private(set) var previewByteCount: Int64?
    @Published private(set) var symlinkInspection: MainframeSymlinkInspection?
    @Published private(set) var rootError: String?
    @Published private(set) var lifecycleMessage: String?
    @Published private(set) var filesystemMessage: String?
    @Published private(set) var quickOpenEntries: [MainframeExplorerNode] = []
    @Published private(set) var quickOpenTruncated = false
    @Published private(set) var quickOpenReceipt: MainframeExplorerSearchReceipt?
    @Published private(set) var quickOpenIndexIsStale = false
    @Published private(set) var quickOpenFailureMessage: String?
    @Published private(set) var includesGeneratedSearchDescendants = false
    @Published private(set) var isIndexing = false
    @Published var quickOpenQuery = ""
    @Published var isQuickOpenPresented = false
    @Published private(set) var navigationRevision = 0

    enum DirtyNavigationDecision { case save, discard, cancel }
    @Published var isDirtyNavigationPresented = false
    @Published private(set) var pendingNavigationDescription = ""
    private var pendingNavigationAction: (@MainActor () -> Void)?

    let editor = MainframeExplorerTextEditingSession()

    private var nodesByPath: [String: MainframeExplorerNode] = [:]
    private var lifecycleScan: MainframeLifecycleScan?
    private var history = MainframeNavigationHistory()
    private let scanner = MainframeExplorerScanner()
    private let lifecycleScanner = MainframeLifecycleScanner()
    private var indexGeneration = UUID()
    private var directoryWatchers: [String: MainframeExplorerDirectoryWatcher] = [:]
    private var selectedFileWatcher: MainframeExplorerDirectoryWatcher?
    private var pendingDirectoryRefreshes: [String: Task<Void, Never>] = [:]
    private var pendingIndexRefresh: Task<Void, Never>?
    private var indexBuildTask: Task<Void, Never>?

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    var quickOpenStatus: String {
        if let quickOpenFailureMessage { return quickOpenFailureMessage }
        if isIndexing { return "Indexing \(quickOpenEntries.count) entries · results are partial" }
        if let quickOpenReceipt {
            let stale = quickOpenIndexIsStale ? " · last observation may be stale" : ""
            return "\(quickOpenEntries.count) entries · \(quickOpenReceipt.summary)\(stale)"
        }
        return "Search index is not available yet"
    }

    /// Canonical Explorer tree. Lifecycle roots are ordered first for spatial
    /// familiarity, but no non-lifecycle root is hidden behind another mode.
    var allRootRows: [VisibleRow] {
        visibleRows(from: orderedRootNodes)
    }

    /// Retained for callers/tests that need the lifecycle subset. The primary
    /// sidebar no longer uses this subset as a replacement for the filesystem.
    var lifecycleRootRows: [VisibleRow] {
        visibleRows(
            from: orderedRootNodes.filter {
                Self.lifecycleRootOrder.contains($0.name)
            }
        )
    }

    /// Retained as a derived subset only. These rows are visible in All Files
    /// by default and are not collapsed into a separate System Files section.
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

    func filterMatches(_ query: String, limit: Int = 160) -> [MainframeExplorerNode] {
        MainframeExplorerTreeFilter.matches(quickOpenEntries, query: query, limit: limit)
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
        guard navigationAllowed(to: nil, description: "Change the Explorer root", resume: { [weak self] in self?.configure(root: newRoot) }) else { return }

        indexGeneration = UUID()
        pendingIndexRefresh?.cancel()
        pendingIndexRefresh = nil
        indexBuildTask?.cancel()
        indexBuildTask = nil
        for task in pendingDirectoryRefreshes.values { task.cancel() }
        pendingDirectoryRefreshes = [:]
        directoryWatchers = [:]
        selectedFileWatcher = nil
        root = normalized
        rootNodes = []
        childrenByDirectory = [:]
        expandedPaths = []
        selectedNode = nil
        documentText = nil
        documentMessage = nil
        previewRoute = .none
        previewRevision = 0
        previewData = nil
        previewByteCount = nil
        symlinkInspection = nil
        rootError = nil
        lifecycleMessage = nil
        filesystemMessage = nil
        quickOpenEntries = []
        quickOpenTruncated = false
        quickOpenReceipt = nil
        quickOpenIndexIsStale = false
        quickOpenFailureMessage = nil
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
        guard navigationAllowed(to: node.relativePath, resume: { [weak self] in self?.toggle(node) }) else { return }
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
        if editor.hasUnsavedChanges, node.relativePath == selectedNode?.relativePath { return }
        guard navigationAllowed(to: node.relativePath, resume: { [weak self] in self?.select(node, recordHistory: recordHistory) }) else { return }
        selectedFileWatcher = nil
        selectedNode = node
        if recordHistory {
            history.visit(node.relativePath)
            navigationRevision += 1
        }
        documentText = nil
        documentMessage = nil
        symlinkInspection = nil
        previewRoute = .none
        previewData = nil
        previewByteCount = nil

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
            watchSelectedFile(node)
            previewRoute = MainframeExplorerPreviewRouter.route(for: node)
            do {
                previewByteCount = try MainframeExplorerPreviewLoader().byteCount(root: root, node: node)
            } catch {
                editor.clear()
                documentMessage = error.localizedDescription
                return
            }
            switch previewRoute {
            case .text:
                do {
                    let text = try MainframeExplorerPreviewLoader().readUTF8Text(root: root, node: node)
                    documentText = text
                    editor.load(node: node, source: text)
                } catch {
                    editor.clear()
                    documentMessage = error.localizedDescription
                }
            case .image, .pdf:
                editor.clear()
                loadNativePreview(root: root, node: node)
            case .unsupportedBinary:
                editor.clear()
                documentMessage = "Unsupported binary format · Explorer will not reinterpret this file as UTF-8 text."
            case .none:
                editor.clear()
            }
        }
    }

    private func loadNativePreview(root: URL, node: MainframeExplorerNode) {
        previewData = nil
        do {
            previewData = try MainframeExplorerPreviewLoader().read(root: root, node: node)
            documentMessage = nil
            previewRevision += 1
        } catch {
            documentMessage = error.localizedDescription
        }
    }

    func reportPreviewOpenFailure(_ message: String) {
        documentMessage = message
    }

    @discardableResult
    func saveEdits() -> Bool {
        guard let root,
              let selectedNode,
              selectedNode.kind == .file,
              editor.isEditable else {
            editor.noteNavigationBlocked()
            return false
        }
        if editor.save(root: root, file: selectedNode.url) {
            documentText = editor.baseline
            documentMessage = nil
            return true
        }
        return false
    }

    func discardEdits() {
        editor.discard()
    }

    func reloadSelectedFileDiscardingBuffer() {
        guard let root,
              let selectedNode,
              selectedNode.kind == .file,
              previewRoute == .text else { return }
        do {
            let text = try MainframeExplorerPreviewLoader().readUTF8Text(root: root, node: selectedNode)
            documentText = text
            documentMessage = nil
            editor.load(node: selectedNode, source: text)
        } catch {
            documentMessage = error.localizedDescription
        }
    }

    func goBack() {
        guard navigationAllowed(to: nil, description: "Go back", resume: { [weak self] in self?.goBack() }) else { return }
        guard let path = history.goBack() else { return }
        navigationRevision += 1
        revealAndSelect(relativePath: path, recordHistory: false)
    }

    func goForward() {
        guard navigationAllowed(to: nil, description: "Go forward", resume: { [weak self] in self?.goForward() }) else { return }
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
        guard navigationAllowed(to: relativePath, resume: { [weak self] in self?.selectBreadcrumb(relativePath) }) else { return }
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

    func performNavigation(_ description: String, action: @escaping @MainActor () -> Void) {
        if navigationAllowed(to: nil, description: description, resume: action) { action() }
    }

    func resolveDirtyNavigation(_ decision: DirtyNavigationDecision) {
        let action = pendingNavigationAction
        pendingNavigationAction = nil
        isDirtyNavigationPresented = false
        pendingNavigationDescription = ""
        switch decision {
        case .cancel: return
        case .save:
            guard saveEdits() else { return }
        case .discard:
            editor.discard()
        }
        action?()
    }

    private func navigationAllowed(to relativePath: String?, description: String? = nil, resume: @escaping @MainActor () -> Void) -> Bool {
        guard editor.hasUnsavedChanges else { return true }
        if let relativePath, relativePath == selectedNode?.relativePath { return true }
        pendingNavigationAction = resume
        pendingNavigationDescription = description ?? "Open \(relativePath ?? "another file")"
        isDirtyNavigationPresented = true
        editor.noteNavigationBlocked()
        return false
    }

    private func revealAndSelect(relativePath: String, recordHistory: Bool) {
        guard navigationAllowed(to: relativePath, resume: { [weak self] in self?.revealAndSelect(relativePath: relativePath, recordHistory: recordHistory) }) else { return }
        guard let root else { return }
        if let known = nodesByPath[relativePath] {
            expandAncestors(of: relativePath, root: root)
            select(known, recordHistory: recordHistory)
            return
        }

        expandAncestors(of: relativePath, root: root)

        // A cache miss is not authoritative. Re-read only the smallest
        // containing directory before reporting the path as missing.
        let containingPath = MainframeExplorerFilesystemFreshness
            .containingDirectoryPath(for: relativePath)
        refreshDirectory(path: containingPath)

        if let discovered = nodesByPath[relativePath] {
            select(discovered, recordHistory: recordHistory)
        } else {
            documentText = nil
            symlinkInspection = nil
            documentMessage = "The requested path is not present on disk after refreshing its containing directory."
        }
    }

    private func expandAncestors(of relativePath: String, root: URL) {
        let parts = Self.pathParts(relativePath)
        guard parts.count > 1 else { return }
        var parentPath = ""

        for component in parts.dropLast() {
            let currentPath = parentPath.isEmpty ? component : "\(parentPath)/\(component)"
            if nodesByPath[currentPath] == nil {
                // Recover newly created intermediate directories one level at
                // a time without rebuilding unrelated parts of the tree.
                refreshDirectory(path: parentPath)
            }
            if let node = nodesByPath[currentPath], node.kind == .directory {
                loadChildrenIfNeeded(for: node)
                expandedPaths.insert(currentPath)
            } else {
                return
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

    private func refreshDirectory(path: String) {
        guard let root else { return }

        let directoryURL: URL
        if path.isEmpty {
            directoryURL = root
        } else if let known = nodesByPath[path], known.kind == .directory {
            directoryURL = known.url
        } else {
            directoryURL = root.appendingPathComponent(path, isDirectory: true)
        }

        do {
            let nodes = path.isEmpty
                ? try scanner.rootChildren(root: root)
                : try scanner.children(root: root, directory: directoryURL)
            cache(nodes, forDirectoryPath: path)
            filesystemMessage = nil
            if path.isEmpty {
                rootNodes = nodes
                rootError = nil
            }
            reconcileSelectedFileAfterFilesystemChange(inDirectoryPath: path)
        } catch {
            let label = path.isEmpty ? "MainFrame root" : path
            filesystemMessage = "Explorer could not refresh \(label): \(error.localizedDescription)"
            if path.isEmpty {
                rootError = error.localizedDescription
            }
        }
    }

    private func scheduleDirectoryRefresh(path: String) {
        pendingDirectoryRefreshes[path]?.cancel()
        pendingDirectoryRefreshes[path] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 160_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingDirectoryRefreshes[path] = nil
            self.refreshDirectory(path: path)
            self.scheduleQuickOpenRefresh()
        }
    }

    private func scheduleQuickOpenRefresh() {
        guard let root else { return }
        pendingIndexRefresh?.cancel()
        pendingIndexRefresh = Task { [weak self] in
            do {
                // Coalesce ordinary create/modify/rename bursts into one
                // bounded full-index refresh. Slice 6 may replace this with a
                // more incremental strategy after workload evidence.
                try await Task.sleep(nanoseconds: 750_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingIndexRefresh = nil
            self.buildQuickOpenIndex(root: root)
        }
    }

    private func watchDirectoryIfNeeded(path: String) {
        guard directoryWatchers[path] == nil, let root else { return }
        let url: URL
        if path.isEmpty {
            url = root
        } else if let node = nodesByPath[path], node.kind == .directory {
            url = node.url
        } else {
            return
        }

        directoryWatchers[path] = MainframeExplorerDirectoryWatcher(url: url) { [weak self] in
            Task { @MainActor in
                self?.scheduleDirectoryRefresh(path: path)
            }
        }
    }

    private func watchSelectedFile(_ node: MainframeExplorerNode) {
        guard node.kind == .file else { return }
        let parentPath = MainframeExplorerFilesystemFreshness
            .containingDirectoryPath(for: node.relativePath)

        selectedFileWatcher = MainframeExplorerDirectoryWatcher(url: node.url) { [weak self] in
            Task { @MainActor in
                self?.scheduleDirectoryRefresh(path: parentPath)
            }
        }
    }

    private func removeCachedSubtree(rootPath: String) {
        let prefix = rootPath + "/"

        let nodeKeys = nodesByPath.keys.filter {
            $0 == rootPath || $0.hasPrefix(prefix)
        }
        for key in nodeKeys {
            nodesByPath.removeValue(forKey: key)
        }

        let directoryKeys = childrenByDirectory.keys.filter {
            $0 == rootPath || $0.hasPrefix(prefix)
        }
        for key in directoryKeys {
            childrenByDirectory.removeValue(forKey: key)
            directoryWatchers.removeValue(forKey: key)
            pendingDirectoryRefreshes[key]?.cancel()
            pendingDirectoryRefreshes.removeValue(forKey: key)
        }

        expandedPaths = Set(expandedPaths.filter {
            $0 != rootPath && !$0.hasPrefix(prefix)
        })
    }

    private func reconcileSelectedFileAfterFilesystemChange(inDirectoryPath path: String) {
        guard let root, let selectedNode else { return }
        let selectedParent = MainframeExplorerFilesystemFreshness
            .containingDirectoryPath(for: selectedNode.relativePath)
        guard selectedParent == path else { return }

        guard let refreshedNode = nodesByPath[selectedNode.relativePath] else {
            selectedFileWatcher = nil
            documentMessage = "The selected file changed on disk and is no longer present at this path."
            documentText = nil
            symlinkInspection = nil
            previewData = nil
            previewByteCount = nil
            if editor.relativePath == selectedNode.relativePath {
                editor.noteExternalChange(
                    "The selected text file was removed or renamed on disk. Your buffer is preserved."
                )
            }
            return
        }

        self.selectedNode = refreshedNode
        guard refreshedNode.kind == .file else {
            if editor.hasUnsavedChanges { editor.noteExternalChange("The selected path is no longer a regular file. Your buffer is preserved.") }
            previewRoute = .none
            previewData = nil
            previewByteCount = nil
            documentText = nil
            documentMessage = "The selected path is no longer a regular file."
            return
        }
        // Atomic replacements can invalidate the watched inode while keeping
        // the same path. Re-arm the selected-file watcher against the current
        // filesystem object after each parent reconciliation.
        watchSelectedFile(refreshedNode)

        previewRoute = MainframeExplorerPreviewRouter.route(for: refreshedNode)
        do {
            previewByteCount = try MainframeExplorerPreviewLoader().byteCount(root: root, node: refreshedNode)
        } catch {
            previewData = nil
            previewByteCount = nil
            documentText = nil
            documentMessage = error.localizedDescription
            if editor.hasUnsavedChanges { editor.noteExternalChange() }
            return
        }
        if previewRoute != .text, editor.hasUnsavedChanges {
            documentMessage = "The file changed to an unsupported text format. Your buffer is preserved."
            editor.noteExternalChange(documentMessage)
            return
        }
        switch previewRoute {
        case .text:
            do {
                let source = try MainframeExplorerPreviewLoader().readUTF8Text(root: root, node: refreshedNode)
                if editor.relativePath == refreshedNode.relativePath,
                   let baseline = editor.baseline,
                   !source.utf8.elementsEqual(baseline.utf8) {
                    if editor.hasUnsavedChanges {
                        editor.noteExternalChange()
                    } else {
                        editor.refreshCleanBufferFromDisk(source)
                        documentText = source
                        documentMessage = nil
                    }
                } else if editor.relativePath != refreshedNode.relativePath, source != documentText {
                    documentText = source
                    documentMessage = "Reloaded after an external file change."
                }
            } catch {
                if editor.hasUnsavedChanges {
                    editor.noteExternalChange(
                        "The selected file changed on disk and can no longer be read as the original UTF-8 document. Your buffer is preserved."
                    )
                } else {
                    documentText = nil
                    documentMessage = "The selected file changed on disk: \(error.localizedDescription)"
                }
            }
        case .image, .pdf:
            editor.clear()
            documentText = nil
            loadNativePreview(root: root, node: refreshedNode)
        case .unsupportedBinary:
            editor.clear()
            documentText = nil
            documentMessage = "Unsupported binary format · Explorer will not reinterpret this file as UTF-8 text."
        case .none:
            editor.clear()
        }
    }

    private func cache(_ nodes: [MainframeExplorerNode], forDirectoryPath path: String) {
        let previous = childrenByDirectory[path] ?? []
        let staleRoots = MainframeExplorerFilesystemFreshness.staleSubtreeRoots(
            previous: previous,
            current: nodes
        )
        for staleRoot in staleRoots {
            removeCachedSubtree(rootPath: staleRoot)
        }

        childrenByDirectory[path] = nodes
        for node in nodes {
            nodesByPath[node.relativePath] = node
        }
        watchDirectoryIfNeeded(path: path)
    }

    func refreshQuickOpenIndex() {
        guard let root else { return }
        pendingIndexRefresh?.cancel()
        pendingIndexRefresh = nil
        buildQuickOpenIndex(root: root)
    }

    func setIncludesGeneratedSearchDescendants(_ value: Bool) {
        guard value != includesGeneratedSearchDescendants else { return }
        includesGeneratedSearchDescendants = value
        refreshQuickOpenIndex()
    }

    func cancelQuickOpenIndex() {
        indexBuildTask?.cancel()
        indexBuildTask = nil
        indexGeneration = UUID()
        isIndexing = false
        quickOpenIndexIsStale = true
        quickOpenFailureMessage = "Indexing cancelled · retained \(quickOpenEntries.count) observed entries; search is incomplete"
    }

    private func buildQuickOpenIndex(root: URL) {
        indexBuildTask?.cancel()
        let generation = UUID()
        indexGeneration = generation
        isIndexing = true
        quickOpenIndexIsStale = true
        quickOpenFailureMessage = nil
        let policy = MainframeExplorerSearchPolicy(excludedDirectoryNames: includesGeneratedSearchDescendants ? [] : MainframeExplorerSearchPolicy.defaultExcludedDirectoryNames)

        indexBuildTask = Task { [weak self] in
            guard let self else { return }
            let worker = Task.detached(priority: .utility) { [self] in
                try MainframeExplorerSearchIndexer().build(root: root, policy: policy, onProgress: { progress in
                    Task { @MainActor in
                        guard self.indexGeneration == generation, self.isIndexing else { return }
                        self.quickOpenEntries = progress.entries
                        self.quickOpenReceipt = progress.receipt
                        self.quickOpenTruncated = !progress.receipt.isComplete
                    }
                })
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, self.indexGeneration == generation else { return }
                self.quickOpenEntries = result.entries
                self.quickOpenReceipt = result.receipt
                self.quickOpenTruncated = !result.receipt.isComplete
                self.quickOpenIndexIsStale = false
                self.isIndexing = false
                self.indexBuildTask = nil
            } catch {
                guard !Task.isCancelled, self.indexGeneration == generation else { return }
                self.isIndexing = false
                self.indexBuildTask = nil
                self.quickOpenFailureMessage = "Search unavailable: \(error.localizedDescription) Retained entries may be stale."
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

#endif
