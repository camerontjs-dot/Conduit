#if os(macOS)
import ConduitCore
import SwiftUI

struct MainframeGraphWorkspaceView: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var radarScope: MindGraphScope = .knowledge

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        VStack(spacing: 0) {
            graphToolbar
            Divider().overlay(palette.line)
            if let scene = model.graphScene {
                sceneSurface(scene)
            } else if model.graphMode == .pathfinder {
                emptyPathfinder
            } else {
                emptyGraph
            }
        }
        .background(palette.app)
        .onChange(of: model.graphMode) { mode in model.setGraphMode(mode) }
        .onChange(of: model.orbitDepth) { depth in model.setOrbitDepth(depth) }
    }

    private var graphToolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Picker("Graph mode", selection: $model.graphMode) {
                    ForEach(MainframeGraphMode.allCases, id: \.self) { mode in
                        Text(modeTitle(mode)).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                if model.graphMode == .orbit || model.graphMode == .radar {
                    Stepper("Depth \(model.orbitDepth)", value: $model.orbitDepth, in: 1...3)
                        .frame(width: 110)
                }

                Spacer()

                if model.graphMode == .radar, !model.radarHits.isEmpty {
                    Button("Clear Radar") { model.clearRadar() }
                        .buttonStyle(.bordered)
                }
            }

            switch model.graphMode {
            case .orbit:
                graphNote("Orbit · authored local links only by default · incoming and outgoing · bounded depth")
            case .atlas:
                graphNote("Atlas · deterministic lifecycle regions and high-connectivity documents · not a global force graph")
            case .pathfinder:
                pathfinderControls
            case .radar:
                radarControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(palette.surface)
    }

    private var pathfinderControls: some View {
        HStack(spacing: 8) {
            graphNote("Shortest authored-link path")
            nodePicker("From", selection: Binding(get: { model.pathfinderSourceID }, set: model.setPathfinderSource))
            Image(systemName: "arrow.right").foregroundStyle(palette.faint)
            nodePicker("To", selection: Binding(get: { model.pathfinderTargetID }, set: model.setPathfinderTarget))
            Spacer()
        }
    }

    private var radarControls: some View {
        HStack(spacing: 8) {
            Picker("Radar scope", selection: $radarScope) {
                ForEach(MindGraphScope.allCases) { scope in
                    Text(scope.displayName).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)

            TextField("Related concept or question", text: $model.radarQuestion)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)

            Button {
                runRadar()
            } label: {
                if model.isRadarLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Query Radar", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRadarLoading || radarQuestion.isEmpty || model.selectedGraphNodeID == nil && model.selectedPath == nil)

            Spacer()

            Text("Nominations · not authored links")
                .font(.caption2)
                .foregroundStyle(palette.faint)
        }
    }

    private func nodePicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text(title).tag(String?.none)
            ForEach(graphDocumentNodes, id: \.id) { node in
                Text(node.label).tag(Optional(node.id))
            }
        }
        .frame(maxWidth: 220)
    }

    private var graphDocumentNodes: [MainframeGraphNode] {
        (model.graphSnapshot?.nodes ?? []).filter { $0.kind != .task }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    @ViewBuilder
    private func sceneSurface(_ scene: MainframeGraphScene) -> some View {
        VStack(spacing: 0) {
            if scene.sourceMayBeIncomplete {
                Label("Graph source is bounded; additional nodes or links may exist outside the indexed corpus.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.surface)
            }

            ScrollView([.horizontal, .vertical]) {
                MainframeGraphSceneView(
                    scene: scene,
                    selectedNodeID: model.selectedGraphNodeID,
                    onSelect: model.selectGraphNode
                )
                .environmentObject(themeStore)
                .frame(width: sceneWidth(scene), height: sceneHeight(scene))
            }
            .background(palette.sink)

            graphSemanticList(scene)
        }
    }

    private func graphSemanticList(_ scene: MainframeGraphScene) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Accessible graph scene")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.faint)
            ScrollView(.horizontal) {
                HStack(spacing: 7) {
                    ForEach(scene.nodes) { node in
                        Button {
                            model.selectGraphNode(node.id)
                        } label: {
                            Label(node.label, systemImage: nodeSymbol(node))
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityValue(node.isAuthoritative ? "authoritative node" : "nomination node")
                    }
                }
            }
        }
        .padding(9)
        .background(palette.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Graph nodes")
    }

    private var emptyPathfinder: some View {
        VStack(spacing: 12) {
            Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                .font(.system(size: 38))
                .foregroundStyle(palette.dim)
            Text("Choose two nodes")
                .font(.title3.bold())
                .foregroundStyle(palette.text)
            Text(pathfinderEmptyMessage)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.dim)
                .frame(maxWidth: 500)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pathfinderEmptyMessage: String {
        if model.pathfinderSourceID != nil && model.pathfinderTargetID != nil {
            return "No authored-link path was found. Conduit will not substitute a semantic connection automatically. Use Radar explicitly if you want nomination candidates."
        }
        return "Pathfinder searches explicit authored-link edges only by default."
    }

    private var emptyGraph: some View {
        VStack(spacing: 12) {
            Image(systemName: "circle.grid.cross")
                .font(.system(size: 38))
                .foregroundStyle(palette.dim)
            Text("No graph scene")
                .font(.title3.bold())
                .foregroundStyle(palette.text)
            Text("Open an indexed document or project, then choose Orbit or Atlas.")
                .foregroundStyle(palette.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func runRadar() {
        let scope = radarScope
        let question = radarQuestion
        model.radarQuestion = question
        model.beginRadarQuery(scope: scope)
        Task {
            let result = await appModel.queryMindGraph(question: question, scope: scope, topK: 16)
            model.applyRadarResult(result, scope: scope)
        }
    }

    private var radarQuestion: String {
        let explicit = model.radarQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        return explicit.isEmpty ? model.selectedTitle : explicit
    }

    private func graphNote(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(palette.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func modeTitle(_ mode: MainframeGraphMode) -> String {
        switch mode {
        case .orbit: return "Orbit"
        case .atlas: return "Atlas"
        case .pathfinder: return "Pathfinder"
        case .radar: return "Radar"
        }
    }

    private func nodeSymbol(_ node: MainframeGraphNode) -> String {
        switch node.kind {
        case .document: return node.isAuthoritative ? "doc.text" : "sparkles"
        case .project: return "hammer"
        case .operation: return "gearshape.2"
        case .task: return "terminal"
        }
    }

    private func sceneWidth(_ scene: MainframeGraphScene) -> CGFloat {
        switch scene.mode {
        case .atlas: return max(1100, CGFloat(MainframeExplorerZone.allCases.count) * 280 + 180)
        default: return 1000
        }
    }

    private func sceneHeight(_ scene: MainframeGraphScene) -> CGFloat {
        switch scene.mode {
        case .atlas:
            let largest = Dictionary(grouping: scene.nodes.compactMap { node in node.zone.map { ($0, node) } }, by: { $0.0 }).values.map(\.count).max() ?? 1
            return max(650, CGFloat(largest) * 84 + 180)
        default: return 700
        }
    }
}

private struct MainframeGraphSceneView: View {
    let scene: MainframeGraphScene
    let selectedNodeID: String?
    let onSelect: (String) -> Void
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        GeometryReader { proxy in
            let positions = displayPositions(size: proxy.size)
            ZStack {
                Canvas { context, _ in
                    for edge in scene.edges {
                        guard let start = positions[edge.sourceID], let end = positions[edge.targetID] else { continue }
                        var path = Path()
                        path.move(to: start)
                        path.addLine(to: end)
                        context.stroke(
                            path,
                            with: .color(edgeColor(edge)),
                            style: edgeStyle(edge)
                        )
                    }
                }
                .accessibilityHidden(true)

                ForEach(scene.nodes) { node in
                    if let point = positions[node.id] {
                        Button {
                            onSelect(node.id)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: nodeSymbol(node))
                                    .font(.system(size: selectedNodeID == node.id ? 17 : 14, weight: .semibold))
                                Text(node.label)
                                    .font(.system(size: 10.5, weight: selectedNodeID == node.id ? .semibold : .regular))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 112)
                            }
                            .foregroundStyle(node.isAuthoritative ? palette.text : palette.dim)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 6)
                            .background(nodeBackground(node))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(selectedNodeID == node.id ? palette.accent : palette.line, lineWidth: selectedNodeID == node.id ? 2 : 1)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .position(point)
                        .help(node.path ?? node.label)
                        .accessibilityLabel("\(node.label), \(node.kind.rawValue) graph node")
                        .accessibilityValue(node.isAuthoritative ? "explicit or derived from source" : "semantic nomination")
                    }
                }
            }
        }
    }

    private func displayPositions(size: CGSize) -> [String: CGPoint] {
        switch scene.mode {
        case .atlas:
            return MainframeGraphLayout.atlas(scene: scene).mapValues { CGPoint(x: $0.x + 130, y: $0.y + 90) }
        case .pathfinder:
            let count = max(scene.nodes.count, 1)
            let spacing = min(220.0, max(130.0, (Double(size.width) - 180) / Double(max(count - 1, 1))))
            return Dictionary(uniqueKeysWithValues: scene.nodes.enumerated().map { index, node in
                (node.id, CGPoint(x: 90 + Double(index) * spacing, y: Double(size.height) / 2))
            })
        case .orbit, .radar:
            return MainframeGraphLayout.orbit(scene: scene, radius: min(Double(size.width), Double(size.height)) * 0.31)
                .mapValues { CGPoint(x: $0.x + Double(size.width) / 2, y: $0.y + Double(size.height) / 2) }
        }
    }

    private func edgeColor(_ edge: MainframeGraphEdge) -> Color {
        switch edge.kind {
        case .authoredLink: return palette.accent.opacity(0.72)
        case .containment: return palette.faint.opacity(0.55)
        case .semanticNomination: return palette.dim.opacity(0.65)
        case .taskSessionAssociation: return palette.dim.opacity(0.8)
        }
    }

    private func edgeStyle(_ edge: MainframeGraphEdge) -> StrokeStyle {
        switch edge.kind {
        case .semanticNomination:
            return StrokeStyle(lineWidth: 1.3, dash: [6, 5])
        case .containment:
            return StrokeStyle(lineWidth: 0.8)
        default:
            return StrokeStyle(lineWidth: 1.4)
        }
    }

    private func nodeBackground(_ node: MainframeGraphNode) -> Color {
        node.isAuthoritative ? palette.surface.opacity(0.96) : palette.surface.opacity(0.62)
    }

    private func nodeSymbol(_ node: MainframeGraphNode) -> String {
        switch node.kind {
        case .document: return node.isAuthoritative ? "doc.text" : "sparkles"
        case .project: return "hammer"
        case .operation: return "gearshape.2"
        case .task: return "terminal"
        }
    }
}
#endif
