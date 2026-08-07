#if os(macOS)
import AppKit
import ConduitCore
import SwiftUI

/// A conservative session thread. Native prompts are exact Conduit records;
/// generic output blocks are explicitly labelled projections of rendered Raw.
struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var runtime: TerminalRuntime
    @ObservedObject private var controller: TerminalSessionController
    /// When true, new timeline events pin the thread to the latest card.
    /// Live character growth only scrolls *within* the active output card.
    @State private var followLatest = true
    @State private var expandedOutputIDs: Set<UUID> = []
    @State private var didApplyFollowDefault = false

    init(runtime: TerminalRuntime) {
        self._runtime = ObservedObject(wrappedValue: runtime)
        self._controller = ObservedObject(wrappedValue: runtime.controller)
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    /// Default max height for Derived-from-Raw cards before internal scroll.
    private let collapsedOutputMaxHeight: CGFloat = 280

    var body: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                activityHeader(at: timeline.date)
            }
            Divider().overlay(palette.line)
            if model.settings.showConversationControls,
               !controller.lifecycle.isTerminal {
                conversationControlStrip
                Divider().overlay(palette.line)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        boundaryCard
                        if !model.selectedTaskConversationDiagnostics.isEmpty {
                            retainedHistoryDiagnosticCard
                        }
                        if case .failed(let detail)? =
                            model.selectedTaskConversationRetentionState {
                            retentionFailureCard(detail)
                        }
                        ForEach(runtime.presentationEvents) { event in
                            eventView(event)
                                .id(event.id)
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
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: runtime.presentationEvents.count) { _ in
                    guard followLatest else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
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
        }
    }

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
                model.injectConversationControl(
                    key: .enter,
                    into: runtime
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Esc") {
                model.injectConversationControl(
                    key: .escape,
                    into: runtime
                )
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
                    "These keys go to the live agent PTY without treating the action as Raw typing, so Derived-from-Raw capture can continue."
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
            Text(state.label)
                .font(.caption)
                .foregroundStyle(palette.dim)
            Text("· \(controller.backendLabel)")
                .font(.caption.monospaced())
                .foregroundStyle(palette.faint)
            if let output = controller.lastOutputAt {
                Text("· output \(relativeLabel(from: output, to: date))")
                    .font(.caption)
                    .foregroundStyle(palette.faint)
            }
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
                    ? "Following latest messages. Click to stop auto-scroll."
                    : "Not following. Click to follow latest messages."
            )
            .accessibilityLabel(followLatest ? "Following latest" : "Not following latest")
            Button("Open Raw") {
                runtime.selectedSurface = .raw
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.accent)
            .accessibilityHint("Opens the live PTY view and direct CLI controls")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(runtime.descriptor.agent.name), \(state.label), \(controller.backendLabel)"
        )
    }

    private var boundaryCard: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(palette.faint)
            Text("Stream of Conduit records and Derived-from-Raw projections. Raw remains the live terminal authority.")
                .font(.caption)
                .foregroundStyle(palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

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

    @ViewBuilder
    private func eventView(_ event: SessionPresentationEvent) -> some View {
        switch event.kind {
        case .sessionOpened(let entry):
            sessionOpenedCard(entry, event: event)
        case .userPrompt(let prompt):
            promptCard(prompt, event: event)
        case .agentOutput(let output):
            agentOutputCard(output, event: event)
        }
    }

    private var waitingForVisibleOutputCard: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text("Waiting for visible terminal output · not private chain-of-thought")
                .font(.caption)
                .foregroundStyle(palette.dim)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func captureNoticeCard(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(palette.dim)
            VStack(alignment: .leading, spacing: 2) {
                Text("Capture stopped")
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

    private func agentOutputCard(
        _ output: AgentVisibleOutput,
        event: SessionPresentationEvent
    ) -> some View {
        let isCurrentCapture = runtime.activeOutputEventID == event.id
        let stateLabel = output.state == .live && !isCurrentCapture
            ? "Capture interrupted"
            : output.state.displayName
        let displayText = ConversationDisplayText.compactDerived(output.text)
        let isExpanded = expandedOutputIDs.contains(event.id)
        let lineCount = displayText.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).count
        let shouldClamp = !isExpanded && lineCount > 18

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Derived from Raw")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.dim)
                Text("· \(stateLabel)")
                    .font(.caption2)
                    .foregroundStyle(palette.faint)
                if isCurrentCapture && output.state == .live {
                    ProgressView()
                        .controlSize(.mini)
                }
                Spacer(minLength: 4)
                Button("Open Raw") {
                    runtime.selectedSurface = .raw
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(palette.accent)
            }
            derivedOutputBody(
                displayText: displayText,
                clamped: shouldClamp,
                eventID: event.id,
                isLive: isCurrentCapture && output.state == .live
            )
            HStack(spacing: 6) {
                Text(output.extraction.displayName)
                if output.truncated {
                    Text("· truncated revision")
                }
                if displayText != output.text {
                    Text("· blanks compacted")
                }
                Spacer(minLength: 4)
                if lineCount > 18 {
                    Button(isExpanded ? "Collapse" : "Expand") {
                        if isExpanded {
                            expandedOutputIDs.remove(event.id)
                        } else {
                            expandedOutputIDs.insert(event.id)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.accent)
                }
                authorityLine(event)
            }
            .font(.caption2)
            .foregroundStyle(palette.faint)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func derivedOutputBody(
        displayText: String,
        clamped: Bool,
        eventID: UUID,
        isLive: Bool
    ) -> some View {
        let textView = Text(displayText)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(palette.text)
            .textSelection(.enabled)
            .lineSpacing(1)
            .frame(maxWidth: .infinity, alignment: .leading)

        if clamped {
            ScrollViewReader { innerProxy in
                ScrollView {
                    textView
                        .padding(.vertical, 2)
                        .id("output-body-\(eventID)")
                }
                .frame(maxHeight: collapsedOutputMaxHeight, alignment: .top)
                .onChange(of: displayText.count) { _ in
                    guard isLive else { return }
                    innerProxy.scrollTo("output-body-\(eventID)", anchor: .bottom)
                }
            }
        } else {
            textView
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sessionOpenedCard(
        _ entry: SessionEntry,
        event: SessionPresentationEvent
    ) -> some View {
        let title: String
        let detail: String
        switch entry {
        case .started(let agentName, let requestedBackend):
            title = "Launch requested for \(agentName)"
            detail = "Backend \(requestedBackend) · attach not proven by this record"
        case .resumed(let agentName, let tmuxName, let attachedElsewhere):
            title = "Reattach requested for \(agentName)"
            detail = "tmux \(tmuxName)"
                + (attachedElsewhere ? " · another client was attached" : "")
                + " · prior Raw not replayed"
        }

        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(palette.dim)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(palette.faint)
            authorityLine(event)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func promptCard(
        _ prompt: SubmittedPrompt,
        event: SessionPresentationEvent
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("You")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.accent)
                if case .forwardedTerminalOutput(let sourceAgentName) = prompt.origin {
                    Text("· forwarded from \(sourceAgentName)")
                        .font(.caption2)
                        .foregroundStyle(palette.dim)
                }
                Spacer(minLength: 4)
                authorityLine(event)
            }
            if !prompt.text.isEmpty {
                Text(prompt.text)
                    .font(.body)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
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
        .padding(.vertical, 8)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.accent.opacity(0.55))
                .frame(width: 2)
        }
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

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
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }

    private func authorityLine(_ event: SessionPresentationEvent) -> some View {
        Text("\(event.authority.displayName) · \(event.occurredAt.formatted(date: .omitted, time: .shortened))")
            .font(.caption2)
            .foregroundStyle(palette.faint)
    }

    private func relativeLabel(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }

}

private extension PromptOrigin {
    var isForwarded: Bool {
        if case .forwardedTerminalOutput = self { return true }
        return false
    }
}

/// Read-only projection used when a sidebar task has no open runtime. Selecting
/// history never launches, attaches, or sends anything.
struct ConversationHistoryView: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    let events: [SessionPresentationEvent]

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(events) { event in
                historyEvent(event)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func historyEvent(_ event: SessionPresentationEvent) -> some View {
        switch event.kind {
        case .sessionOpened(let entry):
            historyBoundary(entry, event: event)
        case .userPrompt(let prompt):
            historyPrompt(prompt, event: event)
        case .agentOutput(let output):
            historyOutput(output, event: event)
        }
    }

    private func historyBoundary(
        _ entry: SessionEntry,
        event: SessionPresentationEvent
    ) -> some View {
        let title: String
        switch entry {
        case .started(let agentName, _):
            title = "Launch requested for \(agentName)"
        case .resumed(let agentName, let tmuxName, let attachedElsewhere):
            title = "Reattach requested for \(agentName) · \(tmuxName)"
                + (attachedElsewhere ? " · another client was attached" : "")
        }
        return Label(title, systemImage: "bolt.horizontal.circle")
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.dim)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(palette.lineSoft)
            .clipShape(Capsule())
            .accessibilityLabel(
                "\(title), \(event.authority.displayName), \(event.occurredAt.formatted())"
            )
    }

    private func historyPrompt(
        _ prompt: SubmittedPrompt,
        event: SessionPresentationEvent
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("You")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.accent)
                Spacer(minLength: 4)
                Text(
                    "\(event.authority.displayName) · "
                        + event.occurredAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                )
                .font(.caption2)
                .foregroundStyle(palette.faint)
            }
            if !prompt.text.isEmpty {
                Text(prompt.text)
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
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
        .padding(.vertical, 8)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.accent.opacity(0.55))
                .frame(width: 2)
        }
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func historyOutput(
        _ output: AgentVisibleOutput,
        event: SessionPresentationEvent
    ) -> some View {
        let stateLabel = output.state == .live
            ? "Capture interrupted"
            : output.state.displayName
        let displayText = ConversationDisplayText.compactDerived(output.text)

        return VStack(alignment: .leading, spacing: 6) {
            Text("Derived from Raw · \(stateLabel)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.dim)
            Text(displayText)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(output.extraction.displayName)
                Spacer(minLength: 4)
                Text(
                    "\(event.authority.displayName) · "
                        + event.occurredAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                )
            }
            .font(.caption2)
            .foregroundStyle(palette.faint)
        }
        .padding(.vertical, 8)
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
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .help(
                delivery == .queued
                    ? "The prior process ended before Conduit retained a delivery result. This prompt is not queued for automatic resend."
                    : delivery.displayName
            )
    }
}
#endif
