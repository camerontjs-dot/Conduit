import Foundation

public struct MainframeAttentionItem: Identifiable, Equatable, Sendable {
    public var id: String { scopePath }
    public let scopePath: String
    public let visitCount: Int
    public let isCurrent: Bool
    public let isPinned: Bool

    public init(scopePath: String, visitCount: Int, isCurrent: Bool, isPinned: Bool) {
        self.scopePath = scopePath
        self.visitCount = visitCount
        self.isCurrent = isCurrent
        self.isPinned = isPinned
    }
}

/// Operator-attention projection only. A high count says the operator visited
/// the scope frequently; it does not imply importance, health, or priority.
public enum MainframeAttentionProjection {
    public static func build(
        navigationPaths: [String],
        scopePaths: [String],
        currentPath: String?,
        pinnedScopes: Set<String> = []
    ) -> [MainframeAttentionItem] {
        scopePaths.sorted().map { scope in
            let count = navigationPaths.filter { $0 == scope || $0.hasPrefix(scope + "/") }.count
            let current = currentPath.map { $0 == scope || $0.hasPrefix(scope + "/") } ?? false
            return MainframeAttentionItem(
                scopePath: scope,
                visitCount: count,
                isCurrent: current,
                isPinned: pinnedScopes.contains(scope)
            )
        }.filter { $0.visitCount > 0 || $0.isCurrent || $0.isPinned }
        .sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent && !rhs.isCurrent }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            if lhs.visitCount != rhs.visitCount { return lhs.visitCount > rhs.visitCount }
            return lhs.scopePath < rhs.scopePath
        }
    }
}
