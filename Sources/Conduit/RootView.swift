#if os(macOS)
import ConduitCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var projectSearch = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 235, max: 280)
        } detail: {
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
        .alert("Conduit", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .sheet(isPresented: $model.showDiagnostics) {
            DiagnosticsView().environmentObject(model)
        }
        .sheet(isPresented: $model.showResources) {
            ResourcePanelView().environmentObject(model)
        }
        .sheet(isPresented: $model.showContextBundle) {
            ContextBundleView().environmentObject(model)
        }
        .onChange(of: model.speech.isRecording) { recording in
            if !recording { model.absorbSpeechTranscript() }
        }
        .task {
            await Task.yield()
            await model.bootstrap()
        }
    }

    private var sidebar: some View {
        let matches = model.projects.filter { ProjectNavigation.matches($0, query: projectSearch) }
        let roots = matches.filter(\.isMainframeRoot)
        let active = matches.filter(ProjectNavigation.isActive)
        let other = matches.filter { !$0.isMainframeRoot && !ProjectNavigation.isActive($0) }

        return List(selection: $model.selectedProjectID) {
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
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $projectSearch, prompt: "Find a project")
        .onChange(of: model.selectedProjectID) { selectedID in
            if let selectedID, let project = model.projects.first(where: { $0.id == selectedID }) {
                model.selectProject(project)
            }
        }
        .safeAreaInset(edge: .bottom) {
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
            .background(.bar)
        }
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
            Text("Choose the folder containing 00_inbox, 10_knowledge, 20_live, and 30_projects. Conduit keeps your files as the source of truth.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560)
            Button("Choose MainFrame Root", action: model.chooseMainframeRoot)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose MainFrame Root")
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Text("macOS no longer recognizes this build's access to the saved folder. Choose the same MainFrame root once; Conduit will preserve that authorization for future launches.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            if let root = model.settings.mainframeRoot {
                Text(root.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Button("Choose MainFrame Root", action: model.chooseMainframeRoot)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose MainFrame Root")
            if let status = model.statusMessage {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .accessibilityElement(children: .contain)
    }
}

private struct ProjectWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    let project: MainframeProject
    @State private var showContextDetails = false

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(project: project)
            Divider()
            WorkSessionBar(project: project)
            Divider()
            SessionBar()
            Divider()
            GeometryReader { geometry in
                if model.showContext && geometry.size.width >= 900 {
                    HSplitView {
                        terminalArea
                            .layoutPriority(1)
                        ContextPanel(project: project)
                            .frame(minWidth: 260, idealWidth: 310, maxWidth: 400)
                    }
                } else {
                    VStack(spacing: 0) {
                        if model.showContext {
                            CompactContextBar(project: project) {
                                showContextDetails = true
                            }
                            Divider()
                        }
                        terminalArea
                    }
                }
            }
            .frame(minHeight: 240)
            Divider()
            ComposerView()
        }
        .sheet(isPresented: $showContextDetails) {
            ContextPanel(project: project)
                .frame(width: 560, height: 620)
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
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var terminalArea: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
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

private struct CompactContextBar: View {
    let project: MainframeProject
    let showDetails: () -> Void

    private var summaryTitle: String {
        project.metadata.nextAction == nil ? "Goal" : "Next action"
    }

    private var summary: String {
        project.metadata.nextAction ?? project.metadata.goal ?? "Open the project context for README details."
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(summaryTitle.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(summary)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let state = project.metadata.projectState ?? project.metadata.status {
                Text(state.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.09), in: Capsule())
            }
            Button("Details", action: showDetails)
                .buttonStyle(.borderless)
                .accessibilityHint("Opens the full project context")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.accentColor.opacity(0.045))
    }
}

private struct ProjectRow: View {
    let project: MainframeProject

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: project.isMainframeRoot ? "shippingbox.fill" : "folder.fill")
                .foregroundStyle(project.isMainframeRoot ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.metadata.title).lineLimit(1)
                if let state = project.metadata.projectState ?? project.metadata.status {
                    Text(state.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .help(project.metadata.title)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
            Text(description)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
        }
        .padding(32)
    }
}

private struct PixelOnboardingMark: View {
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 12, size.height / 12)
            func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: Color) {
                context.fill(Path(CGRect(x: CGFloat(x) * unit, y: CGFloat(y) * unit, width: CGFloat(w) * unit, height: CGFloat(h) * unit)), with: .color(color))
            }
            fill(5, 0, 2, 2, .accentColor)
            fill(5, 2, 2, 1, .secondary)
            fill(2, 3, 8, 6, .secondary.opacity(0.85))
            fill(3, 4, 6, 4, Color(nsColor: .windowBackgroundColor))
            fill(4, 5, 1, 1, .accentColor)
            fill(7, 5, 1, 1, .accentColor)
            fill(0, 5, 2, 3, .secondary)
            fill(10, 5, 2, 3, .secondary)
            fill(3, 9, 2, 3, .secondary)
            fill(7, 9, 2, 3, .secondary)
        }
        .frame(width: 88, height: 88)
        .accessibilityHidden(true)
    }
}
#endif
