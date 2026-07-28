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

    @Published var settings = ConduitSettings()
    @Published var projects: [MainframeProject] = []
    @Published var rootAccessNeedsAuthorization = false
    @Published var isScanningProjects = false
    @Published var selectedProjectID: String?
    @Published var sessions: [TerminalRuntime] = []
    @Published var activeSessionID: UUID?
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
    /// Focused-density temporary trailing context overlay. Closed by default.
    @Published var isContextInspectorPresented = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isDropTargeted = false

    @Published var showDiagnostics = false
    @Published var showResources = false
    @Published var showContextBundle = false
    @Published var projectSearchFocusRequest = 0
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
            // Temporary Focused overlay never carries across density changes.
            isContextInspectorPresented = false
        }
    }

    /// Balanced and Operator pin project context as the NavigationSplitView detail.
    var isContextDetailPinned: Bool {
        density != .focused
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
    private var hasBootstrapped = false
    private var scopedRootURL: URL?
    private var isUsingScopedRoot = false

    /// Load density from UserDefaults; rewrite Focused when missing or invalid.
    private static func loadPersistedDensity() -> Density {
        let raw = UserDefaults.standard.string(forKey: densityStorageKey)
        let resolved = Density.resolved(fromStored: raw)
        if raw != resolved.rawValue {
            UserDefaults.standard.set(resolved.rawValue, forKey: densityStorageKey)
        }
        return resolved
    }

    var selectedProject: MainframeProject? {
        projects.first { $0.id == selectedProjectID }
    }

    var activeSession: TerminalRuntime? {
        sessions.first { $0.id == activeSessionID }
    }

    var enabledAgents: [AgentProfile] {
        settings.agents.filter(\.enabled)
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

    func selectProject(_ project: MainframeProject) {
        selectedProjectID = project.id
        if let first = sessionsForSelectedProject.first {
            activeSessionID = first.id
        }
    }

    func requestProjectSearchFocus() {
        projectSearchFocusRequest += 1
    }

    /// Shared by WorkspaceHeader and ⌘\ . Focused toggles the temporary overlay;
    /// Balanced/Operator keep context pinned and never hide it from this control.
    func toggleContextPresentation() {
        guard !isContextDetailPinned else {
            isContextInspectorPresented = false
            return
        }
        isContextInspectorPresented.toggle()
    }

    func dismissContextInspector() {
        isContextInspectorPresented = false
    }

    var sessionsForSelectedProject: [TerminalRuntime] {
        guard let selectedProject else { return [] }
        return sessions.filter { $0.descriptor.projectPath == selectedProject.path }
    }

    @discardableResult
    func launch(agent: AgentProfile) -> TerminalRuntime? {
        guard let project = selectedProject else {
            errorMessage = "Choose a MainFrame project first."
            return nil
        }
        beginWorkSessionIfNeeded(project)

        if let existing = sessions.first(where: {
            $0.descriptor.projectPath == project.path && $0.descriptor.agent.id == agent.id
        }) {
            if existing.controller.lifecycle.isTerminal {
                // Replace a finished tab with a fresh launch of the same agent.
                closeSession(existing)
            } else {
                activeSessionID = existing.id
                statusMessage = "Focused the existing \(agent.name) session."
                return existing
            }
        }

        return start(
            descriptor: SessionDescriptor(
                projectPath: project.path,
                agent: agent,
                instance: nextInstanceNumber(for: agent, in: project)
            ),
            project: project,
            backendLabel: settings.restoreSessions ? "durable-requested" : "pty"
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
            backendLabel: settings.restoreSessions ? "durable-requested" : "pty"
        )
        statusMessage = "Opened \(agent.name) session \(instance)."
        return runtime
    }

    /// Reattaches to a durable tmux session that already exists. The tmux name
    /// comes from discovery, never re-derived, so the session that opens is the
    /// one that was listed.
    @discardableResult
    func resume(_ discovered: DiscoveredSession) -> TerminalRuntime? {
        guard let project = selectedProject else {
            errorMessage = "Choose a MainFrame project first."
            return nil
        }
        if let open = sessions.first(where: {
            $0.descriptor.tmuxSessionName == discovered.tmuxName
        }) {
            activeSessionID = open.id
            statusMessage = "That session is already open."
            return open
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
                projectPath: discovered.projectPath ?? project.path,
                agent: agent,
                title: discovered.agentName.map { "\($0) · resumed" } ?? "Unidentified · resumed",
                tmuxSessionName: discovered.tmuxName,
                recordsIdentity: discovered.isIdentified
            ),
            project: project,
            backendLabel: "durable-resumed"
        )
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
        backendLabel: String
    ) -> TerminalRuntime {
        var descriptor = descriptor
        if settings.restoreSessions && descriptor.tmuxSessionName == nil {
            descriptor.tmuxSessionName = TmuxSessionNaming.sessionName(
                projectPath: descriptor.projectPath,
                agentName: descriptor.agent.name,
                instance: descriptor.instance
            )
        }
        let runtime = TerminalRuntime(descriptor: descriptor, useDetachedSessions: settings.restoreSessions)
        runtime.controller.onUsageRecord = { [weak self] record in
            Task { @MainActor in self?.bankObservedUsage(record) }
        }
        sessions.append(runtime)
        activeSessionID = runtime.id
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

    /// Refreshes the list of durable tmux sessions. Discovery is read-only —
    /// it never creates, kills, or renames anything.
    func refreshDiscoveredSessions() async {
        guard let tmux = EnvironmentResolver.shared.resolve("tmux") else {
            discoveredSessions = []
            discoveryNote = "tmux was not found on PATH, so no durable sessions could be listed."
            return
        }
        let driver = TmuxDriver(tmuxPath: tmux)
        let outcome = await BlockingWork.run { driver.listConduitSessionsDetailed() }
        discoveredSessions = outcome.sessions
        // An empty list has several causes and they are not interchangeable:
        // no server, a failed command, or output Conduit could not parse. Say
        // which, rather than letting "none found" stand for all of them.
        if outcome.sessions.isEmpty {
            if outcome.exitStatus != 0 {
                discoveryNote = "tmux list-sessions exited \(outcome.exitStatus): \(outcome.rawOutput.prefix(200))"
            } else if !outcome.rawOutput.isEmpty {
                discoveryNote = "tmux reported sessions Conduit could not parse: \(outcome.rawOutput.prefix(200))"
            } else {
                discoveryNote = nil
            }
        } else {
            discoveryNote = nil
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
        runtime.controller.closeSession()
        recordSessionClosed(runtime, endedHard: false)
        removeSessionTab(runtime)
        if keptRunning {
            statusMessage = "Detached \(runtime.descriptor.agent.name). Choose it from Launch to reconnect."
        } else {
            statusMessage = "Closed \(runtime.descriptor.agent.name) session."
        }
    }

    func leaveActiveSession() {
        guard let activeSession else {
            statusMessage = "No active terminal session to leave."
            return
        }
        closeSession(activeSession)
    }

    func endActiveSession() {
        guard let activeSession else {
            statusMessage = "No active terminal session to end."
            return
        }
        endSession(activeSession)
    }

    /// Kill the process / tmux session and drop the tab. Next launch of that
    /// agent on this project starts fresh (no reconnect to a stuck shell).
    func endSession(_ runtime: TerminalRuntime) {
        runtime.controller.endSession()
        recordSessionClosed(runtime, endedHard: true)
        removeSessionTab(runtime)
        statusMessage = "Ended \(runtime.descriptor.agent.name) session."
    }

    /// End the current tab and immediately open a new one for the same agent.
    @discardableResult
    func restartSession(_ runtime: TerminalRuntime) -> TerminalRuntime? {
        let agent = runtime.descriptor.agent
        let projectPath = runtime.descriptor.projectPath
        endSession(runtime)
        if selectedProject?.path != projectPath,
           let project = projects.first(where: { $0.path == projectPath }) {
            selectProject(project)
        }
        return launch(agent: agent)
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
        sessions.removeAll { $0.id == runtime.id }
        if activeSessionID == runtime.id {
            activeSessionID = sessionsForSelectedProject.last?.id
        }
    }

    func sendComposer() {
        let prompt = PromptAssembler.assemble(text: composerText, attachments: attachments)
        guard !prompt.isEmpty else { return }

        let controller: TerminalSessionController
        if let activeSession {
            controller = activeSession.controller
        } else if let runtime = launchDefaultShell() {
            controller = runtime.controller
            statusMessage = "Opened a shell; the prompt will be delivered when it is ready."
        } else {
            return
        }

        let savedText = composerText
        let savedAttachments = attachments
        composerText = ""
        attachments = []
        let agentName = controller.descriptor.agent.name
        controller.deliverPrompt(prompt) { [weak self] delivered in
            guard let self, !delivered else { return }
            // Delivery failed — restore what the user typed so it is never lost,
            // unless they have already started composing something new.
            if self.composerText.isEmpty && self.attachments.isEmpty {
                self.composerText = savedText
                self.attachments = savedAttachments
            }
            self.errorMessage = "The prompt could not be delivered to \(agentName). It has been kept in the composer."
        }
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
        attachments.append(contentsOf: urls.filter { !existing.contains($0) }.map { Attachment(url: $0) })
    }

    func removeAttachment(_ attachment: Attachment) {
        attachments.removeAll { $0.id == attachment.id }
    }

    func pasteImage() {
        do {
            let url = try AttachmentService.saveImageFromPasteboard()
            addAttachments([url])
            statusMessage = "Pasted \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func captureScreen() {
        Task {
            do {
                let url = try await AttachmentService.captureScreenSelection()
                addAttachments([url])
                statusMessage = "Captured \(url.lastPathComponent)."
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
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
        let sourceName = activeSession?.descriptor.agent.name
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

            let savedDraft = draft
            // Distinguish queue acceptance (clear draft) from a later async
            // delivery failure (restore if no newer draft). Sync completions
            // fire re-entrantly during deliverPrompt while isSync is true.
            var isSync = true
            var syncResult: Bool?
            destination.controller.deliverPrompt(prompt) { [weak self] delivered in
                guard let self else { return }
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
        healthResults = await healthChecker.check(agents: settings.agents, mainframeRoot: settings.mainframeRoot)
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
    let descriptor: SessionDescriptor
    let controller: TerminalSessionController

    init(descriptor: SessionDescriptor, useDetachedSessions: Bool) {
        self.id = descriptor.id
        self.descriptor = descriptor
        self.controller = TerminalSessionController(descriptor: descriptor, useDetachedSessions: useDetachedSessions)
    }
}
#endif
