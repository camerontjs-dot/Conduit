#if os(macOS)
import SwiftUI

@main
struct ConduitApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var themeStore = ThemeStore()

    private var contextCommandTitle: String {
        model.isContextInspectorPresented ? "Hide Context Inspector" : "Show Context Inspector"
    }

    var body: some Scene {
        // A single window, not a WindowGroup: terminal NSViews are bound to one
        // window and the model is process-global, so a second window would
        // reparent live terminals and re-run bootstrap over active sessions.
        Window("Conduit", id: "main") {
            RootView()
                .environmentObject(model)
                .environmentObject(themeStore)
                .frame(minWidth: 1080, minHeight: 720)
        }
        // Size from the operator's frame / min size — not from SwiftTerm's
        // preferred cell grid, which previously "zoomed" the window on attach.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandMenu("Conduit") {
                Button("New Task…") { model.showNewTask = true }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Find Tasks") { model.requestTaskSearchFocus() }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("Browse Projects…") { model.showProjectBrowser = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                Button("Open Project Shell") { model.launchDefaultShell() }
                    .keyboardShortcut("t", modifiers: [.command])
                Menu("Launch or Reconnect Agent") {
                    ForEach(model.enabledAgents.filter { $0.kind != .shell }) { agent in
                        Button(agent.name) { model.launch(agent: agent) }
                    }
                }
                // Separate from the menu above on purpose: launching keeps
                // focusing an existing session, so opening a second one is an
                // explicit choice rather than a surprise extra tab.
                Menu("New Session For") {
                    ForEach(model.enabledAgents) { agent in
                        Button(agent.name) { model.launchAdditional(agent: agent) }
                    }
                }
                Button("Resume Session…") { model.showResumeSessions = true }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Show Conversation") {
                    model.selectedTaskRuntime?.selectedSurface = .conversation
                }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(model.selectedTaskRuntime == nil)
                Button("Show Raw Terminal") {
                    model.selectedTaskRuntime?.selectedSurface = .raw
                }
                .keyboardShortcut("2", modifiers: [.command])
                .disabled(model.selectedTaskRuntime == nil)
                Divider()
                Button(model.activeSessionForSelectedProject?.controller.usesTmux == true ? "Detach Active Session" : "Close Active Session") {
                    model.leaveActiveSession()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.activeSessionForSelectedProject == nil)
                Button("End Active Session") { model.endActiveSession() }
                    .disabled(model.activeSessionForSelectedProject == nil)
                Button("Capture to 00_inbox") { model.captureComposerToInbox() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Build Context Bundle") { model.prepareContextBundle() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Conduit Doctor") { model.showDiagnostics = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Resource Deck") { model.showResources = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Agent Usage") { model.showAgentUsage = true }
                    .keyboardShortcut("u", modifiers: [.command, .shift])
                Button("MindGraph…") { model.showMindGraph = true }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Divider()
                Button("Close Work Session & Write Receipt") { model.closeWorkSession(for: model.selectedProject) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button(contextCommandTitle) { model.toggleContextPresentation() }
                    .keyboardShortcut("\\", modifiers: [.command])
                Button("Refresh MainFrame") { model.refreshProjects() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(themeStore)
                .frame(width: 680, height: 560)
        }
    }
}
#else
@main
enum ConduitApp {
    static func main() {
        print("Conduit is a macOS application. Build and run it on macOS 13 or newer.")
    }
}
#endif
