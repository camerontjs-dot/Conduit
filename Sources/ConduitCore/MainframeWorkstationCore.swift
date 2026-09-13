import Foundation

public enum MainframeWorkstationRegion: String, CaseIterable, Sendable {
    case inbox
    case ingest
    case knowledge
    case live
    case projects
    case operations
    case archive

    public var displayName: String {
        switch self {
        case .inbox: return "Inbox"
        case .ingest: return "Ingest"
        case .knowledge: return "Knowledge"
        case .live: return "Live"
        case .projects: return "Projects"
        case .operations: return "Operations"
        case .archive: return "Archive"
        }
    }

    public var directoryName: String {
        switch self {
        case .inbox: return "00_inbox"
        case .ingest: return "01_ingest"
        case .knowledge: return "10_knowledge"
        case .live: return "20_live"
        case .projects: return "30_projects"
        case .operations: return "40_operations"
        case .archive: return "90_archive"
        }
    }
}

public enum MainframeWorkstationSignalKind: String, CaseIterable, Sendable {
    case lifecycleState
    case goal
    case nextAction
    case updated
    case wipClass
    case tag
    case taskCount
    case receiptCount
    case testReceipt
    case gitObservation
    case milestone
}

public enum MainframeWorkstationAuthority: String, Sendable {
    case lifecycleFile
    case observedRuntime
    case durableReceipt
    case observedGit
    case operatorNavigation
    case explicitInput
}

public struct MainframeWorkstationSignal: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: MainframeWorkstationSignalKind
    public let label: String
    public let value: String
    public let sourcePath: String?
    public let authority: MainframeWorkstationAuthority

    public init(
        id: String,
        kind: MainframeWorkstationSignalKind,
        label: String,
        value: String,
        sourcePath: String?,
        authority: MainframeWorkstationAuthority
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.value = value
        self.sourcePath = sourcePath
        self.authority = authority
    }
}

/// A fact supplied by an observed Conduit/Git/receipt boundary. Workstation
/// never invents these from prose or elapsed time.
public struct MainframeObservedWorkFact: Equatable, Sendable {
    public let scopePath: String
    public let kind: MainframeWorkstationSignalKind
    public let label: String
    public let value: String
    public let sourcePath: String?
    public let authority: MainframeWorkstationAuthority

    public init(
        scopePath: String,
        kind: MainframeWorkstationSignalKind,
        label: String,
        value: String,
        sourcePath: String?,
        authority: MainframeWorkstationAuthority
    ) {
        self.scopePath = scopePath
        self.kind = kind
        self.label = label
        self.value = value
        self.sourcePath = sourcePath
        self.authority = authority
    }
}

public struct MainframeWorkstationStation: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let slug: String
    public let recordType: MainframeLifecycleRecordType?
    public let isAuthoritative: Bool
    public let issues: [String]
    public let signals: [MainframeWorkstationSignal]

    public init(
        id: String,
        title: String,
        slug: String,
        recordType: MainframeLifecycleRecordType?,
        isAuthoritative: Bool,
        issues: [String],
        signals: [MainframeWorkstationSignal]
    ) {
        self.id = id
        self.title = title
        self.slug = slug
        self.recordType = recordType
        self.isAuthoritative = isAuthoritative
        self.issues = issues
        self.signals = signals
    }
}

public struct MainframeWorkstationProjection: Sendable {
    public let stations: [MainframeWorkstationStation]
    public let lifecycleIssueCount: Int
    public let rootIssueCount: Int

    public init(stations: [MainframeWorkstationStation], lifecycleIssueCount: Int, rootIssueCount: Int) {
        self.stations = stations
        self.lifecycleIssueCount = lifecycleIssueCount
        self.rootIssueCount = rootIssueCount
    }

    public var projects: [MainframeWorkstationStation] {
        stations.filter { $0.recordType == .project }
    }

    public var operations: [MainframeWorkstationStation] {
        stations.filter { $0.recordType == .operation }
    }
}

public enum MainframeWorkstationBuilder {
    public static func build(
        root: URL,
        lifecycle: MainframeLifecycleScan,
        observedFacts: [MainframeObservedWorkFact] = []
    ) -> MainframeWorkstationProjection {
        let rootPath = root.standardizedFileURL.path
        let factsByScope = Dictionary(grouping: observedFacts, by: \.scopePath)
        let stations = lifecycle.records.compactMap { record -> MainframeWorkstationStation? in
            guard let relative = relativePath(rootPath: rootPath, absolutePath: record.path.standardizedFileURL.path) else { return nil }
            var signals: [MainframeWorkstationSignal] = []
            let source = relative + "/" + record.readmePath.lastPathComponent

            func add(_ kind: MainframeWorkstationSignalKind, _ label: String, _ value: String?) {
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                signals.append(MainframeWorkstationSignal(
                    id: "lifecycle:\(relative):\(kind.rawValue):\(signals.count)",
                    kind: kind,
                    label: label,
                    value: value,
                    sourcePath: source,
                    authority: .lifecycleFile
                ))
            }

            add(.lifecycleState, "State", record.lifecycleState)
            add(.goal, "Goal", record.metadata.goal)
            add(.nextAction, "Next action", record.metadata.nextAction)
            add(.updated, "Updated", record.metadata.updated)
            add(.wipClass, "WIP class", record.wipClass)
            for tag in record.metadata.tags.sorted() { add(.tag, "Tag", tag) }

            for (index, fact) in (factsByScope[relative] ?? []).enumerated() {
                signals.append(MainframeWorkstationSignal(
                    id: "fact:\(relative):\(fact.kind.rawValue):\(index)",
                    kind: fact.kind,
                    label: fact.label,
                    value: fact.value,
                    sourcePath: fact.sourcePath,
                    authority: fact.authority
                ))
            }

            return MainframeWorkstationStation(
                id: relative,
                title: record.metadata.title ?? record.slug,
                slug: record.slug,
                recordType: record.recordType,
                isAuthoritative: record.isValid,
                issues: record.issues,
                signals: signals
            )
        }.sorted { lhs, rhs in
            let leftRank = recordRank(lhs.recordType)
            let rightRank = recordRank(rhs.recordType)
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        return MainframeWorkstationProjection(
            stations: stations,
            lifecycleIssueCount: lifecycle.issues.count,
            rootIssueCount: lifecycle.rootIssues.count
        )
    }

    private static func relativePath(rootPath: String, absolutePath: String) -> String? {
        if absolutePath == rootPath { return "" }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard absolutePath.hasPrefix(prefix) else { return nil }
        return String(absolutePath.dropFirst(prefix.count))
    }

    private static func recordRank(_ type: MainframeLifecycleRecordType?) -> Int {
        switch type {
        case .project: return 0
        case .operation: return 1
        case nil: return 2
        }
    }
}
