#if os(macOS)
import SwiftUI

@main
struct ConduitApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var themeStore = ThemeStore()

    private var contextCommandTitle: String {
        if model.isContextDetailPinned {
            return "Context Inspector Pinned"
        }
        return model.isContextInspectorPresented ? "Hide Context Inspector" : "Show Context Inspector"
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
                Button("Find Project") { model.requestProjectSearchFocus() }
                    .keyboardShortcut("f", modifiers: [.command])
                Button("New Shell") { model.launchDefaultShell() }
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
                Button(model.activeSession?.controller.usesTmux == true ? "Detach Active Session" : "Close Active Session") {
                    model.leaveActiveSession()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.activeSession == nil)
                Button("End Active Session") { model.endActiveSession() }
                    .disabled(model.activeSession == nil)
                Button("Capture to 00_inbox") { model.captureComposerToInbox() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Build Context Bundle") { model.prepareContextBundle() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Conduit Doctor") { model.showDiagnostics = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Resource Deck") { model.showResources = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Divider()
                Button("Close Work Session & Write Receipt") { model.closeWorkSession(for: model.selectedProject) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Button(contextCommandTitle) { model.toggleContextPresentation() }
                    .keyboardShortcut("\\", modifiers: [.command])
                    .disabled(model.isContextDetailPinned)
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
