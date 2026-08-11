#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

struct WorkspaceHeader: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var contextButtonFocused: Bool
    @AccessibilityFocusState private var contextButtonAccessibilityFocused: Bool
    let project: MainframeProject
    let inspectorFocusRequest: Int

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    /// Focused hides action titles; Balanced/Operator show icon + label.
    private var showsActionLabels: Bool {
        model.density != .focused
    }

    /// Resource summary is Balanced/Operator only.
    private var showsResourceSummary: Bool {
        model.density != .focused
    }

    private var contextButtonSymbol: String {
        // sidebar.right is available on macOS 13; filled variant marks open state.
        model.isContextInspectorPresented
            ? "sidebar.right"
            : "rectangle.righthalf.inset.filled"
    }

    private var contextButtonAccessibilityLabel: String {
        model.isContextInspectorPresented ? "Hide inspector" : "Show inspector"
    }

    private var contextButtonAccessibilityValue: String {
        model.isContextInspectorPresented ? "Shown" : "Hidden"
    }

    private var contextButtonHelp: String {
        model.isContextInspectorPresented
            ? "Hide the right inspector (Command-Backslash)"
            : "Show the right inspector: Session, Files, Review, Context, and Usage (Command-Backslash)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedTaskSnapshot?.displayTitle ?? project.metadata.title)
                    .font(.headline)
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(model.selectedTaskSnapshot?.displayTitle ?? project.metadata.title)
                Text(taskSubtitle)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(taskSubtitle)
            }
            .frame(minWidth: 120, idealWidth: 210, maxWidth: 340, alignment: .leading)
            .layoutPriority(1)

            if showsResourceSummary {
                resourceSummary
            }

            Spacer(minLength: 4)

            Button {
                model.showNewTask = true
            } label: {
                actionLabel("New Task", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("New Task")
            .help("Start an agent task and choose its MainFrame scope")

            Menu {
                Button("Move selection to composer", action: model.beginForwardingToComposer)
                Divider()
                ForEach(model.forwardableAgents) { agent in
                    Button("Send to \(agent.name)") { model.beginForwarding(to: agent) }
                }
            } label: {
                actionLabel("Forward", systemImage: "arrowshape.turn.up.right")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Forward copied terminal output")
            .help("Stage copied terminal output for review before sending")

            Menu {
                Button("Build Context Bundle", action: model.prepareContextBundle)
                Button("Open Project Shell", action: {
                    model.launchDefaultShell()
                })
                Button("Resume Durable Session…") {
                    model.showResumeSessions = true
                }
                Button("Resource Deck") { model.showResources = true }
                Button("Conduit Doctor") { model.showDiagnostics = true }
            } label: {
                actionLabel("Tools", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Workspace tools")
            .help("Context bundle, resources, and diagnostics")

            Button {
                model.toggleContextPresentation()
            } label: {
                if showsActionLabels {
                    Label("Inspector", systemImage: contextButtonSymbol)
                } else {
                    Image(systemName: contextButtonSymbol)
                }
            }
            .buttonStyle(.bordered)
            .focused($contextButtonFocused)
            .accessibilityFocused($contextButtonAccessibilityFocused)
            .accessibilityLabel(contextButtonAccessibilityLabel)
            .accessibilityValue(contextButtonAccessibilityValue)
            .help(contextButtonHelp)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .onChange(of: inspectorFocusRequest) { request in
            if request > 0 {
                DispatchQueue.main.async {
                    contextButtonFocused = true
                    contextButtonAccessibilityFocused = true
                }
            }
        }
    }

    private var taskSubtitle: String {
        guard let task = model.selectedTaskSnapshot else {
            return project.path.path
        }
        let agent = task.metadata.agentName ?? "Agent not recorded"
        return "\(agent) · \(project.metadata.title) · \(project.path.path)"
    }

    @ViewBuilder
    private func actionLabel(_ title: String, systemImage: String) -> some View {
        if showsActionLabels {
            Label(title, systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
        }
    }

    /// Compact observed resource strip. Values come only from
    /// `resourceSnapshot` and live session state; absent data shows "—" / "none".
    private var resourceSummary: some View {
        let snapshot = model.resourceSnapshot
        let sessions = model.sessionsForSelectedProject
        let tmuxCount = sessions.filter(\.controller.usesTmux).count
        let ramValue: String = {
            guard snapshot.totalMemoryGB > 0 else { return "—" }
            return String(format: "%.1f/%.0f GB", snapshot.usedMemoryGB, snapshot.totalMemoryGB)
        }()
        let ollamaValue: String = {
            if snapshot.capturedAt == .distantPast {
                return "—"
            }
            if snapshot.ollamaModels.isEmpty {
                return "none"
            }
            return snapshot.ollamaModels.joined(separator: ", ")
        }()
        let sessionValue: String = {
            if sessions.isEmpty {
                return "0"
            }
            // Prefer tmux count when any durable session is present; else total tabs.
            return tmuxCount > 0 ? "\(tmuxCount)" : "\(sessions.count)"
        }()
        let sessionKey = tmuxCount > 0 ? "tmux" : "sessions"

        return HStack(spacing: 0) {
            resourceCell(key: "RAM", value: ramValue)
            Divider().frame(height: 28)
            resourceCell(key: sessionKey, value: sessionValue)
            Divider().frame(height: 28)
            resourceCell(key: "Ollama", value: ollamaValue, compact: true)
        }
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Resource summary")
        .accessibilityValue("RAM \(ramValue), \(sessionKey) \(sessionValue), Ollama \(ollamaValue)")
    }

    private func resourceCell(key: String, value: String, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(palette.faint)
            Text(value)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minWidth: compact ? 72 : 78, alignment: .leading)
    }
}

/// Density-aware work-session card for the project rail.
///
/// Focused: compact strip with Close & Receipt as an accessible icon.
/// Balanced/Operator: expanded objective, note, and labeled Close & Receipt.
/// Live/idle uses the neutral palette ramp — never accent as state evidence.
/// Receipt reveal shows `RECORDED` only after a successful writer return.
struct WorkSessionBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let project: MainframeProject
    @State private var showReceiptNote = false

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var isCompact: Bool {
        model.density == .focused
    }

    private var isWritePending: Bool {
        model.isReceiptWritePending(for: project.id)
    }

    private var recordedResult: RecordedReceiptResult? {
        model.recordedReceipt(for: project.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 9) {
            headerRow

            if let session = model.workSession(for: project) {
                // Active controls stay usable even when another project shows a reveal.
                activeBody(session: session)
            } else if isWritePending {
                pendingBody
            } else if let result = recordedResult {
                ReceiptRevealView(result: result)
            } else {
                idleBody
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, isCompact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(
                    recordedResult != nil ? palette.accent.opacity(0.55) : palette.line,
                    lineWidth: 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Work session")
    }

    private var headerRow: some View {
        let isLive = model.workSession(for: project) != nil
        let lifecycleLabel: String = {
            if isLive { return "LIVE" }
            if isWritePending { return "WRITING" }
            if recordedResult != nil { return "RECORDED" }
            return "IDLE"
        }()
        let lifecycleA11y: String = {
            if isLive { return "Work session live" }
            if isWritePending { return "Writing receipt" }
            if recordedResult != nil { return "Receipt recorded" }
            return "Work session idle"
        }()
        // Lifecycle chrome stays on the neutral ramp; accent is only reward chrome.
        let lifecycleColor = (isLive || isWritePending || recordedResult != nil)
            ? palette.dim
            : palette.faint
        return HStack(spacing: 8) {
            Text("WORK SESSION")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(palette.faint)
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Circle()
                    .fill(lifecycleColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(lifecycleLabel)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundStyle(lifecycleColor)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(lifecycleA11y)
        }
    }

    @ViewBuilder
    private func activeBody(session: ActiveWorkSession) -> some View {
        if isCompact {
            compactActiveBody(session: session)
        } else {
            expandedActiveBody(session: session)
        }
    }

    private func compactActiveBody(session: ActiveWorkSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(session.startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(palette.ink)
                    .accessibilityLabel("Elapsed")
                Spacer(minLength: 4)
                receiptNoteButton(session: session)
                closeReceiptButton(compact: true)
            }
            TextField("Objective", text: model.objectiveBinding(for: project))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit { model.commitWorkSessionFields(for: project) }
                .accessibilityLabel("Work session objective")
        }
    }

    private func expandedActiveBody(session: ActiveWorkSession) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text("OBJECTIVE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(palette.faint)
                TextField("Objective", text: model.objectiveBinding(for: project))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.commitWorkSessionFields(for: project) }
                    .accessibilityLabel("Work session objective")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("ELAPSED")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(palette.faint)
                Text(session.startedAt, style: .timer)
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(palette.ink)
            }

            HStack(spacing: 8) {
                receiptNoteButton(session: session)
                if !session.notes.isEmpty {
                    Text("Note set")
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }

            closeReceiptButton(compact: false)
        }
    }

    /// Neutral pending feedback while snapshot/render/write runs. Not success.
    private var pendingBody: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Writing receipt…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.dim)
                Text("No success claim until the writer returns a path.")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Writing receipt")
        .accessibilityValue("Pending. No success claim until the writer returns a path.")
    }

    private var idleBody: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "record.circle")
                .foregroundStyle(palette.faint)
                .accessibilityHidden(true)
            Text("Launch an agent to begin an evidence-aware work session.")
                .font(.caption)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No work session. Launch an agent to begin an evidence-aware work session.")
    }

    private func receiptNoteButton(session: ActiveWorkSession) -> some View {
        Button {
            showReceiptNote.toggle()
        } label: {
            if isCompact {
                Image(systemName: session.notes.isEmpty ? "note.text.badge.plus" : "note.text")
            } else {
                Label(
                    session.notes.isEmpty ? "Add note" : "Edit note",
                    systemImage: session.notes.isEmpty ? "note.text.badge.plus" : "note.text"
                )
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(session.notes.isEmpty ? "Add receipt note" : "Edit receipt note")
        .help(session.notes.isEmpty ? "Add an optional receipt note" : "Edit the receipt note")
        .popover(isPresented: $showReceiptNote) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Receipt note")
                    .font(.headline)
                    .foregroundStyle(palette.text)
                Text("Record an operator observation. This does not claim the terminal work succeeded.")
                    .font(.caption)
                    .foregroundStyle(palette.dim)
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
    }

    private func closeReceiptButton(compact: Bool) -> some View {
        Button {
            model.closeWorkSession(for: project)
        } label: {
            if compact {
                Image(systemName: "checkmark.seal")
            } else {
                Label("Close & Receipt", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(palette.accent)
        .controlSize(compact ? .small : .regular)
        .accessibilityLabel("Close work session and write receipt")
        .help("Write an append-only receipt under 20_live/conduit/sessions")
    }
}

/// Typewriter-style presentation of a successful receipt write.
/// Facts come only from the returned URL and recorded timestamp.
/// `RECORDED` means the writer returned successfully — not that work succeeded.
private struct ReceiptRevealView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let result: RecordedReceiptResult

    @State private var visibleFactCount = 0
    @State private var typedValueLengths: [Int] = []
    @State private var showRecordedStamp = false
    @State private var revealTask: Task<Void, Never>?

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private static let recordedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var facts: [(label: String, value: String)] {
        [
            ("File", result.url.lastPathComponent),
            ("Recorded", Self.recordedTimeFormatter.string(from: result.recordedAt))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.ellipsis")
                    .font(.caption)
                    .foregroundStyle(palette.ink)
                    .accessibilityHidden(true)
                Text("Receipt")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.text)
                Spacer(minLength: 4)
                Text("20_live/conduit/sessions")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(palette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                    if index < visibleFactCount {
                        factLine(
                            label: fact.label,
                            value: String(fact.value.prefix(typedLength(for: index)))
                        )
                    }
                }
            }

            if showRecordedStamp {
                Text("RECORDED")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(palette.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(palette.accent, lineWidth: 1.5)
                    )
                    .rotationEffect(.degrees(-5))
                    .padding(.top, 2)
                    .accessibilityLabel("Recorded")
                    .accessibilityHint("Receipt file written successfully. Does not claim terminal work succeeded.")
            }

            Text("Receipt file written. This does not claim terminal work succeeded.")
                .font(.caption2)
                .foregroundStyle(palette.faint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    model.openRecordedReceipt(result)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderedProminent)
                .tint(palette.accent)
                .controlSize(.small)
                .accessibilityLabel("Open recorded receipt")
                .help("Open \(result.url.lastPathComponent)")

                Button {
                    model.dismissRecordedReceipt(result)
                } label: {
                    Text("Dismiss")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .foregroundStyle(palette.dim)
                .accessibilityLabel("Dismiss recorded receipt")
                .help("Dismiss this receipt reveal")

                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Work session receipt")
        .onAppear { startRevealIfNeeded() }
        .onChange(of: result.id) { _ in
            resetAndStartReveal()
        }
        .onDisappear {
            revealTask?.cancel()
            revealTask = nil
        }
    }

    private func factLine(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.faint)
                .frame(width: 58, alignment: .leading)
            Text(value.isEmpty ? " " : value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(palette.text)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private func typedLength(for index: Int) -> Int {
        guard typedValueLengths.indices.contains(index) else { return 0 }
        return typedValueLengths[index]
    }

    private func startRevealIfNeeded() {
        guard visibleFactCount == 0, !showRecordedStamp else { return }
        runReveal()
    }

    private func resetAndStartReveal() {
        revealTask?.cancel()
        visibleFactCount = 0
        typedValueLengths = Array(repeating: 0, count: facts.count)
        showRecordedStamp = false
        runReveal()
    }

    private func runReveal() {
        let lines = facts
        if typedValueLengths.count != lines.count {
            typedValueLengths = Array(repeating: 0, count: lines.count)
        }

        if reduceMotion {
            visibleFactCount = lines.count
            typedValueLengths = lines.map(\.value.count)
            showRecordedStamp = true
            return
        }

        revealTask?.cancel()
        revealTask = Task { @MainActor in
            for (index, fact) in lines.enumerated() {
                if Task.isCancelled { return }
                visibleFactCount = index + 1
                typedValueLengths[index] = 0
                for length in 1...max(fact.value.count, 1) {
                    if Task.isCancelled { return }
                    typedValueLengths[index] = min(length, fact.value.count)
                    try? await Task.sleep(nanoseconds: 14_000_000)
                }
                try? await Task.sleep(nanoseconds: 70_000_000)
            }
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 160_000_000)
            if Task.isCancelled { return }
            showRecordedStamp = true
        }
    }
}

/// Operator-density observed-state deck. Only current model facts; no invented
/// progress, tests, or completion claims.
struct OperatorOpsDeck: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let project: MainframeProject


    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10) {
                workSessionCard
                terminalSessionsCard
                agentUsageCard
                resourcesCard
                doctorCard
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(palette.app)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Operator observed state deck")
    }

    private var workSessionCard: some View {
        // Timeline so elapsed stays honest without inventing progress.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let session = model.workSession(for: project)
            opsCard(
                key: "Work session",
                big: session == nil ? "Idle" : "Live",
                sub: {
                    if let session {
                        return "Elapsed \(elapsedLabel(from: session.startedAt, now: context.date))"
                    }
                    return "No active work session"
                }()
            )
        }
    }

    private var terminalSessionsCard: some View {
        let sessions = model.sessionsForSelectedProject
        let detached = sessions.filter { $0.controller.isDetached }.count
        let attached = sessions.count - detached
        let big: String
        let sub: String
        if sessions.isEmpty {
            big = "0"
            sub = "No terminal sessions"
        } else {
            big = "\(sessions.count)"
            sub = "\(attached) attached · \(detached) detached"
        }
        return opsCard(key: "Terminal sessions", big: big, sub: sub)
    }

    /// Observed-usage summary. Opens the per-agent breakdown; the card itself
    /// counts only agents Conduit actually ran, so it never implies coverage of
    /// agents it never saw.
    private var agentUsageCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let rows = model.observedUsageRows(at: context.date)
            let active = rows.filter { $0.sessions > 0 }
            let live = rows.reduce(0) { $0 + $1.liveSessions }
            Button {
                model.showAgentUsage = true
            } label: {
                opsCard(
                    key: "Agent usage",
                    big: "\(active.count)",
                    sub: active.isEmpty
                        ? "No agent sessions observed"
                        : "\(active.count) of \(rows.count) agents · \(live) live"
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the observed per-agent usage breakdown")
        }
    }

    private var resourcesCard: some View {
        let snapshot = model.resourceSnapshot
        let big: String
        let sub: String
        if snapshot.totalMemoryGB > 0 {
            let pct = Int((snapshot.usedMemoryGB / snapshot.totalMemoryGB * 100).rounded())
            big = "\(pct)%"
            sub = String(
                format: "RAM %.1f / %.1f GB",
                snapshot.usedMemoryGB,
                snapshot.totalMemoryGB
            )
        } else {
            big = "—"
            sub = "Memory not measured"
        }
        let ollama: String = {
            if snapshot.capturedAt == .distantPast {
                return "Ollama —"
            }
            if snapshot.ollamaModels.isEmpty {
                return "Ollama none"
            }
            return "Ollama \(snapshot.ollamaModels.count) loaded"
        }()
        return opsCard(key: "Resources", big: big, sub: "\(sub) · \(ollama)")
    }

    private var doctorCard: some View {
        let results = model.healthResults
        let big: String
        let sub: String
        if results.isEmpty {
            big = "—"
            sub = "Local probes not run"
        } else {
            let observed = results.filter { $0.state == .observed }.count
            let warnings = results.filter { $0.state == .warning }.count
            let unavailable = results.filter { $0.state == .unavailable }.count
            big = "\(results.count)"
            sub = "\(observed) observed · \(warnings) attention · \(unavailable) unavailable"
        }
        return opsCard(key: "Local probes · not auth/quota", big: big, sub: sub)
    }

    private func opsCard(key: String, big: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(palette.faint)
            Text(big)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(sub)
                .font(.system(size: 11))
                .foregroundStyle(palette.dim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(minWidth: 150, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(key): \(big). \(sub)")
    }

    private func elapsedLabel(from startedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

struct SessionBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    /// Focused seats stay compact; Balanced/Operator show the full state label.
    private var isCompactSeats: Bool {
        model.density == .focused
    }

    var body: some View {
        // Timeline-driven so seat and pill states stay honest after output goes
        // quiet (a session must not read "working" forever once it idles).
        TimelineView(.periodic(from: .now, by: 0.7)) { timeline in
            VStack(spacing: 0) {
                operatorsRow(date: timeline.date)
                Divider().overlay(palette.line)
                sessionsRow(date: timeline.date)
            }
        }
    }

    /// One seat per enabled agent (including Shell). State is derived only from
    /// a matching runtime in `sessionsForSelectedProject`, or else "available".
    private func operatorsRow(date: Date) -> some View {
        let sessions = model.sessionsForSelectedProject
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: isCompactSeats ? 2 : 4) {
                Text("OPERATORS")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(palette.faint)
                    .padding(.trailing, 4)
                ForEach(model.enabledAgents) { agent in
                    let runtime = sessions.first { $0.descriptor.agent.id == agent.id }
                    OperatorSeat(
                        agent: agent,
                        runtime: runtime,
                        date: date,
                        isCompact: isCompactSeats
                    )
                    .environmentObject(model)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isCompactSeats ? 6 : 9)
        }
        .background(palette.app)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Operator seats")
    }

    /// Real session tabs only — detach/end/restart and New shell unchanged.
    private func sessionsRow(date: Date) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("SESSIONS")
                    .font(.caption2.bold())
                    .foregroundStyle(palette.faint)
                ForEach(model.sessionsForSelectedProject) { runtime in
                    SessionPill(runtime: runtime, date: date)
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
        .background(palette.rail)
    }
}

/// One operator seat for an enabled agent. Launched seats mirror
/// `controller.visualState(at:)`; unlaunched seats read "available" only.
private struct OperatorSeat: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let agent: AgentProfile
    let runtime: TerminalRuntime?
    let date: Date
    let isCompact: Bool

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        if let runtime {
            LaunchedOperatorSeat(
                agent: agent,
                runtime: runtime,
                date: date,
                isCompact: isCompact
            )
            .environmentObject(model)
        } else {
            availableSeat
        }
    }

    private var availableSeat: some View {
        Button {
            model.launch(agent: agent)
        } label: {
            seatChrome(
                presentation: .available,
                stateLabel: "available",
                dotColor: palette.faint,
                isActive: false
            )
        }
        .buttonStyle(.plain)
        .opacity(0.5)
        .accessibilityLabel(
            "\(agent.name), \(AgentSpriteCue.available.accessibilityPhrase), neutral generic companion"
        )
        .accessibilityHint("Launches a new \(agent.name) session for the selected project")
        .help("Launch \(agent.name)")
    }

    private func seatChrome(
        presentation: AgentSpritePresentation,
        stateLabel: String,
        dotColor: Color,
        isActive: Bool
    ) -> some View {
        let spriteSide: CGFloat = isCompact ? 22 : 30
        return VStack(spacing: isCompact ? 1 : 2) {
            ZStack(alignment: .topTrailing) {
                AgentSpriteView(
                    profile: agent,
                    presentation: presentation,
                    frameSize: CGSize(width: spriteSide + 4, height: spriteSide + 6)
                )
                Circle()
                    .fill(dotColor)
                    .frame(width: isCompact ? 6 : 7, height: isCompact ? 6 : 7)
                    .overlay(
                        Circle()
                            .strokeBorder(palette.app, lineWidth: 1.5)
                    )
                    .offset(x: 2, y: -1)
                    .accessibilityHidden(true)
            }
            Text(agent.name)
                .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            if !isCompact {
                Text(stateLabel.uppercased())
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(dotColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, isCompact ? 6 : 8)
        .padding(.vertical, isCompact ? 3 : 5)
        .frame(minWidth: isCompact ? 44 : 58)
        .background(isActive ? palette.accentSoft : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Launched seat observes its real controller so the pose/dot follow PTY state.
private struct LaunchedOperatorSeat: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let agent: AgentProfile
    let runtime: TerminalRuntime
    let date: Date
    let isCompact: Bool
    @ObservedObject private var controller: TerminalSessionController

    init(agent: AgentProfile, runtime: TerminalRuntime, date: Date, isCompact: Bool) {
        self.agent = agent
        self.runtime = runtime
        self.date = date
        self.isCompact = isCompact
        self._controller = ObservedObject(wrappedValue: runtime.controller)
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        let state = controller.visualState(at: date)
        let isActive = runtime.id == model.activeSessionID
        Button {
            model.selectSession(runtime)
        } label: {
            seatChrome(
                state: state,
                isActive: isActive
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "\(agent.name), \(state.spriteCue.accessibilityPhrase), \(AgentSpriteResources.accessibilityDescription(for: agent))"
        )
        .accessibilityHint("Switches to the existing \(agent.name) session")
        .help("Select \(agent.name) session")
    }

    private func seatChrome(state: TerminalVisualState, isActive: Bool) -> some View {
        let spriteSide: CGFloat = isCompact ? 22 : 30
        let dotColor = palette.color(forTerminalState: state)
        return VStack(spacing: isCompact ? 1 : 2) {
            ZStack(alignment: .topTrailing) {
                AgentSpriteView(
                    profile: agent,
                    presentation: .launched(state),
                    frameSize: CGSize(width: spriteSide + 4, height: spriteSide + 6)
                )
                Circle()
                    .fill(dotColor)
                    .frame(width: isCompact ? 6 : 7, height: isCompact ? 6 : 7)
                    .overlay(
                        Circle()
                            .strokeBorder(palette.app, lineWidth: 1.5)
                    )
                    .offset(x: 2, y: -1)
                    .accessibilityHidden(true)
            }
            Text(agent.name)
                .font(.system(size: isCompact ? 9 : 10, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
            if !isCompact {
                Text(state.label.uppercased())
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(dotColor)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, isCompact ? 6 : 8)
        .padding(.vertical, isCompact ? 3 : 5)
        .frame(minWidth: isCompact ? 44 : 58)
        .background(isActive ? palette.accentSoft : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}


private struct SessionPill: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let runtime: TerminalRuntime
    let date: Date
    @ObservedObject private var controller: TerminalSessionController

    init(runtime: TerminalRuntime, date: Date) {
        self.runtime = runtime
        self.date = date
        self._controller = ObservedObject(wrappedValue: runtime.controller)
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        let state = controller.visualState(at: date)
        let artworkDescription = AgentSpriteResources.accessibilityDescription(
            for: runtime.descriptor.agent
        )
        HStack(spacing: 6) {
            AgentSpriteView(profile: runtime.descriptor.agent, state: state)
            Button {
                model.selectSession(runtime)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(palette.color(forTerminalState: state))
                        .frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(runtime.descriptor.agent.name)
                            .font(.caption.bold())
                            .foregroundStyle(palette.text)
                        Text("\(state.label) · \(controller.backendLabel)")
                            .font(.caption2)
                            .foregroundStyle(palette.dim)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(runtime.descriptor.agent.name) session, \(state.spriteCue.accessibilityPhrase), \(controller.backendLabel), \(artworkDescription)"
            )
            .accessibilityHint("Switches to this session")
            Button {
                model.closeSession(runtime)
            } label: {
                Image(systemName: controller.usesTmux ? "rectangle.portrait.and.arrow.right" : "xmark")
                    .font(.caption2)
                    .foregroundStyle(palette.dim)
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
        .background(runtime.id == model.activeSessionID ? palette.accentSoft : palette.lineSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contextMenu {
            Button("Move clipboard selection to composer", action: model.beginForwardingToComposer)
            Menu("Send clipboard selection to") {
                ForEach(model.forwardableAgents) { agent in
                    Button(agent.name) { model.beginForwarding(to: agent) }
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
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let project: MainframeProject
    @State private var markdown = ""

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Project Context", systemImage: "doc.text")
                    .font(.headline)
                    .foregroundStyle(palette.text)
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
                        .foregroundStyle(palette.dim)
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
                        .foregroundStyle(palette.text)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(palette.surface)
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
                .foregroundStyle(palette.faint)
            Text(value)
                .textSelection(.enabled)
                .foregroundStyle(palette.text)
        }
    }
}
#endif
