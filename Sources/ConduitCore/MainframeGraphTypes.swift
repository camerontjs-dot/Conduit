import Foundation

public enum MainframeGraphMode: String, CaseIterable, Sendable {
    case orbit
    case atlas
    case pathfinder
    case radar
}

public enum MainframeGraphNodeKind: String, Sendable {
    case document
    case project
    case operation
    case task
}

public struct MainframeGraphNode: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let path: String?
    public let kind: MainframeGraphNodeKind
    public let zone: MainframeExplorerZone?
    public let isAuthoritative: Bool

    public init(
        id: String,
        label: String,
        path: String?,
        kind: MainframeGraphNodeKind,
        zone: MainframeExplorerZone?,
        isAuthoritative: Bool
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.kind = kind
        self.zone = zone
        self.isAuthoritative = isAuthoritative
    }
}

public enum MainframeGraphEdgeKind: String, CaseIterable, Sendable {
    case authoredLink
    case containment
    case semanticNomination
    case taskSessionAssociation
}

public struct MainframeGraphEdge: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let sourceID: String
    public let targetID: String
    public let kind: MainframeGraphEdgeKind
    public let provenance: String
    public let isDirected: Bool

    public init(
        id: String,
        sourceID: String,
        targetID: String,
        kind: MainframeGraphEdgeKind,
        provenance: String,
        isDirected: Bool
    ) {
        self.id = id
        self.sourceID = sourceID
        self.targetID = targetID
        self.kind = kind
        self.provenance = provenance
        self.isDirected = isDirected
    }
}

public struct MainframeGraphSnapshot: Sendable {
    public let nodes: [MainframeGraphNode]
    public let edges: [MainframeGraphEdge]
    public let sourceMayBeIncomplete: Bool

    public init(nodes: [MainframeGraphNode], edges: [MainframeGraphEdge], sourceMayBeIncomplete: Bool) {
        self.nodes = nodes
        self.edges = edges
        self.sourceMayBeIncomplete = sourceMayBeIncomplete
    }

    public var nodeByID: [String: MainframeGraphNode] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }

    public func edges(allowedKinds: Set<MainframeGraphEdgeKind>) -> [MainframeGraphEdge] {
        edges.filter { allowedKinds.contains($0.kind) }
    }
}

public struct MainframeGraphScene: Sendable {
    public let mode: MainframeGraphMode
    public let nodes: [MainframeGraphNode]
    public let edges: [MainframeGraphEdge]
    public let focusNodeID: String?
    public let sourceMayBeIncomplete: Bool

    public init(
        mode: MainframeGraphMode,
        nodes: [MainframeGraphNode],
        edges: [MainframeGraphEdge],
        focusNodeID: String?,
        sourceMayBeIncomplete: Bool
    ) {
        self.mode = mode
        self.nodes = nodes
        self.edges = edges
        self.focusNodeID = focusNodeID
        self.sourceMayBeIncomplete = sourceMayBeIncomplete
    }
}

public struct MainframeSemanticNomination: Equatable, Sendable {
    public let sourcePath: String
    public let targetPath: String
    public let label: String
    public let provenance: String

    public init(sourcePath: String, targetPath: String, label: String, provenance: String) {
        self.sourcePath = sourcePath
        self.targetPath = targetPath
        self.label = label
        self.provenance = provenance
    }
}

public struct MainframeTaskAssociation: Equatable, Sendable {
    public let taskID: String
    public let taskLabel: String
    public let scopePath: String
    public let provenance: String

    public init(taskID: String, taskLabel: String, scopePath: String, provenance: String) {
        self.taskID = taskID
        self.taskLabel = taskLabel
        self.scopePath = scopePath
        self.provenance = provenance
    }
}
