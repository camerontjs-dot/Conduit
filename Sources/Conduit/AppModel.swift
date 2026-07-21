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

    let speech = SpeechTranscriber()
    private let store = SettingsStore()
    private let scanner = MainframeScanner()
    private let inboxWriter = InboxWriter()

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
        let runtime = TerminalRuntime(descriptor: descriptor)
        sessions.append(runtime)
        activeSessionID = runtime.id
    }

    func launchDefaultShell() {
        guard selectedProject != nil else { return }
        let shell = settings.agents.first(where: { $0.kind == .shell })
            ?? AgentProfile(name: "Shell", command: "/bin/zsh", arguments: ["-l"], kind: .shell)
        launch(agent: shell)
    }

    func closeSession(_ runtime: TerminalRuntime) {
        runtime.controller.terminate()
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
        attachments.append(contentsOf: urls.filter { !existing.contains($0) }.map(Attachment.init(url:)))
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

    func saveSettings() {
        Task {
            do {
                try await store.save(settings)
                statusMessage = "Settings saved."
                refreshProjects()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

@MainActor
final class TerminalRuntime: ObservableObject, Identifiable {
    let descriptor: SessionDescriptor
    let controller: TerminalSessionController
    var id: UUID { descriptor.id }

    init(descriptor: SessionDescriptor) {
        self.descriptor = descriptor
        self.controller = TerminalSessionController(descriptor: descriptor)
    }
}
#endif
