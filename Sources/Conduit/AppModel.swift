#if os(macOS)
import AppKit
import ConduitCore
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = ConduitSettings()
    @Published var projects: [MainframeProject] = []
    @Published var selectedProjectID: String?
    @Published var sessions: [TerminalRuntime] = []
    @Published var activeSessionID: UUID?
    @Published var composerText = ""
    @Published var attachments: [Attachment] = []
    @Published var showContext = true
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isDropTargeted = false

    @Published var showDiagnostics = false
    @Published var showResources = false
    @Published var showContextBundle = false
    @Published var healthResults: [AgentHealthResult] = []
    @Published var resourceSnapshot = ResourceSnapshot.empty
    @Published var contextCandidates: [ContextDocument] = []
    @Published var selectedContextIDs = Set<String>()
    @Published var contextPreview = ""
    @Published var activeWorkSession: ActiveWorkSession?
    @Published var workSessionObjective = ""
    @Published var workSessionNotes = ""

    let speech = SpeechTranscriber()
    private let store = SettingsStore()
    private let scanner = MainframeScanner()
    private let inboxWriter = InboxWriter()
    private let contextBuilder = ContextBundleBuilder()
    private let receiptWriter = WorkSessionReceiptWriter()
    private let healthChecker = AgentHealthChecker()
    private let resourceService = ResourceService()
    private var closedSessionOutcomes: [String: [SessionOutcome]] = [:]

    var selectedProject: MainframeProject? {
        projects.first { $0.id == selectedProjectID }
    }

    var activeSession: TerminalRuntime? {
        sessions.first { $0.id == activeSessionID }
    }

    var enabledAgents: [AgentProfile] {
        settings.agents.filter(\.enabled)
    }

    func bootstrap() async {
        settings = await store.load()
        showContext = settings.showContextByDefault
        refreshProjects()
        async let health: Void = refreshHealth()
        async let resources: Void = refreshResources()
        _ = await (health, resources)
    }

    func refreshProjects() {
        guard let root = settings.mainframeRoot else {
            projects = []
            selectedProjectID = nil
            return
        }
        do {
            projects = try scanner.scan(root: root)
            if selectedProjectID == nil || !projects.contains(where: { $0.id == selectedProjectID }) {
                selectedProjectID = projects.first?.id
            }
            statusMessage = "Loaded \(max(projects.count - 1, 0)) projects from MainFrame."
            errorMessage = nil
        } catch {
            projects = []
            errorMessage = error.localizedDescription
        }
    }

    func chooseMainframeRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choose your MainFrame root"
        panel.prompt = "Use MainFrame"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.mainframeRoot = url
            Task { try? await store.save(settings) }
            refreshProjects()
        }
    }

    func selectProject(_ project: MainframeProject) {
        selectedProjectID = project.id
        if sessionsForSelectedProject.isEmpty {
            launchDefaultShell()
        } else if let first = sessionsForSelectedProject.first {
            activeSessionID = first.id
        }
    }

    var sessionsForSelectedProject: [TerminalRuntime] {
        guard let selectedProject else { return [] }
        return sessions.filter { $0.descriptor.projectPath == selectedProject.path }
    }

    func launch(agent: AgentProfile) {
        guard let project = selectedProject else {
            errorMessage = "Choose a MainFrame project first."
            return
        }
        let descriptor = SessionDescriptor(projectPath: project.path, agent: agent)
        let runtime = TerminalRuntime(descriptor: descriptor, useDetachedSessions: settings.restoreSessions)
        sessions.append(runtime)
        activeSessionID = runtime.id
        beginWorkSessionIfNeeded(project)
    }

    func launchDefaultShell() {
        guard selectedProject != nil else { return }
        let shell = settings.agents.first(where: { $0.kind == .shell })
            ?? AgentProfile(name: "Shell", command: "/bin/zsh", arguments: ["-l"], kind: .shell)
        launch(agent: shell)
    }

    func closeSession(_ runtime: TerminalRuntime) {
        runtime.controller.closeSession()
        let outcome = SessionOutcome(
            agentName: runtime.descriptor.agent.name,
            terminalTitle: runtime.controller.terminalTitle,
            exitCode: runtime.controller.exitCode,
            detached: runtime.controller.isDetached
        )
        closedSessionOutcomes[runtime.descriptor.projectPath.path, default: []].append(outcome)
        sessions.removeAll { $0.id == runtime.id }
        if activeSessionID == runtime.id {
            activeSessionID = sessionsForSelectedProject.last?.id
        }
    }

    func sendComposer() {
        guard let activeSession else {
            launchDefaultShell()
            errorMessage = "A shell was opened. Press Send again when it is ready."
            return
        }
        let prompt = PromptAssembler.assemble(text: composerText, attachments: attachments)
        guard !prompt.isEmpty else { return }
        activeSession.controller.send(prompt + "\n")
        composerText = ""
        attachments = []
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

    func copyClipboardSelectionToComposer() {
        guard let selection = NSPasteboard.general.string(forType: .string), !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Copy terminal text first, then use this action."
            return
        }
        composerText += composerText.isEmpty ? selection : "\n\n\(selection)"
    }

    func forwardClipboardSelection(to agent: AgentProfile) {
        guard let selection = NSPasteboard.general.string(forType: .string) else {
            errorMessage = "Copy terminal text first, then forward it."
            return
        }
        let prompt = TerminalForwarder.prompt(
            selection: selection,
            sourceAgent: activeSession?.descriptor.agent.name,
            destinationAgent: agent.name
        )
        guard !prompt.isEmpty else {
            errorMessage = "The clipboard does not contain text."
            return
        }
        launch(agent: agent)
        guard let destination = activeSession else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            destination.controller.send(prompt + "\n")
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

    func beginWorkSessionIfNeeded(_ project: MainframeProject) {
        guard activeWorkSession?.project.id != project.id else { return }
        activeWorkSession = ActiveWorkSession(project: project, startedAt: Date())
        workSessionObjective = project.metadata.nextAction ?? ""
        workSessionNotes = ""
    }

    func closeWorkSession() {
        guard let root = settings.mainframeRoot, let work = activeWorkSession else {
            errorMessage = "No active work session to close."
            return
        }
        let projectSessions = sessions.filter { $0.descriptor.projectPath == work.project.path }
        let liveOutcomes = projectSessions.map {
            SessionOutcome(
                agentName: $0.descriptor.agent.name,
                terminalTitle: $0.controller.terminalTitle,
                exitCode: $0.controller.exitCode,
                detached: $0.controller.isDetached
            )
        }
        let outcomes = closedSessionOutcomes[work.project.path.path, default: []] + liveOutcomes
        let receipt = WorkSessionReceipt(
            project: work.project,
            startedAt: work.startedAt,
            objective: workSessionObjective,
            outcomes: outcomes,
            gitSummary: SystemSnapshotService.gitSummary(at: work.project.path),
            operatorNotes: workSessionNotes
        )
        do {
            let url = try receiptWriter.write(root: root, receipt: receipt)
            activeWorkSession = nil
            closedSessionOutcomes[work.project.path.path] = nil
            workSessionObjective = ""
            workSessionNotes = ""
            statusMessage = "Saved session receipt to \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

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
