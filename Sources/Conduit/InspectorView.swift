#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

/// Tool-window cards in the trailing Inspector (C86). Visibility and expansion
/// persist; density supplies defaults until the operator customizes.
enum InspectorCard: String, CaseIterable, Identifiable, Codable, Hashable {
    case session
    case files
    case review
    case context
    case usage
    case attention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .session: return "Session"
        case .files: return "Files"
        case .review: return "Review"
        case .context: return "Context"
        case .usage: return "Usage"
        case .attention: return "Attention"
        }
    }

    /// Short source / job label shown in the card chrome.
    var subtitle: String {
        switch self {
        case .session: return "Runtime and safe actions"
        case .files: return "Paths · not verification"
        case .review: return "Observed git only"
        case .context: return "Work session · nominations"
        case .usage: return "Account meters · manual refresh"
        case .attention: return "MainFrame Focus Board · read-only"
        }
    }

    enum DefaultKind {
        case visibility
        case expanded
    }

    /// Density-as-perspective defaults (Focused quieter, Operator fuller).
    static func defaultMap(
        for density: Density,
        kind: DefaultKind
    ) -> [InspectorCard: Bool] {
        switch kind {
        case .visibility:
            switch density {
            case .focused:
                return [
                    .session: true,
                    .files: false,
                    .review: false,
                    .context: false,
                    .usage: false,
                    .attention: false
                ]
            case .balanced:
                return [
                    .session: true,
                    .files: true,
                    .review: true,
                    .context: false,
                    .usage: false,
                    .attention: true
                ]
            case .operator:
                return Dictionary(
                    uniqueKeysWithValues: allCases.map { ($0, true) }
                )
            }
        case .expanded:
            switch density {
            case .focused:
                return Dictionary(
                    uniqueKeysWithValues: allCases.map { ($0, $0 == .session) }
                )
            case .balanced:
                return [
                    .session: true,
                    .files: false,
                    .review: false,
                    .context: false,
                    .usage: false,
                    .attention: false
                ]
            case .operator:
                return [
                    .session: true,
                    .files: true,
                    .review: false,
                    .context: false,
                    .usage: false,
                    .attention: true
                ]
            }
        }
    }
}

/// Historical name used by focus / menu jump targets.
typealias InspectorTab = InspectorCard

/// Trailing inspector: session, files, git review, project context.
struct InspectorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    var project: MainframeProject?
    var showsCloseButton: Bool = false
    var focusRequest: Int = 0
    var onClose: (() -> Void)? = nil

    @State private var gitEntries: [GitStatusEntry] = []
    @State private var gitBranch: String = ""
    @State private var gitError: String?
    @State private var gitLoading = false
    @FocusState private var focusedCard: InspectorCard?
    @AccessibilityFocusState private var cardAccessibilityFocused: Bool

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var visibleCards: [InspectorCard] {
        InspectorCard.allCases.filter { model.isInspectorCardVisible($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.line)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visibleCards) { card in
                        inspectorCard(card)
                    }
                    if visibleCards.isEmpty {
                        Text("All Inspector cards are hidden. Use View → Inspector Cards to show one.")
                            .font(.caption)
                            .foregroundStyle(palette.dim)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(
            ConduitFinishedFill(
                base: palette.surface,
                finish: themeStore.surfaceFinish,
                colorScheme: colorScheme
            )
        )
        .onChange(of: model.inspectorTab) { tab in
            model.focusInspectorCard(tab)
            if tab == .review || model.isInspectorCardExpanded(.review) {
                refreshGitIfNeeded()
            }
            focusedCard = tab
        }
        .onChange(of: project?.id) { _ in
            refreshGitIfNeeded()
        }
        .onChange(of: model.inspectorCardExpanded[.review] ?? false) { expanded in
            if expanded { refreshGitIfNeeded() }
        }
        .onChange(of: model.inspectorCardExpanded[.attention] ?? false) { expanded in
            if expanded { model.refreshFocusBoard() }
        }
        .onAppear {
            refreshGitIfNeeded()
            if focusRequest > 0 {
                requestInspectorFocus()
            }
        }
        .onChange(of: focusRequest) { request in
            if request > 0 {
                requestInspectorFocus()
            }
        }
        .onExitCommand {
            if showsCloseButton, model.isContextInspectorPresented {
                onClose?()
            }
        }
    }

    @ViewBuilder
    private func inspectorCard(_ card: InspectorCard) -> some View {
        let expanded = model.isInspectorCardExpanded(card)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                model.toggleInspectorCardExpanded(card)
                if card == .review, !expanded {
                    refreshGitIfNeeded()
                }
                if card == .attention, !expanded {
                    model.refreshFocusBoard()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(palette.dim)
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.text)
                        Text(card.subtitle)
                            .font(.caption2)
                            .foregroundStyle(palette.faint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedCard, equals: card)
            .accessibilityLabel(card.title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(card.subtitle)
            .accessibilityAddTraits(.isHeader)

            if expanded {
                Divider().overlay(palette.line)
                Group {
                    switch card {
                    case .session: sessionPane
                    case .files: filesPane
                    case .review: reviewPane
                    case .context: contextPane
                    case .usage: usagePane
                    case .attention: FocusBoardPanel()
                    }
                }
                .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.sink.opacity(colorScheme == .dark ? 0.55 : 0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(palette.line.opacity(0.9), lineWidth: 1)
        )
    }

    private func refreshGitIfNeeded() {
        guard model.isInspectorCardVisible(.review),
              model.isInspectorCardExpanded(.review)
        else { return }
        refreshGit()
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
                .accessibilityHint("Returns focus to the control used before Inspector opened")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            ConduitFinishedFill(
                base: palette.surface,
                finish: themeStore.surfaceFinish,
                colorScheme: colorScheme
            )
        )
    }

    private func requestInspectorFocus() {
        DispatchQueue.main.async {
            let target = model.isInspectorCardVisible(model.inspectorTab)
                ? model.inspectorTab
                : (visibleCards.first ?? .session)
            model.focusInspectorCard(target)
            focusedCard = target
            cardAccessibilityFocused = true
        }
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

                nextSafeActionBlock(
                    SessionNextSafeAction.resolve(
                        hasSelectedTask: true,
                        hasOpenRuntime: true,
                        isDetached: runtime.controller.lifecycle == .detached,
                        isReconnectableWithoutRuntime: false
                    ),
                    runtime: runtime
                )

                HStack(spacing: 8) {
                    if runtime.controller.lifecycle != .detached {
                        Button("Open Raw") {
                            runtime.selectedSurface = .raw
                        }
                        .buttonStyle(.bordered)
                    }
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
                let row = model.taskCatalogRows.first { $0.id == task.id }
                let reconnectable = row?.availability.kind == .reconnectable
                Text(
                    reconnectable
                        ? "No open runtime. Reconnect is available as an explicit action."
                        : "No open runtime. Start a new task to send prompts."
                )
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                nextSafeActionBlock(
                    SessionNextSafeAction.resolve(
                        hasSelectedTask: true,
                        hasOpenRuntime: false,
                        isDetached: false,
                        isReconnectableWithoutRuntime: reconnectable
                    ),
                    runtime: nil,
                    taskID: task.id
                )
            } else {
                Text("Select a task to inspect session details.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                nextSafeActionBlock(
                    .selectTask,
                    runtime: nil
                )
            }
            Button {
                model.showMindGraph = true
            } label: {
                Label("Query MindGraph…", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func nextSafeActionBlock(
        _ action: SessionNextSafeAction,
        runtime: TerminalRuntime?,
        taskID: TaskSessionID? = nil
    ) -> some View {
        if action != .none {
            VStack(alignment: .leading, spacing: 6) {
                Text("NEXT SAFE ACTION")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(palette.faint)
                Button {
                    performNextSafeAction(action, runtime: runtime, taskID: taskID)
                } label: {
                    Text(action.title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(action.title)
                .help(action.help)
                Text(action.help)
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.accentSoft.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
        }
    }

    private func performNextSafeAction(
        _ action: SessionNextSafeAction,
        runtime: TerminalRuntime?,
        taskID: TaskSessionID?
    ) {
        switch action {
        case .openRaw:
            runtime?.selectedSurface = .raw
        case .reconnect:
            if let taskID {
                model.reconnectTask(taskID)
            } else if let id = runtime?.descriptor.taskSessionID {
                model.reconnectTask(id)
            }
        case .leave:
            model.leaveActiveSession()
        case .newTask:
            model.showNewTask = true
        case .selectTask, .none:
            break
        }
    }

    private var usagePane: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentUsageMeterPanel()
            Button("Open full usage sheet") {
                model.showAgentUsage = true
            }
            .buttonStyle(.borderedProminent)
            Text("Account meters are optional provider/tool reports. The full sheet keeps them separate from Conduit-observed attach time and output totals.")
                .font(.caption2)
                .foregroundStyle(palette.faint)
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
                Text("No changed paths were observed in this Git working tree. A clean tree is not task completion evidence.")
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
