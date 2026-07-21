#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

struct WorkspaceHeader: View {
    @EnvironmentObject private var model: AppModel
    let project: MainframeProject

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.metadata.title).font(.headline)
                Text(project.path.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            ForEach(model.enabledAgents) { agent in
                Button(agent.name) { model.launch(agent: agent) }
                    .buttonStyle(.bordered)
                    .help("Launch or reconnect to \(agent.name) in \(project.metadata.title)")
            }
            Menu {
                Button("Move clipboard selection to composer", action: model.copyClipboardSelectionToComposer)
                Divider()
                ForEach(model.enabledAgents) { agent in
                    Button("Send to \(agent.name)") { model.forwardClipboardSelection(to: agent) }
                }
            } label: {
                Image(systemName: "arrowshape.turn.up.right")
            }
            .menuStyle(.borderlessButton)
            .help("Forward copied terminal output")
            Button(action: model.prepareContextBundle) {
                Image(systemName: "doc.on.doc")
            }
            .help("Build a labeled context bundle")
            Button { model.showResources = true } label: {
                Image(systemName: "gauge.with.dots.needle.67percent")
            }
            .help("Resource deck")
            Button { model.showDiagnostics = true } label: {
                Image(systemName: "stethoscope")
            }
            .help("Conduit Doctor")
            Button {
                model.showContext.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help("Toggle project context")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct WorkSessionBar: View {
    @EnvironmentObject private var model: AppModel
    let project: MainframeProject

    var body: some View {
        HStack(spacing: 10) {
            if let session = model.workSession(for: project) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Work session")
                    .font(.caption.bold())
                TextField("Objective", text: model.objectiveBinding(for: project))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 220)
                    .onSubmit { model.commitWorkSessionFields(for: project) }
                TextField("Receipt note (optional)", text: model.notesBinding(for: project))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180)
                    .onSubmit { model.commitWorkSessionFields(for: project) }
                Text(session.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Close & Receipt") { model.closeWorkSession(for: project) }
                    .buttonStyle(.bordered)
                    .help("Write an append-only receipt under 20_live/conduit/sessions")
            } else {
                Image(systemName: "record.circle")
                    .foregroundStyle(.secondary)
                Text("Launch an agent to begin an evidence-aware work session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.04))
    }
}

struct SessionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // Timeline-driven so pill states stay honest after output goes quiet
        // (a session must not read "working" forever once it idles).
        TimelineView(.periodic(from: .now, by: 0.7)) { timeline in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.sessionsForSelectedProject) { runtime in
                        SessionPill(runtime: runtime, date: timeline.date)
                            .environmentObject(model)
                    }
                    Button {
                        model.launchDefaultShell()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
        }
        .background(.bar)
    }
}

private struct SessionPill: View {
    @EnvironmentObject private var model: AppModel
    let runtime: TerminalRuntime
    let date: Date
    @ObservedObject private var controller: TerminalSessionController

    init(runtime: TerminalRuntime, date: Date) {
        self.runtime = runtime
        self.date = date
        self._controller = ObservedObject(wrappedValue: runtime.controller)
    }

    var body: some View {
        let state = controller.visualState(at: date)
        HStack(spacing: 6) {
            Circle()
                .fill(state.indicatorColor)
                .frame(width: 7, height: 7)
            Button(controller.terminalTitle) {
                model.activeSessionID = runtime.id
            }
            .buttonStyle(.plain)
            Text(controller.backendLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button {
                model.closeSession(runtime)
            } label: {
                Image(systemName: controller.usesTmux ? "rectangle.portrait.and.arrow.right" : "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .help(controller.usesTmux ? "Detach session" : "Close session")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(runtime.id == model.activeSessionID ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
        .clipShape(Capsule())
        .contextMenu {
            Button("Move clipboard selection to composer", action: model.copyClipboardSelectionToComposer)
            Menu("Send clipboard selection to") {
                ForEach(model.enabledAgents) { agent in
                    Button(agent.name) { model.forwardClipboardSelection(to: agent) }
                }
            }
            Divider()
            Button(controller.usesTmux ? "Detach" : "Close") { model.closeSession(runtime) }
        }
    }
}

struct ContextPanel: View {
    let project: MainframeProject
    @State private var markdown = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Project Context", systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                Button {
                    NSWorkspace.shared.open(project.path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Open in Finder")
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Context shown here is for navigation and inspection, not verification.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let goal = project.metadata.goal {
                        contextSection("Goal", goal)
                    }
                    if let next = project.metadata.nextAction {
                        contextSection("Next action", next)
                    }
                    if let state = project.metadata.projectState ?? project.metadata.status {
                        contextSection("State", state)
                    }
                    Divider()
                    Text(markdown.isEmpty ? "No README.md was found for this workspace." : markdown)
                        .textSelection(.enabled)
                        .font(.system(.body, design: .monospaced))
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task(id: project.id) {
            guard let readme = project.readmePath else {
                markdown = ""
                return
            }
            markdown = (try? String(contentsOf: readme, encoding: .utf8)) ?? "Unable to read \(readme.path)"
        }
    }

    private func contextSection(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}
#endif
