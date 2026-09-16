import Foundation

public enum MainframeGraphBuilder {
    public static func build(
        root: URL,
        content: MainframeContentIndex,
        lifecycle: MainframeLifecycleScan
    ) -> MainframeGraphSnapshot {
        var nodes: [String: MainframeGraphNode] = [:]
        var edges: [MainframeGraphEdge] = []

        for record in content.records {
            nodes[record.path] = MainframeGraphNode(
                id: record.path,
                label: record.name,
                path: record.path,
                kind: .document,
                zone: record.zone,
                isAuthoritative: true
            )
        }

        let rootPath = root.standardizedFileURL.path
        let validRecords = lifecycle.records.filter(\.isValid)
        for record in validRecords {
            guard let relative = relativePath(rootPath: rootPath, absolutePath: record.path.standardizedFileURL.path),
                  let type = record.recordType else { continue }
            let label = record.metadata.title ?? record.slug
            let kind: MainframeGraphNodeKind = type == .project ? .project : .operation
            let zone: MainframeExplorerZone = type == .project ? .projects : .operations
            nodes[relative] = MainframeGraphNode(
                id: relative,
                label: label,
                path: relative,
                kind: kind,
                zone: zone,
                isAuthoritative: true
            )
        }

        let linkIndex = content.linkIndex
        for source in linkIndex.outgoing.keys.sorted() {
            for record in linkIndex.outgoing[source] ?? [] {
                guard !record.link.isImage else { continue }
                switch record.resolution {
                case .local(let target, _):
                    guard nodes[source] != nil, nodes[target] != nil else { continue }
                    edges.append(MainframeGraphEdge(
                        id: "link:\(source):\(record.link.id):\(target)",
                        sourceID: source,
                        targetID: target,
                        kind: .authoredLink,
                        provenance: "Markdown link at \(source):\(record.link.line)",
                        isDirected: true
                    ))
                case .sameDocumentAnchor:
                    continue
                case .external, .unresolved:
                    continue
                }
            }
        }

        let recordNodes = nodes.values.filter { $0.kind == .project || $0.kind == .operation }
        for document in content.records {
            let owners = recordNodes.filter { owner in
                guard let path = owner.path else { return false }
                return document.path.hasPrefix(path + "/")
            }.sorted { ($0.path?.count ?? 0) > ($1.path?.count ?? 0) }
            guard let owner = owners.first else { continue }
            edges.append(MainframeGraphEdge(
                id: "contains:\(owner.id):\(document.path)",
                sourceID: owner.id,
                targetID: document.path,
                kind: .containment,
                provenance: "Filesystem path containment",
                isDirected: true
            ))
        }

        return MainframeGraphSnapshot(
            nodes: nodes.values.sorted { $0.id < $1.id },
            edges: edges.sorted { $0.id < $1.id },
            sourceMayBeIncomplete: content.mayBeIncomplete
        )
    }

    public static func addingSemanticNominations(
        _ nominations: [MainframeSemanticNomination],
        to snapshot: MainframeGraphSnapshot
    ) -> MainframeGraphSnapshot {
        var nodes = snapshot.nodeByID
        var edges = snapshot.edges
        for nomination in nominations {
            guard nodes[nomination.sourcePath] != nil else { continue }
            if nodes[nomination.targetPath] == nil {
                nodes[nomination.targetPath] = MainframeGraphNode(
                    id: nomination.targetPath,
                    label: URL(fileURLWithPath: nomination.targetPath).lastPathComponent,
                    path: nomination.targetPath,
                    kind: .document,
                    zone: MainframeExplorerZone.classify(relativePath: nomination.targetPath),
                    isAuthoritative: false
                )
            }
            edges.append(MainframeGraphEdge(
                id: "semantic:\(nomination.sourcePath):\(nomination.targetPath):\(edges.count)",
                sourceID: nomination.sourcePath,
                targetID: nomination.targetPath,
                kind: .semanticNomination,
                provenance: nomination.provenance,
                isDirected: false
            ))
        }
        return MainframeGraphSnapshot(
            nodes: nodes.values.sorted { $0.id < $1.id },
            edges: deduplicate(edges),
            sourceMayBeIncomplete: snapshot.sourceMayBeIncomplete
        )
    }

    public static func addingTaskAssociations(
        _ associations: [MainframeTaskAssociation],
        to snapshot: MainframeGraphSnapshot
    ) -> MainframeGraphSnapshot {
        var nodes = snapshot.nodeByID
        var edges = snapshot.edges
        for association in associations {
            guard nodes[association.scopePath] != nil else { continue }
            let taskNodeID = "task:\(association.taskID)"
            nodes[taskNodeID] = MainframeGraphNode(
                id: taskNodeID,
                label: association.taskLabel,
                path: nil,
                kind: .task,
                zone: nil,
                isAuthoritative: true
            )
            edges.append(MainframeGraphEdge(
                id: "task-association:\(association.taskID):\(association.scopePath)",
                sourceID: taskNodeID,
                targetID: association.scopePath,
                kind: .taskSessionAssociation,
                provenance: association.provenance,
                isDirected: true
            ))
        }
        return MainframeGraphSnapshot(
            nodes: nodes.values.sorted { $0.id < $1.id },
            edges: deduplicate(edges),
            sourceMayBeIncomplete: snapshot.sourceMayBeIncomplete
        )
    }

    private static func relativePath(rootPath: String, absolutePath: String) -> String? {
        if absolutePath == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard absolutePath.hasPrefix(prefix) else { return nil }
        return String(absolutePath.dropFirst(prefix.count))
    }

    private static func deduplicate(_ edges: [MainframeGraphEdge]) -> [MainframeGraphEdge] {
        var seen = Set<String>()
        return edges.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
    }
}
