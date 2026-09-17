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
