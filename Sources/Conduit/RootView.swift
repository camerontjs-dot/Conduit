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
                ContentUnavailableView(
                    "No MainFrame projects found",
                    systemImage: "folder.badge.questionmark",
                    description: Text("Choose another MainFrame root or create a project under 30_projects.")
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
            Image(systemName: "terminal.fill")
                .font(.system(size: 54))
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
            SessionBar()
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
                ContentUnavailableView(
                    "No terminal session",
                    systemImage: "terminal",
                    description: Text("Launch an agent or open a shell from the toolbar.")
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
#endif
