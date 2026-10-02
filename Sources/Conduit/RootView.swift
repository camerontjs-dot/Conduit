#if os(macOS)
import ConduitCore
import SwiftUI
import UniformTypeIdentifiers

/// Conduit's default shell is the conversation canvas.
///
/// Tasks and Inspector are secondary presentation surfaces. They overlay the
/// conversation by default and shrink it only when the operator explicitly pins
/// them and enough room remains. Runtime/session identity lives below this shell
/// and is never recreated by opening or closing chrome.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @StateObject private var explorerModel = MainframeExplorerWorkspaceModel()
    @State private var isTaskDrawerPresented = false
    @State private var inspectorFocusRequest = 0

    @AppStorage("conduit.taskDrawerPinned") private var taskDrawerPinned = false
    @AppStorage("conduit.inspectorPinned") private var inspectorPinned = false
    @AppStorage("conduit.taskDrawerWidth") private var storedTaskDrawerWidth = 304.0
    @AppStorage("conduit.inspectorWidth") private var storedInspectorWidth = 360.0

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ConversationRootShellPolicy.resolve(
                windowWidth: proxy.size.width,
                taskDrawerPresented: isTaskDrawerPresented,
                taskDrawerPinned: taskDrawerPinned,
                inspectorPresented: model.isContextInspectorPresented,
                inspectorPinned: inspectorPinned,
                preferredTaskDrawerWidth: storedTaskDrawerWidth,
                preferredInspectorWidth: storedInspectorWidth
            )

            conversationRoot(geometry: geometry)
        }
        .tint(palette.accent)
        .background(palette.app)
        .background(MainframeExplorerWindowCloseGuard(explorer: explorerModel).frame(width: 0, height: 0))
        .conduitSurfaceChrome(
            finish: themeStore.surfaceFinish,
            colorScheme: colorScheme
        )
        .toolbar { conversationToolbar }
        .alert(
            "Conduit",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $model.showDiagnostics) {
            DiagnosticsView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showResources) {
            ResourcePanelView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showAgentUsage) {
            AgentUsageSheet()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showMindGraph) {
            MindGraphQueryView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showFocusBoardSheet) {
            FocusBoardSheet()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showContextBundle) {
            ContextBundleView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showResumeSessions) {
            ResumeSessionsSheet()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showNewTask) {
            NewTaskView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showProjectBrowser) {
            ProjectScopeBrowser()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .sheet(isPresented: $model.showSettingsSheet) {
            NavigationStack {
                SettingsView()
                    .environmentObject(model)
                    .environmentObject(themeStore)
                    .frame(minWidth: 640, minHeight: 520)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { model.showSettingsSheet = false }
                        }
                    }
            }
            .frame(width: 700, height: 580)
        }
        .onChange(of: model.speech.isRecording) { recording in
            if !recording { model.absorbSpeechTranscript() }
        }
        .onChange(of: model.taskSearchFocusRequest) { _ in
            withPanelAnimation {
                isTaskDrawerPresented = true
            }
        }
        .onChange(of: model.isContextInspectorPresented) { presented in
            if presented {
                inspectorFocusRequest += 1
            }
        }
        .task {
            await Task.yield()
            await model.bootstrap()
        }
    }

    // MARK: - Conversation-root composition

    private func conversationRoot(
        geometry: ConversationRootShellGeometry
    ) -> some View {
        workspaceColumn
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, CGFloat(geometry.contentLeadingInset))
            .padding(.trailing, CGFloat(geometry.contentTrailingInset))
            .overlay(alignment: .leading) {
                if geometry.taskDrawer != .hidden {
                    taskDrawer(geometry: geometry)
                        .transition(
                            reduceMotion
                                ? .identity
                                : .move(edge: .leading).combined(with: .opacity)
                        )
                        .zIndex(3)
                }
            }
            .overlay(alignment: .trailing) {
                if geometry.inspector != .hidden {
                    inspectorPanel(geometry: geometry)
                        .transition(
                            reduceMotion
                                ? .identity
                                : .move(edge: .trailing).combined(with: .opacity)
                        )
                        .zIndex(2)
                }
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: geometry
            )
    }

    private func taskDrawer(
        geometry: ConversationRootShellGeometry
    ) -> some View {
        VStack(spacing: 0) {
            secondaryPanelHeader(
                title: model.workspace == .explore ? "Files" : "Tasks",
                systemImage: model.workspace == .explore ? "folder" : "sidebar.left",
                isPinned: taskDrawerPinned,
                effectivePlacement: geometry.taskDrawer,
                onTogglePin: { taskDrawerPinned.toggle() },
                onClose: { isTaskDrawerPresented = false }
            )

            Divider().overlay(palette.line)

            sidebar
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: CGFloat(geometry.taskDrawerWidth))
        .frame(maxHeight: .infinity)
        .background(
            ConduitFinishedFill(
                base: palette.rail,
                finish: themeStore.surfaceFinish,
                colorScheme: colorScheme
            )
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(palette.line)
                .frame(width: 1)
                .accessibilityHidden(true)
        }
        .shadow(
            color: geometry.taskDrawer == .overlay
                ? Color.black.opacity(0.30)
                : .clear,
            radius: 18,
            x: 7,
            y: 0
        )
        .onExitCommand {
            isTaskDrawerPresented = false
        }
    }

    private func inspectorPanel(
        geometry: ConversationRootShellGeometry
    ) -> some View {
        VStack(spacing: 0) {
            secondaryPanelHeader(
                title: "Inspector",
                systemImage: "sidebar.right",
                isPinned: inspectorPinned,
                effectivePlacement: geometry.inspector,
                onTogglePin: { inspectorPinned.toggle() },
                onClose: { model.dismissContextInspector() }
            )

            Divider().overlay(palette.line)

            InspectorView(
                project: model.selectedTaskProject ?? model.selectedProject,
                showsCloseButton: false,
                focusRequest: inspectorFocusRequest,
                onClose: { model.dismissContextInspector() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: CGFloat(geometry.inspectorWidth))
        .frame(maxHeight: .infinity)
        .background(
            ConduitFinishedFill(
                base: palette.surface,
                finish: themeStore.surfaceFinish,
                colorScheme: colorScheme
            )
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.line)
                .frame(width: 1)
                .accessibilityHidden(true)
        }
        .shadow(
            color: geometry.inspector == .overlay
                ? Color.black.opacity(0.30)
                : .clear,
            radius: 18,
            x: -7,
            y: 0
        )
        .onExitCommand {
            model.dismissContextInspector()
        }
    }

    private func secondaryPanelHeader(
        title: String,
        systemImage: String,
        isPinned: Bool,
        effectivePlacement: ConversationRootPanelPlacement,
        onTogglePin: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.text)
            Spacer(minLength: 8)
            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(
                effectivePlacement == .pinned
                    ? "Unpin \(title)"
                    : "Pin \(title) when the window has room"
            )
            .accessibilityLabel(isPinned ? "Unpin \(title)" : "Pin \(title)")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close \(title)")
            .accessibilityLabel("Close \(title)")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(palette.surface.opacity(0.92))
    }

    // MARK: - Primary canvas

    @ViewBuilder
    private var workspaceColumn: some View {
        if model.settings.mainframeRoot == nil {
            onboarding
        } else if model.rootAccessNeedsAuthorization {
            rootAuthorization
        } else if model.workspace == .orchestrate {
            OrchestrateWorkspaceView()
                .environmentObject(model)
                .environmentObject(themeStore)
        } else if model.workspace == .explore,
                  let root = model.settings.mainframeRoot {
            MainframeExplorerWorkspaceView(root: root, explorer: explorerModel)
                .environmentObject(themeStore)
        } else {
            conversationCanvas
        }
    }

    private var conversationCanvas: some View {
        SessionSurfaceView(runtime: model.selectedTaskRuntime)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.sink)
            .onDrop(
                of: [UTType.fileURL.identifier],
                isTargeted: $model.isDropTargeted,
                perform: handleFileDrop
            )
            .overlay {
                if model.isDropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            palette.accent,
                            style: StrokeStyle(lineWidth: 3, dash: [8])
                        )
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard model.selectedTaskProject != nil || model.selectedProject != nil else {
            return false
        }
        for provider in providers {
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                if let url {
                    Task { @MainActor in
                        model.addAttachments([url])
                    }
                }
            }
        }
        return !providers.isEmpty
    }

    @ViewBuilder
    private var sidebar: some View {
        if model.workspace == .explore,
           let root = model.settings.mainframeRoot,
           !model.rootAccessNeedsAuthorization {
            MainframeExplorerSidebarView(root: root, explorer: explorerModel)
                .environmentObject(themeStore)
        } else {
            TaskSidebarView(
                model: model,
                sidebarModel: model.taskSidebarModel
            )
        }
    }

    // MARK: - Minimal window chrome

    @ToolbarContentBuilder
    private var conversationToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button {
                withPanelAnimation {
                    isTaskDrawerPresented.toggle()
                }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .help(isTaskDrawerPresented ? "Hide tasks" : "Show tasks")
            .accessibilityLabel(isTaskDrawerPresented ? "Hide tasks" : "Show tasks")
        }

        ToolbarItem(placement: .principal) {
            Text(toolbarTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(toolbarTitle)
        }

        ToolbarItem(placement: .automatic) {
            Button {
                model.showNewTask = true
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New task")
            .accessibilityLabel("New task")
        }

        ToolbarItem(placement: .automatic) {
            toolsMenu
        }

        ToolbarItem(placement: .automatic) {
            Button {
                model.toggleContextPresentation()
            } label: {
                Image(
                    systemName: model.isContextInspectorPresented
                        ? "sidebar.right"
                        : "rectangle.righthalf.inset.filled"
                )
            }
            .help(
                model.isContextInspectorPresented
                    ? "Hide Inspector"
                    : "Show Inspector"
            )
            .accessibilityLabel(
                model.isContextInspectorPresented
                    ? "Hide Inspector"
                    : "Show Inspector"
            )
        }
    }

    private var toolbarTitle: String {
        if let task = model.selectedTaskSnapshot {
            return task.displayTitle
        }
        if let project = model.selectedTaskProject ?? model.selectedProject {
            return project.metadata.title
        }
        switch model.workspace {
        case .sessions:
            return "Conduit"
        case .explore:
            return "Files"
        case .orchestrate:
            return "Orchestrate"
        }
    }

    private var toolsMenu: some View {
        Menu {
            Menu("Workspace") {
                ForEach(ConduitWorkspace.allCases, id: \.self) { workspace in
                    Button {
                        model.workspace = workspace
                    } label: {
                        Label(
                            workspace.displayName,
                            systemImage: model.workspace == workspace
                                ? "checkmark.circle.fill"
                                : workspace.symbolName
                        )
                    }
                }
            }

            Divider()

            Button("Browse Projects…") {
                model.showProjectBrowser = true
            }
            Button("Build Context Bundle", action: model.prepareContextBundle)
            Button("Open Project Shell") {
                _ = model.launchDefaultShell()
            }
            Button("Resume Durable Session…") {
                model.showResumeSessions = true
            }

            Menu("Forward") {
                Button("Move selection to composer", action: model.beginForwardingToComposer)
                Divider()
                ForEach(model.forwardableAgents) { agent in
                    Button("Send to \(agent.name)") {
                        model.beginForwarding(to: agent)
                    }
                }
            }

            Divider()

            Button("Resources…") { model.showResources = true }
            Button("Agent Usage…") { model.showAgentUsage = true }
            Button("Focus Board…") { model.showFocusBoardSheet = true }
            Button("MindGraph…") { model.showMindGraph = true }
            Button("Conduit Doctor…") { model.showDiagnostics = true }

            Divider()

            Menu("Appearance") {
                ForEach(PaletteID.allCases, id: \.self) { id in
                    Button {
                        themeStore.select(id)
                    } label: {
                        Label(
                            id.displayName,
                            systemImage: themeStore.selectedPalette == id
                                ? "checkmark"
                                : "circle.fill"
                        )
                    }
                }
                Divider()
                Button {
                    themeStore.surfaceFinish =
                        themeStore.surfaceFinish == .matte ? .sheen : .matte
                } label: {
                    Label(
                        themeStore.surfaceFinish == .sheen
                            ? "Sheen finish on"
                            : "Sheen finish off",
                        systemImage: themeStore.surfaceFinish == .sheen
                            ? "sparkles"
                            : "circle.dashed"
                    )
                }
            }

            Button("Settings…") { model.showSettingsSheet = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .help("Tools")
        .accessibilityLabel("Tools")
    }

    private func withPanelAnimation(_ changes: () -> Void) {
        if reduceMotion {
            changes()
        } else {
            withAnimation(.easeInOut(duration: 0.18), changes)
        }
    }

    // MARK: - Root setup states

    private var onboarding: some View {
        VStack(spacing: 18) {
            PixelOnboardingMark()
            Text("Connect Conduit to MainFrame")
                .font(.largeTitle.bold())
                .foregroundStyle(palette.text)
            Text(
                "Choose the folder containing 00_inbox, 10_knowledge, 20_live, and 30_projects. Conduit keeps your files as the source of truth."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(palette.dim)
            .frame(maxWidth: 560)
            Button("Choose MainFrame Root", action: model.chooseMainframeRoot)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose MainFrame Root")
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rootAuthorization: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Renew MainFrame Access")
                .font(.title2.bold())
                .foregroundStyle(palette.text)
            Text(
                "macOS no longer recognizes this build's access to the saved folder. Choose the same MainFrame root once; Conduit will preserve that authorization for future launches."
            )
            .multilineTextAlignment(.center)
            .foregroundStyle(palette.dim)
            .frame(maxWidth: 520)
            if let root = model.settings.mainframeRoot {
                Text(root.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(palette.dim)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Button("Choose MainFrame Root", action: model.chooseMainframeRoot)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose MainFrame Root")
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct PixelOnboardingMark: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 12, size.height / 12)
            func fill(
                _ x: Int,
                _ y: Int,
                _ w: Int,
                _ h: Int,
                _ color: Color
            ) {
                context.fill(
                    Path(
                        CGRect(
                            x: CGFloat(x) * unit,
                            y: CGFloat(y) * unit,
                            width: CGFloat(w) * unit,
                            height: CGFloat(h) * unit
                        )
                    ),
                    with: .color(color)
                )
            }
            fill(5, 0, 2, 2, palette.accent)
            fill(5, 2, 2, 1, palette.dim)
            fill(2, 3, 8, 6, palette.dim.opacity(0.85))
            fill(3, 4, 6, 4, palette.surface)
            fill(4, 5, 1, 1, palette.accent)
            fill(7, 5, 1, 1, palette.accent)
            fill(0, 5, 2, 3, palette.dim)
            fill(10, 5, 2, 3, palette.dim)
            fill(3, 9, 2, 3, palette.dim)
            fill(7, 9, 2, 3, palette.dim)
        }
        .frame(width: 88, height: 88)
        .accessibilityHidden(true)
    }
}
#endif
