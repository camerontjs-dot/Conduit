#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case session
    case files
    case review
    case context

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return "Session"
        case .files: return "Files"
        case .review: return "Review"
        case .context: return "Context"
        }
    }
}

/// Trailing inspector: session, files, git review, project context.
struct InspectorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    var project: MainframeProject?
    var showsCloseButton: Bool = false
    var onClose: (() -> Void)? = nil

    @State private var gitEntries: [GitStatusEntry] = []
    @State private var gitBranch: String = ""
    @State private var gitError: String?
    @State private var gitLoading = false

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.line)
            Picker("Inspector", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            ScrollView {
                Group {
                    switch model.inspectorTab {
                    case .session:
                        sessionPane
                    case .files:
                        filesPane
                    case .review:
                        reviewPane
                    case .context:
                        contextPane
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .background(palette.surface)
        .onChange(of: model.inspectorTab) { tab in
            if tab == .review {
                refreshGit()
            }
        }
        .onChange(of: project?.id) { _ in
            if model.inspectorTab == .review {
                refreshGit()
            }
        }
        .onAppear {
            if model.inspectorTab == .review {
                refreshGit()
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Inspector")
                .font(.caption.bold())
                .foregroundStyle(palette.dim)
            Spacer()
            if showsCloseButton {
                Button {
                    onClose?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.bold())
                        .foregroundStyle(palette.dim)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Close inspector")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.surface)
    }

    // MARK: - Session

    private var sessionPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let runtime = model.selectedTaskRuntime {
                labeled("Agent", runtime.descriptor.agent.name)
                labeled("Project", runtime.descriptor.projectPath.path)
                labeled("Backend", runtime.controller.backendLabel)
                labeled("Lifecycle", runtime.controller.lifecycleLabel)
                permissionBlock(for: runtime.descriptor.agent)

                HStack(spacing: 8) {
                    Button("Open Raw") {
                        runtime.selectedSurface = .raw
                    }
                    .buttonStyle(.borderedProminent)
                    if runtime.controller.lifecycle == .detached,
                       let id = runtime.descriptor.taskSessionID {
                        Button("Reconnect") {
                            model.reconnectTask(id)
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Leave") {
                        model.leaveActiveSession()
                    }
                    .buttonStyle(.bordered)
                }
            } else if let task = model.selectedTaskSnapshot {
                labeled("Task", task.displayTitle)
                labeled(
                    "Agent",
                    task.metadata.agentName ?? "Unknown"
                )
                labeled(
                    "Project",
                    task.metadata.workspace.fallbackTitle
                )
                Text("No open runtime. Reconnect or start a new task to send prompts.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                Button("New Task") {
                    model.showNewTask = true
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Select a task to inspect session details.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionBlock(for agent: AgentProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Permission mode")
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.dim)
            if agent.kind == .shell {
                Text("Shell has no agent permission mode.")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            } else {
                let current = model.settings.agents.first(where: {
                    $0.id == agent.id || $0.name == agent.name
                })?.permissionMode ?? agent.permissionMode
                Picker("Permission", selection: Binding(
                    get: { current },
                    set: { model.setPermissionModeForActiveAgent($0) }
                )) {
                    ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .labelsHidden()
                Text(current.help)
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                let resolved = AgentLaunchArguments.resolved(
                    for: model.settings.agents.first(where: {
                        $0.id == agent.id || $0.name == agent.name
                    }) ?? agent
                )
                Text("Next launch: \(agent.command) \(ArgumentTokenizer.join(resolved))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.faint)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Files

    private var filesPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let project {
                fileRow(
                    title: "Project root",
                    path: project.path.path,
                    provenance: "MainFrame project path"
                )
            }
            if !model.attachments.isEmpty {
                Text("Composer attachments")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.dim)
                ForEach(model.attachments) { attachment in
                    fileRow(
                        title: attachment.url.lastPathComponent,
                        path: attachment.url.path,
                        provenance: "Attached for next send"
                    )
                }
            }
            let retained = retainedAttachmentPaths
            if !retained.isEmpty {
                Text("Task attachment paths")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.dim)
                ForEach(retained, id: \.self) { path in
                    fileRow(
                        title: URL(fileURLWithPath: path).lastPathComponent,
                        path: path,
                        provenance: "From conversation history"
                    )
                }
            }
            let detected = detectedProjectionPaths
            if !detected.isEmpty {
                Text("Detected in projection")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.dim)
                Text("Best-effort paths from Derived-from-Raw text — not verified.")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                ForEach(detected, id: \.self) { path in
                    fileRow(
                        title: URL(fileURLWithPath: path).lastPathComponent,
                        path: path,
                        provenance: "Detected in projection"
                    )
                }
            }
            if model.attachments.isEmpty,
               retained.isEmpty,
               detected.isEmpty,
               project == nil {
                Text("No file paths for this task yet.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var retainedAttachmentPaths: [String] {
        let events = model.selectedTaskConversationEvents
        var paths: [String] = []
        var seen = Set<String>()
        for event in events {
            if case .userPrompt(let prompt) = event.kind {
                for path in prompt.attachmentPaths where seen.insert(path).inserted {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    private var detectedProjectionPaths: [String] {
        let events = model.selectedTaskRuntime?.presentationEvents
            ?? model.selectedTaskConversationEvents
        for event in events.reversed() {
            if case .agentOutput(let output) = event.kind {
                return ProjectedPathDetector.detectAbsolutePaths(in: output.text)
            }
        }
        return []
    }

    private func fileRow(title: String, path: String, provenance: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            Text(path)
                .font(.caption2.monospaced())
                .foregroundStyle(palette.faint)
                .lineLimit(2)
                .textSelection(.enabled)
            Text(provenance)
                .font(.caption2)
                .foregroundStyle(palette.dim)
            HStack(spacing: 8) {
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: path)]
                    )
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                    model.statusMessage = "Copied path."
                }
                .buttonStyle(.borderless)
                .font(.caption2)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Review

    private var reviewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(gitBranch.isEmpty ? "Git status" : gitBranch)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.dim)
                Spacer()
                Button("Refresh") { refreshGit() }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .disabled(gitLoading || project == nil)
            }
            if gitLoading {
                ProgressView()
                    .controlSize(.small)
            } else if let gitError {
                Text(gitError)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            } else if gitEntries.isEmpty {
                Text("Working tree clean, or no repository at this scope.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            } else {
                Text("Observed git paths only — not task completion evidence.")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                ForEach(gitEntries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.displayLabel) · \(entry.path)")
                            .font(.caption.monospaced())
                            .foregroundStyle(palette.text)
                            .lineLimit(2)
                        if let project {
                            let full = project.path
                                .appendingPathComponent(entry.path).path
                            HStack {
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [URL(fileURLWithPath: full)]
                                    )
                                }
                                .buttonStyle(.borderless)
                                .font(.caption2)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshGit() {
        guard let project else {
            gitEntries = []
            gitBranch = ""
            gitError = "No project scope selected."
            return
        }
        gitLoading = true
        gitError = nil
        let root = project.path
        Task.detached(priority: .userInitiated) {
            let status = Self.runGit(["status", "--porcelain"], in: root)
            let branch = Self.runGit(
                ["rev-parse", "--abbrev-ref", "HEAD"],
                in: root
            )
            await MainActor.run {
                gitLoading = false
                if let err = status.error {
                    gitEntries = []
                    gitBranch = ""
                    gitError = err
                    return
                }
                gitEntries = GitReviewParser.parsePorcelain(status.output ?? "")
                gitBranch = (branch.output ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if gitBranch.isEmpty, branch.error != nil {
                    gitError = branch.error
                }
            }
        }
    }

    nonisolated private static func runGit(
        _ args: [String],
        in directory: URL
    ) -> (output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = directory
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (nil, error.localizedDescription)
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: data, encoding: .utf8)
        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if process.terminationStatus != 0 {
            return (
                nil,
                (stderr?.isEmpty == false ? stderr : nil)
                    ?? "git exited \(process.terminationStatus)"
            )
        }
        return (stdout, nil)
    }

    // MARK: - Context

    @ViewBuilder
    private var contextPane: some View {
        if let project {
            VStack(spacing: 0) {
                WorkSessionBar(project: project)
                    .environmentObject(model)
                    .environmentObject(themeStore)
                Divider().overlay(palette.line)
                ContextPanel(project: project)
                    .environmentObject(model)
                    .environmentObject(themeStore)
            }
        } else {
            Text("Select a project-scoped task to inspect context.")
                .font(.caption)
                .foregroundStyle(palette.dim)
        }
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.faint)
            Text(value)
                .font(.caption)
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
        }
    }
}

private extension TerminalSessionController {
    var lifecycleLabel: String {
        switch lifecycle {
        case .idle: return "idle"
        case .launching: return "launching"
        case .running: return "running"
        case .detached: return "detached"
        case .exited(let code):
            if let code { return "exited (\(code))" }
            return "exited"
        }
    }
}
#endif
