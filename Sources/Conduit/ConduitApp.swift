#if os(macOS)
import SwiftUI

@main
struct ConduitApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 680)
                .task { await model.bootstrap() }
        }
        .commands {
            CommandMenu("Conduit") {
                Button("New Shell") { model.launchDefaultShell() }
                    .keyboardShortcut("t", modifiers: [.command])
                Button("Capture to 00_inbox") { model.captureComposerToInbox() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Toggle Context") { model.showContext.toggle() }
                    .keyboardShortcut("\\", modifiers: [.command])
                Button("Refresh MainFrame") { model.refreshProjects() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 620, height: 460)
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
