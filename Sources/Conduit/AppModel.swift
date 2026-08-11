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

/// What Conduit can honestly claim about one task's local conversation file.
///
/// This is presentation/control state only. It never upgrades rendered terminal
/// prose into verification or MainFrame project truth.
enum ConversationRetentionState: Equatable, Sendable {
    case legacyPreRetention
    case loading
    case pending
    case persisted
    case missingExpected
    case failed(String)
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

    @Published var settings = ConduitSettings()
    @Published var projects: [MainframeProject] = []
    @Published var rootAccessNeedsAuthorization = false
    @Published var isScanningProjects = false
    @Published var selectedProjectID: String?
    @Published var sessions: [TerminalRuntime] = []
    @Published var activeSessionID: UUID?
    /// Durable, metadata-only task histories. MainFrame's current project scan
    /// remains authoritative for project names, paths, and lifecycle state.
    @Published private(set) var taskSessions: [TaskSessionSnapshot] = []
    @Published var selectedTaskSessionID: TaskSessionID?
    @Published var taskSearchText = ""
    @Published var showArchivedTasks = false
    /// Nil means all task histories under the selected MainFrame root.
    @Published var taskScopeProjectID: String?
    @Published var showNewTask = false
    @Published var showProjectBrowser = false
    @Published private(set) var taskSessionDiagnostics: [TaskSessionEventLogDiagnostic] = []
    /// Source-labelled conversation content retained separately from task
    /// metadata. MainFrame files and work-session receipts remain independent.
    @Published private(set) var conversationHistoryByTask:
        [TaskSessionID: [SessionPresentationEvent]] = [:]
    @Published private(set) var conversationHistoryDiagnostics:
        [TaskSessionID: [ConversationEventLogDiagnostic]] = [:]
    @Published private(set) var conversationRetentionStateByTask:
        [TaskSessionID: ConversationRetentionState] = [:]
    @Published private(set) var taskReconnectabilityObservation: ExternalReconnectabilityObservation = .notChecked
    /// Completed observed-usage records for this root, loaded from the log at
    /// bootstrap and appended to as sessions end.
    @Published private(set) var completedUsage: [SessionUsageRecord] = []
    /// Durable tmux sessions found on the server, refreshed on demand.
    @Published private(set) var discoveredSessions: [DiscoveredSession] = []
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
    @Published var errorMessage: String?
    @Published var isDropTargeted = false

    @Published var showDiagnostics = false
    @Published var showResources = false
    @Published var showAgentUsage = false
    @Published var showMindGraph = false
    @Published var showContextBundle = false
    /// Account-reported usage (Claude / Codex / OpenCode). Separate from Tier A.
    @Published private(set) var accountUsage: [AccountUsageSnapshot] = []
    @Published private(set) var accountUsageRefreshing = false
    @Published private(set) var accountUsageError: String?
    /// Lazy, CLI-owned model catalogs keyed by saved profile identity.
    @Published private(set) var modelOptionsByAgentID: [UUID: [AgentModelOption]] = [:]
    @Published private(set) var modelCatalogRefreshingAgentIDs: Set<UUID> = []
    @Published var taskSearchFocusRequest = 0
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
        }
    }

    func resetCompanionScaleToDensityDefault() {
        companionScaleCustomized = false
        UserDefaults.standard.set(false, forKey: Self.companionScaleCustomizedKey)
        companionScaleStored = CompanionScale.defaultFor(density: density)
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
        var map: [InspectorCard: Bool] = [:]
        for card in InspectorCard.allCases {
            map[card] = raw[card.rawValue] ?? true
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
        let rootURL = settings.mainframeRoot
        let baseRows = SessionCatalog.rows(
            sessions: taskSessions,
            availabilityContext: taskAvailabilityContext,
            query: TaskSessionCatalogQuery(
                workspaceRootURL: rootURL,
                searchText: taskSearchText,
                includeArchived: showArchivedTasks
            )
        )
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
        case .liveSlash(let command):
            if let runtime = liveRuntime {
                runtime.controller.injectSlashCommand(command)
                statusMessage =
                    "\(agent.name): sent \(command) to the live session. Confirm in Raw if the TUI accepted it."
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

    /// Pull Claude OAuth, Codex app-server, and OpenCode DB account usage.
    func refreshAccountUsage() {
        guard !accountUsageRefreshing else { return }
        accountUsageRefreshing = true
        accountUsageError = nil
        Task { @MainActor in
            let snaps = await AccountUsageService.refreshAll()
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
        conversationRetentionStateByTask[taskSessionID] = .loading
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
                    self.conversationRetentionStateByTask[taskSessionID] =
                        .failed("The local conversation file could not be read.")
                } else if result.fileWasPresent {
                    self.conversationRetentionStateByTask[taskSessionID] =
                        .persisted
                } else if retentionWasExpected {
                    self.conversationRetentionStateByTask[taskSessionID] =
                        .missingExpected
                } else {
                    self.conversationRetentionStateByTask[taskSessionID] =
                        .legacyPreRetention
                }
            }
        }
    }

    private func recordConversationRevision(
        _ event: SessionPresentationEvent,
        taskSessionID: TaskSessionID
    ) {
        conversationRetentionStateByTask[taskSessionID] = .pending
        conversationPersistence.append(
            event,
            taskSessionID: taskSessionID
        ) { [weak self] errorDescription in
            Task { @MainActor in
                guard let self else { return }
                if let errorDescription {
                    self.conversationRetentionStateByTask[taskSessionID] =
                        .failed(errorDescription)
                    self.errorMessage =
                        "Conversation is visible but could not be retained locally: \(errorDescription)"
                    return
                }

                self.conversationRetentionStateByTask[taskSessionID] =
                    .persisted
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
    func createTask(agent: AgentProfile, project: MainframeProject) -> TerminalRuntime? {
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
        let runtime = start(
            descriptor: SessionDescriptor(
                projectPath: scannedProject.path,
                agent: agent,
                instance: instance
            ),
            project: scannedProject,
            backendLabel: settings.restoreSessions ? "durable-requested" : "pty",
            entry: .started(
                agentName: agent.name,
                requestedBackend: settings.restoreSessions
                    ? "durable tmux, with PTY fallback"
                    : "direct PTY"
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
        guard let task = taskSessions.first(where: { $0.id == id }),
              let discovered = reconnectableDiscoveredSession(for: task)
        else {
            errorMessage = "No identity-compatible tmux runtime was observed for this task. Refresh discovery or inspect the recovery details."
            return
        }
        let explicitProject = project(for: task)
        _ = resume(discovered, adoptingInto: explicitProject)
    }

    func leaveTask(_ id: TaskSessionID) {
        guard let runtime = sessions.first(where: {
            $0.descriptor.taskSessionID == id
                && !$0.controller.lifecycle.isTerminal
        }) else {
            statusMessage = "This task has no open runtime to leave."
            return
        }
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
        endSession(runtime)
    }

    private func taskCatalogRow(id: TaskSessionID) -> TaskSessionCatalogRow? {
        SessionCatalog.rows(
            sessions: taskSessions,
            availabilityContext: taskAvailabilityContext,
            query: TaskSessionCatalogQuery(includeArchived: true)
        ).first { $0.id == id }
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
        if let durable = discoveredSessions.first(where: { discovered in
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

        return start(
            descriptor: SessionDescriptor(
                projectPath: project.path,
                agent: agent,
                instance: nextInstanceNumber(for: agent, in: project)
            ),
            project: project,
            backendLabel: settings.restoreSessions ? "durable-requested" : "pty",
            entry: .started(
                agentName: agent.name,
                requestedBackend: settings.restoreSessions ? "durable tmux, with PTY fallback" : "direct PTY"
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
        let runtime = start(
            descriptor: SessionDescriptor(
                projectPath: project.path,
                agent: agent,
                instance: instance
            ),
            project: project,
            backendLabel: settings.restoreSessions ? "durable-requested" : "pty",
            entry: .started(
                agentName: agent.name,
                requestedBackend: settings.restoreSessions ? "durable tmux, with PTY fallback" : "direct PTY"
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
        let useDurableSession = settings.restoreSessions
            || requiresDurableSession
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
            loadConversationHistory(for: taskSessionID)
            statusMessage =
                "Loading this task's local conversation history. Reconnect again after it appears."
            return nil
        }
        descriptor.taskSessionID = taskSessionID
        let runtimeAttemptID = RuntimeAttemptID()
        guard appendTaskEvent(
            TaskSessionEvent(
                taskSessionID: taskSessionID,
                authority: .conduitRecorded,
                kind: .operationalStateChanged(.runtimeOpened(runtimeAttemptID))
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
        if case .resumed = entry {
            Task { @MainActor [weak runtime] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                runtime?.controller.startIfNeeded()
                runtime?.resyncConversationCapture()
            }
        }
        // The terminal used to start only when its SwiftTerm view appeared.
        // Conversation is now the default, so process ownership must not depend
        // on mounting the Raw surface.
        runtime.controller.startIfNeeded()
        if let issue = runtime.controller.launchIssue {
            _ = appendTaskEvent(
                TaskSessionEvent(
                    taskSessionID: taskSessionID,
                    authority: .processObserved,
                    kind: .operationalStateChanged(
                        .interrupted(runtimeAttemptID)
                    )
                )
            )
            errorMessage = issue.localizedDescription
            removeSessionTab(runtime)
            return nil
        }
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

    /// A successful tmux observation plus the absence of an in-process runtime
    /// lets Conduit record that a previously-open attempt was interrupted.
    /// Failed discovery remains unknown and never becomes negative evidence.
    private func reconcileInterruptedTaskSessions() {
        let liveTaskIDs = Set(sessions.compactMap(\.descriptor.taskSessionID))
        // A malformed binding could belong to any prior attempt. Until it is
        // repaired or reviewed, absence is not safe negative evidence.
        guard !discoveredSessions.contains(where: {
            if case .malformed = $0.taskSessionBinding { return true }
            return false
        }) else { return }
        let candidates = taskSessions.compactMap { task -> (TaskSessionID, RuntimeAttemptID)? in
            guard !liveTaskIDs.contains(task.id),
                  case .runtimeOpened(let attempt)? = task.operationalState
            else { return nil }
            return (task.id, attempt)
        }
        for (taskID, attemptID) in candidates {
            _ = appendTaskEvent(
                TaskSessionEvent(
                    taskSessionID: taskID,
                    authority: .processObserved,
                    kind: .operationalStateChanged(.interrupted(attemptID))
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
        if savedAttachments.isEmpty,
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

    func saveSettings() {
        Task {
            do {
                try await store.save(settings)
                statusMessage = "Settings saved."
                refreshProjects()
                await refreshHealth()
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
            event = SessionPresentation.agentOutputEvent(
                promptEventID: previousOutput.promptEventID ?? linkedPromptID,
                text: derived.text,
                state: .live,
                extraction: previousOutput.extraction,
                truncated: derived.truncated,
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
}
#endif
