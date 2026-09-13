import Foundation

public enum MainframeGraphQuery {
    public static func orbit(
        snapshot: MainframeGraphSnapshot,
        focusNodeID: String,
        depth: Int = 1,
        allowedKinds: Set<MainframeGraphEdgeKind> = [.authoredLink],
        maxNodes: Int = 80
    ) -> MainframeGraphScene {
        let boundedDepth = min(max(depth, 0), 3)
        let nodeLimit = max(1, maxNodes)
        let nodeByID = snapshot.nodeByID
        guard nodeByID[focusNodeID] != nil else {
            return MainframeGraphScene(mode: .orbit, nodes: [], edges: [], focusNodeID: nil, sourceMayBeIncomplete: snapshot.sourceMayBeIncomplete)
        }
        let candidates = snapshot.edges(allowedKinds: allowedKinds)
        var included: Set<String> = [focusNodeID]
        var frontier: Set<String> = [focusNodeID]

        if boundedDepth > 0 {
            for _ in 1...boundedDepth {
                var next = Set<String>()
                for edge in candidates {
                    if frontier.contains(edge.sourceID) { next.insert(edge.targetID) }
                    if frontier.contains(edge.targetID) { next.insert(edge.sourceID) }
                }
                next.subtract(included)
                if next.isEmpty { break }
                for id in next.sorted() where included.count < nodeLimit { included.insert(id) }
                frontier = Set(next.filter { included.contains($0) })
                if included.count >= nodeLimit { break }
            }
        }

        let nodes = included.compactMap { nodeByID[$0] }.sorted { $0.id < $1.id }
        let edges = candidates.filter { included.contains($0.sourceID) && included.contains($0.targetID) }
        return MainframeGraphScene(
            mode: .orbit,
            nodes: nodes,
            edges: edges,
            focusNodeID: focusNodeID,
            sourceMayBeIncomplete: snapshot.sourceMayBeIncomplete
        )
    }

    public static func atlas(snapshot: MainframeGraphSnapshot, maxNodesPerZone: Int = 40) -> MainframeGraphScene {
        let perZone = max(1, maxNodesPerZone)
        let degree = Dictionary(grouping: snapshot.edges.flatMap { [$0.sourceID, $0.targetID] }, by: { $0 }).mapValues(\.count)
        var selected = Set<String>()

        for zone in MainframeExplorerZone.allCases {
            let zoneNodes = snapshot.nodes.filter { $0.zone == zone }
            let records = zoneNodes.filter { $0.kind == .project || $0.kind == .operation }
            for node in records { selected.insert(node.id) }
            let remaining = zoneNodes.filter { $0.kind == .document }
                .sorted {
                    let left = degree[$0.id] ?? 0
                    let right = degree[$1.id] ?? 0
                    if left != right { return left > right }
                    return $0.id < $1.id
                }
                .prefix(perZone)
            for node in remaining { selected.insert(node.id) }
        }

        let nodes = snapshot.nodes.filter { selected.contains($0.id) }
        let edges = snapshot.edges.filter { selected.contains($0.sourceID) && selected.contains($0.targetID) }
        return MainframeGraphScene(
            mode: .atlas,
            nodes: nodes,
            edges: edges,
            focusNodeID: nil,
            sourceMayBeIncomplete: snapshot.sourceMayBeIncomplete
        )
    }

    public static func shortestPath(
        snapshot: MainframeGraphSnapshot,
        from sourceID: String,
        to targetID: String,
        allowedKinds: Set<MainframeGraphEdgeKind> = [.authoredLink],
        maxVisited: Int = 5_000
    ) -> MainframeGraphScene? {
        guard sourceID != targetID, snapshot.nodeByID[sourceID] != nil, snapshot.nodeByID[targetID] != nil else { return nil }
        let edges = snapshot.edges(allowedKinds: allowedKinds)
        var adjacency: [String: [(neighbor: String, edge: MainframeGraphEdge)]] = [:]
        for edge in edges {
            adjacency[edge.sourceID, default: []].append((edge.targetID, edge))
            adjacency[edge.targetID, default: []].append((edge.sourceID, edge))
        }
        for key in adjacency.keys { adjacency[key]?.sort { $0.neighbor < $1.neighbor } }

        var queue: [String] = [sourceID]
        var cursor = 0
        var previous: [String: (node: String, edge: MainframeGraphEdge)] = [:]
        var visited: Set<String> = [sourceID]
        let visitLimit = max(2, maxVisited)

        while cursor < queue.count, visited.count <= visitLimit {
            let current = queue[cursor]
            cursor += 1
            if current == targetID { break }
            for item in adjacency[current] ?? [] where !visited.contains(item.neighbor) {
                visited.insert(item.neighbor)
                previous[item.neighbor] = (current, item.edge)
                queue.append(item.neighbor)
                if item.neighbor == targetID { break }
            }
        }
        guard visited.contains(targetID) else { return nil }

        var pathNodeIDs: [String] = [targetID]
        var pathEdges: [MainframeGraphEdge] = []
        var current = targetID
        while current != sourceID {
            guard let step = previous[current] else { return nil }
            pathEdges.append(step.edge)
            current = step.node
            pathNodeIDs.append(current)
        }
        pathNodeIDs.reverse()
        pathEdges.reverse()
        let byID = snapshot.nodeByID
        return MainframeGraphScene(
            mode: .pathfinder,
            nodes: pathNodeIDs.compactMap { byID[$0] },
            edges: pathEdges,
            focusNodeID: sourceID,
            sourceMayBeIncomplete: snapshot.sourceMayBeIncomplete
        )
    }
}
