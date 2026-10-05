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
    /// AppModel is retained for action authority only. Presentation reads from
    /// the narrow sidebar model so live conversation revisions cannot
    /// invalidate this view.
    private let model: AppModel
    @ObservedObject private var sidebar: TaskSidebarModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var taskToRename: TaskSessionSnapshot?
    @State private var taskToEnd: TaskSessionSnapshot?
    @State private var showTaskHistoryDiagnostics = false
    @State private var hoveredTaskSessionID: TaskSessionID?
    @State private var recognitionTaskSessionID: TaskSessionID?
    @State private var recognitionSnapshot: ThreadRecognitionSnapshot?
    @FocusState private var isTaskSearchFocused: Bool
    @FocusState private var focusedTaskRowID: UUID?

    init(model: AppModel, sidebarModel: TaskSidebarModel) {
        self.model = model
        self._sidebar = ObservedObject(wrappedValue: sidebarModel)
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var inboxAttention: AgentInboxAttention {
        AgentInboxAttention.from(
            pinned: pinnedRows,
            active: activeRows,
            recent: recentRows,
            archived: archivedRows,
            discoveredCount: discoveredRows.count
        )
    }

    private var playJuicyChrome: Bool {
        JuicyFeedbackPolicy.shouldPlayChromeMotion(
            juicyEnabled: sidebar.juicyFeedbackEnabled,
            reduceMotion: reduceMotion
        )
    }

    /// Hover takes precedence over keyboard focus. Neither path selects the task
    /// or changes provider/runtime authority.
    private var recognitionTargetID: TaskSessionID? {
        if let hoveredTaskSessionID {
            return hoveredTaskSessionID
        }
        return focusedTaskRowID.map { TaskSessionID(rawValue: $0) }
    }

    private var pinnedRows: [TaskSessionCatalogRow] {
        sidebar.taskCatalogRows.filter {
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
        sidebar.taskCatalogRows.filter {
            !$0.session.isPinned
                && !$0.session.isArchived
                && ($0.availability.kind == .running
                    || $0.availability.kind == .reconnectable)
        }
    }

    private var recentRows: [TaskSessionCatalogRow] {
        sidebar.taskCatalogRows.filter {
            !$0.session.isPinned
                && !$0.session.isArchived
                && $0.availability.kind != .running
                && $0.availability.kind != .reconnectable
        }
    }

    private var archivedRows: [TaskSessionCatalogRow] {
        sidebar.taskCatalogRows.filter(\.session.isArchived)
    }

    /// Durable sessions are a recovery surface, not another task-history
    /// authority. A discovered row disappears when its task identity is
    /// already represented by loaded history or an open runtime.
    private var discoveredRows: [ResumableSession] {
        var representedTaskIDs = Set(sidebar.taskSessions.map(\.id))
        representedTaskIDs.formUnion(
            sidebar.sessions.compactMap(\.descriptor.taskSessionID)
        )

        return sidebar.resumableSessions.filter { row in
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
        sidebar.density != .focused
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider().overlay(palette.line)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    inboxSummary

                    if !pinnedRows.isEmpty {
                        taskSection(
                            "Pinned",
                            rows: pinnedRows,
                            emphasis: .secondary
                        )
                    }
                    taskSection(
                        "Active",
                        rows: activeRows,
                        emphasis: .primary,
                        attentionCount: inboxAttention.reconnectable > 0
                            ? inboxAttention.reconnectable
                            : nil
                    )
                    taskSection(
                        "Recent",
                        rows: recentRows,
                        emphasis: .tertiary
                    )
                    if sidebar.showArchivedTasks {
                        taskSection(
                            "Archived",
                            rows: archivedRows,
                            emphasis: .tertiary
                        )
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
        .onChange(of: sidebar.taskSearchFocusRequest) { _ in
            isTaskSearchFocused = true
        }
        .task(id: recognitionTargetID?.rawValue) {
            guard let taskID = recognitionTargetID else {
                recognitionTaskSessionID = nil
                recognitionSnapshot = nil
                return
            }
            recognitionTaskSessionID = taskID
            recognitionSnapshot = nil
            let snapshot = await model.threadRecognitionSnapshot(for: taskID)
            guard recognitionTargetID == taskID else { return }
            recognitionSnapshot = snapshot
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                model.showProjectBrowser = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: sidebar.taskScopeProjectID == nil ? "square.grid.2x2" : "folder")
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
            TextField(
                "Search tasks",
                text: Binding(
                    get: { sidebar.taskSearchText },
                    set: { model.taskSearchText = $0 }
                )
            )
                .textFieldStyle(.plain)
                .foregroundStyle(palette.text)
                .focused($isTaskSearchFocused)
                .accessibilityLabel("Search task history")
            if !sidebar.taskSearchText.isEmpty {
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

    private enum SectionEmphasis {
        case primary
        case secondary
        case tertiary
    }

    private var inboxSummary: some View {
        let attention = inboxAttention
        return VStack(alignment: .leading, spacing: 4) {
            Text("INBOX")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(palette.faint)
            Text(attention.summaryLine)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    attention.needsAttention > 0 ? palette.accent : palette.dim
                )
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if attention.needsAttention > 0 {
                Text("Reconnect is explicit; selection never attaches.")
                    .font(.system(size: 9))
                    .foregroundStyle(palette.faint)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.lineSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent inbox, \(attention.summaryLine)")
    }

    @ViewBuilder
    private func taskSection(
        _ title: String,
        rows: [TaskSessionCatalogRow],
        emphasis: SectionEmphasis = .secondary,
        attentionCount: Int? = nil
    ) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                sectionLabel(
                    title,
                    count: rows.count,
                    emphasis: emphasis,
                    attentionCount: attentionCount
                )
                ForEach(rows) { row in
                    taskRow(row)
                    if sidebar.companionShelfEnabled,
                       sidebar.density != .focused,
                       sidebar.selectedTaskSessionID == row.id {
                        selectedCompanionShelf(for: row)
                    }
                }
            }
        }
    }

    private func sectionLabel(
        _ title: String,
        count: Int,
        emphasis: SectionEmphasis,
        attentionCount: Int?
    ) -> some View {
        let color: Color = {
            switch emphasis {
            case .primary: return palette.text
            case .secondary: return palette.dim
            case .tertiary: return palette.faint
            }
        }()
        return HStack(spacing: 6) {
            Text(title.uppercased())
            if usesExpandedLabels {
                Text("\(count)")
                    .foregroundStyle(palette.faint)
            }
            if let attentionCount, attentionCount > 0, usesExpandedLabels {
                Text("· \(attentionCount) need you")
                    .foregroundStyle(palette.accent)
            }
            Spacer(minLength: 0)
        }
        .font(
            .system(
                size: emphasis == .primary ? 11 : 10,
                weight: emphasis == .primary ? .bold : .semibold,
                design: .monospaced
            )
        )
        .tracking(0.7)
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            attentionCount.map {
                "\(title), \(count) tasks, \($0) reconnectable"
            } ?? "\(title), \(count) task\(count == 1 ? "" : "s")"
        )
    }

    private func taskRow(_ row: TaskSessionCatalogRow) -> some View {
        let isSelected = sidebar.selectedTaskSessionID == row.id
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 7) {
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
                            Spacer(minLength: 4)
                            let cue = taskRecencyCue(row.session)
                            HStack(spacing: 3) {
                                Image(systemName: cue.isConversation ? "bubble.left" : "clock")
                                    .font(.system(size: 8))
                                    .accessibilityHidden(true)
                                Text(cue.compact)
                                    .font(.system(size: 9, design: .monospaced))
                            }
                            .foregroundStyle(palette.faint)
                            .help(cue.help)
                            .accessibilityLabel(cue.accessibilityLabel)
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
            // Recognition is a focus-driven inspection affordance, not only
            // button activation. Explicit participation keeps task rows
            // keyboard-reachable on modern macOS without requiring the global
            // Keyboard Navigation setting.
            .focusable()
            .focused($focusedTaskRowID, equals: row.id.rawValue)
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

            if recognitionTargetID == row.id {
                threadRecognitionCard(row)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, sidebar.density == .focused ? 7 : 9)
        .background(isSelected ? palette.accentSoft : Color.clear)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(
                    isSelected ? palette.accent.opacity(0.42) : palette.lineSoft,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .onHover { isInside in
            if isInside {
                hoveredTaskSessionID = row.id
            } else if hoveredTaskSessionID == row.id {
                hoveredTaskSessionID = nil
            }
        }
        .scaleEffect(isSelected && playJuicyChrome ? 1.01 : 1.0)
        .animation(
            playJuicyChrome
                ? .easeOut(duration: JuicyFeedbackPolicy.selectDuration)
                : nil,
            value: isSelected
        )
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
            sectionLabel(
                "Continue outside Conduit",
                count: discoveredRows.count,
                emphasis: .secondary,
                attentionCount: nil
            )

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

    /// Contextual identity only. Lifecycle text and the availability dot remain
    /// authoritative. This view has no action and never launches or reconnects.
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
                    availability: row.availability,
                    prominence: .selected
                )
            }
        } else if isSelected,
                  let profile = recordedGenericProfile(for: row.session),
                  let state = retainedCompanionState(for: row.availability) {
            companionMark(
                profile: profile,
                state: state,
                availability: row.availability,
                prominence: .selected
            )
        } else if sidebar.railSpritesForAllRows,
                  let profile = recordedGenericProfile(for: row.session),
                  let state = retainedCompanionState(for: row.availability)
                    ?? (row.availability.kind == .running ? .running : nil) {
            companionMark(
                profile: profile,
                state: state,
                availability: row.availability,
                prominence: .row
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

    private enum CompanionProminence {
        case row
        case selected
        case shelf
    }

    private func companionMark(
        profile: AgentProfile,
        state: TerminalVisualState,
        availability: TaskSessionAvailability,
        prominence: CompanionProminence
    ) -> some View {
        let side: CGFloat = {
            switch prominence {
            case .row:
                return CGFloat(sidebar.companionScale.railSpriteSide)
            case .selected:
                return CGFloat(max(sidebar.companionScale.railSpriteSide, 26))
            case .shelf:
                return CGFloat(sidebar.companionScale.spriteSide)
            }
        }()
        let pulse =
            sidebar.outputActivePulseEnabled
            && state == .working
            && JuicyFeedbackPolicy.shouldPlayChromeMotion(
                juicyEnabled: sidebar.juicyFeedbackEnabled,
                reduceMotion: reduceMotion
            )
        return ZStack(alignment: .bottomTrailing) {
            AgentSpriteView(
                profile: profile,
                state: state,
                frameSize: CGSize(width: side, height: side + 4)
            )
            .scaleEffect(pulse ? 1.04 : 1.0)
            .animation(
                pulse
                    ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            Circle()
                .fill(availabilityColor(availability))
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .strokeBorder(palette.rail, lineWidth: 1)
                )
        }
        .frame(width: side + 4, height: side + 8)
        .accessibilityHidden(true)
    }

    /// Larger selected companion under the row (Balanced/Operator). Presentation
    /// only — never launches, reconnects, or sends.
    @ViewBuilder
    private func selectedCompanionShelf(
        for row: TaskSessionCatalogRow
    ) -> some View {
        if let runtime = matchingRuntime(for: row) {
            TimelineView(.periodic(from: .now, by: 0.7)) { timeline in
                let state = runtime.controller.visualState(at: timeline.date)
                companionShelfChrome(
                    profile: runtime.descriptor.agent,
                    state: state,
                    availability: row.availability,
                    lifecycleLine: state.spriteCue.accessibilityPhrase
                )
            }
        } else if let profile = selectedCompanionProfile(for: row),
                  let state = retainedCompanionState(for: row.availability) {
            companionShelfChrome(
                profile: profile,
                state: state,
                availability: row.availability,
                lifecycleLine: availabilityLabel(row.availability)
            )
        }
    }

    private func companionShelfChrome(
        profile: AgentProfile,
        state: TerminalVisualState,
        availability: TaskSessionAvailability,
        lifecycleLine: String
    ) -> some View {
        let artwork = AgentSpriteResources.accessibilityDescription(for: profile)
        let fallback = AgentSpriteResources.visibleFallbackLabel(for: profile)
        return HStack(spacing: 10) {
            companionMark(
                profile: profile,
                state: state,
                availability: availability,
                prominence: .shelf
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                Text(lifecycleLine)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.dim)
                    .lineLimit(2)
                if let fallback {
                    Text(fallback)
                        .font(.system(size: 9))
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(palette.accent.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(profile.name) companion, \(lifecycleLine), \(artwork)"
        )
        .accessibilityHint("Presentation only. Does not launch or reconnect.")
    }

    private func matchingRuntime(for row: TaskSessionCatalogRow) -> TerminalRuntime? {
        let matches = sidebar.sessions.filter {
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
            Image(systemName: sidebar.taskSearchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(palette.faint)
            Text(sidebar.taskSearchText.isEmpty ? "No task history in this scope" : "No tasks match this search")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.dim)
                .multilineTextAlignment(.center)
            if sidebar.taskSearchText.isEmpty {
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
        model.openSettings()
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
                .disabled(sidebar.isScanningProjects || sidebar.rootAccessNeedsAuthorization)
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
                Button(sidebar.showArchivedTasks ? "Hide Archived Tasks" : "Show Archived Tasks") {
                    model.showArchivedTasks.toggle()
                }
                if !sidebar.taskSessionDiagnostics.isEmpty {
                    Button("Task History Issues (\(sidebar.taskSessionDiagnostics.count))…") {
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
        guard let scopeID = sidebar.taskScopeProjectID,
              let project = sidebar.projects.first(where: { $0.id == scopeID })
        else {
            return "All MainFrame"
        }
        return project.isMainframeRoot
            ? "\(project.metadata.title) Root"
            : project.metadata.title
    }

    private var taskHistoryDiagnosticSummary: String {
        let diagnostics = sidebar.taskSessionDiagnostics
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

    private struct TaskRecencyCue {
        let compact: String
        let isConversation: Bool
        let help: String
        let accessibilityLabel: String
    }

    private func taskRecencyCue(_ task: TaskSessionSnapshot) -> TaskRecencyCue {
        let isConversation = task.lastConversationActivityAt != nil
        let date = task.lastConversationActivityAt ?? task.lastActivityAt
        let compact = compactRecency(date)
        let exact = exactTimestamp(date)
        let subject = isConversation ? "Last conversation activity" : "Last task activity"
        return TaskRecencyCue(
            compact: compact,
            isConversation: isConversation,
            help: "\(subject): \(exact)",
            accessibilityLabel: "\(subject), \(exact)"
        )
    }

    private func compactRecency(_ date: Date, now: Date = Date()) -> String {
        let interval = max(0, now.timeIntervalSince(date))
        if interval < 60 {
            return "now"
        }
        if interval < 3_600 {
            return "\(max(1, Int(interval / 60)))m"
        }
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day())
    }

    private func exactTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    @ViewBuilder
    private func threadRecognitionCard(_ row: TaskSessionCatalogRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("THREAD")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(palette.dim)
                Spacer(minLength: 4)
                if recognitionTaskSessionID == row.id,
                   let recognitionSnapshot {
                    Text(recognitionSourceLabel(recognitionSnapshot.source))
                        .font(.system(size: 9))
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                } else {
                    Text("Loading retained context…")
                        .font(.system(size: 9))
                        .foregroundStyle(palette.faint)
                }
            }

            if recognitionTaskSessionID == row.id,
               let recognitionSnapshot {
                promptRecognition(recognitionSnapshot.latestPrompt)
                outputRecognition(recognitionSnapshot.latestOutputBlock)
            }
        }
        .padding(8)
        .background(palette.surface.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(palette.lineSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thread recognition preview for \(row.session.displayTitle)")
    }

    @ViewBuilder
    private func promptRecognition(
        _ fact: ThreadRecognitionFact<ThreadRecognitionPrompt>
    ) -> some View {
        switch fact {
        case .observed(let prompt):
            VStack(alignment: .leading, spacing: 2) {
                Text("Prompt · \(prompt.origin.displayName) · \(exactTimestamp(prompt.event.occurredAt))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.dim)
                Text(prompt.preview.text.isEmpty ? "No prompt text retained." : prompt.preview.text)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if prompt.preview.wasClipped || prompt.preview.sourceWasTruncated {
                    Text("Excerpt is bounded.")
                        .font(.system(size: 8))
                        .foregroundStyle(palette.faint)
                }
            }
        case .notObserved(let coverage):
            Text("No prompt observed in \(recognitionCoverageLabel(coverage).lowercased()).")
                .font(.system(size: 9))
                .foregroundStyle(palette.faint)
        case .unavailable(let reason):
            Text("Prompt unavailable: \(recognitionUnavailableLabel(reason)).")
                .font(.system(size: 9))
                .foregroundStyle(palette.faint)
        }
    }

    @ViewBuilder
    private func outputRecognition(
        _ fact: ThreadRecognitionFact<ThreadRecognitionOutput>
    ) -> some View {
        switch fact {
        case .observed(let output):
            VStack(alignment: .leading, spacing: 2) {
                Text("Output · \(output.extraction.displayName) · \(exactTimestamp(output.event.occurredAt))")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(palette.dim)
                Text(output.preview.text.isEmpty ? "No output text retained." : output.preview.text)
                    .font(.system(size: 10))
                    .foregroundStyle(palette.text)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if output.preview.wasClipped || output.preview.sourceWasTruncated {
                    Text("Excerpt is bounded.")
                        .font(.system(size: 8))
                        .foregroundStyle(palette.faint)
                }
            }
        case .notObserved(let coverage):
            Text("No output observed in \(recognitionCoverageLabel(coverage).lowercased()).")
                .font(.system(size: 9))
                .foregroundStyle(palette.faint)
        case .unavailable(let reason):
            Text("Output unavailable: \(recognitionUnavailableLabel(reason)).")
                .font(.system(size: 9))
                .foregroundStyle(palette.faint)
        }
    }

    private func recognitionSourceLabel(_ source: ThreadRecognitionSourceState) -> String {
        switch source {
        case .retained(let coverage):
            return recognitionCoverageLabel(coverage)
        case .unavailable(let reason):
            return "Unavailable · \(recognitionUnavailableLabel(reason))"
        }
    }

    private func recognitionCoverageLabel(_ coverage: ThreadRecognitionCoverage) -> String {
        switch coverage {
        case .completeRetainedTimeline:
            return "Retained timeline"
        case .boundedRetainedWindow:
            return "Retained window"
        }
    }

    private func recognitionUnavailableLabel(
        _ reason: ThreadRecognitionUnavailableReason
    ) -> String {
        switch reason {
        case .sourceNotLoaded: return "source not loaded"
        case .sourceMissing: return "source missing"
        case .sourceUnreadable: return "source unreadable"
        case .sourceHasDiagnostics: return "source has diagnostics"
        case .duplicateEventIdentity: return "duplicate event identity"
        case .invalidEventAuthority: return "invalid event authority"
        case .invalidEventTime: return "invalid event time"
        case .invalidPreviewByteLimit: return "invalid preview limit"
        case .notRetainedByInputContract: return "not retained by the input contract"
        }
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
        if let current = sidebar.projects.first(where: {
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
        guard let scopeID = sidebar.taskScopeProjectID else { return true }
        guard let project = sidebar.projects.first(where: { $0.id == scopeID }),
              let discoveredPath = row.session.projectPath
        else {
            return false
        }
        return project.path.standardizedFileURL.path
            == discoveredPath.standardizedFileURL.path
    }

    private func discoveredRowMatchesSearch(_ row: ResumableSession) -> Bool {
        let query = Self.normalized(sidebar.taskSearchText)
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
