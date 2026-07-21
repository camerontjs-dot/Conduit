#if os(macOS)
import ConduitCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 250)
        } detail: {
            if model.settings.mainframeRoot == nil {
                onboarding
            } else if let project = model.selectedProject {
                workspace(project)
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
    }

    private var sidebar: some View {
        List(selection: $model.selectedProjectID) {
            Section("MainFrame") {
                ForEach(model.projects) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                        .contentShape(Rectangle())
                        .onTapGesture { model.selectProject(project) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(action: model.chooseMainframeRoot) {
                    Label("Choose Root", systemImage: "folder")
                }
                Spacer()
                Button {
                    model.showDiagnostics = true
                } label: {
                    Image(systemName: "stethoscope")
                }
                .help("Conduit Doctor")
                Button(action: model.refreshProjects) {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh MainFrame")
            }
            .padding(10)
            .background(.bar)
        }
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
        }
        .padding(40)
    }

    private func workspace(_ project: MainframeProject) -> some View {
        VStack(spacing: 0) {
            WorkspaceHeader(project: project)
            Divider()
            WorkSessionBar(project: project)
            Divider()
            SessionBar()
            if !model.sessionsForSelectedProject.isEmpty {
                Divider()
                PixelAgentStrip()
            }
            Divider()
            HSplitView {
                terminalArea
                if model.showContext {
                    ContextPanel(project: project)
                        .frame(minWidth: 260, idealWidth: 330, maxWidth: 440)
                }
            }
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
            }
            ForEach(model.sessionsForSelectedProject) { runtime in
                TerminalHostView(controller: runtime.controller)
                    .opacity(runtime.id == model.activeSessionID ? 1 : 0)
                    .allowsHitTesting(runtime.id == model.activeSessionID)
                    .accessibilityHidden(runtime.id != model.activeSessionID)
            }
        }
        .frame(minWidth: 480, minHeight: 360)
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
        .accessibilityLabel("Conduit pixel operator")
    }
}
#endif
