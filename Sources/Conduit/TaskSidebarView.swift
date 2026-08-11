#if os(macOS)
import AppKit
import ConduitCore
import Foundation
import SwiftUI

/// Conversation-first navigation over durable task history.
///
/// Selecting a task is intentionally side-effect free: it selects recorded
/// history only. Reconnecting, leaving, and ending a runtime remain separate
/// operator actions.
struct TaskSidebarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var taskToRename: TaskSessionSnapshot?
    @State private var taskToEnd: TaskSessionSnapshot?
    @State private var showTaskHistoryDiagnostics = false
    @FocusState private var isTaskSearchFocused: Bool

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var pinnedRows: [TaskSessionCatalogRow] {
        model.taskCatalogRows.filter {
            $0.session.isPinned && !$0.session.isArchived
        }.sorted { lhs, rhs in
            let leftActive = lhs.availability.kind == .running
                || lhs.availability.kind == .reconnectable
            let rightActive = rhs.availability.kind == .running
                || rhs.availability.kind == .reconnectable
            if leftActive != rightActive {
                return leftActive && !rightActive
            }
            return lhs.session.lastActivityAt > rhs.session.lastActivityAt
        }
    }

    private var activeRows: [TaskSessionCatalogRow] {
        model.taskCatalogRows.filter {
            !$0.session.isPinned
                && !$0.session.isArchived
                && ($0.availability.kind == .running
                    || $0.availability.kind == .reconnectable)
        }
    }

    private var recentRows: [TaskSessionCatalogRow] {
        model.taskCatalogRows.filter {
            !$0.session.isPinned
                && !$0.session.isArchived
                && $0.availability.kind != .running
                && $0.availability.kind != .reconnectable
        }
    }

    private var archivedRows: [TaskSessionCatalogRow] {
        model.taskCatalogRows.filter(\.session.isArchived)
    }

    /// Durable sessions are a recovery surface, not another task-history
    /// authority. A discovered row disappears when its task identity is
    /// already represented by loaded history or an open runtime.
    private var discoveredRows: [ResumableSession] {
        var representedTaskIDs = Set(model.taskSessions.map(\.id))
        representedTaskIDs.formUnion(
            model.sessions.compactMap(\.descriptor.taskSessionID)
        )

        return model.resumableSessions.filter { row in
            if case .alreadyOpen = row.relation {
                return false
            }
            if let taskID = row.session.taskSessionBinding.taskSessionID,
               representedTaskIDs.contains(taskID) {
                return false
            }
            guard discoveredRowMatchesScope(row) else { return false }
            return discoveredRowMatchesSearch(row)
        }
    }

    private var hasAnyRows: Bool {
        !pinnedRows.isEmpty
            || !activeRows.isEmpty
            || !recentRows.isEmpty
            || !archivedRows.isEmpty
            || !discoveredRows.isEmpty
    }

    private var usesExpandedLabels: Bool {
        model.density != .focused
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider().overlay(palette.line)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !pinnedRows.isEmpty {
                        taskSection("Pinned", rows: pinnedRows)
                    }
                    taskSection("Active", rows: activeRows)
                    taskSection("Recent", rows: recentRows)
                    if model.showArchivedTasks {
                        taskSection("Archived", rows: archivedRows)
                    }

                    if !discoveredRows.isEmpty {
                        discoveredSection
                    }

                    if !hasAnyRows {
                        emptyState
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 12)
            }

            Divider().overlay(palette.line)
            footer
        }
        .background(palette.rail)
        .sheet(item: $taskToRename) { task in
            TaskRenameSheet(task: task) { title in
                model.renameTask(task.id, title: title)
                taskToRename = nil
            } onCancel: {
                taskToRename = nil
            }
            .environmentObject(themeStore)
        }
        .alert(
            "End this runtime?",
            isPresented: Binding(
                get: { taskToEnd != nil },
                set: { if !$0 { taskToEnd = nil } }
            ),
            presenting: taskToEnd
        ) { task in
            Button("Cancel", role: .cancel) {
                taskToEnd = nil
            }
            Button("End Runtime", role: .destructive) {
                model.endTask(task.id)
                taskToEnd = nil
            }
        } message: { task in
            Text("This terminates the live process for “\(task.displayTitle)”. Its append-only task history remains available.")
        }
        .alert(
            "Task History Issues",
            isPresented: $showTaskHistoryDiagnostics
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(taskHistoryDiagnosticSummary)
        }
        .onChange(of: model.taskSearchFocusRequest) { _ in
            isTaskSearchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.showProjectBrowser = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.taskScopeProjectID == nil ? "square.grid.2x2" : "folder")
                        .accessibilityHidden(true)
                    Text(scopeTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.text)
            .accessibilityLabel("Browse project scope")
            .accessibilityValue(scopeTitle)
            .help("Choose which MainFrame task histories appear")

            Button {
                model.showNewTask = true
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(palette.accent)
                    .foregroundStyle(palette.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New Task")
            .help("Start a new agent task")
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 7)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.faint)
                .accessibilityHidden(true)
            TextField("Search tasks", text: $model.taskSearchText)
                .textFieldStyle(.plain)
                .foregroundStyle(palette.text)
                .focused($isTaskSearchFocused)
                .accessibilityLabel("Search task history")
            if !model.taskSearchText.isEmpty {
                Button {
                    model.taskSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(palette.dim)
                .accessibilityLabel("Clear task search")
                .help("Clear task search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.lineSoft, lineWidth: 1)
        )
        .padding(.horizontal, 9)
        .padding(.bottom, 9)
    }

    @ViewBuilder
    private func taskSection(
        _ title: String,
        rows: [TaskSessionCatalogRow]
    ) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                sectionLabel(title, count: rows.count)
                ForEach(rows) { row in
                    taskRow(row)
                }
            }
        }
    }

    private func sectionLabel(_ title: String, count: Int) -> some View {
        HStack {
            Text(title.uppercased())
            if usesExpandedLabels {
                Text("\(count)")
                    .foregroundStyle(palette.faint)
            }
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .tracking(0.7)
        .foregroundStyle(palette.dim)
        .padding(.horizontal, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) task\(count == 1 ? "" : "s")")
    }

    private func taskRow(_ row: TaskSessionCatalogRow) -> some View {
        let isSelected = model.selectedTaskSessionID == row.id
        return HStack(alignment: .center, spacing: 7) {
            Button {
                model.selectTask(row.id)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    taskIdentityMark(row, isSelected: isSelected)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(row.session.displayTitle)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if row.session.isPinned {
                                Image(systemName: "pin.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(palette.dim)
                                    .accessibilityLabel("Pinned")
                            }
                        }

                        Text(
                            usesExpandedLabels
                                ? taskMetadataLine(row.session)
                                : "\(taskMetadataLine(row.session)) · \(availabilityLabel(row.availability))"
                        )
                            .font(.system(size: 10))
                            .foregroundStyle(palette.dim)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if usesExpandedLabels {
                            Text(availabilityLabel(row.availability))
                                .font(.system(size: 10))
                                .foregroundStyle(palette.faint)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(taskAccessibilityLabel(row, isSelected: isSelected))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityHint(
                row.availability.kind == .reconnectable
                    ? "Selects recorded history without reconnecting"
                    : "Selects this task"
            )

            if row.availability.kind == .reconnectable {
                Button {
                    model.reconnectTask(row.id)
                } label: {
                    if usesExpandedLabels {
                        Text("Reconnect")
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.accent)
                .accessibilityLabel("Reconnect \(row.session.displayTitle)")
                .help("Explicitly reconnect to the observed tmux runtime")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, model.density == .focused ? 7 : 9)
        .background(isSelected ? palette.accentSoft : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(
                    isSelected ? palette.accent.opacity(0.36) : palette.lineSoft,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button("Rename…") {
                taskToRename = row.session
            }
            if row.session.titleOverride != nil {
                Button("Reset Title") {
                    model.renameTask(row.id, title: nil)
                }
            }
            Divider()
            Button(row.session.isPinned ? "Unpin" : "Pin") {
                model.setTaskPinned(row.id, pinned: !row.session.isPinned)
            }

            if row.availability.kind == .reconnectable {
                Button("Reconnect") {
                    model.reconnectTask(row.id)
                }
            }

            if row.session.isArchived {
                Divider()
                Button("Restore from Archive") {
                    model.setTaskArchived(row.id, archived: false)
                }
            } else if row.availability.kind == .running {
                Divider()
                Button("Leave Runtime") {
                    model.leaveTask(row.id)
                }
                Button("End Runtime…", role: .destructive) {
                    taskToEnd = row.session
                }
            } else if row.availability.kind != .reconnectable {
                Divider()
                Button("Archive History") {
                    model.setTaskArchived(row.id, archived: true)
                }
            }
        }
    }

    private var discoveredSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Not Conduit task history: live durable sessions you can open or
            // continue from here (including work started outside the UI).
            sectionLabel("Continue outside Conduit", count: discoveredRows.count)

            Text("tmux sessions still running on this Mac — open to inspect Raw or keep working. Not the same as app-store chat history.")
                .font(.system(size: 9))
                .foregroundStyle(palette.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 7)

            ForEach(discoveredRows, id: \.session.tmuxName) { row in
                discoveredRow(row)
            }

            Button {
                model.showResumeSessions = true
            } label: {
                Label("Browse all reconnectable…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 7)
            .padding(.top, 2)
            .accessibilityLabel("Browse all reconnectable sessions")
            .help("List every durable tmux session Conduit can attach to")
        }
    }

    private func discoveredRow(_ row: ResumableSession) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(palette.faint)
                .padding(.top, 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.session.agentName ?? "Unidentified session")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                Text(discoveredMetadataLine(row))
                    .font(.system(size: 9))
                    .foregroundStyle(palette.faint)
                    .lineLimit(usesExpandedLabels ? 2 : 1)
                    .truncationMode(.middle)
                if usesExpandedLabels {
                    Text(row.session.tmuxName)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.session.tmuxName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasMalformedBinding(row.session) {
                Text("Needs attention")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.dim)
                    .fixedSize()
                    .help(malformedBindingHelp(row.session))
            } else if row.session.projectPath == nil {
                Button("Choose Scope") {
                    model.showResumeSessions = true
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.accent)
                .accessibilityLabel("Choose a scope for \(row.session.agentName ?? "unidentified session")")
                .help("Open recovery details and explicitly choose a MainFrame scope")
            } else {
                Button("Resume") {
                    model.resume(row.session)
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(palette.accent)
                .accessibilityLabel("Resume \(row.session.agentName ?? "unidentified session")")
                .accessibilityHint("Explicitly attaches to this durable tmux session")
                .help("Resume this discovered tmux session")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(palette.surface.opacity(0.54))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.lineSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            if !hasMalformedBinding(row.session),
               row.session.projectPath != nil {
                Button("Resume") {
                    model.resume(row.session)
                }
            } else if !hasMalformedBinding(row.session) {
                Button("Choose Scope…") {
                    model.showResumeSessions = true
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Contextual identity only. The selected row may show an exact known
    /// profile; lifecycle text and the availability dot remain authoritative.
    /// This view has no action and never launches or reconnects a runtime.
    @ViewBuilder
    private func taskIdentityMark(
        _ row: TaskSessionCatalogRow,
        isSelected: Bool
    ) -> some View {
        if isSelected, let runtime = matchingRuntime(for: row) {
            TimelineView(.periodic(from: .now, by: 0.7)) { timeline in
                companionMark(
                    profile: runtime.descriptor.agent,
                    state: runtime.controller.visualState(at: timeline.date),
                    availability: row.availability
                )
            }
        } else if isSelected,
                  let profile = recordedGenericProfile(for: row.session),
                  let state = retainedCompanionState(for: row.availability) {
            companionMark(
                profile: profile,
                state: state,
                availability: row.availability
            )
        } else {
            Circle()
                .fill(availabilityColor(row.availability))
                .frame(width: 7, height: 7)
                .frame(width: 26, height: 26, alignment: .top)
                .padding(.top, 5)
                .accessibilityHidden(true)
        }
    }

    private func companionMark(
        profile: AgentProfile,
        state: TerminalVisualState,
        availability: TaskSessionAvailability
    ) -> some View {
        ZStack(alignment: .bottomTrailing) {
            AgentSpriteView(
                profile: profile,
                state: state,
                frameSize: CGSize(width: 22, height: 26)
            )
            Circle()
                .fill(availabilityColor(availability))
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .strokeBorder(palette.rail, lineWidth: 1)
                )
        }
        .frame(width: 26, height: 30)
        .accessibilityHidden(true)
    }

    private func matchingRuntime(for row: TaskSessionCatalogRow) -> TerminalRuntime? {
        let matches = model.sessions.filter {
            $0.descriptor.taskSessionID == row.id
        }
        return matches.first(where: { !$0.controller.lifecycle.isTerminal })
            ?? matches.first
    }

    private func recordedGenericProfile(
        for task: TaskSessionSnapshot
    ) -> AgentProfile? {
        guard let name = task.metadata.agentName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else {
            return nil
        }
        // Task history records a display name but not the executable signature.
        // Never join that older name to today's settings and accidentally grant
        // dedicated identity art. The recorded name can still label an honest
        // generic placeholder until a live/retained runtime supplies both fields.
        return AgentProfile(
            name: name,
            command: "conduit-history-executable-not-recorded",
            enabled: false
        )
    }

    private func selectedCompanionProfile(
        for row: TaskSessionCatalogRow
    ) -> AgentProfile? {
        if let runtime = matchingRuntime(for: row) {
            return runtime.descriptor.agent
        }
        guard retainedCompanionState(for: row.availability) != nil else {
            return nil
        }
        return recordedGenericProfile(for: row.session)
    }

    private func retainedCompanionState(
        for availability: TaskSessionAvailability
    ) -> TerminalVisualState? {
        switch availability {
        case .reconnectable:
            return .detached
        case .recentClosed:
            return .exited
        case .running, .interrupted, .unavailable, .unknown:
            return nil
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: model.taskSearchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(palette.faint)
            Text(model.taskSearchText.isEmpty ? "No task history in this scope" : "No tasks match this search")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.dim)
                .multilineTextAlignment(.center)
            if model.taskSearchText.isEmpty {
                Button("New Task") {
                    model.showNewTask = true
                }
                .buttonStyle(.borderless)
                .foregroundStyle(palette.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .contain)
    }

    private func openAppSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    private var footer: some View {
        Menu {
            Section("Workspace") {
                Button {
                    openAppSettings()
                } label: {
                    Label("Settings…", systemImage: "gearshape")
                }
                Button {
                    model.chooseMainframeRoot()
                } label: {
                    Label("Choose MainFrame Root…", systemImage: "folder")
                }
                Button {
                    refreshSources()
                } label: {
                    Label("Refresh Projects & Sessions", systemImage: "arrow.clockwise")
                }
                .disabled(model.isScanningProjects || model.rootAccessNeedsAuthorization)
            }

            Section("Tools") {
                Button {
                    model.showDiagnostics = true
                } label: {
                    Label("Conduit Doctor", systemImage: "stethoscope")
                }
                Button {
                    model.showResources = true
                } label: {
                    Label("Resource Deck", systemImage: "gauge.with.dots.needle.33percent")
                }
                Button {
                    model.showAgentUsage = true
                } label: {
                    Label("Agent Usage", systemImage: "chart.bar")
                }
                Button {
                    model.showMindGraph = true
                } label: {
                    Label("MindGraph…", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }

            Section("Task history") {
                Button(model.showArchivedTasks ? "Hide Archived Tasks" : "Show Archived Tasks") {
                    model.showArchivedTasks.toggle()
                }
                if !model.taskSessionDiagnostics.isEmpty {
                    Button("Task History Issues (\(model.taskSessionDiagnostics.count))…") {
                        showTaskHistoryDiagnostics = true
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                Text("Tools")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.faint)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .help("Settings, Doctor, Resources, Usage, MindGraph, and workspace actions")
        .accessibilityLabel("Tools menu")
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(palette.surface)
    }

    private var scopeTitle: String {
        guard let scopeID = model.taskScopeProjectID,
              let project = model.projects.first(where: { $0.id == scopeID })
        else {
            return "All MainFrame"
        }
        return project.isMainframeRoot
            ? "\(project.metadata.title) Root"
            : project.metadata.title
    }

    private var taskHistoryDiagnosticSummary: String {
        let diagnostics = model.taskSessionDiagnostics
        guard !diagnostics.isEmpty else {
            return "No task-history issues were found."
        }
        let visible = diagnostics.prefix(6).map { diagnostic in
            let line = diagnostic.lineNumber.map { " line \($0)" } ?? ""
            return "• \(diagnostic.fileURL.lastPathComponent)\(line): \(diagnostic.detail)"
        }
        let remainder = diagnostics.count - visible.count
        let suffix = remainder > 0
            ? "\n\n…and \(remainder) more. Raw JSONL sources were preserved."
            : "\n\nRaw JSONL sources were preserved."
        return visible.joined(separator: "\n") + suffix
    }

    private func taskMetadataLine(_ task: TaskSessionSnapshot) -> String {
        let workspace = resolvedWorkspaceTitle(task.metadata.workspace)
        guard let agent = task.metadata.agentName, !agent.isEmpty else {
            return workspace
        }
        return "\(agent) · \(workspace)"
    }

    private func resolvedWorkspaceTitle(_ snapshot: WorkspaceScopeSnapshot) -> String {
        let expectedPath = snapshot.projectPath ?? snapshot.rootPath
        if let current = model.projects.first(where: {
            $0.path.standardizedFileURL.path == expectedPath
        }) {
            return current.metadata.title
        }
        return snapshot.fallbackTitle
    }

    private func availabilityLabel(_ availability: TaskSessionAvailability) -> String {
        switch availability {
        case .running:
            return "Running"
        case .reconnectable:
            return "Reconnect available"
        case .recentClosed(let date, _):
            return "Closed \(Self.relative.localizedString(for: date, relativeTo: Date()))"
        case .interrupted:
            return "Interrupted"
        case .unavailable:
            return "Not reconnectable"
        case .unknown:
            return "Status unknown"
        }
    }

    private func availabilityColor(_ availability: TaskSessionAvailability) -> Color {
        switch availability {
        case .running:
            return palette.text
        case .reconnectable:
            return palette.dim
        case .recentClosed:
            return palette.faint.opacity(0.65)
        case .interrupted, .unavailable, .unknown:
            return palette.faint
        }
    }

    private func taskAccessibilityLabel(
        _ row: TaskSessionCatalogRow,
        isSelected: Bool
    ) -> String {
        var parts = [
            row.session.displayTitle,
            taskMetadataLine(row.session),
            availabilityLabel(row.availability)
        ]
        if isSelected, let profile = selectedCompanionProfile(for: row) {
            parts.append(
                AgentSpriteResources.accessibilityDescription(for: profile)
            )
        }
        return parts.joined(separator: ", ")
    }

    private func discoveredRowMatchesScope(_ row: ResumableSession) -> Bool {
        guard let scopeID = model.taskScopeProjectID else { return true }
        guard let project = model.projects.first(where: { $0.id == scopeID }),
              let discoveredPath = row.session.projectPath
        else {
            return false
        }
        return project.path.standardizedFileURL.path
            == discoveredPath.standardizedFileURL.path
    }

    private func discoveredRowMatchesSearch(_ row: ResumableSession) -> Bool {
        let query = Self.normalized(model.taskSearchText)
        guard !query.isEmpty else { return true }
        let session = row.session
        let text = [
            session.agentName ?? "",
            session.tmuxName,
            session.projectPath?.path ?? "",
            discoveredRelationLabel(row)
        ].joined(separator: "\n")
        return Self.normalized(text).contains(query)
    }

    private func discoveredMetadataLine(_ row: ResumableSession) -> String {
        var parts = [discoveredRelationLabel(row)]
        if row.session.attachedClients > 0 {
            parts.append("attached elsewhere")
        }
        if let createdAt = row.session.createdAt {
            parts.append(
                "started \(Self.relative.localizedString(for: createdAt, relativeTo: Date()))"
            )
        }
        return parts.joined(separator: " · ")
    }

    private func discoveredRelationLabel(_ row: ResumableSession) -> String {
        switch row.relation {
        case .alreadyOpen:
            return "Already open"
        case .resumableHere:
            return "Current project"
        case .otherProject(let projectTitle):
            return projectTitle
        case .unidentified:
            return "Project or agent not recorded"
        }
    }

    private func hasMalformedBinding(_ session: DiscoveredSession) -> Bool {
        if case .malformed = session.taskSessionBinding {
            return true
        }
        return false
    }

    private func malformedBindingHelp(_ session: DiscoveredSession) -> String {
        guard case .malformed(let rawValue) = session.taskSessionBinding else {
            return ""
        }
        return "The tmux task-session binding is malformed (\(rawValue)). Conduit will not resume or rewrite it automatically; inspect the @conduit_task_session tmux option before proceeding."
    }

    private func refreshSources() {
        model.refreshProjects()
        Task {
            await model.refreshDiscoveredSessions()
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct TaskRenameSheet: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let task: TaskSessionSnapshot
    let onSave: (String?) -> Void
    let onCancel: () -> Void

    @State private var title: String
    @FocusState private var isTitleFocused: Bool

    init(
        task: TaskSessionSnapshot,
        onSave: @escaping (String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.task = task
        self.onSave = onSave
        self.onCancel = onCancel
        self._title = State(initialValue: task.titleOverride ?? task.displayTitle)
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename Task")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Text("This records an operator-supplied display title. It does not change the agent session or MainFrame project.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFocused)
                .accessibilityLabel("Task title")
                .onSubmit(save)

            HStack {
                Button("Reset to Recorded Default") {
                    onSave(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(palette.dim)
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(palette.canvas)
        .onAppear {
            Task {
                await Task.yield()
                isTitleFocused = true
            }
        }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(trimmed.isEmpty ? nil : trimmed)
    }
}
#endif
