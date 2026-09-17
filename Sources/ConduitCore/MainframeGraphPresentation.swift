import Foundation

/// Stable identity for the visible relationship scene. Presentation layers can
/// reuse layout while this value is unchanged instead of reacting to unrelated
/// runtime publications.
public struct MainframeGraphSceneSignature: Equatable, Hashable, Sendable {
    public let mode: MainframeGraphMode
    public let focusNodeID: String?
    public let nodeIDs: [String]
    public let edgeIDs: [String]

    public init(scene: MainframeGraphScene) {
        mode = scene.mode
        focusNodeID = scene.focusNodeID
        nodeIDs = scene.nodes.map(\.id).sorted()
        edgeIDs = scene.edges.map { "\($0.kind.rawValue):\($0.id)" }.sorted()
    }
}

/// Maps ordinary Explorer selection to the nearest source-backed graph focus.
///
/// Markdown/lifecycle nodes may exist exactly in the graph. Source code and
/// other filesystem entries often do not, so Related falls back to the nearest
/// containing project/operation rather than leaving the previous graph focus
/// stuck on screen or jumping to an unrelated first project.
public enum MainframeGraphFocusResolver {
    public static func focusNodeID(
        selectedPath: String?,
        snapshot: MainframeGraphSnapshot
    ) -> String? {
        guard let selectedPath, !selectedPath.isEmpty else { return nil }
        if snapshot.nodeByID[selectedPath] != nil { return selectedPath }

        return snapshot.nodes
            .filter { node in
                guard node.kind == .project || node.kind == .operation,
                      let path = node.path else { return false }
                return selectedPath == path || selectedPath.hasPrefix(path + "/")
            }
            .sorted {
                let leftLength = $0.path?.count ?? 0
                let rightLength = $1.path?.count ?? 0
                if leftLength != rightLength { return leftLength > rightLength }
                return $0.id < $1.id
            }
            .first?
            .id
    }
}
