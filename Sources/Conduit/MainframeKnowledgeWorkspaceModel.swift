#if os(macOS)
import ConduitCore
import Foundation
import SwiftUI

@MainActor
enum MainframeKnowledgeSurface: String, CaseIterable, Identifiable {
    case reader
    case graph
    case workstation

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .reader: return "doc.text"
        case .graph: return "point.3.connected.trianglepath.dotted"
        case .workstation: return "square.grid.2x2"
        }
    }
}

@MainActor
enum MainframeReaderMode: String, CaseIterable, Identifiable {
    case rendered
    case source

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@MainActor
final class MainframeKnowledgeWorkspaceModel: ObservableObject {
    let root: URL
    private let scanner = MainframeExplorerScanner()

    @Published var surface: MainframeKnowledgeSurface = .reader
    @Published var readerMode: MainframeReaderMode = .rendered
    @Published private(set) var rootChildren: [MainframeExplorerNode] = []
    @Published private(set) var childCache: [String: [MainframeExplorerNode]] = [:]
    @Published private(set) var expandedPaths = Set<String>()
    @Published private(set) var selectedNode: MainframeExplorerNode?
    @Published private(set) var selectedText: String?
    @Published private(set) var selectedDocument: MainframeMarkdownDocument?
    @Published private(set) var readError: String?
    @Published private(set) var loadError: String?
    @Published private(set) var contentIndex: MainframeContentIndex?
    @Published private(set) var lifecycleScan: MainframeLifecycleScan?
    @Published private(set) var graphSnapshot: MainframeGraphSnapshot?
    @Published private(set) var graphScene: MainframeGraphScene?
    @Published private(set) var workstation: MainframeWorkstationProjection?
    @Published private(set) var isIndexing = false
    @Published private(set) var indexError: String?
    @Published private(set) var history = MainframeNavigationHistory()
    @Published private(set) var recent = MainframeRecentNavigation(limit: 20)
    @Published private(set) var navigationTrail: [String] = []

    @Published var quickOpenPresented = false
    @Published var quickOpenQuery = ""
    @Published var searchPresented = false
    @Published var searchQuery = ""
    @Published var graphMode: MainframeGraphMode = .orbit
    @Published var orbitDepth = 1
    @Published var selectedGraphNodeID: String?
    @Published var pathfinderSourceID: String?
    @Published var pathfinderTargetID: String?
    @Published private(set) var radarHits: [MindGraphHit] = []
    @Published private(set) var radarError: String?
    @Published private(set) var radarScope: MindGraphScope?
    @Published var radarQuestion = ""
    @Published private(set) var isRadarLoading = false

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    var selectedPath: String? { selectedNode?.relativePath }
    var selectedTitle: String { selectedNode?.name ?? "MainFrame" }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }
    var indexMayBeIncomplete: Bool { contentIndex?.mayBeIncomplete ?? false }

    var quickOpenMatches: [MainframeExplorerNode] {
        guard let contentIndex else { return [] }
        return MainframeQuickOpen.matches(contentIndex.filesystemEntries, query: quickOpenQuery, limit: 80)
    }

    var searchResult: MainframeSearchResult {
        guard let contentIndex else { return MainframeSearchResult(hits: [], mayBeIncomplete: false) }
        return MainframeTextSearch.search(contentIndex, query: searchQuery, limit: 240)
    }

    var selectedOutgoingLinks: [MainframeDocumentLinkRecord] {
        guard let selectedPath, let contentIndex else { return [] }
        return contentIndex.linkIndex.outgoing[selectedPath] ?? []
    }

    var selectedBacklinks: [MainframeDocumentLinkRecord] {
        guard let selectedPath, let contentIndex else { return [] }
        return contentIndex.linkIndex.incoming[selectedPath] ?? []
    }

    var selectedChecklist: MainframeChecklistProjection {
        guard let selectedText else { return MainframeChecklistProjection(items: []) }
        return MainframeChecklistProjection.parse(markdown: selectedText)
    }

    var attentionItems: [MainframeAttentionItem] {
        let scopes = workstation?.stations.map(\.id) ?? []
        return MainframeAttentionProjection.build(
            navigationPaths: navigationTrail,
            scopePaths: scopes,
            currentPath: selectedPath
        )
    }

    func bootstrap() async {
        do {
            rootChildren = try scanner.rootChildren(root: root)
        } catch {
            loadError = error.localizedDescription
        }
        await rebuildDerivedState()
    }

    func rebuildDerivedState() async {
        guard !isIndexing else { return }
        isIndexing = true
        indexError = nil
        let root = self.root
        do {
            let (content, lifecycle) = try await Task.detached(priority: .userInitiated) {
                async let content = MainframeContentIndexer().build(root: root)
                async let lifecycle = MainframeLifecycleScanner().scan(root: root)
                return try await (content, lifecycle)
            }.value
            contentIndex = content
            lifecycleScan = lifecycle
            graphSnapshot = MainframeGraphBuilder.build(root: root, content: content, lifecycle: lifecycle)
            workstation = MainframeWorkstationBuilder.build(root: root, lifecycle: lifecycle)
            refreshGraphScene()
        } catch {
            indexError = error.localizedDescription
        }
        isIndexing = false
    }

    func children(of node: MainframeExplorerNode) -> [MainframeExplorerNode] {
        childCache[node.relativePath] ?? []
    }

    func isExpanded(_ node: MainframeExplorerNode) -> Bool {
        expandedPaths.contains(node.relativePath)
    }

    func toggleDirectory(_ node: MainframeExplorerNode) {
        guard node.kind == .directory else { return }
        if expandedPaths.contains(node.relativePath) {
            expandedPaths.remove(node.relativePath)
            return
        }
        do {
            if childCache[node.relativePath] == nil {
                childCache[node.relativePath] = try scanner.children(root: root, directory: node.url)
            }
            expandedPaths.insert(node.relativePath)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func collapseAll() {
        expandedPaths.removeAll()
    }

    func select(_ node: MainframeExplorerNode, recordHistory: Bool = true) {
        selectedNode = node
        readError = nil
        selectedText = nil
        selectedDocument = nil
        selectedGraphNodeID = node.relativePath
        if recordHistory {
            history.visit(node.relativePath)
            recent.note(node.relativePath)
            navigationTrail.append(node.relativePath)
            if navigationTrail.count > 400 { navigationTrail.removeFirst(navigationTrail.count - 400) }
        }
        if node.kind == .file {
            do {
                let text = try scanner.readUTF8Text(root: root, file: node.url)
                selectedText = text
                if isMarkdown(node.url) { selectedDocument = MainframeMarkdownParser.parse(text) }
            } catch {
                readError = error.localizedDescription
            }
        }
        if graphMode == .orbit { refreshGraphScene() }
    }

    func open(relativePath: String, surface targetSurface: MainframeKnowledgeSurface = .reader) {
        guard let node = node(relativePath: relativePath) else {
            readError = "Path is unavailable in the current bounded MainFrame index: \(relativePath)"
            return
        }
        reveal(node)
        select(node)
        surface = targetSurface
    }

    func goBack() {
        guard let path = history.goBack(), let node = node(relativePath: path) else { return }
        reveal(node)
        select(node, recordHistory: false)
    }

    func goForward() {
        guard let path = history.goForward(), let node = node(relativePath: path) else { return }
        reveal(node)
        select(node, recordHistory: false)
    }

    func breadcrumbPaths() -> [(label: String, path: String?)] {
        guard let selectedPath else { return [("MainFrame", nil)] }
        let parts = selectedPath.split(separator: "/").map(String.init)
        var result: [(String, String?)] = [("MainFrame", nil)]
        var path = ""
        for part in parts {
            path = path.isEmpty ? part : "\(path)/\(part)"
            result.append((part, path))
        }
        return result
    }

    func openBreadcrumb(_ path: String?) {
        guard let path else {
            selectedNode = nil
            selectedText = nil
            selectedDocument = nil
            return
        }
        open(relativePath: path)
    }

    func authorityBadge(for node: MainframeExplorerNode) -> (label: String, detail: String)? {
        guard let scope = node.recordScope, let scan = lifecycleScan else { return nil }
        guard let records = scan.bySlug[scope.slug], records.count == 1, let record = records.first else {
            return ("UNVERIFIED", "Lifecycle identity is missing or ambiguous.")
        }
        let expected: MainframeLifecycleRecordType = scope.recordType == .project ? .project : .operation
        guard record.isValid, record.recordType == expected else {
            return ("UNVERIFIED", record.issues.joined(separator: " · "))
        }
        return (expected == .project ? "PROJECT" : "OPERATION", "Validated by MainFrame lifecycle identity.")
    }

    func refreshGraphScene() {
        guard let snapshot = graphSnapshot else { graphScene = nil; return }
        switch graphMode {
        case .orbit:
            let focus = selectedGraphNodeID ?? selectedPath ?? snapshot.nodes.first?.id
            if let focus {
                graphScene = MainframeGraphQuery.orbit(snapshot: snapshot, focusNodeID: focus, depth: orbitDepth)
            } else {
                graphScene = nil
            }
        case .atlas:
            graphScene = MainframeGraphQuery.atlas(snapshot: snapshot)
        case .pathfinder:
            if let source = pathfinderSourceID, let target = pathfinderTargetID {
                graphScene = MainframeGraphQuery.shortestPath(snapshot: snapshot, from: source, to: target)
            } else {
                graphScene = MainframeGraphScene(mode: .pathfinder, nodes: [], edges: [], focusNodeID: nil, sourceMayBeIncomplete: snapshot.sourceMayBeIncomplete)
            }
        case .radar:
            let focus = selectedGraphNodeID ?? selectedPath ?? snapshot.nodes.first?.id
            if let focus {
                graphScene = MainframeGraphQuery.orbit(
                    snapshot: snapshot,
                    focusNodeID: focus,
                    depth: orbitDepth,
                    allowedKinds: [.authoredLink, .semanticNomination],
                    maxNodes: 100
                )
            } else {
                graphScene = nil
            }
        }
    }

    func setGraphMode(_ mode: MainframeGraphMode) {
        graphMode = mode
        refreshGraphScene()
    }

    func setOrbitDepth(_ depth: Int) {
        orbitDepth = min(max(depth, 1), 3)
        refreshGraphScene()
    }

    func selectGraphNode(_ id: String) {
        selectedGraphNodeID = id
        if graphMode == .orbit || graphMode == .radar { refreshGraphScene() }
    }

    func setPathfinderSource(_ id: String?) {
        pathfinderSourceID = id
        refreshGraphScene()
    }

    func setPathfinderTarget(_ id: String?) {
        pathfinderTargetID = id
        refreshGraphScene()
    }

    func beginRadarQuery(scope: MindGraphScope) {
        radarScope = scope
        radarError = nil
        isRadarLoading = true
    }

    func applyRadarResult(_ result: Result<[MindGraphHit], MindGraphQueryError>, scope: MindGraphScope) {
        isRadarLoading = false
        radarScope = scope
        switch result {
        case .failure(let error):
            radarHits = []
            radarError = error.displayMessage
        case .success(let hits):
            radarHits = hits
            radarError = nil
            applyRadarHits(hits)
        }
    }

    func clearRadar() {
        radarHits = []
        radarError = nil
        radarScope = nil
        if let base = graphSnapshot {
            graphSnapshot = MainframeGraphSnapshot(
                nodes: base.nodes,
                edges: base.edges.filter { $0.kind != .semanticNomination },
                sourceMayBeIncomplete: base.sourceMayBeIncomplete
            )
        }
        refreshGraphScene()
    }

    private func applyRadarHits(_ hits: [MindGraphHit]) {
        guard let base = graphSnapshot else { return }
        let focus = selectedGraphNodeID ?? selectedPath
        guard let focus else { return }
        let known = Set(base.nodes.compactMap(\.path))
        let nominations = hits.compactMap { hit -> MainframeSemanticNomination? in
            guard let path = conservativeKnownPath(hit.displayPath, known: known), path != focus else { return nil }
            return MainframeSemanticNomination(
                sourcePath: focus,
                targetPath: path,
                label: hit.title,
                provenance: "MindGraph \(hit.scope.displayName) nomination · \(hit.trustProfile)"
            )
        }
        graphSnapshot = MainframeGraphBuilder.addingSemanticNominations(nominations, to: base)
        graphMode = .radar
        refreshGraphScene()
    }

    private func conservativeKnownPath(_ displayPath: String, known: Set<String>) -> String? {
        let trimmed = displayPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if known.contains(trimmed) { return trimmed }
        if trimmed.hasPrefix("./") {
            let stripped = String(trimmed.dropFirst(2))
            if known.contains(stripped) { return stripped }
        }
        return nil
    }

    private func node(relativePath: String) -> MainframeExplorerNode? {
        if let contentIndex, let found = contentIndex.filesystemEntries.first(where: { $0.relativePath == relativePath }) {
            return found
        }
        if let found = rootChildren.first(where: { $0.relativePath == relativePath }) { return found }
        return childCache.values.lazy.flatMap { $0 }.first(where: { $0.relativePath == relativePath })
    }

    private func reveal(_ node: MainframeExplorerNode) {
        let components = node.relativePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }
        var parentPath = ""
        for component in components.dropLast() {
            parentPath = parentPath.isEmpty ? component : "\(parentPath)/\(component)"
            if let parent = node(relativePath: parentPath), parent.kind == .directory {
                if childCache[parentPath] == nil {
                    childCache[parentPath] = try? scanner.children(root: root, directory: parent.url)
                }
                expandedPaths.insert(parentPath)
            }
        }
    }

    private func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }
}
#endif
