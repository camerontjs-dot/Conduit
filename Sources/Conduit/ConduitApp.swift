#if os(macOS)
import SwiftUI

@main
struct ConduitApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        // A single window, not a WindowGroup: terminal NSViews are bound to one
        // window and the model is process-global, so a second window would
        // reparent live terminals and re-run bootstrap over active sessions.
        Window("Conduit", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1080, minHeight: 720)
                .task { await model.bootstrap() }
        }
        // Size from the operator's frame / min size — not from SwiftTerm's
        // preferred cell grid, which previously "zoomed" the window on attach.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 840)
        .commands {
            CommandMenu("Conduit") {
                Button("New Shell") { model.launchDefaultShell() }
                    .keyboardShortcut("t", modifiers: [.command])
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
                Button("Toggle Context") { model.showContext.toggle() }
                    .keyboardShortcut("\\", modifiers: [.command])
                Button("Refresh MainFrame") { model.refreshProjects() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 680, height: 520)
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
