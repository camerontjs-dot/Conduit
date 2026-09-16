#if os(macOS)
import ConduitCore
import Foundation
import SwiftUI

/// Ephemeral derived state shared by Explore's Find, Graph, and Workstation
/// surfaces. MainFrame files remain source truth; none of these projections is
/// persisted as project, knowledge, lifecycle, or verification authority.
@MainActor
final class MainframeKnowledgeProjectionModel: ObservableObject {
    @Published private(set) var contentIndex: MainframeContentIndex?
    @Published private(set) var graphSnapshot: MainframeGraphSnapshot?
    @Published private(set) var workstation: MainframeWorkstationProjection?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var semanticHitCount = 0

    private var baseGraphSnapshot: MainframeGraphSnapshot?
    private var lifecycleScan: MainframeLifecycleScan?
    private var configuredRoot: URL?
    private var generation = UUID()
    private var taskAssociations: [MainframeTaskAssociation] = []
    private var semanticNominations: [MainframeSemanticNomination] = []
    private var observedWorkFacts: [MainframeObservedWorkFact] = []

    func ensureLoaded(root: URL) {
        let normalized = root.standardizedFileURL
        if configuredRoot?.standardizedFileURL == normalized,
           isLoading || (contentIndex != nil && graphSnapshot != nil && workstation != nil) {
            return
        }

        let rootChanged = configuredRoot?.standardizedFileURL != normalized
        configuredRoot = normalized
        if rootChanged {
            taskAssociations = []
            semanticNominations = []
            observedWorkFacts = []
        }

        let currentGeneration = UUID()
        generation = currentGeneration
        isLoading = true
        errorMessage = nil
        contentIndex = nil
        graphSnapshot = nil
        baseGraphSnapshot = nil
        lifecycleScan = nil
        workstation = nil
        semanticHitCount = 0

        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .utility) {
                    let lifecycle = try MainframeLifecycleScanner().scan(root: normalized)
                    let content = try MainframeContentIndexer().build(root: normalized)
                    let graph = MainframeGraphBuilder.build(
                        root: normalized,
                        content: content,
                        lifecycle: lifecycle
                    )
                    return (lifecycle, content, graph)
                }.value

                guard let self, self.generation == currentGeneration else { return }
                self.lifecycleScan = result.0
                self.contentIndex = result.1
                self.baseGraphSnapshot = result.2
                self.rebuildOverlays()
                self.isLoading = false
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func refresh(root: URL) {
        semanticNominations = []
        semanticHitCount = 0
        configuredRoot = nil
        ensureLoaded(root: root)
    }

    func setObservedContext(
        taskAssociations: [MainframeTaskAssociation],
        observedWorkFacts: [MainframeObservedWorkFact]
    ) {
        self.taskAssociations = taskAssociations
        self.observedWorkFacts = observedWorkFacts
        rebuildOverlays()
    }

    func deterministicSearch(_ query: String, limit: Int = 200) -> MainframeSearchResult? {
        guard let contentIndex else { return nil }
        return MainframeTextSearch.search(contentIndex, query: query, limit: limit)
    }

    func outgoingLinks(for path: String) -> [MainframeDocumentLinkRecord] {
        contentIndex?.linkIndex.outgoing[path] ?? []
    }

    func incomingLinks(for path: String) -> [MainframeDocumentLinkRecord] {
        contentIndex?.linkIndex.incoming[path] ?? []
    }

    /// Semantic retrieval is admitted only as a nomination layer and only when
    /// a returned path resolves exactly to a path in the bounded MainFrame
    /// index. Unknown paths are ignored rather than guessed into existence.
    func applyMindGraphHits(_ hits: [MindGraphHit], focusPath: String) {
        guard let baseGraphSnapshot,
              baseGraphSnapshot.nodeByID[focusPath] != nil,
              let contentIndex else { return }

        let knownPaths = Set(contentIndex.filesystemEntries.map(\.relativePath))
            .union(contentIndex.records.map(\.path))
        semanticNominations = hits.compactMap { hit -> MainframeSemanticNomination? in
            guard let target = resolveMindGraphPath(hit.displayPath, knownPaths: knownPaths),
                  target != focusPath else { return nil }
            let score = hit.rrfScore.map { String(format: "%.3f", $0) } ?? "unreported"
            return MainframeSemanticNomination(
                sourcePath: focusPath,
                targetPath: target,
                label: hit.title,
                provenance: "MindGraph nomination · \(hit.scope.displayName) · trust \(hit.trustProfile) · rrf \(score)"
            )
        }
        semanticHitCount = semanticNominations.count
        rebuildOverlays()
    }

    private func rebuildOverlays() {
        if let baseGraphSnapshot {
            var graph = MainframeGraphBuilder.addingTaskAssociations(taskAssociations, to: baseGraphSnapshot)
            graph = MainframeGraphBuilder.addingSemanticNominations(semanticNominations, to: graph)
            graphSnapshot = graph
        }

        if let configuredRoot, let lifecycleScan {
            workstation = MainframeWorkstationBuilder.build(
                root: configuredRoot,
                lifecycle: lifecycleScan,
                observedFacts: observedWorkFacts
            )
        }
    }

    private func resolveMindGraphPath(_ raw: String, knownPaths: Set<String>) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if knownPaths.contains(trimmed) { return trimmed }
        guard let configuredRoot else { return nil }

        let rootPath = configuredRoot.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidate.hasPrefix(prefix) else { return nil }
        let relative = String(candidate.dropFirst(prefix.count))
        return knownPaths.contains(relative) ? relative : nil
    }
}

// MARK: - Deterministic Find

struct MainframeFindSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let root: URL
    @ObservedObject var projection: MainframeKnowledgeProjectionModel
    let onOpenPath: (String) -> Void

    @State private var query = ""

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var result: MainframeSearchResult? {
        projection.deterministicSearch(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Find in MainFrame", systemImage: "text.magnifyingglass")
                    .font(.headline)
                Spacer()
                if projection.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(14)

            TextField("Path, filename, heading, metadata, or exact text", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)

            if let result, result.mayBeIncomplete {
                Text("Bounded derived index: search results may be incomplete.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider().overlay(palette.line)

            if let error = projection.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(palette.dim)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if projection.isLoading && projection.contentIndex == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Building bounded read-only content index…")
                        .foregroundStyle(palette.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(result?.hits ?? []) { hit in
                    Button {
                        onOpenPath(hit.path)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbol(for: hit.kind))
                                .foregroundStyle(palette.dim)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hit.path)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(palette.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !hit.excerpt.isEmpty {
                                    Text(hit.excerpt)
                                        .font(.caption)
                                        .foregroundStyle(palette.dim)
                                        .lineLimit(3)
                                }
                                Text(hit.line > 0
                                    ? "\(hit.kind.rawValue) · line \(hit.line)"
                                    : hit.kind.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(palette.faint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .scrollContentBackground(.hidden)
            }

            Divider().overlay(palette.line)
            HStack {
                Text("Deterministic Find. Semantic MindGraph nominations stay separate.")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                Spacer()
                Button("Refresh Index") { projection.refresh(root: root) }
                    .buttonStyle(.borderless)
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 500)
        .background(palette.app)
        .task { projection.ensureLoaded(root: root) }
    }

    private func symbol(for kind: MainframeSearchHitKind) -> String {
        switch kind {
        case .path: return "folder"
        case .heading: return "textformat.size"
        case .metadata: return "tag"
        case .content: return "text.quote"
        }
    }
}

// MARK: - Graph

struct MainframeGraphSurfaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let root: URL
    let selectedPath: String?
    @ObservedObject var projection: MainframeKnowledgeProjectionModel
    let onOpenPath: (String) -> Void

    @State private var mode: MainframeGraphMode = .orbit
    @State private var focusNodeID: String?
    @State private var selectedGraphNodeID: String?
    @State private var depth = 1
    @State private var allowedKinds: Set<MainframeGraphEdgeKind> = [
        .authoredLink, .containment, .taskSessionAssociation
    ]
    @State private var pathStartID: String?
    @State private var pathEndID: String?
    @State private var showMindGraph = false

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var snapshot: MainframeGraphSnapshot? { projection.graphSnapshot }

    private var effectiveFocusID: String? {
        guard let snapshot else { return nil }
        if let focusNodeID, snapshot.nodeByID[focusNodeID] != nil { return focusNodeID }
        if let selectedPath, snapshot.nodeByID[selectedPath] != nil { return selectedPath }
        return snapshot.nodes.first(where: { $0.kind == .project || $0.kind == .operation })?.id
            ?? snapshot.nodes.first?.id
    }

    private var scene: MainframeGraphScene? {
        guard let snapshot else { return nil }
        switch mode {
        case .orbit:
            guard let focus = effectiveFocusID else { return nil }
            return MainframeGraphQuery.orbit(
                snapshot: snapshot,
                focusNodeID: focus,
                depth: depth,
                allowedKinds: allowedKinds,
                maxNodes: 80
            )
        case .atlas:
            return MainframeGraphQuery.atlas(snapshot: snapshot, maxNodesPerZone: 26)
        case .pathfinder:
            guard let start = pathStartID, let end = pathEndID else { return nil }
            return MainframeGraphQuery.shortestPath(
                snapshot: snapshot,
                from: start,
                to: end,
                allowedKinds: allowedKinds,
                maxVisited: 5_000
            )
        case .radar:
            guard let focus = effectiveFocusID else { return nil }
            return MainframeGraphQuery.orbit(
                snapshot: snapshot,
                focusNodeID: focus,
                depth: depth,
                allowedKinds: [.authoredLink, .containment, .semanticNomination, .taskSessionAssociation],
                maxNodes: 80
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider().overlay(palette.line)

            if let error = projection.errorMessage {
                errorState(error)
            } else if projection.isLoading && projection.graphSnapshot == nil {
                loadingState
            } else if let scene {
                graphScene(scene)
            } else if mode == .pathfinder {
                pathfinderEmptyState
            } else {
                emptyState
            }
        }
        .background(palette.sink)
        .task {
            projection.ensureLoaded(root: root)
            syncObservedContext()
        }
        .onReceive(model.$taskSessions) { _ in
            syncObservedContext()
        }
        .onReceive(model.$sessions) { _ in
            syncObservedContext()
        }
        .onChange(of: selectedPath) { newPath in
            guard let newPath,
                  projection.graphSnapshot?.nodeByID[newPath] != nil else { return }
            focusNodeID = newPath
        }
        .sheet(isPresented: $showMindGraph) {
            MindGraphQueryView(
                initialQuestion: selectedGraphNodeLabel,
                onOpenPath: { path in
                    if let resolved = resolveMindGraphDisplayPath(path) {
                        onOpenPath(resolved)
                    }
                },
                onResults: { hits in
                    guard let focus = effectiveFocusID else { return }
                    projection.applyMindGraphHits(hits, focusPath: focus)
                    mode = .radar
                }
            )
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("Graph mode", selection: $mode) {
                    ForEach(MainframeGraphMode.allCases, id: \.self) { item in
                        Text(modeName(item)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)

                Spacer()

                if mode == .orbit || mode == .radar {
                    Stepper("Depth \(depth)", value: $depth, in: 1...3)
                        .font(.caption)
                }

                Menu {
                    ForEach(MainframeGraphEdgeKind.allCases, id: \.self) { kind in
                        Toggle(isOn: edgeBinding(kind)) {
                            Text(edgeName(kind))
                        }
                    }
                } label: {
                    Label("Edges", systemImage: "line.diagonal")
                }
                .menuStyle(.borderlessButton)

                Button {
                    showMindGraph = true
                } label: {
                    Label("MindGraph", systemImage: "point.3.connected.trianglepath.dotted")
                }
                .buttonStyle(.bordered)
                .actionExplainer(
                    ActionExplainerSpec(
                        title: "MindGraph Radar",
                        summary: "Query semantic project knowledge and overlay returned material as explicit nominations.",
                        nonEffect: "Does not convert semantic retrieval into authored links or filesystem authority.",
                        target: effectiveFocusID,
                        authority: "MindGraph nomination"
                    )
                )

                Button {
                    projection.refresh(root: root)
                    syncObservedContext()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .actionExplainer(
                    ActionExplainerSpec(
                        title: "Refresh Graph",
                        summary: "Rebuild the derived graph from the current MainFrame and reapply observed task bindings.",
                        nonEffect: "Does not modify MainFrame, Git, tasks, or agent runtimes.",
                        target: root.path,
                        authority: "Filesystem + observed task projection"
                    )
                )
            }

            if mode == .pathfinder, let snapshot {
                HStack(spacing: 10) {
                    Picker("From", selection: $pathStartID) {
                        Text("Choose start").tag(String?.none)
                        ForEach(snapshot.nodes) { node in
                            Text(node.label).tag(Optional(node.id))
                        }
                    }
                    .frame(maxWidth: 320)

                    Image(systemName: "arrow.right").foregroundStyle(palette.faint)

                    Picker("To", selection: $pathEndID) {
                        Text("Choose destination").tag(String?.none)
                        ForEach(snapshot.nodes) { node in
                            Text(node.label).tag(Optional(node.id))
                        }
                    }
                    .frame(maxWidth: 320)

                    Spacer()
                    Text("Shortest path over enabled edge classes")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
            }

            if mode == .radar {
                HStack {
                    Text("Radar overlays MindGraph nominations as retrieval evidence, never authored relationships.")
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                    Spacer()
                    Text("\(projection.semanticHitCount) nominations")
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.faint)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.surface)
    }

    private func graphScene(_ scene: MainframeGraphScene) -> some View {
        VStack(spacing: 0) {
            GeometryReader { _ in
                let layout = graphLayout(scene)
                let canvas = canvasGeometry(layout)
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for edge in scene.edges {
                                guard let a = canvas.points[edge.sourceID],
                                      let b = canvas.points[edge.targetID] else { continue }
                                var path = Path()
                                path.move(to: a)
                                path.addLine(to: b)
                                let style = StrokeStyle(
                                    lineWidth: edge.kind == .semanticNomination ? 1.2 : 1.6,
                                    dash: edge.kind == .semanticNomination ? [6, 5] : []
                                )
                                context.stroke(
                                    path,
                                    with: .color(edgeColor(edge.kind)),
                                    style: style
                                )
                            }
                        }
                        .frame(width: canvas.width, height: canvas.height)

                        ForEach(scene.nodes) { node in
                            if let point = canvas.points[node.id] {
                                graphNode(node, focus: scene.focusNodeID == node.id)
                                    .position(point)
                            }
                        }
                    }
                    .frame(width: canvas.width, height: canvas.height)
                }
            }
            .frame(minHeight: 420)

            if let selected = selectedGraphNode {
                Divider().overlay(palette.line)
                graphInspector(selected, scene: scene)
            }
        }
    }

    private func graphNode(_ node: MainframeGraphNode, focus: Bool) -> some View {
        Button {
            selectedGraphNodeID = node.id
        } label: {
            VStack(spacing: 4) {
                Image(systemName: nodeSymbol(node))
                    .font(.system(size: focus ? 20 : 16, weight: .semibold))
                Text(node.label)
                    .font(.caption.weight(focus ? .bold : .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if !node.isAuthoritative {
                    Text("NOMINATION")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                }
            }
            .foregroundStyle(palette.text)
            .frame(width: focus ? 154 : 136)
            .frame(minHeight: focus ? 72 : 58)
            .padding(.vertical, 7)
            .background(focus ? palette.accentSoft : palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        selectedGraphNodeID == node.id ? palette.accent : palette.line,
                        lineWidth: selectedGraphNodeID == node.id ? 2 : 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let path = node.path {
                Button("Open in Explorer") { onOpenPath(path) }
            }
            Button("Focus Orbit Here") {
                focusNodeID = node.id
                mode = .orbit
            }
            Button("Use as Pathfinder Start") {
                pathStartID = node.id
                mode = .pathfinder
            }
            Button("Use as Pathfinder End") {
                pathEndID = node.id
                mode = .pathfinder
            }
        }
    }

    private func graphInspector(_ node: MainframeGraphNode, scene: MainframeGraphScene) -> some View {
        let incident = scene.edges.filter { $0.sourceID == node.id || $0.targetID == node.id }
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(node.label)
                    .font(.headline)
                    .foregroundStyle(palette.text)
                if let path = node.path {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(palette.dim)
                        .textSelection(.enabled)
                }
                Text(node.isAuthoritative ? "SOURCE-BACKED NODE" : "RETRIEVAL NOMINATION")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.faint)
                if let path = node.path {
                    Button("Open in Explorer") { onOpenPath(path) }
                        .buttonStyle(.bordered)
                }
            }
            .frame(width: 250, alignment: .leading)

            Divider()

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    if incident.isEmpty {
                        Text("No visible relationships in this scene.")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                    }
                    ForEach(incident) { edge in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(edgeName(edge.kind).uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(palette.faint)
                            Text(edge.provenance)
                                .font(.caption)
                                .foregroundStyle(palette.dim)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(height: 130)
        .background(palette.surface)
    }

    private var selectedGraphNode: MainframeGraphNode? {
        guard let selectedGraphNodeID else { return nil }
        return projection.graphSnapshot?.nodeByID[selectedGraphNodeID]
    }

    private var selectedGraphNodeLabel: String? {
        selectedGraphNode?.label
            ?? effectiveFocusID.flatMap { projection.graphSnapshot?.nodeByID[$0]?.label }
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Building bounded graph from MainFrame…")
                .foregroundStyle(palette.dim)
            Text("Derived state is ephemeral and does not replace files as authority.")
                .font(.caption)
                .foregroundStyle(palette.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 38))
                .foregroundStyle(palette.dim)
            Text("No graph scene available")
                .font(.headline)
                .foregroundStyle(palette.text)
            Text("Choose a source-backed file or work record in Explorer, or switch to Atlas.")
                .foregroundStyle(palette.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pathfinderEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 38))
                .foregroundStyle(palette.dim)
            Text(pathStartID == nil || pathEndID == nil ? "Choose two graph nodes" : "No explicit path found")
                .font(.headline)
                .foregroundStyle(palette.text)
            Text("Pathfinder searches only the edge classes you explicitly enabled.")
                .foregroundStyle(palette.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Graph unavailable", systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(error).foregroundStyle(palette.dim)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func graphLayout(_ scene: MainframeGraphScene) -> [String: MainframeGraphPoint] {
        switch scene.mode {
        case .orbit, .radar:
            return MainframeGraphLayout.orbit(scene: scene, radius: 230)
        case .atlas:
            return MainframeGraphLayout.atlas(scene: scene, columnWidth: 280, rowHeight: 86)
        case .pathfinder:
            return Dictionary(uniqueKeysWithValues: scene.nodes.enumerated().map { index, node in
                (node.id, MainframeGraphPoint(x: Double(index) * 220, y: 0))
            })
        }
    }

    private func canvasGeometry(
        _ points: [String: MainframeGraphPoint]
    ) -> (points: [String: CGPoint], width: CGFloat, height: CGFloat) {
        guard !points.isEmpty else { return ([:], 900, 520) }
        let xs = points.values.map(\.x)
        let ys = points.values.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        let inset: Double = 150
        let width = max(900, maxX - minX + inset * 2)
        let height = max(520, maxY - minY + inset * 2)
        let shifted = Dictionary(uniqueKeysWithValues: points.map { key, value in
            (key, CGPoint(x: value.x - minX + inset, y: value.y - minY + inset))
        })
        return (shifted, width, height)
    }

    private func edgeBinding(_ kind: MainframeGraphEdgeKind) -> Binding<Bool> {
        Binding(
            get: { allowedKinds.contains(kind) },
            set: { enabled in
                if enabled { allowedKinds.insert(kind) }
                else { allowedKinds.remove(kind) }
                if allowedKinds.isEmpty { allowedKinds.insert(.authoredLink) }
            }
        )
    }

    private func resolveMindGraphDisplayPath(_ path: String) -> String? {
        if projection.contentIndex?.filesystemEntries.contains(where: { $0.relativePath == path }) == true {
            return path
        }
        let rootPath = root.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard candidate.hasPrefix(prefix) else { return nil }
        let relative = String(candidate.dropFirst(prefix.count))
        return projection.contentIndex?.filesystemEntries.contains(where: { $0.relativePath == relative }) == true
            ? relative
            : nil
    }

    private func syncObservedContext() {
        let observed = MainframeObservedTaskBridge.build(
            root: root,
            tasks: model.taskSessions,
            runtimes: model.sessions
        )
        projection.setObservedContext(
            taskAssociations: observed.taskAssociations,
            observedWorkFacts: observed.observedWorkFacts
        )
    }

    private func modeName(_ mode: MainframeGraphMode) -> String {
        switch mode {
        case .orbit: return "Orbit"
        case .atlas: return "Atlas"
        case .pathfinder: return "Pathfinder"
        case .radar: return "Radar"
        }
    }

    private func edgeName(_ kind: MainframeGraphEdgeKind) -> String {
        switch kind {
        case .authoredLink: return "Authored link"
        case .containment: return "Containment"
        case .semanticNomination: return "Semantic nomination"
        case .taskSessionAssociation: return "Task association"
        }
    }

    private func nodeSymbol(_ node: MainframeGraphNode) -> String {
        switch node.kind {
        case .document: return "doc.text"
        case .project: return "hammer"
        case .operation: return "gearshape.2"
        case .task: return "terminal"
        }
    }

    private func edgeColor(_ kind: MainframeGraphEdgeKind) -> Color {
        switch kind {
        case .authoredLink: return palette.accent.opacity(0.68)
        case .containment: return palette.dim.opacity(0.45)
        case .semanticNomination: return palette.faint.opacity(0.68)
        case .taskSessionAssociation: return palette.text.opacity(0.42)
        }
    }
}

// MARK: - Workstation

struct MainframeWorkstationSurfaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let root: URL
    @ObservedObject var projection: MainframeKnowledgeProjectionModel
    let onOpenPath: (String) -> Void

    @State private var filter = ""

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var stations: [MainframeWorkstationStation] {
        guard let workstation = projection.workstation else { return [] }
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return workstation.stations }
        return workstation.stations.filter { station in
            ([station.title, station.slug] + station.signals.map { "\($0.label) \($0.value)" })
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            workstationToolbar
            Divider().overlay(palette.line)

            if let error = projection.errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Workstation unavailable", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(error).foregroundStyle(palette.dim)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if projection.isLoading && projection.workstation == nil {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading lifecycle authority…")
                        .foregroundStyle(palette.dim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                workstationContent
            }
        }
        .background(palette.sink)
        .task {
            projection.ensureLoaded(root: root)
            syncObservedContext()
        }
        .onReceive(model.$taskSessions) { _ in
            syncObservedContext()
        }
        .onReceive(model.$sessions) { _ in
            syncObservedContext()
        }
    }

    private var workstationToolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("MAINFRAME WORKSTATION")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(palette.faint)
                Text("Lifecycle facts and inspectable work signals")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
            Spacer()
            TextField("Filter stations", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
            Button {
                projection.refresh(root: root)
                syncObservedContext()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .actionExplainer(
                ActionExplainerSpec(
                    title: "Refresh Workstation",
                    summary: "Re-read lifecycle authority and reapply current observed task/runtime facts.",
                    nonEffect: "Does not change lifecycle records or agent runtime state.",
                    target: root.path,
                    authority: "Lifecycle records + observed runtime facts"
                )
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.surface)
    }

    private var workstationContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                lifecycleMap

                if let workstation = projection.workstation,
                   workstation.lifecycleIssueCount > 0 || workstation.rootIssueCount > 0 {
                    Label(
                        "Lifecycle authority reports \(workstation.lifecycleIssueCount) record issue(s) and \(workstation.rootIssueCount) root issue(s). Invalid records remain visibly unverified.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .padding(10)
                    .background(palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                stationSection("PROJECTS", stations.filter { $0.recordType == .project })
                stationSection("OPERATIONS", stations.filter { $0.recordType == .operation })
            }
            .padding(18)
        }
    }

    private var lifecycleMap: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("LIFECYCLE MAP")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(palette.faint)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 9)], spacing: 9) {
                ForEach(MainframeWorkstationRegion.allCases, id: \.self) { region in
                    Button {
                        onOpenPath(region.directoryName)
                    } label: {
                        VStack(spacing: 7) {
                            Image(systemName: regionSymbol(region))
                                .font(.system(size: 20))
                                .foregroundStyle(palette.accent)
                            Text(region.displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.text)
                            Text(region.directoryName)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(palette.faint)
                        }
                        .frame(maxWidth: .infinity, minHeight: 82)
                        .background(palette.surface)
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.line, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Region placement means filesystem lifecycle location only. It does not imply progress, health, or priority.")
                .font(.caption2)
                .foregroundStyle(palette.faint)
        }
    }

    @ViewBuilder
    private func stationSection(_ title: String, _ rows: [MainframeWorkstationStation]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(palette.faint)
            if rows.isEmpty {
                Text("No matching validated records in this view.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                    ForEach(rows) { station in
                        stationCard(station)
                    }
                }
            }
        }
    }

    private func stationCard(_ station: MainframeWorkstationStation) -> some View {
        let liveRuntimes = MainframeObservedTaskBridge.liveRuntimes(
            for: station.id,
            root: root,
            tasks: model.taskSessions,
            runtimes: model.sessions
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: station.recordType == .operation ? "gearshape.2" : "hammer")
                    .foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.title)
                        .font(.headline)
                        .foregroundStyle(palette.text)
                    Text(station.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(station.isAuthoritative ? "VERIFIED IDENTITY" : "UNVERIFIED")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(palette.faint)
            }

            ForEach(Array(station.signals.prefix(8))) { signal in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(signal.label.uppercased())
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.faint)
                        .frame(width: 82, alignment: .leading)
                    Text(signal.value)
                        .font(.caption)
                        .foregroundStyle(palette.text)
                        .lineLimit(signal.kind == .goal || signal.kind == .nextAction ? 3 : 1)
                    Spacer(minLength: 0)
                }
                .help(signal.sourcePath.map { "Source: \($0) · \(signal.authority.rawValue)" }
                    ?? "Authority: \(signal.authority.rawValue)")
            }

            if !liveRuntimes.isEmpty {
                liveRuntimeCompanions(liveRuntimes)
            }

            if !station.issues.isEmpty {
                Text(station.issues.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
            }

            HStack {
                Spacer()
                Button("Open Scope") { onOpenPath(station.id) }
                    .buttonStyle(.bordered)
                    .actionExplainer(
                        ActionExplainerSpec(
                            title: "Open Work Scope",
                            summary: "Open this validated project or operation path in Explorer.",
                            nonEffect: "Does not activate an agent or imply the scope is complete, healthy, or prioritized.",
                            target: station.id,
                            authority: station.isAuthoritative ? "Validated lifecycle identity" : "Unverified lifecycle record"
                        )
                    )
            }
        }
        .padding(12)
        .background(palette.surface)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func liveRuntimeCompanions(_ runtimes: [TerminalRuntime]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OBSERVED LIVE RUNTIMES")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.7)
                .foregroundStyle(palette.faint)

            HStack(spacing: 10) {
                ForEach(Array(runtimes.prefix(4).enumerated()), id: \.offset) { _, runtime in
                    TimelineView(.periodic(from: .now, by: 0.7)) { timeline in
                        let state = runtime.controller.visualState(at: timeline.date)
                        VStack(spacing: 3) {
                            AgentSpriteView(
                                profile: runtime.descriptor.agent,
                                state: state,
                                frameSize: CGSize(width: 38, height: 42)
                            )
                            Text(runtime.descriptor.agent.name)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                            Text(state.spriteCue.accessibilityPhrase)
                                .font(.system(size: 7))
                                .foregroundStyle(palette.faint)
                                .lineLimit(1)
                        }
                        .help("Observed runtime for this exact task scope · \(state.spriteCue.accessibilityPhrase)")
                    }
                }
                if runtimes.count > 4 {
                    Text("+\(runtimes.count - 4)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.faint)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(palette.sink.opacity(0.45))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func syncObservedContext() {
        let observed = MainframeObservedTaskBridge.build(
            root: root,
            tasks: model.taskSessions,
            runtimes: model.sessions
        )
        projection.setObservedContext(
            taskAssociations: observed.taskAssociations,
            observedWorkFacts: observed.observedWorkFacts
        )
    }

    private func regionSymbol(_ region: MainframeWorkstationRegion) -> String {
        switch region {
        case .inbox: return "tray"
        case .ingest: return "arrow.down.doc"
        case .knowledge: return "books.vertical"
        case .live: return "dot.radiowaves.left.and.right"
        case .projects: return "hammer"
        case .operations: return "gearshape.2"
        case .archive: return "archivebox"
        }
    }
}
#endif
