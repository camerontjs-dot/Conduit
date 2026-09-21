#if os(macOS)
import AppKit
import ConduitCore
import Foundation
import SwiftUI

struct ActiveWorkSession: Identifiable, Sendable {
    let id: String
    let project: MainframeProject
    let startedAt: Date
    var objective: String
    var notes: String
    let log: WorkSessionEventLog
}

/// Presentation-only result of a successful receipt write.
/// `RECORDED` may be shown only while a matching value exists for a project.
/// Never infer this from a click, pending state, status text, or recovery.
struct RecordedReceiptResult: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Project identity used for per-project routing and dismissal.
    let projectID: String
    /// Exact URL returned by `WorkSessionReceiptWriter.write`.
    let url: URL
    /// Wall-clock time when the writer returned successfully.
    let recordedAt: Date
}

/// Destination for an explicit terminal-selection staging draft.
/// `thisComposer` appends without sending; `agent` delivers via TerminalForwarder.
enum ForwardingDestination: Equatable, Hashable, Sendable {
    case thisComposer
    case agent(UUID)
}

/// Ephemeral operator-reviewed forward. Exists only while the staging card is open.
struct ForwardingDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Editable terminal selection captured from the clipboard at staging open.
    var selection: String
    /// Optional operator note/context; never replaces the evidence boundary.
    var note: String
    /// Provenance frozen at capture: active session agent name, or `"terminal"`.
    let sourceAgentName: String
    var destination: ForwardingDestination

    init(
        id: UUID = UUID(),
        selection: String,
        note: String = "",
        sourceAgentName: String,
        destination: ForwardingDestination
    ) {
        self.id = id
        self.selection = selection
        self.note = note
        self.sourceAgentName = sourceAgentName
        self.destination = destination
    }

    var lineCount: Int {
        if selection.isEmpty { return 0 }
        return selection.reduce(1) { partial, character in
            character == "\n" ? partial + 1 : partial
        }
    }

    var characterCount: Int { selection.count }
}

private enum ProjectScanResult: Sendable {
    case success([MainframeProject])
    case failure(String)
}

@MainActor
final class AppModel: ObservableObject {
    /// UserDefaults key for Focused Flow density. Independent of SettingsStore JSON.
    static let densityStorageKey = "conduit.density"
    /// UserDefaults key for trailing inspector visibility.
    static let inspectorPresentedStorageKey = "conduit.inspectorPresented"
    static let inspectorCardVisibilityKey = "conduit.inspectorCardVisibility"
    static let inspectorCardExpandedKey = "conduit.inspectorCardExpanded"
    static let inspectorCardsCustomizedKey = "conduit.inspectorCardsCustomized"
    static let newTaskScopeStorageKey = "conduit.newTask.scope"
    static let operatorPeekEnabledKey = "conduit.operatorPeek.enabled"
    static let operatorPeekCustomizedKey = "conduit.operatorPeek.customized"
    static let operatorPeekAgentIDsKey = "conduit.operatorPeek.agentIDs"
    static let companionScaleKey = "conduit.companionScale"
    static let companionScaleCustomizedKey = "conduit.companionScale.customized"
    static let companionShelfEnabledKey = "conduit.companionShelf.enabled"
    static let railSpritesForAllRowsKey = "conduit.railSprites.allRows"
    static let juicyFeedbackEnabledKey = "conduit.juicyFeedback.enabled"
    static let outputActivePulseEnabledKey = "conduit.outputActivePulse.enabled"
    static let companionChromeEnabledKey = "conduit.companionChrome.enabled"

    @Published var settings = ConduitSettings() {
        didSet { refreshTaskSidebarProjection() }
    }
    /// App-level navigation. Orchestrate is intentionally not a third surface
    /// over a worker terminal; Conversation and Raw remain session-only.
    @Published var workspace: ConduitWorkspace = .sessions
    @Published var projects: [MainframeProject] = [] {
        didSet { refreshTaskSidebarProjection() }
    }
    @Published var rootAccessNeedsAuthorization = false {
        didSet { refreshTaskSidebarProjection() }
    }
    @Published var isScanningProjects = false {
        didSet { refreshTaskSidebarProjection() }
    }
    @Published var selectedProjectID: String?
    @Published var orchestrationProjectID: String?
    @Published var orchestrationRequest = ""
    @Published private(set) var orchestrationContextPacket: OrchestrationContextPacket?
    @Published private(set) var orchestrationResponse: OrchestrationPlannerResponse?
    @Published private(set) var orchestrationValidation: OrchestrationProposalValidation?
    @Published private(set) var orchestrationRunState: OrchestrationRunState = .idle
    @Published private(set) var isOrchestrationPlannerRunning = false
    /// Explicit planner requests use only Ollama's fixed loopback API. The
    /// planner has no worker, filesystem, shell, MCP, or approval interface.
    let orchestrationBackendLabel = LocalOllamaPlanner.backendLabel
    @Published var sessions: [TerminalRuntime] = [] {
        didSet { refreshTaskSidebarProjection() }
    }
    @Published var activeSessionID: UUID?
    /// Durable, metadata-only task histories. MainFrame's current project scan
    /// remains authoritative for project names, paths, and lifecycle state.
    @Published private(set) var taskSessions: [TaskSessionSnapshot] = [] {
        didSet { refreshTaskSidebarProjection() }
    }
    @Published var selectedTaskSessionID: TaskSessionID? {
        didSet { refreshTaskSidebarProjection() }
    }
    @Published var taskSearchText = "" {
        didSet { refreshTaskSidebarProjection() }
    }
    @Published var showArchivedTasks = false {
        didSet { refreshTaskSidebarProjection() }
    }
    /// Nil means all task histories under the selected MainFrame root.
    @Published var taskScopeProjectID: String? {
        didSet { refreshTaskSidebarProjection() }
    }
    @Published var showNewTask = false
    @Published var showProjectBrowser = false
    @Published private(set) var taskSessionDiagnostics: [TaskSessionEventLogDiagnostic] = [] {
        didSet { refreshTaskSidebarProjection() }
    }
    /// Source-labelled conversation content retained separately from task
    /// metadata. MainFrame files and work-session receipts remain independent.
    @Published private(set) var conversationHistoryByTask:
        [TaskSessionID: [SessionPresentationEvent]] = [:]
    @Published private(set) var conversationHistoryDiagnostics:
        [TaskSessionID: [ConversationEventLogDiagnostic]] = [:]
    @Published private(set) var conversationRetentionStateByTask:
        [TaskSessionID: ConversationRetentionState] = [:]
    /// The sidebar catalog is a projection of task metadata and operational
    /// observations. It must not rebuild SessionCatalog for an unrelated
    /// conversation presentation publication.
    private var taskCatalogProjection = TaskCatalogProjection()
    /// Sidebar presentation observes this narrow model rather than AppModel's
    /// application-wide publisher. AppModel remains the action authority.
    let taskSidebarModel = TaskSidebarModel()
    /// Reconnect of a known task used to abort until history finished loading.
    /// Finish the reconnect automatically once the JSONL is in memory.
    private var reconnectAfterHistoryLoad: Set<TaskSessionID> = []
    /// Explicit MCP reconciliation of a known task also waits for its local
    /// conversation log, but must resume the same task rather than take the
    /// ordinary UI reconnect path.
    private var reconcileAfterHistoryLoad: Set<TaskSessionID> = []
    @Published private(set) var taskReconnectabilityObservation: ExternalReconnectabilityObservation = .notChecked {
        didSet { refreshTaskSidebarProjection() }
    }
    /// Completed observed-usage records for this root, loaded from the log at
    /// bootstrap and appended to as sessions end.
    @Published private(set) var completedUsage: [SessionUsageRecord] = []
    /// Durable tmux sessions found on the server, refreshed on demand.
    @Published private(set) var discoveredSessions: [DiscoveredSession] = [] {
        didSet { refreshTaskSidebarProjection() }
    }
    @Published var showResumeSessions = false
    /// Why discovery came back empty, when it did. Nil means a plain empty.
    @Published private(set) var discoveryNote: String?
    @Published var composerText = ""
    @Published var attachments: [Attachment] = []
    /// Ephemeral staging draft for terminal-selection forwarding. Nil when idle.
    @Published var forwardingDraft: ForwardingDraft?
    /// Legacy settings-backed default; layout no longer embeds context in the workspace.
    @Published var showContext = true
    /// Trailing inspector visibility. Fresh installs start closed; an explicit
    /// operator choice persists independently of responsive overlay/pin geometry.
    /// Persists under `conduit.inspectorPresented`.
    @Published var isContextInspectorPresented: Bool = AppModel.loadPersistedInspectorPresented() {
        didSet {
            UserDefaults.standard.set(
                isContextInspectorPresented,
                forKey: Self.inspectorPresentedStorageKey
            )
        }
    }
    /// Focus / jump target when opening Inspector (expands that card if visible).
    @Published var inspectorTab: InspectorTab = .session
    /// Which Inspector tool cards are shown. Persists under
    /// `conduit.inspectorCardVisibility`. Density defaults apply until customized.
    @Published var inspectorCardVisibility: [InspectorCard: Bool] =
        AppModel.loadInspectorCardMap(key: AppModel.inspectorCardVisibilityKey) {
            didSet {
                Self.persistInspectorCardMap(
                    inspectorCardVisibility,
                    key: Self.inspectorCardVisibilityKey
                )
            }
        }
    /// Which visible cards are expanded. Persists under
    /// `conduit.inspectorCardExpanded`.
    @Published var inspectorCardExpanded: [InspectorCard: Bool] =
        AppModel.loadInspectorCardMap(key: AppModel.inspectorCardExpandedKey) {
            didSet {
                Self.persistInspectorCardMap(
                    inspectorCardExpanded,
                    key: Self.inspectorCardExpandedKey
                )
            }
        }
    /// When false, density changes re-apply card show/expand defaults.
    @Published private(set) var inspectorCardsCustomized: Bool =
        UserDefaults.standard.bool(forKey: AppModel.inspectorCardsCustomizedKey)

    /// Optional multi-agent peek shelf (not a permanent OPERATORS strip).
    /// Density supplies the default until the operator customizes.
    @Published private(set) var operatorPeekCustomized: Bool =
        UserDefaults.standard.bool(forKey: AppModel.operatorPeekCustomizedKey)
    @Published var operatorPeekEnabledStored: Bool =
        UserDefaults.standard.object(forKey: AppModel.operatorPeekEnabledKey) as? Bool
            ?? false
    {
        didSet {
            UserDefaults.standard.set(
                operatorPeekEnabledStored,
                forKey: Self.operatorPeekEnabledKey
            )
        }
    }
    /// Empty means “all enabled agents.” Persisted as UUID strings.
    @Published var operatorPeekAgentIDs: Set<UUID> =
        AppModel.loadUUIDSet(key: AppModel.operatorPeekAgentIDsKey)
    {
        didSet {
            Self.persistUUIDSet(operatorPeekAgentIDs, key: Self.operatorPeekAgentIDsKey)
        }
    }

    @Published private(set) var companionScaleCustomized: Bool =
        UserDefaults.standard.bool(forKey: AppModel.companionScaleCustomizedKey)
    @Published var companionScaleStored: CompanionScale =
        CompanionScale(
            rawValue: UserDefaults.standard.string(
                forKey: AppModel.companionScaleKey
            ) ?? ""
        ) ?? .standard
    {
        didSet {
            UserDefaults.standard.set(
                companionScaleStored.rawValue,
                forKey: Self.companionScaleKey
            )
            refreshTaskSidebarProjection()
        }
    }

    /// Selected-companion shelf under the selected rail row (Balanced/Operator).
    @Published var companionShelfEnabled: Bool =
        UserDefaults.standard.object(forKey: AppModel.companionShelfEnabledKey) as? Bool
            ?? true
    {
        didSet {
            UserDefaults.standard.set(
                companionShelfEnabled,
                forKey: Self.companionShelfEnabledKey
            )
            refreshTaskSidebarProjection()
        }
    }

    /// When true, known-profile rows (not only selected) show a tiny sprite.
    @Published var railSpritesForAllRows: Bool =
        UserDefaults.standard.object(forKey: AppModel.railSpritesForAllRowsKey) as? Bool
            ?? false
    {
        didSet {
            UserDefaults.standard.set(
                railSpritesForAllRows,
                forKey: Self.railSpritesForAllRowsKey
            )
            refreshTaskSidebarProjection()
        }
    }

    /// Chrome juiciness for real operator actions (select/send/inspector).
    @Published var juicyFeedbackEnabled: Bool =
        UserDefaults.standard.object(forKey: AppModel.juicyFeedbackEnabledKey) as? Bool
            ?? true
    {
        didSet {
            UserDefaults.standard.set(
                juicyFeedbackEnabled,
                forKey: Self.juicyFeedbackEnabledKey
            )
            refreshTaskSidebarProjection()
        }
    }

    /// Calm activity cue on companions only while output is observed active.
    @Published var outputActivePulseEnabled: Bool =
        UserDefaults.standard.object(forKey: AppModel.outputActivePulseEnabledKey) as? Bool
            ?? true
    {
        didSet {
            UserDefaults.standard.set(
                outputActivePulseEnabled,
                forKey: Self.outputActivePulseEnabledKey
            )
            refreshTaskSidebarProjection()
        }
    }

    /// Conversation header companion strip (optional).
    @Published var companionChromeEnabled: Bool =
        UserDefaults.standard.object(forKey: AppModel.companionChromeEnabledKey) as? Bool
            ?? true
    {
        didSet {
            UserDefaults.standard.set(
                companionChromeEnabled,
                forKey: Self.companionChromeEnabledKey
            )
        }
    }

    /// Opens Settings as a sheet when the system Settings scene action fails.
    @Published var showSettingsSheet = false

    /// Brief presentation token after Send — UI flash only, not delivery proof.
    @Published private(set) var composerSendFlashToken: Int = 0

    @Published var statusMessage: String?
    /// Backing store for the operator-facing alert in `RootView`.
    @Published private var operatorAlert: String?

    /// Depth of the Session API call currently being served, if any.
    private var sessionAPIServingDepth = 0
    private var sessionAPICapturedError: String?

    /// The error channel shared by the Mac UI and the Session API.
    ///
    /// `RootView` presents any non-nil value as a blocking `.alert`. That made
    /// every failure inside an MCP write raise a modal on the operator's Mac —
    /// observed with `conduit_reconcile_task` on a closed structured task,
    /// which returned its refusal to the caller *and* left a dialog on screen
    /// that only a human standing at the machine could dismiss. Unattended
    /// orchestration cannot clear its own dialogs.
    ///
    /// While a Session API call is being served, assignments are captured for
    /// the MCP result instead of presented. Reads return the captured value,
    /// which is what the create/reconcile/send paths already rely on when they
    /// scrape this property to build an error payload.
    ///
    /// This covers failures raised synchronously while serving the call. An
    /// error assigned later, from an async continuation the call started, is
    /// outside the window and still reaches the operator's alert.
    var errorMessage: String? {
        get { sessionAPIServingDepth > 0 ? sessionAPICapturedError : operatorAlert }
        set {
            if sessionAPIServingDepth > 0 {
                sessionAPICapturedError = newValue
            } else {
                operatorAlert = newValue
            }
        }
    }
    @Published var isDropTargeted = false

    @Published var showDiagnostics = false
    @Published var showResources = false
    @Published var showAgentUsage = false
    @Published var showMindGraph = false
    @Published var showFocusBoardSheet = false
    @Published var showContextBundle = false
    @Published var focusBoard: FocusBoardSnapshot?
    @Published var focusBoardRefreshing = false
    @Published var focusBoardError: String?
    /// Account-reported usage (Claude / Codex / OpenCode). Separate from Tier A.
    @Published private(set) var accountUsage: [AccountUsageSnapshot] = []
    @Published private(set) var accountUsageRefreshing = false
    @Published private(set) var accountUsageError: String?
    @Published private(set) var sessionAPIAddress: String?
    private var sessionAPIServer: ConduitSessionAPIServer?

    var chatgptTunnelID: String? {
        let url = AdapterThreadStore.defaultDirectory()
            .appendingPathComponent("chatgpt-tunnel-id")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    /// Lazy, CLI-owned model catalogs keyed by saved profile identity.
    @Published private(set) var modelOptionsByAgentID: [UUID: [AgentModelOption]] = [:]
    @Published private(set) var modelCatalogRefreshingAgentIDs: Set<UUID> = []
    @Published var taskSearchFocusRequest = 0 {
        didSet { refreshTaskSidebarProjection() }
    }
    @Published var healthResults: [AgentHealthResult] = []
    @Published var resourceSnapshot = ResourceSnapshot.empty
    @Published var contextCandidates: [ContextDocument] = []
    @Published var selectedContextIDs = Set<String>()
    @Published var contextPreview = ""
    /// One work session per project, keyed by project id. Switching projects
    /// never discards a session; each closes explicitly with its own receipt.
    @Published var workSessions: [String: ActiveWorkSession] = [:]

    /// Projects with an in-flight close→render→write. Neutral feedback only;
    /// never a success claim and never sufficient to show `RECORDED`.
    @Published private(set) var pendingReceiptProjectIDs: Set<String> = []

    /// Successful receipt writes keyed by project id. Published only after
    /// `writer.write` returns a real URL. Interrupted-session recovery never
    /// inserts here.
    @Published private(set) var recordedReceipts: [String: RecordedReceiptResult] = [:]

    /// Focused Flow workspace density. Persists immediately under `conduit.density`.
    /// Missing or invalid stored values become and persist as Focused.
    @Published var density: Density = AppModel.loadPersistedDensity() {
        didSet {
            UserDefaults.standard.set(density.rawValue, forKey: Self.densityStorageKey)
            if !inspectorCardsCustomized {
                applyInspectorCardDefaults(for: density)
            }
            refreshTaskSidebarProjection()
        }
    }

    /// Effective optional Operator peek visibility (density default unless customized).
    var showsOperatorPeek: Bool {
        OperatorPeekPolicy.resolveEnabled(
            customized: operatorPeekCustomized,
            storedEnabled: operatorPeekEnabledStored,
            density: density
        )
    }

    /// Effective companion scale (density default unless customized).
    var companionScale: CompanionScale {
        companionScaleCustomized
            ? companionScaleStored
            : CompanionScale.defaultFor(density: density)
    }

    /// Enabled agents filtered for the peek shelf. Empty filter = all enabled.
    var operatorPeekAgents: [AgentProfile] {
        let enabled = enabledAgents
        guard !operatorPeekAgentIDs.isEmpty else { return enabled }
        let filtered = enabled.filter { operatorPeekAgentIDs.contains($0.id) }
        return filtered.isEmpty ? enabled : filtered
    }

    func setOperatorPeekEnabled(_ enabled: Bool) {
        operatorPeekEnabledStored = enabled
        if !operatorPeekCustomized {
            operatorPeekCustomized = true
            UserDefaults.standard.set(true, forKey: Self.operatorPeekCustomizedKey)
        }
    }

    func resetOperatorPeekToDensityDefault() {
        operatorPeekCustomized = false
        UserDefaults.standard.set(false, forKey: Self.operatorPeekCustomizedKey)
        operatorPeekEnabledStored = OperatorPeekPolicy.defaultEnabled(for: density)
    }

    func setCompanionScale(_ scale: CompanionScale) {
        companionScaleStored = scale
        if !companionScaleCustomized {
            companionScaleCustomized = true
            UserDefaults.standard.set(true, forKey: Self.companionScaleCustomizedKey)
            refreshTaskSidebarProjection()
        }
    }

    func resetCompanionScaleToDensityDefault() {
        companionScaleCustomized = false
        UserDefaults.standard.set(false, forKey: Self.companionScaleCustomizedKey)
        companionScaleStored = CompanionScale.defaultFor(density: density)
        refreshTaskSidebarProjection()
    }

    func toggleOperatorPeekAgent(_ id: UUID) {
        if operatorPeekAgentIDs.contains(id) {
            operatorPeekAgentIDs.remove(id)
        } else {
            operatorPeekAgentIDs.insert(id)
        }
    }

    func clearOperatorPeekAgentFilter() {
        operatorPeekAgentIDs = []
    }

    func noteComposerSendFlash() {
        composerSendFlashToken &+= 1
    }

    let speech = SpeechTranscriber()
    private let store = SettingsStore()
    private let scanner = MainframeScanner()
    private let inboxWriter = InboxWriter()
    private let contextBuilder = ContextBundleBuilder()
    private let receiptWriter = WorkSessionReceiptWriter()
    private let healthChecker = AgentHealthChecker()
    private let resourceService = ResourceService()
    /// Bounded admission for Session API writes (D-039).
    ///
    /// Rebuilt on every `syncSessionAPI()` so the policy always matches the
    /// current writes toggle, and seeded additively from the runtimes Conduit
    /// is actually hosting so a relaunch cannot forget occupied capacity.
    private var mcpAdmission: MCPAdmissionController?
    private let worklogDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".conduit/worklog", isDirectory: true)
    private let taskSessionStore = TaskSessionEventStore(
        directory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".conduit/task-sessions", isDirectory: true)
    )
    private let conversationDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".conduit/conversations", isDirectory: true)
    private lazy var conversationPersistence =
        ConversationPersistenceCoordinator(directory: conversationDirectory)
    /// Deduplicates content-free Recent-order facts across immutable revisions
    /// of the same prompt/output event.
    private var recordedConversationActivityKeys = Set<String>()
    private var retentionMarkerTasks = Set<TaskSessionID>()
    private var hasBootstrapped = false
    private var scopedRootURL: URL?
    private var isUsingScopedRoot = false
    /// Ephemeral navigation memory only. Runtime identity remains owned by the
    /// live `sessions` array and is never persisted as project truth.
    private var lastSelectedSessionIDByProject: [String: UUID] = [:]
    private var explicitlyFinalizedRuntimeAttempts = Set<RuntimeAttemptID>()

    init() {
        refreshTaskSidebarProjection()
    }

    /// Load density from UserDefaults; rewrite Focused when missing or invalid.
    private static func loadPersistedDensity() -> Density {
        let raw = UserDefaults.standard.string(forKey: densityStorageKey)
        let resolved = Density.resolved(fromStored: raw)
        if raw != resolved.rawValue {
            UserDefaults.standard.set(resolved.rawValue, forKey: densityStorageKey)
        }
        return resolved
    }

    /// Focused is the product default, so a fresh workspace protects the
    /// Conversation reading surface until the operator asks for Inspector.
    private static func loadPersistedInspectorPresented() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: inspectorPresentedStorageKey) != nil else {
            return false
        }
        return defaults.bool(forKey: inspectorPresentedStorageKey)
    }

    private static func loadInspectorCardMap(key: String) -> [InspectorCard: Bool] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: key),
              let raw = try? JSONDecoder().decode([String: Bool].self, from: data)
        else {
            return InspectorCard.defaultMap(
                for: loadPersistedDensity(),
                kind: key == inspectorCardExpandedKey ? .expanded : .visibility
            )
        }
        let density = loadPersistedDensity()
        let kind: InspectorCard.DefaultKind =
            key == inspectorCardExpandedKey ? .expanded : .visibility
        let densityDefaults = InspectorCard.defaultMap(for: density, kind: kind)
        var map: [InspectorCard: Bool] = [:]
        for card in InspectorCard.allCases {
            map[card] = raw[card.rawValue] ?? densityDefaults[card] ?? false
        }
        return map
    }

    private static func persistInspectorCardMap(
        _ map: [InspectorCard: Bool],
        key: String
    ) {
        var raw: [String: Bool] = [:]
        for (card, value) in map {
            raw[card.rawValue] = value
        }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func isInspectorCardVisible(_ card: InspectorCard) -> Bool {
        inspectorCardVisibility[card] ?? true
    }

    func isInspectorCardExpanded(_ card: InspectorCard) -> Bool {
        inspectorCardExpanded[card] ?? (card == .session)
    }

    func toggleInspectorCardVisibility(_ card: InspectorCard) {
        markInspectorCardsCustomized()
        var next = inspectorCardVisibility
        let visible = next[card] ?? true
        // Keep at least one card visible so Inspector never becomes empty chrome.
        if visible {
            let others = InspectorCard.allCases.contains {
                $0 != card && (next[$0] ?? true)
            }
            guard others else { return }
        }
        next[card] = !visible
        inspectorCardVisibility = next
    }

    func toggleInspectorCardExpanded(_ card: InspectorCard) {
        markInspectorCardsCustomized()
        var next = inspectorCardExpanded
        next[card] = !(next[card] ?? (card == .session))
        inspectorCardExpanded = next
    }

    func setInspectorCardExpanded(_ card: InspectorCard, expanded: Bool) {
        var next = inspectorCardExpanded
        next[card] = expanded
        inspectorCardExpanded = next
    }

    func focusInspectorCard(_ card: InspectorCard) {
        inspectorTab = card
        if !(inspectorCardVisibility[card] ?? true) {
            markInspectorCardsCustomized()
            var visibility = inspectorCardVisibility
            visibility[card] = true
            inspectorCardVisibility = visibility
        }
        setInspectorCardExpanded(card, expanded: true)
    }

    func resetInspectorCardsToDensityDefaults() {
        inspectorCardsCustomized = false
        UserDefaults.standard.set(false, forKey: Self.inspectorCardsCustomizedKey)
        applyInspectorCardDefaults(for: density)
    }

    private func markInspectorCardsCustomized() {
        guard !inspectorCardsCustomized else { return }
        inspectorCardsCustomized = true
        UserDefaults.standard.set(true, forKey: Self.inspectorCardsCustomizedKey)
    }

    private static func loadUUIDSet(key: String) -> Set<UUID> {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [String] else {
            return []
        }
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    private static func persistUUIDSet(_ set: Set<UUID>, key: String) {
        UserDefaults.standard.set(set.map(\.uuidString).sorted(), forKey: key)
    }

    private func applyInspectorCardDefaults(for density: Density) {
        inspectorCardVisibility = InspectorCard.defaultMap(for: density, kind: .visibility)
        inspectorCardExpanded = InspectorCard.defaultMap(for: density, kind: .expanded)
    }

    var selectedProject: MainframeProject? {
        projects.first { $0.id == selectedProjectID }
    }

    var orchestrationProjects: [MainframeProject] {
        OrchestrationScopeSelection.selectableProjects(from: projects)
    }

    var orchestrationProject: MainframeProject? {
        OrchestrationScopeSelection.selectedProject(
            explicitID: orchestrationProjectID,
            currentSelection: selectedProject,
            from: orchestrationProjects
        )
    }

    func selectOrchestrationProject(_ projectID: String?) {
        orchestrationProjectID = projectID
        resetOrchestrationPreview()
    }

    /// A deterministic presentation fixture for the Orchestrate workspace.
    /// It intentionally has no adapter, process, network, or task-start call.
    func previewOrchestrationProposal() {
        guard let project = orchestrationProject else {
            errorMessage = "Choose a scanned MainFrame project before preparing a proposal."
            return
        }
        let request = orchestrationRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            errorMessage = "Describe the bounded planning request first."
            return
        }
        guard let suggestedAgent = enabledAgents.first(where: {
            $0.name.localizedCaseInsensitiveContains("OpenCode")
        }) ?? enabledAgents.first(where: { $0.kind != .shell }) else {
            errorMessage = "Enable a non-shell agent before preparing a proposal."
            return
        }

        let context = OrchestrationContextPacket(projectID: project.id, entries: [])
        let proposal = OrchestrationProposal(
            objective: request,
            projectID: project.id,
            suggestedAgent: suggestedAgent.name,
            scopeAllowlist: ["(select bounded paths before a real launch)"],
            deliverables: ["Operator-reviewed task brief"],
            verificationSteps: ["Choose a deterministic check before launch."],
            risks: ["Fixture output is not a model response or task verification."],
            nonGoals: ["Do not launch a worker from fixture mode."]
        )
        let response = OrchestrationPlannerResponse(
            text: "Fixture proposal prepared locally. It demonstrates the review boundary only; no model, tool, or worker was invoked.",
            proposal: proposal,
            backendLabel: orchestrationBackendLabel
        )
        let policy = OrchestrationProposalPolicy(allowedAgentNames: [suggestedAgent.name])

        orchestrationRunState = OrchestrationRunReducer.reduce(.idle, event: .beginContext)
        orchestrationRunState = OrchestrationRunReducer.reduce(orchestrationRunState, event: .requestPlanner)
        orchestrationRunState = OrchestrationRunReducer.reduce(orchestrationRunState, event: .receiveProposal(proposal))
        orchestrationContextPacket = context
        orchestrationResponse = response
        orchestrationValidation = policy.validate(
            proposal: proposal,
            selectedProjectID: project.id,
            contextPacket: context,
            workerAlreadyActive: sessions.contains { !$0.controller.lifecycle.isTerminal }
        )
    }

    /// Calls the isolated local planner only after an explicit UI action. This
    /// cannot create or steer a worker task; it may only return visible text
    /// and, when declared JSON is valid, a reviewable proposal.
    func requestLocalOrchestrationProposal() {
        guard !isOrchestrationPlannerRunning else { return }
        guard let project = orchestrationProject else {
            errorMessage = "Choose a scanned MainFrame project before asking the local planner."
            return
        }
        let request = orchestrationRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else {
            errorMessage = "Describe the bounded planning request first."
            return
        }
        guard let openCodeAgent = enabledAgents.first(where: {
            $0.name.localizedCaseInsensitiveContains("OpenCode")
        }) else {
            errorMessage = "Enable the OpenCode profile before asking the local planner."
            return
        }

        let context = OrchestrationContextPacket(projectID: project.id, entries: [])
        orchestrationContextPacket = context
        orchestrationResponse = nil
        orchestrationValidation = nil
        orchestrationRunState = OrchestrationRunReducer.reduce(.idle, event: .beginContext)
        orchestrationRunState = OrchestrationRunReducer.reduce(orchestrationRunState, event: .requestPlanner)
        isOrchestrationPlannerRunning = true

        Task { [weak self] in
            defer { self?.isOrchestrationPlannerRunning = false }
            do {
                let response = try await LocalOllamaPlanner().propose(
                    request: request,
                    context: context
                )
                self?.orchestrationResponse = response
                if let proposal = response.proposal {
                    let policy = OrchestrationProposalPolicy(allowedAgentNames: [openCodeAgent.name])
                    self?.orchestrationRunState = OrchestrationRunReducer.reduce(
                        self?.orchestrationRunState ?? .idle,
                        event: .receiveProposal(proposal)
                    )
                    self?.orchestrationValidation = policy.validate(
                        proposal: proposal,
                        selectedProjectID: project.id,
                        contextPacket: context,
                        workerAlreadyActive: self?.sessions.contains { !$0.controller.lifecycle.isTerminal } ?? true
                    )
                } else {
                    self?.orchestrationRunState = .failed(
                        reason: "Planner text was visible but did not contain a declared typed proposal."
                    )
                }
            } catch {
                self?.orchestrationRunState = .failed(reason: error.localizedDescription)
                self?.errorMessage = "Local planner failed before any worker was created: \(error.localizedDescription)"
            }
        }
    }

    func resetOrchestrationPreview() {
        orchestrationContextPacket = nil
        orchestrationResponse = nil
        orchestrationValidation = nil
        orchestrationRunState = .idle
        isOrchestrationPlannerRunning = false
    }

    /// The active session only when it belongs to the project currently on
    /// screen. This prevents a project switch with no open tabs from silently
    /// leaving the composer aimed at the previous project.
    var activeSessionForSelectedProject: TerminalRuntime? {
        guard let selectedProject else { return nil }
        return sessions.first {
            $0.id == activeSessionID
                && session($0, belongsTo: selectedProject)
                && !$0.controller.lifecycle.isTerminal
        }
    }

    var selectedTaskSnapshot: TaskSessionSnapshot? {
        guard let selectedTaskSessionID else { return nil }
        return taskSessions.first { $0.id == selectedTaskSessionID }
    }

    var selectedTaskRuntime: TerminalRuntime? {
        guard let selectedTaskSessionID else { return nil }
        let matches = sessions.filter {
            $0.descriptor.taskSessionID == selectedTaskSessionID
        }
        return matches.first(where: { !$0.controller.lifecycle.isTerminal })
            ?? matches.first
    }

    var selectedTaskConversationEvents: [SessionPresentationEvent] {
        if let runtime = selectedTaskRuntime {
            return runtime.presentationEvents
        }
        guard let selectedTaskSessionID else { return [] }
        return conversationHistoryByTask[selectedTaskSessionID] ?? []
    }

    var selectedTaskConversationDiagnostics: [ConversationEventLogDiagnostic] {
        guard let selectedTaskSessionID else { return [] }
        return conversationHistoryDiagnostics[selectedTaskSessionID] ?? []
    }

    var selectedTaskConversationRetentionState: ConversationRetentionState? {
        guard let selectedTaskSessionID else { return nil }
        return conversationRetentionStateByTask[selectedTaskSessionID]
    }

    var selectedTaskProject: MainframeProject? {
        selectedTaskSnapshot.flatMap { project(for: $0) }
    }

    var selectedTaskAvailability: TaskSessionAvailability? {
        guard let selectedTaskSnapshot else { return nil }
        return TaskSessionAvailabilityResolver.resolve(
            session: selectedTaskSnapshot,
            context: taskAvailabilityContext
        )
    }

    /// Last explicit New Task scope. It is navigation preference only, never
    /// project authority, and falls back to the scanned MainFrame root.
    var newTaskDefaultProjectID: String? {
        let stored = UserDefaults.standard.string(forKey: Self.newTaskScopeStorageKey)
        if let stored, projects.contains(where: { $0.id == stored }) {
            return stored
        }
        return projects.first(where: \.isMainframeRoot)?.id ?? projects.first?.id
    }

    var taskAvailabilityContext: TaskSessionAvailabilityContext {
        var live: [TaskSessionID: RuntimeAttemptID] = [:]
        for runtime in sessions {
            guard !runtime.controller.lifecycle.isTerminal,
                  let taskID = runtime.descriptor.taskSessionID
            else { continue }
            live[taskID] = runtime.runtimeAttemptID
        }
        let reconnectable = Set(taskSessions.compactMap { task in
            reconnectableDiscoveredSession(for: task) == nil ? nil : task.id
        })
        return TaskSessionAvailabilityContext(
            liveRuntimeAttempts: live,
            reconnectableTaskSessionIDs: reconnectable,
            externalObservation: taskReconnectabilityObservation
        )
    }

    var taskCatalogRows: [TaskSessionCatalogRow] {
        let baseRows = catalogRows(includeArchived: showArchivedTasks)
        guard let scopeID = taskScopeProjectID,
              let project = projects.first(where: { $0.id == scopeID })
        else { return baseRows }
        if project.isMainframeRoot {
            return baseRows.filter {
                $0.session.metadata.workspace.projectPath == nil
            }
        }
        let path = project.path.standardizedFileURL.path
        return baseRows.filter {
            $0.session.metadata.workspace.projectPath == path
        }
    }

    private func catalogRows(
        includeArchived: Bool
    ) -> [TaskSessionCatalogRow] {
        let rootURL = settings.mainframeRoot
        taskCatalogProjection.update(
            sessions: taskSessions,
            availabilityContext: taskAvailabilityContext,
            query: TaskSessionCatalogQuery(
                workspaceRootURL: rootURL,
                searchText: taskSearchText,
                includeArchived: includeArchived
            )
        )
        return taskCatalogProjection.rows
    }

    var enabledAgents: [AgentProfile] {
        settings.agents.filter(\.enabled)
    }

    /// The profile currently targeted by the ordinary composer, if any.
    var composerAgent: AgentProfile? {
        activeSessionForSelectedProject?.descriptor.agent
    }

    func modelOptions(for agent: AgentProfile) -> [AgentModelOption] {
        var options = modelOptionsByAgentID[agent.id] ?? []
        if let model = agent.model,
           !model.isEmpty,
           !options.contains(where: { $0.id == model }) {
            options.insert(
                AgentModelOption(
                    id: model,
                    detail: "Configured model",
                    contextWindowTokens: agent.contextWindowTokens
                ),
                at: 0
            )
        }
        return options
    }

    func isModelCatalogRefreshing(for agent: AgentProfile) -> Bool {
        modelCatalogRefreshingAgentIDs.contains(agent.id)
    }

    /// Refreshes a model menu from the installed CLI. This is intentionally
    /// lazy so Conduit does not turn startup into a provider/network probe.
    func refreshModelCatalog(for agent: AgentProfile) {
        guard !modelCatalogRefreshingAgentIDs.contains(agent.id) else { return }
        modelCatalogRefreshingAgentIDs.insert(agent.id)
        let agentID = agent.id
        Task { @MainActor in
            let options = await AgentModelCatalogService.discover(for: agent)
            modelOptionsByAgentID[agentID] = options
            modelCatalogRefreshingAgentIDs.remove(agentID)
        }
    }

    /// Stores a model choice for future launches. When a live runtime for this
    /// agent supports mid-session switch (e.g. OpenCode `/model`), inject that
    /// slash command into the PTY; otherwise keep config for next launch only.
    func setModelSelection(
        _ option: AgentModelOption?,
        forAgentID id: UUID,
        persist: Bool = true
    ) {
        guard let index = settings.agents.firstIndex(where: { $0.id == id }) else {
            return
        }
        let model = option?.id.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.agents[index].model = model?.isEmpty == true ? nil : model
        settings.agents[index].contextWindowTokens = option?.contextWindowTokens
        let agent = settings.agents[index]
        if persist {
            saveSettings()
        }

        let liveRuntime = sessions.first {
            $0.descriptor.agent.id == id
                && !$0.controller.lifecycle.isTerminal
        }
        let applyMode = AgentMidSessionModelPolicy.applyMode(
            for: agent,
            modelID: agent.model,
            hasLiveRuntime: liveRuntime != nil
        )
        switch applyMode {
        case .nextLaunchOnly:
            statusMessage =
                "\(agent.name) model → \(agent.model ?? "CLI default"). Applies to the next launch."
        case .liveRequiresRelaunch:
            statusMessage =
                "\(agent.name) model → \(agent.model ?? "CLI default") saved. This live session keeps its current model until you leave and relaunch."
        case .liveSequence(let steps, let operatorNote):
            if let runtime = liveRuntime {
                runtime.controller.injectModelSwitchSequence(steps)
                statusMessage = "\(agent.name): \(operatorNote)"
            } else {
                statusMessage =
                    "\(agent.name) model → \(agent.model ?? "CLI default"). Applies to the next launch."
            }
        }

        guard let selectedModel = agent.model,
              option?.contextWindowTokens == nil
        else { return }
        Task { @MainActor in
            let context = await AgentModelCatalogService.contextWindowTokens(
                for: agent,
                model: selectedModel
            )
            guard let index = settings.agents.firstIndex(where: { $0.id == id }),
                  settings.agents[index].model == selectedModel
            else { return }
            settings.agents[index].contextWindowTokens = context
            if let context {
                modelOptionsByAgentID[id] = modelOptionsByAgentID[id, default: []].map {
                    guard $0.id == selectedModel else { return $0 }
                    return AgentModelOption(
                        id: $0.id,
                        displayName: $0.displayName,
                        detail: $0.detail,
                        contextWindowTokens: context
                    )
                }
                if persist { saveSettings() }
            }
        }
    }

    func openSettings() {
        // Prefer the SwiftUI Settings scene when the system action responds;
        // always offer the sheet as a reliable same-window fallback.
        let opened = NSApp.sendAction(
            Selector(("showSettingsWindow:")),
            to: nil,
            from: nil
        ) || NSApp.sendAction(
            Selector(("showPreferencesWindow:")),
            to: nil,
            from: nil
        )
        if !opened {
            showSettingsSheet = true
        } else {
            // Some macOS builds report success without raising a window.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self else { return }
                let settingsVisible = NSApp.windows.contains {
                    $0.isVisible
                        && (
                            $0.title.localizedCaseInsensitiveContains("settings")
                                || $0.title.localizedCaseInsensitiveContains("preferences")
                        )
                }
                if !settingsVisible {
                    self.showSettingsSheet = true
                }
            }
        }
    }

    /// Adds research-backed optional CLIs without touching an existing profile
    /// or rewriting the user's config behind their back.
    @discardableResult
    func addRecommendedCLIProfiles() -> Int {
        let existingCommands = Set(settings.agents.map {
            URL(fileURLWithPath: $0.command).lastPathComponent.lowercased()
        })
        let additions = AgentProfile.recommendedCLIProfiles.filter {
            !existingCommands.contains(
                URL(fileURLWithPath: $0.command).lastPathComponent.lowercased()
            )
        }
        guard !additions.isEmpty else {
            statusMessage = "Recommended CLI profiles are already configured."
            return 0
        }
        settings.agents.append(contentsOf: additions)
        saveSettings()
        let names = additions.map(\.name).joined(separator: ", ")
        statusMessage = "Added \(names) profile\(additions.count == 1 ? "" : "s")."
        return additions.count
    }

    // MARK: - Tier A observed usage

    /// Append-only log of what Conduit observed, under the selected root.
    /// Nil when no root is selected or the root is not a MainFrame live tree —
    /// in that case usage is still shown for live sessions but nothing is
    /// persisted, rather than being written somewhere arbitrary.
    private var usageLog: AgentUsageLog? {
        settings.mainframeRoot.flatMap { AgentUsageLog(mainframeRoot: $0) }
    }

    private func bankObservedUsage(_ record: SessionUsageRecord) {
        completedUsage.append(record)
        guard let usageLog else { return }
        do {
            try usageLog.append(record)
        } catch {
            // Usage is diagnostic, never evidence — a failed write must not
            // interrupt a session close or a receipt.
            statusMessage = "Usage note not written: \(error.localizedDescription)"
        }
    }

    private func handleUsageRecord(
        _ record: SessionUsageRecord,
        taskSessionID: TaskSessionID,
        runtimeAttemptID: RuntimeAttemptID
    ) {
        bankObservedUsage(record)
        if explicitlyFinalizedRuntimeAttempts.remove(runtimeAttemptID) != nil {
            return
        }
        let authority: TaskSessionEventAuthority
        let state: TaskSessionOperationalState
        switch record.outcome {
        case .detached:
            authority = .processObserved
            state = .runtimeDetached(runtimeAttemptID)
            if let runtime = sessions.first(where: {
                $0.runtimeAttemptID == runtimeAttemptID
            }) {
                noteDurableRuntimeAvailable(runtime)
            }
        case .exitedClean, .exitedFailed:
            authority = .processObserved
            state = .closed(.runtimeEnded)
            if let runtime = sessions.first(where: {
                $0.runtimeAttemptID == runtimeAttemptID
            }), runtime.controller.usesTmux,
               let tmuxName = runtime.descriptor.tmuxSessionName {
                discoveredSessions.removeAll { $0.tmuxName == tmuxName }
                taskReconnectabilityObservation = .notChecked
                Task { await refreshDiscoveredSessions() }
            }
        }
        _ = appendTaskEvent(
            TaskSessionEvent(
                taskSessionID: taskSessionID,
                occurredAt: record.endedAt,
                authority: authority,
                kind: .operationalStateChanged(state)
            )
        )
    }

    /// Rows for every configured agent, observed only. An agent with no
    /// activity reads zero observed sessions, which is a true statement about
    /// what Conduit saw — unlike a hidden row. Carries no token or cost data:
    /// that is Tier B and is not implemented.
    func observedUsageRows(at date: Date) -> [AgentObservedUsage] {
        let live = sessions.compactMap { runtime -> LiveSessionUsage? in
            let controller = runtime.controller
            guard !controller.lifecycle.isTerminal,
                  let startedAt = controller.attachedAt
            else { return nil }
            return LiveSessionUsage(
                agent: runtime.descriptor.agent.name,
                startedAt: startedAt,
                outputBytes: controller.observedOutputBytes,
                promptsDelivered: controller.observedPromptsDelivered,
                promptsFailed: controller.observedPromptsFailed
            )
        }
        return AgentUsageLedger.aggregate(
            records: completedUsage,
            live: live,
            roster: settings.agents.map(\.name),
            now: date
        )
    }

    /// Live attach observations used by week/session budget meters.
    func liveUsageSnapshots() -> [LiveSessionUsage] {
        sessions.compactMap { runtime -> LiveSessionUsage? in
            let controller = runtime.controller
            guard !controller.lifecycle.isTerminal,
                  let startedAt = controller.attachedAt
            else { return nil }
            return LiveSessionUsage(
                agent: runtime.descriptor.agent.name,
                startedAt: startedAt,
                outputBytes: controller.observedOutputBytes,
                promptsDelivered: controller.observedPromptsDelivered,
                promptsFailed: controller.observedPromptsFailed
            )
        }
    }

    /// This calendar week's observed usage for one agent profile name.
    func weekUsage(for agentName: String, at date: Date) -> AgentUsageMeters.WeekWindowUsage {
        AgentUsageMeters.weekUsage(
            agent: agentName,
            records: completedUsage,
            live: liveUsageSnapshots(),
            now: date
        )
    }

    /// Reload the MainFrame Focus Board from recorded feeds. Manual only.
    func refreshFocusBoard() {
        guard !focusBoardRefreshing else { return }
        guard let root = settings.mainframeRoot else {
            focusBoardError = FocusBoardLoadError.rootMissing.displayMessage
            return
        }
        focusBoardRefreshing = true
        focusBoardError = nil
        Task { @MainActor in
            let result = await FocusBoardService.load(mainframeRoot: root)
            self.focusBoardRefreshing = false
            switch result {
            case .success(let snapshot):
                self.focusBoard = snapshot
            case .failure(let error):
                self.focusBoardError = error.displayMessage
            }
        }
    }

    /// Reveal a MainFrame-relative evidence path in Finder when it is safe.
    func revealFocusBoardEvidence(_ relativePath: String) {
        guard let root = settings.mainframeRoot,
              let url = FocusBoard.resolvedEvidenceURL(
                path: relativePath,
                mainframeRoot: root
              )
        else {
            statusMessage = "Evidence path is not revealable from Conduit."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Pull Claude OAuth, Codex app-server, and OpenCode DB account usage.
    func refreshAccountUsage() {
        guard !accountUsageRefreshing else { return }
        accountUsageRefreshing = true
        accountUsageError = nil
        Task { @MainActor in
            var liveCodex: Data?
            if let ready = sessions.compactMap(\.appServer).first(where: \.isReady) {
                liveCodex = try? await ready.readRateLimits()
            }
            let snaps = await AccountUsageService.refreshAll(codexOverride: liveCodex)
            self.accountUsage = snaps
            self.accountUsageRefreshing = false
            let failed = snaps.compactMap(\.error)
            if failed.count == snaps.count, !failed.isEmpty {
                self.accountUsageError = "Could not load account usage for any agent."
            }
        }
    }

    // MARK: - MindGraph (operator query station)

    /// Runs one scoped MindGraph query via MainFrame `bin/mindgraph`.
    /// Knowledge and projects are never blended in a single call.
    func queryMindGraph(
        question: String,
        scope: MindGraphScope,
        topK: Int = 8
    ) async -> Result<[MindGraphHit], MindGraphQueryError> {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyQuestion) }

        guard let binary = MindGraphQuerySupport.resolveBinary(
            mainframeRoot: settings.mainframeRoot
        ) else {
            return .failure(.binaryNotFound)
        }
        let db = MindGraphQuerySupport.databaseURL(for: scope)
        guard FileManager.default.fileExists(atPath: db.path) else {
            return .failure(.databaseMissing(db.path))
        }

        let cappedTopK = max(1, min(30, topK))
        let result = await BlockingWork.run(qos: .userInitiated) {
            SubprocessRunner.run(
                binary.path,
                [
                    "query",
                    trimmed,
                    "--db", db.path,
                    "--top-k", "\(cappedTopK)",
                    "--json",
                    "--no-intent",
                ],
                timeout: 90
            )
        }

        if result.timedOut {
            return .failure(.timedOut)
        }
        // mindgraph may print log lines on stderr merged into output; still try
        // to decode when exit is non-zero if JSON is present.
        let data = Data(result.output.utf8)
        do {
            let hits = try MindGraphQuerySupport.decodeHits(
                from: data,
                scope: scope
            )
            if result.status != 0 && hits.isEmpty {
                return .failure(
                    .processFailed(status: result.status, message: result.output)
                )
            }
            return .success(hits)
        } catch let error as MindGraphQueryError {
            if result.status != 0 {
                return .failure(
                    .processFailed(status: result.status, message: result.output)
                )
            }
            return .failure(error)
        } catch {
            return .failure(.invalidJSON(error.localizedDescription))
        }
    }

    /// Agents eligible as staging forward targets (enabled, non-shell).
    var forwardableAgents: [AgentProfile] {
        enabledAgents.filter { $0.kind != .shell }
    }

    func bootstrap() async {
        // Runs once per process. RootView's .task can fire again (window
        // reopened), and re-running would let recovery delete live session
        // logs, so guard it.
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        statusMessage = "Loading Conduit configuration…"

        Task.detached(priority: .utility) {
            EnvironmentResolver.shared.prewarm()
        }
        let taskStore = taskSessionStore
        let taskLoad = await BlockingWork.run(qos: .utility) {
            taskStore.load()
        }
        applyTaskSessionLoad(taskLoad)
        settings = SettingsStore.loadSnapshot()
        showContext = settings.showContextByDefault
        guard activateSavedRootAccess() else {
            projects = []
            selectedProjectID = nil
            if settings.mainframeRoot != nil {
                rootAccessNeedsAuthorization = true
                statusMessage = "Choose Root once to renew macOS access to MainFrame."
            }
            return
        }
        statusMessage = "Scanning the configured MainFrame root…"
        guard await refreshProjectsForBootstrap() else { return }
        completedUsage = usageLog?.readRecords() ?? []
        recoverInterruptedWorkSessions()
        await refreshDiscoveredSessions()
        async let health: Void = refreshHealth()
        async let resources: Void = refreshResources()
        _ = await (health, resources)
        syncSessionAPI()
    }

    /// Startup scanning touches a protected user-selected folder. Keep that
    /// filesystem walk off the main actor so AppKit can finish first-window
    /// layout and present any privacy UI without a zero-sized window.
    @discardableResult
    private func refreshProjectsForBootstrap() async -> Bool {
        guard let root = settings.mainframeRoot else {
            projects = []
            selectedProjectID = nil
            return false
        }
        guard !isScanningProjects else { return false }
        isScanningProjects = true
        defer { isScanningProjects = false }
        let scanner = self.scanner
        let result = await BlockingWork.run(qos: .userInitiated, timeout: 6) {
            do {
                return ProjectScanResult.success(try scanner.scan(root: root))
            } catch {
                return ProjectScanResult.failure(error.localizedDescription)
            }
        }
        guard let result else {
            projects = []
            selectedProjectID = nil
            rootAccessNeedsAuthorization = true
            statusMessage = "MainFrame did not respond. Choose Root to renew macOS folder access."
            return false
        }
        switch result {
        case .success(let scanned):
            projects = scanned
            if selectedProjectID == nil || !scanned.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = scanned.first?.id
            }
            statusMessage = "Loaded \(max(scanned.count - 1, 0)) projects from MainFrame."
            errorMessage = nil
            rootAccessNeedsAuthorization = false
            return true
        case .failure(let message):
            projects = []
            errorMessage = message
            return false
        }
    }

    func refreshProjects() {
        guard !isScanningProjects else { return }
        Task {
            statusMessage = "Refreshing MainFrame projects…"
            _ = await refreshProjectsForBootstrap()
        }
    }

    func chooseMainframeRoot() {
        guard !sessions.contains(where: { !$0.controller.lifecycle.isTerminal }) else {
            errorMessage = "Leave or end open task runtimes before switching the MainFrame root."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose your MainFrame root"
        panel.prompt = "Use MainFrame"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.mainframeRoot
        if panel.runModal() == .OK, let url = panel.url {
            endScopedRootAccess()
            do {
                let bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                settings.mainframeRoot = url
                settings.mainframeRootBookmark = bookmark
                selectedTaskSessionID = nil
                selectedProjectID = nil
                activeSessionID = nil
                // Same reason as removeSessionTab: these runtimes are about to
                // become unreachable, so any promise they still owe has to be
                // recorded as broken first.
                for runtime in sessions { runtime.abandonHeldPrompts() }
                sessions.removeAll()
                lastSelectedSessionIDByProject.removeAll()
                taskScopeProjectID = nil
                discoveredSessions = []
                taskReconnectabilityObservation = .notChecked
                scopedRootURL = url
                isUsingScopedRoot = url.startAccessingSecurityScopedResource()
                rootAccessNeedsAuthorization = false
            } catch {
                rootAccessNeedsAuthorization = true
                errorMessage = "Conduit could not preserve access to that folder: \(error.localizedDescription)"
                return
            }
            Task {
                do {
                    try await store.save(settings)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            refreshProjects()
        }
    }

    private func activateSavedRootAccess() -> Bool {
        guard let bookmark = settings.mainframeRootBookmark else {
            return settings.mainframeRoot == nil
        }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            settings.mainframeRoot = url
            scopedRootURL = url
            isUsingScopedRoot = url.startAccessingSecurityScopedResource()
            if isStale {
                rootAccessNeedsAuthorization = true
                statusMessage = "MainFrame access has expired. Choose Root to renew it."
                endScopedRootAccess()
                return false
            }
            return true
        } catch {
            rootAccessNeedsAuthorization = true
            statusMessage = "MainFrame access could not be restored. Choose Root to renew it."
            return false
        }
    }

    private func endScopedRootAccess() {
        if isUsingScopedRoot {
            scopedRootURL?.stopAccessingSecurityScopedResource()
        }
        scopedRootURL = nil
        isUsingScopedRoot = false
    }

    // MARK: - Task history

    private func refreshTaskSidebarProjection() {
        taskSidebarModel.refresh(from: self)
    }

    private func applyTaskSessionLoad(_ result: TaskSessionEventStoreLoadResult) {
        taskSessions = result.snapshots
        taskSessionDiagnostics = result.diagnostics
        if let selectedTaskSessionID,
           !result.snapshots.contains(where: { $0.id == selectedTaskSessionID }) {
            self.selectedTaskSessionID = nil
        }
    }

    private func loadConversationHistory(
        for taskSessionID: TaskSessionID
    ) {
        let retentionWasExpected = taskSessions.first {
            $0.id == taskSessionID
        }?.conversationRetentionEnabled == true
        setConversationRetentionState(.loading, for: taskSessionID)
        conversationPersistence.read(
            taskSessionID: taskSessionID
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.conversationHistoryByTask[taskSessionID] =
                    result.log.events
                self.conversationHistoryDiagnostics[taskSessionID] =
                    result.log.diagnostics

                if result.log.diagnostics.contains(where: {
                    $0.kind == .unreadableLog
                }) {
                    self.setConversationRetentionState(
                        .failed("The local conversation file could not be read."),
                        for: taskSessionID
                    )
                } else if result.fileWasPresent {
                    self.setConversationRetentionState(
                        .persisted,
                        for: taskSessionID
                    )
                } else if retentionWasExpected {
                    self.setConversationRetentionState(
                        .missingExpected,
                        for: taskSessionID
                    )
                } else {
                    self.setConversationRetentionState(
                        .legacyPreRetention,
                        for: taskSessionID
                    )
                }

                if self.reconcileAfterHistoryLoad.remove(taskSessionID) != nil {
                    self.reconcileTask(taskSessionID)
                } else if self.reconnectAfterHistoryLoad.remove(taskSessionID) != nil {
                    self.reconnectTask(taskSessionID)
                }
            }
        }
    }

    private func recordConversationRevision(
        _ event: SessionPresentationEvent,
        taskSessionID: TaskSessionID
    ) {
        setConversationRetentionState(.pending, for: taskSessionID)
        conversationPersistence.append(
            event,
            taskSessionID: taskSessionID
        ) { [weak self] errorDescription in
            Task { @MainActor in
                guard let self else { return }
                let retentionState = ConversationRetentionPolicy.stateAfterAppend(
                    event,
                    errorDescription: errorDescription
                )
                if case .failed(let description) = retentionState {
                    self.setConversationRetentionState(
                        .failed(description),
                        for: taskSessionID
                    )
                    self.errorMessage =
                        "Conversation is visible but could not be retained locally: \(description)"
                    return
                }

                self.setConversationRetentionState(
                    retentionState,
                    for: taskSessionID
                )
                if self.taskSessions.first(where: {
                    $0.id == taskSessionID
                })?.conversationRetentionEnabled != true,
                   self.retentionMarkerTasks.insert(taskSessionID).inserted {
                    let marked = self.appendTaskEvent(
                        .conversationRetentionEnabled(
                            taskSessionID: taskSessionID
                        )
                    )
                    if !marked {
                        self.retentionMarkerTasks.remove(taskSessionID)
                    }
                }
                self.recordConversationActivityIfNeeded(
                    event,
                    taskSessionID: taskSessionID
                )
            }
        }
    }

    private func setConversationRetentionState(
        _ state: ConversationRetentionState,
        for taskSessionID: TaskSessionID
    ) {
        guard conversationRetentionStateByTask[taskSessionID] != state else {
            return
        }
        conversationRetentionStateByTask[taskSessionID] = state
    }

    private func recordConversationActivityIfNeeded(
        _ event: SessionPresentationEvent,
        taskSessionID: TaskSessionID
    ) {
        let phase: String
        switch event.kind {
        case .sessionOpened:
            return
        case .userPrompt:
            phase = "prompt"
        case .interruptRequested:
            phase = "interrupt-requested"
        case .agentOutput(let output):
            switch output.state {
            case .live: phase = "output-first"
            case .settled: phase = "output-settled"
            case .closed: phase = "output-closed"
            }
        }
        let key = "\(taskSessionID.rawValue.uuidString):\(event.id.uuidString):\(phase)"
        guard recordedConversationActivityKeys.insert(key).inserted else {
            return
        }
        _ = appendTaskEvent(
            .conversationActivity(
                taskSessionID: taskSessionID
            )
        )
    }

    @discardableResult
    private func appendTaskEvent(_ event: TaskSessionEvent) -> Bool {
        do {
            try TaskSessionEventLog(
                directory: taskSessionStore.directory,
                taskSessionID: event.taskSessionID
            ).append(event)
            applyTaskSessionLoad(taskSessionStore.load())
            return true
        } catch {
            errorMessage = "Could not record task history: \(error.localizedDescription)"
            return false
        }
    }

    private func workspaceSnapshot(for project: MainframeProject) -> WorkspaceScopeSnapshot {
        if project.isMainframeRoot {
            return .root(
                RootWorkspaceScopeSnapshot(
                    rootURL: project.path,
                    fallbackTitle: project.metadata.title,
                    fallbackSlug: project.slug
                )
            )
        }
        return .project(
            ProjectWorkspaceScopeSnapshot(
                rootURL: settings.mainframeRoot ?? project.path.deletingLastPathComponent(),
                projectURL: project.path,
                fallbackTitle: project.metadata.title,
                fallbackSlug: project.slug
            )
        )
    }

    private func createTaskSessionIfNeeded(
        id: TaskSessionID,
        project: MainframeProject,
        agentName: String?,
        defaultTitle: String
    ) -> Bool {
        if taskSessions.contains(where: { $0.id == id }) {
            return true
        }
        let metadata = TaskSessionMetadata(
            workspace: workspaceSnapshot(for: project),
            agentName: agentName,
            defaultTitle: defaultTitle
        )
        return appendTaskEvent(
            TaskSessionEvent(
                taskSessionID: id,
                authority: .conduitRecorded,
                kind: .created(metadata)
            )
        )
    }

    private func project(for task: TaskSessionSnapshot) -> MainframeProject? {
        switch task.metadata.workspace {
        case .root(let snapshot):
            return projects.first {
                $0.isMainframeRoot
                    && $0.path.standardizedFileURL.path == snapshot.rootPath
            }
        case .project(let snapshot):
            return projects.first {
                $0.path.standardizedFileURL.path == snapshot.projectPath
            }
        }
    }

    private func task(
        _ task: TaskSessionSnapshot,
        belongsTo project: MainframeProject
    ) -> Bool {
        switch task.metadata.workspace {
        case .root(let snapshot):
            return project.isMainframeRoot
                && project.path.standardizedFileURL.path == snapshot.rootPath
        case .project(let snapshot):
            return !project.isMainframeRoot
                && project.path.standardizedFileURL.path == snapshot.projectPath
        }
    }

    /// Applies the same deterministic identity checks used by `resume` before
    /// the catalog labels a task reconnectable. A task binding alone proves
    /// continuity, but it does not prove that the current project/agent
    /// metadata is compatible with the observed tmux session.
    private func reconnectableDiscoveredSession(
        for task: TaskSessionSnapshot
    ) -> DiscoveredSession? {
        guard let project = project(for: task) else { return nil }
        return discoveredSessions.first { discovered in
            guard discovered.taskSessionBinding.taskSessionID == task.id else {
                return false
            }
            if let discoveredPath = discovered.projectPath,
               discoveredPath.standardizedFileURL
                != project.path.standardizedFileURL {
                return false
            }
            if let recordedAgent = task.metadata.agentName,
               let discoveredAgent = discovered.agentName,
               recordedAgent != discoveredAgent {
                return false
            }
            return true
        }
    }

    /// Selects history only. Reconnect remains an explicit operator action.
    func selectTask(_ id: TaskSessionID) {
        guard let task = taskSessions.first(where: { $0.id == id }) else {
            errorMessage = "That task history is no longer available."
            return
        }
        selectedTaskSessionID = task.id
        if let project = project(for: task) {
            selectedProjectID = project.id
        } else {
            selectedProjectID = nil
        }
        if let runtime = sessions.first(where: {
            $0.descriptor.taskSessionID == task.id
                && !$0.controller.lifecycle.isTerminal
        }) {
            activeSessionID = runtime.id
            if let project = selectedProject {
                lastSelectedSessionIDByProject[project.id] = runtime.id
            }
        } else {
            activeSessionID = nil
            loadConversationHistory(for: task.id)
        }
    }

    @discardableResult
    func createTask(
        agent: AgentProfile,
        project: MainframeProject,
        taskSessionID requestedTaskSessionID: TaskSessionID? = nil
    ) -> TerminalRuntime? {
        guard enabledAgents.contains(where: { $0.id == agent.id }) else {
            errorMessage = "That agent is not currently enabled."
            return nil
        }
        guard let scannedProject = projects.first(where: { $0.id == project.id }) else {
            errorMessage = "That workspace is not in the current MainFrame scan."
            return nil
        }
        selectProject(scannedProject)
        UserDefaults.standard.set(scannedProject.id, forKey: Self.newTaskScopeStorageKey)
        beginWorkSessionIfNeeded(scannedProject)
        let instance = nextInstanceNumber(for: agent, in: scannedProject)
        let taskSessionID = requestedTaskSessionID ?? TaskSessionID()
        let hosted = hostedBackend(for: agent)
        let runtime = start(
            descriptor: SessionDescriptor(
                projectPath: scannedProject.path,
                agent: agent,
                taskSessionID: taskSessionID,
                instance: instance,
                recordsIdentity: true
            ),
            project: scannedProject,
            backendLabel: hosted.label,
            entry: .started(
                agentName: agent.name,
                requestedBackend: hosted.requested
            )
        )
        if runtime != nil {
            showNewTask = false
            statusMessage = "Started a new \(agent.name) task in \(scannedProject.metadata.title)."
        }
        return runtime
    }

    func renameTask(_ id: TaskSessionID, title: String?) {
        guard taskSessions.contains(where: { $0.id == id }) else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kind: TaskSessionEventKind = trimmed.isEmpty
            ? .titleReset
            : .titleOverridden(trimmed)
        _ = appendTaskEvent(
            TaskSessionEvent(
                taskSessionID: id,
                authority: .operatorAsserted,
                kind: kind
            )
        )
    }

    func setTaskPinned(_ id: TaskSessionID, pinned: Bool) {
        guard taskSessions.contains(where: { $0.id == id }) else { return }
        _ = appendTaskEvent(
            TaskSessionEvent(
                taskSessionID: id,
                authority: .operatorAsserted,
                kind: .pinChanged(pinned)
            )
        )
    }

    func setTaskArchived(_ id: TaskSessionID, archived: Bool) {
        guard let row = taskCatalogRow(id: id) else { return }
        if archived,
           (row.availability.kind == .running
                || row.availability.kind == .reconnectable) {
            errorMessage = "Detach or end this task before archiving its history."
            return
        }
        _ = appendTaskEvent(
            TaskSessionEvent(
                taskSessionID: id,
                authority: .operatorAsserted,
                kind: .archiveChanged(archived)
            )
        )
    }

    func reconnectTask(_ id: TaskSessionID) {
        if let runtime = sessions.first(where: {
            $0.descriptor.taskSessionID == id
                && !$0.controller.lifecycle.isTerminal
        }) {
            if let task = taskSessions.first(where: { $0.id == id }),
               let project = project(for: task) {
                selectedProjectID = project.id
            }
            _ = selectSession(runtime)
            return
        }
        guard let task = taskSessions.first(where: { $0.id == id }) else {
            errorMessage = "That task is no longer in the local catalog."
            return
        }
        if let discovered = reconnectableDiscoveredSession(for: task) {
            let explicitProject = project(for: task)
            _ = resume(discovered, adoptingInto: explicitProject)
            return
        }
        if let project = project(for: task),
           let agent = agentProfile(named: task.metadata.agentName),
           agent.prefersStructuredHost {
            selectProject(project)
            beginWorkSessionIfNeeded(project)
            _ = start(
                descriptor: SessionDescriptor(
                    projectPath: project.path,
                    agent: agent,
                    taskSessionID: task.id,
                    recordsIdentity: true
                ),
                project: project,
                backendLabel: agent.preferredSessionBackend.workSessionLabel,
                entry: .started(
                    agentName: agent.name,
                    requestedBackend: "\(agent.preferredSessionBackend.requestedBackendDescription) resume"
                )
            )
            return
        }
        errorMessage = "No identity-compatible tmux runtime was observed for this task. Refresh discovery or inspect the recovery details."
    }

    /// Explicit MCP recovery for a task whose runtime was not provisioned.
    /// This reuses the durable task ID and, when recorded, the exact attempted
    /// tmux name. It never kills, replaces, or adopts an uncertain session.
    func reconcileTask(_ id: TaskSessionID) {
        if let runtime = sessionAPILiveRuntime(for: id) {
            _ = selectSession(runtime)
            return
        }
        guard let task = taskSessions.first(where: { $0.id == id }) else {
            errorMessage = "That task is no longer in the local catalog."
            return
        }
        guard task.operationalState != nil else {
            errorMessage = "That task has no runtime attempt to reconcile."
            return
        }
        if conversationHistoryByTask[id] == nil {
            reconcileAfterHistoryLoad.insert(id)
            loadConversationHistory(for: id)
            statusMessage = "Loading this task's local history before reconciliation."
            return
        }
        if let discovered = reconnectableDiscoveredSession(for: task) {
            _ = resume(discovered, adoptingInto: project(for: task))
            return
        }
        let retryableProvisioningState: Bool = {
            switch task.operationalState {
            case .runtimeProvisioning?, .runtimeProvisioningFailed?:
                return true
            default:
                return false
            }
        }()
        guard retryableProvisioningState,
              let project = project(for: task),
              let agent = agentProfile(named: task.metadata.agentName)
        else {
            if case .runtimeProvisioningFailed(_, _, _, let recoverable)? = task.operationalState,
               !recoverable {
                errorMessage = "This task's provisioning failure is not marked recoverable."
            } else {
                errorMessage = "No identity-compatible runtime was observed for this task. Refresh discovery before retrying."
            }
            return
        }

        let targetSessionName: String?
        switch task.operationalState {
        case .runtimeProvisioning(_, _, let name)?,
             .runtimeProvisioningFailed(_, let name, _, _)?:
            targetSessionName = name
        default:
            targetSessionName = nil
        }
        selectProject(project)
        beginWorkSessionIfNeeded(project)
        _ = start(
            descriptor: SessionDescriptor(
                projectPath: project.path,
                agent: agent,
                tmuxSessionName: targetSessionName,
                taskSessionID: task.id,
                instance: targetSessionName == nil
                    ? nextInstanceNumber(for: agent, in: project)
                    : 1,
                recordsIdentity: true
            ),
            project: project,
            backendLabel: agent.prefersStructuredHost
                ? agent.preferredSessionBackend.workSessionLabel
                : (targetSessionName == nil && !settings.restoreSessions
                    ? AgentSessionBackend.pty.workSessionLabel
                    : "durable-reconcile"),
            entry: .started(
                agentName: agent.name,
                requestedBackend: targetSessionName == nil && !settings.restoreSessions
                    ? "direct PTY retry"
                    : "safe durable runtime reconciliation"
            ),
            requiresDurableSession: targetSessionName != nil
        )
    }

    private func agentProfile(named name: String?) -> AgentProfile? {
        guard let name else { return nil }
        return settings.agents.first { $0.name == name }
            ?? enabledAgents.first { $0.name == name }
    }

    /// Most recently active unarchived app-server task for this agent/project.
    /// Used by Launch-or-Reconnect so Codex does not mint a new thread.
    private func latestAppServerTask(
        agent: AgentProfile,
        project: MainframeProject
    ) -> TaskSessionSnapshot? {
        taskSessions
            .filter { task in
                !task.isArchived
                    && task.metadata.agentName == agent.name
                    && self.task(task, belongsTo: project)
            }
            .max(by: { $0.lastActivityAt < $1.lastActivityAt })
    }

    func leaveTask(_ id: TaskSessionID) {
        guard let runtime = sessions.first(where: {
            $0.descriptor.taskSessionID == id
                && !$0.controller.lifecycle.isTerminal
        }) else {
            statusMessage = "This task has no open runtime to leave."
            return
        }
        // Leaving is an explicit lifecycle verb, so it releases the admission
        // slot. A runtime that merely detached or died on its own does not.
        mcpAdmission?.markTaskEnded(id)
        closeSession(runtime)
    }

    func endTask(_ id: TaskSessionID) {
        guard let runtime = sessions.first(where: {
            $0.descriptor.taskSessionID == id
                && !$0.controller.lifecycle.isTerminal
        }) else {
            statusMessage = "Reconnect this task before ending its runtime."
            return
        }
        mcpAdmission?.markTaskEnded(id)
        endSession(runtime)
    }

    private func taskCatalogRow(id: TaskSessionID) -> TaskSessionCatalogRow? {
        catalogRows(includeArchived: true).first { $0.id == id }
    }

    func selectProject(_ project: MainframeProject) {
        guard let scannedProject = projects.first(where: { $0.id == project.id }) else {
            errorMessage = "That project is not in the current MainFrame scan. Refresh projects or choose the correct root."
            return
        }

        if let currentProject = selectedProject,
           let currentRuntime = activeSessionForSelectedProject {
            lastSelectedSessionIDByProject[currentProject.id] = currentRuntime.id
        }

        selectedProjectID = scannedProject.id
        let projectSessions = sessions.filter { session($0, belongsTo: scannedProject) }
        let restored = lastSelectedSessionIDByProject[scannedProject.id].flatMap { rememberedID in
            projectSessions.first {
                $0.id == rememberedID
                    && !$0.controller.lifecycle.isTerminal
            }
        }
        let selected = restored
            ?? projectSessions.first(where: { !$0.controller.lifecycle.isTerminal })
            ?? projectSessions.first
        activeSessionID = selected?.controller.lifecycle.isTerminal == false
            ? selected?.id
            : nil
        selectedTaskSessionID = selected?.descriptor.taskSessionID
        if let selected {
            lastSelectedSessionIDByProject[scannedProject.id] = selected.id
        } else {
            lastSelectedSessionIDByProject[scannedProject.id] = nil
        }
    }

    /// The sole view-facing path for selecting a live runtime. It refuses
    /// cross-project or stale runtime objects instead of redirecting composer
    /// and session commands outside the visible project scope.
    @discardableResult
    func selectSession(_ runtime: TerminalRuntime) -> Bool {
        guard let openRuntime = sessions.first(where: { $0.id == runtime.id }) else {
            errorMessage = "That session is no longer open."
            return false
        }
        guard let project = selectedProject,
              session(openRuntime, belongsTo: project) else {
            errorMessage = "That session does not belong to the selected project."
            return false
        }
        activeSessionID = openRuntime.controller.lifecycle.isTerminal
            ? nil
            : openRuntime.id
        selectedTaskSessionID = openRuntime.descriptor.taskSessionID
        lastSelectedSessionIDByProject[project.id] = openRuntime.id
        return true
    }

    func requestTaskSearchFocus() {
        taskSearchFocusRequest += 1
    }

    /// Shared by WorkspaceHeader and ⌘\ . Toggles the trailing inspector.
    func toggleContextPresentation() {
        isContextInspectorPresented.toggle()
    }

    func dismissContextInspector() {
        isContextInspectorPresented = false
    }

    var sessionsForSelectedProject: [TerminalRuntime] {
        guard let selectedProject else { return [] }
        return sessions.filter { session($0, belongsTo: selectedProject) }
    }

    private func session(_ runtime: TerminalRuntime, belongsTo project: MainframeProject) -> Bool {
        runtime.descriptor.projectPath.standardizedFileURL == project.path.standardizedFileURL
    }

    @discardableResult
    func launch(agent: AgentProfile) -> TerminalRuntime? {
        guard let project = selectedProject else {
            errorMessage = "Choose a MainFrame project first."
            return nil
        }
        beginWorkSessionIfNeeded(project)

        let matchingRuntimes = sessions.filter {
            $0.descriptor.projectPath.standardizedFileURL
                == project.path.standardizedFileURL
                && $0.descriptor.agent.id == agent.id
        }
        if let existing = matchingRuntimes.first(where: {
            !$0.controller.lifecycle.isTerminal
        }) {
            _ = selectSession(existing)
            statusMessage = "Focused the existing \(agent.name) task."
            return existing
        }
        for stale in matchingRuntimes where stale.controller.lifecycle.isTerminal {
            // Its process-observed terminal state is already recorded.
            // Removing stale presentation must not overwrite that state with
            // a second operator-close event.
            removeSessionTab(stale)
        }
        if agent.prefersStructuredHost,
           let existingTask = latestAppServerTask(agent: agent, project: project) {
            reconnectTask(existingTask.id)
            if let runtime = sessions.first(where: {
                $0.descriptor.taskSessionID == existingTask.id
                    && !$0.controller.lifecycle.isTerminal
            }) {
                statusMessage = "Reconnecting \(existingTask.displayTitle)."
                return runtime
            }
            return nil
        }
        if !agent.prefersStructuredHost,
           let durable = discoveredSessions.first(where: { discovered in
            discovered.projectPath?.standardizedFileURL == project.path.standardizedFileURL
                && discovered.agentName == agent.name
                && !sessions.contains(where: { runtime in
                    runtime.descriptor.tmuxSessionName == discovered.tmuxName
                })
        }) {
            switch durable.taskSessionBinding {
            case .valid:
                return resume(durable)
            case .absent:
                errorMessage = "A legacy \(agent.name) tmux session was found. Resume it explicitly from Discovered so Conduit can create its task history."
                return nil
            case .malformed(let rawValue):
                errorMessage = "The discovered \(agent.name) tmux session has a malformed task binding (\(rawValue)). It was left unchanged."
                return nil
            }
        }

        let hosted = hostedBackend(for: agent)
        return start(
            descriptor: SessionDescriptor(
                projectPath: project.path,
                agent: agent,
                instance: nextInstanceNumber(for: agent, in: project)
            ),
            project: project,
            backendLabel: hosted.label,
            entry: .started(
                agentName: agent.name,
                requestedBackend: hosted.requested
            )
        )
    }

    /// Explicitly opens an additional session for an agent that already has
    /// one. Kept separate from `launch` so the ordinary click keeps focusing
    /// the existing session rather than quietly multiplying tabs.
    @discardableResult
    func launchAdditional(agent: AgentProfile) -> TerminalRuntime? {
        guard let project = selectedProject else {
            errorMessage = "Choose a MainFrame project first."
            return nil
        }
        beginWorkSessionIfNeeded(project)
        let instance = nextInstanceNumber(for: agent, in: project)
        let hosted = hostedBackend(for: agent)
        let runtime = start(
            descriptor: SessionDescriptor(
                projectPath: project.path,
                agent: agent,
                instance: instance
            ),
            project: project,
            backendLabel: hosted.label,
            entry: .started(
                agentName: agent.name,
                requestedBackend: hosted.requested
            )
        )
        if runtime != nil {
            statusMessage = "Opened \(agent.name) session \(instance)."
        }
        return runtime
    }

    /// Reattaches to a durable tmux session that already exists. The tmux name
    /// comes from discovery, never re-derived, so the session that opens is the
    /// one that was listed.
    @discardableResult
    func resume(
        _ discovered: DiscoveredSession,
        adoptingInto explicitProject: MainframeProject? = nil
    ) -> TerminalRuntime? {
        let taskSessionID: TaskSessionID
        switch discovered.taskSessionBinding {
        case .valid(let existing):
            taskSessionID = existing
        case .absent:
            // The operator chose Resume on a visible legacy session. Passing a
            // fresh ID with its explicit tmux name is the reviewed adoption.
            taskSessionID = TaskSessionID()
        case .malformed(let rawValue):
            errorMessage = "Did not resume \(discovered.tmuxName): its task binding is malformed (\(rawValue)). Raw tmux state was left unchanged."
            return nil
        }

        let project: MainframeProject
        if let discoveredPath = discovered.projectPath {
            guard let knownProject = projects.first(where: {
                $0.path.standardizedFileURL == discoveredPath.standardizedFileURL
            }) else {
                errorMessage = "That durable session belongs to \(discoveredPath.path), which is not in the current MainFrame project scan. Refresh projects or choose the correct root before resuming."
                return nil
            }
            project = knownProject
        } else {
            guard let explicitProject,
                  let knownProject = projects.first(where: {
                      $0.id == explicitProject.id
                  }) else {
                errorMessage = "This legacy tmux session has no recorded project. Choose a MainFrame scope explicitly before adopting it."
                return nil
            }
            project = knownProject
        }
        if case .valid(let boundTaskID) = discovered.taskSessionBinding,
           let localTask = taskSessions.first(where: { $0.id == boundTaskID }) {
            guard task(localTask, belongsTo: project) else {
                errorMessage = "Did not reconnect \(discovered.tmuxName): its task history belongs to \(localTask.metadata.workspace.fallbackTitle), not \(project.metadata.title). Nothing was attached or rewritten."
                return nil
            }
            if let recordedAgent = localTask.metadata.agentName,
               let discoveredAgent = discovered.agentName,
               recordedAgent != discoveredAgent {
                errorMessage = "Did not reconnect \(discovered.tmuxName): tmux reports \(discoveredAgent), while its task history records \(recordedAgent). Nothing was attached or rewritten."
                return nil
            }
        }
        // Resolve all deterministic identity conflicts before navigation
        // changes. The explicit Resume action may then reveal the target
        // project while the attach itself remains separately guarded.
        selectProject(project)
        if let open = sessions.first(where: {
            $0.descriptor.tmuxSessionName == discovered.tmuxName
        }) {
            if !open.controller.lifecycle.isTerminal {
                guard selectSession(open) else { return nil }
                statusMessage = "That session is already open."
                return open
            }
            removeSessionTab(open)
        }
        // Resuming an unidentified session cannot invent an agent for it. The
        // placeholder below is a display label only — `recordsIdentity: false`
        // keeps it from being written back onto the tmux session as if it were
        // known.
        let knownAgent = discovered.agentName.flatMap { name in
            settings.agents.first { $0.name == name }
        }
        let agent = knownAgent
            ?? AgentProfile(
                name: discovered.agentName ?? "Unidentified",
                command: "/bin/zsh",
                arguments: ["-l"],
                kind: .shell
            )

        beginWorkSessionIfNeeded(project)
        let runtime = start(
            descriptor: SessionDescriptor(
                projectPath: project.path,
                agent: agent,
                title: discovered.agentName.map { "\($0) · resumed" } ?? "Unidentified · resumed",
                tmuxSessionName: discovered.tmuxName,
                taskSessionID: taskSessionID,
                adoptsLegacyTaskSession: discovered.taskSessionBinding == .absent,
                requiresExistingTmuxSession: true,
                recordsIdentity: discovered.isIdentified
            ),
            project: project,
            backendLabel: "durable-resumed",
            entry: .resumed(
                agentName: discovered.agentName ?? "Unidentified session",
                tmuxSessionName: discovered.tmuxName,
                attachedElsewhere: discovered.attachedClients > 0
            ),
            requiresDurableSession: true
        )
        guard let runtime else { return nil }
        statusMessage = discovered.attachedClients > 0
            ? "Resumed \(discovered.tmuxName) — another client is also attached."
            : "Resumed \(discovered.tmuxName)."
        return runtime
    }

    private func hostedBackend(for agent: AgentProfile) -> (label: String, requested: String) {
        let backend = agent.preferredSessionBackend
        if backend.isStructured {
            return (backend.workSessionLabel, backend.requestedBackendDescription)
        }
        if settings.restoreSessions {
            return ("durable-requested", "durable tmux, with PTY fallback")
        }
        return ("pty", "direct PTY")
    }

    /// Lowest instance number not already taken by an open tab or a live tmux
    /// session, so a new instance never collides with a detached one.
    private func nextInstanceNumber(for agent: AgentProfile, in project: MainframeProject) -> Int {
        var taken = Set(sessions.compactMap(\.descriptor.tmuxSessionName))
        taken.formUnion(discoveredSessions.map(\.tmuxName))
        return TmuxSessionNaming.nextInstance(
            projectPath: project.path,
            agentName: agent.name,
            existingNames: taken
        )
    }

    private func start(
        descriptor: SessionDescriptor,
        project: MainframeProject,
        backendLabel: String,
        entry: SessionEntry,
        requiresDurableSession: Bool = false
    ) -> TerminalRuntime? {
        var descriptor = descriptor
        let useDurableSession = !descriptor.agent.prefersStructuredHost
            && (settings.restoreSessions || requiresDurableSession)
        if useDurableSession && descriptor.tmuxSessionName == nil {
            descriptor.tmuxSessionName = TmuxSessionNaming.sessionName(
                projectPath: descriptor.projectPath,
                agentName: descriptor.agent.name,
                instance: descriptor.instance
            )
        }
        let taskSessionID = descriptor.taskSessionID ?? TaskSessionID()
        let taskWasAlreadyKnown = taskSessions.contains {
            $0.id == taskSessionID
        }
        let recordedAgentName = descriptor.recordsIdentity
            ? descriptor.agent.name
            : nil
        let defaultTitle = recordedAgentName.map {
            "\($0) · \(project.metadata.title)"
        } ?? "Session · \(project.metadata.title)"
        guard createTaskSessionIfNeeded(
            id: taskSessionID,
            project: project,
            agentName: recordedAgentName,
            defaultTitle: defaultTitle
        ) else {
            return nil
        }
        if taskWasAlreadyKnown,
           conversationHistoryByTask[taskSessionID] == nil {
            reconnectAfterHistoryLoad.insert(taskSessionID)
            loadConversationHistory(for: taskSessionID)
            statusMessage =
                "Loading this task's local conversation history, then reconnecting."
            return nil
        }
        descriptor.taskSessionID = taskSessionID
        let runtimeAttemptID = RuntimeAttemptID()
        guard appendTaskEvent(
            TaskSessionEvent(
                taskSessionID: taskSessionID,
                authority: .conduitRecorded,
                kind: .operationalStateChanged(
                    .runtimeProvisioning(
                        runtimeAttemptID,
                        backend: useDurableSession ? "tmux" : "pty",
                        tmuxSessionName: descriptor.tmuxSessionName
                    )
                )
            )
        ) else {
            return nil
        }
        let priorConversation =
            conversationHistoryByTask[taskSessionID] ?? []
        let runtime = TerminalRuntime(
            descriptor: descriptor,
            useDetachedSessions: useDurableSession,
            entry: entry,
            runtimeAttemptID: runtimeAttemptID,
            priorEvents: priorConversation,
            recordEventRevision: { [weak self] event in
                self?.recordConversationRevision(
                    event,
                    taskSessionID: taskSessionID
                )
            }
        )
        runtime.controller.onUsageRecord = { [weak self] record in
            Task { @MainActor in
                self?.handleUsageRecord(
                    record,
                    taskSessionID: taskSessionID,
                    runtimeAttemptID: runtimeAttemptID
                )
            }
        }
        sessions.append(runtime)
        _ = selectSession(runtime)
        // After durable reattach, rebuild any incomplete turn projection from
        // the live pane (missed paint while Conduit was away).
        if case .resumed = entry,
           !descriptor.agent.prefersStructuredHost {
            Task { @MainActor [weak runtime] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                runtime?.controller.startIfNeeded()
                runtime?.resyncConversationCapture()
            }
        }
        // Process ownership is independent of the Raw tab. Structured hosts
        // skip PTY/tmux unless fallback actually runs.
        if descriptor.agent.prefersStructuredHost {
            let resumeThreadID = AdapterThreadStore(
                directory: AdapterThreadStore.defaultDirectory()
            ).threadID(for: taskSessionID)
            let backend = descriptor.agent.preferredSessionBackend
            runtime.attachStructuredAdapter(
                backend: backend,
                cwd: descriptor.projectPath,
                model: descriptor.agent.model,
                resumeSessionID: resumeThreadID
            )
            Task { @MainActor [weak self, weak runtime] in
                guard let self, let runtime else { return }
                self.statusMessage = "Starting \(descriptor.agent.name) on \(backend.displayName)…"
                if let failure = await runtime.startStructuredAdapterIfNeeded() {
                    runtime.stopStructuredAdapter()
                    self.statusMessage =
                        "\(descriptor.agent.name) \(backend.displayName) failed (\(failure)). Falling back to PTY."
                    runtime.controller.preparePTYFallback()
                    runtime.controller.startIfNeeded()
                    if let issue = runtime.controller.launchIssue {
                        self.errorMessage = issue.localizedDescription
                    }
                } else {
                    self.statusMessage =
                        "\(descriptor.agent.name) is running on \(backend.displayName)."
                }
            }
        } else {
            runtime.controller.startIfNeeded()
        }
        if let issue = runtime.controller.launchIssue {
            _ = appendTaskEvent(
                TaskSessionEvent(
                    taskSessionID: taskSessionID,
                    authority: .conduitRecorded,
                    kind: .operationalStateChanged(
                        .runtimeProvisioningFailed(
                            runtimeAttemptID,
                            tmuxSessionName: descriptor.tmuxSessionName,
                            reason: issue.localizedDescription,
                            recoverable: true
                        )
                    )
                )
            )
            errorMessage = issue.localizedDescription
            removeSessionTab(runtime)
            return nil
        }
        _ = appendTaskEvent(
            TaskSessionEvent(
                taskSessionID: taskSessionID,
                authority: .conduitRecorded,
                kind: .operationalStateChanged(
                    .runtimeOpened(runtimeAttemptID)
                )
            )
        )
        if runtime.controller.usesTmux {
            noteDurableRuntimeAvailable(runtime)
        }
        appendEvent(
            .agentLaunched(
                agent: descriptor.agent.name,
                backend: backendLabel,
                at: Date()
            ),
            for: project
        )
        return runtime
    }

    // MARK: - Durable session discovery

    /// Upserts the one durable session Conduit just created, attached to, or
    /// detached from. This is a narrow local fact, not a claim that the whole
    /// tmux server was successfully observed.
    private func noteDurableRuntimeAvailable(_ runtime: TerminalRuntime) {
        guard runtime.controller.usesTmux,
              let tmuxName = runtime.descriptor.tmuxSessionName,
              let taskSessionID = runtime.descriptor.taskSessionID
        else { return }
        let previous = discoveredSessions.first { $0.tmuxName == tmuxName }
        let attachedClients = runtime.controller.isDetached
            ? max((previous?.attachedClients ?? 1) - 1, 0)
            : max(previous?.attachedClients ?? 0, 1)
        let observation = DiscoveredSession(
            tmuxName: tmuxName,
            projectPath: runtime.descriptor.recordsIdentity
                ? runtime.descriptor.projectPath
                : previous?.projectPath,
            agentName: runtime.descriptor.recordsIdentity
                ? runtime.descriptor.agent.name
                : previous?.agentName,
            taskSessionBinding: .valid(taskSessionID),
            createdAt: previous?.createdAt ?? runtime.descriptor.createdAt,
            attachedClients: attachedClients
        )
        discoveredSessions.removeAll { $0.tmuxName == tmuxName }
        discoveredSessions.append(observation)
    }

    /// Refreshes the list of durable tmux sessions. Discovery is read-only —
    /// it never creates, kills, or renames anything.
    func refreshDiscoveredSessions() async {
        guard let tmux = EnvironmentResolver.shared.resolve("tmux") else {
            discoveryNote = "tmux was not found on PATH, so no durable sessions could be listed."
            taskReconnectabilityObservation = .failed(observedAt: Date())
            return
        }
        let driver = TmuxDriver(tmuxPath: tmux)
        let outcome = await BlockingWork.run { driver.listConduitSessionsDetailed() }
        // An empty list has several causes and they are not interchangeable:
        // no server, a failed command, or output Conduit could not parse. Say
        // which, rather than letting "none found" stand for all of them.
        if !outcome.observationSucceeded {
            // Positive observations survive a failed or partial refresh.
            // Parsed rows are fresher positive facts, but missing rows are not
            // negative evidence until a complete observation succeeds.
            let parsedNames = Set(outcome.sessions.map(\.tmuxName))
            discoveredSessions.removeAll {
                parsedNames.contains($0.tmuxName)
            }
            discoveredSessions.append(contentsOf: outcome.sessions)
            if outcome.exitStatus != 0 {
                discoveryNote = "tmux list-sessions exited \(outcome.exitStatus): \(outcome.rawOutput.prefix(200))"
            } else {
                discoveryNote = "tmux reported one or more Conduit sessions that could not be parsed. Parsed rows remain visible, but absence is not treated as evidence."
            }
            taskReconnectabilityObservation = .failed(observedAt: Date())
        } else {
            discoveredSessions = outcome.sessions
            let hasMalformedTaskBinding = outcome.sessions.contains {
                if case .malformed = $0.taskSessionBinding { return true }
                return false
            }
            if hasMalformedTaskBinding {
                discoveryNote = "tmux discovery succeeded, but at least one Conduit session has a malformed task binding. Positive matches remain usable; absence is not treated as evidence until that identity is reviewed."
                taskReconnectabilityObservation = .failed(observedAt: Date())
            } else {
                discoveryNote = nil
                taskReconnectabilityObservation = .succeeded(observedAt: Date())
            }
        }
        if case .succeeded = taskReconnectabilityObservation {
            reconcileInterruptedTaskSessions()
        }
    }

    /// A successful tmux observation plus the absence of both an in-process
    /// runtime and a positively bound durable runtime lets Conduit record that
    /// a previously-open attempt was interrupted. Failed or malformed
    /// discovery remains unknown and never becomes negative evidence.
    private func reconcileInterruptedTaskSessions() {
        let liveTaskIDs = Set(sessions.compactMap(\.descriptor.taskSessionID))
        let candidates = TaskSessionRestartReconciler.interruptionCandidates(
            taskSessions: taskSessions,
            liveTaskIDs: liveTaskIDs,
            discoveredSessions: discoveredSessions
        )
        for candidate in candidates {
            _ = appendTaskEvent(
                TaskSessionEvent(
                    taskSessionID: candidate.taskSessionID,
                    authority: .processObserved,
                    kind: .operationalStateChanged(
                        .interrupted(candidate.runtimeAttemptID)
                    )
                )
            )
        }
    }

    /// Discovered sessions classified against what is currently open.
    var resumableSessions: [ResumableSession] {
        DiscoveredSessionCatalog.classify(
            discovered: discoveredSessions,
            selectedProjectPath: selectedProject?.path,
            openTmuxNames: Set(sessions.compactMap(\.descriptor.tmuxSessionName)),
            knownProjects: Dictionary(
                projects.map { ($0.path, $0.metadata.title) },
                uniquingKeysWith: { first, _ in first }
            )
        )
    }

    @discardableResult
    func launchDefaultShell() -> TerminalRuntime? {
        guard selectedProject != nil else { return nil }
        let shell = settings.agents.first(where: { $0.kind == .shell })
            ?? AgentProfile(name: "Shell", command: "/bin/zsh", arguments: ["-l"], kind: .shell)
        return launch(agent: shell)
    }

    /// Detach (tmux durable) or terminate (PTY). Tab leaves the UI; tmux work
    /// may keep running and will reconnect if the same agent is launched again.
    func closeSession(_ runtime: TerminalRuntime) {
        let keptRunning = runtime.controller.usesTmux
        explicitlyFinalizedRuntimeAttempts.insert(runtime.runtimeAttemptID)
        // Persist a deterministic closure before direct PTY termination can
        // deallocate the runtime and its weak lifecycle callback.
        runtime.closeAgentOutputCapture()
        runtime.stopAppServer()
        runtime.controller.closeSession()
        if let taskID = runtime.descriptor.taskSessionID {
            let state: TaskSessionOperationalState = keptRunning
                ? .runtimeDetached(runtime.runtimeAttemptID)
                : .closed(.operatorClosed)
            _ = appendTaskEvent(
                TaskSessionEvent(
                    taskSessionID: taskID,
                    authority: keptRunning ? .conduitRecorded : .operatorAsserted,
                    kind: .operationalStateChanged(state)
                )
            )
        }
        recordSessionClosed(runtime, endedHard: false)
        if keptRunning {
            noteDurableRuntimeAvailable(runtime)
            Task { await refreshDiscoveredSessions() }
        }
        removeSessionTab(runtime)
        if keptRunning {
            statusMessage = "Detached \(runtime.descriptor.agent.name). Reconnect it from task history."
        } else {
            statusMessage = "Closed \(runtime.descriptor.agent.name) session."
        }
    }

    func leaveActiveSession() {
        guard let activeSessionForSelectedProject else {
            statusMessage = "No active terminal session to leave."
            return
        }
        closeSession(activeSessionForSelectedProject)
    }

    func endActiveSession() {
        guard let activeSessionForSelectedProject else {
            statusMessage = "No active terminal session to end."
            return
        }
        endSession(activeSessionForSelectedProject)
    }

    /// Kill the process / tmux session and drop the tab. Next launch of that
    /// agent on this project starts fresh (no reconnect to a stuck shell).
    @discardableResult
    func endSession(_ runtime: TerminalRuntime) -> Bool {
        let tmuxName = runtime.controller.usesTmux
            ? runtime.descriptor.tmuxSessionName
            : nil
        explicitlyFinalizedRuntimeAttempts.insert(runtime.runtimeAttemptID)
        runtime.closeAgentOutputCapture()
        runtime.stopAppServer()
        let runtimeEnded = runtime.controller.endSession()
        if let taskID = runtime.descriptor.taskSessionID {
            let state: TaskSessionOperationalState = runtimeEnded
                ? .closed(.operatorEndedRuntime)
                : .runtimeDetached(runtime.runtimeAttemptID)
            _ = appendTaskEvent(
                TaskSessionEvent(
                    taskSessionID: taskID,
                    authority: runtimeEnded
                        ? .operatorAsserted
                        : .conduitRecorded,
                    kind: .operationalStateChanged(state)
                )
            )
        }
        recordSessionClosed(runtime, endedHard: runtimeEnded)
        if let tmuxName {
            if runtimeEnded {
                discoveredSessions.removeAll { $0.tmuxName == tmuxName }
                taskReconnectabilityObservation = .notChecked
            } else {
                noteDurableRuntimeAvailable(runtime)
            }
            Task { await refreshDiscoveredSessions() }
        }
        removeSessionTab(runtime)
        if runtimeEnded {
            statusMessage = "Ended \(runtime.descriptor.agent.name) session."
        } else {
            statusMessage = "Left the \(runtime.descriptor.agent.name) client."
            errorMessage = "Conduit could not confirm that tmux ended the underlying runtime. It remains available for explicit reconnection until a successful observation proves otherwise."
        }
        return runtimeEnded
    }

    /// End the current runtime and open a new attempt under the same task
    /// identity. This never routes to another same-agent task.
    @discardableResult
    func restartSession(_ runtime: TerminalRuntime) -> TerminalRuntime? {
        guard let taskSessionID = runtime.descriptor.taskSessionID else {
            errorMessage = "This legacy runtime has no task identity, so Conduit cannot restart it without breaking continuity."
            return nil
        }
        guard runtime.descriptor.recordsIdentity else {
            errorMessage = "This runtime has no verified agent identity. End or leave it, then start a new task explicitly."
            return nil
        }
        let agent = runtime.descriptor.agent
        let descriptor = runtime.descriptor
        guard let project = projects.first(where: {
            $0.path.standardizedFileURL
                == descriptor.projectPath.standardizedFileURL
        }) else {
            errorMessage = "This runtime's MainFrame workspace is no longer in the current project scan."
            return nil
        }
        let wasDurable = runtime.controller.usesTmux
        guard endSession(runtime) else {
            errorMessage = "The underlying tmux runtime could not be confirmed ended, so Conduit did not launch a replacement."
            return nil
        }
        selectProject(project)
        beginWorkSessionIfNeeded(project)
        return start(
            descriptor: SessionDescriptor(
                projectPath: descriptor.projectPath,
                agent: agent,
                tmuxSessionName: wasDurable
                    ? descriptor.tmuxSessionName
                    : nil,
                taskSessionID: taskSessionID,
                instance: descriptor.instance,
                recordsIdentity: true
            ),
            project: project,
            backendLabel: wasDurable
                ? "durable-restarted"
                : (settings.restoreSessions
                    ? "durable-requested"
                    : "pty"),
            entry: .started(
                agentName: agent.name,
                requestedBackend: wasDurable
                    ? "fresh durable tmux runtime"
                    : (settings.restoreSessions
                        ? "durable tmux, with PTY fallback"
                        : "direct PTY")
            ),
            requiresDurableSession: wasDurable
        )
    }

    private func recordSessionClosed(_ runtime: TerminalRuntime, endedHard: Bool) {
        let controller = runtime.controller
        if let project = projects.first(where: { $0.path == runtime.descriptor.projectPath }) {
            appendEvent(
                .terminalOutcome(
                    agent: runtime.descriptor.agent.name,
                    title: controller.terminalTitle,
                    exitCode: controller.exitCode,
                    detached: !endedHard && controller.isDetached,
                    live: false,
                    at: Date()
                ),
                for: project
            )
        }
    }

    private func removeSessionTab(_ runtime: TerminalRuntime) {
        // Dropping the tab drops the last strong reference to the runtime, and
        // the hold-expiry Task holds it weakly, so anything still held here
        // would never be resolved: the durable prompt event would stay
        // `queued` for good and a caller that was told not to resend would
        // wait on nothing. closeSession and endSession already resolve holds
        // via stopStructuredAdapter, but the stale-tab sweeps and the
        // provisioning-failure path reach this function without them, and an
        // adapter that exits on its own never calls stop at all.
        runtime.abandonHeldPrompts()
        if let taskSessionID = runtime.descriptor.taskSessionID {
            // Never present volatile runtime memory as retained history. This
            // read is queued behind every prior append/close revision.
            conversationHistoryByTask.removeValue(forKey: taskSessionID)
            loadConversationHistory(for: taskSessionID)
        }
        sessions.removeAll { $0.id == runtime.id }
        let staleProjectIDs = lastSelectedSessionIDByProject.compactMap { projectID, rememberedID in
            rememberedID == runtime.id ? projectID : nil
        }
        for projectID in staleProjectIDs {
            lastSelectedSessionIDByProject[projectID] = nil
        }
        if activeSessionID == runtime.id {
            // Task-first navigation keeps the just-left task selected so its
            // detached/closed history remains visible. Reconnection is explicit.
            activeSessionID = nil
        }
    }

    func sendComposer() {
        let assembled = PromptAssembler.assemble(
            text: composerText,
            attachments: attachments
        )
        guard !assembled.isEmpty else { return }

        let runtime: TerminalRuntime
        if let activeSessionForSelectedProject {
            runtime = activeSessionForSelectedProject
        } else if selectedTaskSnapshot != nil {
            errorMessage = "This task has no open runtime. Reconnect it or start a new task before sending."
            return
        } else if let launched = launchDefaultShell() {
            runtime = launched
            statusMessage = "Opened a shell; the prompt will be delivered when it is ready."
        } else {
            return
        }

        let savedText = composerText
        let savedAttachments = attachments
        let trimmedComposer = savedText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        // Slash/skills: complete in the Conduit composer, then on Return run as
        // a real CLI command (TUI inject). Paste delivery is treated as chat by
        // OpenCode/Claude and does not invoke builtins like `/cost`.
        if runtime.usesStructuredHost, !runtime.structuredIsReady {
            errorMessage = "\(runtime.descriptor.agent.name) is still starting. Wait for it to become ready before sending."
            return
        }
        if savedAttachments.isEmpty,
           !runtime.usesStructuredHost,
           AgentSlashCatalog.looksLikeSlashCommand(trimmedComposer) {
            sendSlashCommand(
                trimmedComposer,
                via: runtime
            )
            return
        }

        let deliveryPayload = deliveryPayload(
            assembled: assembled,
            runtime: runtime,
            attachmentCount: savedAttachments.count
        )
        let eventID = runtime.recordPrompt(
            text: savedText,
            attachmentPaths: savedAttachments.map(\.url.path),
            renderedPayload: deliveryPayload
        )
        runtime.selectedSurface = .conversation
        composerText = ""
        let attachmentCount = savedAttachments.count
        attachments = []
        noteComposerSendFlash()
        if attachmentCount > 0 {
            statusMessage = attachmentCount == 1
                ? "Sent with 1 attachment."
                : "Sent with \(attachmentCount) attachments."
        }
        let agentName = runtime.controller.descriptor.agent.name
        if runtime.structuredIsReady {
            let delivered = runtime.sendStructuredPrompt(text: assembled)
            runtime.updatePromptDelivery(
                eventID: eventID,
                to: delivered ? .delivered : .failed
            )
            if !delivered {
                if composerText.isEmpty && attachments.isEmpty {
                    composerText = savedText
                    attachments = savedAttachments
                }
                errorMessage = "The prompt could not be delivered to \(runtime.descriptor.agent.name). It has been kept in the composer."
            }
            return
        }
        // Capture uses the human-visible assembled prompt for echo stripping,
        // not the host envelope wrapper.
        runtime.controller.deliverPrompt(
            deliveryPayload,
            willDeliver: { [weak runtime] baseline in
                runtime?.beginAgentOutputCapture(
                    promptEventID: eventID,
                    promptText: assembled,
                    baseline: baseline
                )
            }
        ) { [weak self, weak runtime] delivered in
            guard let self else { return }
            runtime?.updatePromptDelivery(
                eventID: eventID,
                to: delivered ? .delivered : .failed
            )
            guard !delivered else { return }
            // Delivery failed — restore what the user typed so it is never lost,
            // unless they have already started composing something new.
            if self.composerText.isEmpty && self.attachments.isEmpty {
                self.composerText = savedText
                self.attachments = savedAttachments
            }
            self.errorMessage = "The prompt could not be delivered to \(agentName). It has been kept in the composer."
        }
    }

    /// Completes a slash/skill into the Conduit composer only. Return then
    /// sends it as a CLI command (see `sendSlashCommand`).
    func applySlashCommandToComposer(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composerText = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        statusMessage = "Selected \(composerText). Press Return to run it."
    }

    /// Records the slash in Conversation, then injects it into the live agent
    /// input with Enter so builtins/skills actually run (not chat-pasted).
    private func sendSlashCommand(
        _ command: String,
        via runtime: TerminalRuntime
    ) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !runtime.controller.lifecycle.isTerminal else {
            errorMessage = "No live agent session for slash commands."
            return
        }
        let eventID = runtime.recordPrompt(
            text: trimmed,
            attachmentPaths: [],
            renderedPayload: trimmed
        )
        let baseline = runtime.controller.currentCaptureBaseline()
        runtime.beginAgentOutputCapture(
            promptEventID: eventID,
            promptText: trimmed,
            baseline: baseline
        )
        runtime.controller.armConversationCapture(from: baseline)
        runtime.controller.injectSlashCommand(trimmed)
        runtime.updatePromptDelivery(eventID: eventID, to: .delivered)
        // Catch the command result without waiting on the paste queue.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak runtime] in
            runtime?.controller.refreshConversationCapture()
        }
        runtime.selectedSurface = .conversation
        composerText = ""
        attachments = []
        noteComposerSendFlash()
        statusMessage = "Ran \(trimmed) as a CLI command."
    }

    /// Builds the terminal delivery string. CLI agents receive a compact
    /// Conduit host envelope; Conversation still stores human text separately.
    private func deliveryPayload(
        assembled: String,
        runtime: TerminalRuntime,
        attachmentCount: Int
    ) -> String {
        let agent = runtime.descriptor.agent
        guard settings.injectHostEnvelope,
              !runtime.usesStructuredHost,
              HostEnvelope.shouldInject(for: agent) else { return assembled }
        let projectPath = runtime.descriptor.projectPath.path
        let taskID = selectedTaskSnapshot?.id.rawValue.uuidString
            ?? runtime.descriptor.taskSessionID?.rawValue.uuidString
        let context = HostEnvelope.Context(
            taskSessionID: taskID,
            projectPath: projectPath,
            agentName: agent.name,
            surface: runtime.selectedSurface.rawValue,
            tmuxSessionName: runtime.controller.tmuxSessionName
                ?? runtime.descriptor.tmuxSessionName,
            attachmentCount: attachmentCount
        )
        return HostEnvelope.wrap(prompt: assembled, context: context)
    }

    func addFiles() {
        let panel = NSOpenPanel()
        panel.title = "Attach files or folders"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            addAttachments(panel.urls)
        }
    }

    func addAttachments(_ urls: [URL]) {
        let existing = Set(attachments.map(\.url))
        let fresh = urls.filter { !existing.contains($0) }.map { Attachment(url: $0) }
        guard !fresh.isEmpty else {
            if !urls.isEmpty {
                statusMessage = urls.count == 1
                    ? "Already attached \(urls[0].lastPathComponent)."
                    : "Those files are already attached."
            }
            return
        }
        attachments.append(contentsOf: fresh)
        if fresh.count == 1 {
            statusMessage = "Attached \(fresh[0].url.lastPathComponent)."
        } else {
            statusMessage = "Attached \(fresh.count) items (\(attachments.count) ready to send)."
        }
    }

    func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
        if attachments.isEmpty {
            statusMessage = "Attachment removed."
        } else {
            statusMessage = "Attachment removed · \(attachments.count) remaining."
        }
    }

    /// Updates the stored agent profile permission mode. Applies on the next
    /// process launch for that agent, not mid-flight inside an open runtime.
    func setPermissionMode(
        _ mode: AgentPermissionMode,
        forAgentID id: UUID
    ) {
        guard let index = settings.agents.firstIndex(where: { $0.id == id }) else {
            return
        }
        settings.agents[index].permissionMode = mode
        saveSettings()
        let name = settings.agents[index].name
        statusMessage =
            "\(name) permission mode → \(mode.displayName). Applies to the next launch of this agent."
    }

    /// Sets permission mode for the agent matching the selected runtime profile.
    func setPermissionModeForActiveAgent(_ mode: AgentPermissionMode) {
        guard let runtime = selectedTaskRuntime ?? activeSessionForSelectedProject
        else {
            errorMessage = "No active agent task to configure."
            return
        }
        let agent = runtime.descriptor.agent
        if let index = settings.agents.firstIndex(where: {
            $0.id == agent.id || $0.name == agent.name
        }) {
            setPermissionMode(mode, forAgentID: settings.agents[index].id)
        } else {
            errorMessage = "Could not find a saved profile for \(agent.name)."
        }
    }

    /// Sends a menu choice or control key into the live PTY without treating it
    /// as Raw direct input, so Conversation capture can continue.
    func injectConversationControl(
        text: String? = nil,
        key: TerminalControlKey? = nil,
        submit: Bool = false,
        into runtime: TerminalRuntime
    ) {
        if let key {
            runtime.controller.injectControlKey(key)
            statusMessage = "Sent \(key.label) to \(runtime.descriptor.agent.name)."
            return
        }
        if let text {
            runtime.controller.injectControlInput(text, submit: submit)
            let shown = text
                .replacingOccurrences(of: "\n", with: "↵")
                .replacingOccurrences(of: "\r", with: "↵")
            statusMessage = submit
                ? "Sent “\(shown)” + Enter to \(runtime.descriptor.agent.name)."
                : "Sent “\(shown)” to \(runtime.descriptor.agent.name)."
        }
    }

    func pasteImage() {
        do {
            let url = try AttachmentService.saveImageFromPasteboard()
            addAttachments([url])
            // addAttachments already sets status; keep a paste-specific phrase.
            statusMessage = "Pasted image \(url.lastPathComponent)."
        } catch {
            errorMessage = "Could not paste image: \(error.localizedDescription)"
        }
    }

    func captureScreen() {
        statusMessage = "Capturing screen area…"
        Task {
            do {
                let url = try await AttachmentService.captureScreenSelection()
                addAttachments([url])
                statusMessage = "Captured screenshot \(url.lastPathComponent)."
            } catch is CancellationError {
                statusMessage = "Screen capture cancelled."
            } catch {
                errorMessage = "Screen capture failed: \(error.localizedDescription)"
                statusMessage = nil
            }
        }
    }

    func captureComposerToInbox() {
        guard let root = settings.mainframeRoot else {
            errorMessage = "Choose your MainFrame root first."
            return
        }
        do {
            let url = try inboxWriter.capture(
                root: root,
                project: selectedProject,
                text: composerText,
                attachments: attachments
            )
            composerText = ""
            attachments = []
            statusMessage = "Captured to \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func absorbSpeechTranscript() {
        let transcript = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { return }
        composerText += composerText.isEmpty ? transcript : " \(transcript)"
        speech.transcript = ""
    }

    func toggleSpeech() {
        if speech.isRecording {
            speech.stop()
            absorbSpeechTranscript()
        } else {
            speech.start()
        }
    }

    /// Opens staging with This composer pre-selected. Captures clipboard only.
    func beginForwardingToComposer() {
        beginForwardingStaging(destination: .thisComposer)
    }

    /// Opens staging with a named agent pre-selected. Captures clipboard only.
    func beginForwarding(to agent: AgentProfile) {
        beginForwardingStaging(destination: .agent(agent.id))
    }

    /// Capture clipboard text + provenance into an ephemeral draft. Does not
    /// launch, write a PTY, mutate the ordinary composer, or claim delivery.
    func beginForwardingStaging(destination: ForwardingDestination) {
        guard let selection = NSPasteboard.general.string(forType: .string),
              !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Copy terminal text first, then forward it."
            return
        }
        let sourceName = activeSessionForSelectedProject?.descriptor.agent.name
        let provenance = (sourceName?.isEmpty == false) ? sourceName! : "terminal"
        forwardingDraft = ForwardingDraft(
            selection: selection,
            sourceAgentName: provenance,
            destination: destination
        )
        errorMessage = nil
    }

    /// Dismiss the staging draft only. Clipboard, composer, sessions, and
    /// attachments are untouched.
    func cancelForwardingDraft() {
        forwardingDraft = nil
    }

    /// Explicit confirmation: append to composer or deliver via TerminalForwarder.
    func confirmForwardingDraft() {
        guard let draft = forwardingDraft else { return }
        let trimmedSelection = draft.selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSelection.isEmpty else {
            errorMessage = "The selection is empty."
            return
        }
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)

        switch draft.destination {
        case .thisComposer:
            var block = draft.selection
            if !note.isEmpty {
                block += "\n\n\(note)"
            }
            composerText += composerText.isEmpty ? block : "\n\n\(block)"
            forwardingDraft = nil
            statusMessage = "Selection moved to the composer."
            errorMessage = nil

        case .agent(let agentID):
            guard let agent = forwardableAgents.first(where: { $0.id == agentID }) else {
                errorMessage = "That destination agent is no longer available. Choose another target or Cancel."
                return
            }
            var prompt = TerminalForwarder.prompt(
                selection: draft.selection,
                sourceAgent: draft.sourceAgentName,
                destinationAgent: agent.name
            )
            guard !prompt.isEmpty else {
                errorMessage = "The selection is empty."
                return
            }
            // Operator context is additive; TerminalForwarder's evidence warning stays intact.
            if !note.isEmpty {
                prompt += "\n\nOperator context:\n\(note)"
            }
            guard let destination = launch(agent: agent) else {
                // launch already set an honest error; keep the draft recoverable.
                return
            }
            let eventID = destination.recordPrompt(
                origin: .forwardedTerminalOutput(sourceAgentName: draft.sourceAgentName),
                text: draft.selection + (note.isEmpty ? "" : "\n\nOperator context:\n\(note)"),
                attachmentPaths: [],
                renderedPayload: prompt
            )
            destination.selectedSurface = .conversation

            let savedDraft = draft
            // Distinguish queue acceptance (clear draft) from a later async
            // delivery failure (restore if no newer draft). Sync completions
            // fire re-entrantly during deliverPrompt while isSync is true.
            var isSync = true
            var syncResult: Bool?
            destination.controller.deliverPrompt(
                prompt,
                willDeliver: { [weak destination] baseline in
                    destination?.beginAgentOutputCapture(
                        promptEventID: eventID,
                        promptText: prompt,
                        baseline: baseline
                    )
                }
            ) { [weak self] delivered in
                guard let self else { return }
                destination.updatePromptDelivery(
                    eventID: eventID,
                    to: delivered ? .delivered : .failed
                )
                if isSync {
                    syncResult = delivered
                    return
                }
                guard !delivered else { return }
                if self.forwardingDraft == nil {
                    self.forwardingDraft = savedDraft
                }
                self.errorMessage = "The forwarded output could not be delivered to \(agent.name). The staging draft has been restored."
            }
            isSync = false

            if let syncResult {
                if syncResult {
                    forwardingDraft = nil
                    statusMessage = "Forwarded selection to \(agent.name)."
                    errorMessage = nil
                } else {
                    errorMessage = "The forwarded output could not be delivered to \(agent.name)."
                }
            } else {
                // Accepted by the controller queue (pending readiness or in-flight).
                forwardingDraft = nil
                statusMessage = "Forwarding selection to \(agent.name)…"
                errorMessage = nil
            }
        }
    }

    func prepareContextBundle() {
        guard let project = selectedProject else { return }
        contextCandidates = contextBuilder.candidates(for: project)
        selectedContextIDs = Set(contextCandidates.map(\.id))
        refreshContextPreview()
        showContextBundle = true
    }

    func setContextDocument(_ document: ContextDocument, selected: Bool) {
        if selected {
            selectedContextIDs.insert(document.id)
        } else {
            selectedContextIDs.remove(document.id)
        }
        refreshContextPreview()
    }

    func refreshContextPreview() {
        let selected = contextCandidates.filter { selectedContextIDs.contains($0.id) }
        contextPreview = contextBuilder.assemble(documents: selected).markdown
    }

    func attachContextBundle() {
        guard !contextPreview.isEmpty else { return }
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".conduit/bundles", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"
            let url = directory.appendingPathComponent("context-\(formatter.string(from: Date())).md")
            try contextPreview.write(to: url, atomically: true, encoding: .utf8)
            addAttachments([url])
            showContextBundle = false
            statusMessage = "Attached \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Work sessions (event-sourced)

    func workSession(for project: MainframeProject) -> ActiveWorkSession? {
        workSessions[project.id]
    }

    func objectiveBinding(for project: MainframeProject) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.workSessions[project.id]?.objective ?? "" },
            set: { [weak self] in self?.workSessions[project.id]?.objective = $0 }
        )
    }

    func notesBinding(for project: MainframeProject) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.workSessions[project.id]?.notes ?? "" },
            set: { [weak self] in self?.workSessions[project.id]?.notes = $0 }
        )
    }

    /// Persists the current objective/notes text into the event log so a
    /// crash cannot lose committed field edits.
    func commitWorkSessionFields(for project: MainframeProject) {
        guard let work = workSessions[project.id] else { return }
        appendEvent(.objectiveChanged(text: work.objective, at: Date()), for: project)
        appendEvent(.notesChanged(text: work.notes, at: Date()), for: project)
    }

    func beginWorkSessionIfNeeded(_ project: MainframeProject) {
        guard workSessions[project.id] == nil else { return }
        let id = UUID().uuidString
        let log = WorkSessionEventLog(directory: worklogDirectory, sessionID: id)
        let objective = project.metadata.nextAction ?? ""
        let work = ActiveWorkSession(
            id: id,
            project: project,
            startedAt: Date(),
            objective: objective,
            notes: "",
            log: log
        )
        workSessions[project.id] = work
        do {
            try log.append(.started(
                sessionID: id,
                projectSlug: project.slug,
                projectTitle: project.metadata.title,
                projectPath: project.path.path,
                objective: objective,
                at: work.startedAt
            ))
        } catch {
            errorMessage = "Could not start the work session event log: \(error.localizedDescription)"
        }
    }

    func isReceiptWritePending(for projectID: String) -> Bool {
        pendingReceiptProjectIDs.contains(projectID)
    }

    func recordedReceipt(for projectID: String) -> RecordedReceiptResult? {
        recordedReceipts[projectID]
    }

    /// Removes only the matching recorded result (identity + project).
    func dismissRecordedReceipt(_ result: RecordedReceiptResult) {
        guard recordedReceipts[result.projectID]?.id == result.id else { return }
        recordedReceipts[result.projectID] = nil
    }

    /// Opens the exact URL returned by a successful write.
    func openRecordedReceipt(_ result: RecordedReceiptResult) {
        NSWorkspace.shared.open(result.url)
    }

    private func setReceiptWritePending(_ projectID: String, pending: Bool) {
        if pending {
            pendingReceiptProjectIDs.insert(projectID)
        } else {
            pendingReceiptProjectIDs.remove(projectID)
        }
    }

    func closeWorkSession(for project: MainframeProject?) {
        guard let project, let root = settings.mainframeRoot, let work = workSessions[project.id] else {
            errorMessage = "No active work session to close."
            return
        }
        appendEvent(.objectiveChanged(text: work.objective, at: Date()), for: project)
        appendEvent(.notesChanged(text: work.notes, at: Date()), for: project)
        for runtime in sessions where runtime.descriptor.projectPath == project.path {
            let controller = runtime.controller
            appendEvent(
                .terminalOutcome(
                    agent: runtime.descriptor.agent.name,
                    title: controller.terminalTitle,
                    exitCode: controller.exitCode,
                    detached: controller.isDetached,
                    live: !controller.lifecycle.isTerminal,
                    at: Date()
                ),
                for: project
            )
        }
        workSessions[project.id] = nil

        // Honest neutral pending only — never publish RECORDED from a click.
        // Clear any prior success first so a later render/write failure cannot
        // re-show a stale RECORDED reveal for this project.
        let projectID = project.id
        recordedReceipts[projectID] = nil
        setReceiptWritePending(projectID, pending: true)

        let log = work.log
        let projectPath = project.path
        let writer = receiptWriter
        Task {
            // git snapshot is blocking subprocess work — keep it off the
            // cooperative pool.
            let git = await BlockingWork.run { SystemSnapshotService.gitSummary(at: projectPath) }
            try? log.append(.gitSnapshot(summary: git, at: Date()))
            try? log.append(.closed(at: Date()))
            guard let rendered = WorkSessionReceiptRenderer.render(events: log.readEvents()) else {
                await MainActor.run { [weak self] in
                    self?.setReceiptWritePending(projectID, pending: false)
                    self?.errorMessage = "The work session event log could not be rendered into a receipt."
                }
                return
            }
            do {
                let url = try writer.write(root: root, receipt: rendered)
                log.delete()
                let recordedAt = Date()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.setReceiptWritePending(projectID, pending: false)
                    // Sole success gate: writer returned a real URL.
                    self.recordedReceipts[projectID] = RecordedReceiptResult(
                        id: UUID(),
                        projectID: projectID,
                        url: url,
                        recordedAt: recordedAt
                    )
                    self.statusMessage = "Saved session receipt to \(url.lastPathComponent)."
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.setReceiptWritePending(projectID, pending: false)
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Renders receipts for sessions interrupted by a crash or force quit.
    /// Only ever called once per process (guarded by bootstrap), and it skips
    /// any log belonging to a currently-active work session as a second guard,
    /// so a live session's log can never be mistaken for an interrupted one.
    private func recoverInterruptedWorkSessions() {
        guard let root = settings.mainframeRoot else { return }
        let activeLogs = Set(workSessions.values.map { $0.log.url.lastPathComponent })
        let logs = WorkSessionEventLog.interruptedLogs(in: worklogDirectory)
            .filter { !activeLogs.contains($0.url.lastPathComponent) }
        guard !logs.isEmpty else { return }
        let writer = receiptWriter
        Task.detached(priority: .utility) {
            var recovered = 0
            for log in logs {
                guard let rendered = WorkSessionReceiptRenderer.render(events: log.readEvents(), recovered: true) else {
                    log.delete()
                    continue
                }
                if (try? writer.write(root: root, receipt: rendered)) != nil {
                    recovered += 1
                    log.delete()
                }
            }
            if recovered > 0 {
                let count = recovered
                await MainActor.run { [weak self] in
                    self?.statusMessage = "Recovered \(count) interrupted work session receipt\(count == 1 ? "" : "s")."
                }
            }
        }
    }

    private func appendEvent(_ event: WorkSessionEvent, for project: MainframeProject) {
        guard let work = workSessions[project.id] else { return }
        do {
            try work.log.append(event)
        } catch {
            errorMessage = "Could not record a work session event: \(error.localizedDescription)"
        }
    }

    // MARK: - Health and resources

    func refreshHealth() async {
        healthResults = await healthChecker.check(
            agents: settings.agents.filter(\.enabled),
            mainframeRoot: settings.mainframeRoot
        )
    }

    func refreshResources() async {
        resourceSnapshot = await resourceService.snapshot()
    }

    func unloadOllamaModels() async {
        let failures = await resourceService.unloadOllamaModels(resourceSnapshot.ollamaModels)
        if failures.isEmpty {
            statusMessage = "Requested unload for all detected Ollama models."
        } else {
            errorMessage = failures.joined(separator: "\n")
        }
        await refreshResources()
    }

    @discardableResult
    private func rebuildMCPAdmission() -> MCPAdmissionController {
        let controller = MCPAdmissionController(
            policy: .conduitSessionAPI(
                writesEnabled: settings.enableSessionAPIWrites
            ),
            initialLiveTaskSessionIDs: Set(
                sessions
                    .filter { !$0.controller.lifecycle.isTerminal }
                    .compactMap(\.descriptor.taskSessionID)
            )
        )
        mcpAdmission = controller
        return controller
    }

    private var sessionAPIAdmission: MCPAdmissionController {
        mcpAdmission ?? rebuildMCPAdmission()
    }

    /// A fresh resource sample for one admission decision.
    ///
    /// The circuit breaker rejects stale samples, so this is measured per
    /// request rather than cached. Both sensors are pure syscalls.
    private func sessionAPIResourceSnapshot() -> ConduitResourceSnapshot {
        let now = Date()
        func measured(_ value: UInt64?) -> ConduitResourceMeasurement {
            guard let value else { return .unknown }
            return .known(value: value, observedAt: now)
        }
        // Prompts Conduit is holding for a not-yet-ready structured host are
        // real backlog. Counting only the PTY controller's depth would let a
        // caller stack holds behind a slow-starting runtime while the circuit
        // breaker read the queue as empty.
        let queued = sessions.reduce(into: UInt64(0)) { total, runtime in
            total += UInt64(max(0, runtime.controller.queuedPromptDepth))
            total += UInt64(max(0, runtime.heldPromptCount))
        }
        return ConduitResourceSnapshot(
            availablePhysicalMemoryBytes: measured(
                ConduitResourceSensors.availablePhysicalMemoryBytes()
            ),
            ownedProcessTreeRSSBytes: measured(
                ConduitResourceSensors.ownedProcessTreeRSSBytes()
            ),
            persistenceQueueCount: .unknown,
            persistenceQueueBytes: .unknown,
            promptQueueDepth: .known(value: queued, observedAt: now)
        )
    }

    private func sessionAPIAdmissionRefusal(
        _ decision: MCPAdmissionDecision
    ) -> [String: Any] {
        var admission: [String: Any] = [
            "outcome": decision.outcome.rawValue,
            "code": decision.code.rawValue,
            "detail": decision.detail,
        ]
        if let retry = decision.retryAfterSeconds {
            admission["retry_after_seconds"] = Int(retry.rounded(.up))
        }
        if !decision.resourceViolations.isEmpty {
            admission["resource_violations"] = decision.resourceViolations.map {
                violation -> [String: Any] in
                var row: [String: Any] = [
                    "metric": violation.metric.rawValue,
                    "code": violation.code.rawValue,
                    "detail": violation.detail,
                ]
                if let observed = violation.observedValue {
                    row["observed"] = NSNumber(value: observed)
                }
                if let limit = violation.limitValue {
                    row["limit"] = NSNumber(value: limit)
                }
                return row
            }
        }
        return [
            "error": "mcp admission refused",
            "admission": admission,
            "authority": "admission decision; no runtime was started, changed, or ended",
        ]
    }

    func copySessionAPIToken() {
        let token = ConduitSessionAPIServer.loadOrCreateToken()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
        statusMessage = "Session API token copied. ChatGPT still needs tunnel-client running."
    }

    func syncSessionAPI() {
        sessionAPIServer?.stop()
        sessionAPIServer = nil
        sessionAPIAddress = nil
        guard settings.enableSessionAPI else { return }
        let token = ConduitSessionAPIServer.loadOrCreateToken()
        rebuildMCPAdmission()
        let server = ConduitSessionAPIServer(
            token: token,
            allowWrites: settings.enableSessionAPIWrites
        ) { [weak self] command, caller in
            self?.sessionAPIPayload(command, caller: caller)
                ?? ["error": "Conduit is not ready."]
        }
        do {
            try server.start()
            sessionAPIServer = server
            sessionAPIAddress =
                "http://127.0.0.1:\(ConduitSessionAPI.loopbackPort)\(ConduitSessionAPI.loopbackPath)"
            statusMessage = "Session API listening on \(sessionAPIAddress ?? "")."
        } catch {
            errorMessage = "Session API failed to start: \(error.localizedDescription)"
        }
    }

    /// Serve one MCP command without letting it raise a modal on the Mac.
    ///
    /// A failure that the UI would have shown in an alert is returned to the
    /// caller instead. If the command's own payload already carries an
    /// `error`, that wording wins — it was written for this caller — and the
    /// captured alert text is offered alongside it rather than replacing it.
    private func sessionAPIPayload(
        _ command: ConduitSessionCommand,
        caller: ConduitSessionCaller = .unidentified
    ) -> [String: Any] {
        sessionAPIServingDepth += 1
        let captured = sessionAPICapturedError
        sessionAPICapturedError = nil
        var payload = sessionAPIDispatch(command, caller: caller)
        let raised = sessionAPICapturedError
        sessionAPICapturedError = captured
        sessionAPIServingDepth -= 1
        if let raised, !raised.isEmpty {
            if payload["error"] == nil {
                payload["error"] = raised
            } else if (payload["error"] as? String) != raised {
                payload["ui_error_suppressed"] = raised
            }
        }
        return payload
    }

    private func sessionAPIDispatch(
        _ command: ConduitSessionCommand,
        caller: ConduitSessionCaller = .unidentified
    ) -> [String: Any] {
        switch command {
        case .listProjects:
            return [
                "projects": projects.map { project in
                    [
                        "slug": project.slug,
                        "title": project.metadata.title,
                        "state": project.metadata.projectState ?? "",
                    ]
                }
            ]
        case .listSessions(let cursor, let limit):
            // Newest activity first. The old first-40 slice dropped whichever
            // tasks sorted late by identifier, which is arbitrary from the
            // caller's side and indistinguishable from a complete inventory.
            let ordered = taskSessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
            let window = ConduitSessionListPage.window(
                total: ordered.count,
                cursor: cursor,
                limit: limit
            )
            return [
                "sessions": ordered[window.startIndex..<window.endIndex].map {
                    task -> [String: Any] in
                    sessionAPITaskPayload(for: task)
                },
                "total": ordered.count,
                "returned": window.count,
                "has_more": window.hasMore,
                "next_cursor": window.nextCursor,
                "cursor_state": window.cursorState.rawValue,
                "order": "last_activity_desc",
                "authority": ConduitSessionListPage.authorityNote,
            ]
        case .listAdapters:
            return sessionAPIListAdapters()
        case .listProviderSessions(let provider):
            return sessionAPIListProviderSessions(provider: provider)
        case .observeWorker(let provider, let providerSessionID):
            return sessionAPIObserveWorker(
                provider: provider,
                providerSessionID: providerSessionID
            )
        case .adoptProviderSession(
            let provider,
            let providerSessionID,
            let controllerID
        ):
            return sessionAPIAdoptProviderSession(
                provider: provider,
                providerSessionID: providerSessionID,
                controllerID: controllerID
            )
        case .sessionStatus(let rawID):
            guard let uuid = UUID(uuidString: rawID),
                  let task = taskSessions.first(where: { $0.id.rawValue == uuid })
            else {
                return ["error": "unknown task"]
            }
            var payload = sessionAPITaskPayload(for: task, includeEvents: true)
            // Preserve the caller's spelling for the identifier in this
            // response while the task record remains UUID-authoritative.
            payload["taskSessionID"] = rawID
            return payload
        case .sessionEvents(let rawID, let cursor, let limit):
            return sessionAPISessionEvents(
                taskSessionID: rawID,
                cursor: cursor,
                limit: limit
            )
        case .queryMindGraph(let question, let scope):
            let askedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !askedQuestion.isEmpty else {
                return ["error": "question is empty"]
            }
            guard ConduitSessionAPI.allowsMindGraphScope(scope) else {
                return ["error": "scope must be knowledge or projects"]
            }
            guard let binary = MindGraphQuerySupport.resolveBinary(
                mainframeRoot: settings.mainframeRoot
            ) else {
                return ["error": "mindgraph binary not found"]
            }
            let parsedScope = scope == "projects"
                ? MindGraphScope.projects
                : MindGraphScope.knowledge
            let db = MindGraphQuerySupport.databaseURL(for: parsedScope)
            let result = SubprocessRunner.run(
                binary.path,
                [
                    "query", askedQuestion, "--db", db.path,
                    "--top-k", "8", "--json", "--no-intent",
                ],
                timeout: 45
            )
            // `status` used to carry the process exit code under a name that
            // reads like a result status. Separate the two, and hand back
            // parsed results instead of a log preamble glued to JSON.
            var payload: [String: Any] = [
                "scope": scope,
                "exit_code": result.status,
                "trust": "nomination only",
                "authority": "retrieval nominations; not evidence that a claim holds",
            ]
            if let json = MindGraphOutput.jsonPayload(in: result.output),
               let data = json.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               let rows = parsed as? [[String: Any]] {
                let split = MindGraphOutput.partitionByCitation(rows)
                payload["results"] = split.citable.map { MindGraphOutput.projectResult($0) }
                payload["result_count"] = split.citable.count
                payload["not_citable"] = split.notCitable.map {
                    MindGraphOutput.projectResult($0)
                }
                payload["citation_counts"] = MindGraphOutput.citationCounts(rows)
            } else {
                payload["output"] = String(result.output.prefix(8_000))
                payload["parse_error"] =
                    "MindGraph output was not a JSON array; raw output retained"
            }
            return payload
        case .createTask(let agentName, let projectSlug, let objective, let idempotencyKey):
            return sessionAPICreateTask(
                agentName: agentName,
                projectSlug: projectSlug,
                objective: objective,
                idempotencyKey: idempotencyKey,
                caller: caller
            )
        case .reconcileTask(let rawID):
            return sessionAPIReconcileTask(taskSessionID: rawID, caller: caller)
        case .sendPrompt(let rawID, let text, let origin):
            return sessionAPISendPrompt(
                taskSessionID: rawID,
                text: text,
                origin: origin,
                caller: caller
            )
        case .interrupt(let rawID):
            return sessionAPIInterrupt(taskSessionID: rawID, caller: caller)
        case .closeSession(let rawID):
            return sessionAPIClose(taskSessionID: rawID, caller: caller)
        }
    }

    private func sessionAPIListAdapters() -> [String: Any] {
        let enabled = settings.agents.filter(\.enabled)
        let profiles = enabled.map { profile -> [String: Any] in
            let backend = profile.preferredSessionBackend
            let catalog = StructuredAdapterCatalog.descriptor(matching: profile.commandBasename)
                ?? StructuredAdapterCatalog.descriptor(matching: profile.name)
            return [
                "name": profile.name,
                "command": profile.commandBasename,
                "backend": backend.workSessionLabel,
                "surface": backend.surfaceDescription,
                "structured": backend.isStructured,
                "pty_fallback": backend.isStructured,
                "status": catalog?.status ?? (backend.isStructured ? "preferred" : "pty-only"),
                "launch": catalog?.launch ?? profile.command,
                "resume": catalog?.resume ?? "",
                "notes": catalog?.notes ?? "",
            ]
        }
        return [
            "adapters": profiles,
            "authority": "declared launch surfaces; not a live health check",
        ]
    }

    private func sessionAPIListProviderSessions(
        provider: String
    ) -> [String: Any] {
        guard sessionAPINormalizedProvider(provider) == "opencode" else {
            return [
                "error": "unsupported provider",
                "provider": provider,
                "supported_providers": ["opencode"],
            ]
        }
        let coordinator = sessionAPIOpenCodeAuthorityCoordinator()

        do {
            let observations = try coordinator.listSessions { [weak self] sessionID in
                self?.sessionAPIProviderBinding(
                    providerSessionID: sessionID
                )
            }
            let encoded = observations.compactMap {
                observation -> [String: Any]? in
                guard var worker = sessionAPIWorkerLineageObject(
                    observation.worker
                ),
                let authority = sessionAPIJSONObject(observation.authority)
                else {
                    return nil
                }
                worker["provider_session_authority"] = authority
                return worker
            }
            guard encoded.count == observations.count else {
                return [
                    "error": "provider inventory could not be encoded completely",
                    "provider": "opencode",
                    "authority": "provider observation succeeded but no partial inventory is returned",
                ]
            }
            return [
                "provider": "opencode",
                "workers": encoded,
                "count": encoded.count,
                "capacity_effect": "none; no Conduit create admission or live-task reservation",
                "authority": "provider persistence observation plus Conduit's provider-session writer registry; external writer ownership remains UNKNOWN without independent provider authority",
            ]
        } catch {
            return [
                "error": error.localizedDescription,
                "provider": "opencode",
                "authority": "provider observation failed; no task/session mutation attempted",
            ]
        }
    }

    private func sessionAPIObserveWorker(
        provider: String,
        providerSessionID: String
    ) -> [String: Any] {
        guard sessionAPINormalizedProvider(provider) == "opencode" else {
            return [
                "error": "unsupported provider",
                "provider": provider,
                "supported_providers": ["opencode"],
            ]
        }
        let coordinator = sessionAPIOpenCodeAuthorityCoordinator()

        do {
            let observation = try coordinator.observeSession(
                providerSessionID: providerSessionID,
                binding: sessionAPIProviderBinding(
                    providerSessionID: providerSessionID
                )
            )
            guard var worker = sessionAPIWorkerLineageObject(
                observation.worker
            ),
            let authority = sessionAPIJSONObject(observation.authority)
            else {
                return [
                    "error": "provider observation could not be encoded",
                    "provider": "opencode",
                ]
            }
            worker["provider_session_authority"] = authority
            return [
                "provider": "opencode",
                "worker": worker,
                "capacity_effect": "none; no Conduit create admission or live-task reservation",
                "authority": "read-only provider observation plus Conduit's independent writer registry; observation itself never adopts or controls the session",
            ]
        } catch {
            return [
                "error": error.localizedDescription,
                "provider": "opencode",
                "provider_session_id": providerSessionID,
                "authority": "provider observation failed; no task/session mutation attempted",
            ]
        }
    }

    private func sessionAPIAdoptProviderSession(
        provider: String,
        providerSessionID: String,
        controllerID: String
    ) -> [String: Any] {
        guard settings.enableSessionAPIWrites else {
            return ["error": "write tools are disabled"]
        }
        guard sessionAPINormalizedProvider(provider) == "opencode" else {
            return [
                "error": "unsupported provider",
                "provider": provider,
                "supported_providers": ["opencode"],
            ]
        }
        let requestedController = controllerID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !requestedController.isEmpty else {
            return ["error": "controller_id is empty"]
        }

        let coordinator = sessionAPIOpenCodeAuthorityCoordinator()
        do {
            let result = try coordinator.adoptSession(
                providerSessionID: providerSessionID,
                controllerID: requestedController,
                binding: sessionAPIProviderBinding(
                    providerSessionID: providerSessionID
                )
            )
            guard var worker = sessionAPIWorkerLineageObject(
                result.observation.worker
            ),
            let authority = sessionAPIJSONObject(
                result.observation.authority
            ),
            let receipt = sessionAPIJSONObject(result.receipt)
            else {
                return [
                    "error": "provider authority result could not be encoded",
                    "provider": "opencode",
                    "provider_session_id": providerSessionID,
                ]
            }
            worker["provider_session_authority"] = authority

            var payload: [String: Any] = [
                "provider": "opencode",
                "provider_session_id": providerSessionID,
                "controller_id": requestedController,
                "disposition": result.receipt.disposition.rawValue,
                "worker": worker,
                "authority_receipt": receipt,
                "provider_mutation": "none",
                "capacity_effect": "none; no provider turn or execution slot is created by the authority claim",
                "workspace_authority": "separate; this claim grants no #57 worktree/workspace writer lease",
                "transfer_supported": false,
                "authority": "Conduit provider-session writer governance only; no provider prompt, resume, replacement, PTY fallback, lifecycle mutation, or workspace mutation is performed",
            ]

            if result.receipt.disposition == .writerCollision {
                let recognized = result.receipt.recognizedControllerID.value
                    ?? "another controller"
                payload["error"] =
                    "writer_collision: provider session \(providerSessionID) "
                    + "is already controlled by \(recognized); the exact "
                    + "provider session remains present and unchanged"
                payload["provider_session_exists"] = true
            }

            return payload
        } catch {
            return [
                "error": error.localizedDescription,
                "provider": "opencode",
                "provider_session_id": providerSessionID,
                "controller_id": requestedController,
                "provider_mutation": "none",
                "authority": "adoption failed before any provider mutation; no replacement session, prompt, turn, resume, or PTY fallback was attempted",
            ]
        }
    }

    private func sessionAPINormalizedProvider(_ provider: String) -> String {
        provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func sessionAPIOpenCodeObserver() -> OpenCodeProviderSessionObserver {
        // Observation reads OpenCode persistence directly from a disposable
        // SQLite snapshot. It must not resolve or launch the OpenCode CLI,
        // because provider startup may apply persistence migrations.
        let transport = OpenCodeSQLiteObservationTransport()
        return OpenCodeProviderSessionObserver(transport: transport)
    }

    private func sessionAPIOpenCodeAuthorityCoordinator()
        -> ProviderSessionAuthorityCoordinator
    {
        ProviderSessionAuthorityCoordinator(
            observer: sessionAPIOpenCodeObserver(),
            registry: .shared
        )
    }

    /// Exact provider-session correlation only.
    ///
    /// A task binding is useful lineage, but it is not evidence that Conduit is
    /// the current writer/controller. Ambiguous duplicate bindings therefore
    /// stay UNKNOWN instead of picking whichever task happens to sort first.
    private func sessionAPIProviderBinding(
        providerSessionID: String
    ) -> ProviderObservationBinding? {
        var matches: [ProviderObservationBinding] = []
        let store = AdapterThreadStore(
            directory: AdapterThreadStore.defaultDirectory()
        )

        for task in taskSessions {
            guard let profile = agentProfile(named: task.metadata.agentName),
                  profile.preferredSessionBackend == .httpServer
            else {
                continue
            }
            let live = sessionAPILiveRuntime(for: task.id)
            let threadID: String?
            if let live, live.usesStructuredHost {
                threadID = live.structuredSessionID
            } else {
                threadID = store.threadID(for: task.id)
            }
            guard threadID == providerSessionID else { continue }

            matches.append(
                ProviderObservationBinding(
                    conduitTaskID: task.id.rawValue.uuidString,
                    runtimeAttemptID: sessionAPIRuntimeAttemptID(
                        for: task,
                        live: live
                    )?.rawValue.uuidString
                )
            )
        }

        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func sessionAPIJSONObject<Value: Encodable>(
        _ value: Value
    ) -> [String: Any]? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return dictionary
    }

    private func sessionAPIWorkerLineageObject(
        _ worker: WorkerLineage
    ) -> [String: Any]? {
        sessionAPIJSONObject(worker)
    }

    private func sessionAPITaskID(_ rawID: String) -> TaskSessionID? {
        guard let uuid = UUID(uuidString: rawID) else { return nil }
        return TaskSessionID(rawValue: uuid)
    }

    private func sessionAPILiveRuntime(for id: TaskSessionID) -> TerminalRuntime? {
        sessions.first {
            $0.descriptor.taskSessionID == id
                && !$0.controller.lifecycle.isTerminal
        }
    }

    private func sessionAPIRuntimeLifecycle(
        _ lifecycle: SessionLifecycle
    ) -> String {
        switch lifecycle {
        case .idle: return "idle"
        case .launching: return "starting"
        case .running: return "running"
        case .detached: return "detached"
        case .exited: return "closed"
        }
    }

    private func sessionAPIRuntimeAttemptID(
        for task: TaskSessionSnapshot,
        live: TerminalRuntime?
    ) -> RuntimeAttemptID? {
        if let live {
            return live.runtimeAttemptID
        }
        switch task.operationalState {
        case .runtimeProvisioning(let attemptID, _, _):
            return attemptID
        case .runtimeOpened(let attemptID):
            return attemptID
        case .runtimeProvisioningFailed(let attemptID, _, _, _):
            return attemptID
        case .runtimeDetached(let attemptID):
            return attemptID
        case .interrupted(let attemptID):
            return attemptID
        case .closed, nil:
            return nil
        }
    }

    /// MCP-facing state projection. These fields deliberately keep durable
    /// registration, provisioning, runtime presence, and readiness separate.
    /// In particular, an absent runtime can never satisfy `ready` through an
    /// optional-chain default.
    private func sessionAPITaskPayload(
        for task: TaskSessionSnapshot,
        includeEvents: Bool = false
    ) -> [String: Any] {
        let live = sessionAPILiveRuntime(for: task.id)
        let isLive = live != nil
        let profile = agentProfile(named: task.metadata.agentName)
        let backend: String
        if let live {
            backend = live.usesStructuredHost
                ? (profile?.preferredSessionBackend.workSessionLabel
                    ?? AgentSessionBackend.appServer.workSessionLabel)
                : AgentSessionBackend.pty.workSessionLabel
        } else {
            backend = profile?.preferredSessionBackend.workSessionLabel ?? "unknown"
        }

        var provisioning = "unknown"
        var runtimeState = "absent"
        var lifecycle = "unknown"
        var ready = false
        var recoverable = false
        var recoveryAction: String?
        var failure: String?
        var targetSessionName: String?

        if let live {
            let controllerLifecycle = live.controller.lifecycle
            runtimeState = sessionAPIRuntimeLifecycle(controllerLifecycle)
            lifecycle = runtimeState
            let adapterReady = !live.usesStructuredHost || live.structuredIsReady
            provisioning = adapterReady ? "ready" : "starting"
            ready = isLive && adapterReady
            recoverable = false
        } else {
            switch task.operationalState {
            case .runtimeProvisioning(_, _, let tmuxSessionName):
                provisioning = "pending"
                runtimeState = "pending"
                lifecycle = "provisioning"
                recoverable = true
                recoveryAction = "conduit_reconcile_task"
                targetSessionName = tmuxSessionName
            case .runtimeProvisioningFailed(_, let tmuxSessionName, let reason, let canRecover):
                provisioning = "failed"
                runtimeState = "absent"
                lifecycle = "provisioning_failed"
                failure = reason
                recoverable = canRecover
                if canRecover {
                    recoveryAction = "conduit_reconcile_task"
                }
                targetSessionName = tmuxSessionName
            case .runtimeDetached:
                runtimeState = "detached"
                lifecycle = "detached"
                recoverable = true
                recoveryAction = "conduit_reconcile_task"
            case .interrupted:
                provisioning = "unknown"
                runtimeState = "interrupted"
                lifecycle = "interrupted"
                recoverable = true
                recoveryAction = "conduit_reconcile_task"
            case .runtimeOpened:
                runtimeState = "absent"
                lifecycle = "runtime_missing"
                recoverable = true
                recoveryAction = "conduit_reconcile_task"
            case .closed:
                runtimeState = "closed"
                lifecycle = "closed"
            case nil:
                break
            }
        }

        var payload: [String: Any] = [
            "taskSessionID": task.id.rawValue.uuidString,
            "title": task.displayTitle,
            "agent": task.metadata.agentName ?? "",
            "project": project(for: task)?.slug ?? "",
            "backend": backend,
            "durable_state": "registered",
            "provisioning_state": provisioning,
            "runtime_state": runtimeState,
            "lifecycle": lifecycle,
            "live": isLive,
            "ready": ready,
            "recoverable": recoverable,
        ]
        if let failure {
            payload["failure"] = failure
        }
        // A caller told `queued` was told not to resend. Surfacing the count
        // makes that promise observable while it is outstanding, instead of a
        // silent gap between the create response and the delivery.
        if let live, live.heldPromptCount > 0 {
            payload["prompts_held_pending_ready"] = live.heldPromptCount
        }
        // Whether close_session is reversible is a property of the backend,
        // and an orchestrator needs it before it decides to free a slot, not
        // in the response that tells it the decision was final.
        if let live {
            payload["close_outcome"] = SessionCloseSemantics.outcome(
                usesStructuredHost: live.usesStructuredHost
            ).rawValue
        }
        // Every structured client replaces a refused resume with a new, empty
        // session and then reports a healthy ready one. Saying which it is
        // turns a clean green result over lost history into something the
        // caller can branch on -- the same promise close_outcome makes about
        // the other direction.
        if let provenance = live?.structuredResumeProvenance {
            payload["thread_provenance"] = provenance.wireValue
            payload["thread_provenance_authority"] =
                SessionResumeSemantics.authority(for: provenance)
            if let continuous = provenance.historyIsContinuous {
                payload["history_is_continuous"] = continuous
            }
            if let superseded = provenance.supersededID {
                payload["superseded_thread_id"] = superseded
            }
        }
        // Durable counterpart: the live provenance goes with the runtime, but
        // a thread this task displaced stays readable after it is gone.
        if let profile, profile.preferredSessionBackend.isStructured {
            let history = AdapterThreadStore(
                directory: AdapterThreadStore.defaultDirectory()
            ).supersededThreadIDs(for: task.id)
            if !history.isEmpty {
                payload["superseded_thread_ids"] = history
            }
        }
        if let recoveryAction {
            payload["recovery_action"] = recoveryAction
        }
        if let targetSessionName {
            payload["runtime_target"] = targetSessionName
        }
        if includeEvents {
            // Fall back to the durable log the way sessionAPISessionEvents
            // already does. Reading only live or cached state meant every task
            // reported an empty history after a restart, while advertising
            // that it returns recent conversation events.
            let eventSource = live?.presentationEvents
                ?? conversationHistoryByTask[task.id]
                ?? ConversationEventLog(
                    directory: conversationDirectory,
                    taskSessionID: task.id
                ).read().events
            let events = eventSource.suffix(6).map { event in
                switch event.kind {
                case .userPrompt(let prompt):
                    return "user[\(prompt.origin.displayName)]: \(prompt.text.prefix(240))"
                case .agentOutput(let output):
                    return "agent[\(output.extraction.displayName)]: \(output.text.prefix(240))"
                case .sessionOpened:
                    return "opened[\(event.authority.displayName)]"
                case .interruptRequested:
                    return "interrupt requested[\(event.authority.displayName)]"
                }
            }
            payload["events"] = Array(events)
            payload["authority"] = "observed summaries; not verification"
        }
        return payload
    }

    private func sessionAPISessionEvents(
        taskSessionID rawID: String,
        cursor: String?,
        limit: Int?
    ) -> [String: Any] {
        guard let uuid = UUID(uuidString: rawID),
              let task = taskSessions.first(where: { $0.id.rawValue == uuid })
        else {
            return ["error": "unknown task"]
        }
        let live = sessionAPILiveRuntime(for: task.id)
        let status = sessionAPITaskPayload(for: task)
        let backend: AgentSessionBackend = {
            if live?.usesStructuredHost == true {
                return agentProfile(named: task.metadata.agentName)?.preferredSessionBackend
                    ?? .appServer
            }
            let profile = agentProfile(named: task.metadata.agentName)
            return profile?.preferredSessionBackend ?? .pty
        }()
        let adapter: ConduitSessionAdapterSnapshot? = {
            guard let live, live.usesStructuredHost else { return nil }
            return ConduitSessionAdapterSnapshot(
                threadID: live.structuredSessionID,
                turnActive: live.structuredTurnActive,
                lastTurnStatus: live.structuredLastTurnStatus,
                pendingApproval: live.structuredPendingApproval,
                pendingApprovalSummary: live.structuredPendingApprovalSummary,
                turnFailure: live.structuredTurnFailure
            )
        }()
        let persistedThreadID: String? = {
            guard live == nil, backend.isStructured else { return nil }
            return AdapterThreadStore(
                directory: AdapterThreadStore.defaultDirectory()
            ).threadID(for: task.id)
        }()
        let eventSource: [SessionPresentationEvent]
        if let live {
            eventSource = live.presentationEvents
        } else if let cached = conversationHistoryByTask[task.id], !cached.isEmpty {
            eventSource = cached
        } else {
            eventSource = ConversationEventLog(
                directory: conversationDirectory,
                taskSessionID: task.id
            ).read().events
        }
        let source = ConduitSessionEventSource(
            taskSessionID: rawID,
            backend: backend,
            sessionLifecycle: status["lifecycle"] as? String ?? "unknown",
            runtimeState: status["runtime_state"] as? String ?? "unknown",
            live: status["live"] as? Bool ?? false,
            ready: status["ready"] as? Bool ?? false,
            events: eventSource,
            adapter: adapter,
            runtimeAttemptID: sessionAPIRuntimeAttemptID(for: task, live: live),
            persistedThreadID: persistedThreadID,
            observedAt: Date()
        )
        return ConduitSessionEventExport.page(
            source: source,
            cursor: cursor,
            limit: limit
        ).jsonObject()
    }

    private func sessionAPICreateTask(
        agentName: String,
        projectSlug: String,
        objective: String,
        idempotencyKey: String?,
        caller: ConduitSessionCaller
    ) -> [String: Any] {
        // Gate, agent, and project are one decision, evaluated in ConduitCore
        // so the refusal contract and its ordering are testable without AppKit
        // (contract §18). Admission deliberately stays below: it consumes rate
        // and capacity budget, so it must not run for a request that names no
        // real agent or project.
        let precondition = CreateTaskPrecondition.evaluate(
            writesEnabled: settings.enableSessionAPIWrites,
            requestedAgent: agentName,
            among: enabledAgents,
            requestedProject: projectSlug,
            projectSlugs: projects.map(\.slug)
        )
        if let refusal = precondition.refusalPayload { return refusal }
        guard case .admitted(let resolvedAgent, let resolvedSlug) = precondition,
              let agent = enabledAgents.first(where: { $0.name == resolvedAgent }),
              let project = projects.first(where: { $0.slug == resolvedSlug })
        else {
            return ["error": "unknown or disabled agent", "agent": agentName]
        }
        // Hoisted: every return path below that could carry an objective has
        // to report its fate, including the failure paths. A response that
        // omits objective_delivery_state leaves a caller branching on it with
        // no defined case, which is the ambiguity this field exists to remove.
        let trimmed = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        let objectiveWasSupplied = !objective.isEmpty

        // Admission runs only once the request is known to name a real agent
        // and project, so a typo can never burn create-rate budget or hold a
        // capacity reservation.
        let admission = sessionAPIAdmission
        let dedupe = idempotencyKey.map { key in
            MCPCreateDedupeIdentity(
                idempotencyKey: key,
                requestFingerprint: MCPCreateDedupeIdentity.fingerprint(
                    canonicalComponents: [
                        "conduit_create_task",
                        agent.name,
                        project.slug,
                        ConduitSafetyHash.digest(
                            namespace: "mcp-create-objective",
                            text: objective
                        ),
                    ]
                )
            )
        }
        let decision = admission.admitCreate(
            callerIdentity: caller.identity,
            dedupeIdentity: dedupe,
            resources: sessionAPIResourceSnapshot()
        )
        if decision.code == .duplicateCompleted,
           let existingID = decision.taskSessionID,
           let existing = taskSessions.first(where: { $0.id == existingID }) {
            var payload = sessionAPITaskPayload(for: existing)
            payload["origin"] = ConduitSessionOrigin.chatgpt.rawValue
            payload["deduplicated"] = true
            payload["authority"] =
                "an identical create already completed; the original task is returned and no second runtime was started"
            return payload
        }
        guard decision.shouldExecute,
              let reservationID = decision.reservationID else {
            return sessionAPIAdmissionRefusal(decision)
        }
        // Any path that does not reach a started runtime gives the reserved
        // slot straight back, so a failed provision cannot leak capacity.
        var reservationCommitted = false
        defer {
            if !reservationCommitted {
                admission.cancelCreate(reservationID: reservationID)
            }
        }

        let taskID = TaskSessionID()
        guard let runtime = createTask(
            agent: agent,
            project: project,
            taskSessionID: taskID
        ) else {
            guard let task = taskSessions.first(where: { $0.id == taskID }) else {
                return [
                    "error": errorMessage ?? "create_task failed",
                    "agent": agent.name,
                    "project": project.slug,
                ]
            }
            var failedPayload = sessionAPITaskPayload(for: task)
            failedPayload["error"] = task.metadata.agentName == agent.name
                ? (failedPayload["failure"] as? String ?? errorMessage ?? "create_task failed")
                : (errorMessage ?? "create_task failed")
            failedPayload["created"] = true
            if objectiveWasSupplied {
                // Provisioning failed, so nothing was ever handed to a
                // runtime. The caller owns this objective.
                ObjectiveDeliveryReport(
                    state: .failed,
                    error: "task registered but provisioning failed; "
                        + "the objective was not delivered"
                ).apply(to: &failedPayload)
            }
            failedPayload["origin"] = ConduitSessionOrigin.chatgpt.rawValue
            failedPayload["authority"] = "task registered; provisioning failed"
            return failedPayload
        }
        // A runtime exists for this id, so the reserved slot is now genuinely
        // occupied whatever the durable reload does next.
        admission.commitCreate(reservationID: reservationID, taskSessionID: taskID)
        reservationCommitted = true
        guard let task = taskSessions.first(where: { $0.id == taskID }) else {
            var reloadFailure: [String: Any] = [
                "error": "runtime started but durable task could not be reloaded",
                "taskSessionID": taskID.rawValue.uuidString,
                "agent": agent.name,
                "project": project.slug,
            ]
            if objectiveWasSupplied {
                // The runtime exists but the objective was never passed to it.
                ObjectiveDeliveryReport(
                    state: .failed,
                    error: "durable task could not be reloaded; "
                        + "the objective was not delivered"
                ).apply(to: &reloadFailure)
            }
            return reloadFailure
        }
        var payload = sessionAPITaskPayload(for: task)
        payload["origin"] = ConduitSessionOrigin.chatgpt.rawValue
        payload["authority"] = "session created; not verification"
        guard !trimmed.isEmpty else {
            // A whitespace-only objective is discarded. Say so rather than
            // returning a task that looks like it carries an instruction.
            if objectiveWasSupplied {
                ObjectiveDeliveryReport(state: .notAttempted).apply(to: &payload)
            }
            return payload
        }
        let sent = sessionAPIDeliver(
            trimmed,
            to: runtime,
            origin: .chatgpt
        )
        // sessionAPIDeliver already distinguishes a refused objective from one
        // it accepted and will write asynchronously, but only `delivered` and
        // `error` used to be forwarded. Dropping the queued marker made a PTY
        // create indistinguishable from a structured refusal, so a caller
        // following the documented recovery re-sent an objective that was
        // already on its way and ran the work twice.
        ObjectiveDeliveryReport.from(
            delivered: sent["delivered"] as? Bool ?? false,
            delivery: sent["delivery"] as? String,
            error: sent["error"] as? String
        ).apply(to: &payload)
        return payload
    }

    private func sessionAPIReconcileTask(
        taskSessionID rawID: String,
        caller: ConduitSessionCaller
    ) -> [String: Any] {
        guard settings.enableSessionAPIWrites else {
            return ["error": "write tools are disabled"]
        }
        guard let taskID = sessionAPITaskID(rawID),
              let task = taskSessions.first(where: { $0.id == taskID })
        else {
            return ["error": "unknown task", "taskSessionID": rawID]
        }
        let reconcileDecision = sessionAPIAdmission.admitWrite(
            callerIdentity: caller.identity,
            resources: sessionAPIResourceSnapshot()
        )
        guard reconcileDecision.shouldExecute else {
            return sessionAPIAdmissionRefusal(reconcileDecision)
        }
        let requestMayProceed = ConduitSessionAPI
            .reconciliationRequestMayProceed(
                operationalState: task.operationalState,
                hasCompatibleDiscoveredRuntime:
                    reconnectableDiscoveredSession(for: task) != nil
            )
        reconcileTask(taskID)
        guard let current = taskSessions.first(where: { $0.id == taskID }) else {
            return ["error": "task disappeared during reconciliation", "taskSessionID": rawID]
        }
        var payload = sessionAPITaskPayload(for: current)
        payload["taskSessionID"] = rawID
        if sessionAPILiveRuntime(for: taskID) != nil {
            payload["reconciled"] = true
        } else if requestMayProceed {
            // History loading and tmux re-observation can be asynchronous. The
            // durable ID and explicit state remain the handoff contract.
            payload["reconcile_requested"] = true
        } else if payload["error"] == nil {
            payload["error"] = errorMessage
                ?? "No safe runtime reconciliation is available for this task"
        }
        payload["authority"] = "reconciliation requested; inspect status for observation"
        return payload
    }

    private func sessionAPISendPrompt(
        taskSessionID rawID: String,
        text: String,
        origin: ConduitSessionOrigin,
        caller: ConduitSessionCaller
    ) -> [String: Any] {
        guard settings.enableSessionAPIWrites else {
            return ["error": "write tools are disabled"]
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["error": "text is empty"]
        }
        guard let taskID = sessionAPITaskID(rawID) else {
            return ["error": "invalid taskSessionID"]
        }
        let admission = sessionAPIAdmission
        let decision = admission.admitPrompt(
            callerIdentity: caller.identity,
            taskSessionID: taskID,
            observedTaskQueueDepth: UInt64(
                max(0, sessionAPILiveRuntime(for: taskID)?
                    .controller.queuedPromptDepth ?? 0)
                    + max(0, sessionAPILiveRuntime(for: taskID)?
                        .heldPromptCount ?? 0)
            ),
            resources: sessionAPIResourceSnapshot()
        )
        guard decision.shouldExecute,
              let reservationID = decision.reservationID else {
            return sessionAPIAdmissionRefusal(decision)
        }
        // The reservation covers handing the prompt to a runtime, not the
        // agent's turn. It is released as soon as this call returns either
        // way; a queued PTY write is still tracked by the runtime's own depth.
        defer { admission.markPromptFinished(reservationID: reservationID) }

        if sessionAPILiveRuntime(for: taskID) == nil {
            reconnectTask(taskID)
        }
        guard let runtime = sessionAPILiveRuntime(for: taskID) else {
            return [
                "error": errorMessage
                    ?? "no live runtime; create a new task or reconnect in Conduit",
                "taskSessionID": rawID,
            ]
        }
        return sessionAPIDeliver(trimmed, to: runtime, origin: origin)
    }

    private func sessionAPIDeliver(
        _ text: String,
        to runtime: TerminalRuntime,
        origin: ConduitSessionOrigin
    ) -> [String: Any] {
        _ = selectSession(runtime)
        let eventID = runtime.recordPrompt(
            origin: origin.promptOrigin,
            text: text,
            attachmentPaths: [],
            renderedPayload: text
        )
        runtime.selectedSurface = .conversation
        // A structured host that has not finished starting used to refuse the
        // prompt outright and tell the caller to send it again. That made
        // create_task(objective:) undeliverable on every structured backend:
        // the runtime it had just started was necessarily still starting, so
        // the objective always came back `failed` while the host reported
        // ready seconds later. Conduit queues for a PTY already; it now does
        // the same here, and `queued` means what it has always meant — Conduit
        // owns delivery, do not resend.
        //
        // Readiness is read once, on this actor, with no suspension between
        // the check and the hold, so a host cannot become ready in the gap and
        // strand the prompt.
        if StructuredPromptHold.disposition(
            text: text,
            usesStructuredHost: runtime.usesStructuredHost,
            isReady: runtime.structuredIsReady
        ) == .hold {
            runtime.holdPromptUntilReady(eventID: eventID, text: text)
            return [
                "taskSessionID": runtime.descriptor.taskSessionID?.rawValue.uuidString ?? "",
                "delivered": false,
                "delivery": "queued",
                "backend": runtime.descriptor.agent.preferredSessionBackend.workSessionLabel,
                "origin": origin.rawValue,
                "ready": false,
                "authority": "prompt accepted before the runtime was ready; "
                    + "Conduit owns delivery and will complete it when the host "
                    + "reports ready. Do not resend. The outcome is recorded on "
                    + "the prompt event, readable through conduit_session_events.",
            ]
        }
        if runtime.structuredIsReady {
            let delivered = runtime.sendStructuredPrompt(text: text)
            runtime.updatePromptDelivery(
                eventID: eventID,
                to: delivered ? .delivered : .failed
            )
            return [
                "taskSessionID": runtime.descriptor.taskSessionID?.rawValue.uuidString ?? "",
                "delivered": delivered,
                "backend": runtime.descriptor.agent.preferredSessionBackend.workSessionLabel,
                "origin": origin.rawValue,
                "authority": "prompt recorded; not verification",
            ]
        }
        if AgentSlashCatalog.looksLikeSlashCommand(text) {
            sendSlashCommand(text, via: runtime)
            return [
                "taskSessionID": runtime.descriptor.taskSessionID?.rawValue.uuidString ?? "",
                "delivered": false,
                "delivery": "queued",
                "backend": AgentSessionBackend.pty.workSessionLabel,
                "origin": origin.rawValue,
                "authority": "slash command queued to PTY; delivery is decided asynchronously. Read conduit_session_events for the recorded delivery state.",
            ]
        }
        runtime.controller.deliverPrompt(
            text,
            willDeliver: { [weak runtime] baseline in
                runtime?.beginAgentOutputCapture(
                    promptEventID: eventID,
                    promptText: text,
                    baseline: baseline
                )
            }
        ) { [weak runtime] delivered in
            runtime?.updatePromptDelivery(
                eventID: eventID,
                to: delivered ? .delivered : .failed
            )
        }
        return [
            "taskSessionID": runtime.descriptor.taskSessionID?.rawValue.uuidString ?? "",
            // Queued, not delivered. The terminal write completes after this
            // response is serialized, and its real result is recorded on the
            // durable prompt event, which can still turn out to be `failed`.
            "delivered": false,
            "delivery": "queued",
            "backend": AgentSessionBackend.pty.workSessionLabel,
            "origin": origin.rawValue,
            "authority": "prompt queued to PTY; delivery is decided asynchronously. Read conduit_session_events for the recorded delivery state; neither value is agent completion.",
        ]
    }

    private func sessionAPIInterrupt(
        taskSessionID rawID: String,
        caller: ConduitSessionCaller
    ) -> [String: Any] {
        guard settings.enableSessionAPIWrites else {
            return ["error": "write tools are disabled"]
        }
        guard let taskID = sessionAPITaskID(rawID) else {
            return ["error": "invalid taskSessionID"]
        }
        let decision = sessionAPIAdmission.admitWrite(
            callerIdentity: caller.identity,
            resources: sessionAPIResourceSnapshot()
        )
        guard decision.shouldExecute else {
            return sessionAPIAdmissionRefusal(decision)
        }
        guard let runtime = sessionAPILiveRuntime(for: taskID) else {
            return ["error": "no live runtime to interrupt", "taskSessionID": rawID]
        }
        let interruptionEventID = runtime.recordInterruptRequest()
        if runtime.usesStructuredHost {
            runtime.interruptStructuredAdapter()
        } else {
            runtime.controller.interrupt()
        }
        return [
            "taskSessionID": rawID,
            "interrupt": "requested",
            "interrupt_event_id": interruptionEventID.uuidString,
            "interrupted": true,
            "authority": "Conduit issued and recorded an interrupt request; provider cancellation has not been observed. Read conduit_session_events for later observation.",
        ]
    }

    private func sessionAPIClose(
        taskSessionID rawID: String,
        caller: ConduitSessionCaller
    ) -> [String: Any] {
        guard settings.enableSessionAPIWrites else {
            return ["error": "write tools are disabled"]
        }
        guard let taskID = sessionAPITaskID(rawID) else {
            return ["error": "invalid taskSessionID"]
        }
        let decision = sessionAPIAdmission.admitWrite(
            callerIdentity: caller.identity,
            resources: sessionAPIResourceSnapshot()
        )
        guard decision.shouldExecute else {
            return sessionAPIAdmissionRefusal(decision)
        }
        guard let runtime = sessionAPILiveRuntime(for: taskID) else {
            return ["error": "no live runtime to close", "taskSessionID": rawID]
        }
        // Read the backend before the close: afterwards there is no live
        // runtime left to ask.
        let outcome = SessionCloseSemantics.outcome(
            usesStructuredHost: runtime.usesStructuredHost
        )
        leaveTask(taskID)
        return [
            "taskSessionID": rawID,
            "closed": true,
            "close_outcome": outcome.rawValue,
            "recoverable": !outcome.isTerminal,
            "authority": SessionCloseSemantics.authority(for: outcome),
        ]
    }

    func saveSettings() {
        Task {
            do {
                try await store.save(settings)
                statusMessage = "Settings saved."
                refreshProjects()
                await refreshHealth()
                self.syncSessionAPI()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
final class TerminalRuntime: ObservableObject, Identifiable {
    nonisolated let id: UUID
    nonisolated let runtimeAttemptID: RuntimeAttemptID
    let descriptor: SessionDescriptor
    let controller: TerminalSessionController
    @Published var selectedSurface: SessionSurface = .productDefault
    @Published private(set) var presentationEvents: [SessionPresentationEvent]
    @Published private(set) var isAwaitingAgentOutput = false
    @Published private(set) var activeOutputEventID: UUID?
    @Published private(set) var conversationCaptureNotice: String?
    @Published private(set) var appServer: CodexAppServerClient?
    @Published var pendingAppServerApproval: CodexAppServerApproval?
    @Published private(set) var grokACP: GrokACPClient?
    @Published private(set) var openCode: OpenCodeHTTPClient?
    @Published private(set) var streamJSON: StreamJSONClient?
    @Published var pendingStructuredApproval: (id: String, summary: String)?

    var usesAppServer: Bool { appServer != nil }
    var usesStructuredHost: Bool {
        appServer != nil || grokACP != nil || openCode != nil || streamJSON != nil
    }
    var structuredIsReady: Bool {
        if let appServer { return appServer.isReady }
        if let grokACP { return grokACP.isReady }
        if let openCode { return openCode.isReady }
        if let streamJSON { return streamJSON.isReady }
        return false
    }
    var structuredSessionID: String? {
        appServer?.threadID ?? grokACP?.sessionID ?? openCode?.sessionID ?? streamJSON?.sessionID
    }
    var structuredTurnActive: Bool {
        appServer?.isTurnActive == true
            || grokACP?.isTurnActive == true
            || openCode?.isTurnActive == true
            || streamJSON?.isTurnActive == true
    }
    var structuredLastTurnStatus: String? {
        appServer?.lastTurnStatus
            ?? grokACP?.lastTurnStatus
            ?? openCode?.lastTurnStatus
            ?? streamJSON?.lastTurnStatus
    }
    /// Whether the live structured session is the one the caller asked to
    /// resume, a replacement started after the provider refused, or unknown.
    ///
    /// Every client substitutes a fresh session when a resume does not take.
    /// The substitution is the right recovery and the wrong thing to report as
    /// success, so it is carried out to the caller instead of being swallowed.
    var structuredResumeProvenance: SessionResumeSemantics.Provenance? {
        appServer?.resumeProvenance
            ?? grokACP?.resumeProvenance
            ?? openCode?.resumeProvenance
            ?? streamJSON?.resumeProvenance
    }
    /// The provider's own failure signal for the live structured host.
    ///
    /// Observed 2026-09-04: OpenCode died with `ProviderModelNotFoundError`
    /// and authored nothing, while the control plane reported the turn as
    /// `structured_completed`. Every client already recorded this; nothing
    /// carried it out.
    var structuredTurnFailure: String? {
        appServer?.turnFailure
            ?? grokACP?.turnFailure
            ?? openCode?.turnFailure
            ?? streamJSON?.turnFailure
    }
    var structuredPendingApproval: Bool {
        pendingAppServerApproval != nil || pendingStructuredApproval != nil
    }
    var structuredPendingApprovalSummary: String? {
        pendingAppServerApproval?.summary
            ?? pendingStructuredApproval?.summary
            ?? grokACP?.pendingApprovalSummary
            ?? openCode?.pendingApprovalSummary
    }

    private struct ActiveOutputCapture {
        let id: UUID
        let promptEventID: UUID
        let promptText: String
        let baseline: RawDerivedSnapshot
    }

    private let recordEventRevision: ((SessionPresentationEvent) -> Void)?
    private var activeOutputCapture: ActiveOutputCapture?
    private let reductionQueue = DispatchQueue(
        label: "dev.camerontjs.conduit.raw-derived-reduction",
        qos: .userInitiated
    )
    private var reductionGeneration = 0
    private var lastAppliedReductionGeneration = 0
    private var outputSettleWorkItem: DispatchWorkItem?
    private var lastPersistedOutputAt: Date?
    private var lastPersistedOutputText = ""
    private let outputPersistenceInterval: TimeInterval = 2
    private let outputSettleInterval: TimeInterval = 1.1

    init(
        descriptor: SessionDescriptor,
        useDetachedSessions: Bool,
        entry: SessionEntry,
        runtimeAttemptID: RuntimeAttemptID = RuntimeAttemptID(),
        priorEvents: [SessionPresentationEvent] = [],
        recordEventRevision: ((SessionPresentationEvent) -> Void)? = nil
    ) {
        self.id = descriptor.id
        self.runtimeAttemptID = runtimeAttemptID
        self.descriptor = descriptor
        self.controller = TerminalSessionController(descriptor: descriptor, useDetachedSessions: useDetachedSessions)
        self.recordEventRevision = recordEventRevision
        let opening = SessionPresentation.openingEvent(entry)
        self.presentationEvents = priorEvents + [opening]
        recordEventRevision?(opening)
        controller.onRenderedOutput = { [weak self] capture in
            self?.recordRenderedOutput(capture)
        }
        controller.onTerminalBoundary = { [weak self] in
            self?.closeAgentOutputCapture()
        }
        // Direct Raw typing no longer ends capture. Surface switches and slash
        // menus stay on the same turn; process boundaries still close cleanly.
        controller.onDirectRawInput = { [weak self] in
            self?.handleDirectRawInputWhileCapturing()
        }
    }

    /// Keep capture live and pull a fresh snapshot so Conversation does not
    /// lag while the operator is in Raw.
    private func handleDirectRawInputWhileCapturing() {
        guard activeOutputCapture != nil
                || activeOutputEventID != nil
                || isAwaitingAgentOutput
        else { return }
        conversationCaptureNotice = nil
        controller.refreshConversationCapture()
    }

    /// Re-arm capture after reconnect or surface return and pull pane text that
    /// arrived while Conversation was not the focused reading surface.
    func resyncConversationCapture() {
        let hadNotice = conversationCaptureNotice != nil
        conversationCaptureNotice = nil

        if let capture = activeOutputCapture {
            controller.armConversationCapture(
                from: .available(capture.baseline)
            )
            controller.refreshConversationCapture()
            return
        }

        // Recovery: last operator prompt has no closed assistant block yet.
        // Empty same-surface baseline + prompt-anchored reduction rebuilds the
        // visible agent reply after reconnect (missed paint while detached).
        guard let lastPrompt = presentationEvents.last(where: {
            if case .userPrompt = $0.kind { return true }
            return false
        }),
        case .userPrompt(let prompt) = lastPrompt.kind
        else { return }

        let linkedOutputs = presentationEvents.compactMap { event
            -> AgentVisibleOutput? in
            guard case .agentOutput(let output) = event.kind,
                  output.promptEventID == lastPrompt.id
            else { return nil }
            return output
        }
        let hasClosedOutput = linkedOutputs.contains { $0.state == .closed }
        guard !hasClosedOutput else { return }

        let needsRecovery = hadNotice
            || isAwaitingAgentOutput
            || linkedOutputs.isEmpty
            || linkedOutputs.contains { $0.state == .live || $0.state == .settled }
        guard needsRecovery else { return }

        let liveBaseline = controller.currentCaptureBaseline()
        let emptyBaseline: RawDerivedCapture
        switch liveBaseline {
        case .available(let snap):
            emptyBaseline = .available(
                RawDerivedSnapshot(text: "", extraction: snap.extraction)
            )
        case .unavailable(let reason):
            emptyBaseline = .unavailable(reason)
        }

        beginAgentOutputCapture(
            promptEventID: lastPrompt.id,
            promptText: prompt.text,
            baseline: emptyBaseline
        )
        guard activeOutputCapture != nil || isAwaitingAgentOutput else { return }
        // Reuse the open projection card when one already exists for this prompt
        // so reconnect catch-up grows the same turn instead of duplicating it.
        if let existing = presentationEvents.last(where: { event in
            guard case .agentOutput(let output) = event.kind else { return false }
            return output.promptEventID == lastPrompt.id
        }) {
            activeOutputEventID = existing.id
            isAwaitingAgentOutput = false
        }
        // Empty same-surface arm → prompt-anchored reduction on next snapshot.
        controller.armConversationCapture(from: emptyBaseline)
        controller.refreshConversationCapture()
    }

    @discardableResult
    func recordPrompt(
        origin: PromptOrigin = .composer,
        text: String,
        attachmentPaths: [String],
        renderedPayload: String
    ) -> UUID {
        let event = SessionPresentation.promptEvent(
            origin: origin,
            text: text,
            attachmentPaths: attachmentPaths,
            renderedPayload: renderedPayload
        )
        presentationEvents.append(event)
        recordEventRevision?(event)
        return event.id
    }

    func updatePromptDelivery(
        eventID: UUID,
        to delivery: PromptDeliveryState
    ) {
        presentationEvents = SessionPresentation.updatingPromptDelivery(
            in: presentationEvents,
            eventID: eventID,
            to: delivery
        )
        if let event = presentationEvents.first(where: { $0.id == eventID }) {
            recordEventRevision?(event)
        }
        if delivery == .failed {
            closeAgentOutputCapture()
        }
    }

    @discardableResult
    func recordInterruptRequest() -> UUID {
        let event = SessionPresentation.interruptRequestEvent()
        presentationEvents.append(event)
        recordEventRevision?(event)
        return event.id
    }

    /// Opens a best-effort raw-derived block at the exact point Conduit hands
    /// the prompt to the terminal. Output before this boundary remains startup
    /// or unrelated terminal activity and is not projected as a response.
    func beginAgentOutputCapture(
        promptEventID: UUID,
        promptText: String,
        baseline: RawDerivedCapture
    ) {
        closeAgentOutputCapture()
        conversationCaptureNotice = nil
        guard case .available(let snapshot) = baseline else {
            activeOutputCapture = nil
            activeOutputEventID = nil
            isAwaitingAgentOutput = false
            let reason: String
            if case .unavailable(let detail) = baseline {
                reason = detail.displayName
            } else {
                reason = "terminal snapshot unavailable"
            }
            conversationCaptureNotice =
                "Conversation capture is unavailable for this prompt (\(reason)). Inspect Raw for the exact terminal output."
            return
        }
        activeOutputCapture = ActiveOutputCapture(
            id: UUID(),
            promptEventID: promptEventID,
            promptText: promptText,
            baseline: snapshot
        )
        activeOutputEventID = nil
        isAwaitingAgentOutput = true
        reductionGeneration += 1
        lastAppliedReductionGeneration = reductionGeneration
        lastPersistedOutputAt = nil
        lastPersistedOutputText = ""
    }

    func closeAgentOutputCapture() {
        outputSettleWorkItem?.cancel()
        outputSettleWorkItem = nil
        reductionGeneration += 1
        lastAppliedReductionGeneration = reductionGeneration
        guard let eventID = activeOutputEventID,
              let event = presentationEvents.first(where: { $0.id == eventID }),
              case .agentOutput(let output) = event.kind
        else {
            activeOutputCapture = nil
            activeOutputEventID = nil
            isAwaitingAgentOutput = false
            return
        }
        let closed = SessionPresentationEvent(
            id: event.id,
            occurredAt: event.occurredAt,
            authority: event.authority,
            kind: .agentOutput(output.withState(.closed))
        )
        presentationEvents = SessionPresentation.upsertingAgentOutput(
            in: presentationEvents,
            event: closed
        )
        recordEventRevision?(closed)
        activeOutputCapture = nil
        activeOutputEventID = nil
        isAwaitingAgentOutput = false
        lastPersistedOutputAt = nil
        lastPersistedOutputText = ""
    }

    private func recordRenderedOutput(_ observed: RawDerivedCapture) {
        guard let capture = activeOutputCapture else { return }
        switch observed {
        case .unavailable(let reason):
            closeAgentOutputCapture()
            conversationCaptureNotice =
                "Rendered output could not be separated safely from prior Raw history (\(reason.displayName)). Inspect Raw for the exact terminal output."
        case .available(let current):
            reductionGeneration += 1
            let generation = reductionGeneration
            let captureID = capture.id
            let promptText = capture.promptText
            let baseline = capture.baseline
            reductionQueue.async { [weak self] in
                let reduction = RawDerivedOutputReducer.derive(
                    baseline: baseline,
                    current: current,
                    promptText: promptText
                )
                Task { @MainActor in
                    self?.applyRenderedReduction(
                        reduction,
                        current: current,
                        captureID: captureID,
                        generation: generation
                    )
                }
            }
        }
    }

    private func applyRenderedReduction(
        _ reduction: RawDerivedOutputReduction,
        current: RawDerivedSnapshot,
        captureID: UUID,
        generation: Int
    ) {
        guard let capture = activeOutputCapture,
              capture.id == captureID,
              generation > lastAppliedReductionGeneration
        else { return }
        lastAppliedReductionGeneration = generation

        guard case .output(let derived) = reduction else {
            closeAgentOutputCapture()
            let reason: String
            if case .unavailable(let detail) = reduction {
                reason = detail.displayName
            } else {
                reason = "reduction declined"
            }
            conversationCaptureNotice =
                "Rendered output could not be separated safely from prior Raw history (\(reason)). Inspect Raw for the exact terminal output."
            return
        }
        guard !derived.text.isEmpty else { return }

        // Capture-scoped link: output was opened for this Conduit-recorded
        // prompt delivery. That is timeline association for turn grouping, not
        // a claim of a structured ACP assistant message (still derivedFromRaw).
        let linkedPromptID = capture.promptEventID
        let event: SessionPresentationEvent
        if let eventID = activeOutputEventID,
           let previous = presentationEvents.first(where: { $0.id == eventID }),
           case .agentOutput(let previousOutput) = previous.kind {
            // Keep thinking/reasoning that the TUI painted then collapsed.
            let mergedText = ConversationCaptureMerge.preservingEphemeral(
                previous: previousOutput.text,
                next: derived.text
            )
            event = SessionPresentation.agentOutputEvent(
                promptEventID: previousOutput.promptEventID ?? linkedPromptID,
                text: mergedText,
                state: .live,
                extraction: previousOutput.extraction,
                truncated: derived.truncated || previousOutput.truncated,
                id: previous.id,
                occurredAt: previous.occurredAt
            )
        } else {
            event = SessionPresentation.agentOutputEvent(
                promptEventID: linkedPromptID,
                text: derived.text,
                state: .live,
                extraction: current.extraction,
                truncated: derived.truncated
            )
        }

        presentationEvents = SessionPresentation.upsertingAgentOutput(
            in: presentationEvents,
            event: event
        )
        activeOutputEventID = event.id
        persistOutputRevisionIfNeeded(event)
        scheduleOutputSettled(eventID: event.id)
    }

    private func persistOutputRevisionIfNeeded(
        _ event: SessionPresentationEvent
    ) {
        guard case .agentOutput(let output) = event.kind else { return }
        let now = Date()
        let elapsed = lastPersistedOutputAt.map {
            now.timeIntervalSince($0)
        } ?? .infinity
        let characterDelta = abs(
            output.text.count - lastPersistedOutputText.count
        )
        guard lastPersistedOutputAt == nil
                || elapsed >= outputPersistenceInterval
                || characterDelta >= 4_096
        else { return }
        recordEventRevision?(event)
        lastPersistedOutputAt = now
        lastPersistedOutputText = output.text
    }

    private func scheduleOutputSettled(eventID: UUID) {
        outputSettleWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.markOutputSettled(eventID: eventID)
        }
        outputSettleWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + outputSettleInterval,
            execute: item
        )
    }

    private func markOutputSettled(eventID: UUID) {
        guard activeOutputEventID == eventID,
              let event = presentationEvents.first(where: { $0.id == eventID }),
              case .agentOutput(let output) = event.kind
        else { return }
        let settled = SessionPresentationEvent(
            id: event.id,
            occurredAt: event.occurredAt,
            authority: event.authority,
            kind: .agentOutput(output.withState(.settled))
        )
        presentationEvents = SessionPresentation.upsertingAgentOutput(
            in: presentationEvents,
            event: settled
        )
        recordEventRevision?(settled)
        lastPersistedOutputAt = Date()
        lastPersistedOutputText = output.text
    }

    func attachAppServer(cwd: URL, model: String?, resumeThreadID: String? = nil) {
        let client = CodexAppServerClient(
            cwd: cwd,
            model: model,
            resumeThreadID: resumeThreadID
        )
        client.onEffect = { [weak self] effect in
            self?.applyAppServerEffect(effect)
        }
        client.onFailed = { [weak self] message in
            self?.conversationCaptureNotice = message
        }
        client.onExited = { [weak self] in
            self?.controller.markAdapterExited()
        }
        client.onReady = { [weak self] in
            self?.deliverHeldPrompts()
        }
        appServer = client
    }

    func startAppServerIfNeeded() async -> String? {
        guard let appServer else { return "Codex app-server client is missing." }
        guard let executable = EnvironmentResolver.shared.resolve(
            descriptor.agent.command
        ) ?? EnvironmentResolver.shared.resolve("codex") else {
            return "codex is not on PATH."
        }
        controller.markAdapterLaunching()
        do {
            try await appServer.start(executable: executable)
            controller.markAdapterHosted()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func sendAppServerPrompt(text: String) -> Bool {
        do {
            try appServer?.sendTurn(text: text)
            return true
        } catch {
            conversationCaptureNotice = error.localizedDescription
            return false
        }
    }

    // MARK: - Held prompts

    /// A prompt Conduit accepted on behalf of a structured host that was not
    /// ready to take it yet.
    private struct HeldPrompt {
        let eventID: UUID
        let text: String
        let heldAt: Date
    }

    private var heldPrompts: [HeldPrompt] = []
    private var holdExpiry: Task<Void, Never>?

    /// How many prompts Conduit is currently holding for this runtime.
    var heldPromptCount: Int { heldPrompts.count }

    /// Take ownership of a prompt the structured host cannot accept yet.
    ///
    /// The caller is told `queued`, which in `ObjectiveDeliveryReport` means
    /// exactly this: Conduit owns delivery and the caller must not resend. The
    /// prompt event is recorded before the hold, so the promise is visible in
    /// `conduit_session_events` as a queued prompt rather than as nothing at
    /// all, and its real outcome lands on that same event.
    func holdPromptUntilReady(eventID: UUID, text: String) {
        heldPrompts.append(
            HeldPrompt(eventID: eventID, text: text, heldAt: Date())
        )
        scheduleHoldExpiry()
    }

    /// Deliver everything Conduit promised to deliver, in arrival order.
    ///
    /// Order matters: an orchestrator can create a task with an objective and
    /// send a follow-up before the host finishes starting, and the follow-up
    /// must not overtake the objective.
    func deliverHeldPrompts() {
        guard !heldPrompts.isEmpty, structuredIsReady else { return }
        let pending = heldPrompts
        heldPrompts = []
        holdExpiry?.cancel()
        holdExpiry = nil
        for prompt in pending {
            let delivered = sendStructuredPrompt(text: prompt.text)
            resolve(
                prompt,
                with: delivered
                    ? .delivered
                    : .refused(
                        "\(descriptor.agent.name) refused the prompt Conduit "
                            + "was holding for it"
                    )
            )
        }
    }

    /// Break the promise out loud.
    ///
    /// Conduit told the caller it owned delivery. If the runtime goes away
    /// first, the prompt is recorded as failed rather than left queued
    /// forever, because a caller waiting on `queued` has been told not to
    /// resend and would otherwise wait on nothing.
    func abandonHeldPrompts() {
        guard !heldPrompts.isEmpty else { return }
        let pending = heldPrompts
        heldPrompts = []
        holdExpiry?.cancel()
        holdExpiry = nil
        let resolution = StructuredPromptHold.teardownResolution(
            agentName: descriptor.agent.name
        )
        for prompt in pending { resolve(prompt, with: resolution) }
    }

    private func resolve(
        _ prompt: HeldPrompt,
        with resolution: StructuredPromptHold.Resolution
    ) {
        updatePromptDelivery(
            eventID: prompt.eventID,
            to: resolution.promptDeliveryState
        )
        if let reason = resolution.reason {
            conversationCaptureNotice = reason
        }
    }

    /// Re-arm the deadline for the oldest hold still outstanding.
    private func scheduleHoldExpiry() {
        holdExpiry?.cancel()
        guard let earliest = heldPrompts.map(\.heldAt).min() else {
            holdExpiry = nil
            return
        }
        let wait = max(
            0,
            earliest
                .addingTimeInterval(StructuredPromptHold.readinessGrace)
                .timeIntervalSinceNow
        )
        holdExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expireHeldPrompts()
        }
    }

    private func expireHeldPrompts() {
        let now = Date()
        let expired = heldPrompts.filter {
            StructuredPromptHold.hasExpired(heldAt: $0.heldAt, now: now)
        }
        guard !expired.isEmpty else {
            scheduleHoldExpiry()
            return
        }
        let expiredIDs = Set(expired.map(\.eventID))
        heldPrompts.removeAll { expiredIDs.contains($0.eventID) }
        let resolution = StructuredPromptHold.expiryResolution(
            agentName: descriptor.agent.name
        )
        for prompt in expired { resolve(prompt, with: resolution) }
        scheduleHoldExpiry()
    }

    func stopAppServer() {
        stopStructuredAdapter()
    }

    func stopStructuredAdapter() {
        // Before the clients go, anything Conduit promised to deliver has to
        // be recorded as undelivered. Otherwise a caller that was told
        // `queued` — and therefore told not to resend — waits forever.
        abandonHeldPrompts()
        appServer?.stop()
        appServer = nil
        grokACP?.stop()
        grokACP = nil
        openCode?.stop()
        openCode = nil
        streamJSON?.stop()
        streamJSON = nil
        pendingAppServerApproval = nil
        pendingStructuredApproval = nil
    }

    func respondToAppServerApproval(accept: Bool) {
        respondToStructuredApproval(accept: accept)
    }

    func respondToStructuredApproval(accept: Bool) {
        if pendingAppServerApproval != nil {
            appServer?.respondToApproval(accept: accept)
            pendingAppServerApproval = nil
            return
        }
        grokACP?.respondToApproval(accept: accept)
        openCode?.respondToApproval(accept: accept)
        streamJSON?.respondToApproval(accept: accept)
        pendingStructuredApproval = nil
    }

    func sendStructuredPrompt(text: String) -> Bool {
        if appServer != nil {
            return sendAppServerPrompt(text: text)
        }
        do {
            if let grokACP {
                try grokACP.sendTurn(text: text)
                return true
            }
            if let openCode {
                try openCode.sendTurn(text: text)
                return true
            }
            if let streamJSON {
                try streamJSON.sendTurn(text: text)
                return true
            }
            conversationCaptureNotice = "No structured adapter is attached."
            return false
        } catch {
            conversationCaptureNotice = error.localizedDescription
            return false
        }
    }

    func interruptStructuredAdapter() {
        if let appServer {
            appServer.interrupt()
            return
        }
        grokACP?.interrupt()
        openCode?.interrupt()
        streamJSON?.interrupt()
    }

    func attachStructuredAdapter(
        backend: AgentSessionBackend,
        cwd: URL,
        model: String?,
        resumeSessionID: String?
    ) {
        switch backend {
        case .appServer:
            controller.suppressProcessLaunch = true
            attachAppServer(cwd: cwd, model: model, resumeThreadID: resumeSessionID)
        case .acp:
            controller.suppressProcessLaunch = true
            controller.markAdapterLaunching()
            let command = descriptor.agent.commandBasename
            let client: GrokACPClient
            if command == "gemini" {
                var env = GrokACPClient.environmentFromDotEnv(relativePath: ".gemini/.env")
                env["GEMINI_CLI_TRUST_WORKSPACE"] = "true"
                client = GrokACPClient(
                    cwd: cwd,
                    resumeSessionID: resumeSessionID,
                    launchArguments: ["--acp"],
                    authenticateMethodID: "gemini-api-key",
                    extraEnvironment: env
                )
            } else {
                client = GrokACPClient(cwd: cwd, resumeSessionID: resumeSessionID)
            }
            wireStructured(client)
            grokACP = client
        case .httpServer:
            controller.suppressProcessLaunch = true
            controller.markAdapterLaunching()
            let client = OpenCodeHTTPClient(
                cwd: cwd,
                model: model,
                resumeSessionID: resumeSessionID
            )
            wireStructured(client)
            openCode = client
        case .structuredCli:
            controller.suppressProcessLaunch = true
            controller.markAdapterLaunching()
            let flavor = StreamJSONFlavor.from(profile: descriptor.agent) ?? .claude
            let client = StreamJSONClient(
                flavor: flavor,
                cwd: cwd,
                resumeSessionID: resumeSessionID
            )
            wireStructured(client)
            streamJSON = client
        case .pty:
            break
        }
    }

    func startStructuredAdapterIfNeeded() async -> String? {
        if appServer != nil {
            return await startAppServerIfNeeded()
        }
        controller.markAdapterLaunching()
        let backend = descriptor.agent.preferredSessionBackend
        let executableName: String
        switch backend {
        case .acp:
            executableName = descriptor.agent.command
        case .httpServer:
            executableName = descriptor.agent.command
        case .structuredCli:
            executableName = descriptor.agent.command
        default:
            return "No structured adapter for this profile."
        }
        guard let executable = EnvironmentResolver.shared.resolve(executableName)
                ?? EnvironmentResolver.shared.resolve(
                    URL(fileURLWithPath: executableName).lastPathComponent
                )
        else {
            return "\(executableName) is not on PATH."
        }
        do {
            if let grokACP {
                try await grokACP.start(executable: executable)
            } else if let openCode {
                try await openCode.start(executable: executable)
            } else if let streamJSON {
                try await streamJSON.start(executable: executable)
            } else {
                return "Structured adapter client is missing."
            }
            controller.markAdapterHosted(titleSuffix: backend.displayName)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func wireStructured(_ client: GrokACPClient) {
        client.onEffect = { [weak self] effect in
            self?.applyStructuredEffect(effect, backend: .acp)
        }
        client.onFailed = { [weak self] message in
            self?.conversationCaptureNotice = message
        }
        client.onExited = { [weak self] in
            self?.controller.markAdapterExited()
        }
        client.onReady = { [weak self] in
            self?.deliverHeldPrompts()
        }
    }

    private func wireStructured(_ client: OpenCodeHTTPClient) {
        client.onEffect = { [weak self] effect in
            self?.applyStructuredEffect(effect, backend: .httpServer)
        }
        client.onFailed = { [weak self] message in
            self?.conversationCaptureNotice = message
        }
        client.onExited = { [weak self] in
            self?.controller.markAdapterExited()
        }
        client.onReady = { [weak self] in
            self?.deliverHeldPrompts()
        }
    }

    private func wireStructured(_ client: StreamJSONClient) {
        client.onEffect = { [weak self] effect in
            self?.applyStructuredEffect(effect, backend: .structuredCli)
        }
        client.onFailed = { [weak self] message in
            self?.conversationCaptureNotice = message
        }
        client.onExited = { [weak self] in
            self?.controller.markAdapterExited()
        }
        client.onReady = { [weak self] in
            self?.deliverHeldPrompts()
        }
    }

    private func applyStructuredEffect(
        _ effect: StructuredAdapterEffect,
        backend: AgentSessionBackend
    ) {
        switch effect {
        case .sessionStarted(let id):
            if let taskID = descriptor.taskSessionID {
                AdapterThreadStore(directory: AdapterThreadStore.defaultDirectory())
                    .save(
                        taskSessionID: taskID,
                        backend: backend.workSessionLabel,
                        threadID: id
                    )
            }
        case .upsertOutput(let text, let state):
            upsertAdapterOutput(text: text, state: state)
        case .requestApproval(let id, let summary):
            pendingStructuredApproval = (id, summary)
        case .turnCompleted:
            closeAgentOutputCapture()
        case .failed(let message):
            conversationCaptureNotice = message
        }
    }

    private func applyAppServerEffect(_ effect: CodexAppServerEffect) {
        switch effect {
        case .threadStarted(let id):
            if let taskID = descriptor.taskSessionID {
                AdapterThreadStore(directory: AdapterThreadStore.defaultDirectory())
                    .save(
                        taskSessionID: taskID,
                        backend: AgentSessionBackend.appServer.workSessionLabel,
                        threadID: id
                    )
            }
        case .upsertOutput(let text, let state):
            upsertAdapterOutput(text: text, state: state)
        case .requestApproval(let approval):
            pendingAppServerApproval = approval
        case .turnCompleted:
            closeAgentOutputCapture()
        case .failed(let message):
            conversationCaptureNotice = message
        }
    }

    private func upsertAdapterOutput(text: String, state: AgentOutputState) {
        conversationCaptureNotice = nil
        let promptID = presentationEvents.last(where: {
            if case .userPrompt = $0.kind { return true }
            return false
        })?.id
        let event: SessionPresentationEvent
        if let eventID = activeOutputEventID,
           let previous = presentationEvents.first(where: { $0.id == eventID }),
           case .agentOutput(let previousOutput) = previous.kind,
           previousOutput.extraction == .structuredAdapter {
            event = SessionPresentation.agentOutputEvent(
                promptEventID: previousOutput.promptEventID ?? promptID,
                text: text,
                state: state,
                extraction: .structuredAdapter,
                truncated: previousOutput.truncated,
                id: previous.id,
                occurredAt: previous.occurredAt
            )
        } else {
            event = SessionPresentation.agentOutputEvent(
                promptEventID: promptID,
                text: text,
                state: state,
                extraction: .structuredAdapter,
                truncated: false
            )
        }
        presentationEvents = SessionPresentation.upsertingAgentOutput(
            in: presentationEvents,
            event: event
        )
        activeOutputEventID = event.id
        isAwaitingAgentOutput = state == .live
        recordEventRevision?(event)
        if state == .closed {
            activeOutputCapture = nil
            isAwaitingAgentOutput = false
        }
    }

    func ensureRemoteTUI() {
        guard let socketPath = appServer?.socketPath,
              let executable = EnvironmentResolver.shared.resolve(
                descriptor.agent.command
              ) ?? EnvironmentResolver.shared.resolve("codex")
        else { return }
        controller.attachRemoteTUI(executable: executable, socketPath: socketPath)
    }
}
#endif
