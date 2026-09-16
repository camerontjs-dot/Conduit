import Foundation

public enum MainframeEvidenceEventKind: String, CaseIterable, Sendable {
    case objective
    case task
    case fileChange
    case test
    case pullRequest
    case receipt
    case review
    case decision
    case milestone
    case other
}

public struct MainframeEvidenceEvent: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: MainframeEvidenceEventKind
    public let title: String
    public let detail: String?
    public let observedAt: Date?
    public let sourceLabel: String
    public let sourcePath: String?

    public init(
        id: String,
        kind: MainframeEvidenceEventKind,
        title: String,
        detail: String?,
        observedAt: Date?,
        sourceLabel: String,
        sourcePath: String?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.observedAt = observedAt
        self.sourceLabel = sourceLabel
        self.sourcePath = sourcePath
    }
}

public struct MainframeEvidenceTrail: Equatable, Sendable {
    public let events: [MainframeEvidenceEvent]

    public init(events: [MainframeEvidenceEvent]) {
        self.events = events.sorted { lhs, rhs in
            switch (lhs.observedAt, rhs.observedAt) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs.id < rhs.id
            }
        }
    }
}
