#if os(macOS)
import ConduitCore
import SwiftUI

/// Explicit task creation. MainFrame's scanned projects and enabled local CLI
/// profiles are the only choices; this view creates no shadow registry.
struct NewTaskView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedProjectID: String?
    @State private var selectedAgentID: UUID?

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var selectedProject: MainframeProject? {
        guard let selectedProjectID else { return nil }
        return model.projects.first { $0.id == selectedProjectID }
    }

    private var selectedAgent: AgentProfile? {
        guard let selectedAgentID else { return nil }
        return model.enabledAgents.first { $0.id == selectedAgentID }
    }

    private var canCreate: Bool {
        selectedProject != nil && selectedAgent != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(palette.line)

            VStack(alignment: .leading, spacing: 18) {
                conversationFirstNote

                VStack(alignment: .leading, spacing: 7) {
                    Text("PROJECT")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(palette.dim)
                    projectPicker
                    if let project = selectedProject {
                        Text(project.path.path)
                            .font(.caption.monospaced())
                            .foregroundStyle(palette.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(project.path.path)
                    }
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("AGENT")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(0.7)
                        .foregroundStyle(palette.dim)
                    agentPicker
                    if let agent = selectedAgent {
                        Text("Installed CLI: \(agent.command)")
                            .font(.caption.monospaced())
                            .foregroundStyle(palette.faint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(agent.command)
                    }
                }

                if model.projects.isEmpty || model.enabledAgents.isEmpty {
                    missingRequirement
                }
            }
            .padding(20)

            Spacer(minLength: 8)
            Divider().overlay(palette.line)
            footer
        }
        .frame(width: 520, height: 410)
        .background(palette.canvas)
        .onAppear(perform: reconcileSelections)
        .onChange(of: model.projects) { _ in
            reconcileSelections()
        }
        .onChange(of: model.enabledAgents) { _ in
            reconcileSelections()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("New Task")
                .font(.headline)
                .foregroundStyle(palette.text)
            Text("Start an enabled CLI agent in a project discovered from MainFrame.")
                .font(.caption)
                .foregroundStyle(palette.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(palette.surface)
    }

    private var conversationFirstNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(palette.dim)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Conversation opens first")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text("Conduit launches the installed CLI through a real PTY. The full terminal remains available from Raw for direct input, approvals, and debugging.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(palette.lineSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var projectPicker: some View {
        if model.projects.isEmpty {
            Text("No projects are available")
                .foregroundStyle(palette.dim)
        } else {
            Picker("Project", selection: $selectedProjectID) {
                ForEach(model.projects) { project in
                    Text(projectPickerTitle(project))
                        .tag(Optional(project.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Project")
            .accessibilityValue(selectedProject.map(projectPickerTitle) ?? "None")
            .help("Projects come from the current MainFrame file scan")
        }
    }

    @ViewBuilder
    private var agentPicker: some View {
        if model.enabledAgents.isEmpty {
            Text("No agent profiles are enabled")
                .foregroundStyle(palette.dim)
        } else {
            Picker("Agent", selection: $selectedAgentID) {
                ForEach(model.enabledAgents) { agent in
                    Text(agent.kind == .shell ? "\(agent.name) — Shell" : agent.name)
                        .tag(Optional(agent.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Agent")
            .accessibilityValue(selectedAgent?.name ?? "None")
            .help("Enabled local CLI profiles from Conduit Settings")
        }
    }

    private var missingRequirement: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(palette.dim)
            Text(
                model.projects.isEmpty
                    ? "Choose or refresh a MainFrame root before starting a task."
                    : "Enable at least one agent profile in Settings before starting a task."
            )
            .font(.caption)
            .foregroundStyle(palette.dim)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            Text("Starting opens a live local process.")
                .font(.caption)
                .foregroundStyle(palette.faint)
            Spacer()
            Button("Cancel") {
                model.showNewTask = false
            }
            .keyboardShortcut(.cancelAction)
            Button("Create Task", action: createTask)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
                .accessibilityHint("Starts the selected local CLI agent")
        }
        .padding(14)
        .background(palette.surface)
    }

    private func projectPickerTitle(_ project: MainframeProject) -> String {
        project.isMainframeRoot
            ? "\(project.metadata.title) — MainFrame Root"
            : project.metadata.title
    }

    private func reconcileSelections() {
        if selectedProjectID == nil
            || !model.projects.contains(where: { $0.id == selectedProjectID }) {
            selectedProjectID = model.newTaskDefaultProjectID
                ?? model.projects.first?.id
        }

        if selectedAgentID == nil
            || !model.enabledAgents.contains(where: { $0.id == selectedAgentID }) {
            selectedAgentID = model.enabledAgents.first(where: { $0.kind != .shell })?.id
                ?? model.enabledAgents.first?.id
        }
    }

    private func createTask() {
        guard let project = selectedProject, let agent = selectedAgent else {
            return
        }
        _ = model.createTask(agent: agent, project: project)
    }
}
#endif
