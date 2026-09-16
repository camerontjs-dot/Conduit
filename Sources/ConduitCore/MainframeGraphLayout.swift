import Foundation

public struct MainframeGraphPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// Deterministic presentation coordinates. They are scene state only and carry
/// no authority or project-state meaning.
public enum MainframeGraphLayout {
    public static func orbit(scene: MainframeGraphScene, radius: Double = 220) -> [String: MainframeGraphPoint] {
        guard let focus = scene.focusNodeID else { return [:] }
        var result: [String: MainframeGraphPoint] = [focus: MainframeGraphPoint(x: 0, y: 0)]
        let others = scene.nodes.filter { $0.id != focus }.sorted { $0.id < $1.id }
        guard !others.isEmpty else { return result }
        for (index, node) in others.enumerated() {
            let angle = (Double(index) / Double(others.count)) * 2 * Double.pi - Double.pi / 2
            result[node.id] = MainframeGraphPoint(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        return result
    }

    public static func atlas(scene: MainframeGraphScene, columnWidth: Double = 280, rowHeight: Double = 84) -> [String: MainframeGraphPoint] {
        let zoneOrder = MainframeExplorerZone.allCases
        var result: [String: MainframeGraphPoint] = [:]
        for (zoneIndex, zone) in zoneOrder.enumerated() {
            let nodes = scene.nodes.filter { $0.zone == zone }.sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    let rank: [MainframeGraphNodeKind: Int] = [.project: 0, .operation: 0, .document: 1, .task: 2]
                    return (rank[lhs.kind] ?? 9) < (rank[rhs.kind] ?? 9)
                }
                return lhs.id < rhs.id
            }
            for (row, node) in nodes.enumerated() {
                result[node.id] = MainframeGraphPoint(x: Double(zoneIndex) * columnWidth, y: Double(row) * rowHeight)
            }
        }
        return result
    }
}
