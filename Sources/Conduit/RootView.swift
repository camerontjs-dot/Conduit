#if os(macOS)
import ConduitCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var projectSearch = ""
    /// Both supported compositions use `.all`: Focused two-column shows rail+workspace;
    /// Balanced/Operator three-column pins all three including context detail.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var isProjectSearchFocused: Bool

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    /// Deterministic visibility for the active density composition (never `.automatic`).
    private var densityColumnVisibility: NavigationSplitViewVisibility {
        switch model.density {
        case .focused:
            // Two-column form: rail + workspace.
            return .all
        case .balanced, .operator:
            // Three-column form: pin sidebar, workspace, and context detail.
            return .all
        }
    }

    var body: some View {
        // macOS 13 has no NavigationSplitViewVisibility that keeps sidebar+content
        // while hiding only detail, and no .inspector (macOS 14+). Density picks
        // a supported composition over the same three semantic regions.
        Group {
            if model.density == .focused {
                focusedSplitLayout
            } else {
                pinnedThreeColumnLayout
            }
        }
        .tint(palette.accent)
        .background(palette.app)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                paletteMenu
            }
        }
        .alert("Conduit", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
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
        .sheet(isPresented: $model.showContextBundle) {
            ContextBundleView()
                .environmentObject(model)
                .environmentObject(themeStore)
        }
        .onChange(of: model.speech.isRecording) { recording in
            if !recording { model.absorbSpeechTranscript() }
        }
        .onChange(of: model.projectSearchFocusRequest) { _ in
            // Keep density-appropriate columns (rail visible); do not collapse pinned detail.
            columnVisibility = densityColumnVisibility
            Task {
                await Task.yield()
                isProjectSearchFocused = true
            }
        }
        .onChange(of: model.density) { _ in
            columnVisibility = densityColumnVisibility
        }
        .task {
            await Task.yield()
            await model.bootstrap()
        }
    }

    /// Focused: two-column rail + workspace, with a temporary trailing overlay for context.
    private var focusedSplitLayout: some View {
        ZStack(alignment: .trailing) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn
            } detail: {
                workspaceColumn
            }

            if model.isContextInspectorPresented, let project = model.selectedProject {
                focusedContextOverlay(project: project)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.isContextInspectorPresented)
    }

    /// Balanced / Operator: three-column NavigationSplitView with context pinned as detail.
    private var pinnedThreeColumnLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarColumn
        } content: {
            workspaceColumn
        } detail: {
            contextDetailColumn
        }
    }

    private var sidebarColumn: some View {
        sidebar
            .navigationSplitViewColumnWidth(min: 200, ideal: 235, max: 280)
            .background(palette.rail)
    }

    private var workspaceColumn: some View {
        Group {
            if model.settings.mainframeRoot == nil {
                onboarding
            } else if model.rootAccessNeedsAuthorization {
                rootAuthorization
            } else if let project = model.selectedProject {
                ProjectWorkspaceView(project: project)
            } else {
                EmptyStateView(
                    title: "No MainFrame projects found",
                    systemImage: "folder.badge.questionmark",
                    description: "Choose another MainFrame root or create a project under 30_projects."
                )
            }
        }
        .background(palette.app)
    }

    private var contextDetailColumn: some View {
        Group {
            if let project = model.selectedProject {
                ContextPanel(project: project)
            } else {
                EmptyStateView(
                    title: "No project selected",
                    systemImage: "doc.text",
                    description: "Select a MainFrame project to inspect its context."
                )
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 400)
        .background(palette.surface)
    }

    /// Custom macOS 13-compatible trailing overlay (not SwiftUI `.inspector`).
    private func focusedContextOverlay(project: MainframeProject) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                Rectangle()
                    .fill(palette.line)
                    .frame(width: 1)
                    .accessibilityHidden(true)

                VStack(spacing: 0) {
                    HStack {
                        Text("Inspector")
                            .font(.caption.bold())
                            .foregroundStyle(palette.dim)
                        Spacer()
                        Button {
                            model.dismissContextInspector()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.bold())
                                .foregroundStyle(palette.dim)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Close project context inspector")
                        .help("Close inspector")
                        .keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(palette.surface)

                    Divider()

                    ContextPanel(project: project)
                }
                .frame(width: 320)
                .frame(maxHeight: .infinity)
                .background(palette.surface)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.14), radius: 10, x: -2, y: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project context inspector")
    }

    /// Always-reachable palette picker. Swatches resolve each palette's accent
    /// for the live system light/dark scheme.
    private var paletteMenu: some View {
        Menu {
            ForEach(PaletteID.allCases, id: \.self) { id in
                Button {
                    themeStore.select(id)
                } label: {
                    Label {
                        Text(id.displayName)
                    } icon: {
                        Image(systemName: themeStore.selectedPalette == id ? "checkmark.circle.fill" : "circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                themeStore.accentSwatch(for: id, colorScheme: colorScheme),
                                themeStore.accentSwatch(for: id, colorScheme: colorScheme)
                            )
                    }
                }
            }
        } label: {
            Label("Palette", systemImage: "paintpalette")
        }
        .help("Choose color palette")
        .accessibilityLabel("Palette")
        .accessibilityValue(themeStore.selectedPalette.displayName)
    }

    private var sidebar: some View {
        let matches = model.projects.filter { ProjectNavigation.matches($0, query: projectSearch) }
        let roots = matches.filter(\.isMainframeRoot)
        let active = matches.filter(ProjectNavigation.isActive)
        let other = matches.filter { !$0.isMainframeRoot && !ProjectNavigation.isActive($0) }

        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.dim)
                    .accessibilityHidden(true)
                TextField("Find a project", text: $projectSearch)
                    .textFieldStyle(.plain)
                    .foregroundStyle(palette.text)
                    .focused($isProjectSearchFocused)
                    .onSubmit(selectFirstSearchMatch)
                    .accessibilityLabel("Find a project")
                if !projectSearch.isEmpty {
                    Button {
                        projectSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(palette.dim)
                    .accessibilityLabel("Clear project search")
                    .help("Clear project search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            List(selection: $model.selectedProjectID) {
                if !roots.isEmpty {
                    Section("Workspace") {
                        ForEach(roots) { project in
                            projectRow(project)
                        }
                    }
                }
                if !active.isEmpty {
                    Section("Active") {
                        ForEach(active) { project in
                            projectRow(project)
                        }
                    }
                }
                if !other.isEmpty {
                    Section("Other") {
                        ForEach(other) { project in
                            projectRow(project)
                        }
                    }
                }
                if matches.isEmpty {
                    Text("No projects match “\(projectSearch)”.")
                        .foregroundStyle(palette.dim)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.rail)
            .onChange(of: model.selectedProjectID) { selectedID in
                if let selectedID, let project = model.projects.first(where: { $0.id == selectedID }) {
                    model.selectProject(project)
                }
            }

            // Work-session card lives in the project rail (below list, above footer).
            if let project = model.selectedProject {
                WorkSessionBar(project: project)
            }

            HStack {
                Button(action: model.chooseMainframeRoot) {
                    Label("Choose Root", systemImage: "folder")
                }
                .accessibilityLabel("Choose MainFrame Root")
                Spacer()
                Button {
                    model.showDiagnostics = true
                } label: {
                    Image(systemName: "stethoscope")
                }
                .accessibilityLabel("Conduit Doctor")
                .help("Conduit Doctor")
                Button(action: model.refreshProjects) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isScanningProjects || model.rootAccessNeedsAuthorization)
                .accessibilityLabel("Refresh MainFrame projects")
                .help("Refresh MainFrame")
            }
            .padding(10)
            .background(palette.surface)
        }
    }

    private func selectFirstSearchMatch() {
        guard let project = ProjectNavigation.firstMatch(
            in: model.projects,
            query: projectSearch
        ) else { return }
        model.selectProject(project)
        projectSearch = ""
        isProjectSearchFocused = false
        columnVisibility = densityColumnVisibility
    }

    private func projectRow(_ project: MainframeProject) -> some View {
        ProjectRow(project: project)
            .tag(project.id)
            .contentShape(Rectangle())
            .onTapGesture { model.selectProject(project) }
    }

    private var onboarding: some View {
        VStack(spacing: 18) {
            PixelOnboardingMark()
            Text("Connect Conduit to MainFrame")
                .font(.largeTitle.bold())
                .foregroundStyle(palette.text)
            Text("Choose the folder containing 00_inbox, 10_knowledge, 20_live, and 30_projects. Conduit keeps your files as the source of truth.")
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
    }

    private var rootAuthorization: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Renew MainFrame Access")
                .font(.title2.bold())
                .foregroundStyle(palette.text)
            Text("macOS no longer recognizes this build's access to the saved folder. Choose the same MainFrame root once; Conduit will preserve that authorization for future launches.")
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
        .accessibilityElement(children: .contain)
    }
}

private struct ProjectWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let project: MainframeProject

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(project: project)
            Divider()
            // Operator-only observed-state deck (above session strip / terminal).
            if model.density == .operator {
                OperatorOpsDeck(project: project)
                Divider()
            }
            SessionBar()
            Divider()
            terminalArea
                .frame(minHeight: 240)
            Divider()
            ComposerView()
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTargeted) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    if let url {
                        Task { @MainActor in model.addAttachments([url]) }
                    }
                }
            }
            return !providers.isEmpty
        }
        .overlay {
            if model.isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(palette.accent, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var terminalArea: some View {
        ZStack {
            palette.sink
            if model.sessionsForSelectedProject.isEmpty {
                EmptyStateView(
                    title: "No terminal session",
                    systemImage: "terminal",
                    description: "Launch an agent or open a shell from the toolbar."
                )
            } else if let active = activeTerminalRuntime {
                TerminalHostView(controller: active.controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
        .frame(minWidth: 280, minHeight: 240)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activeTerminalRuntime: TerminalRuntime? {
        let sessions = model.sessionsForSelectedProject
        if let id = model.activeSessionID, let match = sessions.first(where: { $0.id == id }) {
            return match
        }
        return sessions.first
    }
}

private struct ProjectRow: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let project: MainframeProject

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: project.isMainframeRoot ? "shippingbox.fill" : "folder.fill")
                .foregroundStyle(project.isMainframeRoot ? palette.text : palette.dim)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.metadata.title)
                    .lineLimit(1)
                    .foregroundStyle(palette.text)
                if let state = project.metadata.projectState ?? project.metadata.status {
                    Text(state.uppercased())
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                }
            }
        }
        .padding(.vertical, 3)
        .help(project.metadata.title)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let systemImage: String
    let description: String

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(palette.dim)
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(palette.text)
            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.dim)
                .frame(maxWidth: 420)
        }
        .padding(32)
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
            func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: Color) {
                context.fill(Path(CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit, width: CGFloat(w) * unit, height: CGFloat(h) * unit)), with: .color(color))
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
