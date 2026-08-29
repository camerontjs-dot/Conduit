import Foundation

// MARK: - Vocabulary

/// Severity order strongest → weakest (rank uses this).
public enum FocusBoardSeverity: String, CaseIterable, Codable, Sendable, Equatable {
    case urgent
    case actionRequired = "action_required"
    case watch
    case info

    /// Stronger severities rank first. Matches workstation `SEVERITY_RANK`.
    public var rank: Int {
        switch self {
        case .urgent: return 4
        case .actionRequired: return 3
        case .watch: return 2
        case .info: return 1
        }
    }

    public var displayLabel: String {
        switch self {
        case .urgent: return "urgent"
        case .actionRequired: return "action required"
        case .watch: return "watch"
        case .info: return "info"
        }
    }
}

/// Feed source ids (stable for UI chips and asserts).
public enum FocusBoardSource: String, CaseIterable, Codable, Sendable, Equatable {
    case sessionClose = "session-close"
    case evalSchedule = "eval-schedule"
    case projectIndex = "project-index"
    case ingest
    case workingTree = "working-tree"
    case feedsMissing = "feeds-missing"
}

public enum FocusBoardPaths {
    public static let sessionClose = "20_live/workstation/session-close-feed.jsonl"
    public static let scheduleRuns = "20_live/eval-registry/schedule-runs.jsonl"
    public static let projectIndex = "30_projects/index.md"
    public static let ingestStatus = "bin/ingest-status"
    public static let proposalDirectory = "20_live/focus/proposals"
    public static let approvedFocus = "20_live/focus/current.yaml"
    public static let feedsMissingEvidence = "20_live/workstation/"
}

public enum FocusBoardConstants {
    /// ADR-036 weekly staleness threshold (days).
    public static let weeklyStaleDays = 8
    /// ADR-046 total active ceiling (product + eval).
    public static let activeCap = 10
    public static let ingestTimeoutSeconds: TimeInterval = 3

    public static let knownProjectStates: Set<String> = [
        "active", "paused", "planned", "blocked", "suspended", "shipped", "trashed",
    ]

    public static let proposalFilePattern =
        #"^weekly-focus-\d{4}-\d{2}-\d{2}(?:-[A-Za-z0-9._-]+)?\.json$"#
}

// MARK: - Models

public struct FocusBoardItem: Equatable, Identifiable, Sendable {
    public var id: String
    public var severity: FocusBoardSeverity
    public var title: String
    public var detail: String
    public var source: FocusBoardSource
    public var evidencePath: String
    public var asOf: String?
    public var fixture: Bool
    public var evidenceKind: String?
    public var evidenceSessionHash: String?

    public init(
        id: String,
        severity: FocusBoardSeverity,
        title: String,
        detail: String,
        source: FocusBoardSource,
        evidencePath: String,
        asOf: String? = nil,
        fixture: Bool = false,
        evidenceKind: String? = nil,
        evidenceSessionHash: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
        self.source = source
        self.evidencePath = evidencePath
        self.asOf = asOf
        self.fixture = fixture
        self.evidenceKind = evidenceKind
        self.evidenceSessionHash = evidenceSessionHash
    }
}

public struct FocusBoardFeedMeta: Equatable, Identifiable, Sendable {
    public var id: String
    public var path: String
    public var present: Bool
    public var recordCount: Int?
    public var error: String?

    public init(
        id: String,
        path: String,
        present: Bool,
        recordCount: Int? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.path = path
        self.present = present
        self.recordCount = recordCount
        self.error = error
    }
}

public struct FocusBoardProjectProblem: Equatable, Sendable {
    public var code: String
    public var project: String
    public var detail: String

    public init(code: String, project: String, detail: String) {
        self.code = code
        self.project = project
        self.detail = detail
    }
}

public struct FocusBoardProjectRow: Equatable, Sendable {
    public var slug: String
    public var title: String
    public var state: String
    public var nextAction: String
    public var evidence: String

    public init(slug: String, title: String, state: String, nextAction: String, evidence: String) {
        self.slug = slug
        self.title = title
        self.state = state
        self.nextAction = nextAction
        self.evidence = evidence
    }
}

public struct FocusBoardProjectIndexSummary: Equatable, Sendable {
    public var activeCount: Int
    public var activeCap: Int
    public var problems: [FocusBoardProjectProblem]
    public var asOf: String?
    public var projects: [FocusBoardProjectRow]
    public var fixture: Bool

    public init(
        activeCount: Int,
        activeCap: Int = FocusBoardConstants.activeCap,
        problems: [FocusBoardProjectProblem] = [],
        asOf: String? = nil,
        projects: [FocusBoardProjectRow] = [],
        fixture: Bool = false
    ) {
        self.activeCount = activeCount
        self.activeCap = activeCap
        self.problems = problems
        self.asOf = asOf
        self.projects = projects
        self.fixture = fixture
    }
}

public struct FocusBoardProposalSlot: Equatable, Identifiable, Sendable {
    public var id: String { key }
    public var key: String
    public var label: String
    public var status: String
    public var project: String?
    public var action: String
    public var reason: String?
    public var evidenceRefs: [String]

    public init(
        key: String,
        label: String,
        status: String,
        project: String?,
        action: String,
        reason: String? = nil,
        evidenceRefs: [String] = []
    ) {
        self.key = key
        self.label = label
        self.status = status
        self.project = project
        self.action = action
        self.reason = reason
        self.evidenceRefs = evidenceRefs
    }
}

public struct FocusBoardProposal: Equatable, Sendable {
    public var status: String
    public var artifactPath: String?
    public var error: String?
    public var detail: String?
    public var asOf: String?
    public var proposalID: String?
    public var approvalApproved: Bool
    public var approvalStatus: String?
    public var attentionRule: [String]
    public var slots: [FocusBoardProposalSlot]
    public var warnings: [String]
    public var intentStatus: String?

    public init(
        status: String,
        artifactPath: String? = nil,
        error: String? = nil,
        detail: String? = nil,
        asOf: String? = nil,
        proposalID: String? = nil,
        approvalApproved: Bool = false,
        approvalStatus: String? = nil,
        attentionRule: [String] = [],
        slots: [FocusBoardProposalSlot] = [],
        warnings: [String] = [],
        intentStatus: String? = nil
    ) {
        self.status = status
        self.artifactPath = artifactPath
        self.error = error
        self.detail = detail
        self.asOf = asOf
        self.proposalID = proposalID
        self.approvalApproved = approvalApproved
        self.approvalStatus = approvalStatus
        self.attentionRule = attentionRule
        self.slots = slots
        self.warnings = warnings
        self.intentStatus = intentStatus
    }

    public static func unavailable(error: String, detail: String? = nil, artifactPath: String? = nil) -> FocusBoardProposal {
        FocusBoardProposal(
            status: "unavailable",
            artifactPath: artifactPath,
            error: error,
            detail: detail
        )
    }
}

public struct FocusBoardApprovedPrimary: Equatable, Sendable {
    public var project: String?
    public var desiredOutcome: String?
    public var successBoundary: String?
    public var whyNow: String?
    public var confidence: String?
    public var evidenceRefs: [String]

    public init(
        project: String? = nil,
        desiredOutcome: String? = nil,
        successBoundary: String? = nil,
        whyNow: String? = nil,
        confidence: String? = nil,
        evidenceRefs: [String] = []
    ) {
        self.project = project
        self.desiredOutcome = desiredOutcome
        self.successBoundary = successBoundary
        self.whyNow = whyNow
        self.confidence = confidence
        self.evidenceRefs = evidenceRefs
    }
}

public struct FocusBoardApprovedSlot: Equatable, Sendable {
    public var project: String?
    public var role: String?
    public var note: String?

    public init(project: String? = nil, role: String? = nil, note: String? = nil) {
        self.project = project
        self.role = role
        self.note = note
    }
}

public struct FocusBoardApprovedFocus: Equatable, Sendable {
    public var status: String
    public var sourcePath: String
    public var decisionID: String?
    public var revision: String?
    public var asOf: String?
    public var reviewBy: String?
    public var reviewStatus: String
    public var selectedBy: String?
    public var primary: FocusBoardApprovedPrimary
    public var supportingSlots: [FocusBoardApprovedSlot]
    public var candidateSnapshot: String?
    public var errors: [String]
    public var warnings: [String]

    public init(
        status: String,
        sourcePath: String = FocusBoardPaths.approvedFocus,
        decisionID: String? = nil,
        revision: String? = nil,
        asOf: String? = nil,
        reviewBy: String? = nil,
        reviewStatus: String = "unknown",
        selectedBy: String? = nil,
        primary: FocusBoardApprovedPrimary = FocusBoardApprovedPrimary(),
        supportingSlots: [FocusBoardApprovedSlot] = [],
        candidateSnapshot: String? = nil,
        errors: [String] = [],
        warnings: [String] = []
    ) {
        self.status = status
        self.sourcePath = sourcePath
        self.decisionID = decisionID
        self.revision = revision
        self.asOf = asOf
        self.reviewBy = reviewBy
        self.reviewStatus = reviewStatus
        self.selectedBy = selectedBy
        self.primary = primary
        self.supportingSlots = supportingSlots
        self.candidateSnapshot = candidateSnapshot
        self.errors = errors
        self.warnings = warnings
    }

    public static func unavailable(error: String) -> FocusBoardApprovedFocus {
        FocusBoardApprovedFocus(
            status: "unavailable",
            errors: [error]
        )
    }
}

/// Ranked Focus Board projection. Overlay fields (proposal / approved / feeds)
/// are attached by the loader; the pure builder fills items + honesty flags.
public struct FocusBoardSnapshot: Equatable, Sendable {
    public var items: [FocusBoardItem]
    public var insufficient: Bool
    public var feedNotes: [String]
    public var asOf: String?
    public var feeds: [FocusBoardFeedMeta]
    public var parseErrors: [String]
    public var weeklyFocusProposal: FocusBoardProposal?
    public var approvedFocus: FocusBoardApprovedFocus?
    public var fixture: Bool

    public init(
        items: [FocusBoardItem],
        insufficient: Bool,
        feedNotes: [String] = [],
        asOf: String? = nil,
        feeds: [FocusBoardFeedMeta] = [],
        parseErrors: [String] = [],
        weeklyFocusProposal: FocusBoardProposal? = nil,
        approvedFocus: FocusBoardApprovedFocus? = nil,
        fixture: Bool = false
    ) {
        self.items = items
        self.insufficient = insufficient
        self.feedNotes = feedNotes
        self.asOf = asOf
        self.feeds = feeds
        self.parseErrors = parseErrors
        self.weeklyFocusProposal = weeklyFocusProposal
        self.approvedFocus = approvedFocus
        self.fixture = fixture
    }

    public var isFeedsMissing: Bool {
        insufficient || (items.count == 1 && items.first?.source == .feedsMissing)
    }
}

public enum FocusBoardLoadError: Error, Equatable, Sendable {
    case rootMissing
    case unexpected(String)

    public var displayMessage: String {
        switch self {
        case .rootMissing:
            return "MainFrame root is not set. Choose a root in Settings before loading Attention."
        case .unexpected(let detail):
            return "Focus Board load failed: \(detail)"
        }
    }
}

// MARK: - JSON record (untyped feed objects)

/// Loose JSON object used by feed projectors. Matches the workstation's
/// untyped record contract without adding a Codable schema for every feed.
public struct FocusBoardJSON: Equatable, Sendable {
    public var fields: [String: FocusBoardJSONValue]

    public init(_ fields: [String: FocusBoardJSONValue] = [:]) {
        self.fields = fields
    }

    public subscript(key: String) -> FocusBoardJSONValue? {
        get { fields[key] }
        set { fields[key] = newValue }
    }

    public var fixture: Bool { self["fixture"]?.boolValue == true }

    public static func object(_ pairs: [String: FocusBoardJSONValue]) -> FocusBoardJSON {
        FocusBoardJSON(pairs)
    }
}

public enum FocusBoardJSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([FocusBoardJSONValue])
    case object(FocusBoardJSON)

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .number(let n) where n.rounded() == n: return String(Int(n))
        case .number(let n): return String(n)
        case .bool(let v): return v ? "true" : "false"
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var intValue: Int? {
        guard let d = doubleValue, d.rounded() == d else { return nil }
        return Int(d)
    }

    public var arrayValue: [FocusBoardJSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: FocusBoardJSON? {
        if case .object(let o) = self { return o }
        return nil
    }

    public static func fromJSON(_ any: Any?) -> FocusBoardJSONValue {
        guard let any, !(any is NSNull) else { return .null }
        if let b = any as? Bool { return .bool(b) }
        if let n = any as? NSNumber {
            // NSNumber can box Bool; distinguish via objC type.
            let type = String(cString: n.objCType)
            if type == "c" || type == "B" { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = any as? String { return .string(s) }
        if let arr = any as? [Any] {
            return .array(arr.map { fromJSON($0) })
        }
        if let dict = any as? [String: Any] {
            var fields: [String: FocusBoardJSONValue] = [:]
            for (k, v) in dict { fields[k] = fromJSON(v) }
            return .object(FocusBoardJSON(fields))
        }
        return .null
    }
}

public struct FocusBoardInputs: Equatable, Sendable {
    public var sessionCloseRecords: [FocusBoardJSON]?
    public var scheduleRuns: [FocusBoardJSON]?
    public var projectIndex: FocusBoardProjectIndexSummary?
    public var ingestStatus: FocusBoardJSON?
    public var nowMs: Double?
    public var feedsMissing: Bool
    public var fixture: Bool

    public init(
        sessionCloseRecords: [FocusBoardJSON]? = nil,
        scheduleRuns: [FocusBoardJSON]? = nil,
        projectIndex: FocusBoardProjectIndexSummary? = nil,
        ingestStatus: FocusBoardJSON? = nil,
        nowMs: Double? = nil,
        feedsMissing: Bool = false,
        fixture: Bool = false
    ) {
        self.sessionCloseRecords = sessionCloseRecords
        self.scheduleRuns = scheduleRuns
        self.projectIndex = projectIndex
        self.ingestStatus = ingestStatus
        self.nowMs = nowMs
        self.feedsMissing = feedsMissing
        self.fixture = fixture
    }
}

// MARK: - Pure projectors

public enum FocusBoard {
    public static func parseTimeMs(_ value: String?) -> Double? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let ms = parseISODate(raw) {
            return ms
        }
        return nil
    }

    public static func daysBetween(earlierMs: Double, laterMs: Double) -> Double {
        (laterMs - earlierMs) / (1000 * 60 * 60 * 24)
    }

    public static func rankFocusItems(_ items: [FocusBoardItem]) -> [FocusBoardItem] {
        items.sorted { a, b in
            if a.severity.rank != b.severity.rank {
                return a.severity.rank > b.severity.rank
            }
            let ta = parseTimeMs(a.asOf) ?? Double.infinity
            let tb = parseTimeMs(b.asOf) ?? Double.infinity
            if ta != tb { return ta < tb }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
    }

    public static func dedupeFocusItems(_ items: [FocusBoardItem]) -> [FocusBoardItem] {
        var map: [String: FocusBoardItem] = [:]
        var order: [String] = []
        for item in items {
            if let prev = map[item.id] {
                if item.severity.rank > prev.severity.rank {
                    map[item.id] = item
                }
            } else {
                map[item.id] = item
                order.append(item.id)
            }
        }
        return order.compactMap { map[$0] }
    }

    public static func parseJsonl(_ text: String) -> [FocusBoardJSON] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var out: [FocusBoardJSON] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            guard let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any]
            else { continue }
            if case .object(let rec) = FocusBoardJSONValue.fromJSON(dict) {
                out.append(rec)
            }
        }
        return out
    }

    public static func itemsFromCloseCheck(_ record: FocusBoardJSON) -> [FocusBoardItem] {
        guard record["kind"]?.stringValue == "close-check" else { return [] }
        let fixture = record.fixture
        let asOf = record["as_of"]?.stringValue ?? record["logged_at"]?.stringValue
        let evidencePath = FocusBoardPaths.sessionClose
        var out: [FocusBoardItem] = []
        let sessionBit = sessionPrefix(record["session_hash"]?.stringValue)

        if record["ok"]?.boolValue == false {
            let reason = record["reason"]?.stringValue
            let detail: String
            if reason == "other" {
                detail = "Recorded close-check ok=false — review pending actions and warnings."
            } else {
                detail = "Recorded close-check failed (reason: \(reason ?? "unrecorded"))."
            }
            out.append(
                item(
                    id: "close-check-failed-\(sessionBit)-\(asOf ?? "na")",
                    severity: .urgent,
                    title: "Session close check failed",
                    detail: detail,
                    source: .sessionClose,
                    evidencePath: evidencePath,
                    asOf: asOf,
                    fixture: fixture,
                    evidenceKind: "close-check",
                    evidenceSessionHash: record["session_hash"]?.stringValue
                )
            )
        }

        let warnings = record["warnings"]?.arrayValue ?? []
        for warning in warnings {
            let name = warning.stringValue ?? String(describing: warning)
            if name == "eval-schedule" {
                out.append(
                    item(
                        id: "close-warn-eval-\(sessionBit)",
                        severity: .urgent,
                        title: "Eval schedule needs attention",
                        detail: "Session-close recorded an eval-schedule warning (stale or failed weekly).",
                        source: .evalSchedule,
                        evidencePath: evidencePath,
                        asOf: asOf,
                        fixture: fixture
                    )
                )
            } else if name == "working-tree" {
                out.append(
                    item(
                        id: "close-warn-wt-\(sessionBit)",
                        severity: .watch,
                        title: "Working tree dirty at session end",
                        detail: "Session-close recorded uncommitted changes (working-tree warning).",
                        source: .workingTree,
                        evidencePath: evidencePath,
                        asOf: asOf,
                        fixture: fixture
                    )
                )
            } else {
                out.append(
                    item(
                        id: "close-warn-\(name)-\(sessionBit)",
                        severity: .watch,
                        title: "Session warning: \(name)",
                        detail: "Close-check recorded warning \"\(name)\".",
                        source: .sessionClose,
                        evidencePath: evidencePath,
                        asOf: asOf,
                        fixture: fixture
                    )
                )
            }
        }

        let actions = record["actions"]?.arrayValue ?? []
        for actionValue in actions {
            guard let action = actionValue.objectValue else { continue }
            guard action["needed"]?.boolValue == true, action["ran"]?.boolValue != true else {
                continue
            }
            let name = action["name"]?.stringValue ?? "action"
            let kind = action["kind"]?.stringValue
            if kind == "manual" {
                out.append(
                    item(
                        id: "close-manual-\(name)-\(sessionBit)",
                        severity: .actionRequired,
                        title: "Manual close action: \(name)",
                        detail: action["reason"]?.stringValue
                            ?? "Recorded manual session-close action still needed.",
                        source: .sessionClose,
                        evidencePath: evidencePath,
                        asOf: asOf,
                        fixture: fixture
                    )
                )
            } else if kind == "auto" {
                out.append(
                    item(
                        id: "close-auto-\(name)-\(sessionBit)",
                        severity: .watch,
                        title: "Pending auto close action: \(name)",
                        detail: action["reason"]?.stringValue
                            ?? "Recorded auto session-close action not yet run.",
                        source: .sessionClose,
                        evidencePath: evidencePath,
                        asOf: asOf,
                        fixture: fixture
                    )
                )
            }
        }

        let pendingAuto = record["pending_auto"]?.arrayValue ?? []
        let hasAutoAction = actions.contains { actionValue in
            guard let action = actionValue.objectValue else { return false }
            return action["kind"]?.stringValue == "auto"
                && action["needed"]?.boolValue == true
                && action["ran"]?.boolValue != true
        }
        if !pendingAuto.isEmpty && !hasAutoAction {
            let names = pendingAuto.compactMap(\.stringValue).joined(separator: ", ")
            out.append(
                item(
                    id: "close-pending-auto-\(sessionBit)",
                    severity: .watch,
                    title: "\(pendingAuto.count) pending auto close action(s)",
                    detail: "pending_auto: \(names)",
                    source: .sessionClose,
                    evidencePath: evidencePath,
                    asOf: asOf,
                    fixture: fixture
                )
            )
        }

        return out
    }

    public static func itemsFromCheckpoint(_ record: FocusBoardJSON) -> [FocusBoardItem] {
        guard record["kind"]?.stringValue == "checkpoint" else { return [] }
        let fixture = record.fixture
        let asOf = record["as_of"]?.stringValue ?? record["logged_at"]?.stringValue
        let evidencePath = FocusBoardPaths.sessionClose
        var out: [FocusBoardItem] = []
        let sessionBit = sessionPrefix(record["session_hash"]?.stringValue)

        if record["drift"]?.boolValue == true {
            out.append(
                item(
                    id: "checkpoint-drift-\(sessionBit)",
                    severity: .actionRequired,
                    title: "STATE.md active project drifts from derived activity",
                    detail: "Checkpoint recorded drift between declared STATE.md active project and derived activity.",
                    source: .sessionClose,
                    evidencePath: evidencePath,
                    asOf: asOf,
                    fixture: fixture
                )
            )
        }

        if let we = record["weekly_eval"]?.objectValue {
            if we["stale"]?.boolValue == true || we["ok"]?.boolValue == false {
                let detail: String
                if let reason = we["reason"]?.stringValue {
                    detail = reason
                } else if we["stale"]?.boolValue == true {
                    detail = "Checkpoint weekly_eval marked stale."
                } else {
                    detail = "Checkpoint weekly_eval not ok."
                }
                out.append(
                    item(
                        id: "checkpoint-weekly-\(sessionBit)",
                        severity: .urgent,
                        title: "Weekly eval unhealthy at checkpoint",
                        detail: detail,
                        source: .evalSchedule,
                        evidencePath: evidencePath,
                        asOf: asOf,
                        fixture: fixture
                    )
                )
            }
        }

        if let dirty = record["dirty_files"]?.doubleValue, dirty > 0 {
            let count = record["dirty_files"]?.intValue ?? Int(dirty)
            out.append(
                item(
                    id: "checkpoint-dirty-\(sessionBit)",
                    severity: .watch,
                    title: "\(count) dirty file(s) at checkpoint",
                    detail: "Checkpoint recorded a non-clean working tree.",
                    source: .workingTree,
                    evidencePath: evidencePath,
                    asOf: asOf,
                    fixture: fixture
                )
            )
        }

        if out.isEmpty {
            out.append(
                item(
                    id: "checkpoint-ok-\(sessionBit)",
                    severity: .info,
                    title: "Checkpoint recorded",
                    detail: "PreCompact/session checkpoint as_of \(asOf ?? "unknown") (no drift or weekly flags).",
                    source: .sessionClose,
                    evidencePath: evidencePath,
                    asOf: asOf,
                    fixture: fixture
                )
            )
        }
        return out
    }

    public static func itemsFromScheduleRuns(
        _ runs: [FocusBoardJSON],
        nowMs: Double?,
        staleDays: Int = FocusBoardConstants.weeklyStaleDays
    ) -> [FocusBoardItem] {
        guard !runs.isEmpty else { return [] }
        let fixture = runs.contains { $0.fixture }
        let evidencePath = FocusBoardPaths.scheduleRuns
        let weekly = runs
            .filter { $0["cadence"]?.stringValue == "weekly" }
            .sorted { a, b in
                let ta = parseTimeMs(a["finished_at"]?.stringValue ?? a["started_at"]?.stringValue) ?? 0
                let tb = parseTimeMs(b["finished_at"]?.stringValue ?? b["started_at"]?.stringValue) ?? 0
                return ta > tb
            }
        if weekly.isEmpty {
            return [
                item(
                    id: "eval-no-weekly",
                    severity: .urgent,
                    title: "No weekly eval runs recorded",
                    detail: "schedule-runs.jsonl has no cadence=weekly entries.",
                    source: .evalSchedule,
                    evidencePath: evidencePath,
                    asOf: nil,
                    fixture: fixture
                ),
            ]
        }

        let last = weekly[0]
        let asOf = last["finished_at"]?.stringValue ?? last["started_at"]?.stringValue
        let finishedMs = parseTimeMs(asOf)
        let runID = last["run_id"]?.stringValue ?? "unknown"
        let lastFixture = fixture || last.fixture
        var out: [FocusBoardItem] = []

        if last["all_passed"]?.boolValue == false {
            out.append(
                item(
                    id: "eval-failed-\(runID)",
                    severity: .urgent,
                    title: "Last weekly eval failed",
                    detail: "Run \(runID) recorded all_passed=false.",
                    source: .evalSchedule,
                    evidencePath: evidencePath,
                    asOf: asOf,
                    fixture: lastFixture
                )
            )
        }

        if let finishedMs, let nowMs, nowMs.isFinite {
            let age = daysBetween(earlierMs: finishedMs, laterMs: nowMs)
            if age > Double(staleDays) {
                out.append(
                    item(
                        id: "eval-stale-\(runID)",
                        severity: .urgent,
                        title: "Weekly eval stale (\(formatOneDecimal(age))d)",
                        detail: "Last weekly finished more than \(staleDays)d ago (ADR-036 threshold).",
                        source: .evalSchedule,
                        evidencePath: evidencePath,
                        asOf: asOf,
                        fixture: lastFixture
                    )
                )
            } else if last["all_passed"]?.boolValue == true {
                out.append(
                    item(
                        id: "eval-ok-\(runID)",
                        severity: .info,
                        title: "Weekly eval recent and green",
                        detail: "Run \(runID) all_passed=true (\(formatOneDecimal(age))d ago).",
                        source: .evalSchedule,
                        evidencePath: evidencePath,
                        asOf: asOf,
                        fixture: lastFixture
                    )
                )
            }
        }
        return out
    }

    public static func itemsFromProjectIndex(_ summary: FocusBoardProjectIndexSummary?) -> [FocusBoardItem] {
        guard let summary else { return [] }
        let evidencePath = FocusBoardPaths.projectIndex
        var out: [FocusBoardItem] = []

        if summary.activeCount > summary.activeCap {
            out.append(
                item(
                    id: "project-wip-breach",
                    severity: .urgent,
                    title: "Total active cap breach (\(summary.activeCount) active > \(summary.activeCap))",
                    detail: "More projects are marked active than the ADR-046 total ceiling allows (product seats 5 + eval seats share a total of 10).",
                    source: .projectIndex,
                    evidencePath: evidencePath,
                    asOf: summary.asOf,
                    fixture: summary.fixture
                )
            )
        }

        for problem in summary.problems {
            let severity: FocusBoardSeverity =
                (problem.code == "missing_frontmatter"
                    || problem.code == "unknown_state"
                    || problem.code == "active_without_evidence")
                    ? .actionRequired
                    : .watch
            out.append(
                item(
                    id: "project-\(problem.code)-\(problem.project)",
                    severity: severity,
                    title: "Project index: \(problem.project) (\(problem.code))",
                    detail: problem.detail,
                    source: .projectIndex,
                    evidencePath: evidencePath,
                    asOf: summary.asOf,
                    fixture: summary.fixture
                )
            )
        }
        return out
    }

    public static func itemsFromIngestStatus(_ status: FocusBoardJSON?) -> [FocusBoardItem] {
        guard let status else { return [] }
        let fixture = status.fixture
        let evidencePath = FocusBoardPaths.ingestStatus
        let asOf = status["as_of"]?.stringValue
        var out: [FocusBoardItem] = []
        let lanes = status["lanes"]?.arrayValue ?? []

        for laneValue in lanes {
            guard let lane = laneValue.objectValue else { continue }
            let name = lane["name"]?.stringValue ?? "lane"
            let files = lane["files"]?.intValue ?? 0
            let oldest = lane["oldest_file_age_days"]?.doubleValue
            if files > 0, let oldest, oldest >= 7 {
                out.append(
                    item(
                        id: "ingest-aging-\(name)",
                        severity: oldest >= 30 ? .actionRequired : .watch,
                        title: "\(name) has \(files) file(s) aging",
                        detail: "Oldest file age ~\(oldest.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(oldest)) : String(oldest))d in lane \(name).",
                        source: .ingest,
                        evidencePath: evidencePath,
                        asOf: asOf,
                        fixture: fixture
                    )
                )
            } else if files > 0 {
                let ageLabel: String
                if let oldest {
                    ageLabel = oldest.truncatingRemainder(dividingBy: 1) == 0
                        ? String(Int(oldest))
                        : String(oldest)
                } else {
                    ageLabel = "unknown"
                }
                out.append(
                    item(
                        id: "ingest-pending-\(name)",
                        severity: .info,
                        title: "\(name): \(files) file(s) pending",
                        detail: "Lane \(name) has files waiting (oldest age \(ageLabel)d).",
                        source: .ingest,
                        evidencePath: evidencePath,
                        asOf: asOf,
                        fixture: fixture
                    )
                )
            }
        }
        return out
    }

    public static func parseProjectIndexMarkdown(
        _ markdown: String,
        activeCap: Int = FocusBoardConstants.activeCap,
        asOf: String? = nil,
        fixture: Bool = false
    ) -> FocusBoardProjectIndexSummary {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return FocusBoardProjectIndexSummary(
                activeCount: 0,
                activeCap: activeCap,
                problems: [
                    FocusBoardProjectProblem(
                        code: "index_missing",
                        project: "30_projects",
                        detail: "index.md empty or unreadable"
                    ),
                ],
                asOf: asOf,
                projects: [],
                fixture: fixture
            )
        }

        let pattern = #"^\|\s*\[([^\]]+)\]\(([^)]+)\)\s*\|\s*([^|]+?)\s*\|\s*([^|]*)\|\s*([^|]*)\|\s*([^|]*)\|\s*([^|]*)\|\s*$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        var problems: [FocusBoardProjectProblem] = []
        var projects: [FocusBoardProjectRow] = []
        var activeCount = 0

        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line)
            guard raw.hasPrefix("|"), let regex else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, range: range), match.numberOfRanges == 8 else {
                continue
            }
            func group(_ i: Int) -> String {
                guard let r = Range(match.range(at: i), in: raw) else { return "" }
                return String(raw[r]).trimmingCharacters(in: .whitespaces)
            }
            let title = group(1)
            let link = group(2)
            let state = group(3).lowercased()
            let nextAction = group(5)
            let evidence = group(7)
            let slug = link.replacingOccurrences(
                of: "/README.md",
                with: "",
                options: .caseInsensitive
            ).split(separator: "/").first.map(String.init) ?? title

            projects.append(
                FocusBoardProjectRow(
                    slug: slug,
                    title: title,
                    state: state,
                    nextAction: nextAction,
                    evidence: evidence
                )
            )

            if !FocusBoardConstants.knownProjectStates.contains(state) {
                problems.append(
                    FocusBoardProjectProblem(
                        code: "unknown_state",
                        project: slug,
                        detail: "Unknown project_state \"\(state)\" in index row"
                    )
                )
            }

            if state == "active" {
                activeCount += 1
                if nextAction.isEmpty || nextAction == "-" || nextAction.lowercased() == "none" {
                    problems.append(
                        FocusBoardProjectProblem(
                            code: "active_missing_next_action",
                            project: slug,
                            detail: "Active project has empty or placeholder next_action in index"
                        )
                    )
                }
                if evidence.isEmpty || evidence == "-" {
                    problems.append(
                        FocusBoardProjectProblem(
                            code: "active_without_evidence",
                            project: slug,
                            detail: "Active project has no Evidence date in 30_projects/index.md"
                        )
                    )
                }
            }
        }

        return FocusBoardProjectIndexSummary(
            activeCount: activeCount,
            activeCap: activeCap,
            problems: problems,
            asOf: asOf,
            projects: projects,
            fixture: fixture
        )
    }

    public static func buildFocusBoard(_ inputs: FocusBoardInputs) -> FocusBoardSnapshot {
        let fixture = inputs.fixture
            || (inputs.sessionCloseRecords?.contains { $0.fixture } ?? false)
            || (inputs.scheduleRuns?.contains { $0.fixture } ?? false)
            || (inputs.projectIndex?.fixture ?? false)
            || (inputs.ingestStatus?.fixture ?? false)

        var feedNotes: [String] = []
        let sessionRecords = inputs.sessionCloseRecords
        let scheduleRuns = inputs.scheduleRuns
        let hasProject = inputs.projectIndex != nil
        let hasIngest = inputs.ingestStatus != nil
        let nowMs = inputs.nowMs ?? (Date().timeIntervalSince1970 * 1000)

        let sessionsEmpty = sessionRecords == nil || sessionRecords?.isEmpty == true
        let scheduleEmpty = scheduleRuns == nil || scheduleRuns?.isEmpty == true
        if inputs.feedsMissing || (sessionsEmpty && scheduleEmpty && !hasProject && !hasIngest) {
            feedNotes.append("no session-close, schedule, project-index, or ingest inputs")
            let emptyItem = item(
                id: "feeds-missing",
                severity: .info,
                title: "No truth feeds recorded",
                detail: "Focus Board has no session-close, eval-schedule, project-index, or ingest inputs to project. This is not an all-clear.",
                source: .feedsMissing,
                evidencePath: FocusBoardPaths.feedsMissingEvidence,
                asOf: nil,
                fixture: fixture
            )
            return FocusBoardSnapshot(
                items: [emptyItem],
                insufficient: true,
                feedNotes: feedNotes,
                fixture: fixture
            )
        }

        if let sessionRecords {
            feedNotes.append("session-close records: \(sessionRecords.count)")
        }
        if let scheduleRuns {
            feedNotes.append("schedule runs: \(scheduleRuns.count)")
        }
        if hasProject { feedNotes.append("project-index: present") }
        if hasIngest { feedNotes.append("ingest-status: present") }

        var items: [FocusBoardItem] = []
        if let sessionRecords, !sessionRecords.isEmpty {
            let closes = sessionRecords.filter { $0["kind"]?.stringValue == "close-check" }
            let checks = sessionRecords.filter { $0["kind"]?.stringValue == "checkpoint" }
            let latestClose = closes.max { a, b in
                recordTime(a) < recordTime(b)
            }
            let latestCheck = checks.max { a, b in
                recordTime(a) < recordTime(b)
            }
            if let latestClose {
                items.append(contentsOf: itemsFromCloseCheck(latestClose))
            }
            if let latestCheck {
                items.append(contentsOf: itemsFromCheckpoint(latestCheck))
            }
        }
        if let scheduleRuns {
            items.append(contentsOf: itemsFromScheduleRuns(scheduleRuns, nowMs: nowMs))
        }
        if hasProject {
            items.append(contentsOf: itemsFromProjectIndex(inputs.projectIndex))
        }
        if hasIngest {
            items.append(contentsOf: itemsFromIngestStatus(inputs.ingestStatus))
        }

        items = rankFocusItems(dedupeFocusItems(items))
        return FocusBoardSnapshot(
            items: items,
            insufficient: false,
            feedNotes: feedNotes,
            fixture: fixture
        )
    }

    // MARK: - Proposal / approved-focus display parsers

    public static func parseApprovedFocus(_ text: String, nowMs: Double = Date().timeIntervalSince1970 * 1000) -> FocusBoardApprovedFocus {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let primaryLines = primaryBlock(lines)
        var errors: [String] = []
        let decisionID = scalarAt(lines, key: "decision_id")
        let revision = scalarAt(lines, key: "revision")
        let asOf = scalarAt(lines, key: "as_of")
        let reviewBy = scalarAt(lines, key: "review_by")
        let primaryProject = scalarAt(primaryLines, key: "project", indent: 2)

        if decisionID == nil { errors.append("decision_id missing") }
        if revision == nil { errors.append("revision missing") }
        if asOf == nil { errors.append("as_of missing") }
        if reviewBy == nil { errors.append("review_by missing") }
        if primaryProject == nil { errors.append("primary.project missing") }

        var reviewStatus = "unknown"
        let reviewMs = reviewBy.flatMap { parseTimeMs($0) }
        let asOfMs = asOf.flatMap { parseTimeMs($0) } ?? nowMs
        if let reviewMs {
            if asOf.flatMap({ parseTimeMs($0) }) != nil || asOf == nil {
                reviewStatus = asOfMs > reviewMs ? "past_due" : "current"
            }
        } else if reviewBy != nil {
            reviewStatus = "unparseable"
        }

        return FocusBoardApprovedFocus(
            status: errors.isEmpty ? "available" : "invalid",
            sourcePath: FocusBoardPaths.approvedFocus,
            decisionID: decisionID,
            revision: revision,
            asOf: asOf,
            reviewBy: reviewBy,
            reviewStatus: reviewStatus,
            selectedBy: scalarAt(lines, key: "selected_by"),
            primary: FocusBoardApprovedPrimary(
                project: primaryProject,
                desiredOutcome: scalarAt(primaryLines, key: "desired_outcome", indent: 2),
                successBoundary: scalarAt(primaryLines, key: "success_boundary", indent: 2),
                whyNow: scalarAt(primaryLines, key: "why_now", indent: 2),
                confidence: scalarAt(primaryLines, key: "confidence", indent: 2),
                evidenceRefs: parseEvidenceRefs(primaryLines)
            ),
            supportingSlots: parseSupportingSlots(lines),
            candidateSnapshot: scalarAt(lines, key: "candidate_snapshot"),
            errors: errors,
            warnings: reviewStatus == "past_due"
                ? ["focus review_by \(reviewBy ?? "") is past due"]
                : []
        )
    }

    public static func parseFocusProposal(
        data: Data,
        artifactPath: String
    ) -> FocusBoardProposal {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else {
            return .unavailable(
                error: "weekly focus proposal artifact could not be parsed",
                detail: "invalid JSON",
                artifactPath: artifactPath
            )
        }
        return parseFocusProposal(dict, artifactPath: artifactPath)
    }

    public static func parseFocusProposal(
        _ dict: [String: Any],
        artifactPath: String
    ) -> FocusBoardProposal {
        let artifactType = dict["artifact_type"] as? String
        let schema = (dict["schema_version"] as? NSNumber)?.intValue
            ?? dict["schema_version"] as? Int
        guard artifactType == "weekly_focus_proposal", schema == 1 else {
            return .unavailable(
                error: "weekly focus proposal artifact has an unsupported schema",
                detail: "expected weekly_focus_proposal schema_version 1",
                artifactPath: artifactPath
            )
        }

        let approval = dict["approval"] as? [String: Any]
        let approved = approval?["approved"] as? Bool ?? false
        let approvalStatus = approval?["status"] as? String
        let proposed = dict["proposed"] as? [String: Any] ?? [:]
        let intent = dict["intent_context"] as? [String: Any]
        let warnings = (dict["warnings"] as? [Any] ?? []).compactMap { $0 as? String }
        let attention = (dict["attention_rule"] as? [Any] ?? []).compactMap { $0 as? String }

        let slotSpecs: [(key: String, label: String)] = [
            ("website_outcome", "Website outcome"),
            ("buyer_facing_action", "Buyer-facing action"),
            ("supporting_proof", "Supporting proof"),
            ("exploration", "Exploration"),
            ("maintenance", "Bounded maintenance"),
            ("selective_backup", "Selective backup"),
        ]
        let slots: [FocusBoardProposalSlot] = slotSpecs.compactMap { spec in
            guard let slot = proposed[spec.key] as? [String: Any] else { return nil }
            let refs = (slot["evidence_refs"] as? [Any] ?? []).compactMap { $0 as? String }
            let action = (slot["action"] as? String)
                ?? (slot["next_action"] as? String)
                ?? (slot["reason"] as? String)
                ?? "No action recorded."
            return FocusBoardProposalSlot(
                key: spec.key,
                label: spec.label,
                status: (slot["status"] as? String) ?? "unassigned",
                project: slot["project"] as? String,
                action: action,
                reason: slot["reason"] as? String,
                evidenceRefs: refs
            )
        }

        return FocusBoardProposal(
            status: "available",
            artifactPath: artifactPath,
            asOf: dict["as_of"] as? String,
            proposalID: dict["proposal_id"] as? String,
            approvalApproved: approved,
            approvalStatus: approvalStatus,
            attentionRule: attention,
            slots: slots,
            warnings: warnings,
            intentStatus: intent?["status"] as? String
        )
    }

    public static func isProposalFileName(_ name: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: FocusBoardConstants.proposalFilePattern) else {
            return false
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return regex.firstMatch(in: name, range: range) != nil
    }

    /// Paths that are revealable under the MainFrame root. Bins, absolute
    /// paths, and `..` stay labels only.
    public static func isViewableEvidencePath(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return false }
        if p.hasPrefix("bin/") || p == FocusBoardPaths.ingestStatus { return false }
        if p.contains("..") || p.hasPrefix("/") { return false }
        return p.hasPrefix("20_live/")
            || p.hasPrefix("30_projects/")
            || p.hasPrefix("10_knowledge/")
            || p.hasPrefix("00_inbox/")
            || p.hasPrefix("01_ingest/")
            || p.hasSuffix(".md")
            || p.hasSuffix(".jsonl")
            || p.hasSuffix(".json")
    }

    /// Resolve a relative evidence path under `root` when it is viewable.
    public static func resolvedEvidenceURL(path: String, mainframeRoot: URL) -> URL? {
        guard isViewableEvidencePath(path) else { return nil }
        let url = mainframeRoot.appendingPathComponent(path)
        let rootPath = mainframeRoot.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate == rootPath || candidate.hasPrefix(rootPath + "/") else {
            return nil
        }
        return url
    }

    public static func decodeJSONObject(_ data: Data) -> FocusBoardJSON? {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              case .object(let rec) = FocusBoardJSONValue.fromJSON(dict)
        else { return nil }
        return rec
    }

    public static func jsonFromAny(_ any: Any) -> FocusBoardJSON? {
        if case .object(let rec) = FocusBoardJSONValue.fromJSON(any) {
            return rec
        }
        return nil
    }

    // MARK: - Internals

    private static func item(
        id: String,
        severity: FocusBoardSeverity,
        title: String,
        detail: String,
        source: FocusBoardSource,
        evidencePath: String,
        asOf: String?,
        fixture: Bool,
        evidenceKind: String? = nil,
        evidenceSessionHash: String? = nil
    ) -> FocusBoardItem {
        FocusBoardItem(
            id: id,
            severity: severity,
            title: title,
            detail: detail,
            source: source,
            evidencePath: evidencePath,
            asOf: asOf,
            fixture: fixture,
            evidenceKind: evidenceKind,
            evidenceSessionHash: evidenceSessionHash
        )
    }

    private static func sessionPrefix(_ hash: String?) -> String {
        guard let hash, !hash.isEmpty else { return "unknown" }
        return String(hash.prefix(8))
    }

    private static func recordTime(_ record: FocusBoardJSON) -> Double {
        parseTimeMs(record["logged_at"]?.stringValue ?? record["as_of"]?.stringValue) ?? 0
    }

    private static func formatOneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private static func parseISODate(_ raw: String) -> Double? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) {
            return date.timeIntervalSince1970 * 1000
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) {
            return date.timeIntervalSince1970 * 1000
        }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        if let date = day.date(from: raw) {
            return date.timeIntervalSince1970 * 1000
        }
        // JS Date.parse fallback for offsets without colon, space separators, etc.
        let fallbacks = [
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXX",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss",
        ]
        let generic = DateFormatter()
        generic.locale = Locale(identifier: "en_US_POSIX")
        for format in fallbacks {
            generic.dateFormat = format
            generic.timeZone = TimeZone(secondsFromGMT: 0)
            if let date = generic.date(from: raw) {
                return date.timeIntervalSince1970 * 1000
            }
        }
        return nil
    }

    private static func unquote(_ value: String?) -> String? {
        guard var raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        if raw.count >= 2,
           (raw.hasPrefix("\"") && raw.hasSuffix("\""))
            || (raw.hasPrefix("'") && raw.hasSuffix("'")) {
            raw = String(raw.dropFirst().dropLast())
        }
        if raw == "null" || raw == "~" || raw.isEmpty { return nil }
        return raw
    }

    private static func indentOf(_ line: String) -> Int {
        line.count - line.trimmingCharacters(in: .whitespaces).count
    }

    private static func scalarAt(_ lines: [String], key: String, indent: Int = 0) -> String? {
        let prefix = String(repeating: " ", count: indent) + "\(key):"
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return unquote(String(line.dropFirst(prefix.count)))
    }

    private static func primaryBlock(_ lines: [String]) -> [String] {
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "primary:" }) else {
            return []
        }
        var block: [String] = []
        for i in (start + 1)..<lines.count {
            let line = lines[i]
            if !line.trimmingCharacters(in: .whitespaces).isEmpty && indentOf(line) == 0 {
                break
            }
            block.append(line)
        }
        return block
    }

    private static func parseEvidenceRefs(_ block: [String]) -> [String] {
        var refs: [String] = []
        var inList = false
        for line in block {
            if line.trimmingCharacters(in: .whitespaces) == "evidence_refs:" {
                inList = true
                continue
            }
            if inList, line.range(of: #"^\s{4}-\s+"#, options: .regularExpression) != nil {
                let stripped = line.replacingOccurrences(
                    of: #"^\s{4}-\s+"#,
                    with: "",
                    options: .regularExpression
                )
                if let value = unquote(stripped) {
                    refs.append(value)
                }
                continue
            }
            if inList, !line.trimmingCharacters(in: .whitespaces).isEmpty, indentOf(line) <= 2 {
                inList = false
            }
        }
        return refs
    }

    private static func parseSupportingSlots(_ lines: [String]) -> [FocusBoardApprovedSlot] {
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "supporting_slots:"
        }) else { return [] }
        var slots: [FocusBoardApprovedSlot] = []
        var current: FocusBoardApprovedSlot?
        for i in (start + 1)..<lines.count {
            let line = lines[i]
            if !line.trimmingCharacters(in: .whitespaces).isEmpty && indentOf(line) == 0 {
                break
            }
            if let match = line.range(of: #"^\s{2}-\s+project:\s*(.*)$"#, options: .regularExpression) {
                if let current { slots.append(current) }
                let value = String(line[match]).replacingOccurrences(
                    of: #"^\s{2}-\s+project:\s*"#,
                    with: "",
                    options: .regularExpression
                )
                current = FocusBoardApprovedSlot(project: unquote(value))
                continue
            }
            if var currentSlot = current,
               let field = line.range(of: #"^\s{4}([A-Za-z0-9_]+):\s*(.*)$"#, options: .regularExpression) {
                let body = String(line[field])
                if let nameRange = body.range(of: #"([A-Za-z0-9_]+)"#, options: .regularExpression) {
                    let name = String(body[nameRange])
                    let valuePart = body.replacingOccurrences(
                        of: #"^\s{4}[A-Za-z0-9_]+:\s*"#,
                        with: "",
                        options: .regularExpression
                    )
                    let value = unquote(valuePart)
                    switch name {
                    case "role": currentSlot.role = value
                    case "note": currentSlot.note = value
                    case "project": currentSlot.project = value
                    default: break
                    }
                    current = currentSlot
                }
            }
        }
        if let current { slots.append(current) }
        return slots
    }
}
