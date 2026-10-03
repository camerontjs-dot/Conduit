#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

@main
struct ConduitApp: App {
    @NSApplicationDelegateAdaptor(MainframeExplorerApplicationDelegate.self) private var explorerApplicationDelegate
    @StateObject private var model = AppModel()
    @StateObject private var themeStore = ThemeStore()

    private var contextCommandTitle: String {
        model.isContextInspectorPresented ? "Hide Context Inspector" : "Show Context Inspector"
    }

    var body: some Scene {
        // The primary task/runtime surface remains a single window: terminal
        // NSViews are bound there. Context IDE source windows below never host
        // RootView, bootstrap, or terminal NSViews, so they do not reparent live
        // sessions or create a second runtime authority.
        Window("Conduit", id: "main") {
            RootView()
                .environmentObject(explorerApplicationDelegate)
                .environmentObject(model)
                .environmentObject(themeStore)
                .frame(minWidth: 1080, minHeight: 720)
        }
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
                Button(
                    model.activeSessionForSelectedProject?.controller.usesTmux == true
                        ? "Detach Active Session"
                        : "Close Active Session"
                ) {
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
                Button("Attention Board…") {
                    model.showFocusBoardSheet = true
                    model.refreshFocusBoard()
                }
                Divider()
                Button("Close Work Session & Write Receipt") {
                    model.closeWorkSession(for: model.selectedProject)
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                Button(contextCommandTitle) { model.toggleContextPresentation() }
                    .keyboardShortcut("\\", modifiers: [.command])
                Menu("Inspector Cards") {
                    ForEach(InspectorCard.allCases) { card in
                        Button {
                            model.toggleInspectorCardVisibility(card)
                        } label: {
                            if model.isInspectorCardVisible(card) {
                                Text("✓ \(card.title)")
                            } else {
                                Text(card.title)
                            }
                        }
                    }
                    Divider()
                    Button("Reset Cards to Density Defaults") {
                        model.resetInspectorCardsToDensityDefaults()
                    }
                }
                Menu("Workbench View") {
                    Button {
                        model.setOperatorPeekEnabled(!model.showsOperatorPeek)
                    } label: {
                        Text(
                            model.showsOperatorPeek
                                ? "✓ Operator Peek Shelf"
                                : "Operator Peek Shelf"
                        )
                    }
                    Button("Reset Peek to Density Default") {
                        model.resetOperatorPeekToDensityDefault()
                    }
                    Divider()
                    Menu("Companion Size") {
                        ForEach(CompanionScale.allCases, id: \.self) { scale in
                            Button {
                                model.setCompanionScale(scale)
                            } label: {
                                if model.companionScale == scale {
                                    Text("✓ \(scale.displayName)")
                                } else {
                                    Text(scale.displayName)
                                }
                            }
                        }
                        Divider()
                        Button("Reset Size to Density Default") {
                            model.resetCompanionScaleToDensityDefault()
                        }
                    }
                    Button {
                        model.companionShelfEnabled.toggle()
                    } label: {
                        Text(
                            model.companionShelfEnabled
                                ? "✓ Selected Companion Shelf"
                                : "Selected Companion Shelf"
                        )
                    }
                    Button {
                        model.railSpritesForAllRows.toggle()
                    } label: {
                        Text(
                            model.railSpritesForAllRows
                                ? "✓ Sprites on All Known Rows"
                                : "Sprites on All Known Rows"
                        )
                    }
                    Divider()
                    Button {
                        model.juicyFeedbackEnabled.toggle()
                    } label: {
                        Text(
                            model.juicyFeedbackEnabled
                                ? "✓ Juicy Operator Feedback"
                                : "Juicy Operator Feedback"
                        )
                    }
                    Button {
                        model.outputActivePulseEnabled.toggle()
                    } label: {
                        Text(
                            model.outputActivePulseEnabled
                                ? "✓ Output-Active Companion Pulse"
                                : "Output-Active Companion Pulse"
                        )
                    }
                    Button {
                        model.companionChromeEnabled.toggle()
                    } label: {
                        Text(
                            model.companionChromeEnabled
                                ? "✓ Conversation Companion Bar"
                                : "Conversation Companion Bar"
                        )
                    }
                }
                Button("Refresh MainFrame") { model.refreshProjects() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            ContextIDESourceCommands(model: model)
        }

        // Auxiliary Context IDE windows are intentionally source-only. They
        // share theme/settings but never mount terminals or bootstrap a second
        // runtime surface.
        WindowGroup("Source Workbench", id: "source-workbench", for: String.self) { $path in
            if let path,
               let root = model.settings.mainframeRoot {
                let file = URL(fileURLWithPath: path).standardizedFileURL
                MainframeSourceWorkbenchView(
                    root: root,
                    file: file,
                    relativePath: ContextIDEBridge.displayPath(
                        file,
                        mainframeRoot: root
                    )
                )
                .environmentObject(explorerApplicationDelegate)
                .environmentObject(themeStore)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 34))
                    Text("No MainFrame source selected")
                        .font(.headline)
                    Text("Choose a MainFrame root and open a source file from the Context IDE menu.")
                        .foregroundStyle(.secondary)
                }
                .padding(30)
                .frame(minWidth: 620, minHeight: 420)
            }
        }
        .defaultSize(width: 1120, height: 760)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(themeStore)
                .frame(width: 680, height: 560)
        }
    }
}

private struct ContextIDESourceCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Context IDE") {
            Button("Open Source Workbench…") {
                chooseSource()
            }
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(model.settings.mainframeRoot == nil || model.rootAccessNeedsAuthorization)
        }
    }

    private func chooseSource() {
        guard let root = model.settings.mainframeRoot else { return }
        let panel = NSOpenPanel()
        panel.title = "Open MainFrame Source"
        panel.prompt = "Open in Workbench"
        panel.directoryURL = root
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let file = panel.url else { return }

        // MainframeExplorerScanner remains the real containment authority when
        // the window loads. This lexical preflight only avoids opening a utility
        // window for an obviously unrelated path selected in the panel.
        let rootPath = root.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else {
            NSSound.beep()
            return
        }
        openWindow(id: "source-workbench", value: filePath)
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
