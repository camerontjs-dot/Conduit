#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

/// Operator-facing turn stream over one live runtime.
///
/// Conversation is a document of Conduit-recorded prompts and best-effort
/// agent turns (Derived-from-Raw or structured adapter). Raw remains the live
/// terminal authority; this surface never pretends otherwise.
struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var runtime: TerminalRuntime
    @ObservedObject private var controller: TerminalSessionController
    /// When true, the whole stream pins to the latest content.
    @State private var followLatest = true
    @State private var didApplyFollowDefault = false
    /// Local key monitor for agent menu shortcuts (no focus ring on the stream).
    @State private var keyMonitor: Any?

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

    /// Live Derived-from-Raw character count — drives whole-stream follow, not
    /// per-message inner scroll views.
    private var streamContentSignature: Int {
        var total = runtime.presentationEvents.count * 1_000_000
        if let eventID = runtime.activeOutputEventID,
           let event = runtime.presentationEvents.first(where: { $0.id == eventID }),
           case .agentOutput(let output) = event.kind {
            total += output.text.count
        }
        if runtime.isAwaitingAgentOutput { total += 1 }
        if runtime.conversationCaptureNotice != nil { total += 2 }
        return total
    }

    private var activeOutputHasInteractiveMenu: Bool {
        guard let eventID = runtime.activeOutputEventID,
              let event = runtime.presentationEvents.first(where: { $0.id == eventID }),
              case .agentOutput(let output) = event.kind
        else { return false }
        let display = ConversationDisplayText.workstationDerived(output.text)
        return TerminalMenuParser.looksLikeInteractiveMenu(display)
            && !TerminalMenuParser.options(in: display).isEmpty
    }

    private var showsControlStrip: Bool {
        guard !controller.lifecycle.isTerminal else { return false }
        return model.settings.showConversationControls || activeOutputHasInteractiveMenu
    }

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                activityHeader(at: timeline.date)
            }
            Divider().overlay(palette.line)
            if showsControlStrip {
                conversationControlStrip
                Divider().overlay(palette.line)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if !model.selectedTaskConversationDiagnostics.isEmpty {
                            retainedHistoryDiagnosticCard
                        }
                        if case .failed(let detail)? =
                            model.selectedTaskConversationRetentionState {
                            retentionFailureCard(detail)
                        }
                        ForEach(turns) { turn in
                            turnView(turn)
                                .id(turn.id)
                        }
                        if runtime.isAwaitingAgentOutput,
                           runtime.activeOutputEventID == nil {
                            waitingForVisibleOutputCard
                        }
                        if let notice = runtime.conversationCaptureNotice {
                            captureNoticeCard(notice)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("conversation-bottom")
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 18)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: streamContentSignature) { _ in
                    guard followLatest else { return }
                    proxy.scrollTo("conversation-bottom", anchor: .bottom)
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { _ in
                            if followLatest {
                                followLatest = false
                            }
                        }
                )
            }
            if !followLatest {
                jumpToLatestBar
            }
        }
        .background(palette.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(runtime.descriptor.agent.name) conversation")
        .onAppear {
            if !didApplyFollowDefault {
                followLatest = model.settings.followConversationByDefault
                didApplyFollowDefault = true
            }
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
    }

    // MARK: - Header / controls

    private var conversationControlStrip: some View {
        HStack(spacing: 8) {
            permissionModeMenu

            Divider()
                .frame(height: 18)

            Text("Reply")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.faint)

            ForEach(["1", "2", "3", "4"], id: \.self) { choice in
                Button(choice) {
                    model.injectConversationControl(
                        text: choice,
                        submit: true,
                        into: runtime
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Send \(choice)+Enter to the agent menu without opening Raw")
                .accessibilityLabel("Send menu choice \(choice)")
            }

            Button("Enter") {
                model.injectConversationControl(key: .enter, into: runtime)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Esc") {
                model.injectConversationControl(key: .escape, into: runtime)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("↑") {
                model.injectConversationControl(key: .up, into: runtime)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Send up arrow")

            Button("↓") {
                model.injectConversationControl(key: .down, into: runtime)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Send down arrow")

            Spacer(minLength: 4)

            Text("Does not end capture")
                .font(.caption2)
                .foregroundStyle(palette.faint)
                .help(
                    "These keys go to the live agent PTY without treating the action as Raw typing, so capture can continue."
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.rail)
    }

    private var permissionModeMenu: some View {
        let agent = runtime.descriptor.agent
        let current = model.settings.agents.first(where: {
            $0.id == agent.id || $0.name == agent.name
        })?.permissionMode ?? agent.permissionMode

        return Menu {
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
            Divider()
            Text("Applies to next launch of \(agent.name)")
                .font(.caption)
        } label: {
            Label(current.shortLabel, systemImage: "shield.lefthalf.filled")
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .help(current.help)
        .disabled(agent.kind == .shell)
        .accessibilityLabel("Permission mode \(current.displayName)")
    }

    private var jumpToLatestBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                followLatest = true
            } label: {
                Label("Jump to latest", systemImage: "arrow.down.to.line")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .background(palette.rail)
        .accessibilityHint("Resumes following new conversation events")
    }

    private func activityHeader(at date: Date) -> some View {
        let state = controller.visualState(at: date)
        return HStack(spacing: 8) {
            AgentSpriteView(
                profile: runtime.descriptor.agent,
                state: state,
                frameSize: CGSize(width: 30, height: 34)
            )
            Circle()
                .fill(palette.color(forTerminalState: state))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(runtime.descriptor.agent.name)
                .font(.subheadline.bold())
                .foregroundStyle(palette.text)
            Text(conversationStateLabel(state: state, at: date))
                .font(.caption)
                .foregroundStyle(palette.dim)
            Spacer(minLength: 4)
            Button {
                followLatest.toggle()
            } label: {
                Image(systemName: followLatest ? "lock.fill" : "lock.open")
                    .font(.caption)
                    .foregroundStyle(followLatest ? palette.accent : palette.dim)
            }
            .buttonStyle(.borderless)
            .help(
                followLatest
                    ? "Following latest. Click to stop auto-scroll."
                    : "Not following. Click to follow latest."
            )
            .accessibilityLabel(followLatest ? "Following latest" : "Not following latest")
            Button("Raw") {
                runtime.selectedSurface = .raw
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.accent)
            .accessibilityHint("Opens the live PTY view and direct CLI controls")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(runtime.descriptor.agent.name), \(conversationStateLabel(state: state, at: date))"
        )
    }

    private func conversationStateLabel(
        state: TerminalVisualState,
        at date: Date
    ) -> String {
        if runtime.isAwaitingAgentOutput || runtime.activeOutputEventID != nil {
            if case .some(.agentOutput(let output)) =
                runtime.presentationEvents.first(where: {
                    $0.id == runtime.activeOutputEventID
                })?.kind,
               output.state == .live {
                return "Writing"
            }
            return "Working"
        }
        switch state {
        case .working:
            return "Working"
        case .running:
            return "Ready"
        case .launching:
            return "Starting"
        case .detached:
            return "Detached"
        case .exited:
            return "Ended"
        case .failed:
            return "Failed"
        }
    }

    // MARK: - Diagnostics

    private var retainedHistoryDiagnosticCard: some View {
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

    private func retentionFailureCard(_ detail: String) -> some View {
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

    private var waitingForVisibleOutputCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text("Waiting for the next turn…")
                .font(.callout)
                .foregroundStyle(palette.dim)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func captureNoticeCard(_ notice: String) -> some View {
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
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button("Open Raw") {
                runtime.selectedSurface = .raw
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(palette.accent)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Turns

    @ViewBuilder
    private func turnView(_ turn: ConversationTurn) -> some View {
        switch turn.kind {
        case .boundary(let event):
            if case .sessionOpened(let entry) = event.kind {
                sessionBoundary(entry, event: event)
            }
        case .exchange(let user, let outputs):
            VStack(alignment: .leading, spacing: 14) {
                if let user, case .userPrompt(let prompt) = user.kind {
                    promptBlock(prompt, event: user)
                }
                ForEach(outputs) { outputEvent in
                    if case .agentOutput(let output) = outputEvent.kind {
                        assistantBlock(output, event: outputEvent)
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
        return HStack(spacing: 8) {
            Rectangle()
                .fill(palette.line)
                .frame(height: 1)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.faint)
                .fixedSize()
            Text(event.occurredAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(palette.faint)
                .fixedSize()
            Rectangle()
                .fill(palette.line)
                .frame(height: 1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private func promptBlock(
        _ prompt: SubmittedPrompt,
        event: SessionPresentationEvent
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
                if case .forwardedTerminalOutput(let sourceAgentName) = prompt.origin {
                    Text("· forwarded from \(sourceAgentName)")
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                }
                Spacer(minLength: 4)
                Text(relativeOrClock(event.occurredAt))
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }
            if !prompt.text.isEmpty {
                Text(prompt.text)
                    .font(.body)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            deliveryMark(prompt.delivery)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.accent.opacity(0.45))
                .frame(width: 2)
                .padding(.vertical, 2)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func assistantBlock(
        _ output: AgentVisibleOutput,
        event: SessionPresentationEvent
    ) -> some View {
        let isCurrentCapture = runtime.activeOutputEventID == event.id
        let displayText = ConversationDisplayText.workstationDerived(output.text)
        let menuOptions = TerminalMenuParser.options(in: displayText)
        let interactiveMenu = TerminalMenuParser.looksLikeInteractiveMenu(displayText)
            && !menuOptions.isEmpty
            && !controller.lifecycle.isTerminal
        let blocks = ConversationDisplayText.proseBlocks(in: displayText)
        let showLive = isCurrentCapture && output.state == .live

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(runtime.descriptor.agent.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.ink)
                if showLive {
                    ProgressView()
                        .controlSize(.mini)
                    Text("writing")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                } else if output.state == .live && !isCurrentCapture {
                    Text("interrupted")
                        .font(.caption2)
                        .foregroundStyle(palette.faint)
                }
                Spacer(minLength: 4)
                Text(relativeOrClock(event.occurredAt))
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
            }

            if displayText.isEmpty {
                Text("…")
                    .font(.body)
                    .foregroundStyle(palette.faint)
            } else if interactiveMenu {
                // Keep menu text readable as plain lines plus clickable panel.
                Text(displayText)
                    .font(.body)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                interactiveMenuPanel(options: menuOptions)
            } else {
                ConversationProseView(blocks: blocks, palette: palette)
            }

            sourceDisclosure(output: output, event: event)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private func sourceDisclosure(
        output: AgentVisibleOutput,
        event: SessionPresentationEvent
    ) -> some View {
        let sourceLabel: String = {
            switch event.authority {
            case .derivedFromRaw:
                return "Projected from Raw"
            case .toolReported:
                return "Structured adapter"
            default:
                return event.authority.displayName
            }
        }()
        var bits = [sourceLabel]
        if output.truncated {
            bits.append("truncated")
        }
        let display = ConversationDisplayText.workstationDerived(output.text)
        if display != output.text {
            bits.append("chrome filtered")
        }
        return Text(bits.joined(separator: " · "))
            .font(.caption2)
            .foregroundStyle(palette.faint)
            .help(
                "\(output.extraction.displayName). Raw remains the live terminal authority."
            )
            .accessibilityLabel(bits.joined(separator: ", "))
    }

    private func interactiveMenuPanel(options: [TerminalMenuOption]) -> some View {
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
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(option.key)
                            .font(.caption.monospaced().weight(.bold))
                            .foregroundStyle(palette.onAccent)
                            .frame(width: 22, height: 22)
                            .background(palette.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(option.label)
                            .font(.callout)
                            .foregroundStyle(palette.text)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if option.isSelected {
                            Text("selected")
                                .font(.caption2)
                                .foregroundStyle(palette.accent)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        option.isSelected ? palette.accentSoft : palette.lineSoft
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                option.isSelected
                                    ? palette.accent.opacity(0.55)
                                    : palette.line,
                                lineWidth: 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose \(option.key): \(option.label)")
                .help("Sends \(option.key)+Enter without opening Raw")
            }
            HStack(spacing: 8) {
                Button("Enter") {
                    model.injectConversationControl(key: .enter, into: runtime)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Esc") {
                    model.injectConversationControl(key: .escape, into: runtime)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("↑") {
                    model.injectConversationControl(key: .up, into: runtime)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("↓") {
                    model.injectConversationControl(key: .down, into: runtime)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(palette.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.accent.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Key routing

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            handleConversationKeyEvent(event)
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// When Conversation is the active surface and the composer is not first
    /// responder, route menu keys into the live agent PTY. Avoids a focusable
    /// stream container (which drew a large system focus ring on click).
    private func handleConversationKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard !controller.lifecycle.isTerminal,
              runtime.selectedSurface == .conversation
        else { return event }

        if let first = NSApp.keyWindow?.firstResponder {
            if first is NSTextView || first is NSTextField {
                return event
            }
            if let view = first as? NSView,
               view is NSText || view.enclosingScrollView?.documentView is NSTextView {
                return event
            }
        }

        let flags = event.modifierFlags.intersection([
            .command, .control, .option
        ])
        guard flags.isEmpty else { return event }

        if event.keyCode == 36 || event.keyCode == 76 {
            model.injectConversationControl(key: .enter, into: runtime)
            return nil
        }
        if event.keyCode == 53 {
            model.injectConversationControl(key: .escape, into: runtime)
            return nil
        }
        if event.keyCode == 126 {
            model.injectConversationControl(key: .up, into: runtime)
            return nil
        }
        if event.keyCode == 125 {
            model.injectConversationControl(key: .down, into: runtime)
            return nil
        }
        if event.keyCode == 123 {
            model.injectConversationControl(key: .left, into: runtime)
            return nil
        }
        if event.keyCode == 124 {
            model.injectConversationControl(key: .right, into: runtime)
            return nil
        }

        if let chars = event.charactersIgnoringModifiers,
           chars.count == 1,
           let ch = chars.first,
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

    // MARK: - Shared marks

    private func deliveryMark(_ delivery: PromptDeliveryState) -> some View {
        let symbol: String
        let color: Color
        switch delivery {
        case .queued:
            symbol = "clock"
            color = palette.dim
        case .delivered:
            symbol = "checkmark"
            color = palette.ink
        case .failed:
            symbol = "exclamationmark.triangle"
            color = .red
        }
        return Label(delivery.displayName, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(color)
    }

    private func relativeOrClock(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Document prose

private struct ConversationProseView: View {
    let blocks: [ConversationProseBlock]
    let palette: ConduitPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(text)
                        .font(headingFont(level))
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .paragraph(let text):
                    Text(text)
                        .font(.body)
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(palette.dim)
                                Text(item)
                                    .font(.body)
                                    .foregroundStyle(palette.text)
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .code(_, let body):
                    Text(body)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(palette.text)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.sink.opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(palette.line, lineWidth: 1)
                        )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.semibold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

// MARK: - Historical (no live runtime)

/// Read-only projection used when a sidebar task has no open runtime. Selecting
/// history never launches, attaches, or sends anything.
struct ConversationHistoryView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let events: [SessionPresentationEvent]

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    private var turns: [ConversationTurn] {
        SessionPresentation.conversationTurns(from: events)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(turns) { turn in
                historyTurn(turn)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func historyTurn(_ turn: ConversationTurn) -> some View {
        switch turn.kind {
        case .boundary(let event):
            if case .sessionOpened(let entry) = event.kind {
                historyBoundary(entry, event: event)
            }
        case .exchange(let user, let outputs):
            VStack(alignment: .leading, spacing: 14) {
                if let user, case .userPrompt(let prompt) = user.kind {
                    historyPrompt(prompt, event: user)
                }
                ForEach(outputs) { outputEvent in
                    if case .agentOutput(let output) = outputEvent.kind {
                        historyOutput(output, event: outputEvent)
                    }
                }
            }
        }
    }

    private func historyBoundary(
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
        return HStack(spacing: 8) {
            Rectangle()
                .fill(palette.line)
                .frame(height: 1)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.faint)
                .fixedSize()
            Text(
                event.occurredAt.formatted(date: .abbreviated, time: .shortened)
            )
            .font(.caption2)
            .foregroundStyle(palette.faint)
            .fixedSize()
            Rectangle()
                .fill(palette.line)
                .frame(height: 1)
        }
        .accessibilityLabel(title)
    }

    private func historyPrompt(
        _ prompt: SubmittedPrompt,
        event: SessionPresentationEvent
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
                Spacer(minLength: 4)
                Text(
                    event.occurredAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.caption2)
                .foregroundStyle(palette.faint)
            }
            if !prompt.text.isEmpty {
                Text(prompt.text)
                    .font(.body)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(prompt.attachmentPaths, id: \.self) { path in
                Label(path, systemImage: "paperclip")
                    .font(.caption2.monospaced())
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            historicalDeliveryMark(prompt.delivery)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.accent.opacity(0.45))
                .frame(width: 2)
        }
        .padding(.leading, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyOutput(
        _ output: AgentVisibleOutput,
        event: SessionPresentationEvent
    ) -> some View {
        let displayText = ConversationDisplayText.workstationDerived(output.text)
        let blocks = ConversationDisplayText.proseBlocks(in: displayText)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Agent")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 4)
                Text(
                    event.occurredAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.caption2)
                .foregroundStyle(palette.faint)
            }
            if displayText.isEmpty {
                Text("(empty projection)")
                    .font(.callout)
                    .foregroundStyle(palette.faint)
            } else {
                ConversationProseView(blocks: blocks, palette: palette)
            }
            Text(
                event.authority == .derivedFromRaw
                    ? "Projected from Raw"
                    : event.authority.displayName
            )
            .font(.caption2)
            .foregroundStyle(palette.faint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historicalDeliveryMark(
        _ delivery: PromptDeliveryState
    ) -> some View {
        let label: String
        let symbol: String
        let color: Color
        switch delivery {
        case .queued:
            label = "Delivery unconfirmed"
            symbol = "questionmark.circle"
            color = palette.dim
        case .delivered:
            label = delivery.displayName
            symbol = "checkmark"
            color = palette.ink
        case .failed:
            label = delivery.displayName
            symbol = "exclamationmark.triangle"
            color = .red
        }
        return Label(label, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(color)
            .help(
                delivery == .queued
                    ? "The prior process ended before Conduit retained a delivery result. This prompt is not queued for automatic resend."
                    : delivery.displayName
            )
    }
}
#endif
