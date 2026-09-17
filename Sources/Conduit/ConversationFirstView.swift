#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

/// Chat-first daily-driver presentation over one unchanged TerminalRuntime.
/// Raw, task/runtime identity, capture, persistence, and provider semantics are
/// intentionally owned elsewhere; this view only projects and exposes explicit
/// operator actions over already-observed conversation data.
struct ConversationFirstView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var runtime: TerminalRuntime
    @ObservedObject private var controller: TerminalSessionController

    @State private var followLatest = true
    @State private var didApplyFollowDefault = false
    @State private var pendingScroll: Task<Void, Never>?
    @State private var keyMonitor: Any?
    @State private var renderCache = ConversationFirstRenderCache()

    init(runtime: TerminalRuntime) {
        self._runtime = ObservedObject(wrappedValue: runtime)
        self._controller = ObservedObject(wrappedValue: runtime.controller)
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var turns: [ConversationTurn] {
        SessionPresentation.conversationTurns(from: runtime.presentationEvents)
    }

    /// Tail-only signal for follow-latest. It avoids scanning the whole stream
    /// every time the active answer gains a few characters.
    private var streamRevision: String {
        var parts = [String(runtime.presentationEvents.count)]
        if let last = runtime.presentationEvents.last {
            parts.append(last.id.uuidString)
            if case .agentOutput(let output) = last.kind {
                parts.append(String(output.text.count))
                parts.append(output.state.rawValue)
            }
        }
        if let active = runtime.activeOutputEventID {
            parts.append(active.uuidString)
        }
        parts.append(runtime.isAwaitingAgentOutput ? "waiting" : "idle")
        return parts.joined(separator: ":")
    }

    var body: some View {
        VStack(spacing: 0) {
            compactHeader
            Divider().overlay(palette.line)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        diagnostics

                        ForEach(turns) { turn in
                            turnView(turn)
                                .id(turn.id)
                        }

                        if runtime.isAwaitingAgentOutput,
                           runtime.activeOutputEventID == nil {
                            waitingForOutput
                        }

                        if let notice = runtime.conversationCaptureNotice {
                            captureNotice(notice)
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("conversation-first-bottom")
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 920, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: streamRevision) { _ in
                    scheduleFollowLatest(proxy)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            if followLatest { followLatest = false }
                        }
                )
            }

            if !followLatest {
                jumpToLatestBar
            }
        }
        .background(palette.canvas)
        .onAppear {
            if !didApplyFollowDefault {
                followLatest = model.settings.followConversationByDefault
                didApplyFollowDefault = true
            }
            installKeyMonitor()
        }
        .onDisappear {
            pendingScroll?.cancel()
            pendingScroll = nil
            removeKeyMonitor()
        }
    }

    // MARK: Header

    private var compactHeader: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 10) {
                Circle()
                    .fill(
                        palette.color(
                            forTerminalState: controller.visualState(at: timeline.date)
                        )
                    )
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text(runtime.descriptor.agent.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.text)
                    Text(conversationStateLabel(at: timeline.date))
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    followLatest.toggle()
                } label: {
                    Image(
                        systemName: followLatest
                            ? "arrow.down.to.line.compact"
                            : "arrow.down.to.line"
                    )
                }
                .buttonStyle(.borderless)
                .help(
                    followLatest
                        ? "Following latest output"
                        : "Resume following latest output"
                )
                .accessibilityLabel(
                    followLatest ? "Following latest" : "Not following latest"
                )

                sessionControlsMenu

                ConversationThreadActionsMenu(
                    title: model.selectedTaskSnapshot?.displayTitle
                        ?? runtime.descriptor.title,
                    agentName: runtime.descriptor.agent.name,
                    taskSessionID: runtime.descriptor.taskSessionID,
                    events: runtime.presentationEvents,
                    onError: { model.errorMessage = $0 }
                )

                Button {
                    runtime.selectedSurface = .raw
                } label: {
                    Label("Raw", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open the authoritative Raw terminal (Command-2)")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(palette.surface)
        }
    }

    private var sessionControlsMenu: some View {
        Menu {
            let agent = runtime.descriptor.agent
            let current = model.settings.agents.first(where: {
                $0.id == agent.id || $0.name == agent.name
            })?.permissionMode ?? agent.permissionMode

            Menu("Permission: \(current.displayName)") {
                ForEach(AgentPermissionMode.allCases, id: \.self) { mode in
                    Button {
                        model.setPermissionModeForActiveAgent(mode)
                    } label: {
                        if mode == current {
                            Label(mode.displayName, systemImage: "checkmark")
                        } else {
                            Text(mode.displayName)
                        }
                    }
                }
            }
            .disabled(agent.kind == .shell)

            Divider()
            Menu("Reply") {
                ForEach(["1", "2", "3", "4"], id: \.self) { choice in
                    Button(choice) {
                        model.injectConversationControl(
                            text: choice,
                            submit: true,
                            into: runtime
                        )
                    }
                }
            }
            Button("Enter") {
                model.injectConversationControl(key: .enter, into: runtime)
            }
            Button("Escape") {
                model.injectConversationControl(key: .escape, into: runtime)
            }
            Button("Up") {
                model.injectConversationControl(key: .up, into: runtime)
            }
            Button("Down") {
                model.injectConversationControl(key: .down, into: runtime)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .help("Agent controls")
        .accessibilityLabel("Agent controls")
    }

    private var jumpToLatestBar: some View {
        HStack {
            Spacer()
            Button {
                followLatest = true
            } label: {
                Label("Jump to latest", systemImage: "arrow.down.to.line")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
        }
        .padding(.vertical, 6)
        .background(palette.surface)
    }

    // MARK: Turns

    @ViewBuilder
    private func turnView(_ turn: ConversationTurn) -> some View {
        switch turn.kind {
        case .boundary(let event):
            if case .sessionOpened(let entry) = event.kind {
                sessionBoundary(entry, event: event)
            }
        case .exchange(let user, let outputs):
            VStack(alignment: .leading, spacing: 12) {
                if let user, case .userPrompt(let prompt) = user.kind {
                    promptCard(prompt, event: user, turn: turn)
                }
                ForEach(outputs) { outputEvent in
                    if case .agentOutput(let output) = outputEvent.kind {
                        assistantCard(output, event: outputEvent, turn: turn)
                    }
                }
            }
        }
    }

    private func sessionBoundary(
        _ entry: SessionEntry,
        event: SessionPresentationEvent
    ) -> some View {
        let title: String
        switch entry {
        case .started(let agentName, _):
            title = "Started \(agentName)"
        case .resumed(let agentName, let tmuxName, let attachedElsewhere):
            title = "Reattached \(agentName) · \(tmuxName)"
                + (attachedElsewhere ? " · shared attach" : "")
        }
        return HStack(spacing: 10) {
            Rectangle().fill(palette.line).frame(height: 1)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.faint)
                .fixedSize()
            Text(event.occurredAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(palette.faint)
                .fixedSize()
            Rectangle().fill(palette.line).frame(height: 1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func promptCard(
        _ prompt: SubmittedPrompt,
        event: SessionPresentationEvent,
        turn: ConversationTurn
    ) -> some View {
        ConversationTurnCard(
            role: "You",
            timestamp: event.occurredAt,
            accent: true,
            copyText: ConversationFirstCopy.turn(
                turn,
                agentName: runtime.descriptor.agent.name
            ),
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !prompt.text.isEmpty {
                    SelectableConversationDocument(
                        attributedString: ConversationFirstDocumentFormatter.plain(
                            prompt.text
                        )
                    )
                }
                if !prompt.attachmentPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(prompt.attachmentPaths, id: \.self) { path in
                            Label(path, systemImage: "paperclip")
                                .font(.caption2.monospaced())
                                .foregroundStyle(palette.dim)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                        }
                    }
                }
                if prompt.delivery != .delivered {
                    Text(prompt.delivery.displayName)
                        .font(.caption2)
                        .foregroundStyle(
                            prompt.delivery == .failed ? Color.red : palette.faint
                        )
                }
            }
        }
    }

    private func assistantCard(
        _ output: AgentVisibleOutput,
        event: SessionPresentationEvent,
        turn: ConversationTurn
    ) -> some View {
        let rendered = renderCache.renderedOutput(event: event, output: output)
        let isCurrentCapture = runtime.activeOutputEventID == event.id
        let showLive = isCurrentCapture && output.state == .live

        return ConversationTurnCard(
            role: runtime.descriptor.agent.name,
            timestamp: event.occurredAt,
            accent: false,
            isLive: showLive,
            copyText: ConversationFirstCopy.turn(
                turn,
                agentName: runtime.descriptor.agent.name
            ),
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 9) {
                if let thinking = rendered.thinking, !thinking.isEmpty {
                    DisclosureGroup("Thinking") {
                        SelectableConversationDocument(
                            attributedString: ConversationFirstDocumentFormatter.muted(
                                thinking
                            )
                        )
                        .padding(.top, 4)
                    }
                    .font(.caption)
                    .foregroundStyle(palette.dim)
                    .padding(8)
                    .background(palette.sink.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                ForEach(rendered.segments) { segment in
                    switch segment.kind {
                    case .prose(let attributed):
                        if attributed.length > 0 {
                            SelectableConversationDocument(
                                attributedString: attributed
                            )
                        }
                    case .activity(let activity):
                        providerActivityCard(activity)
                    }
                }

                if rendered.segments.isEmpty, showLive {
                    Text("…")
                        .font(.callout)
                        .foregroundStyle(palette.faint)
                }

                if rendered.interactiveMenu {
                    compactInteractiveMenu(rendered.menuOptions)
                }

                HStack(spacing: 5) {
                    Text(event.authority == .derivedFromRaw ? "from Raw" : "adapter")
                    if output.truncated { Text("· truncated") }
                }
                .font(.caption2)
                .foregroundStyle(palette.faint.opacity(0.82))
                .help(
                    "\(output.extraction.displayName). This is presentation evidence, not task verification."
                )
            }
        }
    }

    private func providerActivityCard(_ activity: ConversationFirstActivity) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                SelectableConversationDocument(
                    attributedString: ConversationFirstDocumentFormatter.code(
                        activity.detail
                    )
                )
                HStack(spacing: 8) {
                    Text("provider reported")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                    Spacer()
                    if activity.possiblePath != nil {
                        Button("Open in Workbench") {
                            openActivityInWorkbench(activity)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    Button("Copy") {
                        ConversationFirstCopy.write(activity.detail)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(.top, 7)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: activity.symbol)
                    .foregroundStyle(palette.dim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activity.displayTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.text)
                    Text(activity.detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(10)
        .background(palette.sink.opacity(0.62))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(palette.lineSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func compactInteractiveMenu(_ options: [TerminalMenuOption]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Choose an option")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.dim)
            ForEach(options) { option in
                Button {
                    model.injectConversationControl(
                        text: option.key,
                        submit: true,
                        into: runtime
                    )
                } label: {
                    HStack(spacing: 8) {
                        Text(option.key)
                            .font(.caption.monospaced().weight(.bold))
                            .frame(width: 24)
                        Text(option.label)
                            .font(.callout)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
                .background(
                    option.isSelected ? palette.accentSoft : palette.lineSoft
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(10)
        .background(palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Diagnostics

    @ViewBuilder
    private var diagnostics: some View {
        if !model.selectedTaskConversationDiagnostics.isEmpty {
            Label(
                "\(model.selectedTaskConversationDiagnostics.count) retained-history record(s) could not be projected. Valid records remain visible; source bytes were preserved.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(palette.dim)
            .padding(12)
            .background(palette.lineSoft)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        if case .failed(let detail)? = model.selectedTaskConversationRetentionState {
            Label(
                "\(detail) This thread may include volatile on-screen events that have not been confirmed retained.",
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.caption)
            .foregroundStyle(palette.dim)
            .padding(12)
            .background(palette.lineSoft)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var waitingForOutput: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text("Waiting for visible output…")
                .font(.caption)
                .foregroundStyle(palette.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func captureNotice(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(palette.dim)
            VStack(alignment: .leading, spacing: 2) {
                Text("Capture paused")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.text)
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(palette.dim)
            }
            Spacer()
            Button("Open Raw") { runtime.selectedSurface = .raw }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(10)
        .background(palette.lineSoft)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func conversationStateLabel(at date: Date) -> String {
        if runtime.isAwaitingAgentOutput || runtime.activeOutputEventID != nil {
            return "Working"
        }
        switch controller.visualState(at: date) {
        case .working: return "Working"
        case .running: return "Ready"
        case .launching: return "Starting"
        case .detached: return "Detached"
        case .exited: return "Ended"
        case .failed: return "Failed · inspect Raw"
        }
    }

    // MARK: Workbench deep link

    private func openActivityInWorkbench(_ activity: ConversationFirstActivity) {
        guard let rawPath = activity.possiblePath,
              let root = model.settings.mainframeRoot
        else { return }

        let standardRoot = root.standardizedFileURL
        let project = model.selectedTaskProject ?? model.selectedProject
        let candidate: URL
        if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath).standardizedFileURL
        } else if let project {
            candidate = project.path
                .appendingPathComponent(rawPath)
                .standardizedFileURL
        } else {
            candidate = standardRoot
                .appendingPathComponent(rawPath)
                .standardizedFileURL
        }

        let rootPath = standardRoot.path
        let candidatePath = candidate.path
        guard candidatePath == rootPath
                || candidatePath.hasPrefix(rootPath + "/")
        else {
            model.errorMessage =
                "That provider-reported path is outside the selected MainFrame root."
            return
        }

        openWindow(id: "source-workbench", value: candidatePath)
    }

    // MARK: Coalesced follow-latest

    private func scheduleFollowLatest(_ proxy: ScrollViewProxy) {
        guard followLatest else { return }
        pendingScroll?.cancel()
        pendingScroll = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled, followLatest else { return }
            proxy.scrollTo("conversation-first-bottom", anchor: .bottom)
        }
    }

    // MARK: Menu-key routing

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleConversationKeyEvent(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleConversationKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard !controller.lifecycle.isTerminal,
              runtime.selectedSurface == .conversation
        else { return event }

        if let first = NSApp.keyWindow?.firstResponder,
           first is NSTextView || first is NSTextField {
            return event
        }

        let flags = event.modifierFlags.intersection([
            .command, .control, .option
        ])
        guard flags.isEmpty else { return event }

        switch event.keyCode {
        case 36, 76:
            model.injectConversationControl(key: .enter, into: runtime)
            return nil
        case 53:
            model.injectConversationControl(key: .escape, into: runtime)
            return nil
        case 126:
            model.injectConversationControl(key: .up, into: runtime)
            return nil
        case 125:
            model.injectConversationControl(key: .down, into: runtime)
            return nil
        default:
            break
        }

        if let characters = event.charactersIgnoringModifiers,
           characters.count == 1,
           let ch = characters.first,
           ch >= "1", ch <= "9" {
            model.injectConversationControl(
                text: String(ch),
                submit: true,
                into: runtime
            )
            return nil
        }
        return event
    }
}

// MARK: Retained history

/// Read-only retained conversation. Selecting/history actions never launch,
/// reconnect, or mutate runtime state.
struct ConversationFirstHistoryView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    let events: [SessionPresentationEvent]
    let taskSessionID: TaskSessionID
    let title: String
    let agentName: String
    let onError: (String) -> Void

    @State private var renderCache = ConversationFirstRenderCache()

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var turns: [ConversationTurn] {
        SessionPresentation.conversationTurns(from: events)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversation")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.text)
                Spacer()
                ConversationThreadActionsMenu(
                    title: title,
                    agentName: agentName,
                    taskSessionID: taskSessionID,
                    events: events,
                    onError: onError
                )
            }

            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(turns) { turn in
                    historyTurn(turn)
                }
            }
        }
    }

    @ViewBuilder
    private func historyTurn(_ turn: ConversationTurn) -> some View {
        switch turn.kind {
        case .boundary(let event):
            if case .sessionOpened(let entry) = event.kind {
                let label: String
                switch entry {
                case .started(let name, _):
                    label = "Started \(name)"
                case .resumed(let name, let tmux, _):
                    label = "Reattached \(name) · \(tmux)"
                }
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        case .exchange(let user, let outputs):
            VStack(alignment: .leading, spacing: 12) {
                if let user, case .userPrompt(let prompt) = user.kind {
                    ConversationTurnCard(
                        role: "You",
                        timestamp: user.occurredAt,
                        accent: true,
                        copyText: ConversationFirstCopy.turn(
                            turn,
                            agentName: agentName
                        ),
                        palette: palette
                    ) {
                        SelectableConversationDocument(
                            attributedString: ConversationFirstDocumentFormatter.plain(
                                prompt.text
                            )
                        )
                    }
                }

                ForEach(outputs) { event in
                    if case .agentOutput(let output) = event.kind {
                        let rendered = renderCache.renderedOutput(
                            event: event,
                            output: output
                        )
                        ConversationTurnCard(
                            role: agentName,
                            timestamp: event.occurredAt,
                            accent: false,
                            copyText: ConversationFirstCopy.turn(
                                turn,
                                agentName: agentName
                            ),
                            palette: palette
                        ) {
                            VStack(alignment: .leading, spacing: 9) {
                                ForEach(rendered.segments) { segment in
                                    switch segment.kind {
                                    case .prose(let attributed):
                                        SelectableConversationDocument(
                                            attributedString: attributed
                                        )
                                    case .activity(let activity):
                                        VStack(alignment: .leading, spacing: 5) {
                                            Label(
                                                activity.displayTitle,
                                                systemImage: activity.symbol
                                            )
                                            .font(.caption.weight(.semibold))
                                            SelectableConversationDocument(
                                                attributedString:
                                                    ConversationFirstDocumentFormatter.code(
                                                        activity.detail
                                                    )
                                            )
                                            Text("provider reported")
                                                .font(.caption2)
                                                .foregroundStyle(palette.faint)
                                        }
                                        .padding(9)
                                        .background(palette.sink.opacity(0.55))
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                    }
                                }
                                Text(
                                    event.authority == .derivedFromRaw
                                        ? "from Raw"
                                        : "adapter"
                                )
                                .font(.caption2)
                                .foregroundStyle(palette.faint)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Turn chrome

private struct ConversationTurnCard<Content: View>: View {
    let role: String
    let timestamp: Date
    let accent: Bool
    var isLive: Bool = false
    let copyText: String
    let palette: ConduitPalette
    @ViewBuilder let content: () -> Content

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(role)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent ? palette.accent : palette.ink)
                if isLive {
                    ProgressView().controlSize(.mini)
                    Text("writing")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
                Spacer(minLength: 6)
                Text(timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                if hovered {
                    Button {
                        ConversationFirstCopy.write(copyText)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy turn")
                    .accessibilityLabel("Copy turn")
                    .transition(.opacity)
                }
            }
            content()
        }
        .padding(.horizontal, accent ? 13 : 2)
        .padding(.vertical, accent ? 11 : 2)
        .background(accent ? palette.accentSoft.opacity(0.34) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy turn") {
                ConversationFirstCopy.write(copyText)
            }
        }
    }
}

// MARK: Continuous native text selection

/// One NSTextView per logical body keeps selection continuous across headings,
/// paragraphs, lists, and code instead of breaking at every SwiftUI Text node.
private struct SelectableConversationDocument: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        if !view.attributedString().isEqual(to: attributedString) {
            view.textStorage?.setAttributedString(attributedString)
            view.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSTextView,
        context: Context
    ) -> CGSize? {
        let width = max(proposal.width ?? 320, 1)
        guard let textContainer = nsView.textContainer,
              let layoutManager = nsView.layoutManager
        else { return CGSize(width: width, height: 20) }

        textContainer.containerSize = NSSize(
            width: width,
            height: .greatestFiniteMagnitude
        )
        textContainer.widthTracksTextView = false
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        return CGSize(width: width, height: ceil(used.height) + 1)
    }
}

// MARK: Render cache and structured activity

private final class ConversationFirstRenderCache {
    private struct Entry {
        let sourceText: String
        let state: AgentOutputState
        let extraction: AgentOutputExtraction
        let rendered: ConversationFirstRenderedOutput
    }

    private var entries: [UUID: Entry] = [:]

    func renderedOutput(
        event: SessionPresentationEvent,
        output: AgentVisibleOutput
    ) -> ConversationFirstRenderedOutput {
        if let cached = entries[event.id],
           cached.sourceText == output.text,
           cached.state == output.state,
           cached.extraction == output.extraction {
            return cached.rendered
        }

        let display = ConversationDisplayText.workstationDerived(output.text)
        let split = splitPreservedThinking(display)
        let inputs = ConversationFirstActivityParser.segments(
            text: split.answer,
            structured: event.authority == .toolReported
                && output.extraction == .structuredAdapter
        )
        let segments = inputs.enumerated().map { index, input in
            switch input {
            case .prose(let text):
                return ConversationFirstRenderSegment(
                    id: "\(event.id.uuidString)-p-\(index)",
                    kind: .prose(
                        ConversationFirstDocumentFormatter.markdown(text)
                    )
                )
            case .activity(let activity):
                return ConversationFirstRenderSegment(
                    id: "\(event.id.uuidString)-a-\(index)-\(activity.id)",
                    kind: .activity(activity)
                )
            }
        }
        let menuOptions = TerminalMenuParser.options(in: split.answer)
        let rendered = ConversationFirstRenderedOutput(
            thinking: split.thinking,
            segments: segments,
            interactiveMenu:
                TerminalMenuParser.looksLikeInteractiveMenu(split.answer)
                    && !menuOptions.isEmpty,
            menuOptions: menuOptions
        )
        entries[event.id] = Entry(
            sourceText: output.text,
            state: output.state,
            extraction: output.extraction,
            rendered: rendered
        )
        return rendered
    }

    private func splitPreservedThinking(
        _ text: String
    ) -> (thinking: String?, answer: String) {
        let header = ConversationCaptureMerge.thinkingHeader
        guard text.contains(header) else { return (nil, text) }
        let parts = text.components(separatedBy: "\n—\n")
        guard parts.count >= 2 else { return (nil, text) }

        var thinking = parts[0]
        if let range = thinking.range(of: header) {
            thinking = String(thinking[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let answer = parts.dropFirst().joined(separator: "\n—\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (thinking.isEmpty ? nil : thinking, answer)
    }
}

private struct ConversationFirstRenderedOutput {
    let thinking: String?
    let segments: [ConversationFirstRenderSegment]
    let interactiveMenu: Bool
    let menuOptions: [TerminalMenuOption]
}

private struct ConversationFirstRenderSegment: Identifiable {
    enum Kind {
        case prose(NSAttributedString)
        case activity(ConversationFirstActivity)
    }

    let id: String
    let kind: Kind
}

private struct ConversationFirstActivity: Identifiable {
    let id: String
    let type: String
    let detail: String
    let possiblePath: String?

    var displayTitle: String {
        let spaced = type.unicodeScalars.reduce(into: "") { output, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !output.isEmpty {
                output.append(" ")
            }
            output.append(String(scalar))
        }
        let trimmed = spaced.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Agent activity" : trimmed.capitalized
    }

    var symbol: String {
        let lower = type.lowercased()
        if lower.contains("command") || lower.contains("exec") {
            return "terminal"
        }
        if lower.contains("search") || lower.contains("grep") {
            return "magnifyingglass"
        }
        if lower.contains("file") || lower.contains("patch")
            || lower.contains("change") {
            return "doc.text.magnifyingglass"
        }
        return "gearshape.2"
    }
}

private enum ConversationFirstActivitySegmentInput {
    case prose(String)
    case activity(ConversationFirstActivity)
}

private enum ConversationFirstActivityParser {
    static func segments(
        text: String,
        structured: Bool
    ) -> [ConversationFirstActivitySegmentInput] {
        guard structured else {
            return text.isEmpty ? [] : [.prose(text)]
        }

        var result: [ConversationFirstActivitySegmentInput] = []
        var proseLines: [String] = []
        var priorActivityKey: String?

        func flushProse() {
            let prose = proseLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !prose.isEmpty { result.append(.prose(prose)) }
            proseLines.removeAll(keepingCapacity: true)
        }

        for (index, rawLine) in text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init).enumerated() {
            if let activity = parseActivity(rawLine, index: index) {
                flushProse()
                let key = "\(activity.type)\n\(activity.detail)"
                if key != priorActivityKey {
                    result.append(.activity(activity))
                }
                priorActivityKey = key
            } else {
                proseLines.append(rawLine)
                priorActivityKey = nil
            }
        }
        flushProse()
        return result
    }

    private static func parseActivity(
        _ line: String,
        index: Int
    ) -> ConversationFirstActivity? {
        guard line.hasPrefix("["),
              let close = line.firstIndex(of: "]"),
              close > line.startIndex
        else { return nil }

        let typeStart = line.index(after: line.startIndex)
        let type = String(line[typeStart..<close])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detailStart = line.index(after: close)
        let detail = String(line[detailStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !type.isEmpty, !detail.isEmpty else { return nil }

        return ConversationFirstActivity(
            id: "\(index)-\(type)-\(detail)",
            type: type,
            detail: detail,
            possiblePath: probablePath(detail)
        )
    }

    private static func probablePath(_ detail: String) -> String? {
        var candidate = detail
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))

        if let colon = candidate.lastIndex(of: ":") {
            let suffix = candidate[candidate.index(after: colon)...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                candidate = String(candidate[..<colon])
            }
        }

        guard !candidate.isEmpty,
              !candidate.contains("\n"),
              !candidate.contains("\t"),
              !candidate.contains(" "),
              candidate.contains("/") || candidate.contains(".")
        else { return nil }
        return candidate
    }
}

// MARK: One selectable attributed document per body

private enum ConversationFirstDocumentFormatter {
    static func plain(_ text: String) -> NSAttributedString {
        make(
            text,
            font: NSFont.systemFont(ofSize: 14),
            color: .labelColor
        )
    }

    static func muted(_ text: String) -> NSAttributedString {
        make(
            text,
            font: NSFont.systemFont(ofSize: 12.5),
            color: .secondaryLabelColor
        )
    }

    static func code(_ text: String) -> NSAttributedString {
        make(
            text,
            font: NSFont.monospacedSystemFont(
                ofSize: 12.5,
                weight: .regular
            ),
            color: .labelColor
        )
    }

    static func markdown(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = ConversationDisplayText.proseBlocks(in: text)
        if blocks.isEmpty { return plain(text) }

        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            switch block {
            case .heading(let level, let value):
                let size: CGFloat = level == 1
                    ? 17
                    : (level == 2 ? 15.5 : 14.5)
                result.append(
                    make(
                        value,
                        font: NSFont.systemFont(
                            ofSize: size,
                            weight: .semibold
                        ),
                        color: .labelColor
                    )
                )
            case .paragraph(let value):
                result.append(plain(value))
            case .bullets(let items):
                result.append(
                    plain(items.map { "• \($0)" }.joined(separator: "\n"))
                )
            case .code(_, let body):
                result.append(code(body))
            }
        }
        return result
    }

    private static func make(
        _ text: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

// MARK: Conversation actions and retained-log access

private struct ConversationThreadActionsMenu: View {
    let title: String
    let agentName: String
    let taskSessionID: TaskSessionID?
    let events: [SessionPresentationEvent]
    let onError: (String) -> Void

    var body: some View {
        Menu {
            Button("Copy conversation") {
                ConversationFirstCopy.write(
                    ConversationFirstCopy.transcript(
                        title: title,
                        agentName: agentName,
                        events: events
                    )
                )
            }
            Button("Export Markdown…") {
                do {
                    try ConversationFirstCopy.exportMarkdown(
                        title: title,
                        agentName: agentName,
                        events: events
                    )
                } catch {
                    onError(error.localizedDescription)
                }
            }

            Divider()
            if let taskSessionID {
                Button("Reveal Conduit chat log") {
                    if let error = ConversationFirstCopy.revealLog(taskSessionID) {
                        onError(error)
                    }
                }
                Button("Copy chat log path") {
                    ConversationFirstCopy.write(
                        ConversationFirstCopy.logURL(taskSessionID).path
                    )
                }
            } else {
                Text("No retained task log identity")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("Conversation actions")
        .accessibilityLabel("Conversation actions")
    }
}

private enum ConversationFirstCopy {
    static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func turn(_ turn: ConversationTurn, agentName: String) -> String {
        switch turn.kind {
        case .boundary(let event):
            if case .sessionOpened(let entry) = event.kind {
                switch entry {
                case .started(let name, _):
                    return "Started \(name)"
                case .resumed(let name, let tmux, _):
                    return "Reattached \(name) · \(tmux)"
                }
            }
            return ""
        case .exchange(let user, let outputs):
            var sections: [String] = []
            if let user, case .userPrompt(let prompt) = user.kind {
                var body = prompt.text
                if !prompt.attachmentPaths.isEmpty {
                    let attachments = prompt.attachmentPaths
                        .map { "- \($0)" }
                        .joined(separator: "\n")
                    body += (body.isEmpty ? "" : "\n\n")
                        + "Attachments:\n"
                        + attachments
                }
                sections.append("You\n\n\(body)")
            }
            for outputEvent in outputs {
                guard case .agentOutput(let output) = outputEvent.kind else {
                    continue
                }
                let visible = ConversationDisplayText.workstationDerived(
                    output.text
                )
                sections.append("\(agentName)\n\n\(visible)")
            }
            return sections.joined(separator: "\n\n")
        }
    }

    static func transcript(
        title: String,
        agentName: String,
        events: [SessionPresentationEvent]
    ) -> String {
        var result = "# \(title)\n\n"
        result += "Exported from Conduit. Conversation content preserves its recorded presentation authority; it is not task verification.\n\n"
        for turn in SessionPresentation.conversationTurns(from: events) {
            let rendered = self.turn(turn, agentName: agentName)
            guard !rendered.isEmpty else { continue }
            result += rendered + "\n\n"
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func exportMarkdown(
        title: String,
        agentName: String,
        events: [SessionPresentationEvent]
    ) throws {
        let panel = NSSavePanel()
        panel.title = "Export Conduit Conversation"
        panel.nameFieldStringValue = safeFilename(title) + ".md"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try transcript(
            title: title,
            agentName: agentName,
            events: events
        ).write(to: url, atomically: true, encoding: .utf8)
    }

    static func logURL(_ taskSessionID: TaskSessionID) -> URL {
        ConversationEventLog(
            directory: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    ".conduit/conversations",
                    isDirectory: true
                ),
            taskSessionID: taskSessionID
        ).url
    }

    static func revealLog(_ taskSessionID: TaskSessionID) -> String? {
        let url = logURL(taskSessionID)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return nil
        }
        let directory = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            NSWorkspace.shared.open(directory)
        }
        return "No retained conversation log exists yet for this task."
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_ "))
        let mapped = value.unicodeScalars.map {
            allowed.contains($0) ? Character(String($0)) : "-"
        }
        let collapsed = String(mapped)
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .map(String.init)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return collapsed.isEmpty ? "conduit-conversation" : collapsed
    }
}
#endif