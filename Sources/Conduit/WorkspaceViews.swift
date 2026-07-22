#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

struct WorkspaceHeader: View {
    @EnvironmentObject private var model: AppModel
    let project: MainframeProject

    private var launchAgents: [AgentProfile] {
        model.enabledAgents.filter { $0.kind != .shell }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.metadata.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(project.path.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 120, idealWidth: 210, maxWidth: 340, alignment: .leading)
            .layoutPriority(1)

            Button {
                model.launchDefaultShell()
            } label: {
                Label("Shell", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Open or reconnect project shell")
            .help("Open or reconnect to the project shell")

            Menu {
                ForEach(launchAgents) { agent in
                    Button(agent.name) { model.launch(agent: agent) }
                }
            } label: {
                Label("Launch", systemImage: "sparkles")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(launchAgents.isEmpty)
            .accessibilityLabel("Launch or reconnect agent")
            .help("Launch or reconnect to an agent")

            Menu {
                Button("Move selection to composer", action: model.copyClipboardSelectionToComposer)
                Divider()
                ForEach(model.enabledAgents) { agent in
                    Button("Send to \(agent.name)") { model.forwardClipboardSelection(to: agent) }
                }
            } label: {
                Image(systemName: "arrowshape.turn.up.right")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Forward copied terminal output")
            .help("Forward copied terminal output")

            Menu {
                Button("Build Context Bundle", action: model.prepareContextBundle)
                Button("Resource Deck") { model.showResources = true }
                Button("Conduit Doctor") { model.showDiagnostics = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Workspace tools")
            .help("Context bundle, resources, and diagnostics")

            Button {
                model.showContext.toggle()
            } label: {
                Image(systemName: model.showContext ? "sidebar.trailing" : "sidebar.trailing.hide")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(model.showContext ? "Hide project context" : "Show project context")
            .help("Toggle project context")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

struct WorkSessionBar: View {
    @EnvironmentObject private var model: AppModel
    let project: MainframeProject
    @State private var showReceiptNote = false

    var body: some View {
        HStack(spacing: 10) {
            if let session = model.workSession(for: project) {
                Label("Work", systemImage: "record.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.green)
                    .accessibilityLabel("Work session active")
                Text(session.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                TextField("Objective", text: model.objectiveBinding(for: project))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 150)
                    .layoutPriority(1)
                    .onSubmit { model.commitWorkSessionFields(for: project) }
                    .accessibilityLabel("Work session objective")
                Button {
                    showReceiptNote.toggle()
                } label: {
                    Image(systemName: session.notes.isEmpty ? "note.text.badge.plus" : "note.text")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(session.notes.isEmpty ? "Add receipt note" : "Edit receipt note")
                .help(session.notes.isEmpty ? "Add an optional receipt note" : "Edit the receipt note")
                .popover(isPresented: $showReceiptNote) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Receipt note")
                            .font(.headline)
                        Text("Record an operator observation. This does not claim the terminal work succeeded.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("Optional observation", text: model.notesBinding(for: project))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                model.commitWorkSessionFields(for: project)
                                showReceiptNote = false
                            }
                        HStack {
                            Spacer()
                            Button("Done") {
                                model.commitWorkSessionFields(for: project)
                                showReceiptNote = false
                            }
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding()
                    .frame(width: 360)
                    .onDisappear { model.commitWorkSessionFields(for: project) }
                }
                Button {
                    model.closeWorkSession(for: project)
                } label: {
                    Label("Receipt", systemImage: "checkmark.seal")
                }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Close work session and write receipt")
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
        .background(Color.accentColor.opacity(0.04))
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
                    Text("SESSIONS")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                    ForEach(model.sessionsForSelectedProject) { runtime in
                        SessionPill(runtime: runtime, date: timeline.date)
                            .environmentObject(model)
                    }
                    Button {
                        model.launchDefaultShell()
                    } label: {
                        Label("New shell", systemImage: "plus")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityLabel("Open or reconnect project shell")
                    .accessibilityHint("Starts or reconnects to the project shell")
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
        let sprite = AgentSpriteResolver.resolve(runtime.descriptor.agent)
        HStack(spacing: 6) {
            AgentSpriteView(profile: runtime.descriptor.agent, state: state)
            Button {
                model.activeSessionID = runtime.id
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.indicatorColor)
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(runtime.descriptor.agent.name)
                            .font(.caption.bold())
                        Text("\(state.label) · \(controller.backendLabel)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(runtime.descriptor.agent.name) session, \(state.label), \(controller.backendLabel)")
            .accessibilityHint(
                sprite.isExactMatch
                    ? "Switches the terminal to this session"
                    : "Switches the terminal to this session. A generic character is shown because this profile has no dedicated sprite."
            )
            Button {
                model.closeSession(runtime)
            } label: {
                Image(systemName: controller.usesTmux ? "rectangle.portrait.and.arrow.right" : "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(controller.usesTmux ? "Detach \(runtime.descriptor.agent.name) session" : "Close \(runtime.descriptor.agent.name) session")
            .accessibilityHint(controller.usesTmux ? "Keeps the tmux process running; choose the agent from Launch to reconnect" : "Ends the direct terminal process")
            .help(
                controller.usesTmux
                    ? "Detach (keeps tmux running — relaunch reconnects). Right-click for End / Restart."
                    : "Close session"
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(runtime.id == model.activeSessionID ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Move clipboard selection to composer", action: model.copyClipboardSelectionToComposer)
            Menu("Send clipboard selection to") {
                ForEach(model.enabledAgents) { agent in
                    Button(agent.name) { model.forwardClipboardSelection(to: agent) }
                }
            }
            Divider()
            if controller.usesTmux {
                Button("Detach (keep running)") { model.closeSession(runtime) }
                Button("End session (kill process)", role: .destructive) { model.endSession(runtime) }
                Button("Restart session") { _ = model.restartSession(runtime) }
            } else {
                Button("Close", role: .destructive) { model.closeSession(runtime) }
                Button("Restart session") { _ = model.restartSession(runtime) }
            }
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
                .accessibilityLabel("Open project in Finder")
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
