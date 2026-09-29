import Foundation

public enum ContextRepresentationLevel: String, Codable, CaseIterable, Sendable {
    case reference
    case compactNomination
    case excerpt
    case full
    case extractiveDigest
    case generatedSummary
}

public enum ContextSetDisposition: String, Codable, CaseIterable, Sendable {
    case mandatory
    case nominated
    case expanded
    case omitted
    case deferred
}

public enum ContextInclusionReasonKind: String, Hashable, Codable, CaseIterable, Sendable {
    case objective
    case operatorPin
    case requiredContract
    case exactIdentity
    case lexicalMatch
    case semanticNomination
    case graphRelationship
    case taskArtifact
    case priorContextSet
    case explicitExpansion
    case externalBootstrap
    case other
}

public struct ContextInclusionReason: Equatable, Hashable, Codable, Sendable {
    public let kind: ContextInclusionReasonKind
    public let detail: String?

    public init(_ kind: ContextInclusionReasonKind, detail: String? = nil) {
        self.kind = kind
        self.detail = detail
    }
}

public struct ContextComponentVersion: Equatable, Codable, Sendable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct ContextRepositoryIdentity: Equatable, Codable, Sendable {
    public let repository: String?
    public let scopePath: String?
    public let branch: String?
    public let commitSHA: String?

    public init(
        repository: String? = nil,
        scopePath: String? = nil,
        branch: String? = nil,
        commitSHA: String? = nil
    ) {
        self.repository = repository
        self.scopePath = scopePath
        self.branch = branch
        self.commitSHA = commitSHA
    }
}

public struct ContextSupersession: Equatable, Codable, Sendable {
    public let targetItemID: String
    public let targetSourceReference: String
    public let targetRevisionIdentity: String

    public init(
        targetItemID: String,
        targetSourceReference: String,
        targetRevisionIdentity: String
    ) {
        self.targetItemID = targetItemID
        self.targetSourceReference = targetSourceReference
        self.targetRevisionIdentity = targetRevisionIdentity
    }
}

/// A typed reference inside a Context Set.
///
/// This stores provenance and representation metadata around an existing
/// `AgentContextItem`. It does not copy source bytes into the Context Set.
public struct ContextSetEntry: Equatable, Codable, Sendable {
    public var item: AgentContextItem
    public var disposition: ContextSetDisposition
    public var representation: ContextRepresentationLevel
    public var inclusionReasons: [ContextInclusionReason]
    public var contentDigest: String?
    public var truncationReason: String?
    public var dispositionReason: String?
    public var duplicateItemIDs: [String]
    public var duplicateSourceReferences: [String]
    public var supersedes: [ContextSupersession]

    public init(
        item: AgentContextItem,
        disposition: ContextSetDisposition,
        representation: ContextRepresentationLevel = .reference,
        inclusionReasons: [ContextInclusionReason] = [],
        contentDigest: String? = nil,
        truncationReason: String? = nil,
        dispositionReason: String? = nil,
        duplicateItemIDs: [String] = [],
        duplicateSourceReferences: [String] = [],
        supersedes: [ContextSupersession] = []
    ) {
        self.item = item
        self.disposition = disposition
        self.representation = representation
        self.inclusionReasons = Self.normalizedReasons(inclusionReasons)
        self.contentDigest = contentDigest
        self.truncationReason = truncationReason
        self.dispositionReason = dispositionReason
        self.duplicateItemIDs = Self.normalizedStrings(duplicateItemIDs)
        self.duplicateSourceReferences = Self.normalizedStrings(duplicateSourceReferences)
        self.supersedes = supersedes
    }

    public var isDeliveredToWorker: Bool {
        disposition == .mandatory || disposition == .expanded
    }

    public var isProtectedHardContext: Bool {
        disposition == .mandatory || item.isPinned || item.authority == .operatorPinned
    }

    fileprivate var duplicateKey: String {
        let authorityClass = item.authority.authorityClass.rawValue
        if let digest = contentDigest?.trimmingCharacters(in: .whitespacesAndNewlines),
           !digest.isEmpty {
            return [
                "digest",
                digest,
                authorityClass,
                representation.rawValue
            ].joined(separator: "|")
        }

        let range = item.lineRange.map { "\($0.lowerBound)-\($0.upperBound)" } ?? ""
        if let revision = item.revisionIdentity, !revision.isEmpty {
            return [
                "source",
                item.sourceReference,
                revision,
                range,
                authorityClass,
                representation.rawValue
            ].joined(separator: "|")
        }

        return [
            "item",
            item.id,
            item.sourceReference,
            range,
            authorityClass,
            representation.rawValue
        ].joined(separator: "|")
    }

    fileprivate static func normalizedReasons(
        _ reasons: [ContextInclusionReason]
    ) -> [ContextInclusionReason] {
        Array(Set(reasons)).sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return ($0.detail ?? "") < ($1.detail ?? "")
        }
    }

    fileprivate static func normalizedStrings(_ strings: [String]) -> [String] {
        Array(Set(strings.filter { !$0.isEmpty })).sorted()
    }
}

public struct ContextSet: Equatable, Codable, Sendable {
    public let id: String
    public let objective: String
    public let taskIdentity: String?
    public let repositoryIdentity: ContextRepositoryIdentity?
    public let entries: [ContextSetEntry]
    public let unresolvedPrerequisites: [String]
    public let retrieverVersions: [ContextComponentVersion]

    public init(
        id: String,
        objective: String,
        taskIdentity: String? = nil,
        repositoryIdentity: ContextRepositoryIdentity? = nil,
        entries: [ContextSetEntry],
        unresolvedPrerequisites: [String] = [],
        retrieverVersions: [ContextComponentVersion] = []
    ) {
        self.id = id
        self.objective = objective
        self.taskIdentity = taskIdentity
        self.repositoryIdentity = repositoryIdentity
        self.entries = entries
        self.unresolvedPrerequisites = ContextSetEntry.normalizedStrings(unresolvedPrerequisites)
        self.retrieverVersions = retrieverVersions.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.version < $1.version
        }
    }

    public func expanding(
        itemID: String,
        representation: ContextRepresentationLevel = .full,
        reasonDetail: String? = nil
    ) throws -> ContextSet {
        guard let index = entries.firstIndex(where: { $0.item.id == itemID }) else {
            throw ContextCompilerError.itemNotFound(itemID)
        }

        let current = entries[index]
        guard current.disposition == .nominated || current.disposition == .expanded else {
            throw ContextCompilerError.itemNotExpandable(itemID, current.disposition)
        }

        var updated = entries
        var entry = current
        entry.disposition = .expanded
        entry.representation = representation
        entry.dispositionReason = nil
        entry.inclusionReasons = ContextSetEntry.normalizedReasons(
            entry.inclusionReasons
                + [ContextInclusionReason(.explicitExpansion, detail: reasonDetail)]
        )
        updated[index] = entry

        return ContextSet(
            id: id,
            objective: objective,
            taskIdentity: taskIdentity,
            repositoryIdentity: repositoryIdentity,
            entries: updated,
            unresolvedPrerequisites: unresolvedPrerequisites,
            retrieverVersions: retrieverVersions
        )
    }

    /// Applies only explicit, exact supersession statements.
    ///
    /// Hard context is never evicted by this helper. A target is marked omitted
    /// only when item ID, source reference and exact revision identity all match
    /// the declared predecessor.
    public func applyingExplicitSupersession() -> ContextSet {
        var updated = entries
        for superseder in entries
        where superseder.disposition != .omitted && superseder.disposition != .deferred {
            for relation in superseder.supersedes {
                guard let targetIndex = updated.firstIndex(where: {
                    $0.item.id == relation.targetItemID
                        && $0.item.sourceReference == relation.targetSourceReference
                        && $0.item.revisionIdentity == relation.targetRevisionIdentity
                }) else {
                    continue
                }
                guard updated[targetIndex].item.id != superseder.item.id,
                      !updated[targetIndex].isProtectedHardContext else {
                    continue
                }
                updated[targetIndex].disposition = .omitted
                updated[targetIndex].dispositionReason =
                    "explicitly superseded by \(superseder.item.id)"
            }
        }

        return ContextSet(
            id: id,
            objective: objective,
            taskIdentity: taskIdentity,
            repositoryIdentity: repositoryIdentity,
            entries: updated,
            unresolvedPrerequisites: unresolvedPrerequisites,
            retrieverVersions: retrieverVersions
        )
    }

    /// Deterministically coalesces exact duplicate references while retaining
    /// every inclusion reason and inspectable duplicate source identity.
    ///
    /// The input order remains the ranking order. Deduplication does not invent
    /// a new relevance score or authority class.
    public func deduplicated() -> ContextSet {
        let supersessionApplied = protectingHardContext().applyingExplicitSupersession()
        var result: [ContextSetEntry] = []
        var indexByKey: [String: Int] = [:]

        for entry in supersessionApplied.entries {
            let key = entry.duplicateKey
            if let existingIndex = indexByKey[key] {
                result[existingIndex] = Self.merge(result[existingIndex], entry)
            } else {
                indexByKey[key] = result.count
                result.append(entry)
            }
        }

        return ContextSet(
            id: id,
            objective: objective,
            taskIdentity: taskIdentity,
            repositoryIdentity: repositoryIdentity,
            entries: result,
            unresolvedPrerequisites: unresolvedPrerequisites,
            retrieverVersions: retrieverVersions
        )
    }

    private func protectingHardContext() -> ContextSet {
        var updated = entries
        for index in updated.indices
        where updated[index].item.isPinned
            || updated[index].item.authority == .operatorPinned {
            updated[index].disposition = .mandatory
            updated[index].inclusionReasons = ContextSetEntry.normalizedReasons(
                updated[index].inclusionReasons + [ContextInclusionReason(.operatorPin)]
            )
        }
        return ContextSet(
            id: id,
            objective: objective,
            taskIdentity: taskIdentity,
            repositoryIdentity: repositoryIdentity,
            entries: updated,
            unresolvedPrerequisites: unresolvedPrerequisites,
            retrieverVersions: retrieverVersions
        )
    }

    private static func merge(
        _ left: ContextSetEntry,
        _ right: ContextSetEntry
    ) -> ContextSetEntry {
        let stronger = strongerDisposition(left.disposition, right.disposition)
        let prefersRight = stronger == right.disposition && stronger != left.disposition
        let preferred = prefersRight ? right : left
        let other = prefersRight ? left : right

        var merged = preferred
        merged.disposition = stronger
        merged.inclusionReasons = ContextSetEntry.normalizedReasons(
            left.inclusionReasons + right.inclusionReasons
        )
        merged.contentDigest = preferred.contentDigest ?? other.contentDigest
        merged.truncationReason = preferred.truncationReason ?? other.truncationReason
        merged.dispositionReason = preferred.dispositionReason ?? other.dispositionReason
        merged.supersedes = left.supersedes + right.supersedes

        let duplicateIDs = left.duplicateItemIDs
            + right.duplicateItemIDs
            + [other.item.id]
        merged.duplicateItemIDs = ContextSetEntry.normalizedStrings(
            duplicateIDs.filter { $0 != merged.item.id }
        )

        let duplicateSources = left.duplicateSourceReferences
            + right.duplicateSourceReferences
            + [other.item.sourceReference]
        merged.duplicateSourceReferences = ContextSetEntry.normalizedStrings(
            duplicateSources.filter { $0 != merged.item.sourceReference }
        )

        return merged
    }

    private static func strongerDisposition(
        _ left: ContextSetDisposition,
        _ right: ContextSetDisposition
    ) -> ContextSetDisposition {
        func rank(_ value: ContextSetDisposition) -> Int {
            switch value {
            case .mandatory: return 5
            case .expanded: return 4
            case .nominated: return 3
            case .deferred: return 2
            case .omitted: return 1
            }
        }
        return rank(right) > rank(left) ? right : left
    }
}

public struct ContextExternalBootstrap: Equatable, Codable, Sendable {
    public let objective: String
    public let taskIdentity: String?
    public let repositoryIdentity: ContextRepositoryIdentity?
    public let mandatoryItems: [AgentContextItem]
    public let discoverableItems: [AgentContextItem]
    public let taskTriggeredItems: [AgentContextItem]
    public let unresolvedPrerequisites: [String]
    public let producerVersions: [ContextComponentVersion]

    public init(
        objective: String,
        taskIdentity: String? = nil,
        repositoryIdentity: ContextRepositoryIdentity? = nil,
        mandatoryItems: [AgentContextItem] = [],
        discoverableItems: [AgentContextItem] = [],
        taskTriggeredItems: [AgentContextItem] = [],
        unresolvedPrerequisites: [String] = [],
        producerVersions: [ContextComponentVersion] = []
    ) {
        self.objective = objective
        self.taskIdentity = taskIdentity
        self.repositoryIdentity = repositoryIdentity
        self.mandatoryItems = mandatoryItems
        self.discoverableItems = discoverableItems
        self.taskTriggeredItems = taskTriggeredItems
        self.unresolvedPrerequisites = unresolvedPrerequisites
        self.producerVersions = producerVersions
    }

    public func makeContextSet(id: String) -> ContextSet {
        func entry(
            _ item: AgentContextItem,
            category: String,
            mandatory: Bool
        ) -> ContextSetEntry {
            let protected = mandatory || item.isPinned || item.authority == .operatorPinned
            return ContextSetEntry(
                item: item,
                disposition: protected ? .mandatory : .nominated,
                representation: protected ? .reference : .compactNomination,
                inclusionReasons: [
                    ContextInclusionReason(.externalBootstrap, detail: category),
                    item.isPinned || item.authority == .operatorPinned
                        ? ContextInclusionReason(.operatorPin)
                        : ContextInclusionReason(.other, detail: "bootstrap classification")
                ]
            )
        }

        let entries =
            mandatoryItems.map { entry($0, category: "mandatory", mandatory: true) }
            + discoverableItems.map { entry($0, category: "discoverable", mandatory: false) }
            + taskTriggeredItems.map { entry($0, category: "task-triggered", mandatory: false) }

        return ContextSet(
            id: id,
            objective: objective,
            taskIdentity: taskIdentity,
            repositoryIdentity: repositoryIdentity,
            entries: entries,
            unresolvedPrerequisites: unresolvedPrerequisites,
            retrieverVersions: producerVersions
        )
    }
}

public enum ContextCompilerError: Error, Equatable, Sendable {
    case itemNotFound(String)
    case itemNotExpandable(String, ContextSetDisposition)
}

public struct ContextDestination: Equatable, Codable, Sendable {
    public let runtime: String?
    public let model: String?
    public let capacityTokens: Int?
    public let tokenizer: String?

    public init(
        runtime: String? = nil,
        model: String? = nil,
        capacityTokens: Int? = nil,
        tokenizer: String? = nil
    ) {
        self.runtime = runtime
        self.model = model
        self.capacityTokens = capacityTokens.map { max(0, $0) }
        self.tokenizer = tokenizer
    }
}

public struct ContextBudget: Equatable, Codable, Sendable {
    public let reservedOutputTokens: Int?
    public let reservedToolTokens: Int?

    public init(
        reservedOutputTokens: Int? = nil,
        reservedToolTokens: Int? = nil
    ) {
        self.reservedOutputTokens = reservedOutputTokens.map { max(0, $0) }
        self.reservedToolTokens = reservedToolTokens.map { max(0, $0) }
    }
}

public enum ContextBudgetAssessmentState: String, Codable, CaseIterable, Sendable {
    case fitsKnownEstimate
    case unknownDestinationCapacity
    case unknownReservation
    case unknownSelectedCost
    case hardContextExceedsCapacity
    case selectedContextExceedsCapacity
}

public struct ContextBudgetSummary: Equatable, Codable, Sendable {
    public let destinationCapacityTokens: Int?
    public let reservedOutputTokens: Int?
    public let reservedToolTokens: Int?
    public let availableInputTokens: Int?

    public let mandatoryKnownEstimatedTokens: Int
    public let mandatoryUnknownItemCount: Int
    public let expandedKnownEstimatedTokens: Int
    public let expandedUnknownItemCount: Int
    public let optionalNominationKnownEstimatedTokens: Int
    public let optionalNominationUnknownItemCount: Int

    public let state: ContextBudgetAssessmentState

    public var deliveredKnownEstimatedTokenSubtotal: Int {
        mandatoryKnownEstimatedTokens + expandedKnownEstimatedTokens
    }
}

public enum ContextBudgetEvaluator {
    public static func assess(
        entries: [ContextSetEntry],
        destination: ContextDestination,
        budget: ContextBudget
    ) -> ContextBudgetSummary {
        let mandatory = tokenFacts(entries.filter { $0.disposition == .mandatory })
        let expanded = tokenFacts(entries.filter { $0.disposition == .expanded })
        let nominations = tokenFacts(entries.filter { $0.disposition == .nominated })

        let capacity = destination.capacityTokens
        let reservedOutput = budget.reservedOutputTokens
        let reservedTool = budget.reservedToolTokens

        let available: Int?
        if let capacity, let reservedOutput, let reservedTool {
            available = max(0, capacity - reservedOutput - reservedTool)
        } else {
            available = nil
        }

        let state: ContextBudgetAssessmentState
        if capacity == nil {
            state = .unknownDestinationCapacity
        } else if reservedOutput == nil || reservedTool == nil {
            state = .unknownReservation
        } else if let available, mandatory.knownTokens > available {
            state = .hardContextExceedsCapacity
        } else if let available,
                  mandatory.knownTokens + expanded.knownTokens > available {
            state = .selectedContextExceedsCapacity
        } else if mandatory.unknownCount + expanded.unknownCount > 0 {
            state = .unknownSelectedCost
        } else {
            state = .fitsKnownEstimate
        }

        return ContextBudgetSummary(
            destinationCapacityTokens: capacity,
            reservedOutputTokens: reservedOutput,
            reservedToolTokens: reservedTool,
            availableInputTokens: available,
            mandatoryKnownEstimatedTokens: mandatory.knownTokens,
            mandatoryUnknownItemCount: mandatory.unknownCount,
            expandedKnownEstimatedTokens: expanded.knownTokens,
            expandedUnknownItemCount: expanded.unknownCount,
            optionalNominationKnownEstimatedTokens: nominations.knownTokens,
            optionalNominationUnknownItemCount: nominations.unknownCount,
            state: state
        )
    }

    private static func tokenFacts(
        _ entries: [ContextSetEntry]
    ) -> (knownTokens: Int, unknownCount: Int) {
        var known = 0
        var unknown = 0
        for entry in entries {
            if let estimate = entry.item.estimatedTokens {
                known += estimate
            } else {
                unknown += 1
            }
        }
        return (known, unknown)
    }
}

public enum ContextManifestDeliveryState: String, Codable, CaseIterable, Sendable {
    case delivered
    case nominationOnly
    case omitted
    case deferred
}

public struct ContextManifestEntry: Equatable, Codable, Sendable {
    public let contextItemID: String
    public let title: String
    public let sourceReference: String
    public let revisionIdentity: String?
    public let contentDigest: String?
    public let authority: AgentContextAuthority
    public let authorityClass: AgentContextAuthorityClass
    public let representation: ContextRepresentationLevel
    public let deliveryState: ContextManifestDeliveryState
    public let inclusionReasons: [ContextInclusionReason]
    public let lineRange: ClosedRange<Int>?
    public let estimatedTokens: Int?
    public let freshness: AgentContextFreshness
    public let truncationReason: String?
    public let dispositionReason: String?
    public let duplicateItemIDs: [String]
    public let duplicateSourceReferences: [String]

    fileprivate init(_ entry: ContextSetEntry) {
        contextItemID = entry.item.id
        title = entry.item.title
        sourceReference = entry.item.sourceReference
        revisionIdentity = entry.item.revisionIdentity
        contentDigest = entry.contentDigest
        authority = entry.item.authority
        authorityClass = entry.item.authority.authorityClass
        representation = entry.representation
        inclusionReasons = entry.inclusionReasons
        lineRange = entry.item.lineRange
        estimatedTokens = entry.item.estimatedTokens
        freshness = entry.item.freshness
        truncationReason = entry.truncationReason
        dispositionReason = entry.dispositionReason
        duplicateItemIDs = entry.duplicateItemIDs
        duplicateSourceReferences = entry.duplicateSourceReferences

        switch entry.disposition {
        case .mandatory, .expanded:
            deliveryState = .delivered
        case .nominated:
            deliveryState = .nominationOnly
        case .omitted:
            deliveryState = .omitted
        case .deferred:
            deliveryState = .deferred
        }
    }
}

/// Inspectable description of what the worker was and was not given.
///
/// This is a context-delivery record. Inclusion never implies that the material
/// is true, authoritative for another decision, fresh, or independently verified.
public struct ContextManifest: Equatable, Codable, Sendable {
    public let contextSetID: String
    public let compilerVersion: String
    public let objective: String
    public let taskIdentity: String?
    public let repositoryIdentity: ContextRepositoryIdentity?
    public let destination: ContextDestination
    public let entries: [ContextManifestEntry]
    public let budget: ContextBudgetSummary
    public let retrieverVersions: [ContextComponentVersion]
    public let unresolvedPrerequisites: [String]

    public var deliveredEntries: [ContextManifestEntry] {
        entries.filter { $0.deliveryState == .delivered }
    }
}

public enum ContextManifestCompiler {
    public static let version = "context-compiler-core-v1"

    public static func compile(
        contextSet: ContextSet,
        destination: ContextDestination,
        budget: ContextBudget
    ) -> ContextManifest {
        let normalized = contextSet.deduplicated()
        return ContextManifest(
            contextSetID: normalized.id,
            compilerVersion: version,
            objective: normalized.objective,
            taskIdentity: normalized.taskIdentity,
            repositoryIdentity: normalized.repositoryIdentity,
            destination: destination,
            entries: normalized.entries.map(ContextManifestEntry.init),
            budget: ContextBudgetEvaluator.assess(
                entries: normalized.entries,
                destination: destination,
                budget: budget
            ),
            retrieverVersions: normalized.retrieverVersions,
            unresolvedPrerequisites: normalized.unresolvedPrerequisites
        )
    }
}
