#if os(macOS)
import ConduitCore
import SwiftUI

struct MainframeGraphInspectorView: View {
    @ObservedObject var model: MainframeKnowledgeWorkspaceModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette { themeStore.palette(for: colorScheme) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let node = selectedNode {
                    nodeCard(node)
                    relationshipSection(node)
                    legend
                } else {
                    Text("Select a graph node to inspect its exact type, source path, authority posture, and incident relationships.")
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(palette.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Graph inspector")
    }

    private var selectedNode: MainframeGraphNode? {
        guard let id = model.selectedGraphNodeID else { return nil }
        return model.graphSnapshot?.nodeByID[id]
    }

    private func nodeCard(_ node: MainframeGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: nodeSymbol(node))
                    .foregroundStyle(node.isAuthoritative ? palette.accent : palette.dim)
                Text(node.label)
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Spacer()
            }
            fact("Type", node.kind.rawValue)
            if let path = node.path { fact("Path", path) }
            if let zone = node.zone { fact("Region", zone.rawValue) }
            fact("Node posture", node.isAuthoritative ? "Explicit / source-derived" : "Semantic nomination")

            if let path = node.path, model.contentIndex?.filesystemEntries.contains(where: { $0.relativePath == path }) == true {
                Button("Open in Reader") {
                    model.open(relativePath: path, surface: .reader)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .padding(12)
        .background(palette.app)
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(palette.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private func relationshipSection(_ node: MainframeGraphNode) -> some View {
        let edges = incidentEdges(node.id)
        VStack(alignment: .leading, spacing: 9) {
            Text("Relationships")
                .font(.headline)
                .foregroundStyle(palette.text)
            if edges.isEmpty {
                Text("No relationships in the current graph snapshot.")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            } else {
                ForEach(MainframeGraphEdgeKind.allCases, id: \.self) { kind in
                    let group = edges.filter { $0.kind == kind }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(edgeTitle(kind))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.dim)
                            ForEach(group) { edge in
                                edgeRow(edge, selectedID: node.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private func edgeRow(_ edge: MainframeGraphEdge, selectedID: String) -> some View {
        let otherID = edge.sourceID == selectedID ? edge.targetID : edge.sourceID
        let other = model.graphSnapshot?.nodeByID[otherID]
        return VStack(alignment: .leading, spacing: 3) {
            Button {
                model.selectGraphNode(otherID)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: edge.kind == .semanticNomination ? "sparkles" : "arrow.left.and.right")
                        .foregroundStyle(edge.kind == .semanticNomination ? palette.dim : palette.faint)
                    Text(other?.label ?? otherID)
                        .font(.caption)
                        .foregroundStyle(palette.text)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            Text(edge.provenance)
                .font(.caption2)
                .foregroundStyle(palette.faint)
                .fixedSize(horizontal: false, vertical: true)
            Text(edge.isDirected ? "Directed relationship" : "Undirected nomination")
                .font(.caption2)
                .foregroundStyle(palette.faint)
        }
        .padding(7)
        .background(palette.app.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Legend")
                .font(.headline)
                .foregroundStyle(palette.text)
            legendRow("Authored link", "Solid accent edge", "Markdown source")
            legendRow("Containment", "Fine neutral edge", "Filesystem path")
            legendRow("Radar", "Dashed edge", "MindGraph nomination")
            legendRow("Task association", "Neutral edge", "Recorded Conduit scope")
            Text("Graph geometry is presentation only. Distance and placement do not encode certainty, health, importance, or progress.")
                .font(.caption2)
                .foregroundStyle(palette.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func legendRow(_ title: String, _ visual: String, _ source: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(palette.text)
            Text("\(visual) · \(source)").font(.caption2).foregroundStyle(palette.dim)
        }
    }

    private func incidentEdges(_ id: String) -> [MainframeGraphEdge] {
        (model.graphSnapshot?.edges ?? [])
            .filter { $0.sourceID == id || $0.targetID == id }
            .sorted {
                if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
                return $0.id < $1.id
            }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.faint)
            Text(value)
                .font(.caption)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
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

    private func edgeTitle(_ kind: MainframeGraphEdgeKind) -> String {
        switch kind {
        case .authoredLink: return "Authored links"
        case .containment: return "Containment"
        case .semanticNomination: return "Radar nominations"
        case .taskSessionAssociation: return "Task associations"
        }
    }
}
#endif
